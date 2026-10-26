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
//! The `worktrees.autoCleanup` setting (default on) turns the automatic
//! passes off; `_acpmux/worktree/clean` (the machine view's Clean up now)
//! runs one regardless. Either way a worktree goes only after its quiet
//! time, archived first, with no session in it and nothing holding it open
//! (`procs::open_inside`, right before the removal).
//!
//! A session that starts again in a reclaimed worktree gets it back first
//! (`care_restore_for`, from `cold_start`): its files, index and archived
//! work, before the harness starts in the folder.

use super::*;

pub(super) mod revive;

use std::path::PathBuf;
use std::sync::LazyLock;
use std::sync::atomic::AtomicU64;
use std::time::Duration;

use cmux_worktree_care::inventory::now_ms;
use cmux_worktree_care::pass::{self, Options};
use cmux_worktree_care::policy::{self as care_policy, Pressure, Settings as CareSettings};
use cmux_worktree_care::schedule::{self, Claim, Refused};
use cmux_worktree_care::{Store as ArchiveStore, disk};

/// The setting that turns automatic passes off.
pub const SETTING_AUTO_CLEANUP: &str = "worktrees.autoCleanup";

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
    pub(crate) fn care_worker(self: &Arc<Self>) {
        let hub = Arc::downgrade(self);
        *CARE.why.lock().unwrap_or_else(|e| e.into_inner()) = "startup";
        CARE.wake.notify_one();
        tokio::spawn(async move {
            loop {
                CARE.wake.notified().await;
                let Some(hub) = hub.upgrade() else { return };
                let why = *CARE.why.lock().unwrap_or_else(|e| e.into_inner());
                hub.care_if_due(why).await;
            }
        });
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
            Ok(report) => tracing::info!(
                why,
                freed = report.get("freed").and_then(|v| v.as_u64()).unwrap_or(0),
                "worktree cleanup pass"
            ),
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
                settings: CareSettings::default(),
                apply,
                pressure: None,
                only,
                measure: !apply,
            };
            let store = archive_store()?;
            let report = pass::run(&options, &store);
            if let Err(error) = claim.finish(now_ms()) {
                tracing::warn!("worktree cleanup could not record its pass: {error}");
            }
            let report = report.map_err(RpcError::internal)?;
            Ok::<_, RpcError>((report, auto_cleanup_enabled()))
        })
        .await
        .map_err(|e| RpcError::internal(format!("the cleanup pass stopped: {e}")))?;
        let (report, auto) = report?;
        let mut value = serde_json::to_value(&report).unwrap_or(Value::Null);
        if let Some(object) = value.as_object_mut() {
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
                }
            })
            .collect()
    }

    /// Before a session's harness starts: its folder back, when cleanup
    /// reclaimed the worktree it is in. Logged as `worktree_restored`, or
    /// `worktree_restore_failed` (the start goes on and reports the
    /// missing folder as before).
    pub(super) async fn ready_to_start(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        self.care_restore_for(session).await;
        self.revive_folder(session, &CARE.restoring).await?;
        // A stopped session reopens on demand. Only a purge is final.
        if session.status() == SessionStatus::Closed {
            self.append(session, "mux", "reopened", json!({}));
            self.set_status(session, SessionStatus::Idle);
        }
        Ok(())
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

    /// Before a prompt for a session with no running agent is taken: its folder, restored when
    /// cleanup reclaimed it, or a refusal naming the folder when it is still gone (a worktree
    /// removed by hand). The refusal is retryable, so an outbox delivery (`server/outbox.rs`)
    /// keeps the message and sends it again once the folder is back; a harness started in a
    /// missing folder failed the turn after it was taken, as `spawn harness process: No such
    /// file or directory`.
    async fn folder_ready(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        self.care_restore_for(session).await;
        self.revive_folder(session, &CARE.restoring).await?;
        let meta = session.meta();
        // A folder that cannot be read (its permissions) fails at the start as before.
        match tokio::fs::metadata(&meta.cwd).await {
            Ok(m) if m.is_dir() => return Ok(()),
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Ok(()),
            _ => {}
        }
        Err(RpcError::internal(format!(
            "session.folder_missing: the folder of {} ({}) no longer exists; it was moved or \
             removed (or a file took its place), so its agent cannot start until it is back",
            meta.name,
            meta.cwd.display()
        ))
        .with_data(json!({
            "reason": "session.folder_missing",
            "folder": meta.cwd,
            "retryable": true,
        })))
    }

    async fn care_restore_for(&self, session: &Arc<Session>) {
        let cwd = session.meta().cwd.clone();
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            return;
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
            Ok(None) => return,
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
}
