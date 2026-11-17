//! The idempotency ledger: every lifecycle call goes through it.
//!
//! An append-only JSON-lines file. Before a call, the ledger writes a
//! `pending` line and syncs it; after a definite answer it writes `done` or
//! `failed`. A key whose last line is `pending` had its answer lost (a crash,
//! a timeout, a 5xx): the next run with that key first looks at the provider
//! and settles the op from what it sees, and reissues only when the op did not
//! take effect. The provider's own request id makes that reissue safe too.
//!
//! Each op appends two short lines and reads nothing, so a call costs the
//! same at 10 entries and at 100,000 (the bench in `examples/` measures it).
//! Opening replays the file once. One process writes a ledger at a time (it
//! holds the file's lock).
//!
//! A key belongs to one provider, project and location: the same key and
//! request against another zone is a conflict, not a replay.

use crate::contract::{
    IdempotencyKey, MachineProvider, MachineState, Op, ProviderError, Receipt, Request,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// How a call was answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The call ran now and the provider answered.
    Committed(Receipt),
    /// The key was already settled: the stored receipt, no provider call.
    Replayed(Receipt),
    /// The key was pending; the provider showed the op had taken effect.
    Reconciled(Receipt),
}

impl Outcome {
    pub fn receipt(&self) -> &Receipt {
        match self {
            Self::Committed(r) | Self::Replayed(r) | Self::Reconciled(r) => r,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case")]
enum Line {
    Pending { key: IdempotencyKey, fingerprint: String, op: Op, machine: String },
    Done { fingerprint: String, receipt: Receipt },
    Failed { key: IdempotencyKey, fingerprint: String, error: String },
}

#[derive(Debug, Clone)]
enum Entry {
    Pending { fingerprint: String, op: Op, machine: String },
    Done { fingerprint: String, receipt: Receipt },
    Failed { fingerprint: String },
}

impl Entry {
    fn fingerprint(&self) -> &str {
        match self {
            Self::Pending { fingerprint, .. }
            | Self::Done { fingerprint, .. }
            | Self::Failed { fingerprint } => fingerprint,
        }
    }
}

pub struct Ledger {
    path: PathBuf,
    file: File,
    entries: HashMap<IdempotencyKey, Entry>,
    generations: HashMap<String, u64>,
}

impl Ledger {
    /// Open (or create) the ledger at `path`, replaying what it holds, and
    /// hold it: a second open, here or in another process, is refused until
    /// this one drops. A torn last line (a crash mid-append) is cut off, so
    /// its op stays pending and the next line starts clean.
    pub fn open(path: &Path) -> std::io::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut options = OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(path)?;
        file.try_lock().map_err(|e| {
            std::io::Error::other(format!("{}: another process holds it ({e})", path.display()))
        })?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        let whole = bytes.iter().rposition(|&b| b == b'\n').map_or(0, |i| i.saturating_add(1));
        if whole < bytes.len() {
            file.set_len(whole as u64)?;
        }
        file.seek(SeekFrom::Start(whole as u64))?;
        let mut ledger = Self {
            path: path.to_owned(),
            file,
            entries: HashMap::new(),
            generations: HashMap::new(),
        };
        for line in bytes.get(..whole).unwrap_or_default().split(|&b| b == b'\n') {
            let Ok(line) = serde_json::from_slice::<Line>(line) else { continue };
            ledger.absorb(line);
        }
        Ok(ledger)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Keys whose answer was lost: the orphans a reaper settles on next open.
    pub fn pending(&self) -> Vec<(IdempotencyKey, Op, String)> {
        let mut out: Vec<_> = self
            .entries
            .iter()
            .filter_map(|(key, entry)| match entry {
                Entry::Pending { op, machine, .. } => Some((key.clone(), *op, machine.clone())),
                _ => None,
            })
            .collect();
        out.sort_by(|a, b| a.0.as_str().cmp(b.0.as_str()));
        out
    }

    /// Run `request` under `key` through `provider`, at most once.
    pub fn run(
        &mut self,
        provider: &dyn MachineProvider,
        key: &IdempotencyKey,
        request: &Request,
    ) -> Result<Outcome, ProviderError> {
        if let Some(spec) = &request.spec {
            spec.validate()?;
        }
        let scope = scope_of(provider);
        let fingerprint =
            hex::encode(Sha256::digest(format!("{scope}\0{}", request.fingerprint()).as_bytes()));
        let machine = match (request.op, &request.machine) {
            (Op::Create, _) => provider.machine_for(key),
            (_, Some(machine)) => machine.clone(),
            (_, None) => return Err(ProviderError::Refused("this op names a machine".into())),
        };
        match self.entries.get(key).cloned() {
            Some(entry) if entry.fingerprint() != fingerprint => {
                return Err(ProviderError::Conflict(format!(
                    "key {} was used for another request",
                    key.as_str()
                )));
            }
            Some(Entry::Done { receipt, .. }) => return Ok(Outcome::Replayed(receipt)),
            Some(Entry::Pending { .. }) => {
                if let Some(state) = settled_by(request.op, provider.observe(&machine)?) {
                    let receipt =
                        self.commit(provider, key, request.op, &machine, state, None, true);
                    self.append(&Line::Done { fingerprint, receipt: receipt.clone() })?;
                    return Ok(Outcome::Reconciled(receipt));
                }
            }
            Some(Entry::Failed { .. }) | None => {
                self.append(&Line::Pending {
                    key: key.clone(),
                    fingerprint: fingerprint.clone(),
                    op: request.op,
                    machine: machine.clone(),
                })?;
            }
        }
        match provider.apply(key, request) {
            Ok((state, artifact)) => {
                let receipt =
                    self.commit(provider, key, request.op, &machine, state, artifact, false);
                self.append(&Line::Done { fingerprint, receipt: receipt.clone() })?;
                Ok(Outcome::Committed(receipt))
            }
            // The answer is lost: the line stays pending for the next run.
            Err(error @ ProviderError::Indeterminate(_)) => Err(error),
            Err(error) => {
                self.append(&Line::Failed {
                    key: key.clone(),
                    fingerprint,
                    error: error.to_string(),
                })?;
                Err(error)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn commit(
        &self,
        provider: &dyn MachineProvider,
        key: &IdempotencyKey,
        op: Op,
        machine: &str,
        state: MachineState,
        artifact: Option<String>,
        reconciled: bool,
    ) -> Receipt {
        let generation_key = format!("{}/{machine}", scope_of(provider));
        Receipt {
            provider: provider.provider().to_owned(),
            project: provider.project().to_owned(),
            location: provider.location().to_owned(),
            machine: machine.to_owned(),
            generation: self
                .generations
                .get(&generation_key)
                .copied()
                .unwrap_or(0)
                .saturating_add(1),
            op,
            key: key.clone(),
            state,
            artifact,
            reconciled,
            at_unix_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
                .unwrap_or(0),
        }
    }

    fn append(&mut self, line: &Line) -> Result<(), ProviderError> {
        let mut bytes = serde_json::to_vec(line)
            .map_err(|e| ProviderError::Refused(format!("ledger encode: {e}")))?;
        bytes.push(b'\n');
        self.file
            .write_all(&bytes)
            .and_then(|()| self.file.sync_data())
            .map_err(|e| ProviderError::Refused(format!("ledger {}: {e}", self.path.display())))?;
        self.absorb(line.clone());
        Ok(())
    }

    fn absorb(&mut self, line: Line) {
        match line {
            Line::Pending { key, fingerprint, op, machine } => {
                self.entries.insert(key, Entry::Pending { fingerprint, op, machine });
            }
            Line::Done { fingerprint, receipt } => {
                let at = format!(
                    "{}/{}/{}/{}",
                    receipt.provider, receipt.project, receipt.location, receipt.machine
                );
                self.generations.insert(at, receipt.generation);
                self.entries.insert(receipt.key.clone(), Entry::Done { fingerprint, receipt });
            }
            Line::Failed { key, fingerprint, .. } => {
                self.entries.insert(key, Entry::Failed { fingerprint });
            }
        }
    }
}

/// Where a key's machines live: `provider/project/location`.
fn scope_of(provider: &dyn MachineProvider) -> String {
    format!("{}/{}/{}", provider.provider(), provider.project(), provider.location())
}

/// The state that shows a pending op took effect, or `None` when it must be
/// reissued. A snapshot is never settled by looking: its provider-side name
/// is deterministic, so the reissue finds it.
fn settled_by(op: Op, observed: Option<MachineState>) -> Option<MachineState> {
    match (op, observed) {
        (Op::Create, Some(state))
            if !matches!(state, MachineState::Deleting | MachineState::Deleted) =>
        {
            Some(state)
        }
        (Op::Delete, None | Some(MachineState::Deleted)) => Some(MachineState::Deleted),
        (Op::Delete, Some(MachineState::Deleting)) => Some(MachineState::Deleting),
        (Op::Stop, Some(MachineState::Stopped)) => Some(MachineState::Stopped),
        (Op::Start, Some(state @ (MachineState::Running | MachineState::Provisioning))) => {
            Some(state)
        }
        _ => None,
    }
}
