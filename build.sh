#!/usr/bin/env bash
# build.sh — compile, bundle, and codesign CaffeineTimer.app.
# Uses SwiftPM + hand assembly. If Xcode is installed, also compiles Assets.car
# from AppIcon.icns so current macOS notification UI can resolve CFBundleIconName.
# Verified on macOS 26 / Swift 6.3.
set -euo pipefail

APP_NAME="CaffeineTimer"
BUNDLE_ID="com.vigod.caffeinetimer"
DISPLAY_NAME="Caffeine Timer"
SHORT_VERSION="1.4.0"
BUILD_VERSION="8"
MIN_OS="13.0"
COPYRIGHT="Copyright © 2026 Marc Vigod."

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/${APP_NAME}.app"

# Optional Apple notarization: ./build.sh --notarize
# Auth via a notarytool keychain profile (create once, see README/CLAUDE.md):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id 8F72LV7S24
NOTARIZE=0
for arg in "$@"; do [ "$arg" = "--notarize" ] && NOTARIZE=1; done
NOTARY_PROFILE="${NOTARY_PROFILE:-vigod-notary}"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/${APP_NAME}"

echo "==> assembling ${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/icon/MenuIcon.pdf" "$APP/Contents/Resources/MenuIcon.pdf"

echo "==> asset catalog"
compile_assets_car() {
    local actool_developer_dir="${ACTOOL_DEVELOPER_DIR:-}"
    local tmp iconset appiconset
    local -a actool_cmd

    if [ -z "$actool_developer_dir" ] && [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/actool" ]; then
        actool_developer_dir="/Applications/Xcode.app/Contents/Developer"
    fi

    if [ -n "$actool_developer_dir" ]; then
        actool_cmd=(env "DEVELOPER_DIR=$actool_developer_dir" xcrun actool)
    elif xcrun --find actool >/dev/null 2>&1; then
        actool_cmd=(xcrun actool)
    else
        echo "    actool not found; keeping classic AppIcon.icns only"
        return 0
    fi

    tmp="$(mktemp -d)"
    iconset="$tmp/AppIcon.iconset"
    appiconset="$tmp/Assets.xcassets/AppIcon.appiconset"
    mkdir -p "$appiconset"
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN

    iconutil -c iconset "$ROOT/icon/AppIcon.icns" -o "$iconset"
    cp "$iconset"/*.png "$appiconset/"
    cat > "$appiconset/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

    "${actool_cmd[@]}" "$tmp/Assets.xcassets" \
        --compile "$APP/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target "$MIN_OS" \
        --app-icon AppIcon \
        --output-partial-info-plist "$tmp/assetcatalog_generated_info.plist" >/dev/null

    test -f "$APP/Contents/Resources/Assets.car"
    echo "    wrote Contents/Resources/Assets.car"
}
compile_assets_car

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>          <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleIconName</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>             <string>${BUILD_VERSION}</string>
    <key>LSUIElement</key>                 <true/>
    <key>LSMinimumSystemVersion</key>      <string>${MIN_OS}</string>
    <key>NSHumanReadableCopyright</key>    <string>${COPYRIGHT}</string>
</dict>
</plist>
EOF

plutil -lint "$APP/Contents/Info.plist"

echo "==> codesign"
# Prefer a real Apple identity (stable Team ID -> notifications register & prompt).
# Override with CODESIGN_IDENTITY=... ; falls back to ad-hoc if none is found.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    # Prefer a Developer ID Application cert (distributable + notarizable); only fall
    # back to Apple Development if no Developer ID cert exists. (Order matters: a single
    # combined regex with `exit` would pick whichever cert `security` lists first.)
    SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
# No --deep (deprecated for signing since macOS 13; single-binary bundle has no nested code).
if [ -n "$SIGN_ID" ]; then
    echo "    identity: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    echo "    no Developer identity found — ad-hoc (notifications won't register)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = "1" ]; then
    case "$SIGN_ID" in
        "Developer ID Application:"*) : ;;
        *) echo "ERROR: --notarize needs a 'Developer ID Application' identity (got: ${SIGN_ID:-none}). Set CODESIGN_IDENTITY=..."; exit 1 ;;
    esac
    echo "==> notarize (keychain profile: $NOTARY_PROFILE)"
    ZIP="$ROOT/dist/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo "==> staple ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -vvv "$APP" 2>&1 | head -3 || true
fi

echo

# Install to /Applications (shared) when it's writable without an admin prompt,
# else ~/Applications. Override with INSTALL_DIR=... Keep exactly ONE Launch
# Services registration — duplicate registrations of one bundle id break
# notification registration, so stale copies elsewhere are removed.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
INSTALL_DIR="${INSTALL_DIR:-}"
if [ -z "$INSTALL_DIR" ]; then
    if [ -w "/Applications" ]; then INSTALL_DIR="/Applications"; else INSTALL_DIR="$HOME/Applications"; fi
fi
mkdir -p "$INSTALL_DIR"
INSTALL="$INSTALL_DIR/${APP_NAME}.app"
echo "==> install to $INSTALL (replaces any running instance)"
pkill -x "$APP_NAME" 2>/dev/null || true

# Unregister the build artifact and installed copy before replacing it, and
# remove any stale copy in the OTHER location.
"$LSREG" -u "$APP" 2>/dev/null || true
if [ -e "$INSTALL" ]; then
    "$LSREG" -u "$INSTALL" 2>/dev/null || true
fi
for OTHER in "/Applications/${APP_NAME}.app" "$HOME/Applications/${APP_NAME}.app"; do
    if [ "$OTHER" != "$INSTALL" ] && [ -e "$OTHER" ]; then
        "$LSREG" -u "$OTHER" 2>/dev/null || true
        rm -rf "$OTHER"
    fi
done

rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
"$LSREG" -f "$INSTALL"
echo "    LS registrations for ${BUNDLE_ID}: $("$LSREG" -dump 2>/dev/null | grep -c "identifier: *${BUNDLE_ID}")"
open "$INSTALL"

echo
echo "Installed & launched: $INSTALL"
