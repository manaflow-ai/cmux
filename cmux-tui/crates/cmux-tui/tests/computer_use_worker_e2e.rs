//! The real `cmux-tui __computer-use-worker` process, driven the way the
//! daemon and acpmux's bridge drive it: configure over its stdin, then an
//! agent over the Unix socket. The worker uses the in-memory desktop
//! (`CMUX_CU_FAKE_DESKTOP=1`, honored by debug builds only).
#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

fn line(reader: &mut impl BufRead) -> Value {
    let mut text = String::new();
    reader.read_line(&mut text).unwrap();
    serde_json::from_str(&text).unwrap_or(Value::Null)
}

#[test]
fn computer_use_worker_serves_agents_and_exits_when_stdin_closes() {
    let dir = std::env::temp_dir().join(format!("cu-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let socket = dir.join("run").join("cu.sock");
    let secret = "5a".repeat(32);
    let mut worker = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("__computer-use-worker")
        .env("CMUX_CU_FAKE_DESKTOP", "1")
        .env_remove("DISPLAY")
        .env_remove("WAYLAND_DISPLAY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut control = worker.stdin.take().unwrap();
    let mut events = BufReader::new(worker.stdout.take().unwrap());
    writeln!(
        control,
        "{}",
        json!({"type": "configure", "config": {"mode": "approvedApps"}, "socket": socket,
               "secret": secret, "state_dir": dir.join("state"), "machine": "e2e"})
    )
    .unwrap();
    let ready = line(&mut events);
    assert_eq!(ready["type"], "ready", "{ready}");
    assert_eq!(ready["pid"], worker.id());

    // A peer without the secret is refused.
    let mut bad = UnixStream::connect(&socket).unwrap();
    bad.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(bad, "{}", json!({"secret": "00".repeat(32)})).unwrap();
    assert_eq!(line(&mut BufReader::new(bad))["reason"], "bad secret");

    let agent = UnixStream::connect(&socket).unwrap();
    agent.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut answers = BufReader::new(agent.try_clone().unwrap());
    let mut agent = agent;
    writeln!(agent, "{}", json!({"secret": secret})).unwrap();
    assert_eq!(line(&mut answers)["ok"], true);
    writeln!(agent, "{}", json!({"id": 1, "method": "status"})).unwrap();
    let status = line(&mut answers);
    assert_eq!(status["result"]["body"]["machine"], "e2e", "{status}");
    assert_eq!(status["result"]["body"]["platform"]["os"], "fake");
    assert_eq!(status["result"]["body"]["worker"]["pid"], worker.id(), "{status}");

    // list_displays is metadata: no ask even in approvedApps, and its id is
    // the one a display screenshot takes.
    writeln!(
        agent,
        "{}",
        json!({"id": 10, "method": "tools/call", "name": "list_displays", "session": "s",
        "call_id": "d-1", "arguments": {}})
    )
    .unwrap();
    let displays = line(&mut answers);
    assert_eq!(displays["result"]["is_error"], false, "{displays}");
    let list = displays["result"]["body"]["displays"].as_array().unwrap().clone();
    assert_eq!(list.len(), 1, "{displays}");
    assert_eq!(list[0]["main"], true);
    assert_eq!(list[0]["frame"]["width"], 1000.0);

    // Approved apps: the first use asks the host; "always" is saved.
    writeln!(
        agent,
        "{}",
        json!({"id": 2, "method": "tools/call", "name": "click", "session": "s",
        "label": "Claude", "call_id": "c-1", "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    let ask = line(&mut events);
    assert_eq!(ask["type"], "ask", "{ask}");
    assert_eq!(ask["question"]["remember"], true);
    writeln!(control, "{}", json!({"type": "answer", "id": ask["id"], "answer": "always"}))
        .unwrap();
    let clicked = line(&mut answers);
    assert_eq!(clicked["id"], 2);
    assert_eq!(clicked["result"]["is_error"], false, "{clicked}");
    // The retry of the same call_id does not ask or click again.
    writeln!(
        agent,
        "{}",
        json!({"id": 3, "method": "tools/call", "name": "click", "session": "s",
        "call_id": "c-1", "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    // It answers with the click's own result. The state after the click (its
    // tree and screenshot) is not part of the record, which is written before
    // it is attached, so the retry has none, and the agent's next screenshot
    // returns the image.
    let retried = line(&mut answers);
    let mut first = clicked["result"].clone();
    assert!(first["body"]["state"].is_object(), "{clicked}");
    assert!(first["png"].is_string(), "{clicked}");
    first["body"].as_object_mut().unwrap().remove("state");
    first["png"] = Value::Null;
    assert_eq!(retried["result"], first, "{retried}");
    let saved: Value =
        serde_json::from_slice(&std::fs::read(dir.join("state").join("approvals.json")).unwrap())
            .unwrap();
    assert_eq!(saved["always"], json!(["com.apple.Safari"]));

    record_a_display(&mut agent, &mut answers, &mut events, &mut control, &dir);

    // stdin closes: the worker stops serving and exits 0.
    drop(control);
    let status = worker.wait().unwrap();
    assert!(status.success(), "{status}");
    assert!(!socket.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// `record` through the real worker: the whole screen is asked for once, a
/// one-call recording returns a finished MP4 in the worker's own folder that
/// reads back frame for frame, and a start then a stop on a new connection
/// (nothing held open between them) returns another.
fn record_a_display(
    agent: &mut UnixStream,
    answers: &mut impl BufRead,
    events: &mut impl BufRead,
    control: &mut impl Write,
    dir: &std::path::Path,
) {
    use cmux_computer_use::record::{mp4, synthetic};
    let call = |id: u32, arguments: Value| {
        json!({"id": id, "method": "tools/call", "name": "record", "session": "s",
               "label": "Claude", "call_id": format!("rec-{id}"), "arguments": arguments})
    };
    writeln!(agent, "{}", call(10, json!({"seconds": 0.5, "fps": 20}))).unwrap();
    let ask = line(events);
    assert_eq!(ask["type"], "ask", "{ask}");
    assert_eq!(ask["question"]["app"]["id"], "display", "{ask}");
    writeln!(control, "{}", json!({"type": "answer", "id": ask["id"], "answer": "allow_session"}))
        .unwrap();
    let done = line(answers);
    assert_eq!(done["id"], 10);
    assert_eq!(done["result"]["is_error"], false, "{done}");
    let body = &done["result"]["body"];
    assert_eq!(body["ended"], "max_seconds", "{body}");
    assert_eq!(body["codec"], "h264");
    let path = std::path::PathBuf::from(body["path"].as_str().unwrap());
    assert!(path.starts_with(dir.join("state").join("recordings")), "{path:?}");
    let track = mp4::read_samples(&path).unwrap();
    assert_eq!(track.info.codec, "avc1");
    assert_eq!(Some(track.info.frames), body["frames"].as_u64());
    assert_eq!(Some(track.info.bytes), body["bytes"].as_u64());
    assert_eq!(Some(u64::from(track.info.width)), body["width"].as_u64());
    assert!(track.info.frames >= 2, "{:?}", track.info);
    assert!((500..5000).contains(&track.info.duration_ms), "{:?}", track.info);
    assert!(track.samples[0].key);
    for (i, sample) in track.samples.iter().enumerate() {
        assert_eq!(synthetic::stats(&sample.data).unwrap().index as usize, i);
    }

    // Start on this connection; stop and read on a new one.
    writeln!(agent, "{}", call(11, json!({"action": "start", "max_seconds": 30, "fps": 20})))
        .unwrap();
    let started = line(answers);
    assert_eq!(started["result"]["body"]["recording"], true, "{started}");
    let id = started["result"]["body"]["recording_id"].as_str().unwrap().to_owned();
    writeln!(agent, "{}", call(12, json!({"action": "start"}))).unwrap();
    let second = line(answers);
    assert_eq!(second["result"]["is_error"], true, "{second}");
    assert!(second.to_string().contains("already_recording"), "{second}");
    std::thread::sleep(Duration::from_millis(300));

    let socket = dir.join("run").join("cu.sock");
    let later = UnixStream::connect(socket).unwrap();
    later.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut later_answers = BufReader::new(later.try_clone().unwrap());
    let mut later = later;
    writeln!(later, "{}", json!({"secret": "5a".repeat(32)})).unwrap();
    assert_eq!(line(&mut later_answers)["ok"], true);
    writeln!(later, "{}", call(13, json!({"action": "stop"}))).unwrap();
    let stopped = line(&mut later_answers);
    let body = &stopped["result"]["body"];
    assert_eq!(body["recording_id"], id.as_str(), "{stopped}");
    assert_eq!(body["ended"], "stopped", "{stopped}");
    let path = std::path::PathBuf::from(body["path"].as_str().unwrap());
    let info = mp4::probe(&path).unwrap();
    assert!(info.frames >= 2 && info.duration_ms >= 300, "{info:?}");
    // The file's bytes through the tool, as a caller on another machine reads them.
    let mut got = Vec::new();
    let mut offset = 0u64;
    for n in 0..10_000u32 {
        writeln!(
            later,
            "{}",
            call(100 + n, json!({"action": "read", "recording_id": id, "offset": offset}))
        )
        .unwrap();
        let piece = line(&mut later_answers);
        let body = &piece["result"]["body"];
        assert_eq!(piece["result"]["is_error"], false, "{piece}");
        got.extend(
            base64::Engine::decode(
                &base64::engine::general_purpose::STANDARD,
                body["data_base64"].as_str().unwrap(),
            )
            .unwrap(),
        );
        offset = body["next_offset"].as_u64().unwrap();
        if body["eof"] == true {
            break;
        }
    }
    assert_eq!(got, std::fs::read(&path).unwrap());
}
