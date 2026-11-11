//! The app's holder of the signed Cloud capability, as one reducer: the app sends the state it
//! keeps between calls (opaque to it), one event and its clock in milliseconds; this answers the
//! next state, the header value a call sends, and the effects to run (start a mint, arm or stop
//! the refresh timer, drop a mint in flight). The app keeps only the install token, the clock, the
//! HTTP and the timer; what it holds, when it mints, a team switch, a sign-out and a retry are here.
//!
//! The rules it asks are [`super::read_mint`] and [`super::plan`]. Served over the app FFI's JSON
//! channel as op `cloud_capability_step` (`cmux-layout-reducer-ffi`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Held, Plan, Reason, State, plan, read_mint};

/// The refresh timer never wakes sooner than this after it is armed (one deadline, never a poll).
pub const MIN_WAKE_MS: i64 = 1_000;

/// What the app keeps between calls, in memory only (it holds the capability's token).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Holder {
    pub held: Option<Held>,
    /// When a mint for `failed_team` last failed (a refusal, an unreadable answer or no answer).
    pub failed_at: Option<i64>,
    pub failed_team: Option<String>,
    /// When a call or an intent last asked.
    pub last_use: Option<i64>,
    /// A mint is in flight: one at a time.
    pub minting: bool,
    /// The team the newest call or intent asked for while a mint was in flight (a team switch
    /// mid-mint). Its mint goes as soon as the one in flight answers, when it is still due then;
    /// a later ask replaces it, so only the newest team waits and it is minted once.
    pub queued: Option<String>,
    /// Bumped by a sign-out: a mint, an intent or a wake begun before it keeps nothing.
    pub generation: u64,
}

/// One event. `team` is the team claim of the install token the event goes with (`None`: no team
/// or signed out); `generation` is the one the reply that began the event's wait named.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "camelCase")]
pub enum Event {
    /// A relayed call wants its header. Never waits for a mint: when one is due it starts beside.
    Call { team: Option<String> },
    /// Sign-in, a team switch or the person's Cloud intent began: counts as use. The app then reads
    /// the install token and sends [`Event::Intent`] with this reply's generation.
    Use,
    /// The intent's install token was read: mints when none is held for its team or the held one is due.
    Intent { team: Option<String>, generation: u64 },
    /// A mint answered: its HTTP status and body, or `status: None` when the post failed.
    Minted {
        team: String,
        generation: u64,
        #[serde(default)]
        status: Option<u16>,
        #[serde(default)]
        body: Option<String>,
    },
    /// The refresh timer fired and the install token was read.
    Wake { team: Option<String>, generation: u64 },
    /// Sign-out: forget it all, stop the timer, and a mint in flight keeps nothing.
    Clear,
}

/// What the app runs after a step, in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase")]
pub enum Effect {
    /// `POST` [`super::PATH`] with the event's install token, then send [`Event::Minted`] with
    /// this team and generation.
    Mint { team: String, generation: u64 },
    /// Arm the refresh timer (replacing any armed one); when it fires, read the install token and
    /// send [`Event::Wake`] with this generation.
    Schedule {
        #[serde(rename = "afterMs")]
        after_ms: i64,
        generation: u64,
    },
    /// Stop the refresh timer.
    CancelTimer,
    /// Cancel and forget the mint in flight.
    CancelMint,
}

/// A step's answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub state: Holder,
    /// The header value a [`Event::Call`] sends; `None` for every other event.
    pub send: Option<String>,
    pub effects: Vec<Effect>,
}

/// The next state, what a call sends, and the effects to run for `event` at `now`.
pub fn step(mut state: Holder, event: Event, now: i64) -> Step {
    let mut effects = Vec::new();
    let mut send = None;
    match event {
        Event::Call { team } => {
            state.last_use = Some(now);
            let plan = ask(&state, Reason::Call, team.clone(), now);
            if plan.fetch {
                start_mint(&mut state, team, &mut effects);
            } else if state.minting {
                // This call's team is held and fresh: nothing else waits behind the mint in flight.
                state.queued = None;
            }
            send = plan.send;
        }
        Event::Use => state.last_use = Some(now),
        Event::Intent { team, generation } => {
            if generation == state.generation {
                if ask(&state, Reason::Intent, team.clone(), now).fetch {
                    start_mint(&mut state, team, &mut effects);
                } else if state.minting {
                    // The newest intent's team is held and fresh: drop an older team waiting.
                    state.queued = None;
                }
            }
        }
        Event::Minted { team, generation, status, body } => {
            if generation == state.generation {
                state.minting = false;
                let body = body
                    .and_then(|body| serde_json::from_str::<Value>(&body).ok())
                    .unwrap_or(Value::Null);
                match status.and_then(|status| read_mint(status, &body, &team, now)) {
                    Some(next) => {
                        state.held = Some(next);
                        state.failed_at = None;
                        state.failed_team = None;
                    }
                    None => {
                        state.failed_at = Some(now);
                        state.failed_team = Some(team);
                    }
                }
                // A held one's refresh, or its retry when the backoff ends, while Cloud is in use.
                schedule(&state, now, &mut effects);
                // The team asked for while that mint was in flight goes now, not at the next timer.
                if let Some(queued) = state.queued.take()
                    && ask(&state, Reason::Intent, Some(queued.clone()), now).fetch
                {
                    start_mint(&mut state, Some(queued), &mut effects);
                }
            }
        }
        Event::Wake { team, generation } => {
            if generation == state.generation && ask(&state, Reason::Timer, team.clone(), now).fetch
            {
                start_mint(&mut state, team, &mut effects);
            }
        }
        Event::Clear => {
            state = Holder { generation: state.generation.wrapping_add(1), ..Holder::default() };
            effects.push(Effect::CancelMint);
            effects.push(Effect::CancelTimer);
        }
    }
    Step { state, send, effects }
}

fn ask(state: &Holder, reason: Reason, team: Option<String>, now: i64) -> Plan {
    plan(
        &State {
            held: state.held.clone(),
            team,
            now,
            failed_at: state.failed_at,
            failed_team: state.failed_team.clone(),
            last_use: state.last_use,
        },
        reason,
    )
}

/// Starts a mint for `team`, or, while one is in flight, keeps `team` as the one to mint when it
/// answers (the newest ask wins; a later ask for the same team adds nothing).
fn start_mint(state: &mut Holder, team: Option<String>, effects: &mut Vec<Effect>) {
    let Some(team) = team.filter(|team| !team.is_empty()) else { return };
    if state.minting {
        state.queued = Some(team);
        return;
    }
    state.minting = true;
    effects.push(Effect::Mint { team, generation: state.generation });
}

/// Arms the timer at the held one's refresh time (or its retry), or stops it.
fn schedule(state: &Holder, now: i64, effects: &mut Vec<Effect>) {
    let team = state.held.as_ref().map(|held| held.team.clone());
    match ask(state, Reason::Timer, team, now).wake_in {
        Some(wake) => effects.push(Effect::Schedule {
            after_ms: wake.max(MIN_WAKE_MS),
            generation: state.generation,
        }),
        None => effects.push(Effect::CancelTimer),
    }
}

#[cfg(test)]
mod tests;
