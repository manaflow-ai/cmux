//! `--until`, `--match` and `--timeout` on `cmux agents events` (a real
//! daemon) and `cmux events` (the app's `events.stream`, served here by a
//! stand-in app socket since the app is not part of this crate): a wait
//! answers the first matching event and exits 0, and one that runs out of
//! time says `timed_out` and exits 124.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::*;

#[test]
fn agents_events_until_answers_the_first_match_and_times_out_with_124() {
    let server = HeadlessServer::start("agents-events-until");
    let no_app = server.dir.join("no-app.sock");
    let command = |args: &[&str]| -> Command {
        let mut command = Command::new(bin());
        command
            .arg("--socket")
            .arg(&server.socket)
            .arg("--app-socket")
            .arg(&no_app)
            .args(["agents", "events"])
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    };

    // A wait started before the change ends on it, not at its timeout.
    let waiting = command(&[
        "--json",
        "--until",
        "workspace.*",
        "--match",
        "name=until-target",
        "--timeout",
        "30s",
    ])
    .spawn()
    .unwrap();
    std::thread::sleep(Duration::from_millis(700));
    let started = Instant::now();
    for name in ["until-other", "until-target"] {
        assert_success(&json_cli(&server, &["workspace", "create", "--name", name]));
    }
    let output: Output = waiting.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(started.elapsed() < Duration::from_secs(15), "{:?}", started.elapsed());
    let answer = json_output(&output);
    let events = answer["events"].as_array().cloned().unwrap_or_default();
    assert_eq!(events.len(), 1, "only the matching event: {answer}");
    assert_eq!(events[0]["kind"], "workspace", "{answer}");
    assert_eq!(events[0]["change"], "changed", "{answer}");
    assert_eq!(events[0]["name"], "until-target", "{answer}");
    assert_eq!(
        (answer["matched"].as_bool(), answer["timed_out"].as_bool()),
        (Some(true), Some(false))
    );
    assert_eq!(answer["until"], json!({"name": "workspace.*", "match": {"name": "until-target"}}));
    let after = answer["next_after"].as_str().unwrap().to_owned();

    // A wait whose event never comes says timed_out and exits 124, on time.
    let started = Instant::now();
    let output = command(&[
        "--json",
        "--after",
        &after,
        "--until",
        "dialog.opened",
        "--match",
        "id=never",
        "--timeout",
        "1s",
    ])
    .output()
    .unwrap();
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_millis(900) && elapsed < Duration::from_secs(8),
        "{elapsed:?}"
    );
    let answer = json_output(&output);
    assert_eq!(
        (answer["matched"].as_bool(), answer["timed_out"].as_bool()),
        (Some(false), Some(true))
    );
    assert_eq!(answer["events"], json!([]), "{answer}");

    // Events already pending after the cursor count: a later wait from the
    // same cursor finds one that happened before it started.
    assert_success(&json_cli(&server, &["workspace", "create", "--name", "until-late"]));
    let output =
        command(&["--json", "--after", &after, "--match", "name=until-late", "--timeout", "10s"])
            .output()
            .unwrap();
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(json_output(&output)["events"][0]["name"], "until-late");

    // Without --until or --match a timeout past the long-poll bound, or a
    // bad --until, is a usage error naming the form.
    for bad in [vec!["--timeout", "5m"], vec!["--until", "a*b"], vec!["--match", "nokey"]] {
        let mut args = vec!["--json"];
        args.extend(bad.iter().copied());
        let usage = command(&args).output().unwrap();
        assert_eq!(usage.status.code(), Some(2), "{bad:?}");
        assert_eq!(json_error(&usage)["code"], "usage.invalid", "{bad:?}");
    }
}

/// A stand-in app socket: `ping` answers PONG, an `events.stream` request
/// gets an ack, a heartbeat and `frames`, and the stream then stays open
/// until the test is done (as the app's does). A `{"quiet_ms": N}` frame
/// sends nothing for N ms; `{"close": true}` ends the stream. With `trickle`, each of
/// `frames` (not the ack or heartbeat) is sent a byte at a time with that
/// pause between bytes.
fn stand_in_app(
    socket: &std::path::Path,
    frames: Vec<Value>,
    trickle: Option<Duration>,
    done: Arc<AtomicBool>,
) {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        while !done.load(Ordering::Relaxed) {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(error) => panic!("app accept: {error}"),
            };
            let frames = frames.clone();
            let done = done.clone();
            std::thread::spawn(move || {
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let text = line.trim().to_owned();
                    line.clear();
                    if text == "ping" {
                        let _ = writeln!(writer, "PONG");
                        continue;
                    }
                    let Ok(request) = serde_json::from_str::<Value>(&text) else { continue };
                    if request["method"] != "events.stream" {
                        // `--socket`'s kind probe wants `pong`.
                        let result = match request["method"].as_str() {
                            Some("system.ping") => json!({"pong": true}),
                            _ => json!({}),
                        };
                        let _ = writeln!(
                            writer,
                            "{}",
                            json!({"id": request["id"], "ok": true, "result": result})
                        );
                        continue;
                    }
                    let ack = json!({"type": "ack", "protocol": "cmux-events", "version": 1});
                    let heartbeat = json!({"type": "heartbeat"});
                    let opening = [ack, heartbeat];
                    let all = opening.iter().map(|frame| (frame, None));
                    for (frame, pause) in all.chain(frames.iter().map(|frame| (frame, trickle))) {
                        // Directives, not frames: go quiet, or end the stream.
                        if let Some(quiet) = frame["quiet_ms"].as_u64() {
                            std::thread::sleep(Duration::from_millis(quiet));
                            continue;
                        }
                        if frame["close"] == true {
                            return;
                        }
                        let text = format!("{frame}\n");
                        let sent = match pause {
                            None => writer.write_all(text.as_bytes()),
                            Some(pause) => text.bytes().try_for_each(|byte| {
                                std::thread::sleep(pause);
                                writer.write_all(&[byte])
                            }),
                        };
                        if sent.is_err() {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(50));
                    }
                    while !done.load(Ordering::Relaxed) {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    return;
                }
            });
        }
    });
}

#[test]
fn cmux_events_until_prints_the_match_and_a_timeout_exits_124() {
    let dir = std::env::temp_dir().join(format!("cmux-events-until-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let app = dir.join("app.sock");
    let event = |seq: u64, name: &str, workspace: &str| {
        json!({"type": "event", "seq": seq, "name": name, "category": "workspace",
            "workspace_id": workspace, "payload": {"origin": "cli", "index": seq}})
    };
    let frames = vec![
        event(1, "workspace.selected", "ws_1"),
        event(2, "workspace.created", "ws_1"),
        event(3, "workspace.created", "ws_2"),
        event(4, "workspace.closed", "ws_2"),
    ];
    let done = Arc::new(AtomicBool::new(false));
    stand_in_app(&app, frames, None, done.clone());
    let run = |args: &[&str]| -> Output {
        Command::new(bin())
            .arg("--app-socket")
            .arg(&app)
            .arg("events")
            .args(args)
            .env("CMUX_TUI_SOCKET", dir.join("no-daemon.sock"))
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .output()
            .unwrap()
    };
    let lines = |output: &Output| -> Vec<Value> {
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap_or_else(|_| panic!("not JSON: {line}")))
            .collect()
    };

    // The first event that matches the name and every field, alone.
    let output = run(&[
        "--until",
        "workspace.created",
        "--match",
        "workspace_id=ws_2",
        "--match",
        "payload.index=3",
        "--timeout",
        "10s",
    ]);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    let got = lines(&output);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(
        (got[0]["seq"].as_u64(), got[0]["name"].as_str()),
        (Some(3), Some("workspace.created"))
    );

    // A prefix glob ends on the first workspace event.
    let output = run(&["--until", "workspace.*", "--timeout", "10s"]);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(lines(&output)[0]["seq"], 1);

    // No match by the timeout: the last line says timed_out; exit 124.
    let started = Instant::now();
    let output = run(&["--jsonl", "--until", "workspace.renamed", "--timeout", "1s"]);
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_millis(900) && elapsed < Duration::from_secs(8),
        "{elapsed:?}"
    );
    let got = lines(&output);
    assert_eq!(got.len(), 1, "only the timeout record: {got:?}");
    assert_eq!(got[0]["type"], "timeout");
    assert_eq!(got[0]["timed_out"], true);
    assert_eq!(got[0]["waited_ms"], "1000");
    assert_eq!(got[0]["until"], json!({"name": "workspace.renamed"}));

    // A plain --timeout streams every frame, then the timeout record.
    let output = run(&["--json", "--timeout", "1500ms"]);
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
    let got = lines(&output);
    assert_eq!(got.first().map(|frame| frame["type"].clone()), Some(json!("ack")), "{got:?}");
    assert_eq!(got.iter().filter(|frame| frame["type"] == "event").count(), 4, "{got:?}");
    assert_eq!(got.last().map(|frame| frame["timed_out"].clone()), Some(json!(true)), "{got:?}");

    // A person sees why it stopped on stderr; stdout stays the stream.
    let output = run(&["--until", "workspace.renamed", "--timeout", "1s"]);
    assert_eq!(output.status.code(), Some(124));
    assert!(output.stdout.is_empty(), "{}", String::from_utf8_lossy(&output.stdout));
    assert!(String::from_utf8_lossy(&output.stderr).contains("timed out"));

    // Bad flags are usage errors.
    for bad in [vec!["--timeout", "soon"], vec!["--until", ""], vec!["--match", "=x"]] {
        let output = run(&bad);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{bad:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    done.store(true, Ordering::Relaxed);
    let _ = fs::remove_dir_all(&dir);
}

/// The deadline holds between socket reads: a matching frame the app sends
/// a byte at a time, slower than `--timeout`, still ends at the timeout
/// with 124 (a line read gave each of its reads the whole time left).
#[test]
fn cmux_events_timeout_holds_while_a_frame_trickles_in() {
    let dir = std::env::temp_dir().join(format!("cmux-events-trickle-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let app = dir.join("app.sock");
    let frame = json!({"type": "event", "seq": 1, "name": "workspace.created",
        "workspace_id": "ws_1", "payload": {"origin": "cli"}});
    let done = Arc::new(AtomicBool::new(false));
    // About 110 bytes at 30 ms each: over 3 s for the frame.
    stand_in_app(&app, vec![frame], Some(Duration::from_millis(30)), done.clone());
    let started = Instant::now();
    let output = Command::new(bin())
        .arg("--app-socket")
        .arg(&app)
        .args(["events", "--jsonl", "--until", "workspace.created", "--timeout", "1s"])
        .env("CMUX_TUI_SOCKET", dir.join("no-daemon.sock"))
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    let elapsed = started.elapsed();
    done.store(true, Ordering::Relaxed);
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stdout));
    assert!(elapsed < Duration::from_millis(2500), "{elapsed:?}");
    let _ = fs::remove_dir_all(&dir);
}

/// Without --timeout the stream has no deadline: the 5 s reply timeout of
/// `--socket`'s kind probe (`system.ping`) is cleared, so a wait outlasts a
/// quiet app (it used to stop after 5 s with exit 124).
#[test]
fn cmux_events_without_timeout_outlasts_a_quiet_app() {
    let dir = std::env::temp_dir().join(format!("cmux-events-quiet-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let app = dir.join("app.sock");
    let frames = vec![
        json!({"quiet_ms": 6500}),
        json!({"type": "event", "seq": 7, "name": "mobile.rpc.ready", "payload": {}}),
    ];
    let done = Arc::new(AtomicBool::new(false));
    stand_in_app(&app, frames, None, done.clone());
    let output = Command::new(bin())
        .arg("--socket")
        .arg(&app)
        .args(["events", "--jsonl", "--until", "mobile.rpc.ready"])
        .env("CMUX_TUI_SOCKET", dir.join("no-daemon.sock"))
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stdout));
    let line = String::from_utf8_lossy(&output.stdout);
    assert!(line.contains("\"seq\":7"), "{line}");
    let _ = fs::remove_dir_all(&dir);
}

/// The app closing the stream before the match names the seq to resume
/// from: the last one it sent, though no event it sent matched.
#[test]
fn cmux_events_closed_names_the_seq_to_resume_after() {
    let dir = std::env::temp_dir().join(format!("cmux-events-closed-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let app = dir.join("app.sock");
    let event = |seq: u64| json!({"type": "event", "seq": seq, "name": "mobile.rpc.ready"});
    let frames = vec![event(4), event(5), json!({"close": true})];
    let done = Arc::new(AtomicBool::new(false));
    stand_in_app(&app, frames, None, done.clone());
    let output = Command::new(bin())
        .arg("--app-socket")
        .arg(&app)
        .args(["--json", "events", "--until", "action.catalog.changed", "--timeout", "10s"])
        .env("CMUX_TUI_SOCKET", dir.join("no-daemon.sock"))
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    done.store(true, Ordering::Relaxed);
    assert_eq!(output.status.code(), Some(1), "{}", String::from_utf8_lossy(&output.stderr));
    let error = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(error.contains("events.closed"), "{error}");
    assert!(error.contains("--after 5"), "{error}");
    let _ = fs::remove_dir_all(&dir);
}
