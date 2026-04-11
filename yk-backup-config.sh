#!/usr/bin/env bash
# yk-backup-config.sh — Export YubiKey configuration state to JSON as restore reference
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

yk_cmd() { timeout 5 "$@" 2>/dev/null || true; }

usage() {
    echo "Usage: $(basename "$0") [-o OUTPUT] [-h]"
    echo ""
    echo "Export full YubiKey configuration state to a JSON file."
    echo ""
    echo "Options:"
    echo "  -o OUTPUT    Output file. Default: yubikey-backup-<serial>-<date>.json"
    echo "  -h           Show this help."
    exit 1
}

json_str() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//$'\n'/\\n}"
    val="${val//$'\t'/\\t}"
    printf '"%s"' "$val"
}

json_array_from_lines() {
    local input="$1"
    local first=true
    printf '['
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        $first || printf ','
        json_str "$line"
        first=false
    done <<< "$input"
    printf ']'
}

json_kv_from_lines() {
    local input="$1"
    local sep="${2:-:}"
    local first=true
    printf '{'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key val
        key=$(echo "$line" | cut -d"$sep" -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        val=$(echo "$line" | cut -d"$sep" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$key" ]] && continue
        $first || printf ','
        printf '%s:%s' "$(json_str "$key")" "$(json_str "$val")"
        first=false
    done <<< "$input"
    printf '}'
}

OUTPUT=""

while getopts ":o:h" opt; do
    case "$opt" in
        o) OUTPUT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

command -v ykman &>/dev/null || { err "ykman not found. Install yubikey-manager first."; exit 1; }

YK_LIST=$(yk_cmd ykman list)
[[ -n "$YK_LIST" ]] || { err "No YubiKey detected. Is it plugged in?"; exit 1; }

info "Reading YubiKey configuration..."

YK_INFO=$(yk_cmd ykman info)
SERIAL=$(echo "$YK_INFO" | grep -i "serial" | head -1 | awk '{print $NF}' || true)
DEVICE_TYPE=$(echo "$YK_INFO" | grep -i "device type" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)
FIRMWARE=$(echo "$YK_INFO" | grep -i "firmware" | head -1 | awk '{print $NF}' || true)
FORM_FACTOR=$(echo "$YK_INFO" | grep -i "form factor" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DATE_SHORT=$(date '+%Y%m%d-%H%M%S')

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="yubikey-backup-${SERIAL:-unknown}-${DATE_SHORT}.json"
fi

if [[ -f "$OUTPUT" ]]; then
    warn "Output file already exists: ${OUTPUT}"
    read -rp "[?] Overwrite? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

USB_CFG=$(yk_cmd ykman config usb --list 2>/dev/null || true)
NFC_CFG=$(yk_cmd ykman config nfc --list 2>/dev/null || true)

info "Reading OTP slots..."
OTP_INFO=$(yk_cmd ykman otp info)

info "Reading FIDO2 info..."
FIDO_INFO=$(yk_cmd ykman fido info)

info "Reading PIV info..."
PIV_INFO=$(yk_cmd ykman piv info)

PIV_CERTS=""
if [[ -n "$PIV_INFO" ]]; then
    info "Reading PIV certificates..."
    for slot in 9a 9c 9d 9e; do
        CERT=$(yk_cmd ykman piv certificates export "$slot" - 2>/dev/null || true)
        if [[ -n "$CERT" ]]; then
            PIV_CERTS="${PIV_CERTS}{\"slot\":\"${slot}\",\"pem\":$(json_str "$CERT")},"
        fi
    done
fi

info "Reading OATH accounts..."
OATH_LIST=$(yk_cmd ykman oath accounts list -H -o 2>/dev/null || true)

info "Reading OpenPGP info..."
OPGP_INFO=$(yk_cmd ykman openpgp info)

GPG_CARD=""
if command -v gpg &>/dev/null; then
    info "Reading GPG card status..."
    GPG_CARD=$(yk_cmd gpg --card-status 2>/dev/null || true)
fi

GPG_PUBKEYS=""
if [[ -n "$GPG_CARD" ]]; then
    KEYGRIPS=$(echo "$GPG_CARD" | grep -oP 'key\.\.\.\.: [A-F0-9]{40}' | awk '{print $2}' || true)
    if [[ -z "$KEYGRIPS" ]]; then
        KEYGRIPS=$(echo "$GPG_CARD" | grep -oP '[A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4}  [A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4} [A-F0-9]{4}' | tr -d ' ' || true)
    fi
    if [[ -n "$KEYGRIPS" ]]; then
        while IFS= read -r fpr; do
            [[ -z "$fpr" ]] && continue
            PUBKEY=$(gpg --export --armor "$fpr" 2>/dev/null || true)
            if [[ -n "$PUBKEY" ]]; then
                GPG_PUBKEYS="${GPG_PUBKEYS}$(json_str "$PUBKEY"),"
            fi
        done <<< "$KEYGRIPS"
    fi
fi

info "Building JSON..."

{
    printf '{\n'
    printf '  "backup_metadata": {\n'
    printf '    "version": "1.0",\n'
    printf '    "timestamp": %s,\n' "$(json_str "$TIMESTAMP")"
    printf '    "hostname": %s,\n' "$(json_str "$(hostname)")"
    printf '    "tool": "yk-backup-config.sh"\n'
    printf '  },\n'

    printf '  "device": {\n'
    printf '    "type": %s,\n' "$(json_str "$DEVICE_TYPE")"
    printf '    "serial": %s,\n' "$(json_str "$SERIAL")"
    printf '    "firmware": %s,\n' "$(json_str "$FIRMWARE")"
    printf '    "form_factor": %s\n' "$(json_str "$FORM_FACTOR")"
    printf '  },\n'

    printf '  "interfaces": {\n'
    printf '    "usb": %s,\n' "$(json_array_from_lines "${USB_CFG:-}")"
    printf '    "nfc": %s\n' "$(json_array_from_lines "${NFC_CFG:-}")"
    printf '  },\n'

    printf '  "otp_slots": %s,\n' "$(json_kv_from_lines "${OTP_INFO:-}")"

    printf '  "fido2": %s,\n' "$(json_kv_from_lines "${FIDO_INFO:-}")"

    printf '  "piv": {\n'
    printf '    "info": %s,\n' "$(json_kv_from_lines "${PIV_INFO:-}")"
    printf '    "certificates": ['
    if [[ -n "$PIV_CERTS" ]]; then
        printf '%s' "${PIV_CERTS%,}"
    fi
    printf ']\n'
    printf '  },\n'

    printf '  "oath_accounts": %s,\n' "$(json_array_from_lines "${OATH_LIST:-}")"

    printf '  "openpgp": {\n'
    printf '    "info": %s,\n' "$(json_kv_from_lines "${OPGP_INFO:-}")"
    printf '    "gpg_card_status": %s,\n' "$(json_str "${GPG_CARD:-}")"
    printf '    "public_keys": ['
    if [[ -n "$GPG_PUBKEYS" ]]; then
        printf '%s' "${GPG_PUBKEYS%,}"
    fi
    printf ']\n'
    printf '  },\n'

    printf '  "ykman_info_raw": %s\n' "$(json_str "$YK_INFO")"

    printf '}\n'
} > "$OUTPUT"

chmod 600 "$OUTPUT"

log "Backup saved: ${OUTPUT}"
echo "  Size: $(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT") bytes"
echo ""
warn "This file contains device metadata — store it securely."
warn "Secrets (HMAC keys, PIV private keys, FIDO2 credentials) cannot be exported"
warn "and remain inside the YubiKey hardware."
