# Cloud VM commands

The Rust client can list Cloud VMs and open a VM's full TUI in the current
terminal. The macOS cmux app must be running and signed in. It owns the account,
the private route, and one shared userspace WireGuard hub. These commands do
not start a system VPN or invoke the Swift CLI. This adapter targets macOS.
Forwarding the app control socket alone does not make its local WireGuard hub
available to a client on another computer.

```sh
cmux-tui vm ls --json
cmux-tui vm tui <vm-id>
```

`vm tui` connects this process to the VM. It does not open a desktop pane.
Detach with `Ctrl-b d`; the VM session remains available. The app holds the hub
until sign-out or app exit, including after this client detaches. No route,
WireGuard config, or hub path needs to be copied. An absent hub, untrusted
listener, or incompatible protocol fails before the TUI connects.

Use `--socket <app-socket>` or `CMUX_SOCKET_PATH` for a tagged app. The default
is `/tmp/cmux.sock`. Within the `vm` scope this is the app socket, not a local
TUI session socket. `--session` and `--machine` are rejected. Socket passwords
and inherited terminal capabilities use the same environment variables as the
desktop CLI. The socket server must belong to the current operating-system user.

Read and write an existing VM terminal without opening a local pane:

```sh
cmux-tui vm tree <vm-id> --refresh --json
cmux-tui vm terminal read <vm-id> <terminal-id>
cmux-tui vm terminal send <vm-id> <terminal-id> --keys enter -- 'printf "cmux-userspace-ok\n"'
cmux-tui vm terminal read <vm-id> <terminal-id>
```

`vm terminal new <vm-id> --name <name> --json` creates a remote terminal with
no local pane. `vm terminal close <vm-id> <terminal-id>` ends that terminal.
Use `--` before literal terminal text, especially text containing CLI options.
VM creation, billing, port publishing, and optional system VPN control remain
on the desktop CLI. This is the first Rust Cloud command set, not complete
desktop CLI parity.

## Cloud VM コマンド

Rust クライアントから Cloud VM を一覧表示し、現在の端末で VM の TUI を開けます。
macOS の cmux アプリを起動してログインしてください。アカウント、プライベート経路、
共有ユーザー空間 WireGuard ハブはアプリが管理します。システム VPN の起動や Swift
CLI の呼び出しは行いません。このアダプターの対象は macOS です。アプリの制御
ソケットだけを転送しても、別のコンピューターからローカルの WireGuard ハブを
使用することはできません。

上記の `vm ls` と `vm tui` を使用してください。`vm tui` はデスクトップのペインを
開かず、このプロセスを VM に接続します。`Ctrl-b d` で切断しても VM セッションは
残ります。ハブはアプリのログアウトまたは終了まで保持されます。経路、WireGuard
設定、ハブのパスをコピーする必要はありません。ハブや信頼済みリスナーがない場合、
またはプロトコルが一致しない場合は、接続前にエラーになります。

タグ付きアプリは `--socket <app-socket>` または `CMUX_SOCKET_PATH` で指定します。
既定は `/tmp/cmux.sock` です。`vm` のソケットはアプリ用であり、ローカル TUI
セッション用ではありません。`--session` と `--machine` は使用できません。
ソケットのパスワードと端末のアクセス権は、デスクトップ CLI と同じ環境変数を使います。
ソケットの所有者は現在の OS ユーザーと一致する必要があります。

`vm tree` で端末 ID を確認し、`vm terminal read` と `vm terminal send` で既存の
端末を操作できます。ローカルのペインは開きません。`vm terminal new` はリモート端末を
作成し、`vm terminal close` はその端末を終了します。送信する文字列の前には `--` を
指定してください。VM の作成、課金、ポートの公開、任意のシステム VPN 操作は引き続き
デスクトップ CLI を使用します。これは最初の Rust Cloud コマンド群です。
