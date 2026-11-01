//! Part of `Hub`; see `hub/mod.rs`. An idle session hibernates: its harness exits.
//!
//! Every new session used to keep its adapter alive until the daemon
//! stopped: after about 25 sessions, 36 adapters, 187 processes and 9.4 GB,
//! with switches slowing as they piled up. A session is idle when no turn
//! runs or waits, nothing is queued, no permission or question is pending, no
//! start holds its spawn lock, no background command or subagent runs, and
//! nothing was logged for `idle_child` (2 min, `IDLE_CHILD`;
//! `ACPMUX_IDLE_CHILD_SECS`). A client attached to it, the open chat on screen
//! included, does not keep it awake: the chat stays where it is and only the
//! agent goes. Its harness is then stopped through `detach_child`: the record
//! and the agent session id stay, so the next prompt resumes it
//! (`session/load`, `claude --resume`). It is stopped only while nothing but
//! its MCP servers runs under it (`idle_census.rs`): a stop ends its group and
//! what runs under it, the MCP servers included.
//!
//! A wake is the next start of a hibernated session's agent: a prompt, a
//! person typing into the chat (`_acpmux/typing`, `wake_for_typing`, so the
//! agent is up by the time they send), or any request that needs the agent.
//! Every hibernation and every wake is logged with its cause and duration.
//! A wake that fails fails its prompt like any start that fails (its
//! `turn_error`, which the chat shows with Retry).
//!
//! The same task ends a running turn whose model has said nothing for
//! `stalledTurnEndMs` (`stalled_turn.rs`), and an agent a mode write moved
//! into full access while MDM forces it off (`full_access_bound.rs`).
//!
//! One task per hub waits on the injected clock for the earliest deadline
//! and on a wake signal for a new child; it never polls, so idle costs no
//! CPU. Activity only moves deadlines later, so the task wakes at most once
//! per idle period per live child. It sleeps without a deadline when no
//! session has a live child, and ends with the hub (its weak reference) or
//! for good once shutdown starts (`stop_idle_reaper`).

use super::*;
use cmux_json::JsonSet as _;

/// One agent request on its way to its answer (`Session::agent_requests`): counted from when the
/// inbound loop reads it until its task ends.
pub(super) struct AgentRequest(Arc<Session>);

impl AgentRequest {
    pub(super) fn new(session: &Arc<Session>) -> Self {
        session.agent_requests.fetch_add(1, Ordering::SeqCst);
        Self(session.clone())
    }
}

impl Drop for AgentRequest {
    fn drop(&mut self) {
        self.0.agent_requests.fetch_sub(1, Ordering::SeqCst);
    }
}

impl Hub {
    /// The hub clock's time, as stored in `Session::last_active`.
    pub(super) fn clock_now(&self) -> u64 {
        self.clock.lock().unwrap().now().as_nanos() as u64
    }

    /// Something happened in `session`: its idle period starts again.
    pub(super) fn touch(&self, session: &Session) {
        session.last_active.store(self.clock_now(), Ordering::SeqCst);
    }

    /// Unused right now, read while the caller holds its `turn_lock`, `harness_use` and
    /// `spawn_lock` leases (so no prompt, mode change or start begins until the harness is gone).
    /// A turn or permission an adopted host's recovery rebuilt (`hosts.rs` `recover_work`) counts
    /// like a live one: it sets `session.turn` (and holds `turn_lock` until the answer), registers
    /// the permission as pending, and moves the status off ready.
    fn idle_eligible(&self, session: &Session) -> bool {
        !self.stopping.load(Ordering::SeqCst)
            && matches!(session.status(), SessionStatus::Ready | SessionStatus::Idle)
            && session.turn().is_none()
            && !session.harness_turn.load(Ordering::SeqCst)
            && session.asks_in_flight.load(Ordering::SeqCst) == 0
            && !self.secrets.waiting_in(&session.id)
            && session.queued() == 0
            && session.pending_permissions().is_empty()
            // A harness's own background process (a dev server, a watcher) ends with the
            // harness: never reap it for idleness. A task the daemon owns (`bg_tasks.rs`) is not
            // in this table and outlives the harness.
            && !self.any_process_running(session)
            // Nor a background subagent, which the harness's exit would end too.
            && session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() == 0
            // Nor one whose agent waits on a request of its own (a permission not shown yet).
            && session.agent_requests.load(Ordering::SeqCst) == 0
            // Nor one whose cut turn's automatic continuation waits or starts (`auto_resume.rs`).
            && !self.continuation_pending(session)
            // Nor one with a sub-session or background subagent at work (`work_below.rs`).
            && session.work_below_since.lock().map_or(true, |v| *v == 0)
            // A Claude chat with turns but none stored would wake as a fresh conversation with
            // its transcript restored into the prompt (`claude_resume_refusal`): kept awake.
            && !(session.meta().claude_unstored && session.meta().turn_count > 0)
    }

    /// What a host this daemon starts does once no daemon controls it (`agent_host::OrphanExit`;
    /// its servers come from `LaunchServers::orphan_exit`): it waits [`crate::agent_host::ORPHAN_IDLE`], or this daemon's
    /// own idle period when that is longer, and never ends while idle hibernation is off
    /// (`ACPMUX_IDLE_CHILD_SECS=0`): an agent this daemon would keep, its host keeps too.
    pub(super) fn orphan_exit(&self) -> Option<crate::agent_host::OrphanExit> {
        let idle = (*self.idle_child.lock().unwrap_or_else(|e| e.into_inner()))?;
        #[cfg_attr(not(debug_assertions), allow(unused_mut))]
        let mut wait = idle.max(crate::agent_host::ORPHAN_IDLE);
        // Debug builds only: `ACPMUX_TEST_HOST_ORPHAN_IDLE_MS` replaces the wait, so the
        // integration tests can drive a host's own end. Release builds have no seam.
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("ACPMUX_TEST_HOST_ORPHAN_IDLE_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            wait = std::time::Duration::from_millis(ms);
        }
        Some(crate::agent_host::OrphanExit {
            idle_ms: u64::try_from(wait.as_millis()).unwrap_or(u64::MAX),
            servers: Vec::new(),
            path: String::new(),
            cwd: std::path::PathBuf::new(),
        })
    }

    /// The daemon is stopping (`_acpmux/shutdown`, SIGTERM, then
    /// `shutdown_all`): the idle reaper never stops a harness again.
    pub fn stop_idle_reaper(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        self.peer_notices_stop.send_replace(true);
        // Reads of peer chats ahead of an open end too, before the last flush (`peer_snapshot/warm.rs`).
        self.peer_snapshots.stop_warming();
        self.idle_wake.notify_one();
    }

    /// A child was published: make sure the reaper runs and sees it.
    pub(super) fn wake_idle_reaper(self: &Arc<Self>) {
        if !self.idle_reaper.swap(true, Ordering::SeqCst) {
            let weak = Arc::downgrade(self);
            let wake = self.idle_wake.clone();
            tokio::spawn(async move { Self::idle_reaper_loop(weak, wake).await });
        }
        self.idle_wake.notify_one();
    }

    async fn idle_reaper_loop(weak: std::sync::Weak<Self>, wake: Arc<Notify>) {
        loop {
            let (next, clock) = {
                let Some(hub) = weak.upgrade() else { return };
                if hub.stopping.load(Ordering::SeqCst) {
                    return;
                }
                let clock = hub.clock.lock().unwrap().clone();
                // The same task ends stalled turns (`stalled_turn.rs`).
                let stalled = hub.config.read().await.stalled_turn_end();
                let stalled = stalled.and_then(|s| hub.next_stalled_deadline(s));
                let next = match (hub.next_idle_deadline(), stalled) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
                (next, clock)
            };
            match next {
                Some(at) => {
                    tokio::select! {
                        _ = clock.sleep_until(at) => {}
                        _ = wake.notified() => {}
                    }
                }
                None => wake.notified().await,
            }
            let Some(hub) = weak.upgrade() else { return };
            hub.end_every_managed_full_access(hub.full_access_managed_off()).await;
            if let Some(stalled) = hub.config.read().await.stalled_turn_end() {
                hub.settle_stalled_turns(stalled);
            }
            hub.stop_idle_children().await;
        }
    }

    /// When the first live child's idle period ends, on the hub clock.
    fn next_idle_deadline(&self) -> Option<std::time::Duration> {
        let idle = (*self.idle_child.lock().unwrap())?;
        self.sessions()
            .iter()
            .filter(|s| s.child.try_lock().map(|c| c.is_some()).unwrap_or(true))
            .map(|s| std::time::Duration::from_nanos(s.last_active.load(Ordering::Relaxed)) + idle)
            .min()
    }

    async fn stop_idle_children(&self) {
        // Shutdown owns every child from its first step: hosted ones are
        // handed off or ended there, never terminated here meanwhile.
        let _pass = self.idle_pass.lock().await;
        if self.stopping.load(Ordering::SeqCst) {
            return;
        }
        let Some(idle) = *self.idle_child.lock().unwrap() else { return };
        let now = self.clock_now();
        let idle = idle.as_nanos() as u64;
        for session in self.sessions() {
            if session.last_active.load(Ordering::Relaxed).saturating_add(idle) > now {
                continue;
            }
            let has_child = session.child.try_lock().map(|c| c.is_some()).unwrap_or(true);
            if !has_child {
                continue;
            }
            // In use at its deadline: a full idle period starts now.
            let busy = session.turn_lock.try_lock().is_err()
                || session.spawn_lock.try_lock().is_err()
                || session.harness_use.try_write().is_err();
            if busy || !self.idle_eligible(&session) {
                self.touch(&session);
                continue;
            }
            // Its MCP servers, read before the leases: the configs are files (`idle_census.rs`).
            let Some(child) = session.child.lock().await.clone() else { continue };
            let sidecars = self.sidecars(&child).await;
            // Held until the harness is ended: no turn, start, mode change, fork or stop
            // begins meanwhile, and one that already began keeps the harness up.
            let turn = session.turn_lock.try_lock();
            let using = session.harness_use.try_write();
            let spawning = session.spawn_lock.try_lock();
            let same = session.child.lock().await.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child));
            if turn.is_err()
                || using.is_err()
                || spawning.is_err()
                || !same
                || !self.idle_eligible(&session)
            {
                // In use at its deadline: a full idle period starts now.
                self.touch(&session);
                continue;
            }
            // Nothing it did not report may end with it (`idle_census.rs`).
            let census = self.idle_census(child.pid, sidecars).await;
            if !matches!(census, super::idle_census::Census::Clear) {
                self.note_refusal(&session, &census);
                self.touch(&session);
                continue;
            }
            // Anything that happened while the census ran moved the deadline.
            if session.last_active.load(Ordering::SeqCst).saturating_add(idle) > self.clock_now()
                || !self.idle_eligible(&session)
            {
                continue;
            }
            let idle_for = now.saturating_sub(session.last_active.load(Ordering::SeqCst));
            let began = std::time::Instant::now();
            // A hosted child whose link is closed cannot take a Terminate
            // frame: end its host with the nonce proof, as closing does.
            let link_lost = child.host_record().is_some() && !child.is_alive().await;
            // Marked before the harness ends: typing or a click while it ends wakes it again,
            // its start waiting for the spawn lock this pass holds. One that came between the
            // deadline read above and the mark either sees the mark (and wakes it) or moved
            // `last_active`, read again here after the mark (both SeqCst): then the session is in
            // use and stays up. What the agent sent and the reader already queued (a turn Claude
            // Code starts itself, its `system/init`) is handled first and counts: drained, then
            // every gate read again. An exit the drain handles is no hibernation's (the mark is
            // set after it).
            let seen = session.last_active.load(Ordering::SeqCst);
            Self::drain_inbound(&session).await;
            if session.last_active.load(Ordering::SeqCst) != seen
                || seen.saturating_add(idle) > self.clock_now()
                || !self.idle_eligible(&session)
            {
                self.touch(&session);
                continue;
            }
            session.hibernated_at.store(self.clock_now().max(1), Ordering::SeqCst);
            if session.last_active.load(Ordering::SeqCst) != seen {
                self.clear_hibernation(&session);
                continue;
            }
            self.detach_child(&session).await;
            if link_lost {
                self.end_unadopted_host(&session).await;
            }
            // Stopped meanwhile (`kill` clears the mark): its next start is no wake, and this
            // was no hibernation. The leases stay held through the stored mark, so no Stop (it
            // takes `harness_use`) and no wake (it takes `spawn_lock`) clears it in between.
            if session.status() == SessionStatus::Closed
                || session.hibernated_at.load(Ordering::SeqCst) == 0
            {
                self.clear_hibernation(&session);
                tracing::info!(session = %session.id, "stopped while the idle exit ended it: not hibernated");
                continue;
            }
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).hibernated_ms =
                crate::store::now_ms().max(1);
            self.save_meta(&session);
            drop((turn, using, spawning));
            tracing::info!(
                session = %session.id,
                cause = "idle",
                idle_secs = idle_for / 1_000_000_000,
                exit_ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX),
                "hibernated: no turn, nothing queued, no question pending, nothing but its MCP \
                 servers running under it; the harness and its MCP servers exited and the session \
                 wakes on its next prompt"
            );
        }
    }

    /// `session` is no longer hibernated (woken, stopped, or its hibernation given up): its
    /// mark, the cause a wake recorded, and the stored flag go.
    pub(super) fn clear_hibernation(&self, session: &Session) {
        session.hibernated_at.store(0, Ordering::SeqCst);
        session.wake_cause.lock().unwrap_or_else(|e| e.into_inner()).take();
        let was = std::mem::take(
            &mut session.meta.lock().unwrap_or_else(|e| e.into_inner()).hibernated_ms,
        );
        if was != 0 {
            self.save_meta(session);
        }
    }

    /// What asks for a hibernated session's agent: told to the wake's log (`wake_began`).
    /// Only the first cause counts until the wake is done.
    pub(super) fn wake_cause(&self, session: &Session, cause: &'static str) {
        if session.hibernated_at.load(Ordering::SeqCst) != 0 {
            session.wake_cause.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert(cause);
        }
    }

    /// Whether a start of `session`'s agent now is a wake from hibernation: its `resumed` record
    /// says so, and the transcript draws no row for it (`transcript.rs`).
    pub(super) fn waking(&self, session: &Session) -> bool {
        session.hibernated_at.load(Ordering::SeqCst) != 0
    }

    /// `record` (a `resumed` one) with `"wake": true` when the start is a wake (`waking`).
    pub(super) fn wake_marked(&self, session: &Session, mut record: Value) -> Value {
        if self.waking(session) {
            record.set("wake", json!(true));
        }
        record
    }

    /// A start of `session`'s agent begins (`ensure_child`): a wake when the idle exit hibernated
    /// it, timed from here.
    pub(super) fn wake_began(&self, session: &Session) -> Option<(std::time::Instant, u64)> {
        // Wall time (Unix ms) it hibernated at, kept across a restart; 0 when not stored yet.
        let at = session.meta().hibernated_ms;
        (session.hibernated_at.load(Ordering::SeqCst) != 0).then(|| (std::time::Instant::now(), at))
    }

    /// The start `wake_began` timed ended: logs the wake with its cause and duration. A failed
    /// one stays hibernated, so the next try is logged as a wake again.
    pub(super) fn wake_ended(
        &self,
        session: &Session,
        began: Option<(std::time::Instant, u64)>,
        failed: Option<&RpcError>,
    ) {
        // `at`: the mark when the wake began (a stop meanwhile clears the session's).
        let Some((began, at)) = began else { return };
        let took_ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
        let slept_secs = (at != 0).then(|| crate::store::now_ms().saturating_sub(at) / 1000);
        let cause = *session.wake_cause.lock().unwrap_or_else(|e| e.into_inner());
        let cause = cause.unwrap_or("request");
        match failed {
            None => {
                self.clear_hibernation(session);
                tracing::info!(session = %session.id, cause, took_ms, ?slept_secs, "woke");
            }
            Some(e) => {
                tracing::warn!(session = %session.id, cause, took_ms, ?slept_secs, "wake failed: {}", e.message)
            }
        }
    }

    /// A person typed into `session` (`_acpmux/typing` on, sent again every 5 s while typing goes
    /// on, cause `typing`) or opened it on screen (`_acpmux/attach` or `_acpmux/view` visible,
    /// cause `click`): its idle period starts again, and a hibernated session wakes now, so its
    /// agent is up by the time they send. Nothing for a session that was not hibernated, is
    /// closed, is watched (no agent until Take Over, `watch.rs`), or whose folder has no Trust
    /// answer (`warm.rs`). The wake runs on its own task under the stop count read here, so a
    /// Stop that comes first is never undone by it (`ensure_child`). A failure is logged and the
    /// prompt that follows starts the agent itself (and shows its error, with Retry, if that
    /// fails too).
    pub fn wake_for(self: &Arc<Self>, session: &Arc<Session>, web: bool, cause: &'static str) {
        // Use: a chat being typed into or opened does not hibernate meanwhile.
        self.touch(session);
        // The person asked for it: what a daemon start held in its protected folder goes on.
        self.release_protected_hold(session);
        let stops = session.stops.load(Ordering::SeqCst);
        if session.hibernated_at.load(Ordering::SeqCst) == 0
            || session.status() == SessionStatus::Closed
            || session.meta().watching.is_some()
            || self.stopping.load(Ordering::SeqCst)
        {
            return;
        }
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            if !hub.folder_trusted(&session, web).await
                || session.stops.load(Ordering::SeqCst) != stops
                || session.status() == SessionStatus::Closed
            {
                return;
            }
            hub.wake_cause(&session, cause);
            let _ = hub.child_for_since(&session, stops).await;
        });
    }

    /// What keeps this daemon in use with no client (`daemon/unused_exit.rs`), or None: its
    /// startup, store and chat-log load or adoption still running, a peer link, a listener another machine reaches it by
    /// (the mesh relay, WireGuard, the tailnet, a WebSocket listener off loopback), an
    /// undelivered message or a watch, a running agent or agent host (adopted or not), a turn or
    /// anything one waits on, a background task, or a move to another machine under way.
    pub(crate) async fn in_use(&self) -> Option<&'static str> {
        // Still loading: queued prompts and cut turns the last daemon left resume from the chat
        // logs, and adoption reattaches running agents.
        if !self.store_loaded()
            || !*self.startup_ready.borrow()
            || !*self.adoption_ready.borrow()
            || !*self.logs_ready.borrow()
        {
            return Some("its startup");
        }
        // A link this daemon keeps to a peer may carry work for that peer's agents (the GitHub
        // broker, a relay): it never passes through `serve_connection_from` here.
        if !self.connected_peers().is_empty() {
            return Some("a peer link");
        }
        if self.mesh.get().is_some() {
            return Some("the mesh relay");
        }
        if self.wireguard.is_some() {
            return Some("WireGuard");
        }
        #[cfg(all(unix, feature = "tailnet"))]
        if self.tailnet_controller.get().is_some_and(|c| c.node().is_some()) {
            return Some("the tailnet listener");
        }
        let listen = self.config.read().await.websocket.as_ref().map(|w| w.listen.clone());
        if listen.is_some_and(|l| !on_loopback(&l)) {
            return Some("a WebSocket listener off loopback");
        }
        if self.outbox.unsettled() > 0 {
            return Some("an undelivered message");
        }
        if !self.watches.is_empty() {
            return Some("a watch");
        }
        for session in self.sessions() {
            // A move to another machine not yet committed or aborted: its watch still settles
            // it, and the chat stays frozen here until it does (`transfer_watch.rs`).
            if session.moving().is_some() && session.meta().moved_to.is_none() {
                return Some("a move under way");
            }
            // A child being published or ended holds the lock: counted as running.
            if session.child.try_lock().map(|c| c.is_some()).unwrap_or(true) {
                return Some("a running agent");
            }
            if session.turn().is_some()
                || session.harness_turn.load(Ordering::SeqCst)
                || session.queued() > 0
                || !session.pending_permissions().is_empty()
                || session.asks_in_flight.load(Ordering::SeqCst) > 0
                || session.agent_requests.load(Ordering::SeqCst) > 0
                || self.continuation_pending(&session)
            {
                return Some("a turn");
            }
            if self.bg_running(&session) {
                return Some("a background task");
            }
        }
        // An agent host still running, adopted or not, would lose its daemon; records that
        // cannot be read may hide one.
        let live = tokio::task::spawn_blocking(Self::read_live_host_sessions).await.ok().flatten();
        if live.is_none_or(|live| !live.is_empty()) {
            return Some("an agent host");
        }
        None
    }
}

/// Whether a listen address (`127.0.0.1:47811`, `[::1]:0`, `localhost:8080`) is loopback only;
/// one that does not parse is not.
fn on_loopback(listen: &str) -> bool {
    listen.parse::<std::net::SocketAddr>().is_ok_and(|a| a.ip().is_loopback())
        || listen.strip_prefix("localhost:").is_some_and(|port| port.parse::<u16>().is_ok())
}

#[cfg(test)]
#[path = "idle_tests.rs"]
mod idle_tests;
