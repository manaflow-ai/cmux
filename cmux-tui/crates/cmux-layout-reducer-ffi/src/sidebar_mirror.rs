//! The app's mirror of the sidebar document (CONTRACT.md "FFI"): the
//! confirmed document from `sidebar.get` and the `session.events` batches,
//! plus the app's pending intents replayed on top with the daemon's own
//! reducer, so a row moves the moment the user drops it.
//!
//! - `load`: the confirmed document (a `sidebar.get` result); pending
//!   intents are kept and replayed.
//! - `apply_batch`: one echoed batch `{revision, previous_revision?,
//!   idempotency_key?, changes:[state_upsert|state_delete of sidebar_item,
//!   sidebar_section, sidebar_doc]}`. The daemon's `sidebar_doc` marker
//!   change carries the same three fields when the batch has none. A batch
//!   whose `previous_revision` is not the confirmed revision answers
//!   `{"refetch":true}`; a batch at or below the confirmed revision is stale
//!   and ignored. The pending intent with the batch's key is dropped, and so
//!   is every pending intent that no longer applies. `{idempotency_key,
//!   rejected:true}` drops a refused intent.
//! - `apply_intent`: `{idempotency_key, ops:[op]}` (or `op`) on the shown
//!   document: `{"ok":true,"inverse":[...]}` or `{"refusal":"<code>"}`.
//! - `view`: the flat rows (an array) of a view request on the shown
//!   document.
//! - `drag_begin`: `{items:[id]}` (or a bare array): the acceptance table
//!   `{row_key: {before, into, after, refusal?}}` over the rows of the last
//!   view.

use cmux_layout_reducer::sidebar_doc::{
    Doc, Item, Op, Section, accept, reduce,
    view::{self, Row, ViewRequest},
};
use serde::Deserialize;
use serde_json::{Value, json};

struct Intent {
    key: String,
    ops: Vec<Op>,
}

#[derive(Default)]
pub struct Mirror {
    confirmed: Doc,
    loaded: bool,
    pending: Vec<Intent>,
    next_local: u64,
    rows: Vec<Row>,
}

fn refusal(reason: &str) -> Value {
    json!({"refusal": reason})
}

fn error(message: impl std::fmt::Display) -> Value {
    json!({"error": message.to_string()})
}

impl Mirror {
    pub fn new() -> Self {
        Mirror::default()
    }

    /// The confirmed document with every pending intent replayed. An
    /// intent that no longer applies is skipped (and dropped by the caller).
    fn shown(&mut self) -> (Doc, Vec<String>) {
        let mut doc = self.confirmed.clone();
        let mut failed = Vec::new();
        // Stored intents carry every id they add (see `apply_intent`).
        let mut mint = String::new;
        for intent in &self.pending {
            match reduce::apply(&doc, &intent.ops, &mut mint) {
                Ok(outcome) => doc = outcome.doc,
                Err(_) => failed.push(intent.key.clone()),
            }
        }
        (doc, failed)
    }

    fn prune(&mut self) -> Vec<String> {
        let (_, failed) = self.shown();
        self.pending.retain(|intent| !failed.contains(&intent.key));
        failed
    }

    pub fn load(&mut self, input: &[u8]) -> Value {
        let mut doc: Doc = match serde_json::from_slice(input) {
            Ok(doc) => doc,
            Err(e) => return error(e),
        };
        doc.normalize();
        self.confirmed = doc;
        self.loaded = true;
        let dropped = self.prune();
        json!({"ok": true, "revision": self.confirmed.revision.to_string(), "dropped": dropped})
    }

    pub fn apply_batch(&mut self, input: &[u8]) -> Value {
        let batch: Value = match serde_json::from_slice(input) {
            Ok(batch) => batch,
            Err(e) => return error(e),
        };
        let changes = batch["changes"].as_array().cloned().unwrap_or_default();
        let marker = changes
            .iter()
            .find(|change| change["resource"] == "sidebar_doc")
            .map(|change| change["value"].clone())
            .unwrap_or(Value::Null);
        let field = |name: &str| {
            batch.get(name).filter(|v| !v.is_null()).or_else(|| marker.get(name)).cloned()
        };
        let decimal = |value: Option<Value>| {
            value.and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        };
        let key = field("idempotency_key").and_then(|v| v.as_str().map(str::to_string));
        if batch["rejected"] == true {
            self.pending.retain(|intent| Some(&intent.key) != key.as_ref());
            return json!({"ok": true, "dropped": key.into_iter().collect::<Vec<_>>()});
        }
        let Some(revision) = decimal(field("revision")) else {
            return error("batch has no revision");
        };
        if !self.loaded {
            return json!({"refetch": true});
        }
        if revision <= self.confirmed.revision {
            return json!({"ok": true, "stale": true});
        }
        let previous = decimal(field("previous_revision")).unwrap_or(revision - 1);
        if previous != self.confirmed.revision {
            return json!({"refetch": true});
        }
        let mut doc = self.confirmed.clone();
        for change in &changes {
            let resource = change["resource"].as_str().unwrap_or_default();
            let id = change["id"].as_str().unwrap_or_default().to_string();
            let op = match (change["kind"].as_str().unwrap_or_default(), resource) {
                ("state_upsert", "sidebar_item") => {
                    match serde_json::from_value::<Item>(change["value"].clone()) {
                        Ok(item) => Op::ItemPut { item },
                        Err(e) => return error(e),
                    }
                }
                ("state_upsert", "sidebar_section") => {
                    match serde_json::from_value::<Section>(change["value"].clone()) {
                        Ok(section) => Op::SectionPut { section },
                        Err(e) => return error(e),
                    }
                }
                ("state_delete", "sidebar_item") => Op::ItemDelete { id },
                ("state_delete", "sidebar_section") => Op::SectionDelete { id },
                _ => continue,
            };
            if let Err(refusal) = reduce::apply_one(&mut doc, &op, &mut String::new) {
                return error(refusal);
            }
        }
        doc.normalize();
        doc.revision = revision;
        self.confirmed = doc;
        let mut dropped = Vec::new();
        if let Some(key) = &key
            && self.pending.iter().any(|intent| intent.key == *key)
        {
            self.pending.retain(|intent| intent.key != *key);
            dropped.push(key.clone());
        }
        dropped.extend(self.prune());
        json!({"ok": true, "revision": revision.to_string(), "dropped": dropped})
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
                *slot = Some(format!("itm_local_{}", self.next_local));
            }
        }
        let (doc, _) = self.shown();
        let mut mint = String::new;
        match reduce::apply(&doc, &ops, &mut mint) {
            Ok(outcome) => {
                self.pending.push(Intent { key: intent.idempotency_key, ops });
                json!({"ok": true, "inverse": outcome.inverse})
            }
            Err(reason) => refusal(reason.as_str()),
        }
    }

    pub fn view(&mut self, input: &[u8]) -> Value {
        let request: ViewRequest = match serde_json::from_slice(input) {
            Ok(request) => request,
            Err(e) => return error(e),
        };
        let (doc, _) = self.shown();
        self.rows = view::view(&doc, &request);
        json!(self.rows)
    }

    pub fn drag_begin(&mut self, input: &[u8]) -> Value {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Items {
            List(Vec<String>),
            Object { items: Vec<String> },
        }
        let items = match serde_json::from_slice::<Items>(input) {
            Ok(Items::List(items) | Items::Object { items }) => items,
            Err(e) => return error(e),
        };
        let (doc, _) = self.shown();
        json!(accept::drag_begin(&doc, &self.rows, &items))
    }
}
