#!/bin/bash
# Create the local self-signed code signing identity patch.sh signs Telemost with.
# Signed by it, the designated requirement is "identifier + this certificate", so macOS
# privacy grants (screen recording, camera, mic) survive re-patching and updates.
# The key never leaves this Mac; codesign alone may use it without a prompt.
set -euo pipefail
NAME="${TT_SIGN_IDENTITY:-TelemostTweaks Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
	echo "identity '$NAME' already exists"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
cat >"$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# -legacy: `security import` cannot read OpenSSL 3's default AES/SHA-256 PKCS#12
# ("MAC verification failed"); LibreSSL ignores the flag's absence, so add it only for OpenSSL 3
LEGACY=
openssl version | grep -q '^OpenSSL 3' && LEGACY=-legacy
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
	-out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "created identity '$NAME'"
