use super::*;

/// A newly adopted host must confirm even an absent cwd at a new resource revision.
pub(super) enum PublishedDirectory {
    Unreported,
    Reported(Option<String>),
}

impl Surface {
    /// Raw VT state is only a candidate. Public state changes after its ordered commit.
    pub(crate) fn published_directory(&self) -> Option<String> {
        self.as_pty().and_then(|pty| match &*pty.published_directory.lock().unwrap() {
            PublishedDirectory::Unreported => None,
            PublishedDirectory::Reported(value) => value.clone(),
        })
    }

    /// The directory the public graph shows: the shell's committed report when
    /// it has made one, nothing after it explicitly cleared that report, and
    /// otherwise the directory the daemon launched the terminal in
    /// (https://github.com/manaflow-ai/cmux/issues/10756).
    pub(crate) fn presented_directory(&self) -> Option<String> {
        let pty = self.as_pty()?;
        match &*pty.published_directory.lock().unwrap() {
            PublishedDirectory::Reported(Some(directory)) => Some(directory.clone()),
            PublishedDirectory::Reported(None)
                if pty.directory_reported.load(Ordering::Acquire) =>
            {
                None
            }
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
            PublishedDirectory::Reported(value) => value == directory,
        })
    }

    pub(crate) fn commit_published_directory(&self, directory: Option<String>) {
        if let Some(pty) = self.as_pty() {
            *pty.published_directory.lock().unwrap() = PublishedDirectory::Reported(directory);
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
    /// A program set the title through OSC 0/2, including an explicit clear.
    pub(super) fn record_reported_title(&self, title: String) {
        *self.reported_title.lock().unwrap() = Some(title.clone());
        *self.title.lock().unwrap() = title;
    }

    /// A VT replay rebuilt the parser. A replayed title is the program's own
    /// state, so a non-empty one counts as a report. An empty one means only
    /// that the replay did not carry a title, so the earlier report (or the
    /// persisted title) keeps presenting.
    pub(super) fn record_replayed_title(&self, title: String) {
        if !title.is_empty() {
            *self.reported_title.lock().unwrap() = Some(title.clone());
        }
        *self.title.lock().unwrap() = title;
    }

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
