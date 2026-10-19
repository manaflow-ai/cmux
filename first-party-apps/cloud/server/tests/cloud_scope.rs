//! The real host relay must gate cached results by the parent's current opaque scope.
use cmux_cloud::api::HostRelay;
use cmux_cloud::{Request, Server};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{self, BufRead, Cursor, Read, Write};
use std::sync::{Arc, Mutex};

struct Host {
    scope: String,
    calls: Vec<Value>,
    answers: VecDeque<Vec<u8>>,
}
struct Input {
    host: Arc<Mutex<Host>>,
    current: Cursor<Vec<u8>>,
}
struct Output {
    host: Arc<Mutex<Host>>,
    pending: Vec<u8>,
}
impl Read for Input {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let bytes = self.fill_buf()?;
        let n = bytes.len().min(out.len());
        out[..n].copy_from_slice(&bytes[..n]);
        self.consume(n);
        Ok(n)
    }
}
impl BufRead for Input {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        if self.current.position() as usize == self.current.get_ref().len() {
            let next = self.host.lock().unwrap().answers.pop_front().unwrap_or_default();
            self.current = Cursor::new(next);
        }
        self.current.fill_buf()
    }
    fn consume(&mut self, n: usize) {
        self.current.consume(n);
    }
}
impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(bytes);
        while let Some(end) = self.pending.iter().position(|b| *b == b'\n') {
            let raw: Vec<_> = self.pending.drain(..=end).collect();
            let request: Value = serde_json::from_slice(&raw).unwrap();
            let mut host = self.host.lock().unwrap();
            let reply = match request["type"].as_str() {
                Some("relay.session") => json!({"type": "relay.session", "id": request["id"],
                    "signed_in": true, "team": "team_aaaaaaaaaaaaaaaaaaaa", "scope": host.scope}),
                Some("relay.op") => {
                    host.calls.push(request.clone());
                    json!({"type": "relay.result", "id": request["id"], "ok": true, "value": {"deleted": true}})
                }
                other => panic!("unexpected host request {other:?}"),
            };
            let mut bytes = serde_json::to_vec(&reply).unwrap();
            bytes.push(b'\n');
            host.answers.push_back(bytes);
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn server() -> (Server<HostRelay<Input, Output>>, Arc<Mutex<Host>>) {
    let host = Arc::new(Mutex::new(Host {
        scope: "a".repeat(64),
        calls: vec![],
        answers: VecDeque::new(),
    }));
    let input = Input { host: host.clone(), current: Cursor::new(vec![]) };
    let output = Output { host: host.clone(), pending: vec![] };
    (Server::new(HostRelay::new(input, output)), host)
}
fn request(scope: &str) -> Request {
    // Deserialize the actual op line so the baseline compiles but demonstrates ignored metadata.
    serde_json::from_value(
        json!({"op": "cloud.snapshot.delete", "args": {"snapshot": "snap_s0000000000000000001"},
        "idempotency_key": "same-intent", "expected_scope": scope}),
    )
    .unwrap()
}

#[test]
fn cloud_scope_cached_mutations_cannot_cross_a_parent_selection_change() {
    let (mut server, host) = server();
    let first = request(&"a".repeat(64));
    assert_eq!(server.handle(&first).unwrap(), json!({"deleted": true}));
    assert_eq!(server.handle(&first).unwrap(), json!({"deleted": true}));
    assert_eq!(host.lock().unwrap().calls.len(), 1, "same-scope replay is still idempotent");
    host.lock().unwrap().scope = "b".repeat(64);
    let error =
        server.handle(&first).expect_err("a cached result must not bypass the new parent scope");
    assert_eq!(error.code, "credential.session_changed");
    assert_eq!(host.lock().unwrap().calls.len(), 1);
    assert_eq!(server.handle(&request(&"b".repeat(64))).unwrap(), json!({"deleted": true}));
    let host = host.lock().unwrap();
    assert_eq!(host.calls.len(), 2, "the new account/team must reach its own owner");
    assert_eq!(host.calls[0]["expected_scope"], "a".repeat(64));
    assert_eq!(host.calls[1]["expected_scope"], "b".repeat(64));
}

#[test]
fn cloud_scope_stale_operations_are_refused_before_relay_io() {
    let (mut server, host) = server();
    host.lock().unwrap().scope = "b".repeat(64);
    let error = server.handle(&request(&"a".repeat(64))).expect_err("stale request");
    assert_eq!(error.code, "credential.session_changed");
    assert!(host.lock().unwrap().calls.is_empty());
}
