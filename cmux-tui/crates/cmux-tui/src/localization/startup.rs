//! `startup` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct StartupMessages {
    pub(super) schema_too_new: &'static str,
    pub invalid_session_name: &'static str,
    pub duplicate_attach: &'static str,
    pub session_socket: &'static str,
    pub stop_newer_server: &'static str,
    pub no_server_listening: &'static str,
    pub reset_saved_state: &'static str,
    pub reset_saved_state_unsupported: &'static str,
    pub forced_handoff_unsupported: &'static str,
    pub different_server: &'static str,
    pub server_not_verified: &'static str,
    pub saved_state_requires_newer: &'static str,
    pub start_separate_session: &'static str,
}

impl StartupMessages {
    pub(crate) fn schema_too_new(&self, session: &str, version: &str) -> String {
        self.schema_too_new.replace("{version}", version).replace("{session}", session)
    }
}

pub(super) const ENGLISH: StartupMessages = StartupMessages {
    schema_too_new: "cannot open session \"{session}\" with cmux {version}: its saved state is incompatible with this build",
    invalid_session_name: "The session name must be one path component without separators or control characters",
    duplicate_attach: "attach may be supplied only once",
    session_socket: "session socket",
    stop_newer_server: "a newer cmux server owns this saved session; stop it before retrying:",
    no_server_listening: "no server is listening on this socket",
    reset_saved_state: "inspect this session's incompatible saved state reset plan:",
    reset_saved_state_unsupported: "scoped saved-state reset is not supported on this platform; no reset command is shown",
    forced_handoff_unsupported: "this server cannot accept a safe forced shutdown command; use the newer cmux build that started it to stop the session",
    different_server: "this socket belongs to a different cmux session; no shutdown command is shown",
    server_not_verified: "cmux could not verify which session owns this socket; no shutdown command is shown",
    saved_state_requires_newer: "the saved state still requires a newer cmux; upgrade cmux to reopen this session",
    start_separate_session: "or start this build in a separate session:",
};

pub(super) const JAPANESE: StartupMessages = StartupMessages {
    schema_too_new: "cmux {version} ではセッション \"{session}\" を開けません。保存状態はこのビルドと互換性がありません",
    invalid_session_name: "セッション名には、区切り文字や制御文字を含まない 1 つのパス要素を指定してください",
    duplicate_attach: "attach は 1 回だけ指定できます",
    session_socket: "セッションソケット",
    stop_newer_server: "新しい cmux サーバーがこの保存済みセッションを所有しています。再試行する前に停止:",
    no_server_listening: "このソケットを待ち受けているサーバーはありません",
    reset_saved_state: "このセッションの互換性のない保存状態のリセット計画を確認:",
    reset_saved_state_unsupported: "このプラットフォームではスコープ付き保存状態リセットに対応していないため、リセットコマンドは表示しません",
    forced_handoff_unsupported: "このサーバーは安全な強制停止コマンドに対応していません。セッションを停止するには、起動に使用した新しい cmux ビルドを使用してください",
    different_server: "このソケットは別の cmux セッションに属しています。シャットダウンコマンドは表示しません",
    server_not_verified: "このソケットを所有するセッションを確認できませんでした。シャットダウンコマンドは表示しません",
    saved_state_requires_newer: "保存状態には新しい cmux が必要です。このセッションを再度開くには cmux をアップグレードしてください",
    start_separate_session: "または、このビルドを別のセッションで開始:",
};
