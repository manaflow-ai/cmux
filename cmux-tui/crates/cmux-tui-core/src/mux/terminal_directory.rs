use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};
use cmux_threads::work::{Lane, Priority};

impl Mux {
    /// Commit terminal cwd under the same registry -> state fence as topology.
    /// A late reader from a replaced runtime cannot update its successor.
    #[track_caller]
    pub(crate) fn publish_terminal_directory(
        &self,
        source: &Surface,
        observed: &Option<String>,
        directory: Option<String>,
    ) -> anyhow::Result<bool> {
        let Some(id) = source.terminal_public_id() else { return Ok(true) };
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        let Some(current) = state.terminal_catalog.get(id).cloned() else { return Ok(false) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(true);
        }
        // A snapshot flush may race the reader. Only the latest serialized OSC state wins.
        if current.pwd() != *observed {
            return Ok(false);
        }
        if current.directory_publication_matches(&directory) {
            return Ok(true);
        }
        // A terminal that has never reported has nothing to publish: the
        // snapshot already presents its launch directory, and confirming an
        // absent report would only spend a resource revision, which replayed
        // creations and restarts must not do.
        if directory.is_none() && !source.directory_was_reported() {
            current.commit_published_directory(None);
            return Ok(true);
        }
        // A shell can report its first directory before the terminal's
        // resource row commits or its launch settles. Keep the report pending
        // until then; the reader, the public snapshot, and every topology
        // commit retry it. Only an ended terminal settles without publishing.
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(false) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(false) };
        match durable.lifecycle {
            TerminalLifecycle::Running => {}
            TerminalLifecycle::Launching | TerminalLifecycle::Adopting => return Ok(false),
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned => return Ok(true),
        }
        // Only this terminal's tab rows: a full topology read here made each
        // cwd report O(session) under the registry lock.
        let tabs = terminal_tab_ids_in_canonical_order(
            registry
                .resource_tabs_of_content(id.as_str())?
                .into_iter()
                .map(|tab| (id.clone(), tab.pane_id, tab.position, tab.public_id)),
        )
        .remove(id)
        .unwrap_or_default();
        let mut value = public_terminal_snapshot(id, &durable, Some(&current), tabs)?;
        let fields = value.as_object_mut().context("terminal snapshot is not an object")?;
        if let Some(directory) = &directory {
            fields.insert("cwd".into(), serde_json::json!(directory));
        } else {
            // An explicit clear: the shell reported a directory before and now
            // reports none.
            fields.remove("cwd");
        }
        let deltas = serde_json::json!([{
            "kind": "upsert", "sequence": 0, "resource": "terminal", "id": id, "value": value,
        }]);
        let mutation = WorkspaceMutation::daemon_local("terminal.cwd");
        let commit = registry.commit_resource_patch(
            &mutation,
            "terminal.cwd",
            &value,
            None,
            None,
            &ResourcePatch { changes: Vec::new() },
            &value,
            &deltas,
        )?;
        if let Err(error) = registry.record_terminal_relaunch_cwd(&host_id, directory.as_deref()) {
            eprintln!("cmux-tui: terminal {id} relaunch cwd failed: {error:#}");
        }
        current.commit_published_directory(directory);
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        // Notify directly: publish_resource_event would retry pending
        // directories, including this one, from inside its own publication.
        self.publish_journal_event();
        self.emit_terminal_tabs_changed(id);
        Ok(true)
    }

    /// Queues the cwd and progress publications of terminal runtime
    /// `surface` on the Files lane, in `sequence`
    /// ([`Surface::post_pending_publications`]): an output thread may not
    /// commit to the registry itself. The item finds the runtime when it
    /// runs; one gone by then has nothing left to publish. `posted` is the
    /// terminal's dirty flag, set by the caller: the pass clears it before
    /// it reads, and a pass that never runs (shutdown refused or dropped
    /// it) clears it as it drops, so the flag never stays set with no pass
    /// queued.
    pub(crate) fn post_terminal_publications(
        &self,
        surface: SurfaceId,
        sequence: &Arc<mux_work::Sequence>,
        posted: &Arc<std::sync::atomic::AtomicBool>,
    ) {
        let pass = PublicationPass { posted: posted.clone(), ran: false };
        let _ = self.post_mux_work_sequenced(
            sequence,
            Priority::UserVisible,
            Lane::Files,
            move |mux| {
                // The whole pass moves in, so it drops with the item.
                let mut pass = pass;
                let Some(mux) = mux.upgrade() else { return };
                if let Some(runtime) = mux.surface(surface) {
                    // The pass clears the flag itself, before it reads.
                    pass.ran = true;
                    runtime.publish_posted_publications();
                }
            },
        );
    }

    /// Posts the desktop notifications terminal runtime `surface`'s output
    /// asked for (OSC 9, 777, 99) on the Files lane, in the terminal's
    /// publication `sequence`, so they keep their order with its cwd and
    /// progress publications. A post records the notification in the
    /// registry and reads the terminal's foreground process, which its
    /// output thread may not do. A refused item (shutdown) posts nothing.
    pub(crate) fn post_terminal_notifications_off_output(
        &self,
        surface: SurfaceId,
        sequence: &Arc<mux_work::Sequence>,
        notifications: Vec<crate::terminal_metadata::TerminalNotification>,
    ) {
        let _ = self.post_mux_work_sequenced(
            sequence,
            Priority::UserVisible,
            Lane::Files,
            move |mux| {
                if let Some(mux) = mux.upgrade() {
                    mux.post_terminal_notifications(surface, notifications);
                }
            },
        );
    }

    /// Queues the end of a local terminal's reader (`surface::local_reader`)
    /// on the Files lane, in the terminal's publication `sequence`: after
    /// every publication its output queued, and on a thread that may block
    /// (the exit is a registry commit, `Mux::surface_exited`). A refused or
    /// dropped item drops `end`, which releases what the reader held and
    /// publishes nothing (shutdown, the owner gone).
    pub(crate) fn post_terminal_end(
        &self,
        sequence: &Arc<mux_work::Sequence>,
        end: impl FnOnce() + Send + 'static,
    ) {
        let _ =
            self.post_mux_work_sequenced(sequence, Priority::UserVisible, Lane::Files, move |_| {
                end()
            });
    }

    /// Close the startup race where the first prompt preceded runtime registration.
    pub(crate) fn publish_pending_terminal_directories(&self) {
        let terminals = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_catalog
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for surface in terminals {
            surface.publish_pending_directory();
        }
    }
}

/// One queued publication pass of a terminal. A pass that runs clears the
/// terminal's dirty flag itself, before it reads the state; one that never
/// runs (shutdown refused or dropped it, its mux or runtime is gone)
/// clears it as it drops, so the flag is never left set with no pass
/// queued and a later change always queues a new one.
struct PublicationPass {
    posted: Arc<std::sync::atomic::AtomicBool>,
    ran: bool,
}

impl Drop for PublicationPass {
    fn drop(&mut self) {
        if !self.ran {
            self.posted.store(false, std::sync::atomic::Ordering::Release);
        }
    }
}
