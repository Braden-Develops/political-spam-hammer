#!/bin/zsh
# Creates a self-signed "TextStop Local Signing" identity in its own keychain, so rebuilt apps keep
# their macOS permissions. The keychain and its random password stay in Application Support (0600),
# never in the repo.
set -euo pipefail
dir="$HOME/Library/Application Support/textstop"
keychain="$dir/signing.keychain-db"
pass_file="$dir/signing.pass"
[[ -f "$keychain" ]] && { echo "already exists: $keychain"; exit 0; }
mkdir -p "$dir"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl rand -hex 24 > "$pass_file"
pass=$(cat "$pass_file")
security create-keychain -p "$pass" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$pass" "$keychain"
cat > "$tmp/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=TextStop Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 3650 -config "$tmp/c.cnf" 2>/dev/null
p12pass=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -out "$tmp/id.p12" -passout "pass:$p12pass" -name "TextStop Local Signing"
security import "$tmp/id.p12" -k "$keychain" -P "$p12pass" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$keychain" >/dev/null
echo "created $keychain"
