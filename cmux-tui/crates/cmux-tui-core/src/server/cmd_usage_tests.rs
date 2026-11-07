//! `usage-record` / `usage-set-enabled`: refused off the trusted local
//! transport, and a batch lands in the usage folder only while it is on.

use super::*;
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

#[test]
fn usage_commands_refuse_a_remote_or_websocket_client() {
    let mux = Mux::new_for_test("usage-refuse", crate::SurfaceOptions::default());
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        let client = client(&mux, transport);
        let params = RecordParams { source: "app-dev".into(), events: BATCH.into() };
        let error = record(&mux, client, &params).expect_err("refused");
        assert!(error.to_string().contains("trusted local connection"), "{error}");
        let error = set_enabled(&mux, client, &SetEnabledParams { on: true }).expect_err("refused");
        assert!(error.to_string().contains("trusted local connection"), "{error}");
    }
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
