# QZ Tray Installer

Automated installer scripts for [QZ Tray](https://qz.io/) with SSL certificate generation.

## Features

- ✅ Cross-platform support (Windows, macOS, Linux)
- ✅ Automatic version detection (stable/beta)
- ✅ Automatic SSL certificate generation with localhost + primary IPv4
- ✅ Smart QZ Tray process detection and restart
- ✅ Architecture detection (amd64, arm64, riscv)

## Quick Installation

### PowerShell (Windows/Linux/macOS)

```powershell
irm https://aprilboiz.github.io/qz-installer | iex
```

Or download and run:
```powershell
irm https://aprilboiz.github.io/qz-installer/install.ps1 -OutFile install.ps1
.\install.ps1
```

### Bash (Linux/macOS)

```bash
curl -fsSL https://aprilboiz.github.io/qz-installer/install.sh | bash
```

Or download and run:
```bash
curl -fsSL https://aprilboiz.github.io/qz-installer/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

## Usage Options

Install specific version:
```powershell
# PowerShell
irm https://aprilboiz.github.io/qz-installer | iex -args "2.2.5"

# Bash
curl -fsSL https://aprilboiz.github.io/qz-installer/install.sh | bash -s -- "2.2.5"
```

Install beta version:
```powershell
# PowerShell
irm https://aprilboiz.github.io/qz-installer | iex -args "beta"

# Bash
curl -fsSL https://aprilboiz.github.io/qz-installer/install.sh | bash -s -- "beta"
```

Show help:
```powershell
# PowerShell
irm https://aprilboiz.github.io/qz-installer | iex -args "help"

# Bash
curl -fsSL https://aprilboiz.github.io/qz-installer/install.sh | bash -s -- "help"
```

## What It Does

1. **Downloads** the latest QZ Tray installer for your platform
2. **Detects** if QZ Tray is running and stops it gracefully
3. **Installs** QZ Tray silently
4. **Generates** SSL certificates for localhost + your primary IPv4 address
5. **Restarts** QZ Tray automatically

## SSL Certificate

After installation, QZ Tray will be accessible via HTTPS at:
- `https://localhost:8181`
- `https://<your-ip>:8181`

The certificate is generated with both localhost and your primary network IP for remote access.

## Requirements

### Windows
- PowerShell 5.1 or later (built-in on Windows 10+)
- Administrator privileges (for installation)

### Linux
- Bash shell
- `curl` or `wget`
- `sudo` access

### macOS
- Bash shell
- `curl` (built-in)
- `sudo` access

## License

These installer scripts are provided as-is. QZ Tray itself is licensed under the [LGPL/MIT License](https://github.com/qzind/tray).

## Credits

QZ Tray is developed by [QZ Industries, LLC](https://qz.io/).
