//! The commit journal: proof that a keyed `git.commit` started git. The
//! attempt is written (atomically, 0600, under the session's state directory
//! in `git-commits/`) before git runs and removed once the result is in the
//! mutation ledger or git refused.
//!
//! When a reply is lost between git's commit and the ledger (the daemon
//! stopped, or the deadline stopped git after it moved HEAD), a retry with the
//! same key and arguments finds the attempt. It reports HEAD as the attempt's
//! commit only when HEAD is a new commit whose parents are the ones the
//! attempt planned, committed no earlier than the attempt started, with the
//! attempt's subject. Without an attempt nothing is recovered: a commit with
//! the same message made in a terminal is never taken for this one.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::Repository;
use super::checkpoint::store::{hex, private_directory, read_json, write_json};
use super::mutation::refused;
use crate::Mux;
use crate::resource::ResourceError;

const DIRECTORY: &str = "git-commits";

/// A started commit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct Attempt {
    pub idempotency_key: String,
    pub fingerprint: Value,
    /// HEAD before the commit; `None` on an unborn branch.
    pub head: Option<String>,
    /// The parents the new commit gets: HEAD, or HEAD's own with amend.
    pub parents: Vec<String>,
    /// The subject git derives from the message.
    pub subject: String,
    /// Seconds since the epoch.
    pub started_at: u64,
}

impl Attempt {
    pub(super) fn new(
        key: &str,
        fingerprint: &Value,
        head: Option<String>,
        parents: Vec<String>,
        message: &str,
    ) -> Self {
        Self {
            idempotency_key: key.to_string(),
            fingerprint: fingerprint.clone(),
            head,
            parents,
            subject: subject(message),
            started_at: now(),
        }
    }

    /// HEAD, when it is the commit this attempt made.
    pub(super) fn recovered(&self, repository: &Repository, head: Option<&str>) -> Option<String> {
        let head = head?;
        if Some(head) == self.head.as_deref() {
            return None;
        }
        let arguments = ["log", "-1", "--format=%P%n%ct%n%s", "--end-of-options", head];
        let output = repository.run(&arguments, 64 * 1024).ok()?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.split('\n');
        let parents: Vec<String> =
            lines.next()?.split_whitespace().map(str::to_string).collect();
        let committed: u64 = lines.next()?.trim().parse().ok()?;
        let subject = lines.next()?.trim_end();
        // One second of slack: the attempt's clock and git's round down.
        let same = parents == self.parents
            && committed + 1 >= self.started_at
            && subject == self.subject;
        same.then(|| head.to_string())
    }
}

/// The journal entry of one key, or none for a session without durable
/// state.
pub(super) struct Journal {
    path: PathBuf,
    operation: &'static str,
}

impl Journal {
    pub(super) fn open(
        mux: &Mux,
        key: &str,
        operation: &'static str,
    ) -> Result<Option<Self>, ResourceError> {
        let Some(session) = mux.session_state_directory() else { return Ok(None) };
        let directory = session.join(DIRECTORY);
        private_directory(&directory).map_err(|error| failed(operation, &error))?;
        let name = format!("{}.json", hex(&Sha256::digest(key.as_bytes())));
        Ok(Some(Self { path: directory.join(name), operation }))
    }

    /// The unfinished attempt of this key with this fingerprint.
    pub(super) fn attempt(&self, key: &str, fingerprint: &Value) -> Option<Attempt> {
        let attempt: Attempt = read_json(&self.path).ok().flatten()?;
        (attempt.idempotency_key == key && &attempt.fingerprint == fingerprint).then_some(attempt)
    }

    pub(super) fn start(&self, attempt: &Attempt) -> Result<(), ResourceError> {
        write_json(&self.path, attempt).map_err(|error| failed(self.operation, &error))
    }

    /// Drops the attempt; a leftover entry only costs a lookup.
    pub(super) fn finish(&self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// What git's `%s` shows for `message`: its first paragraph, each line
/// without trailing whitespace, joined with spaces.
pub(super) fn subject(message: &str) -> String {
    message
        .lines()
        .map(str::trim_end)
        .skip_while(|line| line.is_empty())
        .take_while(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

fn failed(operation: &'static str, error: &std::io::Error) -> ResourceError {
    let message = format!("the commit journal could not be read or written: {error}");
    refused(operation, "store_failed", message, Value::Null)
}
