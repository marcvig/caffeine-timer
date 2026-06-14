#!/usr/bin/env bash
# make_icns.sh — render icon/AppIcon.svg into a full macOS AppIcon.icns
# (16,32,128,256,512 each @1x and @2x). Requires Inkscape + iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SVG="${1:-$ROOT/icon/AppIcon.svg}"
OUT="${2:-$ROOT/icon/AppIcon.icns}"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

render() { # <px> <filename>
    inkscape "$SVG" --export-type=png --export-filename="$ICONSET/$2" -w "$1" -h "$1" >/dev/null 2>&1
}
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"

# Keep the menu-bar glyph PDF in sync with its SVG.
if [ -f "$ROOT/icon/MenuIcon.svg" ]; then
    inkscape "$ROOT/icon/MenuIcon.svg" --export-type=pdf \
        --export-filename="$ROOT/icon/MenuIcon.pdf" >/dev/null 2>&1
    echo "wrote $ROOT/icon/MenuIcon.pdf"
fi
