//! Part of `Hub`; see `hub/mod.rs`. Adopting agent hosts after a daemon
//! restart or upgrade (plans/cmux-next/durable-sessions.md 2.5): reattach,
//! resume the host's entries after the last one logged, wait until the
//! replayed entries are in the log, then rebuild the turn and permission
//! state that died with the previous daemon from that complete log.

use super::full_access_bound::FullAccessEnd;
use super::full_access_bound::OffLatch;
use super::person::ANSWERED_BY_SLOT;
use super::*;
use crate::agent::Attached;
use crate::agent_host::{self, Liveness};
use crate::store::RecordHead;
use cmux_json::JsonSet as _;
use futures_util::StreamExt;

/// How long adoption waits for the next replayed entry of one host to be
/// logged before it recovers from the log as it is.
const REPLAY_STALL: std::time::Duration = std::time::Duration::from_secs(10);
/// The most one host's replay may hold adoption (and daemon startup).
const REPLAY_CEILING: std::time::Duration = std::time::Duration::from_secs(120);

/// What the session log says about the work in flight under one host
/// incarnation when the previous controller stopped.
#[derive(Debug, Default)]
pub(super) struct OpenWork {
    /// `turn_started` without `turn_result`: (seq, turnId, promptId, prompt,
    /// client, control; a Web steer's `turn_control` raises it).
    turn: Option<(u64, String, String, String, String, Control)>,
    /// That turn's line on the summary (`turn_started` `promptLine`, `prompt_line.rs`); `None`
    /// for an older record.
    turn_line: Option<String>,
    /// That turn was carried on from the turn before (`turn_started` `carried`,
    /// `carried_turn.rs`): its prompt is the hub's own, and a steer is never it.
    turn_carried: bool,
    /// The person's own prompt started that turn (`turn_started` `persons`, `inbox.rs`).
    turn_persons: bool,
    /// The last turn ended naming the turn it carried into (`turn_result` `carriedTo`), which
    /// never logged its start: the restart came in between.
    carry_next: Option<(String, Value)>,
    /// A Web steer raised the turn the open one carried into, before the open one's end was
    /// logged (`turn_control` for another turn): that turn is a Web turn (`carried_turn.rs`).
    next_raised: bool,
    /// When that turn started and when its model last showed a sign of work
    /// (`tap.rs` `logged_from_the_model`; 0 for none), Unix ms: the
    /// recovered turn keeps its age and its stalled count (`stalled_turn.rs`).
    turn_at: u64,
    heard_at: u64,
    /// That turn's tool calls with no end logged (`stalled_turn.rs`).
    open_tools: std::collections::HashSet<String>,
    /// The `session/prompt` request id written to this host for that turn,
    /// and its answer when it is already logged.
    prompt_request: Option<Value>,
    prompt_response: Option<Value>,
    /// The steers written into that turn (`_meta.steer`), by request id with
    /// their logged answer. A Claude Code steer is answered `steered` at once
    /// and the turn runs on; a codex-acp turn answers only its last prompt,
    /// so a steer's answer can be the one that ends the turn
    /// (`steer_end.rs`). Never the turn's own prompt (`prompt_request`).
    steers: Vec<(Value, Option<Value>)>,
    /// Agent requests to this host with no logged answer: (id, method,
    /// params, hostSeq).
    requests: Vec<(Value, String, Option<Value>, Option<u64>)>,
    /// `permission_request` records by agent request id: (permissionId,
    /// request, logged decision when there is one).
    pub(super) permissions: HashMap<String, (String, Value, Option<Value>)>,
    /// Of those, the agent request ids whose logged decision an ancestor session gave
    /// (`answeredBy.session`, `subsession_answer.rs`).
    ancestor_answers: std::collections::HashSet<String>,
    /// Of those asked (`permissions`), the agent request ids the agent withdrew, before or after
    /// their logged decision: under MDM's off a withdrawn ancestor's answer is never asked again
    /// (review 130 of #23322).
    withdrawn_asks: std::collections::HashSet<String>,
    /// Agent request ids withdrawn before their permission request was
    /// recorded. These are scoped to the adopted host incarnation.
    pub(super) withdrawn: std::collections::HashSet<String>,
    /// Permission records whose durable withdrawal has not yet been settled
    /// with a `permission_decision` record.
    pub(super) cancelled_permissions: std::collections::HashSet<String>,
    /// The receipts of the fenced lines its host took (`QUEUED_METHOD`, protocol 3) that have
    /// no receipt logged (`WRITTEN_METHOD`): its harness may not have them yet.
    pub(super) unwritten: std::collections::BTreeSet<u64>,
    /// `unwritten` proves nothing (fail closed): the log could not be read to its end, it has
    /// no start of this incarnation, or one of those notes could not be read.
    pub(super) receipts_unproven: bool,
    /// Largest `hostSeq` logged under this incarnation. Every entry kind is
    /// logged in entry order before its ack, so this is the logged prefix.
    pub(super) last_host_seq: u64,
    /// The remote floor's marks (`remote_floor.rs`): the turn it cancelled,
    /// who started the last turn, and whether this harness process was given
    /// a lasting grant ("allow always").
    floor_cancelled: Option<String>,
    last_control: Option<Control>,
    harness_grant: bool,
    /// A remote chain's Claude Code session whose current host has no
    /// passed sandbox canary just before it started (`remote_sandbox.rs`).
    unsandboxed: bool,
    /// What that turn does, from its logged updates under this incarnation: its tool calls in
    /// flight, its latest tool and its plan step (`hub/activity.rs`).
    doing: super::activity::TurnActivity,
    /// Whether the adopted host's main Claude turn was compacting when the
    /// previous controller stopped. Recovered from its logged `compaction`
    /// updates so Stop keeps the prompt-first path after a restart.
    compacting: bool,
}

/// What the host records say (`Hub::read_host_records`).
pub(super) struct HostRecords {
    /// Sessions whose agent host may still run (a live or unproven record).
    pub(super) live: std::collections::HashSet<String>,
    /// Of those, the sessions whose record this build cannot read: what their host runs is not
    /// known (#23322, review 69).
    pub(super) unreadable: std::collections::HashSet<String>,
}

impl Hub {
    /// Sessions whose agent host is still running, by session id. Read at
    /// startup so their open turns are not marked lost.
    pub(super) fn live_host_sessions() -> std::collections::HashSet<String> {
        Self::read_live_host_sessions().unwrap_or_default()
    }

    /// `live_host_sessions`, or `None` when the host records cannot be read.
    pub(super) fn read_live_host_sessions() -> Option<std::collections::HashSet<String>> {
        Self::read_host_records().map(|records| records.live)
    }

    /// The host records as the full-access bound reads them, or `None` when they cannot be read.
    pub(super) fn read_host_records() -> Option<HostRecords> {
        let dir = agent_host::hosts_dir();
        let (good, bad) = agent_host::load_records(&dir).ok()?;
        let mut unreadable = std::collections::HashSet::new();
        let mut live: std::collections::HashSet<String> = good
            .into_iter()
            .filter(|(_, r)| {
                agent_host::liveness(&dir, &r.session_id, &r.start_nonce) != Liveness::Dead
            })
            .map(|(_, r)| r.session_id)
            .collect();
        for b in bad {
            // A dead host's unreadable record must not block the session.
            if let Some(nonce) = &b.start_nonce
                && agent_host::liveness(&dir, &b.session_id, nonce) == Liveness::Dead
            {
                let _ = std::fs::remove_file(&b.path);
                continue;
            }
            unreadable.insert(b.session_id.clone());
            live.insert(b.session_id);
        }
        Some(HostRecords { live, unreadable })
    }

    /// Adopt this session's running host again (its link was lost, or a
    /// first adoption failed). Returns the adopted child.
    pub(super) async fn readopt(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Option<Arc<ChildAgent>> {
        // A reader that stopped in this process: reconnect only. This process
        // still holds the open requests, prompts and turn; recovery would
        // handle them a second time.
        let current = session.child.lock().await.clone();
        // MDM's off, read once for this re-adoption with the count of offs, so one pushed
        // while it runs counts too (`OffLatch`, #23322 review 68).
        let off = self.off_latch();
        // The link closed. Either the harness exited and its host is
        // finishing (wait, bounded, for the host's lock to drop, then let the
        // caller start a fresh agent), or the link alone was lost while the
        // host lives on (another owner took it over and left): reconnect to
        // it like a broken link, so the session is never locked.
        if let Some(child) =
            current.as_ref().filter(|c| c.host_record().is_some() && !c.is_broken())
            && let Some(record) = child.host_record()
        {
            let dead = agent_host::wait_dead_async(
                agent_host::hosts_dir(),
                record.session_id.clone(),
                record.start_nonce.clone(),
                std::time::Duration::from_secs(2),
            )
            .await;
            if dead || child.has_exited() {
                return None;
            }
            match child.reattach().await {
                Ok(()) => {
                    self.append(session, "mux", "host_reattached", json!({"reason": "link_lost"}));
                    return self.judged_after_reattach(session, child, &off).await;
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, "agent host reattach after a lost link failed: {e:#}");
                    return None;
                }
            }
        }
        if let Some(child) = current.filter(|c| c.is_broken()) {
            match child.reattach().await {
                Ok(()) => {
                    return self.judged_after_reattach(session, &child, &off).await;
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, "agent host reattach failed: {e:#}")
                }
            }
            return Some(child);
        }
        let dir = agent_host::hosts_dir();
        let (good, _) = agent_host::load_records(&dir).ok()?;
        let (_, record) = good.into_iter().find(|(_, r)| r.session_id == session.id)?;
        if let Err(e) = self.adopt_one(session, record, &off).await {
            tracing::warn!(session = %session.id, "agent host re-adoption failed: {e:#}");
        }
        session.child.lock().await.clone().filter(|c| c.host_record().is_some())
    }

    /// Ctrl-B of a chat whose agent runs in a host this daemon adopted or reached again
    /// (`processes.rs`): what the host runs, whatever the config says now. A host that does not
    /// answer goes by `kind`, its profile's; with no profile the chat keeps what it had.
    pub(super) async fn note_host_kind(
        &self,
        session: &Session,
        child: &ChildAgent,
        kind: Option<crate::config::HarnessKind>,
    ) {
        let moves = match (child.runs_claude().await, kind) {
            (Some(claude), _) => claude,
            (None, Some(kind)) => super::processes::backgrounds_work(kind),
            (None, None) => return,
        };
        session.backgrounds_work.store(moves, Ordering::SeqCst);
    }

    /// A reattached `child` under MDM's off (#23322, review 63): what its host kept while the link
    /// was down is judged before the agent is handed out. The replay is waited for (bounded, as
    /// adoption waits) and the session judged again from the log; an agent that runs in full
    /// access, or whose replay did not complete, ends, and None is returned (the caller starts a
    /// fresh agent, or refuses when the host did not end). Without MDM's off (`off`, the caller's
    /// one read of it, with any off pushed since) it is handed out at once, and the next off judges
    /// its replay: an earlier read of its log no longer holds (`FloorState::left_host_read`), and
    /// until the replay is all in the log the agent counts as full access (review 1 of #26057).
    /// The replay runs to what the host numbered before it handled this daemon's `Resume`, not to
    /// its hello (`ChildAgent::learn_replay_end`, review 3); with MDM unset that is learned in the
    /// background, and nothing waits on it.
    async fn judged_after_reattach(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        off: &OffLatch,
    ) -> Option<Arc<ChildAgent>> {
        session.floor.left_host_read.store(false, Ordering::SeqCst);
        if !off.off() {
            let learning = child.clone();
            tokio::spawn(async move { learning.learn_replay_end(REPLAY_STALL).await });
            return Some(child.clone());
        }
        let replayed = match child.learn_replay_end(REPLAY_STALL).await {
            Some(end) => child.wait_replayed(end, REPLAY_STALL, REPLAY_CEILING).await,
            None => false,
        };
        session.floor.left_host_read.store(false, Ordering::SeqCst);
        let ended = if replayed {
            self.end_if_runs_full_access(session, true).await
        } else {
            self.end_managed_full_access(session).await
        };
        (ended == FullAccessEnd::NotInFullAccess).then(|| child.clone())
    }

    /// Whether a host for `session` may still run (a live or unproven record).
    pub(super) fn host_record_live(session_id: &str) -> bool {
        Self::live_host_sessions().contains(session_id)
    }

    /// Whether the host records prove that no host for `session` runs. Records that cannot be
    /// read prove nothing (review 66 of #23322).
    pub(super) fn host_record_gone(session_id: &str) -> bool {
        Self::read_live_host_sessions().is_some_and(|live| !live.contains(session_id))
    }

    /// Reattach every running agent host. Called once at daemon start,
    /// before agents may spawn; a prompt to a kept session may still adopt
    /// its host first (`readopt`).
    pub async fn adopt_agent_hosts(self: &Arc<Self>) {
        // MDM's off (start-mode.json, loaded with the hub), read once for this adoption with the
        // count of offs, so one pushed while it runs counts too (`OffLatch`, #23322 review 68).
        let off = self.off_latch();
        // Debug builds only: `ACPMUX_TEST_ADOPT_HOLD_MS` holds adoption here, after it read MDM's
        // off, so integration tests can push the off meanwhile. Bounded; release builds have no
        // seam.
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_ADOPT_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
        {
            tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
        }
        // Pooled sessions of a previous daemon were never taken: end them.
        self.sweep_pool_hosts().await;
        let dir = agent_host::hosts_dir();
        let (good, bad) = match agent_host::load_records(&dir) {
            Ok(records) => records,
            Err(e) => {
                tracing::warn!("agent hosts: {e:#}");
                // Any host may still hold a line the previous daemon handed it (fail closed).
                self.hold_unresolved(None).await;
                return;
            }
        };
        // Each host has its own spawn lock, replay and recovery. A slow host must not hold
        // every following chat behind its replay deadline. Keep at most eight in flight;
        // this pass ends once the records are drained and owns no detached adoption tasks.
        futures_util::stream::iter(good)
            .for_each_concurrent(8, |(_, record)| self.adopt_record(&dir, record, &off))
            .await;
        for unreadable in bad {
            // Nothing proves what it may still write: held until its host is proven gone.
            if !Self::host_record_gone(&unreadable.session_id) {
                self.hold_unresolved(Some(&unreadable.session_id)).await;
            }
            if let Some(session) = self.session_by_id(&unreadable.session_id) {
                // MDM forces full access off (#23322), or a cleared grant: a live host this build
                // cannot adopt ends too (`end_unadopted_host`: its nonce proves it).
                let ended = {
                    let _spawning = session.spawn_lock.lock().await;
                    self.ends_before_adoption(&session, off.off()).await
                };
                if ended && Self::host_record_gone(&session.id) {
                    continue;
                }
                self.mark_unadoptable(
                    &session,
                    json!({"recordVersion": unreadable.record_version, "reason": unreadable.reason}),
                );
            }
        }
    }

    async fn adopt_record(
        self: &Arc<Self>,
        dir: &std::path::Path,
        record: agent_host::HostRecord,
        off: &OffLatch,
    ) {
        if agent_host::liveness(dir, &record.session_id, &record.start_nonce) == Liveness::Dead {
            agent_host::remove_artifacts(dir, &record);
            return;
        }
        let Some(session) = self.session_by_id(&record.session_id) else {
            // A host for a session this daemon does not know (purged):
            // nothing can show it, so end it.
            let ended = end_host_blocking(
                dir.to_owned(),
                record.session_id.clone(),
                Some(record.start_nonce.clone()),
                Some(record.host_pid),
            )
            .await;
            if ended {
                agent_host::remove_artifacts(dir, &record);
            } else {
                self.hold_unresolved(Some(&record.session_id)).await;
            }
            return;
        };
        // This runs after the ready line, so a prompt can reach the host
        // first (`ensure_child` -> `readopt`, under the spawn lock). One
        // adoption per host: a second link would replace the first
        // child, and the requests open on it would be lost.
        let _spawning = session.spawn_lock.lock().await;
        if let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await
        {
            return;
        }
        // MDM forces full access off (start-mode.json, loaded with the hub), or the chat's grant
        // was cleared (`policy_source.rs`): its host is ended, never adopted (#23322). One whose
        // end failed is not adopted either (review 51), and may still write a line the previous
        // daemon handed it: held until it is proven gone (`hold_unresolved`).
        if self.ends_before_adoption(&session, off.off()).await {
            if !Self::host_record_gone(&session.id) {
                self.hold_unresolved(Some(&session.id)).await;
            }
            return;
        }
        if let Err(e) = self.adopt_one(&session, record, off).await {
            tracing::warn!(session = %session.id, "agent host adoption failed: {e:#}");
        }
    }

    /// End the host of a session that has no adopted child, when one runs
    /// (a host this build cannot adopt, or one whose link was lost).
    pub(super) async fn end_unadopted_host(&self, session: &Session) {
        // A lost home's hosts folder may be another daemon's now: its records name that daemon's
        // agents. This daemon's own hosts end with their folder (`agent_host`), so none is read.
        if crate::config::home_path_lost() {
            return;
        }
        let dir = agent_host::hosts_dir();
        let Ok((good, bad)) = agent_host::load_records(&dir) else { return };
        let record = good.iter().find(|(_, r)| r.session_id == session.id).map(|(_, r)| r.clone());
        let host = record
            .as_ref()
            .map(|r| (Some(r.start_nonce.clone()), Some(r.host_pid)))
            .or_else(|| {
                bad.iter()
                    .find(|b| b.session_id == session.id)
                    .map(|b| (b.start_nonce.clone(), b.host_pid))
            });
        let Some((nonce, host_pid)) = host else { return };
        if end_host_blocking(dir.clone(), session.id.clone(), nonce, host_pid).await {
            if let Some(record) = record {
                agent_host::remove_artifacts(&dir, &record);
            } else if let Some(b) = bad.iter().find(|b| b.session_id == session.id) {
                let _ = std::fs::remove_file(&b.path);
            }
            self.append(session, "mux", "host_ended", json!({}));
        } else {
            tracing::warn!(session = %session.id, "could not end its unadopted agent host");
        }
    }

    fn session_by_id(&self, id: &str) -> Option<Arc<Session>> {
        self.sessions.lock().unwrap().get(id).cloned()
    }

    pub(super) fn mark_unadoptable(&self, session: &Arc<Session>, detail: Value) {
        self.append(session, "mux", "host_unadoptable", detail);
        self.set_status(session, SessionStatus::Disconnected);
        self.save_meta(session);
    }

    /// Adopts `record`'s host for `session`; `off` is the caller's one read of MDM's off, with any
    /// off pushed since (`OffLatch`). The family gate is held from before the host is reached
    /// until its log is read and what it may still write is held again (`hold_unwritten`), so no
    /// off push returns in between. Whatever stops that short (the host can't be reached or
    /// spoken to, or a remote one's end fails) leaves one hold that only the host's end settles
    /// (`link::adopt_untold`): fail closed.
    async fn adopt_one(
        self: &Arc<Self>,
        session: &Arc<Session>,
        record: agent_host::HostRecord,
        off: &OffLatch,
    ) -> anyhow::Result<()> {
        let kept = record.clone();
        let mut hold = Some(self.family_hold().await);
        let adopted = self.adopt_held(session, record, off, &mut hold).await;
        if let Some(hold) = hold {
            Self::hold_fences(&session.id, hold, vec![agent_host::link::adopt_untold(&kept)]);
        }
        adopted
    }

    async fn adopt_held(
        self: &Arc<Self>,
        session: &Arc<Session>,
        record: agent_host::HostRecord,
        off: &OffLatch,
        hold: &mut Option<super::full_access_bound::FamilyHold>,
    ) -> anyhow::Result<()> {
        if session.meta().remote_origin
            && !self.remote_host_env_current(session, &record.incarnation)
        {
            let dir = agent_host::hosts_dir();
            let ended = end_host_blocking(
                dir.clone(),
                record.session_id.clone(),
                Some(record.start_nonce.clone()),
                Some(record.host_pid),
            )
            .await;
            if ended {
                agent_host::remove_artifacts(&dir, &record);
                // Ended: nothing it had can be written now.
                hold.take();
            }
            self.append(
                session,
                "mux",
                "host_ended",
                json!({"reason": "remote_env_policy_changed"}),
            );
            return Ok(());
        }
        let resume_after = self.last_host_seq(session, &record.incarnation);
        // The subagents the host still runs, before its first replayed line reaches the tap:
        // a child's line is tagged with its session from the first one (`work_below.rs`).
        self.seed_subagents_from_log(session);
        let tap = self.session_tap(session);
        let incarnation = record.incarnation.clone();
        let caller_token = record.caller_token.clone();
        let attached = ChildAgent::attach_hosted(
            &session.meta().harness,
            record,
            resume_after,
            Vec::new(),
            session.inbound_tx.clone(),
            tap,
        )
        .await?;
        let (child, adopted) = match attached {
            Attached::Ready(child, adopted, _) => (child, adopted),
            Attached::Incompatible { min, max, host_build } => {
                // Its replay is never read, so what it kept while no daemon was attached is
                // unknown: under MDM's off it counts as full access, now and at any later off
                // (`unjudged_host`), and ends by its nonce. A host whose end fails stays held and
                // is never reached (`FullAccessEnd::StillRunning`). With MDM unset it runs on,
                // unadoptable, as before (#26337).
                session.floor.unjudged_host.store(true, Ordering::SeqCst);
                let ended = off.off()
                    && self.end_managed_full_access(session).await == FullAccessEnd::Ended;
                if ended {
                    hold.take();
                    return Ok(());
                }
                self.mark_unadoptable(
                    session,
                    json!({"hostProtocol": [min, max], "hostBuild": host_build}),
                );
                return Ok(());
            }
        };
        // Its replay is not known to be in the log until its end is learned (below).
        child.mark_replay_unknown();
        let proven = self.adopt_caller_token(&session.id, caller_token);
        // A fork through an adopted agent asks for the list it started with
        // (`spawn.rs` decides it at session/new for a spawned one).
        let meta = session.meta();
        let (_, env) = self.harness_env(&meta).await;
        let (all, kind) = {
            let cfg = self.config.read().await;
            let profile = cfg.profile(&meta.harness);
            let all = profile.is_some_and(|p| {
                crate::agent_tools::lists_all_tools(&meta.harness, p, &env, &meta.cwd)
            });
            (all, profile.map(|p| p.kind))
        };
        child.all_tools.store(all, std::sync::atomic::Ordering::Relaxed);
        *session.child.lock().await = Some(child.clone());
        self.wake_idle_reaper();
        if let Some(rx) = session.inbound_rx.lock().await.take() {
            let hub = self.clone();
            let s = session.clone();
            tokio::spawn(async move { hub.inbound_loop(s, rx).await });
        }
        // Asked once the inbound loop drains the replay, which the answer comes behind.
        self.note_host_kind(session, &child, kind).await;
        // Scan only once every entry the host had is in the log: what the
        // previous daemon wrote or answered may still sit in its buffer.
        // Debug builds only: `ACPMUX_TEST_REPLAY_INCOMPLETE` makes every replay count as incomplete,
        // as a host that stalls mid-replay does. Release builds have no seam.
        #[cfg(debug_assertions)]
        let stalls = std::env::var_os("ACPMUX_TEST_REPLAY_INCOMPLETE").is_some();
        #[cfg(not(debug_assertions))]
        let stalls = false;
        let replayed =
            !stalls && child.wait_replayed(adopted.last_h, REPLAY_STALL, REPLAY_CEILING).await;
        if !replayed {
            tracing::warn!(session = %session.id, "agent host replay incomplete; recovering from the partial log");
        }
        // MDM forces full access off (#23322, review 60): what the host kept while no daemon was
        // attached is in the log now. A mode or option it moved to then is judged before the
        // agent is handed out (every caller holds the spawn lock, so `child_for` waits); a later
        // report reaches `write_mode_state` live.
        // A replay that did not complete may still hold such a report: under MDM's off the host
        // is not known to ask, so it ends (review 61).
        // An off pushed since adoption read the policy counts (review 68): that push may have
        // read the log before the replay reached it. With MDM unset the agent is handed out, and
        // the next off reads the log the replay added to: an earlier read of it no longer holds
        // (review 2 of #26057).
        // The replay runs to what the host numbered before it handled this daemon's `Resume`, which
        // may be past its hello's `last_h` (review 3 of #26057): under MDM's off that end is learned
        // and waited for before the judgement; with MDM unset it is learned in the background and
        // nothing waits on it, as before.
        session.floor.left_host_read.store(false, Ordering::SeqCst);
        if off.off() {
            let replayed = replayed
                && match child.learn_replay_end(REPLAY_STALL).await {
                    Some(end) => child.wait_replayed(end, REPLAY_STALL, REPLAY_CEILING).await,
                    None => false,
                };
            let ended = if replayed {
                self.end_if_runs_full_access(session, true).await
            } else {
                self.end_managed_full_access(session).await
            };
            if ended != FullAccessEnd::NotInFullAccess {
                // Ended: nothing it had can be written now. Still running: held until it ends.
                if ended == FullAccessEnd::Ended {
                    hold.take();
                }
                return Ok(());
            }
        } else {
            let learning = child.clone();
            tokio::spawn(async move { learning.learn_replay_end(REPLAY_STALL).await });
        }
        self.append(
            session,
            "mux",
            "host_adopted",
            json!({"incarnation": incarnation, "hostBuild": adopted.host_build, "resumedAfter": resume_after}),
        );
        let work = self.recovery_work(session, &incarnation, resume_after);
        // Handed on before recovery, which may take the family gate itself.
        if let (Some(record), Some(hold)) = (child.host_record(), hold.take()) {
            let told = replayed && adopted.version >= agent_host::QUEUED_VERSION;
            Self::hold_unwritten(session, hold, &record, told, &work);
        }
        let changes = session.status_changes.load(Ordering::SeqCst);
        self.recover_work(session, &child, &incarnation, work).await;
        // The status after recovery, not before it: set before, `ready` was logged and shown
        // between `host_adopted` and a turn the host still runs (an idle chat that was working).
        // Recovery sets the turn and `running` under the spawn lock every new prompt waits on, so
        // no prompt starts in between. When recovery wrote a status (a recovered turn, which may
        // also have ended by now; a permission asked again), it stands. Else the status loaded from
        // disk is replaced as a turn's end does (`turns.rs` `finish_turn`): `waiting` while
        // something still asks the person, `ready` otherwise, read under the permissions lock
        // that an answer takes.
        if session.status_changes.load(Ordering::SeqCst) == changes && session.turn().is_none() {
            let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let asking = !state.pending.is_empty() || self.secrets.waiting_in(&session.id);
            let status = if asking { SessionStatus::Waiting } else { SessionStatus::Ready };
            self.set_status(session, status);
            drop(state);
        }
        self.restart_unproven(session, proven);
        self.save_meta(session);
        Ok(())
    }

    fn recovery_work(&self, session: &Session, incarnation: &str, resume_after: u64) -> OpenWork {
        // A withdrawal either precedes this snapshot in the log or waits
        // on this lock until its recovered request has been admitted.
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let mut work = self.open_work(session, incarnation);
        // Requests after the resume point were replayed into the live
        // inbound loop and are handled there; only earlier ones were the
        // previous daemon's to answer.
        work.requests.retain(|(_, _, _, h)| h.is_none_or(|h| h <= resume_after));
        for (id, kind, _, _) in &work.requests {
            if kind == method::SESSION_REQUEST_PERMISSION {
                state
                    .active_requests
                    .insert(super::permission_groups::AgentRequestKey::new(Some(incarnation), id));
            }
        }
        work
    }

    fn remote_host_env_current(&self, session: &Session, incarnation: &str) -> bool {
        let mut current = false;
        let _ = self.store.scan_heads(&session.id, &mut |head| {
            if head.dir == "mux"
                && head.kind == "host_started"
                && let Some(event) = head.record()
                && event.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
            {
                current = event.msg.get("remoteEnvPolicy").and_then(Value::as_str)
                    == Some(crate::agent::REMOTE_ENV_POLICY_ID);
            }
            true
        });
        current
    }

    /// Largest `hostSeq` logged under host `incarnation`.
    fn last_host_seq(&self, session: &Session, incarnation: &str) -> u64 {
        // And the `seq` of the record that holds it.
        let (mut last, mut at) = (0, 0);
        let mut current = false;
        // Only starts and deferred withdrawals need their incarnation parsed.
        let _ = self.store.scan_heads(&session.id, &mut |head| {
            if head.dir == "mux" && head.kind == "host_started" {
                if let Some(e) = head.record() {
                    current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                    if current {
                        (last, at) = (0, 0);
                    }
                }
            } else if current
                && (head.kind != "permission_withdrawn"
                    || head.record().is_some_and(|e| host_seq_matches(&e, incarnation)))
                && let Some(h) = head.host_seq.filter(|&h| h > last)
            {
                (last, at) = (h, head.seq);
            }
            true
        });
        if last > 0 && !self.logs_host_seq(session, at, last) {
            return self.last_host_seq_parsed(session, incarnation);
        }
        last
    }

    /// `last_host_seq` from whole records only.
    fn last_host_seq_parsed(&self, session: &Session, incarnation: &str) -> u64 {
        let mut last = 0;
        let mut current = false;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            if e.dir == "mux" && e.kind == "host_started" {
                current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                if current {
                    last = 0;
                }
            } else if current
                && host_seq_matches(&e, incarnation)
                && let Some(h) = e.host_seq
            {
                last = last.max(h);
            }
            true
        });
        last
    }

    /// Whether record `seq` is whole and logs host entry `host_seq`. A head is read from the
    /// line's bytes; a line a crash cut short reads none of its own, or another record's
    /// `hostSeq`, which a whole-record read skips. Reads from `seq`'s segment, not the log.
    fn logs_host_seq(&self, session: &Session, seq: u64, host_seq: u64) -> bool {
        let mut whole = false;
        let _ = self.store.scan(&session.id, seq.saturating_sub(1), &mut |e: EventRecord| {
            whole = e.seq == seq && e.host_seq == Some(host_seq);
            false
        });
        whole
    }

    /// Scan the log for the work in flight under host `incarnation`. Agent
    /// requests, answers and permission records count only within this
    /// incarnation: every harness restarts its own request ids.
    pub(super) fn open_work(&self, session: &Session, incarnation: &str) -> OpenWork {
        self.open_work_reading(session, incarnation, open_work_reads)
    }

    /// `open_work`, parsing the records `reads` asks for (tests: every one).
    fn open_work_reading(
        &self,
        session: &Session,
        incarnation: &str,
        reads: fn(&RecordHead<'_>, bool, bool) -> bool,
    ) -> OpenWork {
        let mut work = OpenWork::default();
        let mut current = false;
        let mut requests: Vec<(Value, String, Option<Value>, Option<u64>)> = Vec::new();
        let mut answered: std::collections::HashSet<String> = Default::default();
        let mut asked: HashMap<String, (String, Value, Option<Value>)> = HashMap::new();
        let mut by_permission: HashMap<String, String> = HashMap::new();
        let mut open_request_ids: std::collections::HashSet<String> = Default::default();
        let mut ancestors = std::collections::HashSet::new();
        // permissionId -> the ids of its "allow always" options.
        let mut lasting: HashMap<String, Vec<String>> = HashMap::new();
        let always = |request: Option<&Value>| -> Vec<String> {
            request
                .and_then(|r| r.get("options"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|o| o.get("kind").and_then(Value::as_str) == Some("allow_always"))
                .filter_map(|o| o.get("optionId").and_then(Value::as_str).map(str::to_owned))
                .collect()
        };
        // The canary passes, then the host starts: that host is sandboxed.
        // Only the adopted incarnation's own start counts, with the canary of
        // the current profile right before it; missing: unsandboxed.
        let remote_claude = self.remote_claude(session);
        work.unsandboxed = remote_claude;
        let mut canary_passed = false;
        // Which logged updates are a subagent's, as the tap tells them live: by the subagents
        // the log itself started, never by an update's own `_meta`.
        // The chat's native roots, current and earlier, are never subagents (as the tap seeds them).
        let mut subagents = crate::subagents::SubagentTree::default();
        let meta = session.meta();
        subagents.set_own(meta.agent_session_id.as_deref());
        subagents.set_roots(
            meta.agent_session_id.iter().chain(&meta.retired_agent_session_ids).map(String::as_str),
        );
        // Only the log's last turn can be open when the scan ends: an earlier turn's records
        // (most of a long log) are folded away at its `turn_result`. Found from the end, on the
        // heads of the records after that turn's marker.
        let mut last_turn = 0;
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|dir, kind| dir != b"mux" || !matches!(kind, b"turn_started" | b"turn_result"),
            // A line whose head does not read reaches here unskipped.
            &mut |e| {
                if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "turn_result") {
                    last_turn = e.seq;
                    return false;
                }
                true
            },
        );
        // The `seq` of the record whose head alone gave `last_host_seq`, proven whole at the end.
        let mut host_seq_at: Option<u64> = None;
        let mut started = false;
        let scanned = self.store.scan_heads(&session.id, &mut |head| {
            // A record the fold would leave as it is counts by its head's `hostSeq` alone.
            let last_turn_open = work.turn.as_ref().is_some_and(|t| t.0 >= last_turn);
            if !reads(head, current, last_turn_open) {
                if current
                    && head.kind != "permission_withdrawn"
                    && let Some(h) = head.host_seq.filter(|&h| h > work.last_host_seq)
                {
                    work.last_host_seq = h;
                    host_seq_at = Some(head.seq);
                }
                return true;
            }
            let Some(mut e) = head.record() else {
                // A receipt note that can not be read proves nothing: fail closed.
                work.receipts_unproven |= current
                    && head.dir == "out"
                    && matches!(head.kind, agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD);
                return true;
            };
            let subagents_own = e.dir == "in"
                && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
                && e.msg.get_mut("params").is_some_and(|p| subagents.annotate(p).is_some());
            if e.dir == "mux" {
                let text = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
                match e.kind.as_str() {
                    "host_started" => {
                        lasting.clear();
                        work.harness_grant = false;
                        if text("incarnation").as_deref() == Some(incarnation) {
                            work.unsandboxed = remote_claude && !canary_passed;
                        }
                        canary_passed = false;
                    }
                    "remote_sandbox" => {
                        canary_passed = e.msg.get("canary").and_then(Value::as_str)
                            == Some("passed")
                            && text("profile").as_deref()
                                == Some(super::remote_sandbox::profile_id().as_str());
                    }
                    "permission_request" => {
                        if let Some(pid) = text("permissionId") {
                            lasting.insert(pid, always(e.msg.get("request")));
                        }
                    }
                    "permission_decision" => {
                        let chosen = e.msg.pointer("/outcome/optionId").and_then(Value::as_str);
                        if let (Some(pid), Some(o)) = (text("permissionId"), chosen)
                            && lasting.get(&pid).is_some_and(|ids| ids.iter().any(|i| i == o))
                        {
                            work.harness_grant = true;
                        }
                    }
                    "permission_auto" => {
                        if let Some(o) = text("optionId")
                            && always(e.msg.get("request")).contains(&o)
                        {
                            work.harness_grant = true;
                        }
                    }
                    "turn_started" => {
                        work.last_control = Some(Control::from_recorded(
                            e.msg.get("control").and_then(Value::as_str),
                        ));
                    }
                    "turn_control" => work.last_control = Some(Control::Web),
                    "remote_floor_cancel" => work.floor_cancelled = text("turnId"),
                    _ => {}
                }
            }
            match (e.dir.as_str(), e.kind.as_str()) {
                ("mux", "host_started") => {
                    current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                    started |= current;
                    // A new harness: its ids and answers start over.
                    requests.clear();
                    answered.clear();
                    asked.clear();
                    by_permission.clear();
                    work.withdrawn.clear();
                    work.withdrawn_asks.clear();
                    work.cancelled_permissions.clear();
                    work.unwritten.clear();
                    work.receipts_unproven = false;
                    open_request_ids.clear();
                    work.prompt_request = None;
                    work.prompt_response = None;
                    work.steers.clear();
                    // A new harness runs no carried turn of the old one's.
                    work.carry_next = None;
                    work.turn_carried = false;
                    // The open turn is still the person's own on a new harness (`turn_started`).
                    work.next_raised = false;
                    work.last_host_seq = 0;
                    host_seq_at = None;
                    work.doing = Default::default();
                }
                ("mux", "turn_started") => {
                    let field = |k: &str| {
                        e.msg.get(k).and_then(Value::as_str).unwrap_or_default().to_owned()
                    };
                    // A carried turn raised to Web before its start was logged keeps it.
                    let raised = work.carry_next.as_ref().is_some_and(|(_, next)| {
                        next.get("turnId") == e.msg.get("turnId")
                            && next.get("control").and_then(Value::as_str) == Some("web")
                    });
                    work.turn = Some((
                        e.seq,
                        field("turnId"),
                        field("promptId"),
                        field("prompt"),
                        field("client"),
                        if raised {
                            Control::Web
                        } else {
                            Control::from_recorded(e.msg.get("control").and_then(Value::as_str))
                        },
                    ));
                    work.turn_line =
                        e.msg.get("promptLine").and_then(Value::as_str).map(str::to_owned);
                    work.turn_at = e.at;
                    work.turn_carried = e.msg.get("carried").is_some_and(|c| !c.is_null());
                    work.turn_persons = e.msg.get("persons") == Some(&Value::Bool(true));
                    work.carry_next = None;
                    work.next_raised = false;
                    work.heard_at = 0;
                    work.open_tools.clear();
                    work.prompt_request = None;
                    work.prompt_response = None;
                    work.steers.clear();
                    work.doing = Default::default();
                }
                ("mux", "turn_control") => {
                    if let Some(t) = work.turn.as_mut() {
                        if e.msg.get("turnId").and_then(Value::as_str) == Some(t.1.as_str()) {
                            t.5 = Control::from_recorded(
                                e.msg.get("control").and_then(Value::as_str),
                            );
                        } else {
                            // The turn it carried into, put in place before its end was logged.
                            work.next_raised = true;
                        }
                    }
                    // A Web steer into a carried turn not started yet (`carried_turn.rs`).
                    if let Some((_, next)) = work.carry_next.as_mut()
                        && e.msg.get("turnId") == next.get("turnId")
                    {
                        next.set("control", json!(Control::Web.as_str()));
                    }
                }
                ("mux", "turn_result") => {
                    work.carry_next = e.msg.get("carriedTo").filter(|c| !c.is_null()).map(|c| {
                        let from = work.turn.as_ref().map(|t| t.1.clone());
                        let from = from.or_else(|| {
                            e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned)
                        });
                        (from.unwrap_or_default(), c.clone())
                    });
                    work.turn = None;
                    work.turn_line = None;
                    work.turn_carried = false;
                    work.turn_persons = false;
                    work.next_raised = false;
                    work.compacting = false;
                    // No turn, no turn state: an ended turn's records are not read
                    // (`open_work_reads`), so none of them may outlive it here.
                    work.heard_at = 0;
                    work.open_tools.clear();
                    work.prompt_request = None;
                    work.prompt_response = None;
                    work.steers.clear();
                    work.doing = Default::default();
                }
                // A subagent's updates are not the turn's own (`permissions.rs` `on_update`).
                ("in", "tool_call" | "tool_call_update" | "plan")
                    if current && work.turn.is_some() && !subagents_own =>
                {
                    work.doing.note(&e.msg["params"]["update"]);
                }
                ("in", "compaction") if current && work.turn.is_some() && !subagents_own => {
                    match e.msg.pointer("/params/update/state").and_then(Value::as_str) {
                        Some("running") => work.compacting = true,
                        Some("completed") | Some("failed") => work.compacting = false,
                        _ => {}
                    }
                }
                ("mux", "permission_request") if current => {
                    if let (Some(pid), Some(aid)) = (
                        e.msg.get("permissionId").and_then(Value::as_str),
                        e.msg.get("agentRequestId").filter(|v| !v.is_null()),
                    ) {
                        let request = e.msg.get("request").cloned().unwrap_or(Value::Null);
                        let key = aid.to_string();
                        let decided = work.withdrawn.remove(&key).then(|| {
                            work.withdrawn_asks.insert(key.clone());
                            work.cancelled_permissions.insert(key.clone());
                            json!({"outcome": "cancelled"})
                        });
                        asked.insert(aid.to_string(), (pid.to_owned(), request, decided));
                        by_permission.insert(pid.to_owned(), aid.to_string());
                    }
                }
                ("mux", "permission_withdrawn")
                    if current
                        && e.msg.get("incarnation").and_then(Value::as_str)
                            == Some(incarnation) =>
                {
                    if let Some(aid) = e.msg.get("agentRequestId")
                        && open_request_ids.contains(&aid.to_string())
                    {
                        if let Some(entry) = asked.get_mut(&aid.to_string()) {
                            work.withdrawn_asks.insert(aid.to_string());
                            // A decision already logged won the race before
                            // the withdrawal reached the hub.
                            if entry.2.is_none() {
                                entry.2 = Some(json!({"outcome": "cancelled"}));
                                work.cancelled_permissions.insert(aid.to_string());
                            }
                        } else {
                            work.withdrawn.insert(aid.to_string());
                        }
                    }
                }
                ("mux", "permission_decision") if current => {
                    if let Some(aid) = e
                        .msg
                        .get("permissionId")
                        .and_then(Value::as_str)
                        .and_then(|pid| by_permission.get(pid))
                        && let Some(entry) = asked.get_mut(aid)
                    {
                        entry.2 = e.msg.get("outcome").cloned();
                        work.cancelled_permissions.remove(aid);
                        // Beside the outcome, or inside it as a re-asked prompt's answer was
                        // logged before review 84 of #23322.
                        let inside = format!("/outcome/{ANSWERED_BY_SLOT}/session");
                        if e.msg.pointer("/answeredBy/session").is_some()
                            || e.msg.pointer(&inside).is_some()
                        {
                            ancestors.insert(aid.clone());
                        } else {
                            ancestors.remove(aid);
                        }
                    }
                }
                ("out", method::SESSION_PROMPT) if current && work.turn.is_some() => {
                    let id = e.msg.get("id").cloned();
                    // A steer into the running turn is not the turn's prompt: its
                    // answer (Claude Code's `steered`) does not end the turn.
                    let steer =
                        e.msg.pointer("/params/_meta/steer").and_then(Value::as_bool) == Some(true);
                    if steer && (work.prompt_request.is_some() || work.turn_carried) {
                        work.steers.extend(id.map(|id| (id, None)));
                    } else {
                        work.prompt_request = id;
                        // A carried turn's steers may go in before its prompt.
                        if !work.turn_carried {
                            work.steers.clear();
                        }
                    }
                }
                ("in", "response") if current => {
                    let id = e.msg.get("id");
                    if work.prompt_request.is_some() && id == work.prompt_request.as_ref() {
                        work.prompt_response = Some(e.msg.clone());
                    } else if let Some(steer) =
                        work.steers.iter_mut().find(|(steer, _)| id == Some(steer))
                    {
                        steer.1 = Some(e.msg.clone());
                    }
                }
                ("out", agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD) if current => {
                    match e.msg.pointer("/params/receipt").and_then(Value::as_u64) {
                        Some(r) if e.kind == agent_host::QUEUED_METHOD => {
                            work.unwritten.insert(r);
                        }
                        Some(r) => {
                            work.unwritten.remove(&r);
                        }
                        None => work.receipts_unproven = true,
                    }
                }
                ("out", "response") if current => {
                    if let Some(id) = e.msg.get("id") {
                        answered.insert(id.to_string());
                        open_request_ids.remove(&id.to_string());
                    }
                }
                ("in", kind)
                    if current && e.msg.get("id").is_some() && e.msg.get("method").is_some() =>
                {
                    let id = e.msg["id"].clone();
                    open_request_ids.insert(id.to_string());
                    let params = e.msg.get("params").cloned();
                    requests.push((id, kind.to_owned(), params, e.host_seq));
                }
                _ => {}
            }
            if current
                && host_seq_matches(&e, incarnation)
                && let Some(h) = e.host_seq.filter(|&h| h > work.last_host_seq)
            {
                work.last_host_seq = h;
                host_seq_at = None;
            }
            if work.turn.is_some() && super::tap::logged_from_the_model(&e) {
                work.heard_at = e.at;
                if let Some(update) = e.msg.pointer("/params/update") {
                    super::stalled_turn::track_tool(&mut work.open_tools, update);
                }
            }
            true
        });
        work.receipts_unproven |= scanned.is_err() || !started;
        // A line cut short showed it: the whole records decide, as before.
        if let Some(seq) = host_seq_at
            && !self.logs_host_seq(session, seq, work.last_host_seq)
        {
            return self.open_work_reading(session, incarnation, |_, _, _| true);
        }
        work.requests = requests
            .into_iter()
            .filter(|(id, _, _, _)| !answered.contains(&id.to_string()))
            .collect();
        work.permissions = asked;
        work.ancestor_answers = ancestors;
        work
    }

    /// The remote floor's marks of an adopted host (`open_work`).
    pub(super) fn recover_floor(session: &Session, work: &OpenWork) {
        session.floor.harness_grant.store(work.harness_grant, Ordering::SeqCst);
        session.floor.unsandboxed.store(work.unsandboxed, Ordering::SeqCst);
        session
            .floor
            .last_turn_web
            .store(work.last_control == Some(Control::Web), Ordering::SeqCst);
        if let Some((_, turn_id, ..)) = &work.turn
            && work.floor_cancelled.as_ref() == Some(turn_id)
        {
            *session.floor.floor_cancelled_turn.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(turn_id.clone());
        }
    }

    /// Rebuild the turn and the unanswered agent requests of an adopted host.
    async fn recover_work(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        incarnation: &str,
        work: OpenWork,
    ) {
        Self::recover_floor(session, &work);
        session.compacting.store(work.compacting, Ordering::SeqCst);
        self.rebuild_processes(session);
        // A carried turn the restart cut before its prompt went out (or before it started):
        // the agent runs it still, and it goes on (`carried_turn.rs`).
        if let Some((turn_seq, turn_id, prompt_id, prompt, client, control)) = work.turn.clone()
            && work.turn_carried
            && work.prompt_request.is_none()
        {
            let mut turn = TurnInfo::prompted(&client, &prompt, &turn_id, &prompt_id, control);
            if let Some(line) = &work.turn_line {
                turn.show(line);
            }
            turn.turn_seq = turn_seq;
            if work.turn_at > 0 {
                turn.started_at = work.turn_at;
            }
            self.recover_carried(session, child, turn, None, Default::default());
        } else if work.turn.is_none()
            && let Some((from, record)) = &work.carry_next
            && let Some(next) = super::carried_turn::NextTurn::from_record(record)
        {
            let super::carried_turn::NextTurn { carried, next, continues } = next;
            let begin = Some((from.clone(), carried));
            self.recover_carried(session, child, next, begin, continues);
        } else if let Some((turn_seq, turn_id, prompt_id, prompt, client, control)) =
            work.turn.clone()
        {
            // A steer whose logged answer ended the turn settles it like the turn's own answer.
            let answer = work.prompt_response.clone().or_else(|| {
                work.steers.iter().find_map(|(_, a)| a.clone().filter(steer_answer_ends_turn))
            });
            match (work.prompt_request.clone(), answer) {
                // The prompt never reached this host (or another host ran
                // it): nothing can answer it any more.
                (None, _) => {
                    let error = "the agent host never received this turn's prompt";
                    self.append_unknown_outcome(session, json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "error": error, "errorText": error}));
                    self.save_meta(session);
                }
                (Some(request_id), answer) => {
                    let outcome = super::prompt_ledger::recover(session, &prompt_id);
                    // Before anything can force its end (`turn_answer`).
                    let ended = session.steer_end.subscribe();
                    // Its start as logged: a restart does not make it new.
                    let started_at = if work.turn_at > 0 { work.turn_at } else { now_ms() };
                    // Its line on the summary as the turn showed it (`prompt_line.rs`); an older
                    // record's as its client tells it.
                    let line = work
                        .turn_line
                        .clone()
                        .unwrap_or_else(|| super::prompt_line::prompt_line(&prompt, &client, None));
                    *session.turn.lock().unwrap() = Some(TurnInfo {
                        started_at,
                        client,
                        masked_preview: super::auto_resume::shown_line(&line),
                        prompt_preview: prompt,
                        turn_id: turn_id.clone(),
                        prompt_id: prompt_id.clone(),
                        turn_seq,
                        // Who prompted (`turn_started`); an older record without it is Web.
                        control,
                        doing: work.doing.clone(),
                        // A restart keeps no provenance of the turn: its History line stays.
                        notice: false,
                        // As logged (`turn_started` `persons`); an older record's takes notices.
                        persons: work.turn_persons,
                    });
                    session.floor.last_turn_web.store(control == Control::Web, Ordering::SeqCst);
                    // A Web turn in flight in an agent the sandbox did not
                    // start does not go on (tools that do not ask).
                    if control == Control::Web && session.floor.unsandboxed.load(Ordering::SeqCst) {
                        self.remote_floor_cancel(session, "remote.unsandboxed_agent");
                    }
                    // Nor one in a mode only a machine's Full-access setting allows: which
                    // machine sent it is not kept across a restart (`full_access_hold`).
                    if self.full_access_hold(&session.meta(), control, None).is_err() {
                        self.remote_floor_cancel(session, "remote.full_access_ended");
                    }
                    *session.open_tools.lock().unwrap_or_else(|e| e.into_inner()) =
                        work.open_tools.clone();
                    self.watch_stalled_turn(session, Some(work.heard_at.max(started_at)));
                    self.set_status(session, SessionStatus::Running);
                    // Its cap counts from its start, as logged (`turn_cap.rs`).
                    self.arm_turn_cap(session, &turn_id);
                    // The answer is either logged already, or still to come
                    // (`await_response` also takes one that arrived first).
                    let rx = match answer {
                        Some(_) => None,
                        None => Some(child.await_response(request_id).await),
                    };
                    // The steers still unanswered: one of them may end the turn.
                    let mut steer_answers = Vec::new();
                    if rx.is_some() {
                        for (id, logged) in &work.steers {
                            if logged.is_none() {
                                steer_answers.push(child.await_response(id.clone()).await);
                            }
                        }
                    }
                    let hub = self.clone();
                    let next_raised = work.next_raised;
                    let s = session.clone();
                    let c = child.clone();
                    tokio::spawn(async move {
                        // New prompts queue behind the recovered turn.
                        let guard = s.turn_lock.lock().await;
                        let result = match (answer, rx) {
                            (Some(msg), _) => response_result(&msg),
                            (None, Some(rx)) => {
                                turn_answer(rx, steer_answers, ended, &turn_id).await
                            }
                            (None, None) => Err(RpcError::internal("agent answer lost")),
                        };
                        // Its agent ended it and runs on with steers it read after: the next turn
                        // starts as this one ends (`carried_turn.rs`).
                        let mut carried = hub.next_carried(&s, &turn_id, &result);
                        // A Web steer raised the turn it carried into before the restart.
                        let raised = next_raised && carried.is_some();
                        if let Some(c) = carried.as_mut().filter(|_| next_raised) {
                            c.next.control = Control::Web;
                        }
                        let next = carried.as_deref();
                        let mut result = hub
                            .finish_turn(&s, &c, result, &prompt_id, &turn_id, turn_seq, None, next)
                            .await;
                        if let Ok(value) = &mut result {
                            super::merge_mux_meta(
                                value,
                                json!({"promptId": prompt_id,
                                "turnId": turn_id, "turnSeq": turn_seq}),
                            );
                        }
                        outcome.send_replace(Some(result));
                        super::prompt_ledger::prune(
                            &mut s.prompts.lock().unwrap_or_else(|e| e.into_inner()),
                        );
                        // A recovered turn is not continued (`auto_resume.rs`); settle its mark.
                        hub.schedule_auto_resume(&s, &turn_id, None);
                        if let Some(carried) = &carried {
                            // Its task takes the turn lock once this one lets it go.
                            hub.start_carried(&s, &c, &turn_id, carried, None);
                            if raised {
                                hub.recovered_floor(&s, Control::Web);
                            }
                            drop(guard);
                            return;
                        }
                        // A route switch or an update asked for a restart
                        // during the turn (route_switch.rs): the process ends
                        // now and the next prompt starts it again, resuming
                        // the chat. Not started here: this task runs inside
                        // the adoption a start itself may run.
                        if s.route_switch.swap(false, Ordering::SeqCst) {
                            hub.detach_child(&s).await;
                        }
                        // A Stop ended its agent (`cancel.rs`). Not started again here, for the
                        // reason above, nor on a task of its own: that start would run inside
                        // this adoption's future (not `Send`). The next prompt starts it, on the
                        // same conversation, as after any agent exit.
                        s.stop_respawn.store(0, Ordering::SeqCst);
                        drop(guard);
                    });
                }
            }
        }
        let epoch = session.permission_epoch.load(Ordering::SeqCst);
        let turn_id = session.turn().map(|t| t.turn_id);
        // The remote floor cancelled the recovered turn (in the log, or just
        // now for an unsandboxed agent): its permissions are cancelled too,
        // never answered from the log or shown again.
        let floored = Self::web_turn(session) && self.remote_floor_breach(session).is_some();
        // Every request that starts its own task is counted before the
        // answers below are sent, so no group of them is shown while one
        // still waits for its spawn (`AskInFlight`).
        let asks: Vec<_> = work
            .requests
            .iter()
            .map(|(id, m, _, _)| {
                (m == method::SESSION_REQUEST_PERMISSION
                    && !work.permissions.contains_key(&id.to_string()))
                .then(|| super::permission_groups::AskInFlight::new(session))
            })
            .collect();
        for ((id, m, params, _), ask) in work.requests.into_iter().zip(asks) {
            if m == method::SESSION_REQUEST_PERMISSION && work.withdrawn.contains(&id.to_string()) {
                let cancelled = json!({"outcome": {"outcome": "cancelled"}});
                let _ = child.respond(id.clone(), Ok(cancelled)).await;
                self.finish_agent_request(session, &id, Some(incarnation));
                continue;
            }
            if m == method::SESSION_REQUEST_PERMISSION
                && let Some((permission_id, request, decided)) =
                    work.permissions.get(&id.to_string()).cloned()
            {
                if floored {
                    let cancelled = json!({"outcome": {"outcome": "cancelled"}});
                    let _ = child.respond(id.clone(), Ok(cancelled)).await;
                    self.finish_agent_request(session, &id, Some(incarnation));
                    continue;
                }
                match decided {
                    // An ancestor's answer that never reached the agent: checked and written
                    // under the family gate, as a new one is (`subsession_answer.rs`). Under MDM's
                    // off, or once an off push cut it, it is asked again, decided under the bound
                    // now, never resent unchecked (reviews 82 and 84 of #23322; with MDM unset it
                    // is sent as before).
                    Some(outcome) if work.ancestor_answers.contains(&id.to_string()) => {
                        pause_replayed_answer("ACPMUX_TEST_PAUSE_RECOVERED_ANSWER").await;
                        let hold = self.family_hold().await;
                        // Asked again under the epoch and turn read before the wait: a Stop
                        // meanwhile cancels it (review 88 of #23322).
                        if hold.bound.off {
                            drop(hold);
                            // The agent withdrew it (before or after the answer was logged): it
                            // is answered cancelled, never asked again (review 130 of #23322).
                            if work.withdrawn_asks.contains(&id.to_string()) {
                                let key = super::permission_groups::AgentRequestKey::new(
                                    Some(incarnation),
                                    &id,
                                );
                                let mut state =
                                    session.permissions.lock().unwrap_or_else(|e| e.into_inner());
                                state.cancelled_requests.insert(key);
                            }
                            let asked = Some((epoch, turn_id.clone()));
                            self.reregister_permission(
                                session,
                                child,
                                id,
                                permission_id,
                                request,
                                incarnation,
                                asked,
                            )
                            .await;
                            continue;
                        }
                        pause_replayed_answer("ACPMUX_TEST_PAUSE_REPLAYED_ANSWER").await;
                        let fence = self.hold_until_written(session, hold);
                        let answer = Ok(permission_answer(outcome));
                        let _ = child.respond_fenced(id.clone(), answer, Some(&fence)).await;
                        // Finished once the fence settles (`ask_again_once_cut`).
                        let asked = Some((epoch, turn_id.clone()));
                        let again = (id, permission_id, request, incarnation.to_owned(), asked);
                        self.ask_again_once_cut(session, child, fence, again);
                    }
                    // Decided but the answer never reached the agent: send it.
                    Some(outcome) => {
                        if work.cancelled_permissions.contains(&id.to_string()) {
                            self.append(
                                session,
                                "mux",
                                "permission_decision",
                                json!({"permissionId": permission_id, "outcome": outcome.clone()}),
                            );
                        }
                        let _ = child.respond(id.clone(), Ok(permission_answer(outcome))).await;
                        self.finish_agent_request(session, &id, Some(incarnation));
                    }
                    None => {
                        self.reregister_permission(
                            session,
                            child,
                            id,
                            permission_id,
                            request,
                            incarnation,
                            None,
                        )
                        .await;
                    }
                }
                continue;
            }
            // Never answered and never asked: handle it as if it just came.
            let hub = self.clone();
            let s = session.clone();
            let turn_id = turn_id.clone();
            let request_id = id.clone();
            let incarnation = incarnation.to_owned();
            // Counted until it is answered, as a live one is (`idle.rs`).
            let busy = super::idle::AgentRequest::new(session);
            tokio::spawn(async move {
                let finish_hub = hub.clone();
                hub.on_agent_request(
                    s.clone(),
                    id,
                    m,
                    params,
                    epoch,
                    turn_id,
                    ask,
                    Some(incarnation.clone()),
                    None,
                )
                .await;
                finish_hub.finish_agent_request(&s, &request_id, Some(&incarnation));
                drop(busy);
            });
        }
    }

    /// A permission prompt the previous daemon showed: keep the same id so a
    /// client answers it as before, and answer the agent's original request.
    /// `asked`: the permission epoch and turn its previous answer was sent under; a stop or a
    /// new turn since cancels it instead (review 86 of #23322).
    pub(super) async fn reregister_permission(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        agent_request_id: Value,
        permission_id: String,
        mut request: Value,
        incarnation: &str,
        asked: Option<(u64, Option<String>)>,
    ) {
        // A record from a daemon without question normalization gets it here,
        // so its answers are checked like a new ask's.
        super::questions::normalize(&mut request, Self::preview_format(session));
        // The display line is acpmux's own, worked out again (`permissions/display.rs`): never
        // one the record held.
        self.stamp_permission_display(session, &mut request);
        let (tx, rx) = oneshot::channel();
        let decision_nonce = super::person::new_nonce();
        let key =
            super::permission_groups::AgentRequestKey::new(Some(incarnation), &agent_request_id);
        let asked = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let stopped = asked.as_ref().is_some_and(|(epoch, turn)| {
                session.permission_epoch.load(Ordering::SeqCst) != *epoch
                    || super::permissions::stale_turn(session, turn)
            });
            if stopped || state.cancelled_requests.remove(&key) {
                None
            } else {
                // The epoch and turn it is asked under, read under the lock a Stop takes: an
                // answer to it that is cut is asked again only while they hold (review 88 of
                // #23322).
                let asked = asked.unwrap_or_else(|| {
                    let epoch = session.permission_epoch.load(Ordering::SeqCst);
                    (epoch, session.turn().map(|t| t.turn_id))
                });
                state.pending.insert(
                    permission_id.clone(),
                    PendingPermission {
                        // The agent's own ask, judged like a fresh one (a re-adopted AskUserQuestion).
                        ancestor_may_answer: super::questions::ancestor_answerable(&request, true),
                        request: request.clone(),
                        reply: tx,
                        decision_nonce: decision_nonce.clone(),
                        // Settled by the task below, from a turn or none (`status_after_ask`).
                        prev_status: SessionStatus::Waiting,
                        agent_request: Some(agent_request_id.clone()),
                        agent_host_incarnation: Some(incarnation.to_owned()),
                    },
                );
                Some(asked)
            }
        };
        // Withdrawn by the agent, or cancelled by a stop or a new turn since its previous answer.
        let Some(asked) = asked else {
            let outcome = json!({"outcome": "cancelled"});
            self.append(
                session,
                "mux",
                "permission_decision",
                json!({"permissionId": permission_id, "outcome": outcome}),
            );
            let _ = child.respond(agent_request_id.clone(), Ok(permission_answer(outcome))).await;
            self.finish_agent_request(session, &agent_request_id, Some(incarnation));
            return;
        };
        // The prompt's new nonce under this daemon run, for a relayed allow
        // (`person.rs`): clients get it as `_acpmux/permission_pending`.
        self.append(
            session,
            "mux",
            "permission_reissued",
            json!({"permissionId": permission_id, "decisionNonce": decision_nonce,
                   "personInstance": self.person.instance(), "request": request.clone(),
                   "agentRequestId": agent_request_id.clone()}),
        );
        self.set_status(session, SessionStatus::Waiting);
        let hub = self.clone();
        let s = session.clone();
        let c = child.clone();
        let incarnation = incarnation.to_owned();
        tokio::spawn(async move {
            let mut outcome = rx.await.unwrap_or_else(|_| json!({"outcome": "cancelled"}));
            // Who answered, beside the outcome as an ask logs it, so the next restart knows an
            // ancestor's answer; never sent to the agent (review 84 of #23322).
            let answered_by = outcome.as_object_mut().and_then(|o| o.remove(ANSWERED_BY_SLOT));
            let mut decision = json!({"permissionId": permission_id, "outcome": outcome.clone()});
            if let Some(by) = answered_by {
                decision.set("answeredBy", by);
            }
            hub.append(&s, "mux", "permission_decision", decision);
            {
                let state = s.permissions.lock().unwrap_or_else(|e| e.into_inner());
                if state.pending.is_empty()
                    && s.status() == SessionStatus::Waiting
                    && !hub.secrets.waiting_in(&s.id)
                {
                    let next = if s.turn().is_some() {
                        SessionStatus::Running
                    } else {
                        SessionStatus::Ready
                    };
                    hub.set_status(&s, next);
                }
            }
            // An ancestor's answer: written under its fence (`subsession_answer.rs`).
            let fence = hub.answer_fences.lock().unwrap().remove(&permission_id);
            let asked = Some(asked);
            let answer = Ok(permission_answer(outcome));
            let _ = c.respond_fenced(agent_request_id.clone(), answer, fence.as_ref()).await;
            if let Some(fence) = fence {
                // Finished once the fence settles (`ask_again_once_cut`).
                let again = (agent_request_id, permission_id, request, incarnation, asked);
                hub.ask_again_once_cut(&s, &c, fence, again);
            } else {
                hub.finish_agent_request(&s, &agent_request_id, Some(&incarnation));
            }
        });
    }

    /// An ancestor's answer to the prompt `permission_id`, sent under `fence`: once an off push
    /// cut it while queued it never reaches the agent, which still waits, so the prompt is asked
    /// again (review 84 of #23322), unless a stop or a new turn since `again.4`, or the agent's
    /// withdrawal, cancelled it. The agent's request stays open until the fence settles, so a
    /// withdrawal while the answer waits is kept for the ask again (review 88, round 7); it is
    /// finished here, or by the ask again.
    fn ask_again_once_cut(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        fence: crate::agent::Fence,
        again: ReAsk,
    ) {
        let (hub, s, c) = (self.clone(), session.clone(), child.clone());
        // task-owner: ends once its writer takes the answer or it is cut: only a queued one can
        // be (review 88 of #23322).
        tokio::spawn(async move {
            fence.taken().await;
            // A writer that stopped cuts what it still had: its agent is gone and asks nothing.
            // Asked again only of the agent that asked it, while it still has the session: a
            // failover's agent starts its request ids over (review 130 of #23322).
            let (id, permission_id, request, incarnation, asked) = again;
            let asking = s.child.lock().await.as_ref().is_some_and(|now| Arc::ptr_eq(now, &c));
            if fence.is_cut() && asking && c.is_alive().await {
                hub.reregister_permission(&s, &c, id, permission_id, request, &incarnation, asked)
                    .await;
            } else {
                hub.finish_agent_request(&s, &id, Some(&incarnation));
            }
        });
    }
}

/// A prompt to ask again (`Hub::ask_again_once_cut`): the agent's request id, the permission id,
/// the request, its host incarnation, and the permission epoch and turn its answer was sent under.
type ReAsk = (Value, String, Value, String, Option<(u64, Option<String>)>);

/// Debug builds only: a test pauses a restart's resend of an ancestor's answer 3 s, right after
/// its check (`ACPMUX_TEST_PAUSE_REPLAYED_ANSWER`, so it can push MDM's off then) or before it
/// (`ACPMUX_TEST_PAUSE_RECOVERED_ANSWER`, so it can stop the session then): the pause writes
/// the file `var` names first (`durable_agents.rs`). Release builds have no seam.
async fn pause_replayed_answer(var: &str) {
    #[cfg(debug_assertions)]
    if let Some(marker) = std::env::var_os(var) {
        let _ = std::fs::write(marker, "");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
    #[cfg(not(debug_assertions))]
    let _ = var;
}

/// The `session/request_permission` result for a logged outcome, shaped as
/// `handle_permission` shapes it (`_meta` lifted out of the outcome).
/// Whether a logged steer answer (a JSON-RPC response) ended its turn: any
/// stop reason but Claude Code's `steered` (`steer_end.rs`).
fn steer_answer_ends_turn(msg: &Value) -> bool {
    msg.pointer("/result/stopReason").and_then(Value::as_str).is_some_and(|r| r != "steered")
}

/// The answer that settles a recovered turn: its own prompt's, the first
/// steer answer that ends the turn (`steered` answers do not), or the end
/// acpmux forces on turn `turn_id` (`ended`: Stop past its grace, `cancel.rs`;
/// a stalled turn, `stalled_turn.rs`). Without that last one Stop never ended
/// a turn an adopted host ran whose agent did not answer the cancel.
async fn turn_answer(
    own: tokio::sync::oneshot::Receiver<Result<Value, RpcError>>,
    steers: Vec<tokio::sync::oneshot::Receiver<Result<Value, RpcError>>>,
    mut ended: tokio::sync::watch::Receiver<Option<(String, Value)>>,
    turn_id: &str,
) -> Result<Value, RpcError> {
    use futures::StreamExt;
    let mut ending = steers
        .into_iter()
        .map(|rx| async move {
            match rx.await {
                Ok(Ok(v)) if v.get("stopReason").and_then(Value::as_str) != Some("steered") => {
                    Some(Ok(v))
                }
                _ => None,
            }
        })
        .collect::<futures::stream::FuturesUnordered<_>>()
        .filter_map(std::future::ready);
    // acpmux ended this turn itself: Stop past its grace, or a stalled turn.
    // The end may have come already, before this task ran.
    let forced = async {
        loop {
            if let Some((turn, answer)) = ended.borrow_and_update().clone()
                && turn == turn_id
            {
                return answer;
            }
            if ended.changed().await.is_err() {
                return std::future::pending().await;
            }
        }
    };
    tokio::select! {
        r = own => r.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped"))),
        Some(r) = ending.next() => r,
        answer = forced => Ok(answer),
    }
}

fn permission_answer(mut outcome: Value) -> Value {
    // Who answered is audit only (`ANSWERED_BY_SLOT`), never sent to the agent.
    if let Some(o) = outcome.as_object_mut() {
        o.remove(ANSWERED_BY_SLOT);
    }
    let mut out = json!({"outcome": outcome});
    if let Some(m) = out["outcome"].get("_meta").cloned() {
        out.set("_meta", m);
        if let Some(o) = out["outcome"].as_object_mut() {
            o.remove("_meta");
        }
    }
    out
}

fn response_result(msg: &Value) -> Result<Value, RpcError> {
    match msg.get("error") {
        Some(e) if !e.is_null() => {
            Err(serde_json::from_value(e.clone())
                .unwrap_or_else(|_| RpcError::internal("agent error")))
        }
        _ => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
    }
}

/// `agent_host::terminate_unadoptable` off the async runtime.
pub(super) async fn end_host_blocking(
    dir: std::path::PathBuf,
    session_id: String,
    nonce: Option<String>,
    host_pid: Option<u32>,
) -> bool {
    // Debug builds only: `ACPMUX_TEST_HOST_END_FAILS` makes every end by nonce fail (`=once`: only
    // the first), as one does on a host that outlives its proof, so the daemon's integration
    // tests can drive that path. Release builds have no seam.
    #[cfg(debug_assertions)]
    if let Ok(how) = std::env::var("ACPMUX_TEST_HOST_END_FAILS") {
        static FAILED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
        if how != "once" || !FAILED.swap(true, Ordering::SeqCst) {
            return false;
        }
    }
    tokio::task::spawn_blocking(move || {
        agent_host::terminate_unadoptable(&dir, &session_id, nonce.as_deref(), host_pid)
            .unwrap_or(false)
    })
    .await
    .unwrap_or(false)
}

impl Hub {
    /// New agents run under an `__agent-host` process, so they outlive this
    /// daemon (durable sessions). The daemon turns this on at start
    /// (`daemon run`; `ACPMUX_AGENT_HOSTS=0` is the one-release opt-out);
    /// an in-process hub (tests, embedding) keeps direct children. Memory
    /// stores keep no log to resume from, so they never use hosts.
    pub(crate) fn agent_hosts_enabled(&self) -> bool {
        self.store.session_dir("probe").is_some() && self.agent_hosts.load(Ordering::SeqCst)
    }

    /// Run new agents under agent hosts (see `agent_hosts_enabled`).
    /// Windows: agent hosts are not ported yet, so agents stay direct
    /// children in job objects (sessions do not outlive the daemon there).
    pub fn enable_agent_hosts(&self) {
        self.agent_hosts.store(cfg!(unix), Ordering::SeqCst);
    }

    pub(super) async fn spawn_hosted_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &HarnessProfile,
        meta: &SessionMeta,
        command_line: Option<(String, Vec<String>)>,
        translator: Option<crate::agent_host::TranslatorSpec>,
        tap: crate::agent::Tap,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        let internal = |e: anyhow::Error| {
            crate::launch_policy::spawn_error(e, |e| RpcError::internal(format!("{e:#}")))
        };
        // From the profile, before its CODEX_PATH picks the binary.
        let codex_bridge = command_line.is_none()
            && translator.is_none()
            && crate::codex_app_server::is_profile_launch(&profile.argv);
        // Host launches receive a complete environment snapshot. It must be
        // current when that snapshot is made, including on credential revocation.
        if !crate::login_env::machine_env_fresh_before_spawn().await {
            return Err(RpcError::internal(
                "machine environment changed; login env refresh failed",
            ));
        }
        let cmd = crate::agent::harness_command(
            &meta.harness,
            profile,
            &meta.cwd,
            command_line,
            Some((&session.id, &meta.name)),
        )
        .map_err(internal)?;
        self.record_preview_format(session, crate::agent::pinned_preview_format(&cmd));
        let std_cmd = cmd.as_std();
        let hosts = crate::agent_host::hosts_dir();
        let env = if meta.remote_origin {
            crate::agent::command_env_cleared(&cmd)
        } else {
            crate::agent::command_env(&cmd)
        };
        // The class it runs at once its start is over, from the harness's own env: its profile's
        // value as resolved (`cpu_class.rs`). It starts at normal class.
        let run_class = crate::cpu_class::CpuClass::for_session(
            env.iter().map(|(k, v)| (k.as_str(), v.as_str())),
        );
        let mut spec = crate::agent_host::SpawnSpec {
            session_id: session.id.clone(),
            program: std_cmd.get_program().to_string_lossy().into_owned(),
            args: std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect(),
            env,
            cwd: meta.cwd.clone(),
            codex_bridge,
            translator,
            socket: crate::agent_host::socket_path(&hosts, &session.id),
            hosts_dir: hosts,
            buffer_cap: crate::agent_host::DEFAULT_BUFFER_CAP,
            router_owner_fifo: crate::daemon::router_owner_path(),
            cwd_pin: crate::cwd_pin::CwdPin::current(),
            orphan_exit: None,
        };
        let launcher = crate::agent_host::link::HostLauncher::current().map_err(internal)?;
        // Its MCP configs are read before it starts, never after (`hub/idle_census.rs`).
        let launch = crate::agent::Launch::new(&spec.program, &spec.args, &spec.env, &spec.cwd);
        let servers = LaunchServers::read(&launch, meta.family.clone().unwrap_or_default()).await;
        spec.orphan_exit = servers.orphan_exit(self.orphan_exit());
        let launched = |child: Arc<ChildAgent>| {
            child.record_launch(servers.clone());
            child.set_run_class(run_class);
            child
        };
        let first = match self.start_hosted(session, meta, &launcher, &spec, tap.clone()).await {
            Ok(child) => return Ok(launched(child)),
            Err(e) => e,
        };
        // A host that started but did not answer (a wedged or dead host: its hello missed the
        // `link::connect` budget) is ended and one fresh host takes its place, once; never for a
        // remote-origin chain, whose sandbox canary proves only the start it preceded.
        let Some(failed) = first.started else { return Err(internal(first.error)) };
        let ended = self.end_unanswered_host(session, &failed, &first.error).await;
        if !ended || meta.remote_origin {
            return Err(internal(first.error));
        }
        tracing::warn!(session = %session.id, "agent host did not answer ({:#}); starting a fresh host", first.error);
        match self.start_hosted(session, meta, &launcher, &spec, tap).await {
            Ok(child) => Ok(launched(child)),
            Err(second) => {
                if let Some(failed) = &second.started {
                    let _ = self.end_unanswered_host(session, failed, &second.error).await;
                }
                Err(RpcError::internal(format!(
                    "{:#} (a fresh agent host also failed: {:#})",
                    first.error, second.error
                )))
            }
        }
    }

    /// Start one host for `spec` and attach to it. A failure after the host
    /// started carries its record, so the caller can end it.
    async fn start_hosted(
        self: &Arc<Self>,
        session: &Arc<Session>,
        meta: &SessionMeta,
        launcher: &crate::agent_host::link::HostLauncher,
        spec: &crate::agent_host::SpawnSpec,
        tap: crate::agent::Tap,
    ) -> Result<Arc<ChildAgent>, HostStartFailed> {
        // A start runs only once the session's old host is gone (`ensure_child`), so a host this
        // build could not speak to no longer counts: cleared before the new host's record is
        // live, so no off push in between ends the new one for it (#26337).
        session.floor.unjudged_host.store(false, Ordering::SeqCst);
        let record = crate::agent_host::program_wait::spawn(launcher, spec)
            .await
            .map_err(|error| HostStartFailed { error, started: None })?;
        // Not at a background class another process set (`cpu_class.rs`, item 1). Its host reaps
        // it: a harness that already ended leaves the pid to a process of this user at most.
        if let Some(pid) = record.harness_pid {
            crate::cpu_class::clear_running(pid);
        }
        self.forget_adopted_caller(&session.id);
        // Logged before the first entry, so a later controller counts every
        // entry of this incarnation.
        let mut started = json!({
            "incarnation": record.incarnation.clone(),
            "hostPid": record.host_pid,
            "hostBuild": record.host_build.clone()
        });
        if meta.remote_origin {
            started.set("remoteEnvPolicy", crate::agent::REMOTE_ENV_POLICY_ID.into());
        }
        self.append(session, "mux", "host_started", started);
        // A new host: its log is read back again under MDM's off, no end is pending for it, and
        // none of its reports waits (`full_access_bound.rs`).
        session.floor.left_host_read.store(false, Ordering::SeqCst);
        session.floor.full_access_end_pending.store(false, Ordering::SeqCst);
        session.floor.unapplied_full_access.store(0, Ordering::SeqCst);
        let attached = ChildAgent::attach_hosted(
            &meta.harness,
            record.clone(),
            0,
            Vec::new(),
            session.inbound_tx.clone(),
            tap,
        )
        .await;
        match attached {
            Ok(crate::agent::Attached::Ready(child, _, _)) => Ok(child),
            Ok(crate::agent::Attached::Incompatible { .. }) => Err(HostStartFailed {
                error: anyhow::anyhow!("a host of this build refused its controller"),
                started: None,
            }),
            Err(error) => Err(HostStartFailed { error, started: Some(record) }),
        }
    }

    /// End a host this daemon started but could not attach to, by nonce
    /// proof, and remove its files, so a fresh host can take the session's
    /// socket and record. True when it no longer runs.
    async fn end_unanswered_host(
        &self,
        session: &Session,
        record: &agent_host::HostRecord,
        error: &anyhow::Error,
    ) -> bool {
        let dir = agent_host::hosts_dir();
        let ended = end_host_blocking(
            dir.clone(),
            record.session_id.clone(),
            Some(record.start_nonce.clone()),
            Some(record.host_pid),
        )
        .await;
        if ended {
            agent_host::remove_artifacts(&dir, record);
        } else {
            tracing::warn!(session = %session.id, "could not end an agent host that did not answer");
        }
        self.append(
            session,
            "mux",
            "host_unanswered",
            json!({"incarnation": record.incarnation, "hostPid": record.host_pid, "ended": ended, "error": format!("{error:#}")}),
        );
        ended
    }
}

/// The `mux` kinds `open_work` folds.
const OPEN_WORK_MUX_KINDS: [&str; 10] = [
    "host_started",
    "remote_sandbox",
    "permission_request",
    "permission_decision",
    "permission_withdrawn",
    "permission_auto",
    "turn_started",
    "turn_control",
    "turn_result",
    "remote_floor_cancel",
];

/// A deferred withdrawal may be logged after its host was replaced. Its
/// checkpoint belongs only to the incarnation named in the durable marker.
fn host_seq_matches(e: &crate::store::EventRecord, incarnation: &str) -> bool {
    e.kind != "permission_withdrawn"
        || e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation)
}

/// Whether `open_work` must parse a record to fold it, judged from its head and the scan so far:
/// whether the adopted incarnation is current and the log's last turn is open (`turn_open`; an
/// earlier turn's records are folded away when it ends). A record it passes is one the fold would
/// leave as it is but for its `hostSeq`, which the head holds; one it cannot rule out is read.
/// Most of a long log is closed turns' agent output, which is passed unparsed.
fn open_work_reads(head: &RecordHead<'_>, current: bool, turn_open: bool) -> bool {
    match head.dir {
        "mux" => OPEN_WORK_MUX_KINDS.contains(&head.kind),
        "out" => {
            current
                && (matches!(
                    head.kind,
                    "response" | agent_host::QUEUED_METHOD | agent_host::WRITTEN_METHOD
                ) || (turn_open && head.kind == method::SESSION_PROMPT))
        }
        "in" => {
            // An open turn's records: the model's signs of work, its tools, steers' answers.
            turn_open
                // Every subagent the log starts, which a later turn's update may belong to.
                || super::work_below::names_subagents(head)
                // An agent request (an `id` and a `method`), answered or not.
                || (current && head.may_contain(b"\"id\":") && head.may_contain(b"\"method\":"))
        }
        _ => true,
    }
}

/// [`Hub::start_hosted`] failed; `started` is the host that runs anyway.
struct HostStartFailed {
    error: anyhow::Error,
    started: Option<agent_host::HostRecord>,
}

#[cfg(test)]
#[path = "hosts_tests.rs"]
mod hosts_tests;
