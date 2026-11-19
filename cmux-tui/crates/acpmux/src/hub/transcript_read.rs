//! `_acpmux/transcript_read` on the hub: the text around a transcript search hit, here or on the
//! one peer `host` names (`crate::transcript_read`).

use std::sync::Arc;

use serde_json::Value;

use crate::rpc::RpcError;
use crate::transcript_read::{Error, Params, read_here};
use crate::transcript_search::{PEER_DEADLINE, roots};

impl super::Hub {
    /// `_acpmux/transcript_read`: here, or on the peer `host` names unless the caller is a peer
    /// (a peer's read never goes on to a third machine).
    pub async fn transcript_read(
        self: &Arc<Self>,
        params: &Value,
        from_peer: bool,
    ) -> Result<Value, RpcError> {
        let p = Params::from_value(params).map_err(RpcError::invalid_params)?;
        // An acpmux session names its harness session; anything else is taken as one.
        let session = match (&p.harness_session, &p.session) {
            (Some(id), _) => id.clone(),
            (None, Some(key)) => match self.resolve(key) {
                Ok(s) => s.meta().agent_session_id.clone().unwrap_or_else(|| key.clone()),
                Err(_) => key.clone(),
            },
            (None, None) => return Err(RpcError::invalid_params("sessionId is required")),
        };
        let own = crate::pairing::machine_name();
        let host = if from_peer { None } else { p.host.clone() };
        if let Some(name) = host.filter(|h| *h != own && h != "local") {
            let peer = self
                .peers
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .values()
                .find(|peer| peer.name == name)
                .cloned()
                .ok_or_else(|| {
                    RpcError::invalid_params(format!(
                        "host {name:?} is neither this machine nor one of its peers"
                    ))
                })?;
            let forward = Params { host: None, session: None, harness_session: Some(session), ..p }
                .to_value();
            return match tokio::time::timeout(
                PEER_DEADLINE,
                peer.request(crate::rpc::method::MUX_TRANSCRIPT_READ, forward),
            )
            .await
            {
                Ok(Ok(mut v)) => {
                    v["host"] = Value::String(name);
                    Ok(v)
                }
                Ok(Err(e)) => Err(e),
                Err(_) => Err(RpcError::internal(format!(
                    "{name} gave no answer in {} s",
                    PEER_DEADLINE.as_secs()
                ))),
            };
        }
        let chats = self.chats.get().cloned();
        tokio::task::spawn_blocking(move || {
            read_here(&p, &session, &roots(chats.as_deref()), Some(&own))
        })
        .await
        .map_err(|e| RpcError::internal(format!("transcript read stopped: {e}")))?
        .map_err(|e| match e {
            Error::NotFound(m) => RpcError::not_found(m),
            Error::Other(m) => RpcError::internal(m),
        })
    }
}
