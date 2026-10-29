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

    /// Since when the terminal's own shell sits idle at its prompt (its
    /// prompt's time): `extra.shell_idle` (`terminal-activity-v1`, see
    /// `terminal_activity`). Memory only: the foreground check behind it
    /// ran on the terminal's publication ([`Self::check_shell_foreground`]).
    pub(crate) fn terminal_shell_idle_since(&self) -> Option<u64> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .idle_since()
    }

    /// Runs the foreground check a prompt mark asked for, or checks a
    /// published idle fact again (`ShellActivity::foreground_check_epoch`):
    /// whether the terminal's own process holds the PTY's foreground and
    /// still runs the program the daemon spawned. It reads the process
    /// table, so it runs here, in the publication (the work lane or the
    /// terminal work pool), outside the metadata lock, never in the output
    /// thread's parse; a local reader runs the publication itself only when
    /// that pool is full, as it does the registry commit beside it. A mark or
    /// input that came meanwhile drops its answer.
    fn check_shell_foreground(&self, pty: &PtySurface) {
        let due = pty.terminal_metadata.lock().recover_poison().activity.foreground_check_epoch();
        let Some(epoch) = due else { return };
        let holds = !self.is_dead() && own_program_holds_foreground(pty.pid, &pty.command);
        let leader = foreground_leader(pty.pid);
        pty.terminal_metadata
            .lock()
            .recover_poison()
            .activity
            .record_foreground_leader(epoch, holds, leader);
    }

    /// The daemon's last foreground check behind `shell_idle`: `extra.foreground_check`.
    pub(crate) fn terminal_foreground_check(&self) -> Option<(bool, Option<u32>)> {
        self.as_pty()?
            .terminal_metadata
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .activity
            .foreground_check()
    }

    /// Notes that input may reach this terminal's PTY without the daemon
    /// seeing it (`ShellActivity::note_unseen_input`): a renderer grant, or
    /// a terminal host adopted from another daemon. Its shell never reads
    /// idle again. Publishes the change when idle was published.
    pub(crate) fn note_unseen_shell_input(&self) {
        let Some(pty) = self.as_pty() else { return };
        let publish = pty.terminal_metadata.lock().recover_poison().activity.note_unseen_input();
        if publish {
            self.post_pending_publications();
        }
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
        // Its two callers ran the foreground check first (`check_pending_shell_foreground`).
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
    /// blocking disallowed) may not make (MQ-13, p02-threads-303): in the
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
        // The foreground check first: the directory upsert below carries the
        // record too, and must not publish the previous check's idle fact.
        self.check_pending_shell_foreground();
        self.publish_pending_directory();
        self.publish_pending_progress();
    }

    /// Runs the foreground check a publication owes ([`Self::check_shell_foreground`]) before any part of it
    /// publishes the terminal record.
    pub(crate) fn check_pending_shell_foreground(&self) {
        if let Some(pty) = self.as_pty() {
            self.check_shell_foreground(pty);
        }
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

/// The PTY's foreground group leader of the terminal's child `pid`; `None`
/// when unknown (and on Windows).
fn foreground_leader(pid: Option<u32>) -> Option<u32> {
    #[cfg(unix)]
    {
        platform::foreground_leader(pid?)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        None
    }
}

/// Whether the terminal's PTY child `pid` (or the shell login(1) started for
/// it) holds the PTY's foreground and still runs `command`'s program, the one
/// the daemon spawned, and that program is an interactive shell: not a job it
/// started (ssh, a nested shell), not a program `exec`ed in its place, and not
/// a terminal that runs ssh itself. The shell must also have no child process:
/// with job control off (`set +m`) its jobs run in its own process group, so its
/// group leading the foreground proves nothing (a nested shell over ssh printing
/// its own prompt), and with job control on a background or stopped job (`make
/// &`, vim after Ctrl-Z) dies with the terminal. A shell whose prompt keeps a
/// helper running (an async prompt worker) therefore never reads idle: a close
/// asks. The children are the same one-pid listing `terminal.process.get`
/// reports for a terminal's own process, never a process scan.
/// False when unknown: no pid, a failed lookup (a child list that cannot be
/// read included), and Windows, where a console has no foreground process group.
fn own_program_holds_foreground(pid: Option<u32>, command: &[String]) -> bool {
    #[cfg(unix)]
    {
        let (Some(pid), Some(spawned)) = (pid, command.first()) else { return false };
        if !crate::terminal_activity::spawned_shell(command) {
            return false;
        }
        let Some((shell, running)) = platform::foreground_own_shell(pid) else { return false };
        crate::terminal_activity::same_program(&running, spawned)
            && crate::resource_router::direct_children(shell)
                .is_some_and(|children| children.is_empty())
    }
    #[cfg(not(unix))]
    {
        let _ = (pid, command);
        false
    }
}
