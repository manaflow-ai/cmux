//! The actor stamp (plans/cmux-next/identity.md section 3, package P8).
//!
//! The stamp records which process acted: the user, a terminal, an ACP
//! session or an app. The owner builds it from a verified launch credential
//! (or the connection); a caller never states it. It is recorded beside
//! `origin` and the idempotency key, and it is not part of the idempotency
//! fingerprint, so the same key sent again under another credential is a
//! replay that keeps the first stamp.
//!
//! The JSON is the P8 shape. When P8 ships a shared Rust type, this type
//! becomes a re-export with the same JSON (the op log does not change).

use serde::{Deserialize, Serialize};

/// The local OS user (P8 `user_local`).
pub const LOCAL_USER: &str = "user_local";

/// Longest id or host accepted in a stamp.
const MAX_FIELD: usize = 200;

/// A `user` actor (the person an app acts for).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename = "user")]
pub struct UserActor {
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Actor {
    /// `user_local`, or the account user id.
    User { id: String },
    /// A terminal (public id) on session host `host`.
    Terminal {
        id: String,
        host: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent: Option<String>,
    },
    /// An acpmux session on session host `host`.
    AcpSession {
        id: String,
        host: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent: Option<String>,
    },
    /// An app (`<publisher>/<name>`). Set only by the app supervisor path.
    App { id: String, host: String, version: String, on_behalf_of: UserActor },
}

fn field_ok(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_FIELD && !value.chars().any(char::is_control)
}

impl Actor {
    pub fn local_user() -> Self {
        Self::User { id: LOCAL_USER.to_owned() }
    }

    /// Every field non-empty, bounded and free of control characters.
    pub fn is_well_formed(&self) -> bool {
        match self {
            Self::User { id } => field_ok(id),
            Self::Terminal { id, host, agent } | Self::AcpSession { id, host, agent } => {
                field_ok(id) && field_ok(host) && agent.as_deref().is_none_or(field_ok)
            }
            Self::App { id, host, version, on_behalf_of } => {
                field_ok(id)
                    && id.contains('/')
                    && field_ok(host)
                    && field_ok(version)
                    && field_ok(&on_behalf_of.id)
            }
        }
    }

    /// The agent principal the stamp names, if any (`terminal` and
    /// `acp_session` only).
    pub fn agent(&self) -> Option<&str> {
        match self {
            Self::Terminal { agent, .. } | Self::AcpSession { agent, .. } => agent.as_deref(),
            Self::User { .. } | Self::App { .. } => None,
        }
    }

    /// The ACP session id, when the stamp is an ACP session.
    pub fn acp_session(&self) -> Option<&str> {
        match self {
            Self::AcpSession { id, .. } => Some(id),
            _ => None,
        }
    }
}
