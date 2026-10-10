//! A live-parser-free `HostShared` for host tests, optionally with a
//! caller's terminal, parser channel and clipboard broker.

use super::*;

pub(super) fn test_host_shared() -> Arc<HostShared> {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, _parser_receiver) = sync_channel(1);
    test_host_shared_with(term, parser_commands, ClipboardReads::new(Arc::new(SystemClock)))
}

pub(super) fn test_host_shared_with(
    mut term: Terminal,
    parser_commands: SyncSender<ParserCommand>,
    clipboard: ClipboardReads,
) -> Arc<HostShared> {
    term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
        .unwrap();
    let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
    let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
    let host = Arc::new(HostShared {
        terminal_id: TerminalId::random().unwrap(),
        incarnation: HostIncarnation::random().unwrap(),
        owner_token: CapabilityToken::random().unwrap(),
        capabilities: CapabilityStore::new(64),
        term: Mutex::new(term),
        terminal_metadata: Mutex::new(crate::terminal_metadata::TerminalMetadata::default()),
        default_colors: Mutex::new(DefaultColors::default()),
        stream_progress: TerminalStreamProgress::default(),
        writer: Mutex::new(Box::new(std::io::sink())),
        master: Mutex::new(Box::new(TestHostMaster {
            size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap()),
        })),
        killer: Mutex::new(Box::new(TestHostKiller)),
        pid: None,
        command: vec!["/bin/cat".into()],
        cwd: None,
        size: Mutex::new((80, 24)),
        cell_pixels: Mutex::new(DEFAULT_CELL_PIXELS),
        viewer_sizes: Mutex::new(ViewerSizes::default()),
        taps: Mutex::new(HashMap::new()),
        broadcast_lock: Mutex::new(()),
        sequence: AtomicU64::new(0),
        smart: SmartStreamState::new(),
        source_order_lock: Mutex::new(()),
        parser_commands,
        parser_budget: ParserBudget::new(1),
        clipboard,
        parser_progress: (Mutex::new(0), Condvar::new()),
        next_client: AtomicU64::new(1),
        dead: AtomicBool::new(false),
        launch_owner_claimed: AtomicBool::new(false),
        launch_owner_stream_ready: AtomicBool::new(false),
        launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
        active_client_streams: AtomicUsize::new(0),
        accept_waker: AcceptWaker::new().unwrap(),
        child_exit: (Mutex::new(None), Condvar::new()),
        child_waitable: AtomicBool::new(false),
        pty_drained: AtomicBool::new(false),
        exit_published: AtomicBool::new(false),
        exit_record_path: std::env::temp_dir().join(format!(
            "cmux-host-test-exit-{}-{}",
            std::process::id(),
            RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        )),
        exit_publish_requests,
        force_pty_drain: AtomicBool::new(false),
        pty_drain_waker: Mutex::new(pty_drain_waker),
        termination_started: AtomicBool::new(false),
        child_signal_lock: Mutex::new(()),
        child_reaped: AtomicBool::new(false),
        group_escalation_complete: AtomicBool::new(false),
        adopted_session: None,
        fail_next_resize_publication: AtomicBool::new(false),
    });
    HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
    host
}
