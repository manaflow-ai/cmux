use std::io::{Cursor, Write};
use std::sync::OnceLock;

use cmux_tui_machine_protocol::provider_action_id;
use unicode_width::UnicodeWidthStr;

use crate::config::Action;

const FOREIGN_VIEWPORT_HINT_CAPACITY: usize = 64;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PairingMessages {
    pub title: &'static str,
    pub confirm: &'static str,
    pub peer_prefix: &'static str,
    pub deny: &'static str,
    pub approve: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ForeignViewportMessages {
    pub terminal_grid: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MachineAgentMessages {
    pub help: &'static str,
    pub usage: &'static str,
    pub pairing_code: &'static str,
    pub registered: &'static str,
    pub retrying: &'static str,
    pub migration_failed: &'static str,
    pub pairing_code_unavailable: &'static str,
    pub runtime_failed: &'static str,
    pub invalid_session: &'static str,
    pub identity_unavailable: &'static str,
    pub registration_already_running: &'static str,
    pub cloud_configuration_invalid: &'static str,
    pub argument_needs_value: &'static str,
    pub invalid_cloud_port: &'static str,
    pub cloud_port_cannot_be_zero: &'static str,
    pub unknown_argument: &'static str,
}

impl MachineAgentMessages {
    pub(crate) fn retrying_message(&self, milliseconds: u128) -> String {
        self.retrying.replace("{milliseconds}", &milliseconds.to_string())
    }

    pub(crate) fn argument_needs_value_message(&self, argument: &str) -> String {
        self.argument_needs_value.replace("{argument}", argument)
    }

    pub(crate) fn invalid_cloud_port_message(&self, value: &str) -> String {
        self.invalid_cloud_port.replace("{value}", value)
    }

    pub(crate) fn unknown_argument_message(&self, argument: &str) -> String {
        self.unknown_argument.replace("{argument}", argument)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MenuMessages {
    pub maximize_pane: &'static str,
    pub restore_pane_layout: &'static str,
    pub show_sidebar: &'static str,
    pub hide_sidebar: &'static str,
    pub compact_sidebar: &'static str,
    pub full_sidebar: &'static str,
    pub focus_sidebar: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ShortcutMessages {
    pub title: &'static str,
    pub close_button: &'static str,
    pub footer: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LayoutMessages {
    pub startup_shortcuts: &'static str,
    pub verb_help_heading: &'static str,
    pub new_pane_right_help: &'static str,
    pub set_viewport_pane_width_help: &'static str,
    pub undo_layout_help: &'static str,
    pub create_viewport_pane_operation: &'static str,
    pub undo_layout_operation: &'static str,
    pub resize_exact_split_operation: &'static str,
    pub split_id_subject: &'static str,
    pub resize_viewport_pane_operation: &'static str,
    pub viewport_pane_subject: &'static str,
    pub remote_viewport_panes_unsupported: &'static str,
    pub viewport_width_out_of_range: &'static str,
    pane_without_resizable_column: &'static str,
    pub remote_viewport_resize_unsupported: &'static str,
    pub remote_layout_undo_unsupported: &'static str,
    pub layout_undo_missing_screen: &'static str,
    pub layout_undo_missing_revision: &'static str,
    pub layout_undo_missing_closes_panes: &'static str,
    pub layout_undo_invalid_pane: &'static str,
    pub layout_undo_missing_outcome: &'static str,
    pub layout_undo_confirmation_flags_together: &'static str,
    pub layout_changed_before_undo: &'static str,
    unknown_split: &'static str,
    unknown_pane_split: &'static str,
    unrepresentable_viewport_width: &'static str,
    unrepresentable_viewport_ratio: &'static str,
    pub viewport_ratio_target_missing: &'static str,
    pub viewport_ratio_out_of_range: &'static str,
    pub viewport_column_missing: &'static str,
    unsupported_server_command: &'static str,
    layout_undo_applied: &'static str,
    layout_undo_confirmation_required: &'static str,
}

impl LayoutMessages {
    pub(crate) fn pane_without_resizable_column(&self, pane: u64) -> String {
        self.pane_without_resizable_column.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unknown_split(&self, split: u64) -> String {
        self.unknown_split.replace("{split}", &split.to_string())
    }

    pub(crate) fn unknown_pane_split(&self, pane: u64) -> String {
        self.unknown_pane_split.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unrepresentable_viewport_width(
        &self,
        split: u64,
        ratio: f32,
        width: f32,
    ) -> String {
        self.unrepresentable_viewport_width
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
            .replace("{width}", &width.to_string())
    }

    pub(crate) fn unrepresentable_viewport_ratio(&self, split: u64, ratio: f32) -> String {
        self.unrepresentable_viewport_ratio
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
    }

    pub(crate) fn unsupported_server_command(&self, command: &str) -> String {
        self.unsupported_server_command.replace("{command}", command)
    }

    pub(crate) fn layout_undo_applied(&self, screen: u64, revision: u64) -> String {
        self.layout_undo_applied
            .replace("{screen}", &screen.to_string())
            .replace("{revision}", &revision.to_string())
    }

    pub(crate) fn layout_undo_confirmation_required(&self, revision: u64, panes: &str) -> String {
        self.layout_undo_confirmation_required
            .replace("{revision}", &revision.to_string())
            .replace("{panes}", panes)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RuntimeMessages {
    pub unknown_panic: &'static str,
    renderer_panicked: &'static str,
    host_input_failed: &'static str,
    terminal_restore_also_failed: &'static str,
}

impl RuntimeMessages {
    pub(crate) fn renderer_panicked(&self, message: &str) -> String {
        self.renderer_panicked.replace("{message}", message)
    }

    pub(crate) fn host_input_failed(&self, error: &str) -> String {
        self.host_input_failed.replace("{error}", error)
    }

    pub(crate) fn terminal_restore_also_failed(&self, error: &str, restore_error: &str) -> String {
        self.terminal_restore_also_failed
            .replace("{error}", error)
            .replace("{restore_error}", restore_error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AttachMessages {
    pub filtered_subscription_unavailable: &'static str,
    unknown_terminal_prefix: &'static str,
    unknown_terminal_suffix: &'static str,
    ambiguous_terminal_prefix: &'static str,
    ambiguous_terminal_suffix: &'static str,
    browser_terminal_prefix: &'static str,
    browser_terminal_suffix: &'static str,
}

impl AttachMessages {
    pub fn unknown_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.unknown_terminal_prefix, self.unknown_terminal_suffix)
    }

    pub fn ambiguous_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.ambiguous_terminal_prefix, self.ambiguous_terminal_suffix)
    }

    pub fn browser_not_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.browser_terminal_prefix, self.browser_terminal_suffix)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SidebarMessages {
    pub machines: &'static str,
    pub workspaces: &'static str,
    pub new_machine: &'static str,
    pub connect_machine: &'static str,
    pub no_machines: &'static str,
    pub recoverable_machine: &'static str,
    pub rename_machine: &'static str,
    pub delete_machine: &'static str,
    pub restore_machine: &'static str,
    pub purge_machine: &'static str,
    pub confirm_delete_machine: &'static str,
    pub confirm_purge_machine: &'static str,
    pub new_workspace: &'static str,
    pub new_isolated_workspace: &'static str,
    pub new_shared_workspace: &'static str,
    pub recoverable_workspace: &'static str,
    pub rename_workspace: &'static str,
    pub delete_workspace: &'static str,
    pub restore_workspace: &'static str,
    pub purge_workspace: &'static str,
    pub confirm_purge_workspace: &'static str,
    pub no_active_session: &'static str,
    pub managed_workspace_unsupported: &'static str,
    pub managed_workspace_machine_inactive: &'static str,
    pub managed_workspace_unavailable: &'static str,
    pub managed_workspace_operation_not_allowed: &'static str,
    pub running: &'static str,
    pub connecting: &'static str,
    pub sleeping: &'static str,
    pub stopped: &'static str,
    pub unavailable: &'static str,
    pub connect_prompt: &'static str,
    pub connect_host_prompt: &'static str,
    pub personal_scope: &'static str,
    pub team_scope: &'static str,
    pub scope: &'static str,
    pub provider_actions: &'static str,
    pub action_required: &'static str,
    pub action_too_long: &'static str,
    pub action_invalid_email: &'static str,
    pub action_invalid_integer: &'static str,
    pub action_below_minimum: &'static str,
    pub action_above_maximum: &'static str,
    pub action_missing_selected_machine: &'static str,
    pub action_missing_selected_workspace: &'static str,
    pub action_multiple_fields_unsupported: &'static str,
    pub action_list_workspace_ports: &'static str,
    pub action_make_workspace_port_public: &'static str,
    pub action_make_workspace_port_private: &'static str,
    pub action_open_private_workspace_port: &'static str,
    pub action_workspace_port: &'static str,
    pub confirm_destructive_action: &'static str,
    pub confirm_layout_undo: &'static str,
    pub confirmation_mismatch: &'static str,
    pub layout_nothing_to_undo: &'static str,
    pub layout_undo_stale: &'static str,
    pub initial_machine_connection_failed: &'static str,
    pub machine_provider_disconnected: &'static str,
    pub machine_action_failed: &'static str,
    pub provider_action_open_url: &'static str,
    pub machine_provider_update_failed: &'static str,
    pub machine_provider_lifecycle_update_failed: &'static str,
    pub machine_provider_workspace_update_failed: &'static str,
    pub machine_reconnect_failed: &'static str,
    pub machine_terminal_colors_failed: &'static str,
    pub machine_provider_external_connect_unsupported: &'static str,
    pub machine_provider_external_connect_ambiguous: &'static str,
    pub machine_not_ready_to_connect: &'static str,
    pub machine_managed_authority_unsupported: &'static str,
    pub machine_managed_authority_invalid: &'static str,
    pub machine_catalog_create_unsupported: &'static str,
    pub machine_catalog_provider_actions_unsupported: &'static str,
    pub machine_catalog_updates_failed: &'static str,
    pub machine_catalog_restart_failed: &'static str,
    pub machine_replacement_pending: &'static str,
    pub machine_replacement_worker_stopped: &'static str,
    pub machine_replacement_stale: &'static str,
    pub machine_replacement_not_pending: &'static str,
    pub machine_replacement_target_missing: &'static str,
}

impl SidebarMessages {
    pub(crate) fn provider_action_label(&self, action_id: &str) -> Option<&'static str> {
        match action_id {
            provider_action_id::LIST_WORKSPACE_PORTS => Some(self.action_list_workspace_ports),
            provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC => {
                Some(self.action_make_workspace_port_public)
            }
            provider_action_id::MAKE_WORKSPACE_PORT_PRIVATE => {
                Some(self.action_make_workspace_port_private)
            }
            provider_action_id::OPEN_PRIVATE_WORKSPACE_PORT => {
                Some(self.action_open_private_workspace_port)
            }
            _ => None,
        }
    }

    pub(crate) fn provider_action_field_label(
        &self,
        action_id: &str,
        field_id: &str,
    ) -> Option<&'static str> {
        matches!(
            (action_id, field_id),
            (
                provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC
                    | provider_action_id::MAKE_WORKSPACE_PORT_PRIVATE
                    | provider_action_id::OPEN_PRIVATE_WORKSPACE_PORT,
                "port"
            )
        )
        .then_some(self.action_workspace_port)
    }
}

impl ForeignViewportMessages {
    pub fn hint(&self, cols: u16, rows: u16) -> Option<ForeignViewportHint> {
        let mut bytes = [0_u8; FOREIGN_VIEWPORT_HINT_CAPACITY];
        let len = {
            let mut cursor = Cursor::new(bytes.as_mut_slice());
            write!(&mut cursor, "{} ({cols}x{rows})", self.terminal_grid).ok()?;
            cursor.position() as usize
        };
        Some(ForeignViewportHint { bytes, len })
    }

    pub fn hint_width(&self, cols: u16, rows: u16) -> usize {
        self.terminal_grid.width() + 4 + decimal_width(cols) + decimal_width(rows)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForeignViewportHint {
    bytes: [u8; FOREIGN_VIEWPORT_HINT_CAPACITY],
    len: usize,
}

impl ForeignViewportHint {
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.bytes[..self.len])
            .expect("foreign viewport hint is assembled from UTF-8 strings and ASCII digits")
    }
}

const fn decimal_width(mut value: u16) -> usize {
    let mut width = 1;
    while value >= 10 {
        value /= 10;
        width += 1;
    }
    width
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Catalog {
    japanese: bool,
    pub pairing: PairingMessages,
    pub foreign_viewport: ForeignViewportMessages,
    pub machine_agent: MachineAgentMessages,
    pub menu: MenuMessages,
    pub shortcuts: ShortcutMessages,
    pub layout: LayoutMessages,
    pub runtime: RuntimeMessages,
    pub attach: AttachMessages,
    pub sidebar: SidebarMessages,
}

impl Catalog {
    pub fn action_label(&self, action: Action) -> &'static str {
        let definition = action.definition();
        if self.japanese { definition.label_ja } else { definition.label_en }
    }
}

static ENGLISH: Catalog = Catalog {
    japanese: false,
    pairing: PairingMessages {
        title: "Approve browser?",
        confirm: "Confirm this code matches the browser:",
        peer_prefix: "from",
        deny: "[ Deny esc ]",
        approve: "[ Approve enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "terminal grid" },
    machine_agent: MachineAgentMessages {
        help: "\
cmux machine-agent - share one local cmux session through a remote service

USAGE:
  cmux machine-agent [OPTIONS]

OPTIONS:
  --session <name>         Local cmux session (default: main)
  --socket <path>          Explicit local cmux control socket
  --state <path>           Private machine identity file
  --cloud-host <host>      SSH registration host (default: cmux.cloud)
  --cloud-user <user>      SSH user
  --cloud-port <port>      SSH port
  --cloud-identity <path>  SSH identity file
  -h, --help               Show this help

The agent opens one outbound connection. It never opens a public listener or
edits shell files. Authenticate with the configured host before retrying.
",
        usage: "cmux machine-agent           Share one local session through the configured host",
        pairing_code: "Pairing code",
        registered: "Sharing local cmux session",
        retrying: "Cloud connection lost; retrying in {milliseconds} ms",
        migration_failed: "Could not reconnect the machine; please try again",
        pairing_code_unavailable: "Pairing code could not be displayed securely. Run this command from an interactive terminal and retry",
        runtime_failed: "The machine agent could not start or continue; check its configuration",
        invalid_session: "The session name is invalid; use a short name without spaces or control characters",
        identity_unavailable: "The private machine identity is unavailable; check that --state points to a private writable file",
        registration_already_running: "A machine agent is already sharing this session; stop it before starting another",
        cloud_configuration_invalid: "The cloud connection settings are invalid; check the host, user, port, and identity file",
        argument_needs_value: "Option {argument} needs a value",
        invalid_cloud_port: "Invalid --cloud-port value: {value}",
        cloud_port_cannot_be_zero: "--cloud-port cannot be zero",
        unknown_argument: "Unknown machine-agent argument: {argument}",
    },
    menu: MenuMessages {
        maximize_pane: "Maximize pane",
        restore_pane_layout: "Restore pane layout",
        show_sidebar: "Show sidebar",
        hide_sidebar: "Hide sidebar",
        compact_sidebar: "Use compact sidebar",
        full_sidebar: "Use full sidebar",
        focus_sidebar: "Focus sidebar",
    },
    shortcuts: ShortcutMessages {
        title: "Keyboard shortcuts",
        close_button: "Esc close",
        footer: "↑/↓ or wheel scroll · Esc or ? close",
    },
    layout: LayoutMessages {
        startup_shortcuts: "  g  new 2/3 column right   U    undo layout",
        verb_help_heading: "VERB HELP",
        new_pane_right_help: "Create a viewport pane to the right (default width: two-thirds).",
        set_viewport_pane_width_help: "Set the viewport width of the column containing a pane.",
        undo_layout_help: "Undo the latest structural layout change.",
        create_viewport_pane_operation: "create viewport pane",
        undo_layout_operation: "undo layout",
        resize_exact_split_operation: "resize exact pane split",
        split_id_subject: "split id",
        resize_viewport_pane_operation: "resize viewport pane",
        viewport_pane_subject: "viewport pane",
        remote_viewport_panes_unsupported: "remote cmux server does not support viewport panes; upgrade the server before using new-pane-right",
        viewport_width_out_of_range: "viewport pane width must be between 0.1 and 1.0",
        pane_without_resizable_column: "pane {pane} has no resizable viewport column",
        remote_viewport_resize_unsupported: "remote cmux server does not support viewport pane resizing; upgrade the server",
        remote_layout_undo_unsupported: "remote cmux server does not support layout undo; upgrade the server",
        layout_undo_missing_screen: "layout undo response is missing screen",
        layout_undo_missing_revision: "layout undo response is missing revision",
        layout_undo_missing_closes_panes: "layout undo response is missing closes_panes",
        layout_undo_invalid_pane: "layout undo response contains an invalid pane",
        layout_undo_missing_outcome: "layout undo response has no outcome",
        layout_undo_confirmation_flags_together: "--revision and --confirm-close must be supplied together",
        layout_changed_before_undo: "layout changed before undo",
        unknown_split: "unknown split {split}",
        unknown_pane_split: "unknown pane/split {pane}",
        unrepresentable_viewport_width: "split {split} ratio {ratio} implies viewport width {width}; width must be between 0.1 and 1",
        unrepresentable_viewport_ratio: "split {split} ratio {ratio} cannot be represented as a viewport width between 0.1 and 1",
        viewport_ratio_target_missing: "the pane or split no longer exists",
        viewport_ratio_out_of_range: "the requested ratio cannot be represented by a viewport width between 0.1 and 1",
        viewport_column_missing: "the pane has no resizable viewport column",
        unsupported_server_command: "{command} is not supported by this server",
        layout_undo_applied: "undone screen={screen} revision={revision}",
        layout_undo_confirmation_required: "confirmation required: rerun with --revision {revision} --confirm-close (closes panes {panes})",
    },
    runtime: RuntimeMessages {
        unknown_panic: "unknown panic",
        renderer_panicked: "terminal renderer panicked: {message}",
        host_input_failed: "host terminal input failed: {error}",
        terminal_restore_also_failed: "{error}; host terminal restoration also failed: {restore_error}",
    },
    attach: AttachMessages {
        filtered_subscription_unavailable: "single-terminal attach requires a newer cmux-tui server; restart the session",
        unknown_terminal_prefix: "unknown terminal ",
        unknown_terminal_suffix: "; use `cmux-tui ids` to list surfaces",
        ambiguous_terminal_prefix: "ambiguous terminal reference ",
        ambiguous_terminal_suffix: "; use an unambiguous id from `cmux-tui ids`",
        browser_terminal_prefix: "surface ",
        browser_terminal_suffix: " is a browser, not a terminal",
    },
    sidebar: SidebarMessages {
        machines: "machines",
        workspaces: "workspaces",
        new_machine: "new machine",
        connect_machine: "connect machine",
        no_machines: "no machines",
        recoverable_machine: "recoverable",
        rename_machine: "Rename machine",
        delete_machine: "Delete machine",
        restore_machine: "Restore machine",
        purge_machine: "Delete permanently",
        confirm_delete_machine: "Type CONFIRM to delete this machine after a final snapshot",
        confirm_purge_machine: "Type CONFIRM to permanently delete this machine and its snapshots",
        new_workspace: "new workspace",
        new_isolated_workspace: "new isolated",
        new_shared_workspace: "new shared",
        recoverable_workspace: "recoverable",
        rename_workspace: "Rename workspace",
        delete_workspace: "Delete workspace",
        restore_workspace: "Restore workspace",
        purge_workspace: "Delete permanently",
        confirm_purge_workspace: "Type CONFIRM to permanently delete this workspace",
        no_active_session: "select or create a machine first",
        managed_workspace_unsupported: "this machine provider cannot create managed workspaces",
        managed_workspace_machine_inactive: "No machine is active; select or reconnect this workspace's machine, then retry",
        managed_workspace_unavailable: "Managed workspace details are unavailable; wait for the provider to refresh, then retry",
        managed_workspace_operation_not_allowed: "The provider does not allow this operation for this workspace; use an action shown in its menu",
        running: "running",
        connecting: "connecting",
        sleeping: "sleeping",
        stopped: "stopped",
        unavailable: "unavailable",
        connect_prompt: "Host address or pairing code",
        connect_host_prompt: "Host address",
        personal_scope: "personal",
        team_scope: "team",
        scope: "scope",
        provider_actions: "actions",
        action_required: "This value is required",
        action_too_long: "This value is too long",
        action_invalid_email: "Enter a valid email address",
        action_invalid_integer: "Enter a whole number",
        action_below_minimum: "This number is below the allowed minimum",
        action_above_maximum: "This number is above the allowed maximum",
        action_missing_selected_machine: "Select a machine before running this action",
        action_missing_selected_workspace: "Select a workspace before running this action",
        action_multiple_fields_unsupported: "This action needs a form that this client cannot show",
        action_list_workspace_ports: "List workspace ports",
        action_make_workspace_port_public: "Make workspace port public",
        action_make_workspace_port_private: "Make workspace port private",
        action_open_private_workspace_port: "Open private workspace port",
        action_workspace_port: "Port",
        confirm_destructive_action: "Type CONFIRM to continue",
        confirm_layout_undo: "Type CONFIRM to close pane(s) {items}",
        confirmation_mismatch: "Type CONFIRM exactly to run this action",
        layout_nothing_to_undo: "Nothing to undo",
        layout_undo_stale: "The layout changed; undo was not applied",
        initial_machine_connection_failed: "Could not connect",
        machine_provider_disconnected: "Machine provider disconnected; reconnecting",
        machine_action_failed: "Machine action failed",
        provider_action_open_url: "Open",
        machine_provider_update_failed: "Machine provider update failed",
        machine_provider_lifecycle_update_failed: "Machine provider lifecycle update failed",
        machine_provider_workspace_update_failed: "Machine provider workspace update failed",
        machine_reconnect_failed: "Could not reconnect machine",
        machine_terminal_colors_failed: "Could not apply terminal colors",
        machine_provider_external_connect_unsupported: "This machine provider cannot connect external machines",
        machine_provider_external_connect_ambiguous: "The previous connection attempt may have succeeded; reconnect the provider and retry with the same pairing code",
        machine_not_ready_to_connect: "Selected machine is not ready to connect",
        machine_managed_authority_unsupported: "This provider cannot authorize managed workspace mirrors; upgrade the machine provider",
        machine_managed_authority_invalid: "The machine provider returned an invalid managed workspace authority binding",
        machine_catalog_create_unsupported: "This machine catalog cannot create machines",
        machine_catalog_provider_actions_unsupported: "This machine catalog has no provider actions",
        machine_catalog_updates_failed: "Machine catalog updates could not start",
        machine_catalog_restart_failed: "Machine switched without live catalog updates",
        machine_replacement_pending: "Another machine replacement is already pending",
        machine_replacement_worker_stopped: "Machine replacement worker stopped before commit",
        machine_replacement_stale: "Machine replacement decision is stale",
        machine_replacement_not_pending: "Machine replacement is no longer pending",
        machine_replacement_target_missing: "Machine replacement target is missing",
    },
};

static JAPANESE: Catalog = Catalog {
    japanese: true,
    pairing: PairingMessages {
        title: "ブラウザを承認しますか？",
        confirm: "ブラウザのコードと一致するか確認:",
        peer_prefix: "接続元:",
        deny: "[ 拒否 esc ]",
        approve: "[ 承認 enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "端末グリッド" },
    machine_agent: MachineAgentMessages {
        help: "\
cmux machine-agent - ローカルの cmux セッションをリモートサービス経由で共有

使用方法:
  cmux machine-agent [オプション]

オプション:
  --session <name>         ローカル cmux セッション（既定: main）
  --socket <path>          ローカル cmux 制御ソケットを指定
  --state <path>           非公開のマシン ID ファイル
  --cloud-host <host>      SSH 登録ホスト（既定: cmux.cloud）
  --cloud-user <user>      SSH ユーザー
  --cloud-port <port>      SSH ポート
  --cloud-identity <path>  SSH ID ファイル
  -h, --help               このヘルプを表示

エージェントは外向きの接続を 1 つ開きます。公開リスナーを開いたり、シェルファイル
を編集したりしません。再試行する前に、設定したホストで認証してください。
",
        usage: "cmux machine-agent           設定したホスト経由でローカルセッションを共有",
        pairing_code: "ペアリングコード",
        registered: "ローカル cmux セッションを共有中",
        retrying: "クラウド接続が切断されました。{milliseconds} ミリ秒後に再接続します",
        migration_failed: "マシンを再接続できませんでした。もう一度お試しください",
        pairing_code_unavailable: "ペアリングコードを安全に表示できませんでした。対話型端末でこのコマンドを実行して再試行してください",
        runtime_failed: "machine-agent を開始または続行できませんでした。設定を確認してください",
        invalid_session: "セッション名が無効です。空白や制御文字を含まない短い名前を使用してください",
        identity_unavailable: "非公開のマシン ID を使用できません。--state が非公開で書き込み可能なファイルを指していることを確認してください",
        registration_already_running: "このセッションは別の machine-agent が共有中です。停止してからもう一度開始してください",
        cloud_configuration_invalid: "クラウド接続設定が無効です。ホスト、ユーザー、ポート、ID ファイルを確認してください",
        argument_needs_value: "オプション {argument} には値が必要です",
        invalid_cloud_port: "--cloud-port の値が無効です: {value}",
        cloud_port_cannot_be_zero: "--cloud-port に 0 は指定できません",
        unknown_argument: "不明な machine-agent 引数です: {argument}",
    },
    menu: MenuMessages {
        maximize_pane: "ペインを最大化",
        restore_pane_layout: "ペイン配置を復元",
        show_sidebar: "サイドバーを表示",
        hide_sidebar: "サイドバーを隠す",
        compact_sidebar: "サイドバーをコンパクト表示",
        full_sidebar: "サイドバーを通常表示",
        focus_sidebar: "サイドバーにフォーカス",
    },
    shortcuts: ShortcutMessages {
        title: "キーボードショートカット",
        close_button: "Esc 閉じる",
        footer: "↑/↓ またはホイールでスクロール · Esc または ? で閉じる",
    },
    layout: LayoutMessages {
        startup_shortcuts: "  g  右に 2/3 幅の列を追加   U    レイアウトを元に戻す",
        verb_help_heading: "コマンドヘルプ",
        new_pane_right_help: "右側にビューポートペインを作成（既定の幅: 3 分の 2）。",
        set_viewport_pane_width_help: "ペインを含むビューポート列の幅を設定。",
        undo_layout_help: "直前のレイアウト変更を元に戻す。",
        create_viewport_pane_operation: "ビューポートペインを作成",
        undo_layout_operation: "レイアウトを元に戻す",
        resize_exact_split_operation: "ペイン分割のサイズを変更",
        split_id_subject: "分割 ID",
        resize_viewport_pane_operation: "ビューポートペインのサイズを変更",
        viewport_pane_subject: "ビューポートペイン",
        remote_viewport_panes_unsupported: "リモート cmux サーバーはビューポートペインに対応していません。new-pane-right を使用する前にサーバーをアップグレードしてください",
        viewport_width_out_of_range: "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください",
        pane_without_resizable_column: "ペイン {pane} にはサイズ変更可能なビューポート列がありません",
        remote_viewport_resize_unsupported: "リモート cmux サーバーはビューポートペインのサイズ変更に対応していません。サーバーをアップグレードしてください",
        remote_layout_undo_unsupported: "リモート cmux サーバーはレイアウトの取り消しに対応していません。サーバーをアップグレードしてください",
        layout_undo_missing_screen: "レイアウト取り消し応答にスクリーンがありません",
        layout_undo_missing_revision: "レイアウト取り消し応答にリビジョンがありません",
        layout_undo_missing_closes_panes: "レイアウト取り消し応答に closes_panes がありません",
        layout_undo_invalid_pane: "レイアウト取り消し応答に無効なペインがあります",
        layout_undo_missing_outcome: "レイアウト取り消し応答に結果がありません",
        layout_undo_confirmation_flags_together: "--revision と --confirm-close は同時に指定してください",
        layout_changed_before_undo: "取り消し前にレイアウトが変更されました",
        unknown_split: "分割 {split} が見つかりません",
        unknown_pane_split: "ペインまたは分割 {pane} が見つかりません",
        unrepresentable_viewport_width: "分割 {split} の比率 {ratio} ではビューポート幅が {width} になります。幅は 0.1 から 1 の範囲で指定してください",
        unrepresentable_viewport_ratio: "分割 {split} の比率 {ratio} は 0.1 から 1 の範囲のビューポート幅では表現できません",
        viewport_ratio_target_missing: "対象のペインまたは分割が存在しません",
        viewport_ratio_out_of_range: "指定した比率は 0.1 から 1 の範囲のビューポート幅では表現できません",
        viewport_column_missing: "対象のペインにはサイズ変更可能なビューポート列がありません",
        unsupported_server_command: "{command} はこのサーバーではサポートされていません",
        layout_undo_applied: "元に戻しました screen={screen} revision={revision}",
        layout_undo_confirmation_required: "確認が必要です: --revision {revision} --confirm-close を付けて再実行してください（閉じるペイン: {panes}）",
    },
    runtime: RuntimeMessages {
        unknown_panic: "不明なパニック",
        renderer_panicked: "ターミナル描画処理でパニックが発生しました: {message}",
        host_input_failed: "ホストターミナルの入力に失敗しました: {error}",
        terminal_restore_also_failed: "{error}; ホストターミナルの復元にも失敗しました: {restore_error}",
    },
    attach: AttachMessages {
        filtered_subscription_unavailable: "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください",
        unknown_terminal_prefix: "ターミナル ",
        unknown_terminal_suffix: " が見つかりません。`cmux-tui ids` でサーフェス一覧を確認してください",
        ambiguous_terminal_prefix: "ターミナル参照 ",
        ambiguous_terminal_suffix: " は曖昧です。`cmux-tui ids` に表示される一意の ID を使用してください",
        browser_terminal_prefix: "サーフェス ",
        browser_terminal_suffix: " はブラウザであり、ターミナルではありません",
    },
    sidebar: SidebarMessages {
        machines: "マシン",
        workspaces: "ワークスペース",
        new_machine: "新規マシン",
        connect_machine: "マシンを接続",
        no_machines: "マシンがありません",
        recoverable_machine: "復元可能",
        rename_machine: "マシン名を変更",
        delete_machine: "マシンを削除",
        restore_machine: "マシンを復元",
        purge_machine: "完全に削除",
        confirm_delete_machine: "最終スナップショット後に削除するには CONFIRM と入力してください",
        confirm_purge_machine: "マシンとスナップショットを完全に削除するには CONFIRM と入力してください",
        new_workspace: "新規ワークスペース",
        new_isolated_workspace: "新規隔離",
        new_shared_workspace: "新規共有",
        recoverable_workspace: "復元可能",
        rename_workspace: "ワークスペース名を変更",
        delete_workspace: "ワークスペースを削除",
        restore_workspace: "ワークスペースを復元",
        purge_workspace: "完全に削除",
        confirm_purge_workspace: "完全に削除するには CONFIRM と入力してください",
        no_active_session: "先にマシンを選択または作成してください",
        managed_workspace_unsupported: "このマシンプロバイダーは管理ワークスペースを作成できません",
        managed_workspace_machine_inactive: "アクティブなマシンがありません。このワークスペースのマシンを選択または再接続してから再試行してください",
        managed_workspace_unavailable: "管理ワークスペースの情報を取得できません。プロバイダーの更新後に再試行してください",
        managed_workspace_operation_not_allowed: "プロバイダーはこのワークスペースでこの操作を許可していません。メニューに表示される操作を使用してください",
        running: "実行中",
        connecting: "接続中",
        sleeping: "スリープ中",
        stopped: "停止",
        unavailable: "利用不可",
        connect_prompt: "ホストアドレスまたはペアリングコード",
        connect_host_prompt: "ホストアドレス",
        personal_scope: "個人",
        team_scope: "チーム",
        scope: "スコープ",
        provider_actions: "操作",
        action_required: "この値は必須です",
        action_too_long: "この値は長すぎます",
        action_invalid_email: "有効なメールアドレスを入力してください",
        action_invalid_integer: "整数を入力してください",
        action_below_minimum: "この数値は許可された最小値未満です",
        action_above_maximum: "この数値は許可された最大値を超えています",
        action_missing_selected_machine: "この操作を実行する前にマシンを選択してください",
        action_missing_selected_workspace: "この操作を実行する前にワークスペースを選択してください",
        action_multiple_fields_unsupported: "この操作に必要なフォームをこのクライアントでは表示できません",
        action_list_workspace_ports: "ワークスペースのポートを表示",
        action_make_workspace_port_public: "ワークスペースのポートを公開",
        action_make_workspace_port_private: "ワークスペースのポートを非公開",
        action_open_private_workspace_port: "非公開のワークスペースポートを開く",
        action_workspace_port: "ポート",
        confirm_destructive_action: "続行するには CONFIRM と入力",
        confirm_layout_undo: "ペイン {items} を閉じるには CONFIRM と入力",
        confirmation_mismatch: "この操作を実行するには CONFIRM と正確に入力してください",
        layout_nothing_to_undo: "元に戻せるレイアウト操作はありません",
        layout_undo_stale: "レイアウトが変更されたため、元に戻す操作は適用されませんでした",
        initial_machine_connection_failed: "マシンに接続できませんでした",
        machine_provider_disconnected: "マシンプロバイダーから切断されました。再接続しています",
        machine_action_failed: "マシン操作に失敗しました",
        provider_action_open_url: "リンクを開く",
        machine_provider_update_failed: "マシンプロバイダーの更新に失敗しました",
        machine_provider_lifecycle_update_failed: "マシンプロバイダーのライフサイクル更新に失敗しました",
        machine_provider_workspace_update_failed: "マシンプロバイダーのワークスペース更新に失敗しました",
        machine_reconnect_failed: "マシンに再接続できませんでした",
        machine_terminal_colors_failed: "ターミナルの色を適用できませんでした",
        machine_provider_external_connect_unsupported: "このマシンプロバイダーは外部マシンに接続できません",
        machine_provider_external_connect_ambiguous: "前回の接続処理が完了している可能性があります。プロバイダーを再接続し、同じペアリングコードで再試行してください",
        machine_not_ready_to_connect: "選択したマシンは接続準備ができていません",
        machine_managed_authority_unsupported: "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください",
        machine_managed_authority_invalid: "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました",
        machine_catalog_create_unsupported: "このマシンカタログではマシンを作成できません",
        machine_catalog_provider_actions_unsupported: "このマシンカタログにはプロバイダーアクションがありません",
        machine_catalog_updates_failed: "マシンカタログの更新を開始できませんでした",
        machine_catalog_restart_failed: "マシンは切り替わりましたが、カタログのライブ更新を再開できませんでした",
        machine_replacement_pending: "別のマシン切り替えを処理中です",
        machine_replacement_worker_stopped: "確定前にマシン切り替え処理が停止しました",
        machine_replacement_stale: "マシン切り替えの状態が古くなっています",
        machine_replacement_not_pending: "保留中のマシン切り替えがありません",
        machine_replacement_target_missing: "マシン切り替え先が見つかりません",
    },
};

pub(crate) fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<&'static Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| catalog_for_locale(&system_locale()))
}

pub(crate) fn catalog_for_locale(locale: &str) -> &'static Catalog {
    if locale.to_ascii_lowercase().starts_with("ja") { &JAPANESE } else { &ENGLISH }
}

fn system_locale() -> String {
    std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LC_MESSAGES"))
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locale_tags_select_complete_catalogs() {
        assert_eq!(catalog_for_locale("en_US.UTF-8"), &ENGLISH);
        assert_eq!(catalog_for_locale("ja_JP.UTF-8"), &JAPANESE);
        assert_eq!(catalog_for_locale("C"), &ENGLISH);
        assert_eq!(ENGLISH.menu.maximize_pane, "Maximize pane");
        assert_eq!(JAPANESE.menu.maximize_pane, "ペインを最大化");
        assert_eq!(ENGLISH.action_label(Action::NewPaneSmart), "New pane");
        assert_eq!(JAPANESE.action_label(Action::NewPaneSmart), "新しいペイン");
        assert_eq!(ENGLISH.shortcuts.title, "Keyboard shortcuts");
        assert_eq!(JAPANESE.shortcuts.title, "キーボードショートカット");
        assert_eq!(ENGLISH.shortcuts.close_button, "Esc close");
        assert_eq!(JAPANESE.shortcuts.close_button, "Esc 閉じる");
        assert_eq!(
            JAPANESE.attach.filtered_subscription_unavailable,
            "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください"
        );
        assert_eq!(
            ENGLISH.attach.unknown_terminal("missing"),
            "unknown terminal \"missing\"; use `cmux-tui ids` to list surfaces"
        );
        assert_eq!(
            JAPANESE.attach.ambiguous_terminal("000010"),
            "ターミナル参照 \"000010\" は曖昧です。`cmux-tui ids` に表示される一意の ID を使用してください"
        );
        assert_eq!(
            JAPANESE.attach.browser_not_terminal("browser"),
            "サーフェス \"browser\" はブラウザであり、ターミナルではありません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_disconnected,
            "マシンプロバイダーから切断されました。再接続しています"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").machine_agent.pairing_code, "Pairing code");
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.retrying_message(250),
            "Cloud connection lost; retrying in 250 ms"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.pairing_code,
            "ペアリングコード"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.retrying_message(250),
            "クラウド接続が切断されました。250 ミリ秒後に再接続します"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.migration_failed,
            "Could not reconnect the machine; please try again"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.migration_failed,
            "マシンを再接続できませんでした。もう一度お試しください"
        );
        assert!(
            catalog_for_locale("en_US.UTF-8")
                .machine_agent
                .help
                .contains("share one local cmux session through a remote service")
        );
        assert!(
            catalog_for_locale("ja_JP.UTF-8")
                .machine_agent
                .help
                .contains("ローカルの cmux セッションをリモートサービス経由で共有")
        );
        assert!(!catalog_for_locale("en_US.UTF-8").machine_agent.help.contains("BatchMode"));
        assert!(!catalog_for_locale("ja_JP.UTF-8").machine_agent.help.contains("BatchMode"));
        assert!(
            catalog_for_locale("en_US.UTF-8")
                .machine_agent
                .pairing_code_unavailable
                .contains("interactive terminal")
        );
        assert!(
            catalog_for_locale("ja_JP.UTF-8")
                .machine_agent
                .pairing_code_unavailable
                .contains("対話型端末")
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
            "Invalid --cloud-port value: invalid"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
            "--cloud-port の値が無効です: invalid"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.machine_action_failed,
            "Machine action failed"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.connect_prompt,
            "Host address or pairing code"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.new_machine, "new machine");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.new_machine, "新規マシン");
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.connect_prompt,
            "ホストアドレスまたはペアリングコード"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.connect_host_prompt, "Host address");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.connect_host_prompt, "ホストアドレス");
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_action_failed,
            "マシン操作に失敗しました"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_external_connect_ambiguous,
            "前回の接続処理が完了している可能性があります。プロバイダーを再接続し、同じペアリングコードで再試行してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_stale,
            "マシン切り替えの状態が古くなっています"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_catalog_updates_failed,
            "マシンカタログの更新を開始できませんでした"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_worker_stopped,
            "確定前にマシン切り替え処理が停止しました"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_not_ready_to_connect,
            "選択したマシンは接続準備ができていません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_unsupported,
            "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_invalid,
            "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.confirm_layout_undo,
            "Type CONFIRM to close pane(s) {items}"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.confirm_layout_undo,
            "ペイン {items} を閉じるには CONFIRM と入力"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.layout_nothing_to_undo,
            "元に戻せるレイアウト操作はありません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.layout_undo_stale,
            "レイアウトが変更されたため、元に戻す操作は適用されませんでした"
        );
        let japanese_layout = &catalog_for_locale("ja_JP.UTF-8").layout;
        assert_eq!(
            japanese_layout.viewport_width_out_of_range,
            "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください"
        );
        assert_eq!(
            japanese_layout.pane_without_resizable_column(42),
            "ペイン 42 にはサイズ変更可能なビューポート列がありません"
        );
        assert_eq!(
            japanese_layout.unsupported_server_command("undo-layout"),
            "undo-layout はこのサーバーではサポートされていません"
        );
        assert_eq!(japanese_layout.layout_undo_applied(3, 9), "元に戻しました screen=3 revision=9");
        assert_eq!(
            japanese_layout.layout_undo_confirmation_required(8, "15,16"),
            "確認が必要です: --revision 8 --confirm-close を付けて再実行してください（閉じるペイン: 15,16）"
        );
        assert_eq!(
            japanese_layout.layout_undo_confirmation_flags_together,
            "--revision と --confirm-close は同時に指定してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").runtime.renderer_panicked("描画セルが無効"),
            "ターミナル描画処理でパニックが発生しました: 描画セルが無効"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").runtime.host_input_failed("切断"),
            "ホストターミナルの入力に失敗しました: 切断"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8")
                .runtime
                .terminal_restore_also_failed("event loop failed", "restore failed"),
            "event loop failed; host terminal restoration also failed: restore failed"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8")
                .runtime
                .terminal_restore_also_failed("イベントループ失敗", "復元失敗"),
            "イベントループ失敗; ホストターミナルの復元にも失敗しました: 復元失敗"
        );
    }

    #[test]
    fn workspace_port_provider_actions_use_localized_labels() {
        assert_eq!(
            catalog().sidebar.provider_action_label(provider_action_id::LIST_WORKSPACE_PORTS),
            Some(catalog().sidebar.action_list_workspace_ports)
        );
        assert_eq!(
            catalog().sidebar.provider_action_field_label(
                provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC,
                "port"
            ),
            Some(catalog().sidebar.action_workspace_port)
        );
        assert_eq!(catalog().sidebar.provider_action_label("external.action"), None);
    }

    #[test]
    fn foreign_viewport_hints_are_neutral_and_stack_backed() {
        let english = ENGLISH.foreign_viewport.hint(12, 5).expect("English hint fits inline");
        assert_eq!(english.as_str(), "terminal grid (12x5)");
        assert_eq!(english.bytes.len(), 64);
        assert_eq!(ENGLISH.foreign_viewport.hint_width(12, 5), 20);

        let japanese = JAPANESE.foreign_viewport.hint(12, 5).expect("Japanese hint fits inline");
        assert_eq!(japanese.as_str(), "端末グリッド (12x5)");
        assert_eq!(japanese.bytes.len(), 64);
        assert_eq!(JAPANESE.foreign_viewport.hint_width(12, 5), 19);
    }
}
