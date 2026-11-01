#!/bin/bash
# SwiftPM でビルドしたバイナリを talk-catcher.app にまとめる
# 署名は既定で ad-hoc。CODESIGN_IDENTITY に証明書の名前を入れると、それで署名する
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"

scripts/fetch-model.sh
swift build -c "$configuration"
binary="$(swift build -c "$configuration" --show-bin-path)/TalkCatcher"

app="build/talk-catcher.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/TalkCatcher"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/silero_vad.onnx "$app/Contents/Resources/silero_vad.onnx"
cp LICENSE THIRD_PARTY_NOTICES.md licenses/onnxruntime-ThirdPartyNotices.txt "$app/Contents/Resources/"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app" >/dev/null

echo "$app"
