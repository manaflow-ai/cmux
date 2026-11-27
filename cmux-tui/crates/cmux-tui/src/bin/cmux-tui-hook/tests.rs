use super::*;

/// A server may answer and close before the hook child reads. macOS then
/// refuses `setsockopt(SO_RCVTIMEO)` with EINVAL although the receipt is
/// still readable; treating that as a failed attempt re-sent the event,
/// so the journal received it twice and out of order.
#[cfg(unix)]
#[test]
fn codex_hook_receipt_from_a_server_that_already_closed_is_still_read() {
    let (client, mut server) = std::os::unix::net::UnixStream::pair().unwrap();
    server.write_all(b"{\"type\":\"response\"}\n").unwrap();
    drop(server);
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut reader: BufReader<Box<dyn transport::Stream>> = BufReader::new(Box::new(client));
    match read_before(&mut reader, deadline) {
        Ok(response) => assert_eq!(response, b"{\"type\":\"response\"}\n"),
        Err(AppendAttemptError::Retryable(error) | AppendAttemptError::Fatal(error)) => {
            panic!("the written receipt was not read: {error:#}")
        }
    }
}

fn cmux_environ(pid: u32) -> Option<std::collections::HashMap<String, String>> {
    let environment = |terminal: &str| {
        Some(
            [("CMUX_TUI_SOCKET", "/run/cmux.sock"), ("CMUX_TUI_TERMINAL_ID", terminal)]
                .map(|(key, value)| (key.to_owned(), value.to_owned()))
                .into(),
        )
    };
    match pid {
        10 => environment("term_other_window"),
        11 => environment("term_shows_pane"),
        12 => environment("term_recent"),
        // A plain SSH client: no cmux-tui terminal.
        13 => Some([("SSH_TTY".to_owned(), "/dev/pts/3".to_owned())].into()),
        _ => None,
    }
}

#[test]
fn tmux_route_prefers_the_client_showing_the_pane() {
    let clients = "10\t500\t$1\t\t@2\n11\t100\t$1\t\t@1\n12\t900\t$7\t\t@9\n";
    let route = tmux_route::select("$1\t\t@1\n", clients, cmux_environ).unwrap();
    assert_eq!(route.terminal, "term_shows_pane");
    assert_eq!(route.socket, PathBuf::from("/run/cmux.sock"));
}

#[test]
fn tmux_route_falls_back_to_the_most_recent_client_of_the_session_group() {
    // Client 13 shows the pane but is a plain SSH client; 12 attaches a
    // grouped session and is newer than 10.
    let clients = "13\t999\t$1\tgrp\t@1\n10\t500\t$1\tgrp\t@2\n12\t900\t$7\tgrp\t@9\n";
    let route = tmux_route::select("$1\tgrp\t@1", clients, cmux_environ).unwrap();
    assert_eq!(route.terminal, "term_recent");
}

#[test]
fn tmux_route_ignores_other_sessions_and_non_cmux_clients() {
    let clients = "12\t900\t$7\t\t@9\n13\t999\t$1\t\t@1\n";
    assert_eq!(tmux_route::select("$1\t\t@1", clients, cmux_environ), None);
    assert_eq!(tmux_route::select("", clients, cmux_environ), None);
    assert_eq!(tmux_route::select("$1\t\t@1", "garbage\n1\t0\t$1\t\t@1\n", cmux_environ), None);
}

/// claude `SessionStart` carries cmux's startup line as `systemMessage`
/// (shown to the person, never added to the model's context); with no
/// line it is the empty object the installed command expects.
#[test]
fn claude_session_start_writes_the_startup_line_as_a_system_message() {
    let delivery = inbox::Delivery::for_event("claude", "SessionStart")
        .expect("claude SessionStart writes cmux's startup line");
    assert_eq!(delivery.output(None), json!({}));
    assert_eq!(delivery.output(Some("line")), json!({"systemMessage": "line"}));
    assert_eq!(inbox::Delivery::for_event("codex", "SessionStart"), None);
}

#[test]
fn codex_session_end_handoff_stays_below_the_codex_hook_cap() {
    assert!(handoff_wait("codex", "SessionEnd") < Duration::from_secs(3));
    // The session context read (session_context.rs) still fits in 5 s.
    assert!(handoff_wait("codex", "SessionStart") < Duration::from_secs(3));
    assert_eq!(handoff_wait("codex", "Stop"), HANDOFF_WAIT);
    assert_eq!(handoff_wait("claude", "SessionEnd"), HANDOFF_WAIT);
}

#[test]
fn parses_short_positional_source_and_event() {
    assert_eq!(
        parse_args(["codex", "Stop"].map(str::to_owned)).unwrap(),
        Args { source: "codex".into(), native_event: "Stop".into() }
    );
}

#[test]
fn grok_compatibility_events_are_deduplicated_inside_the_helper() {
    use std::ffi::OsStr;

    assert!(shadowed_by_grok("claude", Some(OsStr::new("Stop"))));
    assert!(shadowed_by_grok("cursor", Some(OsStr::new("stop"))));
    assert!(!shadowed_by_grok("codex", Some(OsStr::new("Stop"))));
    assert!(!shadowed_by_grok("claude", None));
}

#[test]
fn invalid_utf8_is_retained_as_base64() {
    let native = read_native_payload(&[0xff, 0x00][..]).unwrap();
    assert_eq!(native, json!({"encoding":"base64","data":"/wA="}));
}

#[test]
fn bounded_detached_request_id_preserves_uuid_and_payload() {
    use std::io::Cursor;

    let request_id = "550e8400-e29b-41d4-a716-446655440000";
    let mut reader = BufReader::new(Cursor::new(format!("{request_id}\n{{\"event\":\"Stop\"}}")));
    assert_eq!(read_detached_request_id(&mut reader).unwrap(), request_id);

    let mut payload = Vec::new();
    reader.read_to_end(&mut payload).unwrap();
    assert_eq!(payload, br#"{"event":"Stop"}"#);
}

#[test]
fn bounded_detached_request_id_accepts_maximum_length_with_crlf() {
    use std::io::Cursor;

    let request_id = "x".repeat(MAX_REQUEST_ID_BYTES);
    let mut input = request_id.as_bytes().to_vec();
    input.extend_from_slice(b"\r\n{}");
    let mut reader = BufReader::new(Cursor::new(input));
    assert_eq!(read_detached_request_id(&mut reader).unwrap(), request_id);

    let mut payload = Vec::new();
    reader.read_to_end(&mut payload).unwrap();
    assert_eq!(payload, b"{}");
}

#[test]
fn bounded_detached_request_id_rejects_an_unterminated_line() {
    use std::io::Cursor;

    let mut reader = BufReader::new(Cursor::new(b"550e8400-e29b-41d4-a716-446655440000"));
    let error = read_detached_request_id(&mut reader).unwrap_err();
    assert_eq!(error.to_string(), "detached request id is missing newline delimiter");
}

#[test]
fn bounded_detached_request_id_rejects_an_oversized_line() {
    use std::io::Cursor;

    let mut input = vec![b'x'; MAX_REQUEST_ID_BYTES + 1];
    input.push(b'\n');
    let mut reader = BufReader::new(Cursor::new(input));
    let error = read_detached_request_id(&mut reader).unwrap_err();
    assert_eq!(
        error.to_string(),
        format!("detached request id exceeds {MAX_REQUEST_ID_BYTES} bytes")
    );
}

/// Repro (Leo, 2026-11-25: "why isn't it registered?"): a Claude Code coordinator in a cmux
/// terminal had no acpmux name, so `cmux agent send` / `acpmux send` could not reach it. cmux's
/// own hook now runs acpmux's first registration step at each prompt, under a stable name, and
/// starts nothing once acpmux marked the process reached.
#[test]
fn a_claude_prompt_in_a_cmux_terminal_registers_the_chat_with_acpmux() {
    assert!(acpmux_register::applies("claude", "UserPromptSubmit"));
    assert!(!acpmux_register::applies("claude", "SessionStart"), "never wakes a fresh session");
    assert!(!acpmux_register::applies("codex", "UserPromptSubmit"), "a Codex chat cannot register");
    let home = tempfile::tempdir().unwrap();
    let vars = [
        ("CMUX_TUI_CLI", "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        ("CLAUDE_CODE_MESSAGING_SOCKET", "/tmp/cc-socks/77.sock"),
        ("CLAUDE_CODE_MESSAGING_TOKEN", "tok"),
    ];
    let getenv = |key: &str| vars.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned());
    let session = Some("9f3a61c2-0b7e-4c55-8d2e-3a1f00c0ffee");
    let (cli, args) =
        acpmux_register::command(getenv, session, "cosmic-gray", home.path()).expect("a command");
    assert_eq!(cli, PathBuf::from(vars[0].1));
    assert_eq!(args, ["acp", "register", "--auto", "claude-cosmic-gray-9f3a61c2", "--json"]);
    let no_cli = |key: &str| if key == "CMUX_TUI_CLI" { None } else { getenv(key) };
    assert!(acpmux_register::command(no_cli, session, "cosmic-gray", home.path()).is_none());
    // Reached with this process (acpmux's CLI leaves the mark): nothing runs again.
    let mark = acpmux::cli::hook_register::mark_path(home.path(), vars[1].1, vars[2].1);
    std::fs::create_dir_all(mark.parent().unwrap()).unwrap();
    std::fs::write(&mark, b"").unwrap();
    assert!(acpmux_register::command(getenv, session, "cosmic-gray", home.path()).is_none());
}
