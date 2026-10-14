//! Part of `Hub`; see `hub/mod.rs`. Keyset pages of the session list, shared by
//! `_acpmux/sessions` and `_acpmux/watch`.
//!
//! The list is newest first by `updatedAt`, then by `sessionId`. A client that
//! sends `limit` gets that many sessions and a `nextCursor` naming the last one
//! (null when the list is done); `cursor` starts the page after the session it
//! names. A session that moves to the top or leaves meanwhile neither repeats
//! nor skips another one; one that moves to the top before its page is read is
//! not in a later page, and reaches a watching client as `_acpmux/session_changed`.
//! Without `limit` the reply is the whole list, as before.

use super::*;

/// Sorts session summaries newest first, ties by `sessionId` ascending. The
/// summaries are snapshots, so the order is total while sorting.
pub(crate) fn sort_session_summaries(list: &mut [Value]) {
    list.sort_by(|a, b| {
        updated_ms(b).cmp(&updated_ms(a)).then_with(|| session_id(a).cmp(session_id(b)))
    });
}

/// The session list reply for `params`: `{sessions}` without `limit`,
/// `{sessions, nextCursor}` with it.
pub(crate) fn session_list_reply(sorted: Vec<Value>, params: &Value) -> Result<Value, RpcError> {
    let limit = match params.get("limit") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64()
                .filter(|&n| n > 0)
                .ok_or_else(|| RpcError::invalid_params("limit must be a positive integer"))?,
        ),
    };
    let cursor =
        match params.get("cursor") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(SessionCursor::parse(text).ok_or_else(|| {
                RpcError::invalid_params(format!("cursor {text:?} is not a cursor"))
            })?),
            Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
        };
    let start = cursor.map_or(0, |c| c.start(&sorted));
    let mut sessions: Vec<Value> = sorted.into_iter().skip(start).collect();
    let Some(limit) = limit else {
        return Ok(json!({"sessions": sessions}));
    };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let next = if sessions.len() > limit {
        sessions.truncate(limit);
        sessions.last().map(|last| SessionCursor::after(last).to_text())
    } else {
        None
    };
    Ok(json!({"sessions": sessions, "nextCursor": next}))
}

/// After the session updated at `updated_ms` whose id hashes to `key`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionCursor {
    updated_ms: u64,
    key: u64,
}

impl SessionCursor {
    fn after(session: &Value) -> Self {
        Self { updated_ms: stamp(session), key: id_hash(session_id(session)) }
    }

    /// `k<stamp hex>.<id hash hex>`: at most 30 characters (the app passes at most 32).
    fn to_text(self) -> String {
        format!("k{:x}.{:016x}", self.updated_ms, self.key)
    }

    fn parse(text: &str) -> Option<Self> {
        let (updated, key) = text.strip_prefix('k')?.split_once('.')?;
        if updated.is_empty() || updated.len() > 12 || key.is_empty() || key.len() > 16 {
            return None;
        }
        Some(Self {
            updated_ms: u64::from_str_radix(updated, 16).ok()?,
            key: u64::from_str_radix(key, 16).ok()?,
        })
    }

    /// Where the page starts in `sorted`. The named session gone or moved, the
    /// page starts at the first session no newer than it was: one updated in
    /// that same millisecond may repeat, none is skipped.
    fn start(self, sorted: &[Value]) -> usize {
        sorted
            .iter()
            .position(|s| stamp(s) == self.updated_ms && id_hash(session_id(s)) == self.key)
            .map(|at| at + 1)
            .unwrap_or_else(|| {
                sorted.iter().position(|s| stamp(s) <= self.updated_ms).unwrap_or(sorted.len())
            })
    }
}

fn updated_ms(session: &Value) -> u64 {
    session.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
}

/// The cursor's timestamp: `updatedAt` clamped to 12 hex digits (year 10889), the same in the
/// cursor and in both comparisons, so a huge stamp still matches its own cursor and the cursor
/// stays at most 30 characters.
fn stamp(session: &Value) -> u64 {
    updated_ms(session).min(MAX_STAMP)
}

const MAX_STAMP: u64 = 0xffff_ffff_ffff;

fn session_id(session: &Value) -> &str {
    session.get("sessionId").and_then(Value::as_str).unwrap_or("")
}

/// FNV-1a of the session id: the same in every daemon run.
fn id_hash(id: &str) -> u64 {
    id.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
