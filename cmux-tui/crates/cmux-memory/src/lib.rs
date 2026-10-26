//! Memory budgets for the cmux daemons (cmux-tui-core and acpmux).
//!
//! A leaf crate: std and libc only, so the daemon and acpmux can share it
//! without depending on each other. [`DaemonBudget`] sizes the daemon's
//! memory from the Mac's installed RAM, as `SubsystemBudget.forMemory` does
//! for the app (plans/cmux-next/chrome-parity/p07-memory.md, section B).

pub mod budget;

pub use budget::DaemonBudget;
