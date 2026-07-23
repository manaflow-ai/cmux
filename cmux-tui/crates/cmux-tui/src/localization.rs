use std::io::{Cursor, Write};
use std::sync::OnceLock;

use unicode_width::UnicodeWidthStr;

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
pub(crate) struct TerminalMessages {
    pub clear_history_failed: &'static str,
    pub keyboard_text_too_large: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SidebarMessages {
    pub machines: &'static str,
    pub workspaces: &'static str,
    pub new_vm: &'static str,
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
    pub action_multiple_fields_unsupported: &'static str,
    pub confirm_destructive_action: &'static str,
    pub confirmation_mismatch: &'static str,
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
    pub pairing: PairingMessages,
    pub foreign_viewport: ForeignViewportMessages,
    pub terminal: TerminalMessages,
    pub sidebar: SidebarMessages,
}

static ENGLISH: Catalog = Catalog {
    pairing: PairingMessages {
        title: "Approve browser?",
        confirm: "Confirm this code matches the browser:",
        peer_prefix: "from",
        deny: "[ Deny esc ]",
        approve: "[ Approve enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "terminal grid" },
    terminal: TerminalMessages {
        clear_history_failed: "Could not clear terminal history",
        keyboard_text_too_large: "Keyboard text exceeds the 4 MiB PTY buffer limit",
    },
    sidebar: SidebarMessages {
        machines: "machines",
        workspaces: "workspaces",
        new_vm: "new VM",
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
        connect_prompt: "Connect user@host",
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
        action_multiple_fields_unsupported: "This action needs a form that this client cannot show",
        confirm_destructive_action: "Type CONFIRM to continue",
        confirmation_mismatch: "Type CONFIRM exactly to run this action",
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
        machine_not_ready_to_connect: "Selected machine is not ready to connect",
        machine_managed_authority_unsupported: "This provider cannot authorize managed workspace mirrors; upgrade the machine provider",
        machine_managed_authority_invalid: "The machine provider returned an invalid managed workspace authority binding",
        machine_catalog_create_unsupported: "This machine catalog cannot create VMs",
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
    pairing: PairingMessages {
        title: "ブラウザを承認しますか？",
        confirm: "ブラウザのコードと一致するか確認:",
        peer_prefix: "接続元:",
        deny: "[ 拒否 esc ]",
        approve: "[ 承認 enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "端末グリッド" },
    terminal: TerminalMessages {
        clear_history_failed: "ターミナル履歴を消去できませんでした",
        keyboard_text_too_large: "キーボード入力が 4 MiB の PTY バッファ上限を超えています",
    },
    sidebar: SidebarMessages {
        machines: "マシン",
        workspaces: "ワークスペース",
        new_vm: "新規 VM",
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
        connect_prompt: "user@host に接続",
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
        action_multiple_fields_unsupported: "この操作に必要なフォームをこのクライアントでは表示できません",
        confirm_destructive_action: "続行するには CONFIRM と入力",
        confirmation_mismatch: "この操作を実行するには CONFIRM と正確に入力してください",
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
        machine_not_ready_to_connect: "選択したマシンは接続準備ができていません",
        machine_managed_authority_unsupported: "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください",
        machine_managed_authority_invalid: "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました",
        machine_catalog_create_unsupported: "このマシンカタログでは仮想マシンを作成できません",
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
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.keyboard_text_too_large,
            "キーボード入力が 4 MiB の PTY バッファ上限を超えています"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_disconnected,
            "マシンプロバイダーから切断されました。再接続しています"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.machine_action_failed,
            "Machine action failed"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_action_failed,
            "マシン操作に失敗しました"
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
