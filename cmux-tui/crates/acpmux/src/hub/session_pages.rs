//! Part of `Hub`; see `hub/mod.rs`. Keyset pages of the session list, shared by
//! `_acpmux/sessions` and `_acpmux/watch`.
//!
//! The list is newest first by `updatedAt`, then by `sessionId`. A client that
//! sends `limit` gets that many sessions and a `nextCursor` naming the last one
//! (null when the list is done); `cursor` starts the page after the session it
//! names. A session that moves to the top or leaves meanwhile neither repeats
//! nor skips another one; one that moves to the top before its page is read is
//! not in a later page, and reaches a watching client as `_acpmux/session_changed`.
//! Without `limit` the reply is the whole list, as before, unless it is too large for one
//! message: then it goes in pages by size, each with the `nextCursor` of the rest
//! (`Snapshot::bounded`, [`byte_page`]). `orderBy: "sessionId"`
//! opts into stable ID ordering, so updates cannot move an unread session past
//! the cursor (used by the quit census, which does not subscribe to changes).
//!
//! `peer`, `status`, `localOnly` and `excludeStatus` narrow the list before it
//! is paged. A caller that only needs this daemon's live sessions can therefore
//! avoid walking the peer mirror. Only
//! `_acpmux/sessions` takes them: a watch streams every session's changes, so
//! a filtered first page would promise a scope its events do not keep
//! (`refuse_watch_filters`).

use super::*;

/// Sorts session summaries newest first, ties by `sessionId` ascending, then by `peer` (this
/// daemon's own first): a chat here and its copy on a peer keep one order. The summaries are
/// snapshots, so the order is total while sorting.
pub(crate) fn sort_session_summaries(list: &mut [Value]) {
    list.sort_by(|a, b| {
        updated_ms(b)
            .cmp(&updated_ms(a))
            .then_with(|| session_id(a).cmp(session_id(b)))
            .then_with(|| peer(a).cmp(&peer(b)))
    });
}

/// The session list reply for `params`: `{sessions}` without `limit`,
/// `{sessions, nextCursor}` with it.
pub(crate) fn session_list_reply(sorted: Vec<Value>, params: &Value) -> Result<Value, RpcError> {
    session_list_reply_borrowed(&sorted, params)
}

/// Pick rows by reference from the shared session-list snapshot, then clone only rows
/// actually returned. A list page of one must not copy all 3,000 session keys first.
pub(crate) fn session_list_reply_borrowed(sorted: &[Value], params: &Value) -> Result<Value, RpcError> {
    let limit = match params.get("limit") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64()
                .filter(|&n| n > 0)
                .ok_or_else(|| RpcError::invalid_params("limit must be a positive integer"))?,
        ),
    };
    let order = text_filter(params, "orderBy")?;
    if order.is_some_and(|value| value != "sessionId") {
        return Err(RpcError::invalid_params("orderBy must be sessionId"));
    }
    let cursor = if order.is_some() {
        None
    } else {
        match params.get("cursor") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(SessionCursor::parse(text).ok_or_else(|| {
                RpcError::invalid_params(format!("cursor {text:?} is not a cursor"))
            })?),
            Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
        }
    };
    let peer = text_filter(params, "peer")?;
    let status = text_filter(params, "status")?;
    let local_only = bool_filter(params, "localOnly")?;
    if order.is_some() && !local_only {
        return Err(RpcError::invalid_params("orderBy sessionId requires localOnly"));
    }
    let excluded = status_filter(params, "excludeStatus")?;
    let selected: Vec<&Value> = sorted
        .iter()
        .filter(|s| peer.is_none_or(|p| s.get("peer").and_then(Value::as_str) == Some(p)))
        .filter(|s| status.is_none_or(|st| s.get("status").and_then(Value::as_str) == Some(st)))
        .filter(|s| !local_only || s.get("peer").and_then(Value::as_str).is_none())
        .filter(|s| {
            s.get("status").and_then(Value::as_str).is_none_or(|st| !excluded.contains(&st))
        })
        .collect();
    if order.is_some() {
        return session_id_page(selected, params, limit);
    }
    let start = cursor.map_or(0, |c| c.start(&selected));
    let mut sessions: Vec<&Value> = selected.into_iter().skip(start).collect();
    let Some(limit) = limit else {
        return Ok(page(sessions.into_iter().cloned().collect(), None));
    };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let next = if sessions.len() > limit {
        sessions.truncate(limit);
        sessions.last().map(|last| SessionCursor::after(last).to_text())
    } else {
        None
    };
    Ok(page(sessions.into_iter().cloned().collect(), Some(next.map_or(Value::Null, Value::String))))
}

/// A page cut by bytes rather than by count, for a reply that has no `limit` to page by (ACP's
/// `session/list`): of the rows whose paging `keys` are given, those after `cursor` (a
/// `nextCursor` of this list) that `row` makes and whose `size`s fit in `budget`, at least one,
/// and the cursor after the last of them when rows are left. Only the page's rows are made.
///
/// Pages go in the order of [`page_key`], a hash of each row's `sessionId` and `peer`, not
/// newest first, and the cursor is that hash, 33 bytes whatever the ids: a session that
/// updates or leaves while a client pages moves no other, so none is skipped or repeated. A
/// row listed twice (one id, one peer) comes once. A page never ends between rows of one hash,
/// which two different rows share only if 128-bit hashes collide.
pub(crate) fn byte_page<R>(
    keys: &[Value],
    cursor: Option<&str>,
    budget: usize,
    row: impl Fn(usize) -> R,
    size: impl Fn(&R) -> usize,
) -> Result<(Vec<R>, Option<String>), RpcError> {
    let after = match cursor {
        None => None,
        Some(text) => Some(
            text.strip_prefix('h')
                .filter(|hex| hex.len() == 32)
                .and_then(|hex| u128::from_str_radix(hex, 16).ok())
                .ok_or_else(|| {
                    RpcError::invalid_params(format!("cursor {text:?} is not a cursor"))
                })?,
        ),
    };
    let pair = |at: usize| keys.get(at).map(|key| (session_id(key), peer(key)));
    let mut order: Vec<(u128, usize)> = keys
        .iter()
        .enumerate()
        .map(|(at, key)| (page_key(key), at))
        .filter(|(hash, _)| after.is_none_or(|after| *hash > after))
        .collect();
    // Stable, so of a row listed twice the first is kept.
    order.sort_by(|(a, at), (b, bt)| a.cmp(b).then_with(|| pair(*at).cmp(&pair(*bt))));
    order.dedup_by(|(_, at), (_, bt)| pair(*at) == pair(*bt));
    let (mut page, mut used, mut last) = (Vec::new(), 0_usize, None);
    for &(hash, at) in &order {
        let value = row(at);
        // One more byte for the comma between rows.
        let bytes = size(&value).saturating_add(1);
        let total = used.saturating_add(bytes);
        if last.is_some_and(|last| last != hash) && total > budget {
            break;
        }
        (used, last) = (total, Some(hash));
        page.push(value);
    }
    let next = (page.len() < order.len()).then(|| format!("h{:032x}", last.unwrap_or_default()));
    Ok((page, next))
}

/// IDs are immutable: an unread session updating between pages cannot be lost.
fn session_id_page(
    mut rows: Vec<&Value>,
    params: &Value,
    limit: Option<u64>,
) -> Result<Value, RpcError> {
    let after = match params.get("cursor") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(
            text.strip_prefix("s:")
                .filter(|id| !id.is_empty())
                .ok_or_else(|| RpcError::invalid_params("cursor is not a sessionId cursor"))?,
        ),
        Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
    };
    rows.retain(|row| after.is_none_or(|id| session_id(row) > id));
    rows.sort_by(|a, b| session_id(a).cmp(session_id(b)));
    let Some(limit) = limit else {
        return Ok(page(rows.into_iter().cloned().collect(), None));
    };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let next = if rows.len() > limit {
        rows.truncate(limit);
        rows.last().map(|row| Value::String(format!("s:{}", session_id(row))))
    } else {
        None
    };
    Ok(page(rows.into_iter().cloned().collect(), Some(next.unwrap_or(Value::Null))))
}

/// `{sessions, nextCursor?}`, moving the sessions in: `json!` would deep-copy the whole list.
fn page(sessions: Vec<Value>, next: Option<Value>) -> Value {
    let mut reply = serde_json::Map::new();
    reply.insert("sessions".to_owned(), Value::Array(sessions));
    if let Some(next) = next {
        reply.insert("nextCursor".to_owned(), next);
    }
    Value::Object(reply)
}

/// A string filter param: absent, null or empty is no filter (the schema allows all three);
/// another type is refused.
fn text_filter<'a>(params: &'a Value, name: &str) -> Result<Option<&'a str>, RpcError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok((!text.is_empty()).then_some(text.as_str())),
        Some(_) => Err(RpcError::invalid_params(format!("{name} must be a string"))),
    }
}

fn bool_filter(params: &Value, name: &str) -> Result<bool, RpcError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(RpcError::invalid_params(format!("{name} must be a boolean"))),
    }
}

fn status_filter<'a>(params: &'a Value, name: &str) -> Result<Vec<&'a str>, RpcError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params(format!("{name} must contain strings")))
            })
            .collect(),
        Some(_) => Err(RpcError::invalid_params(format!("{name} must be an array"))),
    }
}

/// `_acpmux/watch` refuses `peer` and `status`: its events cover every session.
pub(crate) fn refuse_watch_filters(params: &Value) -> Result<(), RpcError> {
    for name in ["peer", "status", "localOnly", "excludeStatus", "orderBy"] {
        if name == "localOnly" {
            if bool_filter(params, name)? {
                return Err(RpcError::invalid_params(format!(
                    "{name} filters _acpmux/sessions only: a watch streams every session"
                )));
            }
            continue;
        }
        if name == "excludeStatus" {
            if !status_filter(params, name)?.is_empty() {
                return Err(RpcError::invalid_params(format!(
                    "{name} filters _acpmux/sessions only: a watch streams every session"
                )));
            }
            continue;
        }
        if text_filter(params, name)?.is_some() {
            return Err(RpcError::invalid_params(format!(
                "{name} filters _acpmux/sessions only: a watch streams every session"
            )));
        }
    }
    Ok(())
}

/// The `cursor` that starts a page after `session`, the `nextCursor` a page ending on it carries:
/// for a client that stops in the middle of a page (`acpmux ls --limit` with a filter of its own).
/// A daemon whose cursor keys differ starts at the first session no newer than it
/// ([`SessionCursor::start`]): one of that same millisecond may repeat, none is skipped.
pub(crate) fn cursor_after(session: &Value) -> String {
    SessionCursor::after(session).to_text()
}

/// After the session updated at `updated_ms` whose id and peer hash to `key` ([`row_key`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionCursor {
    updated_ms: u64,
    key: u64,
}

impl SessionCursor {
    fn after(session: &Value) -> Self {
        Self { updated_ms: stamp(session), key: row_key(session) }
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
    fn start(self, sorted: &[&Value]) -> usize {
        sorted
            .iter()
            .position(|s| stamp(s) == self.updated_ms && row_key(s) == self.key)
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

fn peer(session: &Value) -> Option<&str> {
    session.get("peer").and_then(Value::as_str)
}

/// Where a row stands in [`byte_page`]'s order: two FNV-1a hashes of its `sessionId` and
/// `peer` ([`row_key`]'s bytes), the same in every daemon run.
fn page_key(session: &Value) -> u128 {
    let high = fnv(0xcbf2_9ce4_8422_2325, row_key_bytes(session));
    let low = fnv(0x6c62_272e_07bb_0142, row_key_bytes(session));
    (u128::from(high) << 64) | u128::from(low)
}

/// FNV-1a of the session id, then, for a peer's row, a NUL and the peer's name: the same in
/// every daemon run, and this daemon's own rows keep the key they had before peers were in it.
fn row_key(session: &Value) -> u64 {
    fnv(0xcbf2_9ce4_8422_2325, row_key_bytes(session))
}

fn row_key_bytes(session: &Value) -> impl Iterator<Item = u8> + '_ {
    let peer = peer(session).map(|p| std::iter::once(0).chain(p.bytes()));
    session_id(session).bytes().chain(peer.into_iter().flatten())
}

fn fnv(basis: u64, bytes: impl Iterator<Item = u8>) -> u64 {
    bytes.fold(basis, |hash, byte| (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn json_bytes(value: &Value) -> usize {
        value.to_string().len()
    }

    fn name(row: &Value) -> String {
        format!("{}{}", session_id(row), peer(row).map_or(String::new(), |p| format!("@{p}")))
    }

    /// Every page `budget` cuts, read from the first, with `between` run
    /// on the rows (and the names read so far) after each page.
    fn read_pages(
        rows: &mut Vec<Value>,
        budget: usize,
        mut between: impl FnMut(&mut Vec<Value>, &[String]),
    ) -> Vec<String> {
        let (mut read, mut cursor) = (Vec::new(), None::<String>);
        loop {
            let (page, next) = byte_page(
                rows,
                cursor.as_deref(),
                budget,
                |at| json!({"name": name(&rows[at])}),
                json_bytes,
            )
            .unwrap();
            assert!(!page.is_empty());
            read.extend(page.iter().map(|row| row["name"].as_str().unwrap().to_owned()));
            assert!(read.len() <= rows.len() + 2, "{read:?}");
            match next {
                Some(next) => cursor = Some(next),
                None => return read,
            }
            between(rows, &read);
        }
    }

    fn sorted(mut names: Vec<String>) -> Vec<String> {
        names.sort();
        names
    }

    /// A chat here, its copies on two peers and a row listed twice: at every budget each
    /// comes once.
    #[test]
    fn byte_pages_read_each_row_once() {
        let rows = vec![
            json!({"sessionId": "z", "updatedAt": 1}),
            json!({"sessionId": "dup", "updatedAt": 5, "peer": "p2"}),
            json!({"sessionId": "a", "updatedAt": 9}),
            json!({"sessionId": "dup", "updatedAt": 5}),
            json!({"sessionId": "dup", "updatedAt": 5, "peer": "p1"}),
            json!({"sessionId": "a", "updatedAt": 9}),
        ];
        for budget in [1, 40, 80, 120, 10_000] {
            let read = read_pages(&mut rows.clone(), budget, |_, _| {});
            assert_eq!(sorted(read), ["a", "dup", "dup@p1", "dup@p2", "z"], "budget {budget}");
        }
        let bad = |cursor| byte_page(&rows, Some(cursor), 1, |_| json!({}), json_bytes).is_err();
        assert!(bad("k5.0011") && bad("h") && bad("h12") && bad(&format!("h{}", "g".repeat(32))));
    }

    /// Between pages an unread session becomes the newest, and a read one and an unread one
    /// leave: no row is skipped or repeated.
    #[test]
    fn byte_pages_hold_their_place_while_sessions_update_and_leave() {
        let mut rows: Vec<Value> = ["a", "b", "c", "d", "e", "f"]
            .iter()
            .enumerate()
            .map(|(i, id)| json!({"sessionId": id, "updatedAt": 10 - i}))
            .collect();
        let mut gone = None;
        let read = read_pages(&mut rows, 1, |rows, read| {
            let unread: Vec<String> = rows.iter().map(name).filter(|n| !read.contains(n)).collect();
            match read.len() {
                1 => rows.iter_mut().filter(|r| name(r) == unread[0]).for_each(|r| {
                    r["updatedAt"] = json!(100);
                }),
                2 => {
                    gone = Some(unread[0].clone());
                    rows.retain(|r| name(r) != unread[0] && name(r) != read[0]);
                }
                _ => {}
            }
            sort_session_summaries(rows);
        });
        let mut all: Vec<String> =
            ["a", "b", "c", "d", "e", "f"].map(String::from).into_iter().collect();
        all.retain(|n| Some(n) != gone.as_ref());
        assert_eq!(sorted(read), all);
    }

    /// The cursor is 33 bytes however long the ids are.
    #[test]
    fn a_byte_page_cursor_stays_small_for_a_huge_id() {
        let rows = vec![
            json!({"sessionId": "x".repeat(1 << 20), "peer": "p".repeat(1 << 20)}),
            json!({"sessionId": "y".repeat(1 << 20)}),
        ];
        let (page, next) = byte_page(&rows, None, 1, |at| json!({"at": at}), json_bytes).unwrap();
        assert_eq!(page.len(), 1);
        assert_eq!(next.unwrap().len(), 33);
    }

    #[test]
    fn stable_scan_keeps_an_unread_chief_when_it_updates_and_cursor_row_leaves() {
        let mut rows = vec![
            json!({"sessionId": "a", "updatedAt": 3, "status": "idle"}),
            json!({"sessionId": "b", "updatedAt": 2, "status": "running", "name": "optchat-home"}),
            json!({"sessionId": "c", "updatedAt": 1, "status": "idle"}),
        ];
        let mut params = json!({"localOnly": true, "excludeStatus": ["closed"],
            "orderBy": "sessionId", "limit": 1});
        let first = session_list_reply(rows.clone(), &params).unwrap();
        assert_eq!(ids(&first), ["a"]);
        params["cursor"] = first["nextCursor"].clone();
        rows.remove(0);
        rows[0]["updatedAt"] = json!(100);
        sort_session_summaries(&mut rows);
        let second = session_list_reply(rows.clone(), &params).unwrap();
        assert_eq!(ids(&second), ["b"]);
        params["cursor"] = second["nextCursor"].clone();
        let last = session_list_reply(rows, &params).unwrap();
        assert_eq!(ids(&last), ["c"]);
        assert!(last["nextCursor"].is_null());
        assert!(refuse_watch_filters(&json!({"orderBy": "sessionId"})).is_err());
        assert!(session_list_reply(list(), &json!({"orderBy": "sessionId"})).is_err());
    }

    fn list() -> Vec<Value> {
        let mut list = vec![
            json!({"sessionId": "a", "updatedAt": 5, "peer": "huge-blue", "status": "closed"}),
            json!({"sessionId": "b", "updatedAt": 4, "peer": "huge-blue", "status": "idle"}),
            json!({"sessionId": "c", "updatedAt": 3, "peer": "huge-blue", "status": "closed"}),
            json!({"sessionId": "d", "updatedAt": 2, "peer": "cmux16", "status": "closed"}),
            json!({"sessionId": "e", "updatedAt": 1, "status": "closed"}),
        ];
        sort_session_summaries(&mut list);
        list
    }

    fn ids(reply: &Value) -> Vec<&str> {
        reply["sessions"].as_array().unwrap().iter().map(session_id).collect()
    }

    #[test]
    fn peer_and_status_narrow_the_list_before_it_is_paged() {
        let reply = session_list_reply(
            list(),
            &json!({"peer": "huge-blue", "status": "closed", "limit": 1}),
        )
        .unwrap();
        assert_eq!(ids(&reply), ["a"]);
        let next = reply["nextCursor"].as_str().unwrap().to_owned();
        let reply = session_list_reply(
            list(),
            &json!({"peer": "huge-blue", "status": "closed", "limit": 1, "cursor": next}),
        )
        .unwrap();
        assert_eq!(ids(&reply), ["c"]);
        assert_eq!(reply["nextCursor"], Value::Null);
    }

    #[test]
    fn each_filter_alone_and_none_keeps_the_old_reply() {
        assert_eq!(ids(&session_list_reply(list(), &json!({"peer": "cmux16"})).unwrap()), ["d"]);
        assert_eq!(
            ids(&session_list_reply(list(), &json!({"status": "closed"})).unwrap()),
            ["a", "c", "d", "e"]
        );
        assert_eq!(
            ids(&session_list_reply(list(), &json!({"peer": null})).unwrap()),
            ["a", "b", "c", "d", "e"]
        );
        assert_eq!(
            ids(&session_list_reply(
                vec![
                    json!({"sessionId": "local", "updatedAt": 9, "status": "idle"}),
                    json!({"sessionId": "remote", "updatedAt": 8, "peer": "b", "status": "idle"}),
                    json!({"sessionId": "old", "updatedAt": 7, "status": "closed"}),
                ],
                &json!({"localOnly": true, "excludeStatus": ["closed"]}),
            )
            .unwrap()),
            ["local"]
        );
    }

    #[test]
    fn an_empty_filter_is_none_and_a_non_string_one_is_refused() {
        assert_eq!(ids(&session_list_reply(list(), &json!({"peer": ""})).unwrap()).len(), 5);
        assert!(session_list_reply(list(), &json!({"status": 3})).is_err());
        assert!(session_list_reply(list(), &json!({"localOnly": "yes"})).is_err());
        assert!(session_list_reply(list(), &json!({"excludeStatus": [3]})).is_err());
    }

    #[test]
    fn a_watch_refuses_filters_its_events_would_not_keep() {
        assert!(refuse_watch_filters(&json!({"peer": "huge-blue"})).is_err());
        assert!(refuse_watch_filters(&json!({"status": "closed", "limit": 5})).is_err());
        assert!(refuse_watch_filters(&json!({"limit": 5, "peer": null, "status": ""})).is_ok());
        assert!(refuse_watch_filters(&json!({"localOnly": true})).is_err());
        assert!(refuse_watch_filters(&json!({"excludeStatus": ["closed"]})).is_err());
    }
}

#[cfg(test)]
#[path = "session_pages_bench_tests.rs"]
mod narrow_read_tests;
