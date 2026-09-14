# cc-nudge

このマシンで稼働中の [Claude Code](https://claude.com/claude-code) セッションを監視し、
返答済みのまま放置されているものがあれば macOS 通知で「次の指示は？」と促す小さな bot です。
zsh + jq だけで動き、launchd で 5 分おきに走ります。

## 仕組み

1. `~/.claude/sessions/<pid>.json` から稼働中の claude プロセスの session-id と作業ディレクトリを取る
2. `~/.claude/projects/<作業ディレクトリ>/<session-id>.jsonl` の会話ログから、最後の user / assistant メッセージを読む
3. 状態を判定して、しきい値を超えていたら通知する

| 状態 | 判定 | 通知までの時間 |
| --- | --- | --- |
| WAITING | 最後が Claude の返答で tool_use が無い（または AskUserQuestion） | `CC_NUDGE_IDLE_MIN`（既定 15 分） |
| RUNNING | それ以外（ツール実行中・思考中・許可プロンプト待ち） | `CC_NUDGE_STUCK_MIN`（既定 45 分） |

同じセッションへの再通知は `CC_NUDGE_REPEAT_MIN`（既定 30 分）空けます。

## 通知をクリックすると

`open.sh` が呼ばれ、[herdr](https://github.com/herdr-dev/herdr) で該当セッションが動いているペインにフォーカスを移します。

- `herdr pane list` から、作業ディレクトリと Claude Code のセッションタイトル（ターミナルタイトル）が一致するペインを探します
- herdr のクライアントがどこかのターミナルで開いていれば、そのアプリを前面に出します（祖先プロセスから .app を特定するのでターミナルアプリは問いません）
- 開いていなければ `CC_NUDGE_TERMINAL_APP`（既定 `Terminal`）で新しいウィンドウを開き、`herdr` を起動してからフォーカスします

herdr を使っていない場合は `-execute` が何もしないだけで、通知自体は変わらず届きます。

## 必要なもの

- macOS
- `jq`
- `terminal-notifier`（無ければ `osascript` の `display notification` にフォールバック。クリック動作は terminal-notifier のみ）
- `herdr`（任意。通知クリックでペインを開く機能に使う）

## インストール

```sh
git clone https://github.com/ymmooot/cc-nudge.git
cd cc-nudge
./install.sh
```

`~/.claude/cc-nudge/` に配置され、`~/Library/LaunchAgents/com.ymmooot.cc-nudge.plist` が登録されます。
`nudge.sh` はリポジトリへのシンボリックリンクなので、`git pull` するだけで更新されます。

しきい値を変えたい時は plist の `EnvironmentVariables` を編集して `./install.sh` を再実行してください。

## 監視から外す

`~/.claude/cc-nudge/ignore` に 1 行ずつ書きます。

- session-id（`<session-id>.jsonl` の名前。Claude Code 内では `$CLAUDE_CODE_SESSION_ID`）→ そのセッションだけ完全一致で除外
- それ以外 → 作業ディレクトリのパスとして部分一致で除外（そのディレクトリの全セッションが対象）

Claude Code のセッション内から操作する場合は `/cc-nudge` スキルが使えます（`install.sh` が `~/.claude/skills/cc-nudge` にリンクします）。

```
/cc-nudge ignore 翌日再開まで   # 今のセッションを除外
/cc-nudge unignore              # 監視に戻す
/cc-nudge list                  # 除外一覧
/cc-nudge check                 # 通知なしで判定結果を表示
```

「cc-nudge から外して」「今日はここまで」のような自然文でも呼び出せます。

## 動作確認

通知を出さずに全セッションの判定結果だけ表示します。

```sh
CC_NUDGE_DRY_RUN=1 CC_NUDGE_VERBOSE=1 ./nudge.sh
```

ログは `~/.claude/cc-nudge/nudge.log` に残ります。

## アンインストール

```sh
./uninstall.sh
```

## 既知の制限

- RUNNING の通知は、サブエージェントが長時間走っている場合にも出ます

## License

MIT
