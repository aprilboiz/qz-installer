#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Detects existing QZ Tray installation and configures SSL certificates
.DESCRIPTION
    Robust detection of QZ Tray installations (even in custom paths) using multiple methods.
    Generates SSL certificates with primary IPv4 and deploys override certificate.
.NOTES
    Version: 3.0 (Enhanced Detection & Interactive)
    Enhanced: Multi-method detection (Process, Registry, Search), interactive mode
.EXAMPLE
    .\detect-install.ps1
#>

# ============================================================
# HELPER: Detect OS Platform
# ============================================================
function Get-OSPlatform {
    if($Env:OS -and "$Env:OS".Substring(0, 3) -like "Win*") {
        return "Windows"
    }
    
    # For PowerShell Core 6+
    if($PSVersionTable.PSVersion.Major -ge 6) {
        if($IsMacOS) { return "macOS" }
        if($IsLinux) { return "Linux" }
    }
    
    # Fallback for older PowerShell on Unix
    try {
        $unixName = uname -s 2>$null
        if($unixName -eq "Darwin") { return "macOS" }
        if($unixName -eq "Linux") { return "Linux" }
    } catch { }
    
    return "Unknown"
}

# ============================================================
# FUNCTION: Get Primary IPv4 Address
# ============================================================
function Get-PrimaryIPv4 {
    param(
        [string]$TestHost = "google.com",
        [int]$TestPort = 443
    )
    
    try {
        Write-Host "Detecting primary network interface..." -ForegroundColor Cyan
        
        $socket = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Tcp
        )
        
        $socket.SendTimeout = 240000
        $socket.ReceiveTimeout = 240000
        
        $endpoint = New-Object System.Net.IPEndPoint(
            [System.Net.Dns]::GetHostAddresses($TestHost)[0],
            $TestPort
        )
        $socket.Connect($endpoint)
        
        $primaryIP = $socket.LocalEndPoint.Address.ToString()
        $socket.Close()
        
        Write-Host "Primary IPv4 detected: " -NoNewline
        Write-Host "$primaryIP" -ForegroundColor Green
        
        return $primaryIP
    }
    catch {
        Write-Warning "Unable to detect primary IPv4: $_"
        return $null
    }
}

# ============================================================
# FUNCTION: Check if QZ Tray is running
# Enhanced to detect both qz-tray.exe and Java processes (Liberica Platform binary support)
# ============================================================
function Test-QZTrayRunning {
    $os = Get-OSPlatform
    
    switch($os) {
        "Windows" {
            # Windows: Check for qz-tray.exe process
            try {
                $qzTrayProcess = Get-Process -Name "qz-tray" -ErrorAction SilentlyContinue
                if($qzTrayProcess) {
                    return $true
                }
            } catch { }
            
            # Windows: Find Java processes with QZ Tray patterns in command line
            # This catches Liberica Platform binary and other JVM implementations
            try {
                $javaProcesses = Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'" -ErrorAction SilentlyContinue
                
                foreach($proc in $javaProcesses) {
                    if($proc.CommandLine -like "*qz-tray.jar*" -or 
                       $proc.CommandLine -like "*qz.App*" -or 
                       $proc.CommandLine -like "*qz.ws.PrintSocketServer*") {
                        return $true
                    }
                }
            } catch { }
            return $false
        }
        
        "macOS" {
            # macOS: Use pgrep
            $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
            foreach($pattern in $patterns) {
                $result = pgrep -f "$pattern" 2>/dev/null
                if($result) { return $true }
            }
            return $false
        }
        
        "Linux" {
            # Linux: Check systemd service first, then pgrep
            try {
                $serviceActive = systemctl --user is-active qz-tray 2>/dev/null
                if($serviceActive -eq "active") { return $true }
            } catch { }
            
            # Fallback to pgrep
            $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
            foreach($pattern in $patterns) {
                $result = pgrep -f "$pattern" 2>/dev/null
                if($result) { return $true }
            }
            return $false
        }
        
        default {
            return $false
        }
    }
}

# ============================================================
# FUNCTION: Stop QZ Tray
# Enhanced to stop both qz-tray.exe and Java processes (including Liberica Platform binary)
# ============================================================
function Stop-QZTray {
    param([int]$MaxWaitSeconds = 10)
    
    Write-Host "Stopping QZ Tray..." -ForegroundColor Yellow
    
    $os = Get-OSPlatform
    
    switch($os) {
        "Windows" {
            # Windows: Stop qz-tray.exe process first
            try {
                $qzTrayProcess = Get-Process -Name "qz-tray" -ErrorAction SilentlyContinue
                if($qzTrayProcess) {
                    Write-Host "  Terminating qz-tray.exe (PID: $($qzTrayProcess.Id))..." -ForegroundColor Gray
                    Stop-Process -Name "qz-tray" -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 1
                }
            } catch { }
            
            # Windows: Kill all Java processes running QZ Tray
            try {
                $javaProcesses = Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'" -ErrorAction SilentlyContinue
                
                $killCount = 0
                foreach($proc in $javaProcesses) {
                    if($proc.CommandLine -like "*qz-tray.jar*" -or 
                       $proc.CommandLine -like "*qz.App*" -or 
                       $proc.CommandLine -like "*qz.ws.PrintSocketServer*") {
                        
                        Write-Host "  Terminating QZ Tray Java process (PID: $($proc.ProcessId))..." -ForegroundColor Gray
                        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                        $killCount++
                    }
                }
                
                if($killCount -gt 0) {
                    Start-Sleep -Seconds 2
                    Write-Host "  [✓] Stopped $killCount QZ Tray Java process(es)" -ForegroundColor Green
                }
                
                return $true
            }
            catch {
                Write-Warning "Error stopping QZ Tray: $_"
                return $false
            }
        }
        
        "macOS" {
            # macOS: Try graceful quit, then kill
            osascript -e 'quit app "QZ Tray"' 2>/dev/null
            Start-Sleep -Seconds 2
            
            # Force kill if needed
            $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
            
            foreach($pattern in $patterns) {
                $pids = pgrep -f "$pattern" 2>/dev/null
                if($pids) {
                    foreach($pid in $pids -split '\s+') {
                        if($pid -match '^\d+$') {
                            Write-Host "  Terminating QZ Tray process (PID: $pid)..." -ForegroundColor Gray
                            kill -TERM $pid 2>/dev/null
                        }
                    }
                }
            }
            
            # Wait for graceful shutdown
            $waited = 0
            while((Test-QZTrayRunning) -and ($waited -lt $MaxWaitSeconds)) {
                Start-Sleep -Seconds 1
                $waited++
            }
            
            # Force kill if still running
            if(Test-QZTrayRunning) {
                Write-Host "  Forcing shutdown..." -ForegroundColor Gray
                foreach($pattern in $patterns) {
                    pkill -KILL -f "$pattern" 2>/dev/null
                }
            }
            
            Write-Host "  [✓] QZ Tray stopped" -ForegroundColor Green
            return $true
        }
        
        "Linux" {
            # Linux: Stop systemd service or kill processes
            try {
                systemctl --user stop qz-tray 2>/dev/null
            } catch { }
            
            # Also kill via pgrep
            $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
            
            foreach($pattern in $patterns) {
                $pids = pgrep -f "$pattern" 2>/dev/null
                if($pids) {
                    foreach($pid in $pids -split '\s+') {
                        if($pid -match '^\d+$') {
                            Write-Host "  Terminating QZ Tray process (PID: $pid)..." -ForegroundColor Gray
                            kill -TERM $pid 2>/dev/null
                        }
                    }
                }
            }
            
            # Wait for graceful shutdown
            $waited = 0
            while((Test-QZTrayRunning) -and ($waited -lt $MaxWaitSeconds)) {
                Start-Sleep -Seconds 1
                $waited++
            }
            
            # Force kill if still running
            if(Test-QZTrayRunning) {
                Write-Host "  Forcing shutdown..." -ForegroundColor Gray
                foreach($pattern in $patterns) {
                    pkill -KILL -f "$pattern" 2>/dev/null
                }
            }
            
            Write-Host "  [✓] QZ Tray stopped" -ForegroundColor Green
            return $true
        }
        
        default {
            Write-Warning "Unsupported OS: $os"
            return $false
        }
    }
}

# ============================================================
# FUNCTION: Start QZ Tray
# ============================================================
function Start-QZTray {
    param([string]$InstallPath)
    
    Write-Host "Starting QZ Tray..." -ForegroundColor Yellow
    
    $os = Get-OSPlatform
    
    try {
        switch($os) {
            "Windows" {
                $exePath = Join-Path $InstallPath "qz-tray.exe"
                if(Test-Path $exePath) {
                    Start-Process -FilePath $exePath
                    Start-Sleep -Seconds 3
                    
                    if(Test-QZTrayRunning) {
                        Write-Host "  [✓] QZ Tray started successfully" -ForegroundColor Green
                        return $true
                    } else {
                        Write-Warning "QZ Tray process not detected after start"
                        return $false
                    }
                } else {
                    Write-Warning "QZ Tray executable not found: $exePath"
                    return $false
                }
            }
            
            "macOS" {
                open -a "QZ Tray" 2>/dev/null
                Start-Sleep -Seconds 3
                
                if(Test-QZTrayRunning) {
                    Write-Host "  [✓] QZ Tray started successfully" -ForegroundColor Green
                    return $true
                } else {
                    Write-Warning "QZ Tray not detected after start"
                    return $false
                }
            }
            
            "Linux" {
                # Try systemd service first
                try {
                    $serviceExists = systemctl --user list-unit-files qz-tray.service 2>/dev/null
                    if($serviceExists) {
                        systemctl --user start qz-tray 2>/dev/null
                        Start-Sleep -Seconds 3
                        
                        if(Test-QZTrayRunning) {
                            Write-Host "  [✓] QZ Tray started via systemd" -ForegroundColor Green
                            return $true
                        }
                    }
                } catch { }
                
                # Fallback: Launch executable directly
                if(Test-Path "$InstallPath/qz-tray") {
                    nohup "$InstallPath/qz-tray" >/dev/null 2>&1 &
                    Start-Sleep -Seconds 3
                    
                    if(Test-QZTrayRunning) {
                        Write-Host "  [✓] QZ Tray started successfully" -ForegroundColor Green
                        return $true
                    } else {
                        Write-Warning "QZ Tray not detected after start"
                        return $false
                    }
                } else {
                    Write-Warning "QZ Tray executable not found: $InstallPath/qz-tray"
                    return $false
                }
            }
            
            default {
                Write-Warning "Unsupported OS: $os"
                return $false
            }
        }
    }
    catch {
        Write-Warning "Error starting QZ Tray: $_"
        return $false
    }
}

# ============================================================
# FUNCTION: Pause before exit (Interactive Mode)
# ============================================================
function Invoke-Pause {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================================
# WINDOWS: Find QZ Tray from running processes
# ============================================================
function Find-QZTrayFromProcess-Windows {
    Write-Host "`n[Method 1] Detecting from running processes..." -ForegroundColor Cyan
    
    # Check qz-tray.exe process
    try {
        $qzTrayProcess = Get-Process -Name "qz-tray" -ErrorAction SilentlyContinue
        if($qzTrayProcess -and $qzTrayProcess.Path) {
            $installPath = Split-Path -Parent $qzTrayProcess.Path
            Write-Host "  Found via qz-tray.exe process: " -NoNewline
            Write-Host "$installPath" -ForegroundColor Green
            return $installPath
        }
    } catch { }
    
    # Check Java processes running QZ Tray
    try {
        $javaProcesses = Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'" -ErrorAction SilentlyContinue
        
        foreach($proc in $javaProcesses) {
            if($proc.CommandLine -like "*qz-tray.jar*" -or 
               $proc.CommandLine -like "*qz.App*" -or 
               $proc.CommandLine -like "*qz.ws.PrintSocketServer*") {
                
                # Try to extract path from command line
                $cmdLine = $proc.CommandLine
                
                # Look for qz-tray.jar in the command line
                if($cmdLine -match '([A-Z]:\\[^"]+\\qz-tray\.jar)') {
                    $jarPath = $matches[1]
                    $installPath = Split-Path -Parent $jarPath
                    Write-Host "  Found via Java process (qz-tray.jar): " -NoNewline
                    Write-Host "$installPath" -ForegroundColor Green
                    return $installPath
                }
                
                # Try to get executable path
                try {
                    $exePath = (Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue).Path
                    if($exePath) {
                        # Check if it's in a QZ Tray directory
                        $parentPath = Split-Path -Parent $exePath
                        if($parentPath -like "*QZ Tray*" -or $parentPath -like "*qz-tray*") {
                            Write-Host "  Found via Java process path: " -NoNewline
                            Write-Host "$parentPath" -ForegroundColor Green
                            return $parentPath
                        }
                    }
                } catch { }
            }
        }
    } catch { }
    
    Write-Host "  Not found in running processes" -ForegroundColor Gray
    return $null
}

# ============================================================
# WINDOWS: Find QZ Tray from Windows Registry
# ============================================================
function Find-QZTrayFromRegistry-Windows {
    Write-Host "`n[Method 2] Searching Windows Registry..." -ForegroundColor Cyan
    
    # Registry paths to search
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach($regPath in $registryPaths) {
        try {
            $items = Get-ItemProperty $regPath -ErrorAction SilentlyContinue | 
                     Where-Object { $_.DisplayName -like "*QZ Tray*" }
            
            foreach($item in $items) {
                # Try InstallLocation first
                if($item.InstallLocation -and (Test-Path $item.InstallLocation)) {
                    Write-Host "  Found via Registry (InstallLocation): " -NoNewline
                    Write-Host "$($item.InstallLocation)" -ForegroundColor Green
                    return $item.InstallLocation.TrimEnd('\')
                }
                
                # Try UninstallString
                if($item.UninstallString) {
                    $uninstallPath = $item.UninstallString -replace '"', ''
                    if(Test-Path $uninstallPath) {
                        $installPath = Split-Path -Parent $uninstallPath
                        Write-Host "  Found via Registry (UninstallString): " -NoNewline
                        Write-Host "$installPath" -ForegroundColor Green
                        return $installPath
                    }
                }
                
                # Try DisplayIcon
                if($item.DisplayIcon) {
                    $iconPath = $item.DisplayIcon -replace '"', ''
                    if(Test-Path $iconPath) {
                        $installPath = Split-Path -Parent $iconPath
                        Write-Host "  Found via Registry (DisplayIcon): " -NoNewline
                        Write-Host "$installPath" -ForegroundColor Green
                        return $installPath
                    }
                }
            }
        } catch { }
    }
    
    Write-Host "  Not found in Registry" -ForegroundColor Gray
    return $null
}

# ============================================================
# WINDOWS: Search standard and custom locations
# ============================================================
function Find-QZTrayFromSearch-Windows {
    Write-Host "`n[Method 3] Searching file system..." -ForegroundColor Cyan
    
    # Standard installation paths
    $standardPaths = @(
        "${Env:ProgramFiles}\QZ Tray",
        "${Env:ProgramFiles(x86)}\QZ Tray",
        "C:\Program Files\QZ Tray",
        "C:\Program Files (x86)\QZ Tray",
        "${Env:LOCALAPPDATA}\QZ Tray",
        "${Env:APPDATA}\QZ Tray"
    )
    
    foreach($path in $standardPaths) {
        if(Test-Path "$path\qz-tray.exe") {
            Write-Host "  Found in standard location: " -NoNewline
            Write-Host "$path" -ForegroundColor Green
            return $path
        }
    }
    
    # Deep search in Program Files (limited depth to avoid performance issues)
    Write-Host "  Performing deep search in Program Files..." -ForegroundColor Gray
    $programFilesPaths = @(
        ${Env:ProgramFiles},
        ${Env:ProgramFiles(x86)},
        "C:\Program Files",
        "C:\Program Files (x86)"
    )
    
    foreach($basePath in $programFilesPaths) {
        if(Test-Path $basePath) {
            try {
                $found = Get-ChildItem -Path $basePath -Filter "qz-tray.exe" -Recurse -ErrorAction SilentlyContinue -Depth 3 | 
                         Select-Object -First 1
                
                if($found) {
                    $installPath = Split-Path -Parent $found.FullName
                    Write-Host "  Found via deep search: " -NoNewline
                    Write-Host "$installPath" -ForegroundColor Green
                    return $installPath
                }
            } catch { }
        }
    }
    
    Write-Host "  Not found in file system search" -ForegroundColor Gray
    return $null
}

# ============================================================
# macOS: Find QZ Tray installation
# ============================================================
function Find-QZTray-macOS {
    Write-Host "`nDetecting QZ Tray on macOS..." -ForegroundColor Cyan
    
    # Method 1: Standard locations
    Write-Host "  [Method 1] Checking standard locations..." -ForegroundColor Gray
    $standardPaths = @(
        "/Applications/QZ Tray.app/Contents/MacOS",
        "$HOME/Applications/QZ Tray.app/Contents/MacOS"
    )
    
    foreach($path in $standardPaths) {
        if(Test-Path "$path/QZ Tray") {
            Write-Host "  Found in standard location: " -NoNewline
            Write-Host "$path" -ForegroundColor Green
            return $path
        }
    }
    
    # Method 2: Spotlight search using mdfind
    Write-Host "  [Method 2] Using Spotlight search..." -ForegroundColor Gray
    try {
        $spotlightResult = mdfind "kMDItemDisplayName == 'QZ Tray.app'" 2>/dev/null | Select-Object -First 1
        if($spotlightResult) {
            $installPath = "$spotlightResult/Contents/MacOS"
            if(Test-Path "$installPath/QZ Tray") {
                Write-Host "  Found via Spotlight: " -NoNewline
                Write-Host "$installPath" -ForegroundColor Green
                return $installPath
            }
        }
    } catch { }
    
    # Method 3: Running process
    Write-Host "  [Method 3] Checking running processes..." -ForegroundColor Gray
    try {
        $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
        foreach($pattern in $patterns) {
            $pids = pgrep -f "$pattern" 2>/dev/null
            if($pids) {
                foreach($pid in $pids -split '\s+') {
                    if($pid -match '^\d+$') {
                        $exePath = readlink "/proc/$pid/exe" 2>/dev/null
                        if(-not $exePath) {
                            # macOS doesn't have /proc, try lsof
                            $lsofOutput = lsof -p $pid 2>/dev/null | grep "QZ Tray"
                            if($lsofOutput -match '(/.*QZ Tray\.app/Contents/MacOS)') {
                                $installPath = $matches[1]
                                Write-Host "  Found via running process: " -NoNewline
                                Write-Host "$installPath" -ForegroundColor Green
                                return $installPath
                            }
                        }
                    }
                }
            }
        }
    } catch { }
    
    Write-Host "  Not found on macOS" -ForegroundColor Red
    return $null
}

# ============================================================
# Linux: Find QZ Tray installation
# ============================================================
function Find-QZTray-Linux {
    Write-Host "`nDetecting QZ Tray on Linux..." -ForegroundColor Cyan
    
    # Method 1: Standard locations
    Write-Host "  [Method 1] Checking standard locations..." -ForegroundColor Gray
    $standardPaths = @(
        "/opt/qz-tray",
        "/usr/local/qz-tray",
        "/usr/share/qz-tray",
        "$HOME/.local/share/qz-tray",
        "$HOME/.local/qz-tray"
    )
    
    foreach($path in $standardPaths) {
        if(Test-Path "$path/qz-tray") {
            Write-Host "  Found in standard location: " -NoNewline
            Write-Host "$path" -ForegroundColor Green
            return $path
        }
    }
    
    # Method 2: systemd service file
    Write-Host "  [Method 2] Checking systemd service..." -ForegroundColor Gray
    try {
        $serviceFile = "$HOME/.config/systemd/user/qz-tray.service"
        if(Test-Path $serviceFile) {
            $serviceContent = Get-Content $serviceFile -Raw
            if($serviceContent -match 'ExecStart=([^\s]+)') {
                $exePath = $matches[1]
                if(Test-Path $exePath) {
                    $installPath = Split-Path -Parent $exePath
                    Write-Host "  Found via systemd service: " -NoNewline
                    Write-Host "$installPath" -ForegroundColor Green
                    return $installPath
                }
            }
        }
    } catch { }
    
    # Method 3: Running process
    Write-Host "  [Method 3] Checking running processes..." -ForegroundColor Gray
    try {
        $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
        foreach($pattern in $patterns) {
            $pids = pgrep -f "$pattern" 2>/dev/null
            if($pids) {
                foreach($pid in $pids -split '\s+') {
                    if($pid -match '^\d+$') {
                        $exePath = readlink "/proc/$pid/exe" 2>/dev/null
                        if($exePath -and (Test-Path $exePath)) {
                            $installPath = Split-Path -Parent $exePath
                            Write-Host "  Found via running process: " -NoNewline
                            Write-Host "$installPath" -ForegroundColor Green
                            return $installPath
                        }
                    }
                }
            }
        }
    } catch { }
    
    # Method 4: which/whereis/locate commands
    Write-Host "  [Method 4] Using which/whereis commands..." -ForegroundColor Gray
    try {
        $whichResult = which qz-tray 2>/dev/null
        if($whichResult -and (Test-Path $whichResult)) {
            $installPath = Split-Path -Parent $whichResult
            Write-Host "  Found via which: " -NoNewline
            Write-Host "$installPath" -ForegroundColor Green
            return $installPath
        }
    } catch { }
    
    try {
        $whereisResult = whereis -b qz-tray 2>/dev/null
        if($whereisResult -match 'qz-tray: (.+)') {
            $exePath = $matches[1].Trim()
            if(Test-Path $exePath) {
                $installPath = Split-Path -Parent $exePath
                Write-Host "  Found via whereis: " -NoNewline
                Write-Host "$installPath" -ForegroundColor Green
                return $installPath
            }
        }
    } catch { }
    
    Write-Host "  Not found on Linux" -ForegroundColor Red
    return $null
}

# ============================================================
# MAIN SCRIPT
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "QZ Tray Detection & Configuration Script" -ForegroundColor Cyan
Write-Host "Version 3.0 (Enhanced Detection & Interactive)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$os = Get-OSPlatform
Write-Host "Detected OS: " -NoNewline
Write-Host "$os" -ForegroundColor Yellow

# Detect QZ Tray installation
$qzInstallPath = $null

switch($os) {
    "Windows" {
        # Try multiple detection methods for Windows
        $qzInstallPath = Find-QZTrayFromProcess-Windows
        if(-not $qzInstallPath) {
            $qzInstallPath = Find-QZTrayFromRegistry-Windows
        }
        if(-not $qzInstallPath) {
            $qzInstallPath = Find-QZTrayFromSearch-Windows
        }
    }
    
    "macOS" {
        $qzInstallPath = Find-QZTray-macOS
    }
    
    "Linux" {
        $qzInstallPath = Find-QZTray-Linux
    }
    
    default {
        Write-Host "`nUnsupported operating system: $os" -ForegroundColor Red
        Invoke-Pause
        exit 1
    }
}

# Check if QZ Tray was found
if(-not $qzInstallPath) {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR: QZ Tray installation not found!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "`nPlease install QZ Tray first using the install.ps1 script." -ForegroundColor Yellow
    Write-Host "Or manually install QZ Tray from: https://qz.io/download/" -ForegroundColor Yellow
    Invoke-Pause
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "QZ Tray installation detected!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Installation path: " -NoNewline
Write-Host "$qzInstallPath" -ForegroundColor Cyan

# Stop QZ Tray if running
if(Test-QZTrayRunning) {
    Write-Host "`n" -NoNewline
    Stop-QZTray
    Start-Sleep -Seconds 2
}

# Generate SSL certificates with primary IPv4
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Generating SSL Certificate..." -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$primaryIPv4 = Get-PrimaryIPv4

# Determine console executable path
$qzConsoleExe = $null

switch($os) {
    "Windows" {
        $qzConsoleExe = Join-Path $qzInstallPath "qz-tray-console.exe"
    }
    "macOS" {
        $qzConsoleExe = Join-Path $qzInstallPath "QZ Tray"
    }
    "Linux" {
        $qzConsoleExe = Join-Path $qzInstallPath "qz-tray"
    }
}

if($qzConsoleExe -and (Test-Path $qzConsoleExe)) {
    Write-Host "QZ Tray console found at: " -NoNewline
    Write-Host "$qzConsoleExe" -ForegroundColor Green
    
    # Build hostname list
    $hostList = "localhost"
    if($primaryIPv4) {
        $hostList += ";$primaryIPv4"
        Write-Host "Generating certificate for: " -NoNewline
        Write-Host "localhost, $primaryIPv4" -ForegroundColor Yellow
    } else {
        Write-Host "Generating certificate for: " -NoNewline
        Write-Host "localhost only" -ForegroundColor Yellow
        Write-Warning "Could not detect primary IPv4"
    }
    
    try {
        Write-Host "`nExecuting certificate generation..." -ForegroundColor Cyan
        Write-Host "Command: " -NoNewline
        Write-Host "`"$qzConsoleExe`" certgen --host `"$hostList`"" -ForegroundColor Gray
        Write-Host ""
        
        if($os -eq "Windows") {
            # Windows: Use qz-tray-console.exe with elevation
            $certgenProcess = Start-Process -FilePath $qzConsoleExe `
                                           -ArgumentList "certgen", "--host", "`"$hostList`"" `
                                           -Verb RunAs `
                                           -Wait `
                                           -PassThru
            
            if($certgenProcess.ExitCode -eq 0) {
                Write-Host "`n[SUCCESS]" -ForegroundColor Green -NoNewline
                Write-Host " SSL Certificate generated successfully!"
            } elseif($certgenProcess.ExitCode -eq $null) {
                Write-Host "`n[INFO]" -ForegroundColor Yellow -NoNewline
                Write-Host " Certificate generation completed"
            } else {
                Write-Warning "Certificate generation returned exit code: $($certgenProcess.ExitCode)"
            }
        } else {
            # macOS/Linux
            $certgenCmd = "`"$qzConsoleExe`" certgen --host `"$hostList`""
            if (Get-Command "sudo" -errorAction SilentlyContinue) {
                sudo bash -c $certgenCmd
            } else {
                bash -c $certgenCmd
            }
            
            Write-Host "`n[SUCCESS]" -ForegroundColor Green -NoNewline
            Write-Host " SSL Certificate generated successfully!"
        }
        
        if($primaryIPv4) {
            Write-Host "`nYou can now access QZ Tray via HTTPS at:" -ForegroundColor Cyan
            Write-Host "  - https://localhost:8181" -ForegroundColor White
            Write-Host "  - https://${primaryIPv4}:8181" -ForegroundColor White
        } else {
            Write-Host "`nYou can now access QZ Tray via HTTPS at:" -ForegroundColor Cyan
            Write-Host "  - https://localhost:8181" -ForegroundColor White
        }
        
    } catch {
        Write-Warning "Certificate generation encountered an issue: $_"
    }
} else {
    Write-Warning "QZ Tray console executable not found at: $qzConsoleExe"
}

# Deploy override certificate
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Deploying Override Certificate..." -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$OVERRIDE_URL = "https://aprilboiz.github.io/qz-installer/override.crt"

try {
    $overridePath = Join-Path $qzInstallPath "override.crt"
    
    Write-Host "Downloading override.crt..." -ForegroundColor Yellow
    Write-Host "  Source: " -NoNewline
    Write-Host "$OVERRIDE_URL" -ForegroundColor Blue
    Write-Host "  Target: " -NoNewline
    Write-Host "$overridePath" -ForegroundColor Blue
    
    # Download to temp location first
    $tempOverride = Join-Path $env:TEMP "qz-override.crt"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $OVERRIDE_URL -OutFile $tempOverride -UseBasicParsing
    
    if($os -eq "Windows") {
        # Windows: Use PowerShell to copy with elevation
        Write-Host "`n  Copying to installation directory (requires elevation)..." -ForegroundColor Gray
        
        # Create a PowerShell script to copy the file with admin rights
        $copyScript = @"
`$ErrorActionPreference = 'Stop'
try {
    Copy-Item -Path '$tempOverride' -Destination '$overridePath' -Force
    if(Test-Path '$overridePath') {
        exit 0
    } else {
        exit 1
    }
} catch {
    Write-Error `$_
    exit 1
}
"@
        
        # Save script to temp file
        $tempScript = Join-Path $env:TEMP "qz-copy-override.ps1"
        $copyScript | Out-File -FilePath $tempScript -Encoding UTF8 -Force
        
        # Execute with elevation
        $copyProcess = Start-Process -FilePath "powershell.exe" `
                                    -ArgumentList "-ExecutionPolicy", "Bypass", "-NoProfile", "-File", "`"$tempScript`"" `
                                    -Verb RunAs `
                                    -Wait `
                                    -PassThru `
                                    -WindowStyle Hidden
        
        # Clean up temp script
        Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
        
        if($copyProcess.ExitCode -eq 0 -and (Test-Path $overridePath)) {
            Write-Host "`n[SUCCESS]" -ForegroundColor Green -NoNewline
            Write-Host " Override certificate deployed successfully!"
            Write-Host "This enables silent printing functionality for QZ Tray." -ForegroundColor Cyan
        } else {
            Write-Warning "Failed to copy override.crt to installation directory"
        }
    } else {
        # macOS/Linux: Use sudo to copy
        if (Get-Command "sudo" -errorAction SilentlyContinue) {
            sudo cp "$tempOverride" "$overridePath"
        } else {
            su root -c "cp '$tempOverride' '$overridePath'"
        }
        
        if(Test-Path $overridePath) {
            Write-Host "`n[SUCCESS]" -ForegroundColor Green -NoNewline
            Write-Host " Override certificate deployed successfully!"
            Write-Host "This enables silent printing functionality for QZ Tray." -ForegroundColor Cyan
        } else {
            Write-Warning "Failed to verify override.crt deployment"
        }
    }
    
    # Clean up temp file
    Remove-Item -Path $tempOverride -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Could not deploy override certificate: $_"
    Write-Host "You can manually download it from: $OVERRIDE_URL" -ForegroundColor Yellow
}

# Restart QZ Tray
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Starting QZ Tray..." -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$startSuccess = Start-QZTray -InstallPath $qzInstallPath

if($startSuccess) {
    Write-Host "`nQZ Tray is now running with the new certificate!" -ForegroundColor Green
} else {
    Write-Warning "QZ Tray may not have started automatically."
    Write-Host "Please start QZ Tray manually." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Configuration Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Invoke-Pause
exit 0
