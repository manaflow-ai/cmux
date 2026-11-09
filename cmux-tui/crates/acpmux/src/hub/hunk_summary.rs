//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/hunk_summary` (`crate::hunk_summary`): one plain
//! sentence for one diff hunk, kept by the hunk's content hash.
//!
//! `{path, patch, sessionId?, harness?}` answers `{text, key, cached, harness?}`; a kept sentence
//! runs nothing. `{check: true, sessionId?, harness?}` answers `{ready, harness}` without running
//! anything: whether a harness here could answer (the diff tab disables its toggle otherwise).
//! The harness is `harness`, else the chat `sessionId`'s own, else the daemon's default; a chat
//! whose harness has no headless mode falls back to the default.

use super::*;
use crate::complete::{self, CompleteError, Request};
use crate::hunk_summary::{self as summary, Cache};

/// The longest patch taken, in bytes: the prompt cuts it further (`summary::prompt`).
const MAX_PATCH_BYTES: usize = 256 * 1024;

impl Hub {
    /// `_acpmux/hunk_summary` from a connection of `origin`: the unix socket only, as
    /// `_acpmux/complete` (`complete::allowed`).
    pub async fn hunk_summary(
        self: &Arc<Self>,
        origin: crate::server::Origin,
        params: &Value,
    ) -> Result<Value, RpcError> {
        if !complete::allowed(origin) {
            return Err(CompleteError::LocalOnly.into());
        }
        let harness = self.summary_harness(params).await?;
        if params.get("check").and_then(Value::as_bool) == Some(true) {
            return Ok(json!({"ready": true, "harness": harness}));
        }
        let text = |key: &str| params.get(key).and_then(Value::as_str);
        let (Some(path), Some(patch)) = (text("path"), text("patch")) else {
            return Err(CompleteError::InvalidParams(
                "path and patch (strings) are required".into(),
            )
            .into());
        };
        if patch.trim().is_empty() || patch.len() > MAX_PATCH_BYTES {
            return Err(CompleteError::InvalidParams(format!(
                "patch must be 1 to {MAX_PATCH_BYTES} bytes"
            ))
            .into());
        }
        let key = summary::key(path, patch);
        let cache = Cache::for_daemon();
        let kept = {
            let (cache, key) = (cache.clone(), key.clone());
            tokio::task::spawn_blocking(move || cache.get(&key)).await.ok().flatten()
        };
        if let Some(text) = kept {
            return Ok(json!({"text": text, "key": key, "cached": true}));
        }
        let req = Request {
            prompt: summary::prompt(path, patch, complete::MAX_PROMPT_BYTES),
            harness: Some(harness.clone()),
            model: None,
            max_tokens: summary::MAX_TOKENS,
            timeout: std::time::Duration::from_millis(u64::from(summary::TIMEOUT_MS)),
        };
        let reply = self.complete_request(&req).await.map_err(RpcError::from)?;
        let answer = reply.get("text").and_then(serde_json::Value::as_str).unwrap_or_default();
        let Some(text) = summary::sentence(answer) else {
            return Err(CompleteError::EmptyOutput { harness }.into());
        };
        {
            let (key, text) = (key.clone(), text.clone());
            let saved = tokio::task::spawn_blocking(move || cache.put(&key, &text)).await;
            if let Ok(Err(e)) = saved {
                tracing::debug!("hunk summary not kept: {e}");
            }
        }
        Ok(json!({"text": text, "key": key, "cached": false, "harness": harness}))
    }

    /// The harness a summary runs on (module docs), checked able to answer here.
    async fn summary_harness(&self, params: &Value) -> Result<String, RpcError> {
        let named = params.get("harness").and_then(Value::as_str).filter(|h| !h.trim().is_empty());
        let chat = match (named, params.get("sessionId").and_then(Value::as_str)) {
            // A chat that is gone is no chat: the default answers.
            (None, Some(id)) if !id.is_empty() => self.resolve(id).ok().map(|s| s.meta().harness),
            _ => None,
        };
        let first = named.map(str::to_owned).or(chat);
        match self.completion_ready(first.as_deref()).await {
            Ok(name) => Ok(name),
            // The chat's harness has no headless mode here: the default answers.
            Err(
                CompleteError::UnknownHarness(_)
                | CompleteError::Unsupported { .. }
                | CompleteError::NotInstalled { .. },
            ) if named.is_none() && first.is_some() => {
                self.completion_ready(None).await.map_err(RpcError::from)
            }
            Err(e) => Err(e.into()),
        }
    }
}
