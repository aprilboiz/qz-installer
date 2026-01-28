#!/usr/bin/env pwsh

<#
.SYNOPSIS
    QZ Tray installer for PowerShell with automatic IPv4 detection
.DESCRIPTION
    Downloads, installs QZ Tray, and generates SSL certificates with localhost + primary IPv4
    Automatically detects and restarts QZ Tray if running
.PARAMETER param1
    "stable", "beta", or specific version like "v2.2.1"
.NOTES
    Version: 4.0 (Final)
    Enhanced: Cross-platform support, proper process detection, automatic restart
.EXAMPLE
    .\install.ps1
    .\install.ps1 stable
    .\install.ps1 beta
    .\install.ps1 2.2.5
#>
param([String] $param1)

$OWNER="qzind"
$REPO="tray"
$URL="https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=100"
$SCRIPT_NAME="pwsh.sh"

$RELEASE="auto"
$TAG="auto"

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
# Uses same logic as TaskKiller.java from QZ Tray codebase
# ============================================================
function Test-QZTrayRunning {
    $os = Get-OSPlatform
    
    switch($os) {
        "Windows" {
            # Windows: Find Java processes with qz-tray in command line
            # Same logic as findPidsPwsh() in TaskKiller.java
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
            # macOS: Use pgrep like findPidsPgrep() in TaskKiller.java
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
# Uses same logic as killAll() in TaskKiller.java
# ============================================================
function Stop-QZTray {
    param([int]$MaxWaitSeconds = 10)
    
    Write-Host "Stopping QZ Tray..." -ForegroundColor Yellow
    
    $os = Get-OSPlatform
    
    switch($os) {
        "Windows" {
            # Windows: Kill Java processes running QZ Tray
            try {
                $javaProcesses = Get-CimInstance Win32_Process -Filter "Name = 'java.exe' OR Name = 'javaw.exe'" -ErrorAction SilentlyContinue
                
                $killCount = 0
                foreach($proc in $javaProcesses) {
                    if($proc.CommandLine -like "*qz-tray.jar*" -or 
                       $proc.CommandLine -like "*qz.App*" -or 
                       $proc.CommandLine -like "*qz.ws.PrintSocketServer*") {
                        
                        Write-Host "  Terminating QZ Tray process (PID: $($proc.ProcessId))..." -ForegroundColor Gray
                        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                        $killCount++
                    }
                }
                
                if($killCount -gt 0) {
                    Start-Sleep -Seconds 2
                    Write-Host "  [✓] Stopped $killCount QZ Tray process(es)" -ForegroundColor Green
                } else {
                    Write-Host "  No QZ Tray process found" -ForegroundColor Gray
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
            $killCount = 0
            
            foreach($pattern in $patterns) {
                $pids = pgrep -f "$pattern" 2>/dev/null
                if($pids) {
                    foreach($pid in $pids -split '\s+') {
                        if($pid -match '^\d+$') {
                            Write-Host "  Terminating QZ Tray process (PID: $pid)..." -ForegroundColor Gray
                            kill -TERM $pid 2>/dev/null
                            $killCount++
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
            
            # Also kill via pgrep (in case not running as service)
            $patterns = @("qz-tray.jar", "qz.App", "qz.ws.PrintSocketServer")
            $killCount = 0
            
            foreach($pattern in $patterns) {
                $pids = pgrep -f "$pattern" 2>/dev/null
                if($pids) {
                    foreach($pid in $pids -split '\s+') {
                        if($pid -match '^\d+$') {
                            Write-Host "  Terminating QZ Tray process (PID: $pid)..." -ForegroundColor Gray
                            kill -TERM $pid 2>/dev/null
                            $killCount++
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
# ARGUMENT PARSING
# ============================================================

if($param1) {
    Write-Host "Picked up argument: " -NoNewline
    Write-Host "$param1" -ForegroundColor Blue

    switch -Regex ($param1) {
        ".*help" {
            $SCRIPT="irm $SCRIPT_NAME | iex"
            if($MyInvocation.MyCommand.Definition -contains ".ps1") {
                $SCRIPT=Split-Path $MyInvocation.MyCommand.Definition -leaf
            }
            
            Write-Host "`nUsage:`n  $SCRIPT [`"" -NoNewline
            Write-Host "stable" -ForegroundColor Green -NoNewline
            Write-Host "|`"" -NoNewline
            Write-Host "beta" -ForegroundColor Yellow -NoNewline
            Write-Host "`"|<" -NoNewline
            Write-Host "version" -ForegroundColor Blue -NoNewline
            Write-Host ">|`"" -NoNewline
            Write-host "help" -ForegroundColor Magenta -NoNewline
            Write-Host "`"]"
            
            Write-Host "    stable  " -ForegroundColor Green -NoNewline
            Write-Host "   Downloads and installs the latest stable release"
            Write-Host "    beta    " -ForegroundColor Yellow -NoNewline
            Write-Host "   Downloads and installs the latest beta release"
            Write-Host "    version " -ForegroundColor Blue -NoNewline
            Write-Host "   Downloads and installs the exact version specified, e.g. `"2.2.1`""
            Write-Host "    help    " -ForegroundColor Magenta -NoNewline
            Write-Host "   Displays this help and exits"
            Write-Host "`n  The default behavior is to download and install the " -NoNewline
            Write-Host "stable" -ForegroundColor Green -NoNewline
            Write-Host " version`n"
            exit 0
        }
        "stable" {
            $RELEASE="stable"
        }
        "unstable" {
            $RELEASE="beta"
        }
        "beta" {
            $RELEASE="beta"
        }
    }

    if("$RELEASE" -eq "auto" ) {
        $TAG="$param1"
        if($TAG.Substring(0, 1) -ne "v") {
           $TAG="v${TAG}"
        }
    }
}

# ============================================================
# ARCHITECTURE & OS DETECTION
# ============================================================

if($Env:OS -and "$Env:OS".Substring(0, 3) -like "Win*") {
    if("${Env:ProgramFiles(Arm)}" -ne "") {
        $ARCH="arm64"
    } else {
        switch("$Env:PROCESSOR_ARCHITECTURE") {
            "ARM64" { $ARCH="arm64"; break }
            "x86" { Write-Host "WARNING: 32-bit platforms are unsupported" }
            default { $ARCH="amd64" }
        }
    }
} else {
    $ARCH=(uname -m)
    switch -Regex ($ARCH) {
        ".*arm64.*|.*aarch64.*" { $ARCH="arm64"; break }
        ".*riscv.*" { $ARCH="riscv"; break }
        default { $ARCH="amd64" }
    }
}

$EXTENSION=".exe"
if($Env:OS -and "$Env:OS".Substring(0, 3) -like "Win*") {
    # Windows
} else {
    $os = Get-OSPlatform
    if($os -eq "macOS") {
        $EXTENSION=".pkg"
    } else {
        $EXTENSION=".run"
    }
}

if("$RELEASE" -eq "auto" ) {
    $RELEASE="stable"
}

# ============================================================
# GITHUB API & DOWNLOAD
# ============================================================

Write-Host "Parsing " -NoNewline
Write-Host "$URL" -ForegroundColor Blue -NoNewline
Write-Host "... "
$jsonData = Invoke-RestMethod -Uri "$URL"

if("$TAG" -eq "auto") {
    $STABLE_TAGS=@()
    $BETA_TAGS=@()

    foreach($item in $jsonData) {
        $BETA_TAGS += $item.tag_name
        if(-Not $item.prerelease) {
            $STABLE_TAGS += $item.tag_name
        }
    }

    $LATEST_STABLE = $STABLE_TAGS | Sort-Object -Descending | Select-Object -First 1
    $LATEST_BETA = $BETA_TAGS | Sort-Object -Descending | Select-Object -First 1

    switch($RELEASE) {
        "stable" { $TAG="$LATEST_STABLE"; break }
        "beta" { $TAG="$LATEST_BETA"; break }
    }

    if("$TAG" -eq "") {
        Write-Host "Unable to locate a tag for this release" -ForegroundColor Red
        exit 2
    }

    Write-Host "Latest " -NoNewline
    Write-Host "$RELEASE" -ForegroundColor Green -NoNewline
    Write-Host " version found: " -NoNewline
    Write-Host "$TAG" -ForegroundColor Blue
}

Write-Host "Searching " -NoNewline
Write-Host "${EXTENSION}" -ForegroundColor Blue -NoNewline
Write-Host " downloads for " -NoNewline
Write-Host "${TAG}" -ForegroundColor Blue -NoNewline
Write-Host " matching " -NoNewline
Write-Host "${ARCH}" -ForegroundColor Blue -NoNewline
Write-Host "..."

$OS_URLS=@()
foreach($item in $jsonData) {
    if($item.tag_name -eq $TAG) {
        foreach($asset in $item.assets) {
            if($asset.browser_download_url.EndsWith($EXTENSION)) {
                $OS_URLS += $asset.browser_download_url
            }
        }
    }
}

$AMD64_URLS=@()
$ARM64_URLS=@()
$RISCV_URLS=@()
foreach($url in $OS_URLS) {
    switch -Regex ($url) {
        ".*arm64.*" { $ARM64_URLS += $url; break }
        ".*riscv.*" { $RISCV_URLS += $url; break }
        default { $AMD64_URLS += $url }
    }
}

$DOWNLOAD_URL=""
switch -Regex ($arch) {
    ".*arm64.*" { $DOWNLOAD_URL = $ARM64_URLS | Select-Object -First 1; break }
    ".*riscv.*" { $DOWNLOAD_URL = $RISCV_URLS | Select-Object -First 1; break }
    default { $DOWNLOAD_URL = $AMD64_URLS | Select-Object -First 1 }
}

if ("$DOWNLOAD_URL" -eq "") {
    Write-Host "Unable to locate a download for this platform" -ForegroundColor Red
    exit 2
}

Write-Host "Downloading " -NoNewline
Write-Host "${DOWNLOAD_URL}" -ForegroundColor Blue -NoNewline
Write-Host "..."

if($env:TEMP) {
    $TEMP_FILE = "$env:TEMP\${REPO}-${TAG}${EXTENSION}"
} else {
    $TEMP_FILE="/tmp/${REPO}-${TAG}${EXTENSION}"
}

if (Test-Path -Path "$TEMP_FILE") {
    Remove-Item -fo "$TEMP_FILE"
}

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest "$DOWNLOAD_URL" -OutFile "$TEMP_FILE"

# ============================================================
# CHECK IF QZ TRAY IS RUNNING BEFORE INSTALL
# ============================================================

$wasRunning = Test-QZTrayRunning

if($wasRunning) {
    Write-Host "`nQZ Tray is currently running" -ForegroundColor Yellow
    Write-Host "Stopping QZ Tray before installation..." -ForegroundColor Yellow
    Stop-QZTray
    Start-Sleep -Seconds 2
}

# ============================================================
# INSTALL
# ============================================================

Write-Host "Download successful, beginning the install..."

switch($EXTENSION) {
    ".pkg" {
        sudo installer -pkg "$TEMP_FILE" -target /
        break
    }
    ".run" {
        if (Get-Command "sudo" -errorAction SilentlyContinue) {
            sudo bash "$TEMP_FILE" --nox11 -- -y
        } else {
            su root -c "bash '$TEMP_FILE' --nox11 -- -y"
        }
        break
    }
    default {
        # Windows .exe
        Start-Process "$TEMP_FILE" -ArgumentList "/S" -Verb RunAs -Wait
    }
}

Remove-Item -fo "$TEMP_FILE"

# ============================================================
# CERTIFICATE GENERATION WITH PRIMARY IPv4
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Generating SSL Certificate..." -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$primaryIPv4 = Get-PrimaryIPv4

# Determine QZ Tray installation path
$qzInstallPath = $null
$qzConsoleExe = $null

$os = Get-OSPlatform

switch($os) {
    "Windows" {
        $possiblePaths = @(
            "${Env:ProgramFiles}\QZ Tray",
            "${Env:ProgramFiles(x86)}\QZ Tray",
            "C:\Program Files\QZ Tray",
            "C:\Program Files (x86)\QZ Tray"
        )
        
        foreach($path in $possiblePaths) {
            $consolePath = Join-Path $path "qz-tray-console.exe"
            if(Test-Path $consolePath) {
                $qzInstallPath = $path
                $qzConsoleExe = $consolePath
                break
            }
        }
    }
    
    "macOS" {
        if(Test-Path "/Applications/QZ Tray.app/Contents/MacOS/QZ Tray") {
            $qzInstallPath = "/Applications/QZ Tray.app/Contents/MacOS"
            $qzConsoleExe = "$qzInstallPath/QZ Tray"
        }
    }
    
    "Linux" {
        if(Test-Path "/opt/qz-tray/qz-tray") {
            $qzInstallPath = "/opt/qz-tray"
            $qzConsoleExe = "$qzInstallPath/qz-tray"
        }
    }
}

if($qzConsoleExe -and (Test-Path $qzConsoleExe)) {
    Write-Host "QZ Tray found at: " -NoNewline
    Write-Host "$qzInstallPath" -ForegroundColor Green
    
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
        Write-Host "You can manually generate certificates later using:" -ForegroundColor Yellow
        if($os -eq "Windows") {
            Write-Host "  `"$qzConsoleExe`" certgen --host `"localhost;YOUR_IP`"" -ForegroundColor Gray
        } else {
            Write-Host "  sudo `"$qzConsoleExe`" certgen --host `"localhost;YOUR_IP`"" -ForegroundColor Gray
        }
    }
    
} else {
    Write-Warning "QZ Tray console executable not found."
    Write-Host "`nSearched locations:" -ForegroundColor Yellow
    
    switch($os) {
        "Windows" {
            Write-Host "  - ${Env:ProgramFiles}\QZ Tray\qz-tray-console.exe" -ForegroundColor Gray
            Write-Host "  - ${Env:ProgramFiles(x86)}\QZ Tray\qz-tray-console.exe" -ForegroundColor Gray
        }
        "macOS" {
            Write-Host "  - /Applications/QZ Tray.app/Contents/MacOS/QZ Tray" -ForegroundColor Gray
        }
        "Linux" {
            Write-Host "  - /opt/qz-tray/qz-tray" -ForegroundColor Gray
        }
    }
    
    Write-Host "`nYou can manually generate certificates later." -ForegroundColor Yellow
}

# ============================================================
# RESTART QZ TRAY
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Starting QZ Tray..." -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if($qzInstallPath) {
    $startSuccess = Start-QZTray -InstallPath $qzInstallPath
    
    if($startSuccess) {
        Write-Host "`nQZ Tray is now running with the new certificate!" -ForegroundColor Green
    } else {
        Write-Warning "QZ Tray may not have started automatically."
        Write-Host "Please start QZ Tray manually from:" -ForegroundColor Yellow
        
        switch($os) {
            "Windows" {
                Write-Host "  Start Menu -> QZ Tray" -ForegroundColor Gray
            }
            "macOS" {
                Write-Host "  Applications -> QZ Tray" -ForegroundColor Gray
            }
            "Linux" {
                Write-Host "  $qzInstallPath/qz-tray" -ForegroundColor Gray
                Write-Host "  Or: systemctl --user start qz-tray" -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Warning "QZ Tray installation path not detected."
    Write-Host "Please start QZ Tray manually from the Start Menu or Applications folder." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Installation Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0