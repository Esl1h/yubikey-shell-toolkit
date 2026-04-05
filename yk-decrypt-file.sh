#!/usr/bin/env bash
# yk-decrypt-file.sh — Decrypt file using YubiKey challenge-response (slot 2)
set -euo pipefail

INPUT="${1:?Usage: $0 <file.yk.enc>}"
ENC_FILE="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
CHALLENGE_FILE="${ENC_FILE%.enc}.challenge"
OUTPUT="${ENC_FILE%.yk.enc}"
SLOT=2

# Validate input files
[[ -f "$ENC_FILE" ]] || { echo "[!] Encrypted file not found: ${ENC_FILE}" >&2; exit 1; }
[[ -f "$CHALLENGE_FILE" ]] || { echo "[!] Challenge file not found: ${CHALLENGE_FILE}" >&2; exit 1; }

# Prevent overwriting the original file
if [[ -f "$OUTPUT" ]]; then
    echo "[!] Output file already exists: ${OUTPUT}" >&2
    read -rp "[?] Overwrite? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "[*] Aborted."; exit 0; }
fi

CHALLENGE=$(cat "$CHALLENGE_FILE")
echo "[*] Sending challenge to YubiKey (slot ${SLOT})..."

HMAC=$(ykman otp calculate "$SLOT" "$CHALLENGE" 2>/dev/null) || {
    echo "[!] YubiKey did not respond. Is it inserted and configured?" >&2
    exit 1
}

KEY=$(echo -n "${CHALLENGE}${HMAC}" | openssl dgst -sha256 -binary | xxd -p -c 256)

openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -k "$KEY" \
    -in "$ENC_FILE" \
    -out "$OUTPUT"

echo "[+] Decrypted: ${OUTPUT}"
