//! Signing in enrolls this machine (`cli/cloud_join/enroll.rs`), asked by the local app on its
//! acpmux line: `_acpmux/machine_enroll` on sign-in, `_acpmux/machine_leave_if_auto` on sign-out.
//! The daemon runs the enroll itself so the mesh relay starts live when the machine joins, with
//! no restart (a never-joined daemon started none). The access token arrives in the request's
//! params on the local socket only, and goes only into the hub requests: never a log line.

use std::sync::Arc;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, Origin};
use crate::cli::cloud_join::{EnrollOutcome, EnrollRequest};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// The local app's socket only: never a peer, a phone or a web page. And only the person
/// (`hub/person.rs`): a local shell or agent may neither leave this machine's join nor enroll it
/// with a token and user id it chose, so a connection that did not prove the person is refused
/// with the declared `permission.person_required`.
fn local(conn: &Conn, method: &str) -> Result<(), RpcError> {
    if conn.origin != Origin::Local || conn.origin.web_class() {
        return Err(RpcError::method_not_found(&format!("{method} (local socket only)")));
    }
    if !conn.is_person() {
        return Err(crate::hub::person::person_required(match method {
            crate::rpc::method::MUX_MACHINE_ENROLL => "enrolling this machine in cmux Cloud",
            _ => "removing this machine from cmux Cloud",
        }));
    }
    Ok(())
}

/// `_acpmux/machine_enroll {accessToken, hub?, userId?, buildTag?}` -> `{outcome, relay?}`.
pub(super) async fn enroll(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_ENROLL)?;
    let access = params
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|token| !token.trim().is_empty())
        .map(|token| Zeroizing::new(token.trim().to_owned()))
        .ok_or_else(|| RpcError::invalid_params("accessToken is required"))?;
    let text = |key: &str| {
        params.get(key).and_then(Value::as_str).filter(|v| !v.trim().is_empty()).map(str::to_owned)
    };
    let request =
        EnrollRequest { hub: text("hub"), user_id: text("userId"), build_tag: text("buildTag") };
    let outcome = crate::cli::cloud_join::enroll_self(request, access).await;
    tracing::info!(?outcome, "sign-in enroll");
    let relay = match outcome {
        EnrollOutcome::Joined | EnrollOutcome::AlreadyJoined => Some(start_relay(hub).await),
        _ => None,
    };
    Ok(json!({"outcome": outcome, "relay": relay}))
}

/// Starts the mesh relay the join wrote into config.json, unless one is running.
async fn start_relay(hub: &Arc<Hub>) -> &'static str {
    let mut slot = hub.mesh_relay.lock().await;
    if slot.as_ref().is_some_and(|relay| !relay.is_finished()) {
        return "running";
    }
    let Ok(Ok(config)) = tokio::task::spawn_blocking(crate::config::Config::load).await else {
        return "off";
    };
    let Some(relay) = config.mesh_relay else { return "off" };
    start_relay_with(hub, &mut slot, relay).await
}

/// Starts the mesh relay on `relay`, the join's config, into `slot` (`Hub::mesh_relay`); its
/// client becomes the one sends go through (`Hub::mesh`), replacing a leave's cleared one.
async fn start_relay_with(
    hub: &Arc<Hub>,
    slot: &mut Option<crate::server::mesh_relay::MeshRelay>,
    relay: crate::mesh_http::MeshRelayConfig,
) -> &'static str {
    hub.config.write().await.mesh_relay = Some(relay);
    match crate::server::mesh_relay::start_configured(hub).await {
        Some(relay) => {
            *slot = Some(relay);
            "started"
        }
        None => "off",
    }
}

/// `_acpmux/machine_leave_if_auto {}` -> `{left, kept?, hub?}`: leaves only a join signing in made.
pub(super) async fn leave_if_auto(hub: &Arc<Hub>, conn: &Conn) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_LEAVE_IF_AUTO)?;
    let outcome = crate::cli::cloud_join::leave_if_auto().await;
    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave");
    if outcome.left {
        stop_joined(hub).await;
    }
    serde_json::to_value(outcome).map_err(|e| RpcError::internal(e.to_string()))
}

/// Stops what the join started on this daemon: the mesh relay and the hub client sends went
/// through (`Hub::mesh`), so a later enroll's relay sets its own hub's and nothing goes on
/// through the left one's credentials.
async fn stop_joined(hub: &Arc<Hub>) {
    hub.config.write().await.mesh_relay = None;
    let relay = hub.mesh_relay.lock().await.take();
    if let Some(relay) = relay {
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
    hub.mesh.clear();
}

/// The daemon start's mesh relay. A sign-out's leave the last run did not finish is finished
/// first, off the start's path, and the relay starts only if the machine stayed joined.
pub(crate) async fn start_relay_at_start(hub: &Arc<Hub>) {
    if !crate::cli::cloud_join::leave_pending() {
        *hub.mesh_relay.lock().await = crate::server::mesh_relay::start_configured(hub).await;
        return;
    }
    let hub = Arc::clone(hub);
    // task-owner: one leave and maybe the relay start; ends with them (the leave waits at most
    // for the join lock and the hub's bounded answer).
    tokio::spawn(async move {
        let Some(outcome) = crate::cli::cloud_join::finish_leave_at_start().await else {
            *hub.mesh_relay.lock().await = crate::server::mesh_relay::start_configured(&hub).await;
            return;
        };
        tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
        if crate::cli::cloud_join::relay_may_start(&outcome) {
            let relay = crate::server::mesh_relay::start_configured(&hub).await;
            *hub.mesh_relay.lock().await = relay;
        } else if outcome.left {
            stop_joined(&hub).await;
        }
    });
}

#[cfg(test)]
mod tests {
    //! A local connection that did not prove the person (a shell, the CLI, an agent) is refused
    //! both RPCs before anything runs: no hub request, no join or leave on disk. And the hub
    //! client a join's relay set, a leave clears and a later enroll replaces.
    use crate::config::{Config, StoreMode};
    use crate::rpc::{Message, method};
    use serde_json::{Value, json};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokio::sync::mpsc;

    async fn refused(m: &str, params: Value) -> Value {
        let hub = memory_hub();
        let (input, incoming) = mpsc::channel(8);
        let (out, mut output) = mpsc::channel(64);
        // task-owner: the test's one connection; ends when `input` drops at the test's end.
        tokio::spawn(crate::server::serve_connection(hub, incoming, out));
        let init = Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1}));
        input.send(init.to_line()).await.unwrap();
        input.send(Message::request(2, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let reply: Value = serde_json::from_str(&output.recv().await.unwrap()).unwrap();
                if reply["id"] == 2 {
                    return reply;
                }
            }
        })
        .await
        .expect("the reply comes")
    }

    #[tokio::test]
    async fn enroll_from_a_local_connection_that_is_not_the_person_is_refused() {
        let reply = refused(
            method::MUX_MACHINE_ENROLL,
            json!({"accessToken": "chosen-token", "userId": "someone-else", "hub": "http://127.0.0.1:9"}),
        )
        .await;
        assert!(reply.get("result").is_none(), "{reply}");
        assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{reply}");
    }

    #[tokio::test]
    async fn leave_if_auto_from_a_local_connection_that_is_not_the_person_is_refused() {
        let reply = refused(method::MUX_MACHINE_LEAVE_IF_AUTO, json!({})).await;
        assert!(reply.get("result").is_none(), "{reply}");
        assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{reply}");
    }

    fn memory_hub() -> Arc<crate::hub::Hub> {
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        crate::hub::Hub::new(config, store)
    }

    /// A loopback hub that answers every request 400 and keeps each request's first line.
    async fn recording_hub() -> (crate::mesh_http::MeshRelayConfig, Arc<Mutex<Vec<String>>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = crate::mesh_http::MeshRelayConfig {
            url: format!("http://{}", listener.local_addr().unwrap()),
            token_command: ["sh", "-c", "printf test-token"].map(str::to_owned).to_vec(),
            team_messaging: true,
            credential: None,
            control_from: Vec::new(),
        };
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&seen);
        // task-owner: the test's fake hub; the runtime ends it with the test.
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let log = Arc::clone(&log);
                // task-owner: one request's answer.
                tokio::spawn(async move {
                    let mut bytes = Vec::new();
                    let mut chunk = [0; 4096];
                    while !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                        match stream.read(&mut chunk).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => bytes.extend_from_slice(chunk.get(..n).unwrap_or_default()),
                        }
                    }
                    let line =
                        String::from_utf8_lossy(&bytes).lines().next().unwrap_or("").to_owned();
                    log.lock().unwrap().push(line);
                    let body = r#"{"error":"test"}"#;
                    let answer = format!(
                        "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(answer.as_bytes()).await;
                });
            }
        });
        (config, seen)
    }

    fn sends(seen: &Mutex<Vec<String>>) -> usize {
        seen.lock()
            .unwrap()
            .iter()
            .filter(|line| line.starts_with("POST /v1/mesh/messages "))
            .count()
    }

    async fn send_one(hub: &crate::hub::Hub) {
        let message: crate::mesh::OutMessage = serde_json::from_value(json!({
            "to": {"teamAddress": "@user_receiver/coordinator", "sessionId": "receiver"},
            "from": {"teamAddress": "@user_sender/coordinator"},
            "kind": "prompt", "body": "hello", "mode": "turn-end", "idempotencyKey": "k1",
        }))
        .unwrap();
        let mesh = hub.mesh.get().expect("a relay runs, so sends have a hub");
        let _ = mesh.send(&message).await;
    }

    /// A leave clears the hub client sends go through, and a later enroll on another hub's origin
    /// sets that hub's: sends go to the new hub, never the left one.
    #[tokio::test]
    async fn after_a_leave_and_an_enroll_on_another_hub_sends_go_to_the_new_hub() {
        let hub = memory_hub();
        let (first, first_seen) = recording_hub().await;
        let (second, second_seen) = recording_hub().await;
        assert_ne!(first.url, second.url);

        let mut slot = hub.mesh_relay.lock().await;
        assert_eq!(super::start_relay_with(&hub, &mut slot, first).await, "started");
        drop(slot);
        send_one(&hub).await;
        assert_eq!(sends(&first_seen), 1);

        super::stop_joined(&hub).await;
        assert!(hub.mesh.get().is_none(), "a machine that left sends through no hub");
        assert!(hub.mesh_relay.lock().await.is_none());

        let mut slot = hub.mesh_relay.lock().await;
        assert_eq!(super::start_relay_with(&hub, &mut slot, second).await, "started");
        drop(slot);
        send_one(&hub).await;
        assert_eq!(sends(&second_seen), 1, "the send goes to the hub enrolled last");
        assert_eq!(sends(&first_seen), 1, "nothing more goes to the hub it left");
        super::stop_joined(&hub).await;
    }
}
