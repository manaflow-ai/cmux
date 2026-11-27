//! Part of `Hub`; see `hub/mod.rs`. The machine cleans up after its agents
//! (`cmux-worktree-care`): a pass over this machine's git worktrees archives
//! and removes those nothing uses any more, and trims the build output of
//! idle ones it keeps.
//!
//! A pass runs when something may have freed a worktree (a session went
//! idle at a turn's end or closed, the daemon started: `set_status` and
//! `startup` wake one worker) and the disk says one is due: at
//! most every 6 hours under 80% used, every hour from 80%, every 10 minutes
//! from 90%, counted from the end of the machine's last pass. Nothing runs
//! on a timer. One pass at a time per machine, not per daemon
//! (`cmux_worktree_care::schedule`: a lock and a stamp in the archive
//! store): every daemon on the machine (the app's, the nightly's, each
//! tagged build's) acts on the same worktrees, and a dozen of them each
//! scanning 800 worktrees kept git running all day. Off the runtime: the
//! settings, the disk and the session files are read on a blocking thread
//! too.
//! A whole pass also reports the machine's build caches outside any worktree
//! (Xcode DerivedData per project; SwiftPM, npm and Bun caches under disk
//! pressure only: `cmux_worktree_care::caches`) and removes the idle ones
//! when `worktrees.cleanBuildCaches` is on (default off).
//! The `worktrees.autoCleanup` setting (default on) turns the automatic
//! passes off; `_acpmux/worktree/clean` (the machine view's Clean up now)
//! runs one regardless. Either way a worktree goes only after its quiet
//! time, archived first, with no session in it and nothing holding it open
//! (`procs::open_inside`, right before the removal).
//!
//! A session that starts again in a reclaimed worktree gets it back first
//! (`care_restore_for`, from `cold_start`): its files, index and archived
//! work, before the harness starts in the folder. A folder evicted to a
//! verified cloud copy (`cmux_worktree_care::cold`) comes back the same way
//! (`cold_recall_for`).

use super::*;

mod pr_archive;
pub(in crate::hub) mod revive;
pub(in crate::hub) mod scratch;

/// The refusal of a prompt for session `name` whose folder `cwd` is gone: `session.folder_missing`,
/// naming the folder in its message and data. Retryable: a folder can come back (put back
/// by hand, a worktree recreated), so a sender's outbox keeps the message and sends it again
/// (`server/outbox.rs` `next`); a retry while it is still gone costs one stat (`gone`).
pub(crate) fn folder_missing(name: &str, cwd: &std::path::Path, what: &str) -> RpcError {
    use super::outbox::FOLDER_MISSING;
    RpcError::internal(format!("{FOLDER_MISSING}: the folder of {name} ({}) {what}", cwd.display()))
        .with_data(json!({
            "reason": FOLDER_MISSING,
            "folder": cwd,
            "retryable": true,
        }))
}

/// Folders found gone after every way back was tried (no archive to restore, no recorded worktree
/// or its recreate failed for a reason a retry does not change): a later prompt for a session in
/// one, with the same worktree record, is refused after one stat, with no archive read and no git,
/// until the folder exists again. A daemon restart forgets them, so the full check runs once more.
pub(in crate::hub) mod gone {
    use crate::git_state::WorktreeOrigin;
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::{LazyLock, Mutex};

    struct Gone {
        worktree: Option<WorktreeOrigin>,
        /// The refusal's words after the folder (`folder_missing`).
        what: String,
    }

    /// Bounded: cleared whole past this many folders (each is then checked in full once more).
    const MAX: usize = 1024;

    static GONE: LazyLock<Mutex<HashMap<PathBuf, Gone>>> = LazyLock::new(Default::default);
    /// Full checks of a missing folder (`Hub::folder_ready`), by folder: what a test counts.
    static FULL: LazyLock<Mutex<HashMap<PathBuf, u64>>> = LazyLock::new(Default::default);

    fn gone() -> std::sync::MutexGuard<'static, HashMap<PathBuf, Gone>> {
        GONE.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The refusal's words for `cwd` when it was found gone with this worktree record.
    pub(in crate::hub) fn known(cwd: &Path, worktree: &Option<WorktreeOrigin>) -> Option<String> {
        gone().get(cwd).filter(|g| g.worktree == *worktree).map(|g| g.what.clone())
    }

    pub(in crate::hub) fn mark(cwd: &Path, worktree: &Option<WorktreeOrigin>, what: &str) {
        let mut gone = gone();
        if gone.len() >= MAX && !gone.contains_key(cwd) {
            gone.clear();
        }
        gone.insert(cwd.to_owned(), Gone { worktree: worktree.clone(), what: what.to_owned() });
    }

    pub(in crate::hub) fn forget(cwd: &Path) {
        gone().remove(cwd);
    }

    pub(in crate::hub) fn count_full(cwd: &Path) {
        let mut full = FULL.lock().unwrap_or_else(|e| e.into_inner());
        if full.len() >= MAX && !full.contains_key(cwd) {
            full.clear();
        }
        *full.entry(cwd.to_owned()).or_default() += 1;
    }

    /// How many times a prompt for a session in `cwd` ran the full check (archive read, worktree
    /// recreate) while the folder was missing.
    pub fn full_checks(cwd: &Path) -> u64 {
        FULL.lock().unwrap_or_else(|e| e.into_inner()).get(cwd).copied().unwrap_or(0)
    }
}

use std::path::PathBuf;
use std::sync::LazyLock;
use std::sync::atomic::AtomicU64;
use std::time::Duration;

use cmux_worktree_care::Store as ArchiveStore;
use cmux_worktree_care::care;
use cmux_worktree_care::inventory::now_ms;
use cmux_worktree_care::policy::Settings as CareSettings;
use cmux_worktree_care::schedule::{self, Claim, Refused};

/// How long a session's start waits on its submodules coming back.
const RESTORE_SUBMODULES: Duration = Duration::from_secs(120);

/// Milliseconds per minute for removal log durations.
const MINUTE_MS: u64 = 60 * 1000;

/// This process's cleanup state: one pass at a time in this process (the
/// machine-wide claim is `schedule`), when this process last started one (a
/// floor under the machine's stamp, which a full disk may keep from being
/// written), its report, and one restore at a time (two sessions in one
/// reclaimed worktree start together).
static CARE: LazyLock<CareState> = LazyLock::new(CareState::default);

#[derive(Default)]
struct CareState {
    /// Wakes the worker; `why` names the last trigger.
    wake: Notify,
    why: StdMutex<&'static str>,
    running: AtomicBool,
    last_started_ms: AtomicU64,
    last_report: StdMutex<Option<Value>>,
    restoring: tokio::sync::Mutex<()>,
}

/// Holds `running` for one pass; clears it however the pass ends,
/// a panic or a dropped future included.
struct Running<'a>(&'a AtomicBool);

impl<'a> Running<'a> {
    fn claim(flag: &'a AtomicBool) -> Option<Self> {
        (!flag.swap(true, Ordering::SeqCst)).then_some(Self(flag))
    }
}

impl Drop for Running<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// Whether automatic passes are on (`care_machine`).
pub fn auto_cleanup_enabled() -> bool {
    crate::care_machine::auto_cleanup_enabled()
}

/// A pass report's line for each folder it removed: its path, why, how
/// long it had been idle, its archive id (`acpmux worktree restore <id>`)
/// and the bytes freed. A trim, a kept folder and a failed removal have
/// none.
fn removals(report: &Value) -> Vec<String> {
    let items = report.get("items").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    items
        .iter()
        .filter_map(|item| {
            let action = item.pointer("/verdict/action")?.as_str()?;
            let outcome = item.get("outcome")?;
            let ok = outcome.get("ok").and_then(Value::as_bool) == Some(true);
            if !ok || !matches!(action, "reclaim" | "archive") {
                return None;
            }
            let path = item.get("path")?.as_str()?;
            let reason = item.pointer("/verdict/reason").and_then(Value::as_str).unwrap_or("?");
            let idle = item
                .pointer("/verdict/idleMs")
                .and_then(Value::as_u64)
                .map_or_else(|| "?".to_string(), |ms| (ms / (60 * MINUTE_MS)).to_string());
            let archive = outcome.get("archive").and_then(Value::as_str).unwrap_or("none");
            let freed = outcome.get("freed").and_then(Value::as_u64).unwrap_or(0);
            Some(format!(
                "worktree removed: {path} ({action}: {reason}); idle {idle} h; archive {archive}; \
                 freed {freed} bytes"
            ))
        })
        .collect()
}

fn archive_store() -> Result<ArchiveStore, RpcError> {
    let dir = ArchiveStore::default_dir()
        .ok_or_else(|| RpcError::internal("no home folder for the worktree archive"))?;
    ArchiveStore::open(dir).map_err(RpcError::internal)
}

impl Hub {
    /// A session's status changed: idle (a turn ended) or closed may have
    /// freed a worktree. Only wakes the worker (`care_worker`): no lock is
    /// taken, so any status write may call it.
    pub(super) fn care_status(&self, status: SessionStatus) {
        let why = match status {
            SessionStatus::Idle => "turn_end",
            SessionStatus::Closed => "session_close",
            _ => return,
        };
        self.care_wake(why);
    }

    pub(super) fn care_wake(&self, why: &'static str) {
        *CARE.why.lock().unwrap_or_else(|e| e.into_inner()) = why;
        CARE.wake.notify_one();
    }

    /// Starts the daemon's one cleanup worker: on each wake (a status
    /// change, and once now for the start) it runs a pass when one is due
    /// (`spacing`) and none runs. It holds the hub weakly and ends with it.
    /// Supervised (`crate::supervise`): a pass that panics starts the worker again, which wakes
    /// itself once so the pass that panicked is tried again; before, the panic ended the worker
    /// and no pass ran until the daemon restarted.
    pub(crate) fn care_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let hub = Arc::downgrade(self);
        *CARE.why.lock().unwrap_or_else(|e| e.into_inner()) = "startup";
        CARE.wake.notify_one();
        let mut again = false;
        crate::supervise::restarting("worktree care", &self.fatal, move || {
            if std::mem::replace(&mut again, true) {
                CARE.wake.notify_one();
            }
            let hub = hub.clone();
            async move {
                loop {
                    let why = tokio::select! {
                        () = CARE.wake.notified() => {
                            *CARE.why.lock().unwrap_or_else(|e| e.into_inner())
                        }
                        () = tokio::time::sleep(Duration::from_secs(crate::care_machine::TICK_SECS)) => "tick",
                    };
                    crate::supervise::panic_point("worktree care", why);
                    let Some(hub) = hub.upgrade() else { return };
                    hub.care_if_due(why).await;
                }
            }
        })
    }

    async fn care_if_due(self: &Arc<Self>, why: &'static str) {
        let Some(_running) = Running::claim(&CARE.running) else { return };
        let claim = tokio::task::spawn_blocking(move || {
            if !auto_cleanup_enabled() {
                return None;
            }
            let home = dirs::home_dir()?;
            let store = match archive_store() {
                Ok(store) => store,
                Err(e) => {
                    tracing::warn!(why, "worktree cleanup skipped: {}", e.message);
                    return None;
                }
            };
            // The cheap half: a disk sample every look, the spacing from the budget plan.
            let look = care::look(&home, &store, &CareSettings::default())?;
            let now = now_ms();
            let floor = CARE.last_started_ms.load(Ordering::Relaxed);
            if now.saturating_sub(floor) < look.plan.spacing_ms {
                return None;
            }
            match care::due(&store, &look) {
                Ok(claim) => Some((claim, look)),
                Err(Refused::Unavailable(error)) => {
                    tracing::warn!(why, "worktree cleanup skipped: {error}");
                    None
                }
                Err(Refused::Busy | Refused::NotDue) => None,
            }
        })
        .await
        .ok()
        .flatten();
        let Some((claim, look)) = claim else { return };
        CARE.last_started_ms.store(now_ms(), Ordering::Relaxed);
        match self.care_run(claim, true, Vec::new(), Some(look)).await {
            Ok(report) => {
                // One line per folder that went, so a search of the journal
                // for a missing checkout finds what removed it (hq#13316).
                for line in removals(&report) {
                    tracing::info!(why, "{line}");
                }
                tracing::info!(
                    why,
                    freed = report.get("freed").and_then(|v| v.as_u64()).unwrap_or(0),
                    "worktree cleanup pass"
                )
            }
            Err(e) => tracing::warn!(why, "worktree cleanup pass failed: {}", e.message),
        }
    }

    /// `_acpmux/worktree/report` and `_acpmux/worktree/clean`: a pass now,
    /// acting with `apply`. A report-only pass measures what would be freed.
    pub(crate) async fn care_pass(
        self: &Arc<Self>,
        apply: bool,
        only: Vec<PathBuf>,
    ) -> Result<Value, RpcError> {
        let busy = || RpcError::internal("a worktree cleanup pass or report is already running");
        let Some(_running) = Running::claim(&CARE.running) else { return Err(busy()) };
        // Asked for: no spacing. Only a pass that acts on every worktree
        // counts as the machine's last.
        let record = apply && only.is_empty();
        if record {
            CARE.last_started_ms.store(now_ms(), Ordering::Relaxed);
        }
        let claim = tokio::task::spawn_blocking(move || {
            let store = archive_store()?;
            schedule::claim(&store.dir, now_ms(), None, record).map_err(|refused| match refused {
                Refused::Busy | Refused::NotDue => busy(),
                Refused::Unavailable(error) => RpcError::internal(error),
            })
        })
        .await
        .map_err(|e| RpcError::internal(format!("the cleanup pass stopped: {e}")))??;
        self.care_run(claim, apply, only, None).await
    }

    /// Runs one pass; the caller holds `running` and the machine's `claim`,
    /// which ends with the pass.
    async fn care_run(
        self: &Arc<Self>,
        claim: Claim,
        apply: bool,
        only: Vec<PathBuf>,
        look: Option<care::Look>,
    ) -> Result<Value, RpcError> {
        let home = dirs::home_dir().ok_or_else(|| RpcError::internal("no home folder"))?;
        let hub = Arc::clone(self);
        let daemon_home = crate::config::home();
        let only_given = !only.is_empty();
        let report = tokio::task::spawn_blocking(move || {
            let managed = pr_archive::managed_root(&home);
            let rules = super::auto_settle::read_rules();
            let live = hub.care_sessions(managed.as_deref(), &rules);
            let released: std::collections::HashMap<_, _> = live
                .iter()
                .filter_map(|s| s.archived_checkout.as_ref().map(|c| (c.root.clone(), c.clone())))
                .collect();
            let store = archive_store()?;
            let mut config = crate::care_machine::config(
                &home,
                store,
                live,
                Some(&daemon_home),
                crate::care_machine::Ask {
                    apply,
                    only,
                    // A clean of named worktrees leaves the other families alone.
                    only_families: if only_given {
                        vec![care::WORKTREES.into()]
                    } else {
                        Vec::new()
                    },
                    roots: Vec::new(),
                    pressure: None,
                },
            );
            config.pass.open = Arc::new({
                let home = home.clone();
                move |root| {
                    if let Some(expected) = released.get(root) {
                        let open = cmux_worktree_care::procs::open_tree(root)?;
                        hub.recheck_pr_archive(expected, &home, managed.as_deref())?;
                        return Ok(open);
                    }
                    cmux_worktree_care::procs::open_inside(root)
                }
            });
            let caches_on = config.clean_caches;
            let report = care::run(&config, look.as_ref());
            if let Err(error) = claim.finish(now_ms()) {
                tracing::warn!("worktree cleanup could not record its pass: {error}");
            }
            let report = report.map_err(RpcError::internal)?;
            Ok::<_, RpcError>((report, auto_cleanup_enabled(), caches_on))
        })
        .await
        .map_err(|e| RpcError::internal(format!("the cleanup pass stopped: {e}")))?;
        let (report, auto, caches_on) = report?;
        // Backward compatible: the worktree pass's own report is the body, the
        // caches, budget, forecast and families are added beside it.
        let mut value = serde_json::to_value(&report.worktrees).unwrap_or(Value::Null);
        if let Some(object) = value.as_object_mut() {
            object.insert(
                "caches".into(),
                serde_json::to_value(report.caches).unwrap_or(Value::Null),
            );
            object.insert(
                "budget".into(),
                serde_json::to_value(report.budget).unwrap_or(Value::Null),
            );
            object.insert(
                "forecast".into(),
                serde_json::to_value(report.forecast).unwrap_or(Value::Null),
            );
            object.insert(
                "families".into(),
                serde_json::to_value(report.families).unwrap_or(Value::Null),
            );
            object.insert("projectedFraction".into(), json!(report.projected_fraction));
            object.insert("cleanBuildCaches".into(), json!(caches_on));
            object.insert("autoCleanup".into(), json!(auto));
            object.insert("at".into(), json!(now_ms()));
        }
        *CARE.last_report.lock().unwrap_or_else(|e| e.into_inner()) = Some(value.clone());
        Ok(value)
    }

    /// `_acpmux/worktree/restore`: a reclaimed worktree back, by its
    /// folder, branch or archive id, one restore at a time.
    pub(crate) async fn care_restore(
        &self,
        key: String,
        path: Option<PathBuf>,
    ) -> Result<Value, RpcError> {
        let _one = CARE.restoring.lock().await;
        tokio::task::spawn_blocking(move || {
            let store = archive_store()?;
            let manifest = store.find(&key).ok_or_else(|| {
                RpcError::not_found(format!("no reclaimed worktree matches {key}"))
            })?;
            let restored = cmux_worktree_care::restore::restore(&store, &manifest, path.as_deref())
                .map_err(RpcError::internal)?;
            Ok(json!(restored))
        })
        .await
        .map_err(|e| RpcError::internal(format!("the restore stopped: {e}")))?
    }

    /// The last pass's report, if one ran since the daemon started.
    pub(crate) fn care_last_report(&self) -> Option<Value> {
        CARE.last_report.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Before a session's harness starts: its folder back, when cleanup
    /// reclaimed the worktree it is in. Logged as `worktree_restored`, or
    /// `worktree_restore_failed` (the start goes on and reports the
    /// missing folder as before).
    pub(super) async fn ready_to_start(
        &self,
        session: &Arc<Session>,
        stops: u64,
    ) -> Result<(), RpcError> {
        self.care_restore_for(session).await;
        self.revive_folder(session, &CARE.restoring).await?;
        // A stopped session reopens on demand. Only a purge is final.
        self.reopen_to_start(session, stops)
    }

    /// Before a prompt for a session with no running agent is recorded (`turns.rs`): its folder
    /// (`folder_ready`), then its harness, found from the folder for a folder harness
    /// (`folder_profiles.rs`). A refusal here lets the caller send it again (handoff start).
    pub(super) async fn cold_prompt_check(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        self.folder_ready(session).await?;
        let m = session.meta();
        let cfg = self.config.read().await;
        super::resolve::session_profile_checked(&cfg, &m.harness, &m.cwd, m.remote_origin)?;
        Ok(())
    }

    /// How many times a prompt for a session in `cwd` ran the full folder check (archive read,
    /// worktree recreate) while the folder was missing; a retry after that costs one stat.
    #[doc(hidden)]
    pub fn folder_missing_full_checks(&self, cwd: &std::path::Path) -> u64 {
        gone::full_checks(cwd)
    }

    /// Before a prompt for a session with no running agent is taken: its folder, restored when
    /// cleanup reclaimed it or recreated when it was a recorded worktree (`revive_folder`), or a
    /// refusal naming the folder when it is still gone (a worktree removed by hand, a probe
    /// folder under /tmp). The refusal is retryable, so an outbox delivery (`server/outbox.rs`)
    /// keeps the message and sends it again once the folder is back; while it stays gone, each
    /// retry is one stat (`gone`): no archive read, no git, no harness. Only acpmux's own temporary
    /// folder, which never comes back, is refused for good. A harness started in a
    /// missing folder failed the turn after it was taken, as `spawn harness process: No such
    /// file or directory`.
    async fn folder_ready(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        let meta = session.meta();
        // A proven peer's scratch folder in the temp dir, gone with it (a reboot): made again,
        // so a restart's continuation of its cut turn runs (`worktree_care/scratch.rs`).
        #[cfg(unix)]
        if meta.worktree.is_none() && !meta.remote_origin {
            let cwd = meta.cwd.clone();
            let made =
                tokio::task::spawn_blocking(move || scratch::revive_peer_scratch(&cwd)).await;
            match made {
                Ok(Ok(true)) => {
                    gone::forget(&meta.cwd);
                    self.append(session, "mux", "scratch_recreated", json!({"cwd": meta.cwd}));
                }
                Ok(Err(e)) => {
                    tracing::warn!(session = %session.id, cwd = %meta.cwd.display(), "peer scratch folder not made again: {e}")
                }
                _ => {}
            }
        }
        if tokio::fs::try_exists(&meta.cwd).await.unwrap_or(true) {
            gone::forget(&meta.cwd);
        } else if let Some(what) = gone::known(&meta.cwd, &meta.worktree) {
            return Err(folder_missing(&meta.name, &meta.cwd, &what));
        } else {
            gone::count_full(&meta.cwd);
        }
        let archived = self.care_restore_for(session).await;
        self.revive_folder(session, &CARE.restoring).await?;
        let meta = session.meta();
        // A folder that cannot be read (its permissions) fails at the start as before.
        match tokio::fs::metadata(&meta.cwd).await {
            Ok(m) if m.is_dir() => return Ok(()),
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Ok(()),
            _ => {}
        }
        // A folder in acpmux's own session temp folders never comes back (`session_tmp::holds`):
        // the refusal is final, so an outbox or relayed delivery is refused once, its sender told
        // why, instead of being tried again every minute forever. Any other folder may come back
        // (a worktree removed by hand and made again), so its refusal stays retryable.
        #[cfg(unix)]
        let session_tmp = crate::agent::session_tmp::holds(&meta.cwd);
        // Session temp folders are a unix-only part of acpmux (`agent::session_tmp`).
        #[cfg(not(unix))]
        let session_tmp = false;
        if meta.worktree.is_none() && session_tmp {
            return Err(RpcError::internal(format!(
                "session.folder_missing: the folder of {} ({}) was a temporary folder and is gone \
                 for good, so its agent cannot start again; start a new chat, or archive this one \
                 (`acpmux archive {}`)",
                meta.name,
                meta.cwd.display(),
                meta.name,
            ))
            .with_data(json!({
                "reason": "session.folder_missing",
                "folder": meta.cwd,
                "retryable": false,
                "temporary": true,
            })));
        }
        let what = "no longer exists; it was moved or removed (or a file took its place), so its \
                    agent cannot start until it is back";
        // An archive whose restore failed is read again next time: that may work.
        if !archived && !tokio::fs::try_exists(&meta.cwd).await.unwrap_or(true) {
            gone::mark(&meta.cwd, &meta.worktree, what);
        }
        Err(folder_missing(&meta.name, &meta.cwd, what))
    }

    /// Restores the folder of `session` from cleanup's archive when it is missing and one holds
    /// it. Whether an archive for it was found (restored or not).
    async fn care_restore_for(&self, session: &Arc<Session>) -> bool {
        let cwd = session.meta().cwd.clone();
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            return false;
        }
        let _one = CARE.restoring.lock().await;
        let restored = tokio::task::spawn_blocking(move || {
            // Another session's start may have brought it back meanwhile.
            if cwd.exists() {
                return None;
            }
            let store = archive_store().ok()?;
            let manifest = store.list().into_iter().find(|m| {
                m.restored_ms.is_none() && cmux_worktree_care::store::inside_folder(&cwd, &m.path)
            })?;
            let id = manifest.id.clone();
            Some((
                id,
                cmux_worktree_care::restore::restore_within(
                    &store,
                    &manifest,
                    None,
                    RESTORE_SUBMODULES,
                ),
            ))
        })
        .await;
        let (kind, detail) = match restored {
            Ok(None) => return self.cold_recall_for(session).await,
            Ok(Some((id, Ok(restored)))) => (
                "worktree_restored",
                json!({"archive": id, "path": restored.path, "notes": restored.notes}),
            ),
            Ok(Some((id, Err(error)))) => {
                ("worktree_restore_failed", json!({"archive": id, "error": error}))
            }
            Err(error) => ("worktree_restore_failed", json!({"error": error.to_string()})),
        };
        self.append(session, "mux", kind, detail);
        true
    }

    /// Brings back the evicted folder (`cmux_worktree_care::cold`, "optimize storage") that holds
    /// the missing folder of `session`, from its verified cloud copy. Logged as `folder_recalled`
    /// or `folder_recall_failed`. Whether an evicted folder held it. A few stats when none does;
    /// nothing evicts unless a caller asks, so this is a no-op by default.
    async fn cold_recall_for(&self, session: &Arc<Session>) -> bool {
        let cwd = session.meta().cwd.clone();
        let Some(records) = cmux_worktree_care::cold::default_records() else { return false };
        let recalled = tokio::task::spawn_blocking(move || {
            cmux_worktree_care::cold::recall_for(&cwd, &records)
        })
        .await;
        let (kind, detail) = match recalled {
            Ok(Ok(None)) => return false,
            Ok(Ok(Some(record))) => (
                "folder_recalled",
                json!({"path": record.path, "bytes": record.bytes, "manifest": record.manifest_id}),
            ),
            Ok(Err(error)) => ("folder_recall_failed", json!({"error": error})),
            Err(error) => ("folder_recall_failed", json!({"error": error.to_string()})),
        };
        self.append(session, "mux", kind, detail);
        true
    }
}

#[cfg(test)]
#[path = "worktree_care_care_tests.rs"]
mod care_tests;
