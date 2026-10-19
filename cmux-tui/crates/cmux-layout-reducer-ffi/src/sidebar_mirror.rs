//! The app's mirror of the sidebar document (CONTRACT.md "FFI"): the
//! confirmed document from `sidebar.get` and the `session.events` batches,
//! plus the app's pending intents replayed on top with the daemon's own
//! reducer, so a row moves the moment the user drops it.
//!
//! - `load`: the confirmed document (a `sidebar.get` result); pending
//!   intents are kept and replayed.
//! - `apply_batch`: one echoed batch `{revision, previous_revision?,
//!   idempotency_key?, changes:[state_upsert|state_delete of sidebar_item,
//!   sidebar_section, sidebar_doc]}`. The document revisions and key come
//!   from the daemon's `sidebar_doc` changes (the first one's
//!   `previous_revision`, the last one's `revision`); the batch's own fields
//!   count only when it has none, and a batch with neither is ignored. The
//!   pending intent with the batch's key is dropped first, in every case. A
//!   batch whose previous revision is not the confirmed revision answers
//!   `{"refetch":true}`; a batch at or below the confirmed revision is stale
//!   and ignored. Every pending intent that no longer applies is dropped.
//!   `{idempotency_key, rejected:true}` drops a refused intent.
//! - `apply_intent`: `{idempotency_key, ops:[op]}` (or `op`) on the shown
//!   document: `{"ok":true,"ops":[...],"inverse":[...]}` (`ops` with the
//!   ids the mirror minted for added items: send those to the daemon) or
//!   `{"refusal":"<code>"}`.
//! - `view`: the flat rows (an array) of a view request on the shown
//!   document.
//! - `drag_begin`: `{items:[id]}` (or a bare array): the acceptance table
//!   `{row_key: {before, into, after, refusal?}}` over the rows of the last
//!   view.

use crate::typed::{CAcceptanceTable, CReply, CRows, Out};
use cmux_layout_reducer::sidebar_doc::{
    Doc, Item, Op, Section, accept, reduce,
    view::{self, Row, ViewRequest},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

struct Intent {
    key: String,
    ops: Vec<Op>,
    /// Undoes this intent on the shown document (the reducer's inverse).
    inverse: Vec<Op>,
}

#[derive(Default)]
pub struct Mirror {
    confirmed: Doc,
    /// `confirmed` with every pending intent applied, kept in step: a batch
    /// undoes the pending intents (newest first, by their inverses), applies
    /// its rows, and replays them, so no call copies the document.
    shown: Doc,
    loaded: bool,
    pending: Vec<Intent>,
    next_local: u64,
    /// A per-mirror random prefix of local ids, so ids minted after a
    /// relaunch never collide with ones the daemon stored earlier.
    local_prefix: String,
    rows: Vec<Row>,
    /// The buffers of the last typed replies (`*_typed`).
    out: Out,
}

fn refusal(reason: &str) -> Value {
    json!({"refusal": reason})
}

fn error(message: impl std::fmt::Display) -> Value {
    json!({"error": message.to_string()})
}

impl Mirror {
    pub fn new() -> Self {
        use std::hash::{BuildHasher, Hasher};
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_nanos()),
        );
        Mirror { local_prefix: format!("itm_{:016x}", hasher.finish()), ..Mirror::default() }
    }

    /// Undo every pending intent on the shown document: it is the
    /// confirmed document again.
    fn unwind(&mut self) {
        for intent in self.pending.iter().rev() {
            reduce::apply_rows(&mut self.shown, &intent.inverse);
        }
        self.shown.revision = self.confirmed.revision;
    }

    /// Apply the pending intents again; drop (and return) the ones that no
    /// longer apply.
    fn replay(&mut self) -> Vec<String> {
        let mut failed = Vec::new();
        // Stored intents carry every id they add (see `apply_intent`).
        let mut mint = String::new;
        let shown = &mut self.shown;
        self.pending.retain_mut(|intent| {
            match reduce::apply_in_place(shown, &intent.ops, &mut mint) {
                Ok(applied) => {
                    intent.inverse = applied.inverse;
                    true
                }
                Err(_) => {
                    failed.push(intent.key.clone());
                    false
                }
            }
        });
        failed
    }

    pub fn load(&mut self, input: &[u8]) -> Value {
        let doc: Doc = match serde_json::from_slice(input) {
            Ok(doc) => doc,
            Err(e) => return error(e),
        };
        self.shown = doc.clone();
        self.confirmed = doc;
        self.loaded = true;
        let dropped = self.replay();
        json!({"ok": true, "revision": self.confirmed.revision.to_string(), "dropped": dropped})
    }

    pub fn apply_batch(&mut self, input: &[u8]) -> Value {
        let batch: Value = match serde_json::from_slice(input) {
            Ok(batch) => batch,
            Err(e) => return error(e),
        };
        let changes = batch["changes"].as_array().cloned().unwrap_or_default();
        // The document revisions come from the `sidebar_doc` markers (a
        // session.events delta's own revisions are the session's): the
        // first marker's previous revision and the last marker's revision
        // (one commit can write two). A batch with no marker and no
        // document fields of its own is not a sidebar batch.
        let markers: Vec<&Value> = changes
            .iter()
            .filter(|change| change["resource"] == "sidebar_doc")
            .map(|change| &change["value"])
            .collect();
        let decimal = |value: Option<&Value>| {
            value.and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        };
        let own = |name: &str| batch.get(name).filter(|v| !v.is_null());
        let key = markers
            .iter()
            .find_map(|marker| marker["idempotency_key"].as_str())
            .or_else(|| own("idempotency_key").and_then(Value::as_str))
            .map(str::to_string);
        let (revision, previous) = if markers.is_empty() {
            (decimal(own("revision")), decimal(own("previous_revision")))
        } else {
            (
                decimal(markers.last().map(|m| &m["revision"])),
                decimal(markers.first().map(|m| &m["previous_revision"])),
            )
        };
        // What the batch is: refused, not a sidebar batch, early, stale,
        // gapped, or rows to apply.
        let verdict = if batch["rejected"] == true {
            Some(json!({"ok": true}))
        } else if let Some(revision) = revision {
            if !self.loaded {
                Some(json!({"refetch": true}))
            } else if revision <= self.confirmed.revision {
                Some(json!({"ok": true, "stale": true}))
            } else if previous.unwrap_or(revision - 1) != self.confirmed.revision {
                Some(json!({"refetch": true}))
            } else {
                None
            }
        } else {
            Some(json!({"ok": true, "ignored": true}))
        };
        let mut rows = Vec::new();
        let mut bad_row = None;
        if verdict.is_none() {
            for change in &changes {
                let resource = change["resource"].as_str().unwrap_or_default();
                let id = change["id"].as_str().unwrap_or_default().to_string();
                let op = match (change["kind"].as_str().unwrap_or_default(), resource) {
                    ("state_upsert", "sidebar_item") => {
                        match serde_json::from_value::<Item>(change["value"].clone()) {
                            Ok(item) => Op::ItemPut { item },
                            Err(e) => {
                                bad_row = Some(error(e));
                                break;
                            }
                        }
                    }
                    ("state_upsert", "sidebar_section") => {
                        match serde_json::from_value::<Section>(change["value"].clone()) {
                            Ok(section) => Op::SectionPut { section },
                            Err(e) => {
                                bad_row = Some(error(e));
                                break;
                            }
                        }
                    }
                    ("state_delete", "sidebar_item") => Op::ItemDelete { id },
                    ("state_delete", "sidebar_section") => Op::SectionDelete { id },
                    _ => continue,
                };
                rows.push(op);
            }
        }
        // The intent this batch confirms or refuses goes in every case: a
        // stale or gapped batch still says the daemon decided it. The shown
        // document changes only when an intent goes or rows apply.
        let confirms =
            key.as_ref().is_some_and(|key| self.pending.iter().any(|intent| intent.key == *key));
        let applies = verdict.is_none() && bad_row.is_none();
        if !confirms && !applies {
            let mut result = verdict.or(bad_row).unwrap_or_else(|| json!({"ok": true}));
            result["dropped"] = json!(Vec::<String>::new());
            return result;
        }
        if !self.loaded {
            // Nothing is shown yet: drop the intent; `load` replays the rest.
            self.pending.retain(|intent| Some(&intent.key) != key.as_ref());
            let mut result = verdict.unwrap_or_else(|| json!({"refetch": true}));
            result["dropped"] = json!(key.into_iter().collect::<Vec<_>>());
            return result;
        }
        self.unwind();
        let mut dropped = Vec::new();
        if let Some(key) = key.filter(|_| confirms) {
            self.pending.retain(|intent| intent.key != key);
            dropped.push(key);
        }
        let mut result = match (verdict, bad_row) {
            (Some(verdict), _) => verdict,
            (None, Some(bad_row)) => bad_row,
            (None, None) => {
                let revision = revision.unwrap_or_default();
                reduce::apply_rows(&mut self.confirmed, &rows);
                reduce::apply_rows(&mut self.shown, &rows);
                self.confirmed.revision = revision;
                self.shown.revision = revision;
                json!({"ok": true, "revision": revision.to_string()})
            }
        };
        dropped.extend(self.replay());
        result["dropped"] = json!(dropped);
        result
    }

    pub fn apply_intent(&mut self, input: &[u8]) -> Value {
        #[derive(Deserialize)]
        struct IntentInput {
            idempotency_key: String,
            #[serde(default)]
            ops: Vec<Op>,
            #[serde(default)]
            op: Option<Op>,
        }
        let intent: IntentInput = match serde_json::from_slice(input) {
            Ok(intent) => intent,
            Err(e) => return error(e),
        };
        let mut ops = intent.ops;
        ops.extend(intent.op);
        // Mint the ids of added items now, so a replay adds the same ids.
        for op in &mut ops {
            let slot = match op {
                Op::ItemAdd { item, .. } => &mut item.id,
                Op::GroupCreate { id, .. } => id,
                _ => continue,
            };
            if slot.is_none() {
                self.next_local += 1;
                *slot = Some(format!("{}_{}", self.local_prefix, self.next_local));
            }
        }
        let mut mint = String::new;
        match reduce::apply_in_place(&mut self.shown, &ops, &mut mint) {
            Ok(applied) => {
                // The ops with their minted ids: send these to the daemon,
                // so the echo and the inverse name the same items.
                let stamped = serde_json::to_value(&ops).unwrap_or(Value::Null);
                let inverse = applied.inverse.clone();
                self.pending.push(Intent {
                    key: intent.idempotency_key,
                    ops,
                    inverse: applied.inverse,
                });
                json!({"ok": true, "ops": stamped, "inverse": inverse})
            }
            Err(reason) => refusal(reason.as_str()),
        }
    }

    /// Reads a view request and keeps its rows for `drag_begin`.
    fn view_rows(&mut self, input: &[u8]) -> Result<(), Value> {
        let request: ViewRequest = serde_json::from_slice(input).map_err(error)?;
        self.rows = view::view(&self.shown, &request);
        Ok(())
    }

    pub fn view(&mut self, input: &[u8]) -> Value {
        match self.view_rows(input) {
            Ok(()) => json!(self.rows),
            Err(e) => e,
        }
    }

    fn acceptance(&self, input: &[u8]) -> Result<BTreeMap<String, accept::Acceptance>, Value> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Items {
            List(Vec<String>),
            Object { items: Vec<String> },
        }
        let (Items::List(items) | Items::Object { items }) =
            serde_json::from_slice::<Items>(input).map_err(error)?;
        Ok(accept::drag_begin(&self.shown, &self.rows, &items))
    }

    pub fn drag_begin(&mut self, input: &[u8]) -> Value {
        match self.acceptance(input) {
            Ok(table) => json!(table),
            Err(e) => e,
        }
    }

    // Typed replies (crate::typed): the same calls, read with no JSON.

    pub fn view_typed(&mut self, input: &[u8]) -> *const CRows {
        let ok = self.view_rows(input).is_ok();
        self.out.rows(ok.then_some(self.rows.as_slice()))
    }

    pub fn drag_begin_typed(&mut self, input: &[u8]) -> *const CAcceptanceTable {
        let table = self.acceptance(input).ok();
        self.out.acceptance(table.as_ref())
    }

    pub fn load_typed(&mut self, input: &[u8]) -> *const CReply {
        let reply = self.load(input);
        self.out.reply(&reply)
    }

    pub fn apply_batch_typed(&mut self, input: &[u8]) -> *const CReply {
        let reply = self.apply_batch(input);
        self.out.reply(&reply)
    }

    pub fn apply_intent_typed(&mut self, input: &[u8]) -> *const CReply {
        let reply = self.apply_intent(input);
        self.out.reply(&reply)
    }
}
