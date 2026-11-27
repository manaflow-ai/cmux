use super::*;

#[test]
fn a_silent_daemon_reads_as_no_answer_in_its_bound() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("d.sock");
    // Accepts and never answers, as a powered-off target behind a carrier does.
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let _held = std::thread::spawn(move || {
        listener.accept().map(|(stream, _)| {
            std::thread::sleep(Duration::from_secs(5));
            drop(stream);
        })
    });
    let error = call_once(&socket, "agent-transfer-write", json!({}), Duration::from_millis(200))
        .unwrap_err();
    let message = error.message();
    assert!(!message.contains("os error"), "{message}");
    assert_eq!(message, "agent-transfer-write: no answer in 200ms");
}

#[test]
fn another_socket_error_keeps_its_words() {
    let error = std::io::Error::from(std::io::ErrorKind::BrokenPipe);
    let lost = lost_to("agent-transfer-read", &error, Duration::from_secs(45));
    assert_eq!(lost.message(), format!("agent-transfer-read: {error}"));
}
