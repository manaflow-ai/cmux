//! `update_notice` strings of the CLI catalog (English and Japanese): the
//! line an npm or PyPI install prints on exit when a newer release exists
//! (update_notice.rs). `{latest}`, `{current}` and `{command}` are replaced
//! at the call site; the command stays literal.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UpdateNoticeMessages {
    /// `{latest}` the newer release, `{current}` this one, `{command}` the update command.
    pub available: &'static str,
}

pub(super) const ENGLISH: UpdateNoticeMessages = UpdateNoticeMessages {
    available: "cmux {latest} is available (you have {current}). Update: {command}",
};

pub(super) const JAPANESE: UpdateNoticeMessages = UpdateNoticeMessages {
    available: "cmux {latest} が利用できます (現在 {current})。更新: {command}",
};
