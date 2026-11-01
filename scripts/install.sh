#!/bin/bash
set -euo pipefail

# build/talk-catcher.app を作って ~/Applications に入れる。前に入れたものは置き換える
# 動いている talk-catcher は先にメニューの「終了」で止めておく。止めずに置き換えると録音中の分が書き出されない
cd "$(dirname "$0")/.."
if pgrep -x TalkCatcher >/dev/null; then
    echo "talk-catcher が動いている。メニューの「talk-catcher を終了」で止めてから、もう一度実行して" >&2
    exit 1
fi
app="$(./scripts/build-app.sh | tail -n 1)"
destination="$HOME/Applications/talk-catcher.app"

mkdir -p "$HOME/Applications"
rm -rf "$destination"
ditto "$app" "$destination"
echo "$destination"
