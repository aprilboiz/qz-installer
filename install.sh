#!/usr/bin/env bash

set -e

# ============================================================
# QZ Tray Installer for Bash with automatic IPv4 detection
# ============================================================
#
# SYNOPSIS
#     Downloads, installs QZ Tray, and generates SSL certificates 
#     with localhost + primary IPv4
#     Automatically detects and restarts QZ Tray if running
#
# USAGE
#     ./install.sh [stable|beta|<version>|help]
#
# VERSION
#     5.0 (Enhanced Detection & Interactive)
#
# NOTES
#     Enhanced: Java process detection (Liberica Platform binary support),
#     interactive mode, cross-platform support
# ============================================================

# Console colors
RED="\x1B[1;31m"
GREEN="\x1B[1;32m"
BLUE="\x1B[1;34m"
PURPLE="\x1B[1;35m"
YELLOW="\x1B[1;33m"
CYAN="\x1B[1;36m"
GRAY="\x1B[0;37m"
PLAIN="\x1B[0m"

OWNER="qzind"
REPO="tray"
URL="https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=100"
FETCH=""

RELEASE="auto"
TAG="auto"

# Track if QZ Tray was running before install
WAS_RUNNING=false

# ============================================================
# HELPER: Print colored messages
# ============================================================
print_success() {
    echo -e "${GREEN}[✓]${PLAIN} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${PLAIN} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${PLAIN} $1"
}

# ============================================================
# HELPER: Detect OS Platform
# ============================================================
get_os_platform() {
    case "$OSTYPE" in
        darwin*)
            echo "macOS"
            ;;
        linux*)
            echo "Linux"
            ;;
        msys*|cygwin*|mingw*)
            echo "Windows"
            ;;
        *)
            # Fallback using uname
            local uname_result
            uname_result="$(uname -s 2>/dev/null || echo "Unknown")"
            case "$uname_result" in
                Darwin)
                    echo "macOS"
                    ;;
                Linux)
                    echo "Linux"
                    ;;
                MINGW*|MSYS*|CYGWIN*)
                    echo "Windows"
                    ;;
                *)
                    echo "Unknown"
                    ;;
            esac
            ;;
    esac
}

# ============================================================
# FUNCTION: Get Primary IPv4 Address
# Uses socket connection to detect primary network interface
# ============================================================
get_primary_ipv4() {
    local test_host="${1:-google.com}"
    local test_port="${2:-443}"
    local primary_ip=""
    
    echo -e "${CYAN}Detecting primary network interface...${PLAIN}"
    
    local os_platform
    os_platform="$(get_os_platform)"
    
    case "$os_platform" in
        "macOS")
            # macOS: Use route to find default interface, then get its IP
            local default_if
            default_if="$(route -n get default 2>/dev/null | grep 'interface:' | awk '{print $2}')"
            if [ -n "$default_if" ]; then
                primary_ip="$(ipconfig getifaddr "$default_if" 2>/dev/null)"
            fi
            
            # Fallback: Use Python socket approach
            if [ -z "$primary_ip" ]; then
                if which python3 >/dev/null 2>&1; then
                    primary_ip="$(python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
                elif which python >/dev/null 2>&1; then
                    primary_ip="$(python -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
                fi
            fi
            ;;
            
        "Linux")
            # Linux: Use ip route or Python socket approach
            if which ip >/dev/null 2>&1; then
                primary_ip="$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+')"
            fi
            
            # Fallback: Use Python socket approach
            if [ -z "$primary_ip" ]; then
                if which python3 >/dev/null 2>&1; then
                    primary_ip="$(python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
                elif which python >/dev/null 2>&1; then
                    primary_ip="$(python -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
                fi
            fi
            
            # Fallback: hostname -I
            if [ -z "$primary_ip" ]; then
                primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            fi
            ;;
            
        *)
            # Generic fallback using Python
            if which python3 >/dev/null 2>&1; then
                primary_ip="$(python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
            elif which python >/dev/null 2>&1; then
                primary_ip="$(python -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('$test_host', $test_port)); print(s.getsockname()[0]); s.close()" 2>/dev/null)"
            fi
            ;;
    esac
    
    if [ -n "$primary_ip" ]; then
        echo -e "Primary IPv4 detected: ${GREEN}$primary_ip${PLAIN}"
        echo "$primary_ip"
        return 0
    else
        print_warning "Unable to detect primary IPv4"
        return 1
    fi
}

# ============================================================
# FUNCTION: Check if QZ Tray is running
# Enhanced to detect Java processes including Liberica Platform binary
# Uses pgrep -f to search for command-line patterns:
#   - qz-tray.jar (JAR file)
#   - qz.App (main application class)
#   - qz.ws.PrintSocketServer (print server class)
# ============================================================
test_qz_tray_running() {
    local os_platform
    os_platform="$(get_os_platform)"
    
    # Pattern names to search for (catches Java processes including Liberica)
    local patterns=("qz-tray.jar" "qz.App" "qz.ws.PrintSocketServer")
    
    case "$os_platform" in
        "macOS"|"Linux")
            # Use pgrep -f to find processes with QZ Tray patterns in command line
            for pattern in "${patterns[@]}"; do
                if pgrep -f "$pattern" >/dev/null 2>&1; then
                    return 0
                fi
            done
            
            # Linux: Also check systemd service
            if [ "$os_platform" = "Linux" ]; then
                if systemctl --user is-active qz-tray >/dev/null 2>&1; then
                    return 0
                fi
            fi
            
            return 1
            ;;
            
        *)
            # For other platforms, try pgrep as fallback
            for pattern in "${patterns[@]}"; do
                if pgrep -f "$pattern" >/dev/null 2>&1; then
                    return 0
                fi
            done
            return 1
            ;;
    esac
}

# ============================================================
# FUNCTION: Stop QZ Tray
# Enhanced to kill all Java processes running QZ Tray (including Liberica Platform binary)
# Searches for processes with patterns: qz-tray.jar, qz.App, qz.ws.PrintSocketServer
# ============================================================
stop_qz_tray() {
    local max_wait="${1:-10}"
    
    echo -e "${YELLOW}Stopping QZ Tray...${PLAIN}"
    
    local os_platform
    os_platform="$(get_os_platform)"
    
    # Pattern names to search for (catches all Java processes running QZ Tray)
    local patterns=("qz-tray.jar" "qz.App" "qz.ws.PrintSocketServer")
    local kill_count=0
    
    case "$os_platform" in
        "macOS")
            # macOS: Try graceful quit via AppleScript, then kill
            # Also unload launch agent (from TaskKiller.java)
            /bin/launchctl unload ~/Library/LaunchAgents/qz-tray.plist 2>/dev/null || true
            
            osascript -e 'quit app "QZ Tray"' 2>/dev/null || true
            sleep 2
            
            # Force kill if needed - stops all Java processes running QZ Tray
            for pattern in "${patterns[@]}"; do
                local pids
                pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
                if [ -n "$pids" ]; then
                    for pid in $pids; do
                        if [ -n "$pid" ] && [ "$pid" -eq "$pid" ] 2>/dev/null; then
                            echo -e "  ${GRAY}Terminating QZ Tray process (PID: $pid)...${PLAIN}"
                            kill -TERM "$pid" 2>/dev/null || true
                            ((kill_count++)) || true
                        fi
                    done
                fi
            done
            
            # Wait for graceful shutdown
            local waited=0
            while test_qz_tray_running && [ "$waited" -lt "$max_wait" ]; do
                sleep 1
                ((waited++)) || true
            done
            
            # Force kill if still running
            if test_qz_tray_running; then
                echo -e "  ${GRAY}Forcing shutdown...${PLAIN}"
                for pattern in "${patterns[@]}"; do
                    pkill -KILL -f "$pattern" 2>/dev/null || true
                done
            fi
            ;;
            
        "Linux")
            # Linux: Stop systemd service first, then kill processes
            systemctl --user stop qz-tray 2>/dev/null || true
            
            # Also kill via pgrep - stops all Java processes running QZ Tray (including Liberica)
            for pattern in "${patterns[@]}"; do
                local pids
                pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
                if [ -n "$pids" ]; then
                    for pid in $pids; do
                        if [ -n "$pid" ] && [ "$pid" -eq "$pid" ] 2>/dev/null; then
                            echo -e "  ${GRAY}Terminating QZ Tray process (PID: $pid)...${PLAIN}"
                            kill -TERM "$pid" 2>/dev/null || true
                            ((kill_count++)) || true
                        fi
                    done
                fi
            done
            
            # Wait for graceful shutdown
            local waited=0
            while test_qz_tray_running && [ "$waited" -lt "$max_wait" ]; do
                sleep 1
                ((waited++)) || true
            done
            
            # Force kill if still running
            if test_qz_tray_running; then
                echo -e "  ${GRAY}Forcing shutdown...${PLAIN}"
                for pattern in "${patterns[@]}"; do
                    pkill -KILL -f "$pattern" 2>/dev/null || true
                done
            fi
            ;;
            
        *)
            # Generic fallback
            for pattern in "${patterns[@]}"; do
                pkill -f "$pattern" 2>/dev/null || true
            done
            ;;
    esac
    
    print_success "QZ Tray stopped"
    return 0
}

# ============================================================
# FUNCTION: Start QZ Tray
# ============================================================
start_qz_tray() {
    local install_path="$1"
    
    echo -e "${YELLOW}Starting QZ Tray...${PLAIN}"
    
    local os_platform
    os_platform="$(get_os_platform)"
    
    case "$os_platform" in
        "macOS")
            open -a "QZ Tray" 2>/dev/null || true
            sleep 3
            
            if test_qz_tray_running; then
                print_success "QZ Tray started successfully"
                return 0
            else
                print_warning "QZ Tray not detected after start"
                return 1
            fi
            ;;
            
        "Linux")
            # Try systemd service first
            if systemctl --user list-unit-files qz-tray.service >/dev/null 2>&1; then
                systemctl --user start qz-tray 2>/dev/null || true
                sleep 3
                
                if test_qz_tray_running; then
                    print_success "QZ Tray started via systemd"
                    return 0
                fi
            fi
            
            # Fallback: Launch executable directly
            local qz_exe="${install_path:-/opt/qz-tray}/qz-tray"
            if [ -x "$qz_exe" ]; then
                nohup "$qz_exe" >/dev/null 2>&1 &
                sleep 3
                
                if test_qz_tray_running; then
                    print_success "QZ Tray started successfully"
                    return 0
                else
                    print_warning "QZ Tray not detected after start"
                    return 1
                fi
            else
                print_warning "QZ Tray executable not found: $qz_exe"
                return 1
            fi
            ;;
            
        *)
            print_warning "Unsupported OS: $os_platform"
            return 1
            ;;
    esac
}

# ============================================================
# FUNCTION: Pause before exit (Interactive Mode)
# ============================================================
invoke_pause() {
    echo -e "\n${CYAN}========================================${PLAIN}"
    echo -e "${YELLOW}Press any key to exit...${PLAIN}"
    read -n 1 -s -r
}

# ============================================================
# FUNCTION: Generate SSL Certificate
# ============================================================
generate_certificate() {
    local primary_ipv4="$1"
    
    echo -e "\n${CYAN}========================================${PLAIN}"
    echo -e "${CYAN}Generating SSL Certificate...${PLAIN}"
    echo -e "${CYAN}========================================${PLAIN}\n"
    
    local os_platform
    os_platform="$(get_os_platform)"
    
    local qz_install_path=""
    local qz_console_exe=""
    
    case "$os_platform" in
        "macOS")
            if [ -x "/Applications/QZ Tray.app/Contents/MacOS/QZ Tray" ]; then
                qz_install_path="/Applications/QZ Tray.app/Contents/MacOS"
                qz_console_exe="$qz_install_path/QZ Tray"
            fi
            ;;
            
        "Linux")
            if [ -x "/opt/qz-tray/qz-tray" ]; then
                qz_install_path="/opt/qz-tray"
                qz_console_exe="$qz_install_path/qz-tray"
            fi
            ;;
    esac
    
    if [ -n "$qz_console_exe" ] && [ -x "$qz_console_exe" ]; then
        echo -e "QZ Tray found at: ${GREEN}$qz_install_path${PLAIN}"
        
        # Build hostname list
        local host_list="localhost"
        if [ -n "$primary_ipv4" ]; then
            host_list="localhost;$primary_ipv4"
            echo -e "Generating certificate for: ${YELLOW}localhost, $primary_ipv4${PLAIN}"
        else
            echo -e "Generating certificate for: ${YELLOW}localhost only${PLAIN}"
            print_warning "Could not detect primary IPv4"
        fi
        
        echo -e "\n${CYAN}Executing certificate generation...${PLAIN}"
        echo -e "Command: ${GRAY}\"$qz_console_exe\" certgen --host \"$host_list\"${PLAIN}\n"
        
        # Run certgen with sudo
        if which sudo >/dev/null 2>&1; then
            sudo "$qz_console_exe" certgen --host "$host_list"
        else
            su root -c "\"$qz_console_exe\" certgen --host \"$host_list\""
        fi
        
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            print_success "SSL Certificate generated successfully!"
        else
            print_warning "Certificate generation returned exit code: $exit_code"
        fi
        
        if [ -n "$primary_ipv4" ]; then
            echo -e "\n${CYAN}You can now access QZ Tray via HTTPS at:${PLAIN}"
            echo -e "  - https://localhost:8181"
            echo -e "  - https://${primary_ipv4}:8181"
        else
            echo -e "\n${CYAN}You can now access QZ Tray via HTTPS at:${PLAIN}"
            echo -e "  - https://localhost:8181"
        fi
        
        # Return the install path for later use
        echo "$qz_install_path"
        return 0
    else
        print_warning "QZ Tray console executable not found."
        echo -e "\n${YELLOW}Searched locations:${PLAIN}"
        
        case "$os_platform" in
            "macOS")
                echo -e "  ${GRAY}- /Applications/QZ Tray.app/Contents/MacOS/QZ Tray${PLAIN}"
                ;;
            "Linux")
                echo -e "  ${GRAY}- /opt/qz-tray/qz-tray${PLAIN}"
                ;;
        esac
        
        echo -e "\n${YELLOW}You can manually generate certificates later.${PLAIN}"
        return 1
    fi
}

# ============================================================
# MAIN: Determine if curl or wget are available
# ============================================================
if which curl >/dev/null 2>&1; then
    FETCH="curl -Lks"
elif which wget >/dev/null 2>&1; then
    FETCH="wget -q -O -"
else
    print_error "Either \"curl\" or \"wget\" are required to use this script"
    invoke_pause
    exit 2
fi

# ============================================================
# ARGUMENT PARSING
# ============================================================
if [ -n "$1" ]; then
    echo -e "Picked up argument: ${BLUE}$1${PLAIN}"
    
    case "$1" in
        *"help")
            SCRIPT="$FETCH qz.sh | bash -s --"
            if [ -t 0 ]; then
                SCRIPT="install.sh"
            fi
            
            echo -e "\nUsage:\n  $SCRIPT [\"${GREEN}stable${PLAIN}\"|\"${YELLOW}beta${PLAIN}\"|<${BLUE}version${PLAIN}>|\"${PURPLE}help${PLAIN}\"]"
            echo -e "    ${GREEN}stable${PLAIN}     Downloads and installs the latest stable release"
            echo -e "    ${YELLOW}beta${PLAIN}       Downloads and installs the latest beta release"
            echo -e "    ${BLUE}version${PLAIN}    Downloads and installs the exact version specified, e.g. \"2.2.1\""
            echo -e "    ${PURPLE}help${PLAIN}       Displays this help and exits"
            echo -e "\n  The default behavior is to download and install the ${GREEN}stable${PLAIN} version\n"
            invoke_pause
            exit 0
            ;;
        "stable")
            RELEASE="stable"
            ;;
        "beta"|"unstable")
            RELEASE="beta"
            ;;
        *)
            # If a parameter was provided but we don't recognize it, treat it as a tag
            TAG="$1"
            # Append "v" to version if missing (e.g. 2.2.1 vs v2.2.1)
            first_char="$(echo "$TAG" | cut -c1)"
            if [ "$first_char" != "v" ]; then
                TAG="v${TAG}"
            fi
            ;;
    esac
fi

# ============================================================
# ARCHITECTURE DETECTION
# ============================================================
ARCH="$(uname -m)"
case "$ARCH" in
    *"arm64"*|*"aarch64"*)
        ARCH="arm64"
        ;;
    *"riscv"*)
        ARCH="riscv"
        ;;
    *)
        ARCH="amd64"
        ;;
esac

# ============================================================
# FILE EXTENSION DETECTION
# ============================================================
EXTENSION=".run"
case "$OSTYPE" in
    "darwin"*)
        EXTENSION=".pkg"
        ;;
esac

if [ "$RELEASE" = "auto" ]; then
    RELEASE="stable"
fi

# ============================================================
# GITHUB API & DOWNLOAD
# ============================================================
echo -e "Parsing ${BLUE}${URL}${PLAIN}..."
JSON="$($FETCH "$URL")"

# Gather stable and beta tagged releases by loop over JSON returned from GitHub API
if [ "$TAG" = "auto" ]; then
    STABLE_TAGS=""
    BETA_TAGS=""
    tag_name=""
    
    while IFS= read -r line; do
        case "$line" in
            *"\"tag_name\":"*)
                # assume "tag_name": comes before "prerelease":
                tag_name="$(echo "$line" | cut -d '"' -f4 | tr -d '"' | tr -d ',' | tr -d ' ')"
                ;;
            *"\"prerelease\": false,"*)
                STABLE_TAGS+="$tag_name"$'\n'
                BETA_TAGS+="$tag_name"$'\n'
                ;;
            *"\"prerelease\": true,"*)
                BETA_TAGS+="$tag_name"$'\n'
                ;;
            *"\"assets\":"*)
                # we've gone too far
                tag_name=""
                ;;
        esac
    done <<< "$JSON"
    
    # Sort the results
    LATEST_STABLE="$(echo "${STABLE_TAGS}" | sort -Vr | head -1)"
    LATEST_BETA="$(echo "${BETA_TAGS}" | sort -Vr | head -1)"
    
    case "$RELEASE" in
        "stable")
            TAG="$LATEST_STABLE"
            ;;
        "beta")
            TAG="$LATEST_BETA"
            ;;
    esac
    
    if [ -z "$TAG" ]; then
        print_error "Unable to locate a tag for this release"
        invoke_pause
        exit 2
    fi
    
    echo -e "Latest ${GREEN}${RELEASE}${PLAIN} version found: ${BLUE}$TAG${PLAIN}"
fi

# Get URL for latest release
echo -e "Searching ${BLUE}${EXTENSION}${PLAIN} downloads for ${BLUE}${TAG}${PLAIN} matching ${BLUE}${ARCH}${PLAIN}..."

OS_URLS=""
while IFS= read -r line; do
    url=""
    case "$line" in
        *"download/$TAG/"*)
            url=$(echo "$line" | cut -d '"' -f4 | tr -d '"' | tr -d ',' | tr -d ' ')
            ;;
    esac
    case "$url" in
        *"$EXTENSION")
            OS_URLS+="$url"$'\n'
            ;;
    esac
done <<< "$JSON"

# Gather all URLs that match current architecture
AMD64_URLS=""
ARM64_URLS=""
RISCV_URLS=""

while IFS= read -r line; do
    case "$line" in
        *"arm64"*)
            ARM64_URLS+="$line"$'\n'
            ;;
        *"riscv"*)
            RISCV_URLS+="$line"$'\n'
            ;;
        *)
            AMD64_URLS+="$line"$'\n'
            ;;
    esac
done <<< "$OS_URLS"

# Echo the proper download URL
DOWNLOAD_URL=""
case "$ARCH" in
    *"arm64"*)
        DOWNLOAD_URL=$(echo "$ARM64_URLS" | head -1)
        ;;
    *"riscv"*)
        DOWNLOAD_URL=$(echo "$RISCV_URLS" | head -1)
        ;;
    *)
        DOWNLOAD_URL=$(echo "$AMD64_URLS" | head -1)
        ;;
esac

if [ -z "$DOWNLOAD_URL" ]; then
    print_error "Unable to locate a download for this platform"
    invoke_pause
    exit 2
fi

echo -e "Downloading ${BLUE}${DOWNLOAD_URL}${PLAIN}..."

TEMP_FILE="/tmp/${REPO}-${TAG}${EXTENSION}"

# Remove old copy if needed
if [ -f "$TEMP_FILE" ]; then
    rm -f "$TEMP_FILE" >/dev/null
fi

# Download installer using curl or wget
if which curl >/dev/null 2>&1; then
    curl -Lks "$DOWNLOAD_URL" --output "$TEMP_FILE"
elif which wget >/dev/null 2>&1; then
    wget -q -O "$TEMP_FILE" "$DOWNLOAD_URL"
else
    print_error "Either \"curl\" or \"wget\" are required to use this script"
    invoke_pause
    exit 2
fi

# ============================================================
# CHECK IF QZ TRAY IS RUNNING BEFORE INSTALL
# ============================================================
if test_qz_tray_running; then
    WAS_RUNNING=true
    echo -e "\n${YELLOW}QZ Tray is currently running${PLAIN}"
    echo -e "${YELLOW}Stopping QZ Tray before installation...${PLAIN}"
    stop_qz_tray
    sleep 2
fi

# ============================================================
# INSTALL
# ============================================================
echo -e "Download successful, beginning the install..."

case "$OSTYPE" in
    "darwin"*)
        # Assume .pkg (installer) for MacOS
        sudo installer -pkg "$TEMP_FILE" -target /
        ;;
    *)
        # Assume .run (makeself) for others
        if which sudo >/dev/null 2>&1; then
            sudo bash "$TEMP_FILE" --nox11 -- -y
        else
            su root -c "bash '$TEMP_FILE' --nox11 -- -y"
        fi
        ;;
esac

# Clean up
rm -f "$TEMP_FILE" >/dev/null

# ============================================================
# CERTIFICATE GENERATION WITH PRIMARY IPv4
# ============================================================
# Capture IPv4 (output goes to stderr, IP to stdout via function design)
PRIMARY_IPV4=""
ipv4_output="$(get_primary_ipv4 2>&1)"
# Extract just the IP address (last line that looks like an IP)
PRIMARY_IPV4="$(echo "$ipv4_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"

QZ_INSTALL_PATH=""
cert_output="$(generate_certificate "$PRIMARY_IPV4" 2>&1)"
echo "$cert_output" | head -n -1  # Print all but last line (which is the path)

# Extract install path from last line
case "$(get_os_platform)" in
    "macOS")
        QZ_INSTALL_PATH="/Applications/QZ Tray.app/Contents/MacOS"
        ;;
    "Linux")
        QZ_INSTALL_PATH="/opt/qz-tray"
        ;;
esac

# ============================================================
# DEPLOY OVERRIDE CERTIFICATE FOR SILENT PRINTING
# ============================================================
echo -e "\n${CYAN}========================================${PLAIN}"
echo -e "${CYAN}Deploying Override Certificate...${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}\n"

OVERRIDE_URL="https://aprilboiz.github.io/qz-installer/override.crt"

if [ -n "$QZ_INSTALL_PATH" ]; then
    OVERRIDE_PATH="${QZ_INSTALL_PATH}/override.crt"
    
    echo -e "${YELLOW}Downloading override.crt...${PLAIN}"
    echo -e "  Source: ${BLUE}${OVERRIDE_URL}${PLAIN}"
    echo -e "  Target: ${BLUE}${OVERRIDE_PATH}${PLAIN}"
    
    # Download override certificate
    if which curl >/dev/null 2>&1; then
        if sudo curl -Lks "$OVERRIDE_URL" -o "$OVERRIDE_PATH" 2>/dev/null; then
            print_success "Override certificate deployed successfully!"
            echo -e "${CYAN}This enables silent printing functionality for QZ Tray.${PLAIN}"
        else
            print_warning "Could not deploy override certificate"
            echo -e "${YELLOW}You can manually download it from: ${OVERRIDE_URL}${PLAIN}"
        fi
    elif which wget >/dev/null 2>&1; then
        if sudo wget -q -O "$OVERRIDE_PATH" "$OVERRIDE_URL" 2>/dev/null; then
            print_success "Override certificate deployed successfully!"
            echo -e "${CYAN}This enables silent printing functionality for QZ Tray.${PLAIN}"
        else
            print_warning "Could not deploy override certificate"
            echo -e "${YELLOW}You can manually download it from: ${OVERRIDE_URL}${PLAIN}"
        fi
    else
        print_warning "curl or wget required to download override.crt"
        echo -e "${YELLOW}You can manually download it from: ${OVERRIDE_URL}${PLAIN}"
    fi
else
    print_warning "QZ Tray installation path not detected, skipping override.crt deployment"
    echo -e "${YELLOW}You can manually download override.crt from: ${OVERRIDE_URL}${PLAIN}"
fi

# ============================================================
# RESTART QZ TRAY
# ============================================================
echo -e "\n${CYAN}========================================${PLAIN}"
echo -e "${CYAN}Starting QZ Tray...${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}\n"

if [ -n "$QZ_INSTALL_PATH" ]; then
    if start_qz_tray "$QZ_INSTALL_PATH"; then
        echo -e "\n${GREEN}QZ Tray is now running with the new certificate!${PLAIN}"
    else
        print_warning "QZ Tray may not have started automatically."
        echo -e "${YELLOW}Please start QZ Tray manually from:${PLAIN}"
        
        case "$(get_os_platform)" in
            "macOS")
                echo -e "  ${GRAY}Applications -> QZ Tray${PLAIN}"
                ;;
            "Linux")
                echo -e "  ${GRAY}$QZ_INSTALL_PATH/qz-tray${PLAIN}"
                echo -e "  ${GRAY}Or: systemctl --user start qz-tray${PLAIN}"
                ;;
        esac
    fi
else
    print_warning "QZ Tray installation path not detected."
    echo -e "${YELLOW}Please start QZ Tray manually from the Applications folder.${PLAIN}"
fi

echo -e "\n${CYAN}========================================${PLAIN}"
echo -e "${GREEN}Installation Complete!${PLAIN}"
echo -e "${CYAN}========================================${PLAIN}\n"

invoke_pause
exit 0