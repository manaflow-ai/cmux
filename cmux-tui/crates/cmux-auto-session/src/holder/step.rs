//! The one transition function, and the rules that hold in every state.

use super::out::Out;
use super::{Chat, Effect, Event, State, Stop, laptop, machine};
use crate::consts::LEASE_MS;

/// A clock that went back by more than this is not trusted: the chat stops and asks, as on a
/// wake. Smaller steps back are a clock being set right.
pub const CLOCK_SLACK_MS: u64 = 1_000;

/// The chat after `event` at `now` (epoch ms), and what the daemon does, in order.
///
/// It is pure and total: the same input gives the same output, and an event that means nothing
/// in a state leaves the chat as it is with no effects.
///
/// Three rules hold in every state, around the state's own handling of the event:
/// - A clock that jumped past [`LEASE_MS`], or went back, is a wake: the chat is stepped with
///   [`Event::Wake`] first, then with `event`.
/// - A laptop that holds the chat and has had no renewal answered for
///   [`SELF_STOP_MS`](crate::consts::SELF_STOP_MS) stops it, whatever the event.
/// - `ShowBlocked` goes out when [`Chat::blocked`] changed and `ScheduleAt` when
///   [`Chat::wake_at`] did; a tick always schedules the next one.
pub fn step(chat: Chat, event: Event, now: u64) -> (Chat, Vec<Effect>) {
    let mut out = Out::new(chat);
    let jumped = now > chat.seen_at.saturating_add(LEASE_MS)
        || now.saturating_add(CLOCK_SLACK_MS) < chat.seen_at;
    out.chat.seen_at = now;
    if jumped && event != Event::Wake {
        apply(&mut out, Event::Wake, now);
    }
    apply(&mut out, event, now);
    stop_when_unanswered(&mut out, now);
    // A tick never leaves the next one due at once, which would spin.
    if event == Event::Tick && out.due(now) {
        out.tick_in_a_period(now);
    }
    if out.chat.blocked() != chat.blocked() {
        out.push(Effect::ShowBlocked { blocked: out.chat.blocked() });
    }
    match out.chat.wake_at() {
        Some(at) if event == Event::Tick || chat.wake_at() != Some(at) => {
            out.push(Effect::ScheduleAt { at });
        }
        Some(_) | None => {}
    }
    (out.chat, out.effects)
}

/// The state's own handling of one event.
fn apply(out: &mut Out, event: Event, now: u64) {
    match out.chat.state {
        State::Off => laptop::off(out, event, now),
        State::Registering => laptop::registering(out, event, now),
        State::Holding { epoch } => laptop::holding(out, epoch, event, now),
        State::Stopped { epoch, .. } => laptop::stopped(out, epoch, event, now),
        State::Standby { epoch } => laptop::standby(out, epoch, event, now),
        State::ComingHome { epoch, failed } => laptop::coming_home(out, epoch, failed, event, now),
        State::Away => machine::away(out, event, now),
        State::Taking { epoch, reason, failed } => {
            machine::taking(out, epoch, reason, failed, event, now);
        }
        State::Serving { epoch } => machine::serving(out, epoch, event, now),
    }
}

/// A laptop that cannot reach the Cloud stops by itself, before the Cloud's lease runs out. The
/// stop goes first among the step's effects. Renewals go on at their pace, and the next one
/// answered decides.
fn stop_when_unanswered(out: &mut Out, now: u64) {
    let State::Holding { epoch } = out.chat.state else { return };
    if out.chat.self_stop_at().is_some_and(|at| now >= at) {
        out.to(State::Stopped { epoch, why: Stop::Offline });
        out.effects.insert(0, Effect::StopTree);
    }
}
