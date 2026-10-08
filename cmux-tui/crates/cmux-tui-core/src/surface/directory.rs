use super::*;

/// A newly adopted host must confirm even an absent cwd at a new resource revision.
pub(super) enum PublishedDirectory {
    Unreported,
    Reported(Option<String>),
    /// A committed report was followed by a committed absent report: the
    /// shell cleared its directory, so the launch directory is not shown.
    Cleared,
}

impl PtyTerminalRuntime {
    /// The OSC 7501 records this terminal's parser feeds. A replaced mirror
    /// terminal (resize, reconnect) gets the same records.
    pub(super) fn program_status_records(&self) -> crate::program_status::SharedProgramStatus {
        self.terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .program_status()
    }
}

impl Surface {
    /// The terminal's OSC 9;4 progress while one is shown.
    pub(crate) fn terminal_progress(&self) -> Option<crate::terminal_metadata::TerminalProgress> {
        self.as_pty()?.terminal_metadata.lock().unwrap().progress()
    }

    /// The terminal's OSC 7501 program status records as the public value
    /// (`extra.program_status`); `running` false hides the records that end
    /// with the process. `None` when nothing is shown.
    pub(crate) fn terminal_program_status(&self, running: bool) -> Option<serde_json::Value> {
        let records = self.as_pty()?.program_status_records();
        let records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        records.to_json(running)
    }

    /// Publish a changed OSC 9;4 progress or OSC 7501 program status as a
    /// terminal upsert. The reader calls this after each output chunk,
    /// outside the parser lock.
    pub(crate) fn publish_pending_progress(&self) {
        let Some(pty) = self.as_pty() else { return };
        let (progress_changed, records) = {
            let mut metadata = pty.terminal_metadata.lock().unwrap();
            (metadata.take_progress_change().is_some(), metadata.program_status())
        };
        let status_change = {
            let mut records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            records.take_change().then(|| records.last_change_json())
        }
        .flatten();
        let status_changed = status_change.is_some();
        if !progress_changed && !status_changed {
            return;
        }
        let Some(mux) = pty.mux.upgrade() else { return };
        let mutation = if status_changed { "terminal.program_status" } else { "terminal.progress" };
        if let Err(error) = mux.publish_terminal_progress(self, mutation, status_change) {
            eprintln!("cmux-tui: terminal {mutation} publication failed: {error}");
        }
    }

    /// Raw VT state is only a candidate. Public state changes after its ordered commit.
    pub(crate) fn published_directory(&self) -> Option<String> {
        self.as_pty().and_then(|pty| match &*pty.published_directory.lock().unwrap() {
            PublishedDirectory::Unreported | PublishedDirectory::Cleared => None,
            PublishedDirectory::Reported(value) => value.clone(),
        })
    }

    /// The directory the public graph shows: the shell's committed report when
    /// it has made one, nothing after it explicitly cleared that report, and
    /// otherwise the directory the daemon launched the terminal in
    /// (https://github.com/manaflow-ai/cmux/issues/10756).
    /// Only committed state decides: a report the reader recorded but has not
    /// committed yet must not turn the initial absent state into a clear.
    pub(crate) fn presented_directory(&self) -> Option<String> {
        let pty = self.as_pty()?;
        match &*pty.published_directory.lock().unwrap() {
            PublishedDirectory::Reported(Some(directory)) => Some(directory.clone()),
            PublishedDirectory::Cleared => None,
            PublishedDirectory::Reported(None) | PublishedDirectory::Unreported => pty.cwd.clone(),
        }
    }

    /// Whether the shell has ever reported a directory, which makes a later
    /// absent report an explicit clear.
    pub(crate) fn directory_was_reported(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.directory_reported.load(Ordering::Acquire))
    }

    pub(crate) fn directory_publication_matches(&self, directory: &Option<String>) -> bool {
        self.as_pty().is_some_and(|pty| match &*pty.published_directory.lock().unwrap() {
            PublishedDirectory::Unreported => false,
            PublishedDirectory::Cleared => directory.is_none(),
            PublishedDirectory::Reported(value) => value == directory,
        })
    }

    pub(crate) fn commit_published_directory(&self, directory: Option<String>) {
        if let Some(pty) = self.as_pty() {
            let mut published = pty.published_directory.lock().unwrap();
            let cleared = directory.is_none()
                && matches!(
                    *published,
                    PublishedDirectory::Reported(Some(_)) | PublishedDirectory::Cleared
                );
            *published = if cleared {
                PublishedDirectory::Cleared
            } else {
                PublishedDirectory::Reported(directory)
            };
        }
    }

    pub(crate) fn publish_pending_directory(&self) {
        let Some(pty) = self.as_pty() else { return };
        if !pty.directory_pending.load(Ordering::Acquire) {
            return;
        }
        let raw = pty.pwd.lock().unwrap().clone();
        #[cfg(unix)]
        let hosted = matches!(
            &*pty.runtime.lock().unwrap(),
            PtyRuntime::Hosted(_) | PtyRuntime::ExitedHosted
        );
        #[cfg(not(unix))]
        let hosted = false;
        let directory = raw
            .as_deref()
            .and_then(|value| {
                if hosted {
                    platform::terminal_pwd_to_local_path(value)
                } else {
                    platform::local_terminal_pwd_to_local_path(value)
                }
            })
            .map(|path| path.to_string_lossy().into_owned());
        let Some(mux) = pty.mux.upgrade() else { return };
        match mux.publish_terminal_directory(self, &raw, directory) {
            Ok(true) => {
                let current = pty.pwd.lock().unwrap();
                if *current == raw {
                    pty.directory_pending.store(false, Ordering::Release);
                }
            }
            Ok(false) => {}
            Err(error) => eprintln!("terminal cwd publication failed: {error}"),
        }
    }
}

impl PtyTerminalRuntime {
    /// Called in the serialized parser stream; publication happens after releasing VT locks.
    /// `None` is a real report too: the VT keeps its pwd across output until the
    /// shell clears it, so a change to `None` must reach the graph like any other.
    pub(super) fn record_directory(&self, value: Option<String>) {
        if value.is_some() {
            self.directory_reported.store(true, Ordering::Release);
        }
        let mut previous = self.pwd.lock().unwrap();
        if *previous != value {
            *previous = value;
            self.directory_pending.store(true, Ordering::Release);
        }
    }
}
