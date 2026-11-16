//! `_acpmux/rows` and the live row patches (`_acpmux/rows_patch`): each chat's row table, kept
//! in the hub for the chats a client reads rows of, caught up from the log on each read and on
//! each live record, and the recent patches a following connection has not been sent yet.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::fold::{Patch, RowTable};
use super::page::{DEFAULT_ROW_PAGE_BYTES, RowsCursor};
use crate::hub::Hub;
use crate::no_panic::LockExt;
use crate::rpc::RpcError;
use crate::store::EventRecord;

/// How many chats' tables the hub keeps; the least recently read goes first.
const TABLES_KEPT: usize = 16;
/// How many bytes of recent patches a table keeps for connections that follow it. A connection
/// further behind is told it lagged and reads a page again.
const PATCH_BYTES_KEPT: usize = 2 << 20;

/// One chat's table and its recent patches.
#[derive(Default)]
pub struct Folded {
    table: RowTable,
    recent: VecDeque<(Patch, usize)>,
    recent_bytes: usize,
}

impl Folded {
    fn keep(&mut self, patches: Vec<Patch>) {
        for p in patches {
            let bytes = patch_bytes(&p);
            self.recent_bytes = self.recent_bytes.saturating_add(bytes);
            self.recent.push_back((p, bytes));
        }
        while self.recent_bytes > PATCH_BYTES_KEPT
            && let Some((_, bytes)) = self.recent.pop_front()
        {
            self.recent_bytes = self.recent_bytes.saturating_sub(bytes);
        }
    }

    /// The patches after version `from`, or None when the oldest kept is past it.
    fn since(&self, from: u64) -> Option<Vec<Patch>> {
        if from >= self.table.version() {
            return Some(Vec::new());
        }
        let oldest = self.recent.front()?.0.version();
        if oldest > from.saturating_add(1) {
            return None;
        }
        Some(
            self.recent
                .iter()
                .filter(|(p, _)| p.version() > from)
                .map(|(p, _)| p.clone())
                .collect(),
        )
    }
}

fn patch_bytes(p: &Patch) -> usize {
    match p {
        Patch::Append { text, .. } | Patch::Text { text, .. } => text.len().saturating_add(64),
        Patch::Insert { row, .. } => row.text.len().saturating_add(512),
        Patch::Head { .. } => 512,
    }
}

/// The hub's row tables, by chat id.
#[derive(Default)]
pub struct RowsCache {
    tables: Mutex<Vec<(String, Arc<Mutex<Folded>>)>>,
}

impl RowsCache {
    /// Chat `id`'s table, made empty if the hub holds none; it becomes the most recently read.
    fn table(&self, id: &str) -> Arc<Mutex<Folded>> {
        let mut tables = self.tables.lock_or_recover();
        let found = tables.iter().position(|(chat, _)| chat == id);
        let entry = match found {
            Some(at) => tables.remove(at),
            None => (id.to_owned(), Arc::default()),
        };
        let table = entry.1.clone();
        tables.push(entry);
        if tables.len() > TABLES_KEPT {
            tables.remove(0);
        }
        table
    }

    /// Chat `id`'s table if the hub holds one, without making it the most recently read.
    fn held(&self, id: &str) -> Option<Arc<Mutex<Folded>>> {
        let tables = self.tables.lock_or_recover();
        tables.iter().find(|(chat, _)| chat == id).map(|(_, t)| t.clone())
    }
}

/// Folds chat `id`'s records past the table's newest into it, from the log.
fn catch_up(hub: &Hub, id: &str, folded: &mut Folded) -> Result<(), RpcError> {
    let mut patches = Vec::new();
    let after = folded.table.last_seq();
    let table = &mut folded.table;
    hub.scan_events(id, after, &mut |rec| {
        table.apply(&rec, &mut patches);
        true
    })
    .map_err(|e| RpcError::internal(format!("rows: read the log: {e}")))?;
    folded.keep(patches);
    Ok(())
}

/// A connection that follows a chat's rows: the newest version it was sent.
#[derive(Debug, Default)]
pub struct Following {
    sent: Mutex<u64>,
}

/// `_acpmux/rows {sessionId, afterSeq | beforeSeq, maxBytes, follow}`: one page of the chat's
/// rows (`page.rs`). With neither cursor, the newest rows. `follow` asks for the patches after
/// the page on the live stream; the caller keeps the returned `Following` on its subscription.
pub fn read(
    hub: &Hub,
    id: &str,
    params: &Value,
) -> Result<(Value, Option<Arc<Following>>), RpcError> {
    let seq = |key: &str| -> Result<Option<u64>, RpcError> {
        match params.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(v) => v.as_u64().map(Some).ok_or_else(|| {
                RpcError::invalid_params(format!("{key} must be a non-negative integer"))
            }),
        }
    };
    let cursor = match (seq("afterSeq")?, seq("beforeSeq")?) {
        (Some(_), Some(_)) => {
            return Err(RpcError::invalid_params("name afterSeq or beforeSeq, not both"));
        }
        (Some(after), None) => RowsCursor::After(after),
        (None, Some(before)) => RowsCursor::Before(before),
        (None, None) => RowsCursor::Before(u64::MAX),
    };
    let max = params
        .get("maxBytes")
        .and_then(Value::as_u64)
        .map_or(DEFAULT_ROW_PAGE_BYTES, |b| usize::try_from(b).unwrap_or(usize::MAX));
    let follow = params.get("follow").and_then(Value::as_bool) == Some(true);
    let table = hub.rows.table(id);
    let mut folded = table.lock_or_recover();
    catch_up(hub, id, &mut folded)?;
    let page = folded.table.page(cursor, max);
    let following = follow.then(|| Arc::new(Following { sent: Mutex::new(page.version) }));
    let mut reply = serde_json::to_value(&page)
        .map_err(|e| RpcError::internal(format!("rows: encode the page: {e}")))?;
    if let Some(o) = reply.as_object_mut() {
        o.insert("sessionId".into(), json!(id));
    }
    Ok((reply, following))
}

/// What a following connection is sent for live record `rec` of chat `id`: one
/// `_acpmux/rows_patch` params with the patches it has not had, or `_acpmux/rows_lagged` params
/// when they are no longer kept. None: nothing new.
pub fn live(
    hub: &Hub,
    id: &str,
    rec: &EventRecord,
    following: &Following,
) -> Option<(&'static str, Value)> {
    let table = hub.rows.held(id)?;
    let mut folded = table.lock_or_recover();
    if folded.table.last_seq().saturating_add(1) == rec.seq {
        let mut patches = Vec::new();
        folded.table.apply(rec, &mut patches);
        folded.keep(patches);
    } else if folded.table.last_seq() < rec.seq && catch_up(hub, id, &mut folded).is_err() {
        return None;
    }
    let mut sent = following.sent.lock_or_recover();
    let version = folded.table.version();
    match folded.since(*sent) {
        Some(patches) if patches.is_empty() => None,
        Some(patches) => {
            *sent = version;
            Some((
                crate::rpc::method::MUX_ROWS_PATCH,
                json!({"sessionId": id, "version": version, "lastSeq": folded.table.last_seq(), "patches": patches}),
            ))
        }
        None => {
            *sent = version;
            Some((
                crate::rpc::method::MUX_ROWS_LAGGED,
                json!({"sessionId": id, "version": version, "lastSeq": folded.table.last_seq()}),
            ))
        }
    }
}

/// The rows of chat `id`'s table, if the hub holds one; for tests.
#[cfg(test)]
pub fn held_rows(hub: &Hub, id: &str) -> Option<Vec<super::Row>> {
    let table = hub.rows.held(id)?;
    let folded = table.lock_or_recover();
    Some(folded.table.rows().to_vec())
}

#[cfg(test)]
pub(super) fn kept_patches(folded: &Folded) -> usize {
    folded.recent.len()
}

#[cfg(test)]
pub(super) fn folded_with(records: &[EventRecord]) -> Folded {
    let mut folded = Folded::default();
    let mut patches = Vec::new();
    for rec in records {
        folded.table.apply(rec, &mut patches);
    }
    folded.keep(patches);
    folded
}

#[cfg(test)]
pub(super) fn since(folded: &Folded, from: u64) -> Option<Vec<Patch>> {
    folded.since(from)
}

#[cfg(test)]
pub(super) fn version(folded: &Folded) -> u64 {
    folded.table.version()
}
