//! Braid's path manager (RFD 0164, slice B1).
//!
//! One racer for every dial ([`race`]) and one memory of the route that won per peer
//! ([`LastGood`]). Today's racers (cmux-remote's hedged connect, the TURN allocate race, the
//! remote route race) each pick a winner and forget it; the next dial pays the same stalls
//! again. This crate keeps the winner and its connect time, so the next dial tries it first
//! and starts its backup sooner, and every caller shares the same code and the same numbers.

pub mod last_good;
pub mod race;
pub mod remembered;

pub use last_good::{LastGood, Remembered};
pub use race::{RacePolicy, Won, race, stagger_after};
pub use remembered::{race_remembered, v6_first};
