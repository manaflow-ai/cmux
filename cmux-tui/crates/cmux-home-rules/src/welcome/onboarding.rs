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
mod tests {
    use super::*;

    fn cx(stored: Option<&str>, skips: bool) -> Context {
        Context { stored: stored.map(str::to_owned), skips, ..Context::default() }
    }

    fn shown(step: Step) -> State {
        State { shows: true, decided: true, step, ..State::default() }
    }

    /// `init`: pending shows; any stored state, or skipping, decides; skipping hides a pending one.
    #[test]
    fn launch_reads_the_stored_state() {
        let launch =
            |stored, skips| apply(State::default(), Event::Launch, &cx(stored, skips)).state;
        assert_eq!((launch(None, false).shows, launch(None, false).decided), (false, false));
        assert_eq!(
            (launch(Some("pending"), false).shows, launch(Some("pending"), false).decided),
            (true, true)
        );
        assert_eq!(
            (launch(Some("done"), false).shows, launch(Some("done"), false).decided),
            (false, true)
        );
        assert_eq!(
            (launch(Some("pending"), true).shows, launch(Some("pending"), true).decided),
            (false, true)
        );
        assert_eq!((launch(None, true).shows, launch(None, true).decided), (false, true));
    }

    /// `begin(freshInstall:)`: only a fresh install with nothing stored and no skip starts it, once.
    #[test]
    fn begin_starts_once_on_a_fresh_install() {
        let begin = |fresh, stored: Option<&str>, skips| {
            let cx = Context { fresh_install: fresh, ..cx(stored, skips) };
            apply(State { step: Step::Look, ..State::default() }, Event::Begin, &cx)
        };
        let started = begin(true, None, false);
        assert!(started.started && started.state.shows && started.state.decided);
        assert_eq!((started.state.step, started.store), (Step::Meet, Some("pending")));
        for out in [
            begin(false, None, false),
            begin(true, Some("done"), false),
            begin(true, Some("pending"), false),
            begin(true, None, true),
        ] {
            assert!(!out.started && !out.state.shows && out.state.decided && out.store.is_none());
            assert_eq!(out.state.step, Step::Look, "a refused begin leaves the step");
        }
    }

    /// Next and Back walk the three steps; next on the last finishes; neither acts while hidden.
    #[test]
    fn next_and_back_walk_the_steps() {
        let none = Context::default();
        let failed = State { write_failed: true, ..shown(Step::Meet) };
        let access = apply(failed, Event::Next, &none);
        assert_eq!(
            (access.state.step, access.state.write_failed, access.store),
            (Step::Access, false, None)
        );
        assert_eq!(apply(shown(Step::Access), Event::Next, &none).state.step, Step::Look);
        let end = apply(State { reopened: true, ..shown(Step::Look) }, Event::Next, &none);
        assert_eq!(end.store, Some("done"));
        assert_eq!(end.state, State { decided: true, ..State::default() });
        let back = apply(State { write_failed: true, ..shown(Step::Look) }, Event::Back, &none);
        assert_eq!((back.state.step, back.state.write_failed), (Step::Access, false));
        let first = State { write_failed: true, ..shown(Step::Meet) };
        assert_eq!(
            apply(first, Event::Back, &none).state,
            first,
            "Back on the first step does nothing"
        );
        let hidden = State { step: Step::Access, write_failed: true, ..State::default() };
        for event in [Event::Next, Event::Back, Event::Finish] {
            let out = apply(hidden, event, &none);
            assert_eq!((out.state, out.store), (hidden, None));
        }
    }

    /// Finish ends it for good at any step; reopen shows it again, at a named step.
    #[test]
    fn finish_and_reopen() {
        let out = apply(
            State { reopened: true, write_failed: true, ..shown(Step::Access) },
            Event::Finish,
            &Context::default(),
        );
        assert_eq!(out.store, Some("done"));
        assert_eq!(out.state, State { decided: true, write_failed: true, ..State::default() });
        let reopen = |step: Option<&str>| {
            let cx = Context { step: step.map(str::to_owned), ..Context::default() };
            apply(
                State { write_failed: true, step: Step::Access, ..State::default() },
                Event::Reopen,
                &cx,
            )
        };
        let again = reopen(None);
        assert_eq!(
            again.state,
            State { shows: true, decided: true, reopened: true, ..State::default() }
        );
        assert_eq!(again.store, None);
        assert_eq!(reopen(Some("look")).state.step, Step::Look);
        assert_eq!(reopen(Some("access")).state.step, Step::Access);
        assert_eq!(reopen(Some("nope")).state.step, Step::Meet);
    }

    /// `place`: the first run on the only empty Chief chat; reopened on any chat until its next message.
    #[test]
    fn place_cases() {
        let first = shown(Step::Meet);
        assert_eq!(place(&first, 0, None, 0), Place::Shows);
        assert_eq!(place(&first, 0, None, 1), Place::Hidden);
        assert_eq!(place(&first, 1, Some(0), 0), Place::Ends);
        assert_eq!(place(&first, 3, None, 0), Place::Ends);
        assert_eq!(place(&State::default(), 7, None, 2), Place::Hidden);
        let reopened = State { reopened: true, ..first };
        assert_eq!(place(&reopened, 7, None, 2), Place::Shows);
        assert_eq!(place(&reopened, 7, Some(7), 2), Place::Shows);
        assert_eq!(place(&reopened, 8, Some(7), 2), Place::Ends);
        assert_eq!(
            place(&State { reopened: true, ..State::default() }, 8, Some(7), 0),
            Place::Hidden
        );
    }

    /// `changeTextSize(by:)`, `canShrinkText`, `canGrowText` over the range 10...16.
    #[test]
    fn look_cases() {
        assert_eq!(
            look(12.0, 10.0, 16.0, 1.0),
            Look { can_shrink: true, can_grow: true, size: Some(13.0) }
        );
        assert_eq!(
            look(16.0, 10.0, 16.0, 1.0),
            Look { can_shrink: true, can_grow: false, size: None }
        );
        assert_eq!(
            look(10.0, 10.0, 16.0, -1.0),
            Look { can_shrink: false, can_grow: true, size: None }
        );
        assert_eq!(look(12.5, 10.0, 16.0, 0.0).size, Some(13.0), "half rounds away from zero");
        assert_eq!(look(11.5, 10.0, 16.0, -1.0).size, Some(11.0));
        assert_eq!(look(9.0, 10.0, 16.0, -1.0).size, Some(10.0), "below the range clamps up");
        assert_eq!(
            look(20.0, 10.0, 16.0, 1.0),
            Look { can_shrink: true, can_grow: false, size: Some(16.0) }
        );
    }

    /// The ops' wire: Swift's request and reply keys.
    #[test]
    fn ops_wire() {
        let out = call("onboarding", &json!({"state": {"shows": true, "decided": true, "step": "access", "reopened": false, "writeFailed": true}, "event": "next", "stored": "pending", "skips": false, "freshInstall": false})).unwrap();
        assert_eq!(
            out,
            json!({"view": {"shows": true, "decided": true, "step": "look", "reopened": false, "writeFailed": false,
            "index": 2, "canGoBack": true, "isLast": true, "holdsWelcome": true}, "store": null, "started": false})
        );
        let back = call("onboarding", &json!({"state": out["view"], "event": "back"})).unwrap();
        assert_eq!(back["view"]["step"], json!("access"), "the view's derived keys are read past");
        let launch = call("onboarding", &json!({"event": "launch"})).unwrap();
        assert_eq!(
            (
                launch["view"]["holdsWelcome"].clone(),
                launch["view"]["index"].clone(),
                launch["view"]["canGoBack"].clone()
            ),
            (json!(true), json!(0), json!(false))
        );
        let begin = call("onboarding", &json!({"event": "begin", "freshInstall": true})).unwrap();
        assert_eq!(
            (begin["store"].clone(), begin["started"].clone()),
            (json!("pending"), json!(true))
        );
        assert_eq!(
            call("onboarding", &json!({"event": "reopen", "step": "look"})).unwrap()["view"]["step"],
            json!("look")
        );
        assert_eq!(
            call(
                "onboardingPlace",
                &json!({"state": {"shows": true}, "lastSeq": 0, "otherChiefs": 0})
            )
            .unwrap(),
            json!({"place": "shows"})
        );
        assert_eq!(
            call(
                "onboardingPlace",
                &json!({"state": {"shows": true, "reopened": true}, "lastSeq": 5, "shownAt": 4})
            )
            .unwrap(),
            json!({"place": "ends"})
        );
        assert_eq!(
            call(
                "onboardingLook",
                &json!({"size": 12.0, "min": 10.0, "max": 16.0, "points": -1.0})
            )
            .unwrap(),
            json!({"canShrink": true, "canGrow": true, "size": 11.0})
        );
        assert!(matches!(call("onboarding", &json!({"event": "dance"})), Err(OpError::Invalid(_))));
        assert_eq!(STATE_KEY, "home.firstRun.chiefOnboarding");
    }
}
