#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.3.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z' >&2; exit 1; }
app="dist/Codex Account Switcher.app"
mkdir -p build "$app/Contents/MacOS"
xcrun swiftc Sources/*.swift -O -target arm64-apple-macosx13.0 -o "$app/Contents/MacOS/CodexAccountSwitcher" -framework Cocoa -framework Security
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexAccountSwitcher</string>
<key>CFBundleIdentifier</key><string>local.codex-account-switcher</string>
<key>CFBundleName</key><string>Codex Account Switcher</string>
<key>CFBundleDisplayName</key><string>Codex 계정 전환</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/CodexAccountSwitcher" --self-test
archive="dist/Codex-Account-Switcher-$version-macOS-arm64.zip"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$app" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > SHA256SUMS.txt)
echo "Built: $archive"
