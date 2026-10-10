//! Unit tests of the Unix terminal-host runtime (`mod unix`): shared test
//! doubles and fixtures here, tests by topic in `tests/`.

mod attach_protocol;
mod clipboard_read;
mod host_fixture;
mod input_records;
mod launch_codec;
mod parser_failure;
mod parser_order;
mod smart_viewer_exit;
use super::super::shared::control_responses::ControlResponseWaiter;
use super::super::shared::host_serve::*;
use super::super::sys::process_definitely_gone as process_definitely_absent;
use super::super::sys::{HostLivenessLease, terminal_host_publication_lock_path};
use super::*;
use crate::lock_rank::RankedMutex;
use cmux_pty::{Child, PtyOpenError, PtySize};
use ghostty_vt::Callbacks;
use ghostty_vt::CursorShape;
use host_fixture::{test_host_shared, test_host_shared_with};
use std::os::unix::fs::PermissionsExt;
use std::sync::TryLockError;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender};

fn test_kitty_state() -> KittyReplayState {
    KittyReplayState {
        limits: KittyGraphicsLimits { image_bytes: 1, inflight_bytes: 2, images: 3, placements: 4 },
        replay_cursor_offset: 0,
        replay_next_image_ids: KittyImageIdCursors { primary: 5, alternate: 7 },
        next_image_ids: KittyImageIdCursors { primary: 6, alternate: 8 },
    }
}

struct TestHostMaster {
    size: Mutex<PtySize>,
}

impl MasterPty for TestHostMaster {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    fn as_raw_fd(&self) -> Option<RawFd> {
        None
    }

    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

#[derive(Debug)]
struct TestHostKiller;

impl ChildKiller for TestHostKiller {
    fn kill(&mut self) -> std::io::Result<()> {
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(Self)
    }
}

#[derive(Debug)]
struct GuardTestChild {
    kills: Arc<AtomicUsize>,
}

impl ChildKiller for GuardTestChild {
    fn kill(&mut self) -> std::io::Result<()> {
        self.kills.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(Self { kills: Arc::clone(&self.kills) })
    }
}

impl Child for GuardTestChild {
    fn try_wait(&mut self) -> std::io::Result<Option<cmux_pty::ExitStatus>> {
        Ok(Some(cmux_pty::ExitStatus::with_exit_code(0)))
    }

    fn wait(&mut self) -> std::io::Result<cmux_pty::ExitStatus> {
        Ok(cmux_pty::ExitStatus::with_exit_code(0))
    }

    fn process_id(&self) -> Option<u32> {
        Some(42)
    }
}

fn exited_host_fixture_with_parser_at(
    exit_record_parent: PathBuf,
) -> (Arc<HostShared>, Receiver<ParserCommand>) {
    let mut term = Terminal::new(80, 24, 1_000, Callbacks::default()).unwrap();
    term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
        .unwrap();
    let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
    let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
    let (parser_commands, parser_receiver) = sync_channel(1);
    let terminal_id = TerminalId::random().unwrap();
    let exit_record_path = exit_record_parent.join(format!("{}.exit", terminal_id.to_hex()));
    let host = Arc::new(HostShared {
        terminal_id,
        incarnation: HostIncarnation::random().unwrap(),
        owner_token: CapabilityToken::random().unwrap(),
        capabilities: CapabilityStore::new(64),
        term: RankedMutex::new(term),
        terminal_metadata: RankedMutex::new(crate::terminal_metadata::TerminalMetadata::default()),
        default_colors: RankedMutex::new(DefaultColors::default()),
        stream_progress: TerminalStreamProgress::default(),
        writer: RankedMutex::new(Box::new(std::io::sink())),
        master: RankedMutex::new(Box::new(TestHostMaster {
            size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap()),
        })),
        killer: Mutex::new(Box::new(TestHostKiller)),
        pid: None,
        command: Vec::new(),
        cwd: None,
        size: RankedMutex::new((80, 24)),
        cell_pixels: RankedMutex::new(DEFAULT_CELL_PIXELS),
        viewer_sizes: RankedMutex::new(ViewerSizes::default()),
        taps: RankedMutex::new(HashMap::new()),
        broadcast_lock: Mutex::new(()),
        sequence: AtomicU64::new(0),
        smart: SmartStreamState::new(),
        source_order_lock: RankedMutex::new(()),
        parser_commands,
        parser_budget: ParserBudget::new(1),
        clipboard: ClipboardReads::new(Arc::new(SystemClock)),
        parser_progress: (RankedMutex::new(0), Condvar::new()),
        next_client: AtomicU64::new(1),
        dead: AtomicBool::new(false),
        launch_owner_claimed: AtomicBool::new(true),
        launch_owner_stream_ready: AtomicBool::new(true),
        launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
        active_client_streams: AtomicUsize::new(0),
        accept_waker: AcceptWaker::new().unwrap(),
        child_exit: (
            Mutex::new(Some(TerminalExit {
                outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
                exited_at_ms: 1_234,
            })),
            Condvar::new(),
        ),
        child_waitable: AtomicBool::new(true),
        pty_drained: AtomicBool::new(true),
        exit_published: AtomicBool::new(false),
        exit_record_path,
        exit_publish_requests,
        force_pty_drain: AtomicBool::new(false),
        pty_drain_waker: Mutex::new(pty_drain_waker),
        termination_started: AtomicBool::new(false),
        child_signal_lock: RankedMutex::new(()),
        child_reaped: AtomicBool::new(true),
        group_escalation_complete: AtomicBool::new(false),
        adopted_session: None,
        fail_next_resize_publication: AtomicBool::new(false),
    });
    HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
    (host, parser_receiver)
}

fn exited_host_fixture_at(exit_record_parent: PathBuf) -> Arc<HostShared> {
    exited_host_fixture_with_parser_at(exit_record_parent).0
}

fn exited_host_fixture() -> Arc<HostShared> {
    let root = std::env::temp_dir().join(format!(
        "cmux-terminal-exit-tests-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&root).unwrap();
    exited_host_fixture_at(root)
}

fn exited_host_fixture_with_parser() -> (Arc<HostShared>, Receiver<ParserCommand>) {
    let root = std::env::temp_dir().join(format!(
        "cmux-terminal-exit-tests-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&root).unwrap();
    exited_host_fixture_with_parser_at(root)
}

fn record_fixture(name: &str) -> (PathBuf, TerminalHostRecord, HostLivenessLease) {
    let root = std::env::temp_dir().join(format!(
        "cmux-host-record-{name}-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&root).unwrap();
    let terminal_id = TerminalId::random().unwrap();
    let incarnation = HostIncarnation::random().unwrap();
    let owner = CapabilityToken::random().unwrap();
    let nonce = CapabilityToken::random().unwrap();
    let terminal_hex = terminal_id.to_hex();
    let uid = fs::metadata(&root).unwrap().uid();
    let record = TerminalHostRecord {
        record_version: HOST_RECORD_VERSION,
        terminal_id: terminal_hex.clone(),
        incarnation: incarnation.to_hex(),
        endpoint: format!("/tmp/cmux-th-{uid}/{terminal_hex}.sock"),
        owner_token: encode_hex(owner.as_bytes()),
        host_pid: std::process::id(),
        host_start_nonce: encode_hex(nonce.as_bytes()),
        workspace_key: String::new(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: true,
        supports_input_ack: true,
        supports_terminal_metadata: true,
        supports_clipboard_read: false,
        supports_viewer_size_priority: true,
        supports_pty_custody: false,
    };
    let record_path = record.record_path(&root);
    let lease = HostLivenessLease::acquire(liveness_path(&record_path, &record)).unwrap();
    write_record(&record_path, &record).unwrap();
    (record_path, record, lease)
}

pub(crate) fn input_ack_surface_fixture() -> (HostAttachment, UnixStream) {
    let terminal_id = TerminalId::random().unwrap();
    let incarnation = HostIncarnation::random().unwrap();
    let owner = CapabilityToken::random().unwrap();
    let nonce = CapabilityToken::random().unwrap();
    let record = TerminalHostRecord {
        record_version: HOST_RECORD_VERSION,
        terminal_id: terminal_id.to_hex(),
        incarnation: incarnation.to_hex(),
        endpoint: "/tmp/cmux-input-ack-surface-test.sock".into(),
        owner_token: encode_hex(owner.as_bytes()),
        host_pid: std::process::id(),
        host_start_nonce: encode_hex(nonce.as_bytes()),
        workspace_key: String::new(),
        supports_set_defaults: false,
        supports_clear_history: false,
        supports_terminate_ack: false,
        supports_input_ack: true,
        supports_terminal_metadata: false,
        supports_clipboard_read: false,
        supports_viewer_size_priority: false,
        supports_pty_custody: false,
    };
    let record_path = std::env::temp_dir().join(format!(
        "cmux-input-ack-surface-{}-{}.json",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let (client, host) = UnixStream::pair().unwrap();
    let reader = client.try_clone().unwrap();
    let attachment = HostAttachment {
        record,
        record_path,
        snapshot: HostSnapshot {
            cols: 80,
            rows: 24,
            cell_pixels: DEFAULT_CELL_PIXELS,
            replay: Vec::new(),
            kitty_image_aliases: Vec::new(),
            kitty_state: test_kitty_state(),
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid: None,
            command: Vec::new(),
            cwd: None,
            osc_progress: String::new(),
        },
        protocol_version: PROTOCOL_VERSION,
        smart_renderer: false,
        reader: Some(reader),
        writer: Arc::new(RankedMutex::new(client)),
        control_responses: Arc::new(ControlResponses::new()),
        next_request: AtomicU64::new(2),
        viewer_size: RankedMutex::new(None),
        launch_process: None,
        launch_activation_pending: false,
        pty_custody: None,
    };
    (attachment, host)
}

fn snapshot_boundary_client_hello(host: &HostShared, smart: bool) -> anyhow::Result<Frame> {
    let (role, rights, token) = if smart {
        (
            ClientRole::Renderer,
            CapabilityRights::RENDERER,
            host.capabilities.mint(
                host.terminal_id,
                CapabilityRights::RENDERER,
                Duration::from_secs(1),
            )?,
        )
    } else {
        (ClientRole::Admin, CapabilityRights::ADMIN, host.owner_token)
    };
    let mut hello = ClientHello {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        role,
        requested_rights: rights,
        terminal_id: host.terminal_id,
        token,
    }
    .into_frame(1);
    if smart {
        hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
    }
    Ok(hello)
}
