//! Part of `Hub`; see `hub/mod.rs`. Compact an idle Claude chat before its prompt cache expires
//! (Leo, 2026-11-03: "idk if we maybe also wanna be showing that/opt-in autocompact around that
//! 5min mark").
//!
//! The chat's `usage_update`s carry when its prompt cache lapses (`_meta.acpmux.cacheExpiresAt`,
//! `claude_stdio/prompt_cache.rs`). With Settings > General > Prompt Cache's "Compact Before the
//! Cache Expires" on (`agents.cacheCompact.enabled`, off by default: a compaction is a model call
//! that counts toward usage), each such update arms one timer for the session, [`LEAD_MS`] before
//! that expiry, while the context is at least `agents.cacheCompact.minContextPercent` of its
//! window. When it fires, the chat runs Claude Code's `/compact` as acpmux's own prompt
//! ([`KIND`]), which reads the still-warm cache.
//!
//! It fires only when the chat is idle (no turn running or starting, nothing queued, no
//! permission, question or continuation waiting), nobody is typing in it and its composer holds no
//! draft; it is sent `no_queue`, so a turn that starts at that moment refuses it rather than
//! queueing it. It runs once per idle stretch: after it fires, no timer is armed until a prompt of
//! the person's (or any prompt but this one) runs.
//!
//! The timer: one task per session (`Session::cache_compact_timer`). Stop condition: it fires once
//! at its deadline and ends. Cleanup: every new `usage_update` aborts the previous one before
//! arming (a turn's own updates, a new expiry, none for a compacted context), and so does the
//! session's next prompt (`prompt_started`); it holds only weak references, so a dropped session
//! or hub ends it at its deadline without effect.

use super::*;

/// The provenance kind of the compaction this timer sends.
pub(crate) const KIND: &str = "cache_compact";
/// How long before the cache's expiry the compaction runs: room for the request to reach the
/// model while the cache is still warm.
pub(crate) const LEAD_MS: u64 = 30_000;
pub const SETTING_ENABLED: &str = "agents.cacheCompact.enabled";
pub const SETTING_MIN_CONTEXT: &str = "agents.cacheCompact.minContextPercent";
const DEFAULT_MIN_CONTEXT: f64 = 50.0;
const MIN_CONTEXT_RANGE: (f64, f64) = (10.0, 95.0);

/// The Settings keys as the daemon reads them: None when off (the default, a missing or
/// unreadable file included), else the context share (0-1) a chat must reach.
pub(crate) fn settings_threshold(doc: Option<&Value>) -> Option<f64> {
    let doc = doc?;
    let get = |key: &str| crate::user_settings::value(doc, key);
    if get(SETTING_ENABLED).and_then(|v| v.as_bool()) != Some(true) {
        return None;
    }
    let percent = get(SETTING_MIN_CONTEXT)
        .and_then(|v| v.as_f64())
        .filter(|n| n.is_finite())
        .map_or(DEFAULT_MIN_CONTEXT, |n| n.clamp(MIN_CONTEXT_RANGE.0, MIN_CONTEXT_RANGE.1));
    Some(percent / 100.0)
}

fn read_threshold() -> Option<f64> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_threshold(Some(&doc)),
        _ => None,
    }
}

/// How long from `now_ms` until the compaction runs for a `usage_update` (`used` of `size`
/// tokens, the cache lapsing at `expires_ms`), with `threshold` the share it needs. None: no
/// timer (no expiry, under the threshold, or too close to the expiry to run in time).
pub(crate) fn wait_ms(update: &Value, threshold: f64, now_ms: u64) -> Option<u64> {
    let expires = update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64)?;
    let used = update.get("used").and_then(Value::as_u64)?;
    let size = update.get("size").and_then(Value::as_u64).filter(|s| *s > 0)?;
    if (used as f64) < threshold * size as f64 {
        return None;
    }
    let fire = expires.checked_sub(LEAD_MS)?;
    fire.checked_sub(now_ms).filter(|wait| *wait > 0)
}

/// Whether a prompt is this timer's compaction.
pub(crate) fn is_compaction(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(KIND)
}

impl Hub {
    /// A live (not replayed) `usage_update` of `session`: arms its timer again (module docs).
    pub(super) fn cache_compact_on_usage(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        self.disarm_cache_compact(session);
        if session.cache_compacted.load(Ordering::SeqCst) {
            return;
        }
        let Some(threshold) = read_threshold() else { return };
        let Some(wait) = wait_ms(update, threshold, now_ms()) else { return };
        let deadline = self.clock_now().saturating_add(wait.saturating_mul(1_000_000));
        let clock = self.clock.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let hub = Arc::downgrade(self);
        let weak = Arc::downgrade(session);
        let task = tokio::spawn(async move {
            clock.sleep_until(std::time::Duration::from_nanos(deadline)).await;
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.cache_compact_fire(&session).await;
        });
        *session.cache_compact_timer.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(task.abort_handle());
    }

    /// Aborts `session`'s timer, if one is armed.
    pub(super) fn disarm_cache_compact(&self, session: &Session) {
        if let Some(timer) =
            session.cache_compact_timer.lock().unwrap_or_else(|e| e.into_inner()).take()
        {
            timer.abort();
        }
    }

    /// A prompt of `session` starts: its timer goes, and any prompt but the compaction itself
    /// begins a new idle stretch.
    pub(super) fn cache_compact_prompt_started(
        &self,
        session: &Session,
        provenance: Option<&Value>,
    ) {
        self.disarm_cache_compact(session);
        if !is_compaction(provenance) {
            session.cache_compacted.store(false, Ordering::SeqCst);
        }
    }

    /// Whether `session` may be compacted now: idle, nobody typing, no draft (module docs).
    fn cache_compact_ready(&self, session: &Session) -> bool {
        let idle = !self.stopping.load(Ordering::SeqCst)
            && matches!(session.status(), SessionStatus::Ready | SessionStatus::Idle)
            && session.turn().is_none()
            && !session.harness_turn.load(Ordering::SeqCst)
            && session.asks_in_flight.load(Ordering::SeqCst) == 0
            && session.queued() == 0
            && session.pending_permissions().is_empty()
            && session.agent_requests.load(Ordering::SeqCst) == 0
            && !self.continuation_pending(session)
            && session.turn_lock.try_lock().is_ok();
        let typing = self.presence.snapshot(&session.id)["participants"]
            .as_array()
            .is_some_and(|people| people.iter().any(|p| p["typing"] == true));
        let draft = session
            .read_meta(|m| m.composer_draft.as_deref().is_some_and(|d| !d.trim().is_empty()));
        idle && !typing && !draft
    }

    async fn cache_compact_fire(self: &Arc<Self>, session: &Arc<Session>) {
        session.cache_compact_timer.lock().unwrap_or_else(|e| e.into_inner()).take();
        if session.cache_compacted.load(Ordering::SeqCst) || !self.cache_compact_ready(session) {
            return;
        }
        // Read again: the setting may have been turned off since the timer was armed.
        if read_threshold().is_none() {
            return;
        }
        session.cache_compacted.store(true, Ordering::SeqCst);
        let opts = PromptOptions {
            prompt_id: Some(format!("cache-compact-{}", uuid::Uuid::now_v7())),
            provenance: Some(json!({"kind": KIND})),
            no_queue: true,
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": "/compact"})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", false, opts).await {
            tracing::info!(session = %session.id, error = ?e, "cache compaction not sent");
        }
    }
}
