#!/usr/bin/env bash
# yk-gui-setup.sh — Install YubiKey GUI applications (selective, with detection)
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

# --- Root check ---
[[ $EUID -eq 0 ]] || { err "Run as root or with sudo."; exit 1; }

# --- Detect package manager ---
detect_pm() {
    if command -v pacman &>/dev/null; then
        PM="pacman"; DISTRO="arch"
    elif command -v dnf &>/dev/null; then
        PM="dnf"; DISTRO="fedora"
    elif command -v apt &>/dev/null; then
        PM="apt"; DISTRO="debian"
    elif command -v zypper &>/dev/null; then
        PM="zypper"; DISTRO="opensuse"
    else
        err "No supported package manager found (pacman/dnf/apt/zypper)."
        exit 1
    fi
    log "Detected: ${DISTRO} (${PM})"
}

# --- App definitions ---
# Each app: description, binary to check, package per distro
declare -A APP_DESC=(
    [ykman-gui]="YubiKey Manager GUI — manage OTP, FIDO2, PIV, OATH, interfaces"
    [yubioath]="Yubico Authenticator — TOTP/HOTP with secrets stored on YubiKey"
    [kleopatra]="Kleopatra — GPG/X.509 certificate manager (OpenPGP smartcard)"
)

declare -A APP_BIN=(
    [ykman-gui]="ykman-gui"
    [yubioath]="authenticator"
    [kleopatra]="kleopatra"
)

# Package names per distro: app:distro
declare -A APP_PKG=(
    [ykman-gui:arch]="yubikey-manager-qt"
    [ykman-gui:fedora]="yubikey-manager-qt"
    [ykman-gui:debian]="yubikey-manager-qt"
    [ykman-gui:opensuse]="yubikey-manager-qt"
    [yubioath:arch]="yubico-authenticator-bin"
    [yubioath:fedora]="yubioath-desktop"
    [yubioath:debian]="yubioath-desktop"
    [yubioath:opensuse]="yubioath-desktop"
    [kleopatra:arch]="kleopatra"
    [kleopatra:fedora]="kleopatra"
    [kleopatra:debian]="kleopatra"
    [kleopatra:opensuse]="kleopatra"
)

# Flatpak fallback IDs
declare -A APP_FLATPAK=(
    [ykman-gui]=""
    [yubioath]="com.yubico.yubioath"
    [kleopatra]="org.kde.kleopatra"
)

APP_ORDER=(ykman-gui yubioath kleopatra)

# --- Detect installed status ---
check_installed() {
    local app="$1"
    local bin="${APP_BIN[$app]}"

    # Check binary in PATH
    if command -v "$bin" &>/dev/null; then
        return 0
    fi

    # Check common desktop file locations
    local name
    case "$app" in
        ykman-gui) name="ykman-gui" ;;
        yubioath)  name="yubico-authenticator\|com.yubico.yubioath" ;;
        kleopatra) name="kleopatra" ;;
    esac

    if find /usr/share/applications /var/lib/flatpak/exports/share/applications \
            "$HOME/.local/share/applications" \
            -iname "*${name}*.desktop" 2>/dev/null | grep -q .; then
        return 0
    fi

    # Check flatpak
    local flatpak_id="${APP_FLATPAK[$app]}"
    if [[ -n "$flatpak_id" ]] && command -v flatpak &>/dev/null; then
        if flatpak list --app 2>/dev/null | grep -qi "$flatpak_id"; then
            return 0
        fi
    fi

    return 1
}

# --- Display menu ---
show_menu() {
    echo ""
    info "YubiKey GUI Applications"
    echo ""

    local i=1
    for app in "${APP_ORDER[@]}"; do
        local status
        if check_installed "$app"; then
            status="${GREEN}installed${NC}"
        else
            status="${YELLOW}not installed${NC}"
        fi
        echo -e "  ${i}) ${APP_DESC[$app]}"
        echo -e "     Status: ${status}"
        echo ""
        ((i++)) || true
    done

    echo "  a) Install all (skip already installed)"
    echo "  q) Quit"
    echo ""
}

# --- Install a single app ---
install_app() {
    local app="$1"
    local pkg="${APP_PKG[${app}:${DISTRO}]:-}"
    local flatpak_id="${APP_FLATPAK[$app]}"

    if check_installed "$app"; then
        log "${APP_BIN[$app]} is already installed — skipping"
        return 0
    fi

    # Try native package first
    if [[ -n "$pkg" ]]; then
        info "Installing ${pkg} via ${PM}..."
        case "$PM" in
            pacman) pacman -Sy --needed --noconfirm "$pkg" 2>/dev/null && { log "${pkg} installed."; return 0; } ;;
            dnf)    dnf install -y --skip-unavailable "$pkg" 2>/dev/null && { log "${pkg} installed."; return 0; } ;;
            apt)    apt install -y "$pkg" 2>/dev/null && { log "${pkg} installed."; return 0; } ;;
            zypper) zypper install -y "$pkg" 2>/dev/null && { log "${pkg} installed."; return 0; } ;;
        esac
        warn "Native package ${pkg} not available."
    fi

    # Flatpak fallback
    if [[ -n "$flatpak_id" ]] && command -v flatpak &>/dev/null; then
        info "Trying flatpak: ${flatpak_id}..."
        if flatpak install -y flathub "$flatpak_id" 2>/dev/null; then
            log "${flatpak_id} installed via flatpak."
            return 0
        fi
    fi

    # AUR hint for Arch
    if [[ "$DISTRO" == "arch" ]]; then
        case "$app" in
            ykman-gui)
                warn "YubiKey Manager GUI not in official Arch repos."
                echo "     Install from AUR: yay -S yubikey-manager-qt"
                return 1
                ;;
            yubioath)
                warn "Yubico Authenticator not in official repos."
                echo "     Install from AUR: yay -S yubico-authenticator-bin"
                return 1
                ;;
        esac
    fi

    err "Could not install ${app}. Install manually."
    return 1
}

# --- Process selection ---
process_selection() {
    local choice="$1"

    case "$choice" in
        1) install_app "ykman-gui" ;;
        2) install_app "yubioath" ;;
        3) install_app "kleopatra" ;;
        a|A)
            for app in "${APP_ORDER[@]}"; do
                install_app "$app"
            done
            ;;
        q|Q) echo ""; log "Done."; exit 0 ;;
        *)   err "Invalid selection." ;;
    esac
}

# --- Main loop ---
main() {
    detect_pm

    while true; do
        show_menu
        read -rp "Select [1-3/a/q]: " CHOICE
        echo ""
        process_selection "$CHOICE"
        echo ""
        read -rp "Install another? [y/N]: " AGAIN
        [[ "$AGAIN" =~ ^[Yy]$ ]] || break
    done

    echo ""
    log "Done."
}

main "$@"
