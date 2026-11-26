//! Part of `Hub`; see `hub/mod.rs`. Compact an idle Claude chat before its prompt cache expires
//! (Leo, 2026-11-03: "idk if we maybe also wanna be showing that/opt-in autocompact around that
//! 5min mark").
//!
//! The chat's `usage_update`s carry when its prompt cache lapses (`_meta.acpmux.cacheExpiresAt`,
//! `claude_stdio/prompt_cache.rs`). With Settings > General > Prompt Cache's "Compact Before the
//! Cache Expires" on (`agents.cacheCompact.enabled`, off by default: only an explicit `true` or
//! `ACPMUX_CACHE_COMPACT=1` turns it on), each such update arms one timer for the session, [`lead_ms`] before
//! that expiry, while the context is at least `agents.cacheCompact.minContextTokens` tokens or
//! `agents.cacheCompact.minContextPercent` of its window, whichever trips first ([`Threshold`]).
//! When it fires, the chat runs Claude Code's `/compact` as acpmux's own prompt
//! ([`KIND`]), which reads the still-warm cache.
//!
//! Off by default since 2026-11-26 (Leo: "we ought to not make jcmux/acpmux so opinionated with
//! compacition. only do it for our personal fleet situation"): when to compact is the person's
//! call, and Claude Code compacts on its own terms otherwise. Our fleet turns it on in its own
//! settings. The numbers below are why the fleet runs it, at 30%.
//!
//! Why 30% (Leo, 2026-11-24: "we need to be compacting arguably BEFORE cache expires...",
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
//! Why an expected-cost rule over a floor (2026-11-25; Leo: "Honestly why not just compact
//! regardless of 30% or not"): the bars are now a floor (20K tokens, or the percent), and over it
//! [`pays`] decides at the deadline from the chat's odds of waking again ([`p_wake`]: a turn
//! coming, its lanes or sub-sessions at work, else its kind's measured share) and the model's own
//! prices. With a certain wake it pays from about 24K tokens; for an idle lane (P 0.65) from
//! about 32K; at 60K once P is over 0.32. Replayed over the fleet's 24 h of idle stretches
//! (leo-workspace `tools/compact_rule_replay.py`), wake rewrites plus compactions priced alike:
//! the 60K bar costs 43% of no compaction, compacting every chat of 20K or more 48%, this rule
//! 43%, and it rewrites 43M tokens a day on a wake against the 60K bar's 65M (no compaction:
//! 263M). A skipped deadline logs
//! `cache compaction skipped: the expected saving does not pay for it`.
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
//! A deadline that comes while only a turn's lease (`turn_lock`) is still held, in the last steps
//! of a turn already answered, waits for the lease, bounded by the cache's expiry, and checks
//! again: refused there, the timer was spent and nothing armed it again.
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
pub(crate) const DEFAULT_MIN_TOKENS: u64 = 20_000;
pub(crate) const MIN_TOKENS_RANGE: (u64, u64) = (10_000, 500_000);

/// The floor under which a chat is never compacted: a context of at least `tokens`, or at least
/// `share` (0-1) of its window, whichever trips first. Over it, [`pays`] decides.
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
/// them: None when off (the default: on only with an explicit `agents.cacheCompact.enabled:
/// true` or `ACPMUX_CACHE_COMPACT=1`), else what a chat must reach, at [`DEFAULT_MIN_TOKENS`] or
/// [`DEFAULT_MIN_CONTEXT`] percent unless the settings say otherwise.
pub(crate) fn settings_threshold_with(
    doc: Option<&Value>,
    env: impl Fn(&str) -> Option<String>,
) -> Option<Threshold> {
    let get = |key: &str| doc.and_then(|doc| crate::user_settings::value(doc, key));
    let enabled = super::super::cold_wake::env_flag(env(ENV_ENABLED).as_deref())
        .or_else(|| get(SETTING_ENABLED).and_then(|v| v.as_bool()));
    if enabled != Some(true) {
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
    let used = context(update)?;
    // Armed only where the rule could pay at all (a certain wake): the fire decides with P(wake).
    if !over(used, threshold) || !pays(used.0, 1.0, Prices::of(None, true)) {
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

/// The expected-cost rule (desktop-zoe, 2026-11-25, after Leo: "Honestly why not just compact
/// regardless of 30% or not"). A compaction just before the cache expires reads the warm context
/// once and writes a summary; it saves the cold rewrite of the whole context only if the chat is
/// woken again. So it runs when
///
/// `P(wake) x (S - s) x write  >  read x S + output x summary`
///
/// with S the context now, s the context after a compaction ([`POST_TOKENS`]), summary its
/// output ([`SUMMARY_TOKENS`]), and the model's prices as multiples of its input price
/// ([`Prices::of`]). Measured 2026-11-25 over the fleet's last 24 h of transcripts
/// (leo-workspace `tools/compact_rule_replay.py` over `cache_write_sources.py fleet`): see
/// [`P_WAKE_COORDINATOR`] and [`P_WAKE_OTHER`].
pub(crate) fn pays(used: u64, p_wake: f64, prices: Prices) -> bool {
    let (s, out) = (POST_TOKENS as f64, SUMMARY_TOKENS as f64);
    let used = used as f64;
    p_wake * (used - s).max(0.0) * prices.write > prices.read * used + prices.output * out
}

/// What a compacted context holds: the summary and the turns Claude Code keeps after it. The
/// fleet's 5,785 compactions in the 24 h to 2026-11-25 13Z (43 hosts): `postTokens` 8.1K mean
/// (Claude Code's autocompact 9.3K, acpmux's `/compact` 6.0K).
pub(crate) const POST_TOKENS: u64 = 8_000;
/// What a compaction writes as output: its summary, most of the compacted context.
pub(crate) const SUMMARY_TOKENS: u64 = 6_000;
/// P(wake) for a coordinator whose next wake nothing names yet (no turn coming, no lane or
/// sub-session at work): the share of acpmux coordinators' idle stretches (55 min or more) that
/// ended in a turn, same 24 h: 0.73 (a stretch still open at the window's end counts as no wake,
/// so every share here is a floor).
pub(crate) const P_WAKE_COORDINATOR: f64 = 0.7;
/// The same for any other chat: lanes 0.67, goals 0.88, reviews 0.72, dictators 0.12 (few).
pub(crate) const P_WAKE_OTHER: f64 = 0.65;
/// A chat whose lanes or sub-sessions are at work: their reports wake it.
pub(crate) const P_WAKE_DELEGATING: f64 = 0.9;

/// A model's prices as multiples of its input price: the cache write of the TTL the chat's cache
/// uses, the cache read and the output (leo-workspace `machines/costs-watch.json` `token_rates`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Prices {
    pub write: f64,
    pub read: f64,
    pub output: f64,
}

impl Prices {
    /// `model` (None: the default, Opus 5.5) on a 1-hour cache (`long`) or a 5-minute one. Every
    /// Claude model's output is 5x its input, a 1-hour write 2x and a 5-minute one 1.25x; a read
    /// is 0.05x on the 5.5 models (Opus 5.5: $0.20 of $4 a Mtok) and 0.1x before them.
    pub(crate) fn of(model: Option<&str>, long: bool) -> Self {
        let m = model.unwrap_or("").to_ascii_lowercase();
        let older = ["opus-5-1", "opus-5-0", "opus-4", "sonnet-4", "sonnet-5-0", "haiku"]
            .iter()
            .any(|old| m.contains(old))
            || m.ends_with("opus-5")
            || m.ends_with("sonnet-5");
        Self {
            write: if long { 2.0 } else { 1.25 },
            read: if older { 0.1 } else { 0.05 },
            output: 5.0,
        }
    }
}

/// Whether a chat named `name` is a coordinator, as leo-workspace's `cache_write_sources.py`
/// and `claude-coord-cap` match one.
pub(crate) fn coordinator_name(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["coord", "chief", "delegate", "interim", "deputy"].iter().any(|w| n.contains(w))
}

/// P(wake) of a chat from what acpmux knows of it: a turn already coming is a wake; lanes or
/// sub-sessions at work wake it with their reports; else its kind's measured share.
pub(crate) fn p_wake(coming: bool, delegating: bool, coordinator: bool) -> f64 {
    if coming {
        1.0
    } else if delegating {
        P_WAKE_DELEGATING
    } else if coordinator {
        P_WAKE_COORDINATOR
    } else {
        P_WAKE_OTHER
    }
}

/// The context (tokens) under which a chat at `used` (tokens, window) no longer trips
/// `threshold`: what surgery must reach to stand in for `/compact`.
pub(crate) fn compact_line((_, size): (u64, u64), threshold: Threshold) -> u64 {
    let share = (size > 0).then_some((threshold.share * size as f64) as u64);
    share.map_or(threshold.tokens, |share| share.min(threshold.tokens))
}

/// Whether a prompt's provenance is this timer's compaction.
pub(crate) fn is_own(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(KIND)
}

fn completed_compaction(update: &Value) -> bool {
    update.get("sessionUpdate").and_then(Value::as_str) == Some("compaction")
        && update.get("state").and_then(Value::as_str) == Some("completed")
}

/// What [`Hub::cache_compact_ready`] found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Ready {
    Yes,
    /// Ready but for a turn's lease (`turn_lock`) still held: the fire waits for it.
    Leased,
    No,
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
        let long = expires.saturating_sub(now_ms()) > LONG_CACHE_MS;
        tracing::info!(session = %session.id, "cache compaction runs before the idle stop");
        let session = session.clone();
        self.scope.spawn_until_cancelled("cache-compact-before-reap", async move {
            hub.cache_compact_fire(&session, expires, used, long).await;
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
        let long = expires.saturating_sub(now_ms()) > LONG_CACHE_MS;
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
            hub.cache_compact_fire(&session, expires, used, long).await;
        });
        timers.insert(session.id.clone(), (generation, task.abort_handle(), expires, used));
    }

    /// Whether `session` may be compacted now: idle as the reaper judges it, nobody typing, no
    /// draft, no Web turn last (module docs). [`Ready::Leased`]: all of that, but a turn's lease
    /// (`turn_lock`) is still held.
    fn cache_compact_ready(&self, session: &Session) -> Ready {
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
        if !self.idle_eligible(session) || remote || typing || draft {
            Ready::No
        } else if session.turn_lock.try_lock().is_err() {
            Ready::Leased
        } else {
            Ready::Yes
        }
    }

    /// [`p_wake`] for `session` now: a turn coming (`work_coming`), its lanes or live sub-sessions
    /// at work, else its kind.
    fn cache_compact_p_wake(&self, session: &Session) -> f64 {
        let coming = self.work_coming(&session.id);
        let delegating = self.subsessions.live_count(&session.id) > 0
            || !self.waking_children(&session.id).is_empty()
            || self.lane_links(|links| links.values().any(|l| l.parent == session.id));
        p_wake(coming, delegating, coordinator_name(&session.meta().name))
    }

    /// The timer's deadline: `/compact` for a chat at `used` of its window, if it still may be.
    async fn cache_compact_fire(
        self: &Arc<Self>,
        session: &Arc<Session>,
        expires_ms: u64,
        used: (u64, u64),
        long: bool,
    ) {
        // Sent only while the chat still ends on the turn it ends on now (`after_turn`, checked
        // with no await before the turn is taken and again after). Read before the checks below:
        // a Web or phone turn that ends after this read refuses it at admission, and one that
        // started before the checks shows in them, so it never lifts that turn's remote floor.
        // A turn's lease outlives its end: the prompt is answered and the chat reads idle while
        // the turn's task still holds `turn_lock` for its last steps. A deadline that fell there
        // was refused, its entry already taken, and nothing armed it again (the turn's usage came
        // before): the chat's cache lapsed uncompacted. So the deadline waits for the lease, until
        // the cache's expiry, and every check runs again; a turn that starts meanwhile shows in
        // them or moves the last turn (this deadline then ends: that turn's usage arms its own
        // timer), and `after_turn` refuses this one if it starts later still.
        let last_turn = || {
            let last = session.meta().last_turn.as_ref().and_then(|t| t.get("turnId").cloned());
            last.and_then(|t| t.as_str().map(str::to_owned))
        };
        let Some(at_deadline) = last_turn() else { return };
        let (last, threshold) = loop {
            let Some(last) = last_turn().filter(|last| *last == at_deadline) else { return };
            // Read again: the setting may have been turned off or its threshold raised since the
            // timer was armed, and the cache must still be warm when the request goes.
            let Some(threshold) = read_threshold().filter(|threshold| over(used, *threshold))
            else {
                return;
            };
            let Some(left) = expires_ms.checked_sub(now_ms()).filter(|left| *left > 0) else {
                return;
            };
            let p = self.cache_compact_p_wake(session);
            // `long`: a 1-hour cache (its write 2x input), else a 5-minute one (1.25x).
            let model = session.applied.lock().unwrap_or_else(|e| e.into_inner()).model.clone();
            if !pays(used.0, p, Prices::of(model.as_deref(), long)) {
                tracing::info!(session = %session.id, used = used.0, p_wake = p,
                    "cache compaction skipped: the expected saving does not pay for it");
                return;
            }
            match self.cache_compact_ready(session) {
                Ready::Yes => break (last, threshold),
                Ready::No => return,
                Ready::Leased => {
                    let lease = session.turn_lock.lock();
                    let left = std::time::Duration::from_millis(left);
                    let Ok(guard) = tokio::time::timeout(left, lease).await else { return };
                    drop(guard);
                }
            }
        };
        // Surgery first (`surgery.rs`, RFD 0149): it masks old tool output with no model call, so
        // the chat lands under the threshold without a `/compact` turn; `/compact` when it says
        // no or fails (counted in `harnessMagic.surgery.fallbacks`).
        if self
            .surgery_before_compact(session, compact_line(used, threshold), "cache_compact")
            .await
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
