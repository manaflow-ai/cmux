//! Wake-to-first-echo timing, sans I/O (RFD 0063, hq#21300): every resume of the guest becomes one
//! `wake` block in a `cloud.vm.status.report`, with the wall-clock marks the Cloud splits into
//! phases (restore, net up, pty attach, echo).
//!
//! The marks, all wall-clock epoch ms on this machine:
//! - `resumed_at`: the supervisor's resume reached this role (the guest's clock is set by then).
//! - `net_up_at`: the first status report after the resume came back ok (the guest reaches the
//!   Cloud again).
//! - `pty_attach_at`: the first person's client (tui, web, mac, frontend) attached to the daemon
//!   after the resume (the daemon's `last_person_attach_at_ms`, capability `vm-activity-echo-v1`).
//! - `input_at`, `echo_at`: that person's first input after the attach and the first terminal
//!   output that followed it (`echo_input_at_ms`, `echo_at_ms`).
//!
//! The block is versioned (`v`: 1); the Cloud ignores any other version, and a report without it
//! reads as before. An older daemon sends none of its marks: the wake ends at its deadline as a
//! `timeout` with only the marks this role took.

use serde_json::{Value, json};

/// The wake block's version; the Cloud records only the versions it knows.
pub const WAKE_ECHO_VERSION: u64 = 1;

/// How long after a resume the role waits for the first echo before it reports the wake as a
/// `timeout`.
pub const WAKE_ECHO_DEADLINE_MS: u64 = 10 * 60 * 1000;

/// A daemon mark this much before `resumed_at` still counts as this wake's: the role learns of the
/// resume a moment after the guest runs again, and a person's client may reattach first. A mark
/// from before the pause is older by at least the pause.
pub const WAKE_MARK_SLACK_MS: u64 = 2_000;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Wake {
    /// The role's monotonic clock at the resume, and the wall clock then.
    resumed_mono: u64,
    resumed_at: u64,
    net_up_at: Option<u64>,
    pty_attach_at: Option<u64>,
    input_at: Option<u64>,
    echo_at: Option<u64>,
    /// The resume's working-set prefetch (`resume_prefetch.rs`), only with the setting on.
    prefetch: Option<Value>,
}

impl Wake {
    fn wall(&self, mono: u64) -> u64 {
        self.resumed_at + mono.saturating_sub(self.resumed_mono)
    }

    fn block(&self, outcome: &str) -> Value {
        let mut b = json!({
            "v": WAKE_ECHO_VERSION,
            "resumed_at": self.resumed_at,
            "net_up_at": self.net_up_at,
            "pty_attach_at": self.pty_attach_at,
            "input_at": self.input_at,
            "echo_at": self.echo_at,
            "outcome": outcome,
        });
        // Optional in v1: a reader that does not know it ignores it (cmux-platform reads named keys).
        if let Some(p) = &self.prefetch {
            b["prefetch"] = p.clone();
        }
        b
    }
}

/// The wake being measured and the last finished one.
#[derive(Debug, Default)]
pub struct WakeEcho {
    cur: Option<Wake>,
    done: Option<Value>,
}

impl WakeEcho {
    /// The guest resumed at monotonic `now`, wall-clock `wall`. A wake still being measured ends
    /// as a `timeout` (it never echoed before this pause) and is returned to report.
    pub fn resumed(&mut self, now: u64, wall: u64) -> Option<Value> {
        let ended = self.cur.take().map(|w| self.finish(w, "timeout"));
        self.cur = Some(Wake {
            resumed_mono: now,
            resumed_at: wall,
            net_up_at: None,
            pty_attach_at: None,
            input_at: None,
            echo_at: None,
            prefetch: None,
        });
        ended
    }

    /// A status report came back ok at monotonic `now`: the first after a resume is net up.
    pub fn report_ok(&mut self, now: u64) {
        if let Some(w) = self.cur.as_mut()
            && w.net_up_at.is_none()
        {
            w.net_up_at = Some(w.wall(now));
        }
    }

    /// One daemon activity snapshot or event. Returns the finished block when it holds this
    /// wake's echo.
    pub fn daemon_activity(&mut self, activity: &Value) -> Option<Value> {
        let w = self.cur.as_mut()?;
        let floor = w.resumed_at.saturating_sub(WAKE_MARK_SLACK_MS);
        let mark = |key: &str| activity[key].as_u64().filter(|ms| *ms >= floor);
        if w.pty_attach_at.is_none() {
            w.pty_attach_at = mark("last_person_attach_at_ms");
        }
        let attach = w.pty_attach_at?;
        // The daemon resets its echo pair on every person attach, so a pair whose input follows
        // the first attach of this wake is this wake's (a later attach's pair still is: the
        // person's first echo after waking).
        let input = mark("echo_input_at_ms").filter(|ms| *ms >= attach)?;
        let echo = mark("echo_at_ms").filter(|ms| *ms >= input)?;
        let mut w = self.cur.take()?;
        w.input_at = Some(input);
        w.echo_at = Some(echo);
        Some(self.finish(w, "echoed"))
    }

    /// Sets the wake's `prefetch` field. `resumed_at` names the wake it is for (`None`: the one being
    /// measured). When that wake already finished, its kept block is rewritten and `(old, new)`
    /// returned so the caller can swap a block not yet delivered.
    pub fn set_prefetch(
        &mut self,
        resumed_at: Option<u64>,
        prefetch: Value,
    ) -> Option<(Value, Value)> {
        if let Some(w) = self.cur.as_mut()
            && resumed_at.is_none_or(|at| at == w.resumed_at)
        {
            w.prefetch = Some(prefetch);
            return None;
        }
        let at = resumed_at?;
        let done = self.done.as_mut()?;
        if done["resumed_at"].as_u64() != Some(at) {
            return None;
        }
        let old = done.clone();
        done["prefetch"] = prefetch;
        Some((old, done.clone()))
    }

    /// Runs the deadline: a wake with no echo by then ends as a `timeout`.
    pub fn fire(&mut self, now: u64) -> Option<Value> {
        let due = self.next_deadline().is_some_and(|at| at <= now);
        if !due {
            return None;
        }
        let w = self.cur.take()?;
        Some(self.finish(w, "timeout"))
    }

    pub fn next_deadline(&self) -> Option<u64> {
        self.cur.as_ref().map(|w| w.resumed_mono + WAKE_ECHO_DEADLINE_MS)
    }

    /// The wake being measured (its block so far, `outcome` null) or else the last finished one,
    /// for the role's state file.
    pub fn latest(&self) -> Option<Value> {
        match &self.cur {
            Some(w) => {
                let mut b = w.block("");
                b["outcome"] = Value::Null;
                Some(b)
            }
            None => self.done.clone(),
        }
    }

    fn finish(&mut self, w: Wake, outcome: &str) -> Value {
        let block = w.block(outcome);
        self.done = Some(block.clone());
        block
    }
}
