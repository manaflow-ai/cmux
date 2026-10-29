//! Host side of one client connection that touches no OS API (cx-ko2e
//! table A): the launch-owner barrier claim, the active-stream count that
//! wakes the accept loop, the client-setup rollback, client
//! authentication, renderer-capability minting, and the per-client
//! connection loop (`serve_client*`) over `HostStream`.

use crate::panic_free::RecoverPoison;
use std::borrow::Cow;
use std::io::Write;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::mpsc::channel as mpsc_channel;
use std::sync::{Arc, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

use super::super::sys::{self, HostStream};
use super::super::*;
use super::clipboard_read::*;
use super::codec::*;
use super::host_shared::{HostLoop, HostShared};
use super::host_state::*;

mod stdio;
// Only the Unix host process runs this loop until the Windows host lands.
#[cfg_attr(not(unix), allow(unused_imports))]
pub use stdio::{serve_terminal_host_process, serve_terminal_host_stdio};

pub(crate) struct LaunchOwnerConnection {
    pub(crate) host: Arc<HostShared>,
    pub(crate) claimed: bool,
}

impl LaunchOwnerConnection {
    pub(crate) fn claim(host: Arc<HostShared>, granted_rights: CapabilityRights) -> Self {
        let claimed = granted_rights.contains(CapabilityRights::ADMIN)
            && host
                .launch_owner_claimed
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok();
        Self { host, claimed }
    }

    pub(crate) fn stream_ready(&self) {
        if !self.claimed {
            return;
        }
        self.host.mark_launch_owner_stream_ready();
    }
}

impl Drop for LaunchOwnerConnection {
    fn drop(&mut self) {
        if !self.claimed {
            return;
        }
        // A failed initial stream must release the same launch barrier as
        // a successful one. The launching daemon reports the handshake
        // failure, while the independently hosted process can still
        // publish or clean up its terminal exit.
        self.host.mark_launch_owner_stream_ready();
    }
}

pub(crate) struct ActiveClientStream {
    pub(crate) host: Arc<HostShared>,
}

impl ActiveClientStream {
    pub(crate) fn register(host: Arc<HostShared>) -> Self {
        // The first stream ends an orphan clock: wake the accept loop so it
        // stops counting (cx-3ryj), as the last stream's drop wakes it.
        if host.active_client_streams.fetch_add(1, Ordering::AcqRel) == 0 {
            host.accept_waker.wake();
        }
        Self { host }
    }
}

impl Drop for ActiveClientStream {
    fn drop(&mut self) {
        let previous = self.host.active_client_streams.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous > 0, "active terminal-host stream underflow");
        if previous == 1 {
            self.host.accept_waker.wake();
        }
    }
}

pub(crate) struct ClientSetupRollback {
    pub(crate) host: Arc<HostShared>,
    pub(crate) client: u64,
    pub(crate) armed: bool,
}

impl ClientSetupRollback {
    pub(crate) fn new(host: Arc<HostShared>, client: u64) -> Self {
        Self { host, client, armed: true }
    }

    pub(crate) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ClientSetupRollback {
    fn drop(&mut self) {
        if self.armed {
            self.host.remove_client(self.client);
        }
    }
}

pub(crate) fn authenticate_client(
    host: &HostShared,
    hello: &ClientHello,
) -> anyhow::Result<HostHello> {
    if hello.terminal_id != host.terminal_id {
        anyhow::bail!("terminal-host capability denied");
    }
    if constant_time_equal(hello.token.as_bytes(), host.owner_token.as_bytes()) {
        if hello.role != ClientRole::Admin
            || !owner_rights_allowed(hello.requested_rights)
            || hello.min_version > PROTOCOL_VERSION
            || hello.max_version < PROTOCOL_VERSION
        {
            anyhow::bail!("terminal-host owner capability denied");
        }
        return Ok(HostHello {
            selected_version: PROTOCOL_VERSION,
            granted_rights: hello.requested_rights,
            terminal_id: host.terminal_id,
            incarnation: host.incarnation,
        });
    }
    Ok(host.capabilities.accept(hello, PROTOCOL_VERSION..=PROTOCOL_VERSION, host.incarnation)?)
}

pub(crate) fn mint_renderer_capability(
    host: &HostShared,
    payload: &[u8],
) -> anyhow::Result<CapabilityToken> {
    if payload.len() != 8 {
        anyhow::bail!("bad renderer capability request");
    }
    let field = |offset| {
        crate::terminal_host_protocol::wire_u32(payload, offset)
            .ok_or_else(|| anyhow::anyhow!("bad renderer capability request"))
    };
    let rights = CapabilityRights::from_bits(field(0)?)
        .ok_or_else(|| anyhow::anyhow!("unknown renderer capability rights"))?;
    if !rights.contains(CapabilityRights::READ) || !CapabilityRights::RENDERER.contains(rights) {
        anyhow::bail!("renderer capability rights are out of range");
    }
    let ttl_ms = field(4)?;
    let ttl = Duration::from_millis(u64::from(ttl_ms));
    if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
        anyhow::bail!("renderer capability TTL is out of range");
    }
    Ok(host.capabilities.mint(host.terminal_id, rights, ttl)?)
}

pub(crate) fn send_snapshot_resync(
    host: &HostShared,
    stream: &mut HostStream,
    smart_renderer: bool,
) {
    let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
    resync.sequence = if smart_renderer {
        host.smart.applied_cursor.load(Ordering::Acquire)
    } else {
        host.sequence.load(Ordering::Acquire)
    };
    let _ = write_frame(stream, &resync);
}

/// The snapshot's geometry try-lock lost to a resize or cell-metric writer:
/// step aside for it before trying again (the parser guard is already
/// dropped, so that writer can finish).
fn yield_to_geometry_writer(remaining: Duration) {
    // wakeup-allow: bounded retries only while a writer holds the geometry during a client's attach,
    // never past the snapshot deadline; an idle host never reaches this
    thread::park_timeout(remaining.min(Duration::from_millis(1)));
}

pub(crate) fn serve_client(host: Arc<HostShared>, stream: HostStream) -> anyhow::Result<()> {
    serve_client_with_snapshot_timeout(host, stream, HOST_SNAPSHOT_BOUNDARY_TIMEOUT)
}

pub(crate) fn serve_client_with_snapshot_timeout(
    host: Arc<HostShared>,
    mut stream: HostStream,
    snapshot_timeout: Duration,
) -> anyhow::Result<()> {
    // A client that stops reading must not retain an exited host forever.
    // Bound the actual stalled resource instead of imposing a wall-clock
    // deadline on healthy clients that are still draining sequenced bytes.
    stream.set_write_timeout(Some(HOST_CLIENT_WRITE_TIMEOUT))?;
    let hello_frame = read_required_frame(&mut stream, "client hello")?;
    if hello_frame.kind != MessageKind::ClientHello
        || hello_frame.sequence != 0
        || hello_frame.flags
            & !(FLAG_VIEWER_SIZE_ACKS
                | FLAG_SMART_RENDERER
                | FLAG_TERMINAL_METADATA
                | FLAG_VIEWER_SIZE_PRIORITY
                | FLAG_PTY_CUSTODY
                | FLAG_PROGRAM_STATUS
                | FLAG_SHELL_ACTIVITY
                | FLAG_INPUT_FLOW
                | FLAG_INPUT_STAGES)
            != 0
        || (hello_frame.flags & FLAG_TERMINAL_METADATA != 0
            && hello_frame.version != PROTOCOL_VERSION)
        || (hello_frame.flags & FLAG_INPUT_FLOW != 0 && hello_frame.version != PROTOCOL_VERSION)
        || (hello_frame.flags & FLAG_INPUT_STAGES != 0 && hello_frame.flags & FLAG_INPUT_FLOW == 0)
        || (hello_frame.flags & FLAG_PROGRAM_STATUS != 0
            && hello_frame.flags & FLAG_TERMINAL_METADATA == 0)
        || (hello_frame.flags & FLAG_SHELL_ACTIVITY != 0
            && hello_frame.flags & FLAG_TERMINAL_METADATA == 0)
    {
        anyhow::bail!("terminal-host client did not send ClientHello");
    }
    let hello = ClientHello::decode(&hello_frame.payload)?;
    let response = authenticate_client(&host, &hello)?;
    if hello_frame.flags & FLAG_PTY_CUSTODY != 0 {
        return sys::serve_pty_custody(&host, stream, &hello_frame, &hello, &response);
    }
    if hello_frame.version != response.selected_version
        || !response.granted_rights.contains(CapabilityRights::READ)
    {
        anyhow::bail!("terminal-host capability denied");
    }
    let selected_version = response.selected_version;
    let granted_rights = response.granted_rights;
    let launch_owner = LaunchOwnerConnection::claim(host.clone(), granted_rights);
    let launch_owner_claimed = launch_owner.claimed;
    let activation_required = launch_owner_claimed
        && selected_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION
        && !host.launch_owner_stream_ready.load(Ordering::Acquire);
    let viewer_size_acks = hello_frame.flags & FLAG_VIEWER_SIZE_ACKS != 0
        && granted_rights.contains(CapabilityRights::RESIZE);
    let smart_renderer = selected_version >= SMART_RENDERER_PROTOCOL_VERSION
        && hello_frame.flags & FLAG_SMART_RENDERER != 0
        && matches!(hello.role, ClientRole::Renderer | ClientRole::Admin);
    let terminal_metadata =
        selected_version == PROTOCOL_VERSION && hello_frame.flags & FLAG_TERMINAL_METADATA != 0;
    let program_status_negotiated =
        terminal_metadata && hello_frame.flags & FLAG_PROGRAM_STATUS != 0;
    let shell_activity_negotiated =
        terminal_metadata && hello_frame.flags & FLAG_SHELL_ACTIVITY != 0;
    let viewer_size_priority = hello_frame.flags & FLAG_VIEWER_SIZE_PRIORITY != 0
        && hello.role == ClientRole::Renderer
        && granted_rights.contains(CapabilityRights::RESIZE);
    let mut hello_response = Frame::new(MessageKind::HostHello, response.encode());
    if viewer_size_acks {
        hello_response.flags |= FLAG_VIEWER_SIZE_ACKS;
    }
    if viewer_size_priority {
        hello_response.flags |= FLAG_VIEWER_SIZE_PRIORITY;
    }
    if activation_required {
        hello_response.flags |= FLAG_LAUNCH_ACTIVATION_REQUIRED;
    }
    if smart_renderer {
        hello_response.flags |= FLAG_SMART_RENDERER;
    }
    if terminal_metadata {
        hello_response.flags |= FLAG_TERMINAL_METADATA;
    }
    if program_status_negotiated {
        hello_response.flags |= FLAG_PROGRAM_STATUS;
    }
    if shell_activity_negotiated {
        hello_response.flags |= FLAG_SHELL_ACTIVITY;
    }
    // Key-press flows: only a client that may write input, and on the
    // smart stream, whose Output frames carry the flow of the read they come from.
    let input_flow = hello_frame.flags & FLAG_INPUT_FLOW != 0
        && selected_version == PROTOCOL_VERSION
        && smart_renderer
        && granted_rights.contains(CapabilityRights::INPUT);
    if input_flow {
        hello_response.flags |= FLAG_INPUT_FLOW;
    }
    // Key stages ride on the flow's Output frames.
    let input_stages = input_flow && hello_frame.flags & FLAG_INPUT_STAGES != 0;
    if input_stages {
        hello_response.flags |= FLAG_INPUT_STAGES;
    }
    hello_response.request_id = hello_frame.request_id;
    write_frame(&mut stream, &hello_response)?;

    let client = host.next_client.fetch_add(1, Ordering::Relaxed);
    // Queue admission is bounded by HostTap's byte counters. A fixed
    // channel capacity would make harmless PTY fragmentation observable
    // as a renderer disconnect.
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(stream.try_clone()?), MAX_HOST_CLIENT_QUEUED_BYTES);
    let command_sender = tap.clone();
    let (snapshot, colors, snapshot_sequence, replay_gap, _active_client_stream) = {
        // Wait for a parser boundary without blocking resize or cell-metric
        // writers. Try-locking geometry while the safe parser guard is held
        // gives the snapshot one atomic state without reversing the normal
        // blocking lock order.
        let snapshot_deadline = Instant::now() + snapshot_timeout;
        let (mut viewer_sizes, size, cell_pixels, mut term) = loop {
            let remaining = snapshot_deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                send_snapshot_resync(&host, &mut stream, smart_renderer);
                anyhow::bail!("terminal snapshot geometry did not stabilize before timeout");
            }
            let term = match host.terminal_at_snapshot_boundary(remaining) {
                Ok(term) => term,
                Err(error) => {
                    send_snapshot_resync(&host, &mut stream, smart_renderer);
                    return Err(error);
                }
            };
            let viewer_sizes = match host.viewer_sizes.try_lock() {
                Ok(guard) => guard,
                Err(TryLockError::WouldBlock) => {
                    drop(term);
                    yield_to_geometry_writer(remaining);
                    continue;
                }
                Err(TryLockError::Poisoned(_)) => {
                    drop(term);
                    send_snapshot_resync(&host, &mut stream, smart_renderer);
                    anyhow::bail!("terminal snapshot viewer-size state is poisoned");
                }
            };
            let size = match host.size.try_lock() {
                Ok(guard) => guard,
                Err(TryLockError::WouldBlock) => {
                    drop(viewer_sizes);
                    drop(term);
                    yield_to_geometry_writer(remaining);
                    continue;
                }
                Err(TryLockError::Poisoned(_)) => {
                    drop(viewer_sizes);
                    drop(term);
                    send_snapshot_resync(&host, &mut stream, smart_renderer);
                    anyhow::bail!("terminal snapshot size state is poisoned");
                }
            };
            let cell_pixels = match host.cell_pixels.try_lock() {
                Ok(guard) => guard,
                Err(TryLockError::WouldBlock) => {
                    drop(size);
                    drop(viewer_sizes);
                    drop(term);
                    yield_to_geometry_writer(remaining);
                    continue;
                }
                Err(TryLockError::Poisoned(_)) => {
                    drop(size);
                    drop(viewer_sizes);
                    drop(term);
                    send_snapshot_resync(&host, &mut stream, smart_renderer);
                    anyhow::bail!("terminal snapshot cell-pixel state is poisoned");
                }
            };
            break (viewer_sizes, size, cell_pixels, term);
        };
        let replay = term
            .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)?;
        let colors = term.color_overrides();
        let (osc_progress, shell_activity, program_status) = {
            let metadata = host.terminal_metadata.lock().recover_poison();
            // The parser feeds the records under the terminal lock held
            // here, so they match the replay.
            let records = program_status_negotiated.then(|| {
                let records = metadata.program_status();
                let records = records.lock().recover_poison();
                records.snapshot()
            });
            let shell_activity = shell_activity_negotiated.then(|| metadata.activity.snapshot());
            (metadata.osc_progress().to_owned(), shell_activity, records)
        };
        let (cols, rows) = *size;
        let cell_pixels = *cell_pixels;
        debug_assert_eq!((term.cols(), term.rows()), (cols, rows));
        if host.dead.load(Ordering::Acquire) {
            anyhow::bail!("terminal host exited before snapshot");
        }
        let active_client_stream = ActiveClientStream::register(host.clone());
        // A renderer needs an initial reservation until it reports its
        // measured grid. Admin and read-only mirror connections are
        // management/observation channels and must never pin the PTY to
        // the snapshot size merely by connecting. Priority starts with the
        // reservation so other viewers cannot move the grid before this
        // renderer reports its measured size.
        if hello.role == ClientRole::Renderer && granted_rights.contains(CapabilityRights::RESIZE) {
            viewer_sizes.sizes.insert(client, (cols, rows));
            if viewer_size_priority {
                viewer_sizes.preferred.insert(client);
            }
        }
        let (snapshot_sequence, replay_gap) = if smart_renderer {
            match host.smart.subscribe(client, tap.clone()) {
                Ok(boundary) => (boundary, None),
                Err(gap) => (host.smart.applied_cursor.load(Ordering::Acquire), Some(gap)),
            }
        } else {
            let _broadcast = host.broadcast_lock.lock().recover_poison();
            host.taps.lock().recover_poison().insert(client, tap.clone());
            (host.sequence.load(Ordering::Acquire), None)
        };
        (
            HostSnapshot {
                cols,
                rows,
                cell_pixels,
                replay: replay.self_contained_bytes().into_owned(),
                kitty_image_aliases: replay.kitty_image_aliases,
                kitty_state: replay.kitty_state,
                sequence_boundary: 0,
                colors: colors.clone(),
                pid: host.pid,
                command: host.command.clone(),
                cwd: snapshot_cwd(&term, host.cwd.as_deref(), &host.owner_token, selected_version),
                osc_progress,
                program_status,
                shell_activity,
            },
            colors,
            snapshot_sequence,
            replay_gap,
            active_client_stream,
        )
    };
    let mut client_setup = ClientSetupRollback::new(host.clone(), client);
    if let Some(gap) = replay_gap {
        let mut frame = Frame::new(MessageKind::ResyncRequired, gap.encode());
        frame.sequence = snapshot_sequence;
        let _ = write_frame(&mut stream, &frame);
        return Ok(());
    }
    if granted_rights.contains(CapabilityRights::CLIPBOARD_READ) {
        host.clipboard.register_owner(&host.term, client, tap.clone());
    }
    // Legacy hosts began reading as soon as the first owner tap joined.
    // Protocol v4 waits for Activate so public topology and its journal
    // record commit before the first exact PTY bytes can be observed.
    if !activation_required {
        launch_owner.stream_ready();
    }
    let include_terminal_metadata = hello_response.flags & FLAG_TERMINAL_METADATA != 0;
    let mut snapshot_frame = Frame::new(
        MessageKind::Snapshot,
        encode_snapshot_for_version(&snapshot, selected_version, include_terminal_metadata)?,
    );
    snapshot_frame.sequence = snapshot_sequence;
    write_frame(&mut stream, &snapshot_frame)?;
    let mut colors_frame =
        Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors));
    colors_frame.sequence = snapshot_sequence;
    write_frame(&mut stream, &colors_frame)?;
    if smart_renderer {
        let mut ready = Frame::new(MessageKind::Ready, Vec::new());
        ready.sequence = snapshot_sequence;
        write_frame(&mut stream, &ready)?;
    }

    let command_stream = stream.try_clone()?;
    let frames = Arc::new(ClientFrames {
        host: host.clone(),
        sender: command_sender.clone(),
        client,
        granted_rights,
        selected_version,
        launch_owner_claimed,
        smart_renderer,
        viewer_size_acks,
        input_flow,
        ended: AtomicBool::new(false),
    });
    // The client's frames run on its control sequence, which this loop
    // owns: it starts before client-input and is joined before this loop
    // returns, so no thread of the client outlives it.
    let control = ClientControl::start(frames.clone())?;
    let lane = control.lane.clone();
    let serve_input = move |command_stream: &mut crate::echo_thread::OwnHostStream<'_>| {
        // However client-input ends (the client's end of stream, a frame
        // it refuses, a panic), the control sequence runs what it holds
        // and then ends the client.
        let _finish = FinishInput(lane.clone());
        let hang_watch = HostLoop::ClientInput.register();
        while let Ok(Some(frame)) = read_frame(command_stream, MAX_FRAME_PAYLOAD) {
            // One hang-watch scope per frame, after its read.
            let _item = HostLoop::ClientInput.watch(&hang_watch);
            if frames.ended.load(Ordering::Acquire) || !frames.frame_is_valid(&frame) {
                break;
            }
            // This thread is echo path and disallows blocking (p02-threads
            // 210); a frame's handler may wait for the parser (a geometry,
            // default color, cell-metric, Kitty-limit or clear-history
            // commit). So it only routes: every frame goes to the control
            // sequence, in the order read, and runs there.
            lane.submit(frame);
        }
    };
    let client_input = HostLoop::ClientInput.thread_name();
    crate::echo_thread::spawn_host_stream_reader(client_input, command_stream, serve_input)?;
    client_setup.disarm();

    // The output loop is echo path: every PTY byte the client sees crosses
    // it, so it writes its own socket only and blocks on nothing else.
    crate::echo_thread::with_own_host_stream(&stream, |output| {
        while let Ok(frame) = receiver.recv() {
            if frame.kind == MessageKind::ResyncRequired && frame.sequence == 0 {
                tap.release(&frame);
                break;
            }
            let write_result =
                write_frame(output, &client_wire_frame(&frame, input_flow, input_stages));
            tap.release(&frame);
            if write_result.is_err() {
                break;
            }
            if frame.kind == MessageKind::Exit {
                break;
            }
        }
    });
    host.remove_client(client);
    // The output loop ended (Exit, a fenced detach drained, a write error or
    // the client's end): nothing more can reach this client, so the owner
    // ends it. The socket shuts both ways, client-input reads its end, the
    // control sequence runs what it holds and stops, and this loop joins it,
    // so the client's stream count drops here, as when this loop returned
    // at once.
    tap.close();
    control.join();
    Ok(())
}

/// What one client frame asks of its connection ([`ClientFrames::handle`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FrameStep {
    /// Read the next frame.
    Next,
    /// End the client.
    Close,
    /// End the client after a fenced detach: its writer drains on its own.
    Detached,
}

/// One accepted client's frame handling: its frames run on its control
/// sequence ([`ClientControl`]), one at a time, in the order client-input
/// read them.
struct ClientFrames {
    host: Arc<HostShared>,
    sender: HostTap,
    client: u64,
    granted_rights: CapabilityRights,
    selected_version: u16,
    launch_owner_claimed: bool,
    smart_renderer: bool,
    viewer_size_acks: bool,
    input_flow: bool,
    /// The client ended ([`ClientEnd`]): no frame runs after it.
    ended: AtomicBool,
}

impl ClientFrames {
    /// Client-to-host messages define one flag (a negotiated
    /// FLAG_INPUT_FLOW on interactive Input) and never participate in the
    /// host live-stream sequence.
    fn frame_is_valid(&self, frame: &Frame) -> bool {
        let flags_valid = frame.flags == 0
            || (self.input_flow
                && frame.flags == FLAG_INPUT_FLOW
                && frame.kind == MessageKind::Input
                && frame.request_id == 0);
        frame.version == self.selected_version && flags_valid && frame.sequence == 0
    }

    fn handle(&self, frame: Frame) -> FrameStep {
        let ctx = self;
        match frame.kind {
            MessageKind::Activate => {
                if ctx.selected_version < LAUNCH_ACTIVATION_PROTOCOL_VERSION
                    || !ctx.launch_owner_claimed
                    || frame.request_id != 0
                    || !frame.payload.is_empty()
                {
                    return FrameStep::Close;
                }
                ctx.host.mark_launch_owner_stream_ready();
            }
            MessageKind::Input => {
                let Some((input, flow)) = split_flow_trailer(frame.flags, &frame.payload) else {
                    return FrameStep::Close;
                };
                if !ctx.granted_rights.contains(CapabilityRights::INPUT)
                    || !input_request_is_supported(ctx.selected_version, frame.request_id)
                    || !ctx.host.write_input(input, frame.request_id, flow, &ctx.sender)
                {
                    return FrameStep::Close;
                }
            }
            MessageKind::Paste => {
                if !ctx.granted_rights.contains(CapabilityRights::INPUT) {
                    return FrameStep::Close;
                }
                let bracketed = ctx.host.term.lock().recover_poison().mode(2004, false);
                let mut writer = ctx.host.pty_writer();
                if bracketed {
                    let _ = writer.write_all(b"\x1b[200~");
                }
                let _ = writer.write_all(&frame.payload);
                if bracketed {
                    let _ = writer.write_all(b"\x1b[201~");
                }
                let _ = writer.flush();
            }
            MessageKind::ViewerSize if frame.payload.len() == 4 => {
                if !ctx.granted_rights.contains(CapabilityRights::RESIZE) {
                    return FrameStep::Close;
                }
                let field = |offset| {
                    crate::terminal_host_protocol::wire_u16(&frame.payload, offset).unwrap_or(0)
                };
                let (cols, rows) = (field(0), field(2));
                let targeted_ack = ctx
                    .viewer_size_acks
                    .then_some((frame.request_id, &ctx.sender))
                    .filter(|(request_id, _)| *request_id != 0);
                let acknowledge_with_replay = !ctx.smart_renderer && targeted_ack.is_none();
                if !matches!(
                    ctx.host.set_viewer_size(
                        ctx.client,
                        cols,
                        rows,
                        acknowledge_with_replay,
                        targeted_ack,
                    ),
                    Ok(true)
                ) {
                    // Invalid geometry or a PTY/parser resize failure
                    // rejects this admin stream. A failed targeted
                    // acknowledgement closes only this renderer; the
                    // committed canonical transition remains valid.
                    return FrameStep::Close;
                }
            }
            MessageKind::ReleaseViewer => {
                if !ctx.granted_rights.contains(CapabilityRights::RESIZE) {
                    return FrameStep::Close;
                }
                ctx.host.remove_viewer_size(ctx.client);
            }
            MessageKind::Terminate => {
                if !ctx.granted_rights.contains(CapabilityRights::TERMINATE) {
                    return FrameStep::Close;
                }
                // Integration failure-injection seam: a host whose
                // termination receipt reaches the daemon late. Only a
                // receipted request waits; bounded so an accidental
                // setting cannot wedge a real host.
                if frame.request_id != 0
                    && let Ok(delay) = std::env::var("CMUX_TUI_TEST_TERMINATE_ACK_DELAY_MS")
                    && let Ok(delay) = delay.parse::<u64>()
                    && delay > 0
                {
                    // The injected late receipt is a wait, not a hang.
                    cmux_hang_watch::invalidate_active();
                    // wakeup-allow: fixture integration failure-injection seam, only with CMUX_TUI_TEST_TERMINATE_ACK_DELAY_MS set; bounded at 5 s
                    cmux_threads::allow_blocking(
                        cmux_threads::AllowReason::FailureInjection,
                        || {
                            cmux_threads::checked::sync::sleep(Duration::from_millis(
                                delay.min(5_000),
                            ));
                        },
                    );
                }
                if ctx.launch_owner_claimed {
                    ctx.host.mark_launch_owner_stream_ready();
                }
                let receipt_queued = if frame.request_id == 0 {
                    true
                } else {
                    let mut response = Frame::new(MessageKind::TerminateAck, Vec::new());
                    response.request_id = frame.request_id;
                    let _broadcast = ctx.host.broadcast_lock.lock().recover_poison();
                    ctx.sender.try_send(response)
                };
                ctx.host.request_termination();
                if !receipt_queued {
                    return FrameStep::Close;
                }
            }
            MessageKind::Detach => {
                if !ctx.granted_rights.contains(CapabilityRights::TERMINATE)
                    || frame.request_id == 0
                {
                    return FrameStep::Close;
                }
                if !ctx.host.fence_client_detach(ctx.client, frame.request_id, &ctx.sender) {
                    return FrameStep::Close;
                }
                ctx.sender.wake_writer();
                return FrameStep::Detached;
            }
            MessageKind::SetDefaults => {
                if !ctx.granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                    return FrameStep::Close;
                }
                let Ok(colors) = decode_default_colors_payload(&frame.payload) else {
                    return FrameStep::Close;
                };
                ctx.host.set_default_colors(colors);
            }
            MessageKind::SetThreadQos => {
                if !ctx.granted_rights.contains(CapabilityRights::MINT_CAPABILITY)
                    || frame.request_id != 0
                {
                    return FrameStep::Close;
                }
                let Some(qos) = super::thread_qos::decode_thread_qos(&frame.payload) else {
                    return FrameStep::Close;
                };
                // One atomic store: no parser wait, so it runs inline.
                ctx.host.set_thread_qos(qos);
            }
            MessageKind::SetCellPixelSize if frame.request_id != 0 && frame.payload.len() == 4 => {
                if !ctx.granted_rights.contains(CapabilityRights::RESIZE) {
                    return FrameStep::Close;
                }
                let field = |offset| {
                    crate::terminal_host_protocol::wire_u16(&frame.payload, offset).unwrap_or(0)
                };
                let (width_px, height_px) = (field(0), field(2));
                if !matches!(
                    ctx.host.set_cell_pixel_size(
                        width_px,
                        height_px,
                        frame.request_id,
                        &ctx.sender,
                    ),
                    Ok(true)
                ) {
                    return FrameStep::Close;
                }
            }
            MessageKind::SetKittyGraphicsLimits
                if frame.request_id != 0
                    && frame.payload.len() == KITTY_GRAPHICS_LIMITS_ENCODED_LEN =>
            {
                if !ctx.granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                    return FrameStep::Close;
                }
                let mut decoder = PayloadDecoder::new(&frame.payload);
                let Ok(limits) = decode_kitty_graphics_limits(&mut decoder) else {
                    return FrameStep::Close;
                };
                if decoder.finish().is_err()
                    || !matches!(
                        ctx.host.set_kitty_graphics_limits(limits, frame.request_id, &ctx.sender,),
                        Ok(true)
                    )
                {
                    return FrameStep::Close;
                }
            }
            MessageKind::ClearHistory => {
                if !ctx.granted_rights.contains(CapabilityRights::INPUT) || frame.request_id == 0 {
                    return FrameStep::Close;
                }
                let Ok(fallback_key) =
                    crate::server::decode_terminal_host_clear_history(&frame.payload)
                else {
                    return FrameStep::Close;
                };
                let status = match ctx.host.clear_history_or_encode_key(
                    fallback_key.as_ref(),
                    ctx.smart_renderer.then_some((frame.request_id, &ctx.sender)),
                ) {
                    Ok(ClearHistoryAckDisposition::Queued) => return FrameStep::Next,
                    Ok(ClearHistoryAckDisposition::ConnectionClosed) => return FrameStep::Close,
                    Ok(ClearHistoryAckDisposition::Pending) => CLEAR_HISTORY_ACK_OK,
                    Err(failure) => clear_history_ack_status(Err(failure)),
                };
                let mut response = Frame::new(MessageKind::ClearHistoryAck, vec![status]);
                response.request_id = frame.request_id;
                let _broadcast = ctx.host.broadcast_lock.lock().recover_poison();
                if !ctx.sender.try_send(response) {
                    return FrameStep::Close;
                }
            }
            MessageKind::MintCapability => {
                if !ctx.granted_rights.contains(CapabilityRights::MINT_CAPABILITY)
                    || frame.request_id == 0
                {
                    return FrameStep::Close;
                }
                let Ok(token) = mint_renderer_capability(&ctx.host, &frame.payload) else {
                    return FrameStep::Close;
                };
                let mut response = Frame::new(MessageKind::Capability, token.as_bytes().to_vec());
                response.request_id = frame.request_id;
                // Targeted control responses share the socket writer
                // with live frames. Serialize enqueueing with coupled
                // Output/Resized + Colors publication so even an admin
                // response cannot physically split an atomic pair.
                let _broadcast = ctx.host.broadcast_lock.lock().recover_poison();
                if !ctx.sender.try_send(response) {
                    return FrameStep::Close;
                }
            }
            MessageKind::TraceControl => {
                if !ctx.granted_rights.contains(CapabilityRights::ADMIN) || frame.request_id == 0 {
                    return FrameStep::Close;
                }
                let Some(op) = super::host_trace::decode_request(&frame.payload) else {
                    return FrameStep::Close;
                };
                if !super::host_trace::answer(
                    ctx.host.clone(),
                    ctx.sender.clone(),
                    op,
                    frame.request_id,
                    ctx.selected_version,
                ) {
                    return FrameStep::Close;
                }
            }
            MessageKind::ClipboardReadReply => {
                if !ctx.host.apply_clipboard_read_reply(
                    ctx.client,
                    ctx.granted_rights,
                    &frame,
                    ctx.selected_version,
                ) {
                    return FrameStep::Close;
                }
            }
            _ => return FrameStep::Close,
        }

        FrameStep::Next
    }
}

/// Ends one client ([`ClientFrames::ended`]) once, however its control
/// sequence ends: its writer is woken (unless a fenced detach lets it
/// drain) and its socket shut down, so its peer sees the end, and the host
/// forgets it. Runs while unwinding too: the host's locks recover from poison.
struct ClientEnd {
    frames: Arc<ClientFrames>,
    detached: bool,
}

impl Drop for ClientEnd {
    fn drop(&mut self) {
        if self.frames.ended.swap(true, Ordering::AcqRel) {
            return;
        }
        // Wake a writer that is waiting on an otherwise-empty live-frame
        // channel. The socket is shut down first, so this private wakeup
        // frame can never be mistaken for a sequenced host transition.
        if !self.detached {
            self.frames.sender.close_and_wake_writer();
        }
        self.frames.host.remove_client(self.frames.client);
    }
}

/// The thread name of a client's control sequence.
const CONTROL_THREAD: &str = "terminal-host-client-control";

/// A client's control sequence (`terminal-host-client-control`): it runs
/// every frame client-input reads, in order, and may block (a frame that
/// waits for the parser). One path for every frame: a key typed after a
/// resize is written after the resize applied. Chromium routes an IO
/// thread's message to the sequence that owns its work the same way
/// (content/browser/browser_thread_impl.cc). The client's serve loop owns
/// it: it starts before client-input, and its owner joins it before it
/// returns (on drop too, an early return included).
struct ClientControl {
    lane: Arc<ControlLane>,
    thread: Option<crate::supervised::SupervisedThread<()>>,
}

#[derive(Default)]
struct ControlLane {
    state: cmux_threads::sync::Mutex<ControlState>,
    changed: cmux_threads::sync::Condvar,
}

#[derive(Default)]
struct ControlState {
    queue: std::collections::VecDeque<Frame>,
    /// Client-input read its last frame.
    finished: bool,
}

impl ControlLane {
    /// Queues `frame` after the frames read before it.
    fn submit(&self, frame: Frame) {
        self.state.lock().recover_poison().queue.push_back(frame);
        self.changed.notify_one();
    }

    /// Client-input read its last frame: the sequence runs what it holds,
    /// then ends the client.
    fn finish(&self) {
        self.state.lock().recover_poison().finished = true;
        self.changed.notify_one();
    }
}

/// Finishes the control sequence however client-input ends, a panic
/// included: a sequence left waiting would keep its client forever.
struct FinishInput(Arc<ControlLane>);

impl Drop for FinishInput {
    fn drop(&mut self) {
        self.0.finish();
    }
}

impl ClientControl {
    fn start(frames: Arc<ClientFrames>) -> std::io::Result<Self> {
        let lane = Arc::new(ControlLane::default());
        let thread_lane = lane.clone();
        // Every key press of the client crosses it: the echo path's class.
        let thread = crate::supervised::spawn_at(
            CONTROL_THREAD,
            crate::echo_thread::ECHO_PATH_QOS,
            crate::supervised::Fatal,
            crate::supervised::ShutdownBehavior::Continue,
            move || run_control(&frames, &thread_lane),
        )?;
        Ok(Self { lane, thread: Some(thread) })
    }

    /// Waits for the sequence to end, once client-input finished it or a
    /// frame ended the client.
    fn join(mut self) {
        self.end();
    }

    fn end(&mut self) {
        let Some(thread) = self.thread.take() else { return };
        if thread.is_current() {
            return;
        }
        let _ = thread.join();
    }
}

impl Drop for ClientControl {
    /// An owner that returns early (client-input never started) or unwinds
    /// finishes the sequence itself, then joins it.
    fn drop(&mut self) {
        if self.thread.is_some() {
            self.lane.finish();
        }
        self.end();
    }
}

fn run_control(frames: &Arc<ClientFrames>, lane: &ControlLane) {
    // Ends this client however its frames end, a panic included: a frame
    // thread that died with the client still registered left its peer
    // waiting for a reply forever.
    let mut end = ClientEnd { frames: frames.clone(), detached: false };
    loop {
        let mut state = lane.state.lock().recover_poison();
        let frame = loop {
            if let Some(frame) = state.queue.pop_front() {
                break Some(frame);
            }
            if state.finished || frames.ended.load(Ordering::Acquire) {
                break None;
            }
            // Idle until client-input queues the client's next frame.
            state = lane.changed.idle().wait(state).recover_poison();
        };
        drop(state);
        let Some(frame) = frame else { return };
        if frames.ended.load(Ordering::Acquire) {
            return;
        }
        // R3 (Debug): a client's frames never run on a thread that
        // disallows blocking (client-input), at any load.
        debug_assert!(
            !cmux_threads::blocking::is_blocking_disallowed(),
            "a terminal-host client frame ran on a thread that disallows blocking"
        );
        match frames.handle(frame) {
            FrameStep::Next => {}
            FrameStep::Close => return,
            FrameStep::Detached => {
                end.detached = true;
                return;
            }
        }
    }
}

/// `frame` as this client may read it: an `Output` that carries a key
/// press's flow ([`FLAG_INPUT_FLOW`]) loses the trailer toward a client that
/// did not negotiate it, and its key stages ([`FLAG_INPUT_STAGES`]) toward
/// one that negotiated only the flow, which gets the flow trailer. Every
/// other frame goes as it is.
pub(crate) fn client_wire_frame(
    frame: &Frame,
    input_flow: bool,
    input_stages: bool,
) -> Cow<'_, Frame> {
    let carries_stages = frame.flags & FLAG_INPUT_STAGES != 0;
    if frame.kind != MessageKind::Output
        || frame.flags & FLAG_INPUT_FLOW == 0
        || (input_flow && (input_stages || !carries_stages))
    {
        return Cow::Borrowed(frame);
    }
    let split = if carries_stages {
        split_stages_trailer(&frame.payload).map(|(bytes, flow, _, _)| (bytes.len(), flow))
    } else {
        split_flow_trailer(frame.flags, &frame.payload).map(|(bytes, flow)| (bytes.len(), flow))
    };
    let mut wire = frame.clone();
    wire.flags &= !(FLAG_INPUT_FLOW | FLAG_INPUT_STAGES);
    if let Some((len, flow)) = split {
        wire.payload.truncate(len);
        if input_flow {
            wire.payload.extend_from_slice(&flow.to_le_bytes());
            wire.flags |= FLAG_INPUT_FLOW;
        }
    }
    Cow::Owned(wire)
}
