//! acpmux's wire lockstep (cmux-wire-lockstep): the manifest of every name the daemon speaks,
//! generated from its registries, and the daemon run old against new both ways.
//!
//! - `manifest_is_current`: `spec/wire/acpmux.json` is what `manifest()` builds from
//!   `protocol::ir()` (methods, notifications, closed params keys, `_meta.acpmux` keys),
//!   `capabilities::CAPABILITIES` (what `initialize` lists in `_meta.acpmux.capabilities`),
//!   `peer::PEER_FEATURES` (`_meta.acpmux.features`) and `capabilities::CLIENT_OPT_INS` (the flags
//!   a client names in its `initialize` params). `CMUX_UPDATE_WIRE_MANIFEST=1` rewrites it.
//! - `a_new_daemon_serves_an_old_client`: a client that knows only the base manifest asks every
//!   request it knows and is never told -32601 for one the daemon listed; every notification the
//!   daemon pushes it is one it knows.
//! - `a_new_peer_link_dials_an_old_daemon`: the daemon's peer link dials a daemon that knows only
//!   the base manifest, lists only its features and answers -32601 to anything else; every name
//!   the link sends is one that daemon knows.
//!
//! The base is `$CMUX_WIRE_BASE_DIR/acpmux.json` when CI wrote the PR base's manifest there, else
//! the committed manifest. The `oldest` tests run against a peer that knows only the legacy names
//! and lists nothing: what the rule "never send a name the other side did not say it knows"
//! demands of a daemon today.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts: the old client's requests reach handlers, never a harness. Kept: the
// manifest rewrite switch and the directory CI writes the PR base's manifest to (no secrets).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["CMUX_UPDATE_WIRE_MANIFEST", "CMUX_WIRE_BASE_DIR"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::method;
use acpmux::server::serve_connection;
use cmux_wire_lockstep::{Dir, Manifest, OldPeer, Tap, assert_manifest_current, base_manifest};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Frame;

const PROTOCOL: &str = "acpmux";
const COMMITTED: &str = include_str!("../../../spec/wire/acpmux.json");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const UNKNOWN_METHOD: i64 = -32601;

fn committed_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/wire/acpmux.json")
}

// ---------------------------------------------------------------------------------------------
// The manifest.

/// The registry's methods by name: their kind (`request`, `notification`, ...).
fn kinds() -> BTreeMap<String, String> {
    let ir = acpmux::protocol::ir();
    ir["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| (m["name"].as_str().unwrap().to_owned(), m["kind"].as_str().unwrap().to_owned()))
        .collect()
}

/// `name`'s wire form: a `kind:`-prefixed name as it is; a registry name as `notify:` (the daemon
/// tells) or `method:` (a request, a client's notification, a daemon's request).
fn wire(kinds: &BTreeMap<String, String>, name: &str) -> String {
    if let Some((kind, _)) = name.split_once(':')
        && cmux_wire_lockstep::KINDS.contains(&kind)
    {
        return name.to_owned();
    }
    match kinds.get(name).map(String::as_str) {
        Some("notification") => format!("notify:{name}"),
        Some("client_local") => panic!("{name} is client-local, never on the wire"),
        Some(_) => format!("method:{name}"),
        None => panic!("{name} is not in the protocol registry (protocol::registry)"),
    }
}

// skew: strict: reads the spec's closed types to list their keys; it decodes no peer message.
/// The keys of a closed object type (`additionalProperties: false`), `_meta` left out.
fn closed_keys(types: &Map<String, Value>, schema: &Value) -> Option<Vec<String>> {
    let name = schema.get("$ref")?.as_str()?.strip_prefix("#/types/")?;
    let ty = types.get(name)?;
    if ty.get("additionalProperties") != Some(&Value::Bool(false)) {
        return None;
    }
    Some(ty["properties"].as_object()?.keys().filter(|k| *k != "_meta").cloned().collect())
}

/// What acpmux speaks, from its registries.
fn manifest() -> Manifest {
    let ir = acpmux::protocol::ir();
    let types = ir["types"].as_object().unwrap();
    let kinds = kinds();
    let mut m = Manifest::new(
        PROTOCOL,
        "initialize: the reply's _meta.acpmux.capabilities (daemon surfaces, by id) and \
         _meta.acpmux.features (feature:<id>, read by peer links and the CLI); the params' \
         _meta.acpmux.<flag>: true (client:<flag>, a client's opt-ins)",
    );
    let mut all = BTreeSet::new();
    for entry in ir["methods"].as_array().unwrap() {
        let name = entry["name"].as_str().unwrap();
        if entry["kind"] == "client_local" {
            continue;
        }
        all.insert(wire(&kinds, name));
        if let Some(keys) = closed_keys(types, &entry["params"]) {
            all.extend(keys.into_iter().map(|k| format!("param:{name}#{k}")));
        }
    }
    let meta = types["AcpmuxRequestMeta"]["properties"].as_object().unwrap();
    all.extend(meta.keys().map(|k| format!("field:_meta.acpmux#{k}")));

    let mut gate = |id: String, names: &[&str]| {
        let names: BTreeSet<String> = names.iter().map(|n| wire(&kinds, n)).collect();
        if names.is_empty() {
            // A behavior with no name of its own: nothing on the wire for the manifest to gate.
            return;
        }
        all.extend(names.iter().cloned());
        assert!(m.capabilities.insert(id.clone(), names).is_none(), "{id} twice");
    };
    for c in acpmux::capabilities::CAPABILITIES {
        gate(c.id.to_owned(), c.wire);
    }
    for f in acpmux::peer::PEER_FEATURES {
        gate(format!("feature:{}", f.id), f.gates);
    }
    for o in acpmux::capabilities::CLIENT_OPT_INS {
        gate(format!("client:{}", o.flag), o.gates);
    }
    let gated: BTreeSet<String> = m.capabilities.values().flatten().cloned().collect();
    m.legacy = all.difference(&gated).cloned().collect();
    m
}

#[test]
fn manifest_is_current() {
    let _ = HERMETIC;
    assert_manifest_current(&manifest(), &committed_path()).unwrap();
}

/// The oldest peer a manifest still speaks with: its legacy names and the base surface
/// (`acpmux-v1`, which every daemon lists), no other capability, feature or opt-in.
fn oldest(of: &Manifest) -> Manifest {
    let capabilities = of.capabilities.iter().filter(|(id, _)| *id == "acpmux-v1");
    Manifest {
        capabilities: capabilities.map(|(k, v)| (k.clone(), v.clone())).collect(),
        ..of.clone()
    }
}

fn oldest_peer() -> OldPeer {
    OldPeer::new(oldest(&base_manifest(PROTOCOL, COMMITTED).unwrap()))
}

fn base() -> OldPeer {
    OldPeer::new(base_manifest(PROTOCOL, COMMITTED).unwrap())
}

// ---------------------------------------------------------------------------------------------
// The daemon under test.

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The wire names one JSON-RPC message carries, as `dir` (from the daemon under test: Sent).
fn names_of(kinds: &BTreeMap<String, String>, msg: &Value) -> Vec<String> {
    let Some(m) = msg.get("method").and_then(Value::as_str) else { return vec![] };
    let mut names = vec![match kinds.get(m).map(String::as_str) {
        Some("notification") => format!("notify:{m}"),
        Some(_) => format!("method:{m}"),
        // Not in the registry: the notification form if it has no id, so the report names it.
        None if msg.get("id").is_none() => format!("notify:{m}"),
        None => format!("method:{m}"),
    }];
    let params = &msg["params"];
    if let Some(meta) = params.pointer("/_meta/acpmux").and_then(Value::as_object) {
        names.extend(meta.keys().map(|k| format!("field:_meta.acpmux#{k}")));
    }
    if let Some(obj) = params.as_object() {
        let ir = acpmux::protocol::ir();
        let types = ir["types"].as_object().unwrap();
        let entry = ir["methods"].as_array().unwrap().iter().find(|e| e["name"] == m);
        if entry.and_then(|e| closed_keys(types, &e["params"])).is_some() {
            names.extend(obj.keys().filter(|k| *k != "_meta").map(|k| format!("param:{m}#{k}")));
        }
    }
    names
}

/// A raw JSON-RPC client of an in-process daemon: every line it got.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    answers: BTreeMap<i64, Value>,
    pushed: Vec<Value>,
}

impl Client {
    fn open(hub: Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(1024);
        let (out_tx, out_rx) = mpsc::channel(1 << 16);
        tokio::spawn(serve_connection(hub, in_rx, out_tx));
        Self { tx: in_tx, rx: out_rx, answers: BTreeMap::new(), pushed: Vec::new() }
    }

    async fn send(&self, id: i64, m: &str, params: Value) {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": m, "params": params});
        self.tx.send(format!("{line}\n")).await.unwrap();
    }

    /// Reads for at most `within`; false once nothing came.
    async fn read(&mut self, within: Duration) -> bool {
        let Ok(Some(line)) = tokio::time::timeout(within, self.rx.recv()).await else {
            return false;
        };
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("method").is_some() {
            self.pushed.push(v);
        } else if let Some(id) = v.get("id").and_then(Value::as_i64) {
            self.answers.insert(id, v);
        }
        true
    }

    async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(id, m, params).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !self.answers.contains_key(&id) {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(self.read(left).await, "no answer to {m}");
        }
        self.answers[&id].clone()
    }

    /// The person's proof, as the app gives it.
    async fn prove(&mut self, hub: &Hub, init: &Value) {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = self.call(2, method::MUX_PERSON_PROVE, json!({"proof": proof})).await;
        assert!(proved.get("error").is_none(), "{proved}");
    }
}

/// The `initialize` params of a client that knows `old`: each opt-in it knows, named.
fn hello_of(old: &OldPeer) -> Value {
    let mut meta = Map::new();
    for id in old.advertises() {
        if let Some(flag) = id.strip_prefix("client:") {
            meta.insert(flag.to_owned(), json!(true));
        }
    }
    json!({"protocolVersion": 1, "clientInfo": {"name": "old-client"}, "_meta": {"acpmux": meta}})
}

/// Requests an old client may not ask in this test as a text message: `_acpmux/shutdown` ends the
/// daemon under test, and `_acpmux/file_put_data` is only ever a binary frame's method
/// (`server/upload_frames.rs`), refused as text by every build that knows it.
const NOT_ASKED: &[&str] = &[method::MUX_SHUTDOWN, method::MUX_FILE_PUT_DATA];

/// One-sided names feat-cmux-next has today, each with the gap that makes it one-sided. The
/// non-strict tests pass over these; the `#[ignore]`d strict ones fail on them. Fix a gap, drop
/// its row.
const KNOWN_GAPS: &[(&str, &str)] = &[
    (
        "method:_acpmux/machine_routes",
        "served only in a hub-carrier build (server/chats.rs:124), yet ungated: a default build \
         answers -32601 to a name no capability says it lacks",
    ),
    ("method:_acpmux/machine_route_probe", "as _acpmux/machine_routes"),
    (
        "method:_acpmux/remote.pipe",
        "served only on a streamed transport (server/stream.rs:137), ungated: an in-process or \
         channel connection answers -32601",
    ),
    (
        "method:_acpmux/subagent_stop",
        "an agent passthrough: without a sessionId the catch-all answers -32601, not -32602 \
         (server/requests.rs:4156), though subagent-stop-v1 lists it",
    ),
    ("method:_acpmux/steer_withdraw", "an agent passthrough, as _acpmux/subagent_stop"),
    ("method:_acpmux/step_now", "an agent passthrough, as _acpmux/subagent_stop"),
    (
        "field:_meta.acpmux#personVerified",
        "stamped on a forwarded prompt (server/remote_guard.rs:418, :437) but not declared in \
         AcpmuxRequestMeta (protocol registry)",
    ),
];

/// `tap`'s one-sided messages, those of a [`KNOWN_GAPS`] name left out unless `strict`.
fn one_sided(tap: &Tap, head: &Manifest, old: &OldPeer, strict: bool) -> Vec<String> {
    tap.one_sided(head, old)
        .into_iter()
        .filter(|p| strict || !KNOWN_GAPS.iter().any(|(name, _)| p.contains(&format!(" {name}"))))
        .collect()
}

fn assert_lockstep(tap: &Tap, head: &Manifest, old: &OldPeer, strict: bool) {
    let problems = one_sided(tap, head, old, strict);
    assert!(
        problems.is_empty(),
        "{} one-sided message(s) between the new acpmux and an old peer:\n  {}",
        problems.len(),
        problems.join("\n  ")
    );
}

/// A -32601 that names why this connection may not ask (`(local socket only)`, `(a web
/// connection only)`): the method is known and scoped to another origin, not unknown.
fn scoped_refusal(m: &str, message: &str) -> bool {
    message
        .strip_prefix("Method not found: ")
        .and_then(|r| r.strip_prefix(m))
        .is_some_and(|r| r.starts_with(" ("))
}

/// A new daemon serving a client that knows `old`: it asks every request it knows, and the tap
/// holds what the daemon pushed it (Sent), what it asked (Received), and each request a -32601
/// refused that the daemon had said it serves (listed, or ungated), unless the refusal names
/// another origin ([`scoped_refusal`]).
async fn serve_old_client(head: &Manifest, old: &OldPeer, tap: &Tap) {
    let kinds = kinds();
    let hub = hub();
    let mut client = Client::open(hub.clone());
    let init = client.call(1, method::INITIALIZE, hello_of(old)).await;
    assert!(init.get("error").is_none(), "{init}");
    client.prove(&hub, &init).await;
    let listed: BTreeSet<String> = {
        let a = &init["result"]["_meta"]["acpmux"];
        let caps =
            a["capabilities"].as_array().unwrap().iter().map(|c| c.as_str().unwrap().to_owned());
        let features = a["features"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| format!("feature:{}", f.as_str().unwrap()));
        caps.chain(features).collect()
    };
    // A request the daemon may refuse this connection: every capability gating it is one this
    // reply did not list (`_acpmux/v2` without listStream on a local socket).
    let served = |name: &str| {
        let gates = head.gates(name);
        gates.is_empty() || gates.iter().any(|g| listed.contains(*g))
    };
    let mut asked = BTreeMap::new();
    let mut id = 100;
    for name in old.manifest().names() {
        let Some(m) = name.strip_prefix("method:") else { continue };
        if kinds.get(m).map(String::as_str) != Some("request")
            || NOT_ASKED.contains(&m)
            || m == method::INITIALIZE
        {
            continue;
        }
        tap.record(Dir::Received, name);
        client.send(id, m, json!({})).await;
        asked.insert(id, m.to_owned());
        id += 1;
    }
    // Every answer, bounded: a request that waits (`_acpmux/mail_wait`) never answers here,
    // and is not a refusal.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    while asked.keys().any(|id| !client.answers.contains_key(id))
        && tokio::time::Instant::now() < deadline
    {
        client.read(Duration::from_millis(200)).await;
    }
    while client.read(Duration::from_millis(300)).await {}
    for pushed in &client.pushed {
        for name in names_of(&kinds, pushed) {
            if name.starts_with("notify:") || name.starts_with("method:") {
                tap.record(Dir::Sent, name);
            }
        }
    }
    for (id, m) in &asked {
        let Some(answer) = client.answers.get(id) else { continue };
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
        if answer.pointer("/error/code").and_then(Value::as_i64) == Some(UNKNOWN_METHOD)
            && !scoped_refusal(m, message)
        {
            let name = format!("method:{m}");
            if served(&name) {
                // The daemon's own words travel with the refusal, so a red names its cause.
                eprintln!("{name} refused: {message}");
                tap.refused(Dir::Received, name);
            }
        }
    }
}

async fn old_client_run(old: OldPeer, strict: bool) {
    let _ = HERMETIC;
    let head = manifest();
    let tap = Tap::new();
    serve_old_client(&head, &old, &tap).await;
    assert_lockstep(&tap, &head, &old, strict);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_daemon_serves_an_old_client() {
    old_client_run(base(), false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "gap: KNOWN_GAPS (ungated names a default build or a channel connection refuses)"]
async fn a_new_daemon_serves_an_old_client_strict() {
    old_client_run(base(), true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_daemon_serves_the_oldest_client() {
    old_client_run(oldest_peer(), false).await;
}

// ---------------------------------------------------------------------------------------------
// The peer link dialing an old daemon.

/// A daemon that knows only `old`: `initialize` lists its capabilities and features, a request
/// it knows gets a plain answer, any other a -32601. Every name the link sent is in `tap` (Sent).
async fn old_daemon(old: OldPeer, tap: Arc<Tap>) -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let kinds = kinds();
    let old = Arc::new(old);
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let (old, tap, kinds) = (old.clone(), tap.clone(), kinds.clone());
            tokio::spawn(async move {
                let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { return };
                while let Some(Ok(frame)) = ws.next().await {
                    let Frame::Text(text) = frame else { continue };
                    let Ok(msg) = serde_json::from_str::<Value>(&text) else { continue };
                    let Some(m) = msg.get("method").and_then(Value::as_str) else { continue };
                    let names = names_of(&kinds, &msg);
                    for name in &names {
                        tap.record(Dir::Sent, name.clone());
                    }
                    let known = old.knows(&names[0]);
                    if !known {
                        tap.refused(Dir::Sent, names[0].clone());
                    }
                    let Some(id) = msg.get("id").cloned() else { continue };
                    let reply = if !known {
                        json!({"jsonrpc": "2.0", "id": id, "error": {"code": UNKNOWN_METHOD, "message": format!("unknown method {m}")}})
                    } else {
                        json!({"jsonrpc": "2.0", "id": id, "result": answer(&old, m)})
                    };
                    if ws.send(Frame::Text(reply.to_string().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

/// The old daemon's answer to `m`, a request it knows.
fn answer(old: &OldPeer, m: &str) -> Value {
    let row = json!({"sessionId": "lane", "name": "lane", "updatedAt": 5, "cwd": "/tmp"});
    match m {
        method::INITIALIZE => {
            let listed = old.advertises();
            let features: Vec<&str> =
                listed.iter().filter_map(|id| id.strip_prefix("feature:")).collect();
            let capabilities: Vec<&str> =
                listed.iter().copied().filter(|id| !id.contains(':')).collect();
            json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "acpmux", "title": "acpmux", "version": "0.0.0-old"},
                "agentCapabilities": {"loadSession": true},
                "authMethods": [],
                "_meta": {"acpmux": {"version": "0.0.0-old", "origin": "peer", "auth": "peer",
                    "capabilities": capabilities, "features": features}}
            })
        }
        method::MUX_WATCH | method::MUX_SESSIONS => json!({"sessions": [row]}),
        method::SESSION_PROMPT => json!({"stopReason": "end_turn"}),
        _ => json!({}),
    }
}

/// A new daemon whose peer link dials a daemon that knows only `old`, and a person's client on it
/// that drives the link: its list, a forwarded prompt, a file put, an info, a stop if idle.
async fn dial_old_daemon(old: OldPeer) -> Arc<Tap> {
    let tap = Arc::new(Tap::new());
    let port = old_daemon(old, tap.clone()).await;
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    tokio::time::timeout(Duration::from_secs(20), a.add_peer("old", &url, None, None, true))
        .await
        .expect("the link connects in time")
        .expect("the link connects");
    let mut c = Client::open(a.clone());
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(1, method::INITIALIZE, hello).await;
    c.prove(&a, &init).await;
    let s = "old/lane";
    let drive: &[(&str, Value)] = &[
        (method::MUX_STATUS, json!({})),
        (method::MUX_SESSIONS, json!({})),
        (method::MUX_INFO, json!({"sessionId": s})),
        (
            method::SESSION_PROMPT,
            json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}),
        ),
        (method::MUX_FILE_PUT, json!({"sessionId": s, "name": "a.txt", "data": "aGk="})),
        (method::MUX_KILL, json!({"sessionId": s, "ifIdle": true})),
    ];
    for (i, (m, params)) in drive.iter().enumerate() {
        let _ =
            tokio::time::timeout(Duration::from_secs(5), c.call(10 + i as i64, m, params.clone()))
                .await;
    }
    while c.read(Duration::from_millis(300)).await {}
    tap
}

async fn old_daemon_run(old: OldPeer, strict: bool) {
    let _ = HERMETIC;
    let head = manifest();
    let tap = tokio::time::timeout(Duration::from_secs(30), dial_old_daemon(old.clone()))
        .await
        .expect("under 30 s");
    assert_lockstep(&tap, &head, &old, strict);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_peer_link_dials_an_old_daemon() {
    old_daemon_run(base(), false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "gap: the link stamps _meta.acpmux.personVerified, which the registry never declares"]
async fn a_new_peer_link_dials_an_old_daemon_strict() {
    old_daemon_run(base(), true).await;
}

/// GAP: `_acpmux/info` predates every capability but is listed only under `info-rows-v1`
/// (capabilities.rs), whose change is the `sessionIds` form; acpmux-v1 does not list it. The link
/// forwards it to any peer (server/peer_forward.rs `forward_inner`) without a feature check.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "gap: _acpmux/info is gated only by info-rows-v1 yet forwarded to every peer"]
async fn a_new_peer_link_dials_the_oldest_daemon() {
    old_daemon_run(oldest_peer(), false).await;
}

// ---------------------------------------------------------------------------------------------
// The feature table is the reply's list.

/// `peer::PEER_FEATURES` holds exactly what `initialize` lists: a feature a new daemon lists
/// without a row would gate nothing in the manifest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_feature_table_is_what_initialize_lists() {
    let _ = HERMETIC;
    let mut c = Client::open(hub());
    let init = c.call(1, method::INITIALIZE, json!({"protocolVersion": 1})).await;
    let listed: BTreeSet<&str> = init["result"]["_meta"]["acpmux"]["features"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f.as_str().unwrap())
        .collect();
    let table: BTreeSet<&str> = acpmux::peer::PEER_FEATURES.iter().map(|f| f.id).collect();
    assert_eq!(table.len(), acpmux::peer::PEER_FEATURES.len(), "a feature twice in the table");
    let unlisted: Vec<_> = listed.difference(&table).collect();
    assert!(
        unlisted.is_empty(),
        "initialize lists features with no PEER_FEATURES row: {unlisted:?}"
    );
    // Listed only on some connections (a peer link's list stream, controls, the hub rows).
    let conditional: BTreeSet<&str> =
        ["listStream", "listPages", "linkControls", "listHubRows"].into();
    let missing: Vec<_> =
        table.difference(&listed).filter(|f| !conditional.contains(**f)).collect();
    assert!(missing.is_empty(), "PEER_FEATURES rows initialize never lists: {missing:?}");
}
