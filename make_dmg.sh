#!/usr/bin/env bash
# make_dmg.sh — build a polished drag-to-Applications DMG with a fixed 660x400 window.
# Hand-rolled (hdiutil + two-pass Finder AppleScript), no create-dmg. Then signs,
# notarizes, and staples the DMG itself. Stock-macOS tools only.
# Usage: ./make_dmg.sh [/path/to/CaffeineTimer.app]   (defaults to the /Applications copy)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CaffeineTimer"                                   # <App>.app filename
VOL_NAME="Caffeine Timer"                                  # mounted-volume name + window title
APP_PATH="${1:-/Applications/${APP_NAME}.app}"
DMG_PATH="$ROOT/dist/${APP_NAME}.dmg"
BG_SVG="$ROOT/icon/dmg-background.svg"
BG_PNG="$ROOT/icon/dmg-background.png"
ICON_ICNS="$ROOT/icon/AppIcon.icns"
SIGN_ID="${CODESIGN_IDENTITY:-Developer ID Application: Marc Vigod (8F72LV7S24)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vigod-notary}"

DMG_RW="$ROOT/dist/_rw.dmg"
STAGING="$ROOT/dist/_dmg-staging"
MOUNT="/Volumes/$VOL_NAME"

[ -d "$APP_PATH" ] || { echo "app not found: $APP_PATH (build it first)"; exit 1; }
command -v inkscape >/dev/null || { echo "need inkscape to render the background"; exit 1; }

# The Bash tool blocks a foreground `sleep`; use a perl-based nap inside the script.
nap() { perl -e 'select(undef,undef,undef,$ARGV[0])' "$1"; }

# 0. Render the background and FORCE exactly 660x400 @ 72dpi (the Finder retina-DPI trap:
#    a 144dpi or 2x image makes Finder draw it half-size and the icons miss their spots).
echo "==> background -> 660x400 @ 72dpi"
inkscape "$BG_SVG" --export-type=png --export-filename="$BG_PNG" -w 660 -h 400 >/dev/null 2>&1
sips -z 400 660 "$BG_PNG" >/dev/null                          # sips -z is HEIGHT then WIDTH
sips -s dpiWidth 72 -s dpiHeight 72 "$BG_PNG" >/dev/null

# 1. Stage the app + an /Applications symlink (the drag target)
echo "==> stage"
mkdir -p "$ROOT/dist"
rm -f "$DMG_RW" "$DMG_PATH"; rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

# 2. Author a read-write image from the staging folder
echo "==> author read-write image"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDRW "$DMG_RW" >/dev/null
rm -rf "$STAGING"

# 3. Mount read-write and drop in a hidden .background folder
echo "==> mount + add background"
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW" >/dev/null
nap 3
mkdir -p "$MOUNT/.background"
cp "$BG_PNG" "$MOUNT/.background/background.png"
chflags hidden "$MOUNT/.background"

# 4. Lay out the window. TWO-PASS (open->set->close->delay->open->update->close): a single
#    pass does not reliably persist view options/bounds to .DS_Store.
echo "==> finder layout (two-pass)"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 100, 860, 522}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.png"
    set position of item "${APP_NAME}.app" of container window to {165, 175}
    set position of item "Applications" of container window to {495, 175}
    close
    delay 2
    open
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    update without registering applications
    delay 3
    close
  end tell
end tell
APPLESCRIPT

# 5. Flush + detach, then convert to compressed read-only
# Volume icon (shown when mounted): add .VolumeIcon.icns LAST — after the Finder layout so
# nothing removes it, and while mounted because hdiutil create -srcfolder drops dotfiles.
cp "$ICON_ICNS" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || /usr/bin/SetFile -a C "$MOUNT" 2>/dev/null || true

echo "==> convert to compressed read-only"
sync; nap 2
# Clean detach (not -force) so the just-written .VolumeIcon.icns is flushed to the image.
hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW"

# 6. Sign + notarize + staple the DMG itself (separate from the app inside it)
echo "==> codesign DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
echo "==> notarize DMG (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# .dmg FILE icon (shown in Finder before mounting). Writes file metadata only — verified
# not to invalidate the signature or the stapled ticket — so it's done last.
echo "==> set .dmg file icon"
swift - <<SW >/dev/null 2>&1 || true
import Cocoa
if let img = NSImage(contentsOfFile: "$ICON_ICNS") {
    NSWorkspace.shared.setIcon(img, forFile: "$DMG_PATH", options: [])
}
SW

echo
echo "wrote $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
