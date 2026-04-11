#!/usr/bin/env bash
# yk-verify-file.sh — Verify integrity of an encrypted file without decrypting to disk
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

pass() { echo -e "  ${GREEN}✔${NC} $*"; }
fail() { echo -e "  ${RED}✘${NC} $*"; }

CONFIG_DIR="${HOME}/.config/yk-toolkit/age"
IDENTITY_FILE="${CONFIG_DIR}/yubikey-identity.txt"

usage() {
    echo "Usage: $(basename "$0") [-i IDENTITY] FILE"
    echo ""
    echo "Verify that an encrypted file can be decrypted — without writing the output."
    echo "Auto-detects HMAC (.yk.enc) and age (.age) encrypted files."
    echo ""
    echo "Options:"
    echo "  -i IDENTITY    age identity file (only for .age files)."
    echo "                 Default: YubiKey identity from setup."
    echo "  -h             Show this help."
    exit 1
}

IDENTITY=""

while getopts ":i:h" opt; do
    case "$opt" in
        i) IDENTITY="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { err "No input file specified."; usage; }
[[ -f "$INPUT" ]] || { err "File not found: ${INPUT}"; exit 1; }

INPUT=$(realpath "$INPUT")

FAIL=0

verify_hmac() {
    local enc_file="$1"
    local challenge_file="${enc_file%.enc}.challenge"
    local slot=2

    info "Mode: HMAC-SHA1 challenge-response"
    info "Encrypted file: ${enc_file}"
    echo ""

    if [[ -f "$challenge_file" ]]; then
        pass "Challenge file found: ${challenge_file}"
    else
        fail "Challenge file not found: ${challenge_file}"
        ((FAIL++)) || true
        return
    fi

    command -v ykman &>/dev/null || {
        fail "ykman not found"
        ((FAIL++)) || true
        return
    }
    pass "ykman found: $(command -v ykman)"

    command -v openssl &>/dev/null || {
        fail "openssl not found"
        ((FAIL++)) || true
        return
    }
    pass "openssl found: $(command -v openssl)"

    local challenge
    challenge=$(cat "$challenge_file")

    info "Sending challenge to YubiKey (slot ${slot})..."
    local hmac
    hmac=$(ykman otp calculate "$slot" "$challenge" 2>/dev/null) || {
        fail "YubiKey did not respond. Is it inserted and configured?"
        ((FAIL++)) || true
        return
    }
    pass "YubiKey responded with HMAC"

    local key
    key=$(echo -n "${challenge}${hmac}" | openssl dgst -sha256 -binary | xxd -p -c 256)

    info "Testing decryption (output discarded)..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
        -k "$key" \
        -in "$enc_file" > /dev/null 2>&1; then
        pass "Decryption succeeded"
    else
        fail "Decryption failed — wrong key, corrupted file, or mismatched challenge"
        ((FAIL++)) || true
    fi
}

verify_age() {
    local age_file="$1"

    info "Mode: age + YubiKey PIV"
    info "Encrypted file: ${age_file}"
    echo ""

    command -v age &>/dev/null || {
        fail "age not found. Install it or run yk-age-setup.sh."
        ((FAIL++)) || true
        return
    }
    pass "age found: $(command -v age)"

    command -v age-plugin-yubikey &>/dev/null || {
        fail "age-plugin-yubikey not found. Run yk-age-setup.sh."
        ((FAIL++)) || true
        return
    }
    pass "age-plugin-yubikey found: $(command -v age-plugin-yubikey)"

    if [[ -z "$IDENTITY" ]]; then
        if [[ -f "$IDENTITY_FILE" ]]; then
            IDENTITY="$IDENTITY_FILE"
            pass "Identity file found: ${IDENTITY_FILE}"
        else
            fail "No identity file found. Run yk-age-setup.sh first or pass -i."
            ((FAIL++)) || true
            return
        fi
    else
        if [[ -f "$IDENTITY" ]]; then
            pass "Identity file found: ${IDENTITY}"
        else
            fail "Identity file not found: ${IDENTITY}"
            ((FAIL++)) || true
            return
        fi
    fi

    info "Testing decryption (output discarded)..."
    info "Touch YubiKey if it blinks. PIN may be required."
    echo ""
    if age -d -i "$IDENTITY" -o /dev/null "$age_file" 2>/dev/null; then
        pass "Decryption succeeded"
    else
        fail "Decryption failed — wrong identity, corrupted file, or YubiKey mismatch"
        ((FAIL++)) || true
    fi
}

echo ""
echo -e "${CYAN}━━━ Verify Encrypted File ━━━${NC}"
echo ""

if [[ "$INPUT" == *.yk.enc ]]; then
    verify_hmac "$INPUT"
elif [[ "$INPUT" == *.age ]]; then
    verify_age "$INPUT"
else
    err "Unrecognized file type. Expected .yk.enc (HMAC) or .age (age)."
    err "Usage: $(basename "$0") <file.yk.enc|file.age>"
    exit 1
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    log "All checks passed. File is valid and decryptable."
else
    err "${FAIL} check(s) failed."
fi

exit "$FAIL"
