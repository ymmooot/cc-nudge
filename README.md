# cc-nudge

このマシンで稼働中の [Claude Code](https://claude.com/claude-code) セッションを監視し、
返答済みのまま放置されているものがあればメニューバーで知らせる、macOS の常駐アプリです。

## 表示

- メニューバー
  - 放置されているセッションが無ければ吹き出しのアイコンだけ
  - しきい値を超えたセッションがあると、オレンジの `!` 付きの吹き出しと件数に変わる
- クリックで開くパネル
  - 稼働中のセッションを「入力待ち」「実行中」「除外中」に分け、放置の長いものから並べる
  - 1 行にセッションのタイトル、作業ディレクトリ、最後の返答の冒頭（実行中ならツール名）、放置時間を出す。しきい値を超えた行はオレンジになる
  - 行を押すと、[herdr](https://github.com/herdr-dev/herdr) でそのセッションのペインを開く
  - 行のベルのボタンで、そのセッションを監視から外す／戻す
  - 「ログイン時に起動」と「終了」

外をクリックするか、Esc か、メニューバーの項目をもう一度押すと閉じます。

## 仕組み

10 秒おきに次のことを行います。

1. `~/.claude/sessions/<pid>.json` から稼働中の claude プロセスの session-id と作業ディレクトリを取る
2. `~/.claude/projects/<作業ディレクトリ>/<session-id>.jsonl` の会話ログから、最後の user / assistant メッセージを読む。ログは前回読んだところから、伸びた分だけ読む
3. 状態を判定して、しきい値を超えていたら知らせる

| 状態 | 判定 | 知らせるまでの時間 |
| --- | --- | --- |
| WAITING（入力待ち） | 最後が Claude の返答で tool_use が無い（または AskUserQuestion） | 既定 15 分 |
| RUNNING（実行中） | それ以外（ツール実行中・思考中・許可プロンプト待ち） | 既定 45 分 |

### 対象外

会話ログが止まっていても「人間が待っている」とは限らないケースは除外します。

| 対象外 | 理由 |
| --- | --- |
| pid が使い回されて別プロセスになっている json | `claude daemon` / `bg-pty-host` / `bg-spare` が常駐しているため、終了済みセッションの pid が別の claude プロセスに当たることがある。json の `procStart` と実プロセスの起動時刻で照合する |
| バックグラウンドジョブ（`kind: bg`） | ジョブが終わってもデーモンがプロセスを抱えたままなので、生存＝待機とみなせない。ただし json の `status` が `waiting`（入力待ちの自己申告）なら入力待ちとして扱う |
| 別セッションに引き継がれた会話 | 会話ログ末尾の `continued-in` で判別する。引き継ぎ後は jsonl が凍結するため、放置すると RUNNING として永久に残る。続きは後継セッション側で判定される |

判定できない時（`procStart` が無い・後継の会話ログが見つからない等）は対象に残す側に倒します。

## 行を押すと

`open.sh` が呼ばれ、herdr で該当セッションが動いているペインにフォーカスを移します。

- `herdr pane list` から、作業ディレクトリと Claude Code のセッションタイトル（ターミナルタイトル）が一致するペインを探します
- herdr のクライアントがどこかのターミナルで開いていれば、そのアプリを前面に出します（祖先プロセスから .app を特定するのでターミナルアプリは問いません）
- 開いていなければ `CC_NUDGE_TERMINAL_APP`（既定 `Terminal`）で新しいウィンドウを開き、`herdr` を起動してからフォーカスします

herdr を使っていない場合は何も起きません。

## 必要なもの

- macOS 14 以降
- Swift（Xcode か Command Line Tools）
- `jq`（`open.sh` が使う）
- `herdr`（任意。行を押してペインを開く機能に使う）

## インストール

```sh
git clone https://github.com/ymmooot/cc-nudge.git
cd cc-nudge
./install.sh
```

ビルドして `~/Applications/CCNudge.app` に入れ、起動します。動いているものがあれば入れ替えます。
更新は `git pull` して `./install.sh` を再実行してください。
ログイン時に起動するには、パネルの「ログイン時に起動」にチェックを入れます。

## しきい値

```sh
defaults write com.ymmooot.cc-nudge idleMinutes 20    # WAITING（既定 15）
defaults write com.ymmooot.cc-nudge stuckMinutes 60   # RUNNING（既定 45）
```

次の判定（最大 10 秒後）から効きます。

## 監視から外す

パネルの行のベルのボタンで外せます。外したものは「除外中」に移り、同じボタンで戻せます。

除外は `~/.claude/cc-nudge/ignore` に 1 行ずつ書かれます。手で書き足すこともできます。

- session-id（`<session-id>.jsonl` の名前。Claude Code 内では `$CLAUDE_CODE_SESSION_ID`）→ そのセッションだけ完全一致で除外
- それ以外 → 作業ディレクトリのパスとして部分一致で除外（そのディレクトリの全セッションが対象。パネルからは戻せないので、ignore から消す）

Claude Code のセッション内から操作する場合は `/cc-nudge` スキルが使えます（`install.sh` が `~/.claude/skills/cc-nudge` にリンクします）。

```
/cc-nudge ignore 翌日再開まで   # 今のセッションを除外
/cc-nudge unignore              # 監視に戻す
/cc-nudge list                  # 除外一覧
/cc-nudge check                 # 判定結果を表示
```

「cc-nudge から外して」「今日はここまで」のような自然文でも呼び出せます。

## 動作確認

全セッションの判定結果を表示します。しきい値を超えたものには `OVERDUE` が付きます。

```sh
~/Applications/CCNudge.app/Contents/MacOS/CCNudge --check
```

判定ロジック（`Sources/NudgeCore/`）のテストは `swift test` です。

## 構成

| パス | 内容 |
| --- | --- |
| `Sources/NudgeCore/` | セッションの走査、会話ログの読み取り、状態の判定、ignore の読み書き。テストはここだけ |
| `Sources/CCNudge/main.swift` | メニューバーの項目、パネルの出し入れ、`--check` |
| `Sources/CCNudge/Panel.swift` | パネルの中身（SwiftUI）と吹き出しの形 |
| `open.sh` | herdr のペインを開く。`.app` の Resources に入る |
| `Info.plist` | `.app` に入れる設定。Dock に出さない |
| `install.sh` / `uninstall.sh` | ビルド、`.app` の組み立てと入れ替え／取り除き |

## アンインストール

先にパネルの「ログイン時に起動」を外してから実行してください。

```sh
./uninstall.sh
```

## 既知の制限

- RUNNING は、サブエージェントが長時間走っている場合にも放置扱いになります
- WAITING / RUNNING の判定は会話ログからの推測です。`~/.claude/sessions/<pid>.json` の `status` の方が正確な場面がありますが、値の意味が確定するまで `--check` に出すだけにしています

## License

MIT
