#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CloudVmMessages {
    pub scope: &'static str,
    pub help: &'static str,
    pub invalid_globals: &'static str,
    pub unix_required: &'static str,
    pub empty: &'static str,
    pub app_required: &'static str,
    pub invalid_response: &'static str,
    pub invalid_owner: &'static str,
    pub invalid_auth: &'static str,
    pub auth_failed: &'static str,
    pub read_failed: &'static str,
    pub trust_required: &'static str,
    pub hub_required: &'static str,
    pub protocol_mismatch: &'static str,
    pub request_too_large: &'static str,
}

pub(super) const ENGLISH: CloudVmMessages = CloudVmMessages {
    scope: "Use Cloud VMs through the signed-in cmux app",
    help: "\
USAGE
  cmux-tui vm ls [--json]
  cmux-tui vm tui <vm-id>
  cmux-tui vm tree [<vm-id>] [--refresh] [--json]
  cmux-tui vm terminal new <vm-id> [--name <name>] [--json]
  cmux-tui vm terminal read <vm-id> <terminal-id> [--json]
  cmux-tui vm terminal send <vm-id> <terminal-id> [--keys enter] -- <text>
  cmux-tui vm terminal close <vm-id> <terminal-id> [--json]

The macOS cmux app must be running and signed in. Use --socket <app-socket>
or CMUX_SOCKET_PATH to select it. The default is /tmp/cmux.sock.
The app owns sign-in and its shared userspace WireGuard hub. No system VPN,
sudo, or separate transport install is needed. vm tui opens the full remote
TUI here, in this terminal, without opening an app pane. Closing the client
keeps the VM session. Use vm tree to find existing terminal IDs.
Use -- before literal terminal text that contains command options.
",
    invalid_globals: "vm does not accept --session or --machine; vm tui requires interactive output (no --json, --jsonl, or --quiet)",
    unix_required: "Cloud VM commands require a Unix socket to a running macOS cmux app",
    empty: "No Cloud VMs on this account.",
    app_required: "Cannot reach the cmux app. Start it, sign in, and select its socket with --socket or CMUX_SOCKET_PATH",
    invalid_response: "Invalid response from the cmux app",
    invalid_owner: "The app socket is not owned by the current user",
    invalid_auth: "Invalid app socket credentials",
    auth_failed: "The app denied socket access. Check its socket access setting and credentials",
    read_failed: "The app did not complete the Cloud request",
    trust_required: "The VM has no trusted private listener. Update the app and retry",
    hub_required: "The app returned no userspace WireGuard hub; direct fallback is disabled",
    protocol_mismatch: "The VM and this client use different remote protocols. Update the app and client",
    request_too_large: "The Cloud request exceeds the 4 MiB limit",
};

pub(super) const JAPANESE: CloudVmMessages = CloudVmMessages {
    scope: "ログイン済みの cmux アプリで Cloud VM を操作",
    help: "\
使い方
  cmux-tui vm ls [--json]
  cmux-tui vm tui <vm-id>
  cmux-tui vm tree [<vm-id>] [--refresh] [--json]
  cmux-tui vm terminal new <vm-id> [--name <name>] [--json]
  cmux-tui vm terminal read <vm-id> <terminal-id> [--json]
  cmux-tui vm terminal send <vm-id> <terminal-id> [--keys enter] -- <text>
  cmux-tui vm terminal close <vm-id> <terminal-id> [--json]

macOS の cmux アプリを起動し、ログインしてください。--socket <app-socket>
または CMUX_SOCKET_PATH でアプリを指定します。既定は /tmp/cmux.sock です。
ログインと共有ユーザー空間 WireGuard ハブはアプリが管理します。
システム VPN、sudo、追加の通信ソフトは不要です。vm tui はアプリのペインを
開かず、この端末でリモート TUI を開きます。クライアントを終了しても VM の
セッションは残ります。既存の端末 ID は vm tree で確認できます。
オプションを含む文字列を端末へ送る場合は、文字列の前に -- を指定してください。
",
    invalid_globals: "vm では --session と --machine を使用できません。vm tui は対話出力が必要です（--json、--jsonl、--quiet は使用不可）",
    unix_required: "Cloud VM コマンドには、起動中の macOS cmux アプリへの Unix ソケットが必要です",
    empty: "このアカウントに Cloud VM はありません。",
    app_required: "cmux アプリに接続できません。アプリを起動してログインし、--socket または CMUX_SOCKET_PATH でソケットを指定してください",
    invalid_response: "cmux アプリからの応答が無効です",
    invalid_owner: "アプリのソケットは現在のユーザーが所有していません",
    invalid_auth: "アプリのソケット認証情報が無効です",
    auth_failed: "アプリがソケットアクセスを拒否しました。アクセス設定と認証情報を確認してください",
    read_failed: "アプリが Cloud リクエストを完了しませんでした",
    trust_required: "VM に信頼済みのプライベートリスナーがありません。アプリを更新して再試行してください",
    hub_required: "アプリがユーザー空間 WireGuard ハブを返しませんでした。直接接続への切り替えは無効です",
    protocol_mismatch: "VM とクライアントのリモートプロトコルが異なります。アプリとクライアントを更新してください",
    request_too_large: "Cloud リクエストが 4 MiB の上限を超えています",
};
