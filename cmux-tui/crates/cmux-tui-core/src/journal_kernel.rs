use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use crate::SessionJournalRecord;
use crate::workspace_registry::SessionJournalReader;

const JOURNAL_FANOUT_CAPACITY: usize = 8192;
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
}

impl JournalKernel {
    pub(crate) fn new(database_path: Option<PathBuf>) -> anyhow::Result<Arc<Self>> {
        let Some(database_path) = database_path else {
            return Ok(Arc::new(Self {
                state: Mutex::new(JournalFanoutState {
                    epoch: 0,
                    requested_epoch: 0,
                    head_sequence: 0,
                    records: VecDeque::new(),
                    available: false,
                    #[cfg(test)]
                    database_reader_count: 0,
                }),
                changed: Condvar::new(),
                enabled: false,
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
                available: true,
                #[cfg(test)]
                database_reader_count: 1,
            }),
            changed: Condvar::new(),
            enabled: true,
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

    #[cfg(test)]
    pub(crate) fn database_reader_count(&self) -> u64 {
        self.state.lock().unwrap().database_reader_count
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
                state.records.push_back(record);
                if state.records.len() > JOURNAL_FANOUT_CAPACITY {
                    state.records.pop_front();
                }
            }
            state.head_sequence = last_sequence;
        }
        state.epoch = state.epoch.wrapping_add(1);
        kernel.changed.notify_all();
    }
}
