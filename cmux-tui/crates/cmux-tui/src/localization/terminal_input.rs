//! `terminal_input` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TerminalInputMessages {
    pub too_large: &'static str,
    pub unavailable: &'static str,
    pub confirmation_unsupported: &'static str,
    pub delivery_failed: &'static str,
    /// `{terminal}` and `{command}` are filled in (cli/agent_input_hint.rs).
    pub agent_message_hint: &'static str,
    /// `{terminal}` is filled in (cli/terminal_talk/send.rs).
    pub send_not_submitted: &'static str,
    /// `{waited}` and `{who}` are filled in (cli/agent_start.rs).
    pub resume_not_reported: &'static str,
}

pub(super) const ENGLISH: TerminalInputMessages = TerminalInputMessages {
    too_large: "Terminal input is too large. Send less input at once.",
    unavailable: "The terminal did not take input for 5 seconds: the program in it is not reading its input.",
    confirmation_unsupported: "Input delivery confirmation is unavailable for this terminal: its terminal host is an older build. Start a new terminal session to send it input.",
    delivery_failed: "Terminal input could not be delivered. Check that the terminal is available.",
    agent_message_hint: "{terminal} runs an agent, so this input was typed into its composer. To send it a message instead, run: {command}",
    send_not_submitted: "The message was typed into {terminal}, but the agent did not start a turn: it reported nothing after Enter. If the message is still in its input box, submit it with cmux terminal {terminal} keys enter; then wait with cmux terminal {terminal} wait --until idle. Read the screen first with cmux terminal {terminal} screen read.",
    resume_not_reported: "The resumed agent did not report that it is ready (its SessionStart hook) within {waited}. Read its screen with cmux terminal {who} screen read.",
};

pub(super) const JAPANESE: TerminalInputMessages = TerminalInputMessages {
    too_large: "端末への入力が大きすぎます。一度に送る入力を減らしてください。",
    unavailable: "端末が 5 秒間入力を受け付けませんでした。端末内のプログラムが入力を読み取っていません。",
    confirmation_unsupported: "この端末では入力の送信完了を確認できません。端末ホストが古いビルドです。入力を送るには新しい端末セッションを開始してください。",
    delivery_failed: "端末に入力を送信できませんでした。端末が利用可能か確認してください。",
    agent_message_hint: "{terminal} ではエージェントが動作しているため、この入力はエージェントの入力欄に打ち込まれました。メッセージとして送るには次を実行してください: {command}",
    send_not_submitted: "メッセージは {terminal} に入力されましたが、エージェントはターンを開始しませんでした。Enter の後に何も報告していません。メッセージが入力欄に残っている場合は cmux terminal {terminal} keys enter で送信し、cmux terminal {terminal} wait --until idle で待ってください。先に cmux terminal {terminal} screen read で画面を確認してください。",
    resume_not_reported: "再開したエージェントが {waited} 以内に準備完了を報告しませんでした (SessionStart フック)。cmux terminal {who} screen read で画面を確認してください。",
};
