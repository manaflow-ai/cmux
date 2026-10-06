//! The Chief brain host's sans-I/O core (plans/cmux-next/chief-mac.md).
//!
//! The Chief's model loop runs in its acpmux session. This crate is the
//! deterministic host around it: the inbox (wake rule, catch-up from the
//! read cursor), turn folding and replies, the child-agent supervisor, the
//! durable outbox, memory views, and tool selection from the catalog. It has
//! no I/O and no clock: the daemon shell passes inputs with the time and runs
//! the effects. The TypeScript brain runs the same behavior corpus
//! (`cmux-chief-corpus/1`), so the Mac and cloud brains stay equal.

pub mod acp;
pub mod core;
pub mod corpus;
pub mod memory;
pub mod rules;
pub mod state;
pub mod tools;

pub use crate::core::{
    Core, Effect, Input, OUTBOX_TIMER, PROMPT_TIMER_PREFIX, Port, SESSIONS_TIMER, retry_delay,
};
pub use crate::state::HostState;
