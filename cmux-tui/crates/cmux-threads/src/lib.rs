//! cmux-threads: the daemon's thread rules, after Chrome's base/threading and base/task.
//!
//! - `qos`, `spawn`, `registry`: ThreadQos, named QoS threads and live thread rows (p02-threads-200).
//! - [`work`]: blocking work lanes by kind, priority and shutdown behavior (p02-threads-204).

pub mod work;
