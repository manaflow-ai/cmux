//! The Remote and Cloud fault-injection harness (cmuxterm-hq `docs/design/remote-cloud-durability.md`
//! section 5). A dev-dependency: scenarios live in the crates whose daemons they run
//! (`cmux-remote/tests/rc_faults.rs`, `acpmux/tests/rc_faults.rs`) and take their faults from
//! here, beside the carrier simulation (`cmux-remote/tests/carrier_sim.rs`, whose generator is
//! [`Rng`]) and the session daemon's suite (`cmux-tui/tests/fault_injection.rs`).
//!
//! | Fault | Here |
//! |---|---|
//! | `kill`, `sigstop` | [`process::Recorded`]: SIGKILL, SIGSTOP and SIGCONT by the pid of a child the scenario started |
//! | `partition` | [`proxy::Proxy`]: an in-process TCP proxy that passes, delays, refuses, cuts, blackholes or goes half-open |
//! | `disk-full`, slow fsync | [`disk::DiskFault`]: a switch file the store's debug seam reads (ENOSPC, EDQUOT, a slow sync) |
//! | `ticket-expire`, `mint-down` | [`mint::Mint`]: tickets with a short TTL; the mint answers, refuses (a 503) or hangs |
//! | a phone's link | [`shaper::Shaper`] (TCP) and [`shaper::UdpShaper`] (datagrams: plus a NAT rebinding, one-way loss and a profile step): rate, delay, jitter, loss, a blackout and an address change from a named profile in `link-profiles.json`, seeded |
//! | `clock-jump` | [`clock::WallClock`]: a wall clock on tokio's clock (paused or not) that jumps; monotonic time does not |
//!
//! Every scenario runs through [`runs::Runs`]: `CMUX_FAULT_RUNS` seeds (default 20, the nightly
//! sweep more), or the one `CMUX_FAULT_SEED` names. A failing run prints its seed, its
//! [`trace::Trace`] and the command that replays it. The checks every scenario can call are in
//! [`invariants`]: no lost or doubled event, the reported state matches the truth within a bound,
//! restarts within budget, recovery under its bound.

pub mod clock;
pub mod disk;
pub mod invariants;
pub mod mint;
// Signals by pid (kill, SIGSTOP, SIGCONT): unix only.
#[cfg(unix)]
pub mod process;
pub mod proxy;
pub mod rng;
pub mod runs;
pub mod shaper;
pub mod timer;
pub mod trace;

pub use rng::Rng;
pub use runs::{Failed, Runs};
pub use trace::Trace;
