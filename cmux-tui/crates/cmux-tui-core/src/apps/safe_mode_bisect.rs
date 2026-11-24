//! `cmux safe-mode bisect` (extensions DESIGN.md section 14 step 2; the ricing table's
//! "Safe mode and bisect"): while safe mode is on, find which extension breaks cmux by
//! running half of the suspects at a time, like `git bisect`.
//!
//! `start` takes every installed, enabled extension that safe mode holds off as the
//! suspects and lets the first half run (safe mode still holds the rest off). The person
//! uses cmux and says `good` (nothing broke: the culprit is in the half still off) or `bad`
//! (it broke: the culprit is in the half that ran). Each answer halves the suspects and
//! runs the next half, until one is left: that one is named, and nothing runs again until
//! the person rolls it back, removes it, or leaves safe mode. `reset` ends the bisect and
//! holds every extension off again. Leaving safe mode ends it too.
//!
//! The state survives a restart (`apps-bisect.json` next to `apps.json`), so a `bad` half
//! that crashed cmux is still the half under test when it comes back up.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::PoisonError;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::mirror::Origin;
use super::safe_mode::{OFF, flag_json, holds_off};
use super::supervisor::{ApiError, Inner, Out, Supervisor};

/// The bisect record next to `apps.json`.
const FILE: &str = "apps-bisect.json";

/// One bisect: the extensions that may still be the culprit, and the half running now.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Bisect {
    /// Sorted; the culprit is one of them.
    pub suspects: Vec<String>,
    /// The half of `suspects` running now; empty once one suspect is left.
    pub trial: Vec<String>,
    /// Answers given so far.
    pub steps: u32,
}

impl Bisect {
    /// Starts over `suspects`; `None` when there is none.
    pub fn start(mut suspects: Vec<String>) -> Option<Self> {
        suspects.sort();
        suspects.dedup();
        if suspects.is_empty() {
            return None;
        }
        let mut bisect = Self { suspects, trial: Vec::new(), steps: 0 };
        bisect.next_trial();
        Some(bisect)
    }

    /// The half that ran did not break cmux: the culprit is in the rest.
    pub fn good(&mut self) {
        if self.found().is_some() {
            return;
        }
        let trial = std::mem::take(&mut self.trial);
        self.suspects.retain(|app| !trial.contains(app));
        self.answered();
    }

    /// The half that ran broke cmux: the culprit is in it.
    pub fn bad(&mut self) {
        if self.found().is_some() {
            return;
        }
        self.suspects = std::mem::take(&mut self.trial);
        self.answered();
    }

    fn answered(&mut self) {
        self.steps = self.steps.saturating_add(1);
        self.next_trial();
    }

    /// The first half (rounded up) of the suspects runs; none once one is left.
    fn next_trial(&mut self) {
        self.trial = if self.suspects.len() > 1 {
            self.suspects.iter().take(self.suspects.len().div_ceil(2)).cloned().collect()
        } else {
            Vec::new()
        };
    }

    /// The one suspect left, once the bisect named it.
    pub fn found(&self) -> Option<&str> {
        match self.suspects.as_slice() {
            [only] if self.trial.is_empty() => Some(only.as_str()),
            _ => None,
        }
    }

    /// Whether `app` runs now, though safe mode is on.
    pub fn runs(&self, app: &str) -> bool {
        self.trial.iter().any(|a| a == app)
    }

    /// `{suspects, running, held, steps, found?}`.
    pub fn json(&self) -> Value {
        let held: Vec<&String> = self.suspects.iter().filter(|a| !self.runs(a)).collect();
        let mut out = json!({
            "suspects": self.suspects,
            "running": self.trial,
            "held": held,
            "steps": self.steps,
        });
        if let (Some(found), Some(map)) = (self.found(), out.as_object_mut()) {
            map.insert("found".into(), json!(found));
        }
        out
    }
}

pub(super) fn load(state_dir: Option<&Path>) -> Option<Bisect> {
    let raw = std::fs::read(state_dir?.join(FILE)).ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Writes `bisect` (temp file, rename); `None` removes the file.
pub(super) fn save(state_dir: Option<&Path>, bisect: Option<&Bisect>) -> std::io::Result<()> {
    let Some(dir) = state_dir else { return Ok(()) };
    let path = dir.join(FILE);
    let Some(bisect) = bisect else {
        return match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        };
    };
    std::fs::create_dir_all(dir)?;
    let temp = dir.join(format!("{FILE}.tmp"));
    std::fs::write(&temp, serde_json::to_vec(bisect).map_err(std::io::Error::other)?)?;
    std::fs::rename(&temp, path)
}

/// Whether safe mode holds `app` off now: it is on, and a bisect does not run `app`.
pub(super) fn held_off(inner: &Inner, app: &str) -> bool {
    inner.safe_mode.is_some() && !inner.bisect.as_ref().is_some_and(|bisect| bisect.runs(app))
}

/// The extensions a bisect starts over: installed, enabled, and held off by safe mode.
fn suspects_locked(inner: &Inner) -> Vec<String> {
    inner
        .mirror
        .apps
        .iter()
        .filter(|(_, record)| record.installed && record.enabled)
        .filter(|(app, _)| inner.catalog.packages.get(*app).is_some_and(holds_off))
        .map(|(app, _)| app.clone())
        .collect()
}

/// `{on, reason?, ..., bisect?}`: the safe mode answer with the bisect beside it.
pub(super) fn answer_locked(inner: &Inner) -> Value {
    let mut out = flag_json(inner.safe_mode.as_ref());
    if let (Some(bisect), Some(map)) = (&inner.bisect, out.as_object_mut()) {
        map.insert("bisect".into(), bisect.json());
    }
    out
}

/// Whether the `safe_mode.bisect` args name a step that runs extensions.
pub(crate) fn bisect_step_runs_extensions(args: &Value) -> bool {
    matches!(args.get("step").and_then(Value::as_str), Some("start" | "good" | "bad"))
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct BisectParams {
    /// `start`, `good`, `bad`, `reset` or `status`.
    step: String,
}

impl Supervisor {
    /// `safe_mode.bisect {step}`. `start`, `good` and `bad` run extensions in safe mode, so
    /// they take origin user or cli and never an agent's connection (server/apps.rs);
    /// `reset` and `status` take any origin.
    pub(super) fn bisect_call(
        &self,
        params: BisectParams,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        let step = params.step.as_str();
        if !matches!(step, "start" | "good" | "bad" | "reset" | "status") {
            return Err(ApiError::new(
                "bad-request",
                format!("step is start, good, bad, reset or status, not {step}"),
            ));
        }
        // The person's terminal or cmux itself; the wire refuses an agent's connection.
        if matches!(step, "start" | "good" | "bad") && !matches!(origin, Origin::User | Origin::Cli)
        {
            return Err(ApiError::new(
                "apps.safe_mode.origin",
                "only you can run extensions in safe mode: run the bisect yourself",
            ));
        }
        let (outs, answer) = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let before = inner.bisect.clone();
            let next = match step {
                "status" => before.clone(),
                "reset" => None,
                _ if inner.safe_mode.is_none() => {
                    return Err(ApiError::new(
                        "apps.safe_mode.off",
                        "safe mode is off: a bisect runs in safe mode (cmux safe-mode on)",
                    ));
                }
                "start" => Some(Bisect::start(suspects_locked(&inner)).ok_or_else(|| {
                    ApiError::new("apps.safe_mode.bisect", "no installed extension to bisect")
                })?),
                _ => {
                    let Some(mut bisect) = before.clone() else {
                        return Err(ApiError::new(
                            "apps.safe_mode.bisect",
                            "no bisect is running: start one with cmux safe-mode bisect start",
                        ));
                    };
                    if step == "good" {
                        bisect.good();
                    } else {
                        bisect.bad();
                    }
                    Some(bisect)
                }
            };
            let mut outs = Vec::new();
            if next != before {
                if let Err(error) = save(self.config.state_dir.as_deref(), next.as_ref()) {
                    return Err(ApiError::new("apps.persist", format!("apps-bisect: {error}")));
                }
                inner.bisect = next;
                outs = self.bisect_changed_locked(&mut inner, before.as_ref());
            }
            (outs, answer_locked(&inner))
        };
        let changed = !outs.is_empty();
        self.emit(outs);
        if changed {
            // An app the new half runs in the background starts now.
            self.activate_background(&BTreeSet::new());
        }
        Ok(answer)
    }

    /// The running half changed from `before`: the apps that left it stop, and clients
    /// mount again (the apps that joined it mount; the rest show their native view).
    fn bisect_changed_locked(&self, inner: &mut Inner, before: Option<&Bisect>) -> Vec<Out> {
        let mut outs = Vec::new();
        let left: Vec<String> = before
            .map(|b| b.trial.iter().filter(|app| held_off(inner, app)).cloned().collect())
            .unwrap_or_default();
        for app in left {
            outs.extend(self.stop_app_locked(inner, &app, OFF));
        }
        outs.push(Out::Broadcast(json!({
            "event": "apps-changed",
            "revision": inner.mirror.revision,
            "transaction": "safe-mode-bisect",
            "safe_mode": answer_locked(inner),
        })));
        outs
    }

    /// Leaving safe mode ends the bisect.
    pub(super) fn end_bisect_locked(&self, inner: &mut Inner) {
        if inner.bisect.take().is_some() {
            // Best effort: a record left behind loads only in a later safe mode.
            let _ = save(self.config.state_dir.as_deref(), None);
        }
    }
}

#[cfg(test)]
#[path = "safe_mode_bisect_tests.rs"]
mod tests;
