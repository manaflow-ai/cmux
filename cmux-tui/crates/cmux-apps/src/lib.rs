//! `cmux app publish|versions|rollback|ls`: an app from a Cloud preview, as numbered versions
//! (cmuxterm-hq RFD 0003, "Publish (tier 2, V2)" and "Platform contract (first slice)").
//!
//! A publish infers the command from the process on a port, pins the source to a commit, stages
//! `git archive` of it under `~/.cmux/apps/<slug>/v<n>/`, starts it detached on a free `PORT`,
//! probes `GET /`, and only then asks the platform to move the app's `live` version. A failed
//! probe records the version as failed with its log tail and never reaches the platform.
//!
//! Every effect goes through a trait in [`io`] (files, git, processes, the clock, the local
//! probe, the platform's HTTP and the VM's credential), so the whole flow is tested with fakes;
//! [`system`] holds the real implementations, except HTTPS, which the CLI binary supplies.

pub mod account;
pub mod cli;
pub mod frame;
pub mod infer;
pub mod io;
pub mod platform;
pub mod publish;
pub mod slug;
pub mod state;
#[cfg(unix)]
pub mod system;
pub mod ui;
