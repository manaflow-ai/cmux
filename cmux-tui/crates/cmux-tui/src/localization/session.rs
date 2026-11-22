//! `session` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SessionMessages {
    pub creation_reconciling: &'static str,
    pub operation_reconciling: &'static str,
    pub operation_failed: &'static str,
    pub operation_canceled: &'static str,
    pub mux_subscription_recovered: &'static str,
    pub(super) mux_subscription_recovery_failed: &'static str,
}

impl SessionMessages {
    pub(crate) fn mux_subscription_recovery_failed(&self, error: &str) -> String {
        self.mux_subscription_recovery_failed.replace("{error}", error)
    }
}

pub(super) const ENGLISH: SessionMessages = SessionMessages {
    creation_reconciling: "Session creation may have completed; checking its receipt",
    operation_reconciling: "Session operation may have completed; refreshing the layout",
    operation_failed: "Session operation failed",
    operation_canceled: "Session operation was canceled",
    mux_subscription_recovered: "Mux event backlog overflowed; subscription recovered",
    mux_subscription_recovery_failed: "Mux event backlog recovery failed; queued input was discarded while retrying: {error}",
};

pub(super) const JAPANESE: SessionMessages = SessionMessages {
    creation_reconciling: "セッションの作成が完了している可能性があります。結果を確認しています",
    operation_reconciling: "セッション操作が完了している可能性があります。レイアウトを更新しています",
    operation_failed: "セッション操作に失敗しました",
    operation_canceled: "セッション操作はキャンセルされました",
    mux_subscription_recovered: "Mux イベントの滞留が上限を超えました。購読を復旧しました",
    mux_subscription_recovery_failed: "Mux イベントの滞留から復旧できませんでした。再試行中のキュー入力を破棄しました: {error}",
};
