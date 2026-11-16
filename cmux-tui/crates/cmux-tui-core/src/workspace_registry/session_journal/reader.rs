//! Read-only journal snapshots and bounded restore cursors.

use super::*;

impl SessionJournalReader {
    pub(crate) fn open(database_path: &Path) -> anyhow::Result<Self> {
        let connection = open_registry_database_with_flags(
            database_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| format!("open session journal reader {}", database_path.display()))?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA query_only=ON; PRAGMA foreign_keys=ON;")?;
        Ok(Self { connection })
    }

    /// One page after `sequence`. Like every multi-statement read on this
    /// connection, it reads in one read transaction: the head, the sealed
    /// segments and the active rows come from one snapshot, so a seal that
    /// commits on the registry connection between two of them (moving
    /// records from the active table into a segment) cannot show as a gap.
    pub(crate) fn after(&self, sequence: u64, limit: usize) -> anyhow::Result<SessionJournalPage> {
        let snapshot = self.connection.unchecked_transaction()?;
        query_session_journal_after(&snapshot, sequence, limit)
    }

    /// The resource events after `revision`, read on this reader's own
    /// read-only connection (no registry lock) in one read transaction.
    /// `generation` is the registry's, which never changes while it is open.
    pub(crate) fn resource_events_after(
        &self,
        generation: &str,
        revision: u64,
    ) -> anyhow::Result<ResourceEventPage> {
        let snapshot = self.connection.unchecked_transaction()?;
        resource_store::query_resource_events_after(&snapshot, generation, revision)
    }

    /// One subject-filtered page, in one read transaction (see [`Self::after`]).
    pub(crate) fn after_subjects(
        &self,
        sequence: u64,
        limit: usize,
        subjects: &[JournalSubject],
    ) -> anyhow::Result<SessionJournalSubjectPage> {
        let snapshot = self.connection.unchecked_transaction()?;
        query_session_journal_after_subjects(&snapshot, sequence, limit, subjects)
    }

    pub(crate) fn restore_cursor(
        self,
        source_sequence: u64,
    ) -> anyhow::Result<JournalRestoreCursor> {
        self.connection.execute_batch("BEGIN DEFERRED TRANSACTION")?;
        let target_head = query_journal_head(&self.connection)?;
        anyhow::ensure!(
            source_sequence <= target_head,
            "cursor.invalid: journal sequence {source_sequence} is ahead of {target_head}"
        );
        Ok(JournalRestoreCursor {
            connection: self.connection,
            source_sequence,
            target_head,
            next_segment_start: -1,
            segments_exhausted: false,
            decoded_segment: None,
            record_offset: 0,
            active_sequence: source_sequence,
            previous_segment_end: None,
            finished: false,
            #[cfg(test)]
            segment_decode_count: 0,
            #[cfg(test)]
            segment_content_load_count: 0,
        })
    }
}

impl JournalRestoreCursor {
    pub(crate) fn next_page(&mut self, limit: usize) -> anyhow::Result<SessionJournalPage> {
        anyhow::ensure!(!self.finished, "journal restore cursor is finished");
        anyhow::ensure!(limit > 0, "journal page limit must be positive");
        anyhow::ensure!(
            limit <= MAX_JOURNAL_PAGE_SIZE,
            "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
        );
        let mut records = Vec::with_capacity(limit);
        while records.len() < limit {
            if let Some(decoded) = self.decoded_segment.as_ref() {
                if self.record_offset == decoded.records.len() {
                    self.decoded_segment = None;
                    self.record_offset = 0;
                    continue;
                }
                let record = decoded.records[self.record_offset].clone();
                self.record_offset += 1;
                if record.sequence <= self.source_sequence {
                    continue;
                }
                if record.sequence > self.target_head {
                    break;
                }
                self.validate_and_advance(record, &mut records)?;
                continue;
            }

            let Some(segment_id) = self.next_segment()? else {
                break;
            };
            self.note_segment_decoded();
            let row = self.load_segment(&segment_id)?;
            let decoded = decode_journal_segment(&self.connection, row)?;
            if let Some(previous_end) = self.previous_segment_end {
                anyhow::ensure!(
                    decoded.start_sequence == previous_end + 1,
                    "journal segments contain a gap before sequence {}",
                    decoded.start_sequence
                );
            } else {
                anyhow::ensure!(
                    decoded.start_sequence <= self.source_sequence.saturating_add(1),
                    "journal segments contain a gap before sequence {}",
                    decoded.start_sequence
                );
            }
            self.previous_segment_end = Some(decoded.end_sequence);
            self.decoded_segment = Some(decoded);
        }

        if records.len() < limit {
            let remaining = limit - records.len();
            let mut statement = self.connection.prepare(
                "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                        occurred_at_ms, committed_at_ms, producer_json, authority_json,
                        causation_id, correlation_id, causation_depth, subjects_json,
                        sensitivity, payload_json, content, resource_revision,
                        previous_resource_revision
                 FROM session_journal
                 WHERE sequence > ?1 AND sequence <= ?2
                 ORDER BY sequence ASC
                 LIMIT ?3",
            )?;
            let active = statement
                .query_map(
                    params![
                        i64::try_from(self.active_sequence)?,
                        i64::try_from(self.target_head)?,
                        i64::try_from(remaining)?,
                    ],
                    stored_record_row,
                )?
                .map(|row| decode_record(row?))
                .collect::<anyhow::Result<Vec<_>>>()?;
            drop(statement);
            for record in active {
                self.validate_and_advance(record, &mut records)?;
            }
        }
        anyhow::ensure!(
            self.active_sequence == self.target_head
                || !records.is_empty()
                || pruned_gap(
                    &self.connection,
                    self.active_sequence,
                    self.target_head.saturating_add(1)
                )?,
            "session journal contains a gap after sequence {}",
            self.active_sequence
        );
        Ok(SessionJournalPage { head_sequence: self.target_head, records })
    }

    fn next_segment(&mut self) -> anyhow::Result<Option<String>> {
        if self.segments_exhausted {
            return Ok(None);
        }
        let mut statement = self.connection.prepare(
            "SELECT segment_id, start_sequence
             FROM journal_segments
             WHERE end_sequence > ?1 AND start_sequence > ?2
             ORDER BY end_sequence ASC
             LIMIT 1",
        )?;
        let segment = statement
            .query_row(
                params![i64::try_from(self.source_sequence)?, self.next_segment_start,],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?;
        let Some((segment_id, start_sequence)) = segment else {
            self.segments_exhausted = true;
            return Ok(None);
        };
        self.next_segment_start = start_sequence;
        Ok(Some(segment_id))
    }

    #[cfg(test)]
    fn note_segment_decoded(&mut self) {
        self.segment_decode_count += 1;
    }

    #[cfg(not(test))]
    fn note_segment_decoded(&mut self) {}

    fn load_segment(&mut self, segment_id: &str) -> anyhow::Result<JournalSegmentRow> {
        self.note_segment_content_loaded();
        let mut statement = self.connection.prepare(
            "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                    content, uncompressed_bytes, sha256
             FROM journal_segments
             WHERE segment_id = ?1
               AND length(content) <= ?2",
        )?;
        statement
            .query_row(
                params![segment_id, i64::try_from(MAX_JOURNAL_SEGMENT_COMPRESSED_BYTES)?],
                journal_segment_row,
            )
            .with_context(|| format!("load journal segment {segment_id}"))
    }

    #[cfg(test)]
    fn note_segment_content_loaded(&mut self) {
        self.segment_content_load_count += 1;
    }

    #[cfg(not(test))]
    fn note_segment_content_loaded(&mut self) {}

    fn validate_and_advance(
        &mut self,
        record: SessionJournalRecord,
        records: &mut Vec<SessionJournalRecord>,
    ) -> anyhow::Result<()> {
        let expected = self.active_sequence.saturating_add(1);
        anyhow::ensure!(
            record.sequence == expected
                || (record.sequence > expected
                    && pruned_gap(&self.connection, self.active_sequence, record.sequence)?),
            "session journal contains a gap before sequence {}",
            record.sequence
        );
        self.active_sequence = record.sequence;
        records.push(record);
        Ok(())
    }

    /// Every sequence after `last` through the head is a pruned range.
    pub(crate) fn tail_is_pruned(&self, last: u64) -> anyhow::Result<bool> {
        pruned_gap(&self.connection, last, self.target_head.saturating_add(1))
    }

    pub(crate) fn finish(mut self) -> anyhow::Result<()> {
        self.finished = true;
        self.connection.execute_batch("COMMIT")?;
        Ok(())
    }
}
