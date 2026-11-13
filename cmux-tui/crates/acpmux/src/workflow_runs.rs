//! The daemon's durable ownership of native code-mode workflow runs.
//!
//! Script bytes, inputs and tool ceilings are immutable. A generation fences every runner and
//! activity mutation; pausing commits that fence before any child is interrupted. Runner tokens
//! are launch-local credentials, never part of the on-disk record.

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

mod service;
pub use service::{RUNNER_TOKEN_ENV, Service};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Running,
    Pausing,
    Paused,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Child {
    Agent {
        session_id: String,
        prompt_id: String,
        #[serde(default)]
        host: Option<String>,
    },
    CiMachine {
        intent: CiIntent,
    },
    Machine {
        session_id: String,
        task_id: String,
        #[serde(default)]
        host: Option<String>,
    },
}

/// Immutable fleet submission, committed with the activity before the first POST.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CiIntent {
    pub request_key: String,
    pub repo: String,
    pub source_ref: String,
    pub command: String,
    pub target_worker: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActivityRecord {
    pub id: String,
    pub kind: String,
    pub fingerprint: String,
    pub child: Child,
    #[serde(default)]
    pub policy: Value,
    pub outcome: Option<Result<Value, Value>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunRecord {
    pub version: u32,
    pub id: String,
    pub name: String,
    pub owner_session_id: String,
    /// The same-user Unix CLI created this owner in asking mode, without a chat proof.
    #[serde(default)]
    pub local_principal: bool,
    pub source: String,
    pub source_hash: String,
    pub args: Value,
    /// None is unrestricted; Some(empty) grants no tool. A resume can only narrow this.
    pub allowed_tools: Option<Vec<String>>,
    pub cwd: PathBuf,
    pub generation: u64,
    pub state: State,
    pub activities: BTreeMap<String, ActivityRecord>,
    pub outcome: Option<Result<Value, Value>>,
    /// The Claude Code subagent (`{id, type}`, plain words) whose MCP call started the run
    /// (`subagent_call.rs`): the run's commands run as that subagent's Bash would
    /// (`cli::sender::SUBAGENT_ENV`). A label within the owner session, never a proof. Absent
    /// in records of runs the chat itself, the person or an older build started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_subagent: Option<Value>,
}

/// Private, per-daemon run records, independent of any chat's purge-owned background folder.
#[derive(Debug, Clone)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn directory(&self, id: &str) -> Result<PathBuf> {
        ensure!(valid_id(id), "invalid workflow run id");
        Ok(self.root.join(id))
    }

    pub fn start(&self, mut record: RunRecord) -> Result<RunRecord> {
        record.version = 1;
        record.source_hash = digest(&record.source);
        record.generation = 1;
        record.state = State::Running;
        record.activities.clear();
        record.outcome = None;
        let dir = self.directory(&record.id)?;
        let _lock = lock(&dir)?;
        let path = dir.join("run.json");
        if path.exists() {
            let previous = read(&path)?;
            ensure!(
                previous.owner_session_id == record.owner_session_id
                    && previous.local_principal == record.local_principal
                    && previous.source == record.source
                    && previous.args == record.args
                    && previous.allowed_tools == record.allowed_tools
                    && previous.cwd == record.cwd,
                "this workflow run id already pins different inputs"
            );
            return Ok(previous);
        }
        write(&path, &record)?;
        Ok(record)
    }

    pub fn get(&self, id: &str) -> Result<RunRecord> {
        let dir = self.directory(id)?;
        let _lock = lock(&dir)?;
        read(&dir.join("run.json"))
    }

    pub fn list(&self) -> Result<Vec<RunRecord>> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        let mut records = Vec::new();
        for entry in std::fs::read_dir(&self.root)? {
            let entry = entry?;
            let Some(id) = entry.file_name().to_str().map(str::to_owned) else { continue };
            if valid_id(&id) && entry.file_type()?.is_dir() {
                match self.get(&id) {
                    Ok(record) => records.push(record),
                    Err(error) => {
                        tracing::warn!(run_id = %id, %error, "skip unreadable workflow record")
                    }
                }
            }
        }
        Ok(records)
    }

    pub fn authorize(&self, id: &str, generation: u64, owner: &str) -> Result<RunRecord> {
        let run = self.get(id)?;
        authorize(&run, generation, owner)?;
        Ok(run)
    }

    /// Pause commits its fence before a caller obtains the children to interrupt.
    pub fn pause(&self, id: &str, owner: &str) -> Result<RunRecord> {
        self.change(id, |run| {
            ensure!(run.owner_session_id == owner, "this workflow belongs to another chat");
            if matches!(run.state, State::Paused | State::Pausing) {
                return Ok(());
            }
            ensure!(run.state == State::Running, "this workflow has ended");
            run.generation =
                run.generation.checked_add(1).context("workflow generation exhausted")?;
            run.state = State::Pausing;
            Ok(())
        })
    }

    pub fn paused(&self, id: &str, generation: u64) -> Result<RunRecord> {
        self.change(id, |run| {
            ensure!(run.generation == generation && run.state == State::Pausing, "stale pause");
            run.state = State::Paused;
            Ok(())
        })
    }

    /// An explicit resume, or daemon recovery of a previously running run, gets a fresh fence.
    pub fn resume(&self, id: &str, owner: &str, recovery: bool) -> Result<RunRecord> {
        self.change(id, |run| {
            ensure!(run.owner_session_id == owner, "this workflow belongs to another chat");
            ensure!(
                run.state == State::Paused || (recovery && run.state == State::Running),
                "this workflow is not paused"
            );
            run.generation =
                run.generation.checked_add(1).context("workflow generation exhausted")?;
            run.state = State::Running;
            Ok(())
        })
    }

    pub fn settle(
        &self,
        id: &str,
        generation: u64,
        owner: &str,
        outcome: Result<Value, Value>,
    ) -> Result<RunRecord> {
        self.change(id, |run| {
            authorize(run, generation, owner)?;
            ensure!(
                outcome.is_err()
                    || run
                        .activities
                        .values()
                        .filter(|activity| matches!(activity.kind.as_str(), "agent" | "machine"))
                        .all(|activity| activity.outcome.is_some()),
                "workflow has unresolved activities"
            );
            run.state = if outcome.is_ok() { State::Completed } else { State::Failed };
            run.outcome = Some(outcome);
            Ok(())
        })
    }

    pub fn activity(
        &self,
        id: &str,
        generation: u64,
        owner: &str,
        activity_id: &str,
    ) -> Result<Option<ActivityRecord>> {
        Ok(self.authorize(id, generation, owner)?.activities.get(activity_id).cloned())
    }

    pub fn register_activity(
        &self,
        id: &str,
        generation: u64,
        owner: &str,
        activity: ActivityRecord,
    ) -> Result<ActivityRecord> {
        ensure!(valid_id(&activity.id), "invalid workflow activity id");
        let activity_id = activity.id.clone();
        let record = self.change(id, |run| {
            authorize(run, generation, owner)?;
            if let Some(previous) = run.activities.get(&activity.id) {
                ensure!(
                    previous.kind == activity.kind
                        && previous.fingerprint == activity.fingerprint
                        && previous.child == activity.child,
                    "workflow activity id pins different inputs"
                );
            } else {
                ensure!(activity.outcome.is_none(), "new activity already has an outcome");
                run.activities.insert(activity.id.clone(), activity);
            }
            Ok(())
        })?;
        record.activities.get(&activity_id).cloned().context("activity was not registered")
    }

    /// Persist the schema/stall decision before the executor performs its next effect.
    pub fn update_activity_policy(
        &self,
        id: &str,
        generation: u64,
        owner: &str,
        activity_id: &str,
        policy: Value,
    ) -> Result<ActivityRecord> {
        let record = self.change(id, |run| {
            authorize(run, generation, owner)?;
            let activity =
                run.activities.get_mut(activity_id).context("unknown workflow activity")?;
            ensure!(
                activity.outcome.is_none(),
                "completed workflow activity has no next policy action"
            );
            activity.policy = policy;
            Ok(())
        })?;
        record.activities.get(activity_id).cloned().context("activity disappeared")
    }

    pub fn complete_activity(
        &self,
        id: &str,
        generation: u64,
        owner: &str,
        activity_id: &str,
        outcome: Result<Value, Value>,
    ) -> Result<ActivityRecord> {
        let record = self.change(id, |run| {
            authorize(run, generation, owner)?;
            let activity =
                run.activities.get_mut(activity_id).context("unknown workflow activity")?;
            if let Some(previous) = &activity.outcome {
                ensure!(previous == &outcome, "workflow activity already has another outcome");
            } else {
                activity.outcome = Some(outcome);
            }
            Ok(())
        })?;
        record.activities.get(activity_id).cloned().context("activity disappeared")
    }

    fn change(
        &self,
        id: &str,
        apply: impl FnOnce(&mut RunRecord) -> Result<()>,
    ) -> Result<RunRecord> {
        let dir = self.directory(id)?;
        let _lock = lock(&dir)?;
        let path = dir.join("run.json");
        let mut record = read(&path)?;
        apply(&mut record)?;
        write(&path, &record)?;
        Ok(record)
    }
}

fn authorize(run: &RunRecord, generation: u64, owner: &str) -> Result<()> {
    ensure!(run.owner_session_id == owner, "this workflow belongs to another chat");
    ensure!(run.generation == generation, "stale workflow generation");
    ensure!(run.state == State::Running, "this workflow is not running");
    Ok(())
}

pub fn digest(source: &str) -> String {
    format!("{:x}", Sha256::digest(source.as_bytes()))
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn lock(dir: &Path) -> Result<File> {
    crate::config::private_state_dir(dir)?;
    // Made in the held home (`home_fs`): a home replaced after the check above never gets the
    // lock file (#41462 review F2).
    let mut options = crate::home_fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false).mode(0o600);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let file = options.open(dir.join("record.lock"))?;
    file.lock().context("lock workflow record")?;
    Ok(file)
}

fn read(path: &Path) -> Result<RunRecord> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let record: RunRecord = serde_json::from_reader(options.open(path)?)
        .with_context(|| format!("read workflow record {}", path.display()))?;
    ensure!(record.version == 1, "unsupported workflow record version");
    ensure!(record.source_hash == digest(&record.source), "workflow source hash does not match");
    Ok(record)
}

fn write(path: &Path, record: &RunRecord) -> Result<()> {
    crate::config::write_atomic(path, &serde_json::to_vec(record)?)?;
    // Unlike optional session metadata, an activity fence cannot be acknowledged before its
    // directory entry is durable. A failed sync fails the operation before dispatch.
    #[cfg(unix)]
    File::open(path.parent().context("workflow record has no parent")?)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests;
