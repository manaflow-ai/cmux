//! The chat's copy: its events, its chunks and its snapshot.

use super::store::{Caller, Store, invalid, not_found, refused};
use crate::chunks::{self, ChunkError};
use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::{EVENTS_MAX_BYTES, EVENTS_MAX_PER_APPEND};
use crate::wire::{
    ErrorCode, EventsAppend, EventsPage, Fence, SeqRecord, SnapshotAnswer, SnapshotPost,
};

/// `auto.seq_gap`, with the last seq the store has.
fn seq_gap(last_seq: u64, message: String) -> AutoCloudError {
    AutoCloudError::Http {
        status: ErrorCode::SeqGap.status(),
        code: Some(ErrorCode::SeqGap),
        raw_code: ErrorCode::SeqGap.as_str().to_owned(),
        message,
        last_seq: Some(last_seq),
        missing: Vec::new(),
    }
}

/// `auto.snapshot_incomplete`, naming the chunks the store does not have.
fn incomplete(missing: Vec<String>) -> AutoCloudError {
    AutoCloudError::Http {
        status: ErrorCode::SnapshotIncomplete.status(),
        code: Some(ErrorCode::SnapshotIncomplete),
        raw_code: ErrorCode::SnapshotIncomplete.as_str().to_owned(),
        message: format!("{} of the manifest's chunks are not stored", missing.len()),
        last_seq: None,
        missing,
    }
}

/// A chunk or a manifest the chunk rules refuse.
fn chunk_refused(error: ChunkError) -> AutoCloudError {
    match error.code() {
        Some(code) => refused(code, error.to_string()),
        None => invalid(&error.to_string()),
    }
}

/// More events, or more bytes of them, than one append takes.
fn append_too_large(message: &str) -> AutoCloudError {
    AutoCloudError::http(413, "validation.too_large", message)
}

impl Store {
    /// Appends events and answers the store's last seq. The events come in order; the ones the
    /// store has already are skipped; a first one past the store's next is a gap.
    pub fn append_events(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &EventsAppend,
    ) -> CloudResult<u64> {
        self.write(caller, id, &Fence::new(request.holder.clone(), request.epoch))?;
        if request.events.len() > EVENTS_MAX_PER_APPEND {
            return Err(append_too_large("more than 256 events in one append"));
        }
        let bytes = serde_json::to_vec(&request.events).map_or(usize::MAX, |json| json.len());
        if bytes > EVENTS_MAX_BYTES {
            return Err(append_too_large("more than 1 MiB of events in one append"));
        }
        let last = self.chats.get(id).ok_or_else(not_found)?.last_seq();
        let mut next = match request.events.first() {
            Some(first) if first.seq == 0 => return Err(invalid("seq starts at 1")),
            Some(first) if first.seq > last.saturating_add(1) => {
                let message = format!("the store has events up to {last}, not up to {}", first.seq);
                return Err(seq_gap(last, message));
            }
            Some(first) => first.seq,
            None => return Ok(last),
        };
        for event in &request.events {
            if event.seq != next {
                return Err(seq_gap(last, format!("the events skip from {next} to {}", event.seq)));
            }
            next = next.saturating_add(1);
        }
        let new = request.events.iter().filter(|event| event.seq > last);
        if new.clone().next().is_none() {
            return Ok(last);
        }
        let view = self.change(id, |chat, _| {
            chat.events.extend(new.map(|event| event.record.clone()));
            Ok(())
        })?;
        Ok(view.last_seq)
    }

    /// The events after seq `after`, in order, at most 256 a page.
    pub fn events(
        &self,
        caller: &Caller,
        id: &str,
        after: u64,
        limit: Option<u32>,
    ) -> CloudResult<EventsPage> {
        let chat = self.read(caller, id)?;
        let limit = limit.map_or(EVENTS_MAX_PER_APPEND, |limit| {
            usize::try_from(limit).unwrap_or(usize::MAX).clamp(1, EVENTS_MAX_PER_APPEND)
        });
        let skip = usize::try_from(after).unwrap_or(usize::MAX);
        let events = (1u64..)
            .zip(&chat.events)
            .skip(skip)
            .take(limit)
            .map(|(seq, record)| SeqRecord { seq, record: record.clone() })
            .collect();
        Ok(EventsPage { events, last_seq: chat.last_seq() })
    }

    /// Stores one chunk. The same chunk again is fine.
    pub fn put_chunk(
        &mut self,
        caller: &Caller,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> CloudResult<()> {
        self.write(caller, id, fence)?;
        chunks::check(sha256, bytes).map_err(chunk_refused)?;
        let chat = self.chats.get_mut(id).ok_or_else(not_found)?;
        chat.chunks.entry(sha256.to_owned()).or_insert_with(|| bytes.to_vec());
        Ok(())
    }

    pub fn chunk(&self, caller: &Caller, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        self.read(caller, id)?.chunks.get(sha256).cloned().ok_or_else(not_found)
    }

    /// Accepts a manifest and answers the snapshot's number. Every chunk it names must be
    /// stored, their bytes must be under the cap, and the store must have the events it
    /// includes. The chunks only older snapshots named are dropped.
    pub fn post_snapshot(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &SnapshotPost,
    ) -> CloudResult<u64> {
        self.write(caller, id, &Fence::new(request.holder.clone(), request.epoch))?;
        let manifest = &request.manifest;
        chunks::validate(manifest).map_err(chunk_refused)?;
        let max = self.snapshot_max;
        let chat = self.chats.get(id).ok_or_else(not_found)?;
        let missing = chunks::missing(manifest, |name| chat.chunks.contains_key(name));
        if !missing.is_empty() {
            return Err(incomplete(missing));
        }
        let stored = manifest.chunks().filter_map(|name| chat.chunks.get(name));
        let bytes = stored.fold(0u64, |sum, chunk| sum.saturating_add(chunk.len() as u64));
        if bytes > max {
            let error = ChunkError::TooLarge { bytes, max };
            return Err(refused(ErrorCode::TooLarge, error.to_string()));
        }
        let last = chat.last_seq();
        if manifest.last_seq > last {
            let message = format!(
                "the snapshot includes events up to {}, the store has them up to {last}",
                manifest.last_seq
            );
            return Err(seq_gap(last, message));
        }
        let view = self.change(id, |chat, _| {
            chat.snapshot = chat.snapshot.saturating_add(1);
            chat.chunks.retain(|name, _| manifest.chunks().any(|named| named == name));
            chat.manifest = Some(manifest.clone());
            Ok(())
        })?;
        Ok(view.snapshot)
    }

    pub fn snapshot(&self, caller: &Caller, id: &str) -> CloudResult<SnapshotAnswer> {
        let chat = self.read(caller, id)?;
        match &chat.manifest {
            Some(manifest) => {
                Ok(SnapshotAnswer { snapshot: chat.snapshot, manifest: manifest.clone() })
            }
            None => Err(refused(ErrorCode::NoSnapshot, "the chat has no snapshot")),
        }
    }
}
