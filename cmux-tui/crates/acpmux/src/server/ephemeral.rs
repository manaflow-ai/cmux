//! Ephemeral sessions (`session/new` with `_meta.acpmux.ephemeral: true`,
//! from `acpmux run --ephemeral` and `acpmux exec`): purged when the
//! connection that created them closes.
//!
//! The CLI purges its session after the reply, but only on that path. A CLI
//! killed during the turn (its caller's timeout, Ctrl-C), a flag error after
//! `session/new` or a lost connection kept the session for good, and agents'
//! hand-run smoke tests ("Reply with only: OK") stayed in the person's chat
//! list (2026-10-20). The daemon sees every one of those exits as the
//! connection closing, so it purges here.

use super::Conn;
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;
use serde_json::Value;
use std::sync::Arc;

/// Whether a `session/new` asks for an ephemeral session.
pub(super) fn requested(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/ephemeral").and_then(Value::as_bool) == Some(true)
}

/// Ties `session` to `conn`: purged when the connection closes. A
/// connection that closed while its `session/new` ran purges it now.
pub(super) async fn own(hub: &Hub, conn: &Conn, session: &Arc<Session>) {
    {
        let mut owned = conn.ephemeral.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(ids) = owned.as_mut() {
            ids.push(session.id.clone());
            return;
        }
    }
    purge(hub, session).await;
}

/// Retain only a session this very connection owns, for a failed app open's
/// retry. This cannot change another client's cleanup or session policy.
pub(super) fn keep(conn: &Conn, id: &str) -> Result<(), RpcError> {
    let mut owned = conn.ephemeral.lock().unwrap_or_else(|e| e.into_inner());
    let ids = owned.as_mut().ok_or_else(|| RpcError::invalid_params("connection closed"))?;
    let index = ids.iter().position(|owned| owned == id).ok_or_else(|| {
        RpcError::invalid_params("this connection does not own that ephemeral session")
    })?;
    ids.remove(index);
    Ok(())
}

/// The connection closed: purge every ephemeral session it created.
pub(super) async fn release_all(hub: &Hub, conn: &Conn) {
    let ids = conn.ephemeral.lock().unwrap_or_else(|e| e.into_inner()).take().unwrap_or_default();
    for id in ids {
        // Already purged by the client's own kill: nothing to do.
        if let Ok(session) = hub.resolve(&id) {
            purge(hub, &session).await;
        }
    }
}

async fn purge(hub: &Hub, session: &Arc<Session>) {
    if let Err(e) = hub.kill(session, true).await {
        tracing::warn!(session = %session.id, "purge of an ephemeral session failed: {}", e.message);
    }
}
