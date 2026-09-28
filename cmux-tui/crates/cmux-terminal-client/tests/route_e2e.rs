//! The in-process client path the iOS app takes: a `ws://` route to a
//! machine's private address, dialed through an in-process WireGuard tunnel,
//! with a persistent device identity, raw terminal bytes delivered to the
//! embedding renderer, and the terminal catalog read over mux control.
//!
//! Everything runs in one process with no root and no network interface. The
//! daemon listens on loopback; the "network" side of the tunnel bridges the
//! tunneled TCP connection to it, which is what a VPC address looks like from
//! the client.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use bytes::Bytes;
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{
    Lane, Service, ServiceControl, TERMINAL_BYTES_VIEWER_SIZE_PRIORITY,
    TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED,
};
use cmux_terminal_client::{
    CmuxTerminalClient, cmux_terminal_client_attach_with_timeout,
    cmux_terminal_client_connect_route, cmux_terminal_client_create_terminal,
    cmux_terminal_client_create_terminal_in_workspace, cmux_terminal_client_detach,
    cmux_terminal_client_disconnect, cmux_terminal_client_has_exited,
    cmux_terminal_client_list_terminals, cmux_terminal_client_session_snapshot,
    cmux_terminal_client_set_output_callback, cmux_terminal_client_set_viewer_size_priority,
    cmux_terminal_client_string_free, cmux_wireguard_net_free, cmux_wireguard_net_start,
};
use cmux_tui_core::terminal_host_protocol::{
    Frame, FrameDecoder, MAX_FRAME_PAYLOAD, MessageKind, encode_frame,
};
use cmux_tui_core::terminal_host_runtime::{HostSnapshot, encode_host_snapshot_payload};
use cmux_wg::testing::{LoopbackPair, loopback_pair};
use cmux_wg::{WgConfig, WgNet};
use tempfile::tempdir;
use tokio::net::TcpStream;

const TIMEOUT_MS: u64 = 15_000;
const TERMINAL_ID: &str = "term_0123456789abcdef0123456789abcdef";
const WORKSPACE_ID: &str = "ws_00112233445566778899aabbccddeeff";
const TAB_TERMINAL_ID: &str = "term_fedcba9876543210fedcba9876543210";

fn wg_quick_text(config: &WgConfig) -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut text = String::from("[Interface]\n");
    text.push_str(&format!("PrivateKey = {}\n", b64.encode(*config.private_key)));
    for address in &config.addresses {
        text.push_str(&format!("Address = {address}\n"));
    }
    text.push_str(&format!("MTU = {}\n\n[Peer]\n", config.mtu));
    text.push_str(&format!("PublicKey = {}\n", b64.encode(config.peer_public_key)));
    let allowed = config.allowed_ips.iter().map(|net| net.to_string()).collect::<Vec<_>>();
    text.push_str(&format!("AllowedIPs = {}\n", allowed.join(", ")));
    let endpoint = config.endpoint.as_ref().expect("client config names the peer endpoint");
    text.push_str(&format!("Endpoint = {endpoint}\n"));
    if let Some(keepalive) = config.persistent_keepalive {
        text.push_str(&format!("PersistentKeepalive = {keepalive}\n"));
    }
    text
}

/// Accept tunneled connections on `port` and pipe each to the daemon.
async fn bridge_to_daemon(net: &WgNet, port: u16, daemon: SocketAddr) {
    let mut listener = net.listen(port).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut tunneled) = listener.accept().await {
            tokio::spawn(async move {
                let Ok(mut local) = TcpStream::connect(daemon).await else { return };
                let _ = tokio::io::copy_bidirectional(&mut tunneled, &mut local).await;
            });
        }
    });
}

fn snapshot_payload(replay: &[u8]) -> Vec<u8> {
    encode_host_snapshot_payload(&HostSnapshot {
        cols: 80,
        rows: 24,
        cell_pixels: (8, 16),
        replay: replay.to_vec(),
        kitty_image_aliases: Vec::new(),
        kitty_state: ghostty_vt::KittyReplayState::disabled(),
        sequence_boundary: 0,
        colors: ghostty_vt::TerminalColorOverrides::default(),
        pid: None,
        command: Vec::new(),
        cwd: None,
        osc_progress: String::new(),
    })
    .unwrap()
}

fn frame(kind: MessageKind, payload: Vec<u8>, sequence: u64) -> Bytes {
    let mut frame = Frame::new(kind, payload);
    frame.sequence = sequence;
    Bytes::from(encode_frame(&frame).unwrap())
}

/// What the fake daemon records about TerminalBytes opens, and whether it
/// rejects the viewer-size priority key the way a daemon that predates it does.
#[derive(Default)]
struct PhoneDaemon {
    rejects_viewer_size_priority: bool,
    terminal_opens: Mutex<Vec<BTreeMap<String, String>>>,
    mux_operations: Mutex<Vec<String>>,
    /// Every protocol/2 request as received, for asserting exact params.
    mux_requests: Mutex<Vec<serde_json::Value>>,
}

/// The daemon side of the services a phone client uses: one TerminalBytes
/// stream that replays a prompt and writes one line, and MuxControl answering
/// `terminal.list` and `workspace.create` with canned protocol/2 replies.
async fn serve_phone_services(daemon: Arc<ServiceMultiplexer>, phone: Arc<PhoneDaemon>) {
    loop {
        let Ok(Some(incoming)) = daemon.accept().await else { return };
        let stream = Arc::new(incoming.stream);
        match stream.service() {
            Service::TerminalBytes => {
                phone.terminal_opens.lock().unwrap().push(incoming.metadata.clone());
                if phone.rejects_viewer_size_priority
                    && incoming.metadata.contains_key(TERMINAL_BYTES_VIEWER_SIZE_PRIORITY)
                {
                    let message = "terminal byte stream metadata only supports terminal";
                    stream.reject("invalid-argument".into(), message.into()).await.unwrap();
                    continue;
                }
                tokio::spawn(serve_terminal_bytes(stream));
            }
            Service::MuxControl => {
                let opened = serde_json::to_vec(&serde_json::json!({
                    "type": "opened", "service": "mux-control", "features": []
                }))
                .unwrap();
                for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
                    stream.send_on(lane, Bytes::from(opened.clone())).await.unwrap();
                }
                tokio::spawn(mux_responder(stream, phone.clone()));
            }
            other => panic!("unexpected service {other:?}"),
        }
    }
}

/// One TerminalBytes stream: replay a prompt, write one line, then echo typed
/// input back as output so the input path is proven too. A client may detach
/// as soon as it sees Opened, so a failed send ends only this stream.
async fn serve_terminal_bytes(stream: Arc<cmux_remote::service::ServiceStream>) {
    let opened =
        serde_json::to_vec(&ServiceControl::Opened { service: Service::TerminalBytes }).unwrap();
    let bootstrap = [
        Bytes::from(opened),
        frame(MessageKind::Snapshot, snapshot_payload(b"$ "), 7),
        frame(MessageKind::Ready, Vec::new(), 7),
        frame(MessageKind::Output, b"hello from vm\r\n".to_vec(), 8),
    ];
    for payload in bootstrap {
        if stream.send_on(Lane::Interactive, payload).await.is_err() {
            return;
        }
    }
    // Input arrives as encoded Input frames, exactly as a PTY host sees it.
    let mut sequence = 9;
    let mut decoder = FrameDecoder::new(MAX_FRAME_PAYLOAD);
    while let Ok(Some(chunk)) = stream.receive().await {
        if chunk.payload.is_empty() {
            continue;
        }
        for input in decoder.push(&chunk.payload).unwrap() {
            if input.kind != MessageKind::Input {
                continue;
            }
            let _ = stream
                .send_on(Lane::Interactive, frame(MessageKind::Output, input.payload, sequence))
                .await;
            sequence += 1;
        }
    }
}

/// Decode CMXL packets into lines the way the daemon bridge does, and answer.
async fn mux_responder(stream: Arc<cmux_remote::service::ServiceStream>, phone: Arc<PhoneDaemon>) {
    const HEADER: usize = 20;
    let mut message = 100_u64;
    while let Ok(Some(chunk)) = stream.receive().await {
        if chunk.payload.len() < HEADER {
            continue;
        }
        // One request fits one part in these tests.
        let line = &chunk.payload[HEADER..];
        let request: serde_json::Value = serde_json::from_slice(line).unwrap();
        assert_eq!(request["protocol"], "cmux.protocol/2");
        assert_eq!(request["params"]["machine"], "current");
        let operation = request["operation"].as_str().unwrap();
        phone.mux_operations.lock().unwrap().push(operation.to_string());
        phone.mux_requests.lock().unwrap().push(request.clone());
        let result = match operation {
            "terminal.list" => {
                assert!(request.get("idempotency_key").is_none());
                serde_json::json!([{ "id": TERMINAL_ID, "name": "shell" }])
            }
            "workspace.create" => {
                assert!(request["idempotency_key"].as_str().is_some());
                assert_eq!(request["params"]["initial_content"], "terminal");
                assert_eq!(request["params"]["name"], "phone");
                // The daemon's MutationResult<CreatedPath>, as protocol 5 sends
                // it: the created path is under `value`, discriminated by kind.
                serde_json::json!({
                    "generation": "9ded6c40",
                    "replayed": false,
                    "revision": "3",
                    "value": {
                        "kind": "terminal",
                        "workspace_id": "ws_1",
                        "screen_id": "screen_1",
                        "pane_id": "pane_1",
                        "tab_id": "tab_1",
                        "terminal_id": TERMINAL_ID,
                    },
                })
            }
            "session.snapshot" => {
                assert!(request.get("idempotency_key").is_none());
                assert_eq!(request["params"]["session"], "current");
                session_snapshot_reply()
            }
            // The test asserts this request's params from `mux_requests`; the
            // reply is the daemon's MutationResult<CreatedTerminalPath> for a
            // tab added to the selected workspace's focused pane.
            "tab.create_terminal" => serde_json::json!({
                "generation": "9ded6c40",
                "replayed": false,
                "revision": "4",
                "value": {
                    "kind": "terminal",
                    "workspace_id": request["params"]["workspace"],
                    "screen_id": "screen_1",
                    "pane_id": "pane_1",
                    "tab_id": "tab_2",
                    "terminal_id": TAB_TERMINAL_ID,
                },
            }),
            other => panic!("unexpected operation {other}"),
        };
        let reply = serde_json::json!({
            "protocol": "cmux.protocol/2", "type": "response",
            "id": request["id"], "ok": true, "result": result,
        });
        let mut line = serde_json::to_vec(&reply).unwrap();
        line.push(b'\n');
        let mut packet = Vec::with_capacity(HEADER + line.len());
        packet.extend_from_slice(b"CMXL");
        packet.extend_from_slice(&message.to_be_bytes());
        packet.extend_from_slice(&0u32.to_be_bytes());
        packet.extend_from_slice(&1u32.to_be_bytes());
        packet.extend_from_slice(&line);
        message += 1;
        stream.send_on(chunk.lane, Bytes::from(packet)).await.unwrap();
    }
}

type CapturedEvent = (u32, Vec<u8>, u16, u16);

struct Captured {
    events: Mutex<Vec<CapturedEvent>>,
    saw_hello: AtomicBool,
}

unsafe extern "C" fn capture(
    context: *mut c_void,
    kind: u32,
    bytes: *const u8,
    length: usize,
    cols: u16,
    rows: u16,
) {
    // SAFETY: the test passes an `Arc<Captured>` pointer that outlives the client.
    let captured = unsafe { &*(context as *const Captured) };
    let bytes = if length == 0 {
        Vec::new()
    } else {
        // SAFETY: the emitter passes a live slice for the call.
        unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec()
    };
    if bytes.windows(13).any(|window| window == b"hello from vm") {
        captured.saw_hello.store(true, Ordering::Release);
    }
    captured.events.lock().unwrap().push((kind, bytes, cols, rows));
}

fn c(text: &str) -> CString {
    CString::new(text).unwrap()
}

fn error_text(buffer: &[c_char]) -> String {
    // SAFETY: the library always NUL-terminates within capacity.
    unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy().into_owned()
}

fn take_string(pointer: *mut c_char) -> String {
    assert!(!pointer.is_null());
    // SAFETY: a non-null pointer from this library is a valid C string.
    let text = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
    // SAFETY: freed exactly once here.
    unsafe { cmux_terminal_client_string_free(pointer) };
    text
}

#[test]
fn phone_path_over_wireguard_with_persistent_identity() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let daemon_state = tempdir().unwrap();
    let client_state = tempdir().unwrap();

    // Daemon on loopback, reachable only through the tunnel at server_v6.
    let (auth, server, network, invitation_uri, route, wg_text) = runtime.block_on(async {
        let auth = AuthDatabase::load_or_create(daemon_state.path(), "phone-test", false).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
            .await
            .unwrap();
        let LoopbackPair { client, server: network, server_socket, server_v6, .. } =
            loopback_pair().await.unwrap();
        let network = WgNet::start(network, server_socket).await.unwrap();
        bridge_to_daemon(&network, 1337, server.local_addr()).await;
        // Every accepted connection gets the phone services.
        tokio::spawn(async move {
            while let Some(connection) = accepted.recv().await {
                let services = ServiceMultiplexer::new(connection, EndpointRole::Daemon);
                tokio::spawn(serve_phone_services(services, Arc::default()));
            }
        });
        let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
        let uri = invitation.to_uri().unwrap();
        (
            auth,
            server,
            network,
            uri,
            format!("ws://[{server_v6}]:1337/v1/link"),
            wg_quick_text(&client),
        )
    });
    // Approve the first (invitation) enrollment as the control plane would.
    let approver = runtime.spawn({
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(10)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });

    let mut error = vec![0 as c_char; 512];
    let config = c(&wg_text);
    // SAFETY: valid NUL-terminated config and a writable error buffer.
    let net = unsafe { cmux_wireguard_net_start(config.as_ptr(), error.as_mut_ptr(), error.len()) };
    assert!(!net.is_null(), "wireguard start failed: {}", error_text(&error));

    let route_c = c(&route);
    let state_c = c(client_state.path().to_str().unwrap());
    let device_c = c("iPhone test");
    let invitation_c = c(&invitation_uri);

    // First connect: invitation, through the tunnel.
    // SAFETY: all strings are live NUL-terminated; net is a live handle.
    let client = unsafe {
        cmux_terminal_client_connect_route(
            route_c.as_ptr(),
            state_c.as_ptr(),
            device_c.as_ptr(),
            invitation_c.as_ptr(),
            net,
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(!client.is_null(), "invitation connect failed: {}", error_text(&error));
    runtime.block_on(approver).unwrap();

    let captured =
        Arc::new(Captured { events: Mutex::new(Vec::new()), saw_hello: AtomicBool::new(false) });
    // SAFETY: the context outlives the client; cleared before it is dropped.
    unsafe {
        cmux_terminal_client_set_output_callback(
            client,
            Some(capture),
            Arc::as_ptr(&captured) as *mut c_void,
        );
    }

    // Catalog over mux control.
    let listed = take_string(unsafe {
        cmux_terminal_client_list_terminals(client, error.as_mut_ptr(), error.len(), TIMEOUT_MS)
    });
    let listed: serde_json::Value = serde_json::from_str(&listed).unwrap();
    assert_eq!(listed[0]["id"], TERMINAL_ID);
    let name = c("phone");
    let created = take_string(unsafe {
        cmux_terminal_client_create_terminal(
            client,
            name.as_ptr(),
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    });
    let created: serde_json::Value = serde_json::from_str(&created).unwrap();
    assert_eq!(created["value"]["kind"], "terminal");
    assert_eq!(created["value"]["terminal_id"], TERMINAL_ID);

    // Attach in raw mode: replay, then live output, then echoed input.
    let terminal_c = c(TERMINAL_ID);
    // SAFETY: live handle and NUL-terminated id.
    let attached = unsafe {
        cmux_terminal_client_attach_with_timeout(
            client,
            terminal_c.as_ptr(),
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(attached, "attach failed: {}", error_text(&error));
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !captured.saw_hello.load(Ordering::Acquire) {
        assert!(
            std::time::Instant::now() < deadline,
            "no raw output arrived: {:?}",
            captured.events.lock().unwrap()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    {
        let events = captured.events.lock().unwrap();
        assert_eq!(events[0].0, 1, "first event is the snapshot");
        assert_eq!(&events[0].1, b"$ ");
        assert_eq!((events[0].2, events[0].3), (80, 24));
        assert!(
            events.iter().any(|(kind, bytes, _, _)| *kind == 2 && bytes == b"hello from vm\r\n")
        );
    }
    // SAFETY: live handle; bytes are copied before return.
    assert!(unsafe {
        cmux_terminal_client::cmux_terminal_client_send(client, b"ls\n".as_ptr(), 3)
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if captured
            .events
            .lock()
            .unwrap()
            .iter()
            .any(|(kind, bytes, _, _)| *kind == 2 && bytes == b"ls\n")
        {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "typed input was not echoed");
        std::thread::sleep(Duration::from_millis(20));
    }
    // SAFETY: live handle.
    assert!(!unsafe { cmux_terminal_client_has_exited(client) });
    // SAFETY: clear the context before the client and Arc go away.
    unsafe {
        cmux_terminal_client_set_output_callback(client, None, std::ptr::null_mut());
        cmux_terminal_client_disconnect(client);
    }

    // Second connect: no invitation. The persisted device key is already
    // enrolled, so the daemon admits it in Enrolled mode.
    let client = unsafe {
        cmux_terminal_client_connect_route(
            route_c.as_ptr(),
            state_c.as_ptr(),
            device_c.as_ptr(),
            std::ptr::null(),
            net,
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(!client.is_null(), "enrolled reconnect failed: {}", error_text(&error));
    let identity =
        std::fs::read_to_string(client_state.path().join("client-identity.json")).unwrap();
    assert!(!identity.is_empty(), "device identity persisted in the state dir");
    let known = std::fs::read_dir(client_state.path()).unwrap().count();
    assert!(known >= 2, "identity and known-daemon state both persisted");
    // SAFETY: live handle, owned exactly once.
    unsafe { cmux_terminal_client_disconnect(client) };

    // A fresh state dir has no enrolled daemon for this route.
    let fresh = tempdir().unwrap();
    let fresh_c = c(fresh.path().to_str().unwrap());
    let client = unsafe {
        cmux_terminal_client_connect_route(
            route_c.as_ptr(),
            fresh_c.as_ptr(),
            device_c.as_ptr(),
            std::ptr::null(),
            net,
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(client.is_null());
    assert!(error_text(&error).contains("invitation"), "{}", error_text(&error));

    // SAFETY: no client references the tunnel any longer.
    unsafe { cmux_wireguard_net_free(net) };
    runtime.block_on(async {
        server.shutdown().await.unwrap();
        network.shutdown().await;
    });
}

#[test]
fn unsupported_scheme_and_missing_state_dir_fail_cleanly() {
    let mut error = vec![0 as c_char; 256];
    let route = c("ftp://example/v1/link");
    let state = c("/nonexistent-parent-for-cmux-test/state");
    let device = c("phone");
    // SAFETY: valid strings and error buffer; no tunnel.
    let client = unsafe {
        cmux_terminal_client_connect_route(
            route.as_ptr(),
            state.as_ptr(),
            device.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            error.as_mut_ptr(),
            error.len(),
            1_000,
        )
    };
    assert!(client.is_null());
    assert!(!error_text(&error).is_empty());
}

/// A trimmed public session snapshot whose ids link one terminal to its
/// workspace: terminal.tab_id -> tab.pane_id -> pane.screen_id ->
/// screen.workspace_id.
fn session_snapshot_reply() -> serde_json::Value {
    serde_json::json!({
        "workspaces": [{ "id": "ws_1", "title": "phone" }],
        "screens": [{ "id": "screen_1", "workspace_id": "ws_1" }],
        "panes": [{ "id": "pane_1", "screen_id": "screen_1" }],
        "tabs": [{ "id": "tab_1", "pane_id": "pane_1" }],
        "terminals": [{ "id": TERMINAL_ID, "tab_id": "tab_1" }],
    })
}

/// Connects a client over a plain loopback route (no tunnel) to a fake daemon
/// serving `phone`, runs `body` with it, then disconnects.
fn with_loopback_client<T>(
    phone: Arc<PhoneDaemon>,
    body: impl FnOnce(*mut CmuxTerminalClient) -> T,
) -> T {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let daemon_state = tempdir().unwrap();
    let client_state = tempdir().unwrap();
    let (auth, server, invitation_uri, route) = runtime.block_on(async {
        let auth = AuthDatabase::load_or_create(daemon_state.path(), "loopback", false).unwrap();
        let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
            .await
            .unwrap();
        tokio::spawn(async move {
            while let Some(connection) = accepted.recv().await {
                let services = ServiceMultiplexer::new(connection, EndpointRole::Daemon);
                tokio::spawn(serve_phone_services(services, phone.clone()));
            }
        });
        let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
        let route = format!("ws://{}/v1/link", server.local_addr());
        (auth, server, invitation.to_uri().unwrap(), route)
    });
    let approver = runtime.spawn(async move {
        let pending = auth.wait_for_pending(Duration::from_secs(10)).await.unwrap();
        auth.approve(&pending[0].invitation_id).await.unwrap();
    });

    let mut error = vec![0 as c_char; 512];
    let route_c = c(&route);
    let state_c = c(client_state.path().to_str().unwrap());
    let device_c = c("iPhone loopback test");
    let invitation_c = c(&invitation_uri);
    // SAFETY: all strings are live NUL-terminated; no tunnel is used.
    let client = unsafe {
        cmux_terminal_client_connect_route(
            route_c.as_ptr(),
            state_c.as_ptr(),
            device_c.as_ptr(),
            invitation_c.as_ptr(),
            std::ptr::null(),
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(!client.is_null(), "connect failed: {}", error_text(&error));
    runtime.block_on(approver).unwrap();

    let result = body(client);
    // SAFETY: live handle, owned exactly once.
    unsafe { cmux_terminal_client_disconnect(client) };
    runtime.block_on(async { server.shutdown().await.unwrap() });
    result
}

#[test]
fn session_snapshot_returns_the_daemon_snapshot_over_mux_control() {
    let phone = Arc::new(PhoneDaemon::default());
    let snapshot = with_loopback_client(phone.clone(), |client| {
        let mut error = vec![0 as c_char; 512];
        // SAFETY: live handle and a writable error buffer.
        let text = unsafe {
            cmux_terminal_client_session_snapshot(
                client,
                error.as_mut_ptr(),
                error.len(),
                TIMEOUT_MS,
            )
        };
        assert!(!text.is_null(), "session snapshot failed: {}", error_text(&error));
        take_string(text)
    });
    let snapshot: serde_json::Value = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(snapshot, session_snapshot_reply());
    assert_eq!(*phone.mux_operations.lock().unwrap(), ["session.snapshot"]);
}

#[test]
fn create_terminal_in_workspace_sends_tab_create_terminal_for_that_workspace() {
    let phone = Arc::new(PhoneDaemon::default());
    let created = with_loopback_client(phone.clone(), |client| {
        let mut error = vec![0 as c_char; 512];
        let workspace_c = c(WORKSPACE_ID);
        let name_c = c("phone tab");
        let mut created = Vec::new();
        for name in [name_c.as_ptr(), std::ptr::null()] {
            // SAFETY: live handle, NUL-terminated workspace id, and a name that
            // is null or NUL-terminated.
            let text = unsafe {
                cmux_terminal_client_create_terminal_in_workspace(
                    client,
                    workspace_c.as_ptr(),
                    name,
                    error.as_mut_ptr(),
                    error.len(),
                    TIMEOUT_MS,
                )
            };
            assert!(!text.is_null(), "create in workspace failed: {}", error_text(&error));
            created.push(serde_json::from_str::<serde_json::Value>(&take_string(text)).unwrap());
        }
        created
    });
    for result in &created {
        assert_eq!(result["value"]["kind"], "terminal");
        assert_eq!(result["value"]["workspace_id"], WORKSPACE_ID);
        assert_eq!(result["value"]["terminal_id"], TAB_TERMINAL_ID);
    }

    let requests = phone.mux_requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    for request in requests.iter() {
        assert_eq!(request["operation"], "tab.create_terminal");
        assert!(request["idempotency_key"].as_str().is_some_and(|key| !key.is_empty()));
        let params = request["params"].as_object().unwrap();
        assert_eq!(params["machine"], "current");
        assert_eq!(params["session"], "current");
        assert_eq!(params["workspace"], WORKSPACE_ID);
        // The workspace alone targets its focused pane; the client never
        // guesses a pane or screen.
        assert!(!params.contains_key("pane") && !params.contains_key("screen"), "{params:?}");
    }
    assert_eq!(requests[0]["params"]["name"], "phone tab");
    assert!(requests[1]["params"].get("name").is_none());
    assert_ne!(requests[0]["idempotency_key"], requests[1]["idempotency_key"]);
}

#[test]
fn create_terminal_in_workspace_rejects_anything_but_a_workspace_id_before_sending() {
    let mut error = vec![0 as c_char; 512];
    let workspace_c = c(WORKSPACE_ID);
    // SAFETY: a null client is part of the contract; the other pointers are live.
    let text = unsafe {
        cmux_terminal_client_create_terminal_in_workspace(
            std::ptr::null_mut(),
            workspace_c.as_ptr(),
            std::ptr::null(),
            error.as_mut_ptr(),
            error.len(),
            TIMEOUT_MS,
        )
    };
    assert!(text.is_null());
    assert_eq!(error_text(&error), "client is null");

    let phone = Arc::new(PhoneDaemon::default());
    let errors = with_loopback_client(phone.clone(), |client| {
        // A name, `current`, and another resource's id would all resolve as
        // daemon selectors, so none of them may reach the daemon.
        [Some("current"), Some("phone"), Some(TERMINAL_ID), None].map(|workspace| {
            let workspace_c = workspace.map(c);
            let workspace_ptr = workspace_c.as_ref().map_or(std::ptr::null(), |id| id.as_ptr());
            let mut error = vec![0 as c_char; 512];
            // SAFETY: live handle; the workspace id is null or NUL-terminated.
            let text = unsafe {
                cmux_terminal_client_create_terminal_in_workspace(
                    client,
                    workspace_ptr,
                    std::ptr::null(),
                    error.as_mut_ptr(),
                    error.len(),
                    TIMEOUT_MS,
                )
            };
            assert!(text.is_null(), "{workspace:?} was accepted");
            error_text(&error)
        })
    });
    for error in &errors[..3] {
        assert!(error.starts_with("workspace_id is invalid"), "{error}");
    }
    assert_eq!(errors[3], "workspace_id is null");
    assert!(phone.mux_operations.lock().unwrap().is_empty());
}

/// Attaches once per entry of `choices` (detaching in between) with that
/// viewer-size priority choice, and returns whether each TerminalBytes open
/// the daemon saw carried the key.
fn viewer_size_priority_opens(rejects_key: bool, choices: &[bool]) -> Vec<bool> {
    let phone =
        Arc::new(PhoneDaemon { rejects_viewer_size_priority: rejects_key, ..Default::default() });
    with_loopback_client(phone.clone(), |client| {
        let mut error = vec![0 as c_char; 512];
        let terminal_c = c(TERMINAL_ID);
        for &preferred in choices {
            // SAFETY: live handle; the terminal id is NUL-terminated.
            let attached = unsafe {
                assert!(cmux_terminal_client_set_viewer_size_priority(client, preferred));
                cmux_terminal_client_attach_with_timeout(
                    client,
                    terminal_c.as_ptr(),
                    error.as_mut_ptr(),
                    error.len(),
                    TIMEOUT_MS,
                )
            };
            assert!(attached, "attach failed: {}", error_text(&error));
            // SAFETY: live handle.
            unsafe { cmux_terminal_client_detach(client) };
        }
    });

    let opens = phone.terminal_opens.lock().unwrap();
    opens
        .iter()
        .map(|metadata| {
            assert_eq!(metadata.get("terminal").map(String::as_str), Some(TERMINAL_ID));
            match metadata.get(TERMINAL_BYTES_VIEWER_SIZE_PRIORITY) {
                Some(value) => {
                    assert_eq!(value, TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED);
                    true
                }
                None => false,
            }
        })
        .collect()
}

#[test]
fn viewer_size_priority_open_metadata_follows_the_client_choice() {
    assert_eq!(viewer_size_priority_opens(false, &[false, true, true]), [false, true, true]);
}

#[test]
fn viewer_size_priority_is_dropped_after_an_old_daemon_rejects_it() {
    // The rejected open is retried without the key within the same attach,
    // and later attaches on this connection no longer ask for it.
    assert_eq!(viewer_size_priority_opens(true, &[false, true, true]), [false, true, false, false]);
}
