#!/usr/bin/env bash
# yk-setup.sh — Install all required packages for YubiKey operation
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

# --- YubiKey model selection ---
select_model() {
    echo ""
    info "Select your YubiKey model:"
    echo "  1) YubiKey 5 (USB-A/USB-C/NFC) — FIDO2, PIV, OATH, challenge-response"
    echo "  2) YubiKey 5 Nano/Ci — same as above, nano form factor"
    echo "  3) YubiKey Bio — FIDO2 + fingerprint (no PIV/OATH/challenge-response)"
    echo "  4) YubiKey Security Key — FIDO2/U2F only"
    echo "  5) YubiKey 4 (legacy) — PIV, OATH, challenge-response (no FIDO2)"
    echo ""
    read -rp "Model [1-5]: " MODEL_CHOICE

    case "$MODEL_CHOICE" in
        1|2) MODEL="yk5"   ; HAS_FIDO2=1; HAS_PIV=1; HAS_OATH=1; HAS_CHALRESP=1 ;;
        3)   MODEL="bio"   ; HAS_FIDO2=1; HAS_PIV=0; HAS_OATH=0; HAS_CHALRESP=0 ;;
        4)   MODEL="seckey"; HAS_FIDO2=1; HAS_PIV=0; HAS_OATH=0; HAS_CHALRESP=0 ;;
        5)   MODEL="yk4"   ; HAS_FIDO2=0; HAS_PIV=1; HAS_OATH=1; HAS_CHALRESP=1 ;;
        *)   err "Invalid selection."; exit 1 ;;
    esac
    log "Model: ${MODEL} | FIDO2=${HAS_FIDO2} PIV=${HAS_PIV} OATH=${HAS_OATH} CHALRESP=${HAS_CHALRESP}"
}

# --- Install packages ---
install_packages() {
    local -a BASE_PKGS FIDO_PKGS PIV_PKGS

    case "$DISTRO" in
        arch)
            BASE_PKGS=(yubikey-manager pcsc-tools ccid opensc)
            FIDO_PKGS=(libfido2 pam-u2f)
            PIV_PKGS=(yubico-piv-tool)
            ;;
        fedora)
            BASE_PKGS=(yubikey-manager pcsc-tools pcsc-lite-ccid opensc)
            FIDO_PKGS=(libfido2 pam-u2f)
            PIV_PKGS=(yubico-piv-tool)
            ;;
        debian)
            BASE_PKGS=(yubikey-manager pcscd pcsc-tools libccid opensc)
            FIDO_PKGS=(libfido2-dev libpam-u2f)
            PIV_PKGS=(yubico-piv-tool)
            ;;
        opensuse)
            BASE_PKGS=(yubikey-manager pcsc-tools pcsc-ccid opensc)
            FIDO_PKGS=(libfido2 pam_u2f)
            PIV_PKGS=(yubico-piv-tool)
            ;;
    esac

    local -a PKGS=("${BASE_PKGS[@]}")
    (( HAS_FIDO2 )) && PKGS+=("${FIDO_PKGS[@]}")
    (( HAS_PIV ))   && PKGS+=("${PIV_PKGS[@]}")

    info "Installing: ${PKGS[*]}"
    case "$PM" in
        pacman) pacman -S --needed --noconfirm "${PKGS[@]}" ;;
        dnf)    dnf install -y --skip-unavailable "${PKGS[@]}" ;;
        apt)    apt update && apt install -y "${PKGS[@]}" ;;
        zypper) zypper install -y "${PKGS[@]}" ;;
    esac
    log "Packages installed."
}

# --- Enable services ---
enable_services() {
    info "Enabling pcscd (PC/SC Smart Card Daemon)..."
    systemctl enable --now pcscd.socket 2>/dev/null || \
    systemctl enable --now pcscd.service 2>/dev/null || \
        warn "Could not enable pcscd — check manually."
    log "Services configured."
}

# --- udev rules ---
setup_udev() {
    local RULES_FILE="/etc/udev/rules.d/70-yubikey.rules"

    if [[ -f "$RULES_FILE" ]]; then
        warn "udev rules already exist at ${RULES_FILE}, skipping."
        return
    fi

    info "Writing udev rules..."
    cat > "$RULES_FILE" <<'EOF'
# YubiKey — allow logged-in user access via uaccess
ACTION=="add|change", SUBSYSTEM=="usb", \
  ATTRS{idVendor}=="1050", \
  MODE="0660", TAG+="uaccess"
EOF

    udevadm control --reload-rules
    udevadm trigger
    log "udev rules installed: ${RULES_FILE}"

    # plugdev only on distros that use it
    if [[ "$DISTRO" == "debian" ]]; then
        local CALLING_USER="${SUDO_USER:-$USER}"
        if getent group plugdev &>/dev/null; then
            if ! id -nG "$CALLING_USER" | grep -qw plugdev; then
                usermod -aG plugdev "$CALLING_USER"
                log "Added ${CALLING_USER} to plugdev group (re-login required)."
            fi
        fi
    fi
}

# --- Summary ---
summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN} YubiKey setup complete${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo "  Model:              ${MODEL}"
    echo "  Distro:             ${DISTRO} (${PM})"
    echo "  FIDO2/U2F:          $(( HAS_FIDO2 ))"
    echo "  PIV:                $(( HAS_PIV ))"
    echo "  OATH:               $(( HAS_OATH ))"
    echo "  Challenge-Response: $(( HAS_CHALRESP ))"
    echo ""
    echo "  Useful commands:"
    echo "    ykman info                  — device info"
    echo "    ykman list                  — list connected keys"
    echo "    ykman fido info             — FIDO2 status"
    echo "    ykman oath accounts list    — OATH/TOTP accounts"
    echo "    ykman otp calculate 2 <hex> — test challenge-response"
    echo ""
    warn "Re-login may be required for udev changes to take effect."
}

# --- Main ---
main() {
    detect_pm
    select_model
    install_packages
    enable_services
    setup_udev
    summary
}

main "$@"
