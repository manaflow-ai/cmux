//! Part of `Hub`; see `hub/mod.rs`. The daemon's per-session disk watcher (`session_disk.rs`):
//! one task that measures every acpmux scope once a `TICK`, warns a session over its disk budget
//! in its chat, and stops (SIGSTOP) its top writer's process group while the host's disk is under
//! its floor. Its readings and each scope's budget are `daemon status`'s `sessionBudgets`
//! (`session_budget::status`, versioned).

use super::*;
use crate::session_disk::{self, Action, Sample};

/// The notice's sender.
const SENDER: &str = "acpmux";

impl Hub {
    /// Starts the watcher; off (`session_disk::enabled`, a disk budget of 0) it starts nothing.
    pub fn start_session_budget_watch(self: &Arc<Self>) {
        if !session_disk::enabled() {
            return;
        }
        #[cfg(target_os = "linux")]
        {
            let Some(manager) = std::fs::read_to_string("/proc/self/cgroup")
                .ok()
                .as_deref()
                .and_then(session_disk::manager_dir)
            else {
                return;
            };
            // Weak: the watcher never keeps a stopped hub alive; the hub's scope ends it.
            let weak = Arc::downgrade(self);
            self.scope.spawn_until_cancelled("session-budget-watch", async move {
                let floor = tokio::task::spawn_blocking(|| {
                    crate::placement::disk_floor(
                        crate::placement::load_registry().as_ref(),
                        &crate::host_pressure::host_name(),
                    )
                })
                .await
                .unwrap_or(10_000_000_000);
                let mut next = session_disk::TICK;
                loop {
                    tokio::time::sleep(next).await;
                    let Some(hub) = weak.upgrade() else { return };
                    if hub.stopping.load(Ordering::SeqCst) {
                        return;
                    }
                    let manager = manager.clone();
                    let (actions, tick) = tokio::task::spawn_blocking(move || {
                        let (budget, _) = crate::session_budget::daemon_budget();
                        let free = crate::session_budget::home_disk().map_or(u64::MAX, |(_, f)| f);
                        let mut known = std::mem::take(
                            &mut session_disk::shared()
                                .lock()
                                .unwrap_or_else(|e| e.into_inner())
                                .sessions,
                        );
                        let (samples, truncated) = session_disk::scan(&manager, &mut known);
                        let mut watch =
                            session_disk::shared().lock().unwrap_or_else(|e| e.into_inner());
                        watch.sessions = known;
                        (watch.budget, watch.free, watch.floor, watch.truncated) =
                            (budget.disk, free, floor, truncated);
                        let actions = watch.apply(samples);
                        (actions, session_disk::next_tick(free, floor))
                    })
                    .await
                    .unwrap_or_else(|_| (Vec::new(), session_disk::TICK));
                    next = tick;
                    for (sample, action) in actions {
                        hub.session_budget_act(&sample, action).await;
                    }
                }
            });
        }
    }

    /// Carries out one watcher `action` for `sample`'s scope and tells its chat.
    async fn session_budget_act(self: &Arc<Self>, sample: &Sample, action: Action) {
        let budget = session_disk::shared().lock().unwrap_or_else(|e| e.into_inner()).budget;
        let gib = |b: u64| format!("{:.1} GiB", b as f64 / (1u64 << 30) as f64);
        let used = gib(sample.used());
        let (title, body) = match action {
            Action::Warn => (
                format!("Disk budget passed: {used} of {}", gib(budget)),
                format!(
                    "Processes in {} have written and kept {} ({} in this session's temporary \
                     directory). Delete what you no longer need; if the host's disk gets low, the \
                     top writer's process group is stopped until space comes back.",
                    sample.scope,
                    gib(sample.written),
                    gib(sample.tmp)
                ),
            ),
            Action::WarnUnstoppable => (
                format!("Disk budget passed with the host's disk low: {used}"),
                format!(
                    "The top writer in {} is the session's own process, so it was not stopped. \
                     Free space now: delete build outputs, logs or temporary files.",
                    sample.scope
                ),
            ),
            Action::Stop(g) => {
                #[cfg(unix)]
                let done = session_disk::signal_group(g, libc::SIGSTOP);
                #[cfg(not(unix))]
                let done = false;
                tracing::warn!(scope = %sample.scope, pgid = g, done, "stopped a disk runaway");
                (
                    format!("Stopped process group {g}: over its disk budget with the disk low"),
                    format!(
                        "It used {used} of {} while the host's free disk fell under its floor. It \
                         resumes by itself once space is back; resume it now with `kill -CONT \
                         -{g}`, or end it with `kill -TERM -{g}`. Rollback: \
                         ACPMUX_SESSION_DISK_WATCH=0.",
                        gib(budget)
                    ),
                )
            }
            Action::Resume(g) => {
                #[cfg(unix)]
                let _ = session_disk::signal_group(g, libc::SIGCONT);
                tracing::info!(scope = %sample.scope, pgid = g, "resumed a stopped disk runaway");
                (format!("Resumed process group {g}"), "The host's disk has room again.".to_owned())
            }
        };
        tracing::warn!(scope = %sample.scope, "{title}");
        let Some(id) = sample.session.as_deref() else { return };
        self.session_budget_notice(id, &title, &body).await;
    }

    /// A tool's notice in chat `session_id`: into a running turn at its next tool step, else a
    /// turn of its own, as a background task's end goes (`bg_notify.rs`).
    async fn session_budget_notice(self: &Arc<Self>, session_id: &str, title: &str, body: &str) {
        let session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned();
        let Some(session) = session else { return };
        if session.closing.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        let notice = json!({"sender": SENDER, "severity": "warn", "title": title});
        let text = crate::prompt_provenance::notice_text(&notice, body);
        let provenance = crate::prompt_provenance::notice(&notice, &session.id);
        let opts = PromptOptions {
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Result),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        if let Err(e) = self.prompt_with(&session, blocks, SENDER, true, opts).await {
            tracing::warn!(session = %session.id, "a disk budget notice: {}", e.message);
        }
    }
}

/// `daemon status`'s `sessionBudgets` (`session_budget::status`).
pub(crate) fn status() -> Value {
    let host = crate::session_budget::this_host();
    let empty = Default::default();
    let get = crate::session_scope::knob_reader(&empty, crate::session_scope::daemon_limits());
    let budget = crate::session_budget::Budget::read(&get, &host);
    let task = crate::session_budget::task_budget_from(&get, &host);
    let watch = session_disk::shared()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .json(session_disk::enabled() && budget.disk > 0);
    crate::session_budget::status(&budget, &task, &host, watch)
}
