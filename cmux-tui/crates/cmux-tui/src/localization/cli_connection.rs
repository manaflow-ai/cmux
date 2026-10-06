//! `cli_connection` strings of the CLI catalog (English and Japanese): why a
//! resource command could not reach its session, and the command that fixes it.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CliConnectionMessages {
    pub(super) not_running: &'static str,
    pub(super) stale: &'static str,
    pub(super) other: &'static str,
    pub(super) no_answer: &'static str,
    pub(super) wrong_protocol: &'static str,
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
}

pub(super) const ENGLISH: CliConnectionMessages = CliConnectionMessages {
    not_running: "no cmux session is running at {socket}; start one with `cmux server ensure` (pass the same --session or --socket)",
    stale: "{socket} is stale: no session is listening on it; start the session with `cmux server ensure` (pass the same --session or --socket)",
    other: "cannot connect to session socket {socket}: {error}",
    no_answer: "the session did not answer in time; check it with `cmux server status`, or pass the right --socket",
    wrong_protocol: "the server on this socket does not speak cmux.protocol/2: it is an older cmux or another program; restart the session with this cmux, or pass the right --socket",
};

pub(super) const JAPANESE: CliConnectionMessages = CliConnectionMessages {
    not_running: "{socket} で実行中の cmux セッションはありません。`cmux server ensure` で開始してください (同じ --session または --socket を指定)",
    stale: "{socket} は古いソケットです。待ち受けているセッションがありません。`cmux server ensure` でセッションを開始してください (同じ --session または --socket を指定)",
    other: "セッションソケット {socket} に接続できません: {error}",
    no_answer: "セッションが時間内に応答しませんでした。`cmux server status` で確認するか、正しい --socket を指定してください",
    wrong_protocol: "このソケットのサーバーは cmux.protocol/2 を話しません。古い cmux か別のプログラムです。この cmux でセッションを再起動するか、正しい --socket を指定してください",
};
