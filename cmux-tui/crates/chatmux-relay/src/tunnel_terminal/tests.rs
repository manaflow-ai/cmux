use super::*;
use crate::pty::{
    CmuxTui, DataSink, EnsureDaemon, ExitSink, PtyControl, PtyDeps, PtyHandle, PtyOutput, SpawnSpec,
};
use async_trait::async_trait;
use bytes::Bytes;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;
use tokio::net::tcp::OwnedReadHalf;

#[derive(Default)]
struct FakeState {
    on_data: Option<DataSink>,
    on_exit: Option<ExitSink>,
    written: Vec<Vec<u8>>,
    resized: Vec<(u16, u16)>,
    killed: bool,
}

#[derive(Clone)]
struct FakePty {
    state: Arc<StdMutex<FakeState>>,
}

impl FakePty {
    fn emit(&self, text: &str) {
        let sink = self.state.lock().unwrap().on_data.clone();
        if let Some(sink) = sink {
            sink(Bytes::copy_from_slice(text.as_bytes()));
        }
    }
    fn exit(&self, code: i64) {
        let sink = self.state.lock().unwrap().on_exit.clone();
        if let Some(sink) = sink {
            sink(code);
        }
    }
}

impl PtyControl for FakePty {
    fn write(&self, data: &[u8]) {
        self.state.lock().unwrap().written.push(data.to_vec());
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.state.lock().unwrap().resized.push((cols, rows));
    }
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {
        self.state.lock().unwrap().killed = true;
    }
}

impl PtyOutput for FakePty {
    fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
        let mut state = self.state.lock().unwrap();
        state.on_data = Some(on_data);
        state.on_exit = Some(on_exit);
    }
}

struct FakeDeps {
    spawned: Arc<StdMutex<Vec<FakePty>>>,
}

#[async_trait]
impl PtyDeps for FakeDeps {
    async fn spawn_pty(&self, _spec: SpawnSpec) -> PtyHandle {
        let pty = FakePty { state: Arc::new(StdMutex::new(FakeState::default())) };
        self.spawned.lock().unwrap().push(pty.clone());
        PtyHandle { control: Arc::new(pty.clone()), output: Arc::new(pty), banner: None }
    }
    async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
        None
    }
    async fn ensure_daemon(
        &self,
        _cmux_tui: &CmuxTui,
        _session: &str,
        _socket_dir: &Path,
        _cwd: &crate::pty::ResolvedCwd,
        _env: &HashMap<String, String>,
    ) -> Result<EnsureDaemon, String> {
        Err("no daemon in tunnel tests".to_owned())
    }
    async fn connect_control(
        &self,
        _socket_path: &Path,
    ) -> Result<Arc<dyn crate::control::ControlHandle>, String> {
        Err("no control in tunnel tests".to_owned())
    }
    async fn read_dir(&self, _path: &Path) -> Result<Vec<String>, ()> {
        Err(())
    }
    fn socket_dir(&self) -> PathBuf {
        std::env::temp_dir()
    }
    fn shell(&self) -> String {
        "/bin/fakesh".to_owned()
    }
}

struct Rig {
    manager: Arc<PtyManager>,
    spawned: Arc<StdMutex<Vec<FakePty>>>,
    port: u16,
    cancel: CancellationToken,
}

async fn rig_with_limits(max_ptys: usize) -> Rig {
    let spawned = Arc::new(StdMutex::new(Vec::new()));
    let deps = Arc::new(FakeDeps { spawned: Arc::clone(&spawned) });
    let env = HashMap::from([
        ("SHELL".to_owned(), "/bin/fakesh".to_owned()),
        ("HOME".to_owned(), std::env::temp_dir().to_string_lossy().into_owned()),
    ]);
    let manager =
        Arc::new(PtyManager::with_limits(deps, std::env::temp_dir(), env, max_ptys, 32, 1_048_576));
    let cancel = CancellationToken::new();
    let port = start_tunnel_terminal_listener(
        Arc::clone(&manager),
        cancel.clone(),
        TUNNEL_TERMINAL_HOST,
        0,
    )
    .await
    .expect("bind test listener");
    Rig { manager, spawned, port, cancel }
}

async fn rig() -> Rig {
    rig_with_limits(8).await
}

async fn connect(rig: &Rig) -> TcpStream {
    TcpStream::connect((TUNNEL_TERMINAL_HOST, rig.port)).await.expect("connect")
}

/// Read whole frames off the socket with a deadline; panics on EOF.
async fn next_frame(
    read: &mut OwnedReadHalf,
    decoder: &mut TunnelFrameDecoder,
    queue: &mut Vec<TunnelFrame>,
) -> TunnelFrame {
    loop {
        if !queue.is_empty() {
            return queue.remove(0);
        }
        let mut buffer = vec![0_u8; 65_536];
        let count = tokio::time::timeout(Duration::from_secs(5), read.read(&mut buffer))
            .await
            .expect("frame deadline")
            .expect("read");
        assert!(count > 0, "peer closed while a frame was expected");
        queue.extend(decoder.push(&buffer[..count]).expect("decode"));
    }
}

fn control_json(frame: &TunnelFrame) -> Value {
    assert_eq!(frame.kind, FRAME_KIND_CONTROL);
    serde_json::from_slice(&frame.payload).expect("control json")
}

/// Wait until the fake spawn landed (open settles asynchronously).
async fn spawned_pty(rig: &Rig) -> FakePty {
    for _ in 0..100 {
        if let Some(pty) = rig.spawned.lock().unwrap().first().cloned() {
            return pty;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("no PTY spawned");
}

async fn read_eof(read: &mut OwnedReadHalf) {
    let mut buffer = vec![0_u8; 4_096];
    loop {
        let count = tokio::time::timeout(Duration::from_secs(5), read.read(&mut buffer))
            .await
            .expect("eof deadline")
            .expect("read");
        if count == 0 {
            return;
        }
    }
}

// -- pure codec/parse ---------------------------------------------------

// -- live listener ------------------------------------------------------

#[tokio::test]
async fn handshake_streams_both_ways_and_a_drop_detaches_without_killing() {
    let rig = rig().await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();

    write
        .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
        .await
        .unwrap();
    let opened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(opened["t"], "opened");
    assert_eq!(opened["created"], true);
    assert_eq!(opened["cols"], 80);
    assert_eq!(opened["rows"], 24);
    let session = opened["session"].as_str().expect("session name").to_owned();
    assert!(session.starts_with("web-"), "server-minted name: {session}");

    let pty = spawned_pty(&rig).await;
    pty.emit("hello from the shell");
    let output = next_frame(&mut read, &mut decoder, &mut queue).await;
    assert_eq!(output.kind, FRAME_KIND_PTY);
    assert_eq!(output.payload, b"hello from the shell");

    write.write_all(&encode_pty_frame(b"ls\r")).await.unwrap();
    write
        .write_all(&encode_control_frame(&json!({ "t": "resize", "cols": 132, "rows": 43 })))
        .await
        .unwrap();
    for _ in 0..100 {
        if !pty.state.lock().unwrap().written.is_empty()
            && !pty.state.lock().unwrap().resized.is_empty()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(pty.state.lock().unwrap().written, vec![b"ls\r".to_vec()]);
    assert_eq!(pty.state.lock().unwrap().resized, vec![(132, 43)]);

    // A torn splice detaches; the shell session must survive for a
    // later re-attach (created:false proves it was found again).
    drop(write);
    drop(read);
    for _ in 0..100 {
        if rig.manager.attachment_count() == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(rig.manager.attachment_count(), 0, "drop must release the attachment");
    assert!(!pty.state.lock().unwrap().killed, "detach must not kill the session");

    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    write
        .write_all(&encode_control_frame(
            &json!({ "t": "open", "session": session, "cols": 80, "rows": 24 }),
        ))
        .await
        .unwrap();
    let reopened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(reopened["t"], "opened");
    assert_eq!(reopened["created"], false);
    rig.cancel.cancel();
}

#[tokio::test]
async fn bytes_before_open_are_a_protocol_error() {
    let rig = rig().await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    write.write_all(&encode_pty_frame(b"sneaky")).await.unwrap();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(error["t"], "error");
    assert_eq!(error["code"], "bad_request");
    read_eof(&mut read).await;
    rig.cancel.cancel();
}

#[tokio::test]
async fn duplicate_open_is_a_protocol_error() {
    let rig = rig().await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    let open = encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 }));
    write.write_all(&open).await.unwrap();
    write.write_all(&open).await.unwrap();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    loop {
        let frame = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        if frame["t"] == "error" {
            assert_eq!(frame["code"], "bad_request");
            break;
        }
        assert_eq!(frame["t"], "opened");
    }
    read_eof(&mut read).await;
    rig.cancel.cancel();
}

#[tokio::test]
async fn a_malformed_control_frame_closes_the_connection() {
    let rig = rig().await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    write.write_all(&encode_tunnel_frame(FRAME_KIND_CONTROL, b"{not json")).await.unwrap();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(error["t"], "error");
    assert_eq!(error["code"], "bad_request");
    read_eof(&mut read).await;
    rig.cancel.cancel();
}

#[tokio::test]
async fn a_pty_exit_reaches_the_client_and_ends_the_connection() {
    let rig = rig().await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    write
        .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
        .await
        .unwrap();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    let opened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(opened["t"], "opened");
    spawned_pty(&rig).await.exit(3);
    let exit = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(exit["t"], "exit");
    assert_eq!(exit["code"], 3);
    read_eof(&mut read).await;
    rig.cancel.cancel();
}

#[tokio::test]
async fn a_refused_open_maps_the_error_code_and_closes() {
    let rig = rig_with_limits(0).await;
    let stream = connect(&rig).await;
    let (mut read, mut write) = stream.into_split();
    write
        .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
        .await
        .unwrap();
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let mut queue = Vec::new();
    let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
    assert_eq!(error["t"], "error");
    assert_eq!(error["code"], "session_limit");
    read_eof(&mut read).await;
    rig.cancel.cancel();
}

#[test]
fn parse_accepts_the_wire_shapes_and_rejects_malformed_requests() {
    let open = parse_tunnel_client_frame(br#"{"t":"open","cols":80,"rows":24}"#);
    assert_eq!(open, Some(ClientFrame::Open { session: None, surface: None, cols: 80, rows: 24 }));
    let full = parse_tunnel_client_frame(
        br#"{"t":"open","session":"web-abc2","surface":"s:1.2","cols":1,"rows":10000}"#,
    );
    assert_eq!(
        full,
        Some(ClientFrame::Open {
            session: Some("web-abc2".to_owned()),
            surface: Some("s:1.2".to_owned()),
            cols: 1,
            rows: 10_000,
        })
    );
    assert_eq!(
        parse_tunnel_client_frame(br#"{"t":"resize","cols":120,"rows":40}"#),
        Some(ClientFrame::Resize { cols: 120, rows: 40 })
    );
    assert_eq!(parse_tunnel_client_frame(br#"{"t":"detach"}"#), Some(ClientFrame::Detach));
    for bad in [
        &br#"{"t":"open","cols":0,"rows":24}"#[..],
        br#"{"t":"open","cols":10001,"rows":24}"#,
        br#"{"t":"open","cols":80.5,"rows":24}"#,
        br#"{"t":"open","cols":80}"#,
        br#"{"t":"open","surface":"s:1.2","cols":80,"rows":24}"#,
        br#"{"t":"open","session":"bad/name","cols":80,"rows":24}"#,
        br#"{"t":"open","session":null,"cols":80,"rows":24}"#,
        br#"{"t":"nope"}"#,
        br#"[]"#,
        br#"not json"#,
    ] {
        assert_eq!(parse_tunnel_client_frame(bad), None, "{}", String::from_utf8_lossy(bad));
    }
}
#[test]
fn wire_error_codes_match_the_worker_map() {
    assert_eq!(wire_error_code("trust_refused"), "trust_blocked");
    assert_eq!(wire_error_code("bad_request"), "bad_request");
    assert_eq!(wire_error_code("session_limit"), "session_limit");
    assert_eq!(wire_error_code("terminal_gone"), "terminal_gone");
    assert_eq!(wire_error_code("overflow"), "overflow");
    assert_eq!(wire_error_code("trust_revoked"), "trust_revoked");
    assert_eq!(wire_error_code("busy"), "busy");
    assert_eq!(wire_error_code("failed"), "failed");
    assert_eq!(wire_error_code("brand_new_code"), "failed");
}
