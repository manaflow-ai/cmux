//! The running half of a terminal host: its PTY reader, authoritative
//! parser, child watcher and exit publisher, started on a PTY master and a
//! child. The child is one the host spawned ([`HostChild::Spawned`]) or a
//! running session it adopted from a dead host ([`HostChild::Adopted`],
//! cx-6so.49 L1), which it does not parent and cannot reap.

use std::sync::PoisonError;

use super::adopted_child::AdoptedChild;
use super::*;

/// The process a host's PTY runs.
pub(super) enum HostChild {
    /// Spawned by this host: it waits on and reaps it.
    Spawned(SpawnedPtyChild),
    /// A running session of an earlier host of this terminal.
    Adopted(AdoptedChild),
}

impl HostChild {
    fn process_id(&self) -> Option<u32> {
        match self {
            Self::Spawned(child) => child.child().process_id(),
            Self::Adopted(child) => Some(child.pid()),
        }
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        match self {
            Self::Spawned(child) => child.child().clone_killer(),
            Self::Adopted(child) => child.killer(),
        }
    }

    fn adopted_session(&self) -> Option<libc::pid_t> {
        match self {
            Self::Spawned(_) => None,
            Self::Adopted(child) => Some(child.session_id()),
        }
    }

    /// Block until the child ended, without reaping it. False when that
    /// cannot be observed (the caller then waits and reaps directly).
    fn wait_exit_observed(&self) -> bool {
        match self {
            Self::Spawned(child) => child
                .child()
                .process_id()
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .is_some_and(|pid| wait_for_child_exit_without_reaping(pid).is_ok()),
            Self::Adopted(child) => {
                child.wait_for_exit();
                true
            }
        }
    }

    fn wait_and_disarm(&mut self) -> TerminalExit {
        match self {
            Self::Spawned(child) => child.wait_and_disarm(),
            // Not this host's child: its status went to its real parent.
            Self::Adopted(_) => TerminalExit::unknown(crate::terminal_end::EXIT_UNOBSERVED),
        }
    }
}

/// Start the host runtime on `master` and `child`. `seed` is VT replay of
/// an adopted session's screen, applied to the parser before any PTY byte;
/// it is empty for a spawned child.
pub(super) fn start_host_runtime(
    launch: &HostLaunch,
    bootstrapped: &crate::terminal_host::BootstrappedHost,
    master: Box<dyn MasterPty + Send>,
    mut child: HostChild,
    seed: &[u8],
) -> anyhow::Result<Arc<HostShared>> {
    let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
    let pid = child.process_id();
    let killer = child.clone_killer();
    let pty_poll_fd = master.as_raw_fd().context("open terminal-host PTY poll fd")?;
    let mut pty_reader = master.try_clone_reader()?;
    let pty_writer = master.take_writer()?;
    let (pty_drain_waker, pty_drain_waiter) = UnixStream::pair()?;

    let clipboard = ClipboardReads::new(Arc::new(SystemClock));
    let signals = ParserSignals::new();
    let callbacks = signals.callbacks(&clipboard);
    let mut term = Terminal::new(launch.cols, launch.rows, launch.scrollback, callbacks)?;
    term.resize(launch.cols, launch.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
    term.set_kitty_graphics_limits(launch.kitty_graphics_limits)?;
    term.replace_default_colors(
        launch.default_colors.fg,
        launch.default_colors.bg,
        launch.default_colors.cursor,
    );
    term.set_default_palette(&launch.default_colors.palette);
    replace_ghostty_cursor_defaults(&mut term, launch.default_colors);
    if !seed.is_empty() {
        // The adopted session's earlier screen, from the owner's mirror. It
        // reaches only this parser: replies to queries it holds are dropped,
        // never written to the running program.
        term.vt_write(seed);
        signals.pending_responses.lock().unwrap_or_else(PoisonError::into_inner).clear();
        signals.bell.store(false, Ordering::Release);
    }
    // The seed's OSC 9;4 progress (the owner appends its last value) reaches
    // this host's metadata too, so later snapshots keep it.
    let mut terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();
    if !seed.is_empty() {
        terminal_metadata.observe_output(seed);
        let _ = terminal_metadata.take_notifications();
        let _ = terminal_metadata.take_shell_marks();
    }
    let initial_colors = term.color_overrides();
    let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
    let (parser_commands, parser_command_receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let shared = Arc::new(HostShared {
        terminal_id: bootstrapped.terminal_id,
        incarnation: bootstrapped.incarnation,
        owner_token: bootstrapped.owner_token(),
        capabilities: CapabilityStore::new(64),
        term: Mutex::new(term),
        terminal_metadata: Mutex::new(terminal_metadata),
        default_colors: Mutex::new(launch.default_colors),
        stream_progress: TerminalStreamProgress::default(),
        writer: Mutex::new(pty_writer),
        master: Mutex::new(master),
        killer: Mutex::new(killer),
        pid,
        command: launch.command.clone(),
        cwd: launch.cwd.clone(),
        size: Mutex::new((launch.cols, launch.rows)),
        cell_pixels: Mutex::new(cell_pixels),
        viewer_sizes: Mutex::new(ViewerSizes::default()),
        taps: Mutex::new(HashMap::new()),
        broadcast_lock: Mutex::new(()),
        sequence: AtomicU64::new(0),
        smart: SmartStreamState::new(),
        source_order_lock: Mutex::new(()),
        parser_commands,
        parser_budget: ParserBudget::new(MAX_HOST_PARSER_QUEUED_BYTES),
        clipboard,
        parser_progress: (Mutex::new(0), Condvar::new()),
        next_client: AtomicU64::new(1),
        dead: AtomicBool::new(false),
        launch_owner_claimed: AtomicBool::new(false),
        launch_owner_stream_ready: AtomicBool::new(false),
        launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
        active_client_streams: AtomicUsize::new(0),
        accept_waker: AcceptWaker::new()?,
        child_exit: (Mutex::new(None), Condvar::new()),
        child_waitable: AtomicBool::new(false),
        pty_drained: AtomicBool::new(false),
        exit_published: AtomicBool::new(false),
        exit_record_path: Path::new(&launch.record_path).with_extension("exit"),
        exit_publish_requests,
        force_pty_drain: AtomicBool::new(false),
        pty_drain_waker: Mutex::new(pty_drain_waker),
        termination_started: AtomicBool::new(false),
        child_signal_lock: Mutex::new(()),
        child_reaped: AtomicBool::new(false),
        group_escalation_complete: AtomicBool::new(false),
        adopted_session: child.adopted_session(),
        #[cfg(test)]
        fail_next_resize_publication: AtomicBool::new(false),
    });
    HostShared::start_exit_publisher(&shared, exit_publish_receiver)?;
    shared.clipboard.start_timer(&shared)?;

    let parser_host = shared.clone();
    thread::Builder::new().name("terminal-host-parser".into()).spawn(move || {
        let guarded = parser_host.clone();
        let parse = move || {
            run_host_parser(parser_host, parser_command_receiver, initial_colors, signals);
        };
        run_guarded_host_parser(&guarded, parse, || {
            // crash-allow: the exit is published (or its bound passed); end the host.
            std::process::exit(host_parser::PARSER_FAILURE_EXIT_CODE)
        });
    })?;

    let reader_host = shared.clone();
    thread::Builder::new().name("terminal-host-pty".into()).spawn(move || {
        reader_host.wait_for_launch_owner_stream_ready();
        let mut buffer = [0u8; 64 * 1024];
        let mut forced_at = None;
        let mut pty_drain_waiter = pty_drain_waiter;
        while let Ok(true) = wait_for_pty_readable_or_forced_drain(
            pty_poll_fd,
            &mut pty_drain_waiter,
            &reader_host.force_pty_drain,
            &mut forced_at,
        ) {
            let count = match pty_reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => count,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                    ) =>
                {
                    continue;
                }
                Err(_) => break,
            };
            let bytes = buffer[..count].to_vec();
            let _source_order = reader_host.source_order_lock.lock().unwrap();
            reader_host.parser_budget.reserve(count);
            // Publication deliberately precedes parser enqueue. The
            // bounded queue limits memory while letting a fast renderer
            // consume source bytes independently of parser throughput.
            let source_cursor =
                reader_host.smart.publish(Frame::new(MessageKind::Output, bytes.clone()));
            if !enqueue_parser_output(
                &reader_host.parser_commands,
                &reader_host.parser_budget,
                &reader_host.smart,
                bytes,
                source_cursor,
                count,
            ) {
                break;
            }
        }
        // Drain is ordered after the final source byte. The parser worker,
        // rather than the reader, publishes the drained rendezvous.
        let _source_order = reader_host.source_order_lock.lock().unwrap();
        let _ = reader_host.parser_commands.send(ParserCommand::Drain);
    })?;
    let child_host = shared.clone();
    thread::Builder::new().name("terminal-host-child".into()).spawn(move || {
        let observed_without_reaping = child.wait_exit_observed();
        if observed_without_reaping {
            child_host.mark_child_waitable();
            let mut drain = exited_drain::ExitedDrain::start();
            loop {
                let signal = child_host.child_signal_lock.lock().unwrap();
                let escalation_complete =
                    child_host.group_escalation_complete.load(Ordering::Acquire);
                let termination_started = child_host.termination_started.load(Ordering::Acquire);
                let pty_drained = child_host.pty_drained.load(Ordering::Acquire);
                if escalation_complete || (!termination_started && pty_drained) {
                    let exit = child.wait_and_disarm();
                    child_host.child_reaped.store(true, Ordering::Release);
                    drop(signal);
                    *child_host.child_exit.0.lock().unwrap() = Some(exit);
                    break;
                }
                drop(signal);
                let state = child_host.child_exit.0.lock().unwrap();
                drain.wait(&child_host, state);
            }
            child_host.child_exit.1.notify_all();
            child_host.publish_exit_if_drained();
        } else {
            // Native Unix PTYs always expose a PID and support waitid;
            // retain a conservative fallback for alternate backends.
            let exit = child.wait_and_disarm();
            child_host.child_reaped.store(true, Ordering::Release);
            child_host.mark_child_waitable();
            let mut exited = child_host.child_exit.0.lock().unwrap();
            *exited = Some(exit);
            child_host.child_exit.1.notify_all();
            child_host.publish_exit_if_drained();
        }
    })?;
    Ok(shared)
}

fn wait_for_child_exit_without_reaping(pid: libc::pid_t) -> std::io::Result<()> {
    loop {
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::uninit();
        // SAFETY: status points to writable siginfo storage. WNOWAIT
        // observes this owned child becoming waitable without releasing
        // its PID/PGID for reuse; the portable Child handle reaps it after
        // acquiring child_signal_lock.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
