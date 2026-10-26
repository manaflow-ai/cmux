//! The framed IPC grant rules (p05-ipc-060; spec/transports.md "Framed IPC
//! grants"): what `identify` advertises and what `set-client-info` grants to a
//! local, bridged, WebSocket, remote-entry and page-relay connection, and to a
//! client one API revision behind. Every request takes the connection's real
//! frame path (`handle_connection_frame`), the remote relay's gate included.

use cmux_api_compat::{Change, Compat, MessageChange, Schema};

use super::super::api_revision_wire::NegotiatedRevision;
use super::*;
use crate::request_origin::HelloRole;

const ALL: [&str; 4] =
    ["ipc-frames-v2", "attach-streams-v1", "attach-frames-v1", "terminal-output-ring-v1"];

/// A history whose current revision is 13, so revision 12 is one behind
/// and translated.
fn history() -> &'static Compat {
    let mut schema = Schema::new("cmux-mux", 12);
    schema.push(
        "test rename",
        vec![MessageChange {
            message: "request:rename-tab".into(),
            change: Change::Rename { path: "/title".into(), to: "name".into() },
        }],
    );
    Box::leak(Box::new(Compat::new(schema).unwrap()))
}

struct Connection {
    mux: Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Connection {
    fn open(mux: &Arc<Mux>, transport: ClientTransport) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let mut writer =
            MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        writer.api_revision = Arc::new(NegotiatedRevision::with_compat(history()));
        let client = mux.control_clients.register(transport, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux: mux.clone(), client, transport, writer, outbound, scheduler }
    }

    fn request(&self, frame: Value) -> Value {
        let line = frame.to_string();
        assert!(handle_connection_frame(
            &self.mux,
            self.client,
            self.transport,
            &line,
            &self.writer,
            &self.scheduler
        ));
        // The scheduler may answer on a worker: wait for that reply.
        loop {
            match self.outbound.recv() {
                Some(OutboundItem::Text(text)) => {
                    return serde_json::from_str(&text.to_string()).unwrap();
                }
                Some(OutboundItem::Flush(flushed)) => drop(flushed.send(())),
                None => panic!("the connection closed without a reply"),
            }
        }
    }

    fn advertised(&self) -> Vec<String> {
        let reply = self.request(json!({"id":1,"cmd":"identify"}));
        assert_eq!(reply["ok"], true, "{reply}");
        let capabilities = reply["data"]["capabilities"].as_array().unwrap();
        ALL.iter()
            .filter(|name| capabilities.iter().any(|value| value == **name))
            .map(|name| (*name).to_string())
            .collect()
    }

    /// Echoes all four at `revision` and returns the reply.
    fn ask(&self, revision: u32) -> Value {
        self.request(json!({"id":2,"cmd":"set-client-info","capabilities":ALL,
                            "api_revision":revision}))
    }

    fn granted(&self) -> Vec<&'static str> {
        ALL.into_iter()
            .filter(|name| self.mux.control_clients.supports_capability(self.client, name))
            .collect()
    }
}

fn mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

#[test]
fn ipc_grant_local_unix_at_the_current_revision_gets_all_four() {
    let mux = mux("ipc-grant-local");
    let local = Connection::open(&mux, ClientTransport::Unix);
    assert_eq!(local.advertised(), ALL);
    assert_eq!(local.ask(13)["ok"], true);
    assert_eq!(local.granted(), ALL);
    mux.shutdown();
}

#[test]
fn ipc_grant_one_revision_behind_gets_streams_only() {
    let mux = mux("ipc-grant-n-1");
    let older = Connection::open(&mux, ClientTransport::Unix);
    assert_eq!(older.advertised(), ALL, "identify comes before the revision");
    assert_eq!(older.ask(12)["ok"], true);
    assert_eq!(older.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_needs_a_declared_revision() {
    let mux = mux("ipc-grant-undeclared");
    let silent = Connection::open(&mux, ClientTransport::Unix);
    let reply = silent.request(json!({"id":2,"cmd":"set-client-info","capabilities":ALL}));
    assert_eq!(reply["ok"], true);
    assert_eq!(silent.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_bridged_lane_gets_streams_only() {
    let mux = mux("ipc-grant-bridged");
    let lane = Connection::open(&mux, ClientTransport::Unix);
    mux.control_clients
        .state
        .lock()
        .unwrap()
        .clients
        .get_mut(&lane.client)
        .unwrap()
        .origin
        .mobile_host = true;
    assert_eq!(lane.advertised(), ["attach-streams-v1"]);
    assert_eq!(lane.ask(13)["ok"], true);
    assert_eq!(lane.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_websocket_gets_none() {
    let mux = mux("ipc-grant-websocket");
    let web = Connection::open(&mux, ClientTransport::WebSocket);
    assert!(web.advertised().is_empty());
    assert_eq!(web.ask(13)["ok"], true, "unknown capabilities are ignored, not refused");
    assert!(web.granted().is_empty());
    mux.shutdown();
}

#[test]
fn ipc_grant_remote_entry_gets_none() {
    let mux = mux("ipc-grant-remote");
    let remote = Connection::open(&mux, ClientTransport::Remote);
    assert!(remote.advertised().is_empty());
    let reply = remote
        .request(json!({"id":2,"cmd":"set-client-info","capabilities":["attach-streams-v1"]}));
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(remote.granted().is_empty());
    mux.shutdown();
}

#[test]
fn ipc_grant_page_relay_gets_none_and_a_later_page_hello_ends_a_grant() {
    let mux = mux("ipc-grant-page");
    let page = Connection::open(&mux, ClientTransport::Unix);
    assert!(origin_gate::set_hello(&mux, page.client, HelloRole::PageRelay, None, false, None));
    assert!(page.advertised().is_empty());
    assert_eq!(page.ask(13)["ok"], true);
    assert!(page.granted().is_empty());

    let late = Connection::open(&mux, ClientTransport::Unix);
    assert_eq!(late.ask(13)["ok"], true);
    assert_eq!(late.granted(), ALL);
    assert!(origin_gate::set_hello(&mux, late.client, HelloRole::PageRelay, None, false, None));
    assert!(late.granted().is_empty());
    mux.shutdown();
}

#[test]
fn ipc_grant_a_later_older_revision_ends_the_frame_grants() {
    let mux = mux("ipc-grant-downgrade");
    let local = Connection::open(&mux, ClientTransport::Unix);
    assert_eq!(local.ask(13)["ok"], true);
    assert_eq!(local.granted(), ALL);
    let reply = local.request(json!({"id":3,"cmd":"set-client-info","api_revision":12}));
    assert_eq!(reply["ok"], true);
    assert_eq!(local.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_needs_what_each_capability_requires() {
    let mux = mux("ipc-grant-requires");
    let local = Connection::open(&mux, ClientTransport::Unix);
    let reply = local.request(json!({"id":2,"cmd":"set-client-info",
        "capabilities":["attach-frames-v1","terminal-output-ring-v1"],"api_revision":13}));
    assert_eq!(reply["ok"], true);
    assert!(local.granted().is_empty(), "frames on a stream need ipc-frames-v2 and streams");
    let reply = local.request(json!({"id":3,"cmd":"set-client-info",
        "capabilities":["ipc-frames-v2","attach-streams-v1","attach-frames-v1"]}));
    assert_eq!(reply["ok"], true);
    assert_eq!(local.granted(), &ALL[..3], "an earlier grant counts; the ring was not asked again");
    mux.shutdown();
}

#[test]
fn ipc_grant_rule_table() {
    use IpcCapability::{AttachFrames, AttachStreams, Frames, OutputRing};
    for peer in [IpcPeer::WebSocket, IpcPeer::RemoteEntry, IpcPeer::PageRelay] {
        assert!(IpcCapability::offered(peer).is_empty(), "{peer:?}");
    }
    assert_eq!(
        IpcCapability::offered(IpcPeer::Local),
        [Frames, AttachStreams, AttachFrames, OutputRing]
    );
    assert_eq!(IpcCapability::offered(IpcPeer::Bridged), [AttachStreams]);
    assert!(AttachStreams.allowed(IpcPeer::Local, false));
    assert!(!Frames.allowed(IpcPeer::Local, false));
    assert!(!OutputRing.allowed(IpcPeer::Bridged, true));
    for capability in IpcCapability::ALL {
        assert_eq!(IpcCapability::named(capability.name()), Some(capability));
    }
}
