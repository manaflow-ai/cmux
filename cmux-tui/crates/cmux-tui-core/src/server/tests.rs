//! Unit tests for the control protocol server (server.rs and its child
//! modules): shared imports and fixtures here, tests by family in
//! `tests/<family>.rs`.

use super::*;
use crate::{
    BrowserFrame, BrowserStatus, JournalProducer, JournalReplayPolicy, JournalSubject,
    ProviderWorkspaceAuthority, SessionJournalRecord, SidebarPluginOptions, SurfaceOptions,
};
use ghostty_vt::{Callbacks, RenderState, Terminal};
use std::sync::mpsc::TryRecvError;
use std::time::Duration;

/// A test socket directory: a short directory under the canonical
/// `/tmp` from the shared helper, so socket paths fit sun_path whatever
/// `$TMPDIR` is (cmux_unix_socket::short_test_dir).
struct TestSocketDir(cmux_unix_socket::TestDir);

impl TestSocketDir {
    fn create(name: &str) -> Self {
        Self(cmux_unix_socket::short_test_dir(&format!("cts-{name}")))
    }

    fn path(&self) -> &Path {
        self.0.path()
    }
}

pub(super) fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("test", SurfaceOptions::default())
}

fn sizing_browser(mux: &Arc<Mux>, size: (u16, u16)) -> Arc<crate::Surface> {
    mux.new_browser_tab("about:blank#client-sizing".to_string(), None, Some(size)).unwrap()
}

fn settle_browser_size(surface: &Arc<crate::Surface>, expected: (u16, u16)) {
    if surface.size() != expected {
        if let Some(pending) = surface.pending_resize_completion(expected.0, expected.1).unwrap() {
            wait_for_initial_browser_resize(&pending.completion, surface.id, pending.reservation)
                .unwrap();
        } else {
            // The resize worker may commit between the size observation
            // above and the pending-completion lookup. Absence is valid
            // only when that exact resize has already landed.
            assert_eq!(surface.size(), expected);
        }
    }
    assert_eq!(surface.size(), expected);
}

fn settle_marked_browser_resize(surface: &Arc<crate::Surface>, marked: &MarkedClientAttach) {
    if let Some(reservation) = marked.resize_reservation {
        wait_for_initial_browser_resize(
            marked
                .resize_completion
                .as_ref()
                .expect("sized browser attach has a completion receiver"),
            surface.id,
            reservation,
        )
        .unwrap();
    }
}

const PROVIDER_AUTHORITY: &str = "provider-workspace-authority-for-server-tests-00000001";

fn provider_test_mux() -> Arc<Mux> {
    Mux::new_provider_managed_for_test(
        "provider-test",
        SurfaceOptions::default(),
        ProviderWorkspaceAuthority::new(PROVIDER_AUTHORITY).unwrap(),
    )
}

fn test_writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

struct TestSocket {
    directory: PathBuf,
    path: PathBuf,
}

impl TestSocket {
    fn new(label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);

        let directory = loop {
            let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let candidate = std::env::temp_dir()
                .join(format!("cmux-tui-test-{}-{sequence}", std::process::id()));
            match std::fs::create_dir(&candidate) {
                Ok(()) => break candidate,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create private test socket directory: {error}"),
            }
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
                .expect("secure private test socket directory");
        }
        let path = directory.join(format!("{label}.sock"));
        #[cfg(unix)]
        assert!(unix_socket_path_fits(&path));
        Self { directory, path }
    }
}

impl Drop for TestSocket {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.directory);
    }
}

fn render_protocol_frame(
    terminal: &mut Terminal,
    render_state: &mut RenderState,
) -> SurfaceRenderFrame {
    render_state.update(terminal).unwrap();
    SurfaceRenderFrame {
        frame: render_state.build_frame().unwrap(),
        content_generation: 1,
        scrollback_rows: 0,
        history_epoch: terminal.history_epoch(),
        pointer_semantics: terminal.pointer_semantic_snapshot(),
        palette_colors: [Rgb::default(); 256],
        palette_overridden: [false; 256],
    }
}

fn render_protocol_client(
    terminal: &mut Terminal,
    render_state: &mut RenderState,
) -> RenderClientState {
    RenderClientState::new(
        Arc::new(RenderService::new()),
        &render_protocol_frame(terminal, render_state),
    )
}

fn replace_render_image(
    frame: &mut SurfaceRenderFrame,
    image_id: u32,
    pixels: impl Into<Arc<[u8]>>,
) {
    let graphics = Arc::make_mut(&mut frame.frame.kitty_graphics);
    graphics.generation += 1;
    let image = graphics.images.iter_mut().find(|image| image.id == image_id).unwrap();
    image.generation += 1;
    image.data = pixels.into();
    let delta = Arc::make_mut(&mut frame.frame.kitty_graphics_delta);
    delta.previous_snapshot_id = Some(delta.snapshot_id);
    delta.snapshot_id = delta.snapshot_id.wrapping_add(1);
    delta.image_revision = delta.image_revision.wrapping_add(1);
    delta.image_generations =
        graphics.images.iter().map(|image| (image.id, image.generation)).collect::<Vec<_>>().into();
    delta.changed_image_ids = Arc::from([image_id]);
    delta.removed_image_ids = Arc::from([]);
}

const RED_IMAGE_41: &[u8] = b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\";

const GREEN_IMAGE_42: &[u8] = b"\x1b_Ga=T,t=d,f=24,i=42,p=8,s=1,v=1,c=1,r=1,q=2;AP8A\x1b\\";

const LARGE_RENDER_IMAGE_WIDTH: usize = 1_024;

const LARGE_RENDER_IMAGE_HEIGHT: usize = 768;

const LARGE_RENDER_IMAGE_RAW_BYTES: usize =
    LARGE_RENDER_IMAGE_WIDTH * LARGE_RENDER_IMAGE_HEIGHT * 4;

const LARGE_RENDER_IMAGE_BASE64_CHARS: usize = LARGE_RENDER_IMAGE_RAW_BYTES.div_ceil(3) * 4;

fn large_rgba_kitty_transmission() -> Vec<u8> {
    let data =
        base64::engine::general_purpose::STANDARD.encode(vec![0x7f; LARGE_RENDER_IMAGE_RAW_BYTES]);
    assert_eq!(data.len(), LARGE_RENDER_IMAGE_BASE64_CHARS);
    format!(
        "\x1b_Ga=T,t=d,f=32,i=51,p=1,s={LARGE_RENDER_IMAGE_WIDTH},v={LARGE_RENDER_IMAGE_HEIGHT},c=80,r=24,q=2;{data}\x1b\\"
    )
    .into_bytes()
}

pub(super) fn captured_writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

struct BlockingControlSink {
    outbound: Arc<BoundedOutbound>,
    blocked_request_id: String,
    entered: std::sync::mpsc::SyncSender<()>,
    release: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl MessageSink for BlockingControlSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.outbound.push_regular(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        let value: Value = serde_json::from_str(&text).map_err(json_error_to_io)?;
        if value["type"] == "response"
            && value["id"].as_str() == Some(self.blocked_request_id.as_str())
        {
            self.entered.send(()).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "response blocker observer closed",
                )
            })?;
            self.release.lock().unwrap().recv().map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "response blocker release closed",
                )
            })?;
        }
        self.outbound.push_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_ordered_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn close(&self) {
        self.outbound.close();
    }

    fn abort(&self) {
        self.outbound.abort();
    }
}

fn blocking_control_writer(
    request_id: &str,
) -> (
    MessageWriter,
    Arc<BoundedOutbound>,
    std::sync::mpsc::Receiver<()>,
    std::sync::mpsc::SyncSender<()>,
) {
    let outbound = Arc::new(BoundedOutbound::default());
    let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let writer = MessageWriter::new(BlockingControlSink {
        outbound: outbound.clone(),
        blocked_request_id: request_id.to_string(),
        entered: entered_tx,
        release: Mutex::new(release_rx),
    });
    (writer, outbound, entered_rx, release_tx)
}

struct BlockingFlushSink {
    outbound: Arc<BoundedOutbound>,
    entered: std::sync::mpsc::SyncSender<()>,
    release: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl MessageSink for BlockingFlushSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.outbound.push_regular(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        self.outbound.push_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_ordered_terminal(text, stream)
    }

    fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
        self.entered.send(()).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::BrokenPipe, "flush blocker observer closed")
        })?;
        self.release.lock().unwrap().recv().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::BrokenPipe, "flush blocker release closed")
        })
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn close(&self) {
        self.outbound.close();
    }

    fn abort(&self) {
        self.outbound.abort();
    }
}

struct TimedOutFlushSink {
    outbound: Arc<BoundedOutbound>,
}

impl MessageSink for TimedOutFlushSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.outbound.push_regular(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        self.outbound.push_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_ordered_terminal(text, stream)
    }

    fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "timed out while flushing the shutdown response",
        ))
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn close(&self) {
        self.outbound.close();
    }

    fn abort(&self) {
        self.outbound.abort();
    }
}

fn blocking_flush_writer() -> (
    MessageWriter,
    Arc<BoundedOutbound>,
    std::sync::mpsc::Receiver<()>,
    std::sync::mpsc::SyncSender<()>,
) {
    let outbound = Arc::new(BoundedOutbound::default());
    let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let writer = MessageWriter::new(BlockingFlushSink {
        outbound: outbound.clone(),
        entered: entered_tx,
        release: Mutex::new(release_rx),
    });
    (writer, outbound, entered_rx, release_tx)
}

fn pop_json(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(message) = outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "timed out waiting for outbound JSON");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn resource_request(
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<&str>,
) -> String {
    let mut request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        request["idempotency_key"] = json!(idempotency_key);
    }
    serde_json::to_string(&request).unwrap()
}

fn journal_subscription_filter(max_sensitivity: JournalSensitivity, mut filter: Value) -> Value {
    filter
        .as_object_mut()
        .expect("journal subscription filter fixture is an object")
        .insert("max_sensitivity".into(), json!(max_sensitivity));
    filter
}

fn test_stream_id(index: u64) -> StreamPublicId {
    StreamPublicId::parse(format!("stream_{index:032x}"))
        .expect("test stream id uses the public wire format")
}

fn active_clear_lanes_across_connections(request_count: usize, retained_bytes: usize) -> usize {
    let mux = test_mux();
    let writer = test_writer();
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let schedulers = [
        Arc::new(ConnectionSurfaceScheduler::new(admission.clone())),
        Arc::new(ConnectionSurfaceScheduler::new(admission)),
    ];
    let surfaces = (0..request_count)
        .map(|_| {
            let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
            surface.with_terminal(|term| {
                term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
            });
            surface
        })
        .collect::<Vec<_>>();

    for (index, surface) in surfaces.iter().enumerate() {
        let scheduler = &schedulers[index % schedulers.len()];
        let mut request = Some(Request {
            id: Some(json!(index)),
            cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
        });
        assert_eq!(
            scheduler.dispatch(mux.clone(), 0, &mut request, retained_bytes, writer.clone(),),
            Some(true)
        );
    }
    let active = schedulers
        .iter()
        .map(|scheduler| scheduler.state.lock().unwrap().active_clear_surfaces.len())
        .sum();

    for scheduler in &schedulers {
        let _ = scheduler.close_and_wait(Duration::from_secs(1));
    }
    for surface in surfaces {
        mux.close_surface(surface.id).unwrap();
    }
    active
}

#[derive(Default)]
struct FlushRecordingWriter {
    bytes: Vec<u8>,
    flushes: usize,
}

impl Write for FlushRecordingWriter {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.flushes += 1;
        Ok(())
    }
}

pub(super) fn json_command(value: Value) -> Command {
    serde_json::from_value::<Request>(value).unwrap().cmd
}

pub(super) fn drain_json(outbound: &BoundedOutbound) -> Vec<Value> {
    std::iter::from_fn(|| outbound.try_pop())
        .map(|message| serde_json::from_str(&message).expect("outbound JSON"))
        .collect()
}

pub(super) fn attach_test_view(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    writer: &MessageWriter,
) {
    let stream = writer.start_stream(&attach_overflow_json(surface)).unwrap();
    mux.control_clients.attach_surface(client, surface, stream.clone()).unwrap();
    commit_client_attach(mux, client, surface, stream.id, None, None).unwrap();
}

fn run_json_command(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &test_writer())
}

mod detach_and_browser;
mod event_shape_tests;
mod identify_and_protocol;
mod layout_receipts_shutdown;
mod outbound_and_scheduler;
mod resource_attach;
mod resource_waits;
mod session_streams;
mod sizing;
mod socket_and_render;
mod view_leases;
mod wire_commands;
