//! `_acpmux/transcript_search` on the hub: this machine's transcripts and, when `host` asks, its
//! peers' (`crate::transcript_search`).

use std::sync::Arc;
use std::time::Instant;

use serde_json::{Value, json};

use crate::rpc::RpcError;
use crate::transcript_search::{PEER_DEADLINE, Params, merge, place, roots, search_here};

impl super::Hub {
    /// `_acpmux/transcript_search`: here, and on the peers `host` names unless the caller is a
    /// peer (a peer's search never goes on to a third machine), as `who_else` asks them. With
    /// `sessionId` naming an acpmux session, this machine's hits in its own transcript get the
    /// `seq` of their message in its log (`transcript_search::place`).
    pub async fn transcript_search(
        self: &Arc<Self>,
        params: &Value,
        from_peer: bool,
    ) -> Result<Value, RpcError> {
        let started = Instant::now();
        let mut p = Params::from_value(params).map_err(RpcError::invalid_params)?;
        // An acpmux session names its harness session; anything else is taken as one.
        let session = p.session.as_deref().and_then(|key| self.resolve(key).ok());
        if p.harness_session.is_none()
            && let Some(key) = p.session.clone()
        {
            p.harness_session = Some(
                session.as_ref().and_then(|s| s.meta().agent_session_id.clone()).unwrap_or(key),
            );
        }
        let own = crate::pairing::machine_name();
        let host = if from_peer { None } else { p.host.clone() };
        let all: Vec<Arc<crate::peer::Peer>> =
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let (here, peers) = match host.as_deref() {
            None => (true, Vec::new()),
            Some("all") => (true, all),
            Some(name) if name == own || name == "local" => (true, Vec::new()),
            Some(name) => {
                let one: Vec<_> = all.into_iter().filter(|peer| peer.name == name).collect();
                if one.is_empty() {
                    return Err(RpcError::invalid_params(format!(
                        "host {name:?} is neither this machine nor one of its peers"
                    )));
                }
                (false, one)
            }
        };
        // One machine pages itself; several each answer from their first hit and the merge pages.
        let (asked, skip) =
            if !here || !peers.is_empty() { (p.for_merge(), p.offset) } else { (p.clone(), 0) };
        let forward = Params { host: None, session: None, ..asked.clone() }.to_value();
        let asks = peers.into_iter().map(|peer| {
            let forward = forward.clone();
            async move {
                let answer = tokio::time::timeout(
                    PEER_DEADLINE,
                    peer.request(crate::rpc::method::MUX_TRANSCRIPT_SEARCH, forward),
                )
                .await;
                (peer.name.clone(), answer)
            }
        });
        let local = here.then(|| {
            let chats = self.chats.get().cloned();
            let asked = asked.clone();
            let own = own.clone();
            tokio::task::spawn_blocking(move || {
                search_here(&asked, &roots(chats.as_deref()), Some(&own))
            })
        });
        let mut answers = Vec::new();
        let mut unreached = Vec::new();
        for (name, answer) in futures::future::join_all(asks).await {
            match answer {
                Ok(Ok(mut v)) => {
                    for h in v.get_mut("hits").and_then(Value::as_array_mut).into_iter().flatten() {
                        h["host"] = json!(name);
                        // A peer's log is not this machine's: its seq would place nothing here.
                        if let Some(h) = h.as_object_mut() {
                            h.remove("seq");
                        }
                    }
                    answers.push(v);
                }
                Ok(Err(e)) => unreached.push(json!({"host": name, "error": e.message})),
                Err(_) => unreached.push(json!({
                    "host": name,
                    "error": format!("no answer in {} s", PEER_DEADLINE.as_secs()),
                })),
            }
        }
        if let Some(local) = local {
            let answer = local
                .await
                .map_err(|e| RpcError::internal(format!("transcript search stopped: {e}")))?
                .map_err(RpcError::internal)?;
            answers.insert(0, answer);
        }
        let mut merged = merge(answers, unreached, &p, skip, 0);
        if let (Some(session), Some(harness)) = (session, p.harness_session.clone()) {
            merged =
                self.place_hits(session.id.clone(), harness, own, p.query.clone(), merged).await;
        }
        merged["tookMs"] = json!(started.elapsed().as_millis() as u64);
        Ok(merged)
    }

    /// [`place`] off the executor: the log's text copies are read from disk. A log that cannot be
    /// read leaves the hits with no `seq`.
    async fn place_hits(
        self: &Arc<Self>,
        id: String,
        harness: String,
        own: String,
        query: String,
        mut answer: Value,
    ) -> Value {
        let hub = self.clone();
        let unplaced = answer.clone();
        let placed = tokio::task::spawn_blocking(move || {
            let ours = |h: &Value| {
                h.get("host").and_then(Value::as_str) == Some(own.as_str())
                    && h.get("sessionId").and_then(Value::as_str) == Some(harness.as_str())
                    && h.get("subagent").and_then(Value::as_bool) != Some(true)
            };
            if let Some(hits) = answer.get_mut("hits").and_then(Value::as_array_mut)
                && let Err(error) = place(hub.store.as_ref(), &id, &query, hits, &ours)
            {
                tracing::debug!(%error, session = %id, "transcript search: hits not placed in the log");
            }
            answer
        })
        .await;
        placed.unwrap_or(unplaced)
    }
}
