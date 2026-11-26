//! The owner's agent login a move to their own Cloud machine carries (`link agent move
//! --login-stdin`): the app reads it from this Mac's keychain, as a plain Cloud start does, and
//! hands it on stdin as `{"env":{"NAME":"VALUE"}}`. The target daemon checks it is the owner's
//! own machine (`agent-transfer-credentials-v1`) and its acpmux starts the moved chat's agent
//! with it before the agent resumes or the continuation turn runs. Without it a chat moved to a
//! new machine answered "Claude is not signed in here".
//!
//! The value never reaches argv, a log, an error text or the move's record: [`Login`]'s `Debug`
//! names the variables only, and every refusal here is fixed text.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::{Value, json};

/// The `link agent move` flag: the login is on stdin.
pub const FLAG: &str = "--login-stdin";

/// The target daemon's capability for a finish that carries a login.
pub const CAPABILITY: &str = "agent-transfer-credentials-v1";

/// Most bytes read from stdin: one token is far below it.
pub const MAX_STDIN_BYTES: usize = 64 * 1024;

/// A login read from stdin: the agent's environment variables. A field a newer app adds beside
/// `env` is ignored, so an older cmux-tui still moves the chat with the login.
#[derive(Clone, PartialEq, Eq, Deserialize)]
pub struct Login {
    env: BTreeMap<String, String>,
}

impl std::fmt::Debug for Login {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Login").field("env", &self.env.keys().collect::<Vec<_>>()).finish()
    }
}

impl Login {
    /// The finish's `credentials` param.
    pub fn wire(&self) -> Value {
        json!({"env": self.env})
    }
}

/// Why a move with a login stops before the chat freezes. Its texts never hold the value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Stdin was not `{"env":{...}}` with one or more variables.
    Unreadable,
    /// No `--vm-kind owner`: only the owner's own machine gets their login.
    NotOwner,
    /// The target's cmux-tui is too old to take a login with the move.
    Outdated,
}

impl Refusal {
    pub fn code(self) -> &'static str {
        match self {
            Self::Unreadable => "agent_session.login_unreadable",
            Self::NotOwner => "agent_session.owner_only",
            Self::Outdated => "machine_outdated",
        }
    }

    pub fn message(self) -> &'static str {
        match self {
            Self::Unreadable => {
                "reading the agent login for the move: stdin was not {\"env\":{...}} with a variable"
            }
            Self::NotOwner => {
                "sending the agent login with the move: the Cloud API did not say this machine is yours"
            }
            Self::Outdated => {
                "sending the agent login with the move: the target daemon runs an older cmux-tui \
                 without agent-transfer-credentials-v1"
            }
        }
    }

    /// The daemon a `machine_outdated` is about.
    pub fn side(self) -> Option<&'static str> {
        matches!(self, Self::Outdated).then_some("target")
    }
}

/// The login on stdin, bounded by [`MAX_STDIN_BYTES`].
pub fn read(stdin: &[u8]) -> Result<Login, Refusal> {
    if stdin.len() > MAX_STDIN_BYTES {
        return Err(Refusal::Unreadable);
    }
    let login: Login = serde_json::from_slice(stdin).map_err(|_| Refusal::Unreadable)?;
    if login.env.is_empty()
        || login.env.iter().any(|(name, value)| name.is_empty() || value.is_empty())
    {
        return Err(Refusal::Unreadable);
    }
    Ok(login)
}

/// Whether the finish may carry the login: the Cloud API said `owner`, and the target serves
/// [`CAPABILITY`] (`served`, none when it did not answer `identify`).
pub fn gate(vm_kind: Option<&str>, served: Option<&[&str]>) -> Result<(), Refusal> {
    if vm_kind != Some("owner") {
        return Err(Refusal::NotOwner);
    }
    if !served.is_some_and(|served| served.contains(&CAPABILITY)) {
        return Err(Refusal::Outdated);
    }
    Ok(())
}

#[cfg(test)]
#[path = "login_tests.rs"]
mod tests;
