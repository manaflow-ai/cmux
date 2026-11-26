//! Who a principal is.
//!
//! A person is an authenticated cmux account. An agent is its own principal with an owner person, a
//! reported session and host, and explicit capabilities; it never posts as its owner. A bridge author
//! (`via Slack`, `via GitHub`, `via Linear`) is shown as such and holds no cmux rights.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::model::Principal;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrincipalKind {
    Person,
    Agent,
}

/// The bridge a post came through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Bridge {
    Slack,
    GitHub,
    Linear,
    /// An origin this build does not know. Still a bridge, so still no rights.
    Other,
}

impl Bridge {
    /// Read a forum event's `origin`. An origin this build does not know is still a bridge, so it is
    /// never mistaken for a direct, rights-holding write; it reads as `None` only when absent.
    pub fn from_origin(origin: &str) -> Option<Self> {
        match origin.trim().to_ascii_lowercase().as_str() {
            "" => None,
            "slack" => Some(Self::Slack),
            "github" => Some(Self::GitHub),
            "linear" => Some(Self::Linear),
            _ => Some(Self::Other),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Slack => "via Slack",
            Self::GitHub => "via GitHub",
            Self::Linear => "via Linear",
            Self::Other => "via a bridge",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IdentityError {
    /// An agent with no owner person.
    AgentWithoutOwner { agent: String },
    /// An agent naming itself, or another agent, as its owner.
    BadOwner { agent: String },
    /// A person carrying an owner.
    PersonWithOwner { person: String },
    /// A message's author is not the authenticated caller.
    NotCaller { claimed: String, caller: String },
    /// An agent's credential writing as its owner.
    AgentAsOwner { agent: String, owner: String },
    /// A bridge author tried an act that needs cmux rights.
    BridgeHasNoRights { author: String, via: Bridge },
}

impl fmt::Display for IdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AgentWithoutOwner { agent } => write!(f, "agent {agent} has no owner"),
            Self::BadOwner { agent } => write!(f, "agent {agent}'s owner is not a person"),
            Self::PersonWithOwner { person } => write!(f, "person {person} cannot have an owner"),
            Self::NotCaller { claimed, caller } => {
                write!(f, "{caller} cannot write as {claimed}")
            }
            Self::AgentAsOwner { agent, owner } => {
                write!(f, "agent {agent} cannot post as its owner {owner}")
            }
            Self::BridgeHasNoRights { author, via } => {
                write!(f, "{author} ({}) holds no cmux rights", via.label())
            }
        }
    }
}

impl std::error::Error for IdentityError {}

/// Check a principal's shape: an agent has an owner who is not itself; a person has none.
pub fn validate(p: &Principal) -> Result<(), IdentityError> {
    match p.kind {
        PrincipalKind::Agent => match p.owner_person_id.as_deref().map(str::trim) {
            None | Some("") => Err(IdentityError::AgentWithoutOwner { agent: p.id.clone() }),
            Some(owner) if owner == p.id => Err(IdentityError::BadOwner { agent: p.id.clone() }),
            Some(_) => Ok(()),
        },
        PrincipalKind::Person => match &p.owner_person_id {
            Some(_) => Err(IdentityError::PersonWithOwner { person: p.id.clone() }),
            None => Ok(()),
        },
    }
}

/// Check that `claimed` (a message's author) is `caller` (who the credential authenticated). The
/// two must be the same principal, of the same kind. An agent's credential naming its owner gets
/// [`IdentityError::AgentAsOwner`], so the refusal says what went wrong.
pub fn check_author(claimed: &Principal, caller: &Principal) -> Result<(), IdentityError> {
    validate(caller)?;
    if caller.kind == PrincipalKind::Agent
        && caller.owner_person_id.as_deref() == Some(claimed.id.as_str())
    {
        return Err(IdentityError::AgentAsOwner {
            agent: caller.id.clone(),
            owner: claimed.id.clone(),
        });
    }
    if claimed.id != caller.id || claimed.kind != caller.kind || claimed.via != caller.via {
        return Err(IdentityError::NotCaller {
            claimed: claimed.id.clone(),
            caller: caller.id.clone(),
        });
    }
    Ok(())
}

/// Refuse an act that needs cmux rights to a bridge author.
pub fn require_rights(p: &Principal) -> Result<(), IdentityError> {
    match p.via {
        Some(via) => Err(IdentityError::BridgeHasNoRights { author: p.id.clone(), via }),
        None => Ok(()),
    }
}

/// What `@handle` names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    One(Box<Principal>),
    /// More than one principal holds the handle; the composer asks, it never guesses.
    Ambiguous(Vec<Principal>),
    None,
}

/// Resolve `@handle` (the `@` is optional) among `directory`, limited to `team_id`. `@person`
/// resolves to the person and `@agent-handle` to the agent; a bridge author is never a recipient.
pub fn resolve_handle(handle: &str, team_id: &str, directory: &[Principal]) -> Resolved {
    let want = handle.trim().trim_start_matches('@');
    if want.is_empty() {
        return Resolved::None;
    }
    let mut hits: Vec<Principal> = directory
        .iter()
        .filter(|p| p.via.is_none() && p.team_id == team_id && p.handle == want)
        .cloned()
        .collect();
    hits.sort_by(|a, b| a.id.cmp(&b.id));
    hits.dedup_by(|a, b| a.id == b.id);
    match hits.len() {
        0 => Resolved::None,
        1 => Resolved::One(Box::new(hits.remove(0))),
        _ => Resolved::Ambiguous(hits),
    }
}
