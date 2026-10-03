//! Part of `Hub`; see `hub/mod.rs`. Adopting agent hosts after a daemon
//! restart or upgrade (plans/cmux-next/durable-sessions.md 2.5): reattach,
//! resume the host's entries after the last one logged, and rebuild the turn
//! and permission state that died with the previous daemon.

use super::*;
use crate::agent::Attached;
use crate::agent_host::{self, Liveness};

/// What the session log says about the work in flight when the previous
/// controller stopped.
#[derive(Debug, Default)]
struct OpenWork {
    /// `turn_started` without `turn_result`: (seq, turnId, promptId, prompt, client).
    turn: Option<(u64, String, String, String, String)>,
    /// The `session/prompt` request id written for that turn, and its
    /// response when it is already logged.
    prompt_request: Option<Value>,
    prompt_response: Option<Value>,
    /// Agent requests with no logged answer: (id, method, params).
    requests: Vec<(Value, String, Option<Value>)>,
    /// `permission_request` records with no decision, by agent request id:
    /// (permissionId, request).
    permissions: HashMap<String, (String, Value)>,
    /// Largest `hostSeq` logged under the host incarnation being adopted.
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
        live.extend(bad.into_iter().map(|b| b.session_id));
        live
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
                let _ = agent_host::terminate_unadoptable(
                    &dir,
                    &record.session_id,
                    Some(&record.start_nonce),
                    Some(record.host_pid),
                    record.harness_pid,
                );
                agent_host::remove_artifacts(&dir, &record);
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

    /// End the host of a session that has no adopted child, when one runs.
    pub(super) fn end_unadopted_host(&self, session: &Session) {
        let dir = agent_host::hosts_dir();
        let Ok((good, bad)) = agent_host::load_records(&dir) else { return };
        let host = good
            .iter()
            .find(|(_, r)| r.session_id == session.id)
            .map(|(_, r)| (Some(r.start_nonce.clone()), Some(r.host_pid), r.harness_pid))
            .or_else(|| {
                bad.iter()
                    .find(|b| b.session_id == session.id)
                    .map(|b| (b.start_nonce.clone(), b.host_pid, b.harness_pid))
            });
        let Some((nonce, host_pid, harness_pid)) = host else { return };
        match agent_host::terminate_unadoptable(
            &dir,
            &session.id,
            nonce.as_deref(),
            host_pid,
            harness_pid,
        ) {
            Ok(true) => {
                if let Some((_, record)) = good.iter().find(|(_, r)| r.session_id == session.id) {
                    agent_host::remove_artifacts(&dir, record);
                }
                self.append(session, "mux", "host_ended", json!({}));
            }
            Ok(false) | Err(_) => {
                tracing::warn!(session = %session.id, "could not end its unadopted agent host");
            }
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
        let work = self.open_work(session, &record.incarnation);
        let tap = self.session_tap(session);
        let incarnation = record.incarnation.clone();
        // The open turn's answer may already sit in the host's buffer.
        let awaiting = match (&work.turn, &work.prompt_request, &work.prompt_response) {
            (Some(_), Some(id), None) => vec![id.clone()],
            _ => Vec::new(),
        };
        let attached = ChildAgent::attach_hosted(
            &session.meta().harness,
            record,
            work.last_host_seq,
            awaiting,
            session.inbound_tx.clone(),
            tap,
        )
        .await?;
        let (child, adopted, mut responses) = match attached {
            Attached::Ready(child, adopted, responses) => (child, adopted, responses),
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
        self.append(
            session,
            "mux",
            "host_adopted",
            json!({"incarnation": incarnation, "hostBuild": adopted.host_build, "resumedAfter": work.last_host_seq}),
        );
        self.set_status(session, SessionStatus::Ready);
        self.recover_work(session, &child, work, responses.pop()).await;
        self.save_meta(session);
        Ok(())
    }

    /// Scan the log for the work in flight under host `incarnation`.
    fn open_work(&self, session: &Session, incarnation: &str) -> OpenWork {
        let mut work = OpenWork::default();
        let mut in_incarnation = false;
        // Agent requests and the ids answered, in log order.
        let mut requests: Vec<(Value, String, Option<Value>)> = Vec::new();
        let mut answered: std::collections::HashSet<String> = Default::default();
        let mut decided: std::collections::HashSet<String> = Default::default();
        let mut asked: HashMap<String, (String, Value)> = HashMap::new();
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            match (e.dir.as_str(), e.kind.as_str()) {
                ("mux", "host_started") => {
                    in_incarnation = e.msg.get("incarnation").and_then(Value::as_str)
                        == Some(incarnation);
                    if in_incarnation {
                        work.last_host_seq = 0;
                    }
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
                ("mux", "permission_request") => {
                    if let (Some(pid), Some(aid)) = (
                        e.msg.get("permissionId").and_then(Value::as_str),
                        e.msg.get("agentRequestId").filter(|v| !v.is_null()),
                    ) {
                        let request = e.msg.get("request").cloned().unwrap_or(Value::Null);
                        asked.insert(aid.to_string(), (pid.to_owned(), request));
                    }
                }
                ("mux", "permission_decision") => {
                    if let Some(pid) = e.msg.get("permissionId").and_then(Value::as_str) {
                        decided.insert(pid.to_owned());
                    }
                }
                // Only work handed to this host can still be answered by it.
                ("out", method::SESSION_PROMPT) if work.turn.is_some() && in_incarnation => {
                    work.prompt_request = e.msg.get("id").cloned();
                }
                ("in", "response") => {
                    if work.prompt_request.is_some() && e.msg.get("id") == work.prompt_request.as_ref() {
                        work.prompt_response = Some(e.msg.clone());
                    }
                }
                ("out", "response") => {
                    if let Some(id) = e.msg.get("id") {
                        answered.insert(id.to_string());
                    }
                }
                ("in", kind)
                    if in_incarnation
                        && e.msg.get("id").is_some()
                        && e.msg.get("method").is_some() =>
                {
                    let id = e.msg["id"].clone();
                    let params = e.msg.get("params").cloned();
                    requests.push((id, kind.to_owned(), params));
                }
                _ => {}
            }
            if in_incarnation && let Some(h) = e.host_seq {
                work.last_host_seq = work.last_host_seq.max(h);
            }
            true
        });
        work.requests =
            requests.into_iter().filter(|(id, _, _)| !answered.contains(&id.to_string())).collect();
        work.permissions =
            asked.into_iter().filter(|(_, (pid, _))| !decided.contains(pid)).collect();
        work
    }

    /// Rebuild the turn and the unanswered agent requests of an adopted host.
    async fn recover_work(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        work: OpenWork,
        prompt_answer: Option<crate::agent::Response>,
    ) {
        // The turn first, so a re-registered permission sees it.
        if let (Some((turn_seq, turn_id, prompt_id, prompt, client)), Some(_)) =
            (work.turn.clone(), work.prompt_request.clone())
        {
            *session.turn.lock().unwrap() = Some(TurnInfo {
                started_at: now_ms(),
                client,
                prompt_preview: prompt,
                turn_id: turn_id.clone(),
                prompt_id: prompt_id.clone(),
                turn_seq,
            });
            self.set_status(session, SessionStatus::Running);
            let response = match work.prompt_response.clone() {
                // The answer reached the log before the old daemon settled it.
                Some(msg) => Box::pin(async move { response_result(&msg) })
                    as std::pin::Pin<
                        Box<dyn std::future::Future<Output = Result<Value, RpcError>> + Send>,
                    >,
                None => {
                    let rx = prompt_answer;
                    Box::pin(async move {
                        match rx {
                            Some(rx) => rx.await.unwrap_or_else(|_| {
                                Err(RpcError::internal("agent response channel dropped"))
                            }),
                            None => Err(RpcError::internal("agent response was not awaited")),
                        }
                    })
                }
            };
            let hub = self.clone();
            let s = session.clone();
            let c = child.clone();
            tokio::spawn(async move {
                // New prompts queue behind the recovered turn.
                let guard = s.turn_lock.lock().await;
                let result = response.await;
                let _ = hub.finish_turn(&s, &c, result, &prompt_id, &turn_id, turn_seq).await;
                drop(guard);
            });
        }
        let epoch = session.permission_epoch.load(Ordering::SeqCst);
        let turn_id = session.turn().map(|t| t.turn_id);
        for (id, m, params) in work.requests {
            if m == method::SESSION_REQUEST_PERMISSION
                && let Some((permission_id, request)) = work.permissions.get(&id.to_string()).cloned()
            {
                self.reregister_permission(session, child, id, permission_id, request);
                continue;
            }
            // Never answered and never asked: handle it as if it just came.
            let hub = self.clone();
            let s = session.clone();
            let turn_id = turn_id.clone();
            tokio::spawn(async move { hub.on_agent_request(s, id, m, params, epoch, turn_id).await });
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
                    let next =
                        if s.turn().is_some() { SessionStatus::Running } else { SessionStatus::Ready };
                    hub.set_status(&s, next);
                }
            }
            let mut out = json!({"outcome": outcome});
            if let Some(m) = out["outcome"].get("_meta").cloned() {
                out["_meta"] = m;
                if let Some(o) = out["outcome"].as_object_mut() {
                    o.remove("_meta");
                }
            }
            let _ = c.respond(agent_request_id, Ok(out)).await;
        });
    }
}

fn response_result(msg: &Value) -> Result<Value, RpcError> {
    match msg.get("error") {
        Some(e) if !e.is_null() => Err(serde_json::from_value(e.clone())
            .unwrap_or_else(|_| RpcError::internal("agent error"))),
        _ => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
    }
}
