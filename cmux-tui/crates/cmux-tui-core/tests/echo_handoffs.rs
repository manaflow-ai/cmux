//! The daemon's thread handoffs of a key's echo (p09-observability-102), end to end in their own
//! process with key-press flows recording (CMUX_TRACE_FLOWS): the surface queues the echo for each
//! attach viewer, the viewer's attach-out thread takes it, encodes it and queues it for its
//! connection's line-out thread, which takes it and writes it to the app. Each mark carries the
//! press's flow from its queue item; output that echoes nothing marks no handoff. Both viewer kinds
//! are covered: a replay viewer (`vt-state`) and a snapshot viewer (`terminal-snapshot-v1`, the app's).
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::time::Duration;

mod support;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};
use support::{DaemonMuxOps, wait_for};

fn connect(path: &Path) -> (Box<dyn transport::Stream>, BufReader<Box<dyn transport::Stream>>) {
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    (stream.try_clone_box().unwrap(), BufReader::new(stream))
}

fn read_json_line(reader: &mut impl BufRead) -> Option<serde_json::Value> {
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) => None,
        Ok(_) => serde_json::from_str(&line).ok(),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            None
        }
        Err(error) => panic!("socket read failed: {error}"),
    }
}

/// The next line that `wanted` accepts, skipping every other line.
fn next_line(
    reader: &mut impl BufRead,
    what: &str,
    wanted: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    wait_for(|| read_json_line(reader).filter(&wanted), Duration::from_secs(10))
        .unwrap_or_else(|| panic!("no {what}"))
}

fn send(writer: &mut impl Write, reader: &mut impl BufRead, request: serde_json::Value) {
    writeln!(writer, "{request}").unwrap();
    let response = next_line(reader, "send response", |value| value.get("id") == request.get("id"));
    assert_eq!(response["ok"], true, "send failed: {response}");
}

/// The `key.echo.*` flow steps of `flow` in this process's recording, in time order: the name with
/// `>` for a flow out (queued) and `<` for a flow in (taken).
fn handoff_steps(flow: u64) -> Vec<String> {
    let status = cmux_trace::status().expect("flows started tracing");
    let path = status.recording_path.expect("the recording is a file");
    let decoded = cmux_trace::decode(&std::fs::read(path).unwrap()).expect("the recording decodes");
    let mut steps: Vec<_> = decoded
        .records
        .iter()
        .filter(|record| record.arg1 == flow)
        .filter_map(|record| {
            let name = decoded.name(record.name).filter(|name| name.starts_with("key.echo."))?;
            let mark = if record.phase == cmux_trace::Phase::FlowOut as u8 { '>' } else { '<' };
            Some((record.t_ns, format!("{name}{mark}")))
        })
        .collect();
    steps.sort_by_key(|(at, _)| *at);
    steps.into_iter().map(|(_, step)| step).collect()
}

/// Types one key with `flow` and one without, and checks the echo's handoffs.
fn check_viewer(
    sock_path: &Path,
    surface: &serde_json::Value,
    attach: &mut BufReader<Box<dyn transport::Stream>>,
    flow: u64,
) {
    let (mut writer, mut reader) = connect(sock_path);
    let request =
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": "a", "flow": flow});
    send(&mut writer, &mut reader, request);
    next_line(attach, "echo", |value| value["event"] == "output" && value["flow"] == flow);
    assert_eq!(
        handoff_steps(flow),
        [
            "key.echo.surface_parse>",
            "key.echo.surface_parse<",
            "key.echo.attach_encode>",
            "key.echo.attach_encode<",
            "key.echo.line_out>",
        ],
        "the echo of flow {flow} through the daemon's threads"
    );
}

#[test]
fn echo_handoffs_carry_the_flow_through_the_daemon_threads() {
    let dir = std::env::temp_dir().join(format!("cmux-echo-handoffs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once);
    // this binary has this one test.
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    assert!(cmux_flow_trace::init(), "key-press flows did not start");

    let options =
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new(format!("test-echo-handoffs-{}", std::process::id()), options);
    let surface = mux.new_workspace(None, Some((40, 8))).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    // A replay viewer: `vt-state`, then each output on its `mux-attach-out` thread.
    let (mut attach_writer, mut attach) = connect(&sock_path);
    writeln!(attach_writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id)
        .unwrap();
    next_line(&mut attach, "vt-state", |value| value["event"] == "vt-state");
    check_viewer(&sock_path, &serde_json::json!(surface.id), &mut attach, 4444);
    drop((attach_writer, attach));

    // A snapshot viewer: a READY snapshot, then each output on its `mux-snapshot-attach-out` thread.
    let (mut snapshot_writer, mut snapshot) = connect(&sock_path);
    let request = serde_json::json!({
        "id": 1, "cmd": "attach-surface", "surface": surface.id,
        "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
    });
    writeln!(snapshot_writer, "{request}").unwrap();
    next_line(&mut snapshot, "READY snapshot", |value| {
        value["event"] == "snapshot" && value["phase"] == "ready"
    });
    check_viewer(&sock_path, &serde_json::json!(surface.id), &mut snapshot, 4545);

    // Output that echoes no key press marks no handoff.
    let (mut writer, mut reader) = connect(&sock_path);
    send(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface.id, "text": "b"}),
    );
    let plain = next_line(&mut snapshot, "plain output", |value| value["event"] == "output");
    assert!(plain.get("flow").is_none(), "output with no flow behind it: {plain}");
    assert!(handoff_steps(0).is_empty(), "flow 0 marked a handoff");

    mux.close_surface(surface.id).unwrap();
    cmux_tui_core::server::cleanup(&sock_path);
    let _ = std::fs::remove_dir_all(&dir);
}
