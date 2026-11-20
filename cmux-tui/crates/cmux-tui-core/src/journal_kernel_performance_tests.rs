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
    let state = kernel.state.lock().recover_poison();
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
            published_epoch: 0,
            shutdown_requested: false,
            head_sequence: 0,
            records: VecDeque::new(),
            record_bytes: 0,
            available: true,
            database_reader_count: 0,
        }),
        changed: Condvar::new(),
        tailer: Mutex::new(None),
        #[cfg(test)]
        tailer_hold: Mutex::new(None),
        enabled: true,
        producers: RwLock::new(HashMap::new()),
        database_path: None,
    };
    let observed = kernel.epoch();
    kernel.wake_waiters();
    assert_ne!(kernel.wait(observed, Duration::ZERO), observed);
}

/// A tailer batch over the byte cap keeps only its newest records; the
/// ring must not keep its older records beside them with a hole between
/// (a caught-up reader then skipped the shed records with no Gap; the
/// 4 MiB cap makes such a batch common). Several payload sizes, as the
/// hole depended on how many old records fit beside the batch.
#[test]
fn a_batch_trimmed_by_the_cap_leaves_no_hole_a_reader_could_skip() {
    for padding in [16 * 1024, 40 * 1024, 60 * 1024, 87 * 1024] {
        let kernel = JournalKernel {
            state: Mutex::new(JournalFanoutState {
                epoch: 0,
                requested_epoch: 0,
                published_epoch: 0,
                shutdown_requested: false,
                head_sequence: 0,
                records: VecDeque::new(),
                record_bytes: 0,
                available: true,
                database_reader_count: 0,
            }),
            changed: Condvar::new(),
            tailer: Mutex::new(None),
            #[cfg(test)]
            tailer_hold: Mutex::new(None),
            enabled: true,
            producers: RwLock::new(HashMap::new()),
            database_path: None,
        };
        let big = |sequence: u64| {
            let mut record = record(sequence);
            record.payload = json!({"padding": "x".repeat(padding)});
            Arc::new(JournalDocument::new(record))
        };
        {
            let mut state = kernel.state.lock().unwrap();
            // A caught-up ring: 1..=10, small records.
            let first: VecDeque<_> =
                (1..=10).map(|sequence| Arc::new(JournalDocument::new(record(sequence)))).collect();
            publish_journal_batch(&mut state, first, 0);
            state.head_sequence = 10;
            // One batch 11..=200, read while the tailer was late, bounded
            // as it was read.
            let mut batch = VecDeque::new();
            let mut batch_bytes = 0;
            for sequence in 11..=200 {
                push_bounded_journal_document(&mut batch, &mut batch_bytes, big(sequence));
            }
            publish_journal_batch(&mut state, batch, 10);
            state.head_sequence = 200;
            let sequences: Vec<u64> = state.records.iter().map(|doc| doc.record.sequence).collect();
            assert!(
                sequences.windows(2).all(|pair| pair[1] == pair[0] + 1),
                "padding {padding}: the ring has a hole: {sequences:?}"
            );
        }
        // A reader caught up to 10 gets a Gap (it pages from SQLite), or
        // a page that starts exactly at 11: never a later record.
        match kernel.read_after(10, 4) {
            SharedJournalRead::Gap { .. } => {}
            SharedJournalRead::Page(page) => assert_eq!(
                page.records.first().map(|doc| doc.record.sequence),
                Some(11),
                "padding {padding}: a reader at 10 skipped records"
            ),
            SharedJournalRead::Unavailable => panic!("unavailable"),
        }
    }
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
    // Whichever bound binds first (the byte cap, for these records), the
    // ring holds the newest records, contiguous, within both bounds.
    let newest = JOURNAL_FANOUT_CAPACITY as u64 + 137;
    assert!(records.len() <= JOURNAL_FANOUT_CAPACITY);
    assert!(record_bytes <= JOURNAL_FANOUT_BYTE_CAPACITY);
    assert_eq!(records.back().unwrap().record.sequence, newest);
    assert_eq!(
        records.front().unwrap().record.sequence,
        newest + 1 - records.len() as u64,
        "the ring is not the newest contiguous records"
    );
    assert_eq!(record_bytes, records.iter().map(|record| record.resident_bytes()).sum::<usize>());
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
            published_epoch: 1,
            shutdown_requested: false,
            head_sequence: JOURNAL_FANOUT_CAPACITY as u64,
            records,
            record_bytes,
            available: true,
            database_reader_count: 0,
        }),
        changed: Condvar::new(),
        tailer: Mutex::new(None),
        #[cfg(test)]
        tailer_hold: Mutex::new(None),
        enabled: true,
        producers: RwLock::new(HashMap::new()),
        database_path: None,
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
        if let SharedJournalRead::Page(page) = std::hint::black_box(&kernel).read_after(cursor, 1) {
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
