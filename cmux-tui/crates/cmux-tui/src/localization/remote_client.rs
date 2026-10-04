//! `remote_client` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RemoteClientMessages {
    pub connect_help: &'static str,
    pub ssh_help: &'static str,
    pub forward_help: &'static str,
    pub browser_proxy_help: &'static str,
    pub rpc_help: &'static str,
    pub enroll_help: &'static str,
    pub known_daemons_help: &'static str,
    pub remote_probe_help: &'static str,
    pub remote_link_help: &'static str,
    pub install_self_help: &'static str,
    pub command_help: &'static str,
    pub remote_lifecycle_help: &'static str,
    pub(super) option_needs_value: &'static str,
    pub(super) invalid_option_value: &'static str,
    pub(super) option_must_be_positive: &'static str,
    pub(super) unknown_option: &'static str,
    pub(super) unknown_option_for_command: &'static str,
    pub(super) option_once: &'static str,
    pub(super) unknown_action: &'static str,
    pub(super) enroll_arity: &'static str,
    pub(super) option_create_only: &'static str,
    pub inline_invitation_rejected: &'static str,
    pub invitation_path_invalid: &'static str,
    pub invitation_input_read_failed: &'static str,
    pub invitation_input_empty: &'static str,
    pub(super) invitation_input_too_large: &'static str,
    pub invitation_input_multiline: &'static str,
    pub invitation_input_invalid_utf8: &'static str,
    pub inline_relay_ticket_rejected: &'static str,
    pub inline_enroll_relay_ticket_rejected: &'static str,
    pub relay_command_arg_order: &'static str,
    pub relay_credentials_require_explicit_route: &'static str,
    pub(super) relay_shorthand_requires_relay_route: &'static str,
    pub relay_credential_pair_required: &'static str,
    pub multiple_relay_credentials_require_routes: &'static str,
    pub route_scoped_relay_credential_pair_required: &'static str,
    pub(super) relay_credential_limit: &'static str,
    pub(super) relay_route_not_relay: &'static str,
    pub(super) relay_route_repeated: &'static str,
    pub(super) invitation_relay_route_repeated: &'static str,
    pub(super) relay_route_limit: &'static str,
    pub(super) invitation_daemon_mismatch: &'static str,
    pub invitation_no_routes: &'static str,
    pub(super) daemon_no_routes: &'static str,
    pub known_daemon_key_unavailable: &'static str,
    pub(super) carrier_daemon_requires_carrier: &'static str,
    pub upgrade_requires_ssh: &'static str,
    pub(super) relay_route_not_candidate: &'static str,
    pub(super) daemon_key_changed: &'static str,
    pub known_daemon_refresh_missing: &'static str,
    pub positional_invitation_rejected: &'static str,
    pub connect_one_route: &'static str,
    pub reconnect_policy_invalid: &'static str,
    pub upgrade_no_install: &'static str,
    pub json_requires_headless: &'static str,
    pub help_invalid_options: &'static str,
    pub ssh_destination_required: &'static str,
    pub ssh_destination_invalid: &'static str,
    pub forward_workspace_required: &'static str,
    pub forward_port_required: &'static str,
    pub rpc_request_invalid: &'static str,
    pub rpc_input_invalid: &'static str,
    pub(super) rpc_stdin_too_large: &'static str,
    pub rpc_stdin_invalid_utf8: &'static str,
    pub known_forget_arity: &'static str,
    pub known_state_dir_unavailable: &'static str,
    pub(super) wireguard_config_unreadable: &'static str,
    pub(super) wireguard_config_invalid: &'static str,
    pub(super) wireguard_start_failed: &'static str,
    pub wireguard_hub_conflict: &'static str,
    pub(super) wireguard_hub_serve_failed: &'static str,
    pub(super) wireguard_hub_signal_failed: &'static str,
    pub(super) wg_hub_option_required: &'static str,
    pub wg_hub_help: &'static str,
    pub(super) known_daemon_not_known: &'static str,
    pub(super) known_daemon_forgotten: &'static str,
    pub known_daemons_empty: &'static str,
    pub known_daemon_auth_enrolled: &'static str,
    pub known_daemon_auth_carrier: &'static str,
}

impl RemoteClientMessages {
    pub(crate) fn option_needs_value(&self, option: &str) -> String {
        self.option_needs_value.replace("{option}", option)
    }

    pub(crate) fn wireguard_config_unreadable(&self, path: &str, error: &str) -> String {
        self.wireguard_config_unreadable.replace("{path}", path).replace("{error}", error)
    }

    pub(crate) fn wireguard_config_invalid(&self, error: &str) -> String {
        self.wireguard_config_invalid.replace("{error}", error)
    }

    pub(crate) fn wireguard_start_failed(&self, error: &str) -> String {
        self.wireguard_start_failed.replace("{error}", error)
    }

    pub(crate) fn wireguard_hub_serve_failed(&self, error: &str) -> String {
        self.wireguard_hub_serve_failed.replace("{error}", error)
    }

    pub(crate) fn wireguard_hub_signal_failed(&self, error: &str) -> String {
        self.wireguard_hub_signal_failed.replace("{error}", error)
    }

    pub(crate) fn wg_hub_option_required(&self, option: &str) -> String {
        self.wg_hub_option_required.replace("{option}", option)
    }

    pub(crate) fn invalid_option_value(&self, option: &str, expected: &str) -> String {
        self.invalid_option_value.replace("{option}", option).replace("{expected}", expected)
    }

    pub(crate) fn option_must_be_positive(&self, option: &str) -> String {
        self.option_must_be_positive.replace("{option}", option)
    }

    pub(crate) fn unknown_option(&self, option: &str) -> String {
        self.unknown_option.replace("{option}", &format!("{option:?}"))
    }

    pub(crate) fn unknown_option_for_command(&self, option: &str, command: &str) -> String {
        self.unknown_option_for_command
            .replace("{option}", &format!("{option:?}"))
            .replace("{command}", command)
    }

    pub(crate) fn option_once(&self, option: &str) -> String {
        self.option_once.replace("{option}", option)
    }

    pub(crate) fn unknown_action(&self, command: &str, action: &str) -> String {
        self.unknown_action
            .replace("{command}", command)
            .replace("{action}", &format!("{action:?}"))
    }

    pub(crate) fn enroll_arity(&self, action: &str, expected: usize) -> String {
        self.enroll_arity.replace("{action}", action).replace("{expected}", &expected.to_string())
    }

    pub(crate) fn option_create_only(&self, option: &str) -> String {
        self.option_create_only.replace("{option}", option)
    }

    pub(crate) fn invitation_input_too_large(&self, maximum: usize) -> String {
        self.invitation_input_too_large.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn relay_shorthand_requires_relay_route(&self, route: &str) -> String {
        self.relay_shorthand_requires_relay_route.replace("{route}", route)
    }

    pub(crate) fn relay_credential_limit(&self, maximum: usize) -> String {
        self.relay_credential_limit.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn relay_route_not_relay(&self, route: &str) -> String {
        self.relay_route_not_relay.replace("{route}", route)
    }

    pub(crate) fn relay_route_repeated(&self, route: &str) -> String {
        self.relay_route_repeated.replace("{route}", route)
    }

    pub(crate) fn invitation_relay_route_repeated(&self, route: &str) -> String {
        self.invitation_relay_route_repeated.replace("{route}", route)
    }

    pub(crate) fn relay_route_limit(&self, maximum: usize) -> String {
        self.relay_route_limit.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn invitation_daemon_mismatch(&self, fingerprint: &str) -> String {
        self.invitation_daemon_mismatch.replace("{fingerprint}", &format!("{fingerprint:?}"))
    }

    pub(crate) fn daemon_no_routes(&self, fingerprint: &str) -> String {
        self.daemon_no_routes.replace("{fingerprint}", fingerprint)
    }

    pub(crate) fn carrier_daemon_requires_carrier(&self, fingerprint: &str) -> String {
        self.carrier_daemon_requires_carrier.replace("{fingerprint}", fingerprint)
    }

    pub(crate) fn relay_route_not_candidate(&self, route: &str) -> String {
        self.relay_route_not_candidate.replace("{route}", route)
    }

    pub(crate) fn daemon_key_changed(&self, name: &str) -> String {
        self.daemon_key_changed.replace("{name}", name)
    }

    pub(crate) fn rpc_stdin_too_large(&self, maximum: usize) -> String {
        self.rpc_stdin_too_large.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn known_daemon_not_known(&self, fingerprint: &str) -> String {
        self.known_daemon_not_known.replace("{fingerprint}", &format!("{fingerprint:?}"))
    }

    pub(crate) fn known_daemon_forgotten(&self, fingerprint: &str) -> String {
        self.known_daemon_forgotten.replace("{fingerprint}", fingerprint)
    }
}

pub(super) const ENGLISH: RemoteClientMessages = RemoteClientMessages {
    connect_help: r#"USAGE: cmux remote connect [ROUTE] [OPTIONS]

ROUTES:
  unix:///ABSOLUTE/PATH | ssh://[USER@]HOST[:PORT] | ws:// | wss:// | iroh://
  relay+ws:// | relay+wss:// | relay+https:// | relay+do://

IDENTITY AND SESSION:
  --invite-file PATH|-  --daemon FINGERPRINT  --carrier
  --device-name NAME  --session NAME
  --state-dir PATH  --local-socket PATH  --headless [--json]

  --invite-file avoids exposing the single-use invitation in process arguments.
  Regular files must be owner-only; - reads one line from stdin.
  --carrier dials ws routes with carrier authentication (no enrollment, no
invitation); only a daemon whose listener is trusted accepts it, such as a
cmux Cloud machine reached over the owner's private network.

TRANSPORT:
  --lanes auto|single|isolated  --connect-timeout-seconds N
  For one explicit relay route, --relay-slot SLOT with either
--relay-ticket-file PATH or --relay-ticket-command PROGRAM.
  For fallbacks, repeat up to four --relay-route ROUTE, --relay-slot SLOT,
and credential-source groups in occurrence order.
  --relay-ticket-command-arg ARG  --iroh-relay URL  --iroh-address ADDR
  --iroh-path auto|direct-only|relay-only
  --wireguard-config PATH  dial ws routes inside that tunnel's AllowedIPs
through an in-process WireGuard peer (owner-only wg-quick file; no root)
  --wireguard-hub PATH  dial ws routes through a running `cmux wg hub` socket
instead; exclusive with --wireguard-config
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --agent-hooks PROVIDER[,PROVIDER...] installs those coding-agent hooks for
the remote user on each attach (for example claude,codex)
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar after installing
the pinned binary; terminal panes survive, while remote RPC state resets

RECONNECT:
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#,
    ssh_help: r#"USAGE: cmux remote ssh [USER@]HOST[:PORT] [OPTIONS]

Direct SSH uses one carrier by default. Pass --lanes auto or isolated to opt in
to multiple carriers. The remote binary is probed and, unless --no-install is
set, installed into the user account when missing or incompatible.

OPTIONS:
  --session NAME  --lanes single|auto|isolated  --headless [--json]
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --agent-hooks PROVIDER[,PROVIDER...] installs those coding-agent hooks for
the remote user on each attach (for example claude,codex)
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar; terminal panes
survive, remote clients and forwards disconnect, RPC processes stop, and
other RPC resources reset
  --state-dir PATH  --local-socket PATH  --connect-timeout-seconds N
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#,
    browser_proxy_help: "USAGE: cmux remote browser-proxy [ROUTE] --allowed-host HOST [--allowed-host HOST ...] --workspace-root PATH --wireguard-hub PATH [OPTIONS]\n\nStarts an authenticated local browser proxy to the selected machine's loopback ports. Prints private proxy credentials on stdout.\n",
    forward_help: r#"USAGE: cmux remote forward [ROUTE] --workspace-root PATH --port PORT [OPTIONS]

OPTIONS:
  --host HOST  --listen ADDR  --scheme http|https
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux remote connect` are also accepted.
"#,
    rpc_help: r#"USAGE: cmux remote rpc [ROUTE] [OPTIONS]

Reads one WorkspaceRequest JSON object per stdin line and writes one response
per line. --request JSON sends one request and exits.

OPTIONS:
  --request WORKSPACE_REQUEST_JSON
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux remote connect` are also accepted.
"#,
    enroll_help: r#"USAGE: cmux remote enroll ACTION [OPTIONS]

ACTIONS:
  status | create | pending | approve ID | deny ID | devices | connections
  revoke DEVICE_ID | disconnect DEVICE_ID SESSION_ID | connect ROUTE

OPTIONS:
  --session NAME  --state-dir PATH  --admin-socket PATH  --json
  create: --ttl SECONDS  --advertise ROUTE
  create relay access: repeat --relay-route ROUTE --relay-slot SLOT with
--relay-ticket-file PATH, in occurrence order,
for up to two relay fallbacks
  connect accepts every option documented by `cmux remote connect`.
"#,
    known_daemons_help: "USAGE: cmux remote known-daemons [list] [--state-dir PATH] [--json]\n       cmux remote known-daemons forget FINGERPRINT [--state-dir PATH] [--json]\n",
    remote_probe_help: "USAGE: cmux-tui remote-probe [--json]\n",
    remote_link_help: "USAGE: cmux-tui remote-link --stdio [--session NAME] [--state-dir PATH]\n",
    install_self_help: "USAGE: cmux-tui install-self --destination PATH\n",
    command_help: "USAGE: cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [OPTIONS]\n\nRun `cmux remote COMMAND --help` for command-specific routes and options. Legacy top-level aliases remain available for one compatibility cycle.\n",
    remote_lifecycle_help: "USAGE: cmux remote connect|ssh|forward|rpc [OPTIONS]\n       cmux remote enroll <ACTION> [OPTIONS]\n       cmux remote known-daemons [OPTIONS]\n       cmux remote stop [OPTIONS]\n\nAuthenticated remote operations are explicit under `remote`. Start the owning process with `cmux server start` and explicit remote flags. `cmux remote stop` manages only replaceable SSH sidecars. Stop a listener embedded by `cmux server start` with `cmux server stop`; this also stops its local owner and workspaces.\n",
    option_needs_value: "{option} needs a value",
    invalid_option_value: "{option} has an invalid value; expected {expected}",
    option_must_be_positive: "{option} must be positive",
    unknown_option: "unknown option {option}",
    unknown_option_for_command: "unknown option {option} for {command}",
    option_once: "{option} may only be specified once",
    unknown_action: "unknown {command} action {action}",
    enroll_arity: "enroll {action} expects exactly {expected} positional arguments",
    option_create_only: "{option} is only valid for enroll create",
    inline_invitation_rejected: "inline invitations are not accepted; use --invite-file or stdin",
    invitation_path_invalid: "invitation path must be an owner-only regular file or - for stdin",
    invitation_input_read_failed: "could not read invitation input",
    invitation_input_empty: "invitation input is empty",
    invitation_input_too_large: "invitation input exceeds {maximum} bytes",
    invitation_input_multiline: "invitation input must contain exactly one URI",
    invitation_input_invalid_utf8: "invitation input is not valid UTF-8",
    inline_relay_ticket_rejected: "inline relay tickets are not accepted; use --relay-ticket-file or --relay-ticket-command",
    inline_enroll_relay_ticket_rejected: "inline relay tickets are not accepted; use --relay-ticket-file",
    relay_command_arg_order: "--relay-ticket-command-arg must follow --relay-ticket-command",
    relay_credentials_require_explicit_route: "relay credentials without --relay-route require one explicit relay connection route",
    relay_shorthand_requires_relay_route: "relay credential shorthand requires an explicit relay route, got {route}",
    relay_credential_pair_required: "each relay credential needs one --relay-slot and one relay credential source",
    multiple_relay_credentials_require_routes: "multiple relay credentials require one --relay-route per credential group",
    route_scoped_relay_credential_pair_required: "each route-scoped relay credential needs one --relay-route, one --relay-slot, and one credential source",
    relay_credential_limit: "a client supports at most {maximum} relay credentials",
    relay_route_not_relay: "relay credential route {route} is not a relay route",
    relay_route_repeated: "relay credential route {route} is repeated",
    invitation_relay_route_repeated: "invitation repeats relay bootstrap route {route}",
    relay_route_limit: "a client supports at most {maximum} relay credential routes including invitation bootstrap routes",
    invitation_daemon_mismatch: "invitation daemon fingerprint does not match --daemon {fingerprint}",
    invitation_no_routes: "invitation contains no usable route hints",
    daemon_no_routes: "daemon {fingerprint} has no stored routes; pass a route or enroll again",
    known_daemon_key_unavailable: "known daemon key disappeared",
    carrier_daemon_requires_carrier: "daemon {fingerprint} is known only through a trusted SSH or Unix carrier; use that carrier route or enroll this device for network access",
    upgrade_requires_ssh: "--upgrade requires SSH to be the initial route",
    relay_route_not_candidate: "relay credential route {route} is not one of this connection's route candidates",
    daemon_key_changed: "daemon key changed for {name}",
    known_daemon_refresh_missing: "known daemon disappeared while refreshing its route",
    positional_invitation_rejected: "positional invitations are not accepted; use --invite-file or stdin",
    connect_one_route: "connect accepts one route",
    reconnect_policy_invalid: "reconnect delays, attempt timeout, and enabled heartbeat timeout must be positive; max delay must be at least initial",
    upgrade_no_install: "--upgrade cannot be combined with --no-install",
    json_requires_headless: "--json requires --headless for connect and ssh",
    help_invalid_options: "help cannot be combined with invalid connect options",
    ssh_destination_required: "ssh expects the destination before options",
    ssh_destination_invalid: "invalid SSH destination",
    forward_workspace_required: "forward needs --workspace-root on the daemon",
    forward_port_required: "forward needs --port",
    rpc_request_invalid: "--request is not a WorkspaceRequest JSON object",
    rpc_input_invalid: "invalid WorkspaceRequest",
    rpc_stdin_too_large: "RPC stdin line exceeds {maximum} bytes",
    rpc_stdin_invalid_utf8: "RPC stdin line is not valid UTF-8",
    known_forget_arity: "known-daemons forget expects exactly one fingerprint",
    known_state_dir_unavailable: "cannot determine remote state directory; use --state-dir",
    wireguard_config_unreadable: "cannot read WireGuard config {path}: {error} (the file must be a regular file with owner-only permissions)",
    wireguard_config_invalid: "WireGuard config is not a valid wg-quick file: {error}",
    wireguard_start_failed: "could not start the in-process WireGuard tunnel: {error}",
    wireguard_hub_conflict: "--wireguard-config and --wireguard-hub cannot be combined; one link owns a tunnel or dials through a hub, not both",
    wireguard_hub_serve_failed: "could not serve the WireGuard hub socket: {error}",
    wireguard_hub_signal_failed: "could not wait for the hub shutdown signal: {error}",
    wg_hub_option_required: "wg hub requires {option}",
    wg_hub_help: include_str!("wg_hub_help.en.txt"),
    known_daemon_not_known: "daemon {fingerprint} is not known",
    known_daemon_forgotten: "Forgot daemon {fingerprint}.",
    known_daemons_empty: "No known daemons.",
    known_daemon_auth_enrolled: "enrolled",
    known_daemon_auth_carrier: "carrier",
};

pub(super) const JAPANESE: RemoteClientMessages = RemoteClientMessages {
    connect_help: r#"使用方法: cmux remote connect [ルート] [オプション]

ルート:
  unix:///絶対パス | ssh://[ユーザー@]ホスト[:ポート] | ws:// | wss:// | iroh://
  relay+ws:// | relay+wss:// | relay+https:// | relay+do://

ID とセッション:
  --invite-file パス|-  --daemon フィンガープリント  --carrier
  --device-name 名前  --session 名前
  --state-dir パス  --local-socket パス  --headless [--json]

  --invite-file は一回限りの招待をプロセス引数に公開しません。
  通常ファイルは所有者だけが読める必要があります。- は標準入力から 1 行読みます。
  --carrier は ws ルートをキャリア認証で接続します（登録や招待は不要）。
信頼済みリスナーを持つデーモンだけが受け入れます（例: 所有者のプライベート
ネットワーク経由で到達する cmux Cloud マシン）。

トランスポート:
  --lanes auto|single|isolated  --connect-timeout-seconds 秒数
  単一の明示的なリレールートでは --relay-slot スロットと、
--relay-ticket-file パスまたは --relay-ticket-command プログラムを指定します。
  代替ルートでは --relay-route、--relay-slot、認証情報の組を出現順に最大 4 回指定します。
  --relay-ticket-command-arg 引数  --iroh-relay URL  --iroh-address アドレス
  --iroh-path auto|direct-only|relay-only
  --wireguard-config パス  そのトンネルの AllowedIPs 内の ws ルートを
プロセス内 WireGuard ピア経由で接続します（所有者のみ読める wg-quick ファイル、root 不要）
  --wireguard-hub パス  実行中の `cmux wg hub` ソケット経由で ws ルートに接続します。
--wireguard-config とは併用できません
  --ssh-binary パス  --remote-binary パス  --ssh-arg 引数  --no-install
  --agent-hooks プロバイダー[,プロバイダー...] 接続のたびにリモートユーザーへ
コーディングエージェントのフックを導入 (例: claude,codex)
  --remote-state-dir パス  既定以外のデーモン状態ディレクトリ
  --upgrade は固定済みバイナリのインストール後に SSH 管理のサイドカーを置換します。
ターミナルペインは維持され、リモート RPC 状態はリセットされます。

再接続:
  --reconnect-attempts 回数|unlimited  --reconnect-initial-ms ミリ秒
  --reconnect-max-ms ミリ秒  --reconnect-attempt-timeout-ms ミリ秒
  --reconnect-jitter full|none  --heartbeat-interval-ms ミリ秒
  --heartbeat-timeout-ms ミリ秒
"#,
    ssh_help: r#"使用方法: cmux remote ssh [ユーザー@]ホスト[:ポート] [オプション]

直接 SSH は既定で 1 本の搬送接続を使用します。複数接続を使うには
--lanes auto または isolated を指定します。リモートバイナリを確認し、
--no-install がなければ未導入または非互換時にユーザー領域へインストールします。

オプション:
  --session 名前  --lanes single|auto|isolated  --headless [--json]
  --ssh-binary パス  --remote-binary パス  --ssh-arg 引数  --no-install
  --agent-hooks プロバイダー[,プロバイダー...] 接続のたびにリモートユーザーへ
コーディングエージェントのフックを導入 (例: claude,codex)
  --remote-state-dir パス  既定以外のデーモン状態ディレクトリ
  --upgrade は SSH 管理のサイドカーを明示的に置換します。ターミナルペインは維持され、
リモートクライアントと転送は切断され、RPC プロセスなどの状態はリセットされます。
  --state-dir パス  --local-socket パス  --connect-timeout-seconds 秒数
  --reconnect-attempts 回数|unlimited  --reconnect-initial-ms ミリ秒
  --reconnect-max-ms ミリ秒  --reconnect-attempt-timeout-ms ミリ秒
  --reconnect-jitter full|none  --heartbeat-interval-ms ミリ秒
  --heartbeat-timeout-ms ミリ秒
"#,
    browser_proxy_help: "使用方法: cmux remote browser-proxy [ルート] --allowed-host ホスト [--allowed-host ホスト ...] --workspace-root パス --wireguard-hub パス [オプション]\n\n選択したマシンのループバックポートへの認証付きローカルブラウザプロキシを起動します。非公開のプロキシ認証情報を標準出力に出力します。\n",
    forward_help: r#"使用方法: cmux remote forward [ルート] --workspace-root パス --port ポート [オプション]

オプション:
  --host ホスト  --listen アドレス  --scheme http|https
  `cmux remote connect` の ID、トランスポート、SSH、リレー、Iroh、再接続の
  全オプションも使用できます。
"#,
    rpc_help: r#"使用方法: cmux remote rpc [ルート] [オプション]

標準入力の各行から WorkspaceRequest JSON を 1 件読み、応答を 1 行出力します。
--request JSON は 1 件を送信して終了します。

オプション:
  --request WORKSPACE_REQUEST_JSON
  `cmux remote connect` の ID、トランスポート、SSH、リレー、Iroh、再接続の
  全オプションも使用できます。
"#,
    enroll_help: r#"使用方法: cmux remote enroll 操作 [オプション]

操作:
  status | create | pending | approve ID | deny ID | devices | connections
  revoke DEVICE_ID | disconnect DEVICE_ID SESSION_ID | connect ルート

オプション:
  --session 名前  --state-dir パス  --admin-socket パス  --json
  create: --ttl 秒数  --advertise ルート
  create のリレーアクセスでは --relay-route、--relay-slot、
--relay-ticket-file の組を出現順に最大 2 回指定します。
  connect では `cmux remote connect` の全オプションを使用できます。
"#,
    known_daemons_help: "使用方法: cmux remote known-daemons [list] [--state-dir パス] [--json]\n          cmux remote known-daemons forget フィンガープリント [--state-dir パス] [--json]\n",
    remote_probe_help: "使用方法: cmux-tui remote-probe [--json]\n",
    remote_link_help: "使用方法: cmux-tui remote-link --stdio [--session 名前] [--state-dir パス]\n",
    install_self_help: "使用方法: cmux-tui install-self --destination パス\n",
    command_help: "使用方法: cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [オプション]\n\nコマンド別のルートとオプションは `cmux remote コマンド --help` で表示します。従来のトップレベル別名は互換期間中も使用できます。\n",
    remote_lifecycle_help: "使用方法: cmux remote connect|ssh|forward|rpc [オプション]\n          cmux remote enroll <操作> [オプション]\n          cmux remote known-daemons [オプション]\n          cmux remote stop [オプション]\n\n認証済みリモート操作は `remote` で明示的に指定します。所有プロセスは明示的なリモートフラグを付けた `cmux server start` で起動します。`cmux remote stop` は置換可能な SSH サイドカーだけを管理します。`cmux server start` に組み込まれたリスナーは `cmux server stop` で停止してください。この操作はローカルの所有者とワークスペースも停止します。\n",
    option_needs_value: "{option} には値が必要です",
    invalid_option_value: "{option} の値が無効です。{expected} を指定してください",
    option_must_be_positive: "{option} には正の値を指定してください",
    unknown_option: "不明なオプションです: {option}",
    unknown_option_for_command: "{command} の不明なオプションです: {option}",
    option_once: "{option} は 1 回だけ指定できます",
    unknown_action: "不明な {command} 操作です: {action}",
    enroll_arity: "enroll {action} には位置引数をちょうど {expected} 個指定してください",
    option_create_only: "{option} は enroll create でのみ使用できます",
    inline_invitation_rejected: "招待を引数へ直接指定できません。--invite-file または標準入力を使用してください",
    invitation_path_invalid: "招待パスには所有者専用の通常ファイル、または標準入力を表す - を指定してください",
    invitation_input_read_failed: "招待入力を読み取れませんでした",
    invitation_input_empty: "招待入力が空です",
    invitation_input_too_large: "招待入力が {maximum} バイトの上限を超えています",
    invitation_input_multiline: "招待入力には URI を 1 つだけ含めてください",
    invitation_input_invalid_utf8: "招待入力が有効な UTF-8 ではありません",
    inline_relay_ticket_rejected: "リレーチケットを引数へ直接指定できません。--relay-ticket-file または --relay-ticket-command を使用してください",
    inline_enroll_relay_ticket_rejected: "リレーチケットを引数へ直接指定できません。--relay-ticket-file を使用してください",
    relay_command_arg_order: "--relay-ticket-command-arg は --relay-ticket-command の後に指定してください",
    relay_credentials_require_explicit_route: "--relay-route を指定しないリレー認証情報には、明示的なリレー接続ルートを 1 つ指定してください",
    relay_shorthand_requires_relay_route: "リレー認証情報の短縮形式には明示的なリレールートが必要です。指定されたルート: {route}",
    relay_credential_pair_required: "各リレー認証情報には --relay-slot と認証情報ソースを 1 つずつ指定してください",
    multiple_relay_credentials_require_routes: "複数のリレー認証情報には、認証情報グループごとに --relay-route を 1 つ指定してください",
    route_scoped_relay_credential_pair_required: "ルート別の各リレー認証情報には --relay-route、--relay-slot、認証情報ソースを 1 つずつ指定してください",
    relay_credential_limit: "クライアントが使用できるリレー認証情報は最大 {maximum} 個です",
    relay_route_not_relay: "リレー認証情報のルート {route} はリレールートではありません",
    relay_route_repeated: "リレー認証情報のルート {route} が重複しています",
    invitation_relay_route_repeated: "招待内のリレーブートストラップルート {route} が重複しています",
    relay_route_limit: "招待のブートストラップルートを含め、クライアントが使用できるリレー認証情報ルートは最大 {maximum} 個です",
    invitation_daemon_mismatch: "招待のデーモンフィンガープリントが --daemon {fingerprint} と一致しません",
    invitation_no_routes: "招待に使用可能なルート候補がありません",
    daemon_no_routes: "デーモン {fingerprint} に保存済みルートがありません。ルートを指定するか、再登録してください",
    known_daemon_key_unavailable: "登録済みデーモンの鍵が見つかりません",
    carrier_daemon_requires_carrier: "デーモン {fingerprint} は信頼済みの SSH または Unix 搬送路でのみ登録されています。その搬送路を使用するか、ネットワーク接続用にこのデバイスを登録してください",
    upgrade_requires_ssh: "--upgrade を使用するには最初のルートを SSH にしてください",
    relay_route_not_candidate: "リレー認証情報のルート {route} はこの接続のルート候補に含まれていません",
    daemon_key_changed: "デーモン {name} の鍵が変更されています",
    known_daemon_refresh_missing: "ルートの更新中に登録済みデーモンが見つからなくなりました",
    positional_invitation_rejected: "招待を位置引数へ指定できません。--invite-file または標準入力を使用してください",
    connect_one_route: "connect に指定できるルートは 1 つです",
    reconnect_policy_invalid: "再接続遅延、試行タイムアウト、有効なハートビートタイムアウトには正の値が必要です。最大遅延は初期遅延以上にしてください",
    upgrade_no_install: "--upgrade と --no-install は同時に指定できません",
    json_requires_headless: "connect と ssh で --json を使うには --headless が必要です",
    help_invalid_options: "ヘルプと無効な connect オプションは同時に指定できません",
    ssh_destination_required: "ssh の接続先をオプションより前に指定してください",
    ssh_destination_invalid: "SSH の接続先が無効です",
    forward_workspace_required: "forward にはデーモン上の --workspace-root が必要です",
    forward_port_required: "forward には --port が必要です",
    rpc_request_invalid: "--request は WorkspaceRequest JSON オブジェクトではありません",
    rpc_input_invalid: "WorkspaceRequest が無効です",
    rpc_stdin_too_large: "RPC 標準入力の 1 行が {maximum} バイトの上限を超えています",
    rpc_stdin_invalid_utf8: "RPC 標準入力の行は有効な UTF-8 ではありません",
    known_forget_arity: "known-daemons forget にはフィンガープリントを 1 つ指定してください",
    known_state_dir_unavailable: "リモート状態ディレクトリを特定できません。--state-dir を指定してください",
    wireguard_config_unreadable: "WireGuard 設定 {path} を読めません: {error}（所有者のみ読める通常ファイルが必要です）",
    wireguard_config_invalid: "WireGuard 設定は有効な wg-quick ファイルではありません: {error}",
    wireguard_start_failed: "プロセス内 WireGuard トンネルを開始できませんでした: {error}",
    wireguard_hub_conflict: "--wireguard-config と --wireguard-hub は併用できません。1 つのリンクはトンネルを所有するかハブ経由で接続するかのどちらかです",
    wireguard_hub_serve_failed: "WireGuard ハブソケットを提供できませんでした: {error}",
    wireguard_hub_signal_failed: "ハブの終了シグナルを待機できませんでした: {error}",
    wg_hub_option_required: "wg hub には {option} が必要です",
    wg_hub_help: include_str!("wg_hub_help.ja.txt"),
    known_daemon_not_known: "デーモン {fingerprint} は登録されていません",
    known_daemon_forgotten: "デーモン {fingerprint} を削除しました。",
    known_daemons_empty: "登録済みのデーモンはありません。",
    known_daemon_auth_enrolled: "登録済み",
    known_daemon_auth_carrier: "信頼済み搬送路",
};
