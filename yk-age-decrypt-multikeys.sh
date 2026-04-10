#!/usr/bin/env bash
# yk-age-decrypt-multikeys.sh — Decrypt a file using age + YubiKey PIV (multi-identity support)
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
IDENTITIES_FILE="${CONFIG_DIR}/identities.txt"

usage() {
    echo "Usage: $(basename "$0") [-i IDENTITY [-i IDENTITY ...]] [-o OUTPUT] FILE"
    echo ""
    echo "Options:"
    echo "  -i IDENTITY    age identity file. Can be specified multiple times."
    echo "                 Default: loads from ${IDENTITIES_FILE} or ${IDENTITY_FILE}."
    echo "  -o OUTPUT      Output file. Default: FILE without .age extension."
    echo "  -h             Show this help."
    echo ""
    echo "Multi-identity file: ${IDENTITIES_FILE}"
    echo "  One identity file path per line. Lines starting with # are ignored."
    exit 1
}

# --- Parse args ---
EXTRA_IDENTITIES=()
OUTPUT=""

while getopts ":i:o:h" opt; do
    case "$opt" in
        i) EXTRA_IDENTITIES+=("$OPTARG") ;;
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

# --- Determine identities ---
ALL_IDENTITIES=("${EXTRA_IDENTITIES[@]+"${EXTRA_IDENTITIES[@]}"}")

# Load from identities.txt if no -i was passed
if [[ ${#ALL_IDENTITIES[@]} -eq 0 ]]; then
    if [[ -f "$IDENTITIES_FILE" ]]; then
        info "Loading identities from: ${IDENTITIES_FILE}"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            ALL_IDENTITIES+=("$line")
        done < "$IDENTITIES_FILE"
    fi
fi

# Fallback: single identity file (legacy)
if [[ ${#ALL_IDENTITIES[@]} -eq 0 ]]; then
    if [[ -f "$IDENTITY_FILE" ]]; then
        ALL_IDENTITIES+=("$IDENTITY_FILE")
        info "Using YubiKey identity from: ${IDENTITY_FILE}"
    else
        err "No identity found. Run yk-age-setup.sh first, create ${IDENTITIES_FILE}, or pass -i."
        exit 1
    fi
fi

# Validate all identity files exist
for id in "${ALL_IDENTITIES[@]}"; do
    [[ -f "$id" ]] || { err "Identity file not found: ${id}"; exit 1; }
done

# Build age -i flags
IDENTITY_ARGS=()
for id in "${ALL_IDENTITIES[@]}"; do
    IDENTITY_ARGS+=(-i "$id")
done

# --- Determine output ---
if [[ -z "$OUTPUT" ]]; then
    if [[ "$INPUT" == *.age ]]; then
        OUTPUT="${INPUT%.age}"
    else
        OUTPUT="${INPUT}.decrypted"
    fi
fi

if [[ -f "$OUTPUT" ]]; then
    warn "Output file already exists: ${OUTPUT}"
    read -rp "[?] Overwrite? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# --- Validate age + plugin are available ---
command -v age &>/dev/null || { err "age not found. Install it or run yk-age-setup.sh."; exit 1; }
command -v age-plugin-yubikey &>/dev/null || { err "age-plugin-yubikey not found. Run yk-age-setup.sh."; exit 1; }

# --- Decrypt ---
info "Decrypting: ${INPUT}"
info "Identities: ${#ALL_IDENTITIES[@]}"
for id in "${ALL_IDENTITIES[@]}"; do
    info "  → ${id}"
done
info "Output:     ${OUTPUT}"
echo ""
info "Touch YubiKey if it blinks. PIN may be required."
echo ""

if age -d "${IDENTITY_ARGS[@]}" -o "$OUTPUT" "$INPUT"; then
    log "Decrypted successfully."
    echo ""
    echo "  Input:  ${INPUT} ($(stat -c%s "$INPUT" 2>/dev/null || stat -f%z "$INPUT") bytes)"
    echo "  Output: ${OUTPUT} ($(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT") bytes)"
else
    err "Decryption failed."
    err "Ensure the correct YubiKey is inserted and the identity matches."
    rm -f "$OUTPUT"
    exit 1
fi
