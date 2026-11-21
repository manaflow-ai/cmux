use super::*;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixListener;

#[test]
fn newtab_agent_identity_mcp_hello_obeys_event_deadline() {
    let suffix = wire::random_request_id().unwrap();
    let path = std::env::temp_dir().join(format!("cmux-dl-{}.sock", &suffix[..12]));
    let listener = UnixListener::bind(&path).unwrap();
    let worker = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let hello: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(hello["cmd"], "set-client-info");
        // Deliberately hold the hello until the client closes at its deadline.
        line.clear();
        let _ = reader.read_line(&mut line);
    });
    let global = GlobalArgs { socket: Some(path.clone()), ..Default::default() };
    let started = Instant::now();
    let result = session_events(
        &global,
        None,
        started + Duration::from_millis(60),
        Duration::from_millis(10),
        &mut |_| false,
    );
    let elapsed = started.elapsed();
    worker.join().unwrap();
    std::fs::remove_file(path).unwrap();
    assert!(result.is_ok(), "deadline must end the wait without a transport error: {result:?}");
    assert!(elapsed < Duration::from_millis(750), "hello overran event deadline: {elapsed:?}");
}
