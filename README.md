# cc-nudge

このマシンで稼働中の [Claude Code](https://claude.com/claude-code) セッションを監視し、
返答済みのまま放置されているものがあれば macOS 通知で「次の指示は？」と促す小さな bot です。
zsh + jq だけで動き、launchd で 5 分おきに走ります。

## 仕組み

1. `~/.claude/sessions/<pid>.json` から稼働中の claude プロセスを見つけ、`lsof` で作業ディレクトリを取る
2. `~/.claude/projects/<作業ディレクトリ>/<session-id>.jsonl` の会話ログから、最後の user / assistant メッセージを読む
3. 状態を判定して、しきい値を超えていたら通知する

| 状態 | 判定 | 通知までの時間 |
| --- | --- | --- |
| WAITING | 最後が Claude の返答で tool_use が無い（または AskUserQuestion） | `CC_NUDGE_IDLE_MIN`（既定 15 分） |
| RUNNING | それ以外（ツール実行中・思考中・許可プロンプト待ち） | `CC_NUDGE_STUCK_MIN`（既定 45 分） |

同じセッションへの再通知は `CC_NUDGE_REPEAT_MIN`（既定 30 分）空けます。

## 必要なもの

- macOS
- `jq`
- `terminal-notifier`（無ければ `osascript` の `display notification` にフォールバック）

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

`~/.claude/cc-nudge/ignore` に作業ディレクトリのパス（部分一致）を 1 行ずつ書きます。

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

- 会話ログには pid が記録されないため、同じディレクトリで複数セッションを開いている場合は「更新が新しい順に稼働プロセス数ぶん」のログを対応付けています
- RUNNING の通知は、サブエージェントが長時間走っている場合にも出ます

## License

MIT
