//! Every holder process enters through `serve_process`: the standalone
//! `cmux-holder` and the built-in `__holder` of `cmux-tui-host` and
//! `cmux-tui` the daemon falls back to when the standalone holder fails to
//! start. A panic after that entry appends one line to
//! `holder-panics.jsonl` beside the socket. Its own test binary, so the
//! process's panic hook touches no other test.

#![cfg(unix)]

mod support;

#[test]
fn a_panic_after_serve_process_writes_one_line_beside_the_socket() {
    let dir = support::unique_dir("cmsp");
    let socket = dir.join("h.sock");
    // An unknown argument ends `serve` before it reads the token on stdin;
    // the hook is installed by then.
    let args = ["--socket".to_string(), socket.display().to_string(), "--no-such-flag".to_string()];
    let error = cmux_holder::serve_process(&args).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput, "{error}");

    let joined = std::thread::Builder::new()
        .name("built-in-holder".into())
        .spawn(|| panic!("built-in holder panic"))
        .unwrap()
        .join();
    assert!(joined.is_err(), "the thread panicked");

    let text = std::fs::read_to_string(dir.join("holder-panics.jsonl")).unwrap();
    assert_eq!(text.lines().count(), 1, "one panic, one line: {text}");
    let record: serde_json::Value = serde_json::from_str(text.trim_end()).unwrap();
    assert_eq!(record["process"], "cmux-holder", "{record}");
    assert_eq!(record["message"], "built-in holder panic", "{record}");
    assert_eq!(record["thread"], "built-in-holder", "{record}");
    assert_eq!(record["holder_socket"], "h.sock", "{record}");
    assert_eq!(record["holder_wire"], cmux_holder::version_line(), "{record}");
    let _ = std::fs::remove_dir_all(&dir);
}
