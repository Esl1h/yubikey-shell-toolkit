#!/usr/bin/env bash
# yk-encrypt.sh — Encrypt file using YubiKey as key factor
set -euo pipefail

INPUT="${1:?Usage: $0 <file>}"
FILE="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
SLOT=2

# Generate random challenge and save alongside the encrypted file
CHALLENGE=$(openssl rand -hex 32)
echo "[*] Sending challenge to YubiKey (slot $SLOT)..."

# ykchalresp returns the HMAC in hex
HMAC=$(ykman otp calculate 2 "$CHALLENGE" 2>/dev/null) || {
    echo "[!] YubiKey did not respond. Is it inserted and configured?" >&2
    exit 1
}

# Derive AES-256 key via PBKDF2 (challenge + HMAC as key material)
KEY=$(echo -n "${CHALLENGE}${HMAC}" | openssl dgst -sha256 -binary | xxd -p -c 256)

# Encrypt with AES-256-CBC
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 \
    -k "$KEY" \
    -in "$FILE" \
    -out "${FILE}.yk.enc"

# Save the challenge (without the HMAC — without the physical key, it won't open)
echo "$CHALLENGE" > "${FILE}.yk.challenge"

echo "[+] Encrypted file: ${FILE}.yk.enc"
echo "[+] Challenge saved: ${FILE}.yk.challenge"
echo "[!] Without the YubiKey, the file cannot be decrypted."
