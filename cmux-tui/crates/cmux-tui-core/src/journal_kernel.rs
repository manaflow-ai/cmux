use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, RwLock, Weak};
use std::time::Duration;

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
    wire_value: Value,
    subjects_bytes: Vec<u8>,
    payload_bytes: Vec<u8>,
    record_bytes: Vec<u8>,
}

impl JournalDocument {
    pub(crate) fn new(record: SessionJournalRecord) -> Self {
        let mut subjects_bytes = Vec::new();
        for subject in &record.subjects {
            if !subjects_bytes.is_empty() {
                subjects_bytes.push(0);
            }
            subjects_bytes.extend_from_slice(subject.kind.as_bytes());
            subjects_bytes.push(b':');
            subjects_bytes.extend_from_slice(subject.id.as_bytes());
        }
        let payload_bytes = serde_json::to_vec(&record.payload)
            .expect("session journal payloads are already validated JSON");
        let wire_value = journal_record_value(&record);
        let record_bytes = serde_json::to_vec(&wire_value)
            .expect("session journal wire records are always serializable JSON");
        Self { record, wire_value, subjects_bytes, payload_bytes, record_bytes }
    }

    pub(crate) fn wire_value(&self) -> &Value {
        &self.wire_value
    }

    pub(crate) fn subjects_bytes(&self) -> &[u8] {
        &self.subjects_bytes
    }

    pub(crate) fn payload_bytes(&self) -> &[u8] {
        &self.payload_bytes
    }

    pub(crate) fn record_bytes(&self) -> &[u8] {
        &self.record_bytes
    }

    fn resident_bytes(&self) -> usize {
        self.record_bytes.len().saturating_mul(3).saturating_add(self.subjects_bytes.len())
    }
}

fn journal_record_value(record: &SessionJournalRecord) -> Value {
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
        "payload":record.payload,
        "resource_revision":record.resource_revision.map(|value| value.to_string()),
        "previous_resource_revision":record
            .previous_resource_revision
            .map(|value| value.to_string()),
    })
}

pub(crate) struct SharedJournalPage {
    pub(crate) head_sequence: u64,
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
                    head_sequence: 0,
                    records: VecDeque::new(),
                    record_bytes: 0,
                    available: false,
                    #[cfg(test)]
                    database_reader_count: 0,
                }),
                changed: Condvar::new(),
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
                head_sequence,
                records: VecDeque::new(),
                record_bytes: 0,
                available: true,
                #[cfg(test)]
                database_reader_count: 1,
            }),
            changed: Condvar::new(),
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
        std::thread::Builder::new()
            .name("mux-session-journal-fanout".into())
            .spawn(move || run_tailer(weak, reader, head_sequence))?;
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
        let records = state
            .records
            .iter()
            .filter(|record| record.record.sequence > sequence)
            .take(limit)
            .cloned()
            .collect();
        SharedJournalRead::Page(SharedJournalPage { head_sequence: state.head_sequence, records })
    }

    pub(crate) fn install_producer(
        &self,
        manifest: &JournalProducerManifest,
    ) -> anyhow::Result<()> {
        let compiled = compile_journal_producer(manifest)?;
        self.producers.write().unwrap().insert(manifest.producer_id.clone(), Arc::new(compiled));
        Ok(())
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
    'tailer: loop {
        let Some(kernel) = weak.upgrade() else { break };
        let requested_epoch = {
            let mut state = kernel.state.lock().unwrap();
            loop {
                if state.requested_epoch != observed_request_epoch {
                    break Some(state.requested_epoch);
                }
                let (next_state, waited) =
                    kernel.changed.wait_timeout(state, Duration::from_secs(1)).unwrap();
                state = next_state;
                if waited.timed_out() {
                    break None;
                }
            }
        };
        drop(kernel);
        let Some(requested_epoch) = requested_epoch else {
            if weak.strong_count() == 0 {
                return;
            }
            continue 'tailer;
        };
        observed_request_epoch = requested_epoch;

        let mut appended = Vec::new();
        let mut read_failed = false;
        loop {
            match reader.after(last_sequence, JOURNAL_READ_PAGE_SIZE) {
                Ok(page) => {
                    if page.records.is_empty() {
                        break;
                    }
                    for record in page.records {
                        last_sequence = record.sequence;
                        appended.push(Arc::new(JournalDocument::new(record)));
                    }
                    if last_sequence >= page.head_sequence {
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
        state.available = !read_failed;
        if !read_failed {
            for record in appended {
                state.record_bytes = state.record_bytes.saturating_add(record.resident_bytes());
                state.records.push_back(record);
                while state.records.len() > JOURNAL_FANOUT_CAPACITY
                    || (state.records.len() > 1
                        && state.record_bytes > JOURNAL_FANOUT_BYTE_CAPACITY)
                {
                    if let Some(removed) = state.records.pop_front() {
                        state.record_bytes =
                            state.record_bytes.saturating_sub(removed.resident_bytes());
                    }
                }
            }
            state.head_sequence = last_sequence;
        }
        state.epoch = state.epoch.wrapping_add(1);
        kernel.changed.notify_all();
    }
}
