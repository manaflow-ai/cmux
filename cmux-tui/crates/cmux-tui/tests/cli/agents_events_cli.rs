//! `cmux agents events` through a real daemon: from now it returns nothing
//! old, pending events return at once, a wait answers on the first event,
//! the cursor continues with no gaps or duplicates, `--kind` filters,
//! notification text is cut, human output is one line per event, and a bad
//! request exits 2.

use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::super::*;

#[test]
fn agents_events_cli_reads_the_daemon_journal_from_a_cursor() {
    let server = HeadlessServer::start("agents-events-cli");
    // No app answers here: the daemon's journal alone.
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
    let read = |args: &[&str]| -> Value {
        let mut json = vec!["--json"];
        json.extend_from_slice(args);
        let output = command(&json).output().unwrap();
        assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
        json_output(&output)
    };
    let events = |answer: &Value| answer["events"].as_array().cloned().unwrap_or_default();
    let next = |answer: &Value| answer["next_after"].as_str().unwrap().to_owned();

    // From now: the session's workspace, notifications and agents so far
    // are not events. (Tabs are left out: a shell's title may rename its
    // tab at any time.)
    let started = Instant::now();
    let answer = read(&["--kind", "workspace,notification,agent", "--timeout", "1"]);
    assert_eq!(events(&answer), Vec::<Value>::new(), "{answer}");
    assert_eq!(answer["timed_out"], true);
    assert_eq!(answer["sources"]["daemon"], true, "{answer}");
    assert!(started.elapsed() >= Duration::from_millis(900), "{:?}", started.elapsed());
    let after = next(&answer);

    // Pending events return at once, whatever the timeout.
    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let value = &json_output(&created)["value"];
    let terminal = value["terminal_id"].as_str().unwrap().to_owned();
    let tab = value["tab_id"].as_str().or(value["id"].as_str()).unwrap().to_owned();
    let started = Instant::now();
    let answer = read(&["--after", &after, "--timeout", "30"]);
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    let got = events(&answer);
    assert!(
        got.iter().any(|event| event["kind"] == "tab" && event["id"] == tab.as_str()),
        "the new tab: {answer}"
    );
    // What each event names, to check that none repeats across calls.
    let key = |event: &Value| {
        let field = |name: &str| event[name].as_str().unwrap_or("").to_owned();
        format!("{} {} {} {}", field("kind"), field("id"), field("change"), field("state"))
    };
    let mut seen = got.iter().map(key).collect::<Vec<_>>();
    let mut after = next(&answer);

    // Kinds filter; notification text is cut.
    let long = "x".repeat(400);
    let notify =
        json_cli(&server, &["notification", "create", "--title", "Build", "--body", &long]);
    assert_success(&notify);
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
                "agents-events",
            ],
        );
        assert_success(&output);
    };
    report("working");
    let answer = read(&["--after", &after, "--kind", "notification", "--kind", "agent"]);
    let got = events(&answer);
    assert!(
        got.iter().all(|event| matches!(event["kind"].as_str(), Some("notification" | "agent")))
    );
    let notification =
        got.iter().find(|event| event["kind"] == "notification").expect("a notification event");
    assert_eq!(notification["change"], "created", "{answer}");
    assert_eq!(notification["title"], "Build");
    assert_eq!(notification["truncated"], true, "{notification}");
    assert!(notification["body"].as_str().unwrap().chars().count() <= 161);
    let agent = got.iter().find(|event| event["kind"] == "agent").expect("an agent event");
    assert_eq!(agent["state"], "working", "{answer}");
    assert_eq!(agent["terminal_id"], terminal.as_str());
    seen.extend(got.iter().map(key));
    after = next(&answer);

    // A wait answers on the first event, not the timeout. (A shell's title
    // may rename its tab at any time, so the rest reads agents only.)
    let waiting = command(&["--json", "--after", &after, "--kind", "agent", "--timeout", "20"])
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(700));
    let started = Instant::now();
    report("idle");
    let output: Output = waiting.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    let answer = json_output(&output);
    let got = events(&answer);
    assert_eq!(got.len(), 1, "{answer}");
    assert_eq!((got[0]["kind"].as_str(), got[0]["state"].as_str()), (Some("agent"), Some("idle")));
    seen.extend(got.iter().map(key));
    after = next(&answer);
    let agent_id = agent["id"].as_str().unwrap();
    let once = [
        format!("notification {} created ", notification["id"].as_str().unwrap()),
        format!("agent {agent_id} state working"),
        format!("agent {agent_id} state idle"),
    ];
    for once in &once {
        let count = seen.iter().filter(|key| key.as_str() == once.as_str()).count();
        assert_eq!(count, 1, "{once}: {seen:?}");
    }

    // Nothing new: the same cursor times out empty, and exits 0.
    let started = Instant::now();
    let answer = read(&["--after", &after, "--kind", "agent", "--timeout", "1"]);
    assert_eq!(events(&answer), Vec::<Value>::new(), "{answer}");
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());

    // A one-event walk cuts journal batches and resumes inside them: it
    // reads exactly what one read from the same cursor reads.
    for name in ["events-a", "events-b"] {
        assert_success(&json_cli(&server, &["workspace", "create", "--name", name]));
    }
    let two = json_cli(&server, &["notification", "create", "--title", "Two", "--body", "b"]);
    assert_success(&two);
    let kinds = "workspace,notification,agent";
    let observed = |mut event: Value| {
        // `at` is when a workspace change was read, so it differs.
        event.as_object_mut().unwrap().remove("at");
        event
    };
    let whole = read(&["--after", &after, "--kind", kinds, "--limit", "200", "--timeout", "0"]);
    let whole = events(&whole).into_iter().map(observed).collect::<Vec<_>>();
    assert!(whole.len() >= 3, "two workspaces and a notification: {whole:?}");
    let (mut walked, mut cursor) = (Vec::new(), after.clone());
    for _ in 0..100 {
        let answer = read(&["--after", &cursor, "--kind", kinds, "--limit", "1", "--timeout", "0"]);
        let got = events(&answer);
        assert!(got.len() <= 1, "{answer}");
        cursor = next(&answer);
        if got.is_empty() {
            break;
        }
        walked.extend(got.into_iter().map(observed));
    }
    assert_eq!(walked, whole, "no gaps or duplicates when a batch is cut");

    // A person reads one line per event; the cursor goes to stderr.
    report("working");
    let output =
        command(&["--after", &after, "--kind", "agent", "--timeout", "5"]).output().unwrap();
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines = stdout.lines().collect::<Vec<_>>();
    assert_eq!(lines.len(), 1, "{stdout}");
    assert!(lines[0].contains("agent") && lines[0].ends_with("working"), "{stdout}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("next_after=evc1_"));

    let usage = command(&["--json", "--kind", "terminal"]).output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    assert_eq!(json_error(&usage)["code"], "usage.invalid");
}
