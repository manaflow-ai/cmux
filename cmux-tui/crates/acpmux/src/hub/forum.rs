//! Forum announcements on the hub (`forum.rs` keeps the log, hq#2570).
//!
//! - `announce`: a rule per key, by a person (the proven app, with their
//!   account) or an agent session (its caller token). It supersedes the key's
//!   current rule, except that an agent never replaces a person's rule: its
//!   post is stored as a proposal (`question`, `proposes`) and the rule stays.
//!   `retire` ends a key; the sessions that were told one of its rules are
//!   told it no longer applies.
//! - Delivery, by default: the next prompt of every session carries what it
//!   was not told yet, as one hidden block (`<cmux-rules-context>`, dropped
//!   from replays by `prompt_context.rs`), so a session started later reads
//!   the rules on its first prompt. A rule counts as told only once the agent
//!   answered that prompt (or took a pushed rule into its running turn). A
//!   session restored onto a new agent session, or whose agent ran `/clear`
//!   or `/compact`, gets every rule again on its next prompt; a slash command
//!   gets none (its turn is the command). The author's own session is not
//!   told its own rule.
//! - `urgent`: also a prompt to every live session, the way an agent's
//!   message is (provenance `announcement`, prompt id `forum-<postId>`). A
//!   rule superseded while that prompt still waits is taken out of the queue;
//!   one that starts anyway carries the key's current rule instead. A rule
//!   superseded in the moment between that check and the send can still
//!   reach the agent; the next prompt then tells it the current one.
//! - The block and the prompt say who wrote each rule: a person's is an
//!   instruction, an agent's is information.
//! - Sessions that get no cmux tools (remote origin, `ACPMUX_AGENT_TOOLS=0`
//!   such as a compactor, Claude Code with `--strict-mcp-config`) get no rules.

use super::*;
use crate::forum::{Author, Forum, Kind, MAX_BODY_BYTES, MAX_KEY_BYTES, Post, RULES_TOPIC};

/// Provenance kind of a pushed rule (`prompt_provenance.rs`).
pub const PROVENANCE_KIND: &str = "announcement";
/// The element a rules block is wrapped in (`prompt_context::is_context_text`).
const CONTEXT_TAG: &str = "cmux-rules-context";
/// Prefix of a pushed rule's prompt id.
const PUSH_PREFIX: &str = "forum-";
/// Longest an announce waits for one session to take its urgent prompt.
const PUSH_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

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

/// How an agent reads one rule.
fn rule_text(p: &Post) -> String {
    let key = p.key.as_deref().unwrap_or("");
    let (who, weight) = match &p.author {
        Author::Person { account } => {
            (format!("{account} (a person)"), "an instruction: follow it")
        }
        Author::Agent { name, .. } => (
            format!("agent session {name}"),
            "information from another agent; a person's rule wins",
        ),
    };
    if p.retired {
        return format!("[{key}] retired by {who}: the earlier rule on {key} no longer applies.");
    }
    format!("[{key}] from {who}, {weight} (postId {}):\n{}", p.id, p.body)
}

/// How one urgent push went.
enum Push {
    /// The session took it: queued, steered in, or started.
    Taken,
    /// Not answered within [`PUSH_WAIT`].
    Pending,
    /// Not sent: no rules for this session, not live, or refused.
    No,
}

fn push_text(p: &Post) -> String {
    format!("Urgent cmux rule. {}", rule_text(p))
}

impl Hub {
    pub fn forum(&self) -> &Forum {
        self.forum.get_or_init(Forum::memory)
    }

    /// Keeps the forum log under `root` (the daemon: `<ACPMUX_HOME>/forum`);
    /// before it, a hub keeps posts in memory. Call once, before serving.
    pub fn open_forum(&self, root: &Path) -> anyhow::Result<()> {
        let forum = Forum::open(root)?;
        self.forum.set(forum).map_err(|_| anyhow::anyhow!("the forum is already open"))
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
        let body = if req.retire { String::new() } else { req.body.trim().to_owned() };
        if !req.retire && body.is_empty() {
            return Err(refused("forum.empty", "body must not be empty"));
        }
        if body.len() > MAX_BODY_BYTES {
            return Err(refused("forum.too_long", format!("body is over {MAX_BODY_BYTES} bytes")));
        }
        let topic =
            req.topic.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| RULES_TOPIC.into());
        if topic.len() > MAX_KEY_BYTES || topic.contains(['\n', '\r']) {
            return Err(refused(
                "forum.bad_topic",
                format!("topic must be one line of at most {MAX_KEY_BYTES} bytes"),
            ));
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
            urgent: req.urgent,
            retired: req.retire,
            created: now_ms(),
        };
        // The log flushes the post to disk: off the async workers.
        let hub = self.clone();
        let stored = tokio::task::spawn_blocking(move || {
            hub.forum().post_with(post, |current, mut p| {
                match current {
                    // An agent never replaces or retires a person's rule: it proposes.
                    Some(c) if !c.retired && c.author.is_person() && !p.author.is_person() => {
                        p.kind = Kind::Question;
                        p.proposes = Some(c.id.clone());
                        p.urgent = false;
                    }
                    Some(c) => p.supersedes = Some(c.id.clone()),
                    // Nothing to retire.
                    None if p.retired => p.urgent = false,
                    None => {}
                }
                p
            })
        })
        .await
        .map_err(|e| RpcError::internal(format!("forum log: {e}")))?;
        let post = stored.map_err(storage)?;
        let proposed = post.kind == Kind::Question;
        if let Some(old) = &post.supersedes {
            self.forum_take_back(old);
        }
        let (pushed, pending) =
            if post.urgent { self.forum_push(&post).await } else { Default::default() };
        Ok(json!({"post": post, "proposed": proposed, "pushed": pushed, "pending": pending}))
    }

    /// `_acpmux/forum/rules`: the current rule per key, with who got and acked
    /// each, and agents' open proposals to change them.
    pub fn forum_rules(&self) -> Value {
        json!({"rules": self.forum().rules(), "proposals": self.forum().proposals()})
    }

    /// `_acpmux/forum/ack`: `session` has read announcement `post_id`.
    pub fn forum_ack(&self, session: &Session, post_id: &str) -> Result<Value, RpcError> {
        match self.forum().ack(post_id, &session.id, now_ms()) {
            None => Err(refused("forum.not_found", format!("no announcement {post_id}"))),
            Some(Err(e)) => Err(storage(e)),
            Some(Ok(new)) => Ok(
                json!({"postId": post_id, "sessionId": session.id, "acked": true, "already": !new}),
            ),
        }
    }

    /// Whether `session` gets rules: the sessions that get cmux's tools, by
    /// the profile it spawns with (its preset's env and args included, as
    /// `child_for` resolves it) and the daemon-wide switch.
    async fn forum_reaches(&self, session: &Session) -> bool {
        let m = session.meta();
        let switch = std::env::var_os(crate::agent_tools::SWITCH_ENV);
        if m.remote_origin || switch.is_some_and(|v| v == "0") {
            return false;
        }
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            match super::resolve::session_profile(&cfg, &m.harness, &m.cwd, m.remote_origin) {
                Ok(profile) => (profile, cfg.defaults_for(&m.harness)),
                Err(_) => return false,
            }
        };
        let Ok(profile) = self.spawn_profile_for(&m, &profile, &defaults.env).await else {
            return false;
        };
        // Claude Code alone reads `--strict-mcp-config` (`hub/tools.rs`).
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let args: &[String] = if claude { &profile.argv } else { &[] };
        !crate::agent_tools::left_out(false, &profile.env, args)
    }

    /// Before a prompt is recorded: a pushed rule (`forum-<postId>`) whose
    /// key moved on since it was queued carries the key's current post
    /// instead. The post the prompt tells, or None for any other prompt.
    pub(super) fn forum_refresh_push(
        &self,
        prompt_id: &str,
        blocks: &mut [Value],
        provenance: &mut Option<Value>,
    ) -> Option<String> {
        let id = prompt_id.strip_prefix(PUSH_PREFIX)?;
        let forum = self.forum();
        let post = forum.get(id)?.post;
        if forum.is_current(id) {
            return Some(post.id);
        }
        let current = forum.current(post.key.as_deref()?)?;
        if let Some(block) = blocks.first_mut() {
            *block = json!({"type": "text", "text": push_text(&current)});
        }
        if let Some(p) = provenance.as_mut().filter(|p| p["kind"] == PROVENANCE_KIND) {
            p["postId"] = json!(current.id);
            p["author"] = json!(current.author);
        }
        Some(current.id)
    }

    /// Appends the hidden block of what `session` was not told yet to a
    /// prompt's `blocks`. The posts the turn tells, including `pushed` (a
    /// pushed rule's own post): recorded by [`Self::forum_told`] once the
    /// agent answered.
    pub(super) async fn forum_context(
        &self,
        session: &Session,
        pushed: Option<String>,
        blocks: &mut Vec<Value>,
    ) -> Vec<String> {
        let mut told: Vec<String> = pushed.into_iter().collect();
        let first = blocks.iter().find_map(|b| b.get("text").and_then(Value::as_str));
        // A slash command's turn is the command: the rules wait for the next
        // prompt, all of them after one that empties the agent's context.
        if let Some(command) = first.and_then(|t| t.trim_start().strip_prefix('/')) {
            let name = command.split_whitespace().next().unwrap_or_default();
            if matches!(name, "clear" | "compact" | "new" | "reset") {
                session.forum_retell.store(true, Ordering::SeqCst);
            }
            return told;
        }
        // A new agent session that got the restored transcript lost the rules with it.
        let restored = first.is_some_and(|t| t.starts_with("<restored_transcript"))
            || session.forum_retell.swap(false, Ordering::SeqCst);
        let forum = self.forum();
        let queued: Vec<String> = session
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter_map(|q| q.prompt_id.strip_prefix(PUSH_PREFIX).map(str::to_owned))
            .collect();
        let posts: Vec<Post> = forum
            .undelivered(&session.id, restored)
            .into_iter()
            // Told by this prompt itself, or by its own prompt still waiting.
            .filter(|p| !told.contains(&p.id) && !queued.contains(&p.id))
            .collect();
        if posts.is_empty() || !self.forum_reaches(session).await {
            return told;
        }
        let lines: Vec<String> = posts.iter().map(rule_text).collect();
        told.extend(posts.into_iter().map(|p| p.id));
        blocks.push(json!({
            "type": "text",
            "text": format!(
                "<{CONTEXT_TAG}>\nCurrent cmux rules (forum announcements). Ack each with the forum ack tool once read.\n\n{}\n</{CONTEXT_TAG}>",
                lines.join("\n\n")
            ),
        }));
        told
    }

    /// [`Self::forum_context`] again for a prompt that now opens with a
    /// restored transcript (a fallback agent that could not resume): its
    /// rules block is replaced by every current rule.
    pub(super) async fn forum_retell(
        &self,
        session: &Session,
        pushed: Option<String>,
        blocks: &mut Vec<Value>,
    ) -> Vec<String> {
        let open = format!("<{CONTEXT_TAG}>");
        blocks.retain(|b| {
            !b.get("text").and_then(Value::as_str).is_some_and(|t| t.starts_with(&open))
        });
        self.forum_context(session, pushed, blocks).await
    }

    /// The agent answered a prompt that told `posts`: record them as told.
    pub(super) fn forum_told(&self, session: &Session, posts: &[String]) {
        if posts.is_empty() {
            return;
        }
        if let Err(e) = self.forum().mark_delivered(posts, &session.id, now_ms()) {
            tracing::warn!(session = %session.id, "forum delivery not recorded: {e:#}");
        }
    }

    /// Queues `post` as a prompt to every live session that gets rules, the
    /// author's own excepted (a retirement: only those told the key before),
    /// all at once: the ids that took it, and the ids still on their way
    /// after [`PUSH_WAIT`] (their prompt may still be queued).
    async fn forum_push(self: &Arc<Self>, post: &Post) -> (Vec<String>, Vec<String>) {
        let mut pushes = tokio::task::JoinSet::new();
        for s in self.sessions() {
            if post.author.session_id() == Some(s.id.as_str())
                || s.meta().status == SessionStatus::Closed
            {
                continue;
            }
            if post.retired && !post.key.as_ref().is_some_and(|k| self.forum().told_key(k, &s.id)) {
                continue;
            }
            let (hub, post) = (self.clone(), post.clone());
            pushes.spawn(async move { (s.id.clone(), hub.forum_push_one(&s, &post).await) });
        }
        let (mut pushed, mut pending) = (Vec::new(), Vec::new());
        for (id, push) in pushes.join_all().await {
            match push {
                Push::Taken => pushed.push(id),
                Push::Pending => pending.push(id),
                Push::No => {}
            }
        }
        pushed.sort();
        pending.sort();
        (pushed, pending)
    }

    async fn forum_push_one(self: &Arc<Self>, s: &Arc<Session>, post: &Post) -> Push {
        if !self.forum_reaches(s).await {
            return Push::No;
        }
        let live = match s.child.lock().await.as_ref() {
            Some(child) => child.is_alive().await,
            None => false,
        };
        if !live || !self.forum().is_current(&post.id) {
            return Push::No;
        }
        let prompt_id = format!("{PUSH_PREFIX}{}", post.id);
        let provenance = json!({
            "kind": PROVENANCE_KIND,
            "postId": post.id,
            "key": post.key,
            "author": post.author,
            "to": s.id,
        });
        let (tx, rx) = oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.clone()),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": push_text(post)})];
        let (hub, to) = (self.clone(), s.clone());
        // Steered into a running turn when the agent steers, else queued behind it.
        let turn =
            tokio::spawn(
                async move { hub.prompt_with(&to, blocks, "acpmux-forum", true, opts).await },
            );
        match tokio::time::timeout(PUSH_WAIT, rx).await {
            // Still on its way (a slow agent start): it may yet be queued.
            Err(_) => Push::Pending,
            Ok(Ok(accepted)) => {
                // Steered into the running turn: no turn of its own records it.
                if accepted.get("steer").and_then(Value::as_bool) == Some(true) {
                    self.forum_told(s, std::slice::from_ref(&post.id));
                }
                // Superseded while this push was on its way: take it back too.
                if !self.forum().is_current(&post.id) {
                    self.remove_queued_because(s, &prompt_id, Some("superseded"));
                }
                Push::Taken
            }
            Ok(Err(_)) => {
                if let Ok(Err(e)) = turn.await {
                    tracing::info!(session = %s.id, "urgent rule not pushed: {}", e.message);
                }
                Push::No
            }
        }
    }

    /// Takes the pushed prompt of superseded post `old` out of every queue it still waits in.
    fn forum_take_back(&self, old: &str) {
        let prompt_id = format!("{PUSH_PREFIX}{old}");
        for s in self.sessions() {
            if self.remove_queued_because(&s, &prompt_id, Some("superseded")) {
                tracing::info!(session = %s.id, post = old, "superseded rule taken back");
            }
        }
    }
}
