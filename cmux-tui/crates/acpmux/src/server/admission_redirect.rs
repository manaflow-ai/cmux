//! A `session/new` on a host that is full starts on the least-loaded connected host instead
//! (`hub/admission/redirect.rs` decides where, and when this host is full). This part says
//! which requests may go at all, and sends one as `_meta.acpmux.peer` would
//! (`requests.rs`). Part of the request handler.
//!
//! Only a create over this machine's unix socket goes: agents, scripts and lane tools, which is
//! where the 51 sessions on huge-blue came from (2026-11-16). The app's own chats
//! (`Origin::LocalApp`) stay where they were opened; a peer's create (`Origin::Peer`) is
//! already the forward of another daemon, and a third hop would leave its chat unreachable;
//! a Web client is held to this host's folders. A request that carries something only this
//! host has stays too: a session env, an adopt, a worktree to make here, a fixed id, an
//! ephemeral run tied to this connection, a route, extra folders or a named peer.
//!
//! A create sent elsewhere that the peer refuses (a preset it lacks, a link that dropped)
//! starts here after all, with the cap's warning: a full host never refuses a session.

use super::{Conn, Origin, mux_meta};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use cmux_json::JsonSet as _;
use serde_json::Value;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

/// Whether this `session/new` may start on another host at all (module docs).
pub(super) fn may_go(origin: Origin, params: &Value, fixed_id: bool) -> bool {
    if origin != Origin::Local || fixed_id {
        return false;
    }
    let meta = mux_meta(params);
    let has = |k: &str| meta.and_then(|m| m.get(k)).is_some_and(|v| !v.is_null() && v != false);
    let local_only = ["peer", "adopt", "worktree", "ephemeral", "route"].iter().any(|k| has(k));
    let dirs = params
        .get(crate::hub::additional_dirs::FIELD)
        .is_some_and(|v| v.as_array().is_some_and(|a| !a.is_empty()));
    !local_only && !dirs && !crate::session_env::present(meta)
}

/// The answer of this `session/new` started on another host, when this host is full and it
/// may go there (module docs); `None` starts it here as before.
pub(super) async fn elsewhere(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    fixed_id: bool,
) -> Option<Value> {
    if !may_go(conn.origin, params, fixed_id) {
        return None;
    }
    let cwd = params.get("cwd").and_then(Value::as_str).map(PathBuf::from);
    let person = super::requests::person_asks(conn);
    let app = conn.origin == Origin::LocalApp;
    let (to, notice) = hub.redirect_new(cwd, person, app).await?;
    let mut p = params.clone();
    // The peer makes a scratch folder of its own: the one named here is not there.
    if let Some(obj) = p.as_object_mut() {
        obj.remove("cwd");
    }
    crate::hub::merge_mux_meta(&mut p, serde_json::json!({"peer": to.peer}));
    // Boxed as a trait object: the forward runs the same request handler that called this.
    let forward: Pin<Box<dyn Future<Output = Result<Value, RpcError>> + Send + '_>> =
        Box::pin(super::requests::dispatch_request(hub, conn, method::SESSION_NEW, p, None));
    match forward.await {
        Ok(mut reply) => {
            crate::hub::merge_mux_meta(&mut reply, serde_json::json!({"admission": notice}));
            if let Some(obj) = reply.as_object_mut() {
                obj.entry("peer").or_insert_with(|| Value::String(to.peer.clone()));
            }
            Some(reply)
        }
        Err(e) => {
            tracing::warn!(
                to = to.peer,
                "session/new not started on {} ({}); starting here past the lane cap",
                to.peer,
                e.message
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_a_plain_unix_socket_create_may_go_elsewhere() {
        let plain =
            json!({"cwd": "/tmp/x", "_meta": {"acpmux": {"name": "lane", "harness": "codex"}}});
        assert!(may_go(Origin::Local, &plain, false));
        assert!(!may_go(Origin::LocalApp, &plain, false), "the app's own chat stays");
        assert!(!may_go(Origin::Peer, &plain, false), "a peer's forward never hops again");
        assert!(!may_go(Origin::Local, &plain, true), "a fixed id is this daemon's");
        for (k, v) in [
            ("peer", json!("big")),
            ("adopt", json!({"agentSessionId": "a"})),
            ("worktree", json!({"name": "w"})),
            ("ephemeral", json!(true)),
            ("route", json!("r1")),
            ("env", json!({"CMUX_WORKSPACE_ID": "w"})),
        ] {
            let mut p = plain.clone();
            p["_meta"]["acpmux"][k] = v;
            assert!(!may_go(Origin::Local, &p, false), "{k} is this host's");
        }
        let mut dirs = plain.clone();
        dirs[crate::hub::additional_dirs::FIELD] = json!(["/srv/data"]);
        assert!(!may_go(Origin::Local, &dirs, false), "extra folders are this host's");
        let mut off = plain.clone();
        off["_meta"]["acpmux"]["ephemeral"] = json!(false);
        assert!(may_go(Origin::Local, &off, false));
    }
}
