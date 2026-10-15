//! Auto-update (cx-ny85): per harness, off by default. A check that finds an
//! opted-in harness outdated runs its own updater (the row's update plan, as a
//! program and its arguments, never through a shell), then the daemon checks
//! again. Turning it on runs one at once. A run that leaves the same version
//! and newest version is not repeated until one of them changes or auto-update
//! is turned on again. An update that needs sudo, or whose program raises rights, never
//! runs on its own: the person runs it from Settings > Agents. Sessions already
//! running keep their process; new ones start the new version.
//!
//! The choice is a list of harness ids in `<acpmux home>/harness-auto-update.json`,
//! set with `_acpmux/harness/health {autoUpdate: {id, on}}`.

use super::{HarnessHealth, HealthService, Settings, now_ms, probe};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::PoisonError;
use std::time::Duration;

/// How long one update may take (a large npm package on a slow link).
const UPDATE_LIMIT: Duration = Duration::from_secs(15 * 60);

/// Programs that raise rights; never run on their own.
const ELEVATING: &[&str] = &["sudo", "doas", "su", "pkexec"];

/// What one auto-update did.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AutoUpdateResult {
    /// When it ended (ms since the epoch).
    pub at: u64,
    pub ok: bool,
    /// The updater's last output line, or why it did not finish.
    pub detail: String,
    /// The installed and newest version it ran for.
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub latest: Option<String>,
}

impl AutoUpdateResult {
    fn ran_for(&self, row: &HarnessHealth) -> bool {
        self.version == row.version && self.latest == row.latest
    }
}

fn read(path: Option<&Path>) -> BTreeSet<String> {
    path.and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice::<BTreeSet<String>>(&b).ok())
        .unwrap_or_default()
}

/// The updater a row runs on its own, if any.
fn runnable(row: &HarnessHealth) -> Option<Vec<String>> {
    let plan = row.update.as_ref().filter(|p| !p.elevated)?;
    let program = plan.argv.first()?;
    let name = Path::new(program).file_name().and_then(|n| n.to_str()).unwrap_or(program);
    (row.auto_update && row.outdated && !ELEVATING.contains(&name)).then(|| plan.argv.clone())
}

impl HealthService {
    /// Turns auto-update on or off for harness `id`, saved for the next start.
    /// Turning it on forgets the last run, so the next one tries again.
    pub fn set_auto_update(&self, id: &str, on: bool) -> Result<Vec<HarnessHealth>, String> {
        // Held to the end: one change to the file at a time.
        let settings = self.settings.lock().unwrap_or_else(PoisonError::into_inner);
        let path = settings.auto_update.clone().ok_or("auto-update is not available here")?;
        let mut ids = read(Some(&path));
        if on {
            ids.insert(id.to_owned());
        } else {
            ids.remove(id);
        }
        let body = serde_json::to_vec_pretty(&ids).map_err(|e| e.to_string())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, body)
            .and_then(|()| std::fs::rename(&tmp, &path))
            .map_err(|e| format!("auto-update not saved: {e}"))?;
        if on {
            self.ran.lock().unwrap_or_else(PoisonError::into_inner).remove(id);
        }
        let mut rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        for row in rows.iter_mut().filter(|r| r.id == id) {
            row.auto_update = on;
            if on {
                row.last_auto_update = None;
            }
        }
        Ok(rows.clone())
    }

    /// Marks each row's auto-update choice and what auto-update last did for it.
    pub(super) fn mark_auto(&self, rows: &mut [HarnessHealth], settings: &Settings) {
        let ids = read(settings.auto_update.as_deref());
        let ran = self.ran.lock().unwrap_or_else(PoisonError::into_inner);
        for row in rows {
            row.auto_update = ids.contains(&row.id);
            row.last_auto_update = ran.get(&row.id).cloned();
        }
    }

    /// Runs the updater of every opted-in, outdated harness the last check found
    /// (one at a time, each command once, and not again for the same versions),
    /// and returns the ids it ran for. Callers wait for a run already going.
    pub async fn run_auto_updates(&self) -> Vec<String> {
        // A build session with agent launches off changes no installed CLI (cx-9ettq).
        if crate::launch_policy::agent_launch_disabled() {
            return Vec::new();
        }
        let _one = self.updating.lock().await;
        let mut done: BTreeMap<Vec<String>, AutoUpdateResult> = BTreeMap::new();
        let mut ran = Vec::new();
        for row in self.rows() {
            let path =
                self.settings.lock().unwrap_or_else(PoisonError::into_inner).auto_update.clone();
            let tried = self
                .ran
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&row.id)
                .is_some_and(|r| r.ran_for(&row));
            // Turned off since the rows were read, or already tried for these versions.
            if tried || !read(path.as_deref()).contains(&row.id) {
                continue;
            }
            let Some(argv) = runnable(&row) else { continue };
            let result = match done.get(&argv) {
                Some(result) => result.clone(),
                None => {
                    let run = argv.clone();
                    let outcome = tokio::task::spawn_blocking(move || {
                        probe::run(&run, &BTreeMap::new(), UPDATE_LIMIT)
                    })
                    .await
                    .unwrap_or_else(|e| Err(e.to_string()));
                    let (ok, detail) = match outcome {
                        Ok((ok, text)) => (
                            ok,
                            text.lines()
                                .rev()
                                .find(|l| !l.trim().is_empty())
                                .unwrap_or("")
                                .trim()
                                .to_owned(),
                        ),
                        Err(e) => (false, e),
                    };
                    tracing::info!(harness = %row.id, ok, "auto-update ran");
                    let result = AutoUpdateResult {
                        at: now_ms(),
                        ok,
                        detail,
                        version: row.version.clone(),
                        latest: row.latest.clone(),
                    };
                    done.insert(argv, result.clone());
                    result
                }
            };
            self.ran.lock().unwrap_or_else(PoisonError::into_inner).insert(row.id.clone(), result);
            ran.push(row.id);
        }
        ran
    }
}
