//! The share host's routing, records, device channel, helper discovery and one share served
//! end to end against a loopback hub with fake helpers.

use super::channel::{self, After};
use super::records::{self, Record};
use super::route::{self, Consent, Route};
use super::state::Shared;
use super::{helper, link, session};
use cmux_hub_host::b64;
use cmux_hub_host::hub::{Hub, Renewal};
use cmux_hub_host::identity::Device;
use cmux_hub_host::rd_doc::{self, RdDocument};
use cmux_hub_host::session::Ticket;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn jws(payload: &Value) -> String {
    format!(
        "eyJhbGciOiJFUzI1NiJ9.{}.c2ln",
        b64::encode(payload.to_string().as_bytes())
            .trim_end_matches('=')
            .replace('+', "-")
            .replace('/', "_")
    )
}

/// A host ticket push for session `sid` from viewer device `viewer` (key `key`).
fn ticket_push(sid: &str, scope: &str, viewer: &str, key: &str, signal: &str) -> Value {
    json!({
        "type": "session.ticket", "sessionId": sid, "role": "host", "scope": scope,
        "ticket": jws(&json!({"sid": sid, "role": "host", "peerKey": key})),
        "signalURL": signal, "ice": [],
        "peer": {"id": viewer, "name": "Studio", "signingKey": key}
    })
}

fn ticket(scope: &str) -> Ticket {
    Ticket::from_push(&ticket_push("s1", scope, "v1", "KEY", "wss://hub.example/v1/sessions/s1/ws"))
        .unwrap()
}

fn shared(home: &Path) -> Arc<Shared> {
    let hub = Hub::new("https://hub.example", Device::generate("Mac").unwrap(), None).unwrap();
    Shared::new(home.to_path_buf(), hub)
}

const OPEN: Consent = Consent { enabled: false, required: true, screen: false, control: false };

#[test]
fn route_table() {
    let view = ticket("view");
    let full = ticket("full");
    let granted = Consent { enabled: true, required: true, screen: true, control: true };
    let screen_only = Consent { control: false, ..granted };
    let none = Consent { screen: false, control: false, ..granted };
    let not_joined = Consent { required: false, ..none };
    // An iPhone viewer: the app's while it is attached, else nobody's.
    assert_eq!(route::route(&view, Some("ios"), true, none), Route::App);
    assert_eq!(route::route(&view, Some("ios"), false, granted), Route::End("app_required"));
    // A Mac (or any other) viewer: the daemon's, under the app's gate.
    assert_eq!(
        route::route(&view, Some("macos"), true, granted),
        Route::Daemon { view_only: true }
    );
    assert_eq!(
        route::route(&full, Some("macos"), false, granted),
        Route::Daemon { view_only: false }
    );
    assert_eq!(route::route(&full, None, false, OPEN), Route::Daemon { view_only: false });
    assert_eq!(
        route::route(&view, Some("macos"), false, screen_only),
        Route::Daemon { view_only: true }
    );
    assert_eq!(route::route(&full, Some("macos"), false, screen_only), Route::End("failed"));
    assert_eq!(route::route(&view, Some("linux"), false, none), Route::End("failed"));
    // acpmux says this Mac is not joined: served as before.
    assert_eq!(
        route::route(&full, Some("macos"), false, not_joined),
        Route::Daemon { view_only: false }
    );
    assert_eq!(Route::App.served_by(), "app");
    assert_eq!(Route::End("failed").served_by(), "daemon");
}

#[test]
fn consent_reads_as_the_apps_gate() {
    let status =
        json!({"consentRequired": true, "consent": {"screen": "granted", "control": "none"}});
    let consent = Consent::from_status(true, &status);
    assert!(consent.allows(false));
    assert!(!consent.allows(true));
    assert_eq!(consent.missing(), "control");
    // No answer, or one that does not say otherwise, requires consent.
    let unknown = Consent::from_status(true, &Value::Null);
    assert!(unknown.required && !unknown.allows(false));
    assert_eq!(unknown.missing(), "screen");
    let free = Consent::from_status(true, &json!({"consentRequired": false}));
    assert!(free.allows(true));
    // The Labs switch off: everything, as the app serves.
    assert!(Consent::from_status(false, &Value::Null).allows(true));
}

#[test]
fn a_ticket_both_see_is_served_once_and_the_relay_says_by_whom() {
    let home = tempfile::tempdir().unwrap();
    let shared = shared(home.path());
    shared.set_devices(&json!({"devices": [
        {"id": "mac-viewer", "platform": "macos"},
        {"id": "phone", "platform": "ios"},
    ]}));
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    shared.subscribe(tx);
    assert!(shared.app_attached());
    // A Mac viewer: the daemon serves it, and the app's copy says so.
    let mac = ticket_push("s1", "view", "mac-viewer", "KEY", "wss://hub.example/s");
    assert_eq!(link::decide_for_tests(&shared, &mac, OPEN), ("daemon", Some(true)));
    let annotated: Value = serde_json::from_str(&route::annotate(&mac, "daemon")).unwrap();
    assert_eq!(annotated["servedBy"], "daemon");
    assert_eq!(annotated["sessionId"], "s1");
    // An iPhone viewer: the app serves it; the daemon only relays it.
    let phone = ticket_push("s2", "full", "phone", "KEY", "wss://hub.example/s");
    link::handle_push(&shared, &phone.to_string(), || OPEN);
    let line: Value = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
    assert_eq!(line["event"], "push");
    let relayed: Value = serde_json::from_str(line["text"].as_str().unwrap()).unwrap();
    assert_eq!(relayed["servedBy"], "app");
    assert_eq!(relayed["sessionId"], "s2");
    assert!(records::live(&records::dir(home.path()), Record::alive).is_empty());
    // Any other push reaches the app as it came.
    link::handle_push(&shared, r#"{"type":"relays.changed"}"#, || OPEN);
    let line: Value = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
    assert_eq!(line["text"], r#"{"type":"relays.changed"}"#);
    // A closed app channel is no app.
    drop(rx);
    assert!(!shared.app_attached());
    assert_eq!(link::decide_for_tests(&shared, &phone, OPEN), ("app_required", None));
}

#[test]
fn a_ticket_the_consent_refuses_is_ended_and_asks_for_what_is_missing() {
    let home = tempfile::tempdir().unwrap();
    let shared = shared(home.path());
    shared.set_devices(&json!({"devices": [{"id": "mac-viewer", "platform": "macos"}]}));
    let none = Consent { enabled: true, required: true, screen: false, control: false };
    let screen = Consent { screen: true, ..none };
    let view = ticket_push("s1", "view", "mac-viewer", "KEY", "wss://hub.example/s");
    let full = ticket_push("s1", "full", "mac-viewer", "KEY", "wss://hub.example/s");
    assert_eq!(link::decide_for_tests(&shared, &view, none), ("screen", None));
    assert_eq!(link::decide_for_tests(&shared, &full, screen), ("control", None));
    assert_eq!(link::decide_for_tests(&shared, &view, screen), ("daemon", Some(true)));
    // A ticket that does not agree with its JWS is ended too.
    let mut forged = view.clone();
    forged["sessionId"] = json!("s9");
    assert_eq!(link::decide_for_tests(&shared, &forged, OPEN), ("failed", None));
}

fn record(sid: &str, pid: u32, started_ms: u64) -> Record {
    Record {
        pid,
        started_ms,
        session_id: sid.into(),
        scope: "view".into(),
        viewer_id: "v1".into(),
        viewer_name: "Studio".into(),
    }
}

#[test]
fn session_records_are_written_adopted_and_stale_ones_removed() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let dir = records::dir(home.path());
    let me = Record::of_self(&ticket("view")).unwrap();
    assert!(me.alive());
    records::write(&dir, &me).unwrap();
    let mode = std::fs::metadata(dir.join("s1.json")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    assert_eq!(records::read(&dir, "s1"), Some(me.clone()));
    // A pid whose start time differs is another process: never adopted, never signalled.
    let stale = record("s2", std::process::id(), me.started_ms.saturating_add(1));
    assert!(!stale.alive());
    assert!(!stale.stop());
    records::write(&dir, &stale).unwrap();
    std::fs::write(dir.join("junk.json"), b"{").unwrap();
    assert_eq!(records::live(&dir, Record::alive), vec![me.clone()]);
    assert!(!dir.join("s2.json").exists());
    assert!(!dir.join("junk.json").exists());
    // A newer process serving the same session keeps its record when the old one exits.
    records::remove_if(&dir, "s1", me.pid.saturating_add(1));
    assert!(dir.join("s1.json").exists());
    records::remove_if(&dir, "s1", me.pid);
    assert!(!dir.join("s1.json").exists());
    // An id that is not one path segment is no record.
    assert!(records::write(&dir, &record("../x", 1, 1)).is_err());
    assert_eq!(records::read(&dir, "../x"), None);
}

/// An RNG for the test's sealing side, from ring's system randomness.
struct TestRng(ring::rand::SystemRandom);

impl hpke::rand_core::RngCore for TestRng {
    fn next_u32(&mut self) -> u32 {
        let mut b = [0; 4];
        self.fill_bytes(&mut b);
        u32::from_le_bytes(b)
    }
    fn next_u64(&mut self) -> u64 {
        let mut b = [0; 8];
        self.fill_bytes(&mut b);
        u64::from_le_bytes(b)
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        ring::rand::SecureRandom::fill(&self.0, dest).unwrap();
    }
}

impl hpke::rand_core::CryptoRng for TestRng {}

fn ask(shared: &Shared, request: Value) -> (Value, After) {
    channel::answer(shared, &request.to_string())
}

#[test]
fn the_device_channel_answers_as_the_worker_does() {
    let home = tempfile::tempdir().unwrap();
    let shared = shared(home.path());
    let (identity, after) = ask(&shared, json!({"id": 1, "method": "device.identity"}));
    assert_eq!(after, After::Nothing);
    assert_eq!(identity["id"], 1);
    assert_eq!(identity["ok"], true);
    let result = &identity["result"];
    assert_eq!(result["id"], json!(shared.hub().device.id));
    assert_eq!(b64::decode(result["signing_key"].as_str().unwrap()).unwrap().len(), 65);
    assert_eq!(b64::decode(result["agreement_key"].as_str().unwrap()).unwrap().len(), 65);
    // Not signed in yet: no account to compare.
    assert!(result.get("user_id").is_none());
    let (renewed, _) = ask(&shared, json!({"id": 2, "method": "device.renew"}));
    assert_eq!(renewed["result"], *result);

    // A signature verifies with the identity's signing key.
    let message = b"GET\n/v1/user/ws\n1\n";
    let (signed, _) = ask(
        &shared,
        json!({"id": 3, "method": "device.sign", "params": {"message": b64::encode(message)}}),
    );
    let signature = b64::decode(signed["result"]["signature"].as_str().unwrap()).unwrap();
    assert_eq!(signature.len(), 64);
    let key = result["signing_key"].as_str().unwrap();
    assert!(cmux_hub_host::hub::verify(key, message, &signature));
    assert!(!cmux_hub_host::hub::verify(key, b"other", &signature));

    // A relay secret sealed to the agreement key opens.
    use hpke::{Deserializable, Serializable};
    type Kem = hpke::kem::DhP256HkdfSha256;
    let public = b64::decode(result["agreement_key"].as_str().unwrap()).unwrap();
    let public = <Kem as hpke::Kem>::PublicKey::from_bytes(&public).unwrap();
    let info = b"cmux-device-hub relay v1 relay-1";
    let secret = br#"{"username":"u","credential":"c"}"#;
    let (encapsulated, ciphertext) =
        hpke::single_shot_seal::<hpke::aead::AesGcm256, hpke::kdf::HkdfSha256, Kem, _>(
            &hpke::OpModeS::Base,
            &public,
            info,
            secret,
            &[],
            &mut TestRng(ring::rand::SystemRandom::new()),
        )
        .unwrap();
    let open = |info: &[u8]| {
        ask(
            &shared,
            json!({"id": 4, "method": "device.open", "params": {
                "ciphertext": b64::encode(&ciphertext),
                "encapsulated_key": b64::encode(&encapsulated.to_bytes()),
                "info": b64::encode(info),
            }}),
        )
        .0
    };
    let opened = open(info);
    assert_eq!(b64::decode(opened["result"]["plaintext"].as_str().unwrap()).unwrap(), secret);
    let refused = open(b"cmux-device-hub relay v1 relay-2");
    assert_eq!(refused["ok"], false);
    assert!(refused["error"]["message"].as_str().is_some());

    // Subscribing, the app's settings, and what is refused.
    assert_eq!(ask(&shared, json!({"id": 5, "method": "hub.subscribe"})).1, After::Subscribe);
    let (mode, _) =
        ask(&shared, json!({"id": 6, "method": "host.mode", "params": {"mode": "relay-only"}}));
    assert_eq!(mode, json!({"id": 6, "ok": true, "result": {}}));
    assert_eq!(shared.app.lock().unwrap().host_mode, Some(json!("relay-only")));
    let (unknown, after) = ask(&shared, json!({"id": 7, "method": "device.delete"}));
    assert_eq!(after, After::Nothing);
    assert_eq!(unknown["ok"], false);
    assert!(unknown["error"]["message"].as_str().unwrap().contains("unknown method"));
    let (bad, _) =
        ask(&shared, json!({"id": 8, "method": "device.sign", "params": {"message": "%%"}}));
    assert_eq!(bad["ok"], false);
    let (garbage, _) = channel::answer(&shared, "not json");
    assert_eq!(garbage["ok"], false);
}

#[tokio::test]
async fn the_device_channel_serves_this_user_over_its_socket() {
    use futures::{SinkExt, StreamExt};
    let home = cmux_unix_socket::short_test_dir("share-host");
    let shared = shared(home.path());
    let path = home.path().join("share-host").join("device.sock");
    let server = tokio::spawn(channel::serve(shared.clone(), path.clone()));
    let started = Instant::now();
    while !path.exists() {
        assert!(started.elapsed() < Duration::from_secs(5), "the socket was never bound");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let stream = tokio::net::UnixStream::connect(&path).await.unwrap();
    let mut framed = tokio_util::codec::Framed::new(stream, tokio_util::codec::LinesCodec::new());
    let mut call = async |request: Value| {
        framed.send(request.to_string()).await.unwrap();
        let line = framed.next().await.unwrap().unwrap();
        serde_json::from_str::<Value>(&line).unwrap()
    };
    let answer = call(json!({"id": 1, "method": "hub.subscribe"})).await;
    assert_eq!(answer["ok"], true);
    let answer = call(json!({"id": 2, "method": "device.identity"})).await;
    assert_eq!(answer["result"]["id"], json!(shared.hub().device.id));
    assert!(shared.app_attached());
    shared.relay(r#"{"type":"devices.changed"}"#);
    let line = framed.next().await.unwrap().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap(),
        json!({"event": "push", "text": r#"{"type":"devices.changed"}"#})
    );
    drop(framed);
    let started = Instant::now();
    while shared.app_attached() {
        assert!(started.elapsed() < Duration::from_secs(5), "a closed channel stays attached");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    server.abort();
}

#[test]
fn the_status_names_the_host_its_device_and_its_shares() {
    let home = tempfile::tempdir().unwrap();
    let shared = shared(home.path());
    shared.update_link(|link| {
        link.state = "sign_in_failed";
        link.code = Some("account_not_on_hub".into());
    });
    let status = shared.status_json();
    assert_eq!(status["schema"], "acpmux.share-host.status/1");
    assert_eq!(status["running"], true);
    assert_eq!(status["state"], "sign_in_failed");
    assert_eq!(status["code"], "account_not_on_hub");
    assert_eq!(status["linkUp"], false);
    assert_eq!(status["deviceId"], json!(shared.hub().device.id));
    assert_eq!(status["deviceName"], "Mac");
    assert_eq!(status["sessions"], json!([]));
    assert_eq!(status["appAttached"], false);
    for key in ["hub", "userId", "sharing", "shareByJoin", "helper", "app"] {
        assert!(status.get(key).is_some(), "{key}");
    }
    let why = super::NotRunning::new("cloned", "copied");
    let off = super::state::not_running_json(Some(&why), true);
    assert_eq!(
        off,
        json!({"schema": "acpmux.share-host.status/1", "running": false,
                           "state": "cloned", "detail": "copied"})
    );
    assert_eq!(super::state::not_running_json(None, false)["state"], "unsupported");
}

#[test]
fn each_platform_deployment_has_its_own_device_hub() {
    use cmux_cloud_environment as env;
    assert_eq!(
        super::device_hub_origin(env::PRODUCTION_PLATFORM).as_deref(),
        Some(env::PRODUCTION_DEPLOYMENT.device_hub_origin)
    );
    assert_eq!(
        super::device_hub_origin(&format!("{}/", env::DEVELOPMENT_PLATFORM)).as_deref(),
        Some(env::DEVELOPMENT_DEPLOYMENT.device_hub_origin)
    );
    assert_eq!(super::device_hub_origin("https://cmux.example"), None);
}

/// A fake helper bundle `<app>/Contents/Library/<name>`.
fn helper_bundle(app: &Path, name: &str) -> std::path::PathBuf {
    let bundle = app.join("Contents/Library").join(name);
    std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    std::fs::write(bundle.join("Contents/MacOS").join(helper::EXECUTABLE), b"#!/bin/sh\n").unwrap();
    bundle
}

#[test]
fn helpers_are_found_in_order_and_staged_beside_the_apps_slot() {
    let root = tempfile::tempdir().unwrap();
    let own = root.path().join("cmux DEV.app");
    let nightly = root.path().join("cmux NIGHTLY.app");
    let own_helper = helper_bundle(&own, "cmux DEV Screen Sharing.app");
    let nightly_helper = helper_bundle(&nightly, "cmux NIGHTLY Screen Sharing.app");
    // Not a helper: another bundle in the same folder.
    std::fs::create_dir_all(nightly.join("Contents/Library/cmux Remote.app")).unwrap();
    let env = root.path().join("env Screen Sharing.app");
    let join = root.path().join("join/x.app/Contents/MacOS/cmux-screen-sharing");
    let found = helper::sources(
        Some(env.clone()),
        Some(join.clone()),
        &[own.clone(), nightly.clone(), own],
    );
    assert_eq!(
        found,
        vec![
            helper::Source::Env(env),
            helper::Source::Join(join),
            helper::Source::App(own_helper),
            helper::Source::App(nightly_helper),
        ]
    );
    assert_eq!(
        helper::staging_root(Path::new("/Users/p"), "com.cmuxterm.app.nightly.screen-sharing"),
        Path::new(
            "/Users/p/Library/Application Support/cmux-next/screen-sharing/com.cmuxterm.app.nightly.screen-sharing/daemon"
        )
    );
    assert_eq!(
        helper::app_of(Path::new("/Applications/cmux.app/Contents/Resources/bin/acpmux")),
        Some("/Applications/cmux.app".into())
    );
    assert!(helper::is_helper_bundle_id("com.cmuxterm.app.screen-sharing"));
    assert!(helper::is_helper_bundle_id("com.cmuxterm.app.nightly.screen-sharing"));
    assert!(!helper::is_helper_bundle_id("com.example.screen-sharing"));
    assert!(!helper::is_helper_bundle_id("com.cmuxterm.app.x/../y.screen-sharing"));
}

#[test]
fn the_joins_install_mark_and_status_are_read_from_its_files() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let join = home.path().join("screen-sharing");
    assert_eq!(helper::installed(home.path()), None);
    assert!(!helper::share_by_join_here(home.path()));
    assert_eq!(helper::status(home.path()), None);
    let app = join.join("com.cmuxterm.app.screen-sharing/cmux Screen Sharing.app");
    std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
    std::fs::write(app.join("Contents/MacOS/cmux-screen-sharing"), b"").unwrap();
    std::fs::write(join.join("helper.json"), json!({"app": app}).to_string()).unwrap();
    assert_eq!(
        helper::installed(home.path()),
        Some(app.join("Contents/MacOS/cmux-screen-sharing"))
    );
    let status = json!({"schema": "cmux.screen-share.status/1", "state": "granted"});
    std::fs::write(join.join("status.json"), status.to_string()).unwrap();
    assert_eq!(helper::status(home.path()), Some(status));
    std::fs::write(join.join("status.json"), r#"{"schema":"other"}"#).unwrap();
    assert_eq!(helper::status(home.path()), None);
    // A join by signing in here never asks the hub to share; any other join, or the mark, does.
    std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let credential = |joined_by: Option<&str>| {
        let path = home.path().join("machine-credential.json");
        let record = json!({"credential": "cmm_x", "machine_id": "m", "team_id": "t", "name": "n",
            "hub_origin": "https://h", "last_heartbeat": null, "revoked": false,
            "wgPublicKey": "k", "joined_by": joined_by});
        std::fs::write(&path, record.to_string()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    };
    credential(Some("sign-in"));
    assert!(!helper::share_by_join_here(home.path()));
    std::fs::write(join.join("joined-from-another-device"), b"").unwrap();
    assert!(helper::share_by_join_here(home.path()));
    std::fs::remove_file(join.join("joined-from-another-device")).unwrap();
    credential(None);
    assert!(helper::share_by_join_here(home.path()));
}

/// What the loopback hub heard: the `/end`s, by session.
type Ends = Arc<Mutex<Vec<(String, String)>>>;

/// A loopback device hub: the machine sign-in, `/end`, and each session's signaling socket,
/// which sends the viewer's signed cmux.rd/1 offer and then only listens.
fn fake_hub(viewer: Arc<Device>) -> (String, Ends) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let ends: Ends = Arc::default();
    let heard = ends.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let (viewer, heard) = (viewer.clone(), heard.clone());
            std::thread::spawn(move || answer_one(stream, &viewer, &heard));
        }
    });
    (origin, ends)
}

fn answer_one(stream: std::net::TcpStream, viewer: &Device, ends: &Ends) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let mut headers = Vec::new();
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).unwrap();
        let Some((k, v)) = header.trim_end().split_once(": ") else { break };
        headers.push((k.to_ascii_lowercase(), v.to_owned()));
    }
    let header = |name: &str| headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    let length: usize = header("content-length").map_or(0, |v| v.parse().unwrap());
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let target = line.split_whitespace().nth(1).unwrap_or_default().to_owned();
    let mut out = &stream;
    let reply = |out: &mut &std::net::TcpStream, value: Value| {
        let text = value.to_string();
        write!(out, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{text}", text.len()).unwrap();
    };
    let session = target.strip_prefix("/v1/sessions/").and_then(|rest| rest.split('/').next());
    if target.starts_with("/v1/auth/machine") {
        let expires = cmux_hub_host::hub::now_ms() + 3_600_000;
        reply(&mut out, json!({"session": "sess", "userId": "p:u", "expiresAt": expires}));
    } else if let (Some(sid), true) = (session, target.contains("/end")) {
        let reason: Value = serde_json::from_slice(&body).unwrap();
        ends.lock().unwrap().push((sid.to_owned(), reason["reason"].as_str().unwrap().to_owned()));
        reply(&mut out, json!({}));
    } else if let (Some(sid), true) = (session, target.contains("/ws?ticket=")) {
        let accept = cmux_hub_host::net::accept_key(&header("sec-websocket-key").unwrap());
        write!(out, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").unwrap();
        let sdp = RdDocument { key: "ab".repeat(32), ..RdDocument::default() }.text();
        let fingerprint = rd_doc::fingerprint_of(&sdp).unwrap();
        let signature = viewer
            .signer()
            .unwrap()
            .sign(&rd_doc::fingerprint_message(sid, "viewer", &fingerprint))
            .unwrap();
        let offer = json!({"type": "offer", "sdp": sdp, "fpSig": b64::encode(&signature)});
        let payload = offer.to_string().into_bytes();
        let mut frame = vec![0x81_u8, 126];
        frame.extend_from_slice(&u16::try_from(payload.len()).unwrap().to_be_bytes());
        frame.extend_from_slice(&payload);
        out.write_all(&frame).unwrap();
        // Only listens from here; the share ends on its own.
        let _ = std::io::copy(&mut reader, &mut std::io::sink());
    } else {
        let text = r#"{"error":{"code":"not_found","message":"no"}}"#;
        write!(out, "HTTP/1.1 404 Not Found\r\nContent-Length: {}\r\n\r\n{text}", text.len())
            .unwrap();
    }
}

#[test]
fn a_helper_that_exits_early_ends_only_its_own_share() {
    let viewer = Arc::new(Device::generate("Studio").unwrap());
    let viewer_key = viewer.signer().unwrap().public_key();
    let (origin, ends) = fake_hub(viewer);
    let signal = |sid: &str| format!("{}/v1/sessions/{sid}/ws", origin.replace("http://", "ws://"));
    let home = tempfile::tempdir().unwrap();
    let dir = records::dir(home.path());
    let host = Device::generate("Mac").unwrap();
    // Each share is its own process with its own hub client; these two run side by side.
    let start = |sid: &str, script: &str| {
        let hub = Hub::with_renewal(
            &origin,
            host.clone(),
            None,
            Renewal::Machine { credential: "cmm_test".into() },
        )
        .unwrap();
        let ticket =
            Ticket::from_push(&ticket_push(sid, "view", "v", &viewer_key, &signal(sid))).unwrap();
        let mut command = session::serve_command("/bin/sh".into());
        command.args = vec!["-c".into(), script.into()];
        let stop = Arc::new(AtomicBool::new(false));
        let (flag, dir) = (stop.clone(), dir.clone());
        let thread = std::thread::spawn(move || {
            session::serve_one(&hub, &ticket, true, &command, &flag, &dir)
        });
        (stop, thread)
    };
    // One helper exits after its setup line (a crash); the other serves until stopped.
    let (_, crashed) = start("s-crash", "read -r line; exit 3");
    let (stop_live, live) = start("s-live", "read -r line; cat >/dev/null");
    let ended = crashed.join().unwrap();
    assert_eq!(ended.reason, "the screen host stopped");
    assert_eq!(ended.tell_hub, Some("failed"));
    assert_eq!(*ends.lock().unwrap(), vec![("s-crash".to_owned(), "failed".to_owned())]);
    assert!(!dir.join("s-crash.json").exists());
    // The other share is untouched: still serving, its record still there.
    std::thread::sleep(Duration::from_millis(300));
    assert!(!live.is_finished());
    assert!(records::read(&dir, "s-live").is_some_and(|r| r.alive()));
    stop_live.store(true, Ordering::SeqCst);
    let ended = live.join().unwrap();
    assert_eq!(ended.reason, "stopped");
    assert_eq!(ended.tell_hub, None);
    assert_eq!(ends.lock().unwrap().len(), 1);
    assert!(!dir.join("s-live.json").exists());
}

// The Linux host (`share_host/linux.rs`): cmux-rd's, set up by the daemon with no step on the
// machine.

#[test]
fn cmux_rd_is_where_the_host_unit_runs_it() {
    use super::linux;
    let unit = include_str!("../../../cmux-rd-host/systemd/cmux-screen-host.service");
    let exec = unit.lines().find_map(|l| l.strip_prefix("ExecStart=")).unwrap();
    let path = exec.split_whitespace().next().unwrap();
    let home = Path::new("/home/someone");
    assert_eq!(linux::cmux_rd_path(home), home.join(path.strip_prefix("%h/").unwrap()));
    assert_eq!(linux::HOST_UNIT, "cmux-screen-host.service");
    assert!(unit.contains("linux-host run"));
}

#[test]
fn the_enable_is_the_joins_with_its_device_hub() {
    assert_eq!(
        super::linux::enable_args("https://cmux-device-hub-dev.debussy.workers.dev"),
        [
            "linux-host",
            "enable",
            "--non-interactive",
            "--hub",
            "https://cmux-device-hub-dev.debussy.workers.dev"
        ]
    );
}

#[test]
fn the_user_manager_env_is_filled_in_only_where_missing() {
    use super::linux::user_manager_env;
    use std::ffi::OsString;
    let all = |_: &Path| true;
    let none = |_: &Path| false;
    // A daemon started with no login session (`sudo -u`, a service): both, from /run/user/<uid>.
    assert_eq!(
        user_manager_env(1000, None, None, all),
        vec![
            ("XDG_RUNTIME_DIR", OsString::from("/run/user/1000")),
            ("DBUS_SESSION_BUS_ADDRESS", OsString::from("unix:path=/run/user/1000/bus")),
        ]
    );
    // An empty value counts as none.
    assert_eq!(user_manager_env(7, Some("".into()), Some("".into()), all).len(), 2);
    // The daemon's own are kept as they are.
    assert_eq!(
        user_manager_env(1000, Some("/run/user/1000".into()), Some("unix:path=/x".into()), all),
        vec![]
    );
    // Its own runtime directory, no bus: the bus beside it.
    assert_eq!(
        user_manager_env(1000, Some("/tmp/rt".into()), None, |p| p == Path::new("/tmp/rt/bus")),
        vec![("DBUS_SESSION_BUS_ADDRESS", OsString::from("unix:path=/tmp/rt/bus"))]
    );
    // No user manager here: nothing is made up.
    assert_eq!(user_manager_env(1000, None, None, none), vec![]);
    assert_eq!(
        user_manager_env(1000, None, None, |p| p == Path::new("/run/user/1000")),
        vec![("XDG_RUNTIME_DIR", OsString::from("/run/user/1000"))]
    );
}

#[test]
fn the_enables_output_says_how_it_went() {
    use super::linux::{Outcome, outcome};
    let shared = "OpenH264 is at /x\nThis desktop is shared as \"box\" (dev1), view and control; the host runs as cmux-screen-host.service. OpenH264 is at /x.\n";
    assert_eq!(
        outcome(true, shared, ""),
        Outcome::SetUp(
            "This desktop is shared as \"box\" (dev1), view and control; the host runs as cmux-screen-host.service. OpenH264 is at /x.".into()
        )
    );
    // cmux-rd exits 0 when it could not sign in, with one `not_installed:` line.
    let not = outcome(
        true,
        "not_installed: screen sharing is set up on this machine but not signed in\n",
        "",
    );
    assert_eq!(
        not,
        Outcome::NotInstalled("screen sharing is set up on this machine but not signed in".into())
    );
    assert_eq!(not.state(), "not_installed");
    let failed = outcome(false, "", "warn\ncmux-rd: systemctl --user daemon-reload: no bus\n\n");
    assert_eq!(failed, Outcome::Failed("cmux-rd: systemctl --user daemon-reload: no bus".into()));
    assert_eq!(failed.state(), "enable_failed");
    assert_eq!(outcome(false, "", "").state(), "enable_failed");
    assert_eq!(Outcome::TimedOut.state(), "timed_out");
    assert!(Outcome::TimedOut.detail().contains("180 s"));
    // Control characters never reach the log line.
    assert_eq!(
        outcome(true, "This desktop is shared\u{1b}[31m x\n", ""),
        Outcome::SetUp("This desktop is shared[31m x".into())
    );
}

/// A stand-in cmux-rd: writes its arguments and `ACPMUX_HOME` beside itself, then runs `body`.
fn fake_cmux_rd(dir: &Path, body: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let rd = dir.join("cmux-rd");
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{0}/args'\nprintf '%s\\n' \"$ACPMUX_HOME\" > '{0}/home'\n{body}\n",
        dir.display()
    );
    std::fs::write(&rd, script).unwrap();
    std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o755)).unwrap();
    rd
}

#[test]
fn the_enable_runs_cmux_rd_with_the_daemons_home() {
    use super::linux::{self, Outcome};
    let dir = tempfile::tempdir().unwrap();
    let rd =
        fake_cmux_rd(dir.path(), "echo 'This desktop is shared as \"box\" (dev1), view only.'");
    assert!(linux::executable(&rd));
    let acpmux_home = dir.path().join("acpmux-home");
    let env = [("XDG_RUNTIME_DIR", std::ffi::OsString::from("/run/user/4242"))];
    let args = linux::enable_args("https://hub.example");
    let got = linux::run_enable(&rd, &args, &acpmux_home, &env, Duration::from_secs(30));
    assert_eq!(got, Outcome::SetUp("This desktop is shared as \"box\" (dev1), view only.".into()));
    let recorded = std::fs::read_to_string(dir.path().join("args")).unwrap();
    assert_eq!(recorded.lines().collect::<Vec<_>>(), args);
    let home = std::fs::read_to_string(dir.path().join("home")).unwrap();
    assert_eq!(home.trim_end(), acpmux_home.to_str().unwrap());
    // An exit with an error is a failure with its last line.
    let rd = fake_cmux_rd(dir.path(), "echo 'cmux-rd: no user manager' >&2; exit 3");
    assert_eq!(
        linux::run_enable(&rd, &args, &acpmux_home, &[], Duration::from_secs(30)),
        Outcome::Failed("cmux-rd: no user manager".into())
    );
    // A binary that is not there.
    let missing = dir.path().join("nothing");
    assert!(!linux::executable(&missing));
    assert_eq!(
        linux::run_enable(&missing, &args, &acpmux_home, &[], Duration::from_secs(30)).state(),
        "enable_failed"
    );
}

#[test]
fn an_enable_past_its_wait_is_stopped_with_everything_it_started() {
    use super::linux::{self, Outcome};
    let dir = tempfile::tempdir().unwrap();
    let pid_file = dir.path().join("pid");
    let rd =
        fake_cmux_rd(dir.path(), &format!("sleep 60 &\necho $! > '{}'\nwait", pid_file.display()));
    let started = Instant::now();
    let got = linux::run_enable(
        &rd,
        &linux::enable_args("https://hub.example"),
        dir.path(),
        &[],
        Duration::from_millis(500),
    );
    assert_eq!(got, Outcome::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    // Its group is ended (SIGTERM, then SIGKILL after the grace): the sleep it left goes too.
    let gone_by = Instant::now() + Duration::from_secs(10);
    // SAFETY: signal 0 only asks whether the test's own child's child still exists.
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < gone_by, "the enable's child {pid} still runs");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn the_host_is_set_up_once_per_join() {
    use super::linux;
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("share-host");
    let record = |generation: u64, machine: &str| -> crate::machine_record::MachineCredential {
        serde_json::from_value(json!({"credential": "cmm_x", "machine_id": machine,
            "team_id": "t", "name": "n", "hub_origin": "https://h", "last_heartbeat": null,
            "revoked": false, "wgPublicKey": "k", "credential_generation": generation}))
        .unwrap()
    };
    let mark = linux::mark_of(&record(1, "m1"));
    assert!(!linux::marked(&folder, &mark));
    linux::save_mark(&folder, &mark).unwrap();
    assert!(linux::marked(&folder, &mark));
    // Another join (a new machine, a new credential) is set up again.
    assert!(!linux::marked(&folder, &linux::mark_of(&record(2, "m1"))));
    assert!(!linux::marked(&folder, &linux::mark_of(&record(1, "m2"))));
    // The mark never holds the credential.
    let text = std::fs::read_to_string(folder.join(linux::MARK)).unwrap();
    assert!(!text.contains("cmm_"), "{text}");
}

#[test]
fn the_linux_status_says_whether_cmux_rds_host_is_set_up() {
    use super::linux::status_json;
    let rd = Path::new("/home/u/.local/bin/cmux-rd");
    for (state, running) in [
        ("setting_up", false),
        ("set_up", true),
        ("already_set_up", true),
        ("not_installed", false),
        ("enable_failed", false),
        ("timed_out", false),
    ] {
        let status = status_json(state, "d", rd, "https://hub.example");
        assert_eq!(status["schema"], "acpmux.share-host.status/1");
        assert_eq!(status["running"], running, "{state}");
        assert_eq!(status["state"], state);
        assert_eq!(status["host"], "cmux-rd");
        assert_eq!(status["cmuxRd"], "/home/u/.local/bin/cmux-rd");
        assert_eq!(status["unit"], "cmux-screen-host.service");
    }
    // A Linux daemon is a share host's system: a host it did not start is not "unsupported".
    assert_eq!(super::state::not_running_json(None, true)["state"], "not_started");
}
