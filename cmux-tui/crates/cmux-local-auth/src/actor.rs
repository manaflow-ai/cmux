//! Who made a request (plans/cmux-next/identity.md section 3). Owners record
//! the actor beside `origin`; it is never part of an idempotency fingerprint.

use serde::{Deserialize, Serialize};

/// The kind of principal behind a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActorKind {
    /// The local user (no proof beyond the same-uid socket).
    User,
    /// A process in a cmux terminal, proved by its launch credential.
    Terminal,
    /// An agent in an acpmux ACP session, proved by its launch credential.
    AcpSession,
    /// A cmux app, stamped only by the app supervisor.
    App,
    /// The native app on this machine, proved by its install key.
    Frontend,
}

impl ActorKind {
    /// The stable wire word.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Terminal => "terminal",
            Self::AcpSession => "acp_session",
            Self::App => "app",
            Self::Frontend => "frontend",
        }
    }
}

/// The actor of one request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Actor {
    pub kind: ActorKind,
    pub id: String,
    /// The session host that proved it (absent for `user`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// An agent principal the local user named when minting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

/// The local user's principal id.
pub const LOCAL_USER_ID: &str = "user_local";

impl Actor {
    /// The local user.
    pub fn local_user() -> Self {
        Self { kind: ActorKind::User, id: LOCAL_USER_ID.into(), host: None, agent: None }
    }

    /// The actor a verified launch credential names; None for claims
    /// without exactly one subject (verification already refuses those).
    pub fn from_claims(claims: &crate::launch_credential::Claims) -> Option<Self> {
        let (kind, id) = match (&claims.terminal, &claims.acp_session) {
            (Some(terminal), None) => (ActorKind::Terminal, terminal.clone()),
            (None, Some(session)) => (ActorKind::AcpSession, session.clone()),
            _ => return None,
        };
        Some(Self { kind, id, host: Some(claims.host.clone()), agent: claims.agent.clone() })
    }

    /// Canonical JSON for a record column.
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("actor serializes")
    }
}
