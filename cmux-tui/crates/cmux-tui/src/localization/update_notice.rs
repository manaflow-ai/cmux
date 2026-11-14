//! `update_notice` strings of the CLI catalog (English and Japanese): the
//! line an npm or PyPI install prints on exit when a newer release exists
//! (update_notice.rs). `{latest}`, `{current}` and `{command}` are replaced
//! at the call site; the command stays literal.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UpdateNoticeMessages {
    /// `{latest}` the newer release, `{current}` this one, `{command}` the update command.
    pub available: &'static str,
    /// The TUI attached to a session server of an older build (staged_update.rs):
    /// `{server}` its short commit, `{client}` this client's.
    pub stale_server: &'static str,
    /// A newer build is staged beside this binary and waits for the next
    /// session-server start (staged_update.rs).
    pub staged_waiting: &'static str,
}

pub(super) const ENGLISH: UpdateNoticeMessages = UpdateNoticeMessages {
    available: "cmux {latest} is available (you have {current}). Update: {command}",
    stale_server: "This session server runs an older cmux build ({server}; this client is {client}). It updates the next time the session server starts.",
    staged_waiting: "A newer cmux build is staged. It is installed the next time the session server starts.",
};

pub(super) const JAPANESE: UpdateNoticeMessages = UpdateNoticeMessages {
    available: "cmux {latest} が利用できます (現在 {current})。更新: {command}",
    stale_server: "このセッションサーバーは古い cmux ビルド ({server}) で動いています (このクライアントは {client})。次にセッションサーバーが起動するときに更新されます。",
    staged_waiting: "新しい cmux ビルドが待機しています。次にセッションサーバーが起動するときにインストールされます。",
};
