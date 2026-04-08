#!/usr/bin/env bash
# setup-vnc-server.sh — Install and configure a VNC server compatible with cmux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/scripts/setup-vnc-server.sh | bash
#
# Or download and run manually:
#   chmod +x setup-vnc-server.sh
#   ./setup-vnc-server.sh
#
# What this does:
#   1. Detects your OS and architecture
#   2. Installs TigerVNC server (standard VNC auth — compatible with RoyalVNCKit)
#   3. Optionally installs a lightweight desktop environment (XFCE)
#   4. Configures VNC with a password you choose
#   5. Starts the VNC server on display :1 (port 5901)
#
# Supported platforms:
#   - Debian/Ubuntu (x86_64, aarch64/arm64)
#   - Raspberry Pi OS (armhf, arm64)
#   - Fedora/RHEL/CentOS (x86_64, aarch64)
#   - Arch Linux (x86_64, aarch64)
#   - macOS (uses built-in Screen Sharing)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ─── Platform Detection ───────────────────────────────────────────────

detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                DISTRO="$ID"
                DISTRO_LIKE="${ID_LIKE:-$ID}"
            elif [ -f /etc/debian_version ]; then
                DISTRO="debian"
                DISTRO_LIKE="debian"
            elif [ -f /etc/redhat-release ]; then
                DISTRO="rhel"
                DISTRO_LIKE="rhel"
            else
                DISTRO="unknown"
                DISTRO_LIKE="unknown"
            fi
            ;;
        Darwin)
            DISTRO="macos"
            DISTRO_LIKE="macos"
            ;;
        *)
            err "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    info "Detected: OS=$OS ARCH=$ARCH DISTRO=$DISTRO"
}

# ─── macOS ────────────────────────────────────────────────────────────

setup_macos() {
    echo ""
    info "macOS detected — using built-in Screen Sharing / Remote Management"
    echo ""
    echo -e "  ${CYAN}To enable VNC on macOS:${NC}"
    echo ""
    echo "  1. Open System Settings > General > Sharing"
    echo "  2. Enable 'Screen Sharing' or 'Remote Management'"
    echo "  3. Click the (i) button and enable 'VNC viewers may control screen with password'"
    echo "  4. Set a VNC password"
    echo ""
    echo -e "  ${CYAN}Then connect from cmux:${NC}"
    echo "  Host: localhost (or this Mac's IP)"
    echo "  Port: 5900"
    echo "  User: $(whoami)"
    echo "  Pass: your macOS password"
    echo ""

    # Check if already enabled
    if sudo launchctl list 2>/dev/null | grep -q screensharing; then
        ok "Screen Sharing is already running on port 5900"
    else
        echo -e "  ${YELLOW}Or enable via command line:${NC}"
        echo "  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \\"
        echo "    -activate -configure -access -on -privs -all -restart -agent -menu"
        echo ""
        read -rp "Enable Screen Sharing now? [y/N] " yn
        if [[ "$yn" =~ ^[Yy] ]]; then
            sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
                -activate -configure -access -on -privs -all -restart -agent -menu
            ok "Screen Sharing enabled"
        fi
    fi
}

# ─── Package Manager Detection ────────────────────────────────────────

install_packages() {
    local packages=("$@")

    if command -v apt-get &>/dev/null; then
        info "Installing via apt: ${packages[*]}"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
    elif command -v dnf &>/dev/null; then
        info "Installing via dnf: ${packages[*]}"
        sudo dnf install -y -q "${packages[@]}"
    elif command -v yum &>/dev/null; then
        info "Installing via yum: ${packages[*]}"
        sudo yum install -y -q "${packages[@]}"
    elif command -v pacman &>/dev/null; then
        info "Installing via pacman: ${packages[*]}"
        sudo pacman -Sy --noconfirm "${packages[@]}"
    else
        err "No supported package manager found (apt, dnf, yum, pacman)"
        exit 1
    fi
}

# ─── Linux VNC Setup ──────────────────────────────────────────────────

setup_linux() {
    echo ""
    info "Setting up TigerVNC server on Linux ($DISTRO / $ARCH)"
    echo ""

    # ── Install TigerVNC ──
    case "$DISTRO_LIKE" in
        *debian*|*ubuntu*|*raspbian*)
            install_packages tigervnc-standalone-server tigervnc-common
            ;;
        *rhel*|*fedora*|*centos*)
            install_packages tigervnc-server
            ;;
        *arch*)
            install_packages tigervnc
            ;;
        *)
            warn "Unknown distro '$DISTRO'. Attempting apt-based install..."
            install_packages tigervnc-standalone-server tigervnc-common
            ;;
    esac
    ok "TigerVNC installed"

    # ── Install desktop environment ──
    echo ""
    echo -e "  ${CYAN}Desktop environment options:${NC}"
    echo "  1) XFCE  (lightweight, ~200MB) — recommended"
    echo "  2) LXDE  (very lightweight, ~150MB)"
    echo "  3) Skip  (use existing desktop or headless)"
    echo ""
    read -rp "Choose [1/2/3]: " de_choice

    case "$de_choice" in
        1)
            info "Installing XFCE..."
            case "$DISTRO_LIKE" in
                *debian*|*ubuntu*|*raspbian*)
                    install_packages xfce4 xfce4-terminal dbus-x11
                    ;;
                *rhel*|*fedora*|*centos*)
                    install_packages @xfce-desktop-environment
                    ;;
                *arch*)
                    install_packages xfce4 xfce4-goodies
                    ;;
            esac
            DE_CMD="/usr/bin/startxfce4"
            ok "XFCE installed"
            ;;
        2)
            info "Installing LXDE..."
            case "$DISTRO_LIKE" in
                *debian*|*ubuntu*|*raspbian*)
                    install_packages lxde-core lxterminal dbus-x11
                    ;;
                *rhel*|*fedora*|*centos*)
                    install_packages @lxde-desktop
                    ;;
                *arch*)
                    install_packages lxde
                    ;;
            esac
            DE_CMD="/usr/bin/startlxde"
            ok "LXDE installed"
            ;;
        3|*)
            DE_CMD="/usr/bin/xterm"
            warn "Skipping desktop install. Using xterm as fallback."
            install_packages xterm 2>/dev/null || true
            ;;
    esac

    # ── Set VNC password ──
    echo ""
    info "Set your VNC password (this is what you'll enter in cmux):"
    mkdir -p "$HOME/.vnc"
    chmod 700 "$HOME/.vnc"

    if command -v tigervncpasswd &>/dev/null; then
        tigervncpasswd "$HOME/.vnc/passwd"
    elif command -v vncpasswd &>/dev/null; then
        vncpasswd "$HOME/.vnc/passwd"
    else
        err "vncpasswd not found"
        exit 1
    fi
    ok "VNC password set"

    # ── Create xstartup ──
    cat > "$HOME/.vnc/xstartup" <<XSTARTUP
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
exec $DE_CMD
XSTARTUP
    chmod +x "$HOME/.vnc/xstartup"
    ok "Created ~/.vnc/xstartup"

    # ── Configure display and geometry ──
    echo ""
    read -rp "VNC display number [1]: " display_num
    display_num="${display_num:-1}"
    if ! [[ "$display_num" =~ ^[0-9]+$ ]] || [ "$display_num" -lt 1 ] || [ "$display_num" -gt 99 ]; then
        err "Invalid display number: must be 1-99"
        exit 1
    fi
    VNC_PORT=$((5900 + display_num))

    read -rp "Resolution [1920x1080]: " resolution
    resolution="${resolution:-1920x1080}"
    if ! [[ "$resolution" =~ ^[0-9]+x[0-9]+$ ]]; then
        err "Invalid resolution: must be WIDTHxHEIGHT (e.g. 1920x1080)"
        exit 1
    fi

    read -rp "Color depth [24]: " depth
    depth="${depth:-24}"
    if ! [[ "$depth" =~ ^(8|16|24|32)$ ]]; then
        err "Invalid color depth: must be 8, 16, 24, or 32"
        exit 1
    fi

    # ── Security warning ──
    warn "VNC password auth uses DES encryption (8-char max). For production use, prefer SSH tunneling."

    # ── Kill existing server on this display ──
    tigervncserver -kill ":$display_num" 2>/dev/null || true

    # ── Start VNC server ──
    info "Starting TigerVNC on display :$display_num (port $VNC_PORT)..."
    tigervncserver ":$display_num" \
        -geometry "$resolution" \
        -depth "$depth" \
        -localhost no \
        -xstartup "$HOME/.vnc/xstartup"

    ok "TigerVNC server started!"

    # ── Print connection info ──
    HOSTNAME=$(hostname)
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_IP")

    echo ""
    echo -e "  ${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  VNC Server Ready!${NC}"
    echo -e "  ${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Connect from cmux:${NC}"
    echo "  Host: $HOSTNAME (or $IP)"
    echo "  Port: $VNC_PORT"
    echo "  User: $(whoami)"
    echo "  Pass: (the password you just set)"
    echo ""
    echo -e "  ${CYAN}Or use the cmux CLI:${NC}"
    echo "  cmux vnc $HOSTNAME:$VNC_PORT"
    echo ""
    echo -e "  ${CYAN}To stop the server:${NC}"
    echo "  tigervncserver -kill :$display_num"
    echo ""
    echo -e "  ${CYAN}To auto-start on boot:${NC}"
    echo "  Add to /etc/rc.local or create a systemd service"
    echo ""

    # ── Create systemd service (optional) ──
    read -rp "Create systemd service for auto-start on boot? [y/N] " create_service
    if [[ "$create_service" =~ ^[Yy] ]]; then
        SERVICE_FILE="/etc/systemd/system/vnc@.service"
        sudo tee "$SERVICE_FILE" > /dev/null <<SYSTEMD
[Unit]
Description=TigerVNC Server for cmux on display %i
After=syslog.target network.target

[Service]
Type=forking
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$HOME
ExecStartPre=-/usr/bin/tigervncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/tigervncserver :%i -geometry $resolution -depth $depth -localhost no -xstartup $HOME/.vnc/xstartup
ExecStop=/usr/bin/tigervncserver -kill :%i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD
        sudo systemctl daemon-reload
        sudo systemctl enable "vnc@${display_num}.service"
        ok "Systemd service created: vnc@${display_num}.service"
        echo "  Start:   sudo systemctl start vnc@${display_num}"
        echo "  Status:  sudo systemctl status vnc@${display_num}"
        echo "  Stop:    sudo systemctl stop vnc@${display_num}"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  cmux VNC Server Setup                        ║${NC}"
    echo -e "${CYAN}║  Remote Desktop for Terminal-First Agent Hosts      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_platform

    case "$OS" in
        Darwin) setup_macos ;;
        Linux)  setup_linux ;;
        *)      err "Unsupported OS: $OS"; exit 1 ;;
    esac

    echo ""
    ok "Setup complete!"
}

main "$@"
