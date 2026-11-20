//! `_acpmux/transcript_search` on the hub: this machine's transcripts and, when `host` asks, its
//! peers' (`crate::transcript_search`).

use std::sync::Arc;
use std::time::Instant;

use serde_json::{Value, json};

use crate::rpc::RpcError;
use crate::transcript_search::{PEER_DEADLINE, Params, merge, roots, search_here};

impl super::Hub {
    /// `_acpmux/transcript_search`: here, and on the peers `host` names unless the caller is a
    /// peer (a peer's search never goes on to a third machine), as `who_else` asks them.
    pub async fn transcript_search(
        self: &Arc<Self>,
        params: &Value,
        from_peer: bool,
    ) -> Result<Value, RpcError> {
        let started = Instant::now();
        let mut p = Params::from_value(params).map_err(RpcError::invalid_params)?;
        if p.harness_session.is_none()
            && let Some(key) = p.session.clone()
        {
            // An acpmux session names its harness session; anything else is taken as one.
            p.harness_session = Some(match self.resolve(&key) {
                Ok(s) => s.meta().agent_session_id.clone().unwrap_or(key),
                Err(_) => key,
            });
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
        let forward = Params { host: None, session: None, ..p.clone() }.to_value();
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
            let p = p.clone();
            let own = own.clone();
            tokio::task::spawn_blocking(move || {
                search_here(&p, &roots(chats.as_deref()), Some(&own))
            })
        });
        let mut answers = Vec::new();
        let mut unreached = Vec::new();
        for (name, answer) in futures::future::join_all(asks).await {
            match answer {
                Ok(Ok(mut v)) => {
                    for h in v.get_mut("hits").and_then(Value::as_array_mut).into_iter().flatten() {
                        h["host"] = json!(name);
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
        Ok(merge(answers, unreached, p.limit, started.elapsed().as_millis() as u64))
    }
}
