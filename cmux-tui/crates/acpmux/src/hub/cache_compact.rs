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
//! permission, question or continuation waiting), nobody is typing in it, its composer holds no
//! draft and its last turn was not a Web or phone one (a local prompt would lift the remote
//! floor that turn left, `remote_floor.rs`); it is sent `no_queue`, so a turn that starts at that
//! moment refuses it rather than queueing it. It runs once per idle stretch: the compaction's own
//! context is far under any threshold, so its usage arms no timer, and the next turn's usage arms
//! one again.
//!
//! The timer: one task per session, in [`TIMERS`] under the session's id with a generation of its
//! own. Stop condition: it fires once at its deadline and ends, removing its entry if the entry is
//! still its own. Cleanup: every new live `usage_update` of the session aborts and replaces it
//! (a turn's own updates, a new expiry, none for a compacted context); it holds only weak
//! references, so a dropped session or hub ends it at its deadline without effect.

use super::*;

/// The provenance kind of the compaction this timer sends.
pub(crate) const KIND: &str = "cache_compact";
/// How long before the cache's expiry the compaction runs: room for the request to reach the
/// model while the cache is still warm.
pub(crate) const LEAD_MS: u64 = 30_000;
/// The armed timers: session id -> (generation, the task, when the cache lapses in unix ms).
static TIMERS: std::sync::LazyLock<StdMutex<TimerMap>> = std::sync::LazyLock::new(Default::default);
static GENERATION: AtomicU64 = AtomicU64::new(0);
type TimerMap = HashMap<String, (u64, tokio::task::AbortHandle, u64)>;
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

impl Hub {
    /// `on_update` for an update the agent sent, then the timer for a live `usage_update`.
    pub(in crate::hub) fn on_update_cache(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Option<&Value>,
        replayed: bool,
    ) {
        self.on_update(session, params, replayed);
        let update = params.and_then(|p| p.get("update"));
        let usage =
            |u: &&Value| u.get("sessionUpdate").and_then(Value::as_str) == Some("usage_update");
        if let Some(update) = update.filter(|u| !replayed && usage(u)) {
            self.cache_compact_on_usage(session, update);
        }
    }

    /// A live (not replayed) `usage_update` of `session`: arms its timer again (module docs).
    fn cache_compact_on_usage(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer, _)) = timers.remove(&session.id) {
            timer.abort();
        }
        let Some(threshold) = read_threshold() else { return };
        let Some(wait) = wait_ms(update, threshold, now_ms()) else { return };
        let expires = now_ms() + wait + LEAD_MS;
        let deadline = self.clock_now().saturating_add(wait.saturating_mul(1_000_000));
        let clock = self.clock.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let generation = GENERATION.fetch_add(1, Ordering::SeqCst);
        let (hub, weak, id) = (Arc::downgrade(self), Arc::downgrade(session), session.id.clone());
        let task = tokio::spawn(async move {
            clock.sleep_until(std::time::Duration::from_nanos(deadline)).await;
            // Its own entry goes, or a later usage replaced it (the lock orders this after the
            // insert); a dropped session or hub leaves nothing behind.
            let own = {
                let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
                let own = timers.get(&id).is_some_and(|(g, _, _)| *g == generation);
                if own {
                    timers.remove(&id);
                }
                own
            };
            if !own {
                return;
            }
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.cache_compact_fire(&session, expires).await;
        });
        timers.insert(session.id.clone(), (generation, task.abort_handle(), expires));
    }

    /// Whether `session` may be compacted now: idle, nobody typing, no draft, no Web turn last
    /// (module docs).
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
        let remote = session.floor.last_turn_web.load(Ordering::SeqCst)
            || session.floor.cloud_mobile_turn.load(Ordering::SeqCst);
        let presence = self.presence.snapshot(&session.id);
        let typing = presence.get("participants").and_then(Value::as_array).is_some_and(|people| {
            people.iter().any(|p| p.get("typing").and_then(Value::as_bool) == Some(true))
        });
        let draft = session
            .read_meta(|m| m.composer_draft.as_deref().is_some_and(|d| !d.trim().is_empty()));
        idle && !remote && !typing && !draft
    }

    async fn cache_compact_fire(self: &Arc<Self>, session: &Arc<Session>, expires_ms: u64) {
        // Sent only while the chat still ends on the turn it ends on now (`after_turn`, checked
        // with no await before the turn is taken and again after). Read before the checks below:
        // a Web or phone turn that ends after this read refuses it at admission, and one that
        // started before the checks shows in them, so it never lifts that turn's remote floor.
        let last = session.meta().last_turn.as_ref().and_then(|t| t.get("turnId").cloned());
        let Some(last) = last.and_then(|t| t.as_str().map(str::to_owned)) else { return };
        // Read again: the setting may have been turned off since the timer was armed, and the
        // cache must still be warm when the request goes.
        if read_threshold().is_none()
            || now_ms() >= expires_ms
            || !self.cache_compact_ready(session)
        {
            return;
        }
        let opts = PromptOptions {
            prompt_id: Some(format!("cache-compact-{}", uuid::Uuid::now_v7())),
            provenance: Some(json!({"kind": KIND})),
            no_queue: true,
            after_turn: Some(last),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": "/compact"})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", false, opts).await {
            tracing::info!(session = %session.id, error = ?e, "cache compaction not sent");
        }
    }
}

#[cfg(test)]
#[path = "cache_compact_tests.rs"]
mod tests;
