//! Part of `Hub`; see `hub/mod.rs`. Harness magic `speculative` (RFD 0158 §4), the daemon's
//! half: which check a session runs, and running it again ahead of the session after its
//! edits. The rest (what counts as a check, the kept runs, serving them) is
//! `crate::spec_exec`.
//!
//! A session's foreground Bash call that [`crate::spec_exec::is_check`] takes is remembered
//! when it completes, as the session's next check. Each completed edit tool call (the same
//! updates `verify.rs` reads) restarts a [`DEBOUNCE`] timer; when it runs out with no tool of
//! the session open, the remembered check runs in the session's folder in a blocking task
//! (`spec_exec::prerun`, bounded by [`BOUND`]), one at a time per folder. Counters per turn,
//! on `turn_result`: `harnessMagic.speculative.preRuns`, `kept`, `msTotal`.

use super::*;
use crate::spec_exec;
use crate::touched_files as tf;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::Duration;

/// Quiet time after the last edit before the check runs (the same as `verify.rs`).
const DEBOUNCE: Duration = Duration::from_secs(2);
/// How long one speculative run may take.
const BOUND: Duration = Duration::from_secs(10 * 60);
/// The longest a run waits for the session's open tools to end.
const MAX_WAIT: Duration = Duration::from_secs(10 * 60);

#[derive(Default)]
struct State {
    /// Bash calls started and not yet ended, by `toolCallId`, with their command lines.
    bash: HashMap<String, String>,
    /// The session's last check.
    check: Option<String>,
    generation: u64,
    pre_runs: u64,
    kept: u64,
    ms_total: u64,
}

static STATES: LazyLock<StdMutex<HashMap<String, Arc<StdMutex<State>>>>> =
    LazyLock::new(Default::default);
static FOLDERS: LazyLock<StdMutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>> =
    LazyLock::new(Default::default);

fn state(id: &str) -> Arc<StdMutex<State>> {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() > 1000 {
        map.clear();
    }
    map.entry(id.to_owned()).or_default().clone()
}

/// The command line of a Bash tool call update, when it carries one as a string.
pub(super) fn bash_command(update: &Value) -> Option<String> {
    let raw = update.get("rawInput")?;
    if raw.get("run_in_background").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    raw.get("command").and_then(Value::as_str).map(str::to_owned)
}

/// The turn's counters onto its `turn_result`: what ran since the last one.
pub(super) fn stamp(session_id: &str, msg: &mut serde_json::Map<String, Value>) {
    let Some(s) = STATES.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned() else {
        return;
    };
    let mut s = s.lock().unwrap_or_else(|e| e.into_inner());
    if s.pre_runs == 0 {
        return;
    }
    for (k, v) in [("preRuns", s.pre_runs), ("kept", s.kept), ("msTotal", s.ms_total)] {
        msg.insert(format!("harnessMagic.{}.{k}", spec_exec::FEATURE), json!(v));
    }
    (s.pre_runs, s.kept, s.ms_total) = (0, 0, 0);
}

impl Hub {
    /// One tool call update of a session (`tap.rs`, beside `note_verify`).
    pub(super) fn note_speculative(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        if !matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) || tokio::runtime::Handle::try_current().is_err()
        {
            return;
        }
        let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default();
        let status = update.get("status").and_then(Value::as_str);
        let command = bash_command(update).filter(|c| spec_exec::is_check(c));
        let (paths, edited) = tf::paths_of(update);
        let edit_done = edited == Some(true) && !paths.is_empty() && status == Some("completed");
        let tracked =
            !id.is_empty()
                && STATES.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id).is_some_and(
                    |s| s.lock().unwrap_or_else(|e| e.into_inner()).bash.contains_key(id),
                );
        if command.is_none() && !edit_done && !tracked {
            return;
        }
        if !spec_exec::enabled() {
            return;
        }
        let st = state(&session.id);
        if let Some(c) = command
            && !id.is_empty()
        {
            let mut s = st.lock().unwrap_or_else(|e| e.into_inner());
            if s.bash.len() > 256 {
                s.bash.clear();
            }
            s.bash.insert(id.to_owned(), c);
        }
        if matches!(status, Some("completed" | "failed")) {
            let mut s = st.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(c) = s.bash.remove(id) {
                // A check that ran, red or green, is the one the session will run again.
                s.check = Some(c);
            }
        }
        if edit_done {
            self.speculative_schedule(session, st);
        }
    }

    fn speculative_schedule(self: &Arc<Self>, session: &Arc<Session>, st: Arc<StdMutex<State>>) {
        let generation = {
            let mut s = st.lock().unwrap_or_else(|e| e.into_inner());
            if s.check.is_none() {
                return;
            }
            s.generation = s.generation.wrapping_add(1);
            s.generation
        };
        let session = session.clone();
        self.scope.spawn_named("speculative-run", async move {
            let started = std::time::Instant::now();
            tokio::time::sleep(DEBOUNCE).await;
            loop {
                if st.lock().unwrap_or_else(|e| e.into_inner()).generation != generation {
                    return;
                }
                let busy = !session.open_tools.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
                if !busy {
                    break;
                }
                if started.elapsed() > MAX_WAIT {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            let Some(command) = st.lock().unwrap_or_else(|e| e.into_inner()).check.clone() else {
                return;
            };
            let cwd = PathBuf::from(session.meta().cwd.clone());
            let lock = FOLDERS
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .entry(cwd.clone())
                .or_default()
                .clone();
            let _folder = lock.lock_owned().await;
            if st.lock().unwrap_or_else(|e| e.into_inner()).generation != generation {
                return;
            }
            let t = std::time::Instant::now();
            let kept =
                tokio::task::spawn_blocking(move || spec_exec::prerun(&cwd, &command, BOUND))
                    .await
                    .ok()
                    .flatten();
            let mut s = st.lock().unwrap_or_else(|e| e.into_inner());
            s.pre_runs = s.pre_runs.saturating_add(1);
            let ms = u64::try_from(t.elapsed().as_millis()).unwrap_or(u64::MAX);
            s.ms_total = s.ms_total.saturating_add(ms);
            if kept.is_some() {
                s.kept = s.kept.saturating_add(1);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_background_or_non_string_command_is_not_read() {
        let fg = json!({"rawInput": {"command": "cargo check"}});
        let bg = json!({"rawInput": {"command": "cargo check", "run_in_background": true}});
        let arr = json!({"rawInput": {"command": ["bash", "-lc", "cargo check"]}});
        assert_eq!(bash_command(&fg).as_deref(), Some("cargo check"));
        assert_eq!(bash_command(&bg), None);
        assert_eq!(bash_command(&arr), None);
    }
}
