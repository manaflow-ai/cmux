//! `runtime` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RuntimeMessages {
    pub unknown_panic: &'static str,
    pub terminal_capacity_exhausted: &'static str,
    pub(super) renderer_panicked: &'static str,
    pub(super) host_input_failed: &'static str,
    pub(super) session_transport_lost: &'static str,
    pub(super) session_reconnecting: &'static str,
    pub(super) session_reconnected: &'static str,
    pub(super) session_reconnect_failed: &'static str,
    pub(super) session_stopped: &'static str,
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

    /// The status line while the client reconnects after its daemon left.
    pub(crate) fn session_reconnecting(&self, session: &str) -> String {
        self.session_reconnecting.replace("{session}", session)
    }

    /// The status line once the client is attached to the new daemon.
    pub(crate) fn session_reconnected(&self, session: &str) -> String {
        self.session_reconnected.replace("{session}", session)
    }

    /// The exit error when no daemon came back within `seconds`.
    pub(crate) fn session_reconnect_failed(
        &self,
        session: &str,
        seconds: u64,
        error: &str,
    ) -> String {
        self.session_reconnect_failed
            .replace("{session}", session)
            .replace("{seconds}", &seconds.to_string())
            .replace("{error}", error)
    }

    /// Printed after the TUI exits because its session was stopped.
    pub(crate) fn session_stopped(&self, session: &str) -> String {
        self.session_stopped.replace("{session}", session)
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
    session_reconnecting: "reconnecting to session {session}…",
    session_reconnected: "reconnected to session {session}",
    session_reconnect_failed: "session {session} did not come back within {seconds} s ({error}). Run `cmux daemon status --session {session}`, then attach again.",
    session_stopped: "session {session} stopped. Its daemon was stopped; run `cmux-tui --session {session}` to start it again.",
    signal_handlers_failed: "failed to install signal handlers: {error}",
    terminal_restore_also_failed: "{error}; host terminal restoration also failed: {restore_error}",
};

pub(super) const JAPANESE: RuntimeMessages = RuntimeMessages {
    unknown_panic: "不明なパニック",
    terminal_capacity_exhausted: "疑似ターミナルの空きがありません。不要なターミナルセッションを閉じてから再試行してください。",
    renderer_panicked: "ターミナル描画処理でパニックが発生しました: {message}",
    host_input_failed: "ホストターミナルの入力に失敗しました: {error}",
    session_transport_lost: "セッションへの接続が失われました。再接続して再試行してください。",
    session_reconnecting: "セッション {session} に再接続しています…",
    session_reconnected: "セッション {session} に再接続しました",
    session_reconnect_failed: "セッション {session} が {seconds} 秒以内に戻りませんでした（{error}）。`cmux daemon status --session {session}` を実行してから、もう一度接続してください。",
    session_stopped: "セッション {session} は停止しました。デーモンが停止されました。`cmux-tui --session {session}` で再び起動できます。",
    signal_handlers_failed: "シグナルハンドラーの設定に失敗しました: {error}",
    terminal_restore_also_failed: "{error}; ホストターミナルの復元にも失敗しました: {restore_error}",
};
