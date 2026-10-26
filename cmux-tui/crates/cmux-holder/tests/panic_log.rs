//! The holder's panic log: a panic lands as one JSON line in
//! `holder-panics.jsonl` beside the socket, written by the std-only writer.
//! This file is its own test process, so the hook it installs is the only one.

#![cfg(unix)]

mod support;

fn args(socket: &std::path::Path) -> Vec<String> {
    vec!["--socket".into(), socket.display().to_string()]
}

#[test]
fn the_log_is_beside_the_socket() {
    let socket = std::path::Path::new("/tmp/cmux-hd-501/0123456789abcdef.sock");
    assert_eq!(
        cmux_holder::panic_log_path(&args(socket)).unwrap(),
        std::path::Path::new("/tmp/cmux-hd-501/holder-panics.jsonl"),
    );
    assert_eq!(cmux_holder::panic_log_path(&["--socket".into(), "h.sock".into()]), None);
    assert_eq!(cmux_holder::panic_log_path(&["--version".into()]), None);
}

#[test]
fn a_holder_panic_writes_one_line_beside_its_socket() {
    let dir = support::unique_dir("cmhp");
    let log = dir.join(cmux_holder::PANIC_LOG);
    cmux_holder::install_panic_log(&args(&dir.join("h.sock")));
    assert!(!log.exists(), "no file before a panic");

    let joined = std::thread::Builder::new()
        .name("holder-poll".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("ring \"cut\"\n"))
        .unwrap()
        .join();
    assert!(joined.is_err());

    let text = std::fs::read_to_string(&log).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{text}");
    let line = &lines[0];
    assert_eq!(line["process"], "cmux-holder");
    assert_eq!(line["message"], "ring \"cut\"\n");
    assert_eq!(line["thread"], "holder-poll");
    assert_eq!(line["test"], false);
    assert_eq!(line["wire"], cmux_holder::version_line());
    assert_eq!(line["holder_pid"], std::process::id());
    assert!(line["location"].as_str().unwrap().contains("panic_log.rs:"));
    assert!(line["backtrace"].is_string());
    let _ = std::fs::remove_dir_all(&dir);
}
