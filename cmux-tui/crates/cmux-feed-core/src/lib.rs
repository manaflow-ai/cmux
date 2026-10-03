//! The feed's local owner (plans/cmux-next/feed.md sections 3, 5 and 9.1):
//! notice items that a daemon owns while they live on this machine, the typed
//! ops on them, and the pure reducer that applies the ops. No I/O: the daemon
//! loads the items, applies an op to a copy, writes the changed rows in its
//! own commit, and installs the copy only after that commit succeeds.

mod model;
mod reduce;

pub use model::{
    Actor, Context, FeedError, Item, ItemState, ListFilter, MAX_ALIASES, MAX_ITEMS, Notice,
    RETENTION_MS,
};
pub use reduce::{Changes, Feed, PostOutcome};
