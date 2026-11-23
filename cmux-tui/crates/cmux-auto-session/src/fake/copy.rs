//! The chat's copy: its events, its chunks and its snapshot (the real store's `events.ts` and
//! `snapshots.ts`, and the routes that write them).

use super::record::{MAX_MANIFEST_BYTES, MAX_MANIFEST_CHUNKS, Record};
use super::rules::{self, Refuse, Step};
use super::store::{
    Caller, Chunk, Store, StoredEvent, body_too_large, invalid, not_found, size_of, writer,
};
use crate::chunks;
use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::{CHUNK_MAX_BYTES, EVENTS_MAX_BYTES, EVENTS_MAX_PER_APPEND};
use crate::wire::{
    Cwd, ErrorCode, EventsAppend, EventsPage, Fence, Manifest, SeqRecord, SnapshotAnswer,
    SnapshotPost,
};

/// A page of events is cut once its records pass this size (the first always fits).
const PAGE_MAX_BYTES: u64 = 1 << 20;

fn too_large() -> Refuse {
    Refuse::new(ErrorCode::TooLarge, "the chat is too large to keep a Cloud copy")
}

/// How many bytes a value is as JSON.
fn json_len<T: serde::Serialize>(value: &T) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |json| json.len())
}

/// The chunks a manifest names, each once: every list in it whose items are all chunk names.
/// The real store reads the lists by shape, so a list with anything else in it names nothing.
fn named_chunks(manifest: &Manifest) -> Vec<&str> {
    let lists: [&[String]; 2] = match &manifest.cwd {
        Cwd::Git { bundle, patch, .. } => [bundle.as_slice(), patch.as_slice()],
        Cwd::Folder { tar } => [tar.as_slice(), &[]],
    };
    let mut names: Vec<&str> = Vec::new();
    for list in lists {
        if !list.iter().all(|name| chunks::is_name(name)) {
            continue;
        }
        for name in list {
            if !names.contains(&name.as_str()) {
                names.push(name.as_str());
            }
        }
    }
    names
}

impl Store {
    /// Appends events and answers the store's last seq. The ones the store has already are
    /// skipped (a retry after a lost answer); the rest must go on from the last one stored.
    pub fn append_events(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &EventsAppend,
    ) -> CloudResult<u64> {
        if json_len(request) > EVENTS_MAX_BYTES {
            return Err(body_too_large(EVENTS_MAX_BYTES));
        }
        writer(&request.holder)?;
        if request.events.len() > EVENTS_MAX_PER_APPEND {
            return Err(invalid("events: at most 256 of {seq, record}"));
        }
        if request.events.iter().any(|event| event.seq < 1) {
            return Err(invalid("events: each is {seq, record}, seq from 1"));
        }
        self.admitted(caller, id, true)?;
        let max = self.chat_max;
        let (last_seq, _) = self.apply(id, |chat, _| {
            rules::fence(&chat.rec, caller, &request.holder, request.epoch)?;
            let stored = chat.rec.last_seq;
            let mut fresh: Vec<StoredEvent> = Vec::new();
            let mut expected = stored.saturating_add(1);
            for event in &request.events {
                if event.seq < expected {
                    continue;
                }
                if event.seq > expected {
                    let message = format!("event {} does not follow {stored}", event.seq);
                    let gap = Refuse::new(ErrorCode::SeqGap, message);
                    return Err(Refuse { last_seq: Some(stored), ..gap });
                }
                let bytes = u64::try_from(json_len(&event.record)).unwrap_or(u64::MAX);
                fresh.push(StoredEvent { record: event.record.clone(), bytes });
                expected = expected.saturating_add(1);
            }
            if fresh.is_empty() {
                return Ok(Step::same(stored));
            }
            let bytes = fresh.iter().fold(0u64, |sum, event| sum.saturating_add(event.bytes));
            let event_bytes = chat.rec.event_bytes.saturating_add(bytes);
            if event_bytes > max {
                return Err(too_large());
            }
            let last_seq = expected.saturating_sub(1);
            chat.events.extend(fresh);
            Ok(Step::loud(last_seq, Record { last_seq, event_bytes, ..chat.rec.clone() }))
        })?;
        Ok(last_seq)
    }

    /// The events after seq `after`, in order: at most 256 a page, cut at 1 MiB.
    pub fn events(
        &self,
        caller: &Caller,
        id: &str,
        after: u64,
        limit: Option<u32>,
    ) -> CloudResult<EventsPage> {
        let chat = self.admitted(caller, id, false)?;
        let limit = limit.map_or(EVENTS_MAX_PER_APPEND, |limit| {
            usize::try_from(limit).unwrap_or(usize::MAX).clamp(1, EVENTS_MAX_PER_APPEND)
        });
        let skip = usize::try_from(after).unwrap_or(usize::MAX);
        let mut events: Vec<SeqRecord> = Vec::new();
        let mut bytes = 0u64;
        for (seq, event) in (1u64..).zip(&chat.events).skip(skip).take(limit) {
            bytes = bytes.saturating_add(event.bytes);
            if !events.is_empty() && bytes > PAGE_MAX_BYTES {
                break;
            }
            events.push(SeqRecord { seq, record: event.record.clone() });
        }
        Ok(EventsPage { events, last_seq: chat.rec.last_seq })
    }

    /// Stores one chunk under the name that is its SHA-256. The same chunk again is fine.
    pub fn put_chunk(
        &mut self,
        caller: &Caller,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> CloudResult<()> {
        // A name that is no SHA-256 is no route.
        if !chunks::is_name(sha256) {
            return Err(not_found());
        }
        writer(&fence.holder)?;
        if bytes.len() > CHUNK_MAX_BYTES {
            return Err(body_too_large(CHUNK_MAX_BYTES));
        }
        self.admitted(caller, id, true)?;
        let named = chunks::name_of(bytes) == sha256;
        let max = self.chat_max;
        let stored = self.apply(id, |chat, now| {
            rules::fence(&chat.rec, caller, &fence.holder, fence.epoch)?;
            if !named {
                let message = "the bytes do not hash to the chunk's name";
                return Err(Refuse::new(ErrorCode::ChunkMismatch, message));
            }
            if chat.chunks.contains_key(sha256) {
                return Ok(Step::same(()));
            }
            if !chat.room_for_chunk(size_of(bytes), max, now) {
                return Err(too_large());
            }
            let chunk = Chunk { bytes: bytes.to_vec(), kept: false, at: now };
            chat.chunks.insert(sha256.to_owned(), chunk);
            Ok(Step::same(()))
        });
        stored.map(|((), _)| ())
    }

    pub fn chunk(&self, caller: &Caller, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        if !chunks::is_name(sha256) {
            return Err(not_found());
        }
        let chat = self.admitted(caller, id, false)?;
        let stored = chat.chunks.get(sha256).map(|chunk| chunk.bytes.clone());
        stored.ok_or_else(|| AutoCloudError::http(404, "not_found", "chunk not found"))
    }

    /// Accepts a manifest and answers the snapshot's number. Every chunk it names must be
    /// stored, and their bytes under the chat's limit. The chunks it does not name are
    /// dropped. It counts as covering the chat only through the events the store has.
    pub fn post_snapshot(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &SnapshotPost,
    ) -> CloudResult<u64> {
        writer(&request.holder)?;
        let manifest = &request.manifest;
        if json_len(manifest) > MAX_MANIFEST_BYTES {
            let message = format!("a manifest is at most {MAX_MANIFEST_BYTES} bytes");
            return Err(AutoCloudError::refused(ErrorCode::TooLarge, message));
        }
        self.admitted(caller, id, true)?;
        let names = named_chunks(manifest);
        let max = self.chat_max;
        let (snapshot, _) = self.apply(id, |chat, _| {
            rules::fence(&chat.rec, caller, &request.holder, request.epoch)?;
            if names.len() > MAX_MANIFEST_CHUNKS {
                return Err(too_large());
            }
            let missing: Vec<String> = names
                .iter()
                .filter(|name| !chat.chunks.contains_key(**name))
                .map(|name| (*name).to_owned())
                .collect();
            if !missing.is_empty() {
                let message = format!("{} of the manifest's chunks are not stored", missing.len());
                let incomplete = Refuse::new(ErrorCode::SnapshotIncomplete, message);
                return Err(Refuse { missing, ..incomplete });
            }
            let named = names.iter().filter_map(|name| chat.chunks.get(*name));
            let bytes = named.fold(0u64, |sum, chunk| sum.saturating_add(size_of(&chunk.bytes)));
            if bytes > max {
                return Err(too_large());
            }
            let snapshot = chat.rec.snapshot.saturating_add(1);
            chat.chunks.retain(|name, _| names.contains(&name.as_str()));
            for chunk in chat.chunks.values_mut() {
                chunk.kept = true;
            }
            chat.manifest = Some(manifest.clone());
            let snapshot_seq = manifest.last_seq.min(chat.rec.last_seq);
            Ok(Step::loud(snapshot, Record { snapshot, snapshot_seq, ..chat.rec.clone() }))
        })?;
        Ok(snapshot)
    }

    pub fn snapshot(&self, caller: &Caller, id: &str) -> CloudResult<SnapshotAnswer> {
        let chat = self.admitted(caller, id, false)?;
        match &chat.manifest {
            Some(manifest) => {
                Ok(SnapshotAnswer { snapshot: chat.rec.snapshot, manifest: manifest.clone() })
            }
            None => Err(AutoCloudError::refused(ErrorCode::NoSnapshot, "the chat has no snapshot")),
        }
    }
}
