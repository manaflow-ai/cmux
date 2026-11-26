//! Moving to AutoCloud from anywhere (cmuxterm-hq RFD "Moving to AutoCloud").
//!
//! Leo, 2026-11-24: "we ought to be able to have good migration capabilities all around for people
//! of all stages any and all levels of technical sophistication and teams and organizations of any
//! size and demand to move to autocloud".
//!
//! Every source reads, read-only, into one shape: a [`plan::Plan`] of [`plan::Project`]s (a repo
//! plus the `.cmux/machine.toml` that makes its machine ready) and machine-wide
//! [`plan::Carry`] items (dotfiles, editor settings, agent logins and histories). The plan is the
//! dry run: nothing is made until it is applied, and applying it only ever adds (a machine, a
//! delivered secret, carried files); the source is never changed, so the way back is to delete
//! what was made ([`ledger::Ledger::undo_steps`]).
//!
//! - [`plan`]: the shape every source produces, and the [`plan::Step`]s that apply it through the
//!   Cloud actions that exist (`cloud new-machine --repo --machine-config`, `cloud
//!   deliver-secrets`, `cloud move`).
//! - [`machine_toml`]: a project's `.cmux/machine.toml`, rendered for the machine's applier.
//! - [`ledger`]: what earlier runs made, by project key, so a rerun makes nothing twice, an
//!   interrupted run resumes, and `undo` knows what to delete.
//! - [`sources`]: one reader per place people come from.
//!
//! Pure where it can be: readers take a root folder (a home, a checkout) and read files; nothing
//! here talks to the network or the Cloud API. The CLI and the app run the steps.

pub mod apply;
pub mod ledger;
pub mod machine_toml;
pub mod plan;
pub mod sources;

pub use plan::{Carry, CarryKind, MachineConfig, Plan, Project, Repo, Source, SourceKind, Step};
