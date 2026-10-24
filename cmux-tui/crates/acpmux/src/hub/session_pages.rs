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

/// A session in the list before its summary is built: this daemon's own, or a peer's summary.
enum Listed {
    Local(Arc<Session>),
    Remote(Value),
}

impl Hub {
    /// The session list reply for `params` (`_acpmux/sessions`, `_acpmux/watch`): `{sessions}`
    /// without `limit`, `{sessions, nextCursor}` with it. The list is sorted and its page cut on
    /// each session's `updatedAt` and id, read under its lock, and only the page's summaries are
    /// built: a page cost every session's summary, and the pane walks the whole list a page at a
    /// time (acpmux-audit.md finding 7). The cursor is the snapshot's, so a session that moves
    /// while a summary is built neither repeats nor skips another one.
    pub(crate) fn session_list(&self, params: &Value) -> Result<Value, RpcError> {
        let (limit, cursor) = page_params(params)?;
        let mut keyed: Vec<(u64, String, Listed)> = self
            .sessions()
            .into_iter()
            .map(|s| {
                let (updated, id) = {
                    let m = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    (m.updated_at, m.id.clone())
                };
                (updated, id, Listed::Local(s))
            })
            .collect();
        keyed.extend(self.remote_sessions().into_iter().map(|summary| {
            (updated_ms(&summary), session_id(&summary).to_owned(), Listed::Remote(summary))
        }));
        // Newest first, ties by sessionId: `sort_session_summaries`'s order.
        keyed.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        let start = cursor.map_or(0, |c| c.start_in(keyed.iter().map(|k| (k.0, k.1.as_str()))));
        let page_len = limit.map_or(usize::MAX, |l| usize::try_from(l).unwrap_or(usize::MAX));
        let more = keyed.len().saturating_sub(start) > page_len;
        let page: Vec<_> = keyed.into_iter().skip(start).take(page_len).collect();
        let next = (limit.is_some() && more)
            .then(|| page.last().map(|(u, id, _)| SessionCursor::of(*u, id).to_text()))
            .flatten();
        let sessions: Vec<Value> = page
            .into_iter()
            .map(|(_, _, listed)| match listed {
                Listed::Local(s) => self.session_summary(&s),
                Listed::Remote(summary) => summary,
            })
            .collect();
        Ok(match limit {
            None => json!({"sessions": sessions}),
            Some(_) => json!({"sessions": sessions, "nextCursor": next}),
        })
    }
}

/// `limit` and `cursor` of a session list request.
fn page_params(params: &Value) -> Result<(Option<u64>, Option<SessionCursor>), RpcError> {
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
    Ok((limit, cursor))
}

/// After the session updated at `updated_ms` whose id hashes to `key`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionCursor {
    updated_ms: u64,
    key: u64,
}

impl SessionCursor {
    /// After the session updated at `updated_ms` whose id is `id`.
    fn of(updated_ms: u64, id: &str) -> Self {
        Self { updated_ms: updated_ms.min(MAX_STAMP), key: id_hash(id) }
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

    /// Where the page starts in a list sorted by (`updatedAt`, `sessionId`), newest first. The
    /// named session gone or moved, the page starts at the first session no newer than it was:
    /// one updated in that same millisecond may repeat, none is skipped.
    fn start_in<'a>(self, sorted: impl Iterator<Item = (u64, &'a str)> + Clone) -> usize {
        let stamped = sorted.map(|(updated, id)| (updated.min(MAX_STAMP), id));
        stamped
            .clone()
            .position(|(stamp, id)| stamp == self.updated_ms && id_hash(id) == self.key)
            .map(|at| at + 1)
            .unwrap_or_else(|| {
                let count = stamped.clone().count();
                stamped.clone().position(|(stamp, _)| stamp <= self.updated_ms).unwrap_or(count)
            })
    }
}

fn updated_ms(session: &Value) -> u64 {
    session.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
}

/// The cursor's timestamp is `updatedAt` clamped to 12 hex digits (year 10889), the same in the
/// cursor and in both comparisons, so a huge stamp still matches its own cursor and the cursor
/// stays at most 30 characters.
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
