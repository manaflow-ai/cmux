//! Part of `Hub`; see `hub/mod.rs`. The live rows' cached bytes, kept between lists ("Root-fix
//! anything slow, stalling, uncached, growing").
//!
//! A live row reads more than its metadata (its turn, queue, processes, subagents, inbox, the
//! clock), so no stamp says it is unchanged. A list gathers each live row's inputs anew
//! (`Hub::row_inputs`) and reuses the bytes kept for the same inputs; only a row whose inputs
//! moved is rendered (`views::render_row`: the secret masking, the lane, the serialization). A
//! kept row can never be stale: it is reused only for inputs equal to the ones it was rendered
//! from.

use super::views::{RowInputs, render_row};
use super::*;

/// One rendered form of a live session's row and the inputs it was rendered from.
struct Form {
    inputs: RowInputs,
    bytes: Arc<str>,
}

/// The list form and the full one (with tools).
#[derive(Default)]
struct Entry {
    list: Option<Form>,
    full: Option<Form>,
}

impl Entry {
    fn form_mut(&mut self, with_tools: bool) -> &mut Option<Form> {
        if with_tools { &mut self.full } else { &mut self.list }
    }
}

/// Every live session's last rendered rows.
#[derive(Default)]
pub(crate) struct LiveRows {
    entries: HashMap<String, Entry>,
}

impl LiveRows {
    #[cfg(test)]
    pub(super) fn contains_key(&self, id: &str) -> bool {
        self.entries.contains_key(id)
    }

    /// The bytes kept for session `id` when they were rendered from `inputs`.
    fn current(&mut self, id: &str, with_tools: bool, inputs: &RowInputs) -> Option<Arc<str>> {
        let form = self.entries.get_mut(id)?.form_mut(with_tools).as_ref()?;
        (form.inputs == *inputs).then(|| form.bytes.clone())
    }

    fn store(&mut self, id: &str, with_tools: bool, inputs: RowInputs, bytes: Arc<str>) {
        let entry = match self.entries.get_mut(id) {
            Some(entry) => entry,
            None => self.entries.entry(id.to_owned()).or_default(),
        };
        *entry.form_mut(with_tools) = Some(Form { inputs, bytes });
    }

    pub(super) fn remove(&mut self, id: &str) {
        self.entries.remove(id);
    }
}

impl Hub {
    /// A live `session`'s row as a list page sends it, serialized: the kept bytes when its
    /// inputs gathered now equal the ones they were rendered from, else rendered and kept.
    pub(super) fn live_row_text(&self, session: &Session, with_tools: bool) -> Arc<str> {
        let inputs = self.row_inputs(session, with_tools, false);
        if let Some(bytes) = self.live_row_cache.lock().unwrap_or_else(|e| e.into_inner()).current(
            &session.id,
            with_tools,
            &inputs,
        ) {
            return bytes;
        }
        #[cfg(test)]
        self.live_row_renders.fetch_add(1, Ordering::SeqCst);
        let bytes: Arc<str> =
            serde_json::to_string(&render_row(&inputs)).unwrap_or_default().into();
        let mut cache = self.live_row_cache.lock().unwrap_or_else(|e| e.into_inner());
        // A row built while purge or close was dropping the entry: recheck under the cache lock
        // so a late reader does not keep a row nothing removes again.
        if !session.purged.load(Ordering::SeqCst) && session.status() != SessionStatus::Closed {
            cache.store(&session.id, with_tools, inputs, bytes.clone());
        }
        bytes
    }

    pub(super) fn remove_live_row(&self, id: &str) {
        self.live_row_cache.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }
}
