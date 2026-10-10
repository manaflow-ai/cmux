//! Host side of one client connection that touches no OS API (cx-ko2e
//! table A): the launch-owner barrier claim, the active-stream count that
//! wakes the accept loop, the client-setup rollback, client
//! authentication, renderer-capability minting, and the per-client
//! connection loop (`serve_client*`) over `HostStream`.

use std::io::Write;
use std::sync::atomic::Ordering;
use std::sync::mpsc::channel as mpsc_channel;
use std::sync::{Arc, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

use super::super::sys::{self, HostStream};
use super::super::*;
use super::clipboard_read::*;
use super::codec::*;
use super::host_shared::HostShared;
use super::host_state::*;

mod stdio;
// Only the Unix host process runs this loop until the Windows host lands.
#[cfg_attr(not(unix), allow(unused_imports))]
pub use stdio::serve_terminal_host_stdio;

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
    let rights = CapabilityRights::from_bits(u32::from_le_bytes(
        payload[0..4].try_into().expect("fixed rights slice"),
    ))
    .ok_or_else(|| anyhow::anyhow!("unknown renderer capability rights"))?;
    if !rights.contains(CapabilityRights::READ) || !CapabilityRights::RENDERER.contains(rights) {
        anyhow::bail!("renderer capability rights are out of range");
    }
    let ttl_ms = u32::from_le_bytes(payload[4..8].try_into().expect("fixed TTL slice"));
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
                | FLAG_PTY_CUSTODY)
            != 0
        || (hello_frame.flags & FLAG_TERMINAL_METADATA != 0
            && hello_frame.version != PROTOCOL_VERSION)
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
                    thread::park_timeout(remaining.min(Duration::from_millis(1)));
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
                    thread::park_timeout(remaining.min(Duration::from_millis(1)));
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
                    thread::park_timeout(remaining.min(Duration::from_millis(1)));
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
        let osc_progress = host.terminal_metadata.lock().unwrap().osc_progress().to_owned();
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
            let _broadcast = host.broadcast_lock.lock().unwrap();
            host.taps.lock().unwrap().insert(client, tap.clone());
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

    let mut command_stream = stream.try_clone()?;
    let command_host = host.clone();
    thread::Builder::new().name("terminal-host-client-input".into()).spawn(move || {
        let mut detached = false;
        while let Ok(Some(frame)) = read_frame(&mut command_stream, MAX_FRAME_PAYLOAD) {
            // Client-to-host messages currently define no flags and never
            // participate in the host live-stream sequence.
            if frame.version != selected_version || frame.flags != 0 || frame.sequence != 0 {
                break;
            }
            match frame.kind {
                MessageKind::Activate => {
                    if selected_version < LAUNCH_ACTIVATION_PROTOCOL_VERSION
                        || !launch_owner_claimed
                        || frame.request_id != 0
                        || !frame.payload.is_empty()
                    {
                        break;
                    }
                    command_host.mark_launch_owner_stream_ready();
                }
                MessageKind::Input => {
                    if !granted_rights.contains(CapabilityRights::INPUT)
                        || !input_request_is_supported(selected_version, frame.request_id)
                        || !command_host.write_input(
                            &frame.payload,
                            frame.request_id,
                            &command_sender,
                        )
                    {
                        break;
                    }
                }
                MessageKind::Paste => {
                    if !granted_rights.contains(CapabilityRights::INPUT) {
                        break;
                    }
                    let bracketed = command_host.term.lock().unwrap().mode(2004, false);
                    let mut writer = command_host.writer.lock().unwrap();
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
                    if !granted_rights.contains(CapabilityRights::RESIZE) {
                        break;
                    }
                    let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                    let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                    let targeted_ack = viewer_size_acks
                        .then_some((frame.request_id, &command_sender))
                        .filter(|(request_id, _)| *request_id != 0);
                    let acknowledge_with_replay = !smart_renderer && targeted_ack.is_none();
                    if !matches!(
                        command_host.set_viewer_size(
                            client,
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
                        break;
                    }
                }
                MessageKind::ReleaseViewer => {
                    if !granted_rights.contains(CapabilityRights::RESIZE) {
                        break;
                    }
                    command_host.remove_viewer_size(client);
                }
                MessageKind::Terminate => {
                    if !granted_rights.contains(CapabilityRights::TERMINATE) {
                        break;
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
                        thread::sleep(Duration::from_millis(delay.min(5_000)));
                    }
                    if launch_owner_claimed {
                        command_host.mark_launch_owner_stream_ready();
                    }
                    let receipt_queued = if frame.request_id == 0 {
                        true
                    } else {
                        let mut response = Frame::new(MessageKind::TerminateAck, Vec::new());
                        response.request_id = frame.request_id;
                        let _broadcast = command_host.broadcast_lock.lock().unwrap();
                        command_sender.try_send(response)
                    };
                    command_host.request_termination();
                    if !receipt_queued {
                        break;
                    }
                }
                MessageKind::Detach => {
                    if !granted_rights.contains(CapabilityRights::TERMINATE)
                        || frame.request_id == 0
                    {
                        break;
                    }
                    if !command_host.fence_client_detach(client, frame.request_id, &command_sender)
                    {
                        break;
                    }
                    command_sender.wake_writer();
                    detached = true;
                    break;
                }
                MessageKind::SetDefaults => {
                    if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                        break;
                    }
                    let Ok(colors) = decode_default_colors_payload(&frame.payload) else {
                        break;
                    };
                    command_host.set_default_colors(colors);
                }
                MessageKind::SetCellPixelSize
                    if frame.request_id != 0 && frame.payload.len() == 4 =>
                {
                    if !granted_rights.contains(CapabilityRights::RESIZE) {
                        break;
                    }
                    let width_px = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                    let height_px = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                    if !matches!(
                        command_host.set_cell_pixel_size(
                            width_px,
                            height_px,
                            frame.request_id,
                            &command_sender,
                        ),
                        Ok(true)
                    ) {
                        break;
                    }
                }
                MessageKind::SetKittyGraphicsLimits
                    if frame.request_id != 0
                        && frame.payload.len() == KITTY_GRAPHICS_LIMITS_ENCODED_LEN =>
                {
                    if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                        break;
                    }
                    let mut decoder = PayloadDecoder::new(&frame.payload);
                    let Ok(limits) = decode_kitty_graphics_limits(&mut decoder) else {
                        break;
                    };
                    if decoder.finish().is_err()
                        || !matches!(
                            command_host.set_kitty_graphics_limits(
                                limits,
                                frame.request_id,
                                &command_sender,
                            ),
                            Ok(true)
                        )
                    {
                        break;
                    }
                }
                MessageKind::ClearHistory => {
                    if !granted_rights.contains(CapabilityRights::INPUT) || frame.request_id == 0 {
                        break;
                    }
                    let Ok(fallback_key) =
                        crate::server::decode_terminal_host_clear_history(&frame.payload)
                    else {
                        break;
                    };
                    let status = match command_host.clear_history_or_encode_key(
                        fallback_key.as_ref(),
                        smart_renderer.then_some((frame.request_id, &command_sender)),
                    ) {
                        Ok(ClearHistoryAckDisposition::Queued) => continue,
                        Ok(ClearHistoryAckDisposition::ConnectionClosed) => break,
                        Ok(ClearHistoryAckDisposition::Pending) => CLEAR_HISTORY_ACK_OK,
                        Err(failure) => clear_history_ack_status(Err(failure)),
                    };
                    let mut response = Frame::new(MessageKind::ClearHistoryAck, vec![status]);
                    response.request_id = frame.request_id;
                    let _broadcast = command_host.broadcast_lock.lock().unwrap();
                    if !command_sender.try_send(response) {
                        break;
                    }
                }
                MessageKind::MintCapability => {
                    if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY)
                        || frame.request_id == 0
                    {
                        break;
                    }
                    let Ok(token) = mint_renderer_capability(&command_host, &frame.payload) else {
                        break;
                    };
                    let mut response =
                        Frame::new(MessageKind::Capability, token.as_bytes().to_vec());
                    response.request_id = frame.request_id;
                    // Targeted control responses share the socket writer
                    // with live frames. Serialize enqueueing with coupled
                    // Output/Resized + Colors publication so even an admin
                    // response cannot physically split an atomic pair.
                    let _broadcast = command_host.broadcast_lock.lock().unwrap();
                    if !command_sender.try_send(response) {
                        break;
                    }
                }
                MessageKind::ClipboardReadReply => {
                    if !command_host.apply_clipboard_read_reply(
                        client,
                        granted_rights,
                        &frame,
                        selected_version,
                    ) {
                        break;
                    }
                }
                _ => break,
            }
        }
        // Wake a writer that is waiting on an otherwise-empty live-frame
        // channel. The socket is shut down first, so this private wakeup
        // frame can never be mistaken for a sequenced host transition.
        if !detached {
            command_sender.close_and_wake_writer();
        }
        command_host.remove_client(client);
    })?;
    client_setup.disarm();

    while let Ok(frame) = receiver.recv() {
        if frame.kind == MessageKind::ResyncRequired && frame.sequence == 0 {
            tap.release(&frame);
            break;
        }
        let write_result = write_frame(&mut stream, &frame);
        tap.release(&frame);
        if write_result.is_err() {
            break;
        }
        if frame.kind == MessageKind::Exit {
            break;
        }
    }
    host.remove_client(client);
    Ok(())
}
