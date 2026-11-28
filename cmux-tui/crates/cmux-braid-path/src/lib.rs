//! Braid's path manager (RFD 0164, slices B1, B2, B3 and B4).
//!
//! One racer for every dial ([`race`]), one memory of the route that won per peer
//! ([`LastGood`]), and one path set per peer ([`PathSet`]). Today's racers (cmux-remote's
//! hedged connect, the TURN allocate race, the remote route race) each pick a winner and
//! forget it; the next dial pays the same stalls again. This crate keeps the winner and its
//! connect time, so the next dial tries it first and starts its backup sooner, and every
//! caller shares the same code and the same numbers. [`PathSet`] is the bookkeeping every
//! stack wrapped around `cmux_transport::Selector` on its own (routes to path ids, the probe
//! schedule, lost probes and silences, per-path stats), written once. [`Standby`] keeps the
//! race's losers warm, one per peer and path kind, so a reconnect after the live path dies
//! skips the race. [`network::Fingerprint`] names the network a dial starts from, so a
//! last good route is kept per network (B2), and a route that failed there is marked broken
//! with Chromium's backoff, so it is raced late; [`legs`] counts which leg won each race and
//! why each loser lost.

pub mod last_good;
pub mod legs;
pub mod network;
pub mod path_set;
pub mod probe;
pub mod race;
pub mod remembered;
pub mod standby;

pub use last_good::{BROKEN_FIRST, BROKEN_LONGEST, LastGood, Remembered, broken_for};
pub use legs::{Leg, Outcome};
pub use network::Fingerprint;
pub use path_set::{IdPolicy, Path, PathSet, PathSetError, PathStats, earliest};
pub use probe::{DueProbes, PathWatch, ProbeConfig, WatchStep, silence_window};
pub use race::{
    Losers, Lost, RacePolicy, Won, race, race_keeping_losers, race_keeping_losers_observed,
    stagger_after,
};
pub use remembered::{race_remembered, race_remembered_keeping_losers, v6_first};
pub use standby::{Family, Standby};
