//! Linux soak harness for the peer-list flap path.
//!
//! This is deliberately an ignored test: it runs the same finite workload on
//! a before and after revision, then prints the watcher-event and resource
//! deltas for the PR's Performance table.  Set `ACPMUX_PEER_FLAP_SOAK_SECS`
//! and `ACPMUX_PEER_FLAP_INTERVAL_SECS` for a short smoke run.

use super::*;

#[cfg(all(test, acpmux_tests_hub))]
#[path = "peer_flap_soak_tests.rs"]
mod tests;

#[cfg(all(test, acpmux_tests_hub))]
#[path = "peer_flap_memory_tests.rs"]
mod memory_tests;
