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

pub(in crate::hub) mod revive;

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

use cmux_worktree_care::inventory::now_ms;
use cmux_worktree_care::pass::{self, Options};
use cmux_worktree_care::policy::{self as care_policy, Pressure, Settings as CareSettings};
use cmux_worktree_care::schedule::{self, Claim, Refused};
use cmux_worktree_care::{Store as ArchiveStore, caches, disk};

/// The setting that turns automatic passes off.
pub const SETTING_AUTO_CLEANUP: &str = "worktrees.autoCleanup";

/// The setting that lets a pass also remove the machine's idle build caches
/// (`cmux_worktree_care::caches`). Off by default: they are always reported.
pub const SETTING_CLEAN_BUILD_CACHES: &str = "worktrees.cleanBuildCaches";

const MINUTE_MS: u64 = 60 * 1000;

/// How long a session's start waits on its submodules coming back.
const RESTORE_SUBMODULES: Duration = Duration::from_secs(120);

/// The least time between two automatic passes at each pressure.
fn spacing(pressure: Pressure) -> u64 {
    match pressure {
        Pressure::Normal => 6 * 60 * MINUTE_MS,
        Pressure::High => 60 * MINUTE_MS,
        Pressure::Critical => 10 * MINUTE_MS,
    }
}

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

/// Whether automatic passes are on: the setting, else on. An unreadable
/// settings file turns them off: a removal must not follow a guess.
pub fn auto_cleanup_enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Missing => true,
        crate::user_settings::Settings::Unreadable(_) => false,
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_AUTO_CLEANUP)
                .and_then(|value| value.as_bool())
                .unwrap_or(true)
        }
    }
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

/// Whether a pass may remove idle build caches: the setting, else off. An
/// unreadable settings file keeps them.
pub fn clean_build_caches_enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_CLEAN_BUILD_CACHES)
                .and_then(|value| value.as_bool())
                .unwrap_or(false)
        }
        _ => false,
    }
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
                    CARE.wake.notified().await;
                    let why = *CARE.why.lock().unwrap_or_else(|e| e.into_inner());
                    crate::supervise::panic_point("worktree care", why);
                    let Some(hub) = hub.upgrade() else { return };
                    hub.care_if_due(why).await;
                }
            }
        })
    }

    async fn care_if_due(&self, why: &'static str) {
        let Some(_running) = Running::claim(&CARE.running) else { return };
        let claim = tokio::task::spawn_blocking(move || {
            if !auto_cleanup_enabled() {
                return None;
            }
            let home = dirs::home_dir()?;
            let used = disk::usage(&home).map_or(0.0, |usage| usage.used_fraction());
            let pressure = CareSettings::default().pressure(used);
            let now = now_ms();
            let floor = CARE.last_started_ms.load(Ordering::Relaxed);
            if now.saturating_sub(floor) < spacing(pressure) {
                return None;
            }
            let store = match archive_store() {
                Ok(store) => store,
                Err(e) => {
                    tracing::warn!(why, "worktree cleanup skipped: {}", e.message);
                    return None;
                }
            };
            match schedule::claim(&store.dir, now, Some(spacing(pressure)), true) {
                Ok(claim) => Some(claim),
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
        let Some(claim) = claim else { return };
        CARE.last_started_ms.store(now_ms(), Ordering::Relaxed);
        match self.care_run(claim, true, Vec::new()).await {
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
        self.care_run(claim, apply, only).await
    }

    /// Runs one pass; the caller holds `running` and the machine's `claim`,
    /// which ends with the pass.
    async fn care_run(
        &self,
        claim: Claim,
        apply: bool,
        only: Vec<PathBuf>,
    ) -> Result<Value, RpcError> {
        let home = dirs::home_dir().ok_or_else(|| RpcError::internal("no home folder"))?;
        let live = self.care_sessions();
        let daemon_home = crate::config::home();
        let only_given = !only.is_empty();
        let report = tokio::task::spawn_blocking(move || {
            let mut sessions = live;
            sessions.extend(crate::worktree_sessions::on_disk(&home, Some(&daemon_home)));
            let configs = crate::worktree_sessions::state_configs(&home);
            let options = Options {
                roots: crate::worktree_sessions::default_roots(&home),
                sessions,
                uses: crate::worktree_sessions::uses(crate::worktree_sessions::claude_homes(
                    &home, &configs,
                )),
                open: Arc::new(cmux_worktree_care::procs::open_inside),
                // A recorded session on the Desktop: no git there unasked (LAUNCH-NO-TCC-PROMPTS).
                guarded: Arc::new(crate::protected_folders::in_protected_location),
                settings: CareSettings::default(),
                apply,
                pressure: None,
                only,
                measure: !apply,
            };
            let store = archive_store()?;
            let report = pass::run(&options, &store);
            // The machine's build caches, on a whole pass only (not a clean
            // of named worktrees): reported always, removed only with the
            // setting on.
            let caches_on = clean_build_caches_enabled();
            let caches = match (&report, only_given) {
                (Ok(report), false) => Some(caches::run(&caches::Options {
                    families: caches::default_families(&home),
                    pressure: report.pressure,
                    now_ms: now_ms(),
                    apply: apply && caches_on,
                    uses: options.uses.as_ref(),
                    open: options.open.as_ref(),
                    measure: !apply,
                })),
                _ => None,
            };
            if let Err(error) = claim.finish(now_ms()) {
                tracing::warn!("worktree cleanup could not record its pass: {error}");
            }
            let report = report.map_err(RpcError::internal)?;
            Ok::<_, RpcError>((report, caches, auto_cleanup_enabled(), caches_on))
        })
        .await
        .map_err(|e| RpcError::internal(format!("the cleanup pass stopped: {e}")))?;
        let (report, caches, auto, caches_on) = report?;
        let mut value = serde_json::to_value(&report).unwrap_or(Value::Null);
        if let Some(object) = value.as_object_mut() {
            if let Some(caches) = caches {
                object
                    .insert("caches".into(), serde_json::to_value(&caches).unwrap_or(Value::Null));
            }
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

    /// This daemon's sessions, as cleanup sees them.
    fn care_sessions(&self) -> Vec<care_policy::Session> {
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions
            .values()
            .map(|session| {
                let meta = session.meta();
                care_policy::Session {
                    name: meta.name.clone(),
                    cwd: meta.cwd.clone(),
                    open: meta.status != SessionStatus::Closed,
                    updated_ms: meta.updated_at,
                    ids: std::iter::once(&meta.id)
                        .chain(meta.agent_session_id.as_ref())
                        .chain(&meta.previous_agent_session_ids)
                        .cloned()
                        .collect(),
                }
            })
            .collect()
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
mod care_tests {
    use super::*;

    #[test]
    fn care_passes_come_sooner_as_the_disk_fills() {
        assert!(spacing(Pressure::Normal) > spacing(Pressure::High));
        assert!(spacing(Pressure::High) > spacing(Pressure::Critical));
        assert_eq!(spacing(Pressure::Critical), 10 * MINUTE_MS);
    }

    #[test]
    fn care_one_pass_at_a_time_and_the_flag_clears_on_unwind() {
        let flag = AtomicBool::new(false);
        let held = Running::claim(&flag).expect("free");
        assert!(Running::claim(&flag).is_none());
        drop(held);
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _held = Running::claim(&flag).expect("free again");
            panic!("a pass panics");
        }));
        assert!(caught.is_err());
        assert!(Running::claim(&flag).is_some(), "the panic cleared it");
    }

    /// hq#13316: the journal had only the pass's total for 14 removed
    /// checkouts. Each removal is its own line, from the report as
    /// `care_run` serializes it; what stays, is trimmed or failed to go
    /// has none.
    #[test]
    fn care_each_removed_worktree_is_one_log_line_with_its_reason_idle_age_and_archive() {
        use cmux_worktree_care::pass::{Item, Outcome, Report};
        use cmux_worktree_care::{Action, Verdict};
        let item = |path: &str, action, reason: &str, outcome| Item {
            path: path.into(),
            repository: "/m/cmux.git".into(),
            branch: None,
            verdict: Verdict { action, reason: reason.into(), idle_ms: Some(25 * 60 * MINUTE_MS) },
            facts: None,
            bytes: None,
            outcome,
        };
        let done = |archive: &str| {
            Some(Outcome {
                ok: true,
                freed: 1_359_519_744,
                archive: Some(archive.into()),
                error: None,
            })
        };
        let report = Report {
            disk: None,
            pressure: Pressure::High,
            applied: true,
            items: vec![
                item(
                    "/c/lane--a",
                    Action::Reclaim,
                    "everything pushed; idle 25 h",
                    done("1794973645972-lane--a"),
                ),
                item("/c/lane--b", Action::Keep, "owner session loop is open", None),
                item("/c/lane--c", Action::Trim, "idle 25 h", done("unused")),
                item(
                    "/c/lane--d",
                    Action::Archive,
                    "1 unpushed commits; idle 25 h",
                    Some(Outcome {
                        ok: false,
                        freed: 0,
                        archive: None,
                        error: Some("it changed since the scan".into()),
                    }),
                ),
            ],
            freed: 1_359_519_744,
            reclaimable: 0,
            errors: Vec::new(),
            expired: Vec::new(),
        };
        assert_eq!(
            removals(&serde_json::to_value(&report).unwrap()),
            vec![
                "worktree removed: /c/lane--a (reclaim: everything pushed; idle 25 h); idle 25 h; \
                 archive 1794973645972-lane--a; freed 1359519744 bytes"
                    .to_string()
            ]
        );
    }

    /// #54378: a care pass that panicked ended the daemon's one cleanup worker for good. The
    /// supervised worker starts again and takes a next wake (a second armed panic holds it there,
    /// so the test runs no real pass over this machine's worktrees).
    #[tokio::test]
    async fn a_care_pass_that_panics_starts_the_worker_again() {
        let root = std::env::temp_dir().join(format!("acpmux-care-{}", uuid::Uuid::now_v7()));
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
        crate::supervise::arm_panic("worktree care", "startup");
        crate::supervise::arm_panic("worktree care", "startup");
        let worker = hub.care_worker();
        // Each pass counts once per arming. The wake and its reason are process-wide, so a test
        // running beside this one may take the wake or change its reason: it is sent again until
        // the pass after the panic counts.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut again = false;
        while !again && std::time::Instant::now() < deadline {
            again = crate::supervise::passed(
                "worktree care",
                "startup",
                4,
                std::time::Duration::from_millis(200),
            )
            .await;
            if !again {
                *CARE.why.lock().unwrap_or_else(|e| e.into_inner()) = "startup";
                CARE.wake.notify_one();
            }
        }
        worker.abort();
        assert!(again, "the worker never ran again after its pass panicked");
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
}
