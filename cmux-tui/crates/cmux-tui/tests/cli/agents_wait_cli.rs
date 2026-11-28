//! `cmux agents wait` through a real daemon: it answers when text reaches a
//! terminal's screen and when a terminal's agent stops working, a timeout
//! prints the unmatched receipt and exits 1 (as `screen wait` does), and a bad
//! request exits 2.

use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use super::super::*;

#[test]
fn agents_wait_cli_answers_on_text_and_idle_through_a_real_daemon() {
    let server = HeadlessServer::start("agents-wait-cli");
    // No app answers here: the daemon alone decides.
    let no_app = server.dir.join("no-app.sock");
    let wait = |args: &[&str]| -> Child {
        Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&server.socket)
            .arg("--app-socket")
            .arg(&no_app)
            .args(["agents", "wait"])
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };
    let finish = |child: Child| -> (Output, serde_json::Value) {
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
        let receipt = json_output(&output);
        (output, receipt)
    };

    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_owned();

    // Text: the wait starts first, then the line reaches the screen. The
    // typed command never contains the marker; only its output does.
    let started = Instant::now();
    let text = wait(&["--until", "text", "--target", &terminal, "--text", "WAIT-READY 42"]);
    std::thread::sleep(Duration::from_millis(300));
    let write = json_cli(
        &server,
        &["terminal", &terminal, "write", "--text", "printf 'WAIT-%s 42\\n' READY\n"],
    );
    assert_success(&write);
    let (_, receipt) = finish(text);
    assert_eq!(receipt["until"], "text", "{receipt}");
    assert_eq!(receipt["matched"], true, "{receipt}");
    assert_eq!(receipt["match"]["terminal"], terminal.as_str());
    assert!(started.elapsed() < Duration::from_secs(25), "it answered on the output");
    assert_eq!(receipt["state"]["sources"]["daemon"]["available"], true, "{receipt}");

    // Idle: the terminal's agent works, the wait starts, then the agent
    // reports idle.
    let report = |state: &str| {
        let output = json_cli(
            &server,
            &[
                "agent",
                "report",
                "--terminal",
                &terminal,
                "--state",
                state,
                "--source",
                "socket",
                "--source-session",
                "agents-wait",
            ],
        );
        assert_success(&output);
    };
    report("working");
    let idle = wait(&["--until", "idle", "--target", &terminal, "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(700));
    report("idle");
    let (_, receipt) = finish(idle);
    assert_eq!(receipt["matched"], true, "{receipt}");
    assert_eq!(receipt["match"]["state"], "idle", "{receipt}");
    let waited = receipt["waited_seconds"].as_f64().unwrap();
    assert!((0.5..15.0).contains(&waited), "it waited for the report: {receipt}");

    // A timeout still prints its receipt, and exits 1 as `screen wait` does.
    report("working");
    let started = Instant::now();
    let timed_out = wait(&["--until", "idle", "--target", &terminal, "--timeout", "1"])
        .wait_with_output()
        .unwrap();
    assert_eq!(timed_out.status.code(), Some(1), "{}", String::from_utf8_lossy(&timed_out.stderr));
    let receipt = json_output(&timed_out);
    assert_eq!(receipt["matched"], false, "{receipt}");
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());

    let usage = wait(&["--until", "soon"]).wait_with_output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    assert_eq!(json_error(&usage)["code"], "usage.invalid");
}
