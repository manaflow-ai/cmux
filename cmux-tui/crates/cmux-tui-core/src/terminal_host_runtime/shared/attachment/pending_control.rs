//! A control request split into its send and its wait, so a caller can send
//! under the surface's runtime lock and wait after releasing it. The
//! surface's reader takes that lock while it installs a reconnected host
//! and before it reads the new stream; a request that waited under the lock
//! for a reply only that reader delivers timed out (a renderer mint right
//! after a default-colors update, during the resync reconnect).

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
    writer: Arc<Mutex<HostStream>>,
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
