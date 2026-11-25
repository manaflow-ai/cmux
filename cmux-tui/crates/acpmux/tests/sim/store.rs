//! The simulated disk under the daemon's store. It outlives every daemon incarnation of a run:
//! a restarted daemon opens a new `SimStore` over the same `Disk`, as a real one opens the same
//! folder.
//!
//! A record is written when the daemon appends it and durable once the daemon flushes its chat
//! (`Store::flush_session`, `Store::flush`). A daemon crash keeps every written record (the OS
//! still has them); a power loss also drops the ones not yet durable, as a real disk can.

use acpmux::store::{EventRecord, SessionMeta, Store};
use anyhow::Result;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Chat {
    meta: Option<SessionMeta>,
    /// Every written record, and whether it is durable.
    records: Vec<(EventRecord, bool)>,
}

#[derive(Default)]
pub struct Disk {
    chats: Mutex<BTreeMap<String, Chat>>,
}

impl Disk {
    /// The machine lost power: what was not flushed is gone.
    pub fn power_loss(&self) -> usize {
        let mut chats = self.chats.lock().unwrap();
        let mut lost = 0;
        for chat in chats.values_mut() {
            let before = chat.records.len();
            chat.records.retain(|(_, durable)| *durable);
            lost += before - chat.records.len();
        }
        lost
    }

    /// Every chat's records as written, for the invariants.
    pub fn snapshot(&self) -> BTreeMap<String, Vec<EventRecord>> {
        let chats = self.chats.lock().unwrap();
        chats
            .iter()
            .map(|(id, c)| (id.clone(), c.records.iter().map(|(r, _)| r.clone()).collect()))
            .collect()
    }
}

/// One daemon incarnation's store over the run's disk.
pub struct SimStore(pub Arc<Disk>);

impl SimStore {
    fn sync(&self, id: Option<&str>) {
        let mut chats = self.0.chats.lock().unwrap();
        for (chat_id, chat) in chats.iter_mut() {
            if id.is_none_or(|id| id == chat_id) {
                for (_, durable) in &mut chat.records {
                    *durable = true;
                }
            }
        }
    }
}

impl Store for SimStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        Ok(self.0.chats.lock().unwrap().values().filter_map(|c| c.meta.clone()).collect())
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Ok(self.0.chats.lock().unwrap().get(id).and_then(|c| c.meta.clone()))
    }
    /// Metadata is written whole and replaced atomically (`write_atomic`): durable at once.
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.0.chats.lock().unwrap().entry(meta.id.clone()).or_default().meta = Some(meta.clone());
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut chats = self.0.chats.lock().unwrap();
        if let Some(chat) = chats.get_mut(id).filter(|c| c.meta.is_some()) {
            chat.records.push((record.clone(), false));
        }
        Ok(())
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        self.sync(Some(id));
        Ok(())
    }
    fn flush(&self) -> Result<()> {
        self.sync(None);
        Ok(())
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let chats = self.0.chats.lock().unwrap();
        Ok(chats
            .get(id)
            .map(|c| {
                c.records
                    .iter()
                    .map(|(r, _)| r)
                    .filter(|r| r.seq > after)
                    .take(limit)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default())
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0.chats.lock().unwrap().remove(id);
        Ok(())
    }
}
