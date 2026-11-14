//! Journal hooks (moved out of journal_extensions.rs): hook manifests, the
//! delivery schedule, and the journal events each delivery attempt records.

use super::*;

impl WorkspaceRegistry {
    pub(crate) fn journal_hook_states(&self) -> anyhow::Result<Vec<JournalHookState>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT manifest_json, enabled, cursor_sequence
             FROM journal_hooks
             WHERE enabled = 1
             ORDER BY hook_id ASC, manifest_version ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })?
            .map(|row| {
                let (manifest, enabled, cursor) = row?;
                Ok(JournalHookState {
                    manifest: serde_json::from_str(&manifest)?,
                    cursor_sequence: u64::try_from(cursor)
                        .context("hook cursor sequence is negative")?,
                    enabled: enabled != 0,
                })
            })
            .collect()
    }

    pub(crate) fn journal_events_caused_by_hooks(
        &self,
        hook_ids: &[String],
        event_ids: &[String],
    ) -> anyhow::Result<HashSet<(String, String)>> {
        if hook_ids.is_empty() || event_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let hook_ids = canonical_json(&serde_json::to_value(hook_ids)?)?;
        let event_ids = canonical_json(&serde_json::to_value(event_ids)?)?;
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT causal_hook_id, event_id
             FROM journal_event_index
             WHERE causal_hook_id IN (SELECT value FROM json_each(?1))
               AND event_id IN (SELECT value FROM json_each(?2))",
        )?;
        statement
            .query_map(params![hook_ids, event_ids], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<HashSet<_>, _>>()
            .map_err(Into::into)
    }

    pub(crate) fn put_journal_hook(
        &mut self,
        manifest: &JournalHookManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalAppendCommit> {
        validate_journal_hook_manifest(manifest)?;
        validate_identifier("journal hook origin", origin)?;
        validate_identifier("journal hook idempotency key", idempotency_key)?;
        let manifest_value = serde_json::to_value(manifest)?;
        let fingerprint = Sha256::digest(canonical_json(&manifest_value)?.as_bytes());
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(commit) = operation_receipt(
            &tx,
            "session.journal.hook.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )? {
            return Ok(commit);
        }
        let latest = tx
            .query_row(
                "SELECT manifest_version, manifest_json
                 FROM journal_hooks WHERE hook_id = ?1
                 ORDER BY manifest_version DESC LIMIT 1",
                [&manifest.hook_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((version, stored)) = latest {
            let version = u32::try_from(version).context("hook manifest version is invalid")?;
            anyhow::ensure!(
                manifest.manifest_version > version
                    || (manifest.manifest_version == version
                        && canonical_json(&serde_json::from_str(&stored)?)?
                            == canonical_json(&manifest_value)?),
                "journal hook manifest versions must increase"
            );
        }
        let head = journal_head(&tx)?;
        let cursor = if manifest.delivery.start == "beginning" { 0 } else { head };
        let now = unix_epoch_ms()?;
        tx.execute(
            "INSERT INTO journal_hooks(
               hook_id, manifest_version, manifest_json, enabled, cursor_sequence, installed_at_ms
             ) VALUES(?1, ?2, ?3, 1, ?4, ?5)
             ON CONFLICT(hook_id, manifest_version) DO UPDATE SET
               manifest_json=excluded.manifest_json,
               enabled=1",
            params![
                manifest.hook_id,
                i64::from(manifest.manifest_version),
                canonical_json(&manifest_value)?,
                i64::try_from(cursor)?,
                i64::try_from(now)?,
            ],
        )?;
        tx.execute(
            "UPDATE journal_hooks SET enabled = 0
             WHERE hook_id = ?1 AND manifest_version <> ?2",
            params![manifest.hook_id, i64::from(manifest.manifest_version)],
        )?;
        // The dispatcher runs deliveries of the enabled version only, and a
        // replaced version is never enabled again (versions only increase).
        // Its deliveries that still wait can never run: they end here, so
        // that none of them holds the journal's retention floor for ever. One
        // that executes now is left to the dispatcher, which finishes it.
        tx.execute(
            "UPDATE journal_hook_deliveries
             SET state = 'abandoned', completed_at_ms = ?3,
                 error = 'the hook version was replaced'
             WHERE hook_id = ?1 AND manifest_version <> ?2 AND state = 'scheduled'",
            params![manifest.hook_id, i64::from(manifest.manifest_version), i64::try_from(now)?],
        )?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![
            JournalSubject { kind: "session".into(), id: session_id },
            JournalSubject { kind: "hook".into(), id: manifest.hook_id.clone() },
        ];
        let producer = JournalProducer { kind: "journal_admin".into(), id: origin.into() };
        let event_id = random_event_id("hook_manifest");
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "hook.manifest.installed",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(idempotency_key),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &manifest_value,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
                actor: None,
            },
        )?;
        let result = json!({
            "hook_id":manifest.hook_id,
            "manifest_version":manifest.manifest_version,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.hook.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(JournalAppendCommit { sequence, event_id, replayed: false })
    }

    pub(crate) fn schedule_journal_hook_deliveries(
        &mut self,
        scans: &[JournalHookScan],
    ) -> anyhow::Result<Vec<bool>> {
        if scans.is_empty() {
            return Ok(Vec::new());
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let now = unix_epoch_ms()?;
        let applied = {
            let mut read_cursor = tx.prepare(
                "SELECT cursor_sequence FROM journal_hooks
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND enabled = 1",
            )?;
            let mut insert_delivery = tx.prepare(
                "INSERT OR IGNORE INTO journal_hook_deliveries(
                   hook_id, manifest_version, event_id, event_sequence, attempt, state,
                   next_attempt_at_ms, scheduled_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, 0, 'scheduled', ?5, ?5)",
            )?;
            let mut advance_cursor = tx.prepare(
                "UPDATE journal_hooks SET cursor_sequence = ?3
                 WHERE hook_id = ?1 AND manifest_version = ?2",
            )?;
            let mut applied = Vec::with_capacity(scans.len());
            for scan in scans {
                anyhow::ensure!(
                    scan.scanned_to > scan.expected_cursor,
                    "journal hook scan must advance its cursor"
                );
                let current = read_cursor
                    .query_row(params![scan.hook_id, i64::from(scan.manifest_version)], |row| {
                        row.get::<_, i64>(0)
                    })
                    .optional()?;
                if current.map(u64::try_from).transpose()? != Some(scan.expected_cursor) {
                    applied.push(false);
                    continue;
                }
                for (event_id, sequence) in &scan.matches {
                    insert_delivery.execute(params![
                        scan.hook_id,
                        i64::from(scan.manifest_version),
                        event_id,
                        i64::try_from(*sequence)?,
                        i64::try_from(now)?,
                    ])?;
                }
                advance_cursor.execute(params![
                    scan.hook_id,
                    i64::from(scan.manifest_version),
                    i64::try_from(scan.scanned_to)?,
                ])?;
                applied.push(true);
            }
            applied
        };
        tx.commit()?;
        Ok(applied)
    }

    /// The earliest `next_attempt_at_ms` of a scheduled delivery of an
    /// enabled hook: the dispatcher's next retry deadline.
    pub(crate) fn next_journal_hook_attempt_at_ms(&self) -> anyhow::Result<Option<u64>> {
        let next: Option<i64> = self.connection.get().query_row(
            "SELECT MIN(d.next_attempt_at_ms)
             FROM journal_hook_deliveries d
             JOIN journal_hooks h
               ON h.hook_id = d.hook_id AND h.manifest_version = d.manifest_version
             WHERE h.enabled = 1 AND d.state = 'scheduled'",
            [],
            |row| row.get(0),
        )?;
        Ok(next.map(|value| u64::try_from(value).unwrap_or(0)))
    }

    pub(crate) fn pending_journal_hook_deliveries(
        &self,
        now_ms: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<JournalHookDelivery>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "WITH pending AS (
               SELECT h.manifest_json, d.event_sequence, d.attempt,
                      CAST(json_extract(h.manifest_json, '$.exec.max_parallel') AS INTEGER)
                        AS max_parallel,
                      ROW_NUMBER() OVER (
                        PARTITION BY d.hook_id, d.manifest_version
                        ORDER BY d.event_sequence ASC
                      ) AS hook_slot
               FROM journal_hook_deliveries d
               JOIN journal_hooks h
                 ON h.hook_id = d.hook_id AND h.manifest_version = d.manifest_version
               WHERE h.enabled = 1
                 AND d.state IN ('scheduled','executing')
                 AND d.next_attempt_at_ms <= ?1
             )
             SELECT manifest_json, event_sequence, attempt
             FROM pending
             WHERE hook_slot <= max_parallel
             ORDER BY event_sequence ASC
             LIMIT ?2",
        )?;
        let rows = statement
            .query_map(params![i64::try_from(now_ms)?, i64::try_from(limit)?], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let sequences = rows
            .iter()
            .map(|(_, sequence, _)| u64::try_from(*sequence))
            .collect::<Result<Vec<_>, _>>()?;
        let events = query_session_journal_sequences(&self.connection.get(), &sequences)?
            .into_iter()
            .map(|event| (event.sequence, event))
            .collect::<HashMap<_, _>>();
        rows.into_iter()
            .map(|(manifest, sequence, attempt)| {
                let sequence = u64::try_from(sequence)?;
                let event = events
                    .get(&sequence)
                    .cloned()
                    .context("hook delivery event is absent from the journal")?;
                Ok(JournalHookDelivery {
                    manifest: serde_json::from_str(&manifest)?,
                    event,
                    attempt: u16::try_from(attempt).context("hook attempt is invalid")?,
                })
            })
            .collect()
    }

    pub(crate) fn start_journal_hook_deliveries(
        &mut self,
        deliveries: &[JournalHookDelivery],
    ) -> anyhow::Result<Vec<JournalHookAttempt>> {
        if deliveries.is_empty() {
            return Ok(Vec::new());
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let now = unix_epoch_ms()?;
        let mut attempts = Vec::with_capacity(deliveries.len());
        for delivery in deliveries {
            let attempt = delivery.attempt.checked_add(1).context("hook attempt overflow")?;
            let changed = tx.execute(
                "UPDATE journal_hook_deliveries
                 SET state = 'executing', attempt = ?4, started_at_ms = ?5,
                     completed_at_ms = NULL, exit_code = NULL, error = NULL
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                   AND state IN ('scheduled','executing')",
                params![
                    delivery.manifest.hook_id,
                    i64::from(delivery.manifest.manifest_version),
                    delivery.event.event_id,
                    i64::from(attempt),
                    i64::try_from(now)?,
                ],
            )?;
            anyhow::ensure!(changed == 1, "hook delivery is no longer pending");
            let (_, causation_id) = append_hook_delivery_event(
                &tx,
                "hook.delivery.started",
                delivery,
                attempt,
                json!({"attempt":attempt}),
                now,
            )?;
            tx.execute(
                "UPDATE journal_hook_deliveries
                 SET started_event_id = ?4
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3",
                params![
                    delivery.manifest.hook_id,
                    i64::from(delivery.manifest.manifest_version),
                    delivery.event.event_id,
                    causation_id,
                ],
            )?;
            attempts.push(JournalHookAttempt { attempt, causation_id });
        }
        tx.commit()?;
        Ok(attempts)
    }

    pub(crate) fn finish_journal_hook_deliveries(
        &mut self,
        results: &[JournalHookDeliveryResult],
    ) -> anyhow::Result<()> {
        if results.is_empty() {
            return Ok(());
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let now = unix_epoch_ms()?;
        for result in results {
            let delivery = &result.delivery;
            let attempt = result.attempt;
            let exit_code = result.exit_code;
            let error = result.error.as_deref();
            let success = error.is_none() && exit_code == Some(0);
            if success {
                let changed = tx.execute(
                    "UPDATE journal_hook_deliveries
                     SET state = 'completed', completed_at_ms = ?5, exit_code = ?6, error = NULL
                     WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                       AND state = 'executing' AND attempt = ?4",
                    params![
                        delivery.manifest.hook_id,
                        i64::from(delivery.manifest.manifest_version),
                        delivery.event.event_id,
                        i64::from(attempt),
                        i64::try_from(now)?,
                        exit_code,
                    ],
                )?;
                anyhow::ensure!(changed == 1, "hook delivery attempt is no longer executing");
                append_hook_delivery_event(
                    &tx,
                    "hook.delivery.completed",
                    delivery,
                    attempt,
                    json!({"attempt":attempt,"exit_code":exit_code}),
                    now,
                )?;
            } else {
                let exhausted = attempt >= delivery.manifest.delivery.retry.max_attempts;
                let next_attempt_at = now.saturating_add(
                    delivery.manifest.delivery.retry.backoff_ms.saturating_mul(u64::from(attempt)),
                );
                let changed = tx.execute(
                    "UPDATE journal_hook_deliveries
                     SET state = ?5, next_attempt_at_ms = ?6, completed_at_ms = ?7,
                         exit_code = ?8, error = ?9
                     WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                       AND state = 'executing' AND attempt = ?4",
                    params![
                        delivery.manifest.hook_id,
                        i64::from(delivery.manifest.manifest_version),
                        delivery.event.event_id,
                        i64::from(attempt),
                        if exhausted { "abandoned" } else { "scheduled" },
                        i64::try_from(next_attempt_at)?,
                        i64::try_from(now)?,
                        exit_code,
                        error,
                    ],
                )?;
                anyhow::ensure!(changed == 1, "hook delivery attempt is no longer executing");
                append_hook_delivery_event(
                    &tx,
                    "hook.delivery.failed",
                    delivery,
                    attempt,
                    json!({"attempt":attempt,"exit_code":exit_code,"error":error,"retrying":!exhausted}),
                    now,
                )?;
                if exhausted {
                    append_hook_delivery_event(
                        &tx,
                        "hook.delivery.abandoned",
                        delivery,
                        attempt,
                        json!({"attempt":attempt,"exit_code":exit_code,"error":error}),
                        now,
                    )?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }
}

fn append_hook_delivery_event(
    transaction: &Transaction<'_>,
    kind: &str,
    delivery: &JournalHookDelivery,
    attempt: u16,
    payload: Value,
    occurred_at_ms: u64,
) -> anyhow::Result<(u64, String)> {
    let session_id = transaction_session_id(transaction)?;
    let mut subjects = BTreeSet::from([
        JournalSubject { kind: "session".into(), id: session_id },
        JournalSubject { kind: "hook".into(), id: delivery.manifest.hook_id.clone() },
    ]);
    subjects.extend(delivery.event.subjects.iter().cloned());
    let subjects = subjects.into_iter().collect::<Vec<_>>();
    let producer =
        JournalProducer { kind: "hook_dispatcher".into(), id: delivery.manifest.hook_id.clone() };
    let event_id = random_event_id("hook_delivery");
    let sequence = append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            schema_version: 1,
            kind,
            class: JournalClass::Effect,
            replay: JournalReplayPolicy::Never,
            occurred_at_ms,
            producer: &producer,
            authority: None,
            causation_id: Some(&delivery.event.event_id),
            correlation_id: Some(&format!(
                "{}:{}:{}",
                delivery.manifest.hook_id,
                delivery.manifest.manifest_version,
                delivery.event.event_id
            )),
            causation_depth: delivery.event.causation_depth.saturating_add(1),
            subjects: &subjects,
            sensitivity: JournalSensitivity::Metadata,
            payload: &json!({
                "hook_id":delivery.manifest.hook_id,
                "manifest_version":delivery.manifest.manifest_version,
                "source_event_id":delivery.event.event_id,
                "source_sequence":delivery.event.sequence.to_string(),
                "attempt":attempt,
                "outcome":payload,
            }),
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
            actor: None,
        },
    )?;
    Ok((sequence, event_id))
}
