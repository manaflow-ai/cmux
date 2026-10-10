//! Daemon-side attachment to a terminal host (cx-ko2e table B): the
//! authenticated admin connection (`HostAttachment`) over the
//! `sys::HostStream` seam, the owner handshake and protocol fallback
//! (`connect_record*`), the receipt a durable input write waits on, and the
//! launch-time ownership of the host process (`SpawnedHostProcess`).

use std::io as std_io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Context;

use super::super::sys::{HostStream, PtyCustody, connect_with_retry};
use super::super::*;
use super::clipboard_read::{OwnerIntent, owner_rights_for};
use super::codec::{
    PayloadDecoder, clear_history_ack_failure, decode_hex_array, decode_kitty_graphics_limits,
    decode_snapshot_for_version, encode_default_colors_payload, encode_kitty_graphics_limits,
    protocol_io_error, read_required_frame,
};
use super::control_responses::{ControlResponseWaiter, ControlResponses};
use super::host_state::{
    HOST_HANDSHAKE_TRANSIENT_RETRIES, HOST_LAUNCH_ROLLBACK_WAIT, MAX_PENDING_INPUT_ACK_BYTES,
};
use super::records::{
    acknowledge_terminal_host_exit_record, terminal_host_exit_record, write_record,
};
use super::renderer_grant::ControlRequestUnanswered;

mod connect;
pub(crate) mod launch;
mod terminate;
// Only the Unix host calls these until the Windows host lands.
#[cfg_attr(not(unix), allow(unused_imports))]
pub(crate) use connect::{connect_current_record_with_timeout, connect_record};
#[cfg(all(unix, test))]
pub(crate) use connect::{connect_record_at_version, connect_record_with_timeout};

pub(crate) struct InputAckReceipt {
    pub(crate) request_id: u64,
    pub(crate) receiver: Receiver<Frame>,
    pub(crate) control_responses: Arc<ControlResponses>,
    pub(crate) shutdown: Arc<HostStream>,
    pub(crate) bytes: usize,
}

impl InputAckReceipt {
    pub(crate) fn abort_connection(&self) {
        let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
    }

    pub(crate) fn wait(self) -> std::io::Result<()> {
        self.wait_for(CONTROL_RESPONSE_TIMEOUT)
    }

    pub(crate) fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
        match self.receiver.recv_timeout(timeout) {
            Ok(frame) => {
                if !frame.payload.is_empty() {
                    self.abort_connection();
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "terminal host returned a malformed input acknowledgement",
                    ));
                }
                Ok(())
            }
            Err(error) => {
                self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                // Shutdown uses a separately cloned socket handle. A timed-out
                // receipt therefore does not wait behind another frame writer
                // before it can abort the broken attachment.
                self.abort_connection();
                let kind = match error {
                    RecvTimeoutError::Timeout => std::io::ErrorKind::TimedOut,
                    RecvTimeoutError::Disconnected => std::io::ErrorKind::ConnectionAborted,
                };
                Err(std::io::Error::new(
                    kind,
                    format!("terminal host did not acknowledge receipted input: {error}"),
                ))
            }
        }
    }
}

impl Drop for InputAckReceipt {
    fn drop(&mut self) {
        let abandoned =
            self.control_responses.waiters.lock().unwrap().remove(&self.request_id).is_some();
        self.control_responses.release_input_ack(self.bytes);
        if abandoned {
            // A submitted request whose confirmation is abandoned can still
            // produce a late targeted ACK. Close this attachment now rather
            // than letting that late frame fail the production reader later.
            self.abort_connection();
        }
    }
}

pub(crate) struct SpawnedHostProcess {
    pub(crate) child: Option<std::process::Child>,
}

impl SpawnedHostProcess {
    pub(crate) fn child_mut(&mut self) -> &mut std::process::Child {
        self.child.as_mut().expect("terminal-host child is present")
    }

    pub(crate) fn into_child(mut self) -> std::process::Child {
        self.child.take().expect("terminal-host child is present")
    }

    pub(crate) fn wait_timeout(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let Some(child) = self.child.as_mut() else { return true };
            match child.try_wait() {
                Ok(Some(_)) => {
                    self.child.take();
                    return true;
                }
                Ok(None) if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(None) | Err(_) => return false,
            }
        }
    }
}

impl Drop for SpawnedHostProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub struct HostAttachment {
    pub record: TerminalHostRecord,
    pub record_path: PathBuf,
    pub snapshot: HostSnapshot,
    pub(crate) protocol_version: u16,
    pub(crate) smart_renderer: bool,
    pub(crate) reader: Option<HostStream>,
    pub(crate) writer: Arc<Mutex<HostStream>>,
    pub(crate) control_responses: Arc<ControlResponses>,
    pub(crate) next_request: AtomicU64,
    pub(crate) viewer_size: Mutex<Option<(u16, u16)>>,
    /// Exact process ownership retained only between a successful launch
    /// handshake and complete Surface materialization. Adoption never
    /// carries this guard.
    pub(crate) launch_process: Option<SpawnedHostProcess>,
    /// The first authenticated admin attachment may inherit a protocol-v4
    /// launch barrier. A launcher releases it after committing topology;
    /// an adopter releases an abandoned barrier after validating the host.
    pub(crate) launch_activation_pending: bool,
    /// The owner's copy of this host's PTY master (`pty_custody.rs`).
    pub(crate) pty_custody: Option<PtyCustody>,
}

impl std::fmt::Debug for HostAttachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostAttachment")
            .field("terminal_id", &self.record.terminal_id)
            .field("incarnation", &self.record.incarnation)
            .field("endpoint", &self.record.endpoint)
            .finish_non_exhaustive()
    }
}

/// One frame on a daemon-to-host connection's writer.
pub(crate) fn send_host_frame(
    writer: &Mutex<HostStream>,
    protocol_version: u16,
    kind: MessageKind,
    payload: &[u8],
) -> std::io::Result<()> {
    let mut writer = writer.lock().unwrap();
    let mut frame = Frame::new(kind, payload.to_vec());
    frame.version = protocol_version;
    let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
    if result.is_err() {
        // A timed-out write may have emitted only part of a frame.
        // Poison this connection so the reader takes a fresh atomic
        // Snapshot instead of ever appending to a corrupt stream.
        let _ = writer.shutdown(std::net::Shutdown::Both);
    }
    result
}

impl HostAttachment {
    pub fn take_reader(&mut self) -> anyhow::Result<HostStream> {
        self.reader.take().ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))
    }

    pub(crate) fn is_smart_renderer(&self) -> bool {
        self.smart_renderer
    }

    pub fn send(&self, kind: MessageKind, payload: &[u8]) -> std::io::Result<()> {
        send_host_frame(&self.writer, self.protocol_version, kind, payload)
    }

    pub(crate) fn begin_input_confirmed(
        &self,
        payload: &[u8],
    ) -> Result<InputAckReceipt, ConfirmedInputFailure> {
        // InputAck responses require protocol v4 even when the record advertises support.
        if !self.record.supports_input_ack || self.protocol_version < PROTOCOL_VERSION {
            return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "terminal host cannot acknowledge receipted input",
            )));
        }
        if payload.len() > MAX_PENDING_INPUT_ACK_BYTES {
            return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "terminal input is too large to confirm in one write",
            )));
        }
        if !self.control_responses.try_reserve_input_ack(payload.len()) {
            return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "terminal host receipted-input window is full",
            )));
        }

        let shutdown =
            self.control_responses.input_ack_shutdown_handle(&self.writer).map_err(|error| {
                self.control_responses.release_input_ack(payload.len());
                ConfirmedInputFailure::Known(error)
            })?;

        let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
        if request_id == 0 {
            self.control_responses.release_input_ack(payload.len());
            return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "terminal host input request id exhausted",
            )));
        }
        let (sender, receiver) = sync_channel(1);
        {
            let mut waiters = self.control_responses.waiters.lock().unwrap();
            if waiters.contains_key(&request_id) {
                self.control_responses.release_input_ack(payload.len());
                return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "terminal host input request id collision",
                )));
            }
            waiters.insert(
                request_id,
                ControlResponseWaiter::Blocking { kind: MessageKind::InputAck, sender },
            );
        }

        let mut frame = Frame::new(MessageKind::Input, payload.to_vec());
        frame.version = self.protocol_version;
        frame.request_id = request_id;
        let write_result = {
            let mut writer = self.writer.lock().unwrap();
            let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
            if result.is_err() {
                let _ = writer.shutdown(std::net::Shutdown::Both);
            }
            result
        };
        if let Err(error) = write_result {
            self.control_responses.waiters.lock().unwrap().remove(&request_id);
            self.control_responses.release_input_ack(payload.len());
            return Err(ConfirmedInputFailure::Indeterminate(error));
        }

        Ok(InputAckReceipt {
            request_id,
            receiver,
            control_responses: self.control_responses.clone(),
            shutdown,
            bytes: payload.len(),
        })
    }

    /// Update the authoritative parser defaults on a feature-advertising
    /// host. Legacy records deliberately skip the unknown control while
    /// the disposable frontend still updates its local defaults.
    pub fn send_default_colors(&self, colors: DefaultColors) -> std::io::Result<bool> {
        if !self.record.supports_set_defaults {
            return Ok(false);
        }
        self.send(MessageKind::SetDefaults, &encode_default_colors_payload(colors))?;
        Ok(true)
    }

    pub fn send_clear_history(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> Result<bool, ClearHistoryFailure> {
        if !self.record.supports_clear_history {
            return Ok(false);
        }
        let payload = crate::server::encode_terminal_host_clear_history(fallback_key)
            .map_err(ClearHistoryFailure::known_not_delivered)?;
        let response = self.send_control_request(
            MessageKind::ClearHistory,
            MessageKind::ClearHistoryAck,
            payload,
        )?;
        match response.as_slice() {
            [CLEAR_HISTORY_ACK_OK] => {}
            [CLEAR_HISTORY_ACK_OK, ..] if self.smart_renderer => {}
            [status] => {
                let Some(failure) = clear_history_ack_failure(*status) else {
                    self.disconnect();
                    return Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                        "terminal host returned an unknown clear-history status"
                    )));
                };
                return Err(failure);
            }
            _ => {
                self.disconnect();
                return Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                    "terminal host returned a malformed clear-history response"
                )));
            }
        }
        Ok(true)
    }

    pub fn supports_clear_history(&self) -> bool {
        self.record.supports_clear_history
    }

    pub fn send_viewer_size(&self, cols: u16, rows: u16) -> std::io::Result<()> {
        let (cols, rows) = normalize_terminal_geometry(cols, rows).map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, error.to_string())
        })?;
        let mut viewer_size = self.viewer_size.lock().unwrap();
        if *viewer_size == Some((cols, rows)) {
            return Ok(());
        }
        // This is the daemon's desired logical lease, not an
        // acknowledgement from the host. Retain it across a failed write
        // so reconnect can replay the newest mux state instead of a stale
        // reservation from the dead socket.
        *viewer_size = Some((cols, rows));
        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&cols.to_le_bytes());
        payload.extend_from_slice(&rows.to_le_bytes());
        self.send(MessageKind::ViewerSize, &payload)?;
        Ok(())
    }

    /// Commit frontend cell metrics in the durable host before updating
    /// this daemon's disposable mirror. Protocol-v1 hosts do not expose
    /// this transaction, so callers leave their mirror unchanged.
    pub fn send_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.send_cell_pixel_size_until(
            width_px,
            height_px,
            Instant::now() + CONTROL_RESPONSE_TIMEOUT,
        )
    }

    pub(crate) fn send_cell_pixel_size_until(
        &self,
        width_px: u16,
        height_px: u16,
        deadline: Instant,
    ) -> anyhow::Result<bool> {
        if self.protocol_version < 2 {
            return Ok(false);
        }
        if Instant::now() >= deadline {
            return Err(CellPixelRequestDeadlineElapsed.into());
        }
        let width_px = width_px.max(1);
        let height_px = height_px.max(1);
        let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = sync_channel(1);
        self.control_responses.waiters.lock().unwrap().insert(
            request_id,
            ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, sender },
        );
        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&width_px.to_le_bytes());
        payload.extend_from_slice(&height_px.to_le_bytes());
        let mut frame = Frame::new(MessageKind::SetCellPixelSize, payload);
        frame.version = self.protocol_version;
        frame.request_id = request_id;
        let write_result = {
            let mut writer = self.writer.lock().unwrap();
            write_frame(&mut *writer, &frame).map_err(protocol_io_error)
        };
        if let Err(error) = write_result {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
            self.control_responses.waiters.lock().unwrap().remove(&request_id);
            return Err(error.into());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        let response =
            match (!remaining.is_zero()).then(|| receiver.recv_timeout(remaining)).transpose() {
                Ok(Some(response)) => response,
                Ok(None) | Err(RecvTimeoutError::Timeout) => {
                    match self.defer_or_receive_raced_cell_pixel_ack(
                        request_id,
                        (width_px, height_px),
                        &receiver,
                    )? {
                        Some(response) => response,
                        None => return Err(DeferredCellPixelAck.into()),
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.control_responses.waiters.lock().unwrap().remove(&request_id);
                    anyhow::bail!(
                        "terminal host connection closed before acknowledging cell pixel size"
                    );
                }
            };
        if response.kind != MessageKind::CellPixelSizeAck
            || response.payload.as_slice()
                != [width_px.to_le_bytes(), height_px.to_le_bytes()].concat()
        {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
            anyhow::bail!("terminal host returned a malformed cell pixel size acknowledgement");
        }
        Ok(true)
    }

    /// Commit Kitty resource limits in the authoritative host before
    /// returning control to the disposable mirror. Protocol-v1/v2 hosts
    /// cannot synchronize this sidecar state and therefore keep graphics
    /// disabled in new mirrors.
    pub fn send_kitty_graphics_limits(&self, limits: KittyGraphicsLimits) -> anyhow::Result<bool> {
        self.send_kitty_graphics_limits_until(limits, Instant::now() + CONTROL_RESPONSE_TIMEOUT)
    }

    pub fn send_kitty_graphics_limits_until(
        &self,
        limits: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<bool> {
        if self.protocol_version < 3 {
            return Ok(false);
        }
        let limits = limits
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let mut payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
        encode_kitty_graphics_limits(&mut payload, limits)?;
        let response = self
            .send_control_request_with_policy(
                MessageKind::SetKittyGraphicsLimits,
                MessageKind::KittyGraphicsLimitsAck,
                payload,
                deadline,
                // Advisory control: a missed ack must degrade graphics for
                // this surface, not tear down a healthy host connection.
                false,
            )
            .map_err(ClearHistoryFailure::into_error)
            .context("terminal host did not acknowledge Kitty graphics limits")?;
        let mut decoder = PayloadDecoder::new(&response);
        let acknowledged = decode_kitty_graphics_limits(&mut decoder)?;
        decoder.finish()?;
        if acknowledged != limits {
            self.disconnect();
            anyhow::bail!("terminal host acknowledged different Kitty graphics limits");
        }
        Ok(true)
    }

    pub(crate) fn reconfigure_kitty_graphics_for_adoption(
        &mut self,
        limits: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.protocol_version >= 3,
            "terminal host cannot synchronize Kitty graphics limits"
        );
        let limits = limits
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let mut payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
        encode_kitty_graphics_limits(&mut payload, limits)?;
        let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
        if request_id == 0 {
            self.disconnect();
            anyhow::bail!("terminal host control request id exhausted");
        }
        let mut request = Frame::new(MessageKind::SetKittyGraphicsLimits, payload);
        request.version = self.protocol_version;
        request.request_id = request_id;
        let write_result = {
            let mut writer = self.writer.lock().unwrap();
            write_frame(&mut *writer, &request).map_err(protocol_io_error)
        };
        if let Err(error) = write_result {
            self.disconnect();
            return Err(error.into());
        }

        // No Surface reader exists yet. Drain the old live stream through
        // the targeted acknowledgement, then reconnect for the fresh
        // authoritative Snapshot produced before that acknowledgement.
        let protocol_version = self.protocol_version;
        let deadline = Instant::now() + CONTROL_RESPONSE_TIMEOUT;
        let result = (|| -> anyhow::Result<()> {
            let reader = self
                .reader
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
            let previous_timeout = reader
                .read_timeout()
                .context("read terminal-host timeout before Kitty quota adoption")?;
            let response = (|| -> anyhow::Result<()> {
                loop {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    anyhow::ensure!(
                        !remaining.is_zero(),
                        "terminal host did not apply Kitty graphics limits before adoption"
                    );
                    reader
                        .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                        .context("set terminal-host Kitty quota adoption timeout")?;
                    let frame = read_frame(reader, MAX_FRAME_PAYLOAD)
                        .map_err(protocol_io_error)?
                        .ok_or_else(|| {
                        anyhow::anyhow!(
                            "terminal host disconnected while applying Kitty graphics limits"
                        )
                    })?;
                    anyhow::ensure!(
                        frame.version == protocol_version,
                        "terminal host changed protocol during Kitty quota adoption"
                    );
                    if frame.request_id == 0 {
                        continue;
                    }
                    anyhow::ensure!(
                        frame.request_id == request_id
                            && frame.kind == MessageKind::KittyGraphicsLimitsAck
                            && frame.flags == 0
                            && frame.sequence == 0,
                        "terminal host returned an invalid Kitty quota adoption response"
                    );
                    let mut decoder = PayloadDecoder::new(&frame.payload);
                    let acknowledged = decode_kitty_graphics_limits(&mut decoder)?;
                    decoder.finish()?;
                    anyhow::ensure!(
                        acknowledged == limits,
                        "terminal host acknowledged different Kitty graphics limits"
                    );
                    return Ok(());
                }
            })();
            let restored = reader
                .set_read_timeout(previous_timeout)
                .context("restore terminal-host timeout after Kitty quota adoption");
            response.and(restored)
        })();
        if result.is_err() {
            self.disconnect();
        }
        result
    }

    pub(crate) fn defer_or_receive_raced_cell_pixel_ack(
        &self,
        request_id: u64,
        expected: (u16, u16),
        receiver: &Receiver<Frame>,
    ) -> anyhow::Result<Option<Frame>> {
        if self.control_responses.defer_cell_pixel(request_id, expected) {
            return Ok(None);
        }
        // resolve() removes the waiter while holding the same mutex
        // before delivering the response. An absent entry therefore
        // means a response won the timeout race or the connection failed.
        receiver.recv().map(Some).map_err(|_| {
            anyhow::anyhow!("terminal host connection closed while acknowledging cell pixel size")
        })
    }

    pub fn release_viewer_size(&self) -> std::io::Result<bool> {
        let mut viewer_size = self.viewer_size.lock().unwrap();
        if viewer_size.is_none() {
            return Ok(false);
        }
        // Preserve the desired released state even if this disposable
        // admin connection has already failed; reconnect starts without
        // an implicit lease and therefore needs no compensating message.
        *viewer_size = None;
        self.send(MessageKind::ReleaseViewer, &[])?;
        Ok(true)
    }

    pub fn viewer_size(&self) -> Option<(u16, u16)> {
        *self.viewer_size.lock().unwrap()
    }

    pub fn protocol_version(&self) -> u16 {
        self.protocol_version
    }

    pub fn disconnect(&self) {
        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
    }

    /// Remove this daemon from host publication only after the reader has
    /// consumed every source frame admitted before the request. Record-v4
    /// hosts implement the source fence; older hosts cannot make this
    /// shutdown guarantee.
    pub(crate) fn detach_for_daemon_shutdown_until(&self, deadline: Instant) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.smart_renderer && self.record.record_version >= HOST_RECORD_VERSION,
            "terminal host does not support a source-ordered detach fence"
        );
        let response = self
            .send_control_request_until(
                MessageKind::Detach,
                MessageKind::DetachAck,
                Vec::new(),
                deadline,
            )
            .map_err(ClearHistoryFailure::into_error)?;
        anyhow::ensure!(response.is_empty(), "terminal host returned a malformed detach fence");
        Ok(())
    }

    pub(crate) fn supports_journal_detach_fence(&self) -> bool {
        self.smart_renderer && self.record.record_version >= HOST_RECORD_VERSION
    }

    /// Commit the launch ownership handoff after every fallible Surface
    /// setup step succeeds. Until then, dropping this attachment exact-
    /// kills and waits the child process through SpawnedHostProcess.
    pub(crate) fn commit_launched_host(&mut self) {
        let Some(process) = self.launch_process.take() else { return };
        let mut child = process.into_child();
        // Reaping is housekeeping after the ownership handoff. Failure to
        // create this helper cannot turn a committed live Surface into an
        // error; dropping Child leaves the independent host running.
        let _ = thread::Builder::new().name("terminal-host-reaper".into()).spawn(move || {
            let _ = child.wait();
        });
    }

    /// Release a newly launched protocol-v4 host only after its public
    /// topology is durable. The state flips after the complete frame is
    /// accepted by the local socket, so a retry cannot duplicate it.
    pub(crate) fn activate_launched_host(&mut self) -> std::io::Result<bool> {
        if !self.launch_activation_pending {
            return Ok(false);
        }
        debug_assert!(self.protocol_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION);
        self.send(MessageKind::Activate, &[])?;
        self.launch_activation_pending = false;
        Ok(true)
    }

    pub fn identity(&self) -> TerminalHostIdentity {
        TerminalHostIdentity {
            terminal_id: self.record.terminal_id.clone(),
            incarnation: self.record.incarnation.clone(),
        }
    }

    pub(crate) fn exit_record_path(&self) -> PathBuf {
        self.record_path.with_extension("exit")
    }

    pub(crate) fn discovery_record(&self) -> (TerminalHostRecord, PathBuf) {
        (self.record.clone(), self.record_path.clone())
    }

    pub(crate) fn control_responses(&self) -> Arc<ControlResponses> {
        self.control_responses.clone()
    }

    pub(crate) fn send_control_request(
        &self,
        request_kind: MessageKind,
        response_kind: MessageKind,
        payload: Vec<u8>,
    ) -> Result<Vec<u8>, ClearHistoryFailure> {
        self.send_control_request_until(
            request_kind,
            response_kind,
            payload,
            Instant::now() + CONTROL_RESPONSE_TIMEOUT,
        )
    }

    pub(crate) fn send_control_request_until(
        &self,
        request_kind: MessageKind,
        response_kind: MessageKind,
        payload: Vec<u8>,
        deadline: Instant,
    ) -> Result<Vec<u8>, ClearHistoryFailure> {
        self.send_control_request_with_policy(request_kind, response_kind, payload, deadline, true)
    }

    /// `disconnect_on_timeout` = false keeps the channel alive when the
    /// ack misses the deadline. Responses are matched by request id and
    /// an unknown id is dropped on arrival, so a late ack is harmless.
    /// Advisory controls (Kitty graphics limits) use this: tearing down
    /// a healthy host over a slow ack forced a full terminal reconnect,
    /// which reset the budget blocklist and re-armed the retry storm.
    pub(crate) fn send_control_request_with_policy(
        &self,
        request_kind: MessageKind,
        response_kind: MessageKind,
        payload: Vec<u8>,
        deadline: Instant,
        disconnect_on_timeout: bool,
    ) -> Result<Vec<u8>, ClearHistoryFailure> {
        let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
        if request_id == 0 {
            return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                "terminal host control request id exhausted"
            )));
        }
        let (sender, receiver) = sync_channel(1);
        {
            let mut waiters = self.control_responses.waiters.lock().unwrap();
            if waiters.contains_key(&request_id) {
                return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                    "terminal host control request id collision"
                )));
            }
            waiters.insert(
                request_id,
                ControlResponseWaiter::Blocking { kind: response_kind, sender },
            );
        }
        let mut frame = Frame::new(request_kind, payload);
        frame.version = self.protocol_version;
        frame.request_id = request_id;
        let write_result = {
            let mut writer = self.writer.lock().unwrap();
            let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
            if result.is_err() {
                let _ = writer.shutdown(std::net::Shutdown::Both);
            }
            result
        };
        if let Err(error) = write_result {
            self.control_responses.waiters.lock().unwrap().remove(&request_id);
            return Err(ClearHistoryFailure::ambiguous(error.into()));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        let response = if remaining.is_zero() {
            Err(RecvTimeoutError::Timeout)
        } else {
            receiver.recv_timeout(remaining)
        };
        match response {
            Ok(frame) => Ok(frame.payload),
            Err(error) => {
                self.control_responses.waiters.lock().unwrap().remove(&request_id);
                if disconnect_on_timeout {
                    self.disconnect();
                }
                Err(ClearHistoryFailure::ambiguous(
                    ControlRequestUnanswered { request_kind, cause: error }.into(),
                ))
            }
        }
    }

    pub fn persist_workspace(&mut self, workspace_key: &str) -> anyhow::Result<()> {
        if self.record.workspace_key == workspace_key {
            return Ok(());
        }
        let mut updated = self.record.clone();
        updated.workspace_key = workspace_key.to_string();
        write_record(&self.record_path, &updated)?;
        self.record = updated;
        Ok(())
    }
}

impl Drop for HostAttachment {
    fn drop(&mut self) {
        let Some(mut process) = self.launch_process.take() else { return };
        // Surface setup failed after an authenticated launch. Ask the
        // still-live host to perform its bounded PTY group shutdown and
        // record cleanup, then wait on the exact owned host process. Only
        // a wedged host that exceeds that bound is SIGKILLed by the
        // SpawnedHostProcess fallback below.
        let _ = self.terminate();
        if !process.wait_timeout(HOST_LAUNCH_ROLLBACK_WAIT) {
            drop(process);
        }

        // This attachment still owns an uncommitted launch, so no
        // registry transition can consume its crash-recovery evidence.
        // Process exit is ordered after durable sidecar publication.
        // Remove only the receipt for this exact launch incarnation.
        let identity = self.identity();
        if let Ok(Some((exit_path, exit))) = terminal_host_exit_record(&self.record_path)
            && exit.terminal_id == identity.terminal_id
            && exit.incarnation == identity.incarnation
        {
            let _ = acknowledge_terminal_host_exit_record(&exit_path, &exit);
        }
    }
}
