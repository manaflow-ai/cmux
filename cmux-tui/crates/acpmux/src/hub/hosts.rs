//! Part of `Hub`; see `hub/mod.rs`. Adopting agent hosts after a daemon
//! restart or upgrade (plans/cmux-next/durable-sessions.md 2.5): reattach,
//! resume the host's entries after the last one logged, wait until the
//! replayed entries are in the log, then rebuild the turn and permission
//! state that died with the previous daemon from that complete log.

use super::*;
use crate::agent::Attached;
use crate::agent_host::{self, Liveness};

/// How long adoption waits for one host's replayed entries to be logged.
const REPLAY_BUDGET: std::time::Duration = std::time::Duration::from_secs(10);

/// What the session log says about the work in flight under one host
/// incarnation when the previous controller stopped.
#[derive(Debug, Default)]
struct OpenWork {
    /// `turn_started` without `turn_result`: (seq, turnId, promptId, prompt, client).
    turn: Option<(u64, String, String, String, String)>,
    /// The `session/prompt` request id written to this host for that turn,
    /// and its answer when it is already logged.
    prompt_request: Option<Value>,
    prompt_response: Option<Value>,
    /// Agent requests to this host with no logged answer: (id, method,
    /// params, hostSeq).
    requests: Vec<(Value, String, Option<Value>, Option<u64>)>,
    /// `permission_request` records by agent request id: (permissionId,
    /// request, logged decision when there is one).
    permissions: HashMap<String, (String, Value, Option<Value>)>,
    /// Largest `hostSeq` logged under this incarnation. Every entry kind is
    /// logged in entry order before its ack, so this is the logged prefix.
    last_host_seq: u64,
}

impl Hub {
    /// Sessions whose agent host is still running, by session id. Read at
    /// startup so their open turns are not marked lost.
    pub(super) fn live_host_sessions() -> std::collections::HashSet<String> {
        let dir = agent_host::hosts_dir();
        let Ok((good, bad)) = agent_host::load_records(&dir) else { return Default::default() };
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
            live.insert(b.session_id);
        }
        live
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
        // The harness exited and its host is finishing: wait (bounded) for
        // the host's lock to drop, then let the caller start a fresh agent.
        if let Some(record) = current
            .as_ref()
            .filter(|c| c.host_record().is_some() && !c.is_broken())
            .and_then(|c| c.host_record())
        {
            let dir = agent_host::hosts_dir();
            let waited = tokio::task::spawn_blocking(move || {
                agent_host::wait_dead(&dir, &record.session_id, &record.start_nonce)
            });
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), waited).await;
            return None;
        }
        if let Some(child) = current.filter(|c| c.is_broken()) {
            if let Err(e) = child.reattach().await {
                tracing::warn!(session = %session.id, "agent host reattach failed: {e:#}");
            }
            return Some(child);
        }
        let dir = agent_host::hosts_dir();
        let (good, _) = agent_host::load_records(&dir).ok()?;
        let (_, record) = good.into_iter().find(|(_, r)| r.session_id == session.id)?;
        if let Err(e) = self.adopt_one(session, record).await {
            tracing::warn!(session = %session.id, "agent host re-adoption failed: {e:#}");
        }
        session.child.lock().await.clone().filter(|c| c.host_record().is_some())
    }

    /// Whether a host for `session` may still run (a live or unproven record).
    pub(super) fn host_record_live(session_id: &str) -> bool {
        Self::live_host_sessions().contains(session_id)
    }

    /// Reattach every running agent host. Called once at daemon start,
    /// before agents may spawn.
    pub async fn adopt_agent_hosts(self: &Arc<Self>) {
        let dir = agent_host::hosts_dir();
        let (good, bad) = match agent_host::load_records(&dir) {
            Ok(records) => records,
            Err(e) => {
                tracing::warn!("agent hosts: {e:#}");
                return;
            }
        };
        for (_, record) in good {
            if agent_host::liveness(&dir, &record.session_id, &record.start_nonce) == Liveness::Dead
            {
                agent_host::remove_artifacts(&dir, &record);
                continue;
            }
            let Some(session) = self.session_by_id(&record.session_id) else {
                // A host for a session this daemon does not know (purged):
                // nothing can show it, so end it.
                let ended = end_host_blocking(
                    dir.clone(),
                    record.session_id.clone(),
                    Some(record.start_nonce.clone()),
                    Some(record.host_pid),
                )
                .await;
                if ended {
                    agent_host::remove_artifacts(&dir, &record);
                }
                continue;
            };
            if let Err(e) = self.adopt_one(&session, record).await {
                tracing::warn!(session = %session.id, "agent host adoption failed: {e:#}");
            }
        }
        for unreadable in bad {
            if let Some(session) = self.session_by_id(&unreadable.session_id) {
                self.mark_unadoptable(
                    &session,
                    json!({"recordVersion": unreadable.record_version, "reason": unreadable.reason}),
                );
            }
        }
    }

    /// End the host of a session that has no adopted child, when one runs
    /// (a host this build cannot adopt, or one whose link was lost).
    pub(super) async fn end_unadopted_host(&self, session: &Session) {
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

    fn mark_unadoptable(&self, session: &Arc<Session>, detail: Value) {
        self.append(session, "mux", "host_unadoptable", detail);
        self.set_status(session, SessionStatus::Disconnected);
        self.save_meta(session);
    }

    async fn adopt_one(
        self: &Arc<Self>,
        session: &Arc<Session>,
        record: agent_host::HostRecord,
    ) -> anyhow::Result<()> {
        let resume_after = self.last_host_seq(session, &record.incarnation);
        let tap = self.session_tap(session);
        let incarnation = record.incarnation.clone();
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
                self.mark_unadoptable(
                    session,
                    json!({"hostProtocol": [min, max], "hostBuild": host_build}),
                );
                return Ok(());
            }
        };
        *session.child.lock().await = Some(child.clone());
        if let Some(rx) = session.inbound_rx.lock().await.take() {
            let hub = self.clone();
            let s = session.clone();
            tokio::spawn(async move { hub.inbound_loop(s, rx).await });
        }
        // Scan only once every entry the host had is in the log: what the
        // previous daemon wrote or answered may still sit in its buffer.
        if !child.wait_logged(adopted.last_h, REPLAY_BUDGET).await {
            tracing::warn!(session = %session.id, "agent host replay incomplete; recovering from the partial log");
        }
        self.append(
            session,
            "mux",
            "host_adopted",
            json!({"incarnation": incarnation, "hostBuild": adopted.host_build, "resumedAfter": resume_after}),
        );
        self.set_status(session, SessionStatus::Ready);
        let mut work = self.open_work(session, &incarnation);
        // Requests after the resume point were replayed into the live
        // inbound loop and are handled there; only earlier ones were the
        // previous daemon's to answer.
        work.requests.retain(|(_, _, _, h)| h.is_none_or(|h| h <= resume_after));
        self.recover_work(session, &child, work).await;
        self.save_meta(session);
        Ok(())
    }

    /// Largest `hostSeq` logged under host `incarnation`.
    fn last_host_seq(&self, session: &Session, incarnation: &str) -> u64 {
        let mut last = 0;
        let mut current = false;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            if e.dir == "mux" && e.kind == "host_started" {
                current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                if current {
                    last = 0;
                }
            } else if current && let Some(h) = e.host_seq {
                last = last.max(h);
            }
            true
        });
        last
    }

    /// Scan the log for the work in flight under host `incarnation`. Agent
    /// requests, answers and permission records count only within this
    /// incarnation: every harness restarts its own request ids.
    fn open_work(&self, session: &Session, incarnation: &str) -> OpenWork {
        let mut work = OpenWork::default();
        let mut current = false;
        let mut requests: Vec<(Value, String, Option<Value>, Option<u64>)> = Vec::new();
        let mut answered: std::collections::HashSet<String> = Default::default();
        let mut asked: HashMap<String, (String, Value, Option<Value>)> = HashMap::new();
        let mut by_permission: HashMap<String, String> = HashMap::new();
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            match (e.dir.as_str(), e.kind.as_str()) {
                ("mux", "host_started") => {
                    current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                    // A new harness: its ids and answers start over.
                    requests.clear();
                    answered.clear();
                    asked.clear();
                    by_permission.clear();
                    work.prompt_request = None;
                    work.prompt_response = None;
                    work.last_host_seq = 0;
                }
                ("mux", "turn_started") => {
                    let field = |k: &str| {
                        e.msg.get(k).and_then(Value::as_str).unwrap_or_default().to_owned()
                    };
                    work.turn = Some((
                        e.seq,
                        field("turnId"),
                        field("promptId"),
                        field("prompt"),
                        field("client"),
                    ));
                    work.prompt_request = None;
                    work.prompt_response = None;
                }
                ("mux", "turn_result") => {
                    work.turn = None;
                    work.prompt_request = None;
                    work.prompt_response = None;
                }
                ("mux", "permission_request") if current => {
                    if let (Some(pid), Some(aid)) = (
                        e.msg.get("permissionId").and_then(Value::as_str),
                        e.msg.get("agentRequestId").filter(|v| !v.is_null()),
                    ) {
                        let request = e.msg.get("request").cloned().unwrap_or(Value::Null);
                        asked.insert(aid.to_string(), (pid.to_owned(), request, None));
                        by_permission.insert(pid.to_owned(), aid.to_string());
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
                    }
                }
                ("out", method::SESSION_PROMPT) if current && work.turn.is_some() => {
                    work.prompt_request = e.msg.get("id").cloned();
                }
                ("in", "response")
                    if current
                        && work.prompt_request.is_some()
                        && e.msg.get("id") == work.prompt_request.as_ref() =>
                {
                    work.prompt_response = Some(e.msg.clone());
                }
                ("out", "response") if current => {
                    if let Some(id) = e.msg.get("id") {
                        answered.insert(id.to_string());
                    }
                }
                ("in", kind)
                    if current && e.msg.get("id").is_some() && e.msg.get("method").is_some() =>
                {
                    let id = e.msg["id"].clone();
                    let params = e.msg.get("params").cloned();
                    requests.push((id, kind.to_owned(), params, e.host_seq));
                }
                _ => {}
            }
            if current && let Some(h) = e.host_seq {
                work.last_host_seq = work.last_host_seq.max(h);
            }
            true
        });
        work.requests = requests
            .into_iter()
            .filter(|(id, _, _, _)| !answered.contains(&id.to_string()))
            .collect();
        work.permissions = asked;
        work
    }

    /// Rebuild the turn and the unanswered agent requests of an adopted host.
    async fn recover_work(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        work: OpenWork,
    ) {
        if let Some((turn_seq, turn_id, prompt_id, prompt, client)) = work.turn.clone() {
            match (work.prompt_request.clone(), work.prompt_response.clone()) {
                // The prompt never reached this host (or another host ran
                // it): nothing can answer it any more.
                (None, _) => {
                    let error = "the agent host never received this turn's prompt";
                    self.append(session, "mux", "turn_result", json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "error": error, "errorText": error}));
                }
                (Some(request_id), answer) => {
                    *session.turn.lock().unwrap() = Some(TurnInfo {
                        started_at: now_ms(),
                        client,
                        prompt_preview: prompt,
                        turn_id: turn_id.clone(),
                        prompt_id: prompt_id.clone(),
                        turn_seq,
                    });
                    self.set_status(session, SessionStatus::Running);
                    // The answer is either logged already, or still to come
                    // (`await_response` also takes one that arrived first).
                    let rx = match answer {
                        Some(_) => None,
                        None => Some(child.await_response(request_id).await),
                    };
                    let hub = self.clone();
                    let s = session.clone();
                    let c = child.clone();
                    tokio::spawn(async move {
                        // New prompts queue behind the recovered turn.
                        let guard = s.turn_lock.lock().await;
                        let result = match (answer, rx) {
                            (Some(msg), _) => response_result(&msg),
                            (None, Some(rx)) => rx.await.unwrap_or_else(|_| {
                                Err(RpcError::internal("agent response channel dropped"))
                            }),
                            (None, None) => Err(RpcError::internal("agent answer lost")),
                        };
                        let _ =
                            hub.finish_turn(&s, &c, result, &prompt_id, &turn_id, turn_seq).await;
                        drop(guard);
                    });
                }
            }
        }
        let epoch = session.permission_epoch.load(Ordering::SeqCst);
        let turn_id = session.turn().map(|t| t.turn_id);
        for (id, m, params, _) in work.requests {
            if m == method::SESSION_REQUEST_PERMISSION
                && let Some((permission_id, request, decided)) =
                    work.permissions.get(&id.to_string()).cloned()
            {
                match decided {
                    // Decided but the answer never reached the agent: send it.
                    Some(outcome) => {
                        let _ = child.respond(id, Ok(permission_answer(outcome))).await;
                    }
                    None => self.reregister_permission(session, child, id, permission_id, request),
                }
                continue;
            }
            // Never answered and never asked: handle it as if it just came.
            let hub = self.clone();
            let s = session.clone();
            let turn_id = turn_id.clone();
            tokio::spawn(
                async move { hub.on_agent_request(s, id, m, params, epoch, turn_id).await },
            );
        }
    }

    /// A permission prompt the previous daemon showed: keep the same id so a
    /// client answers it as before, and answer the agent's original request.
    fn reregister_permission(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        agent_request_id: Value,
        permission_id: String,
        request: Value,
    ) {
        let (tx, rx) = oneshot::channel();
        session
            .permissions
            .lock()
            .unwrap()
            .pending
            .insert(permission_id.clone(), PendingPermission { request, reply: tx });
        self.set_status(session, SessionStatus::Waiting);
        let hub = self.clone();
        let s = session.clone();
        let c = child.clone();
        tokio::spawn(async move {
            let outcome = rx.await.unwrap_or_else(|_| json!({"outcome": "cancelled"}));
            hub.append(
                &s,
                "mux",
                "permission_decision",
                json!({"permissionId": permission_id, "outcome": outcome}),
            );
            {
                let state = s.permissions.lock().unwrap();
                if state.pending.is_empty() && s.status() == SessionStatus::Waiting {
                    let next = if s.turn().is_some() {
                        SessionStatus::Running
                    } else {
                        SessionStatus::Ready
                    };
                    hub.set_status(&s, next);
                }
            }
            let _ = c.respond(agent_request_id, Ok(permission_answer(outcome))).await;
        });
    }
}

/// The `session/request_permission` result for a logged outcome, shaped as
/// `handle_permission` shapes it (`_meta` lifted out of the outcome).
fn permission_answer(outcome: Value) -> Value {
    let mut out = json!({"outcome": outcome});
    if let Some(m) = out["outcome"].get("_meta").cloned() {
        out["_meta"] = m;
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
async fn end_host_blocking(
    dir: std::path::PathBuf,
    session_id: String,
    nonce: Option<String>,
    host_pid: Option<u32>,
) -> bool {
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
    pub fn enable_agent_hosts(&self) {
        self.agent_hosts.store(true, Ordering::SeqCst);
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
        let internal = |e: anyhow::Error| RpcError::internal(format!("{e:#}"));
        let cmd = crate::agent::harness_command(
            &meta.harness,
            profile,
            &meta.cwd,
            command_line,
            Some((&session.id, &meta.name)),
        )
        .map_err(internal)?;
        let std_cmd = cmd.as_std();
        let hosts = crate::agent_host::hosts_dir();
        let spec = crate::agent_host::SpawnSpec {
            session_id: session.id.clone(),
            program: std_cmd.get_program().to_string_lossy().into_owned(),
            args: std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect(),
            env: crate::agent::command_env(&cmd),
            cwd: meta.cwd.clone(),
            translator,
            socket: crate::agent_host::socket_path(&hosts, &session.id),
            hosts_dir: hosts,
            buffer_cap: crate::agent_host::DEFAULT_BUFFER_CAP,
        };
        let launcher = crate::agent_host::link::HostLauncher::current().map_err(internal)?;
        let record = crate::agent_host::link::spawn(&launcher, &spec).await.map_err(internal)?;
        // Logged before the first entry, so a later controller counts every
        // entry of this incarnation.
        self.append(
            session,
            "mux",
            "host_started",
            json!({"incarnation": record.incarnation, "hostPid": record.host_pid, "hostBuild": record.host_build}),
        );
        let attached = ChildAgent::attach_hosted(
            &meta.harness,
            record,
            0,
            Vec::new(),
            session.inbound_tx.clone(),
            tap,
        )
        .await
        .map_err(internal)?;
        let child = match attached {
            crate::agent::Attached::Ready(child, _, _) => child,
            crate::agent::Attached::Incompatible { .. } => {
                return Err(RpcError::internal("a host of this build refused its controller"));
            }
        };
        Ok(child)
    }
}
