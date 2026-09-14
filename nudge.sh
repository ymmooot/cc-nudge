#!/bin/zsh
# cc-nudge: このマシンで稼働中の Claude Code セッションを走査し、
# 入力待ちのまま放置されているものがあれば macOS 通知で進捗を促す。
#
# 判定:
#   WAITING : 最後のメッセージが assistant の返答（tool_use なし）or AskUserQuestion → こちらの入力待ち
#   RUNNING : それ以外（ツール実行中・Claude 思考中・許可プロンプト待ちの可能性）
#   WAITING が IDLE_MIN 分、RUNNING が STUCK_MIN 分続いたら通知。同一セッションへは REPEAT_MIN 分空ける。
set -u
export PATH="$HOME/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BASE="${CC_NUDGE_DIR:-$HOME/.claude/cc-nudge}"
STATE="$BASE/state"
LOG="$BASE/nudge.log"
IGNORE="$BASE/ignore"
IDLE_MIN="${CC_NUDGE_IDLE_MIN:-15}"
STUCK_MIN="${CC_NUDGE_STUCK_MIN:-45}"
REPEAT_MIN="${CC_NUDGE_REPEAT_MIN:-30}"
DRY_RUN="${CC_NUDGE_DRY_RUN:-0}"   # 1 なら通知せずログ出力のみ
VERBOSE="${CC_NUDGE_VERBOSE:-0}"   # 1 なら全セッションの状態をログに出す
OPEN="${0:A:h}/open.sh"           # 通知クリック時に herdr の対象ペインを開くスクリプト

mkdir -p "$STATE"
now=$(date +%s)
log() { print -r -- "$(date '+%F %T') $*" >> "$LOG"; [[ "$DRY_RUN" == 1 ]] && print -r -- "$*"; }

notify() {  # title subtitle message group cwd session_title
  if [[ "$DRY_RUN" == 1 ]]; then return; fi
  if command -v terminal-notifier >/dev/null; then
    terminal-notifier -title "$1" -subtitle "$2" -message "$3" -group "$4" -sound default \
      -execute "/bin/zsh ${(qq)OPEN} ${(qq)5} ${(qq)6}" >/dev/null 2>&1
  else
    osascript -e "display notification \"${3//\"/\\\"}\" with title \"${1//\"/\\\"}\" subtitle \"${2//\"/\\\"}\"" >/dev/null 2>&1
  fi
}

is_ignored() {  # cwd sid  — ignore の各行を「セッション ID なら完全一致、それ以外は cwd の部分一致」で判定
  [[ -f "$IGNORE" ]] || return 1
  local pat
  while IFS= read -r pat; do
    pat="${pat%%#*}"; pat="${pat## }"; pat="${pat%% }"
    [[ -z "$pat" ]] && continue
    [[ "$2" == "$pat" ]] && return 0
    [[ "$1" == *"$pat"* ]] && return 0
  done < "$IGNORE"
  return 1
}

# ---- 稼働中の claude プロセスごとに session-id / cwd を取り、会話ログを見る ----
for f in "$CLAUDE_DIR"/sessions/*.json(N); do
  pid="${${f:t}%.json}"
  kill -0 "$pid" 2>/dev/null || continue
  [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *claude* ]] || continue
  sid="$(jq -r '.sessionId // empty' "$f" 2>/dev/null)"
  cwd="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
  [[ -n "$sid" && -n "$cwd" ]] || { log "WARN sessionId/cwd not found in $f"; continue; }
  if is_ignored "$cwd" "$sid"; then
    [[ "$VERBOSE" == 1 ]] && log "IGNORED pid=$pid sid=$sid cwd=$cwd"
    continue
  fi
  jsonl="$CLAUDE_DIR/projects/${cwd//[\/.]/-}/$sid.jsonl"
  [[ -f "$jsonl" ]] || { log "WARN log not found: $jsonl"; continue; }

  # 直近のユーザー/アシスタントメッセージ（サイドチェーン除外）
  last="$(tail -n 300 "$jsonl" | jq -c '
    select(.type=="user" or .type=="assistant") | select(.isSidechain != true)
    | {type, ts: .timestamp,
       tools: ([.message.content[]? | select(type=="object" and .type=="tool_use") | .name]),
       text: ([.message.content | if type=="string" then . else (.[]? | select(type=="object" and .type=="text") | .text) end] | join(" ") | .[0:80])}
  ' 2>/dev/null | tail -1)"
  [[ -n "$last" ]] || continue

  ts="$(print -r -- "$last" | jq -r '.ts // empty')"
  [[ -n "$ts" ]] || continue
  epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) || continue
  idle=$(( (now - epoch) / 60 ))
  mtype="$(print -r -- "$last" | jq -r '.type')"
  tools="$(print -r -- "$last" | jq -r '.tools | join(",")')"
  text="$(print -r -- "$last" | jq -r '.text' | tr '\n' ' ')"
  title="$(grep '"ai-title"' "$jsonl" | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)"
  [[ -n "$title" ]] || title="${cwd:t}"

  if [[ "$mtype" == assistant && ( -z "$tools" || "$tools" == *AskUserQuestion* ) ]]; then
    state=WAITING; limit=$IDLE_MIN
  else
    state=RUNNING; limit=$STUCK_MIN
  fi
  [[ "$VERBOSE" == 1 ]] && log "$state idle=${idle}m sid=$sid [$title] last=$mtype tools=$tools"

  (( idle >= limit )) || continue

  # 再通知の間引き
  sf="$STATE/$sid"
  if [[ -f "$sf" ]]; then
    lastn=$(<"$sf")
    (( now - lastn < REPEAT_MIN * 60 )) && continue
  fi

  if [[ "$state" == WAITING ]]; then
    ntitle="Claude Code が ${idle} 分 入力待ち"
    msg="${text:-返答済み。次の指示を待っています}"
  else
    ntitle="Claude Code が ${idle} 分 止まっている？"
    msg="最後: ${mtype}${tools:+ ($tools)} / 許可プロンプト待ちかハングの可能性"
  fi
  log "NOTIFY $state idle=${idle}m cwd=$cwd sid=$sid [$title]"
  notify "$ntitle" "$title  (${cwd:t})" "$msg" "cc-nudge-$sid" "$cwd" "$title"
  [[ "$DRY_RUN" == 1 ]] || print -r -- "$now" > "$sf"
done

# 古い state を掃除（7日）
find "$STATE" -type f -mtime +7 -delete 2>/dev/null
exit 0
