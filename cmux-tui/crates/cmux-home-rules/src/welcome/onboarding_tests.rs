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
    let launch = |stored, skips| apply(State::default(), Event::Launch, &cx(stored, skips)).state;
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
    assert_eq!(place(&State { reopened: true, ..State::default() }, 8, Some(7), 0), Place::Hidden);
}

/// `changeTextSize(by:)`, `canShrinkText`, `canGrowText` over the range 10...16.
#[test]
fn look_cases() {
    assert_eq!(
        look(12.0, 10.0, 16.0, 1.0),
        Look { can_shrink: true, can_grow: true, size: Some(13.0) }
    );
    assert_eq!(look(16.0, 10.0, 16.0, 1.0), Look { can_shrink: true, can_grow: false, size: None });
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
    assert_eq!((begin["store"].clone(), begin["started"].clone()), (json!("pending"), json!(true)));
    assert_eq!(
        call("onboarding", &json!({"event": "reopen", "step": "look"})).unwrap()["view"]["step"],
        json!("look")
    );
    assert_eq!(
        call("onboardingPlace", &json!({"state": {"shows": true}, "lastSeq": 0, "otherChiefs": 0}))
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
        call("onboardingLook", &json!({"size": 12.0, "min": 10.0, "max": 16.0, "points": -1.0}))
            .unwrap(),
        json!({"canShrink": true, "canGrow": true, "size": 11.0})
    );
    assert!(matches!(call("onboarding", &json!({"event": "dance"})), Err(OpError::Invalid(_))));
    assert_eq!(STATE_KEY, "home.firstRun.chiefOnboarding");
}
