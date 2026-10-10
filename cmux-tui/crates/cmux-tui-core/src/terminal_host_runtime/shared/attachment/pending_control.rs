//! A control request split into its send and its wait, so a caller can send
//! under the surface's runtime lock and wait after releasing it. The
//! surface's reader takes that lock while it installs a reconnected host
//! and before it reads the new stream; a request that waited under the lock
//! for a reply only that reader delivers timed out (a renderer mint right
//! after a default-colors update, during the resync reconnect). Clear
//! history and Kitty graphics limits use the same split.

use super::*;

/// A sent control request whose response has not been read yet. It keeps
/// the connection's writer and response table, so it outlives a runtime
/// swap of its attachment.
pub(crate) struct PendingControlResponse {
    request_kind: MessageKind,
    request_id: u64,
    receiver: Receiver<Frame>,
    deadline: Instant,
    control_responses: Arc<ControlResponses>,
    writer: Arc<RankedMutex<HostStream, { rank::LEAF }>>,
}

impl HostAttachment {
    /// Register the waiter and write the request; `wait` reads the reply.
    pub(crate) fn begin_control_request(
        &self,
        request_kind: MessageKind,
        response_kind: MessageKind,
        payload: Vec<u8>,
        deadline: Instant,
    ) -> Result<PendingControlResponse, ClearHistoryFailure> {
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
        Ok(PendingControlResponse {
            request_kind,
            request_id,
            receiver,
            deadline,
            control_responses: self.control_responses.clone(),
            writer: self.writer.clone(),
        })
    }
}

impl PendingControlResponse {
    /// The response payload, or the failure at the deadline.
    /// `disconnect_on_timeout` = false keeps the channel alive when the
    /// ack misses the deadline. Responses are matched by request id and
    /// an unknown id is dropped on arrival, so a late ack is harmless.
    /// Advisory controls (Kitty graphics limits) use this: tearing down
    /// a healthy host over a slow ack forced a full terminal reconnect,
    /// which reset the budget blocklist and re-armed the retry storm.
    pub(crate) fn wait(&self, disconnect_on_timeout: bool) -> Result<Vec<u8>, ClearHistoryFailure> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        let response = if remaining.is_zero() {
            Err(RecvTimeoutError::Timeout)
        } else {
            self.receiver.recv_timeout(remaining)
        };
        match response {
            Ok(frame) => Ok(frame.payload),
            Err(error) => {
                self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                if disconnect_on_timeout {
                    self.disconnect();
                }
                Err(ClearHistoryFailure::ambiguous(
                    ControlRequestUnanswered { request_kind: self.request_kind, cause: error }
                        .into(),
                ))
            }
        }
    }

    /// Shut the request's connection down.
    pub(crate) fn disconnect(&self) {
        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
    }
}

/// A sent ClearHistory whose acknowledgement has not been read yet.
pub(crate) struct PendingClearHistory {
    pending: PendingControlResponse,
    smart_renderer: bool,
}

/// A sent SetKittyGraphicsLimits whose acknowledgement has not been read yet.
pub(crate) struct PendingKittyGraphicsLimits {
    pending: PendingControlResponse,
    limits: KittyGraphicsLimits,
}

impl HostAttachment {
    /// Send ClearHistory; `None` when the host does not support it.
    pub(crate) fn begin_clear_history(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> Result<Option<PendingClearHistory>, ClearHistoryFailure> {
        if !self.record.supports_clear_history {
            return Ok(None);
        }
        let payload = crate::server::encode_terminal_host_clear_history(fallback_key)
            .map_err(ClearHistoryFailure::known_not_delivered)?;
        let pending = self.begin_control_request(
            MessageKind::ClearHistory,
            MessageKind::ClearHistoryAck,
            payload,
            Instant::now() + CONTROL_RESPONSE_TIMEOUT,
        )?;
        Ok(Some(PendingClearHistory { pending, smart_renderer: self.smart_renderer }))
    }

    /// Send SetKittyGraphicsLimits; `None` when the host predates them.
    pub(crate) fn begin_kitty_graphics_limits(
        &self,
        limits: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<Option<PendingKittyGraphicsLimits>> {
        if self.protocol_version < 3 {
            return Ok(None);
        }
        let limits = limits
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let mut payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
        encode_kitty_graphics_limits(&mut payload, limits)?;
        let pending = self
            .begin_control_request(
                MessageKind::SetKittyGraphicsLimits,
                MessageKind::KittyGraphicsLimitsAck,
                payload,
                deadline,
            )
            .map_err(ClearHistoryFailure::into_error)
            .context("terminal host did not acknowledge Kitty graphics limits")?;
        Ok(Some(PendingKittyGraphicsLimits { pending, limits }))
    }
}

impl PendingClearHistory {
    pub(crate) fn wait(&self) -> Result<(), ClearHistoryFailure> {
        let response = self.pending.wait(true)?;
        match response.as_slice() {
            [CLEAR_HISTORY_ACK_OK] => Ok(()),
            [CLEAR_HISTORY_ACK_OK, ..] if self.smart_renderer => Ok(()),
            [status] => {
                let Some(failure) = clear_history_ack_failure(*status) else {
                    self.pending.disconnect();
                    return Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                        "terminal host returned an unknown clear-history status"
                    )));
                };
                Err(failure)
            }
            _ => {
                self.pending.disconnect();
                Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                    "terminal host returned a malformed clear-history response"
                )))
            }
        }
    }
}

impl PendingKittyGraphicsLimits {
    pub(crate) fn wait(&self) -> anyhow::Result<()> {
        let response = self
            .pending
            // Advisory control: a missed ack must degrade graphics for this
            // surface, not tear down a healthy host connection.
            .wait(false)
            .map_err(ClearHistoryFailure::into_error)
            .context("terminal host did not acknowledge Kitty graphics limits")?;
        let mut decoder = PayloadDecoder::new(&response);
        let acknowledged = decode_kitty_graphics_limits(&mut decoder)?;
        decoder.finish()?;
        if acknowledged != self.limits {
            self.pending.disconnect();
            anyhow::bail!("terminal host acknowledged different Kitty graphics limits");
        }
        Ok(())
    }
}
