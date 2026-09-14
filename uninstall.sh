#!/bin/zsh
# launchd から登録解除する（~/.claude/cc-nudge は残す）
set -u
LABEL="com.ymmooot.cc-nudge"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/.claude/skills/cc-nudge"
echo "uninstalled: $LABEL"
