#!/bin/zsh
# アプリを終了して取り除く（~/.claude/cc-nudge は残す）
set -u
pkill -x CCNudge || true
rm -rf "$HOME/Applications/CCNudge.app"
rm -f "$HOME/.claude/skills/cc-nudge"
echo "uninstalled: ~/Applications/CCNudge.app"
