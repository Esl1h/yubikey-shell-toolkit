#!/usr/bin/env bash
# yk-validate.sh — Post-install validator for YubiKey environment
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)) || true; }
skip() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)) || true; }
header() { echo -e "\n${CYAN}[$1]${NC}"; }

# --- Timeout wrapper ---
yk_cmd() { timeout 5 "$@" 2>/dev/null || true; }

# --- 1. Required binaries ---
check_binaries() {
    header "Required binaries"

    local -a REQUIRED=(ykman openssl xxd)
    local -a OPTIONAL=(gpg ssh-keygen pcsc_scan lsusb)

    for bin in "${REQUIRED[@]}"; do
        if command -v "$bin" &>/dev/null; then
            pass "$bin found: $(command -v "$bin")"
        else
            fail "$bin NOT found — install the corresponding package"
        fi
    done

    for bin in "${OPTIONAL[@]}"; do
        if command -v "$bin" &>/dev/null; then
            pass "$bin found (optional): $(command -v "$bin")"
        else
            skip "$bin not found (optional)"
        fi
    done
}

# --- 2. pcscd service ---
check_pcscd() {
    header "pcscd service"

    if systemctl is-enabled pcscd.socket &>/dev/null || \
       systemctl is-enabled pcscd.service &>/dev/null; then
        pass "pcscd is enabled"
    else
        fail "pcscd is NOT enabled — run: sudo systemctl enable pcscd.socket"
    fi

    if systemctl is-active pcscd.socket &>/dev/null || \
       systemctl is-active pcscd.service &>/dev/null; then
        pass "pcscd is running"
    else
        fail "pcscd is NOT running — run: sudo systemctl start pcscd.socket"
    fi
}

# --- 3. udev rules ---
check_udev() {
    header "udev rules"

    local RULES_FILE="/etc/udev/rules.d/70-yubikey.rules"

    if [[ -f "$RULES_FILE" ]]; then
        pass "udev rules found: ${RULES_FILE}"
        if grep -q "1050" "$RULES_FILE"; then
            pass "Rules contain Yubico vendor ID (1050)"
        else
            fail "Rules file exists but missing vendor ID 1050"
        fi
    else
        fail "udev rules NOT found — expected: ${RULES_FILE}"
    fi
}

# --- 4. USB detection ---
check_usb() {
    header "USB device detection"

    if ! command -v lsusb &>/dev/null; then
        skip "lsusb not available — install usbutils"
        return
    fi

    local YK_USB
    YK_USB=$(yk_cmd lsusb | grep -i "1050:" || true)

    if [[ -n "$YK_USB" ]]; then
        pass "YubiKey detected on USB bus:"
        echo "       ${YK_USB}"
    else
        fail "No YubiKey detected on USB — is it plugged in?"
    fi
}

# --- 5. ykman detection ---
check_ykman() {
    header "ykman device detection"

    if ! command -v ykman &>/dev/null; then
        fail "ykman not installed — cannot proceed with device checks"
        return
    fi

    local YK_LIST
    YK_LIST=$(yk_cmd ykman list)

    if [[ -z "$YK_LIST" ]]; then
        fail "ykman list returned no devices"
        return
    fi

    pass "ykman detected device(s):"
    echo "$YK_LIST" | while IFS= read -r line; do
        echo "       ${line}"
    done

    local YK_INFO
    YK_INFO=$(yk_cmd ykman info)

    if [[ -n "$YK_INFO" ]]; then
        pass "ykman info:"

        local SERIAL FW FORM
        SERIAL=$(echo "$YK_INFO" | grep -i "serial"      | head -1 || true)
        FW=$(echo "$YK_INFO"     | grep -i "firmware"     | head -1 || true)
        FORM=$(echo "$YK_INFO"   | grep -i "form factor"  | head -1 || true)

        [[ -n "$SERIAL" ]] && echo "       ${SERIAL}"
        [[ -n "$FW" ]]     && echo "       ${FW}"
        [[ -n "$FORM" ]]   && echo "       ${FORM}"
    else
        fail "ykman info returned no data"
    fi
}

# --- 6. Interface capabilities ---
check_interfaces() {
    header "Interface capabilities"

    if ! command -v ykman &>/dev/null; then
        fail "ykman not available — skipping"
        return
    fi

    local YK_INFO
    YK_INFO=$(yk_cmd ykman info)
    [[ -z "$YK_INFO" ]] && { fail "No device info available"; return; }

    local -a INTERFACES=(OTP FIDO2 U2F OATH PIV OpenPGP)

    for iface in "${INTERFACES[@]}"; do
        if echo "$YK_INFO" | grep -qi "$iface"; then
            pass "${iface} supported"
        else
            skip "${iface} not reported (may not be available on this model)"
        fi
    done
}

# --- 7. OTP slots (challenge-response) ---
check_otp_slots() {
    header "OTP slot status"

    if ! command -v ykman &>/dev/null; then
        fail "ykman not available — skipping"
        return
    fi

    local OTP_INFO
    OTP_INFO=$(yk_cmd ykman otp info)

    if [[ -z "$OTP_INFO" ]]; then
        fail "Could not read OTP slot info"
        return
    fi

    echo "$OTP_INFO" | while IFS= read -r line; do
        echo "       ${line}"
    done

    if echo "$OTP_INFO" | grep -qi "Slot 2.*challenge-response\|Slot 2.*HMAC"; then
        pass "Slot 2 configured for challenge-response"
    elif echo "$OTP_INFO" | grep -qi "Slot 2.*empty"; then
        fail "Slot 2 is empty — configure with: ykman otp chalresp --touch 2 \$(openssl rand -hex 20)"
    else
        skip "Slot 2 has a configuration but may not be challenge-response"
    fi
}

# --- 8. Challenge-response live test ---
check_chalresp() {
    header "Challenge-response live test"

    if ! command -v ykman &>/dev/null; then
        fail "ykman not available — skipping"
        return
    fi

    local TEST_CHAL RESULT
    TEST_CHAL=$(openssl rand -hex 32)

    echo -e "  ${CYAN}…${NC} Sending challenge (touch YubiKey if it blinks)..."

    RESULT=$(yk_cmd ykman otp calculate 2 "$TEST_CHAL")

    if [[ -n "$RESULT" ]]; then
        pass "Challenge-response OK — HMAC returned (${#RESULT} chars)"
    else
        fail "Challenge-response FAILED — slot 2 not configured or YubiKey not responding"
    fi
}

# --- 9. FIDO2 PIN status ---
check_fido2() {
    header "FIDO2 status"

    if ! command -v ykman &>/dev/null; then
        fail "ykman not available — skipping"
        return
    fi

    local FIDO_INFO
    FIDO_INFO=$(yk_cmd ykman fido info)

    if [[ -z "$FIDO_INFO" ]]; then
        skip "FIDO2 info not available (may not be supported on this model)"
        return
    fi

    pass "FIDO2 info retrieved:"
    echo "$FIDO_INFO" | while IFS= read -r line; do
        echo "       ${line}"
    done

    if echo "$FIDO_INFO" | grep -qiP "PIN.*set|PIN.*true|PIN.*\d+\s*attempt"; then
        pass "FIDO2 PIN is set"
    else
        skip "FIDO2 PIN not set — recommended: ykman fido access change-pin"
    fi
}

# --- 10. File permissions (u2f_keys) ---
check_u2f_keys() {
    header "PAM U2F credentials"

    local CALLING_USER="${SUDO_USER:-$USER}"
    local U2F_KEYS="/home/${CALLING_USER}/.config/Yubico/u2f_keys"

    if [[ -f "$U2F_KEYS" ]]; then
        pass "u2f_keys found: ${U2F_KEYS}"

        local PERMS OWNER
        PERMS=$(stat -c "%a" "$U2F_KEYS")
        OWNER=$(stat -c "%U" "$U2F_KEYS")

        if [[ "$OWNER" == "$CALLING_USER" ]]; then
            pass "Owner: ${OWNER}"
        else
            fail "Owner is ${OWNER}, expected ${CALLING_USER}"
        fi

        if [[ "$PERMS" == "600" || "$PERMS" == "644" ]]; then
            pass "Permissions: ${PERMS}"
        else
            skip "Permissions: ${PERMS} — recommended: 600"
        fi
    else
        skip "u2f_keys not found at ${U2F_KEYS} — FIDO2 PAM not configured"
    fi
}

# --- Summary ---
summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e " Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${WARN} warnings${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"

    if (( FAIL == 0 )); then
        echo -e " ${GREEN}All checks passed. YubiKey environment is operational.${NC}"
    else
        echo -e " ${RED}${FAIL} check(s) failed. Review the output above.${NC}"
    fi
    echo ""

    exit "$FAIL"
}

# --- Main ---
main() {
    echo -e "${CYAN}yk-validate.sh — YubiKey post-install validator${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"

    check_binaries
    check_pcscd
    check_udev
    check_usb
    check_ykman
    check_interfaces
    check_otp_slots
    check_chalresp
    check_fido2
    check_u2f_keys
    summary
}

main "$@"
