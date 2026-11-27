//! Part of `Hub`; see `hub/mod.rs`. A checkpoint of the session's folder at each turn end (RFD
//! 0158 §7, the daemon's first piece): harness magic `checkpoints`, off unless
//! `agents.harnessMagic.checkpoints.enabled` is `true` (`ACPMUX_HM_CHECKPOINTS=0` turns it off,
//! `=1` on, over the setting).
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! Claude Code's own file checkpoints do not follow a `forkSession`, and Codex `thread/revert`
//! leaves files as they are, so the daemon keeps them for every harness: everything git does not
//! ignore, committed or not, as a commit under `refs/cmux-turns/<session>/<turn>`, outside
//! `refs/heads` and never pushed. It is built like `wip_ref.rs`'s, in a scratch index, so the
//! folder's branch, index and working tree are not touched. The scratch index starts as a copy
//! of the folder's own, so `git add -A` hashes only what changed since and not the whole tree.
//! A turn that changed nothing points at the last turn's commit. A session keeps its newest
//! [`KEEP`].
//!
//! The `turn_result` says what it did: `checkpoint: {"commit": .., "changed": bool}` when one was
//! taken, and `harnessMagic.checkpoints.{written,same,skipped,late}`. A folder with no git
//! repository, a git that fails, and a save past [`LIMIT`] leave the field out and never fail
//! or hold up the turn past the bound. Rewinding files to a checkpoint and forking a turn with
//! them are the next pieces; they read these refs.

use super::Session;
use super::wip_ref::git;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The feature's name in its setting, kill switch and counters.
pub(crate) const FEATURE: &str = "checkpoints";

/// The longest a turn end waits on its checkpoint. A save still running then finishes in the
/// background; the turn records it as `late`.
const LIMIT: Duration = Duration::from_secs(5);

/// The checkpoints a session keeps, newest first; older ones are deleted at each new one.
pub(crate) const KEEP: usize = 100;

/// Whether the feature is on: the environment's `ACPMUX_HM_CHECKPOINTS` (`0` off, `1` on), then
/// the settings key (off unless `true`).
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, &super::harness_magic::setting_key(FEATURE)))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// [`enabled_with`] the settings file and environment now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    let env = std::env::var(super::harness_magic::env_key(FEATURE)).ok();
    enabled_with(doc.as_ref(), env.as_deref())
}

fn plain(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 80
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The ref a session's turn is kept under, None for an id that is no plain ref component.
pub(crate) fn ref_name(session_id: &str, turn_id: &str) -> Option<String> {
    (plain(session_id) && plain(turn_id)).then(|| format!("refs/cmux-turns/{session_id}/{turn_id}"))
}

/// The ref naming a session's newest checkpoint, whatever turn took it.
fn latest_ref(session_id: &str) -> String {
    format!("refs/cmux-turns-latest/{session_id}")
}

/// What a checkpoint did, for the `turn_result`, the counters and the tests.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Taken {
    /// Not a git folder, an id that is no ref name, or a git call that failed.
    Skipped,
    /// The folder is as the last checkpoint left it; this turn's ref names that commit.
    Same { commit: String },
    /// A new commit holds the folder as this turn left it.
    Written { commit: String },
}

/// Takes the turn's checkpoint of the folder at `cwd` (blocking).
pub(crate) fn take_blocking(cwd: &Path, session_id: &str, turn_id: &str) -> Taken {
    let Some(name) = ref_name(session_id, turn_id) else { return Taken::Skipped };
    let Some(top) = git(cwd, None, &["rev-parse", "--show-toplevel"]) else {
        return Taken::Skipped;
    };
    let top = PathBuf::from(top);
    let Some(gitdir) = git(&top, None, &["rev-parse", "--absolute-git-dir"]) else {
        return Taken::Skipped;
    };
    let gitdir = PathBuf::from(gitdir);
    let index = gitdir.join(format!("cmux-turn-{session_id}.index"));
    let _ = crate::home_fs::remove_file(&index);
    // The folder's own index as the start. A sparse checkout's files outside its set are in it
    // and not on disk: started empty, the checkpoint would leave them out and a rewind would
    // delete them (2665 of a cmux lane checkout's 75484). Its stat data also lets `add -A` skip
    // every file that has not changed: 1.5 s for that checkout. With no index (a fresh
    // repository), the scratch index starts empty.
    let _ = std::fs::copy(gitdir.join("index"), &index);
    let tree = git(&top, Some(&index), &["add", "-A", "--", "."])
        .and_then(|_| git(&top, Some(&index), &["write-tree"]));
    let _ = crate::home_fs::remove_file(&index);
    let Some(tree) = tree else { return Taken::Skipped };
    let latest = latest_ref(session_id);
    let last = git(&top, None, &["rev-parse", "--verify", "-q", &format!("{latest}^{{commit}}")]);
    let last_tree =
        git(&top, None, &["rev-parse", "--verify", "-q", &format!("{latest}^{{tree}}")]);
    if let (Some(commit), Some(last_tree)) = (last, last_tree) {
        if last_tree == tree {
            if git(&top, None, &["update-ref", &name, &commit]).is_none() {
                return Taken::Skipped;
            }
            prune(&top, session_id);
            return Taken::Same { commit };
        }
    }
    let head = git(&top, None, &["rev-parse", "--verify", "-q", "HEAD"]);
    let message = format!("cmux turn {turn_id}");
    let mut args = vec!["commit-tree", tree.as_str(), "-m", message.as_str()];
    if let Some(head) = head.as_deref() {
        args.extend(["-p", head]);
    }
    let Some(commit) = git(&top, None, &args) else { return Taken::Skipped };
    if git(&top, None, &["update-ref", &name, &commit]).is_none()
        || git(&top, None, &["update-ref", &latest, &commit]).is_none()
    {
        return Taken::Skipped;
    }
    prune(&top, session_id);
    Taken::Written { commit }
}

/// Deletes a session's checkpoints past the newest [`KEEP`], newest by the time of the state
/// each names (a turn that changed nothing ranks with the turn that made its state).
fn prune(top: &Path, session_id: &str) {
    let prefix = format!("refs/cmux-turns/{session_id}/");
    let Some(listed) =
        git(top, None, &["for-each-ref", "--sort=-creatordate", "--format=%(refname)", &prefix])
    else {
        return;
    };
    for old in listed.lines().skip(KEEP) {
        let _ = git(top, None, &["update-ref", "-d", old]);
    }
}

/// The `turn_result` field of what a checkpoint did; `None` (and so `skipped` or `late`) leaves
/// it out.
pub(crate) fn field(taken: Option<&Taken>) -> Map<String, Value> {
    let mut fields = Map::new();
    let (state, commit, changed) = match taken {
        Some(Taken::Written { commit }) => ("written", Some(commit), true),
        Some(Taken::Same { commit }) => ("same", Some(commit), false),
        Some(Taken::Skipped) => ("skipped", None, false),
        None => ("late", None, false),
    };
    if let Some(commit) = commit {
        fields.insert("checkpoint".into(), json!({"commit": commit, "changed": changed}));
    }
    fields.insert(STATE_KEY.into(), json!(state));
    fields
}

/// The private key carrying what the checkpoint did from the turn end to [`count`].
const STATE_KEY: &str = "_checkpointState";

/// Moves the private state [`field`] left on a `turn_result` into its harness-magic counter.
pub(crate) fn count(msg: &mut Value) {
    let Some(state) = msg.as_object_mut().and_then(|o| o.remove(STATE_KEY)) else { return };
    if let Some(state) = state.as_str() {
        super::harness_magic::add_counter(msg, FEATURE, state, 1);
    }
}

/// The turn's checkpoint fields, when the feature is on (bounded, off the runtime).
pub(super) async fn turn_checkpoint(session: &Session, turn_id: &str) -> Map<String, Value> {
    if !enabled() {
        return Map::new();
    }
    let cwd = session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd.clone();
    let (id, turn) = (session.id.clone(), turn_id.to_owned());
    let run = tokio::task::spawn_blocking(move || take_blocking(&cwd, &id, &turn));
    match tokio::time::timeout(LIMIT, run).await {
        Ok(Ok(taken)) => field(Some(&taken)),
        Ok(Err(_)) => field(Some(&Taken::Skipped)),
        Err(_) => {
            tracing::warn!(session = %session.id, "the turn's checkpoint ran past its bound");
            field(None)
        }
    }
}

#[cfg(test)]
#[path = "turn_checkpoint_tests.rs"]
mod tests;
