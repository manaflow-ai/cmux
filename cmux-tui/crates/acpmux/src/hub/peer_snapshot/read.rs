//! Part of `peer_snapshot.rs`: `_acpmux/peer_snapshot`, the one hook a client (the app's agent
//! pane, the VM start and resume path) reads a peer session's kept copy through, whether or not
//! the peer answers. The store's thread answers it from memory or from the copy's file.

use super::*;
use crate::session_identity::SessionReceipt;

/// Records a reply carries by default; at most [`SESSION_EVENTS`].
const READ_LIMIT: usize = 400;

impl PeerSnapshots {
    /// The `_acpmux/peer_snapshot` reply for peer `peer`'s session `mux`: its newest `limit`
    /// records within `max_bytes`, oldest first. A `generation` (the row's `createdAt`) other than
    /// the copy's reads nothing. `row` is the session's row now, if the peer still lists it.
    pub(crate) fn read(
        &self,
        (peer, mux): (&str, &str),
        bounds: (usize, usize),
        generation: Option<u64>,
        row: Option<Value>,
    ) -> Value {
        let mut reply = json!({
            "peer": peer, "sessionId": mux, "qualifiedSessionId": format!("{peer}/{mux}"),
            "events": [], "lastSeq": 0, "generation": null, "capturedAt": null, "hostLastSeq": null,
            "hasMore": false, "stale": true, "summary": row.map(snapshot_row),
        });
        let (tx, rx) = mpsc::sync_channel(1);
        let key = (peer.to_owned(), mux.to_owned());
        // Room reserved like a capture's (`QUEUED_BYTES`): with the queue full, the reply says
        // nothing is kept rather than wait behind it. A loss not sent yet goes first, as before a
        // flush (`flush_now`): a read that starts the thread again never reads what it removes.
        let sent = {
            let mut dropped = self.dropped();
            self.send_unsent(&mut dropped)
                && self.reserve(OP_BYTES)
                && self.enqueue(OP_BYTES, Op::Read { key, generation, bounds, reply: tx })
        };
        if sent
            && let Ok(got) = blocking(|| rx.recv_timeout(ANSWER_WITHIN))
            && let Some(got) = got.as_object()
        {
            for (k, v) in got {
                if k != "summary" || reply["summary"].is_null() {
                    reply[k] = v.clone();
                }
            }
        }
        reply
    }
}

impl Store {
    /// The copy of `key` within `limit` records and `max_bytes`, newest kept; `{}` when there
    /// is none. A `generation` other than the copy's reads nothing, and drops nothing: the caller
    /// read it before this op, so the listing (`Op::Listed`, in order) decides which copy goes.
    pub(super) fn read(
        &mut self,
        key: &Key,
        generation: Option<u64>,
        (limit, max_bytes): (usize, usize),
    ) -> Value {
        let other = |c: &Kept| generation.is_some() && c.head.generation != generation;
        if self.copies.get(key).is_none_or(other) || !self.load(key) {
            return json!({});
        }
        let Some(c) = self.copies.get_mut(key) else { return json!({}) };
        c.used = now_ms();
        let all = c.records.as_ref().map_or(0, BTreeMap::len);
        let (mut events, mut bytes) = (Vec::new(), 0usize);
        for r in c.records.iter().flat_map(|r| r.values().rev()) {
            let b = usize::try_from(record_bytes(r)).unwrap_or(usize::MAX);
            if events.len() >= limit || (!events.is_empty() && bytes.saturating_add(b) > max_bytes)
            {
                break;
            }
            bytes += b;
            events.push(r.clone());
        }
        events.reverse();
        let h = &c.head;
        json!({
            "events": events, "lastSeq": h.last_seq, "generation": h.generation,
            "capturedAt": h.captured_at, "hostLastSeq": h.host_last_seq,
            "hasMore": !(h.from_start && events.len() == all), "summary": h.summary,
        })
    }
}

impl Hub {
    /// `_acpmux/peer_snapshot {sessionId, host?, limit?, maxBytes?}`: this daemon's copy of a peer
    /// session's events, answered whether or not the peer is reachable, always `stale`.
    /// `sessionId` is an id or `HOST/name`, or with `host` the peer's own id (a lease that ended).
    pub fn peer_snapshot(&self, params: &Value) -> Result<Value, RpcError> {
        let id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
        let key = match params.get("host").and_then(Value::as_str).filter(|s| !s.is_empty()) {
            Some(h) if !id.contains('/') => format!("{h}/{id}"),
            _ => id.to_owned(),
        };
        let (peer, mux, row) = match self.resolve_remote(&key) {
            Some((p, mux, row)) => (p.name.clone(), mux, Some(row)),
            None => {
                let (h, m) = SessionReceipt::split_qualified_id(&key).ok_or_else(|| {
                    RpcError::invalid_params(format!(
                        "no peer session {key:?}: name its host and sessionId"
                    ))
                })?;
                (h.to_owned(), m.to_owned(), None)
            }
        };
        // A limit given is a whole number of records, at least one: anything else (0, -1, 1.5,
        // `true`, "2") is refused rather than read as the default.
        let limit = match params.get("limit").filter(|v| !v.is_null()) {
            None => READ_LIMIT,
            Some(v) => match v.as_u64().filter(|&l| l > 0) {
                Some(l) => usize::try_from(l).unwrap_or(SESSION_EVENTS).min(SESSION_EVENTS),
                None => {
                    return Err(RpcError::invalid_params("limit must be a whole number from 1"));
                }
            },
        };
        let generation = row.as_ref().and_then(created_at);
        let bounds = (limit, page_bytes(params));
        Ok(self.peer_snapshots.read((&peer, &mux), bounds, generation, row))
    }
}

#[cfg(test)]
#[path = "read_tests.rs"]
mod tests;
