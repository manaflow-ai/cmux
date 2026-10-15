//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/btw`: a side session about a
//! chat (the composer's `/btw <question>`). Unlike `_acpmux/ask` (`aside.rs`),
//! which answers once and is gone, a side session stays: a chat of its own
//! the person can reply in, opened beside the chat.
//!
//! It runs the chat's harness in the chat's folder, tagged `side` with the
//! chat (the lists hide it), titled with the question, read-only and on a
//! cheap model, and it starts from the chat's conversation:
//!
//! - Claude and Codex fork through the chat's latest finished turn
//!   (`fork_at.rs`), which works while a turn runs.
//! - Any other harness, or a chat with no finished turn, gets a new session
//!   whose first prompt carries a bounded transcript of the chat as hidden
//!   context (`prompt_context.rs`): the side session's thread shows only the
//!   question.
//!
//! Read-only: the harness's read-only mode where it has one, and always a
//! policy no wider than approve-reads plus rules that refuse every tool kind
//! that writes, runs or switches modes. The question is sent as the first
//! prompt; the request answers once the prompt is recorded, never waiting for
//! the answer. The chat itself is never paused, cancelled or changed.

use super::*;

/// The tag that marks a side chat, valued with its chat's session id
/// (webviews sessionList.ts `SIDE_TAG`, `_acpmux/side`).
pub(crate) const SIDE_TAG: &str = "side";
/// The longest transcript a side session without a fork gets, in bytes (its
/// newest part; under `prompt_context::MAX_BYTES` with the wrapper).
const TRANSCRIPT_BYTES: usize = 12 * 1024;
/// Per harness family, the mode that reads but never writes (`web_modes.rs`
/// cites the sources): Claude Code's plan mode, Codex's read-only.
const READ_ONLY_MODES: &[(&str, &str)] = &[("claude", "plan"), ("codex", "read-only")];
/// The ACP tool kinds a side session refuses (`rules.rs` matches the kind):
/// everything but read, search, fetch and think.
const REFUSED_KINDS: &[&str] = &["edit", "delete", "move", "execute", "switch_mode", "other"];
/// Words in a model id or name that mark a small, fast model, best first.
const SMALL_MODEL_WORDS: &[&str] = &["nano", "mini", "flash", "lite", "small", "fast"];

impl Hub {
    /// Open a side session about `session` and send it `question`. Returns
    /// `{sessionId, model, readOnly}`: the side session, the model it was
    /// put on (null: the harness's default) and how it is kept read-only
    /// (`mode`: a read-only mode plus the policy; `policy`: the policy only).
    pub async fn btw(
        self: &Arc<Self>,
        session: &Arc<Session>,
        question: &str,
        model: Option<&str>,
        client: &str,
        opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        let question = question.trim();
        if question.is_empty() {
            return Err(RpcError::invalid_params("question is required"));
        }
        let explicit = model.map(str::trim).filter(|m| !m.is_empty()).map(str::to_owned);
        let meta = session.meta();
        let mut model = match explicit.clone() {
            Some(m) => Some(m),
            None => self.btw_default_model(&meta).await,
        };
        let name = self.unique_name(&format!("{}-btw", meta.name));
        let (side, context) = match self.btw_fork_point(session, &meta).await? {
            Some(through) => (
                self.fork(session, Some(name), None, Default::default(), Some(through)).await?,
                None,
            ),
            None => {
                let req = NewRequest {
                    harness: Some(meta.harness.clone()),
                    preset: meta.preset.clone(),
                    name: Some(name),
                    cwd: Some(meta.cwd.clone()),
                    policy: Some(side_policy(self.btw_chat_policy(session).await)),
                    model: model.clone(),
                    effort: None,
                    adopt: None,
                    remote: meta.remote_origin,
                    env: Default::default(),
                    // Never the start mode (it may be full access): read-only is set below.
                    keep_harness_mode: true,
                };
                let side = match self.new_session(req.clone()).await {
                    // A default model the harness refuses: its own default instead.
                    Err(e) if explicit.is_none() && model.is_some() => {
                        tracing::warn!(session = %session.id, "side session model: {}", e.message);
                        model = None;
                        self.new_session(NewRequest { model: None, ..req }).await?
                    }
                    other => other?,
                };
                (side, Some(self.btw_transcript(session)))
            }
        };
        let forked = context.is_none();
        let settled = self.btw_settle(session, &side, question).await;
        // A fork runs its chat's model until it is set (a new session took it at its start).
        let settled = match (settled, model.clone().filter(|_| forked)) {
            (Ok(mode), Some(m)) => match self.set_model(&side, &m).await {
                Ok(_) => Ok(mode),
                Err(e) if explicit.is_some() => Err(e),
                Err(e) => {
                    tracing::warn!(session = %side.id, "side session model: {}", e.message);
                    model = None;
                    Ok(mode)
                }
            },
            (settled, _) => settled,
        };
        let read_only = match settled {
            Ok(mode) => mode,
            Err(e) => {
                self.btw_discard(&side).await;
                return Err(e);
            }
        };
        let mut blocks = vec![json!({"type": "text", "text": question})];
        if let Some(text) = context.filter(|t| !t.is_empty()) {
            blocks.push(
                json!({"type": "text", "text": text, "_meta": {"acpmux": {"context": true}}}),
            );
        }
        // Answer once the prompt is recorded; the turn runs on.
        let (accepted_tx, accepted) = oneshot::channel();
        let mut opts = opts;
        opts.on_accepted = Some(Box::new(move |_: Value| {
            let _ = accepted_tx.send(());
        }));
        let (hub, run_on, client) = (self.clone(), side.clone(), client.to_owned());
        let run = tokio::spawn(async move {
            let r = hub.prompt_with(&run_on, blocks, &client, false, opts).await;
            if let Err(e) = &r {
                tracing::warn!(session = %run_on.id, "side session question: {}", e.message);
            }
            r
        });
        if accepted.await.is_err() {
            // Refused before it was recorded: no side session is left behind.
            let e = match run.await {
                Ok(Err(e)) => e,
                Ok(Ok(_)) => RpcError::internal("the side session's question was not recorded"),
                Err(e) => RpcError::internal(e.to_string()),
            };
            self.btw_discard(&side).await;
            return Err(e);
        }
        Ok(json!({"sessionId": side.id, "model": model, "readOnly": read_only}))
    }

    /// The model a side session starts on when the request names none:
    /// config.json `btw.model.<profile>`, then `btw.model.<family>`, then the
    /// harness's cheap model (Claude's `haiku`, Codex's smallest advertised
    /// one), else None (the harness's default).
    async fn btw_default_model(&self, meta: &SessionMeta) -> Option<String> {
        let family = crate::web_modes::family_of(meta);
        let configured = {
            let cfg = self.config.read().await;
            cfg.btw.model.get(&meta.harness).or_else(|| cfg.btw.model.get(&family)).cloned()
        };
        if configured.is_some() {
            return configured;
        }
        match family.as_str() {
            "claude" => Some("haiku".into()),
            "codex" => smallest_model(meta),
            _ => None,
        }
    }

    /// The turn a side session forks through: the chat's latest finished
    /// turn, for a harness that forks through a turn (Claude, Codex). None:
    /// a new session with the transcript instead.
    async fn btw_fork_point(
        &self,
        session: &Session,
        meta: &SessionMeta,
    ) -> Result<Option<u64>, RpcError> {
        let cuts = {
            let cfg = self.config.read().await;
            cfg.profile(&meta.harness).and_then(|p| crate::config::turn_cut(&meta.harness, p))
        };
        if cuts.is_none() || meta.agent_session_id.is_none() {
            return Ok(None);
        }
        let latest = self
            .store
            .events(&session.id, 0, 500_000)
            .map_err(|e| RpcError::internal(e.to_string()))?
            .into_iter()
            .filter(|e| e.kind == "turn_result")
            .map(|e| e.seq)
            .max();
        Ok(latest)
    }

    /// The chat's effective policy.
    async fn btw_chat_policy(&self, session: &Session) -> PermissionPolicy {
        let default = self.config.read().await.permission_policy;
        self.policy_for(session, default)
    }

    /// Tag, title, policy, rules and mode of a new side session. Returns how
    /// it is read-only (`mode` or `policy`).
    async fn btw_settle(
        self: &Arc<Self>,
        chat: &Session,
        side: &Arc<Session>,
        question: &str,
    ) -> Result<&'static str, RpcError> {
        let mut tag = serde_json::Map::new();
        tag.insert(SIDE_TAG.into(), Value::String(chat.id.clone()));
        self.set_tags(side, Some(&tag), &[], None);
        {
            let first = question.lines().find(|l| !l.trim().is_empty()).unwrap_or(question);
            side.meta.lock().unwrap_or_else(|e| e.into_inner()).title =
                Some(short_text(first.trim(), 80));
        }
        self.save_meta(side);
        self.set_policy(side, side_policy(self.btw_chat_policy(chat).await)).await;
        self.set_rules(side, Some(json!({"autoDeny": REFUSED_KINDS})));
        let meta = side.meta();
        let family = crate::web_modes::family_of(&meta);
        let Some((_, mode)) = READ_ONLY_MODES.iter().find(|(f, _)| *f == family) else {
            return Ok("policy");
        };
        let set = if offers_mode(&meta, mode) {
            self.set_mode(side, mode).await
        } else if offers_mode_option(&meta, mode) {
            self.set_config(side, "mode", json!(mode)).await
        } else {
            return Ok("policy");
        };
        match set {
            Ok(_) => Ok("mode"),
            Err(e) => {
                // The policy and rules still refuse every write.
                tracing::warn!(session = %side.id, "side session read-only mode: {}", e.message);
                Ok("policy")
            }
        }
    }

    /// The chat as text for a side session that does not fork it: its
    /// prompts and answers, newest last, cut to its newest
    /// `TRANSCRIPT_BYTES`, marked as context. Empty for a chat with nothing yet.
    fn btw_transcript(&self, session: &Session) -> String {
        let events = self.store.events(&session.id, 0, 500_000).unwrap_or_default();
        let mut lines: Vec<(&str, String)> = Vec::new();
        for e in &events {
            let (who, text) = match e.kind.as_str() {
                "user_message" => ("User", e.msg.get("text").and_then(Value::as_str)),
                "agent_message_chunk" => (
                    "Assistant",
                    e.msg.pointer("/params/update/content/text").and_then(Value::as_str),
                ),
                _ => continue,
            };
            let Some(text) = text else { continue };
            // An answer streams in chunks: one line per answer.
            if let Some((_, said)) =
                lines.last_mut().filter(|(last, _)| who == "Assistant" && *last == who)
            {
                said.push_str(text);
                continue;
            }
            lines.push((who, text.to_owned()));
        }
        let body: String = lines
            .iter()
            .map(|(who, text)| format!("{who}: {}\n\n", text.trim()))
            .collect::<String>();
        let body = body.trim_end();
        if body.is_empty() {
            return String::new();
        }
        let (cut, body) = newest(body, TRANSCRIPT_BYTES);
        format!(
            "<cmux-btw-context>\nThe person asks a side question about another chat (the main thread). \
             Its transcript follows{}, read-only: answer from it and by reading files, and never \
             edit files or run commands.\n\n{body}\n</cmux-btw-context>",
            if cut { ", its oldest part cut" } else { "" }
        )
    }

    /// End a side session that failed before its question was recorded.
    async fn btw_discard(&self, side: &Arc<Session>) {
        if let Err(e) = self.kill(side, true).await {
            tracing::warn!(session = %side.id, "side session cleanup: {}", e.message);
        }
    }
}

/// A side session's policy: approve-reads, never wider than its chat's.
fn side_policy(chat: PermissionPolicy) -> PermissionPolicy {
    match chat {
        PermissionPolicy::Ask | PermissionPolicy::DenyAll => chat,
        _ => PermissionPolicy::ApproveReads,
    }
}

/// Whether the session lists `mode` among its ACP modes.
fn offers_mode(meta: &SessionMeta, mode: &str) -> bool {
    meta.modes
        .as_ref()
        .and_then(|m| m.get("availableModes"))
        .and_then(Value::as_array)
        .is_some_and(|a| a.iter().any(|m| m.get("id").and_then(Value::as_str) == Some(mode)))
}

/// Whether the session's `mode` config option offers `mode`.
fn offers_mode_option(meta: &SessionMeta, mode: &str) -> bool {
    meta.config_options.as_ref().and_then(Value::as_array).is_some_and(|a| {
        a.iter().filter(|o| o.get("id").and_then(Value::as_str) == Some("mode")).any(|o| {
            o.get("options").and_then(Value::as_array).is_some_and(|opts| {
                opts.iter().any(|v| v.get("value").and_then(Value::as_str) == Some(mode))
            })
        })
    })
}

/// The smallest, fastest model the session's harness advertises (by the
/// words in `SMALL_MODEL_WORDS`, in its own order), else None.
fn smallest_model(meta: &SessionMeta) -> Option<String> {
    let mut models: Vec<(String, String)> = Vec::new();
    if let Some(list) =
        meta.models.as_ref().and_then(|m| m.get("availableModels")).and_then(Value::as_array)
    {
        for m in list {
            if let Some(id) = m.get("modelId").and_then(Value::as_str) {
                let name = m.get("name").and_then(Value::as_str).unwrap_or(id);
                models.push((id.to_owned(), name.to_lowercase()));
            }
        }
    }
    if let Some(opts) = meta.config_options.as_ref().and_then(Value::as_array) {
        for o in opts.iter().filter(|o| o.get("id").and_then(Value::as_str) == Some("model")) {
            for v in o.get("options").and_then(Value::as_array).into_iter().flatten() {
                if let Some(id) = v.get("value").and_then(Value::as_str) {
                    let name = v.get("name").and_then(Value::as_str).unwrap_or(id);
                    models.push((id.to_owned(), name.to_lowercase()));
                }
            }
        }
    }
    SMALL_MODEL_WORDS.iter().find_map(|word| {
        models
            .iter()
            .find(|(id, name)| id.to_lowercase().contains(word) || name.contains(word))
            .map(|(id, _)| id.clone())
    })
}

/// The newest `max` bytes of `text` (whole characters), and whether it was cut.
fn newest(text: &str, max: usize) -> (bool, &str) {
    if text.len() <= max {
        return (false, text);
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    (true, &text[start..])
}
