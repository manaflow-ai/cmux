//! The new-tab debug timing marks (`CMUX_TUI_DEBUG_SPANS`, cx-6so.58), over
//! a real daemon socket. A `new-tab` with the app's caller-minted terminal id
//! writes its trace under that id, then one `new-tab.follow` line per
//! first-output mark once the tab's shell prints: its first output, then its
//! first prompt mark (OSC 133;A). The shell waits before printing so the
//! prompt reaches the daemon as host output, not in the launch snapshot.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-new-tab-spans-{}-{stamp}", std::process::id()))
}

/// The time of `name` on `trace`, from the arrival of its request.
fn mark(trace: &Value, name: &str) -> Option<u64> {
    trace["marks"].as_array()?.iter().find(|mark| mark[0] == name).and_then(|mark| mark[1].as_u64())
}

#[test]
fn a_new_tab_traces_its_terminal_through_its_first_prompt() {
    let dir = temp_dir();
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let spans = dir.join("spans.jsonl");
    let mut daemon = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_DEBUG_SPANS", &spans)
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    };

    // Unique per test process; the shell exits on its own, and its host with it.
    let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), 0x58);
    let request = json!({"id": 1, "cmd": "new-tab", "terminal_id": terminal_id,
        "env": {"SHELL": "/bin/sh"},
        "shell_args": ["-c", r"sleep 0.3; for i in 1 2 3 4 5 6 7 8; do printf '\033]133;A\007$ '; sleep 0.5; done"]});
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    writeln!(writer, "{request}").unwrap();
    let mut reply = String::new();
    BufReader::new(&stream).read_line(&mut reply).unwrap();
    let reply: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["ok"], true, "new-tab failed: {reply}");

    let deadline = Instant::now() + Duration::from_secs(15);
    let (create, follow) = loop {
        let lines = fs::read_to_string(&spans).unwrap_or_default();
        let traces: Vec<Value> =
            lines.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
        let create = traces
            .iter()
            .find(|trace| trace["label"] == "new-tab" && trace["terminal"] == terminal_id)
            .cloned();
        let follow: Vec<Value> = traces
            .into_iter()
            .filter(|trace| trace["label"] == "new-tab.follow" && trace["terminal"] == terminal_id)
            .collect();
        let prompted = follow.iter().any(|trace| mark(trace, "first_prompt_mark").is_some());
        if let Some(create) = create
            && prompted
        {
            break (create, follow);
        }
        assert!(Instant::now() < deadline, "no new-tab trace with a prompt mark:\n{lines}");
        std::thread::sleep(Duration::from_millis(50));
    };
    let _ = daemon.kill();
    let _ = daemon.wait();
    let _ = fs::remove_dir_all(&dir);

    // The trace starts at the line's arrival, so the connection queue's wait
    // is in it: it ends at `dequeued`, before the pool job starts.
    let dequeued = mark(&create, "dequeued").expect("the create's trace has dequeued");
    let job_start = mark(&create, "job.start").expect("the create's trace has job.start");
    assert_eq!(create["marks"][0][0], "dequeued", "dequeued is the first mark: {create}");
    assert!(dequeued <= job_start, "job.start {job_start} before dequeued {dequeued}");
    let commit = mark(&create, "commit.start").expect("the create's trace has commit.start");
    mark(&create, "reply.queued").expect("the create's trace has reply.queued");
    let first_output = follow.iter().find_map(|trace| mark(trace, "host.first_output"));
    let first_prompt = follow.iter().find_map(|trace| mark(trace, "first_prompt_mark"));
    let (Some(first_output), Some(first_prompt)) = (first_output, first_prompt) else {
        panic!("missing first-output marks: {follow:?}");
    };
    assert!(commit <= first_output, "first output {first_output} before commit {commit}");
    assert!(first_output <= first_prompt, "prompt {first_prompt} before output {first_output}");
    let names: Vec<_> = follow.iter().filter_map(|trace| trace["marks"][0][0].as_str()).collect();
    assert_eq!(
        names.iter().filter(|name| **name == "host.first_output").count(),
        1,
        "each first-output mark is written once: {names:?}"
    );
}
