//! Continuous two-way sync between the Mac and an AutoCloud VM while a chat runs there.
//!
//! Leo: "all we need obv is storage reliable sync SO MAKE IT RELIABLE AND FAST" and "you mark as
//! autocloud, it starts instantly and works like dropbox".
//!
//! Both sides watch their folder ([`watch`]) and keep an index of path to content hash
//! ([`replica`]). The VM ([`follower`]) reports what changed in debounced batches; the Mac
//! ([`leader`]) runs every round with cmux-sync's three-tree rule against the synced revision
//! ([`state`]), over one framed duplex stream ([`proto`]). Every write on either side is
//! compare-and-swap, so a save that lands mid-round is decided again, never overwritten. A
//! conflict merges three-way when clean, else keeps both copies (`NAME.cmux-sync-conflict`).
//! Each connection starts from full manifests, which is the catch-up after a pause, a dropped
//! network or a Mac that slept.

pub mod follower;
pub mod leader;
pub mod proto;
pub mod replica;
pub mod state;
pub mod watch;

use std::time::Duration;

pub use follower::Follower;
pub use leader::{End, Event, Leader};

/// A batch closes once its paths have been quiet this long...
pub const DEBOUNCE_QUIET: Duration = Duration::from_millis(15);
/// ...or once it is this old, whichever comes first (a build writing for seconds still syncs).
pub const DEBOUNCE_MAX: Duration = Duration::from_millis(100);
/// The leader pings this often when idle.
pub const PING_EVERY: Duration = Duration::from_secs(5);
/// A link silent this long is dropped and dialed again.
pub const IDLE_DROP: Duration = Duration::from_secs(15);
