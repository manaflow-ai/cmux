//! Safe mode (docs/cmux-next/extensions/safe-mode.md): one switch that turns
//! every extension off, so no extension can brick the app.
//!
//! While it is on, the supervisor starts no app host at all: no VM, no
//! stream, no mount. `apps-mount` of a scripted app answers
//! `apps.safe_mode`, so every place shows its native view (R5), and the
//! local reload does nothing. Every listing says `run_state: "off: safe
//! mode"` for the apps it holds off.
//!
//! What it covers: every app with a script (`runtime.main`), which is every
//! third-party app, every local and customize app and every bundled
//! first-party app that runs in the app host (agents, caffeinate, codemirror,
//! coderouter, diffs, finder, inbox, integrations, memory, notes, search,
//! skills, usage). None of them is something cmux cannot work without: each
//! place falls back to its native view. What it leaves on: apps with no
//! script (the App Store, Home, Cloud and Remote Desktop panes, drawn by the
//! app itself) and first-party native servers (Cloud, Remote Desktop), which
//! ship and are signed with cmux, never run extension code, and are how the
//! person reaches the App Store to remove what broke.
//!
//! Three ways in: `safe_mode.set {on: true}` (any origin; entering is always
//! allowed), `CMUX_SAFE_MODE=1` at daemon start, or the crash loop rule
//! below. One way out: `safe_mode.set {on: false}` with origin user (the
//! person, through the verified app). `cmux safe-mode off` with no daemon
//! running removes the flag file.
//!
//! Crash loop rule: the app calls `safe_mode.launch_began` when it starts
//! and `safe_mode.launch_settled` once it drew its first frame and stayed up
//! for 10 seconds, or when it quits cleanly. A launch that began and never
//! settled failed. When [`TRIP_FAILURES`] launches failed within
//! [`WINDOW_MS`] of a new launch, that new launch comes up in safe mode with
//! reason `crash-loop`, naming the apps that were mounted in the failed
//! launches. A settled launch clears the count.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::PoisonError;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::catalog::Package;
use super::mirror::Origin;
use super::supervisor::{ApiError, HostKey, Inner, Out, Supervisor};
use crate::safe_mode_flag::{self, Flag, Reason};

/// Failed launches within the window that trip safe mode.
pub(super) const TRIP_FAILURES: usize = 3;
/// The window, before the launch that would be the next failure.
pub(super) const WINDOW_MS: u64 = 5 * 60 * 1000;
/// Failed launches kept (more never change the rule's answer).
const KEPT_FAILURES: usize = 8;
/// What a held-off app's listing and its refused mount say.
pub(super) const OFF: &str = "off: safe mode";
/// The launch record next to `apps.json`.
const LAUNCHES_FILE: &str = "apps-launches.json";

/// One app launch: when it began and which apps mounted in it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Launch {
    pub began_ms: u64,
    #[serde(default)]
    pub apps: BTreeSet<String>,
}

/// The crash loop state machine. `open` is the launch running now; a launch
/// that is still open when the next one begins never settled.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Launches {
    #[serde(default)]
    pub open: Option<Launch>,
    #[serde(default)]
    pub failed: Vec<Launch>,
}

impl Launches {
    /// A launch begins at `now_ms`. Returns the apps to name when this launch
    /// must come up in safe mode (the rule tripped), else `None`.
    ///
    /// Clock skew: a failure stamped after `now_ms` (the clock went back) or
    /// older than the window (the clock went forward, or time passed) is
    /// dropped, so a skewed clock can only miss a loop, never invent one.
    pub fn began(&mut self, now_ms: u64) -> Option<Vec<String>> {
        if let Some(previous) = self.open.take() {
            self.failed.push(previous);
        }
        self.failed
            .retain(|launch| launch.began_ms <= now_ms && now_ms - launch.began_ms <= WINDOW_MS);
        let excess = self.failed.len().saturating_sub(KEPT_FAILURES);
        self.failed = self.failed.split_off(excess);
        self.open = Some(Launch { began_ms: now_ms, apps: BTreeSet::new() });
        if self.failed.len() < TRIP_FAILURES {
            return None;
        }
        let apps: BTreeSet<String> =
            self.failed.iter().flat_map(|launch| launch.apps.iter().cloned()).collect();
        // Tripping uses the failures up: a new loop needs new failures.
        self.failed.clear();
        Some(apps.into_iter().collect())
    }

    /// The open launch settled (first frame and up for a while, or a clean
    /// quit): it did not fail, and the failures before it no longer count.
    pub fn settled(&mut self) {
        self.open = None;
        self.failed.clear();
    }

    /// `app` mounted in the open launch; true when that is new.
    pub fn mounted(&mut self, app: &str) -> bool {
        self.open.as_mut().is_some_and(|launch| launch.apps.insert(app.to_string()))
    }
}

pub(super) fn load_launches(state_dir: Option<&Path>) -> Launches {
    state_dir
        .and_then(|dir| std::fs::read(dir.join(LAUNCHES_FILE)).ok())
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .unwrap_or_default()
}

fn save_launches(state_dir: Option<&Path>, launches: &Launches) {
    let Some(dir) = state_dir else { return };
    let Ok(body) = serde_json::to_vec(launches) else { return };
    let temp = dir.join(format!("{LAUNCHES_FILE}.tmp"));
    // Best effort: a lost write costs one launch of the count, never a start.
    if std::fs::create_dir_all(dir).is_ok() && std::fs::write(&temp, body).is_ok() {
        let _ = std::fs::rename(&temp, dir.join(LAUNCHES_FILE));
    }
}

/// The safe mode a supervisor starts with: the flag file when it says on,
/// else `CMUX_SAFE_MODE` (reason `env`, for this run only), else off.
pub(super) fn initial(file: Option<&Path>, env: bool) -> Option<Flag> {
    file.and_then(safe_mode_flag::read).or_else(|| {
        env.then(|| Flag {
            on: true,
            reason: Reason::Env,
            since_ms: safe_mode_flag::now_ms(),
            extensions: Vec::new(),
        })
    })
}

/// Whether safe mode holds `package` off: it runs in the app host.
pub(super) fn holds_off(package: &Package) -> bool {
    package.has_runtime()
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct SetParams {
    on: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct SettledParams {
    /// `frame` (first frame and up for a while) or `quit` (a clean quit).
    #[serde(default)]
    reason: Option<String>,
}

impl Supervisor {
    /// Whether safe mode is on.
    pub(crate) fn safe_mode_on(&self) -> bool {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).safe_mode.is_some()
    }

    /// App host processes this supervisor spawned (live hosts and load
    /// trials): zero for a run that stayed in safe mode.
    #[cfg(test)]
    pub(crate) fn host_spawns(&self) -> u64 {
        self.host_spawns.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// `apps-safe-mode {op, args}`: `safe_mode.get`, `safe_mode.set`,
    /// `safe_mode.launch_began`, `safe_mode.launch_settled`. The wire
    /// admits the launch ops only from the verified app connection.
    pub(crate) fn safe_mode_call(
        &self,
        op: &str,
        args: Value,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        match op.strip_prefix("cmux.").unwrap_or(op) {
            "safe_mode.get" => {
                super::store::params::<serde_json::Map<String, Value>>(args)?;
                Ok(self.safe_mode_json())
            }
            "safe_mode.set" => {
                let params: SetParams = super::store::params(args)?;
                self.set_safe_mode(params.on, origin)
            }
            "safe_mode.launch_began" => {
                super::store::params::<serde_json::Map<String, Value>>(args)?;
                Ok(self.launch_began(safe_mode_flag::now_ms()))
            }
            "safe_mode.launch_settled" => {
                let params: SettledParams = super::store::params(args)?;
                match params.reason.as_deref() {
                    None | Some("frame" | "quit") => Ok(self.launch_settled()),
                    Some(other) => Err(ApiError::new(
                        "bad-request",
                        format!("reason is frame or quit, not {other}"),
                    )),
                }
            }
            _ => Err(ApiError::new("apps.op.unknown", format!("{op} is not a safe mode op"))),
        }
    }

    /// `{on, reason?, sinceMs?, extensions?}`.
    pub(crate) fn safe_mode_json(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        flag_json(inner.safe_mode.as_ref())
    }

    /// Turns safe mode on (any origin) or off (origin user only).
    pub(crate) fn set_safe_mode(&self, on: bool, origin: Origin) -> Result<Value, ApiError> {
        if !on && origin != Origin::User {
            return Err(ApiError::new(
                "apps.safe_mode.origin",
                "only you can leave safe mode: choose Leave Safe Mode in cmux",
            ));
        }
        let flag = on.then(|| Flag {
            on: true,
            reason: Reason::User,
            since_ms: safe_mode_flag::now_ms(),
            extensions: Vec::new(),
        });
        self.apply_safe_mode(flag)
    }

    /// Makes `flag` the safe mode: written to the flag file first (a failed
    /// write refuses), then held. Entering stops every app host; leaving
    /// clears the launch count and tells clients to mount again.
    fn apply_safe_mode(&self, flag: Option<Flag>) -> Result<Value, ApiError> {
        let (outs, answer, leaving) = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let was_on = inner.safe_mode.is_some();
            // Entering again keeps the first reason and time.
            let flag = match (flag, inner.safe_mode.clone()) {
                (Some(_), Some(current)) => Some(current),
                (next, _) => next,
            };
            // `CMUX_SAFE_MODE` holds for its run only: never written.
            let durable = flag.as_ref().filter(|flag| flag.reason != Reason::Env);
            if let Some(path) = &self.config.safe_mode_file
                && let Err(error) = safe_mode_flag::write(path, durable)
            {
                return Err(ApiError::new("apps.persist", format!("{}: {error}", path.display())));
            }
            inner.safe_mode = flag;
            let now_on = inner.safe_mode.is_some();
            let mut outs = Vec::new();
            if now_on && !was_on {
                outs.extend(self.stop_all_hosts_locked(&mut inner));
            }
            if !now_on {
                inner.launches = Launches::default();
                save_launches(self.config.state_dir.as_deref(), &inner.launches);
            }
            if now_on != was_on {
                outs.push(Out::Broadcast(json!({
                    "event": "apps-changed",
                    "revision": inner.mirror.revision,
                    "transaction": "safe-mode",
                    "safe_mode": flag_json(inner.safe_mode.as_ref()),
                })));
            }
            (outs, flag_json(inner.safe_mode.as_ref()), was_on && !now_on)
        };
        self.emit(outs);
        if leaving {
            // Saves made in safe mode were held; apply them now.
            let prints =
                self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_prints.clone();
            self.reload_local_apps(&prints);
        }
        Ok(answer)
    }

    /// Every app host stops; their mounts fail with "off: safe mode".
    fn stop_all_hosts_locked(&self, inner: &mut Inner) -> Vec<Out> {
        let mut apps: BTreeSet<String> = inner.hosts.keys().map(|key| key.app.clone()).collect();
        apps.extend(inner.mounts.values().map(|mount| mount.host.app.clone()));
        let mut outs = Vec::new();
        for app in apps {
            outs.extend(self.stop_app_locked(inner, &app, OFF));
            // A preview host (the store's) stops too.
            let preview = HostKey { app: app.clone(), preview: true };
            let doomed: Vec<_> = inner
                .mounts
                .iter()
                .filter(|(_, mount)| mount.host == preview)
                .map(|(key, _)| key.clone())
                .collect();
            for key in doomed {
                inner.mounts.remove(&key);
                outs.push(Out::Client(
                    key.client,
                    json!({ "event": "apps-mount-failed", "mount_id": key.mount_id, "reason": OFF }),
                ));
            }
            if inner.hosts.contains_key(&preview) {
                outs.extend(self.end_host_locked(inner, &preview, OFF, "off"));
            }
        }
        outs
    }

    /// `safe_mode.launch_began`: records the launch and, when the crash loop
    /// rule trips, enters safe mode with reason `crash-loop` before anything
    /// mounts. Answers the safe mode the launch comes up in.
    pub(crate) fn launch_began(&self, now_ms: u64) -> Value {
        let tripped = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let tripped = inner.launches.began(now_ms);
            save_launches(self.config.state_dir.as_deref(), &inner.launches);
            tripped
        };
        if let Some(extensions) = tripped {
            let flag = Flag { on: true, reason: Reason::CrashLoop, since_ms: now_ms, extensions };
            if let Err(error) = self.apply_safe_mode(Some(flag.clone())) {
                // Still safe for this run, even when the file cannot be written.
                eprintln!("cmux-tui: safe mode after a crash loop: {}", error.message);
                let outs = {
                    let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
                    inner.safe_mode.get_or_insert(flag);
                    self.stop_all_hosts_locked(&mut inner)
                };
                self.emit(outs);
            }
        }
        self.safe_mode_json()
    }

    /// `safe_mode.launch_settled`.
    pub(crate) fn launch_settled(&self) -> Value {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner.launches.settled();
        save_launches(self.config.state_dir.as_deref(), &inner.launches);
        flag_json(inner.safe_mode.as_ref())
    }

    /// Notes that `app` mounted in the open launch (the crash loop names it).
    pub(super) fn note_launch_mount_locked(&self, inner: &mut Inner, app: &str) {
        if inner.launches.mounted(app) {
            save_launches(self.config.state_dir.as_deref(), &inner.launches);
        }
    }
}

pub(super) fn flag_json(flag: Option<&Flag>) -> Value {
    match flag {
        None => json!({ "on": false }),
        Some(flag) => json!({
            "on": true,
            "reason": flag.reason.as_str(),
            "sinceMs": flag.since_ms,
            "extensions": flag.extensions,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: u64 = 60 * 1000;

    fn fail(launches: &mut Launches, at: u64, app: &str) -> Option<Vec<String>> {
        let tripped = launches.began(at);
        launches.mounted(app);
        tripped
    }

    #[test]
    fn three_failed_launches_in_five_minutes_trip_the_next_one() {
        let mut launches = Launches::default();
        assert_eq!(fail(&mut launches, 10 * MIN, "acme/a"), None);
        assert_eq!(fail(&mut launches, 11 * MIN, "acme/b"), None);
        assert_eq!(fail(&mut launches, 12 * MIN, "acme/a"), None);
        // The fourth launch sees three that never settled.
        assert_eq!(launches.began(13 * MIN), Some(vec!["acme/a".into(), "acme/b".into()]));
        // Tripping used them up.
        assert!(launches.failed.is_empty());
        assert_eq!(launches.began(14 * MIN), None);
    }

    #[test]
    fn a_settled_launch_resets_the_count() {
        let mut launches = Launches::default();
        fail(&mut launches, MIN, "acme/a");
        fail(&mut launches, 2 * MIN, "acme/a");
        launches.began(3 * MIN);
        launches.settled();
        assert_eq!(launches.began(4 * MIN), None);
        assert_eq!(launches.began(5 * MIN), None);
        assert_eq!(launches.began(6 * MIN), None, "only two failed since the settle");
        assert!(launches.began(7 * MIN).is_some());
    }

    #[test]
    fn a_clean_quit_does_not_count() {
        let mut launches = Launches::default();
        for minute in 1..=5 {
            assert_eq!(launches.began(minute * MIN), None);
            // `launch_settled {reason: quit}` settles like a first frame.
            launches.settled();
        }
        assert!(launches.failed.is_empty());
    }

    #[test]
    fn failures_older_than_the_window_do_not_count() {
        let mut launches = Launches::default();
        fail(&mut launches, MIN, "acme/a");
        fail(&mut launches, 2 * MIN, "acme/a");
        fail(&mut launches, 3 * MIN, "acme/a");
        // Six minutes after the first failure only two are in the window.
        assert_eq!(launches.began(6 * MIN + 1), None);
    }

    #[test]
    fn clock_skew_never_invents_a_loop() {
        let mut launches = Launches::default();
        fail(&mut launches, 100 * MIN, "acme/a");
        fail(&mut launches, 101 * MIN, "acme/a");
        fail(&mut launches, 102 * MIN, "acme/a");
        // The clock went back an hour: stamps after now are dropped.
        assert_eq!(launches.began(40 * MIN), None);
        assert!(launches.failed.is_empty());
        // The clock went forward a day: everything is outside the window.
        let mut launches = Launches::default();
        fail(&mut launches, MIN, "acme/a");
        fail(&mut launches, 2 * MIN, "acme/a");
        fail(&mut launches, 3 * MIN, "acme/a");
        assert_eq!(launches.began(24 * 60 * MIN), None);
    }

    #[test]
    fn the_record_stays_bounded() {
        let mut launches = Launches::default();
        // Each launch trips on the fourth; between trips the list never grows past the cap.
        for second in 0..100 {
            launches.began(second * 1000);
            assert!(launches.failed.len() <= KEPT_FAILURES);
        }
    }

    #[test]
    fn the_flag_file_wins_over_the_env_and_off_is_off() {
        let dir =
            std::env::temp_dir().join(format!("cmux-safe-mode-initial-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = safe_mode_flag::path_in(&dir);
        let _ = std::fs::remove_file(&path);
        assert_eq!(initial(Some(&path), false), None);
        assert_eq!(initial(Some(&path), true).map(|f| f.reason), Some(Reason::Env));
        let user = Flag { on: true, reason: Reason::User, since_ms: 5, extensions: vec![] };
        safe_mode_flag::write(&path, Some(&user)).unwrap();
        assert_eq!(initial(Some(&path), true), Some(user));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
