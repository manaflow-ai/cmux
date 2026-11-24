use super::*;

#[test]
fn the_version_line_names_the_wire_range_and_parses_back() {
    assert_eq!(version_line(), format!("cmux-holder wire 1-{}", wire::VERSION));
    assert_eq!(parse_version_line(&version_line()), Some((1, wire::VERSION)));
    assert_eq!(parse_version_line("cmux-holder wire 2-3\n"), Some((2, 3)));
    assert_eq!(parse_version_line("cmux-tui-host 1.2.3"), None);
    assert_eq!(parse_version_line("cmux-holder wire 4-3"), None);
}

#[test]
fn a_holder_ends_terminals_no_daemon_linked_for_a_week() {
    assert_eq!(orphan_grace_from(None), ABANDONED_GRACE);
    assert_eq!(orphan_grace_from(Some("0")), ABANDONED_GRACE);
    assert_eq!(orphan_grace_from(Some("600000")), std::time::Duration::from_secs(600));
    assert_eq!(orphan_grace_from(Some(&u64::MAX.to_string())), ABANDONED_GRACE);
}

#[test]
fn spawn_request_round_trips() {
    let request = SpawnRequest {
        id: [7; 16],
        cols: 80,
        rows: 24,
        px_w: 640,
        px_h: 384,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-l".to_vec()],
        env: vec![b"TERM=xterm-256color".to_vec()],
    };
    assert_eq!(SpawnRequest::decode(&request.encode()).unwrap(), request);
}
