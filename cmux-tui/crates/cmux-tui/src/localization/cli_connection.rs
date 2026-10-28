//! `cli_connection` strings of the CLI catalog (English and Japanese): why a
//! resource command could not reach its session, and the command that fixes it.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CliConnectionMessages {
    pub(super) not_running: &'static str,
    pub(super) stale: &'static str,
    pub(super) other: &'static str,
    pub(super) no_answer: &'static str,
    pub(super) wrong_protocol: &'static str,
    pub(super) busy: &'static str,
    pub(super) unexpected_envelope: &'static str,
    pub(super) app_socket_only: &'static str,
}

impl CliConnectionMessages {
    /// `{socket}` cannot be connected to. `refused` is a socket file with no
    /// listener; `missing` is no socket file at all.
    pub fn connect_failed(
        &self,
        socket: &str,
        missing: bool,
        refused: bool,
        error: &str,
    ) -> String {
        let template = match (missing, refused) {
            (true, _) => self.not_running,
            (false, true) => self.stale,
            (false, false) => self.other,
        };
        template.replace("{socket}", socket).replace("{error}", error)
    }

    pub fn no_answer(&self) -> &'static str {
        self.no_answer
    }

    pub fn wrong_protocol(&self) -> &'static str {
        self.wrong_protocol
    }

    /// The session refused the connection: it is at its connection limit.
    pub fn busy(&self) -> &'static str {
        self.busy
    }

    /// A cmux.protocol/2 envelope of type `{kind}` this command does not expect.
    pub fn unexpected_envelope(&self, kind: &str) -> String {
        self.unexpected_envelope.replace("{kind}", kind)
    }

    /// `CMUX_SOCKET_PATH` names an app socket, and nothing names its session.
    pub fn app_socket_only(&self) -> &'static str {
        self.app_socket_only
    }
}

pub(super) const ENGLISH: CliConnectionMessages = CliConnectionMessages {
    not_running: "no cmux session is running at {socket}; start one with `cmux daemon ensure` (pass the same --session or --socket)",
    stale: "{socket} is stale: no session is listening on it; start the session with `cmux daemon ensure` (pass the same --session or --socket)",
    other: "cannot connect to session socket {socket}: {error}",
    no_answer: "the session did not answer in time; check it with `cmux daemon status`, or pass the right --socket",
    wrong_protocol: "the server on this socket does not speak cmux.protocol/2: it is an older cmux or another program; restart the session with this cmux, or pass the right --socket",
    busy: "the session is busy: it refused this connection at its connection limit; retry (check it with `cmux daemon status`)",
    unexpected_envelope: "the session sent a cmux.protocol/2 \"{kind}\" envelope where a reply was expected; retry",
    app_socket_only: "CMUX_SOCKET_PATH names a cmux app socket, and nothing names that app's session (no CMUX_BUNDLE_ID or CMUX_TAG); pass --socket or --session, or set CMUX_TUI_SOCKET. cmux tried no other socket",
};

pub(super) const JAPANESE: CliConnectionMessages = CliConnectionMessages {
    not_running: "{socket} で実行中の cmux セッションはありません。`cmux daemon ensure` で開始してください (同じ --session または --socket を指定)",
    stale: "{socket} は古いソケットです。待ち受けているセッションがありません。`cmux daemon ensure` でセッションを開始してください (同じ --session または --socket を指定)",
    other: "セッションソケット {socket} に接続できません: {error}",
    no_answer: "セッションが時間内に応答しませんでした。`cmux daemon status` で確認するか、正しい --socket を指定してください",
    wrong_protocol: "このソケットのサーバーは cmux.protocol/2 を話しません。古い cmux か別のプログラムです。この cmux でセッションを再起動するか、正しい --socket を指定してください",
    busy: "セッションが混雑しています。接続数の上限に達したため、この接続を拒否しました。再試行してください (`cmux daemon status` で確認できます)",
    unexpected_envelope: "応答が必要な箇所で、セッションが cmux.protocol/2 の \"{kind}\" エンベロープを送信しました。再試行してください",
    app_socket_only: "CMUX_SOCKET_PATH は cmux アプリのソケットを指定していますが、そのアプリのセッションを指定するものがありません (CMUX_BUNDLE_ID も CMUX_TAG もありません)。--socket か --session を指定するか、CMUX_TUI_SOCKET を設定してください。cmux は他のソケットを試していません",
};
