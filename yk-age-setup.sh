#!/usr/bin/env bash
# yk-age-setup.sh — Install age + age-plugin-yubikey and generate key pair on YubiKey PIV
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

CONFIG_DIR="${HOME}/.config/yk-toolkit/age"
IDENTITY_FILE="${CONFIG_DIR}/yubikey-identity.txt"
RECIPIENT_FILE="${CONFIG_DIR}/yubikey-recipient.txt"

PLUGIN_VERSION="0.5.0"
PLUGIN_URL="https://github.com/str4d/age-plugin-yubikey/releases/download/v${PLUGIN_VERSION}"

# --- Detect architecture ---
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64-linux" ;;
        aarch64) echo "aarch64-linux" ;;
        *)       err "Unsupported architecture: ${arch}"; exit 1 ;;
    esac
}

# --- Install age ---
install_age() {
    if command -v age &>/dev/null; then
        log "age already installed: $(age --version 2>/dev/null || echo 'ok')"
        return 0
    fi

    info "Installing age..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y age
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --needed --noconfirm age
    elif command -v apt &>/dev/null; then
        sudo apt install -y age
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y age
    else
        err "Install age manually: https://github.com/FiloSottile/age"
        return 1
    fi
}

# --- Install pcsc-lite (runtime + dev headers) ---
install_pcsc() {
    info "Ensuring pcsc-lite is installed..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y pcsc-lite pcsc-lite-devel
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --needed --noconfirm pcsclite
    elif command -v apt &>/dev/null; then
        sudo apt install -y pcscd libpcsclite-dev
    elif command -v zypper &>/dev/null; then
        sudo zypper install -y pcsc-lite pcsc-lite-devel
    fi

    if systemctl is-active --quiet pcscd 2>/dev/null; then
        log "pcscd is running."
    else
        info "Starting pcscd..."
        sudo systemctl enable --now pcscd.socket pcscd.service 2>/dev/null || true
    fi
}

# --- Install age-plugin-yubikey from pre-built binary ---
install_plugin() {
    if command -v age-plugin-yubikey &>/dev/null; then
        log "age-plugin-yubikey already installed: $(command -v age-plugin-yubikey)"
        return 0
    fi

    local arch tarball url tmpdir
    arch=$(detect_arch)
    tarball="age-plugin-yubikey-v${PLUGIN_VERSION}-${arch}.tar.gz"
    url="${PLUGIN_URL}/${tarball}"
    tmpdir=$(mktemp -d)

    info "Downloading age-plugin-yubikey v${PLUGIN_VERSION} (${arch})..."
    if ! curl -fSL -o "${tmpdir}/${tarball}" "$url"; then
        err "Download failed: ${url}"
        err "Check available binaries at: ${PLUGIN_URL}"
        rm -rf "$tmpdir"
        return 1
    fi

    info "Extracting..."
    tar xzf "${tmpdir}/${tarball}" -C "$tmpdir"

    local bin
    bin=$(find "$tmpdir" -name "age-plugin-yubikey" -type f | head -1)
    if [[ -z "$bin" ]]; then
        err "Binary not found in archive."
        rm -rf "$tmpdir"
        return 1
    fi

    info "Installing to /usr/local/bin/..."
    sudo install -m 755 "$bin" /usr/local/bin/age-plugin-yubikey

    rm -rf "$tmpdir"
    log "age-plugin-yubikey installed: /usr/local/bin/age-plugin-yubikey"
}

# --- Install dependencies ---
install_deps() {
    info "Checking dependencies..."
    echo ""
    install_age
    install_pcsc
    install_plugin
}

# --- Save identity and recipient to files ---
save_identity() {
    local ident="$1" recip="$2"

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    echo "$ident" > "$IDENTITY_FILE"
    chmod 600 "$IDENTITY_FILE"

    echo "$recip" > "$RECIPIENT_FILE"
    chmod 644 "$RECIPIENT_FILE"

    echo ""
    log "Identity saved."
    echo ""
    echo "  Identity (private ref): ${IDENTITY_FILE}"
    echo "  Recipient (public key): ${RECIPIENT_FILE}"
    echo ""
    echo "  Your public key (share this):"
    echo "  ${recip}"
    echo ""
    info "The private key lives inside the YubiKey — it was never on disk."
}

# --- Extract identity and recipient from YubiKey ---
extract_from_yubikey() {
    local recip ident

    recip=$(age-plugin-yubikey --list 2>/dev/null | grep -E "^age1" | head -1 || true)
    ident=$(age-plugin-yubikey --identity --slot 1 2>/dev/null | grep -E "^AGE-PLUGIN-YUBIKEY-" | head -1 || true)

    if [[ -z "$recip" || -z "$ident" ]]; then
        err "Failed to extract identity/recipient from YubiKey."
        err "Try manually:"
        err "  age-plugin-yubikey --list"
        err "  age-plugin-yubikey --identity --slot 1"
        return 1
    fi

    save_identity "$ident" "$recip"
}

# --- Reuse existing PIV key ---
reuse_existing() {
    info "Extracting existing identity from YubiKey PIV slot 1..."
    extract_from_yubikey
}

# --- Generate new PIV key (overwrites slot) ---
generate_new() {
    warn "This will OVERWRITE the existing key in PIV slot 1."
    warn "Any data encrypted to the current key will be UNRECOVERABLE."
    echo ""
    read -rp "[?] Type 'YES' to confirm: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || { log "Aborted."; return 0; }

    echo ""
    info "Touch YubiKey if it blinks. PIN may be required."
    echo ""

    age-plugin-yubikey --generate \
        --slot 1 \
        --name "yk-toolkit" \
        --touch-policy cached \
        --pin-policy once

    info "Extracting new identity from YubiKey..."
    extract_from_yubikey
}

# --- Generate identity (first time, no existing key) ---
generate_fresh() {
    info "Generating age identity on YubiKey PIV slot 1..."
    echo ""
    info "Touch YubiKey if it blinks. PIN may be required."
    echo ""

    age-plugin-yubikey --generate \
        --slot 1 \
        --name "yk-toolkit" \
        --touch-policy cached \
        --pin-policy once

    info "Extracting identity from YubiKey..."
    extract_from_yubikey
}

# --- PIV key menu ---
piv_menu() {
    # Check for existing key
    local existing
    existing=$(age-plugin-yubikey --list 2>/dev/null | grep -E "^age1" | head -1 || true)

    if [[ -n "$existing" ]]; then
        warn "Existing PIV key detected in YubiKey:"
        echo "  ${existing}"
        echo ""
        echo "  1) Reuse existing key (export identity files only)"
        echo "  2) Generate NEW key (destroys current key — IRREVERSIBLE)"
        echo "  3) Cancel"
        echo ""
        read -rp "[?] Choose [1/2/3]: " CHOICE
        case "$CHOICE" in
            1) reuse_existing ;;
            2) generate_new ;;
            *) log "Cancelled." ;;
        esac
    else
        read -rp "[?] No PIV key found. Generate one now? [Y/n]: " GEN
        if [[ ! "$GEN" =~ ^[Nn]$ ]]; then
            generate_fresh
        else
            show_identity
        fi
    fi
}

# --- Show current identity ---
show_identity() {
    echo ""
    if [[ -f "$RECIPIENT_FILE" ]]; then
        info "Current identity:"
        echo "  Identity file:  ${IDENTITY_FILE}"
        echo "  Recipient file: ${RECIPIENT_FILE}"
        echo "  Public key:     $(cat "$RECIPIENT_FILE")"
    else
        warn "No identity configured yet."
    fi
}

# --- Main ---
main() {
    echo -e "${CYAN}yk-age-setup.sh — age + YubiKey PIV setup${NC}"
    echo ""

    install_deps

    echo ""
    for bin in age age-plugin-yubikey ykman; do
        if command -v "$bin" &>/dev/null; then
            log "${bin}: $(command -v "$bin")"
        else
            warn "${bin}: not found (optional)"
        fi
    done

    echo ""
    piv_menu
}

main "$@"
