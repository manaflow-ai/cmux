//! The framed IPC grant rules (spec/transports.md "Framed IPC
//! grants"): what `identify` advertises and what `set-client-info` grants to a
//! local, bridged, unverified, WebSocket, remote-entry and page-relay
//! connection, and to a client one API revision behind. Every request takes
//! the connection's real frame path (`handle_connection_frame`), the remote
//! relay's gate included. Tests other than the bound-transports one bind
//! every transport, as the tasks that land them will.

use cmux_api_compat::{Change, Compat, MessageChange, Schema};

use super::super::api_revision_wire::NegotiatedRevision;
use super::*;
use crate::request_origin::{HelloRole, PeerProcess};

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
    /// A connection whose accept found `peer` (what `set_peer_identity_at_accept`
    /// records for a Unix peer).
    fn open(mux: &Arc<Mux>, transport: ClientTransport, peer: PeerProcess) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let mut writer =
            MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        writer.api_revision = Arc::new(NegotiatedRevision::with_compat(history()));
        let client = mux.control_clients.register(transport, writer.clone());
        origin_gate::set_peer_process_for_test(mux, client, peer);
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux: mux.clone(), client, transport, writer, outbound, scheduler }
    }

    /// A direct same-user process on the Unix socket.
    fn local(mux: &Arc<Mux>) -> Self {
        Self::open(mux, ClientTransport::Unix, PeerProcess::SameUser)
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
                Some(
                    OutboundItem::Text(text)
                    | OutboundItem::Frame(_, text)
                    | OutboundItem::Chunk { text, .. },
                ) => {
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

    /// What the registry keeps for this connection, rule or not.
    fn recorded(&self) -> Vec<&'static str> {
        let state = self.mux.control_clients.state.lock().unwrap();
        let record = state.clients.get(&self.client).unwrap();
        ALL.into_iter().filter(|name| record.capabilities.contains(*name)).collect()
    }
}

/// A daemon with every framed IPC transport bound.
fn mux(name: &str) -> Arc<Mux> {
    let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
    mux.control_clients.ipc_transports.bind_all_for_test();
    mux
}

#[test]
fn ipc_grant_unbound_transports_are_never_advertised_or_granted() {
    let mux = Mux::new_for_test("ipc-grant-unbound", crate::SurfaceOptions::default());
    let local = Connection::local(&mux);
    // The stream table is bound; no frame reader or ring yet.
    assert_eq!(local.advertised(), ["attach-streams-v1"]);
    assert_eq!(local.ask(13)["ok"], true);
    assert_eq!(local.granted(), ["attach-streams-v1"]);
    assert_eq!(local.recorded(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_local_unix_at_the_current_revision_gets_all_four() {
    let mux = mux("ipc-grant-local");
    let local = Connection::local(&mux);
    assert_eq!(local.advertised(), ALL);
    assert_eq!(local.ask(13)["ok"], true);
    assert_eq!(local.granted(), ALL);
    mux.shutdown();
}

#[test]
fn ipc_grant_one_revision_behind_gets_streams_only() {
    let mux = mux("ipc-grant-n-1");
    let older = Connection::local(&mux);
    assert_eq!(older.advertised(), ALL, "identify before the revision offers all four");
    assert_eq!(older.ask(12)["ok"], true);
    assert_eq!(older.granted(), ["attach-streams-v1"]);
    assert_eq!(older.advertised(), ["attach-streams-v1"], "identify after it offers streams");
    mux.shutdown();
}

#[test]
fn ipc_grant_needs_a_declared_revision() {
    let mux = mux("ipc-grant-undeclared");
    let silent = Connection::local(&mux);
    let reply = silent.request(json!({"id":2,"cmd":"set-client-info","capabilities":ALL}));
    assert_eq!(reply["ok"], true);
    assert_eq!(silent.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_bridged_lane_gets_streams_only() {
    let mux = mux("ipc-grant-bridged");
    let lane = Connection::local(&mux);
    origin_gate::set_mobile_host_peer_for_test(&mux, lane.client);
    assert_eq!(lane.advertised(), ["attach-streams-v1"]);
    assert_eq!(lane.ask(13)["ok"], true);
    assert_eq!(lane.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_byte_bridge_executable_gets_streams_only() {
    let mux = mux("ipc-grant-relay");
    let relay = Connection::open(&mux, ClientTransport::Unix, PeerProcess::ByteBridge);
    assert_eq!(relay.advertised(), ["attach-streams-v1"]);
    assert_eq!(relay.ask(13)["ok"], true);
    assert_eq!(relay.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

/// A bridge that said `bridge-hello` with `bridge-frames-v1` (the SSH
/// bridge's remote end) gets frames at the current revision,
/// never the ring, and streams only one revision behind.
#[test]
fn ipc_grant_framed_bridge_gets_frames_but_never_the_ring() {
    let mux = mux("ipc-grant-framed-bridge");
    for peer in [PeerProcess::ByteBridge, PeerProcess::SameUser] {
        let bridge = Connection::open(&mux, ClientTransport::Unix, peer);
        assert!(origin_gate::declare_frame_bridge(&mux, bridge.client), "{peer:?}");
        assert_eq!(bridge.advertised(), &ALL[..3], "{peer:?}");
        assert_eq!(bridge.ask(13)["ok"], true);
        assert_eq!(bridge.granted(), &ALL[..3], "{peer:?}");
        assert_eq!(bridge.recorded(), &ALL[..3], "the ring is not even recorded");

        let older = Connection::open(&mux, ClientTransport::Unix, peer);
        assert!(origin_gate::declare_frame_bridge(&mux, older.client));
        assert_eq!(older.ask(12)["ok"], true);
        assert_eq!(older.granted(), ["attach-streams-v1"], "{peer:?}");
    }
    mux.shutdown();
}

/// Only a peer the kernel showed to be of the daemon's user, with no role,
/// may say it reads frames: the phone host's lane, an unverified peer, a page
/// relay and a WebSocket stay where their rule puts them.
#[test]
fn ipc_grant_frame_bridge_needs_kernel_facts_and_no_role() {
    let mux = mux("ipc-grant-framed-refused");
    let unknown = Connection::open(&mux, ClientTransport::Unix, PeerProcess::Unverified);
    assert!(!origin_gate::declare_frame_bridge(&mux, unknown.client));
    assert_eq!(unknown.advertised(), ["attach-streams-v1"]);

    let phone = Connection::local(&mux);
    origin_gate::set_mobile_host_peer_for_test(&mux, phone.client);
    assert!(!origin_gate::declare_frame_bridge(&mux, phone.client));
    assert_eq!(phone.ask(13)["ok"], true);
    assert_eq!(phone.granted(), ["attach-streams-v1"]);

    let page = Connection::local(&mux);
    assert!(origin_gate::set_hello(
        &mux,
        page.client,
        HelloRole::PageRelay,
        None,
        false,
        None,
        false
    ));
    assert!(!origin_gate::declare_frame_bridge(&mux, page.client));
    assert!(page.advertised().is_empty());

    let web = Connection::open(&mux, ClientTransport::WebSocket, PeerProcess::SameUser);
    origin_gate::declare_frame_bridge(&mux, web.client);
    assert!(web.advertised().is_empty(), "a WebSocket gets none, whatever its origin says");

    let bridge = Connection::open(&mux, ClientTransport::Unix, PeerProcess::ByteBridge);
    assert!(origin_gate::declare_frame_bridge(&mux, bridge.client));
    assert!(origin_gate::set_hello(
        &mux,
        bridge.client,
        HelloRole::PageRelay,
        None,
        false,
        None,
        false
    ));
    assert!(bridge.advertised().is_empty(), "a later page hello still ends every grant");
    mux.shutdown();
}

#[test]
fn ipc_grant_unverified_peer_gets_streams_only() {
    let mux = mux("ipc-grant-unverified");
    let unknown = Connection::open(&mux, ClientTransport::Unix, PeerProcess::Unverified);
    assert_eq!(unknown.advertised(), ["attach-streams-v1"]);
    assert_eq!(unknown.ask(13)["ok"], true);
    assert_eq!(unknown.granted(), ["attach-streams-v1"]);
    mux.shutdown();
}

#[test]
fn ipc_grant_websocket_gets_none() {
    let mux = mux("ipc-grant-websocket");
    let web = Connection::open(&mux, ClientTransport::WebSocket, PeerProcess::SameUser);
    assert!(web.advertised().is_empty());
    assert_eq!(web.ask(13)["ok"], true, "unknown capabilities are ignored, not refused");
    assert!(web.granted().is_empty());
    mux.shutdown();
}

#[test]
fn ipc_grant_remote_entry_gets_none() {
    let mux = mux("ipc-grant-remote");
    let remote = Connection::open(&mux, ClientTransport::Remote, PeerProcess::SameUser);
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
    let page = Connection::local(&mux);
    assert!(origin_gate::set_hello(
        &mux,
        page.client,
        HelloRole::PageRelay,
        None,
        false,
        None,
        false
    ));
    assert!(page.advertised().is_empty());
    assert_eq!(page.ask(13)["ok"], true);
    assert!(page.granted().is_empty());

    let late = Connection::local(&mux);
    assert_eq!(late.ask(13)["ok"], true);
    assert_eq!(late.granted(), ALL);
    assert!(origin_gate::set_hello(
        &mux,
        late.client,
        HelloRole::PageRelay,
        None,
        false,
        None,
        false
    ));
    assert!(late.granted().is_empty());
    mux.shutdown();
}

#[test]
fn ipc_grant_an_older_revision_removes_the_frame_grants() {
    let mux = mux("ipc-grant-downgrade");
    let local = Connection::local(&mux);
    assert_eq!(local.ask(13)["ok"], true);
    assert_eq!(local.granted(), ALL);
    let reply = local.request(json!({"id":3,"cmd":"set-client-info","api_revision":12}));
    assert_eq!(reply["ok"], true);
    assert_eq!(local.granted(), ["attach-streams-v1"]);
    assert_eq!(local.recorded(), ["attach-streams-v1"], "the grant ends, it is not hidden");

    // Back at the current revision without echoing them: still streams only,
    // which is what a client that computes its own grants expects.
    let reply = local.request(json!({"id":4,"cmd":"set-client-info","api_revision":13}));
    assert_eq!(reply["ok"], true);
    assert_eq!(local.granted(), ["attach-streams-v1"]);
    assert_eq!(local.recorded(), ["attach-streams-v1"]);

    assert_eq!(local.ask(13)["ok"], true, "echoing them again grants them again");
    assert_eq!(local.granted(), ALL);
    mux.shutdown();
}

#[test]
fn ipc_grant_needs_what_each_capability_requires() {
    let mux = mux("ipc-grant-requires");
    let local = Connection::local(&mux);
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
    let bound = IpcTransports::default();
    bound.bind_all_for_test();
    for peer in [IpcPeer::WebSocket, IpcPeer::RemoteEntry, IpcPeer::PageRelay] {
        assert!(IpcCapability::offered(peer, true, &bound).is_empty(), "{peer:?}");
    }
    assert_eq!(
        IpcCapability::offered(IpcPeer::Local, true, &bound),
        [Frames, AttachStreams, AttachFrames, OutputRing]
    );
    assert_eq!(IpcCapability::offered(IpcPeer::Local, false, &bound), [AttachStreams]);
    assert_eq!(IpcCapability::offered(IpcPeer::Bridged, true, &bound), [AttachStreams]);
    assert_eq!(IpcCapability::offered(IpcPeer::Unverified, true, &bound), [AttachStreams]);
    assert_eq!(
        IpcCapability::offered(IpcPeer::FramedBridge, true, &bound),
        [Frames, AttachStreams, AttachFrames]
    );
    assert_eq!(IpcCapability::offered(IpcPeer::FramedBridge, false, &bound), [AttachStreams]);
    assert!(!OutputRing.allowed(IpcPeer::FramedBridge, true));
    assert!(IpcPeer::Local.passes_descriptors());
    assert!(!IpcPeer::FramedBridge.passes_descriptors());
    assert_eq!(
        IpcCapability::offered(IpcPeer::Local, true, &IpcTransports::default()),
        [AttachStreams]
    );
    assert!(AttachStreams.allowed(IpcPeer::Local, false));
    assert!(!Frames.allowed(IpcPeer::Local, false));
    assert!(!OutputRing.allowed(IpcPeer::Bridged, true));
    assert!(!OutputRing.allowed(IpcPeer::Unverified, true));
    for capability in IpcCapability::ALL {
        assert_eq!(IpcCapability::named(capability.name()), Some(capability));
    }
}

#[cfg(unix)]
#[test]
fn ipc_grant_peer_process_is_classified_from_uid_and_executable() {
    use super::super::origin_gate::classify_peer_process;
    use std::path::Path;

    let root = std::env::temp_dir().join(format!("cmux-ipc-peer-{}", std::process::id()));
    let (bin, other) = (root.join("bin"), root.join("other"));
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    let write = |path: &Path| std::fs::write(path, b"").unwrap();
    let daemon = bin.join("cmux-tui");
    for path in [&daemon, &bin.join("cmux"), &bin.join("cmux-app-host"), &other.join("cmux")] {
        write(path);
    }
    let daemon = std::fs::canonicalize(&daemon).unwrap();
    let classify = |uid: Option<u32>, executable: Option<&Path>| {
        classify_peer_process(uid, executable, 501, Some(&daemon))
    };

    assert_eq!(classify(Some(501), Some(&bin.join("cmux"))), PeerProcess::ByteBridge);
    assert_eq!(classify(Some(501), Some(&daemon)), PeerProcess::ByteBridge);
    assert_eq!(classify(Some(501), Some(&bin.join("cmux-app-host"))), PeerProcess::SameUser);
    assert_eq!(classify(Some(501), Some(&other.join("cmux"))), PeerProcess::SameUser);
    assert_eq!(classify(Some(0), Some(&other.join("cmux"))), PeerProcess::Unverified);
    assert_eq!(classify(None, Some(&other.join("cmux"))), PeerProcess::Unverified);
    assert_eq!(classify(Some(501), None), PeerProcess::Unverified);
    assert_eq!(classify(Some(501), Some(&other.join("gone"))), PeerProcess::Unverified);
    assert_eq!(
        classify_peer_process(Some(501), Some(&other.join("cmux")), 501, None),
        PeerProcess::Unverified
    );
    std::fs::remove_dir_all(&root).unwrap();
}
