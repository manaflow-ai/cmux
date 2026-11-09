//! Journal segment sealing (moved out of journal_extensions.rs): archiving a
//! journal prefix into compressed segments, the seal receipt, and the
//! incremental vacuum that hands the freed pages back.

use super::*;

impl WorkspaceRegistry {
    pub(crate) fn migrate_journal_auto_vacuum(&self) -> anyhow::Result<AutoVacuumMigration> {
        migrate_journal_auto_vacuum(&self.connection.get())
    }

    /// Returns up to 256 free pages; true while an incremental-vacuum
    /// registry still has free pages for a later call.
    pub(crate) fn incremental_journal_vacuum(&self) -> anyhow::Result<bool> {
        // Fresh registries opt into SQLite's incremental auto-vacuum. This is
        // intentionally a small step: journal sealing must release the
        // registry writer quickly even when a busy VM has many free pages.
        let db = self.connection.get();
        // SQLite frees one page per step of this pragma, so it must be stepped
        // until done: `execute_batch` steps once and freed a single page.
        let mut vacuum = db.prepare("PRAGMA incremental_vacuum(256)")?;
        let mut steps = vacuum.raw_query();
        while steps.next()?.is_some() {}
        drop(steps);
        drop(vacuum);
        // A legacy registry (auto_vacuum 0) keeps its free pages until it is
        // converted, so they are no work for a later call.
        let mode: i64 = db.query_row("PRAGMA auto_vacuum", [], |row| row.get(0))?;
        let free: i64 = db.query_row("PRAGMA freelist_count", [], |row| row.get(0))?;
        Ok(mode == 2 && free > 0)
    }

    pub(crate) fn journal_segments(&self) -> anyhow::Result<Vec<JournalSegment>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                    uncompressed_bytes, sha256, sealed_at_ms
             FROM journal_segments ORDER BY start_sequence ASC LIMIT ?1",
        )?;
        statement
            .query_map([JOURNAL_LIST_MAX_ITEMS as i64], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Vec<u8>>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            })?
            .map(|row| {
                let (id, start, end, count, codec, bytes, digest, sealed_at) = row?;
                Ok(JournalSegment {
                    segment_id: id,
                    start_sequence: u64::try_from(start)?,
                    end_sequence: u64::try_from(end)?,
                    record_count: u64::try_from(count)?,
                    codec,
                    uncompressed_bytes: u64::try_from(bytes)?,
                    sha256: encode_hex(&digest),
                    sealed_at_ms: u64::try_from(sealed_at)?,
                })
            })
            .collect()
    }

    pub(crate) fn journal_segments_end(&self) -> anyhow::Result<u64> {
        let end = self.connection.get().query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(u64::try_from(end)?)
    }

    pub(crate) fn begin_journal_segment_seal(
        &mut self,
        requested_through: u64,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalSegmentSealStart> {
        anyhow::ensure!(requested_through > 0, "segment through sequence must be positive");
        validate_identifier("journal segment origin", origin)?;
        validate_identifier("journal segment idempotency key", idempotency_key)?;
        let fingerprint: [u8; 32] = Sha256::digest(
            canonical_json(&json!({"through_sequence":requested_through.to_string()}))?.as_bytes(),
        )
        .into();
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(journal) = operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &fingerprint,
        )? {
            return Ok(JournalSegmentSealStart::Replay(journal_segment_receipt(
                &tx,
                origin,
                idempotency_key,
                journal,
            )?));
        }
        let head = journal_head(&tx)?;
        anyhow::ensure!(
            requested_through <= head,
            "segment through sequence is ahead of the journal"
        );
        let checkpoint_sequence = tx
            .query_row(
                "SELECT MAX(source_sequence) FROM journal_checkpoints
                 WHERE source_sequence <= ?1",
                [i64::try_from(requested_through)?],
                |row| row.get::<_, Option<i64>>(0),
            )?
            .map(u64::try_from)
            .transpose()?
            .context("no checkpoint exists at or before the requested segment boundary")?;
        let archived_end = tx.query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let archived_end = u64::try_from(archived_end)?;
        anyhow::ensure!(
            checkpoint_sequence > archived_end,
            "requested journal range is already sealed"
        );
        // A checkpoint can cover a very large prefix. Prepare and commit at
        // most one storage segment per call so terminal writers only wait for
        // a bounded delete/insert transaction; the caller can continue with
        // the same checkpoint on its next maintenance tick.
        let through_sequence = checkpoint_sequence
            .min(archived_end.saturating_add(JOURNAL_SEGMENT_RECORD_LIMIT as u64));
        tx.commit()?;
        Ok(JournalSegmentSealStart::Prepare(JournalSegmentSealPlan {
            requested_through,
            through_sequence,
            archived_end,
            fingerprint,
        }))
    }

    pub(crate) fn commit_journal_segment_seal(
        &mut self,
        prepared: PreparedJournalSegmentSeal,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<Option<JournalSegmentSealCommit>> {
        let PreparedJournalSegmentSeal { plan, segments: prepared_segments } = prepared;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(journal) = operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &plan.fingerprint,
        )? {
            return Ok(Some(journal_segment_receipt(&tx, origin, idempotency_key, journal)?));
        }
        let checkpoint_sequence = tx
            .query_row(
                "SELECT MAX(source_sequence) FROM journal_checkpoints
                 WHERE source_sequence <= ?1",
                [i64::try_from(plan.requested_through)?],
                |row| row.get::<_, Option<i64>>(0),
            )?
            .map(u64::try_from)
            .transpose()?;
        let archived_end = u64::try_from(tx.query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get::<_, i64>(0),
        )?)?;
        let through_sequence = checkpoint_sequence.map(|checkpoint| {
            checkpoint.min(archived_end.saturating_add(JOURNAL_SEGMENT_RECORD_LIMIT as u64))
        });
        if through_sequence != Some(plan.through_sequence) || archived_end != plan.archived_end {
            return Ok(None);
        }
        validate_prepared_journal_segments(&plan, &prepared_segments)?;
        let segments =
            prepared_segments.iter().map(|segment| segment.metadata.clone()).collect::<Vec<_>>();
        for segment in prepared_segments {
            let kinds = segment.kinds.clone();
            tx.execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms, actors_json
                 ) VALUES(?1, ?2, ?3, ?4, ?10, ?5, ?6, ?7, ?8, ?9)",
                params![
                    segment.metadata.segment_id,
                    i64::try_from(segment.metadata.start_sequence)?,
                    i64::try_from(segment.metadata.end_sequence)?,
                    i64::try_from(segment.metadata.record_count)?,
                    segment.compressed,
                    i64::try_from(segment.metadata.uncompressed_bytes)?,
                    segment.digest,
                    i64::try_from(segment.metadata.sealed_at_ms)?,
                    session_journal::segment_actors_json(
                        &tx,
                        segment.metadata.start_sequence,
                        segment.metadata.end_sequence,
                    )?,
                    segment.metadata.codec,
                ],
            )?;
            for kind in kinds {
                tx.execute(
                    "INSERT INTO journal_segment_kinds(segment_id, kind) VALUES(?1, ?2)",
                    params![segment.metadata.segment_id, kind],
                )?;
            }
        }
        tx.execute_batch("DROP TRIGGER IF EXISTS session_journal_reject_delete;")?;
        let deleted = tx.execute(
            "DELETE FROM session_journal WHERE sequence > ?1 AND sequence <= ?2",
            params![i64::try_from(plan.archived_end)?, i64::try_from(plan.through_sequence)?],
        )?;
        anyhow::ensure!(
            deleted == usize::try_from(plan.through_sequence - plan.archived_end)?,
            "journal segment source range changed before commit"
        );
        tx.execute_batch(
            "CREATE TRIGGER IF NOT EXISTS session_journal_reject_delete
             BEFORE DELETE ON session_journal
             BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )?;
        let now = unix_epoch_ms()?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![JournalSubject { kind: "session".into(), id: session_id }];
        let producer = JournalProducer { kind: "retention".into(), id: origin.into() };
        let event_id = random_event_id("segment");
        let payload = json!({
            "through_sequence":plan.through_sequence.to_string(),
            "segments":segments,
        });
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "journal.segment.sealed",
                class: JournalClass::Checkpoint,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(idempotency_key),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Metadata,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
                actor: None,
            },
        )?;
        let result = json!({
            "through_sequence":plan.through_sequence.to_string(),
            "segments":segments,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &plan.fingerprint,
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(Some(JournalSegmentSealCommit {
            through_sequence: plan.through_sequence,
            segments,
            journal: JournalAppendCommit { sequence, event_id, replayed: false },
        }))
    }
}

impl JournalSegmentSealPlan {
    pub(crate) fn prepare(
        self,
        reader: &SessionJournalReader,
    ) -> anyhow::Result<PreparedJournalSegmentSeal> {
        let sealed_at_ms = unix_epoch_ms()?;
        let mut cursor = self.archived_end;
        let mut segments = Vec::new();
        while cursor < self.through_sequence {
            let mut uncompressed =
                Vec::with_capacity(MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES.min(1024 * 1024));
            uncompressed.push(b'[');
            let mut start_sequence = None;
            let mut record_count = 0_u64;
            let mut kinds = BTreeSet::new();
            'segment: while cursor < self.through_sequence
                && record_count < u64::try_from(JOURNAL_SEGMENT_RECORD_LIMIT)?
            {
                let page = reader.after(cursor, 1024)?;
                let mut accepted = 0_usize;
                for record in page
                    .records
                    .into_iter()
                    .take_while(|record| record.sequence <= self.through_sequence)
                {
                    anyhow::ensure!(
                        record.sequence == cursor.saturating_add(1),
                        "journal segment range contains a gap before sequence {}",
                        record.sequence
                    );
                    let sequence = record.sequence;
                    let kind = record.kind.clone();
                    let record = session_journal::journal_record_for_archive(&record);
                    let record_bytes = serde_json::to_vec(&record)?;
                    anyhow::ensure!(
                        record_bytes.len().saturating_add(2)
                            <= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES,
                        "journal record {sequence} is too large to seal"
                    );
                    let separator = usize::from(record_count != 0);
                    if uncompressed
                        .len()
                        .saturating_add(separator)
                        .saturating_add(record_bytes.len())
                        .saturating_add(1)
                        > MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES
                    {
                        break 'segment;
                    }
                    kinds.insert(kind);
                    if separator != 0 {
                        uncompressed.push(b',');
                    }
                    uncompressed.extend_from_slice(&record_bytes);
                    start_sequence.get_or_insert(sequence);
                    cursor = sequence;
                    record_count += 1;
                    accepted += 1;
                    if record_count == u64::try_from(JOURNAL_SEGMENT_RECORD_LIMIT)? {
                        break 'segment;
                    }
                }
                anyhow::ensure!(
                    accepted != 0,
                    "journal segment range contains a gap after sequence {cursor}"
                );
            }
            uncompressed.push(b']');
            let start_sequence =
                start_sequence.context("journal segment range contains no records")?;
            let digest: [u8; 32] = Sha256::digest(&uncompressed).into();
            let digest_hex = encode_hex(&digest);
            let compressed = crate::workspace_registry::segment_codec::encode(&uncompressed)?;
            let segment_id = format!("segment_{start_sequence}_{cursor}_{digest_hex}");
            segments.push(PreparedJournalSegment {
                metadata: JournalSegment {
                    segment_id,
                    start_sequence,
                    end_sequence: cursor,
                    record_count,
                    codec: crate::workspace_registry::segment_codec::SEAL_CODEC.into(),
                    uncompressed_bytes: u64::try_from(uncompressed.len())?,
                    sha256: digest_hex,
                    sealed_at_ms,
                },
                compressed,
                digest,
                kinds: kinds.into_iter().collect(),
            });
        }
        validate_prepared_journal_segments(&self, &segments)?;
        Ok(PreparedJournalSegmentSeal { plan: self, segments })
    }
}

fn validate_prepared_journal_segments(
    plan: &JournalSegmentSealPlan,
    segments: &[PreparedJournalSegment],
) -> anyhow::Result<()> {
    anyhow::ensure!(!segments.is_empty(), "journal segment preparation produced no segments");
    let mut expected = plan.archived_end.saturating_add(1);
    for segment in segments {
        let metadata = &segment.metadata;
        anyhow::ensure!(
            metadata.start_sequence == expected && metadata.end_sequence >= expected,
            "prepared journal segments are not contiguous"
        );
        anyhow::ensure!(
            metadata.record_count
                == metadata.end_sequence.saturating_sub(metadata.start_sequence).saturating_add(1),
            "prepared journal segment record count is invalid"
        );
        anyhow::ensure!(
            metadata.codec == crate::workspace_registry::segment_codec::SEAL_CODEC
                && metadata.sha256 == encode_hex(&segment.digest)
                && metadata.uncompressed_bytes
                    <= u64::try_from(MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES)?,
            "prepared journal segment metadata is invalid"
        );
        anyhow::ensure!(!segment.compressed.is_empty(), "prepared journal segment is empty");
        expected = metadata.end_sequence.saturating_add(1);
    }
    anyhow::ensure!(
        expected == plan.through_sequence.saturating_add(1),
        "prepared journal segment range ended early"
    );
    Ok(())
}

fn journal_segment_receipt(
    transaction: &Transaction<'_>,
    origin: &str,
    idempotency_key: &str,
    journal: JournalAppendCommit,
) -> anyhow::Result<JournalSegmentSealCommit> {
    let result = transaction.query_row(
        "SELECT result_json FROM journal_operation_receipts
         WHERE operation = 'session.journal.segment.seal'
           AND origin = ?1 AND idempotency_key = ?2",
        params![origin, idempotency_key],
        |row| row.get::<_, String>(0),
    )?;
    let result: Value = serde_json::from_str(&result)?;
    let through_sequence = result["through_sequence"]
        .as_str()
        .context("segment receipt omitted through_sequence")?
        .parse()?;
    let segments = serde_json::from_value(result["segments"].clone())?;
    Ok(JournalSegmentSealCommit { through_sequence, segments, journal })
}
