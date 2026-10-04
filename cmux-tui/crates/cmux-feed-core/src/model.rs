//! Item model of the local feed owner.

use serde::{Deserialize, Serialize};

/// The local owner keeps at most this many items. Past it the oldest items
/// that are not handing off go first (read and moved ones before open ones).
pub const MAX_ITEMS: usize = 500;

/// Read and moved items are pruned this long after their last change.
pub const RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// Dedupe keys of notices folded into an item by coalescing, newest last.
pub const MAX_ALIASES: usize = 16;

/// Lifecycle of a local item (section 5 rule 3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemState {
    /// Owned here; every op applies.
    Open,
    /// Frozen while the app sends `feed.adopt`; ops are refused with
    /// `feed.moving` (retryable) until the move completes.
    HandingOff,
    /// Owned by `home` now. This copy is a non-authoritative projection: it
    /// is never a write target, and ops are refused with `owner.unreachable`.
    Moved,
}

impl ItemState {
    pub fn as_str(self) -> &'static str {
        match self {
            ItemState::Open => "open",
            ItemState::HandingOff => "handing_off",
            ItemState::Moved => "moved",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(ItemState::Open),
            "handing_off" => Some(ItemState::HandingOff),
            "moved" => Some(ItemState::Moved),
            _ => None,
        }
    }
}

/// Where an item points in the daemon's tree. Every field is optional: a
/// notice without a terminal (a plain `cmux notify`) has no context.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Context {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
}

/// Who acted (B6, the P8 actor stamp of plans/cmux-next/identity.md
/// section 3: `{kind, id, host?, agent?}`). It travels beside the origin and
/// is never part of an idempotency fingerprint.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Actor {
    /// `user`, `terminal`, `acp_session`, `app` or `frontend`.
    pub kind: String,
    /// `user_local` for the local user, else the terminal, session, app or
    /// install id.
    pub id: String,
    /// The machine the actor ran on (terminal, acp_session, app, frontend).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// The agent that runs in the terminal or ACP session, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

/// One local feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    /// The first notice's dedupe key (`notify:<daemon session>:<notification
    /// id>` for daemon notifications).
    pub dedupe_key: String,
    /// Dedupe keys of later notices folded into this item, newest last,
    /// bounded by [`MAX_ALIASES`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub aliases: Vec<String>,
    pub title: String,
    pub body: String,
    pub level: String,
    /// The producer: `cli`, `terminal` or `agent`.
    pub source: String,
    #[serde(default)]
    pub context: Context,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at_ms: Option<u64>,
    pub state: ItemState,
    /// The owner after a move (`cloud`); `None` while owned here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// Notices this item stands for (1 plus every coalesced notice).
    pub count: u32,
}

impl Item {
    pub fn is_unread(&self) -> bool {
        self.read_at_ms.is_none()
    }

    /// Whether `key` names this item (its own key or a coalesced one).
    pub fn has_key(&self, key: &str) -> bool {
        self.dedupe_key == key || self.aliases.iter().any(|alias| alias == key)
    }
}

/// A new notice for the local owner (`feed.post {type: notice}`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    /// The id the item gets when the notice creates one.
    pub id: String,
    pub dedupe_key: String,
    pub title: String,
    pub body: String,
    pub level: String,
    pub source: String,
    pub context: Context,
    pub actor: Option<Actor>,
    pub at_ms: u64,
    /// Whether the notice is already read (only the ledger migration posts
    /// read notices).
    pub read: bool,
    /// Whether a notice for the same terminal may fold into the newest
    /// unread open item there (B7). The migration turns it off so every
    /// ledger entry keeps its own item.
    pub coalesce: bool,
}

/// Which items `list` returns.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ListFilter {
    pub state: Option<ItemState>,
    pub terminal: Option<String>,
    pub unread_only: bool,
}

impl ListFilter {
    pub fn matches(&self, item: &Item) -> bool {
        self.state.is_none_or(|state| item.state == state)
            && self
                .terminal
                .as_ref()
                .is_none_or(|terminal| item.context.terminal.as_deref() == Some(terminal.as_str()))
            && (!self.unread_only || item.is_unread())
    }
}

/// Why an op was refused. `code` is the wire error code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FeedError {
    /// No local item has this id.
    NotFound(String),
    /// The item is handing off; retry after the move completes.
    Moving(String),
    /// The item moved to `home`; its owner is not reachable from here.
    OwnerUnreachable { item: String, home: String },
    /// The op does not apply in the item's state.
    InvalidState { item: String, state: ItemState, op: &'static str },
    /// A malformed argument.
    Invalid(String),
}

impl FeedError {
    pub fn code(&self) -> &'static str {
        match self {
            FeedError::NotFound(_) => "not_found",
            FeedError::Moving(_) => "feed.moving",
            FeedError::OwnerUnreachable { .. } => "owner.unreachable",
            FeedError::InvalidState { .. } => "feed.invalid_state",
            FeedError::Invalid(_) => "invalid_params",
        }
    }

    /// Whether the same request may succeed later without a change.
    pub fn retryable(&self) -> bool {
        matches!(self, FeedError::Moving(_) | FeedError::OwnerUnreachable { .. })
    }
}

impl std::fmt::Display for FeedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FeedError::NotFound(item) => write!(f, "feed item {item} not found"),
            FeedError::Moving(item) => {
                write!(f, "feed item {item} is moving to its new owner; retry after the move")
            }
            FeedError::OwnerUnreachable { item, home } => {
                write!(f, "feed item {item} moved to {home}; that owner is not reachable (retry)")
            }
            FeedError::InvalidState { item, state, op } => {
                write!(f, "feed item {item} is {}; {op} does not apply", state.as_str())
            }
            FeedError::Invalid(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for FeedError {}
