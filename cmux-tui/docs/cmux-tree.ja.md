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

`cmux-tree` はローカルの Codex プロセスを 10 秒ごとに走査します。TCP WebSocket リスナーは `/healthz` で確認し、実行中の Codex デーモンの Unix ソケットも検出します。`r` を押すとすぐに再走査します。

ローカル TCP リスナーの場合:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

設定しなくても `Local Codex :4500` として表示されます。`codex app-server daemon start` で起動したローカルデーモンも自動的に表示されます。

既定の `stdio://` で起動した Codex app-server は、入出力パイプを親クライアントが所有するため後から接続できません。監視するには WebSocket リスナーまたは管理デーモンを使います。

管理デーモンが Codex の既定 Unix ソケットで待機している場合、cmux は通常の対話起動と `resume` を Codex 標準のデーモン再利用経路へ渡します。元のターミナルは完全な Codex チャットクライアントのまま動作し、`cmux-tree` は別の接続で同じサーバーを監視します。この経路が追加で行う処理はソケット情報の確認 1 回だけで、cmux CLI、接続確認、フック用のプロセスは起動しません。`exec`、明示的なリモート接続、プロファイル、コマンドライン設定の上書きは、Codex が再利用デーモンへ完全な起動設定を再現できないため、従来の埋め込みサーバーとフックの経路を使います。

`cmux-tree` に永続的な Codex イベントフックは不要です。会話の軌跡は app-server のイベントから直接構築します。

認証付きリスナーは自動追加されません。探索処理は別プロセスの引数から認証情報を読みません。保護された bearer token ファイルを指定して手動で追加してください。

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
| `r` | 更新してローカル app-server を再走査 |
| `q`、`Ctrl-C` | 終了 |

マウスで行の選択、軌跡項目の展開、マシン追加ボタンの実行、各列の個別スクロールができます。
