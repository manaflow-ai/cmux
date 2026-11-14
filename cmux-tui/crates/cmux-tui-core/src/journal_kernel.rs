use crate::panic_free::RecoverPoison;
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock, Weak};
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{Value, json};

use crate::workspace_registry::SessionJournalReader;
use crate::{
    JournalClass, JournalIngress, JournalProducerManifest, JournalReplayPolicy, JournalSensitivity,
    SessionJournalRecord,
};

/// The live ring keeps the newest records decoded for the subscribers that
/// keep up; a subscriber behind it pages from SQLite on a reader of its own
/// (`SharedJournalRead::Gap`), as Chrome keeps bounded in-memory history
/// and pages the rest. Both bounds hold: at most this many records, and at
/// most [`JOURNAL_FANOUT_BYTE_CAPACITY`] of resident bytes (the soak lead of
/// 2026-10-28: agent turns' 8 KiB texts grew a 128 MiB-capped ring
/// ~4.4 MB/h in a daemon that should stay small).
const JOURNAL_FANOUT_CAPACITY: usize = 8192;
const JOURNAL_FANOUT_BYTE_CAPACITY: usize = 4 * 1024 * 1024;
const JOURNAL_READ_PAGE_SIZE: usize = 1024;

/// One decoded journal record shared by every live subscriber.
///
/// Search documents and the public wire value are built once when the tailer
/// observes the commit. Catch-up readers use the same representation, but
/// their documents remain private to that one catch-up path.
pub(crate) struct JournalDocument {
    pub(crate) record: SessionJournalRecord,
    wire_value: OnceLock<Value>,
    subjects_bytes: OnceLock<Vec<u8>>,
    payload_bytes: OnceLock<Result<Vec<u8>, serde_json::Error>>,
    record_bytes: OnceLock<Result<Vec<u8>, serde_json::Error>>,
    resident_budget_bytes: usize,
}

impl JournalDocument {
    pub(crate) fn new(record: SessionJournalRecord) -> Self {
        let resident_budget_bytes = journal_document_resident_budget(&record);
        Self {
            record,
            wire_value: OnceLock::new(),
            subjects_bytes: OnceLock::new(),
            payload_bytes: OnceLock::new(),
            record_bytes: OnceLock::new(),
            resident_budget_bytes,
        }
    }

    pub(crate) fn wire_value(&self) -> &Value {
        self.wire_value.get_or_init(|| journal_record_value(&self.record))
    }

    pub(crate) fn subjects_bytes(&self) -> &[u8] {
        self.subjects_bytes
            .get_or_init(|| {
                let mut subjects = Vec::new();
                for subject in &self.record.subjects {
                    if !subjects.is_empty() {
                        subjects.push(0);
                    }
                    subjects.extend_from_slice(subject.kind.as_bytes());
                    subjects.push(b':');
                    subjects.extend_from_slice(subject.id.as_bytes());
                }
                subjects
            })
            .as_slice()
    }

    pub(crate) fn payload_bytes(&self) -> Option<&[u8]> {
        self.payload_bytes
            .get_or_init(|| serde_json::to_vec(&self.record.payload))
            .as_ref()
            .ok()
            .map(Vec::as_slice)
    }

    pub(crate) fn record_bytes(&self) -> Option<&[u8]> {
        self.record_bytes
            .get_or_init(|| serde_json::to_vec(self.wire_value()))
            .as_ref()
            .ok()
            .map(Vec::as_slice)
    }

    pub(crate) fn terminal_output_bytes(&self) -> Option<&[u8]> {
        self.record.terminal_output.as_deref()
    }

    fn resident_bytes(&self) -> usize {
        self.resident_budget_bytes
    }
}

/// Conservatively accounts for the decoded record and every lazy search/wire
/// representation without allocating those representations on the tail path.
fn journal_document_resident_budget(record: &SessionJournalRecord) -> usize {
    let subject_bytes = record.subjects.iter().fold(0_usize, |bytes, subject| {
        bytes.saturating_add(subject.kind.len()).saturating_add(subject.id.len()).saturating_add(2)
    });
    let string_bytes = record
        .event_id
        .len()
        .saturating_add(record.kind.len())
        .saturating_add(record.producer.kind.len())
        .saturating_add(record.producer.id.len())
        .saturating_add(record.causation_id.as_ref().map_or(0, String::len))
        .saturating_add(record.correlation_id.as_ref().map_or(0, String::len))
        .saturating_add(subject_bytes);
    let content_bytes = record.terminal_output.as_ref().map_or(0, |content| content.len());
    let inline_content_upper_bound =
        content_bytes.saturating_add(2).saturating_div(3).saturating_mul(4).saturating_add(64);
    let wire_upper_bound = string_bytes
        .saturating_add(json_encoded_upper_bound(&record.payload))
        .saturating_add(inline_content_upper_bound)
        .saturating_add(2048);
    // The record can own one decoded payload, one lazy wire Value clone, and
    // three byte documents (payload, subjects, whole record). JSON strings can
    // expand to six bytes per input byte when escaped, which the estimator
    // already includes.
    wire_upper_bound.saturating_mul(4).saturating_add(subject_bytes).saturating_add(content_bytes)
}

fn json_encoded_upper_bound(value: &Value) -> usize {
    match value {
        Value::Null => 4,
        Value::Bool(_) => 5,
        Value::Number(_) => 32,
        Value::String(value) => value.len().saturating_mul(6).saturating_add(2),
        Value::Array(values) => values.iter().fold(2_usize, |bytes, value| {
            bytes.saturating_add(1).saturating_add(json_encoded_upper_bound(value))
        }),
        Value::Object(values) => values.iter().fold(2_usize, |bytes, (key, value)| {
            bytes
                .saturating_add(2)
                .saturating_add(key.len().saturating_mul(6))
                .saturating_add(2)
                .saturating_add(json_encoded_upper_bound(value))
        }),
    }
}

fn journal_record_value(record: &SessionJournalRecord) -> Value {
    let mut payload = record.payload.clone();
    if let Some(bytes) = record.terminal_output.as_deref()
        && let Some(payload) = payload.as_object_mut()
    {
        payload.insert("encoding".into(), Value::String("base64".into()));
        payload.insert(
            "data".into(),
            Value::String(base64::engine::general_purpose::STANDARD.encode(bytes)),
        );
    }
    json!({
        "sequence":record.sequence.to_string(),
        "event_id":record.event_id,
        "schema_version":record.schema_version,
        "kind":record.kind,
        "class":record.class,
        "replay":record.replay,
        "occurred_at_ms":record.occurred_at_ms.to_string(),
        "committed_at_ms":record.committed_at_ms.to_string(),
        "producer":record.producer,
        "authority":record.authority,
        "causation_id":record.causation_id,
        "correlation_id":record.correlation_id,
        "causation_depth":record.causation_depth,
        "subjects":record.subjects,
        "sensitivity":record.sensitivity,
        "payload":payload,
        "resource_revision":record.resource_revision.map(|value| value.to_string()),
        "previous_resource_revision":record
            .previous_resource_revision
            .map(|value| value.to_string()),
    })
}

pub(crate) struct SharedJournalPage {
    pub(crate) head_sequence: u64,
    pub(crate) scanned_through: u64,
    pub(crate) records: Vec<Arc<JournalDocument>>,
}

pub(crate) enum SharedJournalRead {
    Page(SharedJournalPage),
    Gap { _oldest_sequence: u64, _head_sequence: u64 },
    Unavailable,
}

struct JournalFanoutState {
    epoch: u64,
    requested_epoch: u64,
    /// The `requested_epoch` the tailer last read through and published: while it is behind,
    /// a commit already acknowledged to its writer may be missing from the ring.
    published_epoch: u64,
    shutdown_requested: bool,
    head_sequence: u64,
    records: VecDeque<Arc<JournalDocument>>,
    record_bytes: usize,
    available: bool,
    #[cfg(test)]
    database_reader_count: u64,
}

/// Tests: the tailer's gate, closed while the flag is true.
#[cfg(test)]
type TailerGate = Arc<(Mutex<bool>, Condvar)>;

/// Tests: releases the tailer held by [`JournalKernel::hold_tailer_for_test`] on drop.
#[cfg(test)]
pub(crate) struct TailerHold {
    kernel: Arc<JournalKernel>,
    hold: TailerGate,
}

#[cfg(test)]
impl Drop for TailerHold {
    fn drop(&mut self) {
        *self.kernel.tailer_hold.lock().recover_poison() = None;
        let (held, released) = &*self.hold;
        *held.lock().recover_poison() = false;
        released.notify_all();
    }
}

/// Session-local journal runtime. It owns the only persistent live-tail
/// SQLite reader and publishes a bounded ring of decoded records.
pub(crate) struct JournalKernel {
    state: Mutex<JournalFanoutState>,
    changed: Condvar,
    tailer: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// Tests: while set, the tailer waits here before each read pass, so the ring trails the
    /// writer's commits on purpose.
    #[cfg(test)]
    tailer_hold: Mutex<Option<TailerGate>>,
    enabled: bool,
    producers: RwLock<HashMap<String, Arc<CompiledJournalProducer>>>,
    /// The registry file, so a reader behind the ring opens its own
    /// read-only connection without the registry lock.
    database_path: Option<PathBuf>,
}

struct CompiledJournalProducer {
    manifest_version: u32,
    max_sensitivity: JournalSensitivity,
    events: HashMap<(String, u32), CompiledJournalEvent>,
}

struct CompiledJournalEvent {
    class: JournalClass,
    replay: JournalReplayPolicy,
    sensitivity: JournalSensitivity,
    validator: jsonschema::Validator,
}

pub(crate) struct PreparedJournalProducer {
    producer_id: String,
    compiled: Arc<CompiledJournalProducer>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ValidatedJournalIngress {
    pub(crate) class: JournalClass,
    pub(crate) replay: JournalReplayPolicy,
    pub(crate) sensitivity: JournalSensitivity,
}

impl JournalKernel {
    pub(crate) fn new(
        database_path: Option<PathBuf>,
        manifests: &[JournalProducerManifest],
    ) -> anyhow::Result<Arc<Self>> {
        let producers = compile_journal_producers(manifests)?;
        let Some(database_path) = database_path else {
            return Ok(Arc::new(Self {
                state: Mutex::new(JournalFanoutState {
                    epoch: 0,
                    requested_epoch: 0,
                    published_epoch: 0,
                    shutdown_requested: false,
                    head_sequence: 0,
                    records: VecDeque::new(),
                    record_bytes: 0,
                    available: false,
                    #[cfg(test)]
                    database_reader_count: 0,
                }),
                changed: Condvar::new(),
                tailer: Mutex::new(None),
                #[cfg(test)]
                tailer_hold: Mutex::new(None),
                enabled: false,
                producers: RwLock::new(producers),
                database_path: None,
            }));
        };

        let reader = SessionJournalReader::open(&database_path)?;
        let head_sequence = reader.head()?;
        let kernel = Arc::new(Self {
            state: Mutex::new(JournalFanoutState {
                epoch: 0,
                requested_epoch: 0,
                published_epoch: 0,
                shutdown_requested: false,
                head_sequence,
                records: VecDeque::new(),
                record_bytes: 0,
                available: true,
                #[cfg(test)]
                database_reader_count: 1,
            }),
            changed: Condvar::new(),
            tailer: Mutex::new(None),
            #[cfg(test)]
            tailer_hold: Mutex::new(None),
            enabled: true,
            producers: RwLock::new(producers),
            database_path: Some(database_path),
        });
        Self::start_tailer(&kernel, reader, head_sequence)?;
        Ok(kernel)
    }

    fn start_tailer(
        kernel: &Arc<Self>,
        reader: SessionJournalReader,
        head_sequence: u64,
    ) -> anyhow::Result<()> {
        let weak = Arc::downgrade(kernel);
        let tailer = std::thread::Builder::new()
            .name("mux-session-journal-fanout".into())
            .spawn(move || run_tailer(weak, reader, head_sequence))?;
        *kernel.tailer.lock().recover_poison() = Some(tailer);
        Ok(())
    }

    /// The registry file this kernel reads, `None` in memory.
    pub(crate) fn database_path(&self) -> Option<&std::path::Path> {
        self.database_path.as_deref()
    }

    pub(crate) const fn enabled(&self) -> bool {
        self.enabled
    }

    /// A new read-only journal reader on its own connection, for a consumer
    /// whose cursor fell behind the ring (a [`SharedJournalRead::Gap`]).
    /// It takes no registry lock, so a long catch-up never stalls writers.
    /// `None` for an in-memory registry.
    pub(crate) fn open_reader(&self) -> anyhow::Result<Option<SessionJournalReader>> {
        self.database_path.as_deref().map(SessionJournalReader::open).transpose()
    }

    /// Wakes the tailer after the writer commits. No SQLite work or record
    /// decoding occurs on the mutation path.
    pub(crate) fn notify_commit(&self) {
        if !self.enabled {
            return;
        }
        let mut state = self.state.lock().recover_poison();
        state.requested_epoch = state.requested_epoch.wrapping_add(1);
        self.changed.notify_all();
    }

    /// Whether the ring holds every commit acknowledged so far: false while the tailer has
    /// not yet read through the last [`Self::notify_commit`]. A reader that must see a
    /// commit its caller already saw acknowledged (`history.entries.list` after an agent
    /// hook) reads the database instead of the ring until then.
    pub(crate) fn ring_is_current(&self) -> bool {
        let state = self.state.lock().recover_poison();
        state.published_epoch == state.requested_epoch
    }

    /// Tests: hold the tailer before its next read pass until the returned guard drops.
    #[cfg(test)]
    pub(crate) fn hold_tailer_for_test(self: &Arc<Self>) -> TailerHold {
        let hold = Arc::new((Mutex::new(true), Condvar::new()));
        *self.tailer_hold.lock().recover_poison() = Some(hold.clone());
        TailerHold { kernel: self.clone(), hold }
    }

    pub(crate) fn epoch(&self) -> u64 {
        self.state.lock().recover_poison().epoch
    }

    /// Like `wait`, but `None` waits with no timeout (a real deadline or
    /// nothing, never a poll period).
    pub(crate) fn wait_until(&self, epoch: u64, deadline: Option<Instant>) -> u64 {
        let mut state = self.state.lock().recover_poison();
        while state.epoch == epoch {
            match deadline {
                None => {
                    state = self.changed.wait(state).recover_poison();
                }
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        break;
                    };
                    state = self.changed.wait_timeout(state, remaining).recover_poison().0;
                }
            }
        }
        state.epoch
    }

    pub(crate) fn wait(&self, epoch: u64, timeout: Duration) -> u64 {
        let state = self.state.lock().recover_poison();
        if state.epoch != epoch {
            return state.epoch;
        }
        let (state, _) = self.changed.wait_timeout(state, timeout).recover_poison();
        state.epoch
    }

    /// Like `wait`, with no timeout: returns the new epoch, or `epoch`
    /// once `interrupt` has fired.
    pub(crate) fn wait_until_interrupted(
        &self,
        epoch: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> u64 {
        let mut state = self.state.lock().recover_poison();
        while state.epoch == epoch && !interrupt.is_fired() {
            state = self.changed.wait(state).recover_poison();
        }
        state.epoch
    }

    /// Wakes every waiter without changing the epoch (an interrupt fired).
    pub(crate) fn notify_waiters(&self) {
        let _state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        self.changed.notify_all();
    }

    pub(crate) fn wake_waiters(&self) {
        let mut state = self.state.lock().recover_poison();
        // The generation is the wait predicate. Advancing it makes a wake
        // observable even when the signal arrives just before wait() locks.
        state.epoch = state.epoch.wrapping_add(1);
        self.changed.notify_all();
    }

    pub(crate) fn shutdown(&self) {
        {
            let mut state = self.state.lock().recover_poison();
            state.shutdown_requested = true;
            state.epoch = state.epoch.wrapping_add(1);
            self.changed.notify_all();
        }
        if let Some(tailer) = self.tailer.lock().recover_poison().take()
            && tailer.join().is_err()
        {
            eprintln!("cmux-tui: session journal tailer panicked during shutdown");
        }
    }

    pub(crate) fn read_after(&self, sequence: u64, limit: usize) -> SharedJournalRead {
        if !self.enabled || limit == 0 {
            return SharedJournalRead::Unavailable;
        }
        let state = self.state.lock().recover_poison();
        if !state.available {
            return SharedJournalRead::Unavailable;
        }
        let Some(oldest_sequence) = state.records.front().map(|record| record.record.sequence)
        else {
            return if sequence < state.head_sequence {
                SharedJournalRead::Gap {
                    _oldest_sequence: state.head_sequence.saturating_add(1),
                    _head_sequence: state.head_sequence,
                }
            } else {
                SharedJournalRead::Page(SharedJournalPage {
                    head_sequence: state.head_sequence,
                    scanned_through: state.head_sequence,
                    records: Vec::new(),
                })
            };
        };
        if sequence.saturating_add(1) < oldest_sequence {
            return SharedJournalRead::Gap {
                _oldest_sequence: oldest_sequence,
                _head_sequence: state.head_sequence,
            };
        }
        let next_sequence = sequence.saturating_add(1);
        let start = usize::try_from(next_sequence.saturating_sub(oldest_sequence))
            .unwrap_or(state.records.len())
            .min(state.records.len());
        let end = start.saturating_add(limit).min(state.records.len());
        let records: Vec<_> = state.records.range(start..end).cloned().collect();
        let scanned_through =
            records.last().map_or(state.head_sequence, |record| record.record.sequence);
        SharedJournalRead::Page(SharedJournalPage {
            head_sequence: state.head_sequence,
            scanned_through,
            records,
        })
    }

    pub(crate) fn prepare_producer(
        manifest: &JournalProducerManifest,
    ) -> anyhow::Result<PreparedJournalProducer> {
        Ok(PreparedJournalProducer {
            producer_id: manifest.producer_id.clone(),
            compiled: Arc::new(compile_journal_producer(manifest)?),
        })
    }

    pub(crate) fn install_prepared_producer(&self, producer: PreparedJournalProducer) {
        let mut producers = self.producers.write().recover_poison();
        if producers
            .get(&producer.producer_id)
            .is_some_and(|current| current.manifest_version > producer.compiled.manifest_version)
        {
            return;
        }
        producers.insert(producer.producer_id, producer.compiled);
    }

    pub(crate) fn validate_ingress(
        &self,
        ingress: &JournalIngress,
    ) -> anyhow::Result<ValidatedJournalIngress> {
        let producer = self
            .producers
            .read()
            .recover_poison()
            .get(&ingress.producer_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("journal producer is not installed"))?;
        anyhow::ensure!(
            ingress.manifest_version == producer.manifest_version,
            "journal producer manifest version is not current"
        );
        let event =
            producer.events.get(&(ingress.kind.clone(), ingress.schema_version)).ok_or_else(
                || anyhow::anyhow!("journal event kind or schema version is not declared"),
            )?;
        let sensitivity = ingress.sensitivity.unwrap_or(event.sensitivity);
        anyhow::ensure!(
            sensitivity != JournalSensitivity::Secret,
            "secret journal payload storage is unavailable until encrypted retention is implemented"
        );
        anyhow::ensure!(
            sensitivity_rank(sensitivity) <= sensitivity_rank(producer.max_sensitivity),
            "journal event sensitivity exceeds producer authority"
        );
        if let Err(error) = event.validator.validate(&ingress.payload) {
            anyhow::bail!("journal event payload does not match its schema: {error}");
        }
        Ok(ValidatedJournalIngress { class: event.class, replay: event.replay, sensitivity })
    }

    #[cfg(test)]
    pub(crate) fn database_reader_count(&self) -> u64 {
        self.state.lock().recover_poison().database_reader_count
    }
}

fn compile_journal_producers(
    manifests: &[JournalProducerManifest],
) -> anyhow::Result<HashMap<String, Arc<CompiledJournalProducer>>> {
    manifests
        .iter()
        .map(|manifest| {
            Ok((manifest.producer_id.clone(), Arc::new(compile_journal_producer(manifest)?)))
        })
        .collect()
}

fn compile_journal_producer(
    manifest: &JournalProducerManifest,
) -> anyhow::Result<CompiledJournalProducer> {
    anyhow::ensure!(
        manifest.max_sensitivity != JournalSensitivity::Secret
            && manifest.events.iter().all(|event| event.sensitivity != JournalSensitivity::Secret),
        "secret journal payload storage is unavailable until encrypted retention is implemented"
    );
    let events = manifest
        .events
        .iter()
        .map(|event| {
            Ok((
                (event.kind.clone(), event.schema_version),
                CompiledJournalEvent {
                    class: event.class,
                    replay: event.replay,
                    sensitivity: event.sensitivity,
                    validator: jsonschema::validator_for(&event.payload_schema)?,
                },
            ))
        })
        .collect::<anyhow::Result<HashMap<_, _>>>()?;
    Ok(CompiledJournalProducer {
        manifest_version: manifest.manifest_version,
        max_sensitivity: manifest.max_sensitivity,
        events,
    })
}

fn sensitivity_rank(value: JournalSensitivity) -> u8 {
    match value {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

fn run_tailer(weak: Weak<JournalKernel>, reader: SessionJournalReader, mut last_sequence: u64) {
    let mut observed_request_epoch = 0;
    // After a failed read the tailer retries with capped backoff; otherwise
    // it waits for a commit or shutdown. It used to wake every second.
    let mut retry =
        crate::backoff::Backoff::new(Duration::from_millis(100), Duration::from_secs(5));
    let mut retry_at: Option<Instant> = None;
    loop {
        let Some(kernel) = weak.upgrade() else { break };
        let requested_epoch = {
            let mut state = kernel.state.lock().recover_poison();
            loop {
                if state.shutdown_requested {
                    return;
                }
                if state.requested_epoch != observed_request_epoch {
                    break state.requested_epoch;
                }
                if state.available {
                    retry_at = None;
                    state = kernel.changed.wait(state).recover_poison();
                    continue;
                }
                let deadline = *retry_at.get_or_insert_with(|| Instant::now() + retry.next_delay());
                let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                    retry_at = None;
                    break state.requested_epoch;
                };
                state = kernel.changed.wait_timeout(state, remaining).recover_poison().0;
            }
        };
        #[cfg(test)]
        let hold = kernel.tailer_hold.lock().recover_poison().clone();
        drop(kernel);
        #[cfg(test)]
        if let Some(hold) = hold {
            let (held, released) = &*hold;
            let mut held = held.lock().recover_poison();
            while *held {
                held = released.wait(held).recover_poison();
            }
        }
        observed_request_epoch = requested_epoch;

        let mut appended = VecDeque::new();
        let mut appended_bytes = 0;
        let mut read_failed = false;
        let mut candidate_sequence = last_sequence;
        loop {
            match reader.after(candidate_sequence, JOURNAL_READ_PAGE_SIZE) {
                Ok(page) => {
                    if page.records.is_empty() {
                        break;
                    }
                    for record in page.records {
                        candidate_sequence = record.sequence;
                        push_bounded_journal_document(
                            &mut appended,
                            &mut appended_bytes,
                            Arc::new(JournalDocument::new(record)),
                        );
                    }
                    if candidate_sequence >= page.head_sequence {
                        break;
                    }
                }
                Err(_) => {
                    read_failed = true;
                    break;
                }
            }
        }

        let Some(kernel) = weak.upgrade() else { break };
        let mut state = kernel.state.lock().recover_poison();
        if state.shutdown_requested {
            return;
        }
        state.available = !read_failed;
        if !read_failed {
            retry.reset();
            publish_journal_batch(&mut state, appended, last_sequence);
            last_sequence = candidate_sequence;
            state.head_sequence = candidate_sequence;
            // Every commit requested before this pass's read is in the ring now.
            state.published_epoch = requested_epoch;
        }
        state.epoch = state.epoch.wrapping_add(1);
        kernel.changed.notify_all();
    }
}

/// Appends one tailer batch read after `last_sequence` to the live ring.
/// The batch itself was bounded while it was read, so it may start past
/// `last_sequence + 1` (a batch over the byte cap kept only its newest
/// records): the ring then drops every older record first. The ring must
/// stay contiguous, because `read_after` finds a sequence by its position;
/// a reader behind the batch's first record then gets a `Gap` and pages
/// from SQLite, instead of silently skipping the records the batch shed.
fn publish_journal_batch(
    state: &mut JournalFanoutState,
    appended: VecDeque<Arc<JournalDocument>>,
    last_sequence: u64,
) {
    if appended
        .front()
        .is_some_and(|first| first.record.sequence != last_sequence.saturating_add(1))
    {
        state.records.clear();
        state.record_bytes = 0;
    }
    for record in appended {
        push_bounded_journal_document(&mut state.records, &mut state.record_bytes, record);
    }
}

fn push_bounded_journal_document(
    records: &mut VecDeque<Arc<JournalDocument>>,
    record_bytes: &mut usize,
    record: Arc<JournalDocument>,
) {
    *record_bytes = record_bytes.saturating_add(record.resident_bytes());
    records.push_back(record);
    while records.len() > JOURNAL_FANOUT_CAPACITY
        || (records.len() > 1 && *record_bytes > JOURNAL_FANOUT_BYTE_CAPACITY)
    {
        if let Some(removed) = records.pop_front() {
            *record_bytes = record_bytes.saturating_sub(removed.resident_bytes());
        }
    }
}

impl JournalKernel {
    /// Tests: the ring's records and their resident bytes.
    #[cfg(test)]
    pub(crate) fn ring_for_test(&self) -> (usize, usize) {
        let state = self.state.lock().recover_poison();
        (state.records.len(), state.record_bytes)
    }
}

#[cfg(test)]
#[path = "journal_kernel_ring_tests.rs"]
mod ring_tests;

#[cfg(test)]
mod performance_tests;
