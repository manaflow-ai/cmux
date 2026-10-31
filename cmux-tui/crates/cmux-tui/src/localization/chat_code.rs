//! Headless code-block lookup errors, in the CLI's supported languages.

pub(crate) struct ChatCodeText {
    pub flag_value: &'static str,
    pub invalid_page: &'static str,
    pub stalled_cursor: &'static str,
    pub scan_limit: &'static str,
}

static ENGLISH: ChatCodeText = ChatCodeText {
    flag_value: "agents chat read: --last-code-block does not take a value",
    invalid_page: "chat events did not contain a page",
    stalled_cursor: "chat event cursor did not advance",
    scan_limit: "latest code block could not be determined within the chat read limit; read the transcript with chat read and next_after",
};

static JAPANESE: ChatCodeText = ChatCodeText {
    flag_value: "agents chat read: --last-code-block に値は指定できません",
    invalid_page: "チャットイベントの応答にページが含まれていませんでした",
    stalled_cursor: "チャットイベントのカーソルが進みませんでした",
    scan_limit: "チャットの読み取り上限内で最新のコードブロックを特定できませんでした。chat read と next_after を使って会話を読み取ってください",
};

pub(crate) fn text() -> &'static ChatCodeText {
    if super::catalog().japanese { &JAPANESE } else { &ENGLISH }
}
