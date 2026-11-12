//! Part of `Hub`; see `hub/mod.rs`. A chat's background work (Claude Code's background subagents
//! and background shells, `Hub::runs_background_work`) lives inside its agent's process: whatever
//! ends that process, or makes Claude Code stop every task, ends all of it. Leo, 2026-11-12, after
//! a coordinator's helpers died on a Stop and on a restart: "ON TOP OF THE FACT EVERYTHING FUCKING
//! STOPPED WHEN I STOPPED YOU I THOUGHT WE ALREADY FIXED THAT TERRIBLE BEHAVIOUR".
//!
//! The 2026-10-31 fix (#29879) made Stop spare background work two ways: Claude Code is started
//! with `perTaskStopAffordance` (`claude_stdio/outbound.rs` `initialize_request`), so its
//! interrupt stops only the turn, and the Stop escalation never ends a process that runs
//! background work (`cancel.rs`). Both held only for processes started after it. An agent host
//! outlives the daemon (durable sessions): each daemon update adopts the running host and the
//! Claude Code process under it, which keeps the `initialize` it was started with. On cosmic-gray
//! the coordinator's host was a 2026-10-29 build, adopted by every daemon for twelve days; its
//! Claude Code had no `perTaskStopAffordance`, so the first Stop killed all of its background
//! subagents at once (`task_updated` `killed` for each, `status: stopped`, never resumable by
//! SendMessage), and the escalation then found no background work left and restarted it.
//!
//! What this module adds, for every way a process ends or stops its tasks:
//!
//! - Stop: adoption reads the `initialize` the adopted Claude Code was started with, from the log
//!   ([`initialize_spares_background`]). One without `perTaskStopAffordance` marks its agent
//!   generation (`Session::stop_kills_background`). A Stop of such an agent while background work
//!   runs writes no interrupt at all, neither the first nor the escalation's second: it ends only
//!   acpmux's turn (`stop_escalated` `spared`, `interrupt: false`), and the agent is restarted on
//!   the current build once its background work ended (below), which starts it with the
//!   affordance. A new process (any start) has a new generation and is never marked.
//! - Restarts between turns (a route or model change, Update Everything, a stale or replaced host
//!   binary, a changed profile, an older host with no caller token, added folders): "between
//!   turns" only meant no acpmux turn ran, and a coordinator between turns runs its background
//!   helpers. Such a restart now waits while background work runs ([`Hub::defer_restart`]): the
//!   restart stays asked (`route_switch`), `restart_deferred` is logged once, and it runs when the
//!   last background subagent or shell ended and nothing else holds the chat
//!   ([`Hub::restart_after_background`], from the tap). Stopping the work stays its own act: a
//!   subagent's stop, a process's kill, or closing the chat.
//!
//! The person's own restart of a chat (`acpmux session restart`, the chat's close) and a
//! security restart (`policy_mode.rs`, `restart_on_route_now`) do not wait.

use super::*;

/// How many records after a host's `host_started` are read for its Claude Code `initialize`: the
/// host writes it first, before any prompt.
const INITIALIZE_WINDOW: usize = 64;

/// Whether the `claude.stdin` records after a host's start show its Claude Code was started with
/// `perTaskStopAffordance`. `Some(false)` for an `initialize` without it; `None` when none of
/// `records` is Claude Code's `initialize` (another harness, or a log that lost it): unknown is
/// not marked.
pub(super) fn initialize_spares_background<'a>(
    records: impl IntoIterator<Item = &'a crate::store::EventRecord>,
) -> Option<bool> {
    records.into_iter().find_map(|e| {
        let request = e.msg.get("request")?;
        (e.dir == "out"
            && e.kind == "claude.stdin"
            && request.get("subtype").and_then(Value::as_str) == Some("initialize"))
        .then(|| request.get("perTaskStopAffordance").and_then(Value::as_bool) == Some(true))
    })
}

impl Hub {
    /// After adopting host `incarnation`: marks `child` when its Claude Code was started without
    /// `perTaskStopAffordance` (module doc), and asks for its restart once background work ends.
    pub(super) fn note_adopted_stop_semantics(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &ChildAgent,
        incarnation: &str,
    ) {
        let mut start = None;
        let _ = self.store.scan_kinds(&session.id, &["host_started"], &mut |e| {
            if e.dir == "mux"
                && e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
            {
                start = Some(e.seq);
            }
            true
        });
        let Some(start) = start else { return };
        let mut records = Vec::new();
        let _ = self.store.scan(&session.id, start, &mut |e| {
            records.push(e);
            records.len() < INITIALIZE_WINDOW
        });
        if initialize_spares_background(&records) != Some(false) {
            return;
        }
        tracing::warn!(session = %session.id, incarnation, "adopted Claude Code was started without perTaskStopAffordance: Stop spares its background work, and it restarts once that work ended");
        session.stop_kills_background.store(child.generation, Ordering::SeqCst);
        self.append(
            session,
            "mux",
            "stop_kills_background",
            json!({"incarnation": incarnation, "restart": "after_background_work"}),
        );
        session.route_switch.store(true, Ordering::SeqCst);
        self.restart_after_background(session);
    }

    /// Whether Claude Code's interrupt to `child` would kill the chat's background work now.
    pub(super) fn interrupt_kills_background(&self, session: &Session, child: &ChildAgent) -> bool {
        session.stop_kills_background.load(Ordering::SeqCst) == child.generation
            && self.runs_background_work(session)
    }

    /// A restart between turns, deferred while background work runs (module doc): true when it
    /// waits. The restart stays asked (`route_switch`) and runs from
    /// [`Hub::restart_after_background`].
    pub(super) fn defer_restart(&self, session: &Session) -> bool {
        if !self.runs_background_work(session) {
            return false;
        }
        session.route_switch.store(true, Ordering::SeqCst);
        if !session.restart_deferred.swap(true, Ordering::SeqCst) {
            tracing::info!(session = %session.id, "restart waits for background work to end");
            self.append(session, "mux", "restart_deferred", json!({"reason": "background_work"}));
        }
        true
    }

    /// A deferred restart runs once the chat is free: no background work, no turn of acpmux's or
    /// Claude Code's own, no open permission ask. Cheap to call on every change of those (the tap
    /// calls it when background work or a Claude Code turn ends).
    pub(super) fn restart_after_background(self: &Arc<Self>, session: &Arc<Session>) {
        let free = |hub: &Hub, session: &Session| {
            session.route_switch.load(Ordering::SeqCst)
                && session.turn().is_none()
                && !session.harness_turn.load(Ordering::SeqCst)
                && session.pending_permissions().is_empty()
                && !hub.runs_background_work(session)
        };
        if !session.restart_deferred.load(Ordering::SeqCst)
            && session.stop_kills_background.load(Ordering::SeqCst) == 0
        {
            return;
        }
        if !free(self, session) {
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let _turn = session.turn_lock.lock().await;
            if !free(&hub, &session) || hub.shutting_down() {
                return;
            }
            if let Err(e) = hub.restart_on_route_now(&session).await {
                tracing::warn!(session = %session.id, "deferred restart: {}", e.message);
            }
        });
    }
}
