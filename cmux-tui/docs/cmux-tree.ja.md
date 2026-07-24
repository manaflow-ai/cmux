# cmux tree

`cmux-tree` は複数のマシンで動く Codex を監視する読み取り専用 TUI です。3 列にマシン、サブエージェントを含む Codex の会話、選択した会話の軌跡を表示します。

バイナリ名は `cmux-tree` です。既存の `cmux tree` コマンドは Swift アプリのペイン階層を表示するため、この初期版では置き換えません。

## 実行

リポジトリでビルドして起動します。

```bash
cd cmux-tui
cargo build -p cmux-tree
target/debug/cmux-tree
```

標準の設定ファイルは `~/.config/cmux-tree/config.json` です。別のファイルを使う場合は `CMUX_TREE_CONFIG` または `--config PATH` を指定します。

## Codex app-server の起動

Codex と同じマシンで使う場合:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

`cmux-tree` で `a` を押し、名前と `ws://127.0.0.1:4500` を入力します。

別のマシンでは、app-server をそのマシンの Tailscale、LAN、または VPN アドレスにバインドします。Codex はループバック以外のリスナーに認証を要求します。

```bash
umask 077
openssl rand -hex 32 > ~/.codex/cmux-tree.token
codex app-server --listen ws://100.64.0.8:4500 \
  --ws-auth capability-token \
  --ws-token-file "$HOME/.codex/cmux-tree.token"
```

トークンを `cmux-tree` を実行するマシンの保護されたファイルへコピーします。マシン追加ダイアログで、リモート WebSocket URL とローカルのトークンファイルのパスを入力します。設定にはトークン本体ではなくファイルのパスだけが保存されます。

`cmux-tree` はネットワークを作成または管理しません。Tailscale、ローカルネットワーク、または別の VPN が提供する任意の経路を利用できます。TLS リバースプロキシで app-server を保護する場合は `wss://` を使います。

Codex は現在 WebSocket app-server トランスポートを実験的機能として扱っています。信頼できるネットワークで使い、ループバック以外のすべてのエンドポイントに capability token を設定してください。

## レイアウトと操作

マシン列には Codex app-server ごとの行が表示されます。会話列は最新のユーザーメッセージまたは停止時刻でルート会話を並べ、親会話の下にサブエージェントのスレッドを表示します。軌跡列は Codex の作業中に更新されます。

完了した作業はターン単位で折りたたまれます。ターンを開くとツール呼び出しと思考が表示され、各項目をさらに開くとコマンド出力、引数、結果、または差分を確認できます。実行中の作業は到着に合わせて展開されます。

| 入力 | 操作 |
| --- | --- |
| `Tab`、`Shift-Tab`、`h`、`l` | 列を変更 |
| `j`、`k`、矢印キー | 選択を移動 |
| `Enter`、`Space` | 展開または折りたたみ |
| `PageUp`、`PageDown`、マウスホイール | スクロール |
| `g`、`G` | 先頭または末尾へ移動 |
| `a` | マシンを追加 |
| `r` | 更新 |
| `q`、`Ctrl-C` | 終了 |

マウスで行の選択、軌跡項目の展開、マシン追加ボタンの実行、各列の個別スクロールができます。
