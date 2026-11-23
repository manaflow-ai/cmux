//! A chat whose account hit its rate limit starts no turn until the limit resets (Leo,
//! 2026-11-17: "the old coord keeps running into these rate limit spirals" / "oh i mean not gh").
//!
//! claude-sr2-coord-old (a 323K-token context) failed 207 of its last 400 turns with "API Error:
//! Request rejected (429) · This request would exceed your account's rate limit". Each failed turn
//! sent the whole context again, against the same account limit: 49.4M input tokens in a day. The
//! 429 was retried as a 529 (`capacity`), and every message from another agent (26 of them) and
//! every background notice started a turn of its own, each with its own chain of four
//! continuations, so the retries multiplied instead of backing off.
//!
//! - A turn that fails on the account's usage or rate limit has reason `rate_limit`
//!   (`turn_errors::resume_cause`), told apart from a provider's 529 or a gateway's 503.
//! - The chat is then held ([`RateHold`]) until the reset: `retry-after` or the error's own reset
//!   (`reset_hint.rs`), else the account's `rate_limit_event` window
//!   (`claude_stdio/usage_limits.rs`), else the continuation's configured wait. One timer per chat,
//!   whatever comes in meanwhile; a later 429 moves the same hold's deadline.
//! - While held no turn starts (`queue.rs`): another agent's message, a background notice and
//!   the person's own prompt all queue. Only acpmux's own continuation of the cut turn runs, once
//!   the hold is due.
//! - At the reset the continuation decides once ([`Hub::rate_hold_due`]): when anything queued
//!   meanwhile, it is not sent; the queue's next turn carries its words instead, and the agent
//!   messages waiting join that one turn (`digest.rs`). When nothing waits, the continuation runs
//!   alone. Either way the first turn after the reset is one turn.
//! - A chat past [`COMPACT_BEFORE_TOKENS`] of context is compacted first (`compact_first.rs`),
//!   so the first turn after the reset does not send a 300K context again.
//! - The session row says so (`SessionSummary::rate_limited_until`; `acpmux ls`: "rate-limited
//!   until HH:MMZ"), and each hold and its end are logged (`rate_limit_held`, `rate_limit_lifted`).
//! - A retry (`_acpmux/retry`) while held is refused (`retry.rate_limited`); Stop parks the
//!   chat (below).
//!
//! The same loop came back on 2026-11-18 (Leo: "claude-sr2-coord fell into a weird "rate limited"
//! loop again 429 and whatever"): from 00:41Z claude-sr2-coord (a 330K-token context) started 159
//! turns and 160 failed with the 429, while no other chat on the machine got one. Each new prompt
//! started its continuation chain at attempt 1 (10 s), and a one-minute watchdog's `acpmux retry`
//! skipped the wait, so the backoff never grew. Now the backoff belongs to the chat, not to a chain:
//!
//! - Every turn that fails on the limit is a strike of the chat (`HoldState::strikes`); a turn
//!   that ends well clears them ([`Hub::rate_turn_ok`]). A continuation waits at least
//!   [`backoff_ms`] of the strikes (60 s, doubling, at most [`MAX_HOLD_MS`]), and longer when
//!   its attempt's wait, `retry-after` or the reset says so: attempt 1's 10 s no longer cuts it.
//! - After [`PARK_AFTER`] strikes in a row the chat parks: it starts nothing by itself, its
//!   continuation waits, and it tells the session it reports to in one line
//!   (`rate_limit_parked`), at most once per [`NOTICE_EVERY_MS`]. `acpmux retry` or the
//!   person's own prompt sends the continuation on (compacted first past
//!   [`COMPACT_BEFORE_TOKENS`]), with what queued as one turn ([`Hub::unpark_rate_hold`]).
//!
//! Two more gaps showed on Leo's Mac on 2026-11-18, 06:50-07:00Z (Leo: "the gui coordinators
//! keep saying stuff is rate limited and 429 and stuff :("), claude-sr2-coord at 354K context:
//!
//! - A NIGHTLY update restarted the daemon, and the chat came back with no hold: 5 more turns
//!   failed on the 429. Every hold, park, lift and unpark is a record with the chat's strikes,
//!   and a restart or a takeover reads the last one back before the queue goes on
//!   ([`Hub::restore_rate_hold`]): a hold before its `until` holds until then, a parked chat
//!   stays parked, and the strikes carry over. Its continuation is restored as before
//!   (`auto_resume/restore.rs`), also behind what queued meanwhile.
//! - After `acpmux session stop`, another agent's message started a turn at once. Stop (and
//!   `session stop`) of a chat that is held, parked or has a strike parks it now
//!   ([`Hub::park_at_stop`], `rate_limit_parked` with `why: "stopped"`): it starts no turn by
//!   itself; other agents' messages, notices and its continuation wait; `acpmux retry` or the
//!   person's own prompt sends it on, as above. Any other chat's Stop is as before.
//!
//! A 429 storm on a long-context chat lost messages (`tests/hub_integration/auto_resume_429_storm.rs`,
//! 9 of 58): the turn a reset folded them into failed on the 429 again, and its continuation's
//! "continue" carried none of them. A 429 refuses the request before the model reads it:
//!
//! - A turn that failed on the limit with no sign of its model ([`Hub::unread_by_limit`]) puts
//!   every agent message in it back in the queue, held, the one that led it too (`digest.rs`
//!   `requeue_unread`), however often the limit refuses them; the next reset's one turn takes
//!   them in, and a turn that completes with them puts none back. The leading message's sender
//!   had the turn's error; the others' sends wait on. A turn its model began is continued as
//!   before, and its messages go back once (`requeue_joined`).

use super::*;
use std::sync::Mutex as StdMutex;
use std::time::Duration;

/// The context past which a chat is compacted before its first turn after a reset.
/// 200K: no chat under 300K got a 429 on 2026-11-16 to 11-18 (1,272 turns), and a request past
/// 200K input tokens is a long-context request, with the provider's lower limits.
pub(super) const COMPACT_BEFORE_TOKENS: u64 = 200_000;

/// The shortest hold when nothing says when the limit resets: a per-minute rate limit's window.
pub(super) const MIN_HOLD_MS: u64 = 60_000;

/// The longest backoff when nothing says when the limit resets.
pub(super) const MAX_HOLD_MS: u64 = 30 * 60_000;

/// Turns in a row that fail on the limit before the chat parks (1 + 2 + 4 + 8 + 16 minutes of
/// backoff before it: about half an hour).
pub(super) const PARK_AFTER: u32 = 6;

/// A parked chat tells the session it reports to at most this often.
pub(super) const NOTICE_EVERY_MS: u64 = 30 * 60_000;

/// The least a chat with `strikes` turns in a row failed on the limit waits: `base` (the
/// continuation's minute, [`backoff_base`]), doubling with each strike, at most [`MAX_HOLD_MS`].
pub(super) fn backoff_ms(strikes: u32, base: u64) -> u64 {
    let doublings = strikes.saturating_sub(1).min(16);
    base.saturating_mul(1 << doublings).min(MAX_HOLD_MS.max(base))
}

/// The backoff's first wait, from the continuation's configured waits: the second (60 s by
/// default, a per-minute limit's window), else the only one.
pub(super) fn backoff_base(delays: &[u64]) -> u64 {
    delays.get(1).or(delays.first()).copied().unwrap_or(MIN_HOLD_MS)
}

/// A chat's rate-limit hold (`Session::rate_hold`).
#[derive(Default)]
pub(crate) struct RateHold {
    state: StdMutex<HoldState>,
    /// The deadline moved or the hold ended: the timer looks again.
    changed: Notify,
    /// The deadline passed while a continuation waits for it ([`Hub::wait_rate_hold`]).
    due: Notify,
    /// The chat's log was read for its hold once ([`Hub::restore_rate_hold`]).
    restored: std::sync::atomic::AtomicBool,
}

/// What a retry or the person's own prompt did to a parked chat ([`Hub::unpark_rate_hold`]).
pub(super) enum Unparked {
    /// The continuation of this cut turn that waited goes on now, with what queued.
    Continues(String),
    /// None waited: the hold ended, and the queue's next turn carries the continuation's words
    /// and what queued.
    Queue,
    /// None waited and nothing queued: the hold ended.
    Released,
}

#[derive(Default)]
struct HoldState {
    /// Absolute ms; `None` when the chat is not held.
    until: Option<u64>,
    /// The cut turn the hold is for.
    turn: Option<String>,
    /// The hold's timer task runs.
    timer: bool,
    /// A continuation waits for the deadline and ends the hold itself.
    continuation: bool,
    /// Turns in a row that failed on the limit; a turn that ends well clears them.
    strikes: u32,
    /// Since when the chat is parked (Unix ms): held with no deadline until a retry or the
    /// person's own prompt.
    parked: Option<u64>,
    /// When the chat last told the session it reports to that it parked.
    noticed_at: Option<u64>,
}

impl RateHold {
    fn lock(&self) -> std::sync::MutexGuard<'_, HoldState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The deadline while the chat is held; none while it is parked (it has none).
    pub(crate) fn until(&self) -> Option<u64> {
        let s = self.lock();
        s.until.filter(|_| s.parked.is_none())
    }

    /// Since when the chat is parked (Unix ms), if it is.
    pub(crate) fn parked(&self) -> Option<u64> {
        self.lock().parked
    }

    /// The chat's strikes: turns in a row that failed on the limit.
    pub(crate) fn strikes(&self) -> u32 {
        self.lock().strikes
    }

    /// Whether the limit has the chat: held, parked, or with a strike. A Stop parks such a chat
    /// ([`Hub::park_at_stop`]).
    pub(super) fn limited(&self) -> bool {
        let s = self.lock();
        s.until.is_some() || s.parked.is_some() || s.strikes > 0
    }
}

impl Hub {
    /// Holds `session` until `until` (absolute ms) for its cut turn `turn`: no turn starts
    /// before. A held chat's deadline moves to `until`. One timer per chat.
    pub(super) fn hold_for_rate_limit(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        until: u64,
        continuation: bool,
    ) {
        let hold = &session.rate_hold;
        let spawn = {
            let mut s = hold.lock();
            s.turn = Some(turn.to_owned());
            s.continuation = continuation;
            // Parked: no deadline, no timer, until a retry or the person's own prompt.
            if s.parked.is_some() {
                return;
            }
            // Each failure is recorded, a strike with it: a restart reads the hold and the
            // strikes back from the last record ([`Hub::restore_rate_hold`]).
            let changed = s.until != Some(until) || !continuation;
            s.until = Some(until);
            if changed {
                self.append(
                    session,
                    "mux",
                    "rate_limit_held",
                    json!({"turnId": turn, "until": until, "strikes": s.strikes}),
                );
            }
            !std::mem::replace(&mut s.timer, true)
        };
        hold.changed.notify_waiters();
        if spawn {
            self.spawn_rate_hold_timer(session);
        }
    }

    fn spawn_rate_hold_timer(self: &Arc<Self>, session: &Arc<Session>) {
        let (hub, session) = (self.clone(), session.clone());
        // One per held chat; it ends with the hold, or with the hub.
        self.scope.spawn_until_cancelled("rate-hold-timer", async move {
            hub.rate_hold_timer(&session).await;
        });
    }

    async fn rate_hold_timer(self: &Arc<Self>, session: &Arc<Session>) {
        let hold = &session.rate_hold;
        loop {
            let changed = hold.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let until = {
                let mut s = hold.lock();
                match s.until {
                    Some(until) if s.parked.is_none() => until,
                    _ => {
                        s.timer = false;
                        return;
                    }
                }
            };
            let now = now_ms();
            if now < until {
                tokio::select! {
                    () = tokio::time::sleep(Duration::from_millis(until - now)) => {}
                    () = changed.as_mut() => {}
                }
                continue;
            }
            let mut s = hold.lock();
            if s.until != Some(until) {
                continue;
            }
            s.timer = false;
            if s.continuation {
                // The continuation ends the hold once it decided (`rate_hold_due`).
                drop(s);
                hold.due.notify_one();
            } else {
                drop(s);
                self.lift_rate_hold(session, "reset");
            }
            return;
        }
    }

    /// Whether no turn may start in `session` now: it is held, or its continuation decides.
    pub(super) fn rate_held(session: &Session) -> bool {
        let s = session.rate_hold.lock();
        s.until.is_some() || s.parked.is_some()
    }

    /// Ends `session`'s hold, if it has one, and lets its queue go on.
    pub(super) fn lift_rate_hold(&self, session: &Session, why: &str) {
        self.lift_hold(session, None, why);
    }

    /// Ends `session`'s hold only while it is still the one for cut turn `turn`: a continuation
    /// whose own turn hit the limit again left a newer hold, which stays.
    pub(super) fn lift_rate_hold_of(&self, session: &Session, turn: &str, why: &str) {
        self.lift_hold(session, Some(turn), why);
    }

    /// A parked chat's hold ends only by [`Hub::unpark_rate_hold`]: a continuation that Stop or
    /// close woke, or that skipped, leaves it parked.
    fn lift_hold(&self, session: &Session, of: Option<&str>, why: &str) {
        let hold = &session.rate_hold;
        let (turn, strikes) = {
            let mut s = hold.lock();
            if s.until.is_none()
                || s.parked.is_some()
                || of.is_some_and(|t| s.turn.as_deref() != Some(t))
            {
                return;
            }
            s.until = None;
            s.continuation = false;
            (s.turn.take(), s.strikes)
        };
        hold.changed.notify_waiters();
        let msg = json!({"turnId": turn, "why": why, "strikes": strikes});
        self.append(session, "mux", "rate_limit_lifted", msg);
        session.queue_moved.notify_waiters();
    }

    /// Holds `session` the moment its turn `turn` failed on the rate limit, before its
    /// continuation's wait is known: until the error's reset, else the account window's, else
    /// the turn's `retry-after` (`not_before`), else [`MIN_HOLD_MS`] from now. Whatever comes in
    /// meanwhile queues.
    ///
    /// It is a strike of the chat: its continuation waits at least [`backoff_ms`] of the
    /// strikes (`auto_resume.rs`), and the [`PARK_AFTER`]th parks it. True when it parked.
    pub(super) fn hold_at_failure(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        error: &str,
        not_before: Option<u64>,
    ) -> bool {
        let now = now_ms();
        let strikes = {
            let mut s = session.rate_hold.lock();
            s.strikes = s.strikes.saturating_add(1);
            s.strikes
        };
        if strikes >= PARK_AFTER {
            self.park_rate_hold(session, turn, strikes, now);
            return true;
        }
        let limits = session.meta().usage_limits;
        let reset = super::auto_resume::reset_hint::reset_at(error, limits.as_ref(), now);
        let until = reset.max(not_before).unwrap_or(now + MIN_HOLD_MS);
        self.hold_for_rate_limit(session, turn, until, false);
        false
    }

    /// Whether the turn of `session` that started at `turn_seq` failed with `error` on the
    /// account's limit before its model read a word: the limit's error, and no record since its
    /// start shows the model at work (`tap.rs` `logged_from_the_model`) but Claude Code's own line
    /// of that error (`model: "<synthetic>"`). Read back from the log's end to the first sign.
    pub(super) fn unread_by_limit(&self, session: &Session, turn_seq: u64, error: &str) -> bool {
        if super::turn_errors::resume_cause(error, error) != Some("rate_limit") {
            return false;
        }
        let mut heard = false;
        let scanned = self.store.scan_back(
            &session.id,
            turn_seq,
            u64::MAX,
            &|dir, _| dir != b"in",
            &mut |e: EventRecord| {
                let synthetic =
                    e.msg.pointer("/message/model").and_then(Value::as_str) == Some("<synthetic>");
                heard = super::tap::logged_from_the_model(&e) && !synthetic;
                !heard
            },
        );
        scanned.is_ok() && !heard
    }

    /// A turn of `session` ended well: its strikes are cleared.
    pub(super) fn rate_turn_ok(&self, session: &Session) {
        session.rate_hold.lock().strikes = 0;
    }

    /// Parks `session` after `strikes` turns in a row failed on the limit: held with no
    /// deadline, its continuation waits for a retry or the person's prompt, and the session it
    /// reports to gets
    /// one line (at most once per [`NOTICE_EVERY_MS`]).
    fn park_rate_hold(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        strikes: u32,
        now: u64,
    ) {
        let notice = {
            let mut s = session.rate_hold.lock();
            s.parked.get_or_insert(now);
            s.until = Some(u64::MAX);
            s.turn = Some(turn.to_owned());
            let due = s.noticed_at.is_none_or(|at| now.saturating_sub(at) >= NOTICE_EVERY_MS);
            if due {
                s.noticed_at = Some(now);
            }
            due
        };
        session.rate_hold.changed.notify_waiters();
        let context = self.usage_stats_of(session, &session.meta()).and_then(|s| s.context_tokens);
        self.append(
            session,
            "mux",
            "rate_limit_parked",
            json!({"turnId": turn, "strikes": strikes, "contextTokens": context, "noticed": notice, "why": "strikes"}),
        );
        if notice {
            self.tell_rate_park(session, strikes, context, now);
        }
    }

    /// A Stop of a chat the limit has ([`RateHold::limited`]) parks it instead of releasing it:
    /// it starts nothing by itself, and what comes in queues until `acpmux retry` or the
    /// person's own prompt. With `keeps_continuation`, the continuation that waits stays and
    /// goes on with the retry; without, the Stop took it. Recorded once, with no notice: the
    /// person stopped it.
    pub(super) fn park_at_stop(&self, session: &Session, keeps_continuation: bool) {
        let (turn, strikes) = {
            let mut s = session.rate_hold.lock();
            s.continuation &= keeps_continuation;
            if s.parked.is_some() {
                return;
            }
            s.parked = Some(now_ms());
            s.until = Some(u64::MAX);
            (s.turn.clone(), s.strikes)
        };
        session.rate_hold.changed.notify_waiters();
        self.append(
            session,
            "mux",
            "rate_limit_parked",
            json!({"turnId": turn, "strikes": strikes, "noticed": false, "why": "stopped"}),
        );
    }

    /// The one line a parked chat sends the session it reports to (its lane's parent, else the
    /// session that started it). None to tell: the record and the row say it.
    fn tell_rate_park(
        self: &Arc<Self>,
        session: &Arc<Session>,
        strikes: u32,
        context: Option<u64>,
        now: u64,
    ) {
        let lane_parent = self.lane_links(|links| links.get(&session.id).map(|l| l.parent.clone()));
        let parent = lane_parent
            .or_else(|| self.spawned_by_session(session))
            .and_then(|p| self.resolve(&p).ok())
            .filter(|p| p.id != session.id);
        let name = session.meta().name;
        let Some(parent) = parent else {
            tracing::warn!(session = %session.id, strikes, "rate limit: parked, no session to tell");
            return;
        };
        let text = park_line(&name, strikes, context);
        let provenance = json!({"kind": "rate_limit_parked", "from": session.id, "fromName": name});
        let opts = PromptOptions {
            prompt_id: Some(format!("{}~rate-parked-{now}", session.id)),
            provenance: Some(provenance),
            agent: Some(name),
            ..PromptOptions::default()
        };
        let hub = self.clone();
        // One line, queued like any agent message; never waited for here.
        self.scope.spawn_until_cancelled("rate-park-notice", async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            if let Err(e) = hub.prompt_with(&parent, blocks, "acpmux", false, opts).await {
                tracing::warn!(session = %parent.id, "rate limit park notice: {}", e.message);
            }
        });
    }

    /// A retry (`why` "retry") or the person's own prompt ("prompt") of a parked `session`:
    /// unparked, its strikes at most one short of parking again. Whatever a person's Stop held
    /// goes in now: the person acted. Its waiting continuation goes on now (compacted first
    /// past [`COMPACT_BEFORE_TOKENS`]) and folds what queued into its one turn
    /// ([`Hub::rate_hold_due`]). With none waiting the hold ends, and when anything queued the
    /// queue's next turn carries the continuation's words. None when the chat is not parked.
    pub(super) fn unpark_rate_hold(&self, session: &Arc<Session>, why: &str) -> Option<Unparked> {
        let (turn, waits, strikes) = {
            let mut s = session.rate_hold.lock();
            s.parked?;
            s.parked = None;
            s.strikes = s.strikes.min(PARK_AFTER - 1);
            if s.continuation {
                s.until = Some(now_ms());
            }
            (s.turn.clone(), s.continuation, s.strikes)
        };
        self.append(
            session,
            "mux",
            "rate_limit_unparked",
            json!({"turnId": turn, "why": why, "continues": waits, "strikes": strikes}),
        );
        // The person acted: a person's Stop's hold of other agents' messages ends (`cancel.rs`).
        // The limit still holds them until the continuation folds them, or the lift below.
        let stop_hold = session.stop_hold.load(std::sync::atomic::Ordering::SeqCst);
        self.release_held_agent_messages(session, stop_hold);
        if waits {
            session.rate_hold.due.notify_one();
            return Some(Unparked::Continues(turn.unwrap_or_default()));
        }
        let queued = session.queue().iter().any(|q| !q.aside());
        if queued {
            let error = session
                .meta()
                .last_turn
                .and_then(|t| t.get("errorText").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_else(|| "HTTP 429".into());
            let note = super::auto_resume::continue_text(&error, "rate_limit");
            session.rate_note.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert(note);
        }
        self.lift_rate_hold(session, why);
        Some(if queued { Unparked::Queue } else { Unparked::Released })
    }

    /// The person's own prompt (`inbox::persons_prompt`), queued in a parked chat, takes it
    /// back as a retry does ([`Hub::unpark_rate_hold`]).
    pub(super) fn persons_prompt_unparks(
        &self,
        session: &Arc<Session>,
        agent: Option<&str>,
        provenance: Option<&Value>,
    ) {
        if session.rate_hold.parked().is_some() && super::inbox::persons_prompt(agent, provenance) {
            let _ = self.unpark_rate_hold(session, "prompt");
        }
    }

    /// After a restart or a takeover: the hold, the park and the strikes `session`'s log says it
    /// had, before its queue and its continuation go on (`queue.rs` `resume_restored_as`). A
    /// NIGHTLY update's restart came back with no hold on 2026-11-18, and the chat failed 5 more
    /// turns on the 429. The last of its `rate_limit_*` records says it, read back no further
    /// than a turn that ended well, which cleared them all:
    ///
    /// - `rate_limit_held` before its `until`: held until then, with its own timer; the
    ///   continuation the restore arms takes the hold over. Past it, nothing holds.
    /// - `rate_limit_parked`: parked, no timer and no turn, until a retry or the person's own
    ///   prompt; its notice counts as sent then.
    /// - `rate_limit_lifted`, `rate_limit_unparked`: nothing holds.
    ///
    /// Each carries the strikes, which carry over.
    pub(super) fn restore_rate_hold(self: &Arc<Self>, session: &Arc<Session>) {
        let hold = &session.rate_hold;
        if hold.restored.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        let kinds: [&[u8]; 5] = [
            b"rate_limit_held",
            b"rate_limit_parked",
            b"rate_limit_lifted",
            b"rate_limit_unparked",
            b"turn_result",
        ];
        let mut last = None;
        let scanned = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|_, kind| !kinds.contains(&kind),
            &mut |e: EventRecord| {
                if e.kind == "turn_result" {
                    return e.msg.get("status").and_then(Value::as_str) != Some("completed");
                }
                last = Some(e);
                false
            },
        );
        let (Ok(()), Some(last)) = (scanned, last) else { return };
        let strikes = |default: u32| {
            last.msg
                .get("strikes")
                .and_then(Value::as_u64)
                .map_or(default, |n| u32::try_from(n).unwrap_or(u32::MAX))
        };
        let turn = last.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
        let spawn = {
            let mut s = hold.lock();
            // Live since: a hold this daemon set already is newer than its log.
            if s.until.is_some() || s.parked.is_some() || s.strikes > 0 {
                return;
            }
            match last.kind.as_str() {
                "rate_limit_parked" => {
                    s.strikes = strikes(PARK_AFTER);
                    s.parked = Some(last.at);
                    s.noticed_at = Some(last.at);
                    s.until = Some(u64::MAX);
                    s.turn = turn;
                    false
                }
                "rate_limit_held" => {
                    s.strikes = strikes(0);
                    let until = last.msg.get("until").and_then(Value::as_u64);
                    match until.filter(|u| *u > now_ms()) {
                        Some(until) => {
                            s.until = Some(until);
                            s.turn = turn;
                            !std::mem::replace(&mut s.timer, true)
                        }
                        None => false,
                    }
                }
                _ => {
                    s.strikes = strikes(0);
                    false
                }
            }
        };
        if spawn {
            self.spawn_rate_hold_timer(session);
        }
    }

    /// A `rate_limit` continuation of `turn` waits here for the hold's deadline `until`, or for
    /// `wake` (Stop, close, a turn that took the chat: the hold then ends, unless the chat is
    /// parked). True when the deadline came: the continuation then decides
    /// ([`Hub::rate_hold_due`]).
    pub(super) async fn wait_rate_hold(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        until: u64,
        wake: &Notify,
    ) -> bool {
        self.hold_for_rate_limit(session, turn, until, true);
        let came = loop {
            tokio::select! {
                () = session.rate_hold.due.notified() => {}
                () = wake.notified() => break false,
            }
            // A permit an earlier hold's timer left is no deadline of this one; a parked chat
            // has none, and waits for its retry (`unpark_rate_hold` sets the deadline to now).
            let deadline = session.rate_hold.lock().until;
            if deadline.is_none_or(|until| now_ms() >= until) {
                break true;
            }
        };
        if !came {
            self.lift_rate_hold(session, "stopped");
        }
        came
    }

    /// At the reset: whether `session`'s continuation folds into the queue's next turn. When
    /// anything waits in the queue (a message, a notice, the person's prompt), the continuation
    /// is not sent: the held prompts of the cut turn go on, the next turn carries the
    /// continuation's words (`rate_note`), and the hold ends. Otherwise the hold ends and the
    /// continuation runs alone.
    pub(super) fn rate_hold_due(
        &self,
        session: &Arc<Session>,
        held: &[String],
        note: String,
    ) -> bool {
        let waiting: Vec<String> = session.queue().iter().map(|q| q.prompt_id.clone()).collect();
        if waiting.is_empty() {
            self.lift_rate_hold(session, "reset");
            return false;
        }
        *session.rate_note.lock().unwrap_or_else(|e| e.into_inner()) = Some(note);
        // What the cut turn held, and every agent message a failed turn held: they waited only
        // for the limit, and go in together as one turn.
        let mut release: Vec<String> = held.to_vec();
        release.extend(
            session
                .queue()
                .iter()
                .filter(|q| q.held && q.run.agent.is_some())
                .map(|q| q.prompt_id.clone()),
        );
        self.resume_held(session, &release);
        self.lift_rate_hold(session, "folded");
        true
    }

    /// The continuation's words a folded continuation left for the chat's next turn, taken.
    pub(super) fn take_rate_note(session: &Session) -> Option<String> {
        session.rate_note.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    /// Whether `session`'s context is past [`COMPACT_BEFORE_TOKENS`].
    pub(super) fn context_past_compact_line(&self, session: &Session) -> bool {
        let m = session.meta();
        self.usage_stats_of(session, &m)
            .and_then(|s| s.context_tokens)
            .is_some_and(|n| n > COMPACT_BEFORE_TOKENS)
    }
}

impl Hub {
    /// Whether a prompt with `provenance` waits for `session`'s hold: every one but acpmux's own
    /// continuation of the cut turn (`auto_resume` provenance), which runs once the hold is due.
    pub(super) fn rate_holds(session: &Session, provenance: Option<&Value>) -> bool {
        Self::rate_held(session)
            && provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) != Some("auto_resume")
    }
}

impl Hub {
    /// A continuation's wait for its attempt at `next_at`: a `rate_limit` one waits for the chat's
    /// hold ([`Hub::wait_rate_hold`]), any other for its delay. Either ends early when its mark
    /// goes (`Wake`): Stop, close, a turn that took the chat.
    pub(super) async fn wait_retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        reason: crate::protocol::session::RetryReason,
        next_at: u64,
        wake: &Notify,
    ) {
        if reason == crate::protocol::session::RetryReason::RateLimit {
            self.wait_rate_hold(session, turn, next_at, wake).await;
            return;
        }
        let delay = next_at.saturating_sub(now_ms());
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(delay)) => {}
            () = wake.notified() => {}
        }
    }
}

impl Session {
    /// The chat's rate-limit strikes (`rate_hold.rs`), for tests.
    #[doc(hidden)]
    pub fn rate_hold_strikes(&self) -> u32 {
        self.rate_hold.strikes()
    }
}

/// The line a parked chat sends the session it reports to.
pub(crate) fn park_line(name: &str, strikes: u32, context: Option<u64>) -> String {
    let context = context.map_or(String::new(), |n| format!(", context {}K tokens", n / 1000));
    format!(
        "acpmux: {name} stopped retrying: its last {strikes} turns failed on the rate limit \
         (HTTP 429){context}. It is parked with its queue kept; `acpmux retry {name}` sends it \
         on (compacted first), and so does the person's own prompt."
    )
}

/// "rate-limited until 04:30Z": a hold's deadline `until` (Unix ms), in UTC (`acpmux ls`, the
/// session row, a refused retry).
pub(crate) fn until_line(until: u64) -> String {
    let at = i64::try_from(until).ok().and_then(chrono::DateTime::from_timestamp_millis);
    match at {
        Some(at) => format!("rate-limited until {}", at.format("%H:%MZ")),
        None => "rate-limited".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_backoff_doubles_from_its_base_up_to_half_an_hour() {
        let waits: Vec<u64> = (1..=8).map(|n| backoff_ms(n, MIN_HOLD_MS) / 1000).collect();
        assert_eq!(waits, [60, 120, 240, 480, 960, 1800, 1800, 1800]);
        assert_eq!(backoff_ms(0, MIN_HOLD_MS), MIN_HOLD_MS);
        assert_eq!(backoff_ms(u32::MAX, MIN_HOLD_MS), MAX_HOLD_MS);
        assert_eq!(backoff_ms(3, 20), 80);
    }

    #[test]
    fn the_base_is_the_continuations_minute() {
        assert_eq!(backoff_base(&[10_000, 60_000, 300_000, 1_200_000]), 60_000);
        assert_eq!(backoff_base(&[25]), 25);
        assert_eq!(backoff_base(&[]), MIN_HOLD_MS);
    }

    #[test]
    fn the_park_line_says_how_to_go_on() {
        let line = park_line("claude-sr2-coord", 6, Some(334_751));
        assert_eq!(
            line,
            "acpmux: claude-sr2-coord stopped retrying: its last 6 turns failed on the rate \
             limit (HTTP 429), context 334K tokens. It is parked with its queue kept; `acpmux \
             retry claude-sr2-coord` sends it on (compacted first), and so does the person's \
             own prompt."
        );
    }
}
