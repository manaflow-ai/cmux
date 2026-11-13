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

use super::channel::{self, Binary, Payload};
use super::role::{self, Lock, Outcome};
use super::{
    Decision, Pending, clear_pending, decide, load_pending, load_state, off_reason,
    record_installed, save_pending, save_state, store,
};
use crate::config::Paths;

/// How long the step may hold the first ready: the channel read (about 0.2 s)
/// and the two downloads (about 197 MB, 3 to 5 s on a cloud link) with room
/// for a slow link or a network that comes up late in the boot.
pub const BOUND: Duration = Duration::from_secs(60);
/// A channel read that failed (the network may not be up yet) is tried again
/// this often within the bound.
pub const READ_RETRY: Duration = Duration::from_secs(2);
/// The unit's command runs through `current` (`<current>/bin/cmux host run`), so
/// the same command after the flip runs the channel's build.
const CURRENT_BIN: &str = "/opt/cmux/current/bin";

fn log(line: &str) {
    eprintln!("cmux-host: updater: {line}");
}

/// What the step does that leaves the process or the machine: the tests' seam.
pub(super) trait Io {
    /// The channel's verified payload.
    fn read_channel(&mut self) -> Result<Payload, String>;
    /// `bin` into `to`, whole (the store checks its sha256 and size).
    fn download(&mut self, bin: &Binary, to: &Path) -> Result<(), String>;
    fn arm_guard(&mut self, pending: &Pending) -> Result<(), String>;
    fn disarm_guard(&mut self);
    /// Restarts what runs `old` but `cmux-host.service` (this process execs instead).
    fn restart_others(&mut self, old: &Path);
}

/// What the step found.
#[derive(Debug, PartialEq, Eq)]
pub enum First {
    /// Not a machine before its first ready (why): the normal updater only.
    NotFirst(&'static str),
    /// The image's build is the channel's (this commit): ready on it.
    Current(String),
    /// `current` now links the channel's build (this commit): the process starts
    /// over on it before anything reports.
    Flipped(String),
    /// Ready on the image's build (why): the normal updater takes the channel's later.
    OnImage(String),
}

/// Why this machine does not take the step, if it does not.
pub(super) fn not_first(paths: &Paths) -> Option<&'static str> {
    if !paths.at(store::CURRENT_LINK).exists() {
        return Some("no store profile");
    }
    if off_reason(paths).is_some() {
        return Some("the updater is off");
    }
    // Bound: it may have reported ready, and a claim may hold it.
    if paths.at(crate::cloud::wire::BOUND_FILE).exists() {
        return Some("bound to Cloud");
    }
    if load_pending(paths).is_some() {
        return Some("an update is waiting for its health check");
    }
    // A session host from an earlier start of the service (`/run` is new at each boot).
    if paths.at(crate::config::DAEMON_PID_FILE).exists() {
        return Some("a session host runs");
    }
    None
}

/// The step on `paths` for `target`, by `deadline`. GETs must be bounded by the
/// caller ([`role::within`]).
pub(super) fn before_ready(
    paths: &Paths,
    target: &str,
    deadline: Instant,
    io: &mut impl Io,
) -> First {
    if let Some(why) = not_first(paths) {
        return First::NotFirst(why);
    }
    let first = step(paths, target, deadline, io);
    let outcome = match &first {
        First::NotFirst(_) => return first,
        First::Current(commit) => Outcome::Current(commit.clone()),
        First::Flipped(commit) => Outcome::Updating(commit.clone()),
        First::OnImage(why) => Outcome::Failed(why.clone()),
    };
    role::save_outcome(paths, &outcome, "before the first ready: ");
    first
}

fn step(paths: &Paths, target: &str, deadline: Instant, io: &mut impl Io) -> First {
    let Some(_lock) = Lock::take(paths, false) else {
        return First::OnImage("another update check runs".to_owned());
    };
    let payload = loop {
        match io.read_channel() {
            Ok(payload) => break payload,
            Err(e) if Instant::now() + READ_RETRY >= deadline => {
                return First::OnImage(format!("the channel was not read in time: {e}"));
            }
            Err(_) => std::thread::sleep(READ_RETRY),
        }
    };
    let mut state = load_state(paths);
    let plan = match decide(paths, &state, &payload, target) {
        Ok(Decision::Update(plan)) => plan,
        Ok(Decision::Current) => return First::Current(payload.commit),
        Ok(Decision::Older) => {
            return First::OnImage("the channel's build is older than this one".to_owned());
        }
        Ok(Decision::RolledBack) => {
            return First::OnImage("the channel's build was rolled back here".to_owned());
        }
        Err(e) => return First::OnImage(e),
    };
    if let Err(e) = role::stage_with(paths, &plan, |bin, file| io.download(bin, file)) {
        return First::OnImage(e);
    }
    if Instant::now() >= deadline {
        return First::OnImage("staged past the bound".to_owned());
    }
    if let Err(e) = store::build_profile(paths, plan.from, plan.to, &plan.replacements()) {
        return First::OnImage(format!("building profile {}: {e}", plan.to));
    }
    record_installed(&mut state, &plan);
    let _ = save_state(paths, &state);
    let pending = plan.pending(role::now());
    if let Err(e) = save_pending(paths, &pending) {
        return First::OnImage(format!("recording the update: {e}"));
    }
    if let Err(e) = io.arm_guard(&pending) {
        clear_pending(paths);
        return First::OnImage(format!("arming the guard: {e}"));
    }
    if let Err(e) = store::flip(paths, plan.to) {
        io.disarm_guard();
        clear_pending(paths);
        return First::OnImage(format!("flipping to profile {}: {e}", plan.to));
    }
    log(&format!(
        "before the first ready: profile {} -> {}: cmux-tui {} ({})",
        plan.from,
        plan.to,
        role::short_hex(&plan.cmux_tui.sha256),
        role::short_hex(&plan.commit)
    ));
    io.restart_others(&role::store_binary(&plan.old_cmux_tui));
    First::Flipped(plan.commit)
}

/// The machine's own effects.
struct Machine;

impl Io for Machine {
    fn read_channel(&mut self) -> Result<Payload, String> {
        role::read_channel()
    }
    fn download(&mut self, bin: &Binary, to: &Path) -> Result<(), String> {
        role::fetch(&bin.url, bin.size, Some(to)).map(drop)
    }
    fn arm_guard(&mut self, pending: &Pending) -> Result<(), String> {
        role::arm_guard(pending)
    }
    fn disarm_guard(&mut self) {
        role::disarm_guard();
    }
    fn restart_others(&mut self, old: &Path) {
        role::restart_others(old);
    }
}

/// `cmux host run`'s first step on a Cloud machine, before the session host and
/// the roles: on a machine an image made, the channel's build within [`BOUND`].
/// Returns `Ok` when this process stays (the image's build is current, or the step
/// did not finish in time); after a flip it execs the unit's command again and
/// never returns, or answers `Err` when that exec failed: the caller exits, and
/// the service starts the new build that `current` already links.
pub fn run(paths: &Paths) -> Result<(), ()> {
    use std::os::unix::process::CommandExt as _;
    if !paths.is_system_root() || not_first(paths).is_some() {
        return Ok(());
    }
    let args: Vec<_> = std::env::args_os().collect();
    let Some(program) = args.first().map(Path::new).filter(|p| p.starts_with(CURRENT_BIN)) else {
        return Ok(());
    };
    let Some(target) = channel::local_target() else { return Ok(()) };
    let started = Instant::now();
    let deadline = started + BOUND;
    let first = role::within(deadline, || before_ready(paths, target, deadline, &mut Machine));
    log(&format!("before the first ready: {first:?} in {} ms", started.elapsed().as_millis()));
    if !matches!(first, First::Flipped(_)) {
        return Ok(());
    }
    let err = std::process::Command::new(program).args(&args[1..]).exec();
    log(&format!("exec {}: {err}; exiting so the service starts the new build", program.display()));
    Err(())
}
