//! Requests to the server, their deadlines, and transport shutdown.

use super::*;

impl RemoteSession {
    pub fn request(&self, cmd: Value) -> anyhow::Result<Value> {
        self.request_with_deadline(cmd, RequestDeadline::Standard)
    }

    /// Fire-and-forget command: enqueued in order with interactive traffic,
    /// never awaited. Used for best-effort reporting such as client focus.
    pub(crate) fn notify(&self, cmd: Value) -> anyhow::Result<()> {
        self.request_no_wait(cmd)
    }

    pub(super) fn request_with_deadline(
        &self,
        mut cmd: Value,
        deadline: RequestDeadline,
    ) -> anyhow::Result<Value> {
        if let Some(error) = self.request_shutdown_error() {
            return Err(error.into());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let progress = Arc::new(AtomicU64::new(0));
        let attach_progress = matches!(deadline, RequestDeadline::Attach)
            .then(|| self.attach_progress.load(Ordering::Acquire));
        let attach_surface = matches!(deadline, RequestDeadline::Attach)
            .then(|| cmd.get("surface").and_then(Value::as_u64))
            .flatten();
        cmd["id"] = json!(id);
        let message = serde_json::to_string(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        if let Some(Value::String(authority)) = cmd.get_mut("authority") {
            zeroize_string(authority);
        }

        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(
            id,
            PendingRemoteRequest { response: tx, progress: progress.clone(), attach_surface },
        );
        let sequence = match self.interactive_writer.enqueue(message, false) {
            Ok(sequence) => sequence,
            Err(error) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(self.classify_transport_error(error).into());
            }
        };
        if let Err(error) = self.wait_for_ordered_write(sequence) {
            self.pending.lock().unwrap().remove(&id);
            return Err(self.classify_transport_error(error).into());
        }

        if self.shutdown.load(Ordering::Acquire) {
            self.pending.lock().unwrap().remove(&id);
            return Err(self.shutdown_error().into());
        }

        let response = match self.wait_for_response(rx, deadline, progress, attach_progress) {
            Ok(response) => response,
            Err(error) => {
                // Drop the pending entry so a half-open session does not
                // accumulate abandoned senders (and a late response is
                // not delivered to a receiver nobody holds).
                self.pending.lock().unwrap().remove(&id);
                return Err(error.into());
            }
        };
        if response.get("shutdown").and_then(Value::as_bool) == Some(true) {
            return Err(self.shutdown_error().into());
        }
        if response.get("ok").and_then(|v| v.as_bool()) == Some(true) {
            Ok(response.get("data").cloned().unwrap_or(Value::Null))
        } else {
            let error = response.get("error").and_then(|v| v.as_str()).unwrap_or("unknown error");
            let code = response.get("error_code").and_then(Value::as_str).map(ToString::to_string);
            let delivery = match response.get("error_delivery").and_then(Value::as_str) {
                Some("known-not-delivered") => Some(ClearHistoryDelivery::KnownNotDelivered),
                Some("ambiguous") => Some(ClearHistoryDelivery::Ambiguous),
                _ => None,
            };
            if disconnect::is_shutdown_pending_refusal(code.as_deref(), error) {
                self.disconnect_state.wait_while_active(disconnect::SHUTDOWN_PENDING_GRACE);
                if let Some(shutdown) = self.request_shutdown_error() {
                    return Err(shutdown.into());
                }
                disconnect::log_missing_shutdown_notice();
            }
            Err(RemoteRequestError::Rejected { error: error.to_string(), code, delivery }.into())
        }
    }

    fn wait_for_response(
        &self,
        rx: Receiver<Value>,
        deadline: RequestDeadline,
        progress: Arc<AtomicU64>,
        attach_progress: Option<u64>,
    ) -> Result<Value, RemoteRequestError> {
        if let RequestDeadline::Standard | RequestDeadline::Fixed(_) = deadline {
            let timeout = match deadline {
                RequestDeadline::Standard => REMOTE_REQUEST_TIMEOUT,
                RequestDeadline::Fixed(timeout) => timeout,
                RequestDeadline::Attach => unreachable!(),
            };
            return match rx.recv_timeout(timeout) {
                Ok(response) => Ok(response),
                Err(RecvTimeoutError::Timeout) => Err(RemoteRequestError::Timeout),
                Err(RecvTimeoutError::Disconnected) if self.shutdown.load(Ordering::Acquire) => {
                    Err(self.shutdown_error())
                }
                Err(RecvTimeoutError::Disconnected) => Err(RemoteRequestError::Timeout),
            };
        }

        let started = Instant::now();
        let mut deadline = AttachResponseDeadline::new(
            started,
            progress.load(Ordering::Acquire),
            attach_progress.expect("attach response wait requires an attach progress epoch"),
            REMOTE_ATTACH_IDLE_TIMEOUT,
            REMOTE_ATTACH_MAX_TIMEOUT,
        );
        loop {
            let request_progress = progress.load(Ordering::Acquire);
            let attach_progress = self.attach_progress.load(Ordering::Acquire);
            // Capture the deadline origin after the progress snapshots so scheduler
            // preemption cannot consume a newly granted idle window.
            let now = Instant::now();
            let Some(wait) = deadline.next_wait(now, request_progress, attach_progress) else {
                return Err(RemoteRequestError::Timeout);
            };
            match rx.recv_timeout(wait) {
                Ok(response) => return Ok(response),
                Err(RecvTimeoutError::Disconnected) if self.shutdown.load(Ordering::Acquire) => {
                    return Err(self.shutdown_error());
                }
                Err(RecvTimeoutError::Disconnected) => return Err(RemoteRequestError::Timeout),
                Err(RecvTimeoutError::Timeout) => {}
            }
            if self.shutdown.load(Ordering::Acquire) {
                return Err(self.shutdown_error());
            }
        }
    }

    /// Write latency-sensitive input in order without waiting for the mux
    /// command acknowledgement. The response reader still drains the reply;
    /// its unknown request id is intentionally ignored. Reliable remote
    /// sessions replay this write after carrier reconnect.
    fn request_no_wait(&self, mut cmd: Value) -> anyhow::Result<()> {
        if let Some(error) = self.request_shutdown_error() {
            return Err(error.into());
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        cmd["id"] = json!(id);
        // The local remote bridge replaces eligible sends with compact binary
        // MuxInput packets. Direct/older mux servers ignore this hint and keep
        // the existing JSON response behavior.
        cmd["no_reply"] = json!(true);
        let message = serde_json::to_string(&cmd)
            .map_err(RemoteRequestError::Encode)
            .map_err(anyhow::Error::new)?;
        let sequence = self
            .interactive_writer
            .enqueue(message, true)
            .map_err(|error| self.classify_transport_error(error))?;
        if self.shutdown.load(Ordering::Acquire) {
            self.wait_for_ordered_write(sequence)
                .map_err(|error| self.classify_transport_error(error))?;
            return Err(self.shutdown_error().into());
        }
        Ok(())
    }

    pub(in crate::session) fn request_guarded_pointer(
        &self,
        cmd: Value,
        lifecycle: GuardedPointerLifecycle,
    ) -> anyhow::Result<Value> {
        let result = self
            .request_with_deadline(cmd, RequestDeadline::Fixed(GUARDED_POINTER_REQUEST_TIMEOUT));
        if lifecycle == GuardedPointerLifecycle::CaptureMutation
            && result
                .as_ref()
                .err()
                .and_then(|error| error.downcast_ref::<RemoteRequestError>())
                .is_some_and(RemoteRequestError::is_timeout)
        {
            // The server may have accepted a press whose reply was lost.
            // Closing the connection removes this client from the server
            // registry and wakes every browser worker to balance its capture.
            self.disconnect_transport();
        }
        result
    }

    pub fn send_bytes(&self, surface: SurfaceId, bytes: &[u8]) -> anyhow::Result<()> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        self.request_no_wait(json!({"cmd": "send", "surface": surface, "bytes": encoded}))
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn interactive_write_metrics(&self) -> InteractiveWriteMetricsSnapshot {
        self.interactive_writer.metrics()
    }

    pub fn clear_history_classified(&self, surface: SurfaceId) -> Result<(), ClearHistoryFailure> {
        self.clear_history_request_classified(surface, None)
    }

    pub fn supports_clear_history_key_fallback(&self, surface: SurfaceId) -> bool {
        let server_supports_fallback = {
            let capabilities = self.capabilities.lock().unwrap();
            capabilities.contains(CLEAR_HISTORY_CAPABILITY)
                && capabilities.contains(CLEAR_HISTORY_KEY_CAPABILITY)
        };
        server_supports_fallback
            && self
                .tree
                .lock()
                .unwrap()
                .view
                .surface(surface)
                .is_some_and(|tab| tab.supports_clear_history_key_fallback)
    }

    pub fn clear_history_or_send_key_classified(
        &self,
        surface: SurfaceId,
        fallback_key: &KeyInput,
    ) -> Result<(), ClearHistoryFailure> {
        if self.supports_clear_history_key_fallback(surface) {
            let fallback_key = ProtocolKeyInput::try_from(fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?;
            return self.clear_history_request_classified(surface, Some(fallback_key));
        }

        // Plain clear-history remains available as a dedicated request, but
        // only an atomic-capability server can choose the active screen and
        // encode the fallback from authoritative keyboard modes. A mirrored
        // terminal is never safe for correctness-critical input routing.
        Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            CLEAR_HISTORY_UNSUPPORTED_ERROR
        )))
    }

    fn clear_history_request_classified(
        &self,
        surface: SurfaceId,
        fallback_key: Option<ProtocolKeyInput>,
    ) -> Result<(), ClearHistoryFailure> {
        require_capability(
            &self.capabilities.lock().unwrap(),
            CLEAR_HISTORY_CAPABILITY,
            "clear-history",
        )
        .map_err(ClearHistoryFailure::known_not_delivered)?;
        self.request(json!({
            "cmd": "clear-history",
            "surface": surface,
            "fallback_key": fallback_key,
        }))
        .map(|_| ())
        .map_err(|error| {
            let known_not_delivered = matches!(
                error.downcast_ref::<RemoteRequestError>(),
                Some(RemoteRequestError::Encode(_))
                    | Some(RemoteRequestError::Rejected {
                        delivery: Some(ClearHistoryDelivery::KnownNotDelivered),
                        ..
                    })
            );
            if known_not_delivered {
                ClearHistoryFailure::known_not_delivered(error)
            } else {
                ClearHistoryFailure::ambiguous(error)
            }
        })
    }

    pub fn is_shut_down(&self) -> bool {
        self.shutdown.load(Ordering::Acquire)
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        matches!(&*self.disconnect_state.lock().unwrap(), DisconnectState::ExpectedRemoteShutdown)
    }

    fn request_shutdown_error(&self) -> Option<RemoteRequestError> {
        match &*self.disconnect_state.lock().unwrap() {
            DisconnectState::LocalShutdown => Some(RemoteRequestError::Shutdown),
            DisconnectState::ExpectedRemoteShutdown => Some(RemoteRequestError::DaemonShutdown),
            DisconnectState::Active | DisconnectState::Remote(_) => None,
        }
    }

    fn shutdown_error(&self) -> RemoteRequestError {
        self.request_shutdown_error().unwrap_or(RemoteRequestError::Shutdown)
    }

    fn classify_transport_error(&self, error: io::Error) -> RemoteRequestError {
        self.request_shutdown_error().unwrap_or(RemoteRequestError::Transport(error))
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.provider_workspaces_guarded.store(false, Ordering::Release);
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for (_, request) in pending {
            let _ = request.response.send(json!({"shutdown": true}));
        }
        if let Ok(Some(sequence)) = self.interactive_writer.last_enqueued_sequence() {
            let _ = self.wait_for_ordered_write(sequence);
        }
    }

    pub(super) fn wait_for_ordered_write(&self, sequence: u64) -> io::Result<()> {
        match self.interactive_writer.wait_until_written(sequence, remote_write_timeout()) {
            Ok(()) => Ok(()),
            Err(error) => {
                if error.kind() == io::ErrorKind::TimedOut {
                    self.interactive_writer.abort(&error);
                }
                Err(error)
            }
        }
    }

    pub(super) fn disconnect_transport(&self) {
        self.disconnect_transport_with_reason(None);
    }

    pub(in crate::session) fn disconnect_transport_with_reason(&self, reason: Option<String>) {
        let mut state = self.disconnect_state.lock().unwrap();
        if matches!(&*state, DisconnectState::Active) {
            *state = match reason {
                Some(reason) => DisconnectState::Remote(reason),
                None => DisconnectState::LocalShutdown,
            };
        }
        drop(state);
        self.disconnect_state.notify();
        self.begin_shutdown();
        self.interactive_writer.close();
    }

    /// Returns the first reason recorded when the remote reader stopped.
    pub fn transport_disconnect_reason(&self) -> Option<String> {
        match &*self.disconnect_state.lock().unwrap() {
            DisconnectState::Remote(reason) => Some(reason.clone()),
            DisconnectState::Active
            | DisconnectState::LocalShutdown
            | DisconnectState::ExpectedRemoteShutdown => None,
        }
    }
}
