use super::*;

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
