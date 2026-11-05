//! The store that keeps sessions and their events in memory (`store.mode` `memory`; tests).

use super::*;

#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<HashMap<String, (SessionMeta, Vec<EventRecord>)>>,
}

impl Store for MemoryStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        Ok(self.inner.lock_or_recover().values().map(|(m, _)| m.clone()).collect())
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Ok(self.inner.lock_or_recover().get(id).map(|(m, _)| m.clone()))
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let mut g = self.inner.lock_or_recover();
        g.entry(meta.id.clone())
            .and_modify(|(m, _)| *m = meta.clone())
            .or_insert_with(|| (meta.clone(), Vec::new()));
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut g = self.inner.lock_or_recover();
        if let Some((_, events)) = g.get_mut(id) {
            events.push(record.clone());
            // Bound memory: keep the newest 20k events.
            if events.len() > 20_000 {
                let drop = events.len() - 20_000;
                events.drain(..drop);
            }
        }
        Ok(())
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let g = self.inner.lock_or_recover();
        Ok(g.get(id)
            .map(|(_, ev)| ev.iter().filter(|e| e.seq > after).take(limit).cloned().collect())
            .unwrap_or_default())
    }
    /// Newest first, a bounded window at a time: a visitor that stops early clones only the
    /// windows it read, and it runs off the lock.
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        const WINDOW: usize = 256;
        let mut before = before;
        loop {
            let (window, lowest) = {
                let g = self.inner.lock_or_recover();
                let Some((_, events)) = g.get(id) else { return Ok(()) };
                let end = events.partition_point(|e| e.seq < before);
                let mut window = Vec::new();
                let mut lowest = None;
                for e in events
                    .get(..end)
                    .unwrap_or_default()
                    .iter()
                    .rev()
                    .take_while(|e| e.seq > after)
                    .take(WINDOW)
                {
                    lowest = Some(e.seq);
                    if !skip(e.dir.as_bytes(), e.kind.as_bytes()) {
                        window.push(e.clone());
                    }
                }
                (window, lowest)
            };
            let Some(lowest) = lowest else { return Ok(()) };
            for record in window {
                if !visit(record) {
                    return Ok(());
                }
            }
            before = lowest;
        }
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.lock_or_recover().remove(id);
        Ok(())
    }
}
