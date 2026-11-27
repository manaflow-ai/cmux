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

/// One held answer: the session it reads, its JSON text and its last read.
struct Held {
    session: String,
    text: Vec<u8>,
    touched: Instant,
}

/// The answers this daemon holds for askers that read them in parts, by id.
#[derive(Default)]
pub(crate) struct ReadParts {
    held: Mutex<HashMap<String, Held>>,
}

impl ReadParts {
    /// Hold `text`, an answer about `session`, and return the id its part reads name.
    pub(crate) fn hold(&self, session: &str, text: String) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|_, h| h.touched.elapsed() < IDLE);
        let entry =
            Held { session: session.to_owned(), text: text.into_bytes(), touched: Instant::now() };
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
