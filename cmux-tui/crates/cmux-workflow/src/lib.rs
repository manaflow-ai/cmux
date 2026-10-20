//! Native cmux workflows (plans/cmux-next/native-workflows.md): code mode
//! plus an `agent()` primitive, not a second engine.
//!
//! A workflow is a JavaScript script with the Claude Code workflow API
//! (`meta`, `phase`, `agent`, `parallel`, `pipeline`, `log`, `args`) plus
//! `machine` and code mode's `cmux.call`, so a script moves between the two
//! unchanged. It runs in the same embedded QuickJS engine as `cmux_exec`,
//! with no file system, network, process, timer, clock or randomness: every
//! effect goes through a [`Host`].
//!
//! - [`run`] executes a script once. Steps (`agent()`, `machine()`) start on
//!   the host and run concurrently; the script awaits their results.
//! - The [`Journal`] records every finished step under its call order and a
//!   hash of its input and options. Running the script again resumes it: the
//!   longest unchanged prefix of steps returns its journaled results at once,
//!   in the order they first finished, so the replay takes the same path. A
//!   step that was still running when the run stopped gets its host handle
//!   back ([`Step::resume`]) so the host can reattach to it.
//! - `agent(prompt, {schema})` validates the reply against a JSON schema and
//!   asks the same agent once more with the errors before it gives up.
//! - [`stall`] decides when a quiet or blocked agent is nudged, restarted on
//!   another route, or failed.

mod driver;
mod engine;
mod journal;
mod schema;
pub mod stall;

pub use driver::{
    Completion, Event, Host, Limits, Output, RunInput, RunOutcome, RunState, Step, StepKind, Wait,
    run,
};
pub use journal::{Entry, Journal};

#[cfg(test)]
mod workflow_runtime_tests;
