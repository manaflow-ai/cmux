//! Working-set prefetch on resume (hq#21300), a hidden setting, default off.
//!
//! The setting is the file [`SETTING_FILE`]: `on` records the working set and prefetches it on
//! each resume; `record` only records (the A/B's off arm, so both arms keep the same plan); absent or
//! anything else does nothing at all. The arm is read at each resume, so a harness can interleave
//! arms on one machine.
//!
//! On a resume with the setting on, a thread touches the last plan's pages
//! (`cmux_resume_prefetch::prefetch`), then, [`RECORD_AFTER`] after the resume, records a new plan
//! from what is resident then and saves it to [`PLAN_FILE`]. The outcome goes into the wake block as
//! `prefetch: {arm, pages, ms, planned, threads}` (wake_echo.rs).

use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::wire::STATE_DIR;

/// The hidden setting: `on`, `record`, or off.
pub const SETTING_FILE: &str = "resume-prefetch";
/// The saved working set (cmux_resume_prefetch::Plan JSON).
pub const PLAN_FILE: &str = "resume-prefetch.plan.json";
/// When a new plan is recorded after a resume: the wake's first work has paged in by then.
pub const RECORD_AFTER: Duration = Duration::from_secs(20);
/// Pages a plan holds at most (4 GiB of 4 KiB pages).
pub const MAX_PAGES: u64 = 1 << 20;
/// A prefetch stops here even if pages are left.
pub const DEADLINE: Duration = Duration::from_secs(20);
pub const THREADS: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arm {
    On,
    Record,
}

impl Arm {
    pub fn parse(text: Option<&str>) -> Option<Arm> {
        match text.map(str::trim) {
            Some("on") => Some(Arm::On),
            Some("record") => Some(Arm::Record),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Arm::On => "on",
            Arm::Record => "record",
        }
    }
}

/// The wake block's `prefetch` field for one resume.
pub fn block(
    arm: Arm,
    planned: Option<u64>,
    outcome: Option<&cmux_resume_prefetch::Outcome>,
) -> Value {
    match (arm, outcome) {
        (Arm::On, Some(o)) => json!({
            "arm": arm.name(), "pages": o.touched, "ms": o.ms, "planned": o.planned,
            "threads": o.threads, "stale_procs": o.stale_procs, "cut": o.cut,
        }),
        _ => json!({ "arm": arm.name(), "pages": 0, "ms": null, "planned": planned }),
    }
}

/// The prefetch thread of the latest resume and the socket that wakes the poll loop when it is done.
pub struct Runner {
    dir: PathBuf,
    wake_rx: UnixStream,
    wake_tx: UnixStream,
    /// (resumed_at wall ms, block) once the prefetch is done.
    done: Arc<Mutex<Option<(u64, Value)>>>,
}

impl Runner {
    /// `dir` is [`STATE_DIR`] under the agent's root.
    pub fn new(dir: PathBuf) -> std::io::Result<Runner> {
        let (wake_rx, wake_tx) = UnixStream::pair()?;
        wake_rx.set_nonblocking(true)?;
        Ok(Runner { dir, wake_rx, wake_tx, done: Arc::new(Mutex::new(None)) })
    }

    pub fn state_dir(paths: &crate::config::Paths) -> PathBuf {
        paths.at(STATE_DIR)
    }

    pub fn fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd;
        self.wake_rx.as_raw_fd()
    }

    /// The arm the setting names now.
    pub fn arm(&self) -> Option<Arm> {
        Arm::parse(std::fs::read_to_string(self.dir.join(SETTING_FILE)).ok().as_deref())
    }

    /// A resume at wall-clock `resumed_at`: starts the thread when the setting is on. Returns the
    /// arm, so the wake block can say so before the thread is done.
    pub fn resumed(&self, resumed_at: u64) -> Option<Arm> {
        let arm = self.arm()?;
        let plan_path = self.dir.join(PLAN_FILE);
        let done = Arc::clone(&self.done);
        let tx = self.wake_tx.try_clone().ok();
        let began = Instant::now();
        let spawned = std::thread::Builder::new().name("resume-prefetch".into()).spawn(move || {
            let plan = std::fs::read_to_string(&plan_path)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .and_then(|v| cmux_resume_prefetch::Plan::from_json(&v));
            let outcome = match (&plan, arm) {
                (Some(p), Arm::On) => Some(cmux_resume_prefetch::prefetch(p, THREADS, DEADLINE)),
                _ => None,
            };
            let b =
                block(arm, plan.as_ref().map(cmux_resume_prefetch::Plan::pages), outcome.as_ref());
            if let Ok(mut slot) = done.lock() {
                *slot = Some((resumed_at, b));
            }
            if let Some(mut tx) = tx {
                let _ = tx.write_all(b"p");
            }
            std::thread::sleep(RECORD_AFTER.saturating_sub(began.elapsed()));
            let fresh = cmux_resume_prefetch::record(MAX_PAGES);
            let tmp = plan_path.with_extension("json.tmp");
            if std::fs::write(&tmp, fresh.to_json().to_string()).is_ok() {
                let _ = std::fs::rename(&tmp, &plan_path);
            }
        });
        if let Err(e) = spawned {
            super::role::log_line(&format!("resume prefetch: no thread: {e}"));
        }
        Some(arm)
    }

    /// After the poll loop saw [`Runner::fd`] readable: the finished prefetch, if any.
    pub fn take(&self) -> Option<(u64, Value)> {
        let mut buf = [0u8; 64];
        while matches!(std::io::Read::read(&mut &self.wake_rx, &mut buf), Ok(n) if n > 0) {}
        self.done.lock().ok()?.take()
    }
}
