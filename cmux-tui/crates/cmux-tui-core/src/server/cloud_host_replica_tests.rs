//! Wire tests for the host replica publisher (`cloud-host-replica-v1`,
//! plans/cmux-next/object-sync/DESIGN.md phase 3): the app's lease over the
//! daemon's line protocol, a scripted cloud, the frames the daemon publishes,
//! and the forwarded ops it runs through its own command path.

use std::time::Duration;

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::*;
use super::install_host_replica;
use crate::cloud_conversations::testing::{FakeBackend, ScriptedWire, wait_until};
use crate::cloud_conversations::{ConnectError, HostReplica, HostReplicaOptions};

const ME: &str = "user_00000000000000000001";
const HOST: &str = "host_0123456789abcdefghij";
/// `{sub: ME, inst: "inst_mac", team: "team_1", exp}`, unsigned (the daemon only reads it).
const INSTALL_TOKEN: &str = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyXzAwMDAwMDAwMDAwMDAwMDAwMDAxIiwiaW5zdCI6Imluc3RfbWFjIiwidGVhbSI6InRlYW1fMSIsImV4cCI6NDEwMjQ0NDgwMH0.sig";
/// The same with `agt` (a chief token).
const CHIEF_TOKEN: &str = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyXzAwMDAwMDAwMDAwMDAwMDAwMDAxIiwiaW5zdCI6Imluc3RfbWFjIiwidGVhbSI6InRlYW1fMSIsImFndCI6ImFnZW50X2NoaWVmIn0.sig";

fn stream() -> String {
    format!("host:{HOST}/session")
}

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn replica_mux() -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    replica_mux_with(HostReplicaOptions::default())
}

fn replica_mux_with(defaults: HostReplicaOptions) -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("host-replica", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = HostReplicaOptions {
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        settle: Duration::from_millis(5),
        max_delay: Duration::from_millis(50),
        purge_timeout: Duration::from_secs(5),
        ..defaults
    };
    assert!(install_host_replica(&mux, HostReplica::with_options(backend.clone(), options)));
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client, backend)
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn resource(mux: &Arc<Mux>, operation: &str, params: Value, key: &str) -> Value {
    let request = json!({"protocol":"cmux.protocol/2","type":"request","id":key,
        "operation":operation,"params":params,"idempotency_key":key});
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
}

fn create_workspace(mux: &Arc<Mux>, name: &str) -> String {
    let created = resource(
        mux,
        "workspace.create",
        json!({"machine":"current","session":"current","name":name,"initial_content":"empty"}),
        &format!("create-{name}"),
    );
    created["result"]["value"]["workspace_id"].as_str().unwrap().to_string()
}

fn lease(mux: &Arc<Mux>, client: u64, token: &str) -> anyhow::Result<Value> {
    run(
        mux,
        client,
        json!({"cmd":"cloud-host-replica-set","api_base_url":"https://api.cmux.test",
               "install_token":token,"expires_at":4_102_444_800_000_u64,"host_name":"studio"}),
    )
}

fn frames(wire: &ScriptedWire) -> Vec<Value> {
    wire.sent().iter().map(|text| serde_json::from_str(text).unwrap()).collect()
}

fn wait_frame(wire: &ScriptedWire, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
    wait_until(what, || frames(wire).iter().any(&matches));
    frames(wire).into_iter().find(|frame| matches(frame)).unwrap()
}

fn workspace_name(mux: &Arc<Mux>, id: &str) -> String {
    let listed = list_workspaces_reply(mux).unwrap().to_string();
    assert!(listed.contains(id), "{listed}");
    let value: Value = serde_json::from_str(&listed).unwrap();
    value["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w.to_string().contains(id))
        .map(|w| w["name"].as_str().unwrap_or_default().to_string())
        .unwrap()
}

/// The app's install token makes the daemon enroll its host and publish its
/// workspace tree; the owner's forwarded rename runs through the daemon's
/// own command path once, its change is published before its answer, and
/// anything outside the allowlist or from another user is refused.
#[test]
fn the_daemon_publishes_its_tree_and_runs_only_the_owners_allowed_ops() {
    let (mux, client, backend) = replica_mux();
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let workspace = create_workspace(&mux, "before");
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "cloud-host-replica-v1")
    );

    backend.reply("/v1/ops", 200, json!({"ok":true,"value":{"id":HOST,"name":"studio"}}));
    let wire = backend.wire();
    wire.push_text(json!({"t":"welcome","role":"publisher","host":HOST,"heads":{}}).to_string());
    let status = lease(&mux, client, INSTALL_TOKEN).unwrap();
    assert!(!status.to_string().contains(INSTALL_TOKEN), "the token is never echoed");

    // Enrolled with the install token, then connected to the host's replica socket.
    let snapshot =
        wait_frame(&wire, "the snapshot", |f| f["t"] == "publish" && f["snapshot"].is_object());
    let posted = backend.posted();
    assert_eq!(posted[0].body["op"], "host.enroll");
    assert_eq!(posted[0].bearer, INSTALL_TOKEN);
    let connected = backend.connected();
    assert_eq!(connected[0].url, format!("wss://api.cmux.test/v1/wire/host/{HOST}"));
    assert_eq!(connected[0].bearer, INSTALL_TOKEN);
    assert_eq!(snapshot["stream"], stream());
    // A stream the replica does not hold starts at the wall clock (ms).
    assert!(snapshot["snapshot"]["seq"].as_u64().unwrap() > 1_600_000_000_000);
    assert!(snapshot["snapshot"]["state"].to_string().contains("before"));
    // Only the listed workspace fields leave the Mac: no screens, no titles.
    let published = &snapshot["snapshot"]["state"]["workspaces"][0];
    for kept in published.as_object().unwrap().keys() {
        assert!(
            [
                "id",
                "resource_id",
                "short_id",
                "name",
                "name_revision",
                "group",
                "color",
                "icon",
                "pinned",
                "marked_unread",
                "unread_count",
                "active"
            ]
            .contains(&kept.as_str()),
            "{kept} is published"
        );
    }
    assert!(published.get("screens").is_none() && published.get("title").is_none(), "{published}");

    // The owner's rename: the daemon runs it, publishes the change, then answers.
    let op = |key: &str, to: &str, user: &str, op: &str, params: Value| {
        json!({"t":"op","stream":stream(),"op":op,"params":params,"idempotency_key":key,
               "origin":"user","to":to,"principal":{"user":user,"kind":"session"}})
        .to_string()
    };
    wire.push_text(op(
        "k1",
        "r1",
        ME,
        "workspace.rename",
        json!({"workspace":workspace,"name":"after"}),
    ));
    let settled =
        wait_frame(&wire, "the settle", |f| f["t"] == "request-settled" && f["to"] == "r1");
    assert_eq!(settled["ok"], true);
    assert_eq!(workspace_name(&mux, &workspace), "after");
    let sent = frames(&wire);
    let event = sent
        .iter()
        .position(|f| {
            f["t"] == "publish" && f["event"]["effects"]["state"].to_string().contains("after")
        })
        .unwrap();
    let settle = sent.iter().position(|f| f["t"] == "request-settled" && f["to"] == "r1").unwrap();
    assert!(event < settle, "the change is published before the answer");
    assert_eq!(settled["sequence"], sent[event]["event"]["seq"]);
    assert!(sent.iter().any(|f| f["t"] == "result" && f["to"] == "r1" && f["replayed"] == false));

    // The same key again answers from memory and runs nothing.
    let before = frames(&wire).len();
    wire.push_text(op(
        "k1",
        "r1b",
        ME,
        "workspace.rename",
        json!({"workspace":workspace,"name":"again"}),
    ));
    let replay = wait_frame(&wire, "the replay", |f| f["t"] == "result" && f["to"] == "r1b");
    assert_eq!(replay["replayed"], true);
    assert_eq!(workspace_name(&mux, &workspace), "after");
    assert!(!frames(&wire)[before..].iter().any(|f| f["t"] == "publish"));

    // Another user, an op outside the allowlist, a field outside it: refused, nothing runs.
    wire.push_text(op(
        "k2",
        "r2",
        "user_00000000000000000002",
        "workspace.rename",
        json!({"workspace":workspace,"name":"x"}),
    ));
    let other = wait_frame(&wire, "another user", |f| f["t"] == "reject" && f["to"] == "r2");
    assert_eq!(other["code"], "auth.forbidden");
    wire.push_text(op("k3", "r3", ME, "workspace.close", json!({"workspace":workspace})));
    let closed = wait_frame(&wire, "a closed op", |f| f["t"] == "reject" && f["to"] == "r3");
    assert_eq!(closed["code"], "operation.unsupported");
    wire.push_text(op(
        "k4",
        "r4",
        ME,
        "workspace.rename",
        json!({"workspace":workspace,"name":"y","machine":"other"}),
    ));
    let field = wait_frame(&wire, "a closed field", |f| f["t"] == "reject" && f["to"] == "r4");
    assert_eq!(field["code"], "validation.invalid");
    wait_frame(&wire, "settles of refusals", |f| {
        f["t"] == "request-settled" && f["to"] == "r4" && f["ok"] == false
    });
    assert_eq!(workspace_name(&mux, &workspace), "after");

    // A local change is published too.
    resource(
        &mux,
        "workspace.rename",
        json!({"machine":"current","session":"current","workspace":workspace,"name":"local"}),
        "local-rename",
    );
    wait_frame(&wire, "the local change", |f| {
        f["t"] == "publish" && f["event"]["effects"]["state"].to_string().contains("local")
    });

    // The replica asks for a snapshot (a gap): it gets a new one at a new seq.
    let seq = frames(&wire).iter().filter_map(|f| f["event"]["seq"].as_u64()).max().unwrap();
    wire.push_text(json!({"t":"snapshot.request","stream":stream(),"pending":[]}).to_string());
    let fresh =
        wait_frame(&wire, "a requested snapshot", |f| f["snapshot"]["seq"].as_u64() > Some(seq));
    assert!(fresh["snapshot"]["state"].to_string().contains("local"));

    // The host's off switch: the cloud copy is purged, then the lease is dropped.
    let off = run(&mux, client, json!({"cmd":"cloud-host-replica-clear","purge":true})).unwrap();
    assert_eq!(off["purge_pending"], true);
    wait_frame(&wire, "the purge", |f| f["t"] == "replica.purge");
    wire.push_text(json!({"t":"replica.purged"}).to_string());
    wait_until("the lease to go", || {
        run(&mux, client, json!({"cmd":"cloud-host-replica-status"})).unwrap()["state"] == "off"
    });
    assert!(
        run(&mux, client, json!({"cmd":"cloud-host-replica-status"}))
            .unwrap()
            .get("api_base_url")
            .is_none()
    );
}

/// Only the verified app leases the install token, and a chief token never
/// publishes a host.
#[test]
fn only_the_verified_app_leases_and_never_with_a_chief_token() {
    let (mux, client, backend) = replica_mux();
    set_role_for_test(&mux, client, "main");
    let refused = lease(&mux, client, INSTALL_TOKEN).unwrap_err();
    assert!(refused.to_string().contains("verified cmux app"), "{refused}");
    let status = run(&mux, client, json!({"cmd":"cloud-host-replica-status"})).unwrap_err();
    assert!(status.to_string().contains("verified cmux app"), "{status}");

    set_verified_app_for_test(&mux, client, true);
    let chief = lease(&mux, client, CHIEF_TOKEN).unwrap_err();
    assert!(chief.to_string().contains("chief"), "{chief}");
    assert!(backend.posted().is_empty() && backend.connected().is_empty());
    assert_eq!(
        run(&mux, client, json!({"cmd":"cloud-host-replica-status"})).unwrap()["state"],
        "off"
    );
}

fn status(mux: &Arc<Mux>, client: u64) -> Value {
    run(mux, client, json!({"cmd":"cloud-host-replica-status"})).unwrap()
}

fn connect_again(backend: &FakeBackend, heads: Value) -> ScriptedWire {
    backend.reply("/v1/ops", 200, json!({"ok":true,"value":{"id":HOST,"name":"studio"}}));
    let wire = backend.wire();
    wire.push_text(json!({"t":"welcome","role":"publisher","host":HOST,"heads":heads}).to_string());
    wire
}

/// The off switch answers an op that arrives while it runs, and the next
/// lease publishes ahead of every seq a reader saw before the purge. A host
/// the cloud removed (close 4403) stays off through a token refresh and
/// enrolls again only after the app clears the replica.
#[test]
fn the_off_switch_never_moves_a_reader_back_and_a_removed_host_stays_off() {
    let (mux, client, backend) = replica_mux();
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    create_workspace(&mux, "tree");
    let first = connect_again(&backend, json!({}));
    lease(&mux, client, INSTALL_TOKEN).unwrap();
    let before = wait_frame(&first, "the first snapshot", |f| f["snapshot"].is_object());
    let seen = before["snapshot"]["seq"].as_u64().unwrap();

    // The off switch, with an op forwarded before the replica confirmed it.
    run(&mux, client, json!({"cmd":"cloud-host-replica-clear","purge":true})).unwrap();
    wait_frame(&first, "the purge", |f| f["t"] == "replica.purge");
    first.push_text(
        json!({"t":"op","stream":stream(),"op":"workspace.rename","params":{},"idempotency_key":"late",
               "origin":"user","to":"r9","principal":{"user":ME,"kind":"session"}})
        .to_string(),
    );
    let late =
        wait_frame(&first, "the late op's answer", |f| f["t"] == "reject" && f["to"] == "r9");
    assert_eq!(late["retryable"], true);
    wait_frame(&first, "its settle", |f| {
        f["t"] == "request-settled" && f["to"] == "r9" && f["ok"] == false
    });
    first.push_text(json!({"t":"replica.purged"}).to_string());
    wait_until("off", || status(&mux, client)["state"] == "off");

    // On again: the replica holds nothing (no head), and the new snapshot is
    // still ahead of the reader's old cursor.
    let second = connect_again(&backend, json!({}));
    lease(&mux, client, INSTALL_TOKEN).unwrap();
    let after = wait_frame(&second, "the snapshot after the purge", |f| f["snapshot"].is_object());
    assert!(after["snapshot"]["seq"].as_u64().unwrap() > seen, "{after} after {seen}");

    // The cloud removes the host: the socket closes 4403 and a token refresh
    // does not enroll it again.
    wait_until("online", || status(&mux, client)["state"] == "online");
    second.push_close(Some(4403));
    wait_until("forbidden", || status(&mux, client)["state"] == "forbidden");
    let enrolls = backend.posted().len();
    let refreshed = lease(&mux, client, INSTALL_TOKEN).unwrap();
    assert_eq!(refreshed["state"], "forbidden");
    assert!(refreshed["last_error"].as_str().unwrap().contains("removed"));
    assert_eq!(status(&mux, client)["state"], "forbidden");
    assert_eq!(backend.posted().len(), enrolls, "no enrollment after a refresh");

    // Clearing, then a lease: the explicit action enrolls the host again.
    run(&mux, client, json!({"cmd":"cloud-host-replica-clear"})).unwrap();
    let third = connect_again(&backend, json!({}));
    lease(&mux, client, INSTALL_TOKEN).unwrap();
    wait_frame(&third, "the snapshot after enrolling again", |f| f["snapshot"].is_object());
    assert_eq!(backend.posted().len(), enrolls + 1);
}

fn lease_until(mux: &Arc<Mux>, client: u64, token: &str, expires_at: u64) -> Value {
    run(
        mux,
        client,
        json!({"cmd":"cloud-host-replica-set","api_base_url":"https://api.cmux.test",
               "install_token":token,"expires_at":expires_at,"host_name":"studio"}),
    )
    .unwrap()
}

fn needed(events: &crate::MuxEventReceiver, seen: &mut Vec<Value>) -> Vec<Value> {
    seen.extend(
        events
            .try_iter()
            .filter(|event| matches!(event, MuxEvent::CloudConversation(_)))
            .map(|event| subscribed_event_json(&event)),
    );
    seen.iter().filter(|event| event["event"] == "cloud-host-replica-needed").cloned().collect()
}

/// The publisher asks the app for a new install token before the lease
/// ends, takes a renewal without dropping its socket, connects again with
/// the new token when the old one expires (4401), and asks again with
/// `unauthenticated` when it holds no newer token.
#[test]
fn the_daemon_asks_for_a_new_token_in_time_and_a_renewal_keeps_the_socket() {
    let (mux, client, backend) = replica_mux();
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let events = mux.subscribe();
    let mut seen = Vec::new();
    let now = u64::try_from(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
    )
    .unwrap();
    let renewed_token = INSTALL_TOKEN.replace(".sig", ".sig2");

    // A lease that ends inside the refresh lead: the daemon asks at once.
    let first = connect_again(&backend, json!({}));
    lease_until(&mux, client, INSTALL_TOKEN, now + 30_000);
    wait_frame(&first, "online", |f| f["snapshot"].is_object());
    wait_until("the expiring ask", || {
        needed(&events, &mut seen).iter().any(|e| e["reason"] == "expiring")
    });
    let ask = needed(&events, &mut seen)[0].clone();
    assert_eq!(ask["expires_at"], now + 30_000, "{ask}");

    // The renewal swaps the token in place: the same socket answers an op.
    lease_until(&mux, client, &renewed_token, now + 3_600_000);
    first.push_text(
        json!({"t":"op","stream":stream(),"op":"workspace.close","params":{},"idempotency_key":"after-renewal",
               "origin":"user","to":"r1","principal":{"user":ME,"kind":"session"}})
        .to_string(),
    );
    wait_frame(&first, "an answer on the same socket", |f| f["t"] == "reject" && f["to"] == "r1");
    assert_eq!(backend.connected().len(), 1, "a renewal does not reconnect");
    assert_eq!(status(&mux, client)["state"], "online");

    // The old token expires: HostDO closes 4401, and the new token connects at once.
    let second = backend.wire();
    second.push_text(json!({"t":"welcome","role":"publisher","host":HOST,"heads":{}}).to_string());
    first.push_close(Some(4401));
    wait_frame(&second, "the reconnect", |f| f["snapshot"].is_object());
    assert_eq!(backend.connected()[1].bearer, renewed_token);
    assert!(!needed(&events, &mut seen).iter().any(|e| e["reason"] == "unauthenticated"));

    // No newer token: the publisher stops and asks for one.
    second.push_close(Some(4401));
    wait_until("unauthenticated", || status(&mux, client)["state"] == "unauthenticated");
    wait_until("the unauthenticated ask", || {
        needed(&events, &mut seen).iter().any(|e| e["reason"] == "unauthenticated")
    });
}

#[test]
fn a_refused_token_is_asked_for_again_until_a_new_lease_comes() {
    let (mux, client, backend) = replica_mux_with(HostReplicaOptions {
        reask: Duration::from_millis(50),
        ..HostReplicaOptions::default()
    });
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let wire = connect_again(&backend, json!({}));
    lease(&mux, client, INSTALL_TOKEN).unwrap();
    wait_frame(&wire, "online", |f| f["snapshot"].is_object());

    // The cloud refuses the token while no app connection listens: that ask is missed.
    wire.push_close(Some(4401));
    wait_until("unauthenticated", || status(&mux, client)["state"] == "unauthenticated");

    // An app connection that subscribes later still hears the ask.
    let events = mux.subscribe();
    let mut seen = Vec::new();
    wait_until("the ask again", || {
        needed(&events, &mut seen).iter().any(|e| e["reason"] == "unauthenticated")
    });

    // A new lease connects again.
    let again = connect_again(&backend, json!({}));
    lease(&mux, client, &INSTALL_TOKEN.replace(".sig", ".sig2")).unwrap();
    wait_frame(&again, "online again", |f| f["snapshot"].is_object());
}

/// A purge whose token the cloud refuses (4401) waits for a new lease and
/// asks for it at the `reask` pace; it does not reconnect with the dead
/// token in a loop.
#[test]
fn a_purge_whose_token_is_refused_waits_for_a_new_one_instead_of_reconnecting_at_once() {
    let (mux, client, backend) = replica_mux_with(HostReplicaOptions {
        reask: Duration::from_millis(100),
        ..HostReplicaOptions::default()
    });
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let events = mux.subscribe();
    let mut seen = Vec::new();
    let wire = connect_again(&backend, json!({}));
    lease(&mux, client, INSTALL_TOKEN).unwrap();
    wait_frame(&wire, "online", |f| f["snapshot"].is_object());

    // The off switch, and the token expires before the cloud confirms the purge.
    run(&mux, client, json!({"cmd":"cloud-host-replica-clear","purge":true})).unwrap();
    wait_frame(&wire, "the purge", |f| f["t"] == "replica.purge");
    for _ in 0..40 {
        backend.refuse(ConnectError::Unauthenticated);
    }
    wire.push_close(Some(4401));
    // Two asks are one `reask` apart: the time to count the connects.
    wait_until("the ask and the ask again", || {
        needed(&events, &mut seen).iter().filter(|e| e["reason"] == "unauthenticated").count() >= 2
    });
    let attempts = backend.connected().len();
    assert!(attempts <= 3, "{attempts} connects while the token is refused");
    assert_eq!(status(&mux, client)["purge_pending"], true);

    // The app's answer (CloudHostReplicaFollower): a new lease, then the purge again.
    backend.wires.lock().unwrap().clear();
    let again = connect_again(&backend, json!({}));
    lease(&mux, client, &INSTALL_TOKEN.replace(".sig", ".sig2")).unwrap();
    run(&mux, client, json!({"cmd":"cloud-host-replica-clear","purge":true})).unwrap();
    wait_frame(&again, "the purge with the new token", |f| f["t"] == "replica.purge");
    again.push_text(json!({"t":"replica.purged"}).to_string());
    wait_until("off", || status(&mux, client)["state"] == "off");
    assert_ne!(status(&mux, client)["purge_pending"], true);
}

/// A Mac clock ahead of the cloud's (every new token reads as expiring) and
/// a cloud that refuses every token: each new lease asks `expiring` and then
/// `unauthenticated`. Each reason keeps its own `reask` pace, so the asks do
/// not drive a loop of token mints.
#[test]
fn expiring_and_refused_asks_keep_their_pace_across_leases() {
    let (mux, client, backend) = replica_mux_with(HostReplicaOptions {
        reask: Duration::from_secs(60),
        ..HostReplicaOptions::default()
    });
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let events = mux.subscribe();
    let mut seen = Vec::new();
    let now = u64::try_from(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
    )
    .unwrap();
    let count = |events: &crate::MuxEventReceiver, seen: &mut Vec<Value>, reason: &str| {
        needed(events, seen).iter().filter(|e| e["reason"] == reason).count()
    };

    backend.reply("/v1/ops", 200, json!({"ok":true,"value":{"id":HOST,"name":"studio"}}));
    backend.refuse(ConnectError::Unauthenticated);
    lease_until(&mux, client, INSTALL_TOKEN, now + 30_000);
    wait_until("the refused ask", || count(&events, &mut seen, "unauthenticated") == 1);
    assert_eq!(count(&events, &mut seen, "expiring"), 1);

    // The app's answer: a new token that also reads as expiring, also refused.
    backend.refuse(ConnectError::Unauthenticated);
    lease_until(&mux, client, &INSTALL_TOKEN.replace(".sig", ".sig2"), now + 31_000);
    wait_until("the second connect", || backend.connected().len() == 2);
    wait_until("refused again", || status(&mux, client)["state"] == "unauthenticated");
    assert_eq!(count(&events, &mut seen, "expiring"), 1, "{seen:?}");
    assert_eq!(count(&events, &mut seen, "unauthenticated"), 1, "{seen:?}");
}

fn chief_stream() -> String {
    format!("host:{HOST}/chief")
}

fn chief_conversation(mux: &Arc<Mux>, client: u64) -> String {
    let created = run(
        mux,
        client,
        json!({"cmd":"conversation-create","idempotency_key":"chief-create","actor":"user_local",
               "title":"Chief","participants":[
                   {"id":"user_local","kind":"human","display_name":"You"},
                   {"id":"agent_mux","kind":"agent","display_name":"Chief","agent_class":"mux","acp_session":"mux"}]}),
    )
    .unwrap();
    created["conversation"]["id"].as_str().unwrap().to_string()
}

fn chief_texts(mux: &Arc<Mux>, client: u64, conversation: &str) -> Vec<(String, String)> {
    let snapshot = run(
        mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":50}),
    )
    .unwrap();
    snapshot["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            (
                m["author"].as_str().unwrap_or("").to_string(),
                m["parts"][0]["text"].as_str().unwrap_or("").to_string(),
            )
        })
        .collect()
}

/// The phone reaches the Mac Chief through the cloud copy (a450, cmux-prompts
/// logs/iphone-chief-DESIGN.md): the daemon publishes the Chief conversation on
/// `host:<h>/chief`, and a `conversation.message.send` the cloud forwards (live or
/// from HostDO's mailbox, `to: "mailbox"`) becomes the person's message once.
#[test]
fn the_daemon_publishes_the_chief_chat_and_takes_the_phones_messages_once() {
    let (mux, client, backend) = replica_mux();
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let conversation = chief_conversation(&mux, client);
    run(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"mac-1",
               "actor":"user_local","op":{"kind":"message.send","client_msg_id":"mac-1",
               "parts":[{"type":"text","text":"hello from the Mac"}]}}),
    )
    .unwrap();

    backend.reply("/v1/ops", 200, json!({"ok":true,"value":{"id":HOST,"name":"studio"}}));
    let wire = backend.wire();
    wire.push_text(json!({"t":"welcome","role":"publisher","host":HOST,"heads":{}}).to_string());
    lease(&mux, client, INSTALL_TOKEN).unwrap();

    // The Chief chat is published with the Mac offline-readable copy: summary and messages.
    let chief = wait_frame(&wire, "the chief snapshot", |f| {
        f["t"] == "publish" && f["stream"] == chief_stream() && f["snapshot"].is_object()
    });
    let state = &chief["snapshot"]["state"];
    assert_eq!(state["conversation"]["id"], conversation);
    assert!(state["messages"].to_string().contains("hello from the Mac"), "{state}");

    // A queued phone message (from the mailbox): the person's message, then published, then settled.
    let op = |key: &str, to: &str, params: Value| {
        json!({"t":"op","stream":chief_stream(),"op":"conversation.message.send","params":params,
               "idempotency_key":key,"origin":"user","to":to,
               "principal":{"user":ME,"kind":"session"}})
        .to_string()
    };
    wire.push_text(op("phone-1", "mailbox", json!({"text":"from the phone"})));
    let settled = wait_frame(&wire, "the mailbox settle", |f| {
        f["t"] == "request-settled" && f["to"] == "mailbox" && f["idempotency_key"] == "phone-1"
    });
    assert_eq!(settled["ok"], true);
    let texts = chief_texts(&mux, client, &conversation);
    assert_eq!(texts.iter().filter(|(_, t)| t == "from the phone").count(), 1, "{texts:?}");
    assert!(texts.iter().any(|(who, t)| who == "user_local" && t == "from the phone"), "{texts:?}");
    let snapshot = run(
        &mux,
        client,
        json!({"cmd":"conversation-snapshot","conversation":conversation,"tail":50}),
    )
    .unwrap();
    assert!(
        snapshot["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["client_msg_id"] == "cloud-phone-1"),
        "the phone's id names the delivered message"
    );
    wait_frame(&wire, "the published phone message", |f| {
        f["stream"] == chief_stream() && f.to_string().contains("from the phone")
    });

    // The same key again (a lost answer, a resend): no second message.
    wire.push_text(op("phone-1", "mailbox", json!({"text":"from the phone"})));
    wait_until("the replay", || {
        frames(&wire)
            .iter()
            .filter(|f| f["t"] == "request-settled" && f["idempotency_key"] == "phone-1")
            .count()
            == 2
    });
    let texts = chief_texts(&mux, client, &conversation);
    assert_eq!(texts.iter().filter(|(_, t)| t == "from the phone").count(), 1, "{texts:?}");

    // Only the text passes: another field is refused and nothing is sent.
    wire.push_text(op("phone-2", "r2", json!({"text":"x","actor":"agent_mux"})));
    let refused = wait_frame(&wire, "a closed field", |f| f["t"] == "reject" && f["to"] == "r2");
    assert_eq!(refused["code"], "validation.invalid");

    // A new Mac message reaches the copy too.
    run(
        &mux,
        client,
        json!({"cmd":"conversation-op","conversation":conversation,"idempotency_key":"mac-2",
               "actor":"user_local","op":{"kind":"message.send","client_msg_id":"mac-2",
               "parts":[{"type":"text","text":"answer for the phone"}]}}),
    )
    .unwrap();
    wait_frame(&wire, "the Mac's answer", |f| {
        f["stream"] == chief_stream() && f.to_string().contains("answer for the phone")
    });
}
