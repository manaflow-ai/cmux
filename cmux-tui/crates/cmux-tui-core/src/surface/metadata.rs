//! Surface metadata reads and writes: title, cwd, process and spawn details,
//! terminal host identity and connection state, name, selection and dirty flags.

use super::*;

impl Surface {
    pub fn set_name(&self, name: Option<String>) {
        *self.name.lock().unwrap() = name;
    }

    pub fn name(&self) -> Option<String> {
        self.name.lock().unwrap().clone()
    }

    pub fn set_selection_text(&self, text: Option<String>) {
        *self.selection.lock().unwrap() = text;
    }

    pub fn selection_text(&self) -> Option<String> {
        self.selection.lock().unwrap().clone()
    }

    pub fn title(&self) -> String {
        match self {
            Surface::Pty(pty) => pty.title.lock().unwrap().clone(),
            Surface::Browser(browser) => browser.title(),
        }
    }

    pub fn pwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.pwd.lock().unwrap().clone())
    }

    pub fn local_cwd(&self) -> Option<String> {
        let hosted = match self {
            Surface::Pty(pty) => {
                #[cfg(unix)]
                {
                    matches!(
                        &*pty.runtime.lock().unwrap(),
                        PtyRuntime::Hosted(_) | PtyRuntime::ExitedHosted
                    )
                }
                #[cfg(not(unix))]
                {
                    false
                }
            }
            Surface::Browser(_) => false,
        };
        // A hosted terminal's OSC 7 report counts only when it names this host
        // (the same rule its published directory follows); a local PTY may also
        // report a hostless URL or a plain path. Anything else falls back to the
        // authenticated launch directory below.
        let terminal_pwd_to_local_path = if hosted {
            platform::terminal_pwd_to_local_path
        } else {
            platform::local_terminal_pwd_to_local_path
        };
        let terminal_cwd = self
            .pwd()
            .as_deref()
            .and_then(terminal_pwd_to_local_path)
            .map(|path| path.to_string_lossy().into_owned());
        terminal_cwd.or_else(|| {
            self.spawn_cwd()
                .as_deref()
                .and_then(platform::spawn_cwd_to_local_path)
                .map(|path| path.to_string_lossy().into_owned())
        })
    }

    #[cfg(test)]
    pub(crate) fn set_test_pwd(&self, pwd: Option<String>) {
        let pty = self.as_pty().expect("test PTY surface");
        pty.record_directory(pwd);
        pty.directory_pending.store(true, Ordering::Release);
    }

    pub fn process_id(&self) -> Option<u32> {
        self.as_pty().and_then(|pty| pty.pid)
    }

    pub fn spawn_command(&self) -> Option<String> {
        self.as_pty().map(|pty| pty.command.join(" "))
    }

    pub fn spawn_argv(&self) -> Option<Vec<String>> {
        self.as_pty().map(|pty| pty.command.clone())
    }

    pub fn spawn_cwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.cwd.clone())
    }

    /// Process-stable identity for hosted terminals. Surface ids remain
    /// daemon-local compatibility handles and may change after adoption.
    pub fn terminal_host_identity(
        &self,
    ) -> Option<crate::terminal_host_runtime::TerminalHostIdentity> {
        self.as_pty().and_then(|pty| pty.host_identity.clone())
    }

    #[cfg(unix)]
    pub(crate) fn release_pending_terminal_host_binding(&self) {
        if let Some(pty) = self.as_pty() {
            pty.pending_host_binding.lock().unwrap().take();
        }
    }

    pub fn terminal_host_connection_state(&self) -> Option<TerminalHostConnectionState> {
        let pty = self.as_pty()?;
        pty.host_identity.as_ref()?;
        Some(TerminalHostConnectionState::from_u8(
            pty.host_connection_state.load(Ordering::Acquire),
        ))
    }

    /// Ask the host to mint a one-use renderer credential. The durable owner
    /// secret remains confined to the daemon and its private state record.
    pub fn mint_renderer_grant(
        &self,
        ttl: Duration,
    ) -> anyhow::Result<crate::terminal_host_runtime::RendererGrant> {
        #[cfg(unix)]
        if let Some(pty) = self.as_pty()
            && let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
        {
            return host.mint_renderer_grant(ttl);
        }
        let _ = ttl;
        anyhow::bail!("surface is not backed by a terminal host")
    }

    pub fn is_dead(&self) -> bool {
        match self {
            Surface::Pty(pty) => pty.dead.load(Ordering::Acquire),
            Surface::Browser(browser) => browser.is_dead(),
        }
    }

    /// Clear the coalesced output flag; returns whether output was pending.
    pub fn take_dirty(&self) -> bool {
        match self {
            Surface::Pty(pty) => pty.dirty.swap(false, Ordering::AcqRel),
            Surface::Browser(browser) => browser.take_dirty(),
        }
    }
}
