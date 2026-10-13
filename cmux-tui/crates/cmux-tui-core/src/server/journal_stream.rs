//! Session journal streams: the journal extension requests (page reads,
//! cursors, remote record redaction), the bounded and live journal stream
//! (prepare, start, run, bounded replay completion). Filters live in
//! `journal_filter`.

use super::LOCAL_JOURNAL_PRINCIPAL;
use super::MessageWriter;
use super::OutboundStream;
use super::ResourceWorkerPermit;
use super::journal_filter::{JournalCompiledRegex, JournalStreamFilter};
use super::register_resource_outbound;
use super::resource_session_id;
use super::resource_stream_end;
use super::resource_stream_id;
use super::send_resource_stream_item;
use super::session_stream;
use crate::JournalSensitivity;
use crate::JournalSubject;
use crate::Mux;
use crate::journal_kernel::JournalDocument;
use crate::journal_kernel::SharedJournalPage;
use crate::journal_kernel::SharedJournalRead;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::SessionPublicId;
use crate::resource::StreamPublicId;
use crate::resource::WireDecimal;
use crate::stream_interrupt::StreamInterrupt;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

const JOURNAL_STREAM_PAGE_SIZE: usize = 1024;

pub(super) struct SessionJournalStreamStart {
    pub(super) stream_id: StreamPublicId,
    pub(super) outbound: OutboundStream,
    pub(super) canceled: Arc<AtomicBool>,
    pub(super) _worker_permit: ResourceWorkerPermit,
    pub(super) session_id: SessionPublicId,
    pub(super) next_sequence: u64,
    pub(super) last_sequence: u64,
    pub(super) through_sequence: Option<u64>,
    pub(super) epoch: u64,
    pub(super) filter: JournalStreamFilter,
    pub(super) indexed_subjects: Option<Vec<JournalSubject>>,
    pub(super) reader: Option<crate::workspace_registry::SessionJournalReader>,
    pub(super) shared_fanout: bool,
    pub(super) remote_redacted: bool,
}

fn journal_cursor(session_id: &SessionPublicId, sequence: u64) -> Value {
    json!({
        "generation":session_id,
        "revision":sequence.to_string(),
    })
}

fn remote_journal_record_value(document: &JournalDocument) -> Value {
    let Value::Object(mut object) = document.wire_value().clone() else {
        return Value::Null;
    };
    object.insert("authority".into(), Value::Null);
    object.insert("causation_id".into(), Value::Null);
    object.insert("correlation_id".into(), Value::Null);
    Value::Object(object)
}

pub(super) fn handle_journal_extension_request(
    mux: &Arc<Mux>,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    let origin = LOCAL_JOURNAL_PRINCIPAL;
    match request.envelope.operation {
        ResourceOperation::SessionJournalProducerList => mux
            .userland_journal_producer_manifests()
            .map(|producers| json!({"producers":producers}))
            .map_err(|error| journal_extension_error("session.journal.producer.list", error)),
        ResourceOperation::SessionJournalProducerPut => {
            let manifest = serde_json::from_value::<crate::JournalProducerManifest>(
                request.fields["manifest"].clone(),
            )
            .map_err(|error| {
                eprintln!("cmux-tui: invalid journal producer manifest: {error}");
                ResourceError::validation_invalid(
                    Some("manifest"),
                    "journal producer manifest is invalid",
                )
            })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.put_journal_producer(&manifest, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "producer_id":manifest.producer_id,
                            "manifest_version":manifest.manifest_version,
                            "namespace":manifest.namespace,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.producer.put", error))
        }
        ResourceOperation::SessionJournalAppend => {
            let ingress =
                serde_json::from_value::<crate::JournalIngress>(request.fields["event"].clone())
                    .map_err(|error| {
                        ResourceError::validation_invalid(
                            Some("event"),
                            format!("journal event is invalid: {error}"),
                        )
                    })?;
            super::command_history::refuse_reserved_producer(&ingress)?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.append_journal_ingress(&ingress, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "producer_id":ingress.producer_id,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.append", error))
        }
        ResourceOperation::SessionJournalHookList => mux
            .journal_hook_states()
            .map(|hooks| {
                json!({
                    "hooks":hooks.into_iter().map(|hook| json!({
                        "manifest":hook.manifest,
                        "enabled":hook.enabled,
                        "cursor":journal_cursor(&session_id, hook.cursor_sequence),
                    })).collect::<Vec<_>>()
                })
            })
            .map_err(|error| journal_extension_error("session.journal.hook.list", error)),
        ResourceOperation::SessionJournalHookPut => {
            let manifest = serde_json::from_value::<crate::JournalHookManifest>(
                request.fields["manifest"].clone(),
            )
            .map_err(|error| {
                eprintln!("cmux-tui: invalid journal hook manifest: {error}");
                ResourceError::validation_invalid(
                    Some("manifest"),
                    "journal hook manifest is invalid",
                )
            })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.put_journal_hook(&manifest, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "hook_id":manifest.hook_id,
                            "manifest_version":manifest.manifest_version,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.hook.put", error))
        }
        ResourceOperation::SessionJournalCheckpointCreate => {
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.create_journal_checkpoint(origin, idempotency_key)
                .map(|commit| {
                    let checkpoint = commit.checkpoint;
                    json!({
                        "value":{
                            "checkpoint_id":checkpoint.checkpoint_id,
                            "source_sequence":checkpoint.source_sequence.to_string(),
                            "reducer_version":checkpoint.reducer_version,
                            "sha256":checkpoint.sha256,
                            "created_at_ms":checkpoint.created_at_ms.to_string(),
                            "content_refs":checkpoint.content_refs,
                            "sequence":commit.journal.sequence.to_string(),
                            "event_id":commit.journal.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.journal.sequence.to_string(),
                        "replayed":commit.journal.replayed,
                    })
                })
                .map_err(|error| {
                    journal_extension_error("session.journal.checkpoint.create", error)
                })
        }
        ResourceOperation::SessionJournalCheckpointList => mux
            .journal_checkpoints()
            .map(|checkpoints| {
                json!({"checkpoints":checkpoints.into_iter().map(|checkpoint| json!({
                    "checkpoint_id":checkpoint.checkpoint_id,
                    "source_sequence":checkpoint.source_sequence.to_string(),
                    "reducer_version":checkpoint.reducer_version,
                    "sha256":checkpoint.sha256,
                    "created_at_ms":checkpoint.created_at_ms.to_string(),
                    "content_refs":checkpoint.content_refs,
                })).collect::<Vec<_>>()})
            })
            .map_err(|error| journal_extension_error("session.journal.checkpoint.list", error)),
        ResourceOperation::SessionJournalRestorePreview => {
            let selector =
                request.fields.get("checkpoint").and_then(Value::as_str).unwrap_or("latest");
            mux.journal_restore_preview(selector)
                .map_err(|error| journal_extension_error("session.journal.restore.preview", error))
        }
        ResourceOperation::SessionJournalSegmentList => mux
            .journal_segments()
            .map(|segments| json!({"segments":segments}))
            .map_err(|error| journal_extension_error("session.journal.segment.list", error)),
        ResourceOperation::SessionJournalSegmentSeal => {
            let through_sequence =
                serde_json::from_value::<WireDecimal>(request.fields["through_sequence"].clone())
                    .map(WireDecimal::get)
                    .map_err(|error| {
                        ResourceError::validation_invalid(
                            Some("through_sequence"),
                            format!("segment through sequence is invalid: {error}"),
                        )
                    })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.seal_journal_segments(through_sequence, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "through_sequence":commit.through_sequence.to_string(),
                            "segments":commit.segments,
                            "sequence":commit.journal.sequence.to_string(),
                            "event_id":commit.journal.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.journal.sequence.to_string(),
                        "replayed":commit.journal.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.segment.seal", error))
        }
        _ => unreachable!("journal extension handler received another operation"),
    }
}

pub(super) fn journal_extension_error(operation: &str, error: anyhow::Error) -> ResourceError {
    let message = error.to_string();
    eprintln!("cmux-tui: {operation} failed: {error:#}");
    if error.downcast_ref::<crate::journal_ingress::JournalCommitIndeterminate>().is_some() {
        // The helper must retry the same idempotency key until SQLite exposes
        // the authoritative result. A non-retryable operation failure would
        // make a later provider invocation allocate a new key and duplicate a
        // commit that completed after the first receipt window.
        return ResourceError::transport_closed(message);
    }
    if message.contains("idempotency key was retried with a different payload") {
        return ResourceError::idempotency_conflict("<redacted>", operation);
    }
    if message.contains("schema")
        || message.contains("manifest")
        || message.contains("namespace")
        || message.contains("producer")
        || message.contains("sensitivity")
        || message.contains("causation")
        || message.contains("payload")
    {
        return ResourceError::validation_invalid(None, "journal request is invalid");
    }
    ResourceError::operation_failed(operation, "journal operation failed", json!({}))
}

fn session_journal_page(
    mux: &Mux,
    reader: Option<&crate::workspace_registry::SessionJournalReader>,
    indexed_subjects: Option<&[JournalSubject]>,
    shared_fanout: bool,
    sequence: u64,
    limit: usize,
) -> anyhow::Result<SharedJournalRead> {
    if let Some(reader) = reader {
        if let Some(subjects) = indexed_subjects {
            let page = reader.after_subjects(sequence, limit, subjects)?;
            return Ok(SharedJournalRead::Page(SharedJournalPage {
                head_sequence: page.head_sequence,
                scanned_through: page.scanned_through,
                records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
            }));
        }
        let page = reader.after(sequence, limit)?;
        let scanned_through =
            page.records.last().map_or(page.head_sequence, |record| record.sequence);
        return Ok(SharedJournalRead::Page(SharedJournalPage {
            head_sequence: page.head_sequence,
            scanned_through,
            records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
        }));
    }
    if shared_fanout {
        return Ok(mux.shared_journal_after(sequence, limit));
    }
    let page = mux.session_journal_after(sequence, limit)?;
    let scanned_through = page.records.last().map_or(page.head_sequence, |record| record.sequence);
    Ok(SharedJournalRead::Page(SharedJournalPage {
        head_sequence: page.head_sequence,
        scanned_through,
        records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
    }))
}

pub(super) fn prepare_session_journal_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SessionJournalStreamStart), ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let shared_fanout = mux.shared_journal_enabled();
    let epoch = if shared_fanout { mux.shared_journal_epoch() } else { mux.journal_event_epoch() };
    let head_sequence = mux.session_journal_head().map_err(|error| {
        eprintln!("cmux-tui: read session journal head: {error:#}");
        ResourceError::operation_failed(
            "session.journal.subscribe",
            "could not read the session journal",
            json!({}),
        )
    })?;
    let current_cursor = journal_cursor(&session_id, head_sequence);
    let requested_cursor = request
        .fields
        .get("cursor")
        .map(|cursor| {
            let generation = cursor["generation"].as_str().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("cursor.generation"),
                    "journal cursor generation is invalid",
                )
            })?;
            let sequence = serde_json::from_value::<WireDecimal>(cursor["revision"].clone())
                .map(WireDecimal::get)
                .map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("cursor.revision"),
                        "journal cursor revision is invalid",
                    )
                })?;
            Ok((generation, sequence))
        })
        .transpose()?;
    let last_sequence = if let Some((generation, sequence)) = requested_cursor {
        if generation != session_id.as_str() || sequence > head_sequence {
            return Err(ResourceError::new(
                "cursor.invalid",
                "journal cursor does not belong to this session position",
                json!({
                    "requested":{
                        "generation":generation,
                        "revision":sequence.to_string(),
                    },
                    "current":current_cursor,
                    "reason":if generation != session_id.as_str() {
                        "cursor belongs to a different session"
                    } else {
                        "cursor sequence is ahead of the journal"
                    },
                }),
                false,
            ));
        }
        sequence
    } else if request.fields.get("start").and_then(Value::as_str) == Some("beginning") {
        0
    } else {
        head_sequence
    };
    let through_sequence = request
        .fields
        .get("follow")
        .and_then(Value::as_bool)
        .is_some_and(|follow| !follow)
        .then_some(head_sequence);
    let reader = if shared_fanout && last_sequence < head_sequence {
        mux.session_journal_reader().map_err(|error| {
            eprintln!("cmux-tui: open session journal catch-up reader: {error:#}");
            ResourceError::operation_failed(
                "session.journal.subscribe",
                "could not open the session journal catch-up reader",
                json!({}),
            )
        })?
    } else {
        None
    };
    let remote_redacted = !mux.control_clients.is_unix(client);
    let mut filter = JournalStreamFilter::parse(request.fields.get("filter"))?;
    if remote_redacted {
        let requested_sensitivity = request
            .fields
            .get("filter")
            .and_then(Value::as_object)
            .and_then(|filter| filter.get("max_sensitivity"));
        if requested_sensitivity.and_then(Value::as_str) == Some("sensitive") {
            return Err(ResourceError::operation_failed(
                "session.journal.subscribe",
                "remote journal subscriptions are limited to metadata sensitivity",
                json!({"maximum_sensitivity":"metadata"}),
            ));
        }
        if filter.regex.as_ref().is_some_and(JournalCompiledRegex::exposes_payload_or_record) {
            return Err(ResourceError::operation_failed(
                "session.journal.subscribe",
                "remote journal regex can match only kind or subjects",
                json!({"allowed_regex_fields":["kind","subjects"]}),
            ));
        }
        filter.max_sensitivity = Some(JournalSensitivity::Metadata);
    }
    let indexed_subjects = filter.indexed_subjects();
    let opened_cursor = journal_cursor(&session_id, last_sequence);
    let overflow = resource_stream_end(
        &stream_id,
        "gap",
        Some(opened_cursor.clone()),
        Some("reconnect with the last journal cursor"),
        None,
    );
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|_| ResourceError::transport_closed("could not allocate an outbound stream"))?;
    let (canceled, worker_permit) = register_resource_outbound(
        mux,
        client,
        &stream_id,
        &outbound,
        "session.journal.subscribe",
    )?;
    Ok((
        json!({"stream_id":stream_id,"cursor":opened_cursor}),
        SessionJournalStreamStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            session_id,
            next_sequence: 0,
            last_sequence,
            through_sequence,
            epoch,
            filter,
            indexed_subjects,
            reader,
            shared_fanout,
            remote_redacted,
        },
    ))
}

pub(super) fn start_session_journal_stream(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SessionJournalStreamStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn = std::thread::Builder::new()
        .name("mux-resource-session-journal".into())
        .spawn(move || run_session_journal_stream(&worker_mux, client, &worker_writer, start));
    if spawn.is_err() {
        let _ = mux.control_clients.take_resource_stream(client, &stream_id);
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a new session journal stream"),
            Some((
                ResourceOperation::SessionJournalSubscribe,
                ResourceError::operation_failed(
                    "session.journal.subscribe",
                    "could not start the session journal stream",
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
    }
}

pub(super) fn run_session_journal_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    mut stream: SessionJournalStreamStart,
) {
    let interrupt = StreamInterrupt::new();
    writer.register_interrupt(&interrupt);
    stream.outbound.register_interrupt(&interrupt);
    mux.wake_journal_waiters_on(&interrupt);
    'stream: loop {
        if session_stream::stopped(&stream.canceled, writer, &stream.outbound) {
            break;
        }
        if complete_bounded_journal_replay(writer, &stream) {
            break;
        }
        loop {
            let page = match session_journal_page(
                mux,
                stream.reader.as_ref(),
                stream.indexed_subjects.as_deref(),
                stream.shared_fanout,
                stream.last_sequence,
                JOURNAL_STREAM_PAGE_SIZE,
            ) {
                Ok(SharedJournalRead::Page(page)) => page,
                Ok(SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable)
                    if stream.shared_fanout && stream.reader.is_none() =>
                {
                    match mux.session_journal_reader() {
                        Ok(Some(reader)) => {
                            stream.reader = Some(reader);
                            continue;
                        }
                        Ok(None) | Err(_) => {
                            let end = resource_stream_end(
                                &stream.stream_id,
                                "gap",
                                Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                                Some("reconnect with the last journal cursor"),
                                None,
                            );
                            let _ = writer.send_terminal(&end, &stream.outbound);
                            break 'stream;
                        }
                    }
                }
                Ok(SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect with the last journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
                Err(_) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect with the last journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
            };
            let head_sequence = page.head_sequence;
            let scanned_through = page.scanned_through;
            if page.records.is_empty() {
                stream.last_sequence = stream.last_sequence.max(
                    stream
                        .through_sequence
                        .map_or(scanned_through, |through| scanned_through.min(through)),
                );
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
                if stream.last_sequence < head_sequence {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect from a retained journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
                if stream.shared_fanout && stream.reader.is_some() {
                    stream.reader = None;
                    stream.epoch = mux.shared_journal_epoch();
                }
                break;
            }
            for document in page.records {
                let record_sequence = document.record.sequence;
                if stream
                    .through_sequence
                    .is_some_and(|through_sequence| record_sequence > through_sequence)
                {
                    stream.last_sequence = stream.through_sequence.expect("presence checked");
                    if complete_bounded_journal_replay(writer, &stream) {
                        break 'stream;
                    }
                }
                if stream.filter.matches(&document) {
                    let cursor = journal_cursor(&stream.session_id, record_sequence);
                    if stream.canceled.load(Ordering::Acquire)
                        || !send_resource_stream_item(
                            writer,
                            &stream.outbound,
                            &stream.stream_id,
                            stream.next_sequence,
                            &cursor,
                            if stream.remote_redacted {
                                remote_journal_record_value(&document)
                            } else {
                                document.wire_value().clone()
                            },
                        )
                    {
                        mux.control_clients.finish_resource_stream(
                            client,
                            &stream.stream_id,
                            stream.outbound.id,
                        );
                        return;
                    }
                    stream.next_sequence = stream.next_sequence.saturating_add(1);
                }
                stream.last_sequence = record_sequence;
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                    Some("reconnect with the last journal cursor"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
            }
            if scanned_through > stream.last_sequence {
                stream.last_sequence = stream
                    .through_sequence
                    .map_or(scanned_through, |through| scanned_through.min(through));
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                    Some("reconnect with the last journal cursor"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
            }
            if stream.last_sequence >= head_sequence {
                if stream.shared_fanout && stream.reader.is_some() {
                    stream.reader = None;
                    stream.epoch = mux.shared_journal_epoch();
                }
                break;
            }
        }
        loop {
            if session_stream::stopped(&stream.canceled, writer, &stream.outbound) {
                break 'stream;
            }
            let epoch = if stream.shared_fanout && stream.reader.is_none() {
                mux.wait_for_shared_journal_until_interrupted(stream.epoch, &interrupt)
            } else {
                mux.wait_for_journal_event_until_interrupted(stream.epoch, &interrupt)
            };
            if epoch != stream.epoch {
                stream.epoch = epoch;
                break;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}

fn complete_bounded_journal_replay(
    writer: &MessageWriter,
    stream: &SessionJournalStreamStart,
) -> bool {
    let Some(through_sequence) = stream.through_sequence else {
        return false;
    };
    if stream.last_sequence < through_sequence {
        return false;
    }
    let end = resource_stream_end(
        &stream.stream_id,
        "completed",
        Some(journal_cursor(&stream.session_id, through_sequence)),
        None,
        None,
    );
    let _ = writer.send_ordered_terminal(&end, &stream.outbound);
    true
}
