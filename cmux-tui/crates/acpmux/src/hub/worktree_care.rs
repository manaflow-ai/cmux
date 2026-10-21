//! Part of `Hub`; see `hub/mod.rs`. The machine cleans up after its agents
//! (`cmux-worktree-care`): a pass over this machine's git worktrees archives
//! and removes those nothing uses any more, and trims the build output of
//! idle ones it keeps.
//!
//! A pass runs when something may have freed a worktree (a turn ended, a
//! session closed, the daemon started) and the disk says one is due: at
//! most every 6 hours under 80% used, every hour from 80%, every 10 minutes
//! from 90%. Nothing runs on a timer. One pass at a time, off the runtime.
//! The `worktrees.autoCleanup` setting (default on) turns the automatic
//! passes off; `_acpmux/worktree/clean` (the machine view's Clean up now)
//! runs one regardless.
//!
//! A session that starts again in a reclaimed worktree gets it back first
//! (`care_restore_for`, from `cold_start`): its files, index and archived
//! work, before the harness starts in the folder.

use super::*;

use std::path::PathBuf;
use std::sync::atomic::AtomicU64;

use cmux_worktree_care::inventory::now_ms;
use cmux_worktree_care::pass::{self, Options};
use cmux_worktree_care::policy::{self as care_policy, Pressure, Settings as CareSettings};
use cmux_worktree_care::{Store as ArchiveStore, disk};

/// The setting that turns automatic passes off.
pub const SETTING_AUTO_CLEANUP: &str = "worktrees.autoCleanup";

const MINUTE_MS: u64 = 60 * 1000;

/// The least time between two automatic passes at each pressure.
fn spacing(pressure: Pressure) -> u64 {
    match pressure {
        Pressure::Normal => 6 * 60 * MINUTE_MS,
        Pressure::High => 60 * MINUTE_MS,
        Pressure::Critical => 10 * MINUTE_MS,
    }
}

/// The hub's cleanup state: one pass at a time, when the last one started,
/// and its report.
#[derive(Default)]
pub(crate) struct CareState {
    running: AtomicBool,
    last_started_ms: AtomicU64,
    last_report: StdMutex<Option<Value>>,
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
    /// Something that may have freed a worktree happened: runs a pass in the
    /// background when one is due (`spacing`) and none runs.
    pub(crate) fn care_nudge(self: &Arc<Self>, why: &'static str) {
        if !auto_cleanup_enabled() {
            return;
        }
        let Some(home) = dirs::home_dir() else { return };
        let used = disk::usage(&home).map_or(0.0, |usage| usage.used_fraction());
        let pressure = CareSettings::default().pressure(used);
        let now = now_ms();
        let last = self.care.last_started_ms.load(Ordering::Relaxed);
        if now.saturating_sub(last) < spacing(pressure)
            || self.care.running.swap(true, Ordering::SeqCst)
        {
            return;
        }
        self.care.last_started_ms.store(now, Ordering::Relaxed);
        let hub = self.clone();
        tokio::spawn(async move {
            match hub.care_run(true, Vec::new()).await {
                Ok(report) => tracing::info!(
                    why,
                    freed = report.get("freed").and_then(|v| v.as_u64()).unwrap_or(0),
                    "worktree cleanup pass"
                ),
                Err(e) => tracing::warn!(why, "worktree cleanup pass failed: {}", e.message),
            }
        });
    }

    /// `_acpmux/worktree/report` and `_acpmux/worktree/clean`: a pass now,
    /// acting with `apply`. A report-only pass measures what would be freed.
    pub(crate) async fn care_pass(
        self: &Arc<Self>,
        apply: bool,
        only: Vec<PathBuf>,
    ) -> Result<Value, RpcError> {
        if self.care.running.swap(true, Ordering::SeqCst) {
            return Err(RpcError::internal("a worktree cleanup pass is already running"));
        }
        if apply {
            self.care.last_started_ms.store(now_ms(), Ordering::Relaxed);
        }
        self.care_run(apply, only).await
    }

    /// Runs one pass; the caller set `running`, which this clears.
    async fn care_run(
        self: &Arc<Self>,
        apply: bool,
        only: Vec<PathBuf>,
    ) -> Result<Value, RpcError> {
        let result = self.care_run_inner(apply, only).await;
        self.care.running.store(false, Ordering::SeqCst);
        result
    }

    async fn care_run_inner(&self, apply: bool, only: Vec<PathBuf>) -> Result<Value, RpcError> {
        let home = dirs::home_dir().ok_or_else(|| RpcError::internal("no home folder"))?;
        let mut sessions = self.care_sessions();
        sessions.extend(crate::worktree_sessions::on_disk(&home, Some(&crate::config::home())));
        let options = Options {
            roots: crate::worktree_sessions::default_roots(&home),
            sessions,
            settings: CareSettings::default(),
            apply,
            pressure: None,
            only,
            measure: !apply,
        };
        let store = archive_store()?;
        let report = tokio::task::spawn_blocking(move || pass::run(&options, &store))
            .await
            .map_err(|e| RpcError::internal(format!("the cleanup pass stopped: {e}")))?
            .map_err(RpcError::internal)?;
        let mut value = serde_json::to_value(&report).unwrap_or(Value::Null);
        if let Some(object) = value.as_object_mut() {
            object.insert("autoCleanup".into(), json!(auto_cleanup_enabled()));
            object.insert("at".into(), json!(now_ms()));
        }
        *self.care.last_report.lock().unwrap_or_else(|e| e.into_inner()) = Some(value.clone());
        Ok(value)
    }

    /// The last pass's report, if one ran since the daemon started.
    pub(crate) fn care_last_report(&self) -> Option<Value> {
        self.care.last_report.lock().unwrap_or_else(|e| e.into_inner()).clone()
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
    pub(super) async fn care_restore_for(&self, session: &Arc<Session>) {
        let cwd = session.meta().cwd.clone();
        if cwd.exists() {
            return;
        }
        let Ok(store) = archive_store() else { return };
        let found = store
            .list()
            .into_iter()
            .find(|manifest| manifest.restored_ms.is_none() && cwd.starts_with(&manifest.path));
        let Some(manifest) = found else { return };
        let id = manifest.id.clone();
        let restored = tokio::task::spawn_blocking(move || {
            cmux_worktree_care::restore::restore(&store, &manifest, None)
        })
        .await;
        let (kind, detail) = match restored {
            Ok(Ok(restored)) => (
                "worktree_restored",
                json!({"archive": id, "path": restored.path, "notes": restored.notes}),
            ),
            Ok(Err(error)) => ("worktree_restore_failed", json!({"archive": id, "error": error})),
            Err(error) => {
                ("worktree_restore_failed", json!({"archive": id, "error": error.to_string()}))
            }
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
}
