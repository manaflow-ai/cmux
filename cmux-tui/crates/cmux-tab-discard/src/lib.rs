//! Which hidden browser tabs of the cmux macOS app freeze, which are discarded, and which are kept
//! (plans/cmux-next/tab-lifecycle.md). Chrome's Memory Saver rules are the reference: a tab that
//! plays audio, holds the person's unsaved form input (an edited field or a `beforeunload` that
//! asks), is pinned or captures is never discarded.
//!
//! Pure: the app reports the facts (each hidden page's [`Candidate`], what its probe said, the
//! memory pressure and the `browser.hibernation` setting) and applies the result (freeze, discard,
//! keep). The app reaches it through the app FFI (cmux-app-ffi `src/tab_discard.rs`, JSON ops in
//! [`ops`]); the rules live here only.
//!
//! - [`setting`]: the `browser.hibernation` setting as the rules read it, and its default.
//! - [`plan`]: the discard plan (which hidden pages go now, least valuable first, and when to look
//!   again) and the freeze plan.
//! - [`probe`]: what a page's probe answer keeps, and the benefit of the doubt a page that does
//!   not answer keeps ([`probe::ProbeHistory`]).

pub mod ops;
pub mod plan;
pub mod probe;
pub mod setting;

pub use plan::{Candidate, Exemption, Pace, Plan, Pressure, freeze_plan, plan};
pub use probe::{PageProbe, ProbeHistory, Step};
pub use setting::{Mode, Setting};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod stress_tests;
