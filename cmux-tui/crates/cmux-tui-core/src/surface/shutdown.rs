//! Surface teardown: kill, daemon shutdown and disconnect, terminal reader and
//! reaper completion, and the hosted launch release.

use super::*;

impl Surface {
    pub(crate) fn terminal_journal_capture_epoch(&self) -> Option<u64> {
        self.as_pty().map(|pty| pty.journal_capture_epoch.load(Ordering::Acquire))
    }

    pub(crate) fn finish_terminal_reader(&self, deadline: Instant) -> Option<TerminalJournalGap> {
        let pty = self.as_pty()?;
        // Decide self-join under the lock and leave the reaper's own handle
        // in place: taking it and putting it back let a concurrent caller
        // see an empty slot and return while the handle was restored later.
        let reaper = {
            let mut slot = pty.reaper_thread.lock().unwrap();
            if slot
                .as_ref()
                .is_some_and(|reaper| reaper.thread().id() == std::thread::current().id())
            {
                eprintln!("cmux-tui: child reaper skipped self-join during shutdown");
                None
            } else {
                slot.take()
            }
        };
        if let Some(reaper) = reaper {
            if pty.reaper_completion.wait_until(deadline) {
                if reaper.join().is_err() {
                    eprintln!("cmux-tui: child reaper thread panicked during shutdown");
                }
            } else {
                *pty.reaper_thread.lock().unwrap() = Some(reaper);
                eprintln!(
                    "cmux-tui: child reaper did not stop before the shared shutdown deadline"
                );
            }
        }
        if let Some(reader) = pty.reader_thread.lock().unwrap().take() {
            if pty.reader_completion.wait_until(deadline) {
                if reader.join().is_err() {
                    eprintln!("cmux-tui: terminal reader thread panicked during shutdown");
                }
            } else {
                eprintln!(
                    "cmux-tui: terminal reader did not stop before the shared shutdown deadline; closing journal capture"
                );
            }
        }
        // A reader that is blocked in the PTY has an even capture epoch and
        // does not delay shutdown. Close the gate between updates. If one
        // update crossed the reader deadline, wait through the active-update
        // grace. Report a gap if that update still did not complete.
        let output_gap = pty.close_terminal_journal_capture_when_idle(deadline);
        if !output_gap || !pty.journal_capture_supported {
            return None;
        }
        pty.terminal_public_id.clone().map(|terminal_id| TerminalJournalGap {
            terminal_id,
            generation: pty.journal_generation.clone(),
            reason: "active_update_timeout",
        })
    }

    #[cfg(test)]
    pub(crate) fn install_terminal_reader_for_test(&self, reader: std::thread::JoinHandle<()>) {
        let pty = self.as_pty().expect("test reader requires a PTY surface");
        pty.reader_completion.reset();
        let completion = pty.reader_completion.clone();
        let reader = std::thread::spawn(move || {
            let result = reader.join();
            completion.complete();
            result.expect("installed test terminal reader panicked");
        });
        let previous = pty.reader_thread.lock().unwrap().replace(reader);
        assert!(previous.is_none(), "test PTY already owns a reader thread");
    }

    #[cfg(test)]
    pub(crate) fn install_terminal_reaper_for_test(&self, reaper: std::thread::JoinHandle<()>) {
        let pty = self.as_pty().expect("test reaper requires a PTY surface");
        pty.reaper_completion.reset();
        let completion = pty.reaper_completion.clone();
        let reaper = std::thread::spawn(move || {
            let result = reaper.join();
            completion.complete();
            result.expect("installed test terminal reaper panicked");
        });
        let previous = pty.reaper_thread.lock().unwrap().replace(reaper);
        assert!(previous.is_none(), "test PTY already owns a reaper thread");
    }

    #[cfg(test)]
    pub(super) fn install_terminal_reaper_that_finishes_for_test(
        self: &Arc<Self>,
        started: SyncSender<()>,
        proceed: Receiver<()>,
    ) -> Arc<ReaderCompletion> {
        let pty = self.as_pty().expect("test reaper requires a PTY surface");
        pty.reaper_completion.reset();
        let completion = pty.reaper_completion.clone();
        let reaper_completion = completion.clone();
        let surface = self.clone();
        let reaper = std::thread::spawn(move || {
            started.send(()).unwrap();
            proceed.recv().unwrap();
            reaper_completion.complete();
            surface.finish_terminal_reader(Instant::now() + Duration::from_secs(1));
        });
        let previous = pty.reaper_thread.lock().unwrap().replace(reaper);
        assert!(previous.is_none(), "test PTY already owns a reaper thread");
        completion
    }

    #[cfg(test)]
    pub(crate) fn wait_for_terminal_reader_for_test(&self, deadline: Instant) -> bool {
        self.as_pty().is_some_and(|pty| pty.reader_completion.wait_until(deadline))
    }

    #[cfg(test)]
    pub(crate) fn begin_terminal_journal_update_for_test(
        &self,
    ) -> Option<TerminalJournalUpdateGuard<'_>> {
        self.as_pty().and_then(|pty| pty.begin_terminal_journal_update())
    }

    pub fn kill(&self) {
        match self {
            Surface::Pty(pty) => {
                #[cfg(any(unix, windows))]
                let mut terminate_fallback = None;
                // Removal is authoritative. Prevent the mirror reader from
                // racing termination by reconnecting a Surface that no longer
                // exists in the mux topology.
                pty.owner_detaching.store(true, Ordering::Release);
                {
                    let mut runtime = pty.runtime.lock().unwrap();
                    match &mut *runtime {
                        PtyRuntime::Local { killer, .. } => {
                            let _ = killer.kill();
                        }
                        #[cfg(any(unix, windows))]
                        PtyRuntime::Hosted(host) => {
                            // The host owns record cleanup and removes it only
                            // after the PTY process has actually exited. Unlinking
                            // here would make a failed Terminate write turn a live
                            // shell into an undiscoverable orphan.
                            if host.terminate().is_err() {
                                terminate_fallback = Some(host.identity());
                            }
                        }
                        #[cfg(any(unix, windows))]
                        PtyRuntime::ExitedHosted => {}
                    }
                }
                if let Some(mux) = pty.mux.upgrade() {
                    #[cfg(any(unix, windows))]
                    if let Some(identity) = terminate_fallback {
                        mux.terminate_discovered_terminal_host(
                            &identity.terminal_id,
                            Some(&identity.incarnation),
                        );
                    }
                    let _ = mux.unregister_kitty_image_surface(self);
                }
            }
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub(crate) fn disconnect_for_daemon_shutdown(&self) {
        match self {
            #[cfg(any(unix, windows))]
            Surface::Pty(pty) => {
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                    pty.owner_detaching.store(true, Ordering::Release);
                    host.disconnect();
                    return;
                }
                if matches!(&*pty.runtime.lock().unwrap(), PtyRuntime::ExitedHosted) {
                    return;
                }
                self.kill();
            }
            #[cfg(not(any(unix, windows)))]
            Surface::Pty(_) => self.kill(),
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub(crate) fn shutdown_for_daemon(&self, deadline: Instant) -> Option<TerminalJournalGap> {
        if self.as_pty().is_some_and(|pty| pty.lifetime == PtyLifetime::DaemonOwned) {
            self.kill();
            return None;
        }
        #[cfg(any(unix, windows))]
        if let Some(pty) = self.as_pty() {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                pty.owner_detaching.store(true, Ordering::Release);
                let mut gap = None;
                if host.supports_journal_detach_fence()
                    && let Err(error) = host.detach_for_daemon_shutdown_until(deadline)
                {
                    eprintln!(
                        "cmux-tui: terminal host {} detach fence failed: {error:#}",
                        pty.event_surface_id
                    );
                    gap = pty.terminal_public_id.clone().map(|terminal_id| TerminalJournalGap {
                        terminal_id,
                        generation: pty.journal_generation.clone(),
                        reason: "detach_fence_failed",
                    });
                }
                host.disconnect();
                return gap;
            }
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return None;
            }
        }
        self.disconnect_for_daemon_shutdown();
        None
    }

    pub(crate) fn persist_host_workspace(&self, workspace_key: &str) -> anyhow::Result<()> {
        #[cfg(any(unix, windows))]
        if let Some(pty) = self.as_pty()
            && let PtyRuntime::Hosted(host) = &mut *pty.runtime.lock().unwrap()
        {
            return host.persist_workspace(workspace_key);
        }
        Ok(())
    }

    /// Release a newly launched host after the caller commits the terminal's
    /// public topology. Adoption and local PTYs are already active, making
    /// this idempotent for shared creation paths.
    pub(crate) fn activate_hosted_launch_stream(&self) -> anyhow::Result<bool> {
        #[cfg(any(unix, windows))]
        {
            let Some(pty) = self.as_pty() else { return Ok(false) };
            let mut runtime = pty.runtime.lock().unwrap();
            let PtyRuntime::Hosted(host) = &mut *runtime else { return Ok(false) };
            host.activate_launched_host().map_err(anyhow::Error::new)
        }
        #[cfg(not(any(unix, windows)))]
        Ok(false)
    }
}
