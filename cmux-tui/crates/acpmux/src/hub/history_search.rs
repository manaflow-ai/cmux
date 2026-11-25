//! Host-wide mode of the indexed session search. Each peer searches its own store, including
//! closed chats its live session mirror omits. A forwarded search never asks another peer.

use super::*;
use crate::session_search::{Query, Role, TextView, search_messages};
use futures::{StreamExt as _, stream};

static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

#[derive(Debug, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Hit {
    pub session: String,
    pub session_id: String,
    pub host: String,
    pub at: u64,
    pub seq: u64,
    pub turn_time: String,
    pub role: Role,
    pub preview: String,
}

#[derive(Default, serde::Deserialize, serde::Serialize)]
pub(crate) struct Answer {
    pub hits: Vec<Hit>,
    pub incomplete: Vec<String>,
}

impl Answer {
    pub(crate) fn newest(&mut self, limit: usize) {
        self.hits.sort_unstable_by(|a, b| {
            b.at.cmp(&a.at)
                .then_with(|| a.host.cmp(&b.host))
                .then_with(|| a.session_id.cmp(&b.session_id))
                .then_with(|| b.seq.cmp(&a.seq))
        });
        self.hits.truncate(limit);
    }
}

impl Hub {
    fn search_local_history(&self, query: &Query, from_peer: bool) -> Answer {
        let mut answer = Answer::default();
        // A peer knows this host by the name it configured; only the local CLI gets its hostname.
        let host = if from_peer { String::new() } else { crate::pairing::machine_name() };
        let view = if from_peer { TextView::PeerConversation } else { TextView::Conversation };
        let mut failed = 0;
        let mut sessions: Vec<_> = self
            .session_handles()
            .into_iter()
            .map(|session| {
                session.read_meta(|meta| (meta.updated_at, session.id.clone(), meta.name.clone()))
            })
            .collect();
        sessions.sort_unstable_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        for (updated_at, id, name) in sessions {
            // Every persisted event moves updated_at. An older session cannot displace the
            // last hit, even if several newer matches came from the same session.
            if answer.hits.len() == query.limit
                && answer.hits.last().is_some_and(|hit| updated_at < hit.at)
            {
                break;
            }
            match search_messages(self.store.as_ref(), &id, query, view) {
                Ok(result) => {
                    for hit in result.hits {
                        answer.hits.push(Hit {
                            session: if name.is_empty() { id.clone() } else { name.clone() },
                            session_id: id.clone(),
                            host: host.clone(),
                            seq: hit.seq,
                            at: hit.at,
                            turn_time: hit
                                .turn_time
                                .unwrap_or_else(|| crate::clock_text::iso(hit.at)),
                            role: hit.role,
                            preview: hit.snippet,
                        });
                    }
                    answer.newest(query.limit);
                }
                Err(error) => {
                    if failed == 0 {
                        answer.incomplete.push(format!("{id}: {error}"));
                    }
                    failed += 1;
                }
            }
        }
        if failed > 1 {
            answer.incomplete.push(format!("{failed} sessions could not be searched"));
        }
        answer
    }

    pub(crate) async fn search_history(
        self: &Arc<Self>,
        params: &Value,
        include_peers: bool,
    ) -> Result<Value, RpcError> {
        let forward = json!({
            "allSessions": true, "query": params.get("query"), "limit": params.get("limit")
        });
        let query = Query::from_params(&forward).map_err(RpcError::invalid_params)?;
        let limit = query.limit;
        let hub = self.clone();
        let slot = READS.acquire().await.map_err(|error| RpcError::internal(error.to_string()))?;
        let local = tokio::task::spawn_blocking(move || {
            let _slot = slot;
            hub.search_local_history(&query, !include_peers)
        });
        let peers = if include_peers {
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect()
        } else {
            Vec::new()
        };
        let mut replies = stream::iter(peers)
            .map(|peer| {
                let params = forward.clone();
                async move {
                    let reply = tokio::time::timeout(
                        std::time::Duration::from_secs(60),
                        peer.request(method::MUX_SESSION_SEARCH, params),
                    )
                    .await;
                    let reply = reply
                        .map_err(|_| "search timed out after 60s".to_owned())
                        .and_then(|reply| reply.map_err(|error| error.message))
                        .and_then(|value| {
                            serde_json::from_value::<Answer>(value).map_err(|e| e.to_string())
                        });
                    (peer.name.clone(), reply)
                }
            })
            .buffer_unordered(8);
        let mut answer = Answer::default();
        while let Some((host, reply)) = replies.next().await {
            match reply {
                Ok(mut remote) => {
                    for hit in &mut remote.hits {
                        hit.host.clone_from(&host);
                    }
                    answer.hits.extend(remote.hits);
                    answer.newest(limit);
                    answer
                        .incomplete
                        .extend(remote.incomplete.into_iter().map(|e| format!("{host}: {e}")));
                }
                Err(error) => answer.incomplete.push(format!("{host}: {error}")),
            }
        }
        let here = local.await.map_err(|e| RpcError::internal(e.to_string()))?;
        answer.hits.extend(here.hits);
        answer.incomplete.extend(here.incomplete);
        answer.newest(limit);
        Ok(json!(answer))
    }
}
