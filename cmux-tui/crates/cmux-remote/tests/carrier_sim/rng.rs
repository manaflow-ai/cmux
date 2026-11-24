//! The simulation's one source of randomness: the fault harness's SplitMix64 (`cmux-fault`'s
//! `Rng`, the same generator as acpmux's simulation, `acpmux/tests/sim/rng.rs`), seeded by the
//! run's seed. Every choice the run makes (the plan, each link's latency, the app's timing) is
//! drawn from a stream split off this one.

pub use cmux_fault::Rng;
