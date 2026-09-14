#!/bin/zsh
# cc-nudge を ~/.claude/cc-nudge に配置し、launchd に登録する（再実行すると更新・再読み込み）
set -eu
SRC="${0:A:h}"
BASE="${CC_NUDGE_DIR:-$HOME/.claude/cc-nudge}"
LABEL="com.ymmooot.cc-nudge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v jq >/dev/null || { echo "jq が必要です (brew install jq)"; exit 1; }
command -v terminal-notifier >/dev/null || echo "note: terminal-notifier が無いので osascript にフォールバックします"

mkdir -p "$BASE/state" "$HOME/Library/LaunchAgents"
ln -sf "$SRC/nudge.sh" "$BASE/nudge.sh"
mkdir -p "$HOME/.claude/skills"
ln -sfn "$SRC/skills/cc-nudge" "$HOME/.claude/skills/cc-nudge"
[[ -f "$BASE/ignore" ]] || cp "$SRC/ignore.example" "$BASE/ignore"
sed "s|__BASE__|$BASE|g" "$SRC/com.ymmooot.cc-nudge.plist.template" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST -> $BASE/nudge.sh"
echo "skill: ~/.claude/skills/cc-nudge -> $SRC/skills/cc-nudge (/cc-nudge)"
