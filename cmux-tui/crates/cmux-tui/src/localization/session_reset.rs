//! `session_reset` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SessionResetMessages {
    pub help: &'static str,
    pub exact_name_required: &'static str,
    pub non_empty_name_required: &'static str,
    pub no_state_root: &'static str,
    pub confirmation_required: &'static str,
    pub confirmation_recovery: &'static str,
    pub(super) routing_options_unsupported: &'static str,
    pub(super) reset_failed: &'static str,
    pub reason_session_running: &'static str,
    pub recovery_session_running: &'static str,
    pub reason_terminal_hosts_live: &'static str,
    pub recovery_terminal_hosts_live: &'static str,
    pub reason_terminal_hosts_unsupported: &'static str,
    pub recovery_terminal_hosts_unsupported: &'static str,
    pub reason_reset_unsupported: &'static str,
    pub recovery_reset_unsupported: &'static str,
    pub reason_invalid_state_path: &'static str,
    pub recovery_invalid_state_path: &'static str,
    pub reason_state_changed: &'static str,
    pub recovery_state_changed: &'static str,
    pub reason_state_too_large: &'static str,
    pub recovery_state_too_large: &'static str,
    pub reason_filesystem: &'static str,
    pub recovery_filesystem: &'static str,
    pub retry_after_preview: &'static str,
}

impl SessionResetMessages {
    pub(crate) fn routing_options_unsupported(&self, options: &str) -> String {
        self.routing_options_unsupported.replace("{options}", options)
    }

    pub(crate) fn reset_failed(&self, session: &str) -> String {
        self.reset_failed.replace("{session}", session)
    }
}

pub(super) const ENGLISH: SessionResetMessages = SessionResetMessages {
    help: "  cmux session <name> reset-state [--force --confirm-reset <token>] [--state <path>]\n    Preview or confirm a scoped saved-state reset",
    exact_name_required: "session reset-state requires an exact session name",
    non_empty_name_required: "session reset-state requires a non-empty name",
    no_state_root: "cannot determine durable state directory; pass --state <path>",
    confirmation_required: "session reset-state --force requires a confirmation token from preview",
    confirmation_recovery: "rerun without --force, review the scoped targets, then retry with the printed --confirm-reset token",
    routing_options_unsupported: "session reset-state does not accept global routing options: {options}; use --state <path> to select the saved-state root",
    reset_failed: "could not complete saved-state reset for session \"{session}\"",
    reason_session_running: "the session is still running",
    recovery_session_running: "stop the running session before retrying the reset",
    reason_terminal_hosts_live: "terminal hosts are still live or cannot be verified",
    recovery_terminal_hosts_live: "reopen this session with a compatible cmux and stop it cleanly before retrying the reset",
    reason_terminal_hosts_unsupported: "terminal-host liveness cannot be verified on this platform",
    recovery_terminal_hosts_unsupported: "use a platform build that can verify terminal-host liveness, or start a separate session",
    reason_reset_unsupported: "safe saved-state reset is not supported on this platform",
    recovery_reset_unsupported: "use a supported platform build to reset this saved state, or start a separate session",
    reason_invalid_state_path: "the state path is not a directory",
    recovery_invalid_state_path: "rerun the preview with the intended --state path",
    reason_state_changed: "the scoped session state changed during reset",
    recovery_state_changed: "rerun the preview, then retry the reset if the targets are still correct",
    reason_state_too_large: "the scoped session state is too large to confirm safely",
    recovery_state_too_large: "reduce the scoped saved state or retry after a compatible cmux stops the session cleanly",
    reason_filesystem: "the filesystem refused the scoped reset",
    recovery_filesystem: "check permissions and available disk, then retry the reset",
    retry_after_preview: "rerun without --force to inspect the scoped reset plan",
};

pub(super) const JAPANESE: SessionResetMessages = SessionResetMessages {
    help: "  cmux session <name> reset-state [--force --confirm-reset <token>] [--state <path>]\n    スコープ付き保存状態のリセットをプレビューまたは確認実行",
    exact_name_required: "session reset-state には正確なセッション名が必要です",
    non_empty_name_required: "session reset-state には空でない名前が必要です",
    no_state_root: "永続状態ディレクトリを特定できません。--state <path> を指定してください",
    confirmation_required: "session reset-state --force にはプレビューで表示された確認トークンが必要です",
    confirmation_recovery: "--force なしで再実行し、スコープ付き対象を確認してから、表示された --confirm-reset トークンを付けて再試行してください",
    routing_options_unsupported: "session reset-state ではグローバルルーティングオプション {options} を使用できません。保存状態のルートを選択するには --state <path> を使用してください",
    reset_failed: "セッション \"{session}\" の保存状態リセットを完了できませんでした",
    reason_session_running: "セッションがまだ実行中です",
    recovery_session_running: "実行中のセッションを停止してからリセットを再試行してください",
    reason_terminal_hosts_live: "ターミナルホストがまだ動作中、または確認できません",
    recovery_terminal_hosts_live: "互換性のある cmux でこのセッションを再度開き、正常に停止してからリセットを再試行してください",
    reason_terminal_hosts_unsupported: "このプラットフォームではターミナルホストの生存確認ができません",
    recovery_terminal_hosts_unsupported: "ターミナルホストの生存確認に対応したプラットフォームのビルドを使うか、別のセッションを開始してください",
    reason_reset_unsupported: "このプラットフォームでは安全な保存状態リセットに対応していません",
    recovery_reset_unsupported: "対応プラットフォームのビルドで保存状態をリセットするか、別のセッションを開始してください",
    reason_invalid_state_path: "状態パスがディレクトリではありません",
    recovery_invalid_state_path: "意図した --state パスでプレビューを再実行してください",
    reason_state_changed: "スコープ付きセッション状態がリセット中に変更されました",
    recovery_state_changed: "プレビューを再実行し、対象が正しければリセットを再試行してください",
    reason_state_too_large: "スコープ付きセッション状態が大きすぎるため安全に確認できません",
    recovery_state_too_large: "スコープ付き保存状態を減らすか、互換性のある cmux でセッションを正常に停止してから再試行してください",
    reason_filesystem: "ファイルシステムがスコープ付きリセットを拒否しました",
    recovery_filesystem: "権限と空きディスク容量を確認してからリセットを再試行してください",
    retry_after_preview: "--force なしで再実行してスコープ付きリセット計画を確認してください",
};
