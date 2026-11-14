//! The parts of a read answer larger than one hub message (`mesh_read.rs`). The receiving daemon
//! holds the answer, and the asker reads it one part at a time, each part one hub message. A
//! page always holds at least one record, so this is how a chat with one record over 64 KiB
//! opens on a machine only the hub reaches.

use base64::Engine;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long a held answer waits for the asker's next part read; each part read starts it again.
const IDLE: Duration = Duration::from_secs(120);

/// The most answer bytes held at once, for askers that have not read all their parts. One answer
/// is at most one RPC message (31 MiB), so the newest always fits; older answers go first.
pub(crate) const MAX_HELD_BYTES: usize = 64 << 20;

/// One held answer: the session it reads, its JSON text and its last read.
struct Held {
    session: String,
    text: Vec<u8>,
    touched: Instant,
    /// The order it was held in, for answers touched at the same instant.
    order: u64,
}

/// The answers this daemon holds for askers that read them in parts, by id.
#[derive(Default)]
pub(crate) struct ReadParts {
    held: Mutex<HashMap<String, Held>>,
    next: std::sync::atomic::AtomicU64,
}

impl ReadParts {
    /// Hold `text`, an answer about `session`, and return the id its part reads name.
    pub(crate) fn hold(&self, session: &str, text: String) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|_, h| h.touched.elapsed() < IDLE);
        // Room for this answer: the answers read least lately go first.
        let mut total: usize = held.values().map(|h| h.text.len()).sum::<usize>() + text.len();
        while total > MAX_HELD_BYTES {
            let oldest = held.iter().min_by_key(|(_, h)| (h.touched, h.order));
            let Some(oldest) = oldest.map(|(k, _)| k.clone()) else { break };
            total -= held.remove(&oldest).map_or(0, |h| h.text.len());
        }
        let order = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let entry = Held {
            session: session.to_owned(),
            text: text.into_bytes(),
            touched: Instant::now(),
            order,
        };
        held.insert(id.clone(), entry);
        id
    }

    /// Part `index` of answer `id` (parts of `size` bytes), as base64. The last part lets the
    /// answer go. None when this daemon holds no such answer about `session`, or no such part.
    pub(crate) fn part(
        &self,
        id: &str,
        session: &str,
        index: usize,
        size: usize,
    ) -> Option<String> {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|_, h| h.touched.elapsed() < IDLE);
        let entry = held.get_mut(id).filter(|h| h.session == session)?;
        let start = index.checked_mul(size).filter(|start| *start < entry.text.len())?;
        let end = start.saturating_add(size).min(entry.text.len());
        let part = base64::engine::general_purpose::STANDARD.encode(entry.text.get(start..end)?);
        entry.touched = Instant::now();
        if end == entry.text.len() {
            held.remove(id);
        }
        Some(part)
    }
}

#[cfg(test)]
impl ReadParts {
    /// The bytes of every answer held now.
    fn held_bytes(&self) -> usize {
        self.held.lock().unwrap_or_else(|e| e.into_inner()).values().map(|h| h.text.len()).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Answers whose askers never read their parts do not pile up without end: the oldest go
    /// first, and the newest answer is always held whole.
    #[test]
    fn send_path_held_answers_stay_within_a_total_and_the_newest_is_kept() {
        let parts = ReadParts::default();
        let answer = |n: u8| String::from_utf8(vec![b'a' + n; 8 << 20]).unwrap();
        let ids: Vec<String> = (0..9).map(|n| parts.hold("s", answer(n))).collect();
        assert!(parts.held_bytes() <= MAX_HELD_BYTES, "{} bytes held", parts.held_bytes());
        let first = parts.part(&ids[8], "s", 0, 4).unwrap();
        let first = base64::engine::general_purpose::STANDARD.decode(first).unwrap();
        assert_eq!(first, b"iiii");
        assert!(parts.part(&ids[0], "s", 0, 4).is_none(), "the oldest went first");
    }
}
