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
    // An iPhone viewer: the app's while it is attached; with no app, the daemon's (cmux.rd/1)
    // under the gate a Mac viewer gets.
    assert_eq!(route::route(&view, Some("ios"), true, none), Route::App);
    assert_eq!(route::route(&view, Some("ios"), false, granted), Route::Daemon { view_only: true });
    assert_eq!(
        route::route(&full, Some("ios"), false, granted),
        Route::Daemon { view_only: false }
    );
    assert_eq!(route::route(&full, Some("ios"), false, OPEN), Route::Daemon { view_only: false });
    assert_eq!(
        route::route(&view, Some("ios"), false, screen_only),
        Route::Daemon { view_only: true }
    );
    assert_eq!(route::route(&full, Some("ios"), false, screen_only), Route::End("failed"));
    assert_eq!(route::route(&view, Some("ios"), false, none), Route::End("failed"));
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
    // A closed app channel is no app: the daemon serves the iPhone itself (the Mac's app
    // closed, cmuxterm-hq#18912), under the consent and own-account rules a Mac viewer gets.
    drop(rx);
    assert!(!shared.app_attached());
    assert_eq!(link::decide_for_tests(&shared, &phone, OPEN), ("daemon", Some(false)));
    let none = Consent { enabled: true, required: true, screen: false, control: false };
    let phone_view = ticket_push("s3", "view", "phone", "KEY", "wss://hub.example/s");
    assert_eq!(link::decide_for_tests(&shared, &phone_view, none), ("screen", None));
    let mut owned = phone.clone();
    owned["ownerKind"] = json!("user");
    assert_eq!(link::decide_for_tests(&shared, &owned, none), ("daemon", Some(false)));
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
    // The hub's own-account ticket serves with no consent (Leo, 2026-11-16, ask-da398bba67);
    // any other owner, or none (an older hub), still asks.
    let owned = |push: &Value, kind: &str| {
        let mut push = push.clone();
        push["ownerKind"] = json!(kind);
        push
    };
    assert_eq!(
        link::decide_for_tests(&shared, &owned(&full, "user"), none),
        ("daemon", Some(false))
    );
    assert_eq!(
        link::decide_for_tests(&shared, &owned(&view, "user"), none),
        ("daemon", Some(true))
    );
    assert_eq!(link::decide_for_tests(&shared, &owned(&view, "team"), none), ("screen", None));
    assert_eq!(link::decide_for_tests(&shared, &owned(&full, "shared"), screen), ("control", None));
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

/// The table cmux-rd picks a join's hub from is cmux-cloud-environment's deployments, row for
/// row: a deployment added there and not in `cmux_hub_host::deployment` fails here.
#[test]
fn the_shared_device_hub_table_is_the_cloud_environments() {
    use cmux_cloud_environment as env;
    let deployments = [
        env::PRODUCTION_DEPLOYMENT,
        env::STAGING_DEPLOYMENT,
        env::DEVELOPMENT_DEPLOYMENT,
        env::LOCAL_DEPLOYMENT,
    ];
    let mut want: Vec<(&str, &str)> =
        deployments.iter().map(|d| (d.platform_origin, d.device_hub_origin)).collect();
    let mut have = cmux_hub_host::deployment::DEVICE_HUBS.to_vec();
    want.sort();
    have.sort();
    assert_eq!(have, want);
}

/// A fake helper bundle `<app>/Contents/Library/<name>`.
fn helper_bundle(app: &Path, name: &str) -> std::path::PathBuf {
    let bundle = app.join("Contents/Library").join(name);
    std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    std::fs::write(bundle.join("Contents/MacOS").join(helper::EXECUTABLE), b"#!/bin/sh\n").unwrap();
    bundle
}

#[test]
fn helpers_are_found_in_order_and_staged_at_the_fixed_path() {
    let root = tempfile::tempdir().unwrap();
    let own = root.path().join("cmux DEV.app");
    let nightly = root.path().join("cmux NIGHTLY.app");
    let own_helper = helper_bundle(&own, "cmux DEV Helper.app");
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
            "/Users/p/Library/Application Support/cmux-next/helper/com.cmuxterm.app.nightly.screen-sharing"
        )
    );
    // The old per-digest slot it removes once, and nothing above Application Support/cmux-next.
    let (legacy, stop) = helper::legacy_root(Path::new("/Users/p"), "x.screen-sharing");
    assert_eq!(
        legacy,
        Path::new(
            "/Users/p/Library/Application Support/cmux-next/screen-sharing/x.screen-sharing/daemon"
        )
    );
    assert_eq!(stop, Path::new("/Users/p/Library/Application Support/cmux-next"));
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
fn the_helpers_own_grant_reading_is_kept_with_the_item_it_is_listed_as() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    assert_eq!(helper::status_json(home.path())["permissions"], Value::Null, "not read yet");
    let macos = home.path().join("cmux NIGHTLY Screen Sharing.app/Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    let exe = macos.join(helper::EXECUTABLE);
    std::fs::write(
        &exe,
        b"#!/bin/sh\n[ \"$1\" = permissions ] || exit 2\necho '{\"screen_recording\":false,\"accessibility\":true}'\n",
    )
    .unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    helper::read_grants(home.path(), &exe);
    let kept = &helper::status_json(home.path())["permissions"];
    assert_eq!(kept["screen_recording"], false);
    assert_eq!(kept["accessibility"], true);
    assert_eq!(kept["listed_as"], "cmux NIGHTLY Screen Sharing");
    assert!(kept["at"].as_u64().is_some());

    // A helper too old to answer leaves the last reading.
    std::fs::write(&exe, b"#!/bin/sh\nexit 2\n").unwrap();
    helper::read_grants(home.path(), &exe);
    assert_eq!(helper::status_json(home.path())["permissions"]["screen_recording"], false);
    assert_eq!(helper::grants_record(&exe, "not json", 1), None);
    assert_eq!(helper::listed_as(Path::new("/opt/cmux-rd")), "cmux Computer Use");
}

#[test]
fn a_fresh_install_reads_the_helpers_grants_once_before_any_share() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let macos = home.path().join("cmux NIGHTLY Helper.app/Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    let exe = macos.join(helper::EXECUTABLE);
    std::fs::write(
        &exe,
        b"#!/bin/sh\n[ \"$1\" = permissions ] || exit 2\necho '{\"screen_recording\":true,\"accessibility\":true}'\n",
    )
    .unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut found = 0;
    helper::read_grants_once(home.path(), || {
        found += 1;
        Some(exe.clone())
    });
    assert_eq!(found, 1);
    let kept = &helper::status_json(home.path())["permissions"];
    assert_eq!(kept["screen_recording"], true, "the helper's grant, before any share: {kept}");
    assert_eq!(kept["listed_as"], "cmux NIGHTLY Helper");

    // Once per home: a second ask neither looks the helper up again nor reads it again.
    let other = tempfile::tempdir().unwrap();
    let mut looked = 0;
    helper::read_grants_once(other.path(), || {
        looked += 1;
        None
    });
    helper::read_grants_once(other.path(), || {
        looked += 1;
        None
    });
    assert_eq!(looked, 1);
    assert_eq!(helper::status_json(other.path())["permissions"], Value::Null);
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
    let (origin, ends, _) = fake_hub_with(viewer, false);
    (origin, ends)
}

/// The text frames the host sent on its signaling sockets.
type Sent = Arc<Mutex<Vec<String>>>;

/// [`fake_hub`], whose viewer (with `webrtc_first`, the iPhone's) offers WebRTC first and its
/// cmux.rd/1 offer only once the host answered that with a frame.
fn fake_hub_with(viewer: Arc<Device>, webrtc_first: bool) -> (String, Ends, Sent) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let ends: Ends = Arc::default();
    let sent: Sent = Arc::default();
    let (heard, told) = (ends.clone(), sent.clone());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let (viewer, heard, told) = (viewer.clone(), heard.clone(), told.clone());
            std::thread::spawn(move || answer_one(stream, &viewer, &heard, &told, webrtc_first));
        }
    });
    (origin, ends, sent)
}

/// One client text frame (masked, as the host's socket sends it), or None at the end.
fn read_client_text(reader: &mut impl Read) -> Option<String> {
    let mut head = [0_u8; 2];
    reader.read_exact(&mut head).ok()?;
    let mut len = u64::from(head[1] & 0x7f);
    if len == 126 {
        let mut ext = [0_u8; 2];
        reader.read_exact(&mut ext).ok()?;
        len = u64::from(u16::from_be_bytes(ext));
    } else if len == 127 {
        let mut ext = [0_u8; 8];
        reader.read_exact(&mut ext).ok()?;
        len = u64::from_be_bytes(ext);
    }
    let mut mask = [0_u8; 4];
    if head[1] & 0x80 != 0 {
        reader.read_exact(&mut mask).ok()?;
    }
    let mut payload = vec![0_u8; usize::try_from(len).ok()?];
    reader.read_exact(&mut payload).ok()?;
    for (i, byte) in payload.iter_mut().enumerate() {
        *byte ^= mask[i % 4];
    }
    (head[0] & 0x0f == 1)
        .then(|| String::from_utf8_lossy(&payload).into_owned())
        .or(Some(String::new()))
}

fn server_text(out: &mut impl Write, value: &Value) {
    let payload = value.to_string().into_bytes();
    let mut frame = vec![0x81_u8, 126];
    frame.extend_from_slice(&u16::try_from(payload.len()).unwrap().to_be_bytes());
    frame.extend_from_slice(&payload);
    out.write_all(&frame).unwrap();
}

fn signed_offer(viewer: &Device, sid: &str, sdp: &str) -> Value {
    let fingerprint = rd_doc::fingerprint_of(sdp).unwrap();
    let signature = viewer
        .signer()
        .unwrap()
        .sign(&rd_doc::fingerprint_message(sid, "viewer", &fingerprint))
        .unwrap();
    json!({"type": "offer", "sdp": sdp, "fpSig": b64::encode(&signature)})
}

fn answer_one(
    stream: std::net::TcpStream,
    viewer: &Device,
    ends: &Ends,
    sent: &Sent,
    webrtc_first: bool,
) {
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
        if webrtc_first {
            // The iPhone's WebRTC offer; its cmux.rd/1 offer follows the host's transport frame.
            let webrtc = "v=0\r\na=fingerprint:sha-256 AB:CD\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n";
            server_text(&mut out, &signed_offer(viewer, sid, webrtc));
            loop {
                let Some(text) = read_client_text(&mut reader) else { return };
                sent.lock().unwrap().push(text.clone());
                if text.contains(r#""type":"transport""#) {
                    break;
                }
            }
        }
        let sdp = RdDocument { key: "ab".repeat(32), ..RdDocument::default() }.text();
        server_text(&mut out, &signed_offer(viewer, sid, &sdp));
        // Only listens from here; the share ends on its own.
        while let Some(text) = read_client_text(&mut reader) {
            sent.lock().unwrap().push(text);
        }
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
    // The hub hears why, so the viewer's card can say it (never only "failed").
    let told = "failed: the screen host stopped";
    assert_eq!(ended.tell_hub.as_deref(), Some(told));
    assert_eq!(*ends.lock().unwrap(), vec![("s-crash".to_owned(), told.to_owned())]);
    assert!(!dir.join("s-crash.json").exists());
    // The other share is untouched: still serving, its record still there.
    std::thread::sleep(Duration::from_millis(300));
    assert!(!live.is_finished());
    assert!(records::read(&dir, "s-live").is_some_and(|r| r.alive()));
    stop_live.store(true, Ordering::SeqCst);
    let ended = live.join().unwrap();
    // Stopped before a viewer connected: the reason says how far it got (the helper had the offer).
    assert_eq!(
        ended.reason,
        "stopped before the viewer connected: the screen host had not answered the viewer's offer"
    );
    assert_eq!(ended.tell_hub, None);
    assert_eq!(ends.lock().unwrap().len(), 1);
    assert!(!dir.join("s-live.json").exists());
}

#[test]
fn a_viewer_that_offers_webrtc_hears_the_transport_and_is_served_on_its_rd_offer() {
    // The iPhone with the Mac's app closed (cmuxterm-hq#18912): the daemon serves it over
    // cmux.rd/1, so its WebRTC offer is answered with the transport frame, not `bye`.
    let viewer = Arc::new(Device::generate("iPhone").unwrap());
    let viewer_key = viewer.signer().unwrap().public_key();
    let (origin, ends, sent) = fake_hub_with(viewer, true);
    let signal = format!("{}/v1/sessions/s-phone/ws", origin.replace("http://", "ws://"));
    let home = tempfile::tempdir().unwrap();
    let dir = records::dir(home.path());
    let hub = Hub::with_renewal(
        &origin,
        Device::generate("Mac").unwrap(),
        None,
        Renewal::Machine { credential: "cmm_test".into() },
    )
    .unwrap();
    let ticket =
        Ticket::from_push(&ticket_push("s-phone", "full", "phone", &viewer_key, &signal)).unwrap();
    let setup = home.path().join("setup.json");
    let mut command = session::serve_command("/bin/sh".into());
    command.args = vec![
        "-c".into(),
        format!("read -r line; echo \"$line\" > '{}'; cat >/dev/null", setup.display()),
    ];
    let stop = Arc::new(AtomicBool::new(false));
    let (flag, records_dir) = (stop.clone(), dir.clone());
    let thread = std::thread::spawn(move || {
        session::serve_one(&hub, &ticket, false, &command, &flag, &records_dir)
    });
    // The helper starts on the cmux.rd/1 offer that followed the frame, in control.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !setup.is_file() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let line: Value = serde_json::from_str(&std::fs::read_to_string(&setup).unwrap()).unwrap();
    assert_eq!(line["scope"], "control", "{line}");
    let told = sent.lock().unwrap().clone();
    assert!(told.iter().any(|t| t == cmux_hub_host::session::TRANSPORT_FRAME), "{told:?}");
    assert!(!told.iter().any(|t| t.contains(r#""type":"bye""#)), "{told:?}");
    stop.store(true, Ordering::SeqCst);
    let ended = thread.join().unwrap();
    assert!(ended.reason.starts_with("stopped"), "{}", ended.reason);
    assert!(ends.lock().unwrap().is_empty());
}

#[test]
fn a_share_with_no_helper_tells_the_hub_which_check_refused_it() {
    let home = Path::new("/Users/someone");
    let why = "app (/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app): \
               signature: /Users/someone/Library/x.app: code failed to satisfy specified code requirement(s)";
    let text = session::no_helper_reason(why, Some(home));
    assert!(text.starts_with("no Screen Sharing helper: app (/Applications/cmux NIGHTLY.app"));
    assert!(text.contains("~/Library/x.app"), "{text}");
    assert!(!text.contains("someone"), "{text}");
    assert_eq!(session::no_helper_reason("none", None), "no Screen Sharing helper: none");
    // What the hub gets is the `failed:` form the viewer's card reads, within its limit.
    let told = cmux_hub_host::session::failed_reason(&text);
    assert!(told.starts_with("failed: no Screen Sharing helper: "));
    assert!(told.encode_utf16().count() <= cmux_hub_host::session::HUB_REASON_MAX);
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
    assert!(linux::identity_of(&rd).is_some());
    let acpmux_home = dir.path().join("acpmux-home");
    let env = [("XDG_RUNTIME_DIR", std::ffi::OsString::from("/run/user/4242"))];
    let args = linux::enable_args("https://hub.example");
    let got = linux::run_enable(
        &rd,
        &args,
        &acpmux_home,
        &env,
        &[],
        Duration::from_secs(30),
        &AtomicBool::new(false),
    );
    assert_eq!(got, Outcome::SetUp("This desktop is shared as \"box\" (dev1), view only.".into()));
    let recorded = std::fs::read_to_string(dir.path().join("args")).unwrap();
    assert_eq!(recorded.lines().collect::<Vec<_>>(), args);
    let home = std::fs::read_to_string(dir.path().join("home")).unwrap();
    assert_eq!(home.trim_end(), acpmux_home.to_str().unwrap());
    // An exit with an error is a failure with its last line.
    let rd = fake_cmux_rd(dir.path(), "echo 'cmux-rd: no user manager' >&2; exit 3");
    assert_eq!(
        linux::run_enable(
            &rd,
            &args,
            &acpmux_home,
            &[],
            &[],
            Duration::from_secs(30),
            &AtomicBool::new(false)
        ),
        Outcome::Failed("cmux-rd: no user manager".into())
    );
    // A binary that is not there.
    let missing = dir.path().join("nothing");
    assert!(linux::identity_of(&missing).is_none());
    assert_eq!(
        linux::run_enable(
            &missing,
            &args,
            &acpmux_home,
            &[],
            &[],
            Duration::from_secs(30),
            &AtomicBool::new(false)
        )
        .state(),
        "enable_failed"
    );
}

/// The join puts cmux's own virtual display in the user environment (DISPLAY=:99); a cmux-rd
/// before 0.2.8 read it as a desktop and installed a host unit that never starts. The enable runs
/// without it, so the next daemon start heals that host; a real desktop's DISPLAY stays.
#[test]
fn the_enable_runs_without_the_virtual_display_cmux_owns() {
    use super::linux;
    let dir = tempfile::tempdir().unwrap();
    let units = dir.path().join("systemd/user");
    std::fs::create_dir_all(&units).unwrap();
    assert_eq!(linux::own_virtual_display(dir.path()), None);
    std::fs::write(
        units.join("cmux-screen-display.service"),
        "[Service]\nExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp\n",
    )
    .unwrap();
    let own = linux::own_virtual_display(dir.path());
    assert_eq!(own, Some(99));
    let os = |s: &str| std::ffi::OsString::from(s);
    assert_eq!(linux::enable_unset(Some(&os(":99")), own), ["DISPLAY"]);
    assert_eq!(linux::enable_unset(Some(&os(":99.0")), own), ["DISPLAY"]);
    assert_eq!(linux::enable_unset(Some(&os("unix:99")), own), ["DISPLAY"]);
    assert!(linux::enable_unset(Some(&os(":0")), own).is_empty());
    assert!(linux::enable_unset(Some(&os(":99")), None).is_empty());
    assert!(linux::enable_unset(None, own).is_empty());

    // The cmux-rd it runs does not see the unset DISPLAY.
    let rd = fake_cmux_rd(
        dir.path(),
        &format!("printf '%s\\n' \"${{DISPLAY-unset}}\" > '{}/display'", dir.path().display()),
    );
    // SAFETY: this test only sets a variable no other test in the crate reads.
    unsafe { std::env::set_var("DISPLAY", ":99") };
    let _ = linux::run_enable(
        &rd,
        &linux::enable_args("https://hub.example"),
        dir.path(),
        &[],
        &["DISPLAY"],
        Duration::from_secs(30),
        &AtomicBool::new(false),
    );
    let seen = std::fs::read_to_string(dir.path().join("display")).unwrap();
    assert_eq!(seen.trim_end(), "unset");
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
        &[],
        Duration::from_millis(500),
        &AtomicBool::new(false),
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

/// Review F2 of #45369: a leave or a daemon restart mid-setup must not let the old enable go on
/// and start the host. A cancelled enable is stopped at once, with everything it started.
#[test]
fn a_cancelled_enable_is_stopped_with_everything_it_started() {
    use super::linux::{self, Outcome};
    let dir = tempfile::tempdir().unwrap();
    let pid_file = dir.path().join("pid");
    let rd =
        fake_cmux_rd(dir.path(), &format!("sleep 60 &\necho $! > '{}'\nwait", pid_file.display()));
    let cancel = Arc::new(AtomicBool::new(false));
    let later = cancel.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        later.store(true, Ordering::SeqCst);
    });
    let started = Instant::now();
    let got = linux::run_enable(
        &rd,
        &linux::enable_args("https://hub.example"),
        dir.path(),
        &[],
        &[],
        Duration::from_secs(60),
        &cancel,
    );
    assert_eq!(got, Outcome::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let gone_by = Instant::now() + Duration::from_secs(10);
    // SAFETY: signal 0 only asks whether the test's own child's child still exists.
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < gone_by, "the enable's child {pid} still runs");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// After an enable: the join is recorded as set up only when it finished for the join that is
/// still current and nothing cancelled it; otherwise the unit it may have started is stopped.
#[test]
fn only_an_enable_for_the_current_join_keeps_its_host() {
    use super::linux::{self, After, Outcome};
    let set_up = Outcome::SetUp("This desktop is shared".into());
    let keep = After { save_mark: true, stop_host: false };
    let undo = After { save_mark: false, stop_host: true };
    assert_eq!(linux::after_enable(&set_up, false, true), keep);
    assert_eq!(linux::after_enable(&set_up, true, true), undo, "cancelled");
    assert_eq!(linux::after_enable(&set_up, false, false), undo, "the join changed");
    assert_eq!(linux::after_enable(&Outcome::Cancelled, true, true), undo);
    // Review of #45369: an enable that failed or timed out may have started the unit before it
    // ended, so for the current join too its host is stopped, never left running unmarked.
    let failed = Outcome::Failed("x".into());
    assert_eq!(linux::after_enable(&failed, false, true), undo, "failed");
    assert_eq!(linux::after_enable(&failed, false, false), undo);
    assert_eq!(linux::after_enable(&Outcome::TimedOut, false, true), undo, "timed out");
    let not_installed = Outcome::NotInstalled("not signed in".into());
    assert_eq!(linux::after_enable(&not_installed, false, true), undo, "not installed");
}

/// A stand-in cmux-rd identity.
fn rd_identity(size: u64, mtime: i64) -> super::linux::Identity {
    super::linux::Identity { size, mtime, mtime_nsec: 0, inode: 7 }
}

#[test]
fn the_host_is_set_up_once_per_join_and_cmux_rd_build() {
    use super::linux;
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("share-host");
    let record = |generation: u64, machine: &str| -> crate::machine_record::MachineCredential {
        serde_json::from_value(json!({"credential": "cmm_x", "machine_id": machine,
            "team_id": "t", "name": "n", "hub_origin": "https://h", "last_heartbeat": null,
            "revoked": false, "wgPublicKey": "k", "credential_generation": generation}))
        .unwrap()
    };
    let rd = rd_identity(1000, 1_700_000_000);
    let mark = linux::mark_of(&record(1, "m1"), &rd);
    assert!(!linux::marked(&folder, &mark));
    linux::save_mark(&folder, &mark).unwrap();
    assert!(linux::marked(&folder, &mark));
    // Another join (a new machine, a new credential) is set up again.
    assert!(!linux::marked(&folder, &linux::mark_of(&record(2, "m1"), &rd)));
    assert!(!linux::marked(&folder, &linux::mark_of(&record(1, "m2"), &rd)));
    // So is another cmux-rd build: another size, modification time (or its nanoseconds) or inode.
    for other in [
        rd_identity(1001, 1_700_000_000),
        rd_identity(1000, 1_700_000_001),
        linux::Identity { mtime_nsec: 5, ..rd },
        linux::Identity { inode: 8, ..rd },
    ] {
        assert!(!linux::marked(&folder, &linux::mark_of(&record(1, "m1"), &other)), "{other:?}");
    }
    // The mark never holds the credential.
    let text = std::fs::read_to_string(folder.join(linux::MARK)).unwrap();
    assert!(!text.contains("cmm_"), "{text}");
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap()["cmuxRd"],
        json!({"size": 1000, "mtime": 1_700_000_000, "mtimeNsec": 0, "inode": 7})
    );
    // A mark from before cmux-rd's identity was recorded (a machine joined before it) matches
    // no build: the next daemon start sets the host up once more.
    let old = json!({"machineId": "m1", "credentialGeneration": 1});
    linux::save_mark(&folder, &old).unwrap();
    assert!(linux::marked(&folder, &old));
    assert!(!linux::marked(&folder, &linux::mark_of(&record(1, "m1"), &rd)));
}

#[test]
fn cmux_rds_identity_changes_when_it_is_replaced() {
    use super::linux::identity_of;
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let rd = dir.path().join("cmux-rd");
    // Not there, or not runnable: not installed.
    assert_eq!(identity_of(&rd), None);
    std::fs::write(&rd, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(identity_of(&rd), None);
    std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o755)).unwrap();
    let first = identity_of(&rd).unwrap();
    assert_eq!(first.size, 10);
    // Looking again changes nothing.
    assert_eq!(identity_of(&rd), Some(first));
    // An install as the join line does it (a new file moved over the old one): a new identity.
    let new = dir.path().join(".cmux-rd.new");
    std::fs::write(&new, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&new, &rd).unwrap();
    let second = identity_of(&rd).unwrap();
    assert_ne!(second, first);
    // A symlink is followed to the binary it names.
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&rd, &link).unwrap();
    assert_eq!(identity_of(&link), Some(second));
    // A directory is not cmux-rd.
    assert_eq!(identity_of(dir.path()), None);
}

#[test]
fn the_watcher_tries_each_cmux_rd_build_once_per_daemon_run() {
    use super::linux::{Step, next_step};
    let a = rd_identity(1000, 1);
    let b = rd_identity(2000, 2);
    // Not installed, whatever was tried before.
    assert_eq!(next_step(None, None), Step::NotInstalled);
    assert_eq!(next_step(Some(&a), None), Step::NotInstalled);
    // A build not tried yet in this daemon run (none yet, a new one, one that came back after
    // another): the enable.
    assert_eq!(next_step(None, Some(a)), Step::Enable(a));
    assert_eq!(next_step(Some(&a), Some(b)), Step::Enable(b));
    assert_eq!(next_step(Some(&b), Some(a)), Step::Enable(a));
    // The build it tried, whether that enable worked or not: nothing, no loop.
    assert_eq!(next_step(Some(&a), Some(a)), Step::Wait);
    // Run the watcher's ticks over a timeline: one attempt per build.
    let timeline = [None, None, Some(a), Some(a), Some(a), Some(b), Some(b), None, Some(b)];
    let mut attempted = None;
    let mut enables = Vec::new();
    for now in timeline {
        if let Step::Enable(id) = next_step(attempted.as_ref(), now) {
            attempted = Some(id);
            enables.push(id);
        }
    }
    assert_eq!(enables, vec![a, b]);
    assert_eq!(super::linux::CHECK_EVERY, Duration::from_secs(60));
}

#[test]
fn a_missing_cmux_rd_says_why_the_join_could_not_install_it() {
    use super::linux::{INSTALL_FAILED, install_failure, not_installed_detail};
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("share-host");
    let rd = Path::new("/home/u/.local/bin/cmux-rd");
    // No file (no folder even): the plain line.
    assert_eq!(install_failure(&folder), None);
    assert_eq!(
        not_installed_detail(rd, &folder),
        "cmux-rd is not installed (/home/u/.local/bin/cmux-rd)"
    );
    std::fs::create_dir_all(&folder).unwrap();
    let file = folder.join(INSTALL_FAILED);
    assert_eq!(INSTALL_FAILED, "cmux-rd-install");
    // The join line's reason: its first line that says something.
    std::fs::write(&file, "\nchecksum verification failed for cmux-rd\nsecond line\n").unwrap();
    assert_eq!(
        not_installed_detail(rd, &folder),
        "cmux-rd is not installed (/home/u/.local/bin/cmux-rd): the join could not install it: \
         checksum verification failed for cmux-rd"
    );
    // Control characters never reach the status.
    std::fs::write(&file, "cannot \u{1b}[31mdownload\tcmux-rd\n").unwrap();
    assert_eq!(install_failure(&folder).unwrap(), "cannot [31mdownloadcmux-rd");
    // An oversized file: at most 1 KiB is read, and the line is cut short.
    std::fs::write(&file, "x".repeat(1 << 20)).unwrap();
    assert_eq!(install_failure(&folder).unwrap(), "x".repeat(300));
    // Only whitespace says nothing.
    std::fs::write(&file, " \n\n").unwrap();
    assert_eq!(install_failure(&folder), None);
    // Once the join line installs cmux-rd it removes the file: the plain line again.
    std::fs::remove_file(&file).unwrap();
    assert_eq!(install_failure(&folder), None);
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

/// A host unit that runs is left alone at the daemon's start only when cmux-rd's own record
/// says it signed in for this join: a person's sign-in that replaced it is set up over.
#[test]
fn a_running_unit_is_the_joins_only_when_cmux_rd_records_that_join() {
    use super::linux::rd_signed_in_for;
    let dir = std::env::temp_dir().join(format!("share-host-rd-joined-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    cmux_hub_host::identity::private_dir(&dir).unwrap();
    let mark = json!({"machineId": "m-b", "credentialGeneration": 2});
    let write = |machine_id: &str, generation: u64| {
        let record = json!({
            "acpmux_home": "/acpmux-home",
            "machine_id": machine_id,
            "credential_generation": generation,
        });
        cmux_hub_host::identity::write_private(
            &dir.join("joined.json"),
            record.to_string().as_bytes(),
        )
        .unwrap();
    };
    let home = std::path::Path::new("/acpmux-home");
    assert!(!rd_signed_in_for(&dir, &mark, home), "no record: a person's sign-in, or none");
    write("m-b", 2);
    assert!(rd_signed_in_for(&dir, &mark, home));
    write("m-b", 1);
    assert!(!rd_signed_in_for(&dir, &mark, home));
    write("m-a", 2);
    assert!(!rd_signed_in_for(&dir, &mark, home));
    // A cmux-rd from before joins were named in its record wrote only the acpmux home: that
    // home's join, never another's (hq docs/findings/2026-11-23-screen-host-restart-loop.md).
    let write_unnamed = |acpmux_home: &str| {
        cmux_hub_host::identity::write_private(
            &dir.join("joined.json"),
            json!({"acpmux_home": acpmux_home}).to_string().as_bytes(),
        )
        .unwrap();
    };
    write_unnamed("/acpmux-home");
    assert!(rd_signed_in_for(&dir, &mark, home), "an unnamed record of this home");
    write_unnamed("/another-home");
    assert!(!rd_signed_in_for(&dir, &mark, home), "an unnamed record of another home");
    write("", 0);
    assert!(rd_signed_in_for(&dir, &mark, home), "an empty machine id names no join");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `cmux remote-host share off` on a joined Mac turns the share host's own device off at the hub,
/// with no app; a machine with no share host keeps the caller's path; a joined Linux machine
/// names cmux-rd's switch; a failed hub call says why and what to do (design Z4).
#[test]
fn share_off_reaches_the_share_hosts_device_only_on_a_joined_mac() {
    use super::NotRunning;
    use super::cli::{OffHere, off_outcome};
    let joined = || -> Result<(), NotRunning> { Ok(()) };
    let not_joined = || -> Result<(), NotRunning> {
        Err(NotRunning::new("not_joined", "this machine is not joined"))
    };
    let hub_ok = || Ok::<_, NotRunning>("hub");
    let off = |hub: &&str| {
        assert_eq!(*hub, "hub");
        Ok(json!({"shared": false}))
    };
    let unreachable = |_: &&str| -> Result<Value, String> { panic!("no hub call expected") };

    assert_eq!(off_outcome(false, joined(), hub_ok, off), OffHere::Off(json!({"shared": false})));
    for linux in [false, true] {
        assert_eq!(off_outcome(linux, not_joined(), hub_ok, unreachable), OffHere::NoHost);
    }
    let OffHere::Failed(line) = off_outcome(true, joined(), hub_ok, unreachable) else {
        panic!("a joined Linux machine names cmux-rd's switch")
    };
    assert!(line.contains("cmux-rd linux-host share off"), "{line}");
    let unregistered = || Err::<&str, _>(NotRunning::new("not_registered", "no device yet"));
    assert_eq!(off_outcome(false, joined(), unregistered, unreachable), OffHere::NoHost);
    let unreadable = || Err::<&str, _>(NotRunning::new("identity_unreadable", "bad key"));
    let OffHere::Failed(line) = off_outcome(false, joined(), unreadable, unreachable) else {
        panic!("an unreadable device is a failure")
    };
    assert!(line.contains("bad key") && line.contains("Allow Mac Screen"), "{line}");
    let refused = |_: &&str| -> Result<Value, String> { Err("hub unreachable".to_owned()) };
    let OffHere::Failed(line) = off_outcome(false, joined(), hub_ok, refused) else {
        panic!("a failed hub call is a failure")
    };
    assert!(line.contains("hub unreachable") && line.contains("run it again"), "{line}");
}

/// What `peers` lists as `deviceHub` on a machine only the mesh hub reaches: the device hub's
/// record of its name (its first label, any case), or that there is none; nothing before the
/// list was read.
#[test]
fn the_device_hub_tells_a_mesh_host_s_screen_by_its_name() {
    let home = tempfile::tempdir().unwrap();
    let shared = shared(home.path());
    assert_eq!(shared.device_hub_of("lane-1"), None);
    let own = shared.hub().device.id.clone();
    shared.set_devices(&json!({"devices": [
        {"id": own, "name": "Mac", "platform": "macos", "macScreenShared": true},
        {"id": "d1", "name": "Lane-1.internal", "platform": "linux", "online": true,
         "macScreenShared": true},
        {"id": "d2", "name": "lane-2", "platform": "linux", "online": false},
        {"id": "d3", "name": "lane-2", "platform": "linux", "online": true,
         "macScreenShared": false},
    ]}));
    assert_eq!(
        shared.device_hub_of("lane-1"),
        Some(json!({"listed": true, "id": "d1", "platform": "linux", "online": true,
            "screenShared": true}))
    );
    assert_eq!(
        shared.device_hub_of("lane-2"),
        Some(json!({"listed": true, "id": "d3", "platform": "linux", "online": true,
            "screenShared": false}))
    );
    assert_eq!(shared.device_hub_of("lane-3"), Some(json!({"listed": false})));
    // Two equal records: the one seen last, as the app picks, not the one listed last.
    shared.set_devices(&json!({"devices": [
        {"id": "new", "name": "vm", "platform": "linux", "online": true, "macScreenShared": true,
         "lastSeenAt": 200.0},
        {"id": "old", "name": "vm", "platform": "linux", "online": true, "macScreenShared": true,
         "lastSeenAt": 100.0},
        {"id": "never", "name": "vm", "platform": "linux", "online": true, "macScreenShared": true},
    ]}));
    assert_eq!(shared.device_hub_of("vm").unwrap()["id"], "new");
    shared.set_devices(&json!({"devices": [
        {"id": own, "name": "Mac", "platform": "macos"},
    ]}));
    // This device's own record is never another machine's.
    assert_eq!(shared.device_hub_of("mac"), Some(json!({"listed": false})));
}

#[test]
fn a_join_made_while_the_daemon_runs_is_set_up_without_a_restart() {
    use super::NotRunning;
    use super::linux::{Step, Tick, tick};
    let rd = rd_identity(1000, 1);
    let not_joined = || Err(NotRunning::new("not_joined", "this machine is not joined"));
    let join = |generation: u64| -> Result<Value, NotRunning> {
        Ok(json!({"machineId": "m1", "credentialGeneration": generation}))
    };
    // The daemon started before the join (the bug: the watcher ended there), then a join, a
    // leave, and a join again, with cmux-rd installed all along.
    let timeline = [not_joined(), not_joined(), join(1), join(1), not_joined(), join(2), join(2)];
    let mut attempted = None;
    let mut seen = Vec::new();
    for read in timeline {
        match tick(read, Value::clone, &mut attempted, Some(rd)) {
            Tick::NotJoined(why) => {
                assert_eq!(why.code, "not_joined");
                assert_eq!(attempted, None, "a leave forgets what was tried");
                seen.push("not_joined".to_owned());
            }
            Tick::Joined(_, key, Step::Enable(id)) => {
                attempted = Some((id, key.clone()));
                seen.push(format!("enable {}", key["credentialGeneration"]));
            }
            Tick::Joined(_, _, step) => seen.push(format!("{step:?}")),
        }
    }
    assert_eq!(
        seen,
        ["not_joined", "not_joined", "enable 1", "Wait", "not_joined", "enable 2", "Wait"]
    );
    // A join while cmux-rd is not there yet says so, and its install is set up on its tick.
    let mut attempted = None;
    assert!(matches!(
        tick(join(3), Value::clone, &mut attempted, None),
        Tick::Joined(_, _, Step::NotInstalled)
    ));
    assert!(matches!(
        tick(join(3), Value::clone, &mut attempted, Some(rd)),
        Tick::Joined(_, _, Step::Enable(_))
    ));
    assert_eq!(super::JOIN_CHECK_EVERY, Duration::from_secs(60));
}

#[tokio::test]
async fn a_status_from_before_a_join_says_the_host_starts_and_wakes_the_check() {
    use super::state::{not_running_json, refreshed};
    use super::{NotRunning, joined_since, next_check};
    // Every join reason, read against a machine joined now: out of date.
    for state in super::JOIN_STATES {
        assert!(joined_since(state, false, || true), "{state}");
        assert!(!joined_since(state, false, || false), "{state}");
    }
    // A running host, or one stopped for another reason, never asks about the join.
    let asked = std::cell::Cell::new(false);
    let ask = || {
        asked.set(true);
        true
    };
    assert!(!joined_since("set_up", true, ask));
    assert!(!joined_since("not_installed", false, ask));
    assert!(!joined_since("enable_failed", false, ask));
    assert!(!asked.get());
    // The daemon's own not-joined status, unchanged while the machine is not joined.
    let why = NotRunning::new("not_joined", "this machine is not joined");
    let before = not_running_json(Some(&why), true);
    assert_eq!(refreshed(before.clone(), || false), before);
    // Joined since: it says the host starts, and the check is woken now, not in a minute.
    let after = refreshed(before, || true);
    assert_eq!(after["state"], "starting");
    assert_eq!(after["running"], false);
    assert!(after["detail"].as_str().unwrap().contains("joined since"));
    tokio::time::timeout(Duration::from_secs(5), next_check(Duration::from_secs(3600)))
        .await
        .expect("a recheck wakes the join check at once");
    // The Linux host's status says the same.
    let linux = super::linux::status_json("not_joined", "x", Path::new("/rd"), "");
    assert_eq!(refreshed(linux, || true)["state"], "starting");
}

#[test]
fn a_ping_without_a_pong_ends_the_link() {
    let s = Duration::from_secs;
    // No ping yet, or one just sent: the socket is fine.
    assert!(!link::pong_overdue(None, true));
    assert!(!link::pong_overdue(Some(s(3)), false));
    // Answered: fine however long ago the ping went out.
    assert!(!link::pong_overdue(Some(s(25)), true));
    // Unanswered past the bound: the socket is gone, reconnect.
    assert!(link::pong_overdue(Some(s(11)), false));
}

#[test]
fn a_watching_app_hears_each_time_the_daemon_comes_online_signed_in() {
    let home = tempfile::tempdir().unwrap();
    let hub = Hub::new("https://hub.example", Device::generate("Mac").unwrap(), Some("u".into()))
        .unwrap();
    let host = Shared::new(home.path().to_path_buf(), hub);
    assert_eq!(
        ask(&host, json!({"id": 1, "method": "device.watch"})),
        (json!({"id": 1, "ok": true, "result": {}}), After::Watch)
    );
    // Not online yet: nothing now, so an app that read no `user_id` waits for the event.
    let (early, mut early_lines) = tokio::sync::mpsc::unbounded_channel();
    host.watch(early);
    assert!(early_lines.try_recv().is_err());
    host.update_link(|link| link.state = "online");
    host.announce_online();
    let event: Value = serde_json::from_str(&early_lines.try_recv().unwrap()).unwrap();
    let id = host.hub().device.id.clone();
    assert_eq!(event, json!({"event": "online", "id": id, "user_id": "u"}));
    // Online already: a new watcher hears it at once.
    let (late, mut late_lines) = tokio::sync::mpsc::unbounded_channel();
    host.watch(late);
    assert_eq!(late_lines.try_recv().unwrap(), event.to_string());
    // A new device (the hub refused the old one) online again: every watcher hears its id.
    host.set_hub(
        Hub::new("https://hub.example", Device::generate("Mac").unwrap(), Some("u".into()))
            .unwrap(),
    );
    host.announce_online();
    let renewed: Value = serde_json::from_str(&early_lines.try_recv().unwrap()).unwrap();
    assert_ne!(renewed["id"], json!(id));
    assert_eq!(renewed["id"], json!(host.hub().device.id));
    assert_eq!(late_lines.try_recv().unwrap(), renewed.to_string());
    // Signed out of the hub or not online: no event.
    let unsigned = shared(home.path());
    unsigned.update_link(|link| link.state = "online");
    assert!(unsigned.online_event().is_none());
}

#[test]
fn a_stopped_link_offers_no_account_so_the_app_keeps_its_own_device() {
    let home = tempfile::tempdir().unwrap();
    let hub =
        Hub::new("https://hub.example", Device::generate("Mac").unwrap(), Some("user-1".into()))
            .unwrap();
    let shared = Shared::new(home.path().to_path_buf(), hub);
    let (signed_in, _) = ask(&shared, json!({"id": 1, "method": "device.identity"}));
    assert_eq!(signed_in["result"]["user_id"], "user-1");
    // The hub removed this device (socket close 4001): the link stops until the Mac joins again.
    shared.update_link(|link| link.state = "stopped");
    let (stopped, _) = ask(&shared, json!({"id": 2, "method": "device.identity"}));
    assert_eq!(stopped["ok"], true);
    assert!(stopped["result"].get("user_id").is_none());
}
