//! The typed failure of a renderer mint that the terminal host did not
//! answer. The daemon maps it to the legacy `error_code`
//! `terminal_host_unavailable` and to the v2 `terminal_host.unavailable`
//! error. The message keeps the full cause chain, because the legacy and v2
//! replies carry only the top-level error text.

/// Why the host did not answer a mint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RendererGrantUnavailable {
    /// No answer within the daemon's control deadline.
    Timeout,
    /// The admin connection ended before the answer. A host refuses a bad
    /// request by closing the connection, so a refusal also lands here.
    Disconnected,
}

impl RendererGrantUnavailable {
    /// The wire `reason` (catalog enum of `terminal_host.unavailable`).
    pub fn reason(self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::Disconnected => "disconnected",
        }
    }
}

/// A mint the terminal host did not answer.
#[derive(Debug)]
pub struct RendererGrantFailure {
    unavailable: RendererGrantUnavailable,
    message: String,
}

impl RendererGrantFailure {
    // Built only by the Unix host attachment.
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn new(unavailable: RendererGrantUnavailable, cause: &anyhow::Error) -> Self {
        Self {
            unavailable,
            message: format!("terminal host did not mint renderer grant: {cause:#}"),
        }
    }

    pub fn unavailable(&self) -> RendererGrantUnavailable {
        self.unavailable
    }
}

impl std::fmt::Display for RendererGrantFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RendererGrantFailure {}
