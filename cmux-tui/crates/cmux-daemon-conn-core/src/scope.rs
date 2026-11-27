//! Everything one app action sent to its daemons
//! (plans/cmux-next/state-ownership.md 4).
//!
//! Each command funnel opens a ticket on entry and closes it after the reply,
//! recording a failure and the event sequence that covers the command's
//! echo; the connection records the objects a creating command made. The
//! action then waits until no ticket is open (the app's waiters) and answers
//! with what the scope saw.
//!
//! With an idempotency key, the mutation ids and generated keys the action
//! sends derive from the key and the command's ordinal, so a retry with the
//! same key replays in the daemon instead of applying twice. A closed scope
//! derives nothing and records nothing.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

/// The stage log keeps its first entries and its newest ones (the end of a
/// long run is what a timeout waited on).
pub const STAGE_LOG_HEAD: usize = 16;
pub const STAGE_LOG_MAX: usize = 48;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Failure {
    pub label: String,
    pub message: String,
    #[serde(default)]
    pub may_have_applied: bool,
    #[serde(default)]
    pub terminal_may_appear: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Created {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Default)]
pub struct Scope {
    idempotency_key: Option<String>,
    open: BTreeSet<u64>,
    next_ticket: u64,
    mutations: u64,
    derived: BTreeMap<String, u64>,
    failures: Vec<Failure>,
    created: Vec<Created>,
    barriers: BTreeMap<String, u64>,
    closed: bool,
    stages: Vec<String>,
}

/// `stage@ms`.
pub fn stamped(stage: &str, at_ms: u64) -> String {
    format!("{stage}@{at_ms}")
}

/// Appends `entry`, keeping the first [`STAGE_LOG_HEAD`] entries and the
/// newest ones up to [`STAGE_LOG_MAX`] in all.
pub fn append_keeping_head(log: &mut Vec<String>, entry: String) {
    if log.len() >= STAGE_LOG_MAX && log.len() > STAGE_LOG_HEAD {
        log.remove(STAGE_LOG_HEAD);
    }
    log.push(entry);
}

impl Scope {
    /// An empty key counts as none.
    pub fn new(idempotency_key: Option<&str>) -> Self {
        Self {
            idempotency_key: idempotency_key.filter(|k| !k.is_empty()).map(str::to_string),
            ..Self::default()
        }
    }

    pub fn idempotency_key(&self) -> Option<&str> {
        self.idempotency_key.as_deref()
    }

    /// The stage log, with the open tickets last.
    pub fn stage_log(&self) -> Vec<String> {
        let mut log = self.stages.clone();
        if !self.open.is_empty() {
            let open: Vec<String> = self.open.iter().map(|t| format!("#{t}")).collect();
            log.push(format!("open now: {}", open.join(" ")));
        }
        log
    }

    pub fn note(&mut self, stage: &str, at_ms: u64) {
        append_keeping_head(&mut self.stages, stamped(stage, at_ms));
    }

    /// Opens a ticket for a command about to be sent; `None` once closed.
    pub fn begin(&mut self, label: Option<&str>, at_ms: u64) -> Option<u64> {
        if self.closed {
            return None;
        }
        self.next_ticket = self.next_ticket.wrapping_add(1);
        let ticket = self.next_ticket;
        self.open.insert(ticket);
        self.note(&labeled(&format!("open#{ticket}"), label), at_ms);
        Some(ticket)
    }

    /// Closes `ticket`, recording `failure`; true when this made the scope
    /// idle (wake the waiters).
    pub fn end(
        &mut self,
        ticket: u64,
        failure: Option<Failure>,
        label: Option<&str>,
        at_ms: u64,
    ) -> bool {
        if !self.open.remove(&ticket) {
            return false;
        }
        self.note(&labeled(&format!("close#{ticket}"), label), at_ms);
        if let Some(failure) = failure {
            self.failures.push(failure);
        }
        self.open.is_empty()
    }

    /// `machine`'s events up to `sequence` cover a command's echo.
    pub fn note_barrier(&mut self, sequence: u64, machine: &str) {
        if self.closed {
            return;
        }
        let barrier = self.barriers.entry(machine.to_string()).or_insert(0);
        *barrier = (*barrier).max(sequence);
    }

    pub fn note_created(&mut self, objects: Vec<Created>) {
        if self.closed {
            return;
        }
        for object in objects {
            if !self.created.contains(&object) {
                self.created.push(object);
            }
        }
    }

    pub fn is_idle(&self) -> bool {
        self.open.is_empty()
    }

    pub fn close(&mut self) {
        self.closed = true;
    }

    pub fn is_open(&self) -> bool {
        !self.closed
    }

    pub fn failures(&self) -> &[Failure] {
        &self.failures
    }

    pub fn created(&self) -> &[Created] {
        &self.created
    }

    pub fn ticket_count(&self) -> u64 {
        self.next_ticket
    }

    pub fn barriers(&self) -> &BTreeMap<String, u64> {
        &self.barriers
    }

    /// The next `mutation_id`: derived from the key and the mutation's
    /// ordinal, or `None` (a fresh id) without a key or once closed.
    pub fn next_mutation_id(&mut self) -> Option<String> {
        let key = self.idempotency_key.clone()?;
        if self.closed {
            return None;
        }
        self.mutations = self.mutations.saturating_add(1);
        Some(derived_uuid(&key, "mutation", self.mutations))
    }

    /// The next generated id of `kind` (a workspace key, a terminal id).
    pub fn next_derived(&mut self, kind: &str) -> Option<String> {
        let key = self.idempotency_key.clone()?;
        if self.closed {
            return None;
        }
        let ordinal = self.derived.entry(kind.to_string()).or_insert(0);
        *ordinal = ordinal.saturating_add(1);
        Some(derived_uuid(&key, kind, *ordinal))
    }
}

fn labeled(stage: &str, label: Option<&str>) -> String {
    match label {
        Some(label) => format!("{stage} {label}"),
        None => stage.to_string(),
    }
}

/// A UUID from SHA-256 of `cmux-next/<kind>/<ordinal>/<key>`, in the version
/// 4 layout (cmux-tui accepts caller-chosen terminal ids only as UUIDv4),
/// lowercase and hyphenated.
pub fn derived_uuid(key: &str, kind: &str, ordinal: u64) -> String {
    let digest = Sha256::digest(format!("cmux-next/{kind}/{ordinal}/{key}").as_bytes());
    let mut text = String::with_capacity(36);
    for (index, byte) in digest.iter().take(16).enumerate() {
        let byte = match index {
            6 => (byte & 0x0F) | 0x40,
            8 => (byte & 0x3F) | 0x80,
            _ => *byte,
        };
        if matches!(index, 4 | 6 | 8 | 10) {
            text.push('-');
        }
        let _ = write!(text, "{byte:02x}");
    }
    text
}
