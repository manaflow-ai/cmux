//! Preview a draft, then send it once.
//!
//! The preview names the destination, each recipient and what the message will do to them (inbox,
//! digest, stored, wake) before anything is written, and flags a `wake` that will not wake. Sending
//! re-runs the same checks and posts with the draft's idempotency key, so a retry after a timeout is
//! the same message, never a second one.

use std::fmt;

use crate::backend::{BackendError, ForumBackend};
use crate::delivery::{DeliveryMode, Route, route};
use crate::identity::{self, IdentityError, PrincipalKind, Resolved, resolve_handle};
use crate::model::{Message, Principal, Space, Team};
use crate::permission::{Capability, effective, wake_allowed};
use crate::refs::StableRef;

/// What the composer holds before send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Draft {
    pub thread_id: String,
    pub body: String,
    /// `@handle`s, `@` optional.
    pub audience: Vec<String>,
    pub mode: DeliveryMode,
    pub refs: Vec<StableRef>,
    pub reply_to: Option<String>,
    /// Chosen once per draft by the client; every retry of this draft reuses it.
    pub idempotency_key: String,
    pub created_at: u64,
}

/// One recipient and what the message will do to them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recipient {
    pub principal: Principal,
    pub route: Route,
    /// The sender asked for `wake` and this agent will not be woken (no owner grant here, or the
    /// sender is a bridge): it lands in the agent's digest instead.
    pub wake_downgraded: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preview {
    pub space_id: String,
    pub thread_id: String,
    pub mode: DeliveryMode,
    pub recipients: Vec<Recipient>,
}

impl Preview {
    pub fn wakes(&self) -> Vec<&str> {
        self.recipients
            .iter()
            .filter(|r| r.route.wakes())
            .map(|r| r.principal.id.as_str())
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Receipt {
    pub message_id: String,
    pub seq: u64,
    /// This key was sent before; nothing new was written.
    pub duplicate: bool,
    pub preview: Preview,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendError {
    Identity(IdentityError),
    UnknownThread(String),
    UnknownSpace(String),
    UnknownTeam(String),
    /// The sender may not post in this space.
    CannotPost {
        sender: String,
        space: String,
    },
    UnknownRecipient(String),
    /// The handle names more than one principal; the composer asks.
    AmbiguousRecipient {
        handle: String,
        candidates: Vec<String>,
    },
    /// The recipient cannot read this space; sending would widen the thread.
    RecipientCannotRead {
        recipient: String,
        space: String,
    },
    EmptyBody,
    EmptyKey,
    Backend(BackendError),
}

impl fmt::Display for SendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Identity(e) => write!(f, "{e}"),
            Self::UnknownThread(t) => write!(f, "no thread {t}"),
            Self::UnknownSpace(s) => write!(f, "no space {s}"),
            Self::UnknownTeam(t) => write!(f, "no team {t}"),
            Self::CannotPost { sender, space } => write!(f, "{sender} cannot post in {space}"),
            Self::UnknownRecipient(h) => write!(f, "no one is @{h}"),
            Self::AmbiguousRecipient { handle, candidates } => {
                write!(f, "@{handle} names {}", candidates.join(", "))
            }
            Self::RecipientCannotRead { recipient, space } => {
                write!(f, "{recipient} cannot read {space}")
            }
            Self::EmptyBody => write!(f, "the message is empty"),
            Self::EmptyKey => write!(f, "the draft has no idempotency key"),
            Self::Backend(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for SendError {}

impl From<IdentityError> for SendError {
    fn from(e: IdentityError) -> Self {
        Self::Identity(e)
    }
}

impl From<BackendError> for SendError {
    fn from(e: BackendError) -> Self {
        Self::Backend(e)
    }
}

/// The send path over a forum backend, with the directory it resolves against.
pub struct Messenger<F> {
    forum: F,
    principals: Vec<Principal>,
    teams: Vec<Team>,
    spaces: Vec<Space>,
}

impl<F: ForumBackend> Messenger<F> {
    pub fn new(forum: F, principals: Vec<Principal>, teams: Vec<Team>, spaces: Vec<Space>) -> Self {
        Self { forum, principals, teams, spaces }
    }

    pub fn forum(&self) -> &F {
        &self.forum
    }

    fn principal(&self, id: &str) -> Option<&Principal> {
        self.principals.iter().find(|p| p.id == id)
    }

    fn owner_of(&self, p: &Principal) -> Option<&Principal> {
        match p.kind {
            PrincipalKind::Agent => p.owner_person_id.as_deref().and_then(|o| self.principal(o)),
            PrincipalKind::Person => None,
        }
    }

    /// Check a draft and say what it will do, writing nothing.
    pub fn preview(&self, caller: &Principal, draft: &Draft) -> Result<Preview, SendError> {
        // The author is the caller's own principal record, never one the draft names.
        let author = self.principal(&caller.id).unwrap_or(caller);
        identity::check_author(author, caller)?;
        identity::require_rights(caller)?;
        if draft.body.trim().is_empty() {
            return Err(SendError::EmptyBody);
        }
        if draft.idempotency_key.trim().is_empty() {
            return Err(SendError::EmptyKey);
        }
        let thread = self.forum.thread(&draft.thread_id).map_err(|e| match e {
            BackendError::NotFound(_) => SendError::UnknownThread(draft.thread_id.clone()),
            other => SendError::Backend(other),
        })?;
        let space = self
            .spaces
            .iter()
            .find(|s| s.id == thread.space_id)
            .ok_or_else(|| SendError::UnknownSpace(thread.space_id.clone()))?;
        let team = self
            .teams
            .iter()
            .find(|t| t.id == space.team_id)
            .ok_or_else(|| SendError::UnknownTeam(space.team_id.clone()))?;
        if !effective(author, self.owner_of(author), team, space).has(Capability::Post) {
            return Err(SendError::CannotPost {
                sender: author.id.clone(),
                space: space.id.clone(),
            });
        }

        let mut recipients: Vec<Recipient> = Vec::new();
        for handle in &draft.audience {
            let p = match resolve_handle(handle, &team.id, &self.principals) {
                Resolved::One(p) => *p,
                Resolved::None => {
                    return Err(SendError::UnknownRecipient(
                        handle.trim().trim_start_matches('@').to_owned(),
                    ));
                }
                Resolved::Ambiguous(ps) => {
                    return Err(SendError::AmbiguousRecipient {
                        handle: handle.trim().trim_start_matches('@').to_owned(),
                        candidates: ps.into_iter().map(|p| p.id).collect(),
                    });
                }
            };
            if recipients.iter().any(|r| r.principal.id == p.id) {
                continue;
            }
            if !effective(&p, self.owner_of(&p), team, space).has(Capability::Read) {
                return Err(SendError::RecipientCannotRead {
                    recipient: p.id,
                    space: space.id.clone(),
                });
            }
            let can_wake = wake_allowed(space, &p);
            let r = route(draft.mode, author, &p, can_wake, space.notify_for(&p.id));
            let wake_downgraded =
                draft.mode == DeliveryMode::Wake && p.kind == PrincipalKind::Agent && !r.wakes();
            recipients.push(Recipient { principal: p, route: r, wake_downgraded });
        }
        Ok(Preview {
            space_id: space.id.clone(),
            thread_id: thread.id,
            mode: draft.mode,
            recipients,
        })
    }

    /// Check and post the draft. The same idempotency key returns the first send's receipt.
    pub fn send(&self, caller: &Principal, draft: &Draft) -> Result<Receipt, SendError> {
        let preview = self.preview(caller, draft)?;
        let author = self.principal(&caller.id).unwrap_or(caller).clone();
        let message = Message {
            id: format!("{}#{}", draft.thread_id, draft.idempotency_key),
            thread_id: draft.thread_id.clone(),
            author,
            audience: preview.recipients.iter().map(|r| r.principal.id.clone()).collect(),
            body: draft.body.clone(),
            refs: draft.refs.clone(),
            delivery: draft.mode,
            created_at: draft.created_at,
            reply_to: draft.reply_to.clone(),
            revision: 0,
        };
        let posted = self.forum.post(&draft.idempotency_key, message)?;
        Ok(Receipt {
            message_id: posted.stored.message.id,
            seq: posted.stored.seq,
            duplicate: posted.duplicate,
            preview,
        })
    }
}
