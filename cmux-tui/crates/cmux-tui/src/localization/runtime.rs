//! `runtime` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RuntimeMessages {
    pub unknown_panic: &'static str,
    pub terminal_capacity_exhausted: &'static str,
    pub(super) renderer_panicked: &'static str,
    pub(super) host_input_failed: &'static str,
    pub(super) session_transport_lost: &'static str,
    pub(super) signal_handlers_failed: &'static str,
    pub(super) terminal_restore_also_failed: &'static str,
}

impl RuntimeMessages {
    pub(crate) fn renderer_panicked(&self, message: &str) -> String {
        self.renderer_panicked.replace("{message}", message)
    }

    pub(crate) fn host_input_failed(&self, error: &str) -> String {
        self.host_input_failed.replace("{error}", error)
    }

    pub(crate) fn session_transport_lost(&self) -> String {
        self.session_transport_lost.to_owned()
    }

    pub(crate) fn signal_handlers_failed(&self, error: &str) -> String {
        self.signal_handlers_failed.replace("{error}", error)
    }

    pub(crate) fn terminal_restore_also_failed(&self, error: &str, restore_error: &str) -> String {
        self.terminal_restore_also_failed
            .replace("{error}", error)
            .replace("{restore_error}", restore_error)
    }
}

pub(super) const ENGLISH: RuntimeMessages = RuntimeMessages {
    unknown_panic: "unknown panic",
    terminal_capacity_exhausted: "No pseudo-terminals are available. Close an unused terminal session, then retry.",
    renderer_panicked: "terminal renderer panicked: {message}",
    host_input_failed: "host terminal input failed: {error}",
    session_transport_lost: "session connection lost. Reconnect and retry.",
    signal_handlers_failed: "failed to install signal handlers: {error}",
    terminal_restore_also_failed: "{error}; host terminal restoration also failed: {restore_error}",
};

pub(super) const JAPANESE: RuntimeMessages = RuntimeMessages {
    unknown_panic: "不明なパニック",
    terminal_capacity_exhausted: "疑似ターミナルの空きがありません。不要なターミナルセッションを閉じてから再試行してください。",
    renderer_panicked: "ターミナル描画処理でパニックが発生しました: {message}",
    host_input_failed: "ホストターミナルの入力に失敗しました: {error}",
    session_transport_lost: "セッションへの接続が失われました。再接続して再試行してください。",
    signal_handlers_failed: "シグナルハンドラーの設定に失敗しました: {error}",
    terminal_restore_also_failed: "{error}; ホストターミナルの復元にも失敗しました: {restore_error}",
};
