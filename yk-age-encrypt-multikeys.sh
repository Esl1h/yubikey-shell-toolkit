#!/usr/bin/env bash
# yk-age-encrypt-multikeys.sh — Encrypt a file using age + YubiKey PIV (multi-recipient support)
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
RECIPIENTS_FILE="${CONFIG_DIR}/recipients.txt"

usage() {
    echo "Usage: $(basename "$0") [-r RECIPIENT [-r RECIPIENT ...]] [-o OUTPUT] FILE"
    echo ""
    echo "Options:"
    echo "  -r RECIPIENT   age recipient (public key). Can be specified multiple times."
    echo "                 Default: loads from ${RECIPIENTS_FILE} or ${RECIPIENT_FILE}."
    echo "  -o OUTPUT      Output file. Default: FILE.age"
    echo "  -h             Show this help."
    echo ""
    echo "Multi-recipient file: ${RECIPIENTS_FILE}"
    echo "  One age public key per line. Lines starting with # are ignored."
    exit 1
}

# --- Parse args ---
EXTRA_RECIPIENTS=()
OUTPUT=""

while getopts ":r:o:h" opt; do
    case "$opt" in
        r) EXTRA_RECIPIENTS+=("$OPTARG") ;;
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

# --- Determine recipients ---
ALL_RECIPIENTS=("${EXTRA_RECIPIENTS[@]+"${EXTRA_RECIPIENTS[@]}"}")

# Load from recipients.txt if no -r was passed
if [[ ${#ALL_RECIPIENTS[@]} -eq 0 ]]; then
    if [[ -f "$RECIPIENTS_FILE" ]]; then
        info "Loading recipients from: ${RECIPIENTS_FILE}"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            ALL_RECIPIENTS+=("$line")
        done < "$RECIPIENTS_FILE"
    fi
fi

# Fallback: single recipient file (legacy)
if [[ ${#ALL_RECIPIENTS[@]} -eq 0 ]]; then
    if [[ -f "$RECIPIENT_FILE" ]]; then
        ALL_RECIPIENTS+=("$(cat "$RECIPIENT_FILE")")
        info "Using YubiKey recipient from: ${RECIPIENT_FILE}"
    else
        # Try to get it live from the YubiKey
        if command -v age-plugin-yubikey &>/dev/null; then
            LIVE_RECIPIENT=$(age-plugin-yubikey --list 2>/dev/null | grep -E "^age1" | head -1 || true)
            [[ -n "$LIVE_RECIPIENT" ]] && ALL_RECIPIENTS+=("$LIVE_RECIPIENT")
        fi
    fi
fi

if [[ ${#ALL_RECIPIENTS[@]} -eq 0 ]]; then
    err "No recipients found. Run yk-age-setup.sh first, create ${RECIPIENTS_FILE}, or pass -r."
    exit 1
fi

# Build age -r flags
RECIPIENT_ARGS=()
for r in "${ALL_RECIPIENTS[@]}"; do
    RECIPIENT_ARGS+=(-r "$r")
done

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
info "Recipients: ${#ALL_RECIPIENTS[@]}"
for r in "${ALL_RECIPIENTS[@]}"; do
    info "  → ${r}"
done
info "Output:     ${OUTPUT}"
echo ""

if age "${RECIPIENT_ARGS[@]}" -o "$OUTPUT" "$INPUT"; then
    log "Encrypted successfully."
    echo ""
    echo "  Input:  ${INPUT} ($(stat -c%s "$INPUT" 2>/dev/null || stat -f%z "$INPUT") bytes)"
    echo "  Output: ${OUTPUT} ($(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT") bytes)"
    echo ""
    info "Decrypt with: yk-age-decrypt-multikeys.sh ${OUTPUT}"
else
    err "Encryption failed."
    rm -f "$OUTPUT"
    exit 1
fi
