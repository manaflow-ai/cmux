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

    /// The last command the terminal's shell finished (OSC 133 `D`):
    /// `extra.last_command` (`terminal-exit-status-v1`).
    pub(crate) fn terminal_last_command(&self) -> Option<crate::terminal_activity::LastCommand> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .last_command()
    }

    /// When a client last wrote input: `extra.last_input`
    /// (`terminal-activity-v1`, read-time only).
    pub(crate) fn terminal_last_input(&self) -> Option<u64> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .last_input()
    }

    /// Notes that a client wrote input to this terminal now.
    pub(crate) fn note_terminal_input(&self) {
        let Some(pty) = self.as_pty() else { return };
        let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        pty.terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .note_input(now_ms);
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

    /// The output reader's side of this terminal's publications. The reader
    /// calls this after each output chunk, outside the parser lock, and never
    /// waits for the workspace registry here (#35413: under load the next
    /// output frame, a key's echo, waited up to 501 ms behind such a commit).
    /// - The alerts its OSC 7501 records raised are taken and rate-limited
    ///   now, in output order, as the inline publication did.
    /// - When its output left a directory, progress, activity or program
    ///   status change to publish (checked in memory under the terminal's
    ///   own locks), the mux's terminal publisher commits it.
    /// - The publisher posts the alerts after that commit (or after one
    ///   already queued, which publishes the latest state), so a client that
    ///   opens the notification finds the record, and after the
    ///   notifications that earlier output queued.
    pub(crate) fn queue_pending_publications(self: &Arc<Self>) {
        let Some(mux) = self.as_pty().and_then(|pty| pty.mux.upgrade()) else { return };
        let alerts = self.take_program_status_alerts();
        if self.publication_due() {
            mux.queue_terminal_publication(self);
        }
        mux.queue_terminal_notifications(self.id, alerts);
    }

    /// Whether `publish_pending_directory` or `publish_pending_state` would
    /// publish or emit something now. Marks nothing.
    fn publication_due(&self) -> bool {
        let Some(pty) = self.as_pty() else { return false };
        if pty.directory_pending.load(Ordering::Acquire) {
            return true;
        }
        let records = {
            let metadata =
                pty.terminal_metadata.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if metadata.has_publication_change() {
                return true;
            }
            metadata.program_status()
        };
        let records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        records.has_publication_change(!self.is_dead())
    }

    /// The alerts this terminal's OSC 7501 records raised since the last
    /// take, as the notifications that pass its rate limit now.
    fn take_program_status_alerts(&self) -> Vec<crate::terminal_metadata::TerminalNotification> {
        let Some(pty) = self.as_pty() else { return Vec::new() };
        let records = pty.program_status_records();
        let alerts =
            records.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take_alerts();
        if alerts.is_empty() {
            return Vec::new();
        }
        pty.terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .admit_program_status_alerts(alerts, Instant::now())
    }

    /// Publish a changed OSC 9;4 progress, shell busy state, or OSC 7501
    /// program status as a terminal upsert (and a program's wait starting or
    /// ending as agent roster evidence), then post the notifications the
    /// records asked for (after the upsert, so a client that opens the
    /// notification finds the record). Adoption, the first view of an app
    /// terminal and its readiness call this directly.
    pub(crate) fn publish_pending_progress(&self) {
        self.publish_progress_change(true);
    }

    /// `publish_pending_progress` for the terminal publisher: the output
    /// reader took the alerts itself, in output order
    /// (`queue_pending_publications`).
    pub(crate) fn publish_pending_state(&self) {
        self.publish_progress_change(false);
    }

    fn publish_progress_change(&self, with_alerts: bool) {
        let Some(pty) = self.as_pty() else { return };
        // A command or prompt edge is durable. A new OSC 9;4 progress and a
        // moved last output are live facts: the open streams get them, the
        // registry and the journal do not.
        let (activity_edge, live_changed, records) = {
            let mut metadata = pty.terminal_metadata.lock().unwrap();
            let progress = metadata.take_progress_change().is_some();
            let edge = metadata.take_busy_change();
            let output = metadata.take_output_change();
            (edge, progress || output, metadata.program_status())
        };
        let (status, shown_changed, shown_state_changed, alerts, blocker) = {
            let mut records = records.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let shown_state = records.shown_published_state();
            let shown = records.take_shown_change(!self.is_dead());
            let shown_state_changed =
                shown.is_some_and(|shown| shown.map(|shown| shown.state) != shown_state);
            let alerts = if with_alerts { records.take_alerts() } else { Vec::new() };
            let blocker = records.take_blocker_change(!self.is_dead());
            (records.take_change(), shown, shown_state_changed, alerts, blocker)
        };
        // A publish after the terminal died (reconnect) can hide its
        // running records with no new report: send that shown change too.
        if !activity_edge && !live_changed && !status.any && shown_changed.is_none() {
            return;
        }
        let Some(mux) = pty.mux.upgrade() else { return };
        // A report that changes a record's state or kind, or the shown
        // state, is one commit. One that keeps them is live, and so is the
        // shown record's new progress number.
        let status_edge = status.edge || (status.any && shown_state_changed);
        // While a journal stream follows the rows of live facts (an agent
        // plugin's wake) or a journal hook is delivered them, a live fact
        // is a row too, as a durable edge is.
        let live = live_changed || status.any;
        if activity_edge || status_edge || (live && mux.terminal_progress_rows_followed()) {
            let mutation = if status.any { "terminal.program_status" } else { "terminal.progress" };
            if let Err(error) = mux.publish_terminal_progress(self, mutation) {
                eprintln!("cmux-tui: terminal {mutation} publication failed: {error}");
            }
        } else if live {
            mux.publish_terminal_live(self);
        }
        // After the terminal's upsert, so the roster's row follows it.
        if let Some(state) = blocker {
            mux.record_program_status_evidence(self, state);
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
        #[cfg(any(unix, windows))]
        let hosted = matches!(
            &*pty.runtime.lock().unwrap(),
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
