//! Durable activity identities for the existing code-mode workflow runtime.
//!
//! A resume re-evaluates the pinned script. Invocation order, primitive kind,
//! prompt and canonical options identify each activity. A started activity is
//! durable before its executor is called; its outcome is durable before JS sees
//! it. Interrupted work keeps the same identity for executor-side reattachment.
//! This journal never grants permission to execute or retry an activity.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const FORMAT: u32 = 1;
const RUNTIME_ABI: &str = "cmux-code-mode-workflow/1";

#[derive(Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum Record {
    Run { format: u32, runtime: String, id: String, source: String },
    Started { ordinal: usize, id: String, fingerprint: String },
    Completed { id: String, result: Result<Value, Value> },
}

struct Entry {
    id: String,
    fingerprint: String,
    result: Option<Result<Value, Value>>,
    completed_at: Option<usize>,
}

struct CorruptTail {
    offset: u64,
    bytes: Vec<u8>,
}

/// The next activity is either already finished or belongs to this stable identity.
#[derive(Debug, Clone, PartialEq)]
pub enum Activity {
    Replay(Result<Value, Value>),
    Work { id: String, recovered: bool },
}

/// A script cannot turn a journal refusal into success by catching a JS error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stop {
    CallBudget,
    Divergence,
}

/// One exclusive execution of a pinned workflow script.
pub struct Journal {
    // Held for the entire interpreter execution, not just an individual append.
    _owner: File,
    file: File,
    path: PathBuf,
    id: String,
    source: String,
    entries: Vec<Entry>,
    cursor: usize,
    fresh_calls: usize,
    fresh_call_limit: usize,
    poisoned: bool,
    stop: Option<Stop>,
    completions: usize,
    corrupt_tail: Option<CorruptTail>,
}

impl Drop for Journal {
    fn drop(&mut self) {
        // flock belongs to the open file description. A concurrent process
        // launch can inherit it briefly before exec closes its descriptor;
        // explicitly release our ownership instead of waiting for that copy.
        let _ = self._owner.unlock();
    }
}

impl Journal {
    /// Opens one run directory. The daemon, rather than a workflow script,
    /// chooses this directory and the pinned source.
    pub fn open(directory: &Path, source: &str, fresh_call_limit: usize) -> Result<Self> {
        crate::config::private_state_dir(directory)?;
        let owner = private_file(&directory.join("resume.lock"))?;
        owner.try_lock().context("another execution owns this workflow run")?;
        Self::open_owned(directory, source, fresh_call_limit, owner)
    }

    /// A daemon restart may launch the successor just before the old runner
    /// notices its disconnected socket. Wait on the kernel lock, with a bounded
    /// deadline, rather than racing it or polling. No work starts until claimed.
    pub fn open_handoff(
        directory: &Path,
        source: &str,
        fresh_call_limit: usize,
        timeout: std::time::Duration,
    ) -> Result<Self> {
        crate::config::private_state_dir(directory)?;
        let owner = private_file(&directory.join("resume.lock"))?;
        let (send, receive) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new().name("workflow-handoff".into()).spawn(move || {
            let result = owner.lock().map(|()| owner);
            // On timeout, dropping the unreceived File releases the eventual
            // lock. This thread performs no dispatch or journal mutation.
            let _ = send.send(result);
        })?;
        let owner = receive
            .recv_timeout(timeout)
            .context("previous workflow runner did not release its journal")??;
        Self::open_owned(directory, source, fresh_call_limit, owner)
    }

    fn open_owned(
        directory: &Path,
        source: &str,
        fresh_call_limit: usize,
        owner: File,
    ) -> Result<Self> {
        let path = directory.join("activities.jsonl");
        if !path.exists() {
            let record = Record::Run {
                format: FORMAT,
                runtime: RUNTIME_ABI.into(),
                id: uuid::Uuid::now_v7().to_string(),
                source: source.into(),
            };
            let mut bytes = serde_json::to_vec(&record)?;
            bytes.push(b'\n');
            crate::config::write_atomic(&path, &bytes)?;
            // write_atomic best-effort syncs its parent; a journal requires it.
            #[cfg(unix)]
            File::open(directory)?.sync_all()?;
        }
        let file = private_file(&path)?;
        let mut journal = Self {
            _owner: owner,
            file,
            path,
            id: String::new(),
            source: String::new(),
            entries: Vec::new(),
            cursor: 0,
            fresh_calls: 0,
            fresh_call_limit,
            poisoned: false,
            stop: None,
            completions: 0,
            corrupt_tail: None,
        };
        journal.restore()?;
        if journal.source != source {
            bail!("workflow source differs from the run's pinned script");
        }
        Ok(journal)
    }

    /// Reserves an ordinal at invocation time, before any parallel work starts.
    /// Replayed and already-started calls consume no fresh-call allowance.
    pub fn begin(&mut self, kind: &str, prompt: &str, options: &Value) -> Result<Activity> {
        self.healthy()?;
        if self.stop.is_some() {
            bail!("workflow execution has stopped; reopen the run before continuing");
        }
        if !matches!(kind, "agent" | "machine" | "call") {
            bail!("unknown workflow activity kind {kind:?}");
        }
        let fingerprint = fingerprint(kind, prompt, options)?;
        if let Some(entry) = self.entries.get(self.cursor) {
            if entry.fingerprint != fingerprint {
                self.stop = Some(Stop::Divergence);
                bail!("workflow replay diverged at activity {}", self.cursor);
            }
            self.cursor += 1;
            return Ok(match &entry.result {
                Some(result) => Activity::Replay(result.clone()),
                None => Activity::Work { id: entry.id.clone(), recovered: true },
            });
        }
        if self.fresh_calls >= self.fresh_call_limit {
            self.stop = Some(Stop::CallBudget);
            bail!(
                "workflow resume reached its fresh-call budget; resume the pinned script to continue"
            );
        }
        let id = format!("{}:{}", self.id, self.cursor);
        self.append(&Record::Started {
            ordinal: self.cursor,
            id: id.clone(),
            fingerprint: fingerprint.clone(),
        })?;
        self.entries.push(Entry { id: id.clone(), fingerprint, result: None, completed_at: None });
        self.cursor += 1;
        self.fresh_calls += 1;
        Ok(Activity::Work { id, recovered: false })
    }

    /// Completion may arrive in any order; it is always bound to the started id.
    pub fn complete(&mut self, id: &str, result: Result<Value, Value>) -> Result<()> {
        self.healthy()?;
        let ordinal = self.ordinal(id).context("unknown workflow activity")?;
        let entry = self.entries.get(ordinal).context("unknown workflow activity")?;
        if let Some(existing) = &entry.result {
            if existing != &result {
                bail!("workflow activity already has a different outcome");
            }
            return Ok(());
        }
        self.append(&Record::Completed { id: id.into(), result: result.clone() })?;
        if let Some(entry) = self.entries.get_mut(ordinal) {
            entry.result = Some(result);
            entry.completed_at = Some(self.completions);
        }
        self.completions += 1;
        Ok(())
    }

    /// Records an operator-confirmed outcome for a final journal line that was
    /// durably delimited but could not be decoded. The original bytes are kept
    /// beside the journal before they are removed from the replay stream.
    ///
    /// This is deliberately separate from [`Self::complete`]: a corrupt line
    /// may already describe an effect that ran, so retrying it is never safe.
    pub fn repair_corrupt_tail(&mut self, id: &str, result: Result<Value, Value>) -> Result<()> {
        if self.poisoned {
            bail!("workflow journal failed a write; reopen it before continuing");
        }
        let tail = self
            .corrupt_tail
            .as_ref()
            .context("workflow journal has no repairable corrupt final record")?;
        let ordinal = self.ordinal(id).context("unknown workflow activity")?;
        let entry = self.entries.get(ordinal).context("unknown workflow activity")?;
        if entry.result.is_some() {
            bail!("workflow activity already has an outcome");
        }

        preserve_corrupt_tail(&self.path, &tail.bytes)?;
        self.file.set_len(tail.offset)?;
        self.file.sync_all()?;
        self.append(&Record::Completed { id: id.into(), result: result.clone() })?;
        if let Some(entry) = self.entries.get_mut(ordinal) {
            entry.result = Some(result);
            entry.completed_at = Some(self.completions);
        }
        self.completions += 1;
        self.corrupt_tail = None;
        Ok(())
    }

    /// Identity reserved by the most recent successful begin, including a replay.
    pub fn last_id(&self) -> Option<&str> {
        self.cursor.checked_sub(1).and_then(|n| self.entries.get(n)).map(|entry| entry.id.as_str())
    }

    /// Resume settles parallel promises in the exact order their outcomes were
    /// delivered to the original interpreter, rather than current executor timing.
    pub fn next_replay(&self, pending: &[String]) -> Option<String> {
        pending
            .iter()
            .filter_map(|id| {
                let entry = self.entries.get(self.ordinal(id)?)?;
                Some((entry.completed_at?, id))
            })
            .min_by_key(|(order, _)| *order)
            .map(|(_, id)| id.clone())
    }

    /// Called before marking a run successful. A script taking a shorter path
    /// or leaving parallel work unresolved is not a completed replay.
    pub fn finish(&self) -> Result<()> {
        self.healthy()?;
        if self.stop.is_some() {
            bail!("workflow execution stopped before completion");
        }
        if self.cursor != self.entries.len()
            || self.entries.iter().any(|entry| entry.result.is_none())
        {
            bail!("workflow ended before every journaled activity was replayed and completed");
        }
        Ok(())
    }

    /// The runner uses this to suspend a budget-limited run or fail a divergent
    /// replay even if user code caught the host call's error.
    pub fn stop_reason(&self) -> Option<Stop> {
        self.stop
    }

    fn ordinal(&self, id: &str) -> Option<usize> {
        let ordinal = id.strip_prefix(&self.id)?.strip_prefix(':')?.parse::<usize>().ok()?;
        self.entries.get(ordinal).filter(|entry| entry.id == id).map(|_| ordinal)
    }

    fn healthy(&self) -> Result<()> {
        if self.poisoned {
            bail!("workflow journal failed a write; reopen it before continuing");
        }
        if self.corrupt_tail.is_some() {
            bail!(
                "workflow journal has an unrepaired corrupt final record; inspect its preserved bytes and call repair_corrupt_tail"
            );
        }
        Ok(())
    }

    fn append(&mut self, record: &Record) -> Result<()> {
        let mut bytes = serde_json::to_vec(record)?;
        bytes.push(b'\n');
        let written = (|| -> std::io::Result<()> {
            self.file.seek(SeekFrom::End(0))?;
            self.file.write_all(&bytes)?;
            self.file.sync_all()
        })();
        if let Err(error) = written {
            self.poisoned = true;
            return Err(error).context("persist workflow activity before continuing");
        }
        Ok(())
    }

    fn restore(&mut self) -> Result<()> {
        let mut reader = BufReader::new(self.file.try_clone()?);
        let mut complete_bytes = 0u64;
        let mut line = Vec::new();
        while reader.read_until(b'\n', &mut line)? != 0 {
            if line.last() != Some(&b'\n') {
                // A crash can cut the final append. Dispatch happens only after
                // its full started record is synced, so discarding a partial tail
                // cannot discard an activity the executor was allowed to start.
                self.file.set_len(complete_bytes)?;
                self.file.sync_all()?;
                break;
            }
            let record = match serde_json::from_slice::<Record>(&line) {
                Ok(record) => record,
                Err(error) => {
                    // A newline-terminated final write can still be garbled
                    // after power loss. Keep it out of replay, but retain the
                    // bytes for an explicit repair if an unfinished activity
                    // gives the operator a stable identity to inspect.
                    if !reader.fill_buf()?.is_empty()
                        || !self.entries.iter().any(|entry| entry.result.is_none())
                    {
                        return Err(error).context("corrupt workflow journal");
                    }
                    self.corrupt_tail =
                        Some(CorruptTail { offset: complete_bytes, bytes: line.clone() });
                    break;
                }
            };
            match record {
                Record::Run { format, runtime, id, source } => {
                    if complete_bytes != 0
                        || format != FORMAT
                        || runtime != RUNTIME_ABI
                        || id.is_empty()
                    {
                        bail!("invalid or incompatible workflow run header");
                    }
                    self.id = id;
                    self.source = source;
                }
                Record::Started { ordinal, id, fingerprint } => {
                    if self.id.is_empty()
                        || ordinal != self.entries.len()
                        || id != format!("{}:{ordinal}", self.id)
                    {
                        bail!("invalid workflow activity order or identity");
                    }
                    self.entries.push(Entry { id, fingerprint, result: None, completed_at: None });
                }
                Record::Completed { id, result } => {
                    let ordinal =
                        self.ordinal(&id).context("workflow completion has no started activity")?;
                    let entry = self
                        .entries
                        .get_mut(ordinal)
                        .context("workflow completion has no started activity")?;
                    if entry.result.is_some() {
                        bail!("duplicate workflow completion");
                    }
                    entry.result = Some(result);
                    entry.completed_at = Some(self.completions);
                    self.completions += 1;
                }
            }
            complete_bytes += line.len() as u64;
            line.clear();
        }
        if self.id.is_empty() {
            bail!("workflow journal has no run header");
        }
        Ok(())
    }
}

fn preserve_corrupt_tail(path: &Path, bytes: &[u8]) -> Result<()> {
    let sidecar = path.with_file_name("activities.jsonl.corrupt");
    match crate::config::private_state_create_new(&sidecar) {
        Ok(mut file) => {
            file.write_all(bytes)?;
            file.sync_all()?;
            #[cfg(unix)]
            File::open(path.parent().context("workflow journal has no parent")?)?.sync_all()?;
            Ok(())
        }
        Err(error)
            if error
                .root_cause()
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
        {
            let existing = std::fs::read(&sidecar).with_context(|| {
                format!("read preserved corrupt workflow journal {}", sidecar.display())
            })?;
            if existing == bytes {
                Ok(())
            } else {
                bail!("preserved corrupt workflow journal bytes differ")
            }
        }
        Err(error) => Err(error)
            .with_context(|| format!("preserve corrupt workflow journal {}", sidecar.display())),
    }
}

fn private_file(path: &Path) -> Result<File> {
    // Use the shared owner-only opener so Windows creates the file with its
    // restrictive DACL, rather than relying on the directory's inheritance.
    crate::config::private_state_rw(path)
        .with_context(|| format!("open workflow journal {}", path.display()))
}

fn fingerprint(kind: &str, prompt: &str, options: &Value) -> Result<String> {
    fn canonical(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let sorted = map
                    .iter()
                    .map(|(key, value)| (key.clone(), canonical(value)))
                    .collect::<BTreeMap<_, _>>();
                Value::Object(sorted.into_iter().collect())
            }
            Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
            other => other.clone(),
        }
    }
    let bytes = serde_json::to_vec(&(kind, prompt, canonical(options)))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

#[cfg(test)]
mod tests;
