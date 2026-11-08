//! Shared harnesses of the simulation and break tests: a seeded generator
//! bit-identical to the Swift suite's, a bash-readline-shaped remote, a
//! one-row terminal, the randomized simulation and the break rig.
#![allow(dead_code)]

pub mod random;
pub mod rig;
pub mod screen;
pub mod simulation;
pub mod simulation_cases;

use std::time::Duration;

/// Milliseconds as an instant.
pub fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

/// Microseconds as an instant.
pub fn us(microseconds: i64) -> Duration {
    Duration::from_micros(u64::try_from(microseconds).expect("non-negative instant"))
}
