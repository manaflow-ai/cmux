//! A machine an image made runs the channel's build before it first reports
//! ready (Cloud V0 item 1: a spare is told ready, `cloud.spare.ready`, only
//! on the current build).
//!
//! An image bakes the cmux-tui build of its roll, which lags the channel by
//! about one roll (2026-11-13: new machines first reported 7d3458da, 96db467d
//! and 04824385, and each swapped about 5 min later, after the start hold and
//! the `Bound` hold). The platform reads a machine as ready at its first
//! `cloud.vm.status.report` of state `running` after its bind
//! (cmux-platform MachineState.ts `connectionOf`; SpareReady.ts tells an
//! unclaimed spare's creator then), and only the Cloud role sends that, once
//! it has bound (`/var/lib/cmux/bound.json`).
//!
//! So `cmux host run`, before anything else starts (the session host, any
//! role, the Cloud bind), on a machine that was never bound to Cloud: reads
//! the channel, downloads and verifies the build it names, builds the next
//! profile, records the update as pending, arms the guard and flips
//! `/opt/cmux/current`; then it restarts the other services that run the old
//! binary (acpmux) and execs `/opt/cmux/current/bin/cmux host run` again, the
//! unit's own command, in the same process. No `cmux-host.service` restart
//! happens, and nothing was ever reported or linked from the old build: the
//! first report, the session host and every link come from the channel's
//! build. That new process proves the update or rolls it back as after any
//! flip ([`super::role`], `resolve`).
//!
//! The whole step is bounded ([`BOUND`]): a channel that cannot be read in
//! time (retried every [`READ_RETRY`]), a download still running at the
//! bound, or any failure leaves the image's build, which starts and reports
//! ready, and the normal updater, with its holds, takes the channel's build
//! later. A machine already bound (it may have reported ready, a claim may
//! hold it), one with an update pending, or one with a session host from an
//! earlier start never takes this step: the connect-hold rules for a running
//! machine stay as they are.

use std::path::Path;
use std::time::{Duration, Instant};

use super::Pending;
use super::channel::{Binary, Payload};
use crate::config::Paths;

/// How long the step may hold the first ready.
pub const BOUND: Duration = Duration::from_secs(60);

/// What the step does that leaves the process or the machine: the tests' seam.
pub(super) trait Io {
    fn read_channel(&mut self) -> Result<Payload, String>;
    fn download(&mut self, bin: &Binary, to: &Path) -> Result<(), String>;
    fn arm_guard(&mut self, pending: &Pending) -> Result<(), String>;
    fn disarm_guard(&mut self);
    fn restart_others(&mut self, old: &Path);
}

/// What the step found.
#[derive(Debug, PartialEq, Eq)]
pub enum First {
    NotFirst(&'static str),
    Current(String),
    Flipped(String),
    OnImage(String),
}

/// Not yet: the image's build reports ready and the held updater swaps it later.
pub(super) fn before_ready(_: &Paths, _: &str, _: Instant, _: &mut impl Io) -> First {
    First::OnImage("no step before the first ready yet".to_owned())
}

/// Not yet.
pub fn run(_: &Paths) {}
