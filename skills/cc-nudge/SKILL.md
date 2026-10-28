---
name: cc-nudge
description: cc-nudge（放置中の Claude Code セッションをメニューバーで知らせる常駐アプリ）の操作。作業を中断・保留するときに、いま自分が動いているセッションを督促の対象から外す／戻す、除外一覧の確認、判定のドライラン。「cc-nudge から外して」「督促しないで」「知らせないで」「監視に戻して」「今日はここまで」などで使う。
argument-hint: "[ignore|unignore|list|check] [理由]"
---

# cc-nudge の操作

## 前提知識（調べ直さないこと）

- 本体: `~/Applications/CCNudge.app`（10 秒おきに判定し、メニューバーとパネルに出す）。パネルの行のベルのボタンでも外す／戻すができる
- 除外リスト: `~/.claude/cc-nudge/ignore`
  - 1 行 1 パターン。**セッション ID なら完全一致**、それ以外は稼働中プロセスの **作業ディレクトリに部分一致** で監視から外れる
  - `#` 以降はコメント。パターン行の直前に `# YYYY-MM-DD <理由> (<ディレクトリ名>)` を置く運用
- 自分のセッション ID は Bash の環境変数 `$CLAUDE_CODE_SESSION_ID`（会話ログ `<sid>.jsonl` の名前と同じ）。空ならシステムプロンプトの scratchpad パスに含まれる UUID を使う
- 基本は **セッション単位** で除外する。ディレクトリ単位はそのディレクトリで開く全セッションが外れるので、ユーザーが明示したときだけ
- 変更はファイル保存だけで反映される（再起動不要）。次の判定（最大 10 秒後）から効く

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
# awk は使わない: スキル本文の $0 が起動引数に置換されて届き、全行が空になる
IGNORE="$HOME/.claude/cc-nudge/ignore"; target="$CLAUDE_CODE_SESSION_ID"
n=$(grep -nxF -- "$target" "$IGNORE" | head -1 | cut -d: -f1)
if [[ -z "$n" ]]; then echo "not ignored: $target"; else
  from=$n
  if [[ $n -gt 1 ]] && sed -n "$((n-1))p" "$IGNORE" | grep -q '^# [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} '; then from=$((n-1)); fi
  sed -i '' "${from},${n}d" "$IGNORE"
  echo "unignored: $target"
fi
```

## list — 除外一覧

```zsh
cat "$HOME/.claude/cc-nudge/ignore"
```

セッション ID だけでは何か分からないので、コメント行の日付・理由・ディレクトリ名とセットで読む。古い除外（作業が終わっていそうなもの、日付が数日前のもの）があれば指摘する。

## check — 判定のドライラン

全セッションの判定結果を表示する。自分のセッションが `IGNORED` になっているかの確認に使う。

```zsh
"$HOME/Applications/CCNudge.app/Contents/MacOS/CCNudge" --check
```

出力の見方: `IGNORED idle=Nm sid=... cwd=...` は除外中。`WAITING idle=Nm` は入力待ち（既定 15 分で知らせる）、`RUNNING idle=Nm` は実行中扱い（既定 45 分で知らせる）。しきい値を超えたものには `OVERDUE` が付く。

## やらないこと

- アプリやしきい値は触らない。しきい値の変更はリポジトリ `ymmooot/cc-nudge` の README（`defaults write`）を案内する
