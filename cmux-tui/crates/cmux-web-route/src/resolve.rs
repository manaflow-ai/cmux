//! A route against what the machines list: exactly one chat or workspace, or a typed refusal
//! (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, "Wrong-chat fallback"). A route whose chat is
//! unknown, ambiguous or refused is a visible failure, never another chat in its place; the
//! caller shows the refusal and opens nothing.

use crate::route::{Machine, Route};

/// One chat a machine lists, as the resolver needs it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Candidate {
    pub machine_id: Option<String>,
    pub machine_name: Option<String>,
    /// acpmux's own session id.
    pub session_id: String,
    pub harness: String,
    /// The harness's own session id (`agentSessionId`), which an agent link names.
    pub agent_session_id: Option<String>,
    /// Why this client may not attach it (a relay-only row, a hub chat this device may not read),
    /// None when it may.
    pub refusal: Option<String>,
}

/// One workspace a machine lists.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceCandidate {
    pub machine_id: Option<String>,
    pub machine_name: Option<String>,
    pub workspace_id: String,
    pub refusal: Option<String>,
}

/// What a route opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    /// The chat to attach (acpmux's session id) and the message to bring into view.
    Chat {
        session_id: String,
        message: Option<String>,
    },
    Workspace {
        workspace_id: String,
    },
}

/// Why a route opens nothing. [`ResolveError::code`] is the stable name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveError {
    /// No listed chat or workspace is on the machine the route names.
    UnknownMachine,
    /// The machine lists no chat with that harness and session.
    UnknownSession,
    /// More than one listed chat answers to the route (the count): none is picked.
    Ambiguous(usize),
    /// The chat or workspace is listed but this client may not attach it, and why.
    Unattachable(String),
    /// The machine lists no such workspace.
    UnknownWorkspace,
}

impl ResolveError {
    pub fn code(&self) -> &'static str {
        match self {
            ResolveError::UnknownMachine => "unknown-machine",
            ResolveError::UnknownSession => "unknown-session",
            ResolveError::Ambiguous(_) => "ambiguous",
            ResolveError::Unattachable(_) => "unattachable",
            ResolveError::UnknownWorkspace => "unknown-workspace",
        }
    }
}

impl std::fmt::Display for ResolveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResolveError::UnknownMachine => {
                f.write_str("no machine of yours by that name lists it")
            }
            ResolveError::UnknownSession => f.write_str("that machine has no such chat"),
            ResolveError::Ambiguous(n) => {
                write!(f, "{n} chats answer to this link; none was opened")
            }
            ResolveError::Unattachable(why) => write!(f, "the chat can't be opened here: {why}"),
            ResolveError::UnknownWorkspace => f.write_str("that machine has no such workspace"),
        }
    }
}

impl std::error::Error for ResolveError {}

fn on_machine(machine: &Option<Machine>, id: &Option<String>, name: &Option<String>) -> bool {
    match machine {
        None => true,
        Some(Machine::Id(want)) => id.as_ref() == Some(want),
        Some(Machine::Name(want)) => name.as_ref() == Some(want),
    }
}

/// What `route` opens among `chats` and `workspaces`.
pub fn resolve(
    route: &Route,
    chats: &[Candidate],
    workspaces: &[WorkspaceCandidate],
) -> Result<Resolved, ResolveError> {
    match route {
        Route::Agent { machine, harness, session, message } => {
            let here: Vec<_> = chats
                .iter()
                .filter(|c| on_machine(machine, &c.machine_id, &c.machine_name))
                .collect();
            if machine.is_some() && here.is_empty() {
                return Err(ResolveError::UnknownMachine);
            }
            let hits: Vec<_> = here
                .into_iter()
                .filter(|c| {
                    &c.harness == harness
                        && (c.agent_session_id.as_ref() == Some(session)
                            || &c.session_id == session)
                })
                .collect();
            match hits.as_slice() {
                [] => Err(ResolveError::UnknownSession),
                [one] => match &one.refusal {
                    Some(why) => Err(ResolveError::Unattachable(why.clone())),
                    None => Ok(Resolved::Chat {
                        session_id: one.session_id.clone(),
                        message: message.clone(),
                    }),
                },
                many => Err(ResolveError::Ambiguous(many.len())),
            }
        }
        Route::Workspace { machine, workspace } => {
            let here: Vec<_> = workspaces
                .iter()
                .filter(|w| on_machine(machine, &w.machine_id, &w.machine_name))
                .collect();
            if machine.is_some() && here.is_empty() {
                return Err(ResolveError::UnknownMachine);
            }
            let hit = here
                .into_iter()
                .find(|w| &w.workspace_id == workspace)
                .ok_or(ResolveError::UnknownWorkspace)?;
            match &hit.refusal {
                Some(why) => Err(ResolveError::Unattachable(why.clone())),
                None => Ok(Resolved::Workspace { workspace_id: hit.workspace_id.clone() }),
            }
        }
    }
}

#[cfg(test)]
#[path = "resolve_tests.rs"]
mod tests;
