//! `notification_banners` strings of the CLI catalog (English and Japanese):
//! the usage errors of `cmux notification banners|open`
//! (`cli/notification_banners.rs`).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct NotificationBannersMessages {
    /// `notification banners` given a word; `{word}` is that word.
    banners_takes_nothing: &'static str,
    /// `notification open` without an id.
    pub open_needs_id: &'static str,
    /// `notification open` with more than one id, or a flag for one.
    pub open_one_id: &'static str,
}

impl NotificationBannersMessages {
    pub(crate) fn banners_takes_nothing(&self, word: &str) -> String {
        self.banners_takes_nothing.replace("{word}", word)
    }
}

pub(super) const ENGLISH: NotificationBannersMessages = NotificationBannersMessages {
    banners_takes_nothing: "notification banners takes no words or flags, not {word}; run `cmux notification --help`",
    open_needs_id: "notification open needs a banner id: run `cmux notification banners` for the ids",
    open_one_id: "notification open takes one banner id and no flags: `cmux notification open <banner-id>`",
};

pub(super) const JAPANESE: NotificationBannersMessages = NotificationBannersMessages {
    banners_takes_nothing: "notification banners は語もフラグも取りません（{word} は不要です）。`cmux notification --help` を実行してください",
    open_needs_id: "notification open にはバナー ID が必要です。`cmux notification banners` で ID を確認してください",
    open_one_id: "notification open はバナー ID を 1 つだけ取り、フラグは取りません: `cmux notification open <banner-id>`",
};
