use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock, Weak};
use std::time::Duration;

use base64::Engine;
use serde_json::{Value, json};

use crate::workspace_registry::SessionJournalReader;
use crate::{
    JournalClass, JournalIngress, JournalProducerManifest, JournalReplayPolicy, JournalSensitivity,
    SessionJournalRecord,
};

const JOURNAL_FANOUT_CAPACITY: usize = 8192;
const JOURNAL_FANOUT_BYTE_CAPACITY: usize = 128 * 1024 * 1024;
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
    shutdown_requested: bool,
    head_sequence: u64,
    records: VecDeque<Arc<JournalDocument>>,
    record_bytes: usize,
    available: bool,
    #[cfg(test)]
    database_reader_count: u64,
}

/// Session-local journal runtime. It owns the only persistent live-tail
/// SQLite reader and publishes a bounded ring of decoded records.
pub(crate) struct JournalKernel {
    state: Mutex<JournalFanoutState>,
    changed: Condvar,
    tailer: Mutex<Option<std::thread::JoinHandle<()>>>,
    enabled: bool,
    producers: RwLock<HashMap<String, Arc<CompiledJournalProducer>>>,
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
                enabled: false,
                producers: RwLock::new(producers),
            }));
        };

        let reader = SessionJournalReader::open(&database_path)?;
        let head_sequence = reader.after(0, 1)?.head_sequence;
        let kernel = Arc::new(Self {
            state: Mutex::new(JournalFanoutState {
                epoch: 0,
                requested_epoch: 0,
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
            enabled: true,
            producers: RwLock::new(producers),
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
        *kernel.tailer.lock().unwrap() = Some(tailer);
        Ok(())
    }

    pub(crate) const fn enabled(&self) -> bool {
        self.enabled
    }

    /// Wakes the tailer after the writer commits. No SQLite work or record
    /// decoding occurs on the mutation path.
    pub(crate) fn notify_commit(&self) {
        if !self.enabled {
            return;
        }
        let mut state = self.state.lock().unwrap();
        state.requested_epoch = state.requested_epoch.wrapping_add(1);
        self.changed.notify_all();
    }

    pub(crate) fn epoch(&self) -> u64 {
        self.state.lock().unwrap().epoch
    }

    pub(crate) fn wait(&self, epoch: u64, timeout: Duration) -> u64 {
        let state = self.state.lock().unwrap();
        if state.epoch != epoch {
            return state.epoch;
        }
        let (state, _) = self.changed.wait_timeout(state, timeout).unwrap();
        state.epoch
    }

    pub(crate) fn wake_waiters(&self) {
        let mut state = self.state.lock().unwrap();
        // The generation is the wait predicate. Advancing it makes a wake
        // observable even when the signal arrives just before wait() locks.
        state.epoch = state.epoch.wrapping_add(1);
        self.changed.notify_all();
    }

    pub(crate) fn shutdown(&self) {
        {
            let mut state = self.state.lock().unwrap();
            state.shutdown_requested = true;
            state.epoch = state.epoch.wrapping_add(1);
            self.changed.notify_all();
        }
        if let Some(tailer) = self.tailer.lock().unwrap().take()
            && tailer.join().is_err()
        {
            eprintln!("cmux-tui: session journal tailer panicked during shutdown");
        }
    }

    pub(crate) fn read_after(&self, sequence: u64, limit: usize) -> SharedJournalRead {
        if !self.enabled || limit == 0 {
            return SharedJournalRead::Unavailable;
        }
        let state = self.state.lock().unwrap();
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
        let mut producers = self.producers.write().unwrap();
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
            .unwrap()
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
        self.state.lock().unwrap().database_reader_count
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
    loop {
        let Some(kernel) = weak.upgrade() else { break };
        let requested_epoch = {
            let mut state = kernel.state.lock().unwrap();
            loop {
                if state.shutdown_requested {
                    return;
                }
                if state.requested_epoch != observed_request_epoch {
                    break state.requested_epoch;
                }
                let (next_state, waited) =
                    kernel.changed.wait_timeout(state, Duration::from_secs(1)).unwrap();
                state = next_state;
                if waited.timed_out() && !state.available {
                    break state.requested_epoch;
                }
            }
        };
        drop(kernel);
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
        let mut state = kernel.state.lock().unwrap();
        if state.shutdown_requested {
            return;
        }
        state.available = !read_failed;
        if !read_failed {
            for record in appended {
                let state = &mut *state;
                push_bounded_journal_document(&mut state.records, &mut state.record_bytes, record);
            }
            last_sequence = candidate_sequence;
            state.head_sequence = candidate_sequence;
        }
        state.epoch = state.epoch.wrapping_add(1);
        kernel.changed.notify_all();
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

#[cfg(test)]
mod performance_tests {
    use super::*;
    use crate::{
        JournalAuthority, JournalEventSchema, JournalProducer, JournalSubject, SessionJournalRecord,
    };
    use std::time::Instant;

    fn record(sequence: u64) -> SessionJournalRecord {
        SessionJournalRecord {
            sequence,
            event_id: format!("event_perf_{sequence:020}"),
            schema_version: 1,
            kind: "plugin.performance.output".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            occurred_at_ms: sequence,
            committed_at_ms: sequence,
            producer: JournalProducer { kind: "benchmark".into(), id: "benchmark".into() },
            authority: Some(JournalAuthority {
                principal_id: "client_performance".into(),
                lease_id: "benchmark".into(),
                generation: "1".into(),
                role: "benchmark".into(),
            }),
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject {
                kind: "terminal".into(),
                id: "term_00000000000000000000000000000001".into(),
            }],
            sensitivity: JournalSensitivity::Metadata,
            payload: json!({"message":"approval-42 is ready","padding":"x".repeat(256)}),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: None,
        }
    }

    fn producer_manifest() -> JournalProducerManifest {
        JournalProducerManifest {
            producer_id: "kernel_test".into(),
            namespace: "plugin.kernel_test".into(),
            manifest_version: 1,
            max_sensitivity: JournalSensitivity::Sensitive,
            permissions: vec!["journal.append.plugin.kernel_test".into()],
            events: vec![JournalEventSchema {
                kind: "plugin.kernel_test.event".into(),
                schema_version: 1,
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                sensitivity: JournalSensitivity::Sensitive,
                payload_schema: json!({"type":"object"}),
            }],
        }
    }

    #[test]
    fn persisted_secret_producer_manifests_fail_closed() {
        let mut manifest = producer_manifest();
        manifest.max_sensitivity = JournalSensitivity::Secret;
        let error = JournalKernel::new(None, &[manifest]).err().unwrap().to_string();
        assert!(error.contains("encrypted retention"), "{error}");
    }

    #[test]
    fn runtime_secret_sensitivity_overrides_fail_closed() {
        let manifest = producer_manifest();
        let kernel = JournalKernel::new(None, std::slice::from_ref(&manifest)).unwrap();
        let error = kernel
            .validate_ingress(&JournalIngress {
                producer_id: manifest.producer_id,
                manifest_version: manifest.manifest_version,
                kind: manifest.events[0].kind.clone(),
                schema_version: manifest.events[0].schema_version,
                occurred_at_ms: None,
                subjects: Vec::new(),
                sensitivity: Some(JournalSensitivity::Secret),
                payload: json!({}),
                causation_id: None,
                correlation_id: None,
            })
            .unwrap_err()
            .to_string();
        assert!(error.contains("encrypted retention"), "{error}");
    }

    fn linear_read_after(kernel: &JournalKernel, sequence: u64, limit: usize) -> SharedJournalRead {
        let state = kernel.state.lock().unwrap();
        let records: Vec<_> = state
            .records
            .iter()
            .filter(|record| record.record.sequence > sequence)
            .take(limit)
            .cloned()
            .collect();
        let scanned_through =
            records.last().map_or(state.head_sequence, |record| record.record.sequence);
        SharedJournalRead::Page(SharedJournalPage {
            head_sequence: state.head_sequence,
            scanned_through,
            records,
        })
    }

    #[test]
    fn journal_documents_materialize_search_fields_lazily() {
        let document = JournalDocument::new(record(1));
        assert!(document.wire_value.get().is_none());
        assert!(document.subjects_bytes.get().is_none());
        assert!(document.payload_bytes.get().is_none());
        assert!(document.record_bytes.get().is_none());
        assert!(document.wire_value.get().is_none());
        assert!(!document.subjects_bytes().is_empty());
        assert!(document.wire_value.get().is_none());
        assert!(document.subjects_bytes.get().is_some());
        assert!(document.payload_bytes.get().is_none());
        assert!(document.record_bytes.get().is_none());
    }

    #[test]
    fn explicit_wake_is_observable_even_before_a_waiter_sleeps() {
        let kernel = JournalKernel {
            state: Mutex::new(JournalFanoutState {
                epoch: 7,
                requested_epoch: 0,
                shutdown_requested: false,
                head_sequence: 0,
                records: VecDeque::new(),
                record_bytes: 0,
                available: true,
                database_reader_count: 0,
            }),
            changed: Condvar::new(),
            tailer: Mutex::new(None),
            enabled: true,
            producers: RwLock::new(HashMap::new()),
        };
        let observed = kernel.epoch();
        kernel.wake_waiters();
        assert_ne!(kernel.wait(observed, Duration::ZERO), observed);
    }

    #[test]
    fn journal_fanout_batches_are_bounded_before_publication() {
        let mut records = VecDeque::new();
        let mut record_bytes = 0;
        for sequence in 1..=JOURNAL_FANOUT_CAPACITY as u64 + 137 {
            push_bounded_journal_document(
                &mut records,
                &mut record_bytes,
                Arc::new(JournalDocument::new(record(sequence))),
            );
        }
        assert_eq!(records.len(), JOURNAL_FANOUT_CAPACITY);
        assert_eq!(records.front().unwrap().record.sequence, 138);
        assert_eq!(records.back().unwrap().record.sequence, JOURNAL_FANOUT_CAPACITY as u64 + 137);
        assert_eq!(
            record_bytes,
            records.iter().map(|record| record.resident_bytes()).sum::<usize>()
        );
    }

    #[test]
    #[ignore = "manual release-mode journal performance probe"]
    fn journal_tail_cache_performance_probe() {
        let started = Instant::now();
        let records = (1..=JOURNAL_FANOUT_CAPACITY as u64)
            .map(record)
            .map(JournalDocument::new)
            .map(Arc::new)
            .collect::<VecDeque<_>>();
        let construction = started.elapsed();
        let record_bytes = records.iter().map(|record| record.resident_bytes()).sum();
        let kernel = JournalKernel {
            state: Mutex::new(JournalFanoutState {
                epoch: 1,
                requested_epoch: 1,
                shutdown_requested: false,
                head_sequence: JOURNAL_FANOUT_CAPACITY as u64,
                records,
                record_bytes,
                available: true,
                database_reader_count: 0,
            }),
            changed: Condvar::new(),
            tailer: Mutex::new(None),
            enabled: true,
            producers: RwLock::new(HashMap::new()),
        };

        let iterations = 100_000_u64;
        let cursor = JOURNAL_FANOUT_CAPACITY as u64 - 1;
        let started = Instant::now();
        let mut linear_observed = 0_u64;
        for _ in 0..iterations {
            if let SharedJournalRead::Page(page) =
                linear_read_after(std::hint::black_box(&kernel), cursor, 1)
            {
                linear_observed += page.records.len() as u64;
            }
        }
        let linear_reads = started.elapsed();
        let started = Instant::now();
        let mut observed = 0_u64;
        for _ in 0..iterations {
            if let SharedJournalRead::Page(page) =
                std::hint::black_box(&kernel).read_after(cursor, 1)
            {
                observed += page.records.len() as u64;
            }
        }
        let reads = started.elapsed();
        eprintln!(
            "journal tail cache: build {} lazy documents in {construction:?}; linear {iterations} near-tail reads in {linear_reads:?} ({:.0} reads/s); indexed in {reads:?} ({:.0} reads/s), {:.1}x faster",
            JOURNAL_FANOUT_CAPACITY,
            iterations as f64 / linear_reads.as_secs_f64(),
            iterations as f64 / reads.as_secs_f64(),
            linear_reads.as_secs_f64() / reads.as_secs_f64(),
        );
        assert_eq!(linear_observed, iterations);
        assert_eq!(observed, iterations);
    }
}
