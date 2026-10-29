//! Exact echo flows end to end: a `send` that
//! carries a key press's `flow` gets that flow on the terminal's next
//! `output` event, once; output with no flow behind it has no `flow` field.
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

mod support;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};
use support::{DaemonMuxOps, wait_for};

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

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

/// The next line of `event`, skipping every other line.
fn next_event(reader: &mut impl BufRead, event: &str) -> serde_json::Value {
    wait_for(
        || read_json_line(reader).filter(|value| value["event"] == event),
        Duration::from_secs(10),
    )
    .unwrap_or_else(|| panic!("no {event} event"))
}

fn send(writer: &mut impl Write, reader: &mut impl BufRead, request: serde_json::Value) {
    writeln!(writer, "{request}").unwrap();
    let response = wait_for(
        || read_json_line(reader).filter(|value| value.get("id") == request.get("id")),
        Duration::from_secs(10),
    )
    .expect("send response");
    assert_eq!(response["ok"], true, "send failed: {response}");
}

#[test]
fn echo_flow_reaches_the_next_output_event_once() {
    let options =
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new(unique_session("test-echo-flow"), options);
    let surface = mux.new_workspace(None, Some((40, 8))).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    let (mut attach_writer, mut attach_reader) = connect(&sock_path);
    writeln!(attach_writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id)
        .unwrap();
    next_event(&mut attach_reader, "vt-state");

    let (mut writer, mut reader) = connect(&sock_path);
    send(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface.id, "text": "a", "flow": 42}),
    );
    let echo = next_event(&mut attach_reader, "output");
    assert_eq!(echo["flow"], 42, "the echo of flow 42: {echo}");

    // The flow went with its echo: input without one gives output without one.
    send(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface.id, "text": "b"}),
    );
    let plain = next_event(&mut attach_reader, "output");
    assert!(plain.get("flow").is_none(), "output with no flow behind it: {plain}");

    mux.close_surface(surface.id).unwrap();
    cmux_tui_core::server::cleanup(&sock_path);
}
