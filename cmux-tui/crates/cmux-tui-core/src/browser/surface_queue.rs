//! BrowserSurface command queue: bounded, control, reconfigure and
//! latest-authority enqueue paths, pointer releases, and the sender.

use super::*;

impl BrowserSurface {
    pub(super) fn maybe_nudge_stalled_external(&self, session: &BrowserSession) {
        if session.runtime.source() == BrowserSource::Launched {
            return;
        }
        let should_nudge = {
            let mut state = self.state.lock().unwrap();
            if frames_stalled_locked(&state, Instant::now(), self.is_dead()) && !state.stall_nudged
            {
                state.stall_nudged = true;
                true
            } else {
                false
            }
        };
        if should_nudge {
            let _ = session.runtime.client.activate_target(&session.target_id, &session.session_id);
        }
    }

    // Bounded, in-order delivery for disposable pointer/key input. Input events
    // are high-frequency and individually expendable, so under backpressure the
    // worker queue drops the newest event rather than blocking or replacing an
    // unrelated queued one. Callers are intentionally told `ok` even on drop:
    // losing one mouse-move or keystroke frame is not a reported failure.
    pub(super) fn enqueue_bounded(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
    }

    pub(super) fn wake_lifecycle_worker(&self) {
        let _ = self.enqueue_bounded(BrowserCommand::WakeLatest);
    }

    // A release closes state established by an earlier accepted press. If the
    // ordinary lane is full, retain it in the same bounded sequence space and
    // wake the worker without blocking the shared browser-input producer.
    pub(super) fn enqueue_pointer_release(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(command)) => {
                if order.retained_releases.len() >= BROWSER_RETAINED_RELEASE_CAPACITY {
                    anyhow::bail!("browser pointer release queue is full")
                }
                order.retained_releases.push_back(command);
                let wake = order.sequence(BrowserCommand::WakeLatest);
                match tx.try_send(wake) {
                    Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
                    Err(TrySendError::Disconnected(_)) => {
                        order.retained_releases.pop_back();
                        anyhow::bail!("browser command worker is closed")
                    }
                }
            }
            Err(TrySendError::Disconnected(_)) => {
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    // Bounded, in-order delivery for discrete control actions
    // (back/forward/reload/activate). These stay in FIFO order so a `Back` can
    // never be swallowed by a later `Forward` (unlike the latest-wins nav slot),
    // but unlike disposable input they must not be silently dropped: losing a
    // control action the caller asked for is a user-visible action that
    // vanished. A full queue (a wedged worker) reports backpressure as an error
    // instead of a false `ok`; `try_send` never blocks. URL navigation uses the
    // latest-wins slot (`enqueue_latest_nav`): only the final destination matters.
    pub(super) fn enqueue_control(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(_)) => anyhow::bail!("browser command worker is closed"),
        }
    }

    pub(super) fn execute_confirmed(&self, command: BrowserCommand) -> anyhow::Result<()> {
        let (completion, outcome) = sync_channel(1);
        self.enqueue_control(BrowserCommand::Confirmed { command: Box::new(command), completion })?;
        outcome
            .recv()
            .map_err(|_| anyhow::anyhow!("browser command worker closed before completion"))?
            .map_err(anyhow::Error::msg)
    }

    pub(super) fn enqueue_reconfigure(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            if let Some(queued) = reject_reconfigure(command) {
                self.release_reconfigure(queued);
            }
            anyhow::bail!("browser surface is closed");
        }
        let tx = match self.command_sender() {
            Ok(tx) => tx,
            Err(error) => {
                if let Some(queued) = reject_reconfigure(command) {
                    self.release_reconfigure(queued);
                }
                return Err(error);
            }
        };
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        match tx.try_send(command) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(command)) => {
                if let Some(queued) = reject_reconfigure(command.command) {
                    self.release_reconfigure(queued);
                }
                anyhow::bail!("browser command queue is full; browser may be unresponsive")
            }
            Err(TrySendError::Disconnected(command)) => {
                if let Some(queued) = reject_reconfigure(command.command) {
                    self.release_reconfigure(queued);
                }
                anyhow::bail!("browser command worker is closed")
            }
        }
    }

    pub(super) fn enqueue_latest_authority(&self, command: BrowserCommand) -> anyhow::Result<()> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        let tx = self.command_sender()?;
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        let displaced = self.latest_authority.lock().unwrap().replace(command);
        let wake = order.sequence(BrowserCommand::WakeLatest);
        let (result, rejected) = match tx.try_send(wake) {
            Ok(()) | Err(TrySendError::Full(_)) => (Ok(()), None),
            Err(TrySendError::Disconnected(_)) => {
                let rejected = self.latest_authority.lock().unwrap().take();
                (Err(anyhow::anyhow!("browser command worker is closed")), rejected)
            }
        };
        drop(order);
        self.release_screencast_capture_command(displaced);
        self.release_screencast_capture_command(rejected);
        result
    }

    pub(super) fn release_screencast_capture_command(
        &self,
        command: Option<SequencedBrowserCommand>,
    ) {
        let Some(BrowserCommand::AuthorizeScreencastCapture {
            session_id,
            reservation_id,
            frame_epoch,
            navigation_epoch,
            ..
        }) = command.map(|queued| queued.command)
        else {
            return;
        };
        self.cancel_screencast_capture(reservation_id);
        if let Some(session) = self.session.lock().unwrap().clone() {
            let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                &session_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            );
        }
    }

    pub(crate) fn wake_pointer_cleanup(&self) {
        let Ok(tx) = self.command_sender() else { return };
        let mut order = self.command_order.lock().unwrap();
        let wake = order.sequence(BrowserCommand::WakeLatest);
        let _ = tx.try_send(wake);
    }

    pub(super) fn command_sender(&self) -> anyhow::Result<SyncSender<SequencedBrowserCommand>> {
        self.command_tx
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("browser command worker is closed"))
    }

    #[cfg(test)]
    pub(super) fn enqueue_test_command(&self, command: BrowserCommand) -> bool {
        let Ok(tx) = self.command_sender() else { return false };
        let mut order = self.command_order.lock().unwrap();
        let command = order.sequence(command);
        tx.try_send(command).is_ok()
    }

    pub(super) fn close_command_sender(&self) {
        let _ = self.command_tx.lock().unwrap().take();
    }

    pub(super) fn claim_not_responding_report(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.not_responding_reported {
            false
        } else {
            state.not_responding_reported = true;
            true
        }
    }
}
