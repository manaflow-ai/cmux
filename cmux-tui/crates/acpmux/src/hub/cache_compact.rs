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
//! It fires only when the chat is idle as the idle reaper judges it (no turn running or
//! starting, nothing queued, no permission, question, secret or continuation waiting, no
//! background subagent, sub-session or harness background process at work: `idle.rs`), the
//! context is still at least the threshold read at that moment, nobody is typing in it, no
//! composer (the shared draft or any surface's own) holds unsent text and its last turn was not
//! a Web or phone one (a local prompt would lift the remote floor that turn left,
//! `remote_floor.rs`); it is sent
//! `no_queue`, so a turn that starts at that moment refuses it rather than queueing it. It runs
//! once per idle stretch: the compaction's own context is far under any threshold, so its usage
//! arms no timer, and the next turn's usage arms one again.
//!
//! The timer: one task per session, in [`TIMERS`] under the session's id with a generation of its
//! own. Stop condition: it fires once at its deadline and ends, removing its entry if the entry is
//! still its own. Cleanup: every new live `usage_update` of the session aborts and replaces it
//! (a turn's own updates, a new expiry, none for a compacted context), and so does a completed
//! compaction (a person's `/compact` reports no usage after it, yet its cache is new); it holds
//! only weak references, so a dropped session or hub ends it at its deadline without effect.
//!
//! A turn of [`KIND`] that fails is not continued by `auto_resume.rs` (`turns.rs`): the next
//! turn's usage arms the timer again, and a continuation would be a model call nobody asked for.
//!
//! Before the person's next prompt (Leo, 2026-11-07: "i thought it'd do a thing where like... it
//! compacted BEFORE you sent a prompt automatically? ... if it had been a while and you were close
//! to the end of the context window anyways"), with no setting: a person's prompt to a Claude chat
//! whose prompt cache has lapsed ([`Session::cache_cold_at`], from the same `usage_update`s) and
//! whose context is at least [`BEFORE_PROMPT_SHARE`] of its window first runs `/compact` as
//! acpmux's own prompt (this [`KIND`], `"when": "before_prompt"`), and the person's prompt queues
//! behind it. A cold cache means the prompt would read the whole context again uncached anyway; the
//! compaction reads it once, and the prompt and the turns after it run on the summary instead of
//! hitting Claude Code's own compaction mid-turn. Only when the chat is idle as the timer requires
//! it (`cache_compact_ready`'s idle and remote-floor checks; the person is the one typing), never
//! for a slash command (the person's own `/compact` runs as typed), a steer, a resend or a prompt
//! that must not queue. Once per idle stretch: it clears the mark, and the compaction's own usage
//! names no cache expiry.

use super::*;

/// The provenance kind of the compaction this timer sends.
pub(crate) const KIND: &str = "cache_compact";
/// The provenance `when` of the compaction that runs before the person's prompt.
pub(crate) const BEFORE_PROMPT: &str = "before_prompt";
/// The context share (0-1) at which a cold chat compacts before the person's next prompt: "close
/// to the end of the context window", short of Claude Code's own compaction mid-turn.
pub(crate) const BEFORE_PROMPT_SHARE: f64 = 0.7;
/// How long the person's prompt waits for the compaction's turn to be taken before it goes on its
/// own (a refused or slow start never holds the person's prompt).
const BEFORE_PROMPT_ACCEPT: std::time::Duration = std::time::Duration::from_secs(10);
/// How long before the cache's expiry the compaction runs: room for the request to reach the
/// model while the cache is still warm.
pub(crate) const LEAD_MS: u64 = 30_000;
/// The armed timers: session id -> (generation, the task).
static TIMERS: std::sync::LazyLock<StdMutex<TimerMap>> = std::sync::LazyLock::new(Default::default);
static GENERATION: AtomicU64 = AtomicU64::new(0);
type TimerMap = HashMap<String, (u64, tokio::task::AbortHandle)>;
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
    if !over(share(update)?, threshold) {
        return None;
    }
    let fire = expires.checked_sub(LEAD_MS)?;
    fire.checked_sub(now_ms).filter(|wait| *wait > 0)
}

/// The share (0-1) of its context window a `usage_update` reports used.
fn share(update: &Value) -> Option<f64> {
    let used = update.get("used").and_then(Value::as_u64)?;
    let size = update.get("size").and_then(Value::as_u64).filter(|s| *s > 0)?;
    Some(used as f64 / size as f64)
}

/// Whether a context at `share` of its window is compacted at `threshold`.
pub(crate) fn over(share: f64, threshold: f64) -> bool {
    share >= threshold
}

/// Whether a prompt's provenance is this timer's compaction.
pub(crate) fn is_own(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(KIND)
}

fn completed_compaction(update: &Value) -> bool {
    update.get("sessionUpdate").and_then(Value::as_str) == Some("compaction")
        && update.get("state").and_then(Value::as_str) == Some("completed")
}

impl Hub {
    /// `on_update` for an update the agent sent, then the timer for a live `usage_update`, which
    /// arms it, or a completed compaction, which ends it.
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
            self.note_cache_cold_at(session, update);
            self.cache_compact_on_usage(session, update);
        } else if update.is_some_and(|u| !replayed && completed_compaction(u)) {
            session.cache_cold_at.store(0, Ordering::SeqCst);
            Self::cache_compact_disarm(&session.id);
        }
    }

    /// Notes when `session`'s prompt cache lapses, on the hub clock, from a live `usage_update`:
    /// none named (a compaction's, a subagent's, no cache use) clears it.
    fn note_cache_cold_at(&self, session: &Session, update: &Value) {
        let at = update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64).map_or(
            0,
            |expires| {
                let left_ns = expires.saturating_sub(now_ms()).saturating_mul(1_000_000);
                self.clock_now().saturating_add(left_ns).max(1)
            },
        );
        session.cache_cold_at.store(at, Ordering::SeqCst);
    }

    /// Before the person's prompt `blocks`: `/compact` first when the chat is cold, near the end of
    /// its window and idle (module docs). Returns once the compaction's turn is taken (the
    /// person's prompt then queues behind it), refused, or [`BEFORE_PROMPT_ACCEPT`] passed.
    pub(in crate::hub) async fn compact_before_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
    ) {
        let cold_at = session.cache_cold_at.load(Ordering::SeqCst);
        if cold_at == 0 || self.clock_now() < cold_at {
            return;
        }
        // A slash command (the person's own /compact, /clear, a skill) runs as typed.
        let first = blocks.iter().find_map(|b| b.get("text").and_then(Value::as_str));
        if first.is_some_and(|t| t.trim_start().starts_with('/')) {
            return;
        }
        let used = session.read_meta(|m| m.usage.as_ref().and_then(share));
        if !used.is_some_and(|used| over(used, BEFORE_PROMPT_SHARE)) {
            return;
        }
        let remote = session.floor.last_turn_web.load(Ordering::SeqCst)
            || session.floor.cloud_mobile_turn.load(Ordering::SeqCst);
        let idle = self.idle_eligible(session) && session.turn_lock.try_lock().is_ok();
        if remote || !idle || !self.can_compact(session).await {
            return;
        }
        // Once per idle stretch, even if the compaction is refused.
        session.cache_cold_at.store(0, Ordering::SeqCst);
        let (taken, accepted) = tokio::sync::oneshot::channel::<()>();
        let opts = PromptOptions {
            prompt_id: Some(format!("compact-before-prompt-{}", uuid::Uuid::now_v7())),
            provenance: Some(json!({"kind": KIND, "when": BEFORE_PROMPT})),
            no_queue: true,
            on_accepted: Some(Box::new(move |_| {
                let _ = taken.send(());
            })),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": "/compact"})];
        let (hub, target) = (self.clone(), session.clone());
        let compaction: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> = Box::pin(
            async move {
                if let Err(e) = hub.prompt_with(&target, blocks, "acpmux", false, opts).await {
                    tracing::info!(session = %target.id, error = ?e, "compaction before the prompt not run");
                }
            },
        );
        self.scope.spawn_named("compact-before-prompt", compaction);
        let _ = tokio::time::timeout(BEFORE_PROMPT_ACCEPT, accepted).await;
    }

    /// Ends `session`'s armed timer, if one is.
    fn cache_compact_disarm(id: &str) {
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer)) = timers.remove(id) {
            timer.abort();
        }
    }

    /// A live (not replayed) `usage_update` of `session`: arms its timer again (module docs).
    fn cache_compact_on_usage(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer)) = timers.remove(&session.id) {
            timer.abort();
        }
        let Some(threshold) = read_threshold() else { return };
        let Some(wait) = wait_ms(update, threshold, now_ms()) else { return };
        let Some(used) = share(update) else { return };
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
                let own = timers.get(&id).is_some_and(|(g, _)| *g == generation);
                if own {
                    timers.remove(&id);
                }
                own
            };
            if !own {
                return;
            }
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.cache_compact_fire(&session, expires, used).await;
        });
        timers.insert(session.id.clone(), (generation, task.abort_handle()));
    }

    /// Whether `session` may be compacted now: idle as the reaper judges it, nobody typing, no
    /// draft, no Web turn last (module docs).
    fn cache_compact_ready(&self, session: &Session) -> bool {
        let idle = self.idle_eligible(session) && session.turn_lock.try_lock().is_ok();
        let remote = session.floor.last_turn_web.load(Ordering::SeqCst)
            || session.floor.cloud_mobile_turn.load(Ordering::SeqCst);
        let presence = self.presence.snapshot(&session.id);
        let typing = presence.get("participants").and_then(Value::as_array).is_some_and(|people| {
            people.iter().any(|p| p.get("typing").and_then(Value::as_bool) == Some(true))
        });
        // The shared draft, and any surface's own unsent text (`_acpmux/composer_set`).
        let draft = session
            .read_meta(|m| m.composer_draft.as_deref().is_some_and(|d| !d.trim().is_empty()))
            || session.composers.lock().unwrap_or_else(|e| e.into_inner()).any_draft();
        idle && !remote && !typing && !draft
    }

    /// The timer's deadline: `/compact` for a chat at `used` of its window, if it still may be.
    async fn cache_compact_fire(
        self: &Arc<Self>,
        session: &Arc<Session>,
        expires_ms: u64,
        used: f64,
    ) {
        // Sent only while the chat still ends on the turn it ends on now (`after_turn`, checked
        // with no await before the turn is taken and again after). Read before the checks below:
        // a Web or phone turn that ends after this read refuses it at admission, and one that
        // started before the checks shows in them, so it never lifts that turn's remote floor.
        let last = session.meta().last_turn.as_ref().and_then(|t| t.get("turnId").cloned());
        let Some(last) = last.and_then(|t| t.as_str().map(str::to_owned)) else { return };
        // Read again: the setting may have been turned off or its threshold raised since the
        // timer was armed, and the cache must still be warm when the request goes.
        if read_threshold().is_none_or(|threshold| !over(used, threshold))
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
