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
//! No I/O happens outside [`Store`] and [`exec`] (and their platform
//! seam, `sys`); schedule math takes the
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
pub mod exec;
mod run;
mod runner;
mod store;
mod sys;
mod trigger;

pub use automation::{Automation, AutomationSpec, Body, new_automation_id};
pub use catch_up::{CatchUp, FirePlan, ON_TIME_SECONDS, plan_fires};
pub use clock::{Civil, Zone};
pub use cron::CronExpr;
pub use run::{Run, RunState, manual_run_id, run_id};
pub use runner::{
    ExecOutcome, Executor, Job, TickReport, finish, recover_orphans, start_manual, tick,
};
pub use store::{AutomationState, RunnerLock, Store, StoreError};
pub use trigger::{ScheduleError, Trigger};
