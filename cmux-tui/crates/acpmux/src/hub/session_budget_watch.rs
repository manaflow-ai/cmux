//! Part of `Hub`; see `hub/mod.rs`. The daemon's per-session disk watcher (`session_disk.rs`):
//! one task that measures every acpmux scope once a `TICK`, warns a session over its disk budget
//! in its chat, and stops (SIGSTOP) its top writer's process group while the host's disk is under
//! its floor. Its readings and each scope's budget are `daemon status`'s `sessionBudgets`
//! (`session_budget::status`, versioned).
//!
//! A second task, every `session_store::TICK`, measures what each loaded chat keeps in acpmux's
//! own store (its event log and background output) against its store budget: a chat over it
//! has its sealed log segments compressed, losslessly (`cold_segments_of`), and is told in its
//! chat once, and again each time it doubles.

use super::*;
use crate::session_disk::{self, Action, Sample};
use crate::session_store;

/// The most cold-segment moves (each at most `cold_segments::PER_PASS` segments) one chat gets
/// in a store pass; the rest waits for the next pass.
const COMPRESS_ROUNDS: usize = 16;

/// The notice's sender.
const SENDER: &str = "acpmux";

/// The most notices one chat holds for its next prompt ([`hold`]); an older one goes first.
const HELD_MAX: usize = 4;

/// Notices that ask nothing now (a budget passed with the disk not low, a store compressed, a
/// group resumed), held for their chat's next prompt when no turn runs to steer into
/// (`take_held`). A turn of their own woke an idle lane for a turn that made no tool call: 23 of
/// them in a day on gcp-agent-lane-19, 103 acpmux notices on gcp-agent-lane-5 (goal
/// wakes-per-landed-pr). In memory: a daemon restart drops them, as it drops `verify`'s.
static HELD: std::sync::LazyLock<StdMutex<HashMap<String, Vec<String>>>> =
    std::sync::LazyLock::new(Default::default);

/// Holds `text` for chat `session_id`'s next prompt.
fn hold(session_id: &str, text: String) {
    let mut map = HELD.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() > 1000 {
        map.clear();
    }
    let held = map.entry(session_id.to_owned()).or_default();
    if held.len() >= HELD_MAX {
        held.remove(0);
    }
    held.push(text);
}

/// The held notices of chat `session_id`, for its next prompt's hidden context, once.
pub(super) fn take_held(session_id: &str) -> Option<String> {
    let held = HELD.lock().unwrap_or_else(|e| e.into_inner()).remove(session_id)?;
    Some(held.join("\n\n"))
}

impl Hub {
    /// Starts the watcher; off (`session_disk::enabled`, a disk budget of 0) it starts nothing.
    pub fn start_session_budget_watch(self: &Arc<Self>) {
        self.start_session_store_watch();
        #[cfg(target_os = "linux")]
        {
            let Some(manager) = std::fs::read_to_string("/proc/self/cgroup")
                .ok()
                .as_deref()
                .and_then(session_disk::manager_dir)
            else {
                return;
            };
            // A group the last daemon stopped resumes now, watcher on or off: no chat stays frozen
            // because the daemon that stopped it went away.
            let home = crate::config::home();
            for g in session_disk::resume_left_stopped(&home, &manager, |pgid| {
                session_disk::signal_group(pgid, libc::SIGCONT)
            }) {
                tracing::info!(scope = %g.scope, pgid = g.pgid, "resumed a group the last daemon stopped");
            }
            if !session_disk::enabled() {
                return;
            }
            // Weak: the watcher never keeps a stopped hub alive; the hub's scope ends it.
            let weak = Arc::downgrade(self);
            self.scope.spawn_until_cancelled("session-budget-watch", async move {
                let floor = tokio::task::spawn_blocking(|| {
                    // The hosts slice's total (`session_total.rs`), once per daemon.
                    crate::session_total::limit_hosts_slice(
                        &crate::session_budget::daemon_totals().1,
                    );
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
                    let (manager, home) = (manager.clone(), home.clone());
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
                        crate::session_total::sweep_blocking(&manager);
                        let mut watch =
                            session_disk::shared().lock().unwrap_or_else(|e| e.into_inner());
                        watch.sessions = known;
                        (watch.budget, watch.free, watch.floor, watch.truncated) =
                            (budget.disk, free, floor, truncated);
                        let held = watch.stopped();
                        let actions = watch.apply(samples);
                        // Written before any SIGSTOP goes out, so a restart can resume it.
                        let stopped = watch.stopped();
                        if stopped != held
                            && let Err(e) = session_disk::write_ledger(&home, &stopped)
                        {
                            tracing::warn!("could not write {}: {e}", session_disk::LEDGER);
                        }
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
        // The disk low (a writer stopped, or one that could not be) wakes the chat: it must free
        // space now. A budget passed with room left, or a group resumed, waits for its next turn.
        let wake = matches!(action, Action::WarnUnstoppable | Action::Stop(_));
        self.session_budget_notice(id, &title, &body, wake).await;
    }

    /// A tool's notice in chat `session_id`: into a running turn at its next tool step, else a
    /// turn of its own when `wake`, as a background task's end goes (`bg_notify.rs`), or held for
    /// the chat's next prompt ([`hold`]).
    async fn session_budget_notice(
        self: &Arc<Self>,
        session_id: &str,
        title: &str,
        body: &str,
        wake: bool,
    ) {
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
        let mut opts = PromptOptions {
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Result),
            ..PromptOptions::default()
        };
        if !wake {
            let steerable = session.steering.load(Ordering::SeqCst);
            let Some(turn) = session.turn().filter(|_| steerable) else {
                hold(&session.id, text);
                return;
            };
            // Into this turn only: one that ended meanwhile must not become a turn of its own.
            opts.steer_only = true;
            opts.interrupt_turn = Some(turn.turn_id.clone());
        }
        let blocks = vec![json!({"type": "text", "text": text.clone()})];
        if let Err(e) = self.prompt_with(&session, blocks, SENDER, true, opts).await {
            if !wake {
                hold(&session.id, text);
                return;
            }
            tracing::warn!(session = %session.id, "a disk budget notice: {}", e.message);
        }
    }
}

impl Hub {
    /// Starts the store budget pass (`session_store.rs`); a budget of 0 starts nothing.
    fn start_session_store_watch(self: &Arc<Self>) {
        let (budget, compress) = store_knobs();
        {
            let mut watch = session_store::shared().lock().unwrap_or_else(|e| e.into_inner());
            (watch.budget, watch.compress) = (budget, compress);
        }
        if budget == 0 || !cfg!(target_os = "linux") {
            return;
        }
        // Weak: the pass never keeps a stopped hub alive; the hub's scope ends it.
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("session-store-watch", async move {
            loop {
                tokio::time::sleep(session_store::TICK).await;
                let Some(hub) = weak.upgrade() else { return };
                if hub.stopping.load(Ordering::SeqCst) || hub.shutting_down() {
                    return;
                }
                let worker = hub.clone();
                let actions = tokio::task::spawn_blocking(move || worker.session_store_pass())
                    .await
                    .unwrap_or_default();
                for (id, action) in actions {
                    if let session_store::Action::Warn { bytes } = action {
                        hub.session_store_warn(&id, bytes).await;
                    }
                }
            }
        });
    }

    /// One store pass, on a blocking thread: measures every loaded chat (at most
    /// `session_store::MAX_SESSIONS`), compresses the ones over, and answers the actions.
    pub(crate) fn session_store_pass(&self) -> Vec<(String, session_store::Action)> {
        let (budget, compress) = store_knobs();
        let ids: Vec<String> = self.sessions().into_iter().map(|s| s.id.clone()).collect();
        self.session_store_pass_of(ids, budget, compress)
    }

    /// [`Self::session_store_pass`] over `ids` at `budget` bytes.
    pub(crate) fn session_store_pass_of(
        &self,
        mut ids: Vec<String>,
        budget: u64,
        compress: bool,
    ) -> Vec<(String, session_store::Action)> {
        let bg = crate::config::home().join("bg");
        let truncated = ids.len() > session_store::MAX_SESSIONS;
        ids.truncate(session_store::MAX_SESSIONS);
        let readings = ids
            .into_iter()
            .map(|id| {
                let dir = self.store.session_path(&id);
                let (bytes, partial) = session_store::measure(dir.as_deref(), &bg.join(&id));
                (id, bytes, partial)
            })
            .collect();
        let actions = {
            let mut watch = session_store::shared().lock().unwrap_or_else(|e| e.into_inner());
            (watch.budget, watch.compress, watch.truncated) = (budget, compress, truncated);
            watch.apply(readings)
        };
        for (id, action) in &actions {
            if *action != session_store::Action::Compress {
                continue;
            }
            let saved = self.session_store_compress(id);
            if saved > 0 {
                let mut watch = session_store::shared().lock().unwrap_or_else(|e| e.into_inner());
                if let Some(entry) = watch.sessions.get_mut(id) {
                    entry.saved = entry.saved.saturating_add(saved);
                }
            }
        }
        actions
    }

    /// Compresses `id`'s sealed log segments (lossless, the cold segment move), at most
    /// [`COMPRESS_ROUNDS`] moves: the bytes it saved.
    fn session_store_compress(&self, id: &str) -> u64 {
        let level = crate::store::cold_segments::DEFAULT_LEVEL;
        let mut saved = 0u64;
        for _ in 0..COMPRESS_ROUNDS {
            if self.shutting_down() {
                break;
            }
            match self.cold_segments_of(id, Some(level)) {
                Ok((moved, more)) => {
                    saved = saved.saturating_add(moved.raw.saturating_sub(moved.comp));
                    if !more {
                        break;
                    }
                }
                Err(e) => {
                    tracing::warn!(session = %id, "store budget: compressing its log: {e:#}");
                    break;
                }
            }
        }
        if saved > 0 {
            tracing::info!(session = %id, saved, "store budget: compressed sealed log segments");
        }
        saved
    }

    /// Tells chat `id` it passed its store budget at `bytes`.
    async fn session_store_warn(self: &Arc<Self>, id: &str, bytes: u64) {
        let (budget, compress) = {
            let watch = session_store::shared().lock().unwrap_or_else(|e| e.into_inner());
            (watch.budget, watch.compress)
        };
        let mib = |b: u64| format!("{:.0} MiB", b as f64 / (1u64 << 20) as f64);
        let title = format!("Chat store budget passed: {} of {}", mib(bytes), mib(budget));
        let kept = if compress {
            "Its older log segments are being compressed (lossless: every line stays readable, \
             nothing is deleted)."
        } else {
            "Compression is off (ACPMUX_SESSION_STORE_COMPRESS=0), so nothing was changed."
        };
        let body = format!(
            "This chat's event log and background task output in acpmux's store hold {}. {kept} \
             Large tool outputs and long-running commands grow it most; start a new chat for new \
             work. Rollback: ACPMUX_SESSION_STORE_MB=0.",
            mib(bytes)
        );
        tracing::warn!(session = %id, bytes, budget, "{title}");
        // Nothing to do now: the compression runs by itself.
        self.session_budget_notice(id, &title, &body, false).await;
    }
}

/// The store budget and whether it compresses, from the daemon config and env.
fn store_knobs() -> (u64, bool) {
    let empty = Default::default();
    let get = crate::session_scope::knob_reader(&empty, crate::session_scope::daemon_limits());
    let (budget, _) = crate::session_budget::daemon_budget();
    (session_store::budget_from(&get, budget.disk), session_store::compress_from(&get))
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
    let tasks = crate::session_scope::sessions_tasks_default(crate::session_scope::threads_max());
    let session_total = crate::session_budget::session_total_from(&get, &host, &budget);
    let hosts_total = crate::session_budget::hosts_total_from(&get, &host, tasks);
    let store = session_store::shared()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .json(cfg!(target_os = "linux"));
    crate::session_budget::status(
        &budget,
        &task,
        (&session_total, &hosts_total),
        &host,
        watch,
        store,
    )
}

#[cfg(test)]
mod tests {
    use super::{HELD_MAX, hold, take_held};

    /// A held notice rides the next prompt once, and a chat holds at most `HELD_MAX`, newest kept.
    #[test]
    fn a_held_notice_rides_the_next_prompt_once() {
        let id = "s-budget-held-test";
        assert_eq!(take_held(id), None);
        for n in 0..HELD_MAX + 2 {
            hold(id, format!("notice {n}"));
        }
        let text = take_held(id).expect("held");
        assert!(!text.contains("notice 0") && !text.contains("notice 1"), "{text}");
        assert!(
            text.starts_with("notice 2") && text.ends_with(&format!("notice {}", HELD_MAX + 1))
        );
        assert_eq!(take_held(id), None, "taken once");
    }
}
