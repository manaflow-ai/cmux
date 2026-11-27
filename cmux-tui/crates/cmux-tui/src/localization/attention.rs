//! `attention` strings of the CLI catalog (English and Japanese): the
//! attention jump and list in the TUI (`app/attention_jump.rs`).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AttentionMessages {
    /// Toast when the jump key finds no tab that needs the person.
    pub nothing: &'static str,
    /// Title of the searchable attention list.
    pub list_title: &'static str,
    /// Placeholder of the list's filter field.
    pub filter_placeholder: &'static str,
    /// Row detail of a tab whose agent waits on the person.
    pub blocked: &'static str,
    /// Row detail of a tab with an unread notification.
    pub unread: &'static str,
    /// Toast when the chosen tab closed after the list opened.
    pub gone: &'static str,
}

pub(super) const ENGLISH: AttentionMessages = AttentionMessages {
    nothing: "Nothing needs you",
    list_title: "Needs you",
    filter_placeholder: "type to filter",
    blocked: "waiting on you",
    unread: "unread",
    gone: "That tab is closed",
};

pub(super) const JAPANESE: AttentionMessages = AttentionMessages {
    nothing: "対応が必要なタブはありません",
    list_title: "対応が必要",
    filter_placeholder: "入力して絞り込む",
    blocked: "あなたの応答待ち",
    unread: "未読",
    gone: "そのタブは閉じられています",
};
