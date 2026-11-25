//! Child exit, forced PTY drain, termination and exit publication of a
//! terminal host.

use super::*;
use crate::panic_free::RecoverPoison;

/// How often a publisher thread that could not start is tried again within
/// one request, and the pause between tries (50 ms in all).
const EXIT_PUBLISHER_START_ATTEMPTS: u32 = 5;
const EXIT_PUBLISHER_START_RETRY: Duration = Duration::from_millis(10);

impl HostShared {
    pub(crate) fn child_exited(&self) -> bool {
        self.child_exit.0.lock().recover_poison().is_some()
    }

    pub(crate) fn wait_for_child_exit(&self, timeout: Duration) -> bool {
        let exited = self.child_exit.0.lock().recover_poison();
        if exited.is_some() {
            return true;
        }
        let (exited, _) = self
            .child_exit
            .1
            .wait_timeout_while(exited, timeout, |value| value.is_none())
            .recover_poison();
        exited.is_some()
    }

    pub(crate) fn wait_for_child_waitable(&self, timeout: Duration) -> bool {
        if self.child_waitable.load(Ordering::Acquire) {
            return true;
        }
        let state = self.child_exit.0.lock().recover_poison();
        let (_state, _) = self
            .child_exit
            .1
            .wait_timeout_while(state, timeout, |_| !self.child_waitable.load(Ordering::Acquire))
            .recover_poison();
        self.child_waitable.load(Ordering::Acquire)
    }

    pub(crate) fn wait_for_pty_drain(&self, timeout: Duration) -> bool {
        if self.pty_drained.load(Ordering::Acquire) {
            return true;
        }
        // The child-exit mutex is only a rendezvous guard here; the PTY
        // reader notifies the same condition variable after publishing
        // its final bytes and setting pty_drained.
        let state = self.child_exit.0.lock().recover_poison();
        let (_state, _) = self
            .child_exit
            .1
            .wait_timeout_while(state, timeout, |_| !self.pty_drained.load(Ordering::Acquire))
            .recover_poison();
        self.pty_drained.load(Ordering::Acquire)
    }

    pub(crate) fn publish_child_wait_predicate(&self, predicate: &AtomicBool) {
        // Every predicate consumed by child_exit.wait_* must change while
        // holding this mutex. Otherwise a notifier can run after a waiter
        // checks the atomic but before Condvar::wait arms, losing the only
        // wake that allows the terminal exit to be published.
        let _state = self.child_exit.0.lock().recover_poison();
        predicate.store(true, Ordering::Release);
        self.child_exit.1.notify_all();
    }

    pub(crate) fn mark_child_waitable(&self) {
        self.publish_child_wait_predicate(&self.child_waitable);
    }

    pub(crate) fn mark_pty_drained(&self) {
        self.publish_child_wait_predicate(&self.pty_drained);
    }

    pub(crate) fn request_forced_pty_drain(&self) {
        self.force_pty_drain.store(true, Ordering::Release);
        // Wake the otherwise blocking poll in the sole PTY reader. The
        // byte has no protocol meaning; it only makes the wake fd ready.
        let _ = self.pty_drain_waker.lock().recover_poison().write_all(&[1]);
    }

    pub(crate) fn request_termination(self: &Arc<Self>) {
        let already_started = {
            // Serialize the ownership transition with WNOWAIT's final
            // reap decision so an explicit Terminate cannot lose the
            // original reserved PID/PGID in between.
            let _signal = self.child_signal_lock.lock().recover_poison();
            self.termination_started.swap(true, Ordering::AcqRel)
        };
        if already_started {
            return;
        }
        let worker = self.clone();
        if thread::Builder::new()
            .name("terminal-host-terminate".into())
            .spawn(move || worker.terminate_and_wait())
            .is_err()
        {
            // Bounded fallback: even thread exhaustion cannot turn an
            // accepted Terminate into an unbounded or ignored request.
            self.terminate_and_wait();
        }
    }

    #[cfg(not(unix))]
    pub(crate) fn finish_group_escalation(&self) {
        self.publish_child_wait_predicate(&self.group_escalation_complete);
    }

    /// Windows has no process groups to scan: the session ends with the
    /// direct child, and the Kill step ends the rest of its job.
    #[cfg(not(unix))]
    pub(crate) fn wait_for_terminal_session_end(&self, grace: Duration) -> bool {
        self.wait_for_child_waitable(grace)
    }

    pub(crate) fn publish_exit_if_drained(&self) {
        // A running program has no exit to publish, and its host no
        // publisher thread: the child thread asks again once it has stored
        // the exit, and that request starts the thread.
        if !self.child_exit_may_be_known() {
            return;
        }
        self.ensure_exit_publisher();
        // Persistence can block or retry under filesystem pressure. A
        // dedicated host-owned worker keeps snapshots, client input, and
        // the listener accept loop independent of that durable write.
        let _ = self.exit_publish_requests.send(());
    }

    /// Whether the child's exit is stored. Also true while the exit's lock
    /// is held: the child thread asks for publication holding it, right
    /// after storing the exit, and a wrong yes only starts the publisher
    /// early. A no is read under the lock, so the store that follows it is
    /// followed by a request that sees every flag set before this call.
    fn child_exit_may_be_known(&self) -> bool {
        match self.child_exit.0.try_lock() {
            Ok(exit) => exit.is_some(),
            Err(std::sync::TryLockError::Poisoned(exit)) => exit.into_inner().is_some(),
            Err(std::sync::TryLockError::WouldBlock) => true,
        }
    }

    /// Arms the exit publisher. Its thread (`terminal-host-exit`) starts with
    /// the first request that has an exit to publish
    /// ([`Self::publish_exit_if_drained`]): a host whose program runs keeps
    /// no thread parked for the one write of its life.
    pub(crate) fn start_exit_publisher(
        host: &Arc<Self>,
        requests: Receiver<()>,
    ) -> std::io::Result<()> {
        *host.exit_publisher.lock().recover_poison() = Some((Arc::downgrade(host), requests));
        Ok(())
    }

    /// Starts the armed publisher's thread, once. A start that fails keeps
    /// the publisher armed, and the request queued behind it, for the next
    /// request.
    fn ensure_exit_publisher(&self) {
        let mut armed = self.exit_publisher.lock().recover_poison();
        if armed.is_none() {
            return;
        }
        // The thread takes the receiver from this slot, so it is still here
        // when the thread could not start.
        let slot = Arc::new(Mutex::new(armed.take()));
        for attempt in 0..EXIT_PUBLISHER_START_ATTEMPTS {
            let thread_slot = slot.clone();
            let spawned =
                thread::Builder::new().name("terminal-host-exit".into()).spawn(move || {
                    let taken = thread_slot.lock().recover_poison().take();
                    if let Some((host, requests)) = taken {
                        Self::run_exit_publisher(host, requests);
                    }
                });
            match spawned {
                Ok(_) => return,
                Err(error) if attempt + 1 == EXIT_PUBLISHER_START_ATTEMPTS => {
                    eprintln!(
                        "terminal-host: the exit publisher did not start; the next request starts it: {error}"
                    );
                }
                Err(_) => thread::sleep(EXIT_PUBLISHER_START_RETRY),
            }
        }
        *armed = slot.lock().recover_poison().take();
    }

    pub(crate) fn run_exit_publisher(weak_host: Weak<Self>, requests: Receiver<()>) {
        while requests.recv().is_ok() {
            let mut attempt = 0_u64;
            let mut retry_delay = HOST_EXIT_PERSIST_RETRY_MIN;
            let mut next_report = Instant::now();
            loop {
                let Some(host) = weak_host.upgrade() else {
                    return;
                };
                let result = host.persist_and_publish_exit_if_drained();
                drop(host);
                match result {
                    Ok(()) => {
                        if let Some(host) = weak_host.upgrade() {
                            clear_exit_persistence_diagnostic(&host.exit_record_path);
                        }
                        break;
                    }
                    Err(error) => {
                        // The host stays live and sends no Exit until the
                        // durable sidecar succeeds. Reconnecting muxes can
                        // still inspect the retained snapshot, and a disk
                        // failure cannot erase the authoritative status.
                        attempt = attempt.saturating_add(1);
                        let now = Instant::now();
                        if now >= next_report {
                            if let Some(host) = weak_host.upgrade() {
                                let _ = write_exit_persistence_diagnostic(
                                    &host.exit_record_path,
                                    attempt,
                                    &error,
                                );
                            }
                            next_report = now + HOST_EXIT_PERSIST_REPORT_INTERVAL;
                        }
                        thread::sleep(retry_delay);
                        while requests.try_recv().is_ok() {}
                        retry_delay = next_exit_persistence_retry_delay(retry_delay);
                    }
                }
            }
        }
    }

    pub(crate) fn persist_and_publish_exit_if_drained(&self) -> anyhow::Result<()> {
        // A command may exit before its launching daemon reaches the host
        // socket. Keep the final parser snapshot and canonical Exit
        // available until that first authenticated owner stream has been
        // inserted into the broadcast set.
        if !self.launch_owner_stream_ready.load(Ordering::Acquire) {
            return Ok(());
        }
        let exit = persist_and_claim_host_exit_after_drain(
            &self.child_exit.0,
            &self.pty_drained,
            &self.exit_published,
            |exit| {
                // With its directory gone no daemon reads the exit record,
                // and writing it would recreate a deleted tree (#36625). The
                // directory check also covers a removal the watch has not
                // reported yet; a removal after it is the remaining window.
                if record_root_removed()
                    || !self.exit_record_path.parent().is_some_and(Path::is_dir)
                {
                    return Ok(());
                }
                write_exit_record(
                    &self.exit_record_path,
                    &TerminalHostExitRecord::new(
                        &TerminalHostIdentity {
                            terminal_id: self.terminal_id.to_hex(),
                            incarnation: self.incarnation.to_hex(),
                        },
                        owner_gone_exit(exit.clone()),
                    ),
                )
            },
        )?;
        if let Some(exit) = exit.map(owner_gone_exit) {
            let _source_order = self.source_order_lock.lock().recover_poison();
            // Snapshot capture keeps `term` held from the dead check
            // through smart subscription. Publish Exit under that same
            // lock so an attach either joins before Exit or observes dead.
            {
                // A parser that panicked while it held the lock poisoned
                // it; the exit must still be published (host_parser.rs).
                let _term = self.term.lock().recover_poison();
                self.dead.store(true, Ordering::Release);
                self.accept_waker.wake();
                let payload = encode_terminal_exit(&exit);
                let cursor = self.smart.publish(Frame::new(MessageKind::Exit, payload.clone()));
                self.smart.mark_applied(cursor);
                self.broadcast(MessageKind::Exit, payload);
            }
            self.note_parser_progress();
        }
        Ok(())
    }

    pub(crate) fn terminate_and_wait(&self) {
        {
            let _signal = self.child_signal_lock.lock().recover_poison();
            self.termination_started.store(true, Ordering::Release);
        }
        // Closing a terminal ends its programs gracefully, off every UI
        // path (the tab is already gone): SIGHUP to the session's groups,
        // HOST_HANGUP_GRACE for them to exit, SIGTERM to what is left,
        // HOST_SIGTERM_GRACE, then SIGKILL. ProcessSignaller only targets
        // the direct child; the group signals reach foreground jobs and
        // descendants too.
        self.signal_terminal_process_groups(GroupSignal::Hangup);
        if !self.child_waitable.load(Ordering::Acquire) {
            let _ = self.killer.lock().recover_poison().kill();
        }
        if !self.wait_for_terminal_session_end(HOST_HANGUP_GRACE) {
            self.signal_terminal_process_groups(GroupSignal::Terminate);
            let _ = self.wait_for_terminal_session_end(HOST_SIGTERM_GRACE);
        }
        let _ = self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE);

        // The direct child may ignore SIGHUP, or it may already have
        // exited while a descendant retains the PTY. Kill both the
        // original session group and its current foreground job group.
        // This escalation is mandatory even if Darwin reports PTY EOF as
        // soon as the session leader exits: an HUP-ignoring descendant
        // can still be alive in the now-invisible original group.
        self.signal_terminal_process_groups(GroupSignal::Kill);
        self.finish_group_escalation();
        let child_exited = self.wait_for_child_exit(HOST_KILL_WAIT);
        if child_exited && self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE) {
            return;
        }

        if child_exited {
            // A process that escaped the PTY session can retain a slave
            // descriptor forever. Do not let an explicit tombstone hang
            // the durable host: wake the reader, drain bytes already
            // readable for a short bounded window, then publish Exit.
            self.request_forced_pty_drain();
            let _ = self.wait_for_pty_drain(HOST_FORCED_DRAIN_WINDOW * 2);
        }
    }
}
