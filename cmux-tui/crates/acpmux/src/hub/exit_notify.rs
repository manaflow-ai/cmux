//! Part of `Hub`; see `hub/mod.rs`. A closed session's exit record goes to the session that
//! started it, once (`exit_record.rs` has the record and why).
//!
//! On unless `ACPMUX_EXIT_RECORDS=0`. [`Hub::exit_record_soon`] runs inside the close
//! (`turns/close.rs`), after the close record is written and before the lane link is retired: it
//! reads the parent (the lane link's, else the first parent tag) and the pull requests the lane's
//! reports named, then hands delivery to the hub's scope. Delivery walks up past closed parents
//! (each one's own parent tag, at most `MAX_HOPS`) to the first open one and puts one hub-set
//! prompt in its chat, steered into a running turn: `{kind: "exit_record", from, fromName, to,
//! via, class, record}`. The prompt id is the same for every try, so a retry never doubles it;
//! an accepted one writes `mux/exit_told` to the closed chat's log. Not sent:
//!
//! - when the parent itself closed it (it knows);
//! - when no parent is named or every one up the chain is closed (logged);
//! - when the parent is on a peer (logged; a follow-up sends it through the outbox).
//!
//! With `ACPMUX_SUPERVISOR_ACT=1` (default off) a crash's supervisor decision is acted on
//! (`supervisor.rs`): `restart` sends the closed chat one hub-set prompt after
//! [`RESTART_AFTER`] ([`Hub::supervisor_restart`]); `escalate` and `restart` add a line to the
//! record the parent gets saying what acpmux did.

use super::*;
use crate::close_why::CloseRecord;
use crate::exit_record::{ExitRecord, KIND, MAX_HOPS, parent_tag};

/// Tries of one delivery, waiting this long before each retry.
const RETRY_SECS: &[u64] = &[2, 5, 15, 60];

/// How long a restart waits after the close, so the close's own steps (the lane link's retire)
/// finish before the chat reopens.
const RESTART_AFTER: std::time::Duration = std::time::Duration::from_secs(2);

/// Where an exit record goes: the open parent, and the closed ones it passed on the way.
pub(super) struct Route {
    pub(super) to: Arc<Session>,
    pub(super) via: Vec<String>,
}

impl Hub {
    /// Captures what the close of `session` hands its parent and sends it in the background
    /// (module docs). Call before `lane_retire`.
    pub(super) fn exit_record_soon(&self, session: &Arc<Session>, close: CloseRecord) {
        if !crate::exit_record::enabled() {
            return;
        }
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        let link = self.lane_links(|links| {
            links.get(&session.id).map(|l| (l.parent.clone(), Self::lane_link_prs(l)))
        });
        let (link_parent, prs) = link.map_or((None, vec![]), |(p, prs)| (Some(p), prs));
        let record = session.read_meta(|m| ExitRecord::new(m, close, prs));
        let first = link_parent.or_else(|| session.read_meta(parent_tag));
        use crate::supervisor as sup;
        let acts = sup::acts() && sup::acts_on(&record);
        let decision = (sup::enabled() || acts)
            .then(|| self.supervisor_log(session, &record, first.as_deref()))
            .filter(|_| acts);
        let note = decision.as_ref().and_then(sup::Decision::parent_note);
        if let Some(sup::Decision::Restart { .. }) = decision {
            let (hub, session, record) = (hub.clone(), session.clone(), record.clone());
            self.scope.spawn_until_cancelled("supervisor-restart", async move {
                tokio::time::sleep(RESTART_AFTER).await;
                hub.supervisor_restart(&session, &record).await;
            });
        }
        let Some(first) = first else { return };
        self.scope.spawn_until_cancelled("exit-record", async move {
            hub.exit_record_deliver(&record, &first, note.as_deref()).await;
        });
    }

    /// Logs what the supervisor would do about this exit (`supervisor.rs`) next to its record:
    /// `mux/supervisor_decision` in the ended chat, and returns it. Its
    /// earlier restarts are the decisions to restart it logged in the window; its tokens are the
    /// newest `usage_update`'s `used`.
    fn supervisor_log(
        &self,
        session: &Arc<Session>,
        record: &ExitRecord,
        parent: Option<&str>,
    ) -> crate::supervisor::Decision {
        use crate::supervisor::{self as sup, Intensity, Restart};
        let limit = Intensity::default();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        let since = now.saturating_sub(limit.window_ms);
        let (mut tokens, mut restarts) = (None::<u64>, Vec::new());
        let wanted = [b"usage_update".as_slice(), sup::KIND.as_bytes()];
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|_, kind| !wanted.contains(&kind),
            &mut |e: EventRecord| {
                if e.at < since {
                    return false;
                }
                if e.kind == "usage_update" && tokens.is_none() {
                    tokens = e.msg.pointer("/params/update/used").and_then(Value::as_u64);
                } else if e.kind == sup::KIND
                    && e.msg.pointer("/decision/action").and_then(Value::as_str) == Some("restart")
                {
                    let t = e.msg.get("tokens").and_then(Value::as_u64).unwrap_or(0);
                    restarts.push(Restart { at_ms: e.at, tokens: t });
                }
                true
            },
        );
        let tokens = tokens.unwrap_or(0);
        let decision = sup::decide(record, now, tokens, &restarts, limit, parent);
        let restart = sup::restart_type(record);
        tracing::info!(session = %record.session, name = %record.name,
            class = record.class.as_str(), ?restart, ?decision, "supervisor decision");
        self.append(
            session,
            "mux",
            sup::KIND,
            json!({"restart": restart, "decision": decision, "tokens": tokens,
                   "restartsInWindow": restarts.len(), "limit": limit,
                   "promptId": record.prompt_id()}),
        );
        decision
    }

    /// Restarts `session`, closed by a crash, as its supervisor decided: one hub-set prompt in
    /// its chat reopens it and resumes its agent from the transcript, as any prompt does. Its id
    /// is the exit record's with `~restart`, so a second try never doubles it. Logged
    /// `mux/supervisor_restart` before it is sent, and `mux/supervisor_restart_failed` with the
    /// error when it is refused. Skipped when the chat opened again, is being deleted or moved.
    pub(super) async fn supervisor_restart(
        self: &Arc<Self>,
        session: &Arc<Session>,
        record: &ExitRecord,
    ) {
        use crate::supervisor as sup;
        if session.status() != SessionStatus::Closed
            || session.purging.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.meta().moved_to.is_some()
        {
            tracing::info!(session = %record.session, "supervisor restart skipped: not closed here");
            return;
        }
        let prompt_id = format!("{}~restart", record.prompt_id());
        self.append(
            session,
            "mux",
            sup::RESTART_KIND,
            json!({"promptId": prompt_id, "transcript": record.transcript,
                   "class": record.class.as_str()}),
        );
        let provenance = json!({"kind": sup::RESTART_KIND, "promptId": record.prompt_id(),
                                "class": record.class.as_str(), "transcript": record.transcript});
        let opts = PromptOptions {
            prompt_id: Some(prompt_id),
            resend: true,
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": sup::restart_text(record)})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", true, opts).await
            && !e.data.as_ref().is_some_and(|d| d["held"] == true)
        {
            tracing::warn!(session = %record.session, "supervisor restart refused: {}", e.message);
            self.append(session, "mux", "supervisor_restart_failed", json!({"error": e.message}));
        }
    }

    /// The open session an exit record of `from` goes to, starting at the parent `first` names
    /// and walking up past closed ones. None when the chain has no open session here.
    pub(super) fn exit_route(&self, from: &str, first: &str) -> Result<Route, &'static str> {
        let mut key = first.to_owned();
        let mut via: Vec<String> = vec![];
        let mut seen = std::collections::HashSet::from([from.to_owned()]);
        for _ in 0..=MAX_HOPS {
            let found = self.session_get(&key).or_else(|| self.resolve(&key).ok());
            let Some(s) = found else {
                return Err(if key.contains('/') {
                    "its parent is on another machine"
                } else {
                    "its parent is gone"
                });
            };
            if !seen.insert(s.id.clone()) {
                return Err("its parents loop");
            }
            if s.status() != SessionStatus::Closed && !s.purged.load(Ordering::SeqCst) {
                return Ok(Route { to: s, via });
            }
            via.push(s.read_meta(|m| m.name.clone()));
            let Some(up) = s.read_meta(parent_tag) else {
                return Err("every parent up its chain is closed");
            };
            key = up;
        }
        Err("its parents run deeper than the walk")
    }

    /// `note` is what acpmux did about the exit (the supervisor's restart or escalation), added
    /// to the text and the provenance.
    pub(super) async fn exit_record_deliver(
        self: &Arc<Self>,
        record: &ExitRecord,
        first: &str,
        note: Option<&str>,
    ) {
        let route = match self.exit_route(&record.session, first) {
            Ok(r) => r,
            Err(why) => {
                tracing::info!(session = %record.session, name = %record.name, parent = %first,
                    class = record.class.as_str(), "exit record not delivered: {why}");
                return;
            }
        };
        // The parent closed it itself: it knows.
        if route.via.is_empty() && record.close.actor.session.as_deref() == Some(&route.to.id) {
            return;
        }
        let mut waits = RETRY_SECS.iter();
        loop {
            match self.exit_record_to(&route, record, note).await {
                Ok(()) => {
                    tracing::info!(session = %record.session, name = %record.name,
                        to = %route.to.id, via = ?route.via, class = record.class.as_str(),
                        "exit record delivered to its parent");
                    if let Some(closed) = self.session_get(&record.session) {
                        self.append(
                            &closed,
                            "mux",
                            "exit_told",
                            json!({"to": route.to.id, "via": route.via,
                                   "promptId": record.prompt_id()}),
                        );
                    }
                    return;
                }
                Err(e) => match waits.next() {
                    Some(secs) => tokio::time::sleep(std::time::Duration::from_secs(*secs)).await,
                    None => {
                        tracing::warn!(session = %record.session, to = %route.to.id,
                            "exit record not delivered after {} tries: {}",
                            RETRY_SECS.len() + 1, e.message);
                        return;
                    }
                },
            }
        }
    }

    /// Puts `record` in `route.to`'s chat as a hub-set prompt; done once it is accepted.
    async fn exit_record_to(
        self: &Arc<Self>,
        route: &Route,
        record: &ExitRecord,
        note: Option<&str>,
    ) -> Result<(), RpcError> {
        let p = route.to.clone();
        let mut provenance = json!({
            "kind": KIND, "from": record.session, "fromName": record.name, "to": p.id,
            "via": route.via, "class": record.class.as_str(),
            "record": serde_json::to_value(record).unwrap_or_default(),
        });
        let mut text = record.text(&route.via);
        if let Some(note) = note {
            provenance["supervisor"] = json!(note);
            text.push(' ');
            text.push_str(note);
        }
        let blocks = vec![json!({"type": "text", "text": text})];
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(record.prompt_id()),
            resend: true,
            provenance: Some(provenance),
            agent: Some(record.name.clone()),
            class: Some(crate::prompt_class::PromptClass::Result),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let hub = self.clone();
        // The hub's scope owns the prompt: it ends with the daemon.
        let run = self.scope.spawn_named("exit-record-notice", async move {
            hub.prompt_with(&p, blocks, "acpmux", true, opts).await
        });
        if rx.await.is_ok() {
            return Ok(());
        }
        match run.await {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(e)) if e.data.as_ref().is_some_and(|d| d["held"] == true) => Ok(()),
            Ok(Err(e)) => Err(e),
            Err(e) => Err(RpcError::internal(e.to_string())),
        }
    }
}
