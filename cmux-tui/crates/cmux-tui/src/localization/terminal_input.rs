//! `terminal_input` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TerminalInputMessages {
    pub too_large: &'static str,
    pub unavailable: &'static str,
    pub confirmation_unsupported: &'static str,
    pub delivery_failed: &'static str,
    /// `{terminal}` and `{command}` are filled in (cli/agent_input_hint.rs).
    pub agent_message_hint: &'static str,
}

pub(super) const ENGLISH: TerminalInputMessages = TerminalInputMessages {
    too_large: "Terminal input is too large. Send less input at once.",
    unavailable: "Terminal input is temporarily unavailable. Try again shortly.",
    confirmation_unsupported: "Input delivery confirmation is unavailable for this terminal: its terminal host is an older build. Start a new terminal session and retry.",
    delivery_failed: "Terminal input could not be delivered. Check that the terminal is available.",
    agent_message_hint: "{terminal} runs an agent, so this input was typed into its composer. To send it a message instead, run: {command}",
};

pub(super) const JAPANESE: TerminalInputMessages = TerminalInputMessages {
    too_large: "端末への入力が大きすぎます。一度に送る入力を減らしてください。",
    unavailable: "現在、端末への入力を受け付けられません。しばらくしてから再試行してください。",
    confirmation_unsupported: "この端末では入力の送信完了を確認できません。端末ホストが古いビルドです。新しい端末セッションを開始してから、もう一度お試しください。",
    delivery_failed: "端末に入力を送信できませんでした。端末が利用可能か確認してください。",
    agent_message_hint: "{terminal} ではエージェントが動作しているため、この入力はエージェントの入力欄に打ち込まれました。メッセージとして送るには次を実行してください: {command}",
};
