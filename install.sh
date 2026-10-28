#!/bin/zsh
# CCNudge.app をビルドして ~/Applications に入れ、起動する。/cc-nudge スキルと ignore も置く（再実行すると入れ替える）
set -eu
SRC="${0:A:h}"
BASE="$HOME/.claude/cc-nudge"
APP="$HOME/Applications/CCNudge.app"

command -v swift >/dev/null || { echo "swift が必要です (xcode-select --install)"; exit 1; }
command -v jq >/dev/null || { echo "jq が必要です (brew install jq)"; exit 1; }

cd "$SRC"
swift build -c release
build=.build/CCNudge.app
rm -rf "$build"
mkdir -p "$build/Contents/MacOS" "$build/Contents/Resources"
cp .build/release/CCNudge "$build/Contents/MacOS/"
cp Info.plist "$build/Contents/"
cp open.sh "$build/Contents/Resources/"
codesign --force --sign - "$build"

pkill -x CCNudge || true
# 終了しきる前の open は -600 で失敗する
while pgrep -qx CCNudge; do sleep 0.2; done
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$build" "$APP"

mkdir -p "$BASE" "$HOME/.claude/skills"
[[ -f "$BASE/ignore" ]] || cp "$SRC/ignore.example" "$BASE/ignore"
ln -sfn "$SRC/skills/cc-nudge" "$HOME/.claude/skills/cc-nudge"
open "$APP"
echo "installed: $APP"
echo "skill: ~/.claude/skills/cc-nudge -> $SRC/skills/cc-nudge (/cc-nudge)"
