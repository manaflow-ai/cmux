//! Pending targeted responses for one terminal-host attachment: blocking
//! waiters keyed by request id, deferred cell-pixel acknowledgements, and the
//! receipted-input window. The attachment's writers register waiters; the
//! surface reader and the connection's frame reader resolve or fail them.

use super::*;

pub(super) enum ControlResponseWaiter {
    Blocking { kind: MessageKind, sender: SyncSender<Frame> },
    DeferredCellPixel { expected: (u16, u16) },
}

#[derive(Debug, Clone)]
pub(crate) enum DeferredCellPixelResolution {
    Response(Frame),
    Disconnected,
}

pub(crate) type DeferredCellPixelHandler =
    Arc<dyn Fn(u64, (u16, u16), DeferredCellPixelResolution) + Send + Sync + 'static>;

#[derive(Default)]
pub(super) struct PendingInputAckWindow {
    writes: usize,
    bytes: usize,
}

pub(crate) struct ControlResponses {
    pub(super) waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,
    pub(super) deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,
    pub(super) latest_cell_pixel_ack: AtomicU64,
    pub(super) pending_input_acks: Mutex<PendingInputAckWindow>,
    pub(super) input_ack_shutdown: Mutex<Option<Arc<UnixStream>>>,
}

impl ControlResponses {
    pub(super) fn new() -> Self {
        Self {
            waiters: Mutex::new(HashMap::new()),
            deferred_cell_pixel_handler: Mutex::new(None),
            latest_cell_pixel_ack: AtomicU64::new(0),
            pending_input_acks: Mutex::new(PendingInputAckWindow::default()),
            input_ack_shutdown: Mutex::new(None),
        }
    }

    #[cfg(test)]
    pub(crate) fn new_for_test() -> Self {
        Self::new()
    }

    #[cfg(test)]
    pub(crate) fn invoke_deferred_cell_pixel_handler_for_test(
        &self,
        request_id: u64,
        expected: (u16, u16),
        resolution: DeferredCellPixelResolution,
    ) {
        if let Some(handler) = self.deferred_cell_pixel_handler.lock().unwrap().clone() {
            handler(request_id, expected, resolution);
        }
    }

    #[cfg(test)]
    pub(crate) fn resolve(&self, frame: &Frame) -> bool {
        self.resolve_after(frame, || {})
    }

    /// Registers a blocking waiter for `kind` and returns its receiver.
    #[cfg(test)]
    pub(crate) fn wait_for_test(&self, request_id: u64, kind: MessageKind) -> Receiver<Frame> {
        let (sender, receiver) = sync_channel(1);
        self.waiters
            .lock()
            .unwrap()
            .insert(request_id, ControlResponseWaiter::Blocking { kind, sender });
        receiver
    }

    /// Whether a waiter for `request_id` is registered.
    pub(crate) fn has_waiter(&self, request_id: u64) -> bool {
        self.waiters.lock().unwrap().contains_key(&request_id)
    }

    pub(crate) fn resolve_after(&self, frame: &Frame, before_resolve: impl FnOnce()) -> bool {
        let waiter = self.waiters.lock().unwrap().remove(&frame.request_id);
        match waiter {
            Some(ControlResponseWaiter::Blocking { kind, sender }) => {
                if kind != frame.kind {
                    return false;
                }
                if frame.kind == MessageKind::CellPixelSizeAck {
                    self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
                }
                before_resolve();
                let _ = sender.try_send(frame.clone());
                true
            }
            Some(ControlResponseWaiter::DeferredCellPixel { expected }) => {
                if frame.kind != MessageKind::CellPixelSizeAck {
                    return false;
                }
                self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
                before_resolve();
                let handler = self.deferred_cell_pixel_handler.lock().unwrap().clone();
                if let Some(handler) = handler {
                    handler(
                        frame.request_id,
                        expected,
                        DeferredCellPixelResolution::Response(frame.clone()),
                    );
                }
                true
            }
            None => false,
        }
    }

    pub(super) fn input_ack_shutdown_handle(
        &self,
        writer: &Mutex<UnixStream>,
    ) -> std::io::Result<Arc<UnixStream>> {
        let mut cached = self.input_ack_shutdown.lock().unwrap();
        if let Some(shutdown) = cached.as_ref() {
            return Ok(shutdown.clone());
        }
        let shutdown = Arc::new(writer.lock().unwrap().try_clone()?);
        *cached = Some(shutdown.clone());
        Ok(shutdown)
    }

    pub(super) fn try_reserve_input_ack(&self, bytes: usize) -> bool {
        if bytes > MAX_PENDING_INPUT_ACK_BYTES {
            return false;
        }
        let mut pending = self.pending_input_acks.lock().unwrap();
        if pending.writes >= MAX_PENDING_INPUT_ACKS
            || bytes > MAX_PENDING_INPUT_ACK_BYTES.saturating_sub(pending.bytes)
        {
            return false;
        }
        pending.writes += 1;
        pending.bytes += bytes;
        true
    }

    pub(super) fn release_input_ack(&self, bytes: usize) {
        let mut pending = self.pending_input_acks.lock().unwrap();
        debug_assert!(pending.writes > 0, "terminal input ACK reservation underflow");
        debug_assert!(pending.bytes >= bytes, "terminal input ACK byte reservation underflow");
        pending.writes = pending.writes.saturating_sub(1);
        pending.bytes = pending.bytes.saturating_sub(bytes);
    }

    #[cfg(test)]
    pub(super) fn pending_input_acks_for_test(&self) -> (usize, usize) {
        let pending = self.pending_input_acks.lock().unwrap();
        (pending.writes, pending.bytes)
    }

    pub(super) fn defer_cell_pixel(&self, request_id: u64, expected: (u16, u16)) -> bool {
        let mut waiters = self.waiters.lock().unwrap();
        let Some(waiter) = waiters.get_mut(&request_id) else { return false };
        if !matches!(
            waiter,
            ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, .. }
        ) {
            return false;
        }
        *waiter = ControlResponseWaiter::DeferredCellPixel { expected };
        true
    }

    pub(crate) fn fail_all(&self) {
        self.fail_all_except(|_| false);
    }

    /// Fail every waiter except blocking waiters for a response kind that
    /// `keep` selects. The surface reader keeps those when it abandons a
    /// stream: the connection's frame reader still delivers them and
    /// fails them when the stream ends.
    pub(crate) fn fail_all_except(&self, keep: impl Fn(MessageKind) -> bool) {
        let deferred = {
            let mut waiters = self.waiters.lock().unwrap();
            let failed = waiters
                .iter()
                .filter(|(_, waiter)| match waiter {
                    ControlResponseWaiter::Blocking { kind, .. } => !keep(*kind),
                    ControlResponseWaiter::DeferredCellPixel { .. } => true,
                })
                .map(|(request_id, _)| *request_id)
                .collect::<Vec<_>>();
            failed
                .into_iter()
                .filter_map(|request_id| match waiters.remove(&request_id) {
                    Some(ControlResponseWaiter::DeferredCellPixel { expected }) => {
                        Some((request_id, expected))
                    }
                    _ => None,
                })
                .collect::<Vec<_>>()
        };
        let handler = self.deferred_cell_pixel_handler.lock().unwrap().clone();
        if let Some(handler) = handler {
            for (request_id, expected) in deferred {
                handler(request_id, expected, DeferredCellPixelResolution::Disconnected);
            }
        }
    }

    pub(crate) fn set_deferred_cell_pixel_handler(&self, handler: DeferredCellPixelHandler) {
        *self.deferred_cell_pixel_handler.lock().unwrap() = Some(handler);
    }

    pub(crate) fn latest_cell_pixel_ack(&self) -> u64 {
        self.latest_cell_pixel_ack.load(Ordering::Acquire)
    }
}
