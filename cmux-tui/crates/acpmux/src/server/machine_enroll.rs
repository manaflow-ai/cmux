//! Signing in enrolls this machine (`cli/cloud_join/enroll.rs`), asked by the local app on its
//! acpmux line: `_acpmux/machine_enroll` on sign-in, `_acpmux/machine_leave_if_auto` on sign-out.
//! The daemon runs the enroll itself so the mesh relay starts live when the machine joins, with
//! no restart (a never-joined daemon started none). The access token arrives in the request's
//! params on the local socket only, and goes only into the hub requests: never a log line.
//!
//! Every change of the join on this daemon (the start's leave and relay, an enroll, a leave,
//! shutdown) holds `Hub::join_transition` throughout, and reads config.json's relay once it
//! holds it: none starts or stops a relay on what it read before another changed the join.

use std::future::Future;
use std::sync::Arc;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, Origin};
use crate::cli::cloud_join::{EnrollOutcome, EnrollRequest, LeaveOutcome};
use crate::hub::Hub;
use crate::mesh_http::MeshRelayConfig;
use crate::no_panic::LockExt;
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
    let (outcome, relay) =
        enroll_transition(hub, crate::cli::cloud_join::enroll_self(request, access), || {
            relay_on_disk(hub)
        })
        .await;
    Ok(json!({"outcome": outcome, "relay": relay}))
}

/// A sign-in's enroll (`enroll`) with the join transition held, then the relay as config.json
/// says once it is done (`on_disk`).
async fn enroll_transition<D: Future<Output = Option<MeshRelayConfig>>>(
    hub: &Arc<Hub>,
    enroll: impl Future<Output = EnrollOutcome>,
    on_disk: impl FnOnce() -> D,
) -> (EnrollOutcome, Option<&'static str>) {
    let _join = hub.join_transition.lock().await;
    let outcome = enroll.await;
    tracing::info!(?outcome, "sign-in enroll");
    let relay = match outcome {
        EnrollOutcome::Joined | EnrollOutcome::AlreadyJoined => {
            Some(reconcile_relay(hub, on_disk().await).await)
        }
        _ => None,
    };
    (outcome, relay)
}

/// config.json's `meshRelay` now; the one this daemon loaded when config.json cannot be read.
async fn relay_on_disk(hub: &Arc<Hub>) -> Option<MeshRelayConfig> {
    match tokio::task::spawn_blocking(crate::config::Config::load).await {
        Ok(Ok(config)) => config.mesh_relay,
        _ => hub.config.read().await.mesh_relay.clone(),
    }
}

/// Makes the running relay what config.json says (`on_disk`), with the join transition held:
/// started when it names one and none runs, stopped (with its hub client) when it names none.
async fn reconcile_relay(hub: &Arc<Hub>, on_disk: Option<MeshRelayConfig>) -> &'static str {
    let Some(relay) = on_disk else {
        stop_joined(hub).await;
        return "off";
    };
    let mut slot = hub.mesh_relay.lock().await;
    if slot.as_ref().is_some_and(|relay| !relay.is_finished()) {
        return "running";
    }
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

/// `_acpmux/machine_leave_if_auto {userId?}` -> `{left, kept?, hub?}`: leaves only a join signing
/// in made for `userId`, the account signing out. With no account named, or a join recorded under
/// another or no account, the join stays.
pub(super) async fn leave_if_auto(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_LEAVE_IF_AUTO)?;
    let account = params.get("userId").and_then(Value::as_str).filter(|v| !v.trim().is_empty());
    let outcome = leave_transition(hub, crate::cli::cloud_join::leave_if_auto(account)).await;
    serde_json::to_value(outcome).map_err(|e| RpcError::internal(e.to_string()))
}

/// A sign-out's leave (`leave`) with the join transition held, then what it stops here.
async fn leave_transition(
    hub: &Arc<Hub>,
    leave: impl Future<Output = LeaveOutcome>,
) -> LeaveOutcome {
    let _join = hub.join_transition.lock().await;
    let outcome = leave.await;
    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave");
    after_leave(hub, &outcome).await;
    outcome
}

/// What a sign-out's leave stops on this daemon: the relay only when the leave removed the
/// join's from config.json. A relay the person set up, or another hub's, which the leave keeps
/// on disk, keeps running here too, and sends keep its hub client. The caller holds the join
/// transition.
async fn after_leave(hub: &Arc<Hub>, outcome: &LeaveOutcome) {
    if outcome.left && outcome.relay_removed {
        stop_joined(hub).await;
    }
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
/// first, off the start's path, and the relay starts only if the machine stayed joined. The
/// join transition is taken before this returns and held until the relay is settled, so an
/// enroll or leave asked meanwhile waits for it, then acts on what it left; its task is kept on
/// the hub (`Hub::join_start`).
pub(crate) async fn start_relay_at_start(hub: &Arc<Hub>) {
    let join = Arc::clone(&hub.join_transition).lock_owned().await;
    let pending = crate::cli::cloud_join::leave_pending();
    let hub_for_disk = Arc::clone(hub);
    let task = at_start(
        hub,
        join,
        pending,
        crate::cli::cloud_join::finish_leave_at_start(),
        move || async move { relay_on_disk(&hub_for_disk).await },
    )
    .await;
    *hub.join_start.lock_or_recover() = task;
}

/// [`start_relay_at_start`]'s order, holding `join` throughout: with no leave `pending`, the
/// relay config.json names (`on_disk`) now; with one, `finish` it in a task first, then the
/// relay as config.json says then, or nothing while the leave is not finished.
async fn at_start<D: Future<Output = Option<MeshRelayConfig>> + Send + 'static>(
    hub: &Arc<Hub>,
    join: tokio::sync::OwnedMutexGuard<()>,
    pending: bool,
    finish: impl Future<Output = Option<LeaveOutcome>> + Send + 'static,
    on_disk: impl FnOnce() -> D + Send + 'static,
) -> Option<tokio::task::JoinHandle<()>> {
    if !pending {
        reconcile_relay(hub, on_disk().await).await;
        drop(join);
        return None;
    }
    let hub = Arc::clone(hub);
    // task-owner: one leave and maybe the relay start, holding the join transition; kept on
    // `Hub::join_start`, and ended by shutdown. The leave waits at most for the join lock and
    // the hub's bounded answer.
    Some(tokio::spawn(async move {
        let _join = join;
        match finish.await {
            Some(outcome) if !crate::cli::cloud_join::relay_may_start(&outcome) => {
                tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
                // Left with the join's relay: stopped. Not finished: nothing changes now.
                if outcome.left {
                    stop_joined(&hub).await;
                }
            }
            outcome => {
                if let Some(outcome) = outcome {
                    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
                }
                reconcile_relay(&hub, on_disk().await).await;
            }
        }
    }))
}

/// Shutdown's end of the join: the start's task, if it still runs, is ended, and the relay is
/// stopped with the join transition held, so nothing starts one after. An enroll or leave in
/// flight is waited for a bounded time.
pub(crate) async fn stop_at_shutdown(hub: &Arc<Hub>) {
    let start = hub.join_start.lock_or_recover().take();
    if let Some(start) = start {
        start.abort();
        let _ = start.await;
    }
    // timeout: an enroll's hub calls are bounded, but shutdown does not wait on them for long.
    let _join = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        Arc::clone(&hub.join_transition).lock_owned(),
    )
    .await;
    let relay = hub.mesh_relay.lock().await.take();
    if let Some(relay) = relay {
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
}

#[cfg(test)]
mod tests {
    //! A local connection that did not prove the person (a shell, the CLI, an agent) is refused
    //! both RPCs before anything runs: no hub request, no join or leave on disk. And the hub
    //! client a join's relay set, a leave clears and a later enroll replaces.
    use crate::cli::cloud_join::{EnrollOutcome, LeaveOutcome};
    use crate::config::{Config, StoreMode};
    use crate::mesh_http::MeshRelayConfig;
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

    /// A sign-out that kept the person's relay in config.json leaves it running, and sends keep
    /// going through it; one that removed the join's relay stops it.
    #[tokio::test]
    async fn a_sign_out_that_keeps_the_persons_relay_leaves_it_running() {
        let hub = memory_hub();
        let (own, seen) = recording_hub().await;
        let mut slot = hub.mesh_relay.lock().await;
        assert_eq!(super::start_relay_with(&hub, &mut slot, own).await, "started");
        drop(slot);
        let kept =
            LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: false };
        super::after_leave(&hub, &kept).await;
        assert!(hub.mesh_relay.lock().await.as_ref().is_some_and(|relay| !relay.is_finished()));
        assert!(hub.config.read().await.mesh_relay.is_some());
        assert!(hub.mesh.get().is_some(), "sends keep the person's relay's hub");
        send_one(&hub).await;
        assert_eq!(sends(&seen), 1);

        let removed = LeaveOutcome { relay_removed: true, ..kept };
        super::after_leave(&hub, &removed).await;
        assert!(hub.mesh_relay.lock().await.is_none());
        assert!(hub.mesh.get().is_none());
    }

    /// A stand-in for config.json's `meshRelay`, as the transitions read it.
    type Disk = Arc<Mutex<Option<MeshRelayConfig>>>;

    fn read(
        disk: &Disk,
    ) -> impl FnOnce() -> std::future::Ready<Option<MeshRelayConfig>> + Send + 'static {
        let disk = Arc::clone(disk);
        move || std::future::ready(disk.lock().unwrap().clone())
    }

    async fn relay_runs(hub: &crate::hub::Hub) -> bool {
        hub.mesh_relay.lock().await.as_ref().is_some_and(|relay| !relay.is_finished())
    }

    /// Lets every task that can run, run.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    /// A sign-in asked while the start finishes a leave waits for it, then starts the relay its
    /// join wrote: the start's stop never lands after it.
    #[tokio::test]
    async fn a_sign_in_during_the_start_leave_ends_with_the_relay_running() {
        let hub = memory_hub();
        let (relay, _seen) = recording_hub().await;
        let disk: Disk = Arc::new(Mutex::new(None));
        let (release, gate) = tokio::sync::oneshot::channel::<()>();
        let join = Arc::clone(&hub.join_transition).lock_owned().await;
        let start = super::at_start(
            &hub,
            join,
            true,
            async move {
                let _ = gate.await;
                Some(LeaveOutcome {
                    left: true,
                    kept: None,
                    hub: Some("revoked"),
                    relay_removed: true,
                })
            },
            read(&disk),
        )
        .await
        .expect("a pending leave runs in a task");
        let sign_in = {
            let (hub, disk, written) = (Arc::clone(&hub), Arc::clone(&disk), read(&disk));
            // task-owner: the test's sign-in; awaited below.
            tokio::spawn(async move {
                let enroll = async move {
                    *disk.lock().unwrap() = Some(relay);
                    EnrollOutcome::Joined
                };
                super::enroll_transition(&hub, enroll, written).await
            })
        };
        settle().await;
        assert!(!sign_in.is_finished(), "the enroll waits for the start's leave");
        assert!(disk.lock().unwrap().is_none());
        let _ = release.send(());
        start.await.unwrap();
        assert_eq!(sign_in.await.unwrap(), (EnrollOutcome::Joined, Some("started")));
        assert!(relay_runs(&hub).await, "the new join's relay runs");
        assert!(hub.mesh.get().is_some());
        super::stop_joined(&hub).await;
    }

    /// A sign-out asked while the start brings up the relay waits for it, then stops it: the
    /// start's relay never comes back after the sign-out.
    #[tokio::test]
    async fn a_sign_out_during_the_start_ends_with_no_relay() {
        let hub = memory_hub();
        let (relay, _seen) = recording_hub().await;
        let disk: Disk = Arc::new(Mutex::new(Some(relay)));
        let (release, gate) = tokio::sync::oneshot::channel::<()>();
        let join = Arc::clone(&hub.join_transition).lock_owned().await;
        let start = super::at_start(
            &hub,
            join,
            true,
            async move {
                let _ = gate.await;
                Some(LeaveOutcome {
                    left: false,
                    kept: Some("signedIn"),
                    hub: None,
                    relay_removed: false,
                })
            },
            read(&disk),
        )
        .await
        .expect("a pending leave runs in a task");
        let sign_out = {
            let (hub, disk) = (Arc::clone(&hub), Arc::clone(&disk));
            // task-owner: the test's sign-out; awaited below.
            tokio::spawn(async move {
                let leave = async move {
                    *disk.lock().unwrap() = None;
                    LeaveOutcome {
                        left: true,
                        kept: None,
                        hub: Some("revoked"),
                        relay_removed: true,
                    }
                };
                super::leave_transition(&hub, leave).await
            })
        };
        settle().await;
        assert!(!sign_out.is_finished(), "the leave waits for the start");
        assert!(disk.lock().unwrap().is_some());
        let _ = release.send(());
        start.await.unwrap();
        assert!(sign_out.await.unwrap().left);
        assert!(!relay_runs(&hub).await, "no relay after the sign-out");
        assert!(hub.mesh_relay.lock().await.is_none());
        assert!(hub.mesh.get().is_none());
        assert!(hub.config.read().await.mesh_relay.is_none());
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
