#!/bin/zsh
# Builds dist/TextStop.app. The bundle gives Full Disk Access and Automation something specific to
# attach to, instead of a shared interpreter like /usr/bin/python3.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product textstop 2>&1 | grep -vE 'xcrun|XCTest|^\s*$' || true

app=dist/TextStop.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/textstop "$app/Contents/MacOS/textstop"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.textstop</string>
    <key>CFBundleName</key><string>TextStop</string>
    <key>CFBundleExecutable</key><string>textstop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSBackgroundOnly</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>TextStop sends STOP replies through Messages.</string>
</dict>
</plist>
PLIST
# A stable local identity keeps Full Disk Access and Automation across rebuilds; ad hoc signing
# changes the code hash every build, which makes macOS forget both. scripts/make-signing-identity.sh
# creates it.
signing_dir="$HOME/Library/Application Support/textstop"
keychain="$signing_dir/signing.keychain-db"
if [[ -f "$keychain" && -f "$signing_dir/signing.pass" ]]; then
    security unlock-keychain -p "$(cat "$signing_dir/signing.pass")" "$keychain"
    # Self-signed, so codesign won't look it up by name; use its hash.
    identity=$(security find-identity -p codesigning "$keychain" | awk '/TextStop Local Signing/ {print $2; exit}')
    # codesign only finds identities in the search list, so add the keychain just for this call.
    original=("${(@f)$(security list-keychains -d user | sed -E 's/^ *"(.*)"$/\1/')}")
    security list-keychains -d user -s "${original[@]}" "$keychain"
    codesign --force --sign "$identity" --keychain "$keychain" --identifier local.textstop "$app" \
        || { security list-keychains -d user -s "${original[@]}"; exit 1; }
    security list-keychains -d user -s "${original[@]}"
else
    echo "no local signing identity; signing ad hoc (permissions reset on every rebuild)"
    codesign --force --sign - --identifier local.textstop "$app"
fi
echo "built $app"
