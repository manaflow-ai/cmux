//! How a terminal incarnation ended (its [`TerminalEnd`], with provenance)
//! and the hosted termination handshake that waits for that end.

use super::*;

impl Surface {
    pub fn terminal_exit(&self) -> Option<TerminalExit> {
        self.terminal_end().map(|end| end.exit().clone())
    }

    /// How this incarnation ended, with its provenance.
    pub(crate) fn terminal_end(&self) -> Option<TerminalEnd> {
        self.as_pty().and_then(|pty| pty.exit.lock().unwrap().clone())
    }

    /// Record a process end on a test runtime, as a host's Exit frame does.
    #[cfg(test)]
    pub(crate) fn record_process_end_for_test(&self, exit: TerminalExit) {
        if let Some(pty) = self.as_pty() {
            *pty.exit.lock().unwrap() = Some(TerminalEnd::ProcessEnded(exit));
        }
    }

    /// Whether [`Self::begin_host_termination`] would signal a terminal host
    /// (`Some`) rather than report a local runtime (`None`). It only reads
    /// the runtime kind; it never waits for the host.
    #[cfg(unix)]
    pub(crate) fn has_host_termination(&self) -> bool {
        let Some(pty) = self.as_pty() else { return false };
        if pty.host_identity.is_none() || pty.host_exit_record_path.is_none() {
            return false;
        }
        !matches!(&*pty.runtime.lock().unwrap(), PtyRuntime::Local { .. })
    }

    /// Ask a hosted terminal to exit through its existing owner connection,
    /// without waiting for a receipt or the exit. Local terminals return
    /// `None` and keep their existing kill path. Pass the result to
    /// [`Self::wait_for_host_exit`], whose durable exit receipt is the
    /// authoritative completion.
    #[cfg(unix)]
    pub(crate) fn begin_host_termination(&self) -> anyhow::Result<Option<HostTermination>> {
        let Some(pty) = self.as_pty() else { return Ok(None) };
        let Some(identity) = pty.host_identity.clone() else { return Ok(None) };
        let Some(path) = pty.host_exit_record_path.clone() else { return Ok(None) };
        let observed = pty.stream_progress.revision();
        let already_exited = {
            let runtime = pty.runtime.lock().unwrap();
            match &*runtime {
                PtyRuntime::Hosted(host) => {
                    host.request_termination().map_err(|error| {
                        anyhow::anyhow!("send terminal-host termination: {error}")
                    })?;
                    false
                }
                PtyRuntime::ExitedHosted => true,
                PtyRuntime::Local { .. } => return Ok(None),
            }
        };
        Ok(Some(HostTermination { identity, path, observed, already_exited }))
    }

    /// Wait for the ordered host stream to publish the durable exit receipt
    /// after [`Self::begin_host_termination`].
    #[cfg(unix)]
    pub(crate) fn wait_for_host_exit(
        &self,
        termination: HostTermination,
        deadline: Instant,
    ) -> anyhow::Result<(PathBuf, crate::terminal_host_runtime::TerminalHostExitRecord)> {
        let pty = self
            .as_pty()
            .ok_or_else(|| anyhow::anyhow!("terminal host termination lost its PTY runtime"))?;
        let HostTermination { identity, path, mut observed, already_exited } = termination;
        loop {
            if let Some(end) = pty.exit.lock().unwrap().clone() {
                return Ok((
                    path,
                    crate::terminal_host_runtime::TerminalHostExitRecord::new(
                        &identity,
                        end.exit().clone(),
                    ),
                ));
            }
            anyhow::ensure!(
                !already_exited,
                "terminal host exited without publishing an exit outcome"
            );
            observed =
                pty.stream_progress.wait_for_change(observed, deadline).ok_or_else(|| {
                    anyhow::anyhow!("terminal host did not exit before the close deadline")
                })?;
        }
    }

    #[cfg(unix)]
    pub(crate) fn terminal_host_exit_sidecar(
        &self,
    ) -> Option<(PathBuf, crate::terminal_host_runtime::TerminalHostExitRecord)> {
        let pty = self.as_pty()?;
        let path = pty.host_exit_record_path.clone()?;
        let identity = pty.host_identity.as_ref()?;
        let exit = pty.exit.lock().unwrap().as_ref()?.exit().clone();
        Some((path, crate::terminal_host_runtime::TerminalHostExitRecord::new(identity, exit)))
    }
}

#[cfg(unix)]
pub(super) fn mark_hosted_runtime_exited(
    pty: &PtySurface,
    identity: &crate::terminal_host_runtime::TerminalHostIdentity,
) {
    let mut runtime = pty.runtime.lock().unwrap();
    let matches = match &*runtime {
        PtyRuntime::Hosted(host) => host.identity() == *identity,
        PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => false,
    };
    if matches {
        if let PtyRuntime::Hosted(host) = &*runtime {
            host.disconnect();
        }
        *runtime = PtyRuntime::ExitedHosted;
        pty.supports_clear_history_key_fallback.store(false, Ordering::Release);
        drop(runtime);
        pty.finish_hosted_exit();
    }
}

pub(super) fn publish_local_exit_if_ready(surface: &Arc<Surface>) {
    let Some(pty) = surface.as_pty() else { return };
    if !pty.local_pty_drained.load(Ordering::Acquire) || pty.exit.lock().unwrap().is_none() {
        return;
    }
    if pty.exit_notified.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err()
    {
        return;
    }
    pty.dead.store(true, Ordering::Release);
    if let Some(mux) = pty.mux.upgrade() {
        mux.surface_exited(surface.id);
    }
}

#[cfg(windows)]
pub(super) fn close_local_terminal_master_after_exit(surface: &Arc<Surface>) {
    let Some(pty) = surface.as_pty() else { return };
    let master = {
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { master, .. } = &mut *runtime;
        master.take()
    };
    // portable-pty's ConPTY reader keeps a separate output handle. Closing
    // the master closes the pseudoconsole, which lets that reader drain the
    // final bytes and then observe EOF.
    drop(master);
}

#[cfg(not(windows))]
pub(super) fn close_local_terminal_master_after_exit(_surface: &Arc<Surface>) {}
