#!/usr/bin/env bash
# Creates a self-signed code-signing certificate, "StageKeeper Local Signing", in the login
# keychain. install.sh signs with it when it exists. macOS ties Accessibility permission to the
# certificate rather than to the build, so the permission survives reinstalls.
# The certificate is valid for ten years and works only on this Mac.
set -euo pipefail

NAME="StageKeeper Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" is already in the login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PASS" -out "$WORK/identity.p12"

# -T lets codesign use the private key. macOS may still ask once for the login keychain
# password the first time codesign uses it; choose Always Allow.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in the login keychain."
echo "Run ./scripts/install.sh, then allow StageKeeper in Accessibility one last time."
echo "If an earlier ad hoc build was allowed, first run: tccutil reset Accessibility local.stagekeeper"
