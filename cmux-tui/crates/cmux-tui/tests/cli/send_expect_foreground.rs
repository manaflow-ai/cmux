//! `send` with `expect_foreground` (`send-expect-foreground-v1`): a reply meant for the program
//! that asked must never reach the shell that took the foreground back after that program exited.
#![cfg(unix)]

use super::*;

fn terminal(server: &HeadlessServer) -> (String, u64) {
    let created = json_cli(server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string();
    let resolved = json_socket_request(
        &server.socket,
        serde_json::json!({"id": 1, "cmd": "resolve-terminal", "terminal_id": terminal}),
    );
    (terminal, resolved["surface"].as_u64().expect("resolved terminal surface"))
}

/// The full response, `ok` or not.
fn raw_request(server: &HeadlessServer, request: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn foreground(server: &HeadlessServer, surface: u64) -> Option<String> {
    let info = json_socket_request(
        &server.socket,
        serde_json::json!({"id": 2, "cmd": "process-info", "surface": surface}),
    );
    info["foreground_executable"].as_str().map(str::to_string)
}

/// Waits until `matches` holds for the terminal's foreground executable and returns it.
fn wait_for_foreground(
    server: &HeadlessServer,
    surface: u64,
    what: &str,
    matches: impl Fn(&str) -> bool,
) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let name = foreground(server, surface);
        if let Some(name) = name.as_deref().filter(|name| matches(name)) {
            return name.to_string();
        }
        assert!(Instant::now() < deadline, "{what} never became the foreground: {name:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn send(server: &HeadlessServer, surface: u64, text: &str) {
    json_socket_request(
        &server.socket,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface, "text": text}),
    );
}

#[test]
fn a_reply_for_an_exited_program_never_reaches_the_shell() {
    let server = HeadlessServer::start("send-expect-foreground-exited");
    let (terminal, surface) = terminal(&server);
    send(&server, surface, "sleep 1000\n");
    let program = wait_for_foreground(&server, surface, "sleep", |name| name.ends_with("sleep"));
    // The program exits: its shell is the foreground again.
    send(&server, surface, "\u{3}");
    wait_for_foreground(&server, surface, "the shell", |name| !name.ends_with("sleep"));

    let refused = raw_request(
        &server,
        serde_json::json!({
            "id": 4, "cmd": "send", "surface": surface, "text": "echo pasted_$((4+3))\r",
            "paste": true, "expect_foreground": program,
        }),
    );
    assert_eq!(refused["ok"], false, "the reply reached the shell: {refused}");
    assert!(
        refused["error"].to_string().contains("foreground"),
        "the refusal does not name the foreground: {refused}"
    );

    send(&server, surface, "echo after_$((1+1))\n");
    let screen = wait_for_screen(&server, &terminal, "after_2");
    assert!(screen.contains("after_2"), "the shell stopped taking input:\n{screen}");
    assert!(!screen.contains("pasted_7"), "the reply ran as a shell command:\n{screen}");
}

#[test]
fn a_reply_reaches_the_program_that_still_runs() {
    let server = HeadlessServer::start("send-expect-foreground-running");
    let (terminal, surface) = terminal(&server);
    send(&server, surface, "cat\n");
    let program = wait_for_foreground(&server, surface, "cat", |name| name.ends_with("cat"));

    let sent = raw_request(
        &server,
        serde_json::json!({
            "id": 4, "cmd": "send", "surface": surface, "text": "typed_to_cat\r",
            "expect_foreground": program,
        }),
    );
    assert_eq!(sent["ok"], true, "the reply to the running program was refused: {sent}");
    let screen = wait_for_screen(&server, &terminal, "typed_to_cat");
    assert!(screen.contains("typed_to_cat"), "the program never got the reply:\n{screen}");
}

#[test]
fn expect_foreground_needs_a_live_surface() {
    let server = HeadlessServer::start("send-expect-foreground-terminal-id");
    let (terminal, _) = terminal(&server);
    let host_id = json_socket_request(
        &server.socket,
        serde_json::json!({"id": 1, "cmd": "resolve-terminal", "terminal_id": terminal}),
    )["terminal_id"]
        .as_str()
        .expect("host terminal id")
        .to_string();
    let plain = raw_request(
        &server,
        serde_json::json!({"id": 4, "cmd": "send", "terminal_id": host_id, "text": ""}),
    );
    assert_eq!(plain["ok"], true, "send by terminal_id failed on its own: {plain}");
    let refused = raw_request(
        &server,
        serde_json::json!({
            "id": 5, "cmd": "send", "terminal_id": host_id, "text": "",
            "expect_foreground": "sleep",
        }),
    );
    assert_eq!(refused["ok"], false, "expect_foreground by terminal_id was accepted: {refused}");
}

#[test]
fn a_reply_is_refused_when_the_foreground_cannot_be_read() {
    let server = HeadlessServer::start("send-expect-foreground-unreadable");
    let (_, surface) = terminal(&server);
    send(&server, surface, "cat\n");
    let program = wait_for_foreground(&server, surface, "cat", |name| name.ends_with("cat"));
    // The terminal's child exits altogether: there is no foreground left to read.
    send(&server, surface, "\u{4}");
    wait_for_foreground(&server, surface, "the shell", |name| !name.ends_with("cat"));
    send(&server, surface, "exit\n");
    let deadline = Instant::now() + Duration::from_secs(10);
    while raw_request(
        &server,
        serde_json::json!({"id": 2, "cmd": "process-info", "surface": surface}),
    )["data"]["foreground_executable"]
        .is_string()
    {
        assert!(Instant::now() < deadline, "the shell never exited");
        std::thread::sleep(Duration::from_millis(50));
    }

    let refused = raw_request(
        &server,
        serde_json::json!({
            "id": 4, "cmd": "send", "surface": surface, "text": "late_reply\r",
            "expect_foreground": program,
        }),
    );
    assert_eq!(refused["ok"], false, "a reply with no foreground to check was written: {refused}");
}
