//! `memory-report`: who may ask, and what it counts per terminal and for the
//! registry. The real-socket test with live shells is
//! tests/memory_report.rs.

use cmux_memory::{MemoryConsumer, PressureLevel, Retention};

use super::super::cmd_server::memory_report;
use super::super::*;
use super::{MEMORY_REPORT_SCHEMA, MemoryReportRefused};

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("memory-report", crate::SurfaceOptions::default())
}

fn report(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(json!({"cmd": "memory-report"})).unwrap();
    handle_command(mux, client, command, &writer())
}

fn terminal<'a>(report: &'a Value, surface: &crate::Surface) -> &'a Value {
    report["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["surface"] == surface.id)
        .unwrap_or_else(|| panic!("surface {} is not reported: {report}", surface.id))
}

/// One 1x1 RGB Kitty image, shown (`a=T`), so libghostty stores it.
const RED_IMAGE: &[u8] = b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\";

#[test]
fn memory_report_counts_each_terminal_and_sums_them() {
    let mux = test_mux();
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let quiet = mux.new_workspace(None, Some((80, 24))).unwrap();
    let busy = mux.new_workspace(None, Some((80, 24))).unwrap();
    let image = mux.new_workspace(None, Some((80, 24))).unwrap();
    let lines: String = (0..20_000).map(|line| format!("line {line} of scrollback\r\n")).collect();
    busy.with_terminal(|term| term.vt_write(lines.as_bytes())).unwrap();
    image.with_terminal(|term| term.vt_write(RED_IMAGE)).unwrap();

    let data = report(&mux, local).unwrap();
    assert_eq!(data["schema"], MEMORY_REPORT_SCHEMA, "{data}");
    assert_eq!(data["pid"], std::process::id(), "{data}");
    assert_eq!(data["terminals"].as_array().unwrap().len(), 3, "{data}");
    let quiet = terminal(&data, &quiet);
    let busy = terminal(&data, &busy);
    let image = terminal(&data, &image);
    for terminal in [quiet, busy, image] {
        assert_eq!(terminal["home"], "daemon", "{terminal}");
        assert_eq!(terminal["state"], "hot", "{terminal}");
        assert!(terminal["holder_ring_bytes"].is_null(), "{terminal}");
        assert!(terminal["scrollback"]["live_bytes"].as_u64().unwrap() > 0, "{terminal}");
    }
    let quiet_live = quiet["scrollback"]["live_bytes"].as_u64().unwrap();
    let busy_live = busy["scrollback"]["live_bytes"].as_u64().unwrap();
    assert!(busy_live > quiet_live, "20000 lines of history cost pages: {busy} vs {quiet}");
    assert_eq!(quiet["kitty_image_bytes"], 0, "{quiet}");
    assert_eq!(image["kitty_image_bytes"], 3, "one 1x1 RGB image: {image}");

    let totals = &data["totals"];
    assert_eq!(totals["terminals"], 3, "{totals}");
    let sum = |field: &str| -> u64 {
        data["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .map(|terminal| {
                let value = match field {
                    "scrollback_live_bytes" => &terminal["scrollback"]["live_bytes"],
                    "scrollback_compressed_bytes" => &terminal["scrollback"]["compressed_bytes"],
                    other => &terminal[other],
                };
                value.as_u64().unwrap_or(0)
            })
            .sum()
    };
    for field in ["scrollback_live_bytes", "scrollback_compressed_bytes", "kitty_image_bytes"] {
        assert_eq!(totals[field].as_u64(), Some(sum(field)), "{field}: {data}");
    }
    assert_eq!(totals["holder_ring_bytes"], 0, "{totals}");
}

#[test]
fn memory_report_names_no_title_or_path() {
    let mux = test_mux();
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface
        .with_terminal(|term| {
            term.vt_write(b"\x1b]0;secret-title\x07\x1b]7;file:///secret/pwd\x07");
        })
        .unwrap();
    let text = report(&mux, local).unwrap().to_string();
    assert!(!text.contains("secret"), "{text}");
}

#[test]
fn memory_report_lists_the_registry_consumers_and_level() {
    let mux = test_mux();
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let registration = mux.memory.registry().register(MemoryConsumer::new(
        "test.cache",
        Retention::Lossy,
        || Some(4096),
        |_| {},
    ));
    let data = report(&mux, local).unwrap();
    let consumers = data["consumers"].as_array().unwrap();
    assert!(
        consumers.contains(&json!({"name": "test.cache", "retention": "lossy", "bytes": 4096})),
        "{data}"
    );
    // The standby terminal host is the first consumer; its spare's memory
    // is its own process's.
    #[cfg(any(unix, windows))]
    assert!(
        consumers.contains(
            &json!({"name": "terminal.standby-host", "retention": "lossless", "bytes": null})
        ),
        "{data}"
    );

    // The level is the worst vote, so a critical vote shows whatever the
    // kernel source says.
    let voter = mux.memory.registry().voter();
    voter.set_level(PressureLevel::Critical);
    assert_eq!(report(&mux, local).unwrap()["pressure"], "critical");
    drop(voter);
    drop(registration);
    let names = report(&mux, local).unwrap()["consumers"].to_string();
    assert!(!names.contains("test.cache"), "an unregistered consumer is gone: {names}");
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn memory_report_reads_the_process_footprint() {
    let mux = test_mux();
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let data = report(&mux, local).unwrap();
    let process = &data["process"];
    assert!(process["private_footprint_bytes"].as_u64().unwrap() > 0, "{data}");
    assert!(process["resident_bytes"].as_u64().unwrap() > 0, "{data}");
}

#[test]
fn memory_report_refuses_a_websocket_or_unknown_client() {
    let mux = test_mux();
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer());
    let error = report(&mux, websocket).expect_err("a WebSocket client is not the owner");
    assert_eq!(error.downcast_ref(), Some(&MemoryReportRefused::NotLocal), "{error}");
    // An unregistered id is remote to dispatch, and never local to the
    // handler.
    let error = report(&mux, 9_999).expect_err("an unregistered client is never trusted");
    assert_eq!(error.to_string(), remote_relay::REMOTE_DENIED, "{error}");
    let error = memory_report(&mux, 9_999).unwrap_err();
    assert_eq!(error.downcast_ref(), Some(&MemoryReportRefused::NotLocal), "{error}");
}

#[test]
fn memory_report_refuses_a_remote_relay_client() {
    let mux = test_mux();
    let remote = mux.control_clients.register(ClientTransport::Remote, writer());
    // Dispatch refuses it before the handler (remote_relay::intercept).
    let error = report(&mux, remote).expect_err("a remote relay client is refused");
    assert_eq!(error.to_string(), remote_relay::REMOTE_DENIED, "{error}");
    // The handler refuses it on its own as well.
    let error = memory_report(&mux, remote).unwrap_err();
    assert_eq!(error.downcast_ref(), Some(&MemoryReportRefused::NotLocal), "{error}");
    // And the frame gate refuses the frame before anything parses it.
    assert_eq!(
        remote_relay::gate::check_frame(r#"{"id":1,"cmd":"memory-report"}"#),
        Err(remote_relay::gate::Denial::Command)
    );
}

#[test]
fn memory_report_reads_a_cold_terminal_without_restoring_it() {
    let mux = test_mux();
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let lines: String = (0..3_000).map(|line| format!("line {line} of scrollback\r\n")).collect();
    surface.with_terminal(|term| term.vt_write(lines.as_bytes())).unwrap();
    let wake: crate::surface::ThawWake = Arc::new(|| {});
    let outcome = surface.freeze_cold_terminal(&[], &wake);
    let Some(crate::surface::ColdFreeze::Frozen { held_bytes }) = outcome else {
        panic!("not frozen: {outcome:?}");
    };

    let data = report(&mux, local).unwrap();
    assert!(surface.terminal_is_cold(), "the report restored the terminal: {data}");
    let cold = terminal(&data, &surface);
    assert_eq!(cold["state"], "cold", "{cold}");
    assert_eq!(cold["cold"]["held_bytes"], held_bytes, "{cold}");
    assert!(cold["cold"]["snapshot_bytes"].as_u64().unwrap() > 0, "{cold}");
    assert!(cold["scrollback"].is_null(), "{cold}");
    assert_eq!(data["totals"]["cold_terminals"], 1, "{data}");
    assert_eq!(data["totals"]["cold_held_bytes"], held_bytes, "{data}");
}
