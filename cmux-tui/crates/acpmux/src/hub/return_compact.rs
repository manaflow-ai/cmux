//! Part of `Hub`; see `hub/mod.rs`. Compact a big Claude chat before the person's prompt once its
//! prompt cache has lapsed, then send the prompt (Leo, 2026-11-18: "a sort of opt-in maybe
//! feature for auto compaction when your Claude Code cache is busted or whatever").
//!
//! After the cache lapses the next turn reads the whole context uncached. With Settings > General
//! > Prompt Cache's mode "When You Return" (`agents.cacheCompact.mode` = `onReturn`, off by
//! default: a compaction is a model call that counts toward usage), a person's prompt to an idle
//! chat whose last usage named an expired cache (`_meta.acpmux.cacheExpiresAt`,
//! `claude_stdio/prompt_cache.rs`) and at least `agents.cacheCompact.returnMinTokens` of context
//! first starts Claude Code's `/compact` as acpmux's own prompt ([`KIND`]); the person's prompt
//! then queues behind it and runs once it ends, failed or not. The decision is the daemon's, so
//! it holds after an app restart, for a chat adopted from a terminal and for every client.
//!
//! A client may decide for one prompt (`_meta.acpmux.cacheCompact`, [`Choice`]): the composer's
//! chip sends `compact` or, flipped, `keep`; `acpmux prompt --compact-first | --keep-cache` the
//! same. `compact` compacts any chat with a known cache, expired or not; `keep` never compacts.
//!
//! The compaction is sent `no_queue` under the person's prompt's own rules (its control, trust
//! gate, device), so a turn that starts at that moment refuses it, and it is never continued by
//! `auto_resume.rs` (`cache_compact::is_own`).

use super::*;

/// The provenance kind of the compaction run before a person's prompt.
pub(crate) const KIND: &str = "return_compact";
pub const SETTING_RETURN_MIN_TOKENS: &str = "agents.cacheCompact.returnMinTokens";
const DEFAULT_RETURN_MIN_TOKENS: u64 = 200_000;
const RETURN_MIN_TOKENS_RANGE: (u64, u64) = (20_000, 1_000_000);
/// How long the person's prompt waits for the compaction to take the turn: it records at once,
/// so this bounds only a stuck admission.
const ACCEPT_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

/// A client's word for one prompt (`_meta.acpmux.cacheCompact`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    /// Compact first, then send.
    Compact,
    /// Send as it is.
    Keep,
}

impl Choice {
    pub fn parse(value: Option<&Value>) -> Option<Self> {
        match value.and_then(Value::as_str) {
            Some("compact") => Some(Self::Compact),
            Some("keep") => Some(Self::Keep),
            _ => None,
        }
    }
}

/// The context a chat must hold for "When You Return" to compact it: None unless that is the
/// mode.
pub(crate) fn settings_min_tokens(doc: Option<&Value>) -> Option<u64> {
    if super::idle::cache_compact::settings_mode(doc) != super::idle::cache_compact::Mode::OnReturn
    {
        return None;
    }
    let tokens = doc
        .and_then(|doc| crate::user_settings::value(doc, SETTING_RETURN_MIN_TOKENS))
        .as_ref()
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .map_or(DEFAULT_RETURN_MIN_TOKENS, |n| {
            (n as u64).clamp(RETURN_MIN_TOKENS_RANGE.0, RETURN_MIN_TOKENS_RANGE.1)
        });
    Some(tokens)
}

pub(crate) fn read_min_tokens() -> Option<u64> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_min_tokens(Some(&doc)),
        _ => None,
    }
}

/// Whether a prompt compacts the chat first: `choice` the client's word, `min_tokens` the
/// setting (None: not "When You Return"), `usage` the chat's last `usage_update`. Only a chat
/// with a known cache (a Claude chat's expiry) is compacted.
pub(crate) fn due(
    choice: Option<Choice>,
    min_tokens: Option<u64>,
    usage: Option<&Value>,
    now_ms: u64,
) -> bool {
    let Some(usage) = usage else { return false };
    let Some(expires) = usage.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64)
    else {
        return false;
    };
    let used = usage.get("used").and_then(Value::as_u64).unwrap_or(0);
    match choice {
        Some(Choice::Keep) => false,
        Some(Choice::Compact) => used > 0,
        None => min_tokens.is_some_and(|min| used >= min) && now_ms >= expires,
    }
}

/// Whether `blocks` is a slash command (a `/compact` or `/clear` of the person's own), which
/// is sent as it is.
fn slash_command(blocks: &[Value]) -> bool {
    blocks
        .iter()
        .find_map(|b| b.get("text").and_then(Value::as_str))
        .is_some_and(|text| text.trim_start().starts_with('/'))
}

impl Hub {
    /// Before a prompt is run: starts the compaction when it is due (module docs) and waits until
    /// it holds the turn, so the prompt queues behind it. True when it did; the prompt then goes
    /// as a plain prompt, never a steer into the compaction.
    pub(super) async fn return_compact_first(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        opts: &PromptOptions,
    ) -> bool {
        if opts.cache_compact == Some(Choice::Keep)
            || opts.steer_only
            || opts.no_queue
            || opts.after_turn.is_some()
            || slash_command(blocks)
        {
            return false;
        }
        // Unasked, only for the person's own prompt; a client's explicit word for any.
        if opts.cache_compact.is_none()
            && !super::inbox::persons_prompt(opts.agent.as_deref(), opts.provenance.as_ref())
        {
            return false;
        }
        // An idle chat only: a running turn or a queued prompt warms the cache first.
        if session.turn().is_some()
            || session.queued() > 0
            || session.harness_turn.load(Ordering::SeqCst)
        {
            return false;
        }
        let usage = session.read_meta(|m| m.usage.clone());
        let min_tokens = if opts.cache_compact.is_none() { read_min_tokens() } else { None };
        if !due(opts.cache_compact, min_tokens, usage.as_ref(), now_ms()) {
            return false;
        }
        let (taken, accepted) = tokio::sync::oneshot::channel::<bool>();
        let compact = PromptOptions {
            prompt_id: Some(format!("return-compact-{}", uuid::Uuid::now_v7())),
            provenance: Some(json!({"kind": KIND})),
            no_queue: true,
            control: opts.control,
            cloud_mobile: opts.cloud_mobile,
            trust_gate: opts.trust_gate,
            full_access_device: opts.full_access_device.clone(),
            on_accepted: Some(Box::new(move |v: Value| {
                let _ = taken.send(v.get("queued") != Some(&Value::Bool(true)));
            })),
            ..PromptOptions::default()
        };
        let (hub, target) = (self.clone(), session.clone());
        // On the hub's scope: a stopping daemon ends it with the hub.
        self.scope.spawn_named(
            "return-compact",
            Box::pin(async move {
                let blocks = vec![json!({"type": "text", "text": "/compact"})];
                if let Err(e) = hub.prompt_with(&target, blocks, "acpmux", false, compact).await {
                    tracing::info!(session = %target.id, error = ?e, "return compaction not run");
                }
            }),
        );
        match tokio::time::timeout(ACCEPT_WAIT, accepted).await {
            Ok(Ok(started)) => started,
            // Refused (a turn began meanwhile, a gate) or still not taken: the prompt goes as is.
            _ => false,
        }
    }
}

#[cfg(test)]
#[path = "return_compact_tests.rs"]
mod tests;
