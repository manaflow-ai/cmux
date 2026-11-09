//! Test seams for kind-scoped journal reads: raw records and a VM step count.

use super::*;

/// One record a test appends as its writer would.
#[derive(Clone)]
pub(crate) struct TestJournalRecord {
    pub(crate) kind: String,
    pub(crate) producer: JournalProducer,
    pub(crate) subjects: Vec<JournalSubject>,
    pub(crate) payload: Value,
}

impl WorkspaceRegistry {
    /// Test seam: append `records` to the active journal in one transaction,
    /// as their writers would. Returns their sequences.
    pub(crate) fn append_journal_records_for_test(
        &self,
        records: &[TestJournalRecord],
    ) -> Vec<u64> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        let sequences = records
            .iter()
            .map(|record| {
                let event_id = format!("event_test_{}", new_uuid_v4().replace('-', ""));
                append_journal_record(
                    &tx,
                    &JournalAppend {
                        event_id: &event_id,
                        schema_version: 1,
                        kind: &record.kind,
                        class: JournalClass::Observation,
                        replay: JournalReplayPolicy::Advisory,
                        occurred_at_ms: 1,
                        producer: &record.producer,
                        authority: None,
                        causation_id: None,
                        correlation_id: None,
                        causation_depth: 0,
                        subjects: &record.subjects,
                        sensitivity: JournalSensitivity::Metadata,
                        payload: &record.payload,
                        content: None,
                        resource_revision: None,
                        previous_resource_revision: None,
                        actor: None,
                    },
                )
                .unwrap()
            })
            .collect();
        tx.commit().unwrap();
        sequences
    }

    /// SQLite VM steps `run` takes on the registry connection, counted in
    /// batches of 16 (deterministic, unlike wall time; see open_cost_tests.rs).
    /// `run` takes the connection itself, through the registry.
    pub(crate) fn vm_steps_for_test(&self, run: impl FnOnce()) -> u64 {
        let steps = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter = Arc::clone(&steps);
        self.connection
            .get()
            .progress_handler(
                16,
                Some(move || {
                    counter.fetch_add(16, std::sync::atomic::Ordering::Relaxed);
                    false
                }),
            )
            .unwrap();
        run();
        self.connection.get().progress_handler(0, None::<fn() -> bool>).unwrap();
        steps.load(std::sync::atomic::Ordering::Relaxed)
    }
}
