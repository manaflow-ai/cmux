//! Meet Chief, the first-run introduction on the empty Chief chat (`ChiefOnboarding`): its once-per-install
//! state, its steps, where a Chief chat shows it and the look step's text size. Swift reads and writes the
//! `home.firstRun.chiefOnboarding` default and runs the settings writes; these ops say what changes.

use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The default the state lives in: absent before a first run started it, "pending", then "done".
pub const STATE_KEY: &str = "home.firstRun.chiefOnboarding";

/// `ChiefOnboardingStep`, in order.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Step {
    #[default]
    Meet,
    Access,
    Look,
}

pub const STEPS: [Step; 3] = [Step::Meet, Step::Access, Step::Look];

impl Step {
    fn index(self) -> usize {
        STEPS.iter().position(|s| *s == self).unwrap_or(0)
    }

    /// `ChiefOnboardingStep(rawValue:)`; nil for an unknown name.
    fn named(name: &str) -> Option<Step> {
        STEPS
            .into_iter()
            .find(|s| serde_json::to_value(s).ok().as_ref().and_then(Value::as_str) == Some(name))
    }
}

/// The model's state (`ChiefOnboarding`'s stored properties).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub shows: bool,
    pub decided: bool,
    pub step: Step,
    pub reopened: bool,
    pub write_failed: bool,
}

/// What happened (`ChiefOnboarding`'s methods).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Event {
    /// `init`: the launch reads the stored state.
    Launch,
    /// `begin(freshInstall:)`.
    Begin,
    /// `next()`: the primary button.
    Next,
    /// `back()`.
    Back,
    /// `finish()`: Skip, Start chatting, or a message sent while it shows.
    Finish,
    /// `reopen()`: Meet Chief in the palette, Debug, captures; at `step` when it names one.
    Reopen,
}

/// The inputs an event reads besides the state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Context {
    /// The stored default (`"pending"`, `"done"`, nil).
    pub stored: Option<String>,
    /// `--skip-onboarding`: it stays away this launch.
    pub skips: bool,
    /// `begin`: this install's first run, before it met Chief.
    pub fresh_install: bool,
    /// `reopen`: the step to show (nil or unknown: the first).
    pub step: Option<String>,
}

/// An event's outcome: the new state, what to store under [`STATE_KEY`] (nil: nothing) and whether
/// `begin` started it now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub state: State,
    pub store: Option<&'static str>,
    pub started: bool,
}

/// `ChiefOnboarding`'s transitions.
pub fn apply(state: State, event: Event, cx: &Context) -> Outcome {
    let mut next = state;
    let mut store = None;
    let mut started = false;
    match event {
        Event::Launch => {
            next.shows = !cx.skips && cx.stored.as_deref() == Some("pending");
            next.decided = cx.skips || cx.stored.is_some();
        }
        Event::Begin => {
            next.decided = true;
            if cx.fresh_install && !cx.skips && cx.stored.is_none() {
                store = Some("pending");
                next.step = Step::Meet;
                next.shows = true;
                started = true;
            }
        }
        Event::Next if state.shows => {
            let index = state.step.index();
            if index == STEPS.len() - 1 {
                return apply(state, Event::Finish, cx);
            }
            next.step = STEPS[index + 1];
            next.write_failed = false;
        }
        Event::Back if state.shows && state.step.index() > 0 => {
            next.step = STEPS[state.step.index() - 1];
            next.write_failed = false;
        }
        Event::Finish if state.shows => {
            store = Some("done");
            next.shows = false;
            next.reopened = false;
            next.step = Step::Meet;
        }
        Event::Reopen => {
            next.decided = true;
            next.step = cx.step.as_deref().and_then(Step::named).unwrap_or_default();
            next.write_failed = false;
            next.reopened = true;
            next.shows = true;
        }
        Event::Next | Event::Back | Event::Finish => {}
    }
    Outcome { state: next, store, started }
}

/// What the model shows: its state and what the step's place gives (`index`, `canGoBack`, `isLast`,
/// `holdsWelcome`). Swift keeps it and sends it back as the next event's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    #[serde(flatten)]
    pub state: State,
    pub index: usize,
    pub can_go_back: bool,
    pub is_last: bool,
    /// Chief's welcome and the Set Up cmux card wait: it shows, or the launch has not decided yet.
    pub holds_welcome: bool,
}

impl View {
    pub fn of(state: State) -> View {
        let index = state.step.index();
        View {
            state,
            index,
            can_go_back: index > 0,
            is_last: index == STEPS.len() - 1,
            holds_welcome: state.shows || !state.decided,
        }
    }
}

/// `ChiefOnboardingPlace`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Place {
    Shows,
    Ends,
    Hidden,
}

/// `ChiefOnboarding.place(chatAt:shownAt:otherChiefs:)`: the first run only on the person's only Chief chat
/// while it is empty, ended by its first message; reopened, on any Chief chat, ended by the next message there.
pub fn place(state: &State, last_seq: u64, shown_at: Option<u64>, other_chiefs: i64) -> Place {
    if !state.shows {
        return Place::Hidden;
    }
    if state.reopened {
        return if shown_at.is_some_and(|at| last_seq > at) { Place::Ends } else { Place::Shows };
    }
    if other_chiefs != 0 {
        return Place::Hidden;
    }
    if last_seq == 0 { Place::Shows } else { Place::Ends }
}

/// The look step's text size: whether it can get one point smaller or larger, and the size `points` more
/// gives (rounded, within the range; nil when it stays the same: `changeTextSize(by:)` writes nothing).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Look {
    pub can_shrink: bool,
    pub can_grow: bool,
    pub size: Option<f64>,
}

pub fn look(size: f64, min: f64, max: f64, points: f64) -> Look {
    // Swift's `min(max((size + points).rounded(), lower), upper)`: `rounded()` is half away from zero.
    let target = (size + points).round().max(min).min(max);
    Look { can_shrink: size > min, can_grow: size < max, size: (target != size).then_some(target) }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApplyRequest {
    #[serde(default)]
    state: State,
    event: Event,
    #[serde(flatten)]
    context: Context,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaceRequest {
    #[serde(default)]
    state: State,
    #[serde(default)]
    last_seq: u64,
    shown_at: Option<u64>,
    #[serde(default)]
    other_chiefs: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRequest {
    size: f64,
    min: f64,
    max: f64,
    #[serde(default)]
    points: f64,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "onboarding" => {
            let req: ApplyRequest = parse(request)?;
            let out = apply(req.state, req.event, &req.context);
            reply(
                &json!({ "view": View::of(out.state), "store": out.store, "started": out.started }),
            )
        }
        "onboardingPlace" => {
            let req: PlaceRequest = parse(request)?;
            reply(
                &json!({ "place": place(&req.state, req.last_seq, req.shown_at, req.other_chiefs) }),
            )
        }
        "onboardingLook" => {
            let req: LookRequest = parse(request)?;
            reply(&look(req.size, req.min, req.max, req.points))
        }
        _ => Err(OpError::Unknown),
    }
}

#[cfg(test)]
#[path = "onboarding_tests.rs"]
mod tests;
