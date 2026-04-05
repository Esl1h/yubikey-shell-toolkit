#!/usr/bin/env bash
# yk-age-encrypt.sh — Encrypt a file using age + YubiKey PIV
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
RECIPIENT_FILE="${CONFIG_DIR}/yubikey-recipient.txt"

usage() {
    echo "Usage: $(basename "$0") [-r RECIPIENT] [-o OUTPUT] FILE"
    echo ""
    echo "Options:"
    echo "  -r RECIPIENT   age recipient (public key or file). Default: YubiKey recipient from setup."
    echo "  -o OUTPUT      Output file. Default: FILE.age"
    echo "  -h             Show this help."
    exit 1
}

# --- Parse args ---
RECIPIENT=""
OUTPUT=""

while getopts ":r:o:h" opt; do
    case "$opt" in
        r) RECIPIENT="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { err "No input file specified."; usage; }
[[ -f "$INPUT" ]] || { err "File not found: ${INPUT}"; exit 1; }

# Resolve absolute path
INPUT=$(realpath "$INPUT")

# --- Determine recipient ---
if [[ -z "$RECIPIENT" ]]; then
    if [[ -f "$RECIPIENT_FILE" ]]; then
        RECIPIENT=$(cat "$RECIPIENT_FILE")
        info "Using YubiKey recipient from: ${RECIPIENT_FILE}"
    else
        # Try to get it live from the YubiKey
        if command -v age-plugin-yubikey &>/dev/null; then
            RECIPIENT=$(age-plugin-yubikey --list 2>/dev/null | grep -E "^age1" | head -1 || true)
        fi
        if [[ -z "$RECIPIENT" ]]; then
            err "No recipient found. Run yk-age-setup.sh first or pass -r."
            exit 1
        fi
        info "Using recipient from YubiKey: ${RECIPIENT}"
    fi
fi

# --- Determine output ---
[[ -z "$OUTPUT" ]] && OUTPUT="${INPUT}.age"

if [[ -f "$OUTPUT" ]]; then
    warn "Output file already exists: ${OUTPUT}"
    read -rp "[?] Overwrite? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# --- Validate age is available ---
command -v age &>/dev/null || { err "age not found. Install it or run yk-age-setup.sh."; exit 1; }

# --- Encrypt ---
info "Encrypting: ${INPUT}"
info "Recipient:  ${RECIPIENT}"
info "Output:     ${OUTPUT}"
echo ""

if age -r "$RECIPIENT" -o "$OUTPUT" "$INPUT"; then
    log "Encrypted successfully."
    echo ""
    echo "  Input:  ${INPUT} ($(stat -c%s "$INPUT" 2>/dev/null || stat -f%z "$INPUT") bytes)"
    echo "  Output: ${OUTPUT} ($(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT") bytes)"
    echo ""
    info "Decrypt with: yk-age-decrypt.sh ${OUTPUT}"
else
    err "Encryption failed."
    rm -f "$OUTPUT"
    exit 1
fi
