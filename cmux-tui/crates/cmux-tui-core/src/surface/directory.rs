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
        self.as_pty()?.terminal_metadata.lock().recover_poison().progress()
    }

    /// The terminal's running shell command: how it uses the terminal and
    /// when it started (`terminal-activity-v1`).
    pub(crate) fn terminal_command_activity(
        &self,
    ) -> Option<(crate::terminal_activity::CommandActivity, u64)> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .command_activity()
    }

    /// When the terminal's shell drew the prompt it sits at (OSC 133 A, until
    /// the next command starts): `extra.prompt` (`terminal-activity-v1`).
    pub(crate) fn terminal_prompt_since(&self) -> Option<u64> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .prompt_since()
    }

    /// When the terminal last printed anything: `extra.last_output`
    /// (`terminal-activity-v1`).
    pub(crate) fn terminal_last_output(&self) -> Option<u64> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .last_output()
    }

    /// The terminal's OSC 7501 program status records as the public value
    /// (`extra.program_status`); `running` false hides the records that end
    /// with the process. `None` when nothing is shown.
    pub(crate) fn terminal_program_status(&self, running: bool) -> Option<serde_json::Value> {
        let records = self.as_pty()?.program_status_records();
        let records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        records.to_json(running)
    }

    /// The status this terminal's tab shows (`ShownProgramStatus`).
    pub fn shown_program_status(&self) -> Option<crate::program_status::ShownProgramStatus> {
        let records = self.as_pty()?.program_status_records();
        let records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        records.shown(!self.is_dead())
    }

    /// Whether [`Self::publish_pending_directory`] or
    /// [`Self::publish_pending_progress`] has something to publish. Reads
    /// in-memory state only, so a reader can ask after every chunk and hand
    /// the publication (the registry's sqlite) to a thread that may block.
    pub(crate) fn has_pending_publication(&self) -> bool {
        let Some(pty) = self.as_pty() else { return false };
        if pty.directory_pending.load(Ordering::Acquire) {
            return true;
        }
        let (metadata_changed, records) = {
            let metadata =
                pty.terminal_metadata.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            (metadata.has_progress_or_busy_change(), metadata.program_status())
        };
        metadata_changed
            || records
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .has_pending(!self.is_dead())
    }

    /// Publish a changed OSC 9;4 progress, shell busy state, or OSC 7501
    /// program status as a terminal upsert, then post the notifications the records asked for
    /// (after the upsert, so a client that opens the notification finds the
    /// record). The reader calls this after each output chunk, outside the
    /// parser lock.
    pub(crate) fn publish_pending_progress(&self) {
        let Some(pty) = self.as_pty() else { return };
        let (progress_changed, records) = {
            let mut metadata = pty.terminal_metadata.lock().recover_poison();
            let progress = metadata.take_progress_change().is_some();
            (metadata.take_busy_change() || progress, metadata.program_status())
        };
        let (status_changed, shown_changed, alerts) = {
            let mut records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let shown = records.take_shown_change(!self.is_dead());
            (records.take_change(), shown, records.take_alerts())
        };
        // A publish after the terminal died (reconnect) can hide its
        // running records with no new report: send that shown change too.
        if !progress_changed && !status_changed && shown_changed.is_none() {
            return;
        }
        let Some(mux) = pty.mux.upgrade() else { return };
        let mutation = if status_changed { "terminal.program_status" } else { "terminal.progress" };
        if (progress_changed || status_changed)
            && let Err(error) = mux.publish_terminal_progress(self, mutation)
        {
            eprintln!("cmux-tui: terminal {mutation} publication failed: {error}");
        }
        // The tab indicator (TUI) changes only with the shown status.
        if let Some(status) = shown_changed {
            mux.emit_terminal_program_status(self.id, status);
        }
        if !alerts.is_empty() {
            let notifications = pty
                .terminal_metadata
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .admit_program_status_alerts(alerts, Instant::now());
            if !notifications.is_empty() {
                mux.post_terminal_notifications(self.id, notifications);
            }
        }
    }

    /// Hands the publications this terminal's output asked for (its cwd, its
    /// progress and program status upserts) to the mux's work lane. Each is
    /// a SQLite workspace registry commit, which an output thread
    /// (`surface-<id>-reader`, `surface-<id>-host`: echo threads with
    /// blocking disallowed) may not make (MQ-13): in the
    /// detector's panic mode the reader panicked holding the registry and
    /// state locks. Chromium posts such work as a `MayBlock` task
    /// (base/task/task_traits.h). The check here is memory only; at most one
    /// publication is queued per terminal, in the terminal's own sequence,
    /// and it publishes the newest state when it runs, so a burst of output
    /// asks for one commit.
    pub(crate) fn post_pending_publications(&self) {
        let Some(pty) = self.as_pty() else { return };
        if !self.has_pending_publication() {
            return;
        }
        if pty.publication_posted.swap(true, Ordering::AcqRel) {
            return;
        }
        let posted = pty
            .mux
            .upgrade()
            .is_some_and(|mux| mux.post_terminal_publications(self.id, &pty.publications));
        if !posted {
            pty.publication_posted.store(false, Ordering::Release);
        }
    }

    /// Hands the notifications this terminal's output asked for to the
    /// work lane, in the terminal's publication sequence
    /// (`Mux::post_terminal_notifications_off_output`): the output thread
    /// may not post them itself.
    pub(crate) fn post_output_notifications(
        &self,
        notifications: Vec<crate::terminal_metadata::TerminalNotification>,
    ) {
        let Some(pty) = self.as_pty() else { return };
        let Some(mux) = pty.mux.upgrade() else { return };
        mux.post_terminal_notifications_off_output(self.id, &pty.publications, notifications);
    }

    /// The queued publication ([`Self::post_pending_publications`]), on the
    /// work lane: the next change queues another.
    pub(crate) fn publish_posted_publications(&self) {
        let Some(pty) = self.as_pty() else { return };
        pty.publication_posted.store(false, Ordering::Release);
        self.publish_pending_directory();
        self.publish_pending_progress();
    }

    /// Raw VT state is only a candidate. Public state changes after its ordered commit.
    pub(crate) fn published_directory(&self) -> Option<String> {
        self.as_pty().and_then(|pty| match &*pty.published_directory.lock().recover_poison() {
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
        match &*pty.published_directory.lock().recover_poison() {
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
        self.as_pty().is_some_and(|pty| match &*pty.published_directory.lock().recover_poison() {
            PublishedDirectory::Unreported => false,
            PublishedDirectory::Cleared => directory.is_none(),
            PublishedDirectory::Reported(value) => value == directory,
        })
    }

    pub(crate) fn commit_published_directory(&self, directory: Option<String>) {
        if let Some(pty) = self.as_pty() {
            let mut published = pty.published_directory.lock().recover_poison();
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
        let raw = pty.pwd.lock().recover_poison().clone();
        #[cfg(any(unix, windows))]
        let hosted = matches!(
            &*pty.runtime.lock().recover_poison(),
            PtyRuntime::Hosted(_) | PtyRuntime::ExitedHosted
        );
        #[cfg(not(any(unix, windows)))]
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
                let current = pty.pwd.lock().recover_poison();
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
        let mut previous = self.pwd.lock().recover_poison();
        if *previous != value {
            *previous = value;
            self.directory_pending.store(true, Ordering::Release);
        }
    }
}
