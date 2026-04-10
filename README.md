# YubiKey Shell Toolkit

Shell scripts for setting up, validating, and using a YubiKey as an encryption key factor.

## Scripts

| Script | Purpose |
|--------|---------|
| `install-setup.sh` | Install all required packages and configure the system for YubiKey operation |
| `install-validator.sh` | Post-install validator — checks binaries, services, udev, device detection, and slot status |
| `install-GUI.sh` | Install YubiKey GUI applications (YubiKey Manager, Yubico Authenticator, Kleopatra) |
| `yk-encrypt-file.sh` | Encrypt a file using YubiKey HMAC-SHA1 challenge-response as key material |
| `yk-decrypt-file.sh` | Decrypt a file previously encrypted with `yk-encrypt-file.sh` |
| `yk-info.sh` | Comprehensive YubiKey device report — USB, sysfs, ykman, FIDO2, PIV, OATH, OpenPGP, PC/SC, SSH |
| `yk-age-encrypt.sh` | Encrypt a file using age + YubiKey PIV (age-plugin-yubikey) |
| `yk-age-decrypt.sh` | Decrypt a file using age + YubiKey PIV (age-plugin-yubikey) |

---

## Requirements

- YubiKey 5 (USB-A/USB-C/NFC), YubiKey 5 Nano/Ci, Bio, Security Key, or YubiKey 4
- Linux with `pacman`, `dnf`, `apt`, or `zypper`
- Root/sudo access for setup and validation

---

## 1. Setup — `install-setup.sh`

Installs all required packages, enables `pcscd`, and writes udev rules. Detects the package manager automatically and prompts for the YubiKey model to install only the relevant packages.

```bash
sudo ./install-setup.sh
```

**What it installs (varies by model and distro):**

- `yubikey-manager` (ykman)
- `pcsc-tools`, `ccid`/`pcsc-lite-ccid`, `opensc`
- `libfido2`, `pam-u2f` (FIDO2-capable models)
- `yubico-piv-tool` (PIV-capable models)

**What it configures:**

- Enables `pcscd.socket` (PC/SC Smart Card Daemon)
- Writes `/etc/udev/rules.d/70-yubikey.rules` with `TAG+="uaccess"` for session-based device access

> **Note:** The script does **not** program OTP slots, register FIDO2 credentials, or modify PAM. Those are manual steps (see below).

---

## 2. Configuring Slot 2 (Challenge-Response)

After running `install-setup.sh`, slot 2 must be programmed manually for HMAC-SHA1 challenge-response. This is required for `yk-encrypt-file.sh` to work.

### Program slot 2

```bash
ykman otp chalresp --touch --force 2 "$(openssl rand -hex 20)"
```

- `--touch` — requires physical touch on the YubiKey for each challenge (recommended)
- `--force` — overwrites slot 2 without confirmation prompt
- `openssl rand -hex 20` — generates a 160-bit secret (maximum for HMAC-SHA1)

### Verify slot status

```bash
ykman otp info
```

Expected output:

```
Slot 1: programmed
Slot 2: programmed
```

### Test challenge-response

```bash
ykman otp calculate 2 "$(openssl rand -hex 32)"
```

If it returns a hex HMAC, the slot is operational.

> **Why 20 bytes for the secret?** HMAC-SHA1 uses a 160-bit key. The YubiKey firmware truncates anything beyond 20 bytes. This is the maximum, not a compromise.

---

## 3. Validation — `install-validator.sh`

Post-install validator that checks 10 aspects of the YubiKey environment. Run after `install-setup.sh` and slot configuration.

```bash
sudo ./install-validator.sh
```

### Checks performed

| # | Check | What it validates |
|---|-------|-------------------|
| 1 | Required binaries | `ykman`, `openssl`, `xxd` present; `gpg`, `ssh-keygen`, `pcsc_scan`, `lsusb` optional |
| 2 | pcscd service | Enabled and running (`pcscd.socket` or `pcscd.service`) |
| 3 | udev rules | `/etc/udev/rules.d/70-yubikey.rules` exists and contains vendor ID `1050` |
| 4 | USB detection | YubiKey visible via `lsusb` (vendor `1050`) |
| 5 | ykman detection | `ykman list` and `ykman info` return device data (serial, firmware, form factor) |
| 6 | Interface capabilities | Reports supported interfaces: OTP, FIDO2, U2F, OATH, PIV, OpenPGP |
| 7 | OTP slot status | Checks if slot 2 is configured for challenge-response |
| 8 | Challenge-response test | Sends a random challenge and verifies HMAC response |
| 9 | FIDO2 status | Retrieves FIDO2 info and checks if PIN is set |
| 10 | PAM U2F credentials | Checks `~/.config/Yubico/u2f_keys` existence, owner, and permissions |

### Output

Each check reports `PASS`, `FAIL`, or `WARNING`. The exit code equals the number of failures — useful for scripting.

All device calls use a 5-second timeout to prevent hangs if `pcscd` or the YubiKey is unresponsive.

---

## 4. GUI Applications — `install-GUI.sh`

Interactive installer for YubiKey graphical tools. Detects already-installed applications and offers native package or Flatpak fallback.

```bash
sudo ./install-GUI.sh
```

### Available applications

| Application | Description |
|-------------|-------------|
| YubiKey Manager GUI | Manage OTP, FIDO2, PIV, OATH, and interfaces |
| Yubico Authenticator | TOTP/HOTP with secrets stored on YubiKey |
| Kleopatra | GPG/X.509 certificate manager (OpenPGP smartcard) |

The script shows installation status for each app and allows installing individually or all at once. If a native package is unavailable, it attempts Flatpak from Flathub.

---

## 5. File Encryption — `yk-encrypt-file.sh`

Encrypts a file using the YubiKey as a key factor via HMAC-SHA1 challenge-response on slot 2.

```bash
./yk-encrypt-file.sh <file>
```

### How it works

1. Generates a random 256-bit challenge
2. Sends the challenge to YubiKey slot 2 — receives HMAC response
3. Derives an AES-256 key: `SHA-256(challenge + HMAC)`
4. Encrypts the file with `openssl enc -aes-256-cbc -pbkdf2 -iter 600000`
5. Saves the challenge to `<file>.yk.challenge`

### Output files

| File | Contents |
|------|----------|
| `<file>.yk.enc` | Encrypted file |
| `<file>.yk.challenge` | Random challenge (needed for decryption) |

---

## 6. File Decryption — `yk-decrypt-file.sh`

Decrypts a file previously encrypted with `yk-encrypt-file.sh`.

```bash
./yk-decrypt-file.sh <file.yk.enc>
```

### How it works

1. Reads the challenge from `<file>.yk.challenge`
2. Sends the challenge to YubiKey slot 2 — recovers the same HMAC
3. Derives the same AES-256 key: `SHA-256(challenge + HMAC)`
4. Decrypts the file with `openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000`
5. Writes the decrypted output to the original filename

The script prompts before overwriting an existing file.

> **Without the physical YubiKey, the file cannot be decrypted.** The challenge alone is not sufficient — the HMAC secret never leaves the hardware.

---

## 7. Device Report — `yk-info.sh`

Generates a comprehensive report of the connected YubiKey, probing USB, sysfs, and all ykman subsystems. Does not require root.

```bash
./yk-info.sh
```

### Sections reported

| # | Section | What it probes |
|---|---------|----------------|
| 1 | USB Device | `lsusb` detection, vendor/product ID, USB descriptor details (MaxPower, iSerial, etc.) |
| 2 | sysfs / udev | Kernel device attributes (`idVendor`, `idProduct`, `manufacturer`, `serial`) and udev properties |
| 3 | ykman info | Device type, serial number, firmware version, form factor, enabled interfaces |
| 4 | ykman config | USB and NFC enabled interfaces list |
| 5 | OTP Slots | Slot 1 and Slot 2 programming status |
| 6 | FIDO2 | FIDO2 info and resident credentials |
| 7 | PIV | PIV applet information |
| 8 | OATH | Number of configured OATH/TOTP accounts |
| 9 | OpenPGP | OpenPGP applet info and `gpg --card-status` (if gpg is available) |
| 10 | PC/SC Smart Card | 1-second `pcsc_scan` snapshot |
| 11 | SSH FIDO2 Resident Keys | Discoverable SSH keys stored on the YubiKey |

All device calls use a 5-second timeout. The script requires only `ykman`; all other tools are optional and gracefully skipped if absent.

---

## 8. Age Encryption (PIV) — `yk-age-encrypt.sh`

Encrypts a file using [age](https://age-encryption.org/) with the YubiKey PIV slot as the recipient, via `age-plugin-yubikey`.

```bash
./yk-age-encrypt.sh <file>
./yk-age-encrypt.sh -r <recipient> -o output.age <file>
```

### Options

| Flag | Description |
|------|-------------|
| `-r` | age recipient (public key or file). Default: reads from `~/.config/yk-toolkit/age/yubikey-recipient.txt` or queries the YubiKey live |
| `-o` | Output file. Default: `<file>.age` |

The script validates the recipient, prompts before overwriting, and cleans up on failure.

---

## 9. Age Decryption (PIV) — `yk-age-decrypt.sh`

Decrypts a file previously encrypted with `yk-age-encrypt.sh`, using the YubiKey PIV identity via `age-plugin-yubikey`.

```bash
./yk-age-decrypt.sh <file.age>
./yk-age-decrypt.sh -i <identity-file> -o output.txt <file.age>
```

### Options

| Flag | Description |
|------|-------------|
| `-i` | age identity file. Default: `~/.config/yk-toolkit/age/yubikey-identity.txt` |
| `-o` | Output file. Default: input filename without `.age` extension |

Requires `age` and `age-plugin-yubikey`. The YubiKey PIN and/or physical touch may be required during decryption.

---

## Security Notes

- The HMAC-SHA1 secret is generated and stored inside the YubiKey — it cannot be extracted
- The challenge is public; the HMAC is the secret component derived at runtime
- `--touch` on slot 2 ensures physical presence for every operation
- The encryption key is never stored on disk
- AES-256-CBC with PBKDF2 (600,000 iterations) provides the symmetric encryption layer

## License

MIT

---

# YubiKey Shell Toolkit (Portugues)

Scripts shell para configurar, validar e utilizar uma YubiKey como fator de chave de criptografia.

Estes scripts sao material de referencia para a serie de posts sobre YubiKey publicada no blog: **[https://esli.blog.br/tag/yubikey](https://esli.blog.br/tag/yubikey)**

## Scripts

| Script | Finalidade |
|--------|------------|
| `install-setup.sh` | Instala todos os pacotes necessarios e configura o sistema para operacao com YubiKey |
| `install-validator.sh` | Validador pos-instalacao — verifica binarios, servicos, udev, deteccao do dispositivo e status dos slots |
| `install-GUI.sh` | Instala aplicativos graficos para YubiKey (YubiKey Manager, Yubico Authenticator, Kleopatra) |
| `yk-encrypt-file.sh` | Criptografa um arquivo usando HMAC-SHA1 challenge-response da YubiKey como material de chave |
| `yk-decrypt-file.sh` | Descriptografa um arquivo previamente criptografado com `yk-encrypt-file.sh` |
| `yk-info.sh` | Relatorio completo do dispositivo YubiKey — USB, sysfs, ykman, FIDO2, PIV, OATH, OpenPGP, PC/SC, SSH |
| `yk-age-encrypt.sh` | Criptografa um arquivo usando age + YubiKey PIV (age-plugin-yubikey) |
| `yk-age-decrypt.sh` | Descriptografa um arquivo usando age + YubiKey PIV (age-plugin-yubikey) |

---

## Requisitos

- YubiKey 5 (USB-A/USB-C/NFC), YubiKey 5 Nano/Ci, Bio, Security Key ou YubiKey 4
- Linux com `pacman`, `dnf`, `apt` ou `zypper`
- Acesso root/sudo para instalacao e validacao

---

## 1. Instalacao — `install-setup.sh`

Instala todos os pacotes necessarios, habilita o `pcscd` e grava regras udev. Detecta o gerenciador de pacotes automaticamente e solicita o modelo da YubiKey para instalar apenas os pacotes relevantes.

```bash
sudo ./install-setup.sh
```

**O que instala (varia por modelo e distro):**

- `yubikey-manager` (ykman)
- `pcsc-tools`, `ccid`/`pcsc-lite-ccid`, `opensc`
- `libfido2`, `pam-u2f` (modelos com FIDO2)
- `yubico-piv-tool` (modelos com PIV)

**O que configura:**

- Habilita `pcscd.socket` (PC/SC Smart Card Daemon)
- Grava `/etc/udev/rules.d/70-yubikey.rules` com `TAG+="uaccess"` para acesso baseado em sessao

> **Nota:** O script **nao** programa slots OTP, registra credenciais FIDO2 nem modifica PAM. Essas sao etapas manuais (veja abaixo).

---

## 2. Configurando o Slot 2 (Challenge-Response)

Apos executar `install-setup.sh`, o slot 2 deve ser programado manualmente para HMAC-SHA1 challenge-response. Isso e necessario para o funcionamento do `yk-encrypt-file.sh`.

### Programar o slot 2

```bash
ykman otp chalresp --touch --force 2 "$(openssl rand -hex 20)"
```

- `--touch` — exige toque fisico na YubiKey a cada desafio (recomendado)
- `--force` — sobrescreve o slot 2 sem solicitar confirmacao
- `openssl rand -hex 20` — gera um segredo de 160 bits (maximo para HMAC-SHA1)

### Verificar status dos slots

```bash
ykman otp info
```

Saida esperada:

```
Slot 1: programmed
Slot 2: programmed
```

### Testar challenge-response

```bash
ykman otp calculate 2 "$(openssl rand -hex 32)"
```

Se retornar um HMAC em hexadecimal, o slot esta operacional.

> **Por que 20 bytes para o segredo?** O HMAC-SHA1 utiliza uma chave de 160 bits. O firmware da YubiKey trunca qualquer valor alem de 20 bytes. Este e o maximo, nao um compromisso.

---

## 3. Validacao — `install-validator.sh`

Validador pos-instalacao que verifica 10 aspectos do ambiente YubiKey. Execute apos `install-setup.sh` e a configuracao do slot.

```bash
sudo ./install-validator.sh
```

### Verificacoes realizadas

| # | Verificacao | O que valida |
|---|-------------|--------------|
| 1 | Binarios obrigatorios | `ykman`, `openssl`, `xxd` presentes; `gpg`, `ssh-keygen`, `pcsc_scan`, `lsusb` opcionais |
| 2 | Servico pcscd | Habilitado e em execucao (`pcscd.socket` ou `pcscd.service`) |
| 3 | Regras udev | `/etc/udev/rules.d/70-yubikey.rules` existe e contem vendor ID `1050` |
| 4 | Deteccao USB | YubiKey visivel via `lsusb` (vendor `1050`) |
| 5 | Deteccao ykman | `ykman list` e `ykman info` retornam dados do dispositivo (serial, firmware, form factor) |
| 6 | Capacidades de interface | Reporta interfaces suportadas: OTP, FIDO2, U2F, OATH, PIV, OpenPGP |
| 7 | Status dos slots OTP | Verifica se o slot 2 esta configurado para challenge-response |
| 8 | Teste de challenge-response | Envia um desafio aleatorio e verifica a resposta HMAC |
| 9 | Status FIDO2 | Obtem informacoes FIDO2 e verifica se o PIN esta definido |
| 10 | Credenciais PAM U2F | Verifica existencia, proprietario e permissoes de `~/.config/Yubico/u2f_keys` |

### Saida

Cada verificacao reporta `PASS` (aprovado), `FAIL` (falha) ou `WARNING` (aviso). O codigo de saida e igual ao numero de falhas — util para automacao.

Todas as chamadas ao dispositivo usam timeout de 5 segundos para evitar travamentos caso o `pcscd` ou a YubiKey nao responda.

---

## 4. Aplicativos Graficos — `install-GUI.sh`

Instalador interativo para ferramentas graficas da YubiKey. Detecta aplicativos ja instalados e oferece pacote nativo ou fallback via Flatpak.

```bash
sudo ./install-GUI.sh
```

### Aplicativos disponiveis

| Aplicativo | Descricao |
|------------|-----------|
| YubiKey Manager GUI | Gerencia OTP, FIDO2, PIV, OATH e interfaces |
| Yubico Authenticator | TOTP/HOTP com segredos armazenados na YubiKey |
| Kleopatra | Gerenciador de certificados GPG/X.509 (smartcard OpenPGP) |

O script exibe o status de instalacao de cada aplicativo e permite instalar individualmente ou todos de uma vez. Se o pacote nativo nao estiver disponivel, tenta Flatpak pelo Flathub.

---

## 5. Criptografia de Arquivos — `yk-encrypt-file.sh`

Criptografa um arquivo usando a YubiKey como fator de chave via HMAC-SHA1 challenge-response no slot 2.

```bash
./yk-encrypt-file.sh <arquivo>
```

### Como funciona

1. Gera um desafio aleatorio de 256 bits
2. Envia o desafio para o slot 2 da YubiKey — recebe a resposta HMAC
3. Deriva uma chave AES-256: `SHA-256(desafio + HMAC)`
4. Criptografa o arquivo com `openssl enc -aes-256-cbc -pbkdf2 -iter 600000`
5. Salva o desafio em `<arquivo>.yk.challenge`

### Arquivos gerados

| Arquivo | Conteudo |
|---------|----------|
| `<arquivo>.yk.enc` | Arquivo criptografado |
| `<arquivo>.yk.challenge` | Desafio aleatorio (necessario para descriptografia) |

---

## 6. Descriptografia de Arquivos — `yk-decrypt-file.sh`

Descriptografa um arquivo previamente criptografado com `yk-encrypt-file.sh`.

```bash
./yk-decrypt-file.sh <arquivo.yk.enc>
```

### Como funciona

1. Le o desafio de `<arquivo>.yk.challenge`
2. Envia o desafio para o slot 2 da YubiKey — recupera o mesmo HMAC
3. Deriva a mesma chave AES-256: `SHA-256(desafio + HMAC)`
4. Descriptografa o arquivo com `openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000`
5. Grava a saida descriptografada com o nome original do arquivo

O script solicita confirmacao antes de sobrescrever um arquivo existente.

> **Sem a YubiKey fisica, o arquivo nao pode ser descriptografado.** O desafio sozinho nao e suficiente — o segredo HMAC nunca sai do hardware.

---

## 7. Relatorio do Dispositivo — `yk-info.sh`

Gera um relatorio completo da YubiKey conectada, consultando USB, sysfs e todos os subsistemas do ykman. Nao requer root.

```bash
./yk-info.sh
```

### Secoes do relatorio

| # | Secao | O que consulta |
|---|-------|----------------|
| 1 | Dispositivo USB | Deteccao via `lsusb`, vendor/product ID, detalhes do descritor USB (MaxPower, iSerial, etc.) |
| 2 | sysfs / udev | Atributos do dispositivo no kernel (`idVendor`, `idProduct`, `manufacturer`, `serial`) e propriedades udev |
| 3 | ykman info | Tipo do dispositivo, numero de serie, versao de firmware, form factor, interfaces habilitadas |
| 4 | ykman config | Lista de interfaces habilitadas via USB e NFC |
| 5 | Slots OTP | Status de programacao do Slot 1 e Slot 2 |
| 6 | FIDO2 | Informacoes FIDO2 e credenciais residentes |
| 7 | PIV | Informacoes do applet PIV |
| 8 | OATH | Quantidade de contas OATH/TOTP configuradas |
| 9 | OpenPGP | Informacoes do applet OpenPGP e `gpg --card-status` (se gpg estiver disponivel) |
| 10 | PC/SC Smart Card | Snapshot de 1 segundo do `pcsc_scan` |
| 11 | Chaves SSH FIDO2 Residentes | Chaves SSH descobriveis armazenadas na YubiKey |

Todas as chamadas ao dispositivo usam timeout de 5 segundos. O script requer apenas `ykman`; todas as outras ferramentas sao opcionais e ignoradas graciosamente se ausentes.

---

## 8. Criptografia com Age (PIV) — `yk-age-encrypt.sh`

> Leitura recomendada: [age: criptografia de arquivos simples, moderna e segura](https://esli.blog.br/age-criptografia-de-arquivos-simples-moderna-e-segura) e [Criptografia com age + YubiKey PIV](https://esli.blog.br/age-yubikey)

Criptografa um arquivo usando [age](https://age-encryption.org/) com o slot PIV da YubiKey como destinatario, via `age-plugin-yubikey`.

```bash
./yk-age-encrypt.sh <arquivo>
./yk-age-encrypt.sh -r <destinatario> -o saida.age <arquivo>
```

### Opcoes

| Flag | Descricao |
|------|-----------|
| `-r` | Destinatario age (chave publica ou arquivo). Padrao: le de `~/.config/yk-toolkit/age/yubikey-recipient.txt` ou consulta a YubiKey diretamente |
| `-o` | Arquivo de saida. Padrao: `<arquivo>.age` |

O script valida o destinatario, solicita confirmacao antes de sobrescrever e limpa em caso de falha.

---

## 9. Descriptografia com Age (PIV) — `yk-age-decrypt.sh`

Descriptografa um arquivo previamente criptografado com `yk-age-encrypt.sh`, usando a identidade PIV da YubiKey via `age-plugin-yubikey`. Veja tambem: [Criptografia com age + YubiKey PIV](https://esli.blog.br/age-yubikey)

```bash
./yk-age-decrypt.sh <arquivo.age>
./yk-age-decrypt.sh -i <arquivo-identidade> -o saida.txt <arquivo.age>
```

### Opcoes

| Flag | Descricao |
|------|-----------|
| `-i` | Arquivo de identidade age. Padrao: `~/.config/yk-toolkit/age/yubikey-identity.txt` |
| `-o` | Arquivo de saida. Padrao: nome do arquivo de entrada sem a extensao `.age` |

Requer `age` e `age-plugin-yubikey`. O PIN da YubiKey e/ou toque fisico podem ser necessarios durante a descriptografia.

---

## Notas de Seguranca

- O segredo HMAC-SHA1 e gerado e armazenado dentro da YubiKey — nao pode ser extraido
- O desafio e publico; o HMAC e o componente secreto derivado em tempo de execucao
- `--touch` no slot 2 garante presenca fisica em cada operacao
- A chave de criptografia nunca e armazenada em disco
- AES-256-CBC com PBKDF2 (600.000 iteracoes) fornece a camada de criptografia simetrica

## Licenca

MIT
