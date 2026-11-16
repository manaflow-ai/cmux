//! `_acpmux/usage` on v1: `{sessionIds: [...]}` or `{sort: "cost" | "context", cursor?}`.
//! Rank starts with 20 rows; continuation returns up to 100. Every reply has count and totals
//! over all indexed rows, local and mirrored. Totals expose `{value, known}` per measure;
//! `ready` is false until the initial background pass completes; it never means zero usage.
//! value is null when no row knows it. Unknown keys appear in `missing`, byte spill in `rest`.
//! Cursors bind the daemon run and sort and carry the last rank. A row that moves while pages
//! are being shown can therefore occur on either side of the cursor (and may be seen twice or
//! not at all); a changed daemon run or sort returns `usage.cursor_stale` with `resync: true`.
//! Rank requests start v1's throttled whole pass in the background and answer from this table;
//! they never wait for that pass. No transcript, session map, row or log walk happens here.

use super::Hub;
use super::usage_order::{MAX_BYTES, MAX_KEYS, Rank, Sort, UsageOrder};
use crate::rpc::RpcError;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    epoch: String,
    sort: Sort,
    after: Rank,
}

fn invalid(message: &str) -> RpcError {
    RpcError::invalid_params(message)
}
fn stale() -> RpcError {
    invalid("usage changed; read the first rank page again")
        .with_data(json!({"reason": "usage.cursor_stale", "resync": true}))
}

impl Hub {
    pub(crate) fn usage_reply(&self, params: &Value) -> Result<Value, RpcError> {
        let params = params.as_object().ok_or_else(|| invalid("usage params must be an object"))?;
        if serde_json::to_vec(params).map_err(|e| RpcError::internal(e.to_string()))?.len()
            > MAX_BYTES
        {
            return Err(invalid("usage params exceed 256 KiB"));
        }
        for key in params.keys() {
            if !matches!(key.as_str(), "sessionIds" | "sort" | "cursor" | "_meta") {
                return Err(invalid("usage accepts sessionIds or sort and cursor"));
            }
        }
        let sort: Sort = params
            .get("sort")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|_| invalid("usage sort must be cost or context"))?
            .unwrap_or_default();
        // Persistent clones release the local writer immediately; the peer snapshot is lock-free.
        let local = self.usage_stats.order.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let remote = self.remote_sessions.read();
        let remote = &remote.usage;
        let mut reply = Map::from_iter([
            ("rows".into(), json!([])),
            ("count".into(), json!(local.len() + remote.len())),
            ("totals".into(), local.totals_with(remote)),
            ("nextCursor".into(), Value::Null),
            (
                "lastPassAt".into(),
                json!(self.usage_stats.last_pass_at.load(std::sync::atomic::Ordering::Acquire)),
            ),
            (
                "ready".into(),
                json!(self.usage_stats.ready.load(std::sync::atomic::Ordering::Acquire)),
            ),
        ]);
        if let Some(ids) = params.get("sessionIds") {
            if params.contains_key("sort") || params.contains_key("cursor") {
                return Err(invalid("usage sessionIds cannot be combined with rank parameters"));
            }
            let ids = ids.as_array().ok_or_else(|| invalid("sessionIds must be an array"))?;
            if ids.is_empty() || ids.len() > MAX_KEYS {
                return Err(invalid("usage sessionIds takes 1 to 100 keys"));
            }
            let keys: Vec<&str> = ids
                .iter()
                .map(|v| v.as_str().filter(|k| !k.is_empty() && k.len() <= 1024))
                .collect::<Option<_>>()
                .ok_or_else(|| {
                    invalid("usage keys must be nonempty strings of at most 1024 bytes")
                })?;
            let mut missing = Vec::new();
            let mut rest = Vec::new();
            let mut rows = Vec::new();
            // Reserve all requested keys (missing/rest) and envelope space before copying rows.
            let mut bytes = serde_json::to_vec(&keys).unwrap_or_default().len() + 4096;
            for key in keys {
                if !rest.is_empty() {
                    rest.push(key);
                    continue;
                }
                let Some(entry) = local.get(key).or_else(|| remote.get(key)) else {
                    missing.push(key);
                    continue;
                };
                if bytes.saturating_add(entry.bytes + 1) > MAX_BYTES - 1024 {
                    if rows.is_empty() {
                        return Err(row_too_large());
                    }
                    rest.push(key);
                    continue;
                }
                bytes += entry.bytes + 1;
                rows.push(entry.row.clone());
            }
            reply.insert("rows".into(), json!(rows));
            reply.insert("missing".into(), json!(missing));
            reply.insert("rest".into(), json!(rest));
        } else {
            let cursor: Option<Cursor> = match params.get("cursor") {
                None | Some(Value::Null) => None,
                Some(Value::String(text)) if text.len() <= 4096 => {
                    Some(serde_json::from_str(text).map_err(|_| invalid("invalid usage cursor"))?)
                }
                _ => return Err(invalid("usage cursor must be a string of at most 4096 bytes")),
            };
            if let Some(c) = &cursor
                && (c.epoch != self.events.list_epoch() || c.sort != sort)
            {
                return Err(stale());
            }
            let limit = if cursor.is_some() { MAX_KEYS } else { 20 };
            let after = cursor.as_ref().map(|c| &c.after);
            let candidates = candidates(&local, remote, sort, after, limit + 1);
            let mut bytes = 8192; // totals, cursor and JSON-RPC envelope, independent of N
            let mut rows = Vec::new();
            let mut last = None;
            let mut more = false;
            for entry in candidates {
                if rows.len() == limit || bytes + entry.bytes + 1 > MAX_BYTES - 1024 {
                    if rows.is_empty() {
                        return Err(row_too_large());
                    }
                    more = true;
                    break;
                }
                bytes += entry.bytes + 1;
                last = Some(entry.rank(sort));
                rows.push(entry.row.clone());
            }
            reply.insert("rows".into(), json!(rows));
            if more && let Some(after) = last {
                let cursor = Cursor { epoch: self.events.list_epoch().to_owned(), sort, after };
                let text = serde_json::to_string(&cursor)
                    .map_err(|e| RpcError::internal(e.to_string()))?;
                if text.len() > 4096 {
                    return Err(row_too_large());
                }
                reply.insert("nextCursor".into(), Value::String(text));
            }
        }
        // Hard bound, including missing/rest and totals. Never return a too-large first row.
        if serde_json::to_vec(&reply).map_err(|e| RpcError::internal(e.to_string()))?.len()
            > MAX_BYTES - 1024
        {
            return Err(row_too_large());
        }
        Ok(Value::Object(reply))
    }
}

fn row_too_large() -> RpcError {
    invalid("usage row exceeds the 256 KiB reply bound")
        .with_data(json!({"reason": "usage.row_too_large"}))
}

/// Read at most two bounded ranges; sorting these candidates never depends on total rows.
fn candidates(
    local: &UsageOrder,
    remote: &UsageOrder,
    sort: Sort,
    after: Option<&Rank>,
    limit: usize,
) -> Vec<std::sync::Arc<super::usage_order::Entry>> {
    let mut rows = local.page(sort, after, limit);
    rows.extend(remote.page(sort, after, limit));
    rows.sort_by_cached_key(|row| row.rank(sort));
    rows.truncate(limit);
    rows
}

#[cfg(test)]
#[path = "usage_request_tests.rs"]
mod tests;
