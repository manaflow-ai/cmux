//! Revision-ordered, persisted terminal titles.
//!
//! A program's OSC 0/2 title reaches resource clients as a `terminal` upsert
//! delta and is stored on the terminal's resource row, so it survives a
//! daemon restart or a host reattach whose VT replay carries no title.
//!
//! Agents rewrite the title for every spinner frame. Each publication is a
//! durable SQLite commit with a journal record, so publication is throttled
//! per terminal: the first report after a quiet interval publishes at once,
//! and later reports inside the interval collapse into one trailing
//! publication of the latest title when the interval ends.

use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};
use crate::workspace_registry::MAX_TERMINAL_TITLE_BYTES;

/// At most one title revision per terminal per interval. One second keeps a
/// continuously animating agent title to one durable commit per second per
/// terminal, while a human-visible title change still lands within a second.
pub(crate) const TERMINAL_TITLE_PUBLISH_INTERVAL: Duration = Duration::from_secs(1);

pub(crate) struct TerminalTitlePublisher {
    state: Mutex<TitlePublisherState>,
    changed: Condvar,
    mux: OnceLock<Weak<Mux>>,
}

struct TitlePublisherState {
    interval: Duration,
    /// Terminals with a report newer than their last publication, keyed by
    /// the runtime surface id that owns the report.
    pending: HashMap<SurfaceId, Weak<Surface>>,
    /// When each terminal last published. Entries older than the interval
    /// carry no throttle and are pruned.
    last_published: HashMap<SurfaceId, Instant>,
    worker_started: bool,
    shutdown: bool,
}

impl Default for TerminalTitlePublisher {
    fn default() -> Self {
        Self {
            state: Mutex::new(TitlePublisherState {
                interval: TERMINAL_TITLE_PUBLISH_INTERVAL,
                pending: HashMap::new(),
                last_published: HashMap::new(),
                worker_started: false,
                shutdown: false,
            }),
            changed: Condvar::new(),
            mux: OnceLock::new(),
        }
    }
}

impl TitlePublisherState {
    /// Remove and return every pending terminal whose throttle has expired,
    /// and the earliest instant a remaining one becomes due.
    fn take_due(&mut self, now: Instant) -> (Vec<Weak<Surface>>, Option<Instant>) {
        let interval = self.interval;
        self.last_published.retain(|_, at| now.saturating_duration_since(*at) < interval);
        let mut due = Vec::new();
        let mut next = None::<Instant>;
        let last_published = &mut self.last_published;
        self.pending.retain(|id, surface| match last_published.get(id) {
            Some(at) => {
                let deadline = *at + interval;
                next = Some(next.map_or(deadline, |next| next.min(deadline)));
                true
            }
            None => {
                last_published.insert(*id, now);
                due.push(surface.clone());
                false
            }
        });
        (due, next)
    }
}

impl TerminalTitlePublisher {
    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    fn schedule(self: &Arc<Self>, surface: &Arc<Surface>) {
        let mut state = self.state.lock().unwrap();
        if state.shutdown {
            return;
        }
        state.pending.insert(surface.id, Arc::downgrade(surface));
        if !state.worker_started {
            let Some(mux) = self.mux.get().cloned() else { return };
            let publisher = Arc::clone(self);
            match std::thread::Builder::new()
                .name("terminal-title-publisher".into())
                .spawn(move || publisher.run(mux))
            {
                Ok(_) => state.worker_started = true,
                Err(error) => eprintln!("cmux-tui: start terminal title publisher: {error}"),
            }
        }
        drop(state);
        self.changed.notify_all();
    }

    fn run(&self, mux: Weak<Mux>) {
        loop {
            let due = {
                let mut state = self.state.lock().unwrap();
                loop {
                    if state.shutdown {
                        return;
                    }
                    let (due, next) = state.take_due(Instant::now());
                    if !due.is_empty() {
                        break due;
                    }
                    state = match next {
                        Some(deadline) => {
                            let wait = deadline.saturating_duration_since(Instant::now());
                            self.changed.wait_timeout(state, wait).unwrap().0
                        }
                        None => self.changed.wait(state).unwrap(),
                    };
                }
            };
            let Some(mux) = mux.upgrade() else { return };
            for surface in due {
                let Some(surface) = surface.upgrade() else { continue };
                if mux.publish_terminal_title_logged(&surface) == TitlePublication::Deferred {
                    self.requeue(&surface);
                }
            }
        }
    }

    /// Retry a terminal that was not yet published (its runtime or durable
    /// host was still being registered) once its throttle interval ends. The
    /// retry stops when the surface is dropped, publication succeeds, or the
    /// terminal is stale or exited.
    fn requeue(&self, surface: &Arc<Surface>) {
        let mut state = self.state.lock().unwrap();
        if !state.shutdown {
            state.pending.entry(surface.id).or_insert_with(|| Arc::downgrade(surface));
        }
    }

    /// Stop the worker and hand back every report it had not yet published,
    /// so shutdown can publish trailing titles instead of dropping them.
    fn shutdown(&self) -> Vec<Weak<Surface>> {
        let mut state = self.state.lock().unwrap();
        state.shutdown = true;
        let pending = state.pending.drain().map(|(_, surface)| surface).collect();
        drop(state);
        self.changed.notify_all();
        pending
    }

    /// Publish every pending report now, ignoring the throttle.
    #[cfg(test)]
    fn take_all_pending(&self) -> Vec<Weak<Surface>> {
        let mut state = self.state.lock().unwrap();
        let now = Instant::now();
        let pending = state.pending.drain().collect::<Vec<_>>();
        pending
            .into_iter()
            .map(|(id, surface)| {
                state.last_published.insert(id, now);
                surface
            })
            .collect()
    }
}

impl Mux {
    /// Queue publication of a program's OSC title report. Called from the
    /// terminal reader after it records the report; the durable commit runs
    /// on the publisher thread, never in the parser stream.
    pub(crate) fn schedule_terminal_title_publication(&self, surface: &Arc<Surface>) {
        if surface.terminal_public_id().is_none() {
            return;
        }
        self.terminal_titles.schedule(surface);
    }

    pub(super) fn stop_terminal_title_publisher(&self) {
        for surface in self.terminal_titles.shutdown() {
            if let Some(surface) = surface.upgrade() {
                let _ = self.publish_terminal_title_logged(&surface);
            }
        }
    }

    fn publish_terminal_title_logged(&self, surface: &Surface) -> TitlePublication {
        self.publish_terminal_title(surface).unwrap_or_else(|error| {
            eprintln!("cmux-tui: terminal title publication failed: {error:#}");
            TitlePublication::Settled
        })
    }

    /// Commit the latest reported title of `source` under the same registry
    /// -> state fence as cwd publication. A late report from a replaced
    /// runtime cannot overwrite its successor.
    pub(crate) fn publish_terminal_title(
        &self,
        source: &Surface,
    ) -> anyhow::Result<TitlePublication> {
        use TitlePublication::{Deferred, Settled};
        let Some(id) = source.terminal_public_id() else { return Ok(Settled) };
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        // The first output can precede runtime registration.
        let Some(current) = state.terminal_catalog.get(id).cloned() else { return Ok(Deferred) };
        if current.terminal_runtime_id() != source.terminal_runtime_id() {
            return Ok(Settled);
        }
        let Some(mut title) = current.unpublished_reported_title() else { return Ok(Settled) };
        truncate_title(&mut title);
        let Some(host_id) = registry.live_terminal_host_id(id)? else { return Ok(Deferred) };
        let Some(durable) = registry.terminal_record(&host_id)? else { return Ok(Deferred) };
        match durable.lifecycle {
            TerminalLifecycle::Running => {}
            TerminalLifecycle::Launching | TerminalLifecycle::Adopting => return Ok(Deferred),
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned => return Ok(Settled),
        }
        // A restarted daemon whose program reports the title it already
        // published must not spend a resource revision on it.
        if registry.terminal_title(id)?.as_deref() == Some(title.as_str()) {
            current.commit_published_title(title);
            return Ok(Settled);
        }
        let topology = registry.resource_topology_snapshot()?;
        let content_id = ContentPublicId::Terminal(id.clone());
        let tabs =
            terminal_tab_ids_in_canonical_order(
                topology.tabs.iter().filter(|tab| tab.content_id == content_id).map(|tab| {
                    (id.clone(), tab.pane_id.clone(), tab.position, tab.public_id.clone())
                }),
            )
            .remove(id)
            .unwrap_or_default();
        let mut value = public_terminal_snapshot(id, &durable, Some(&current), tabs, Some(&title))?;
        // The delta carries exactly the committed title, even if the program
        // reported again between reading it and building the value.
        value["title"] = serde_json::json!(title);
        let deltas = serde_json::json!([{
            "kind": "upsert", "sequence": 0, "resource": "terminal", "id": id, "value": value,
        }]);
        let mutation = WorkspaceMutation::local("terminal.title");
        let commit = registry.commit_resource_patch(
            &mutation,
            "terminal.title",
            &value,
            None,
            None,
            &ResourcePatch {
                changes: vec![ResourceChange::SetTerminalTitle {
                    public_id: id.clone(),
                    title: title.clone(),
                }],
            },
            &value,
            &deltas,
        )?;
        current.commit_published_title(title);
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        self.publish_resource_event();
        Ok(Settled)
    }

    /// Publish every pending title report now, bypassing the throttle.
    #[cfg(test)]
    pub(crate) fn flush_terminal_titles_for_test(&self) {
        for surface in self.terminal_titles.take_all_pending() {
            if let Some(surface) = surface.upgrade() {
                let _ = self.publish_terminal_title_logged(&surface);
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_title_interval_for_test(&self, interval: Duration) {
        self.terminal_titles.state.lock().unwrap().interval = interval;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TitlePublication {
    /// Published, already current, or no longer publishable.
    Settled,
    /// The terminal is not registered or running yet; retry later.
    Deferred,
}

fn truncate_title(title: &mut String) {
    if title.len() <= MAX_TERMINAL_TITLE_BYTES {
        return;
    }
    let mut end = MAX_TERMINAL_TITLE_BYTES;
    while !title.is_char_boundary(end) {
        end -= 1;
    }
    title.truncate(end);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn throttle_publishes_leading_edge_then_one_trailing_edge() {
        let mut state = TerminalTitlePublisher::default().state.into_inner().unwrap();
        state.interval = Duration::from_secs(1);
        let id: SurfaceId = 7;
        let start = Instant::now();
        state.pending.insert(id, Weak::new());
        let (due, next) = state.take_due(start);
        assert_eq!(due.len(), 1, "a report after a quiet interval publishes at once");
        assert!(next.is_none());
        state.pending.insert(id, Weak::new());
        state.pending.insert(id, Weak::new());
        let (due, next) = state.take_due(start + Duration::from_millis(400));
        assert!(due.is_empty(), "reports inside the interval wait");
        assert_eq!(next, Some(start + Duration::from_secs(1)));
        let (due, _) = state.take_due(start + Duration::from_secs(1));
        assert_eq!(due.len(), 1, "a burst collapses into one trailing publication");
        assert!(state.pending.is_empty());
    }
}
