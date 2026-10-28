//! Admit then reply (F10 core, p05-ipc-120; plans/cmux-next/chrome-parity/p05-ipc.md 3.6).
//!
//! A request whose registry commit result was decided at prepare (the
//! in-memory revisions and mutation ledger, p05-ipc-132) does not wait for the
//! journal writer: [`WorkspaceRegistry::admit_registry_intent`] queues the
//! intent on the writer's durable lane, gives it an admit sequence, and
//! returns the prepared receipt. The caller applies its state, emits its
//! events and replies; the writer commits later. Chrome's browser process
//! does the same with its profile stores: the UI thread changes the model and
//! posts the write to a sequenced background runner
//! (components/prefs/json_pref_store.cc, `ImportantFileWriter` in
//! base/files/important_file_writer.cc) instead of waiting on disk.
//!
//! What keeps the reply honest:
//! - Read-your-writes: a cold read through the registry connection waits,
//!   bounded and counted (`read_barrier_waits`), until every admitted intent
//!   has its writer answer (`RegistryConnection::read_barrier`). Hot reads
//!   served by the admitted overlay (p05-ipc-133) never reach it.
//! - The writer only applies: an answer that is an error, or a receipt that
//!   differs from the one the reply gave, keeps the in-memory state and is a
//!   journal-degraded note (`journal_degraded`, a `MuxEvent::Status` when the
//!   next state holder settles).
//! - Every request that could not be admitted commits as before and is
//!   counted by reason (`fallbacks_*`).
//!
//! The path is behind the default-off daemon feature [`FEATURE`]
//! (schemas/features/features.d/admitThenReply.json); off, every call
//! commits through the writer and waits for its receipt as before.
#![cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

use super::RegistryReceipt;

/// The registry name of the feature that turns admit then reply on.
pub(crate) const FEATURE: &str = "admitThenReply";

/// The result of [`super::WorkspaceRegistry::admit_registry_intent`].
#[derive(Debug)]
pub(crate) enum Admission {
    /// The writer's durable lane holds the intent; `receipt` is the one
    /// decided at prepare. `sequence` orders admissions of one registry.
    Admitted { sequence: u64, receipt: RegistryReceipt },
    /// The intent committed before the call returned (a counted fallback);
    /// `receipt` is the committed one.
    Committed(RegistryReceipt),
}

impl Admission {
    /// The receipt the reply carries.
    pub(crate) fn into_receipt(self) -> RegistryReceipt {
        match self {
            Self::Admitted { receipt, .. } | Self::Committed(receipt) => receipt,
        }
    }

    /// The admit sequence, `None` for a committed fallback.
    pub(crate) fn sequence(&self) -> Option<u64> {
        match self {
            Self::Admitted { sequence, .. } => Some(*sequence),
            Self::Committed(_) => None,
        }
    }
}

/// Why a request committed and waited instead of being admitted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FallbackReason {
    /// The feature is off.
    Disabled,
    /// The journal writer does not run, or this is its thread.
    WriterNotRunning,
    /// This thread holds the registry connection (a pin or a guard).
    ConnectionHeld,
    /// The durable lane refused the intent (deadline, admission closed).
    NotQueued,
}

/// The revisions a receipt installs: what the writer's answer must repeat
/// for an admitted reply to stay true.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ReceiptRevisions {
    kind: ReceiptKind,
    revision: u64,
    resource_revision: Option<u64>,
    replayed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReceiptKind {
    Effect,
    Terminal,
    Workspace,
}

impl ReceiptRevisions {
    pub(crate) fn of(receipt: &RegistryReceipt) -> Self {
        match receipt {
            RegistryReceipt::Effect(receipt) => Self {
                kind: ReceiptKind::Effect,
                revision: receipt.revision(),
                resource_revision: Some(receipt.revision()),
                replayed: false,
            },
            RegistryReceipt::Terminal(commit) => Self {
                kind: ReceiptKind::Terminal,
                revision: commit.revision,
                resource_revision: None,
                replayed: commit.replayed,
            },
            RegistryReceipt::Workspace(receipt) => Self {
                kind: ReceiptKind::Workspace,
                revision: receipt.commit.revision,
                resource_revision: receipt.resource_revision,
                replayed: receipt.commit.replayed,
            },
        }
    }
}

/// An admitted intent's reply, kept with its receipt channel until the
/// writer answers.
#[derive(Debug)]
pub(crate) struct AdmittedReply {
    pub(super) sequence: u64,
    pub(super) replied: ReceiptRevisions,
}

impl AdmittedReply {
    /// The journal-degraded note for the writer's `answer`, `None` when the
    /// writer committed exactly what the reply said.
    pub(super) fn degraded_note(&self, answer: &Result<RegistryReceipt, String>) -> Option<String> {
        match answer {
            Ok(receipt) => {
                let committed = ReceiptRevisions::of(receipt);
                (committed != self.replied).then(|| {
                    format!(
                        "admitted registry commit {} committed {committed:?}; its reply said {:?}",
                        self.sequence, self.replied
                    )
                })
            }
            Err(error) => {
                Some(format!("admitted registry commit {} did not commit: {error}", self.sequence))
            }
        }
    }
}

/// The admit gate, sequence and counters of one registry connection.
#[derive(Debug, Default)]
pub(crate) struct AdmitState {
    enabled: AtomicBool,
    next_sequence: AtomicU64,
    /// Admitted intents whose writer answer nobody has taken yet; the read
    /// barrier's one-load fast path.
    unresolved: AtomicUsize,
    admitted: AtomicU64,
    fallbacks_disabled: AtomicU64,
    fallbacks_writer_not_running: AtomicU64,
    fallbacks_connection_held: AtomicU64,
    fallbacks_not_queued: AtomicU64,
    read_barrier_waits: AtomicU64,
    read_barrier_timeouts: AtomicU64,
    journal_degraded: AtomicU64,
    receipt_mismatches: AtomicU64,
}

/// [`AdmitState`]'s counters at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct AdmitStatsSnapshot {
    /// Intents admitted without waiting for the writer.
    pub(crate) admitted: u64,
    pub(crate) fallbacks_disabled: u64,
    pub(crate) fallbacks_writer_not_running: u64,
    pub(crate) fallbacks_connection_held: u64,
    pub(crate) fallbacks_not_queued: u64,
    /// Waits for an admitted intent's writer answer (cold reads, prepares).
    pub(crate) read_barrier_waits: u64,
    /// Read barriers that gave up at their bound and read without the answer.
    pub(crate) read_barrier_timeouts: u64,
    /// Admitted intents the journal does not hold as replied (an error, or a
    /// different receipt); the in-memory state kept the reply.
    pub(crate) journal_degraded: u64,
    /// Of those, receipts that differ from the reply.
    pub(crate) receipt_mismatches: u64,
    /// Admitted intents still without a taken writer answer.
    pub(crate) unresolved: u64,
}

impl AdmitState {
    /// From `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` (disable
    /// wins), for a mux no owner installs features on (tests); the owner sets
    /// its channel-resolved value at start (`install_daemon_features`).
    pub(crate) fn from_env() -> Self {
        let state = Self::default();
        state.enabled.store(cmux_features::listed_in_env(FEATURE), Ordering::Relaxed);
        state
    }

    pub(crate) fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    /// The owner's resolved [`FEATURE`], set once at start.
    pub(crate) fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub(crate) fn set_enabled_for_test(&self, enabled: bool) {
        self.set_enabled(enabled);
    }

    /// The next admit sequence, counted as admitted and unresolved.
    pub(super) fn admit(&self) -> u64 {
        self.admitted.fetch_add(1, Ordering::Relaxed);
        self.unresolved.fetch_add(1, Ordering::AcqRel);
        self.next_sequence.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// True while an admitted intent has no taken writer answer.
    pub(super) fn has_unresolved(&self) -> bool {
        self.unresolved.load(Ordering::Acquire) > 0
    }

    /// One admitted intent's answer was taken; `degraded` when the journal
    /// does not hold it as replied, `mismatch` when the receipt differs.
    pub(super) fn resolved(&self, degraded: bool, mismatch: bool) {
        self.unresolved.fetch_sub(1, Ordering::AcqRel);
        if degraded {
            self.journal_degraded.fetch_add(1, Ordering::Relaxed);
        }
        if mismatch {
            self.receipt_mismatches.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub(super) fn fell_back(&self, reason: FallbackReason) {
        let counter = match reason {
            FallbackReason::Disabled => &self.fallbacks_disabled,
            FallbackReason::WriterNotRunning => &self.fallbacks_writer_not_running,
            FallbackReason::ConnectionHeld => &self.fallbacks_connection_held,
            FallbackReason::NotQueued => &self.fallbacks_not_queued,
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    pub(super) fn barrier_waited(&self, timed_out: bool) {
        self.read_barrier_waits.fetch_add(1, Ordering::Relaxed);
        if timed_out {
            self.read_barrier_timeouts.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub(crate) fn snapshot(&self) -> AdmitStatsSnapshot {
        let load = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        AdmitStatsSnapshot {
            admitted: load(&self.admitted),
            fallbacks_disabled: load(&self.fallbacks_disabled),
            fallbacks_writer_not_running: load(&self.fallbacks_writer_not_running),
            fallbacks_connection_held: load(&self.fallbacks_connection_held),
            fallbacks_not_queued: load(&self.fallbacks_not_queued),
            read_barrier_waits: load(&self.read_barrier_waits),
            read_barrier_timeouts: load(&self.read_barrier_timeouts),
            journal_degraded: load(&self.journal_degraded),
            receipt_mismatches: load(&self.receipt_mismatches),
            unresolved: self.unresolved.load(Ordering::Acquire) as u64,
        }
    }
}
