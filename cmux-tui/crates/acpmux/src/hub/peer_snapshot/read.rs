//! Part of `peer_snapshot.rs`: `_acpmux/peer_snapshot`, the one hook a
//! client (the app's agent pane, the VM start and resume path) reads a peer
//! session's kept copy through, whether or not the peer answers.

use super::*;
use crate::session_identity::SessionReceipt;

/// Records a reply carries by default; at most [`SESSION_EVENTS`].
const READ_LIMIT: usize = 400;

impl PeerSnapshots {
    /// The `_acpmux/peer_snapshot` reply for peer `peer`'s session `mux`:
    /// its newest `limit` records within `max_bytes`, oldest first. A
    /// `generation` (the row's `createdAt`) other than the copy's drops it.
    /// Read under the `disk` lock, so no write or eviction lands between
    /// the copy's meta and its segments; a segment that cannot be read makes
    /// the reply say there is more (`hasMore`), never that it is whole.
    pub(crate) fn read(
        &self,
        (peer, mux): (&str, &str),
        (limit, max_bytes): (usize, usize),
        generation: Option<u64>,
        row: Option<Value>,
    ) -> Value {
        let key = (peer.to_owned(), mux.to_owned());
        let mut reply = json!({
            "peer": peer, "sessionId": mux, "qualifiedSessionId": format!("{peer}/{mux}"),
            "events": [], "lastSeq": 0, "generation": null, "capturedAt": null,
            "hasMore": false, "stale": true, "summary": row.map(snapshot_row),
        });
        self.scan();
        let _disk = lock(&self.0.disk);
        let (segments, mut all, meta) = {
            let mut state = lock(&self.0.state);
            let Some(snap) = state.sessions.get(&key).filter(|_| self.session_dir(&key).is_some())
            else {
                return reply;
            };
            if matches!((snap.meta.generation, generation), (Some(a), Some(b)) if a != b) {
                // The session the peer lists now is not the one this copy is of.
                self.discard(&mut state, &key);
                drop(state);
                self.sweep_locked();
                return reply;
            }
            (snap.segments.clone(), snap.pending.clone(), serde_json::to_value(&snap.meta).ok())
        };
        let mut complete = true;
        for seg in &segments {
            let records = match disk::read_segment(&seg.path) {
                Ok((records, _)) => records,
                Err(e) => {
                    tracing::warn!(
                        peer,
                        session = mux,
                        "could not read a peer snapshot segment: {e:#}"
                    );
                    complete = false;
                    Vec::new()
                }
            };
            for r in records {
                if let Some(seq) = seq_of(&r) {
                    all.entry(seq).or_insert(r);
                }
            }
        }
        let mut events: Vec<Value> = Vec::new();
        let mut bytes = 0;
        for r in all.values().rev() {
            let b = record_bytes(r) as usize;
            if events.len() >= limit.max(1) || (!events.is_empty() && bytes + b > max_bytes) {
                break;
            }
            bytes += b;
            events.push(r.clone());
        }
        events.reverse();
        let meta = meta.unwrap_or(Value::Null);
        let whole = complete && events.len() == all.len() && meta["fromStart"] == true;
        if reply["summary"].is_null() {
            reply["summary"] = meta["summary"].clone();
        }
        reply["lastSeq"] = json!(all.keys().next_back().copied().unwrap_or(0));
        reply["events"] = Value::Array(events);
        reply["hasMore"] = Value::Bool(!whole);
        for f in ["generation", "capturedAt", "hostLastSeq"] {
            reply[f] = meta[f].clone();
        }
        reply
    }
}

impl Hub {
    /// `_acpmux/peer_snapshot {sessionId, host?, limit?, maxBytes?}`: this
    /// daemon's copy of a peer session's events, answered whether or not the
    /// peer is reachable, always `stale`. `sessionId` is an id or
    /// `HOST/name`, or with `host` the peer's own id (a lease that ended).
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
        let limit = params.get("limit").and_then(Value::as_u64).map_or(READ_LIMIT, |l| {
            usize::try_from(l).unwrap_or(SESSION_EVENTS).min(SESSION_EVENTS)
        });
        let generation = row.as_ref().and_then(created_at);
        let bounds = (limit, page_bytes(params));
        Ok(self.peer_snapshots.read((&peer, &mux), bounds, generation, row))
    }
}

#[cfg(test)]
#[path = "read_tests.rs"]
mod tests;
