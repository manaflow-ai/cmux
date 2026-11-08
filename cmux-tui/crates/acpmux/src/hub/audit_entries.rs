//! Part of `Hub`; see `hub/mod.rs`. What each settled answer writes to the approvals audit
//! trail (`audit_log.rs`), and the review index's view of the records that ask and answer
//! (`review_queue.rs`). Called from `Hub::append_record_locked` for every stored record, under
//! the session's append lock: each step is a map update or a channel send, never a write.

use super::review_queue::{ASK_CHARS, Ask, Kind, Settled, ask_text, line, vendor};
use super::*;
use cmux_json::JsonSet as _;

/// The most characters of a Request changes comment the audit entry keeps (masked first).
pub(crate) const COMMENT_CHARS: usize = 4000;

/// How long a purge waits for the audit log's rewrite.
const AUDIT_PURGE_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// What an answer decided: `allow`, `deny`, `answer` (a question's allow with answers) or
/// `cancel` (someone dismissed it), and the option it picked. None for a prompt nobody answered:
/// withdrawn by its agent, or cancelled by a turn's stop or the shutdown.
pub(crate) fn decision(
    kind: Kind,
    request: &Value,
    msg: &Value,
    settled_by: Option<Settled>,
) -> Option<(Option<String>, &'static str)> {
    let outcome = &msg["outcome"];
    if outcome["outcome"].as_str() != Some("selected") {
        // A cancel counts when someone is named as its answerer or its caller dismissed it.
        let named = msg.get("answeredBy").is_some_and(|b| !b.is_null());
        return (named || settled_by == Some(Settled::Caller)).then_some((None, "cancel"));
    }
    let option = outcome["optionId"].as_str().map(str::to_owned);
    let option_kind = request["options"].as_array().into_iter().flatten().find_map(|o| {
        (o["optionId"].as_str() == option.as_deref()).then(|| o["kind"].as_str()).flatten()
    });
    let decided = match option_kind {
        Some("reject_once" | "reject_always") => "deny",
        _ if kind == Kind::Question && outcome.pointer("/_meta/updatedInput/answers").is_some() => {
            "answer"
        }
        _ => "allow",
    };
    Some((option, decided))
}

/// The one-line ask of a queued prompt from its whole text: masked before it is cut, so a
/// secret the cut would go through is still found whole.
pub(crate) fn queued_ask(text: &str) -> String {
    line(super::inbox::relay_body(text), ASK_CHARS)
}

/// `answeredBy` of an entry from a decision record's own `answeredBy`: `person` only for an
/// allow or an answer, which pass the person rule (`respond_permission`), never for an
/// ancestor session's answer (`{session, name}`, `subsession_answer.rs`), and never for one
/// that settled by itself after a policy or mode switch (`via: policy|mode`).
pub(crate) fn answered_by(decided: &str, by: Option<&Value>, settled_by: Option<Settled>) -> Value {
    if let Some(Settled::Auto(via)) = settled_by {
        return json!({"person": false, "via": via});
    }
    let ancestor = by.and_then(|b| b.get("session")).is_some();
    let mut out = json!({"person": matches!(decided, "allow" | "answer") && !ancestor});
    if ancestor {
        out.set("via", json!("ancestor"));
    }
    for key in ["device", "feedItem"] {
        if let Some(v) = by.and_then(|b| b.get(key)).and_then(Value::as_str) {
            out.set(key, json!(v));
        }
    }
    if out.get("device").is_some() && !ancestor {
        out.set("via", json!("device"));
    }
    out
}

impl Hub {
    /// One stored record of `session`, for the review index and the audit trail.
    pub(super) fn observe_for_review(&self, session: &Session, record: &EventRecord) {
        // A purged chat (an incognito space's) leaves no history.
        if record.dir != "mux" || session.purged.load(Ordering::SeqCst) {
            return;
        }
        match record.kind.as_str() {
            "permission_request" | "permission_reissued" => {
                self.review_index.note_ask(&session.id, &record.msg, record.at)
            }
            "permission_decision" => {
                let Some(id) = record.msg.get("permissionId").and_then(Value::as_str) else {
                    return;
                };
                let Some(ask) = self.review_index.take_ask(&session.id, id) else { return };
                if let Some(entry) = self.decision_entry(session, id, &ask, &record.msg, record.at)
                {
                    self.audit.record(entry);
                }
            }
            _ => {}
        }
    }

    /// The fields of an entry about `session`: `{at, sessionId, harness, vendor}`.
    fn entry_base(&self, session: &Session, at: u64) -> Value {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let model = current_model(&m);
        json!({"at": at, "sessionId": session.id, "harness": m.harness,
               "vendor": vendor(m.family.as_deref(), &m.harness, model.as_deref())})
    }

    fn decision_entry(
        &self,
        session: &Session,
        permission_id: &str,
        ask: &Ask,
        msg: &Value,
        at: u64,
    ) -> Option<Value> {
        let kind = Kind::of(&ask.request);
        let (option, decided) = decision(kind, &ask.request, msg, ask.settled_by)?;
        let mut entry = self.entry_base(session, at);
        entry.set("kind", json!(kind.as_str()));
        entry.set("permissionId", json!(permission_id));
        entry.set("ask", json!(ask_text(kind, &ask.request)));
        entry.set(
            "decision",
            match option {
                Some(o) => json!({"optionId": o, "kind": decided}),
                None => json!({"kind": decided}),
            },
        );
        entry.set("answeredBy", answered_by(decided, msg.get("answeredBy"), ask.settled_by));
        Some(entry)
    }

    /// `session` is being purged: its audit entries leave the log (`audit_log.rs`), waited for
    /// up to [`AUDIT_PURGE_WAIT`]. An error fails the purge (`Hub::kill`), so the chat is not
    /// reported deleted while its history is still on disk.
    pub(super) async fn audit_purge(&self, session_id: &str) -> Result<(), RpcError> {
        let fail = |why: &str| {
            tracing::warn!(session = %session_id, "audit: purge failed: {why}");
            Err(RpcError::internal(format!("audit: the chat's entries were not removed: {why}")))
        };
        match self.audit.purge_within(session_id, AUDIT_PURGE_WAIT).await {
            Ok(_) => Ok(()),
            Err(why) => fail(&why),
        }
    }

    /// A queued prompt its owner approved (`allow`, from `control`) or declined (`deny`).
    pub(super) fn audit_queued(
        &self,
        session: &Session,
        prompt_id: &str,
        text: &str,
        approved: bool,
        control: Option<Control>,
    ) {
        if session.purged.load(Ordering::SeqCst) {
            return;
        }
        let mut entry = self.entry_base(session, now_ms());
        entry.set("kind", json!("queued"));
        entry.set("promptId", json!(prompt_id));
        entry.set("ask", json!(queued_ask(text)));
        entry.set("decision", json!({"kind": if approved { "allow" } else { "deny" }}));
        entry.set(
            "answeredBy",
            match control {
                Some(c) => json!({"person": false, "via": c.as_str()}),
                None => json!({"person": false}),
            },
        );
        self.audit.record(entry);
    }

    /// `_acpmux/review_verdict` from the person's connection: the pull request at `url`, one
    /// `session` opened, is accepted or needs changes, and leaves that session's review queue.
    /// A Request changes `comment` is kept in the entry's decision, its secrets masked and cut
    /// at [`COMMENT_CHARS`] (the chat gets it whole: `server/review_queue.rs`).
    /// Blocking: returns once the entry is on disk, and fails (the pull request stays queued)
    /// when it could not be written.
    pub(crate) fn record_review_verdict(
        &self,
        session: &Session,
        url: &str,
        accepted: bool,
        comment: Option<&str>,
        from_app: bool,
    ) -> Result<Value, RpcError> {
        if session.purged.load(Ordering::SeqCst) {
            return Err(RpcError::invalid_params(format!("session {} was purged", session.id)));
        }
        if !session.meta().pull_requests.iter().any(|u| u == url) {
            return Err(RpcError::invalid_params(format!(
                "session {} opened no pull request {url}",
                session.id
            )));
        }
        let mut entry = self.entry_base(session, now_ms());
        entry.set("kind", json!("review"));
        entry.set("prUrl", json!(url));
        entry.set("ask", json!(line(&format!("Review {url}"), ASK_CHARS)));
        let mut decision = json!({"kind": if accepted { "accept" } else { "changes" }});
        if let Some(comment) = comment {
            let masked = crate::secret_scan::mask(comment);
            let mut kept: String = masked.chars().take(COMMENT_CHARS).collect();
            if kept.len() < masked.len() {
                kept.push('…');
            }
            decision.set("comment", json!(kept));
        }
        entry.set("decision", decision);
        entry.set(
            "answeredBy",
            json!({"person": true, "via": if from_app { "app" } else { "local" }}),
        );
        self.audit
            .record_durable(entry)
            .map_err(|e| RpcError::internal(format!("audit: the verdict was not recorded: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool() -> Value {
        json!({"toolCall": {"kind": "execute", "title": "Run ls"},
               "options": [{"optionId": "ok", "name": "Allow", "kind": "allow_once"},
                           {"optionId": "no", "name": "Deny", "kind": "reject_once"}]})
    }

    #[test]
    fn a_decision_reads_allow_deny_answer_or_nothing() {
        let selected = |o: &str| json!({"outcome": {"outcome": "selected", "optionId": o}});
        assert_eq!(
            decision(Kind::Approval, &tool(), &selected("ok"), None),
            Some((Some("ok".into()), "allow"))
        );
        assert_eq!(
            decision(Kind::Approval, &tool(), &selected("no"), None),
            Some((Some("no".into()), "deny"))
        );
        let answered = json!({"outcome": {"outcome": "selected", "optionId": "ok",
                                          "_meta": {"updatedInput": {"answers": {"q": "a"}}}}});
        assert_eq!(
            decision(Kind::Question, &tool(), &answered, None),
            Some((Some("ok".into()), "answer"))
        );
        let cancelled = json!({"outcome": {"outcome": "cancelled"}});
        // Withdrawn, or cancelled by a stop or the shutdown: nobody answered.
        assert_eq!(decision(Kind::Approval, &tool(), &cancelled, None), None);
        // Its caller dismissed it (a question skipped that has no reject option).
        assert_eq!(
            decision(Kind::Question, &tool(), &cancelled, Some(Settled::Caller)),
            Some((None, "cancel"))
        );
        let by = json!({"outcome": {"outcome": "cancelled"}, "answeredBy": {"device": "phone"}});
        assert_eq!(decision(Kind::Approval, &tool(), &by, None), Some((None, "cancel")));
    }

    #[test]
    fn only_a_persons_allow_or_answer_is_marked_theirs() {
        assert_eq!(answered_by("allow", None, None), json!({"person": true}));
        assert_eq!(answered_by("deny", None, None), json!({"person": false}));
        let device = json!({"device": "iphone", "feedItem": "f1"});
        assert_eq!(
            answered_by("allow", Some(&device), None),
            json!({"person": true, "device": "iphone", "feedItem": "f1", "via": "device"})
        );
        let ancestor = json!({"session": "parent", "name": "lead"});
        assert_eq!(
            answered_by("answer", Some(&ancestor), None),
            json!({"person": false, "via": "ancestor"})
        );
        // Allowed by itself after a switch to full access or approve-all: never the person's.
        assert_eq!(
            answered_by("allow", None, Some(Settled::Auto("mode"))),
            json!({"person": false, "via": "mode"})
        );
        assert_eq!(
            answered_by("allow", None, Some(Settled::Auto("policy"))),
            json!({"person": false, "via": "policy"})
        );
    }

    #[test]
    fn a_queued_ask_masks_a_secret_the_preview_cut_goes_through() {
        // The token starts at char 190: the 200-char preview would keep only its head.
        let token = "ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k";
        let text = format!("{} {token} and more words after it", "x".repeat(189));
        let ask = queued_ask(&text);
        assert!(!ask.contains("aZ3kQ9"), "{ask}");
        // The cut keeps ASK_CHARS and marks itself with an ellipsis.
        assert!(ask.chars().count() <= ASK_CHARS + 1, "{ask}");
    }
}
