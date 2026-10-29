//! REQUEST and CANCEL frames over a real socket pair, on a connection the
//! production lane serves after a real `set-client-info` granted frames:
//! a framed request gets the reply body its line gets, as a REPLY or ERROR
//! frame; a frame the method table refuses closes with `bad_message`; a
//! CANCEL ends a `wait-for`.

use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_ipc::{
    Aux, CallAux, CallFlags, FrameHeader, FrameKind, FrameReader, Message, MethodAttrs,
    MethodTables, PriorityHint, ReaderLimits,
};
use serde_json::{Value, json};

use super::{CallRefusal, METHOD_NOT_FRAMED, RequestFrames};
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd, serve_connection};
use crate::server::*;

/// What the daemon sent: a line, or a frame and its JSON payload.
#[derive(Debug)]
pub(in crate::server) enum Got {
    Line(Value),
    Frame(FrameHeader, Value),
}

pub(in crate::server) struct Client {
    pub(in crate::server) mux: Arc<Mux>,
    pub(in crate::server) socket: UnixStream,
    pub(in crate::server) read_half: UnixStream,
    pub(in crate::server) reader: FrameReader,
    served: JoinHandle<ConnectionEnd>,
}

pub(in crate::server) fn method(name: &str) -> &'static MethodAttrs {
    let tables = MethodTables::schema();
    tables.v12_id(name).and_then(|id| tables.method(id)).expect("a v12 method")
}

pub(in crate::server) fn call_frame(
    kind: FrameKind,
    request_id: u32,
    method_id: u16,
    priority: PriorityHint,
    body: &[u8],
) -> Vec<u8> {
    let aux = Aux::Call(CallAux { request_id, method_id, priority, flags: CallFlags::empty() });
    let header = FrameHeader::new(kind, 0, u32::try_from(body.len()).unwrap(), aux).unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(body);
    bytes
}

/// A REQUEST frame for `body`'s `cmd`, with its table priority.
pub(in crate::server) fn request(request_id: u32, body: &Value) -> Vec<u8> {
    let method = method(body["cmd"].as_str().unwrap());
    call_frame(
        FrameKind::Request,
        request_id,
        method.id.raw(),
        method.priority,
        body.to_string().as_bytes(),
    )
}

pub(in crate::server) fn cancel(request_id: u32, name: &str) -> Vec<u8> {
    let method = method(name);
    call_frame(FrameKind::Cancel, request_id, method.id.raw(), method.priority, b"")
}

impl Client {
    /// A same-user local peer whose `set-client-info` declared frames.
    fn granted(label: &str) -> Client {
        Client::granted_with(label, &[])
    }

    /// [`Client::granted`] that also declares `capabilities`.
    pub(in crate::server) fn granted_with(label: &str, capabilities: &[&str]) -> Client {
        Client::granted_with_frames(label, capabilities, RequestFrames::default)
    }

    /// [`Client::granted_with`] served by the lane `frames` makes.
    pub(in crate::server) fn granted_with_frames(
        label: &str,
        capabilities: &[&str],
        frames: impl FnOnce() -> RequestFrames + Send + 'static,
    ) -> Client {
        let mux =
            Mux::new_for_test(format!("frame-dispatch-{label}"), crate::SurfaceOptions::default());
        let (socket, server) = UnixStream::pair().unwrap();
        let served_mux = mux.clone();
        let served = std::thread::spawn(move || {
            let stream: Box<dyn transport::Stream> = Box::new(server);
            serve_connection(
                served_mux,
                stream,
                Arc::new(RenderService::new()),
                None,
                ClientTransport::Unix,
                Box::new(admission::LocalAdmission),
                Box::new(frames()),
            )
        });
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut reader = FrameReader::new(ReaderLimits::default());
        reader.negotiate_frames();
        let mut client = Client { mux, socket, read_half, reader, served };
        client.line(&json!({"id": 99, "cmd": "ping"}));
        assert!(matches!(client.next(), Some(Got::Line(reply)) if reply["id"] == json!(99)));
        let id = client.client_id();
        client.mux.control_clients.ipc_transports.bind_all_for_test();
        origin_gate::set_peer_process_for_test(
            &client.mux,
            id,
            crate::request_origin::PeerProcess::SameUser,
        );
        let (current, _) = api_revision_wire::identify_fields();
        client.line(&json!({
            "id": 1,
            "cmd": "set-client-info",
            "name": "frames",
            "capabilities": ([["ipc-frames-v2"].as_slice(), capabilities].concat()),
            "api_revision": current,
        }));
        match client.next() {
            Some(Got::Line(reply)) => assert_eq!(reply["ok"], json!(true), "{reply}"),
            other => panic!("set-client-info: {other:?}"),
        }
        client
    }

    /// The connection's client (a fresh test mux has no other Unix client).
    pub(in crate::server) fn client_id(&self) -> u64 {
        let state = self.mux.control_clients.state.lock().unwrap();
        let mut unix = state
            .clients
            .iter()
            .filter(|(_, record)| matches!(record.transport, ClientTransport::Unix))
            .map(|(client, _)| *client);
        let client = unix.next().expect("the connection's client");
        assert_eq!(unix.next(), None, "one Unix client");
        client
    }

    pub(in crate::server) fn line(&mut self, value: &Value) {
        self.socket.write_all(format!("{value}\n").as_bytes()).unwrap();
    }

    pub(in crate::server) fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    /// The next reply (events skipped); `None` once the daemon closed.
    pub(in crate::server) fn next(&mut self) -> Option<Got> {
        loop {
            match self.reader.next_message().unwrap() {
                Some(Message::Json(line)) if line.trim().is_empty() => {}
                Some(Message::Json(line)) => {
                    let value: Value = serde_json::from_str(line).unwrap();
                    let v2_item = value
                        .get("type")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| kind != "response");
                    if value.get("event").is_none() && !v2_item {
                        return Some(Got::Line(value));
                    }
                }
                Some(Message::Frame(frame)) => {
                    let value = serde_json::from_slice(frame.payload()).unwrap();
                    return Some(Got::Frame(*frame.header(), value));
                }
                None => {
                    if self.reader.read_from(&mut self.read_half).unwrap() == 0 {
                        return None;
                    }
                }
            }
        }
    }

    pub(in crate::server) fn line_reply(&mut self, body: &Value) -> Value {
        self.line(body);
        match self.next() {
            Some(Got::Line(reply)) => reply,
            other => panic!("expected a line reply to {body}: {other:?}"),
        }
    }

    pub(in crate::server) fn frame_reply(
        &mut self,
        request_id: u32,
        body: &Value,
    ) -> (FrameHeader, Value) {
        self.send(&request(request_id, body));
        match self.next() {
            Some(Got::Frame(header, reply)) => (header, reply),
            other => panic!("expected a frame reply to {body}: {other:?}"),
        }
    }

    pub(in crate::server) fn finish(self) -> ConnectionEnd {
        let _ = self.socket.shutdown(Shutdown::Write);
        self.served.join().unwrap()
    }

    /// The daemon closes at once, and says why. Only the ERROR of a request
    /// the close cancelled (a `wait-for` before the bad frame) may still
    /// arrive; the bad frame itself is never answered.
    fn closed_with(mut self, refusal: CallRefusal) {
        while let Some(got) = self.next() {
            assert!(
                matches!(&got, Got::Frame(header, _) if header.kind() == FrameKind::Error),
                "the daemon answered a bad message: {got:?}"
            );
        }
        assert_eq!(self.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::Call(refusal)));
    }
}

fn assert_answers(header: &FrameHeader, kind: FrameKind, request_id: u32, name: &str) {
    let method = method(name);
    assert_eq!(header.kind(), kind);
    assert_eq!(header.stream(), 0);
    let call = header.call().unwrap();
    assert_eq!(
        (call.request_id, call.method_id, call.priority, call.flags),
        (request_id, method.id.raw(), method.priority, CallFlags::empty())
    );
}

#[test]
fn frame_dispatch_replies_equal_the_line_replies() {
    let mut client = Client::granted("equal");
    let ok = json!({"id": 7, "cmd": "ping"});
    let line = client.line_reply(&ok);
    let (header, framed) = client.frame_reply(70, &ok);
    assert_answers(&header, FrameKind::Reply, 70, "ping");
    assert_eq!(framed, line);

    // An id-less request: the request id in the header is the only match.
    let bare = json!({"cmd": "ping"});
    let line = client.line_reply(&bare);
    let (header, framed) = client.frame_reply(71, &bare);
    assert_answers(&header, FrameKind::Reply, 71, "ping");
    assert_eq!(framed, line);

    // A failed command: the same error body, as an ERROR frame.
    let failing = json!({"id": 8, "cmd": "read-screen", "surface": 987_654});
    let line = client.line_reply(&failing);
    assert_eq!(line["ok"], json!(false), "{line}");
    let (header, framed) = client.frame_reply(80, &failing);
    assert_answers(&header, FrameKind::Error, 80, "read-screen");
    assert_eq!(framed, line);

    // Bad parameters fail like their line.
    let bad = json!({"id": 9, "cmd": "read-screen", "surface": "not-a-surface"});
    let line = client.line_reply(&bad);
    let (header, framed) = client.frame_reply(90, &bad);
    assert_answers(&header, FrameKind::Error, 90, "read-screen");
    assert_eq!(framed, line);

    // An answered id is free again.
    let (header, _) = client.frame_reply(70, &ok);
    assert_answers(&header, FrameKind::Reply, 70, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_a_feature_route_answers_method_not_framed() {
    let mut client = Client::granted("not-framed");
    let (header, reply) = client.frame_reply(5, &json!({"id": 5, "cmd": "apps-list"}));
    assert_answers(&header, FrameKind::Error, 5, "apps-list");
    assert_eq!(reply["error_code"], json!(METHOD_NOT_FRAMED), "{reply}");
    // The connection stays up.
    let (header, _) = client.frame_reply(6, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 6, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// `identify {revisions}` tells a connection offered frames what it may
/// frame: the schema its method table must come from and the methods
/// answered on frames, so it never learns one by a refusal, and every
/// listed method is answered on a frame.
#[test]
fn frame_dispatch_identify_lists_the_framed_methods_and_their_schema() {
    let mut client = Client::granted("identify");
    let reply = client.line_reply(&json!({"id": 2, "cmd": "identify", "revisions": true}));
    let identity = &reply["data"];
    let digest = format!("{:016x}", cmux_ipc::SCHEMA_IDENTITY.sdk_schema_digest);
    assert_eq!(identity["sdk_schema_digest"], json!(digest), "{identity}");
    let framed: Vec<u16> = serde_json::from_value(identity["framed_methods"].clone()).unwrap();
    assert!(framed.windows(2).all(|pair| pair[0] < pair[1]), "in id order: {framed:?}");
    let tables = MethodTables::schema();
    assert!(framed.iter().all(|id| tables.v12(cmux_ipc::MethodId::new(*id)).is_some()));
    assert!(framed.contains(&method("ping").id.raw()));
    assert!(framed.contains(&method("identify").id.raw()));
    assert!(!framed.contains(&method("apps-list").id.raw()), "a feature route answers lines");
    let (header, _) = client.frame_reply(3, &json!({"id": 3, "cmd": "identify"}));
    assert_answers(&header, FrameKind::Reply, 3, "identify");
    // Without `revisions` the reply keeps its shape.
    let plain = client.line_reply(&json!({"id": 4, "cmd": "identify"}));
    assert!(plain["data"].get("framed_methods").is_none(), "{plain}");
    assert!(plain["data"].get("sdk_schema_digest").is_none(), "{plain}");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// A connection that is not offered frames never reads the framed set.
#[test]
fn frame_dispatch_identify_without_the_offer_lists_no_framed_methods() {
    let mux = Mux::new_for_test("frame-dispatch-no-offer", crate::SurfaceOptions::default());
    let params = cmd_server::IdentifyParams { revisions: true, ..Default::default() };
    let identity = cmd_server::identify(&mux, 0, params).unwrap();
    assert!(identity.get("api_revision").is_some(), "{identity}");
    assert!(identity.get("framed_methods").is_none(), "{identity}");
    assert!(identity.get("sdk_schema_digest").is_none(), "{identity}");
}

#[test]
fn frame_dispatch_an_unknown_method_id_closes_with_bad_message() {
    let mut client = Client::granted("unknown");
    assert!(MethodTables::schema().method(cmux_ipc::MethodId::new(0x01FF)).is_none());
    client.send(&call_frame(FrameKind::Request, 1, 0x01FF, PriorityHint::Control, b"{}"));
    client.closed_with(CallRefusal::UnknownMethod { method_id: 0x01FF });
}

#[test]
fn frame_dispatch_a_priority_hint_off_the_table_closes_with_bad_message() {
    let mut client = Client::granted("priority");
    let ping = method("ping");
    assert_eq!(ping.priority, PriorityHint::Control);
    let body = json!({"cmd": "ping"}).to_string();
    client.send(&call_frame(
        FrameKind::Request,
        1,
        ping.id.raw(),
        PriorityHint::Bulk,
        body.as_bytes(),
    ));
    client.closed_with(CallRefusal::PriorityMismatch {
        method_id: ping.id.raw(),
        hint: PriorityHint::Bulk,
        table: PriorityHint::Control,
    });
}

#[test]
fn frame_dispatch_a_body_that_names_another_method_closes_with_bad_message() {
    let ping = method("ping");
    for (label, body) in [
        ("other-cmd", json!({"cmd": "identify"}).to_string()),
        ("no-cmd", json!({"id": 1}).to_string()),
        ("not-json", "ping".to_string()),
        (
            "v2-envelope",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "request",
                "id": "x",
                "operation": "workspace.create",
                "params": {},
            })
            .to_string(),
        ),
    ] {
        let mut client = Client::granted(label);
        client.send(&call_frame(
            FrameKind::Request,
            1,
            ping.id.raw(),
            ping.priority,
            body.as_bytes(),
        ));
        client.closed_with(CallRefusal::MethodMismatch { method_id: ping.id.raw() });
    }
}

#[test]
fn frame_dispatch_a_client_sent_reply_frame_closes_with_bad_message() {
    let mut client = Client::granted("reply-kind");
    let ping = method("ping");
    client.send(&call_frame(FrameKind::Reply, 1, ping.id.raw(), ping.priority, b"{}"));
    assert!(client.next().is_none());
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::UnroutedKind { kind: FrameKind::Reply })
    );
}

fn wait_for(client: &Client, timeout_ms: u64) -> Value {
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    json!({
        "cmd": "wait-for",
        "surface": surface.id,
        "pattern": "frame-dispatch-never-printed",
        "timeout_ms": timeout_ms,
    })
}

/// Waits runs that started (`wait-for` counts one in the watchdog's
/// `expected_waits` once it leaves the queue and runs).
fn waits_started(client: &Client) -> u64 {
    client.mux.request_watchdog.snapshot().expected_waits
}

/// Returns once `count` waits are running. From then on a CANCEL reaches the
/// handler: `wait_for` checks its cancellation before and while it waits.
fn wait_until_running(client: &Client, count: u64) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while waits_started(client) < count {
        assert!(Instant::now() < deadline, "the wait never started");
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn expect_error(client: &mut Client, request_id: u32, name: &str) -> Value {
    match client.next() {
        Some(Got::Frame(header, reply)) => {
            assert_answers(&header, FrameKind::Error, request_id, name);
            reply
        }
        other => panic!("expected the ERROR frame of request {request_id}: {other:?}"),
    }
}

#[test]
fn frame_dispatch_cancel_ends_wait_for() {
    let mut client = Client::granted("cancel");
    let wait = wait_for(&client, 60_000);
    let started = Instant::now();
    client.send(&request(3, &wait));
    wait_until_running(&client, 1);
    // A CANCEL of an id not in flight lost a race with its reply: dropped.
    client.send(&cancel(4, "wait-for"));
    client.send(&cancel(3, "wait-for"));
    let reply = expect_error(&mut client, 3, "wait-for");
    assert_eq!(reply["error"], json!("cancelled while waiting for pattern"), "{reply}");
    assert!(started.elapsed() < Duration::from_secs(30), "the wait ran to its timeout");
    // The connection's dispatcher is free again.
    let (header, _) = client.frame_reply(5, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 5, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_cancel_answers_a_queued_request_without_running_it() {
    let mut client = Client::granted("cancel-queued");
    let running = wait_for(&client, 60_000);
    client.send(&request(3, &running));
    wait_until_running(&client, 1);
    // Both queue behind the running wait on the connection's dispatcher.
    let queued = wait_for(&client, 60_000);
    client.send(&request(4, &queued));
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    client.send(&request(5, &json!({"cmd": "clear-history", "surface": surface.id})));
    client.send(&cancel(4, "wait-for"));
    client.send(&cancel(5, "clear-history"));
    client.send(&cancel(3, "wait-for"));
    let reply = expect_error(&mut client, 3, "wait-for");
    assert_eq!(reply["error"], json!("cancelled while waiting for pattern"), "{reply}");
    let reply = expect_error(&mut client, 4, "wait-for");
    assert_eq!(reply["error"], json!("request cancelled"), "{reply}");
    assert_eq!(reply.get("error_delivery"), None, "{reply}");
    // A clear that never ran is known not delivered, as every other refusal
    // of a clear-history says.
    let reply = expect_error(&mut client, 5, "clear-history");
    assert_eq!(reply["error"], json!("request cancelled"), "{reply}");
    assert_eq!(reply["error_delivery"], json!("known-not-delivered"), "{reply}");
    // The queued wait never ran: only the first one started.
    assert_eq!(waits_started(&client), 1);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// The IPC-5 bench fixture (bench-daemon-latency.py `OpsFixture`): a
/// workspace with one pane, tabs T0..T5 and tab group G holding T1.
struct BenchFixture {
    workspace: Value,
    workspace_rid: Value,
    pane: Value,
    pane_rid: Value,
    tabs: Vec<Value>,
    group: Value,
    keys: u32,
}

fn ok_data(reply: Value, what: &str) -> Value {
    assert_eq!(reply["ok"], json!(true), "{what}: {reply}");
    reply.get("data").or_else(|| reply.get("result")).cloned().unwrap_or(Value::Null)
}

/// Every `surface` member of a `list-workspaces` subtree.
fn holds_surface(node: &Value, surface: &Value) -> bool {
    match node {
        Value::Object(map) => map.iter().any(|(key, value)| {
            (key == "surface" && value == surface) || holds_surface(value, surface)
        }),
        Value::Array(items) => items.iter().any(|item| holds_surface(item, surface)),
        _ => false,
    }
}

impl BenchFixture {
    fn new(client: &mut Client) -> BenchFixture {
        let mut call = |body: Value| ok_data(client.line_reply(&body), &body.to_string());
        let first =
            call(json!({"cmd": "new-workspace", "name": "bench-ops", "cols": 80, "rows": 24}));
        let tree = call(json!({"cmd": "list-workspaces"}));
        let (workspace, pane) = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| {
                workspace["screens"].as_array().into_iter().flatten().flat_map(move |screen| {
                    screen["panes"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(move |pane| (workspace, pane))
                })
            })
            .find(|(_, pane)| holds_surface(pane, &first["surface"]))
            .map(|(workspace, pane)| (workspace.clone(), pane.clone()))
            .expect("the new workspace's pane");
        let mut tabs = vec![first["surface"].clone()];
        for _ in 0..5 {
            let tab = call(json!({"cmd": "new-tab", "pane": pane["id"], "cols": 80, "rows": 24}));
            tabs.push(tab["surface"].clone());
        }
        let group =
            call(json!({"cmd": "create-tab-group", "surfaces": [tabs[1]], "name": "bench-g"}));
        BenchFixture {
            workspace: workspace["id"].clone(),
            workspace_rid: workspace["resource_id"].clone(),
            pane: pane["id"].clone(),
            pane_rid: pane["resource_id"].clone(),
            tabs,
            group: group["group"]["id"].clone(),
            keys: 0,
        }
    }

    fn key(&mut self) -> String {
        self.keys += 1;
        format!("frame-dispatch-bench-{}", self.keys)
    }

    fn call(client: &mut Client, body: Value) -> Value {
        ok_data(client.line_reply(&body), &body.to_string())
    }

    fn v2(&mut self, client: &mut Client, operation: &str, params: Value) -> Value {
        let body = v2_envelope("cleanup", operation, params, Some(self.key()));
        ok_data(client.line_reply(&body), operation)
    }

    fn new_tab(&self, client: &mut Client) -> Value {
        let body = json!({"cmd": "new-tab", "pane": self.pane, "cols": 80, "rows": 24});
        Self::call(client, body)["surface"].clone()
    }

    /// The request of bench op `name`, after the state it needs.
    fn before(&mut self, client: &mut Client, name: &str, round: usize) -> Value {
        let odd = round % 2 == 1;
        let id = json!(format!("bench-{name}"));
        let v12 = |cmd: &str, params: Value| {
            let mut body = params;
            body["id"] = id.clone();
            body["cmd"] = json!(cmd);
            body
        };
        let (ws, ws_rid, pane, pane_rid) =
            (&self.workspace, &self.workspace_rid, &self.pane, &self.pane_rid);
        match name {
            "ping" | "identify" | "list-workspaces" => v12(name, json!({})),
            "send" => v12(name, json!({"surface": self.tabs[0], "text": ":\r"})),
            "new-tab" => v12(name, json!({"pane": pane, "cols": 80, "rows": 24})),
            "create-terminal" => {
                v12(name, json!({"workspace": ws, "argv": ["/bin/sh"], "cols": 80, "rows": 24}))
            }
            "split" => v12(name, json!({"pane": pane, "dir": "right", "cols": 80, "rows": 24})),
            "close-surface" => {
                let tab = self.new_tab(client);
                v12(name, json!({"surface": tab}))
            }
            "close-tabs" => {
                let tab = self.new_tab(client);
                v12(name, json!({"surfaces": [tab], "end_terminals": true}))
            }
            "rename-workspace" => {
                v12(name, json!({"workspace": ws, "name": format!("bench-ops-{}", round % 2)}))
            }
            "select-tab" => v12(name, json!({"pane": pane, "index": round % 2})),
            "select-workspace" => v12(name, json!({"index": round % 2})),
            "move-tab" => {
                let index = if odd { 0 } else { 99 };
                v12(name, json!({"surface": self.tabs[5], "pane": pane, "index": index}))
            }
            "new-frontend-browser-tab" => {
                v12(name, json!({"url": "about:blank", "engine": "webkit", "pane": pane}))
            }
            "create-tab-group" => {
                v12(name, json!({"surfaces": [self.tabs[3], self.tabs[4]], "name": "bench-new"}))
            }
            "update-tab-group" => {
                v12(name, json!({"group": self.group, "name": format!("bench-g{}", round % 2)}))
            }
            "add-tabs-to-tab-group" => {
                v12(name, json!({"group": self.group, "surfaces": [self.tabs[2]]}))
            }
            "remove-tabs-from-tab-group" => {
                let add = json!({"cmd": "add-tabs-to-tab-group", "group": self.group, "surfaces": [self.tabs[2]]});
                Self::call(client, add);
                v12(name, json!({"surfaces": [self.tabs[2]]}))
            }
            "move-tab-group" => {
                v12(name, json!({"group": self.group, "index": if odd { 99 } else { 0 }}))
            }
            "ungroup-tab-group" | "close-tab-group" => {
                let surfaces = if name == "close-tab-group" {
                    vec![self.new_tab(client), self.new_tab(client)]
                } else {
                    vec![self.tabs[3].clone(), self.tabs[4].clone()]
                };
                let create =
                    json!({"cmd": "create-tab-group", "surfaces": surfaces, "name": "bench-new"});
                let group = Self::call(client, create)["group"]["id"].clone();
                let mut params = json!({"group": group});
                if name == "close-tab-group" {
                    params["end_terminals"] = json!(true);
                }
                v12(name, params)
            }
            "workspace.create" => {
                let params = json!({"initial_content": "terminal", "name": "bench-v2"});
                v2_envelope("bench", name, params, Some(self.key()))
            }
            "tab.create_terminal" => {
                let params = json!({"workspace": ws_rid, "pane": pane_rid, "cols": 80, "rows": 24});
                v2_envelope("bench", name, params, Some(self.key()))
            }
            "pane.split" => {
                let params = json!({
                    "workspace": ws_rid, "pane": pane_rid, "direction": "right",
                    "cols": 80, "rows": 24,
                });
                v2_envelope("bench", name, params, Some(self.key()))
            }
            "pane.create" => {
                let params = json!({"workspace": ws_rid, "cols": 80, "rows": 24});
                v2_envelope("bench", name, params, Some(self.key()))
            }
            "workspace.ensure_home" => v2_envelope("bench", name, json!({}), Some(self.key())),
            other => panic!("no fixture for bench op {other}: add it with the bench's op"),
        }
    }

    /// Undoes what bench op `name` made, as the bench does.
    fn after(&mut self, client: &mut Client, name: &str, reply: &Value) {
        if reply["ok"] != json!(true) {
            return;
        }
        let data = reply.get("data").or_else(|| reply.get("result")).unwrap_or(&Value::Null);
        match name {
            "new-tab" | "create-terminal" | "split" | "new-frontend-browser-tab" => {
                Self::call(client, json!({"cmd": "close-surface", "surface": data["surface"]}));
            }
            "create-tab-group" => {
                let group = &data["group"]["id"];
                Self::call(client, json!({"cmd": "ungroup-tab-group", "group": group}));
            }
            "add-tabs-to-tab-group" => {
                let remove =
                    json!({"cmd": "remove-tabs-from-tab-group", "surfaces": [self.tabs[2]]});
                Self::call(client, remove);
            }
            "workspace.create" => {
                let workspace = data["value"]["workspace_id"].clone();
                self.v2(client, "workspace.close", json!({"workspace": workspace}));
            }
            "tab.create_terminal" => {
                let tab = data["value"]["tab_id"].clone();
                self.v2(client, "tab.close", json!({"tab": tab}));
            }
            "pane.split" | "pane.create" => {
                let pane = data["value"]["pane_id"].clone();
                self.v2(client, "pane.close", json!({"pane": pane}));
            }
            _ => {}
        }
    }
}

fn v2_envelope(id: &str, operation: &str, params: Value, key: Option<String>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    envelope
}

/// The method of `body` in this build's table: a v12 line's `cmd`, or a v2
/// envelope's `operation`. None for a v2 operation while
/// spec/resource-operations-v2.json has no method families.
fn table_method(body: &Value) -> Option<&'static MethodAttrs> {
    let tables = MethodTables::schema();
    let id = match body["operation"].as_str() {
        Some(operation) => tables.v2_id(operation),
        None => tables.v12_id(body["cmd"].as_str().unwrap()),
    };
    id.and_then(|id| tables.method(id))
}

/// The reply to `body` sent as a REQUEST frame over the socket.
fn socket_frame_reply(
    client: &mut Client,
    request_id: u32,
    method: &MethodAttrs,
    body: &Value,
) -> (FrameHeader, Value) {
    let bytes = body.to_string();
    let frame = call_frame(
        FrameKind::Request,
        request_id,
        method.id.raw(),
        method.priority,
        bytes.as_bytes(),
    );
    client.send(&frame);
    match client.next() {
        Some(Got::Frame(header, reply)) => (header, reply),
        other => panic!("expected a frame reply to {body}: {other:?}"),
    }
}

/// The reply `handle_framed_request_at` gives `body` as a REQUEST of v2
/// `operation`, on the connection's client, through a writer of its own:
/// the route a frame of the operation takes once the schema gives it an id.
fn routed_frame_reply(
    client: &Client,
    request_id: u32,
    operation: ResourceOperation,
    body: &Value,
) -> (FrameHeader, Value) {
    let (socket, _peer) = UnixStream::pair().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let sink = QueuedSink {
        outbound: outbound.clone(),
        control: Some(SinkControl::Unix(Box::new(socket))),
    };
    let call = CallAux {
        request_id,
        method_id: 0x6000,
        priority: PriorityHint::Control,
        flags: CallFlags::empty(),
    };
    let writer = MessageWriter::new(sink).replying_to(Arc::new(super::FrameCall::new(0, call)));
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(client.mux.surface_operation_admission.clone()));
    let text = body.to_string();
    let request = decode_framed_request(&text, FramedMethod::Resource(operation))
        .unwrap_or_else(|FramedBodyMismatch| panic!("{body} is not a {operation:?} request"));
    let keep_open = handle_framed_request_at(
        &client.mux,
        client.client_id(),
        ClientTransport::Unix,
        &text,
        request,
        &writer,
        &scheduler,
        Instant::now(),
    );
    assert!(keep_open, "{body}");
    loop {
        match outbound.recv() {
            // A long reply leaves in chunks; each holds the whole payload.
            Some(OutboundItem::Frame(header, text) | OutboundItem::Chunk { header, text, .. }) => {
                return (header, serde_json::from_str(&text).unwrap());
            }
            Some(OutboundItem::Text(_)) => {}
            Some(OutboundItem::Flush(_)) | None => panic!("no frame reply to {body}"),
        }
    }
}

/// A reply with every id, name and count it made replaced by its type: two
/// runs of a create make different ids, never a different reply.
fn shape(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            Value::Object(map.iter().map(|(key, value)| (key.clone(), shape(value))).collect())
        }
        Value::Array(items) => Value::Array(items.iter().take(1).map(shape).collect()),
        Value::String(_) => json!("string"),
        Value::Number(_) => json!("number"),
        other => other.clone(),
    }
}

/// IPC-5's acceptance: every bench op answers a REQUEST frame with the reply
/// its line gets (ipc-targets.json `ipc5_ops`, bench-daemon-latency.py). A
/// v2 operation the schema has no method id for yet takes the frame route
/// in process, past the header check only a method id can pass.
#[test]
fn frame_dispatch_bench_ops_equal_as_lines_and_frames() {
    let targets = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../plans/cmux-next/ipc-targets.json");
    let targets: Value = serde_json::from_str(&std::fs::read_to_string(targets).unwrap()).unwrap();
    let ops: Vec<String> = serde_json::from_value(targets["ipc5_ops"].clone()).unwrap();
    assert!(ops.len() >= 26, "{ops:?}");
    let mut client = Client::granted("bench-ops");
    let mut fixture = BenchFixture::new(&mut client);
    for (index, name) in ops.iter().enumerate() {
        // Round 0 sets the state rounds 1 (a line) and 2 (a frame) both
        // change, as the bench alternates its writes.
        let body = fixture.before(&mut client, name, 0);
        let primed = client.line_reply(&body);
        fixture.after(&mut client, name, &primed);
        let body = fixture.before(&mut client, name, 1);
        let line = client.line_reply(&body);
        fixture.after(&mut client, name, &line);
        let body = fixture.before(&mut client, name, 2);
        let request_id = 1000 + u32::try_from(index).unwrap();
        let (header, framed) = match table_method(&body) {
            Some(method) => socket_frame_reply(&mut client, request_id, method, &body),
            None => {
                let operation = ResourceOperation::ALL
                    .iter()
                    .copied()
                    .find(|operation| operation.wire_name() == name)
                    .unwrap_or_else(|| panic!("{name} is in no method table"));
                routed_frame_reply(&client, request_id, operation, &body)
            }
        };
        let kind = if framed["ok"] == json!(false) { FrameKind::Error } else { FrameKind::Reply };
        assert_eq!(header.kind(), kind, "{name}: {framed}");
        assert_eq!(header.call().map(|call| call.request_id), Some(request_id), "{name}");
        fixture.after(&mut client, name, &framed);
        assert_ne!(framed["error_code"], json!(METHOD_NOT_FRAMED), "{name} is not framed");
        assert_eq!(line["ok"], json!(true), "{name} fails as a line: {line}");
        assert_eq!(framed["ok"], line["ok"], "{name}: line {line}, frame {framed}");
        assert_eq!(framed["id"], line["id"], "{name}");
        assert_eq!(framed["error"], line["error"], "{name}: line {line}, frame {framed}");
        assert_eq!(shape(&framed), shape(&line), "{name}: line {line}, frame {framed}");
        if matches!(name.as_str(), "ping" | "list-workspaces") {
            assert_eq!(framed, line, "{name}");
        }
    }
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_an_id_in_flight_closes_with_bad_message() {
    let mut client = Client::granted("duplicate");
    let wait = wait_for(&client, 60_000);
    client.send(&request(3, &wait));
    client.send(&request(3, &json!({"cmd": "ping"})));
    // The close cancels the wait, so the connection ends promptly.
    client.closed_with(CallRefusal::DuplicateRequest { request_id: 3 });
}

#[test]
fn frame_dispatch_a_cancel_must_name_its_request_method() {
    let mut client = Client::granted("cancel-mismatch");
    let wait = wait_for(&client, 60_000);
    client.send(&request(3, &wait));
    client.send(&cancel(3, "ping"));
    client.closed_with(CallRefusal::CancelMismatch {
        request_id: 3,
        method_id: method("ping").id.raw(),
    });

    let mut client = Client::granted("cancel-payload");
    let ping = method("ping");
    client.send(&call_frame(FrameKind::Cancel, 3, ping.id.raw(), ping.priority, b"{}"));
    client.closed_with(CallRefusal::CancelPayload { request_id: 3 });
}

/// While a daemon handoff is pending, a framed request is refused unexecuted
/// with its line's body (the same `daemon_shutdown_pending` code) as an
/// ERROR frame (a body with bad parameters gets its line's bad request); it
/// never runs, and the connection stays up.
#[test]
fn frame_dispatch_pending_handoff_refuses_with_the_line_error() {
    let mut client = Client::granted("pending-handoff");
    let mux = client.mux.clone();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.mark_server_lifecycle_ready();
    mux.begin_daemon_handoff(client.client_id(), DaemonHandoffRequest::unfenced(false)).unwrap();

    let workspaces = mux.with_state(|state| state.workspaces.len());
    for (request_id, body, name) in [
        (1, json!({"id": 7, "cmd": "new-workspace", "name": "must-not-exist"}), "new-workspace"),
        (2, json!({"cmd": "ping"}), "ping"),
        (3, json!({"id": "c", "cmd": "clear-history", "surface": surface.id}), "clear-history"),
    ] {
        let line = client.line_reply(&body);
        assert_eq!(line["error_code"], json!(DAEMON_SHUTDOWN_PENDING_CODE), "{line}");
        let (header, framed) = client.frame_reply(request_id, &body);
        assert_answers(&header, FrameKind::Error, request_id, name);
        assert_eq!(framed, line);
    }
    assert_eq!(
        client.line_reply(&json!({"id": 4, "cmd": "clear-history", "surface": surface.id}))["error_delivery"],
        json!("known-not-delivered")
    );
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspaces);

    // Bad parameters fail like their line: a bad request, not a refusal to
    // retry after the handoff.
    let bad = json!({"id": 9, "cmd": "read-screen", "surface": "not-a-surface"});
    let line = client.line_reply(&bad);
    assert_ne!(line["error_code"], json!(DAEMON_SHUTDOWN_PENDING_CODE), "{line}");
    let (header, framed) = client.frame_reply(9, &bad);
    assert_answers(&header, FrameKind::Error, 9, "read-screen");
    assert_eq!(framed, line);

    // The body's one decode as its method's request and the refusal's
    // `Request` parse, per frame (no resource-envelope probe); the bad
    // request's failed decode also reads its head (to check it names the
    // header's method) and its `id`.
    let parses = mux.ipc_stats().snapshot().parses.frames;
    assert_eq!((parses.requests, parses.json_parses), (4, 10), "{parses:?}");

    // A failed handoff leaves the connection serving frames.
    mux.cancel_daemon_handoff(client.client_id());
    let (header, reply) = client.frame_reply(10, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 10, "ping");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// A client that declared another revision than this daemon's is granted no
/// frames: its REQUEST frame closes the connection before any parse, and its
/// lines are served.
#[test]
fn api_revision_frames_are_not_granted_at_another_revision() {
    let mut client = Client::granted("other-revision");
    let (current, _) = api_revision_wire::identify_fields();
    let reply = client.line_reply(&json!({
        "id": 2,
        "cmd": "set-client-info",
        "name": "frames",
        "capabilities": ["ipc-frames-v2"],
        "api_revision": current + 1,
    }));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let id = client.client_id();
    assert!(!client.mux.control_clients.supports_capability(id, "ipc-frames-v2"));
    assert_eq!(client.line_reply(&json!({"id": 3, "cmd": "ping"}))["ok"], json!(true));

    client.send(&request(4, &json!({"cmd": "ping"})));
    assert!(client.next().is_none(), "the daemon answered an ungranted frame");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
            cmux_ipc::BadMessage::FramesNotNegotiated
        ))
    );
}

/// `server-stats` `ipc` counts a framed connection like a line one: the
/// REQUEST frames that arrived and the REPLY frames sent, by kind, the
/// framed requests and their parses, and a refused frame as a bad message.
#[test]
fn frame_dispatch_ipc_counts_frames_their_parses_and_bad_frames() {
    let mut client = Client::granted("ipc");
    let mux = client.mux.clone();
    let ping = json!({"cmd": "ping"});
    let request_bytes = request(1, &ping).len();
    for request_id in [1, 2] {
        let (header, _) = client.frame_reply(request_id, &ping);
        assert_answers(&header, FrameKind::Reply, request_id, "ping");
    }
    let full = client.line_reply(&json!({"id": 3, "cmd": "server-stats", "include": ["ipc"]}));
    let ipc = &full["data"]["ipc"];
    let row = |direction: &str, kind: &str| {
        ipc[direction]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["kind"] == kind).cloned())
            .unwrap_or_else(|| panic!("no {kind} row in {direction}: {ipc}"))
    };
    let received = row("received", "request");
    assert_eq!(received["messages"], json!(2), "{ipc}");
    assert_eq!(received["bytes"], json!(2 * request_bytes), "{ipc}");
    let sent = row("sent", "reply");
    assert_eq!(sent["messages"], json!(2), "{ipc}");
    assert!(sent["bytes"].as_u64().unwrap() > 2 * 16, "header and payload: {ipc}");
    let frames = &ipc["parses"]["frames"];
    assert_eq!(frames["requests"], json!(2), "{ipc}");
    assert_eq!(
        frames["json_parses"],
        json!(2),
        "a framed request's body is decoded once, as its method's request: {ipc}"
    );
    assert_eq!(ipc["bad_message"], json!(0), "{ipc}");

    client.send(&call_frame(FrameKind::Request, 4, 0x01FF, PriorityHint::Control, b"{}"));
    client.closed_with(CallRefusal::UnknownMethod { method_id: 0x01FF });
    let ipc = mux.ipc_stats().snapshot();
    assert_eq!(ipc.bad_message, 1);
    assert_eq!(ipc.streams.open, 0);
}
