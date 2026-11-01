#!/bin/bash
# Silero VAD のモデルを、版と中身を固定して取ってくる
set -euo pipefail

cd "$(dirname "$0")/.."
model="Resources/silero_vad.onnx"
url="https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.3/src/silero_vad/data/silero_vad.onnx"
sha256="1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"

if [ ! -f "$model" ]; then
    curl -sfL -o "$model" "$url"
fi
echo "$sha256  $model" | shasum -a 256 -c - >/dev/null
