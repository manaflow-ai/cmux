//! What an agent asks of the ledger (RFD 0010 piece 5, the `asks_search`, `asks_get` and
//! `asks_link` MCP tools through `server/asks.rs`): a search of the person's asks, one ask
//! whole, and a link that appends one event to it. Every answer is bounded and read from the
//! folded state in memory, never from chats or their journals.

use super::{AskLedger, Kind, Line, store};
use serde_json::{Value, json};
use std::path::Path;

/// The most asks one search returns, and how many when it names none.
pub(crate) const SEARCH_MAX: usize = 100;
const SEARCH_DEFAULT: usize = 20;
/// The characters of an ask's text a search row carries; `asks_get` brings the rest.
const SNIPPET_CHARS: usize = 300;

/// Statuses a search may filter by: the ones [`super::Ask::status`] folds to.
pub(crate) const STATUSES: [&str; 6] =
    ["open", "routed", "inProgress", "landed", "answered", "dropped"];

/// Whether this home's ledger ever captured an ask: the `askLedger` experiment's mark on a
/// machine, since a machine that never opted in has no ledger file. The MCP tools are listed
/// only then.
pub(crate) fn captured_on(home: &Path) -> bool {
    home.join(super::DIR).join(store::FILE).is_file()
}

impl AskLedger {
    /// The newest asks whose text holds every word of `q` (case-insensitive; none matches all)
    /// and, with `status`, whose folded status is it. At most `limit` (default 20, at most
    /// [`SEARCH_MAX`]); each row's text cut to a snippet.
    pub(crate) fn search(&self, q: &str, status: Option<&str>, limit: Option<usize>) -> Value {
        let limit = limit.unwrap_or(SEARCH_DEFAULT).clamp(1, SEARCH_MAX);
        let words: Vec<String> = q.split_whitespace().map(str::to_lowercase).collect();
        let state = self.lock();
        let mut matched = 0usize;
        let mut asks = Vec::new();
        for id in state.order.iter().rev() {
            let Some(ask) = state.asks.get(id) else { continue };
            if status.is_some_and(|s| s != ask.status()) {
                continue;
            }
            let text = match ask.events.first() {
                Some((_, _, Kind::Captured { row })) => {
                    row.get("text").and_then(Value::as_str).unwrap_or_default()
                }
                _ => "",
            };
            if !words.is_empty() {
                let lower = text.to_lowercase();
                if !words.iter().all(|w| lower.contains(w.as_str())) {
                    continue;
                }
            }
            matched += 1;
            if asks.len() < limit {
                asks.push(summary(id, ask, text));
            }
        }
        json!({"asks": asks, "matched": matched, "total": state.order.len()})
    }

    /// One ask whole: its captured row, folded status and owner, and every later event.
    pub(crate) fn get(&self, id: &str) -> Option<Value> {
        self.lock().asks.get(id).map(super::Ask::row)
    }

    /// Appends `kind` to ask `id` as `by`, and answers the ask after it. A `captured` is never a
    /// link: only the daemon's human-send boundary captures.
    pub(crate) fn link(&self, id: &str, by: &str, kind: Kind) -> Result<Value, String> {
        if matches!(kind, Kind::Captured { .. }) {
            return Err("a link cannot capture an ask".to_owned());
        }
        let sid = self
            .lock()
            .asks
            .get(id)
            .map(|ask| ask.sid.clone())
            .ok_or_else(|| format!("no ask {id} in this machine's ledger"))?;
        let line = Line::Event {
            ask: id.to_owned(),
            sid,
            ts: crate::store::now_ms(),
            by: by.to_owned(),
            kind,
        };
        if !self.record(line, None) {
            // Purged between the read and the write.
            return Err(format!("no ask {id} in this machine's ledger"));
        }
        self.get(id).ok_or_else(|| format!("no ask {id} in this machine's ledger"))
    }
}

fn summary(id: &str, ask: &super::Ask, text: &str) -> Value {
    let snippet: String = text.chars().take(SNIPPET_CHARS).collect();
    let cut = snippet.len() < text.len();
    let created = ask.events.first().map(|(ts, ..)| *ts).unwrap_or_default();
    let mut row = json!({
        "id": id,
        "status": ask.status(),
        "sessionId": ask.sid,
        "createdAt": created,
        "text": snippet,
        "events": ask.events.len().saturating_sub(1),
    });
    if cut {
        row["textCut"] = json!(true);
    }
    if let Some((owner, _)) = ask.owner() {
        row["owner"] = json!(owner);
    }
    row
}
