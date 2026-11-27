//! In-memory backends for tests and simulation. They keep the services' contracts: the forum dedupes
//! on the idempotency key and numbers each thread's log, a room answers for known sessions only, and
//! presence is `cmux-sync`'s own table.

use std::collections::BTreeMap;
use std::sync::Mutex;

use cmux_sync::presence::{Beat, Presence};

use crate::backend::{
    BackendError, ForumBackend, Posted, PresenceBackend, Room, RoomBackend, StoredMessage,
};
use crate::model::{Message, Thread};
use crate::presence::{Participant, from_here};

#[derive(Debug, Default)]
struct ForumState {
    threads: BTreeMap<String, Thread>,
    logs: BTreeMap<String, Vec<StoredMessage>>,
    keys: BTreeMap<String, StoredMessage>,
    /// Calls left to fail with `Unavailable`, for retry tests.
    fail_next: u32,
}

#[derive(Debug, Default)]
pub struct FakeForum {
    state: Mutex<ForumState>,
}

impl FakeForum {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fail the next `n` posts with `Unavailable`, writing nothing.
    pub fn fail_next(&self, n: u32) {
        self.lock().fail_next = n;
    }

    /// Every stored message across threads.
    pub fn stored_count(&self) -> usize {
        self.lock().logs.values().map(Vec::len).sum()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, ForumState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl ForumBackend for FakeForum {
    fn thread(&self, id: &str) -> Result<Thread, BackendError> {
        self.lock().threads.get(id).cloned().ok_or_else(|| BackendError::NotFound(id.to_owned()))
    }

    fn put_thread(&self, thread: Thread) -> Result<(), BackendError> {
        self.lock().threads.insert(thread.id.clone(), thread);
        Ok(())
    }

    fn post(&self, idempotency_key: &str, message: Message) -> Result<Posted, BackendError> {
        let mut s = self.lock();
        if s.fail_next > 0 {
            s.fail_next -= 1;
            return Err(BackendError::Unavailable("injected".to_owned()));
        }
        if let Some(first) = s.keys.get(idempotency_key) {
            return Ok(Posted { stored: first.clone(), duplicate: true });
        }
        if !s.threads.contains_key(&message.thread_id) {
            return Err(BackendError::NotFound(message.thread_id));
        }
        let log = s.logs.entry(message.thread_id.clone()).or_default();
        let stored = StoredMessage {
            seq: log.len() as u64 + 1,
            idempotency_key: idempotency_key.to_owned(),
            message,
        };
        log.push(stored.clone());
        s.keys.insert(idempotency_key.to_owned(), stored.clone());
        Ok(Posted { stored, duplicate: false })
    }

    fn messages(&self, thread_id: &str, after: u64) -> Result<Vec<StoredMessage>, BackendError> {
        let s = self.lock();
        if !s.threads.contains_key(thread_id) {
            return Err(BackendError::NotFound(thread_id.to_owned()));
        }
        Ok(s.logs
            .get(thread_id)
            .map(|l| l.iter().filter(|m| m.seq > after).cloned().collect())
            .unwrap_or_default())
    }
}

#[derive(Debug, Default)]
pub struct FakeRooms {
    rooms: Mutex<BTreeMap<String, Room>>,
}

impl FakeRooms {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn put(&self, room: Room) {
        self.rooms
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(room.session_id.clone(), room);
    }
}

impl RoomBackend for FakeRooms {
    fn room(&self, session_id: &str) -> Result<Room, BackendError> {
        self.rooms
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(session_id)
            .cloned()
            .ok_or_else(|| BackendError::NotFound(session_id.to_owned()))
    }
}

/// `cmux-sync`'s presence table behind the trait.
#[derive(Debug, Default)]
pub struct FakePresence {
    table: Mutex<Presence>,
}

impl FakePresence {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn beat(&self, beat: Beat, now_ms: u64) -> bool {
        self.table.lock().unwrap_or_else(std::sync::PoisonError::into_inner).beat(beat, now_ms)
    }
}

impl PresenceBackend for FakePresence {
    fn here(&self, scope: &str, now_ms: u64) -> Vec<Participant> {
        self.table
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .here(Some(scope), now_ms)
            .iter()
            .map(from_here)
            .collect()
    }
}
