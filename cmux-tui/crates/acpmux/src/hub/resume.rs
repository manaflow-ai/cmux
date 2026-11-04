//! Part of `Hub`; see `hub/mod.rs`. After this machine or this daemon did not run for a while (a
//! paused VM resumed, a computer woke, a `SIGSTOP` ended: `crate::resume`), a turn in flight goes
//! on where it was.
//!
//! A gap is time in which no sign of a model could have arrived, and the model streams held
//! across it come back late (a busy TCP stream is retransmitted on its sender's backoff, up to
//! about 90 s after the resume). So on a gap every running turn's silent and stalled counts start
//! again from the resume (`silent_turn.rs`, `stalled_turn.rs`), a running chat logs one
//! `host_notice` {text, source: "resume", gapMs, kind} naming the gap, and the daemon log says it.
//! Nothing is sent again and no tool call runs twice: the agents' own processes and their local
//! host links (`agent_host/`) ran through the same gap and keep their sequence; only the counts
//! that judge them are moved. The peer links redial on their own wake check (`peer_link::SleepWatch`).
//! Subscribers of [`Hub::subscribe_resumes`] (the Cloud activity report) act on the same gap.
//!
//! One task checks the clocks every `ResumeWatch::EVERY` (10 s) while something reads the gaps: a
//! running turn, or a subscriber of [`Hub::subscribe_resumes`]. When neither is left it parks the
//! watch and waits, with no timer, for the next `turn_started` record (or a timer of a turn that
//! checks first): an idle daemon does not wake for it (cmux-ad m9: 10 s ticks, each one waking a
//! blocking-pool thread, were the measured wakeups of an idle macOS daemon). It ends with the hub
//! (its weak reference) or once shutdown starts (`stopping`). A timer about to judge a turn checks first
//! ([`Hub::check_resume`]), so a turn whose deadline passed while the daemon was stopped is never
//! judged before the gap is seen, whichever timer the runtime fires first.

use super::*;
use crate::resume::{Resume, ResumeWatch};

/// The monotonic clock the watch reads: real time, never the hub clock, so a test that moves a
/// `ManualClock` is not a gap.
fn mono_now() -> std::time::Duration {
    static ORIGIN: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    ORIGIN.get_or_init(std::time::Instant::now).elapsed()
}

/// The hub's watch, and the signal a check of a parked watch gives the parked task.
pub(crate) struct ResumeState {
    watch: StdMutex<ResumeWatch>,
    unparked: Notify,
}

pub(super) fn new_watch() -> Arc<ResumeState> {
    Arc::new(ResumeState {
        watch: StdMutex::new(ResumeWatch::new(crate::store::now_ms(), mono_now())),
        unparked: Notify::new(),
    })
}

impl Hub {
    /// How many gaps this daemon saw; changes once per gap.
    /// A new subscriber starts a parked tick (it reads gaps from now on).
    pub fn subscribe_resumes(&self) -> tokio::sync::watch::Receiver<u64> {
        let receiver = self.resumes.subscribe();
        if self.resume_watch.watch.lock().unwrap_or_else(|e| e.into_inner()).parked() {
            self.resume_watch.unparked.notify_one();
        }
        receiver
    }

    /// Called before a turn is set (started, restored on adoption, carried, put back after a
    /// failover): a parked watch is checked now, while the turn is not set yet, so a sleep while
    /// no turn ran is seen as a gap of no turn (never told in the new turn), and the tick starts.
    pub(super) fn resume_before_turn(&self) {
        let parked = self.resume_watch.watch.lock().unwrap_or_else(|e| e.into_inner()).parked();
        if parked {
            self.check_resume();
        }
    }

    /// Tests: the watch as an idle daemon leaves it: parked, the wall clock `lead` ahead of the
    /// monotonic one (the computer slept that long while no turn ran).
    #[doc(hidden)]
    pub fn park_resume_watch_after_sleep(&self, lead: std::time::Duration) {
        let lead_ms = u64::try_from(lead.as_millis()).unwrap_or(u64::MAX);
        let mut watch = self.resume_watch.watch.lock().unwrap_or_else(|e| e.into_inner());
        *watch = ResumeWatch::new(crate::store::now_ms().saturating_sub(lead_ms), mono_now());
        watch.park();
    }

    /// The gaps seen so far.
    pub fn resume_count(&self) -> u64 {
        *self.resumes.borrow()
    }

    /// Reads the clocks now; a gap since the last check is handled before this returns.
    /// A check of a parked watch (a turn's timer while the tick waits) starts the tick again.
    pub(super) fn check_resume(&self) -> Option<Resume> {
        self.observe_resume(true)
    }

    /// `check_resume`; `wake_tick`: a check of a parked watch starts the parked tick. The tick's
    /// own check never does: it would leave a permit that ends its next park at once, and the
    /// tick would spin (cmux-ad m9: 35,000 switches per 10 s on macOS, job c1c0f4a2).
    fn observe_resume(&self, wake_tick: bool) -> Option<Resume> {
        let (was_parked, resume) = {
            let mut watch = self.resume_watch.watch.lock().unwrap_or_else(|e| e.into_inner());
            let was_parked = watch.parked();
            (was_parked, watch.observe(crate::store::now_ms(), mono_now()))
        };
        if was_parked && wake_tick {
            self.resume_watch.unparked.notify_one();
        }
        let resume = resume?;
        self.machine_resumed(resume);
        Some(resume)
    }

    /// Whether anything reads the gaps now: a running turn here, or a subscriber.
    fn resume_needed(&self) -> bool {
        if self.resumes.receiver_count() > 0 {
            return true;
        }
        // Unsorted, and released before any turn lock is taken.
        let all: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        all.iter().any(|s| s.turn.lock().unwrap_or_else(|e| e.into_inner()).is_some())
    }

    /// Handles one gap (module docs). Public so a test can stand in for a paused machine.
    pub fn machine_resumed(&self, resume: Resume) {
        let gap_ms = resume.gap_ms();
        let mut running = 0usize;
        for session in self.sessions() {
            let Some(turn) = session.turn() else { continue };
            running += 1;
            // The stalled count, where one runs, starts again now (and a stalled end decided
            // before the gap is not carried out: `stalled_gen`).
            if Self::counted_turn(&session).is_some() {
                self.heard_now(&session);
            }
            let text = format!(
                "This machine was {} for {}; the turn goes on where it was",
                resume.kind.as_str(),
                gap_text(gap_ms)
            );
            self.append(
                &session,
                "mux",
                crate::server::host_notice::KIND,
                json!({
                    "text": text,
                    "source": "resume",
                    "gapMs": gap_ms,
                    "kind": resume.kind.as_str(),
                    "turnId": turn.turn_id,
                }),
            );
        }
        tracing::warn!(
            gap_ms,
            kind = resume.kind.as_str(),
            running,
            "this machine did not run for {}: running turns' counts start again",
            gap_text(gap_ms)
        );
        // Silent-turn waits read this and wait a full period again.
        self.resumes.send_modify(|n| *n += 1);
        self.idle_wake.notify_one();
    }

    /// Checks the clocks every `ResumeWatch::EVERY` while [`Hub::resume_needed`], else parks
    /// (module docs), until the hub goes or shutdown starts.
    pub async fn resume_loop(hub: std::sync::Weak<Hub>) {
        loop {
            let mut tick = tokio::time::interval(ResumeWatch::EVERY);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            // Ticking: the first tick is at once (a start, or the turn that unparked it).
            let (mut events, state) = loop {
                tick.tick().await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.stopping.load(Ordering::SeqCst) {
                    return;
                }
                // Subscribed before the check, so a turn that starts in between is not missed.
                let events = hub.subscribe();
                // Appends write the chat logs: off the runtime's threads.
                let checked = hub.clone();
                let _ = tokio::task::spawn_blocking(move || checked.observe_resume(false)).await;
                if !hub.resume_needed() {
                    hub.resume_watch.watch.lock().unwrap_or_else(|e| e.into_inner()).park();
                    break (events, Arc::clone(&hub.resume_watch));
                }
            };
            // Parked: no timer, and no strong reference to the hub (its end closes `events`). A
            // local turn's start, or a check of the parked watch, ends it.
            loop {
                tokio::select! {
                    event = events.recv() => match event {
                        Ok(event) if event.remote.is_none() && event.record.kind == "turn_started" => break,
                        Ok(_) => {}
                        // Missed records: look at the turns themselves.
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                            let Some(hub) = hub.upgrade() else { return };
                            if hub.resume_needed() {
                                break;
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                    },
                    () = state.unparked.notified() => break,
                }
            }
            drop(events);
        }
    }
}

/// `ms` as a person says it: `2m 14s`, `40s`.
fn gap_text(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        3600.. => format!("{}h {}m", s / 3600, s % 3600 / 60),
        60.. => format!("{}m {}s", s / 60, s % 60),
        _ => format!("{s}s"),
    }
}
