//! cmux automations on one machine (docs/automations-platonic-ideal.md).
//!
//! An [`Automation`] is a named prompt or command plus one [`Trigger`]. The
//! [`Store`] keeps it on disk (`~/.config/cmux/automations/<id>/`), every
//! write atomic, run history append-only. The runner calls [`tick`] on a
//! timer: it works out which scheduled times came due since the last tick,
//! applies the automation's [`CatchUp`] policy to the ones a sleeping Mac
//! missed, records every due time as a [`Run`] (run or skipped, with a
//! reason) and hands the runs to an [`Executor`]. Run ids are deterministic
//! (`automation + trigger + scheduled_at`), so a due time is one run however
//! often it is seen.
//!
//! A [`Gate`] sits between a fire and its run: a condition script (run in
//! the run's own process) and guardrails (one live run, cooldown, a daily
//! cap). A `watch` trigger fires on the lines a long-running command prints;
//! [`watch::Watches`] keeps those commands alive in the runner. An `event`
//! trigger (`--when agent-idle`) is a watch whose command cmux supplies
//! ([`events`]).
//!
//! No I/O happens outside [`Store`], [`exec`] and [`watch`] (and their
//! platform seam, `sys`); schedule math takes the
//! time as a parameter, so tests never wait.

// The crash ratchet: no production panics in this crate.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented
    )
)]

mod automation;
mod catch_up;
mod clock;
mod cron;
pub mod events;
pub mod exec;
mod gate;
mod run;
mod runner;
mod store;
mod sys;
mod teleport;
mod trigger;
pub mod watch;

pub use automation::{
    Automation, AutomationSpec, Body, Handoff, LOCAL_HOME, Origin, Tombstone, is_handoff_id,
    new_automation_id, new_handoff_id,
};
pub use catch_up::{CatchUp, FirePlan, ON_TIME_SECONDS, plan_fires};
pub use clock::{Civil, Zone};
pub use cron::CronExpr;
pub use events::{EVENTS, EventKind};
pub use gate::{
    CONDITION_TIMEOUT_SECONDS, Gate, MAX_EVENT_BYTES, Verdict, clip_event, fired, verdict,
};
pub use run::{Run, RunState, event_run_id, manual_run_id, run_id};
pub use runner::{
    EventOutcome, ExecOutcome, Executor, Job, TickReport, finish, gate_verdict, recover_orphans,
    start_event, start_manual, start_manual_with_event, tick,
};
pub use store::{AutomationState, RunnerLock, Store, StoreError, TOMBSTONE_MS};
pub use teleport::{
    Destination, ImportHandoff, ImportSpec, Imported, export_spec, parse_destination,
};
pub use trigger::{DEFAULT_DEBOUNCE_SECONDS, MAX_DEBOUNCE_SECONDS, ScheduleError, Trigger};
