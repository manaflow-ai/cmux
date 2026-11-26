//! Part of `Hub`; see `hub/mod.rs`. Compact an idle Claude chat before its prompt cache expires
//! (Leo, 2026-11-03: "idk if we maybe also wanna be showing that/opt-in autocompact around that
//! 5min mark").
//!
//! The chat's `usage_update`s carry when its prompt cache lapses (`_meta.acpmux.cacheExpiresAt`,
//! `claude_stdio/prompt_cache.rs`). With Settings > General > Prompt Cache's "Compact Before the
//! Cache Expires" on (`agents.cacheCompact.enabled`, on by default since 2026-11-24; only an
//! explicit `false` turns it off), each such update arms one timer for the session, [`lead_ms`] before
//! that expiry, while the context is at least `agents.cacheCompact.minContextTokens` tokens or
//! `agents.cacheCompact.minContextPercent` of its window, whichever trips first ([`Threshold`]).
//! When it fires, the chat runs Claude Code's `/compact` as acpmux's own prompt
//! ([`KIND`]), which reads the still-warm cache.
//!
//! Why on, at 30% (Leo, 2026-11-24: "we need to be compacting arguably BEFORE cache expires...",
//! "this can be toggled but... this as a default seems decent."): off by default, nothing fired in
//! 48 h on one lane VM, and every wake after a 55+ min idle rewrote its whole context (60K-123K
//! tokens; the cache read only the shared ~10K prefix). Over 67 warm compactions (mean 146K
//! tokens before), one read about 12K from cache and wrote about 23K: about 40% of the cold
//! rewrite it saves, so it pays once more than ~40% of idle chats are woken again. Most contexts
//! there were 60-100K, which a 50% threshold on a 200K window misses and 30% catches.
//!
//! Why also an absolute bar, 60K tokens (2026-11-25): the percent alone is of the window the
//! chat reports, and every chat measured then reported a 1M window, so 30% meant 300K: above the
//! 178.5K autocompact cap, so it never fired. Warm compaction saved 70% of the wake at 99K and
//! 82% at 218K; it pays when a chat comes back more than 30% of the time at 50K, 15% at 100K.
//! Of 20 post-idle wakes, 13 were at 60K or more and 7 at 100K or more. The test
//! `the_default_trigger_fires_under_the_autocompact_cap_whatever_the_window` keeps it reachable.
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
//! Tuning: [`ENV_ENABLED`] (`0|1`) and [`ENV_MIN_CONTEXT`] (a percent) in the daemon's
//! environment beat the two settings (the crate's README, "Tuning compaction").
//!
//! The idle reaper (`idle.rs`) stops a harness after its idle period (2 min by default), long
//! before the timer's deadline, and a compaction into the respawned harness runs cold: on one
//! lane VM every measured `/compact` into a resumed harness read about 3K and wrote about 131K
//! tokens, 570-1,833 s after the last request, well inside the 1 h TTL. So the reaper asks
//! first ([`Hub::cache_compact_before_reap`]): a session due to sleep with this timer armed
//! compacts now, into the live harness while its cache is warm, and sleeps on a later pass. The
//! timer's entry goes as it is taken, so a compaction its gates refuse (a draft, a Web turn
//! last) keeps the harness up for at most one more idle period, never for good.
//!
//! A turn of [`KIND`] that fails is not continued by `auto_resume.rs` (`turns.rs`): the next
//! turn's usage arms the timer again, and a continuation would be a model call nobody asked for.

use super::*;

/// The provenance kind of the compaction this timer sends.
pub(crate) const KIND: &str = "cache_compact";
/// How long before a 5-minute cache's expiry the compaction runs: room for the request to reach
/// the model while the cache is still warm.
pub(crate) const LEAD_MS: u64 = 30_000;
/// How long before a 1-hour cache's expiry it runs (Leo, 2026-11-24: "so compact at 59:59 or 3
/// min early? what are the actual numbers on warm vs cold compaction cost?"). The expiry is the
/// last call's `message_start` plus the TTL (`claude_stdio/prompt_cache.rs`), so it runs late by
/// that call's wait for its first token, and the compaction's own request waits as long again.
/// From a prompt to its call's first block, 896 main-loop calls over 3 days on one host
/// (2026-11-24, thinking and tool-input streaming taken out): p50 3.3 s, p90 6.8 s, p99 80 s,
/// p99.9 437 s. Both waits together pass 30 s for 4.8% of compactions, 60 s for 3.1%, 120 s for
/// 1.4%, 180 s for 0.9% and 300 s for 0.4%. A cold compaction rewrites the whole context, about
/// 4x a warm one's cost, and each minute earlier spends a minute of idle in which a real turn
/// could have come and made it unneeded: 3 minutes is where the misses stop paying for it.
pub(crate) const LONG_LEAD_MS: u64 = 180_000;
/// Time left on a cache above which it is the 1-hour tier, not the 5-minute one.
const LONG_CACHE_MS: u64 = 10 * 60_000;

/// How long before the expiry the compaction runs for a cache with `left_ms` to go.
pub(crate) fn lead_ms(left_ms: u64) -> u64 {
    if left_ms > LONG_CACHE_MS { LONG_LEAD_MS } else { LEAD_MS }
}
/// The armed timers: session id -> (generation, the task).
static TIMERS: std::sync::LazyLock<StdMutex<TimerMap>> = std::sync::LazyLock::new(Default::default);
static GENERATION: AtomicU64 = AtomicU64::new(0);
/// session id -> (generation, the task, the cache expiry it was armed for, the context `(used, size)`).
type TimerMap = HashMap<String, (u64, tokio::task::AbortHandle, u64, (u64, u64))>;
pub const SETTING_ENABLED: &str = "agents.cacheCompact.enabled";
pub const SETTING_MIN_CONTEXT: &str = "agents.cacheCompact.minContextPercent";
/// `0|1` in the daemon's environment: [`SETTING_ENABLED`], whatever the settings file says.
pub const ENV_ENABLED: &str = "ACPMUX_CACHE_COMPACT";
/// A percent: [`SETTING_MIN_CONTEXT`], whatever the settings file says.
pub const ENV_MIN_CONTEXT: &str = "ACPMUX_CACHE_COMPACT_MIN_CONTEXT_PERCENT";
/// The context (tokens) from which the timer compacts, whatever the window.
pub const SETTING_MIN_TOKENS: &str = "agents.cacheCompact.minContextTokens";
/// A token count: [`SETTING_MIN_TOKENS`], whatever the settings file says.
pub const ENV_MIN_TOKENS: &str = "ACPMUX_CACHE_COMPACT_MIN_CONTEXT_TOKENS";
const DEFAULT_MIN_CONTEXT: f64 = 30.0;
const MIN_CONTEXT_RANGE: (f64, f64) = (10.0, 95.0);
pub(crate) const DEFAULT_MIN_TOKENS: u64 = 60_000;
pub(crate) const MIN_TOKENS_RANGE: (u64, u64) = (10_000, 500_000);

/// What arms the timer: a context of at least `tokens`, or at least `share` (0-1) of its window,
/// whichever trips first.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Threshold {
    pub share: f64,
    pub tokens: u64,
}

/// The Settings keys as the daemon reads them, the settings file alone.
#[cfg(test)]
pub(crate) fn settings_threshold(doc: Option<&Value>) -> Option<Threshold> {
    settings_threshold_with(doc, |_| None)
}

/// The Settings keys and their environment overrides (`env`, which wins) as the daemon reads
/// them: None when off (only an explicit `agents.cacheCompact.enabled: false` or
/// `ACPMUX_CACHE_COMPACT=0`), else what a chat must reach. No document (no settings file) is
/// the defaults: on, at [`DEFAULT_MIN_TOKENS`] or [`DEFAULT_MIN_CONTEXT`] percent.
pub(crate) fn settings_threshold_with(
    doc: Option<&Value>,
    env: impl Fn(&str) -> Option<String>,
) -> Option<Threshold> {
    let get = |key: &str| doc.and_then(|doc| crate::user_settings::value(doc, key));
    let enabled = super::super::cold_wake::env_flag(env(ENV_ENABLED).as_deref())
        .or_else(|| get(SETTING_ENABLED).and_then(|v| v.as_bool()));
    if enabled == Some(false) {
        return None;
    }
    let percent = env(ENV_MIN_CONTEXT)
        .and_then(|v| v.trim().parse::<f64>().ok())
        .or_else(|| get(SETTING_MIN_CONTEXT).and_then(|v| v.as_f64()))
        .filter(|n| n.is_finite())
        .map_or(DEFAULT_MIN_CONTEXT, |n| n.clamp(MIN_CONTEXT_RANGE.0, MIN_CONTEXT_RANGE.1));
    let tokens = env(ENV_MIN_TOKENS)
        .and_then(|v| v.trim().parse::<f64>().ok())
        .or_else(|| get(SETTING_MIN_TOKENS).and_then(|v| v.as_f64()))
        .filter(|n| n.is_finite())
        .map_or(DEFAULT_MIN_TOKENS, |n| {
            n.clamp(MIN_TOKENS_RANGE.0 as f64, MIN_TOKENS_RANGE.1 as f64) as u64
        });
    Some(Threshold { share: percent / 100.0, tokens })
}

fn read_threshold() -> Option<Threshold> {
    let env = |var: &str| std::env::var(var).ok();
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_threshold_with(Some(&doc), env),
        crate::user_settings::Settings::Missing => settings_threshold_with(None, env),
        // A file that exists but cannot be parsed may hold an explicit `false`: arm nothing until
        // it reads again rather than override what it may say (unless the environment says on).
        crate::user_settings::Settings::Unreadable(_) => {
            if super::super::cold_wake::env_flag(env(ENV_ENABLED).as_deref()) == Some(true) {
                settings_threshold_with(None, env)
            } else {
                None
            }
        }
    }
}

/// How long from `now_ms` until the compaction runs for a `usage_update` (`used` of `size`
/// tokens, the cache lapsing at `expires_ms`), with `threshold` what it needs. None: no
/// timer (no expiry, under the threshold, or too close to the expiry to run in time).
pub(crate) fn wait_ms(update: &Value, threshold: Threshold, now_ms: u64) -> Option<u64> {
    let expires = update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64)?;
    if !over(context(update)?, threshold) {
        return None;
    }
    let fire = expires.checked_sub(lead_ms(expires.saturating_sub(now_ms)))?;
    fire.checked_sub(now_ms).filter(|wait| *wait > 0)
}

/// The context a `usage_update` reports: (tokens used, the window, 0 when it names none).
fn context(update: &Value) -> Option<(u64, u64)> {
    let used = update.get("used").and_then(Value::as_u64)?;
    Some((used, update.get("size").and_then(Value::as_u64).unwrap_or(0)))
}

/// Whether a context of `used` tokens in a window of `size` is compacted at `threshold`: at its
/// token bar, or at its share of a known window.
pub(crate) fn over((used, size): (u64, u64), threshold: Threshold) -> bool {
    used >= threshold.tokens || (size > 0 && used as f64 / size as f64 >= threshold.share)
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
            self.cache_compact_on_usage(session, update);
        } else if update.is_some_and(|u| !replayed && completed_compaction(u)) {
            Self::cache_compact_disarm(&session.id);
        }
    }

    /// Ends `session`'s armed timer, if one is.
    fn cache_compact_disarm(id: &str) {
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer, ..)) = timers.remove(id) {
            timer.abort();
        }
    }

    /// The idle reaper is about to stop `session`'s harness (`idle.rs` `idle_exit`): when its
    /// timer is armed, the timer ends and the compaction runs now, into the live harness, on a
    /// task of its own; true keeps the harness up for it (module docs). False when no timer is
    /// armed (off, under the threshold, no cache expiry, or already compacted) or the hub is
    /// gone.
    pub(in crate::hub) fn cache_compact_before_reap(&self, session: &Arc<Session>) -> bool {
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else {
            return false;
        };
        let armed = {
            let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
            timers.remove(&session.id)
        };
        let Some((_, timer, expires, used)) = armed else { return false };
        timer.abort();
        tracing::info!(session = %session.id, "cache compaction runs before the idle stop");
        let session = session.clone();
        self.scope.spawn_until_cancelled("cache-compact-before-reap", async move {
            hub.cache_compact_fire(&session, expires, used).await;
        });
        true
    }

    /// A live (not replayed) `usage_update` of `session`: arms its timer again (module docs).
    fn cache_compact_on_usage(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer, ..)) = timers.remove(&session.id) {
            timer.abort();
        }
        let Some(threshold) = read_threshold() else { return };
        let Some(wait) = wait_ms(update, threshold, now_ms()) else { return };
        let Some(used) = context(update) else { return };
        let Some(expires) = update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64)
        else {
            return;
        };
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
                let own = timers.get(&id).is_some_and(|(g, ..)| *g == generation);
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
        timers.insert(session.id.clone(), (generation, task.abort_handle(), expires, used));
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
        used: (u64, u64),
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
