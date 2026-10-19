//! The real credential relay selects the scoped Native hub, never the daemon's global hub.
mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport};
use cmux_cloud::api::HostRelay;
use cmux_cloud::link::{Attach, LinkPaths};
use cmux_cloud::{ControlPlane, Origin, Request, Server, WireCall, WireReply};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{self, BufRead, Cursor, Read, Write};
use std::sync::{Arc, Mutex};

const NATIVE: &str = "/tmp/native-team-a.sock";
const GLOBAL: &str = "/tmp/legacy-global.sock";

struct Parent {
    native: Option<Value>,
    wire: common::FakeControlPlane,
    answers: VecDeque<Vec<u8>>,
}
struct Input {
    parent: Arc<Mutex<Parent>>,
    current: Cursor<Vec<u8>>,
}
struct Output {
    parent: Arc<Mutex<Parent>>,
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
            self.current =
                Cursor::new(self.parent.lock().unwrap().answers.pop_front().unwrap_or_default());
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
            let mut parent = self.parent.lock().unwrap();
            let mut reply = match request["type"].as_str() {
                Some("relay.session") => {
                    let mut reply = json!({"type": "relay.session", "signed_in": true,
                        "team": "team_aaaaaaaaaaaaaaaaaaaa", "scope": "a".repeat(64)});
                    if let Some(native) = &parent.native {
                        reply["native_link"] = native.clone();
                    }
                    reply
                }
                Some("relay.op") => {
                    let call = WireCall {
                        op: request["op"].as_str().unwrap().into(),
                        params: request["params"].clone(),
                        idempotency_key: request["idempotency_key"].as_str().map(str::to_owned),
                        origin: None,
                    };
                    match parent.wire.call(&call).unwrap() {
                        WireReply::Result(value) => {
                            json!({"type": "relay.result", "ok": true, "value": value.value, "revision": value.revision})
                        }
                        WireReply::Error(error) => {
                            json!({"type": "relay.result", "ok": false, "error": {
                                "code": error.code, "message": error.message,
                                "retryable": error.retryable, "details": error.details}})
                        }
                    }
                }
                other => panic!("unexpected host request {other:?}"),
            };
            reply["id"] = request["id"].clone();
            let mut bytes = serde_json::to_vec(&reply).unwrap();
            bytes.push(b'\n');
            parent.answers.push_back(bytes);
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
type Relay = HostRelay<Input, Output>;

fn native(socket: Value) -> Value {
    json!({"version": 1, "scope": "a".repeat(64), "socket": socket})
}
fn server(route: Value) -> (Server<Relay>, Arc<Mutex<Parent>>, FakeSpawner) {
    let parent = Arc::new(Mutex::new(Parent {
        native: Some(route),
        wire: common::FakeControlPlane::with(&["vm-get"]),
        answers: VecDeque::new(),
    }));
    let relay = HostRelay::new(
        Input { parent: parent.clone(), current: Cursor::new(vec![]) },
        Output { parent: parent.clone(), pending: vec![] },
    );
    let spawner = FakeSpawner::default();
    let paths = LinkPaths {
        binary: "/opt/cmux/bin/cmux-tui".into(),
        hub_socket: GLOBAL.into(),
        state_dir: "/tmp/cmux-test/state".into(),
        socket_dir: "/tmp/cmux-test".into(),
        device_name: "test-mac".into(),
    };
    let attach =
        Attach::new(Box::new(spawner.clone()), Some(paths), Box::new(FakeTransport::default()))
            .with_env(attach_common::test_env());
    (Server::with_attach(relay, attach), parent, spawner)
}
fn connect(key: &str) -> Request {
    Request::new("cloud.machine.connect", json!({"machine": "vm-alpha01"}))
        .origin(Origin::User)
        .key(key)
}

#[test]
fn cloud_scope_native_hub_overrides_the_global_hub_and_cannot_downgrade() {
    let (mut server, parent, spawner) = server(native(json!(NATIVE)));
    server.handle(&connect("first")).unwrap();
    assert!(spawner.log().commands[0].args.windows(2).any(|a| a == ["--socket", NATIVE]));
    parent.lock().unwrap().native = None;
    server.handle(&Request::new("cloud.port.list", json!({}))).unwrap();
    assert_eq!(spawner.log().terminated.len(), 1, "a lost Native binding closes the old carrier");
    assert!(server.handle(&connect("after-downgrade")).is_err());
    assert_eq!(spawner.spawns(), 1, "never launch through the global fallback");
}

#[test]
fn cloud_scope_native_unavailable_never_falls_back_to_a_live_global_hub() {
    let (mut server, _, spawner) = server(native(Value::Null));
    assert!(server.handle(&connect("not-ready")).is_err());
    assert_eq!(spawner.spawns(), 0);
}

#[test]
fn cloud_scope_malformed_or_cross_scope_native_hubs_fail_before_backend_io() {
    let mut cross_scope = native(json!(NATIVE));
    cross_scope["scope"] = json!("b".repeat(64));
    let mut old_version = native(json!(NATIVE));
    old_version["version"] = json!(0);
    for route in [
        cross_scope,
        old_version,
        native(json!("relative.sock")),
        native(json!("/tmp/../foreign.sock")),
        native(json!("/tmp/bad\u{0}.sock")),
        native(json!(format!("/{}", "x".repeat(104)))),
    ] {
        let (mut server, parent, spawner) = server(route);
        assert!(server.handle(&connect("bad-route")).is_err());
        assert!(parent.lock().unwrap().wire.no_calls(), "invalid metadata reaches no owner op");
        assert_eq!(spawner.spawns(), 0);
    }
}
