//! Refusal codes: the raw values of CmuxNextAgentPane `AgentPaneTransportError`
//! (AgentPaneTransportTypes.swift) that the frame rules give.

/// Why a page frame was refused. The code is what the page reads in the refusal
/// frame's `error.data.code`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Refusal {
    InvalidFrame,
    FrameTooLarge,
    FirstFrameNotInitialize,
    MethodRefused,
    IntentInvalid,
    DuplicateKey,
    McpServersRefused,
    SessionNotInPane,
    /// The user did not enable a folder harness on the host's sheet
    /// (`_acpmux/harness_enable`; the host decides, see `Facts::harness_enable`).
    HarnessNotConfirmed,
    /// A frame of a click-only method that needs a gesture came without the
    /// person's click (`policy.json` `click_only`, [`crate::gesture::Gesture`]).
    GestureRequired,
}

impl Refusal {
    pub fn code(self) -> &'static str {
        match self {
            Refusal::InvalidFrame => "transport.invalid_frame",
            Refusal::FrameTooLarge => "transport.frame_too_large",
            Refusal::FirstFrameNotInitialize => "transport.first_frame",
            Refusal::MethodRefused => "transport.method_refused",
            Refusal::IntentInvalid => "transport.intent_invalid",
            Refusal::DuplicateKey => "transport.duplicate_key",
            Refusal::McpServersRefused => "transport.mcp_servers_refused",
            Refusal::SessionNotInPane => "transport.session_not_in_pane",
            Refusal::HarnessNotConfirmed => "transport.harness_not_confirmed",
            Refusal::GestureRequired => "transport.gesture_required",
        }
    }

    /// The refusal for `code`, None for a code these rules never give.
    pub fn from_code(code: &str) -> Option<Refusal> {
        [
            Refusal::InvalidFrame,
            Refusal::FrameTooLarge,
            Refusal::FirstFrameNotInitialize,
            Refusal::MethodRefused,
            Refusal::IntentInvalid,
            Refusal::DuplicateKey,
            Refusal::McpServersRefused,
            Refusal::SessionNotInPane,
            Refusal::HarnessNotConfirmed,
            Refusal::GestureRequired,
        ]
        .into_iter()
        .find(|r| r.code() == code)
    }
}
