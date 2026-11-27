//! The pure rules of connecting an MCP server by asking
//! (plans/cmux-next/mcp-connect-DESIGN.md). Everything here is a function of
//! its inputs: no network, no disk, no clock, no randomness. The acpmux daemon
//! owns the connections and does the I/O; this crate decides what is allowed
//! and what the card shows, so each rule of the threat model (section 4) has a
//! unit test.

pub mod classify;
pub mod command;
pub mod discovery;
pub mod pin;
pub mod pkce;
pub mod redact;
pub mod registry;
pub mod resolve;
pub mod screen;
pub mod target;
pub mod wire;

/// Why an input is refused before any card is shown. The text is what the
/// agent gets back, so it names the rule, never a secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal(pub String);

impl Refusal {
    pub(crate) fn new(text: impl Into<String>) -> Self {
        Self(text.into())
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refusal {}
