#!/usr/bin/env bash
# yk-info.sh — Comprehensive YubiKey device report (probe/inspect/report)
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
sub()    { echo -e "  ${BOLD}$1${NC}"; }
na()     { echo -e "  ${YELLOW}(not available)${NC}"; }

# --- Timeout wrapper ---
yk_cmd() { timeout 5 "$@" 2>/dev/null || true; }

# --- Require at least ykman ---
command -v ykman &>/dev/null || {
    echo -e "${RED}[!] ykman not found. Install yubikey-manager first.${NC}" >&2
    exit 1
}

# --- Check YubiKey presence ---
YK_LIST=$(yk_cmd ykman list)
[[ -n "$YK_LIST" ]] || {
    echo -e "${RED}[!] No YubiKey detected. Is it plugged in?${NC}" >&2
    exit 1
}

echo -e "${CYAN}${BOLD}yk-info.sh — YubiKey Device Report${NC}"
echo -e "${CYAN}Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"

# --- 1. USB bus ---
header "USB Device"
if command -v lsusb &>/dev/null; then
    LSUSB=$(yk_cmd lsusb | grep -i "1050:" || true)
    if [[ -n "$LSUSB" ]]; then
        echo "$LSUSB" | while IFS= read -r line; do
            sub "$line"
        done

        # Detailed USB descriptor
        BUS_DEV=$(echo "$LSUSB" | head -1 | grep -oP 'Bus \K\d+')
        DEV_NUM=$(echo "$LSUSB" | head -1 | grep -oP 'Device \K\d+')
        if [[ -n "$BUS_DEV" && -n "$DEV_NUM" ]]; then
            DEVPATH="/dev/bus/usb/${BUS_DEV}/$(printf '%03d' "$((10#$DEV_NUM))")"
            sub "Device node: ${DEVPATH}"
        fi

        if command -v lsusb &>/dev/null; then
            VENDOR_ID=$(echo "$LSUSB" | head -1 | grep -oP 'ID \K[0-9a-f:]+')
            if [[ -n "$VENDOR_ID" ]]; then
                echo ""
                sub "lsusb -v (filtered):"
                yk_cmd lsusb -d "$VENDOR_ID" -v 2>/dev/null | grep -iE "idVendor|idProduct|bcdDevice|iManufacturer|iProduct|iSerial|bNumConfigurations|MaxPower" | while IFS= read -r line; do
                    echo "    $line"
                done
            fi
        fi
    else
        na
    fi
else
    na
fi

# --- 2. sysfs device info ---
header "sysfs / udev"
YK_SYSPATH=$(find /sys/bus/usb/devices/ -maxdepth 2 -name "idVendor" -exec grep -l "1050" {} \; 2>/dev/null | head -1 || true)
if [[ -n "$YK_SYSPATH" ]]; then
    YK_DIR=$(dirname "$YK_SYSPATH")
    for attr in idVendor idProduct manufacturer product serial; do
        VAL=$(cat "${YK_DIR}/${attr}" 2>/dev/null || echo "n/a")
        printf "  %-14s %s\n" "${attr}:" "$VAL"
    done

    if command -v udevadm &>/dev/null; then
        DEVNAME=$(udevadm info --query=name --path="$YK_DIR" 2>/dev/null || true)
        [[ -n "$DEVNAME" ]] && sub "udev devname: /dev/${DEVNAME}"

        echo ""
        sub "udev properties (filtered):"
        udevadm info --query=property --path="$YK_DIR" 2>/dev/null | grep -iE "ID_VENDOR|ID_MODEL|ID_SERIAL|ID_USB|DEVNAME|ID_TYPE|DRIVER" | while IFS= read -r line; do
            echo "    $line"
        done
    fi
else
    na
fi

# --- 3. ykman info ---
header "ykman info"
YK_INFO=$(yk_cmd ykman info)
if [[ -n "$YK_INFO" ]]; then
    echo "$YK_INFO" | while IFS= read -r line; do
        echo "  $line"
    done
else
    na
fi

# --- 4. ykman config ---
header "ykman config (USB/NFC interfaces)"
USB_CFG=$(yk_cmd ykman config usb --list 2>/dev/null || true)
NFC_CFG=$(yk_cmd ykman config nfc --list 2>/dev/null || true)

if [[ -n "$USB_CFG" ]]; then
    sub "USB enabled:"
    echo "$USB_CFG" | while IFS= read -r line; do echo "    $line"; done
fi
if [[ -n "$NFC_CFG" ]]; then
    sub "NFC enabled:"
    echo "$NFC_CFG" | while IFS= read -r line; do echo "    $line"; done
fi
[[ -z "$USB_CFG" && -z "$NFC_CFG" ]] && na

# --- 5. OTP slots ---
header "OTP Slots"
OTP_INFO=$(yk_cmd ykman otp info)
if [[ -n "$OTP_INFO" ]]; then
    echo "$OTP_INFO" | while IFS= read -r line; do
        echo "  $line"
    done
else
    na
fi

# --- 6. FIDO2 ---
header "FIDO2"
FIDO_INFO=$(yk_cmd ykman fido info)
if [[ -n "$FIDO_INFO" ]]; then
    echo "$FIDO_INFO" | while IFS= read -r line; do
        echo "  $line"
    done

    sub "FIDO2 credentials:"
    FIDO_CREDS=$(yk_cmd ykman fido credentials list 2>/dev/null || echo "(PIN required or none)")
    echo "    $FIDO_CREDS"
else
    na
fi

# --- 7. PIV ---
header "PIV"
PIV_INFO=$(yk_cmd ykman piv info)
if [[ -n "$PIV_INFO" ]]; then
    echo "$PIV_INFO" | while IFS= read -r line; do
        echo "  $line"
    done
else
    na
fi

# --- 8. OATH ---
header "OATH Accounts"
OATH_LIST=$(yk_cmd ykman oath accounts list 2>/dev/null || true)
if [[ -n "$OATH_LIST" ]]; then
    OATH_COUNT=$(echo "$OATH_LIST" | wc -l)
    sub "${OATH_COUNT} account(s) configured"
    echo "$OATH_LIST" | while IFS= read -r line; do
        echo "    $line"
    done
else
    echo "  (none or password-protected)"
fi

# --- 9. OpenPGP ---
header "OpenPGP"
OPGP_INFO=$(yk_cmd ykman openpgp info)
if [[ -n "$OPGP_INFO" ]]; then
    echo "$OPGP_INFO" | while IFS= read -r line; do
        echo "  $line"
    done
else
    na
fi

# GPG card status (if gpg available)
if command -v gpg &>/dev/null; then
    echo ""
    sub "gpg --card-status:"
    GPG_CARD=$(yk_cmd gpg --card-status 2>/dev/null || true)
    if [[ -n "$GPG_CARD" ]]; then
        echo "$GPG_CARD" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo "    (no OpenPGP card detected or gpg-agent not running)"
    fi
fi

# --- 10. pcsc_scan snapshot ---
header "PC/SC Smart Card"
if command -v pcsc_scan &>/dev/null; then
    sub "pcsc_scan (1s snapshot):"
    PCSC=$(timeout 1 pcsc_scan 2>/dev/null || true)
    if [[ -n "$PCSC" ]]; then
        echo "$PCSC" | head -20 | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo "    (no response — pcscd running?)"
    fi
else
    echo "  pcsc_scan not installed (optional)"
fi

# --- 11. SSH keys (FIDO2 resident) ---
header "SSH FIDO2 Resident Keys"
if command -v ssh-keygen &>/dev/null; then
    SSH_KEYS=$(yk_cmd ssh-keygen -K 2>/dev/null || true)
    if [[ -n "$SSH_KEYS" ]]; then
        echo "$SSH_KEYS" | while IFS= read -r line; do
            echo "  $line"
        done
    else
        echo "  (none found or not supported)"
    fi
else
    echo "  ssh-keygen not available"
fi

# --- Footer ---
echo ""
echo -e "${CYAN}━━━ End of report ━━━${NC}"
