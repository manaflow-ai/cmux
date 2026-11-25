//! Part of `Hub`; see `hub/mod.rs`. A wake onto a cold, large chat costs little, and many small
//! messages cost one turn.
//!
//! Leo, 2026-11-24, on "each wake re-reads the session's whole context without the cache": "clearly
//! we need to probably compact before recieving messages sometimes. oh yeah, and not just
//! batching, but intervals to assist in batching. well, that's the inbox anyways..."
//!
//! On 2026-11-24 01:50Z about 70 stopped chats were woken every ~11 minutes; of 31 running, 16 were
//! woken by an inbox notice and most of the rest by a background task's end. Every such wake of a
//! chat idle past its prompt cache's lifetime reads its whole context uncached.
//!
//! - **Intervals.** An idle chat whose prompt cache lapsed (`_meta.acpmux.cacheExpiresAt` of its
//!   last `usage_update`, else [`NO_EXPIRY_TTL_MS`] after its last turn ended) opens one batch per
//!   idle stretch: the inbox's notice (`inbox.rs` `inbox_review`) and another agent's message the
//!   queue gathers (`agent_gather.rs`: a background task's end, a lane report, a cross-host
//!   message) wait until the batch's deadline, and go in as one turn (`digest.rs` `take_joined`:
//!   an inbox notice takes the agent messages queued behind it). The window ([`window_ms`]) is
//!   [`MIN_WINDOW_MS`] for a chat just gone cold and grows to [`MAX_WINDOW_MS`] with its context
//!   (full at [`SIZE_FULL_TOKENS`]) or with how long it has been cold (full at [`COLD_FULL_MS`]),
//!   whichever is more. A warm chat keeps the 2 s burst window: its cache makes a wake cheap.
//!   A block, a question and a fire notice still wake at once, and the person's prompt never waits.
//! - **Compact before delivery.** When a batch opens on a Claude Code chat whose context is at
//!   least the compaction line ([`DEFAULT_COMPACT_ABOVE_TOKENS`] unless
//!   `agents.coldWake.compactAboveTokens` or [`ENV_COMPACT_ABOVE`] says otherwise), acpmux first tries context surgery (`surgery.rs`: old tool
//!   output masked in a copy of the transcript, no model call) when masking alone takes it under
//!   that line ([`surgery_suffices`]); the batch then goes in to the resumed copy with no
//!   `/compact`. Otherwise (surgery off, refused or failed) it runs `/compact` at once ([`KIND`]),
//!   so the compaction's time hides in the window, and the batch goes in after it ends, into the
//!   compacted context. The compaction reads the cold context once; the batch's turn and every
//!   turn after it read the summary. Nothing steers into the compaction's turn.
//!
//! Tuning: every knob is a setting and an environment variable of the daemon, the variable winning
//! ([`Knobs`]; the table is in the crate's README, "Tuning compaction").
//!
//! The detector is `acpmux::hub::cold_wake` in the daemon's log:
//! `cold wake batch opened` (with the window, the context and how long it was cold) and
//! `cold wake compaction`, and the handbook's "a cold wake re-reads the whole context" page.

use super::*;

/// The provenance kind of the compaction a cold batch runs first.
pub(crate) const KIND: &str = "cold_wake_compact";
/// Its prompt id's prefix: the inbox steers nothing into its turn.
pub(crate) const COMPACT_ID_PREFIX: &str = "cold-wake-compact-";
/// The shortest batch window of a cold chat.
pub(crate) const MIN_WINDOW_MS: u64 = 60_000;
/// The longest batch window of a cold chat.
pub(crate) const MAX_WINDOW_MS: u64 = 5 * 60_000;
/// The context at which the window is longest.
pub(crate) const SIZE_FULL_TOKENS: u64 = 200_000;
/// How long cold a chat is when its window is longest.
pub(crate) const COLD_FULL_MS: u64 = 30 * 60_000;
/// The context below which a cold chat opens no batch: re-reading it uncached costs little, so
/// its wakes go in as before (a chat with no usage reported yet included).
pub(crate) const MIN_BATCH_TOKENS: u64 = 20_000;
/// The context from which a cold batch compacts first, by default. 50K, not 100K: the cold
/// batches measured on one lane VM over 48 h were 75.9K, 85.3K and 89.2K, none compacted, and
/// each post-idle wake rewrote 64K-123K tokens into the cache while reading 9.9K from it.
/// `agents.coldWake.compactAboveTokens` (or [`ENV_COMPACT_ABOVE`]) moves it within
/// [`COMPACT_ABOVE_RANGE`] (Leo, 2026-11-25: "if we know for a fact 50k is beter, if people can
/// adjust it, fine").
pub(crate) const DEFAULT_COMPACT_ABOVE_TOKENS: u64 = 50_000;
/// The range the compaction line is clamped to.
pub(crate) const COMPACT_ABOVE_RANGE: (u64, u64) = (10_000, 500_000);
/// Settings > General > Prompt Cache: batch a cold chat's wakes on an interval (on by default).
pub const SETTING_ENABLED: &str = "agents.coldWake.enabled";
/// And compact a large cold chat before its batch goes in (on by default; Leo, 2026-11-24: "this
/// can be toggled but... this as a default seems decent").
pub const SETTING_COMPACT: &str = "agents.coldWake.compact";
/// The context (tokens) from which a cold batch compacts first ([`DEFAULT_COMPACT_ABOVE_TOKENS`]).
pub const SETTING_COMPACT_ABOVE: &str = "agents.coldWake.compactAboveTokens";
/// `0|1` in the daemon's environment: [`SETTING_ENABLED`], whatever the settings file says.
pub const ENV_ENABLED: &str = "ACPMUX_COLD_WAKE";
/// `0|1`: [`SETTING_COMPACT`], whatever the settings file says.
pub const ENV_COMPACT: &str = "ACPMUX_COLD_WAKE_COMPACT";
/// A token count: [`SETTING_COMPACT_ABOVE`], whatever the settings file says.
pub const ENV_COMPACT_ABOVE: &str = "ACPMUX_COLD_COMPACT_ABOVE_TOKENS";

/// The cold wake's knobs as the daemon reads them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Knobs {
    /// Batch a cold chat's wakes.
    pub enabled: bool,
    /// Compact a large cold chat first (needs `enabled`).
    pub compact: bool,
    /// The context from which it compacts first.
    pub compact_above: u64,
}

/// An on/off environment value: `1|true|on` or `0|false|off`; anything else (or unset) says
/// nothing and the settings file decides.
pub(crate) fn env_flag(value: Option<&str>) -> Option<bool> {
    match value?.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

/// The knobs as `doc` (the settings file) and `env` (the daemon's environment) have them, the
/// environment winning. A missing key, file or an unreadable file is the default: on, at
/// [`DEFAULT_COMPACT_ABOVE_TOKENS`]; compacting first needs batching on; a line out of
/// [`COMPACT_ABOVE_RANGE`] is clamped to it, and a non-number is the default.
pub(crate) fn settings_with(doc: Option<&Value>, env: impl Fn(&str) -> Option<String>) -> Knobs {
    let get = |key: &str| doc.and_then(|d| crate::user_settings::value(d, key));
    let flag = |key: &str, var: &str| {
        env_flag(env(var).as_deref()).or_else(|| get(key).and_then(|v| v.as_bool())).unwrap_or(true)
    };
    let enabled = flag(SETTING_ENABLED, ENV_ENABLED);
    let compact = enabled && flag(SETTING_COMPACT, ENV_COMPACT);
    let from_env = env(ENV_COMPACT_ABOVE).and_then(|v| v.trim().parse::<f64>().ok());
    let line = from_env
        .or_else(|| get(SETTING_COMPACT_ABOVE).and_then(|v| v.as_f64()))
        .filter(|n| n.is_finite())
        .map_or(DEFAULT_COMPACT_ABOVE_TOKENS, |n| {
            n.clamp(COMPACT_ABOVE_RANGE.0 as f64, COMPACT_ABOVE_RANGE.1 as f64) as u64
        });
    Knobs { enabled, compact, compact_above: line }
}

/// The knobs from the settings file alone, the environment unset.
#[cfg(test)]
pub(crate) fn settings(doc: Option<&Value>) -> Knobs {
    settings_with(doc, |_| None)
}

fn read_settings() -> Knobs {
    let env = |var: &str| std::env::var(var).ok();
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_with(Some(&doc), env),
        _ => settings_with(None, env),
    }
}

/// A chat whose usage names no cache expiry is cold this long after its last turn ended (the
/// prompt cache's default lifetime).
pub(crate) const NO_EXPIRY_TTL_MS: u64 = 5 * 60_000;

/// How long the chat of `meta` has been cold at `now` (unix ms), and its context's tokens; None
/// while its cache is warm, nothing says when it lapses (no turn ended yet), or its context is
/// under [`MIN_BATCH_TOKENS`].
pub(crate) fn coldness(meta: &SessionMeta, now: u64) -> Option<(u64, u64)> {
    let usage = meta.usage.as_ref();
    let expires =
        usage.and_then(|u| u.pointer("/_meta/acpmux/cacheExpiresAt")).and_then(Value::as_u64);
    let ended = meta.last_turn.as_ref().and_then(|t| t.get("endedAt")).and_then(Value::as_u64);
    // The later of the two: a turn that ended after the usage that named the expiry (one that
    // reported none) still warmed the cache.
    let expires = match (expires, ended.map(|e| e.saturating_add(NO_EXPIRY_TTL_MS))) {
        (Some(a), Some(b)) => a.max(b),
        (a, b) => a.or(b)?,
    };
    let cold = now.checked_sub(expires).filter(|c| *c > 0)?;
    let tokens = usage.and_then(|u| u.get("used")).and_then(Value::as_u64).unwrap_or(0);
    (tokens >= MIN_BATCH_TOKENS).then_some((cold, tokens))
}

/// The batch window of a chat `cold_ms` cold with `tokens` of context (module docs).
pub(crate) fn window_ms(cold_ms: u64, tokens: u64) -> u64 {
    let size = (tokens as f64 / SIZE_FULL_TOKENS as f64).min(1.0);
    let cold = (cold_ms as f64 / COLD_FULL_MS as f64).min(1.0);
    let spread = (MAX_WINDOW_MS - MIN_WINDOW_MS) as f64 * size.max(cold);
    MIN_WINDOW_MS + spread as u64
}

/// Whether a cold batch of a chat with `tokens` of context compacts first, at the compaction line
/// `line` ([`Knobs::compact_above`]).
pub(crate) fn compacts(tokens: u64, line: u64) -> bool {
    tokens >= line
}

/// Whether surgery's dry run (`surgery.rs`, `dryRun: true`) says masking alone takes the chat
/// under `line` ([`Knobs::compact_above`]), the line that sends it to `/compact`: then surgery reaches
/// what the compaction would, with no model call and nothing summarized away. A chat it leaves
/// above the line still needs `/compact`, and surgery on top would only add a harness restart
/// and a second rewritten prefix, so it compacts alone. No estimate (no stored usage) is no.
pub(crate) fn surgery_suffices(dry: &Result<Value, RpcError>, line: u64) -> bool {
    let Ok(dry) = dry else { return false };
    let masked = dry.get("maskedResults").and_then(Value::as_u64).unwrap_or(0);
    let after = dry.get("tokensAfter").and_then(Value::as_u64);
    dry.get("dryRun").and_then(Value::as_bool) == Some(true)
        && masked > 0
        && after.is_some_and(|a| a < line)
}

/// Whether a surgery's answer says it applied: anything else (`applied: false`, an error) keeps
/// the `/compact` a cold batch ran before surgery.
pub(crate) fn surgery_applied(answer: &Result<Value, RpcError>) -> bool {
    answer.as_ref().is_ok_and(|v| v.get("applied").and_then(Value::as_bool) == Some(true))
}

/// Whether a prompt's provenance is a cold batch's compaction.
pub(crate) fn is_own(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(KIND)
}

/// Whether the running turn is a cold batch's compaction: nothing steers into it.
pub(crate) fn compaction_runs(session: &Session) -> bool {
    session.turn().is_some_and(|t| t.prompt_id.starts_with(COMPACT_ID_PREFIX))
}

/// A batch's deadline (unix ms), as `Session::cold_batch` holds it.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Batch {
    pub due: u64,
}

impl Hub {
    /// The deadline of `session`'s cold batch at `now` (unix ms): the open one, else one opened
    /// now when the chat is cold (and its compaction started, module docs). None while warm.
    /// Never called under the inbox's lock with the batch's lock held after it the other way.
    pub(super) fn cold_batch_due(
        self: &Arc<Self>,
        session: &Arc<Session>,
        meta: &SessionMeta,
        now: u64,
    ) -> Option<u64> {
        let mut batch = session.cold_batch.lock().unwrap_or_else(|e| e.into_inner());
        // A batch no turn took for a whole window past its deadline (its messages left) is over.
        if let Some(b) = *batch {
            if b.due.saturating_add(MAX_WINDOW_MS) >= now {
                return Some(b.due);
            }
            *batch = None;
        }
        let (cold, tokens) = coldness(meta, now)?;
        // Read once per batch opened, not per message: a cold chat opens one per idle stretch.
        let knobs = read_settings();
        if !knobs.enabled {
            return None;
        }
        let window = window_ms(cold, tokens);
        let due = now.saturating_add(window);
        *batch = Some(Batch { due });
        drop(batch);
        tracing::info!(session = %session.id, window_ms = window, tokens, cold_ms = cold, "cold wake batch opened");
        let line = knobs.compact_above;
        if knobs.compact && compacts(tokens, line) {
            let (hub, s) = (self.clone(), session.clone());
            self.scope.spawn_named(
                "cold-wake-compact",
                Box::pin(async move { hub.cold_wake_compact(&s, tokens, line).await }),
            );
        }
        Some(due)
    }

    /// A turn started in `session`: its batch went in with it, unless it is the batch's own
    /// compaction, which the batch waits behind.
    pub(super) fn cold_batch_turn_started(&self, session: &Session) {
        let taken = !compaction_runs(session)
            && session.cold_batch.lock().unwrap_or_else(|e| e.into_inner()).take().is_some();
        session.cold_batch_turn.store(taken, Ordering::SeqCst);
    }

    /// `/compact` ahead of a cold batch, if the chat's agent is Claude Code and it may be
    /// compacted now: no turn, nobody typing, no draft, no Web or phone turn last
    /// (`cache_compact.rs`). A message gathering in the queue does not count: it waits for the
    /// batch anyway.
    async fn cold_wake_compact(self: &Arc<Self>, session: &Arc<Session>, tokens: u64, line: u64) {
        if !self.can_compact(session).await {
            return;
        }
        let last = session.meta().last_turn.as_ref().and_then(|t| t.get("turnId").cloned());
        let Some(last) = last.and_then(|t| t.as_str().map(str::to_owned)) else { return };
        if session.turn().is_some() || !self.cold_compact_ready(session) {
            tracing::info!(session = %session.id, tokens, "cold wake compaction skipped: chat busy");
            return;
        }
        let opts = PromptOptions {
            prompt_id: Some(format!("{COMPACT_ID_PREFIX}{}", uuid::Uuid::now_v7())),
            provenance: Some(json!({"kind": KIND})),
            no_queue: true,
            after_turn: Some(last),
            ..PromptOptions::default()
        };
        // Surgery first (`surgery.rs`): it masks old tool output with no model call; `/compact`
        // only when it says no (off, not a stored Claude conversation, nothing to mask, too
        // little to mask) or fails.
        if self.cold_wake_surgery(session, tokens, line).await {
            self.inbox_review(session);
            return;
        }
        tracing::info!(session = %session.id, tokens, "cold wake compaction");
        let blocks = vec![json!({"type": "text", "text": "/compact"})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", false, opts).await {
            tracing::info!(session = %session.id, error = ?e, "cold wake compaction not sent");
        }
        // Its end reviews the inbox (`inbox_turn_ended`); the batch goes in at its deadline.
        self.inbox_review(session);
    }

    /// Context surgery in place of a cold batch's `/compact`: a dry run first, then the real one
    /// when masking alone takes the chat under the compaction line `line`
    /// ([`surgery_suffices`]). True when it applied: the chat resumed on the masked copy and needs no `/compact`. Called
    /// without the turn lock: surgery takes it itself, and refuses a chat mid-turn.
    async fn cold_wake_surgery(
        self: &Arc<Self>,
        session: &Arc<Session>,
        tokens: u64,
        line: u64,
    ) -> bool {
        let dry = self.surgery(session, None, true).await;
        if !surgery_suffices(&dry, line) {
            tracing::info!(session = %session.id, tokens, outcome = ?dry.as_ref().map_err(|e| &e.message), "cold wake surgery skipped");
            return false;
        }
        let answer = self.surgery(session, None, false).await;
        let applied = surgery_applied(&answer);
        tracing::info!(session = %session.id, tokens, applied, outcome = ?answer.as_ref().map_err(|e| &e.message), "cold wake surgery");
        applied
    }

    /// `cache_compact.rs`'s check but for the queue: no turn holds the lock, no Web or phone turn
    /// was last, nobody is typing and no composer holds unsent text.
    fn cold_compact_ready(&self, session: &Session) -> bool {
        let free = session.turn_lock.try_lock().is_ok();
        let remote = session.floor.last_turn_web.load(Ordering::SeqCst)
            || session.floor.cloud_mobile_turn.load(Ordering::SeqCst);
        let presence = self.presence.snapshot(&session.id);
        let typing = presence.get("participants").and_then(Value::as_array).is_some_and(|people| {
            people.iter().any(|p| p.get("typing").and_then(Value::as_bool) == Some(true))
        });
        let draft = session
            .read_meta(|m| m.composer_draft.as_deref().is_some_and(|d| !d.trim().is_empty()))
            || session.composers.lock().unwrap_or_else(|e| e.into_inner()).any_draft();
        free && !remote && !typing && !draft
    }
}

#[cfg(test)]
#[path = "cold_wake_tests.rs"]
mod tests;
