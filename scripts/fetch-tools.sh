#!/bin/zsh
# Downloads the conversion engine Morphit bundles, checks it against the published SHA-256
# checksums and unpacks it in vendor/bin (not in the repository). build-app.sh copies vendor/bin
# into the app, in Contents/Resources/bin.
#   scripts/fetch-tools.sh
#
#   ffmpeg   ffmpeg.martin-riedl.de   static arm64 build: audio, video, WebP, AVIF, GIF
#   ffprobe  ffmpeg.martin-riedl.de   same build: reads streams, bitrates, durations
# Images to JPEG, PNG, HEIC, HEIF, TIFF and BMP are written by macOS (ImageIO), not by ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_PATH="macos/arm64/1789931890_9.0.2"

DL="vendor/downloads"; mkdir -p "$DL"

get() {   # url file
    [[ -f "$2" ]] || curl -fsSL -o "$2" "$1"
}
check() { # file expected-sha256
    local got=$(shasum -a 256 "$1" | cut -d' ' -f1)
    if [[ "$got" != "$2" ]]; then echo "error: checksum mismatch for $1" >&2; rm -f "$1"; exit 1; fi
}

for tool in ffmpeg ffprobe; do
    get "https://ffmpeg.martin-riedl.de/download/$FFMPEG_PATH/$tool.zip" "$DL/$tool.zip"
    get "https://ffmpeg.martin-riedl.de/download/$FFMPEG_PATH/$tool.zip.sha256" "$DL/$tool.zip.sha256"
    check "$DL/$tool.zip" "$(cut -d' ' -f1 < "$DL/$tool.zip.sha256")"
done

rm -rf vendor/bin; mkdir -p vendor/bin
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for tool in ffmpeg ffprobe; do
    ditto -x -k "$DL/$tool.zip" "$WORK/$tool"; cp "$WORK/$tool/$tool" vendor/bin/$tool
done
chmod +x vendor/bin/ffmpeg vendor/bin/ffprobe
xattr -cr vendor/bin
echo "Tools ready in vendor/bin:"
echo "  $(vendor/bin/ffmpeg -version | head -1 | cut -d' ' -f1-3)"
echo "  $(vendor/bin/ffprobe -version | head -1 | cut -d' ' -f1-3)"
