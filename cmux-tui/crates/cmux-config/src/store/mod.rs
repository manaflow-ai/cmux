//! The settings owner's pure reducer: `apply(&State, Op)` validates an op
//! against the schema, the managed guard, the agent policy, idempotency and
//! `if_revision`, edits the JSONC text in memory and returns the next state
//! with the change it causes. No IO; `owner::ConfigStore` commits.

mod diff;
mod reads;
mod replay;
mod state;
mod write;

use serde::Serialize;
use serde_json::Value;

pub use reads::{GetView, RowView, Snapshot, managed_json};
pub use replay::REPLAY_CAPACITY;
pub use state::{FileRead, State};

use crate::domains::Domains;
use crate::keypath::key_path;
use crate::managed::TeamPolicyLayer;
use crate::refusal::Refusal;

/// A settings key: dotted (`appearance.density`, split by `key_path`) or an
/// explicit key path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Key(String),
    Path(Vec<String>),
}

impl Target {
    pub fn path(&self) -> Vec<String> {
        match self {
            Target::Key(key) => key_path(key),
            Target::Path(path) => path.clone(),
        }
    }
}

/// Who asked (OWNERSHIP-PRINCIPLES `origin`; absent = cli). `File` marks a
/// change the owner found on disk; `App` the hosting app's own inputs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    User,
    #[default]
    Cli,
    Mcp,
    Script,
    Remote,
    App,
    File,
}

impl Origin {
    /// Parses a wire origin; unknown or absent is `cli`.
    pub fn parse(text: Option<&str>) -> Origin {
        match text {
            Some("user") => Origin::User,
            Some("mcp") => Origin::Mcp,
            Some("script") => Origin::Script,
            Some("remote") => Origin::Remote,
            Some("app") => Origin::App,
            _ => Origin::Cli,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Origin::User => "user",
            Origin::Cli => "cli",
            Origin::Mcp => "mcp",
            Origin::Script => "script",
            Origin::Remote => "remote",
            Origin::App => "app",
            Origin::File => "file",
        }
    }
}

/// Request metadata every write carries.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WriteMeta {
    pub origin: Origin,
    pub idempotency_key: Option<String>,
    pub if_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    Set {
        target: Target,
        value: Value,
        meta: WriteMeta,
    },
    Reset {
        target: Target,
        meta: WriteMeta,
    },
    ResetAll {
        meta: WriteMeta,
    },
    /// Accept only from the hosting app's connection (the daemon checks).
    DomainsPublish {
        themes: Vec<String>,
        font_families: Vec<String>,
        sounds: Vec<String>,
    },
    /// Accept only from the hosting app's connection (the daemon checks).
    TeamPolicySet {
        layer: TeamPolicyLayer,
    },
}

/// One `settings-changed` event: the revision it produced and the dotted
/// keys whose effective or file value changed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Change {
    pub revision: u64,
    pub keys: Vec<String>,
    pub origin: Origin,
}

/// The result of an op as the requester sees it. A replay returns the
/// committed outcome with `replayed: true`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Outcome {
    pub revision: u64,
    pub keys: Vec<String>,
    pub replayed: bool,
}

/// What `apply` produced. `write` is the new cmux.json text the IO layer
/// must publish before it adopts `state`.
#[derive(Debug, Clone)]
pub struct Applied {
    pub state: State,
    pub changes: Vec<Change>,
    pub outcome: Outcome,
    pub write: Option<String>,
}

/// The reducer.
pub fn apply(state: &State, op: Op) -> Result<Applied, Refusal> {
    match op {
        Op::Set { .. } | Op::Reset { .. } | Op::ResetAll { .. } => write::apply_write(state, op),
        Op::DomainsPublish { themes, font_families, sounds } => {
            let mut next = state.clone();
            next.domains = Domains::published(themes, font_families, sounds);
            next.recompute();
            Ok(state::finish(state, next, Origin::App))
        }
        Op::TeamPolicySet { layer } => {
            let current = &state.team;
            // A stale read must not roll back a newer version of the same team's policy.
            let stale = !layer.team_id.is_empty()
                && layer.team_id == current.team_id
                && layer.version < current.version;
            if layer == *current || stale {
                return Ok(state::finish(state, state.clone(), Origin::App));
            }
            let mut next = state.clone();
            next.team = layer;
            next.recompute();
            Ok(state::finish(state, next, Origin::App))
        }
    }
}
