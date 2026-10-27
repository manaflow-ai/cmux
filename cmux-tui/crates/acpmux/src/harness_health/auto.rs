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
//!
//! Update Everything (cx-1mbnu, `_acpmux/harness/update`) runs the same
//! updaters on request (`run_updates`), whatever the choice, under the same
//! no-sudo rule.

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

/// The updater cmux may run for an outdated row, if any: a plan that needs
/// no elevated rights and whose program does not raise them.
pub fn updatable(row: &HarnessHealth) -> Option<Vec<String>> {
    let plan = row.update.as_ref().filter(|p| !p.elevated)?;
    if row.channel == super::channel::Channel::Npm
        && !super::channel::npm_update_matches(plan, row.package.as_deref())
    {
        return None;
    }
    if row.channel == super::channel::Channel::Bun
        && !super::channel::bun::matches(plan, row.package.as_deref(), row.path.as_deref())
    {
        return None;
    }
    let program = plan.argv.first()?;
    let name = Path::new(program).file_name().and_then(|n| n.to_str()).unwrap_or(program);
    (row.outdated && !ELEVATING.contains(&name)).then(|| plan.argv.clone())
}

/// The updater a row runs on its own, if any.
fn runnable(row: &HarnessHealth) -> Option<Vec<String>> {
    row.auto_update.then(|| updatable(row)).flatten()
}

/// Runs one updater: whether it succeeded, and its last output line (or why
/// it did not finish).
async fn run_updater(argv: &[String], channel: super::channel::Channel) -> (bool, String) {
    let run = argv.to_vec();
    let outcome = tokio::task::spawn_blocking(move || {
        let run = if channel == super::channel::Channel::Bun {
            super::channel::bun::pin_manager(&run, crate::config::which)
                .ok_or_else(|| "harness_update_plan.unavailable".to_owned())?
        } else {
            run
        };
        probe::run(&run, &BTreeMap::new(), UPDATE_LIMIT)
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()));
    match outcome {
        Ok((ok, text)) => {
            (ok, text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_owned())
        }
        Err(e) => (false, e),
    }
}

/// What a requested update did for one harness (`run_updates`).
#[derive(Clone, Debug, PartialEq)]
pub enum Requested {
    /// The updater ran: whether it succeeded, and its last output line.
    Ran { ok: bool, detail: String },
    /// Nothing to run: the installed version is the newest known.
    Current,
    /// Not run, and why (an update that needs sudo, none known, no such harness).
    Refused(String),
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
        // Owner-only whatever the umask, through a new temporary file each time.
        crate::config::write_atomic(&path, &body)
            .map_err(|e| format!("auto-update not saved: {e:#}"))?;
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
                    let (ok, detail) = run_updater(&argv, row.channel).await;
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

    /// Runs now, for the person (Update Everything, cx-1mbnu), the updater of
    /// each row named in `ids` (every outdated row when None), whatever its
    /// auto-update choice and earlier runs, under the same rule: never one
    /// that needs sudo or whose program raises rights. One at a time, shared
    /// with auto-update, and each command once. `check` runs once the
    /// updates are this caller's (after any auto-update ends), so a version
    /// an auto-update just installed is not installed again; its rows are
    /// returned with the outcomes.
    pub async fn run_updates(
        &self,
        check: impl std::future::Future<Output = Vec<HarnessHealth>>,
        ids: Option<&BTreeSet<String>>,
    ) -> (Vec<HarnessHealth>, Vec<(String, Requested)>) {
        let _one = self.updating.lock().await;
        let rows = check.await;
        let rows = &rows[..];
        let asked: Vec<String> = match ids {
            Some(ids) => ids.iter().cloned().collect(),
            None => rows.iter().filter(|r| r.outdated).map(|r| r.id.clone()).collect(),
        };
        let mut done: BTreeMap<Vec<String>, (bool, String)> = BTreeMap::new();
        let mut out = Vec::new();
        for id in asked {
            let Some(row) = rows.iter().find(|r| r.id == id) else {
                out.push((id, Requested::Refused("no such harness on this machine".into())));
                continue;
            };
            if !row.outdated {
                let unknown = || row.problem.clone().unwrap_or("its version is unknown".into());
                let known_current = row.latest.as_deref().zip(row.version.as_deref()).is_some_and(
                    |(latest, installed)| {
                        matches!(
                            probe::compare_versions(latest, installed),
                            Some(std::cmp::Ordering::Less | std::cmp::Ordering::Equal)
                        )
                    },
                );
                let answer =
                    if known_current { Requested::Current } else { Requested::Refused(unknown()) };
                out.push((id, answer));
                continue;
            }
            let Some(argv) = updatable(row) else {
                let why = match &row.update {
                    Some(plan) => {
                        format!("its update needs elevated rights: run `{}`", plan.command)
                    }
                    None => "cmux cannot update it: update it the way it was installed".to_owned(),
                };
                out.push((id, Requested::Refused(why)));
                continue;
            };
            let (ok, detail) = match done.get(&argv) {
                Some(result) => result.clone(),
                None => {
                    let result = run_updater(&argv, row.channel).await;
                    tracing::info!(harness = %id, ok = result.0, "requested update ran");
                    done.insert(argv, result.clone());
                    result
                }
            };
            out.push((id, Requested::Ran { ok, detail }));
        }
        (rows.to_vec(), out)
    }
}

#[cfg(all(test, unix))]
mod owner_only_tests {
    use super::*;

    /// `harness-auto-update.json` is owner-only whatever the umask, like the rest of the acpmux
    /// home (ergo-walk2, 2026-10-25), and a temporary file a crashed run left changes nothing.
    #[test]
    fn the_auto_update_list_is_saved_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("acpmux-auto-mode-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("harness-auto-update.json");
        let stale = path.with_extension("json.tmp");
        std::fs::write(&stale, "[]").unwrap();
        std::fs::set_permissions(&stale, std::fs::Permissions::from_mode(0o666)).unwrap();
        let service = HealthService::new();
        service.attach(super::super::Settings {
            auto_update: Some(path.clone()),
            home: dir.clone(),
            ..Default::default()
        });
        service.set_auto_update("codex", true).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(std::fs::read_to_string(&path).unwrap().contains("codex"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
