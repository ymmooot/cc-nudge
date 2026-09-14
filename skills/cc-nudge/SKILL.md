---
name: cc-nudge
description: cc-nudge（放置中の Claude Code セッションを macOS 通知で督促する bot）の操作。作業を中断・保留するときに、いま自分が動いているセッションを督促の対象から外す／戻す、除外一覧の確認、判定のドライラン。「cc-nudge から外して」「督促しないで」「通知を止めて」「監視に戻して」「今日はここまで」などで使う。
argument-hint: "[ignore|unignore|list|check] [理由]"
---

# cc-nudge の操作

## 前提知識（調べ直さないこと）

- 本体: `~/.claude/cc-nudge/nudge.sh`（launchd が 5 分おきに実行）。ログは `~/.claude/cc-nudge/nudge.log`
- 除外リスト: `~/.claude/cc-nudge/ignore`
  - 1 行 1 パターン。**セッション ID なら完全一致**、それ以外は稼働中プロセスの **作業ディレクトリに部分一致** で監視から外れる
  - `#` 以降はコメント。パターン行の直前に `# YYYY-MM-DD <理由> (<ディレクトリ名>)` を置く運用
- 自分のセッション ID は Bash の環境変数 `$CLAUDE_CODE_SESSION_ID`（会話ログ `<sid>.jsonl` の名前と同じ）。空ならシステムプロンプトの scratchpad パスに含まれる UUID を使う
- 基本は **セッション単位** で除外する。ディレクトリ単位はそのディレクトリで開く全セッションが外れるので、ユーザーが明示したときだけ
- 変更はファイル保存だけで反映される（再起動不要）。次の実行（最大 5 分後）から効く

サブコマンドは `$ARGUMENTS` の先頭。省略時は文脈で判断する（「外して」「中断」→ ignore、「戻して」「再開」→ unignore）。

## ignore — 現在のセッションを督促対象から外す

1. 対象は `$CLAUDE_CODE_SESSION_ID`。ユーザーが「ディレクトリごと」「このリポジトリ全部」と言ったら `$PWD`
2. 理由は `$ARGUMENTS` の残り、無ければユーザーの発言から一言で。理由が本当に無ければ「一時中断」
3. 既に載っていれば何もせずその旨を伝える

```zsh
IGNORE="$HOME/.claude/cc-nudge/ignore"; target="$CLAUDE_CODE_SESSION_ID"; reason="<理由>"
if grep -qxF -- "$target" "$IGNORE"; then echo "already ignored: $target"; else
  print -r -- "# $(date +%F) $reason (${PWD:t})" >> "$IGNORE"
  print -r -- "$target" >> "$IGNORE"
  echo "ignored: $target"
fi
```

報告: 外した対象（セッション or ディレクトリ）と理由、「再開時は `/cc-nudge unignore` で戻す」ことを一言添える。

## unignore — 監視に戻す

パターン行と、その直前の `# YYYY-MM-DD ...` コメント行を削除する。対象は ignore と同じ規則（既定はセッション ID、ディレクトリ指定なら `$PWD`）。

```zsh
IGNORE="$HOME/.claude/cc-nudge/ignore"; target="$CLAUDE_CODE_SESSION_ID"
if ! grep -qxF -- "$target" "$IGNORE"; then echo "not ignored: $target"; else
  awk -v p="$target" '
    { l[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) if (l[i]==p) { skip[i]=1; if (i>1 && l[i-1] ~ /^# [0-9]+-[0-9]+-[0-9]+ /) skip[i-1]=1 }
      for (i=1;i<=NR;i++) if (!skip[i]) print l[i]
    }' "$IGNORE" > "$IGNORE.tmp" && mv "$IGNORE.tmp" "$IGNORE"
  echo "unignored: $target"
fi
```

## list — 除外一覧

```zsh
cat "$HOME/.claude/cc-nudge/ignore"
```

セッション ID だけでは何か分からないので、コメント行の日付・理由・ディレクトリ名とセットで読む。古い除外（作業が終わっていそうなもの、日付が数日前のもの）があれば指摘する。

## check — 判定のドライラン

通知を出さずに全セッションの状態を表示する。自分のセッションが `IGNORED` になっているかの確認に使う。

```zsh
CC_NUDGE_DRY_RUN=1 CC_NUDGE_VERBOSE=1 "$HOME/.claude/cc-nudge/nudge.sh"
```

出力の見方: `IGNORED pid=... sid=... cwd=...` は除外中。`WAITING idle=Nm` は入力待ち（既定 15 分で通知）、`RUNNING idle=Nm` は実行中扱い（既定 45 分で通知）。

## やらないこと

- `nudge.sh` や plist（しきい値）は触らない。しきい値変更はリポジトリ `ymmooot/cc-nudge` の README を案内する
- `~/.claude/cc-nudge/state/` は再通知の間引き用。手で消さない
