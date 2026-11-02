//! What picking a slower ring (Dev to Nightly) does to the build this Mac
//! runs. Sparkle never offers a lower build, so when the running build is not
//! on the ring and the ring has nothing newer, the way back is the newest kept
//! build of that ring (a rollback swap); with none kept, the running build
//! stays until the ring passes it.

use crate::version::is_older;
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "way", rename_all = "camelCase")]
pub enum RingReturn {
    /// The running build is on the ring, or the ring offers a newer one.
    None,
    /// Restart into the kept build at this index of `kept`, the newest one on the ring.
    GoBack { kept: usize },
    /// Nothing kept on the ring: the running build stays until the ring passes it.
    Waits,
}

/// - `offered`: the versions of the feed's items the ring sees.
/// - `promoted`: builds the canary passed; on the Nightly ring these count as
///   its own even after they leave the feed.
/// - `pulled`: builds on the feed's pulled list: never a way back.
/// - `kept`: kept builds, newest first.
pub fn decide(
    installed_build: &str,
    offered: &[String],
    promoted: &BTreeSet<String>,
    pulled: &BTreeSet<String>,
    kept: &[String],
) -> RingReturn {
    let on_ring = |build: &str| {
        !pulled.contains(build)
            && (promoted.contains(build) || offered.iter().any(|version| version == build))
    };
    if on_ring(installed_build) {
        return RingReturn::None;
    }
    if offered.iter().any(|version| is_older(installed_build, version)) {
        return RingReturn::None;
    }
    kept.iter()
        .position(|build| on_ring(build) && is_older(build, installed_build))
        .map_or(RingReturn::Waits, |kept| RingReturn::GoBack { kept })
}
