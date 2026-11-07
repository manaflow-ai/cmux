//! `usage-record` / `usage-set-enabled`: refused for every client but the
//! verified cmux app, and a batch lands in the usage folder only while it is on.

use super::*;
use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink};

fn temp_dir(name: &str) -> UsageDir {
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-usage-{name}-{}-{}",
        std::process::id(),
        cmux_usage::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    UsageDir::new(dir)
}

fn client(mux: &Arc<Mux>, transport: ClientTransport) -> u64 {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    mux.control_clients.register(transport, writer)
}

const BATCH: &str =
    r#"[{"at":5,"ev":{"t":"active","on":true}},{"at":6,"ev":{"t":"active","on":false}}]"#;

fn assert_refused(mux: &Arc<Mux>, client: u64) {
    let params = RecordParams { source: "app-dev".into(), events: BATCH.into() };
    let error = record(mux, client, &params).expect_err("refused");
    assert!(error.to_string().contains("verified cmux app"), "{error}");
    let error = set_enabled(mux, client, &SetEnabledParams { on: true }).expect_err("refused");
    assert!(error.to_string().contains("verified cmux app"), "{error}");
    let error = set_sharing(mux, client, &SetSharingParams { on: true }).expect_err("refused");
    assert!(error.to_string().contains("verified cmux app"), "{error}");
}

#[test]
fn usage_commands_refuse_a_remote_or_websocket_client() {
    let mux = Mux::new_for_test("usage-refuse", crate::SurfaceOptions::default());
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        assert_refused(&mux, client(&mux, transport));
    }
}

/// A plain local client (an agent in a pane, a script, the `cmux` CLI)
/// cannot switch recording on behind the setting and the per-Mac consent,
/// and neither can a role-main connection that never proved it is the app.
#[test]
fn usage_commands_refuse_a_local_client_that_is_not_the_verified_app() {
    let mux = Mux::new_for_test("usage-refuse-local", crate::SurfaceOptions::default());
    assert_refused(&mux, client(&mux, ClientTransport::Unix));

    let main = client(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, main, "main");
    set_peer_key_for_test(&mux, main, "token:100.1");
    assert_refused(&mux, main);

    // The verified app passes the gate (the folder write is covered below).
    set_verified_app_for_test(&mux, main, true);
    assert!(require_app(&mux, main).is_ok());
}

#[test]
fn a_batch_lands_only_while_recording_is_on() {
    let dir = temp_dir("record");
    assert_eq!(record_in(&dir, "app-dev", BATCH).expect("off")["written"], 0);
    assert!(dir.read(0).is_empty());

    let reply = set_enabled_in(&dir, true).expect("on");
    assert_eq!(reply["on"], true);
    assert_eq!(reply["dir"], dir.path().to_string_lossy().as_ref());
    assert_eq!(record_in(&dir, "app-dev", BATCH).expect("on")["written"], 2);
    let records = dir.read(0);
    assert_eq!(records.len(), 2);
    assert!(records.iter().all(|r| r.src == Source::App));
    assert!(dir.path().join("app-dev.jsonl").is_file());

    set_enabled_in(&dir, false).expect("off");
    assert_eq!(record_in(&dir, "app-dev", BATCH).expect("off again")["written"], 0);
    assert_eq!(dir.read(0).len(), 2);
    let _ = std::fs::remove_dir_all(dir.path());
}

#[test]
fn a_batch_with_an_unknown_field_is_refused_whole() {
    let dir = temp_dir("refuse");
    set_enabled_in(&dir, true).expect("on");
    let bad = r#"[{"at":5,"ev":{"t":"active","on":true}},{"at":6,"ev":{"t":"active","on":true},"url":"x"}]"#;
    let error = record_in(&dir, "app-dev", bad).expect_err("refused");
    assert!(error.to_string().starts_with("bad request"), "{error}");
    assert!(dir.read(0).is_empty());
    let _ = std::fs::remove_dir_all(dir.path());
}

#[test]
fn sharing_switches_only_while_recording_is_on() {
    let dir = temp_dir("share");
    let error = set_sharing_in(&dir, true).expect_err("recording off");
    assert!(error.to_string().contains("needs usage recording"), "{error}");
    assert!(!dir.is_sharing());

    set_enabled_in(&dir, true).expect("on");
    let reply = set_sharing_in(&dir, true).expect("share");
    assert_eq!(reply["on"], true);
    assert!(dir.is_sharing());
    // Recording off takes sharing with it.
    set_enabled_in(&dir, false).expect("off");
    assert!(!dir.is_sharing());
    assert_eq!(set_sharing_in(&dir, false).expect("off is always fine")["on"], false);
    let _ = std::fs::remove_dir_all(dir.path());
}
