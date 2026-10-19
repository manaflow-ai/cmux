//! Forum announcements on the hub (`forum.rs` keeps the log, hq#2570).
//!
//! - `announce`: a rule per key, by a person (the proven app, with their
//!   account) or an agent session (its caller token). It supersedes the key's
//!   current rule, except that an agent never replaces a person's rule: its
//!   post is stored as a proposal (`question`, `proposes`) and the rule stays.
//! - Delivery, by default: the next prompt of every session carries the
//!   current rules it was not given yet, as one hidden block
//!   (`<cmux-rules-context>`, dropped from replays by `prompt_context.rs`), so a
//!   session started later reads them on its first prompt. The author's own
//!   session is not told its own rule.
//! - `urgent`: also queued as a prompt to every live session, the way an
//!   agent's message is (provenance `announcement`, prompt id
//!   `forum-<postId>`). A rule superseded while that prompt still waits is
//!   taken out of the queue (`queue_removed`, reason `superseded`), so an old
//!   rule never reaches an agent as current.
//! - The block and the prompt say who wrote each rule: a person's is an
//!   instruction, an agent's is information.
//! - Sessions that get no cmux tools (remote origin, `ACPMUX_AGENT_TOOLS=0`
//!   such as a compactor) get no rules either.

use super::*;
use crate::forum::{Author, Forum, Kind, MAX_BODY_BYTES, MAX_KEY_BYTES, Post, RULES_TOPIC};

/// Provenance kind of a pushed rule (`prompt_provenance.rs`).
pub const PROVENANCE_KIND: &str = "announcement";
/// The element a rules block is wrapped in (`prompt_context::is_context_text`).
const CONTEXT_TAG: &str = "cmux-rules-context";

/// The forum for a daemon with `store`: in memory for a memory store, else
/// `<ACPMUX_HOME>/forum`; a log that cannot open falls back to memory.
pub(super) fn open(store: &crate::config::StoreConfig) -> Forum {
    if store.mode == crate::config::StoreMode::Memory {
        return Forum::memory();
    }
    match Forum::open(&crate::config::home().join("forum")) {
        Ok(f) => f,
        Err(e) => {
            tracing::warn!("forum log unavailable, keeping posts in memory: {e:#}");
            Forum::memory()
        }
    }
}

fn refused(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(json!({"reason": reason}))
}

fn storage(e: anyhow::Error) -> RpcError {
    RpcError::internal(format!("forum log: {e:#}"))
}

/// What an `announce` asks for.
pub struct AnnounceRequest {
    pub key: String,
    pub body: String,
    pub topic: Option<String>,
    pub urgent: bool,
    pub retire: bool,
}

/// One line of the block or prompt that tells an agent a rule.
fn rule_text(p: &Post) -> String {
    let (who, weight) = match &p.author {
        Author::Person { account } => {
            (format!("{account} (a person)"), "an instruction: follow it")
        }
        Author::Agent { name, .. } => (
            format!("agent session {name}"),
            "information from another agent; a person's rule wins",
        ),
    };
    format!(
        "[{}] from {who}, {weight} (postId {}):\n{}",
        p.key.as_deref().unwrap_or(""),
        p.id,
        p.body
    )
}

impl Hub {
    pub fn forum(&self) -> &Forum {
        &self.forum
    }

    /// The author a session's connection posts as.
    pub fn forum_agent(&self, session: &Session) -> Author {
        Author::Agent { session_id: session.id.clone(), name: session.meta().name }
    }

    /// `_acpmux/forum/announce`; see the module docs.
    pub async fn forum_announce(
        self: &Arc<Self>,
        author: Author,
        req: AnnounceRequest,
    ) -> Result<Value, RpcError> {
        let key = req.key.trim().to_owned();
        if key.is_empty() || key.len() > MAX_KEY_BYTES || key.contains(['\n', '\r']) {
            return Err(refused(
                "forum.bad_key",
                format!("key must be one line of 1 to {MAX_KEY_BYTES} bytes"),
            ));
        }
        let body = req.body.trim().to_owned();
        if !req.retire && body.is_empty() {
            return Err(refused("forum.empty", "body must not be empty"));
        }
        if body.len() > MAX_BODY_BYTES {
            return Err(refused("forum.too_long", format!("body is over {MAX_BODY_BYTES} bytes")));
        }
        let topic =
            req.topic.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| RULES_TOPIC.into());
        if topic.len() > MAX_KEY_BYTES {
            return Err(refused("forum.bad_topic", format!("topic is over {MAX_KEY_BYTES} bytes")));
        }
        let post = Post {
            id: uuid::Uuid::now_v7().to_string(),
            topic,
            author,
            kind: Kind::Announce,
            key: Some(key),
            body,
            supersedes: None,
            proposes: None,
            urgent: req.urgent && !req.retire,
            retired: req.retire,
            created: now_ms(),
        };
        let post = self
            .forum
            .post_with(post, |current, mut p| {
                let current = current.filter(|c| !c.retired);
                match current {
                    // An agent never replaces a person's rule: it proposes.
                    Some(c) if c.author.is_person() && !p.author.is_person() => {
                        p.kind = Kind::Question;
                        p.proposes = Some(c.id.clone());
                        p.urgent = false;
                        p.retired = false;
                    }
                    Some(c) => p.supersedes = Some(c.id.clone()),
                    None => {}
                }
                p
            })
            .map_err(storage)?;
        let proposed = post.kind == Kind::Question;
        if let Some(old) = &post.supersedes {
            self.forum_take_back(old);
        }
        let pushed = if post.urgent { self.forum_push(&post).await } else { Vec::new() };
        Ok(json!({"post": post, "proposed": proposed, "pushed": pushed}))
    }

    /// `_acpmux/forum/rules`: the current rule per key, with who got and acked each.
    pub fn forum_rules(&self) -> Value {
        json!({"rules": self.forum.rules()})
    }

    /// `_acpmux/forum/ack`: `session` has read `post_id`.
    pub fn forum_ack(&self, session: &Session, post_id: &str) -> Result<Value, RpcError> {
        match self.forum.ack(post_id, &session.id, now_ms()) {
            None => Err(refused("forum.not_found", format!("no post {post_id}"))),
            Some(Err(e)) => Err(storage(e)),
            Some(Ok(new)) => Ok(
                json!({"postId": post_id, "sessionId": session.id, "acked": true, "already": !new}),
            ),
        }
    }

    /// Whether `session` gets rules: the sessions that get cmux's tools.
    async fn forum_reaches(&self, session: &Session) -> bool {
        let m = session.meta();
        if m.remote_origin {
            return false;
        }
        let cfg = self.config.read().await;
        match super::resolve::session_profile(&cfg, &m.harness, &m.cwd, m.remote_origin) {
            Ok(profile) => !crate::agent_tools::left_out(false, &profile.env, &[]),
            Err(_) => false,
        }
    }

    /// The hidden block of current rules `session` was not given yet, each
    /// then recorded as delivered; None when there are none.
    pub(super) async fn forum_context(&self, session: &Session) -> Option<Value> {
        let posts = self.forum.undelivered(&session.id);
        if posts.is_empty() || !self.forum_reaches(session).await {
            return None;
        }
        let at = now_ms();
        let mut lines = Vec::new();
        for p in &posts {
            // Read again: a rule superseded since the list was taken is left out.
            if !self.forum.is_current(&p.id) {
                continue;
            }
            match self.forum.mark_delivered(&p.id, &session.id, at) {
                Ok(true) => lines.push(rule_text(p)),
                Ok(false) => {}
                Err(e) => {
                    tracing::warn!(session = %session.id, "forum delivery not recorded: {e:#}")
                }
            }
        }
        if lines.is_empty() {
            return None;
        }
        Some(json!({
            "type": "text",
            "text": format!(
                "<{CONTEXT_TAG}>\nCurrent cmux rules (forum announcements). Acknowledge with the forum ack tool once read.\n\n{}\n</{CONTEXT_TAG}>",
                lines.join("\n\n")
            ),
        }))
    }

    /// Queues `post` as a prompt to every live session that gets rules, the
    /// author's own excepted; the ids it was accepted for.
    async fn forum_push(self: &Arc<Self>, post: &Post) -> Vec<String> {
        let mut pushed = Vec::new();
        for s in self.sessions() {
            if post.author.session_id() == Some(s.id.as_str())
                || s.meta().status == SessionStatus::Closed
                || !self.forum_reaches(&s).await
            {
                continue;
            }
            let live = match s.child.lock().await.as_ref() {
                Some(child) => child.is_alive().await,
                None => false,
            };
            if !live || !self.forum.is_current(&post.id) {
                continue;
            }
            if self.forum_push_one(&s, post).await {
                pushed.push(s.id.clone());
            }
        }
        pushed
    }

    async fn forum_push_one(self: &Arc<Self>, s: &Arc<Session>, post: &Post) -> bool {
        let provenance = json!({
            "kind": PROVENANCE_KIND,
            "postId": post.id,
            "key": post.key,
            "author": post.author,
            "to": s.id,
        });
        let (tx, rx) = oneshot::channel::<Value>();
        let (hub, sid, pid) = (self.clone(), s.id.clone(), post.id.clone());
        let opts = PromptOptions {
            prompt_id: Some(format!("forum-{}", post.id)),
            // Recorded the moment the prompt is, before its turn could add the
            // same rule as a hidden block.
            on_accepted: Some(Box::new(move |v| {
                if let Err(e) = hub.forum.mark_delivered(&pid, &sid, now_ms()) {
                    tracing::warn!(session = %sid, "forum delivery not recorded: {e:#}");
                }
                let _ = tx.send(v);
            })),
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let text = format!("Urgent cmux rule. {}", rule_text(post));
        let blocks = vec![json!({"type": "text", "text": text})];
        let (hub, to) = (self.clone(), s.clone());
        // Steered into a running turn when the agent steers, else queued behind it.
        let turn =
            tokio::spawn(
                async move { hub.prompt_with(&to, blocks, "acpmux-forum", true, opts).await },
            );
        match rx.await {
            Ok(_) => {
                // Superseded while this push was on its way: take it back too.
                if !self.forum.is_current(&post.id) {
                    self.remove_queued_because(
                        s,
                        &format!("forum-{}", post.id),
                        Some("superseded"),
                    );
                }
                true
            }
            Err(_) => {
                if let Ok(Err(e)) = turn.await {
                    tracing::info!(session = %s.id, "urgent rule not pushed: {}", e.message);
                }
                false
            }
        }
    }

    /// Takes the pushed prompt of superseded post `old` out of every queue it still waits in.
    fn forum_take_back(&self, old: &str) {
        let prompt_id = format!("forum-{old}");
        for s in self.sessions() {
            if self.remove_queued_because(&s, &prompt_id, Some("superseded")) {
                tracing::info!(session = %s.id, post = old, "superseded rule taken back");
            }
        }
    }
}
