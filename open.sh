#!/bin/zsh
# cc-nudge open: パネルの行を押した時に呼ばれ、対象セッションが動いている herdr のペインへフォーカスを移す。
# herdr のクライアントが開いていればそのターミナルアプリを前面に出し、無ければ新しくターミナルを開いて herdr を起動する。
#
# usage: open.sh <cwd> [title] [pid]
set -u
export PATH="$HOME/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TERMINAL_APP="${CC_NUDGE_TERMINAL_APP:-Terminal}"   # herdr が開いていない時に使うアプリ名
LOG="${CC_NUDGE_DIR:-$HOME/.claude/cc-nudge}/nudge.log"
cwd="${1:-}"; title="${2:-}"; pid="${3:-}"
log() { print -r -- "$(date '+%F %T') OPEN $*" >> "$LOG"; }

# claude の pid が前面で動いているペインの terminal_id。作業ディレクトリが同じペインから見る。
# タイトルは作業中に「Claude Code」へ変わるので、同じディレクトリに claude のペインが並ぶと取り違える
find_by_pid() {
  [[ -n "$pid" ]] || return
  local pane tid
  herdr pane list 2>/dev/null | jq -r --arg cwd "$cwd" '
    [.result.panes[]? | select(.agent == "claude")] | sort_by(.cwd != $cwd) | .[] | "\(.pane_id) \(.terminal_id)"' |
    while read -r pane tid; do
      herdr pane process-info --pane "$pane" 2>/dev/null |
        jq -e --argjson pid "$pid" '.result.process_info | .foreground_process_group_id == $pid or any(.foreground_processes[]?; .pid == $pid)' >/dev/null &&
        { print -r -- "$tid"; return; }
    done
}

# pid で見つからない時の対象ペインの terminal_id。タイトル一致を優先し、無ければ cwd 一致。
find_target() {
  herdr pane list 2>/dev/null | jq -r --arg cwd "$cwd" --arg title "$title" '
    [.result.panes[]? | select(.cwd == $cwd)] as $c
    | ( [$c[] | select($title != "" and (.terminal_title_stripped | endswith($title)))]
      + [$c[] | select(.agent == "claude")]
      + $c )[0].terminal_id // empty'
}

# 端末で動いている herdr クライアントの pid（サーバーは tty を持たない）
client_pid() { pgrep -x herdr | while read -r p; do [[ "$(ps -o tty= -p "$p")" != "??" ]] && { echo "$p"; return; }; done; }

# pid の祖先をたどって .app を見つけ、そのアプリを前面に出す
activate_app_of() {
  local p="$1" comm
  for _ in {1..10}; do
    comm="$(ps -o comm= -p "$p" 2>/dev/null)"; [[ -n "$comm" ]] || return 1
    if [[ "$comm" == *.app/Contents/MacOS/* ]]; then open "${comm%%.app/*}.app"; return 0; fi
    p="$(ps -o ppid= -p "$p" | tr -d ' ')"; [[ "$p" == 1 || -z "$p" ]] && return 1
  done
  return 1
}

cp="$(client_pid)"
if [[ -z "$cp" ]]; then
  log "no herdr client; launching in $TERMINAL_APP"
  osascript -e "tell application \"$TERMINAL_APP\" to do script \"herdr\"" -e "tell application \"$TERMINAL_APP\" to activate" >/dev/null 2>&1 \
    || open -a "$TERMINAL_APP"
  for _ in {1..20}; do sleep 0.5; cp="$(client_pid)"; [[ -n "$cp" ]] && break; done
else
  activate_app_of "$cp" || open -a "$TERMINAL_APP"
fi

target="$(find_by_pid)"; [[ -n "$target" ]] || target="$(find_target)"
if [[ -n "$target" ]]; then
  herdr agent focus "$target" >/dev/null 2>&1 || herdr pane focus --pane "$target" >/dev/null 2>&1
  log "focused $target cwd=$cwd title=$title pid=$pid"
else
  log "pane not found cwd=$cwd title=$title pid=$pid"
fi
