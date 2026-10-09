//! cmux Tasks model (plans/cmux-next/tasks.md).
//!
//! The Tasks service is the single writer of every Tasks entity of a team.
//! This crate is its pure core: entities, typed ops, the reducer
//! `reduce(state, envelope, ctx) -> Result<Commit, Reject>`, the invariant
//! checker and the operation catalog entries. It performs no I/O; the
//! service crate (`cmux-tasks`) adds the op log, snapshots and transport.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

pub mod catalog;
pub mod event;
pub mod ids;
pub mod invariants;
pub mod model;
pub mod op;
pub mod query;
pub mod reduce;
pub mod sort_key;

pub use event::{Event, EventKind};
pub use ids::{AgentClass, AgentRef, Principal};
pub use model::{
    AgentFlow, AgentSession, Attention, Category, Comment, Priority, Project, ProjectState,
    Relation, RelationKind, SessionStatus, State, Status, Task, TeamSettings,
};
pub use op::{Envelope, Op, Origin};
pub use reduce::{Commit, Ctx, OpResult, Reject, RejectCode, reduce};
