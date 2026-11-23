use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::desktop::fake::{Event, FakeDesktop};
use crate::policy::Mode;

struct Recorder(Mutex<Vec<CursorEvent>>);
impl CursorSink for Recorder {
    fn show(&self, e: CursorEvent) {
        self.0.lock().unwrap().push(e);
    }
}

struct Scripted(Mutex<Vec<Answer>>, Mutex<Vec<Question>>);
impl Approver for Scripted {
    fn ask(&self, q: &Question) -> Answer {
        self.1.lock().unwrap().push(q.clone());
        self.0.lock().unwrap().pop().unwrap_or(Answer::Unavailable)
    }
}

struct Busy;
impl PersonActivity for Busy {
    fn wait_idle(&self, _limit: Duration) -> bool {
        false
    }
}

/// Time that only moves when the engine sleeps: the settle wait's ceiling is
/// exact, and tests never wait.
fn instant_time(parts: &mut EngineParts) -> Arc<AtomicU64> {
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now.clone());
    parts.sleep = Arc::new(move |d| {
        a.fetch_add(d.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    now
}

fn ctx(call: Option<&str>) -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: call.map(str::to_string),
        origin: OriginKind::Local,
        tag: None,
    }
}

fn engine(desktop: Arc<FakeDesktop>, config: PolicyConfig) -> Engine {
    let mut parts = EngineParts::new(desktop);
    instant_time(&mut parts);
    parts.config = config;
    instant_time(&mut parts);
    Engine::new(parts)
}

#[test]
fn click_maps_screenshot_pixels_to_desktop_points() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    let shot = e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert!(!shot.is_error, "{:?}", shot.body);
    // Window 1 is 800x600 pt at 2x = 1600x1200 px, downscaled to 1456 long edge.
    assert_eq!(shot.body["width"], 1456);
    let k = 800.0 / 1456.0;
    // The far right edge, below the title bar (a click on a bare title bar is refused).
    let out =
        e.call(&ctx(Some("c1")), "click", &json!({"window_id": "1", "x": 1456.0, "y": 728.0}));
    assert!(!out.is_error, "{:?}", out.body);
    let Event::Click { point: Some(p), .. } = &d.events()[0] else { panic!("{:?}", d.events()) };
    assert!((p.x - (100.0 + 1456.0 * k)).abs() < 1e-6 && (p.y - (100.0 + 728.0 * k)).abs() < 1e-6);
}

#[test]
fn a_retried_call_id_does_not_click_twice() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    let args = json!({"window_id": "1", "element_id": "e1"});
    let mut first = e.call(&ctx(Some("same")), "click", &args);
    let second = e.call(&ctx(Some("same")), "click", &args);
    // The retry returns the recorded action; the state after it came with the first reply only.
    assert!(first.body.get("state").is_some());
    first.body.as_object_mut().unwrap().remove("state");
    first.png_base64 = None;
    assert_eq!(first, second);
    assert_eq!(d.events().len(), 1);
    e.call(&ctx(Some("other")), "click", &args);
    assert_eq!(d.events().len(), 2);
}

#[test]
fn denied_apps_are_refused_and_redacted() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    e.call(&ctx(None), "screenshot", &json!({"window_id": "2"}));
    let out = e.call(&ctx(None), "click", &json!({"window_id": "2", "x": 1, "y": 1}));
    assert_eq!(out.code.as_deref(), Some("app_denied"));
    assert!(d.events().is_empty());
    let shot = e.call(&ctx(None), "screenshot", &json!({}));
    assert_eq!(shot.body["redacted_windows"], 1);
    let windows = e.call(&ctx(None), "list_windows", &json!({}));
    let pw = &windows.body["windows"][0];
    assert_eq!(pw["denied"], true);
    assert_eq!(pw["title"], "");
}

#[test]
fn approved_apps_asks_and_saves_always() {
    let d = Arc::new(FakeDesktop::standard());
    let approver = Arc::new(Scripted(Mutex::new(vec![Answer::AlwaysAllow]), Mutex::new(vec![])));
    let mut parts = EngineParts::new(d);
    instant_time(&mut parts);
    parts.config = PolicyConfig { mode: Mode::ApprovedApps, ..PolicyConfig::default() };
    parts.approver = approver.clone();
    let e = Engine::new(parts);
    let args = json!({"window_id": "1", "element_id": "e1"});
    assert!(!e.call(&ctx(Some("a")), "click", &args).is_error);
    assert!(!e.call(&ctx(Some("b")), "click", &args).is_error);
    let asked = approver.1.lock().unwrap();
    assert_eq!(asked.len(), 1, "asked once");
    assert!(asked[0].remember);
    assert_eq!(asked[0].app.name, "Safari");
    assert!(e.sessions().saved().is_always("com.apple.Safari"));
}

#[test]
fn nobody_to_ask_fails_closed() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig { mode: Mode::AskEveryTime, ..PolicyConfig::default() });
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert_eq!(out.code.as_deref(), Some("approval_unavailable"));
    assert!(d.events().is_empty());
}

#[test]
fn takeover_pauses_acting_but_not_looking() {
    let mut fake = FakeDesktop::standard();
    fake.windows[1].focused = true; // Safari is the window the person is using.
    let d = Arc::new(fake);
    let mut parts = EngineParts::new(d);
    instant_time(&mut parts);
    parts.takeover = Arc::new(Busy);
    instant_time(&mut parts);
    let e = Engine::new(parts);
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert_eq!(out.code.as_deref(), Some("person_in_control"));
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
}

#[test]
fn takeover_never_holds_background_input_to_a_window_the_person_is_not_using() {
    let d = Arc::new(FakeDesktop::standard());
    let mut parts = EngineParts::new(d.clone());
    instant_time(&mut parts);
    parts.takeover = Arc::new(Busy);
    instant_time(&mut parts);
    parts.config.allow_foreground = true;
    let e = Engine::new(parts);
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(d.events().len(), 1);
    // Foreground input is system-wide: it still waits for the person.
    let out = e.call(
        &ctx(None),
        "type_text",
        &json!({"window_id": "1", "text": "hi", "delivery": "foreground"}),
    );
    assert_eq!(out.code.as_deref(), Some("person_in_control"));
}

struct Slept(Mutex<Vec<Duration>>);

fn settling_engine(d: Arc<FakeDesktop>) -> (Engine, Arc<Slept>) {
    let slept = Arc::new(Slept(Mutex::new(vec![])));
    let mut parts = EngineParts::new(d);
    let now = instant_time(&mut parts);
    let rec = slept.clone();
    parts.sleep = Arc::new(move |t| {
        now.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
        rec.0.lock().unwrap().push(t);
    });
    (Engine::new(parts), slept)
}

#[test]
fn an_action_returns_the_window_after_it_in_one_reply() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, slept) = settling_engine(d.clone());
    let out = e.call(&ctx(Some("c1")), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert!(!out.is_error, "{:?}", out.body);
    let state = &out.body["state"];
    // Nothing seen before: the first capture after the floor is new.
    assert_eq!(state["unchanged"], false);
    assert_eq!(state["waited_ms"], 120);
    assert_eq!(state["width"], 1456);
    // The first look at the window: the whole outline, with small ids.
    assert_eq!(
        state["tree"],
        "[1] window \"com.apple.Safari window\"\n  [2] button \"OK\"\nFocus: no element of this window has keyboard focus"
    );
    assert!(out.png_base64.is_some());
    assert_eq!(*slept.0.lock().unwrap(), vec![Duration::from_millis(120)]);
    // The action is recorded without the state: a retry returns it as it was.
    let again = e.call(&ctx(Some("c1")), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert!(again.body.get("state").is_none() && again.png_base64.is_none());
    assert_eq!(d.events().len(), 1);
}

#[test]
fn the_settle_wait_stops_at_the_first_change() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, slept) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    // The app redraws on the third capture after the agent's screenshot.
    *d.repaint_from.lock().unwrap() = Some((4, 77));
    let out = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "Return"}));
    let state = &out.body["state"];
    assert_eq!(state["unchanged"], false, "{state}");
    assert_eq!(state["waited_ms"], 320);
    assert_eq!(*d.captures.lock().unwrap(), 4);
    assert_eq!(slept.0.lock().unwrap().len(), 3);
    assert!(out.png_base64.is_some());
}

#[test]
fn the_settle_wait_never_passes_the_ceiling() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, _) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "x"}));
    let state = &out.body["state"];
    // Nothing redraws: unchanged at the ceiling, no image (the agent has it).
    assert_eq!(state["unchanged"], true);
    assert_eq!(state["waited_ms"], 1000);
    assert!(out.png_base64.is_none());
    assert_eq!(*d.captures.lock().unwrap(), 1 + 10);
}

/// Leo (ask-cdfac12eab): "why do we ever even wait for screen frames? we
/// shouldnt bother most of the time i think". An app whose accessibility
/// signals are watched and that sent none, with its window unchanged after
/// the floor, returns at the floor after one capture: no frame-by-frame wait
/// to the ceiling.
#[test]
fn a_silent_app_is_not_watched_frame_by_frame() {
    let d = Arc::new(FakeDesktop::standard());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    let (e, slept) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "x"}));
    let state = &out.body["state"];
    assert_eq!(state["unchanged"], true, "{state}");
    assert_eq!(state["waited_ms"], 120, "{state}");
    assert_eq!(*d.captures.lock().unwrap(), 1 + 1);
    assert_eq!(*slept.0.lock().unwrap(), vec![Duration::from_millis(120)]);
}

/// An app that signalled a change its window does not show yet is still
/// watched until the change shows (within the ceiling), a signal it sent
/// while the action ran included: the watch counts from before the action.
#[test]
fn a_signalled_change_is_waited_for_until_it_shows() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, _) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    // One signal since the watch started (sent while the key went in); the
    // app redraws on the third capture after the agent's screenshot.
    *d.signals.lock().unwrap() =
        Some(crate::desktop::Signals { in_window: 1, ..Default::default() });
    *d.repaint_from.lock().unwrap() = Some((4, 77));
    let out = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "Return"}));
    assert_eq!(out.body["state"]["unchanged"], false, "{}", out.body);
    assert_eq!(*d.captures.lock().unwrap(), 1 + 3);
}

/// Bug 5 and the verified results: input the route only delivered, whose
/// effect must show in the window (`shows`), after which nothing changed
/// through a real settle wait (pixels, elements, windows of any process,
/// the pasteboard, the app's accessibility signals) is `no_effect`, with the
/// older `evidence: no_visible_change` and its note (agents reported
/// unchanged state as done, 31 of 70 trials).
#[test]
fn a_delivered_action_with_no_visible_change_says_so() {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    // Review of 02ca109 (7): no_effect needs a read-back that read the
    // target unchanged.
    *d.reads_back.lock().unwrap() = Some(false);
    let (e, _) = settling_engine(d);
    // The elements' baseline (a look at the tree), then the pixels'.
    assert!(!e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["state"]["unchanged"], true);
    assert_eq!(out.body["outcome"], "no_effect", "{}", out.body);
    assert_eq!(out.body["evidence"], "no_visible_change", "{}", out.body);
    assert!(out.body.get("shows").is_none(), "{}", out.body);
    let note = out.body["note"].as_str().unwrap();
    // The app signalled nothing and its window held at the first look: the
    // settle ends there (ask-cdfac12eab), not at the 1 s ceiling.
    assert!(note.contains("no visible change within 120 ms"), "{}", out.body);
    assert!(note.contains("take a screenshot before retrying"), "{}", out.body);
}

/// Review of b4236e6 (3): a screenshot and then the action gives the
/// pixels a baseline but not the elements (the state's first look): an
/// effect in the elements is unknown, so it is never no_effect.
#[test]
fn a_first_look_at_the_elements_is_never_no_effect() {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    let (e, _) = settling_engine(d);
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert_eq!(out.body["state"]["unchanged"], true, "{}", out.body);
    assert_eq!(out.body["outcome"], "uncertain", "{}", out.body);
    assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
}

/// The truth matrix's FNs: a popover's button and a submenu item acted
/// where the window showed nothing. An effect that may not show (no
/// `shows`), or an app nobody could watch, is never `no_effect`.
#[test]
fn nothing_seen_is_no_effect_only_where_the_effect_must_show() {
    for (shows, listening) in [(None, true), (Some("text"), false)] {
        let d = Arc::new(FakeDesktop::standard());
        *d.shows.lock().unwrap() = shows.map(String::from);
        if listening {
            *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        }
        let (e, _) = settling_engine(d);
        assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
        let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
        assert_eq!(out.body["state"]["unchanged"], true);
        assert_eq!(out.body["outcome"], "uncertain", "{shows:?}: {}", out.body);
        assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
    }
}

/// An app's signal (a value changed in a popover), or a copy to the
/// pasteboard, is a change the window's pixels miss: `uncertain`, saying so,
/// and the signals are in the result.
#[test]
fn a_signal_or_a_copy_outside_the_pixels_is_not_no_effect() {
    for copy in [false, true] {
        let d = Arc::new(FakeDesktop::standard());
        *d.shows.lock().unwrap() = Some("text".into());
        let mut signals = crate::desktop::Signals::default();
        if !copy {
            signals.elsewhere = 1;
            signals.kinds.insert("AXValueChanged".into(), 1);
        }
        *d.signals.lock().unwrap() = Some(signals);
        *d.copies_on_input.lock().unwrap() = copy;
        let (e, _) = settling_engine(d);
        assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
        let out = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "cmd+c"}));
        assert_eq!(out.body["outcome"], "uncertain", "{}", out.body);
        let reason = out.body["outcome_reason"].as_str().unwrap();
        if copy {
            assert!(reason.contains("pasteboard"), "{reason}");
        } else {
            assert!(reason.contains("AXValueChanged"), "{reason}");
            assert_eq!(out.body["signals"]["elsewhere"], 1);
        }
    }
}

/// A route that reads the effect back is `confirmed`.
#[test]
fn a_read_back_is_confirmed() {
    let d = Arc::new(FakeDesktop::standard());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    let (e, _) = settling_engine(d);
    let out = e.call(
        &ctx(None),
        "set_value",
        &json!({"window_id": "1", "element_id": "e1", "value": "x"}),
    );
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(out.body["outcome"], "confirmed", "{}", out.body);
}

/// Typed keys land after they are posted: the route's read-back, done
/// after the settle, confirms them; a read-back that fails confirms
/// nothing (and the request never reaches the result).
#[test]
fn a_read_back_after_the_settle_confirms_typed_keys() {
    for (reads, outcome) in [(true, "confirmed"), (false, "uncertain")] {
        let d = Arc::new(FakeDesktop::standard());
        *d.reads_back.lock().unwrap() = Some(reads);
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        d.repaint_from.lock().unwrap().replace((2, 9));
        let (e, _) = settling_engine(d);
        assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
        let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "Zed"}));
        assert_eq!(out.body["outcome"], outcome, "{}", out.body);
        assert!(out.body.get("expect").is_none(), "{}", out.body);
        assert_eq!(out.body["evidence"], if reads { "confirmed" } else { "delivered" });
        assert_eq!(out.body["read_back"], if reads { "text" } else { "failed" });
    }
}

/// Review of b4236e6 (8): every confirmed result is read again after the
/// settle; an effect the app undid is no longer confirmed, and a state that
/// already matched is uncertain, saying so.
#[test]
fn a_confirmed_result_is_read_again_after_the_settle() {
    for (reads, already, outcome, read_back) in [
        (false, false, "uncertain", "failed"),
        (true, true, "uncertain", "already"),
        (true, false, "confirmed", "text"),
    ] {
        let d = Arc::new(FakeDesktop::standard());
        *d.reads_back.lock().unwrap() = Some(reads);
        *d.already.lock().unwrap() = already;
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        let (e, _) = settling_engine(d);
        let out = e.call(
            &ctx(None),
            "set_value",
            &json!({"window_id": "1", "element_id": "e1", "value": "x"}),
        );
        assert_eq!(out.body["outcome"], outcome, "{}", out.body);
        assert_eq!(out.body["read_back"], read_back, "{}", out.body);
        if !reads {
            assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
            assert!(out.body["note"].as_str().unwrap().contains("no longer shows"), "{}", out.body);
        }
    }
}

/// Review of e75f474 (5): a confirmed result that cannot be read again
/// after the settle is delivered, saying so, so it is uncertain.
#[test]
fn a_confirmed_result_that_cannot_be_reread_is_uncertain() {
    for (reread, outcome) in
        [(Some(true), "confirmed"), (None, "uncertain"), (Some(false), "uncertain")]
    {
        let d = Arc::new(FakeDesktop::standard());
        *d.confirms_on_reread.lock().unwrap() = reread;
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        let (e, _) = settling_engine(d);
        let out = e.call(
            &ctx(None),
            "perform_action",
            &json!({"window_id": "1", "element_id": "e1", "action": "press"}),
        );
        assert_eq!(out.body["outcome"], outcome, "{reread:?}: {}", out.body);
        if reread != Some(true) {
            assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
            assert!(
                out.body["note"].as_str().unwrap().contains("after the settle"),
                "{}",
                out.body
            );
        }
    }
}

/// Review of e840a32 (root A, finding 1): a read-back that holds after the
/// settle but states no change (its wanted state held before the action:
/// a stepper asked for the value it had) never confirms, whether the route
/// delivered or confirmed; the result is uncertain, saying so.
#[test]
fn a_read_back_that_states_no_change_never_confirms() {
    for (tool, args) in [
        ("type_text", json!({"window_id": "1", "text": "Zed"})),
        ("set_value", json!({"window_id": "1", "element_id": "e1", "value": "x"})),
        ("perform_action", json!({"window_id": "1", "element_id": "e1", "action": "press"})),
    ] {
        let d = Arc::new(FakeDesktop::standard());
        *d.reads_back.lock().unwrap() = Some(true);
        *d.unchanged.lock().unwrap() = true;
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        let (e, _) = settling_engine(d);
        let out = e.call(&ctx(None), tool, &args);
        assert_eq!(out.body["outcome"], "uncertain", "{tool}: {}", out.body);
        assert_eq!(out.body["evidence"], "delivered", "{tool}: {}", out.body);
        assert_eq!(out.body["read_back"], "already", "{tool}: {}", out.body);
    }
}

/// A set_value whose read-back cannot be read after the settle is never
/// no_effect, even with nothing else changed (a web field that does not
/// answer); one that reads back unchanged, with nothing else changed, is.
#[test]
fn no_effect_needs_the_value_read_back() {
    for (reads, outcome) in [(None, "uncertain"), (Some(false), "no_effect")] {
        let d = Arc::new(FakeDesktop::standard());
        *d.shows.lock().unwrap() = Some("value".into());
        *d.reads_back.lock().unwrap() = Some(true);
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        let (e, _) = settling_engine(d.clone());
        assert!(!e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"})).is_error);
        assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
        *d.reads_back.lock().unwrap() = reads;
        *d.reads_back_expect.lock().unwrap() = true;
        let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
        assert_eq!(out.body["outcome"], outcome, "{reads:?}: {}", out.body);
    }
}

/// Review of 02ca109 (2): a batch step's confirmed goes through the one
/// confirm rule (its read-back must show the change) and loses the route's
/// internal keys.
#[test]
fn a_batch_step_goes_through_the_confirm_rule() {
    let d = Arc::new(FakeDesktop::standard());
    *d.confirms_on_reread.lock().unwrap() = None;
    let (e, _) = settling_engine(d);
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "1", "actions": [{"action": "set_value", "element_id": "e1", "value": "x"}]}),
    );
    let step = &out.body["results"][0];
    assert_eq!(step["status"], "done", "{}", out.body);
    assert_eq!(step["evidence"], "delivered", "{}", out.body);
    assert!(step.get("expect").is_none() && step.get("shows").is_none(), "{}", out.body);
}

/// Each acting step settles on its own and is read back after that settle,
/// whatever the batch's `observe` (which only decides the batch's state).
#[test]
fn batch_steps_are_read_back_after_their_own_settle() {
    for observe in [true, false] {
        let d = Arc::new(FakeDesktop::standard());
        let (e, _) = settling_engine(d);
        let out = e.call(
            &ctx(None),
            "batch",
            &json!({"window_id": "1", "observe": observe,
                    "actions": [{"action": "set_value", "element_id": "e1", "value": "x"}]}),
        );
        let step = &out.body["results"][0];
        assert_eq!(step["evidence"], "confirmed", "observe {observe}: {}", out.body);
        assert_eq!(step["outcome"], "confirmed", "observe {observe}: {}", out.body);
        assert!(step.get("expect").is_none(), "{}", out.body);
        assert_eq!(out.body.get("state").is_some(), observe, "{}", out.body);
    }
}

/// Review of d890b98 (1): a later step's effect must not confirm an earlier
/// one. Each step's outcome is decided after its own settle, before the next
/// step runs, so two steps on the same element are each judged on their own.
#[test]
fn a_batch_step_is_not_confirmed_by_a_later_step() {
    let d = Arc::new(FakeDesktop::standard());
    *d.confirms_on_reread.lock().unwrap() = Some(false);
    let (e, _) = settling_engine(d);
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "set_value", "element_id": "e1", "value": "x"},
            {"action": "set_value", "element_id": "e1", "value": "y"}
        ]}),
    );
    // The first read back nothing after its own settle: it stays delivered,
    // even though nothing stops a later read from showing a value.
    assert_eq!(out.body["results"][0]["evidence"], "delivered", "{}", out.body);
    assert_eq!(out.body["results"][0]["read_back"], "failed", "{}", out.body);
    assert_eq!(out.body["results"][1]["evidence"], "delivered", "{}", out.body);
}

/// Review of 02ca109 (follow-up): without an adaptive settle (observe false)
/// nothing is confirmed.
#[test]
fn without_a_settle_nothing_is_confirmed() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, _) = settling_engine(d);
    let out = e.call(
        &ctx(None),
        "set_value",
        &json!({"window_id": "1", "element_id": "e1", "value": "x", "observe": false}),
    );
    assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
    assert_ne!(out.body["outcome"], "confirmed", "{}", out.body);
}

/// Review of 02ca109 (7): where an effect must show counts only with a
/// read-back to check it; without one, never no_effect.
#[test]
fn no_effect_needs_a_read_back() {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    let (e, _) = settling_engine(d);
    assert!(!e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert_eq!(out.body["outcome"], "uncertain", "{}", out.body);
}

/// Review of 02ca109 (6): the record written before the outcome never says
/// confirmed.
#[test]
fn the_record_before_the_outcome_is_never_confirmed() {
    let out = ToolOutput::ok(json!({"evidence": "confirmed", "expect": {}, "shows": "value"}));
    let record: Value = serde_json::from_str(&provisional_record(&out)).unwrap();
    let body = &record["body"];
    assert_eq!(body["evidence"], "delivered", "{record}");
    assert_eq!(body["outcome"], "uncertain", "{record}");
    assert!(body.get("expect").is_none() && body.get("shows").is_none(), "{record}");
}

/// Root B at the engine: a route whose baseline could not be read attaches
/// no read-back, and a confirmed result without one is uncertain.
#[test]
fn a_route_with_no_baseline_is_never_confirmed() {
    let d = Arc::new(FakeDesktop::standard());
    *d.confirms_on_reread.lock().unwrap() = None;
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    let (e, _) = settling_engine(d);
    let out = e.call(
        &ctx(None),
        "perform_action",
        &json!({"window_id": "1", "element_id": "e1", "action": "press"}),
    );
    assert_eq!(out.body["outcome"], "uncertain", "{}", out.body);
    assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
}

/// Review of b4236e6 (10): a stalled app shows nothing because it does
/// nothing; without an answer after the settle, never no_effect.
#[test]
fn a_stalled_app_is_never_no_effect() {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
    *d.responsive.lock().unwrap() = Some(false);
    let (e, _) = settling_engine(d);
    assert!(!e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert_eq!(out.body["outcome"], "uncertain", "{}", out.body);
    assert!(
        out.body["outcome_reason"].as_str().unwrap().contains("did not answer"),
        "{}",
        out.body
    );
}

/// Review of b4236e6 (12): a retried call id returns the result without the
/// route's internal keys.
#[test]
fn a_retry_record_has_no_internal_keys() {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.reads_back.lock().unwrap() = Some(true);
    let e = engine(d, PolicyConfig::default());
    let args = json!({"window_id": "1", "x": 10, "y": 100, "observe": false});
    let first = e.call(&ctx(Some("r1")), "click", &args);
    let again = e.call(&ctx(Some("r1")), "click", &args);
    for out in [&first, &again] {
        assert!(
            out.body.get("shows").is_none() && out.body.get("expect").is_none(),
            "{}",
            out.body
        );
    }
}

/// The settle wait ends at a change only once the app has gone quiet: a
/// signal since the capture before keeps it waiting (within the ceiling),
/// and the changed capture is what comes back.
#[test]
fn the_settle_wait_holds_while_the_app_still_signals() {
    struct Counting(std::sync::atomic::AtomicU32);
    impl Watch for Counting {
        fn signals(&self) -> crate::desktop::Signals {
            // One more signal on each of the first three reads.
            let n = self.0.fetch_add(1, Ordering::SeqCst).min(3);
            crate::desktop::Signals { in_window: n, ..Default::default() }
        }
        fn listening(&self) -> bool {
            true
        }
    }
    let d = Arc::new(FakeDesktop::standard());
    let (e, slept) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    *d.repaint_from.lock().unwrap() = Some((2, 55));
    let counting = Counting(std::sync::atomic::AtomicU32::new(0));
    let mut out = ToolOutput::ok(json!({"evidence": "delivered"}));
    let app = e.app_of(&e.window("1").unwrap());
    let settled = e.attach_state(
        &ctx(None),
        "1",
        &app,
        &mut out,
        SettleMode::Adaptive,
        false,
        Some(&counting),
    );
    // Reads: 0 before, 1 (changed, not quiet), 2 (not quiet), 3, 3 (quiet).
    assert_eq!(out.body["state"]["unchanged"], false, "{}", out.body);
    assert!(out.png_base64.is_some());
    assert_eq!(*d.captures.lock().unwrap(), 1 + 4);
    assert_eq!(settled, Some(420));
    assert_eq!(slept.0.lock().unwrap().len(), 1 + 3);
}

/// Bug 5 review: the openai and anthropic settle modes capture once (at
/// once, or after a fixed delay), which proves nothing: an unchanged window
/// there keeps `delivered`.
#[test]
fn single_capture_settle_modes_never_claim_no_visible_change() {
    for mode in ["openai", "anthropic"] {
        let (d, e, _) = settled(mode);
        *d.shows.lock().unwrap() = Some("text".into());
        *d.signals.lock().unwrap() = Some(crate::desktop::Signals::default());
        assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
        e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
        let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
        assert_eq!(out.body["state"]["unchanged"], true, "{mode}: {}", out.body);
        assert_eq!(out.body["evidence"], "delivered", "{mode}: {}", out.body);
        assert_eq!(out.body["outcome"], "uncertain", "{mode}: {}", out.body);
    }
}

/// Review 2 (8): an action that opened a window of the app (a sheet, a
/// dialog) is not called no_visible_change though the target window's
/// pixels stayed the same.
#[test]
fn a_new_window_of_the_app_is_a_visible_change() {
    let d = Arc::new(FakeDesktop::standard());
    let mut sheet = d.windows.iter().find(|w| w.id == "1").unwrap().clone();
    sheet.id = "77".into();
    sheet.on_screen = true;
    let (e, _) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    *d.opens_on_input.lock().unwrap() = Some(sheet);
    e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert_eq!(out.body["state"]["unchanged"], true, "{}", out.body);
    assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
}

/// Review 4 (7): a window of another process opening over the target (a
/// Save panel served by another process) is a visible change too.
#[test]
fn a_window_of_another_process_over_the_target_is_a_visible_change() {
    let d = Arc::new(FakeDesktop::standard());
    let target = d.windows.iter().find(|w| w.id == "1").unwrap().clone();
    let mut panel = target.clone();
    panel.id = "88".into();
    panel.pid = target.pid + 1000;
    panel.on_screen = true;
    let (e, _) = settling_engine(d.clone());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    *d.opens_on_input.lock().unwrap() = Some(panel);
    e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    assert_eq!(out.body["state"]["unchanged"], true, "{}", out.body);
    assert_eq!(out.body["evidence"], "delivered", "{}", out.body);
}

/// A result that reports a menu (a right-click that opened a context menu)
/// is never `no_effect`: the menu is the effect (seen live on macOS 27.0.1:
/// the menu opened, the window's pixels did not change).
#[test]
fn a_result_that_reports_a_menu_is_not_no_visible_change() {
    let facts = crate::outcome::Facts {
        evidence: "delivered".into(),
        shows: Some("value".into()),
        menu: true,
        settled_ms: Some(1000),
        changes: Some(json!({
            "pixels": "same", "elements_read": "all", "added": 0, "changed": 0, "removed": 0
        })),
        signals: Some(crate::desktop::Signals::default()),
        outside: Some(vec![]),
        already: false,
        responsive: Some(true),
    };
    assert_eq!(crate::outcome::decide(&facts).outcome, crate::outcome::Outcome::Uncertain);
    let plain = crate::outcome::Facts { menu: false, ..facts };
    assert_eq!(crate::outcome::decide(&plain).outcome, crate::outcome::Outcome::NoEffect);
}

/// The rule claims only what the engine saw: a redraw, or no capture before
/// the action to compare with, leaves `delivered`.
#[test]
fn a_redraw_or_no_earlier_capture_keeps_delivered() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, _) = settling_engine(d.clone());
    let first = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "Return"}));
    assert_eq!(first.body["state"]["unchanged"], false);
    assert_eq!(first.body["evidence"], "delivered");
    *d.repaint_from.lock().unwrap() = Some((*d.captures.lock().unwrap() + 2, 91));
    let out = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "Return"}));
    assert_eq!(out.body["state"]["unchanged"], false, "{}", out.body);
    assert_eq!(out.body["evidence"], "delivered");
}

#[test]
fn observe_false_skips_the_state() {
    let d = Arc::new(FakeDesktop::standard());
    let (e, slept) = settling_engine(d.clone());
    let out = e.call(
        &ctx(None),
        "click",
        &json!({"window_id": "1", "element_id": "e1", "observe": false}),
    );
    assert!(out.body.get("state").is_none() && out.png_base64.is_none());
    assert!(slept.0.lock().unwrap().is_empty());
    assert_eq!(*d.captures.lock().unwrap(), 0);
}

#[test]
fn unchanged_screenshot_has_no_image() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    let a = e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert!(a.png_base64.is_some());
    let b = e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert_eq!(b.body["unchanged"], true);
    assert!(b.png_base64.is_none());
    *d.paint.lock().unwrap() = 10;
    let c = e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert!(c.png_base64.is_some());
}

#[test]
fn cursor_glides_then_clicks() {
    let d = Arc::new(FakeDesktop::standard());
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    let mut parts = EngineParts::new(d);
    instant_time(&mut parts);
    parts.cursor = rec.clone();
    let e = Engine::new(parts);
    e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    rec.0.lock().unwrap().clear();
    e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 100}));
    let events = rec.0.lock().unwrap();
    assert!(matches!(events[0], CursorEvent::Move { .. }));
    assert!(matches!(events[1], CursorEvent::Click { .. }));
    drop(events);
    e.end_session("s1");
    assert!(matches!(rec.0.lock().unwrap().last(), Some(CursorEvent::Hide { .. })));
}

#[test]
fn click_without_window_hit_tests_the_display_screenshot() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    e.call(&ctx(None), "screenshot", &json!({}));
    // Display is 1000x800 pt at 2x -> 1456 px wide: (150, 150) pt is Safari.
    let k = 1456.0 / 1000.0;
    let out = e.call(&ctx(None), "click", &json!({"x": 150.0 * k, "y": 150.0 * k}));
    assert!(!out.is_error, "{:?}", out.body);
    let Event::Click { window, .. } = &d.events()[0] else { panic!() };
    assert_eq!(window, "1");
    // (250, 250) pt is 1Password, on top: denied.
    let out = e.call(&ctx(None), "click", &json!({"x": 250.0 * k, "y": 250.0 * k}));
    assert_eq!(out.code.as_deref(), Some("app_denied"));
}

#[test]
fn ui_tree_frames_come_back_in_screenshot_pixels() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig::default());
    e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    let t = e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1", "format": "json"}));
    let f = &t.body["root"]["children"][0]["frame"];
    let k: f64 = 1456.0 / 800.0;
    assert_eq!(f["x"].as_f64().unwrap(), (10.0 * k).round());
}

#[test]
fn off_refuses_everything_but_status() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig { mode: Mode::Off, ..PolicyConfig::default() });
    assert!(!e.call(&ctx(None), "status", &json!({})).is_error);
    assert_eq!(
        e.call(&ctx(None), "list_apps", &json!({})).code.as_deref(),
        Some("computer_use_off")
    );
}

#[test]
fn mcp_shape() {
    let mut out = ToolOutput::ok(json!({"a": 1}));
    out.png_base64 = Some("AAAA".into());
    let v = out.to_mcp();
    assert_eq!(v["content"][1]["type"], "image");
    assert_eq!(v["isError"], false);
}

#[test]
fn launch_checks_what_would_really_start_not_the_agents_words() {
    let d = Arc::new(FakeDesktop::standard());
    let config = PolicyConfig { denied_apps: vec!["cmd.exe".into()], ..PolicyConfig::default() };
    let e = engine(d.clone(), config);
    for id in ["cmd", "CMD.EXE", "C:\\Windows\\System32\\cmd.exe"] {
        let out = e.call(&ctx(None), "launch_app", &json!({"app_id": id}));
        assert_eq!(out.code.as_deref(), Some("app_denied"), "{id}");
    }
    assert!(d.events().is_empty(), "nothing was launched");
}

#[test]
fn never_apps_are_painted_out_and_marked_in_listings() {
    let d = Arc::new(FakeDesktop::standard());
    let config = PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() };
    let e = engine(d, config);
    assert_eq!(e.call(&ctx(None), "screenshot", &json!({})).body["redacted_windows"], 0);
    e.sessions().update_saved(|s| s.set_never("com.1password.1password"));
    assert_eq!(
        e.call(&ctx(None), "screenshot", &json!({"force": true})).body["redacted_windows"],
        1
    );
    let windows = e.call(&ctx(None), "list_windows", &json!({}));
    assert_eq!(windows.body["windows"][0]["denied"], true);
    let apps = e.call(&ctx(None), "list_apps", &json!({}));
    assert_eq!(apps.body["apps"][1]["denied_reason"], "app_never_allowed");
}

#[test]
fn a_call_cut_off_by_a_restart_is_not_run_again() {
    let dir = std::env::temp_dir().join(format!("cu-engine-restart-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // The first worker recorded the click as started, then stopped.
    Sessions::open(Some(&dir)).begin("s1", "cut");
    let d = Arc::new(FakeDesktop::standard());
    let mut parts = EngineParts::new(d.clone());
    instant_time(&mut parts);
    parts.state_dir = Some(dir.clone());
    let e = Engine::new(parts);
    let out = e.call(&ctx(Some("cut")), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert_eq!(out.code.as_deref(), Some("maybe_done"));
    assert!(d.events().is_empty());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn labels_shown_to_the_person_are_bounded() {
    assert_eq!(safe_label("Claude\n\tCode"), "Claude Code");
    assert_eq!(safe_label("\u{7}"), "Agent");
    let long = "x".repeat(500);
    assert_eq!(safe_label(&long).chars().count(), LABEL_MAX_CHARS);
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    let mut parts = EngineParts::new(Arc::new(FakeDesktop::standard()));
    instant_time(&mut parts);
    parts.cursor = rec.clone();
    let e = Engine::new(parts);
    let mut c = ctx(None);
    c.label = long;
    e.call(&c, "screenshot", &json!({"window_id": "1"}));
    rec.0.lock().unwrap().clear();
    e.call(&c, "click", &json!({"window_id": "1", "x": 1, "y": 100}));
    let events = rec.0.lock().unwrap();
    let CursorEvent::Move { label, .. } = &events[0] else { panic!() };
    assert_eq!(label.chars().count(), LABEL_MAX_CHARS);
}

#[test]
fn an_isolated_window_capture_paints_nothing_out_of_the_target() {
    // 1Password (denied) is drawn over Safari's window. Composited capture:
    // the overlap is painted out. Isolated capture (macOS, Windows): the
    // shot holds only Safari's pixels, so nothing is painted out of it.
    let composited = engine(Arc::new(FakeDesktop::standard()), PolicyConfig::default());
    let shot = composited.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert_eq!(shot.body["redacted_windows"], 1);
    let mut desktop = FakeDesktop::standard();
    desktop.isolated_window_capture = true;
    let isolated = engine(Arc::new(desktop), PolicyConfig::default());
    let shot = isolated.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert_eq!(shot.body["redacted_windows"], 0);
    // A display shot still paints the denied window out.
    let display = isolated.call(&ctx(None), "screenshot", &json!({}));
    assert_eq!(display.body["redacted_windows"], 1);
}

#[test]
fn denied_apps_are_left_out_of_the_capture_where_the_desktop_can() {
    // A desktop that cannot leave processes out: the denied window is painted
    // out whole, whatever is in front of it.
    for reversed in [false, true] {
        let mut desktop = FakeDesktop::standard();
        if reversed {
            desktop.windows.reverse();
        }
        let e = engine(Arc::new(desktop), PolicyConfig::default());
        let shot = e.call(&ctx(None), "screenshot", &json!({}));
        assert_eq!(shot.body["redacted_windows"], 1, "reversed={reversed}");
    }
    // A desktop that can (macOS): 1Password's process (pid 20) is left out of
    // the capture itself and nothing is painted over Safari.
    let mut desktop = FakeDesktop::standard();
    desktop.excludes_apps = true;
    let desktop = Arc::new(desktop);
    let e = engine(desktop.clone(), PolicyConfig::default());
    let shot = e.call(&ctx(None), "screenshot", &json!({}));
    assert_eq!(shot.body["redacted_windows"], 0);
    assert_eq!(shot.body["left_out_apps"], 1);
    assert_eq!(*desktop.last_excluded.lock().unwrap(), vec![20]);
}

#[test]
fn a_floating_denied_app_only_the_capture_sees_is_left_out_and_a_refusal_falls_back_to_painting() {
    use crate::desktop::App;
    // A denied app with no normal window (a floating password panel): only the
    // capture system lists it, and it is still left out.
    let mut desktop = FakeDesktop::standard();
    desktop.excludes_apps = true;
    desktop.capture_only_apps.push(App {
        id: "com.bitwarden.desktop.helper".into(),
        name: "Bitwarden Helper".into(),
        pid: 77,
        frontmost: false,
        hidden: false,
    });
    let desktop = Arc::new(desktop);
    let e = engine(desktop.clone(), PolicyConfig::default());
    e.call(&ctx(None), "screenshot", &json!({}));
    let left = desktop.last_excluded.lock().unwrap().clone();
    assert!(left.contains(&20) && left.contains(&77), "{left:?}");
    // The capture refuses its list: nothing is captured unpainted.
    let mut refusing = FakeDesktop::standard();
    refusing.excludes_apps = true;
    refusing.refuse_exclusion = true;
    let e = engine(Arc::new(refusing), PolicyConfig::default());
    let shot = e.call(&ctx(None), "screenshot", &json!({}));
    assert!(!shot.is_error, "{:?}", shot.body);
    assert_eq!(shot.body["redacted_windows"], 1);
    assert_eq!(shot.body["left_out_apps"], 0);
}

#[test]
fn window_calls_never_read_every_window_when_the_capture_is_isolated() {
    let mut fake = FakeDesktop::standard();
    fake.isolated_window_capture = true;
    let d = Arc::new(fake);
    let e = engine(d.clone(), PolicyConfig::default());
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert!(!out.is_error && out.body["state"].is_object(), "{:?}", out.body);
    assert!(!e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    assert_eq!(*d.window_lists.lock().unwrap(), 0);
    // A display screenshot still reads them all, to paint out denied windows.
    assert!(!e.call(&ctx(None), "screenshot", &json!({})).is_error);
    assert!(*d.window_lists.lock().unwrap() >= 1);
}

#[test]
fn input_to_the_frontmost_app_waits_for_the_person() {
    let mut fake = FakeDesktop::standard();
    fake.apps[0].frontmost = true; // Safari is frontmost; window 1 is not marked focused.
    let d = Arc::new(fake);
    let mut parts = EngineParts::new(d.clone());
    parts.takeover = Arc::new(Busy);
    instant_time(&mut parts);
    let e = Engine::new(parts);
    // Keys posted to Safari reach its key window (a sheet the person types in, too).
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert_eq!(out.code.as_deref(), Some("person_in_control"));
    assert!(d.events().is_empty());
}

#[test]
fn pointer_input_waits_while_the_persons_pointer_is_over_the_window() {
    let d = Arc::new(FakeDesktop::standard());
    *d.pointer.lock().unwrap() = Some(Point { x: 150.0, y: 150.0 }); // inside Safari (window 1)
    let mut parts = EngineParts::new(d);
    parts.takeover = Arc::new(Busy);
    instant_time(&mut parts);
    let e = Engine::new(parts);
    let out = e.call(&ctx(None), "scroll", &json!({"window_id": "1", "dy": 3}));
    assert_eq!(out.code.as_deref(), Some("person_in_control"));
    // Keys to that background app do not meet the pointer.
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert!(!out.is_error, "{:?}", out.body);
}

#[test]
fn the_state_is_withheld_when_the_app_is_denied_during_the_wait() {
    let d = Arc::new(FakeDesktop::standard());
    let mut parts = EngineParts::new(d.clone());
    let engine: Arc<std::sync::OnceLock<std::sync::Weak<Engine>>> = Arc::default();
    let hook = engine.clone();
    parts.sleep = Arc::new(move |_| {
        // The person adds Safari to the deny list while the agent waits.
        if let Some(e) = hook.get().and_then(std::sync::Weak::upgrade) {
            let mut c = e.config();
            c.denied_apps.push("com.apple.Safari".into());
            e.set_config(c);
        }
    });
    parts.clock = Arc::new(|| Duration::ZERO);
    let e = Arc::new(Engine::new(parts));
    engine.set(Arc::downgrade(&e)).ok();
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["state"]["available"], false, "{}", out.body);
    assert!(out.png_base64.is_none());
    assert_eq!(*d.captures.lock().unwrap(), 0);
}

#[test]
fn a_replayed_action_makes_the_next_screenshot_carry_the_image() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig::default());
    let args = json!({"window_id": "1", "element_id": "e1"});
    let first = e.call(&ctx(Some("k")), "click", &args);
    assert!(first.png_base64.is_some());
    // The first reply was lost; the agent retries, then looks.
    e.call(&ctx(Some("k")), "click", &args);
    let shot = e.call(&ctx(None), "screenshot", &json!({"window_id": "1"}));
    assert_eq!(shot.body["unchanged"], false);
    assert!(shot.png_base64.is_some());
}

fn settled(mode: &str) -> (Arc<FakeDesktop>, Engine, Arc<Slept>) {
    let d = Arc::new(FakeDesktop::standard());
    let (e, slept) = settling_engine(d.clone());
    let mut config = e.config();
    config.settle = SettleMode::parse(mode).unwrap();
    e.set_config(config);
    (d, e, slept)
}

#[test]
fn anthropic_waits_two_seconds_then_always_returns_the_image() {
    let (_, e, slept) = settled("anthropic");
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert_eq!(out.body["state"]["settle"], "anthropic");
    assert_eq!(out.body["state"]["waited_ms"], 2000);
    // Unchanged pixels still come back as an image, as Anthropic's tool returns one.
    assert!(out.png_base64.is_some());
    assert_eq!(*slept.0.lock().unwrap(), vec![ANTHROPIC_SCREENSHOT_DELAY]);
}

/// Paced typing (settle=anthropic) sends every character to the element
/// asked for, never only the first (the rest would go to whatever field has
/// focus); a refusal partway says how many characters went first.
#[test]
fn paced_typing_sends_every_character_to_the_element() {
    let (d, e, _) = settled("anthropic");
    let out = e.call(
        &ctx(None),
        "type_text",
        &json!({"window_id": "1", "element_id": "e1", "text": "hello"}),
    );
    assert!(!out.is_error, "{:?}", out.body);
    let typed: Vec<_> = d
        .events()
        .into_iter()
        .filter_map(|e| match e {
            Event::Type { element, text, .. } => Some((element, text)),
            _ => None,
        })
        .collect();
    assert_eq!(typed.len(), 5);
    assert!(typed.iter().all(|(el, _)| el.is_some()), "{typed:?}");
    assert_eq!(typed.iter().map(|(_, t)| t.as_str()).collect::<String>(), "hello");
    // The gate refuses the third character: two went in, and the error says so.
    let (d, e, _) = settled("anthropic");
    *d.type_fails_at.lock().unwrap() = Some(2);
    let out = e.call(
        &ctx(None),
        "type_text",
        &json!({"window_id": "1", "element_id": "e1", "text": "hello"}),
    );
    assert!(out.is_error);
    assert_eq!(out.body["typed_before_refusal"], 2, "{:?}", out.body);
    let msg = out.body["error"].as_str().unwrap_or_default();
    assert!(msg.contains("2 of 5 characters were typed into the element"), "{msg}");
    let typed = d.events().into_iter().filter(|e| matches!(e, Event::Type { .. })).count();
    assert_eq!(typed, 2);
}

#[test]
fn anthropic_types_12_ms_per_key_and_screenshots_at_once() {
    let (d, e, slept) = settled("anthropic");
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "abcd"}));
    assert!(!out.is_error, "{:?}", out.body);
    // The 12 ms keys come before the state; the state itself does not wait.
    assert_eq!(out.body["state"]["waited_ms"], 0);
    assert_eq!(*slept.0.lock().unwrap(), vec![ANTHROPIC_TYPING_DELAY; 3]);
    let typed: Vec<_> =
        d.events().into_iter().filter(|e| matches!(e, Event::Type { .. })).collect();
    assert_eq!(typed.len(), 4);
    // 120 characters: three groups of at most 50; 12 ms between keys inside a group only.
    let (_, e, slept) = settled("anthropic");
    e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "x".repeat(120)}));
    assert_eq!(slept.0.lock().unwrap().len(), 49 + 49 + 19);
}

#[test]
fn openai_captures_at_once() {
    let (_, e, slept) = settled("openai");
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
    let out = e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "Return"}));
    assert_eq!(out.body["state"]["settle"], "openai");
    assert_eq!(out.body["state"]["waited_ms"], 0);
    assert!(out.png_base64.is_some());
    assert!(slept.0.lock().unwrap().is_empty());
}

#[test]
fn a_calls_settle_argument_wins_over_the_setting() {
    let (_, e, _) = settled("anthropic");
    let out = e.call(
        &ctx(None),
        "click",
        &json!({"window_id": "1", "element_id": "e1", "settle": "openai"}),
    );
    assert_eq!(out.body["state"]["settle"], "openai");
}

#[test]
fn wait_defaults_to_two_seconds_and_caps_at_100() {
    let (_, e, slept) = settled("adaptive");
    let out = e.call(&ctx(None), "wait", &json!({"window_id": "1"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["waited_ms"], 2000);
    assert!(out.body["state"].is_object() && out.png_base64.is_some());
    assert_eq!(slept.0.lock().unwrap()[0], WAIT_DEFAULT);
    let out = e.call(&ctx(None), "wait", &json!({"window_id": "1", "duration": 1.5}));
    assert_eq!(out.body["waited_ms"], 1500);
    let out = e.call(&ctx(None), "wait", &json!({"ms": 100001}));
    assert_eq!(out.code.as_deref(), Some("invalid_arguments"));
    // No window: a display screenshot.
    let out = e.call(&ctx(None), "wait", &json!({"ms": 0}));
    assert!(!out.is_error && out.png_base64.is_some(), "{:?}", out.body);
}

#[test]
fn batch_runs_in_order_and_returns_one_state() {
    let (d, e, _) = settled("adaptive");
    let out = e.call(
        &ctx(Some("b1")),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "click", "element_id": "e1"},
            {"action": "type_text", "text": "hi"},
            {"action": "wait", "ms": 50},
            {"action": "press_key", "keys": "Return"}
        ]}),
    );
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["completed"], 4);
    assert_eq!(out.body["stopped"], false);
    assert!(out.body["state"].is_object() && out.png_base64.is_some());
    let events = d.events();
    assert!(matches!(events[0], Event::Click { .. }));
    assert!(matches!(events[1], Event::Type { .. }));
    assert!(matches!(events[2], Event::Keys { .. }));
    // A retried batch runs nothing again.
    e.call(
        &ctx(Some("b1")),
        "batch",
        &json!({"window_id": "1", "actions": [{"action": "click", "element_id": "e1"}]}),
    );
    assert_eq!(d.events().len(), 3);
}

#[test]
fn batch_stops_at_the_first_failure_and_refuses_what_cannot_batch() {
    let (d, e, _) = settled("adaptive");
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "click", "element_id": "e1"},
            {"action": "press_key", "keys": "cmd+nonsense"},
            {"action": "type_text", "text": "never"}
        ]}),
    );
    assert_eq!(out.body["completed"], 1);
    assert_eq!(out.body["stopped"], true);
    assert_eq!(out.body["results"][1]["code"], "invalid_arguments");
    assert_eq!(out.body["results"][1]["status"], "failed");
    assert_eq!(out.body["results"][2]["status"], "not_run");
    assert_eq!(out.body["stopped_at"]["step"], 1);
    assert_eq!(d.events().len(), 1);
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "1", "actions": [{"action": "launch_app", "app_id": "x"}]}),
    );
    assert_eq!(out.body["completed"], 0);
    let too_many: Vec<Value> = (0..21).map(|_| json!({"action": "wait", "ms": 0})).collect();
    let out = e.call(&ctx(None), "batch", &json!({"window_id": "1", "actions": too_many}));
    assert_eq!(out.code.as_deref(), Some("invalid_arguments"));
}

#[test]
fn a_batch_on_a_denied_app_is_refused_like_a_single_call() {
    let (d, e, _) = settled("adaptive");
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "2", "actions": [{"action": "click", "x": 1, "y": 1}]}),
    );
    assert_eq!(out.body["results"][0]["code"], "app_denied");
    assert!(d.events().is_empty());
}

#[test]
fn the_cursor_shows_a_refusal_and_a_wait_for_the_person() {
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    let mut parts = EngineParts::new(Arc::new(FakeDesktop::standard()));
    instant_time(&mut parts);
    parts.cursor = rec.clone();
    let e = Engine::new(parts);
    // A denied app: refused, and the cursor says why.
    e.call(&ctx(None), "screenshot", &json!({"window_id": "2"}));
    e.call(&ctx(None), "click", &json!({"window_id": "2", "x": 1, "y": 1}));
    assert!(rec.0.lock().unwrap().iter().any(
        |e| matches!(e, CursorEvent::Refused { reason, .. } if reason == "App is on the deny list")
    ));
    // A bad argument is an ordinary error, not a refusal.
    rec.0.lock().unwrap().clear();
    e.call(&ctx(None), "press_key", &json!({"window_id": "1", "keys": "cmd+nonsense"}));
    assert!(!rec.0.lock().unwrap().iter().any(|e| matches!(e, CursorEvent::Refused { .. })));

    // The person keeps typing in the frontmost app: Paused first, then refused.
    let mut fake = FakeDesktop::standard();
    fake.apps[0].frontmost = true;
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    let mut parts = EngineParts::new(Arc::new(fake));
    instant_time(&mut parts);
    parts.cursor = rec.clone();
    parts.takeover = Arc::new(Busy);
    let e = Engine::new(parts);
    e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    let ev = rec.0.lock().unwrap();
    let paused = ev.iter().position(|e| matches!(e, CursorEvent::Paused { .. })).expect("paused");
    let refused = ev
        .iter()
        .position(
            |e| matches!(e, CursorEvent::Refused { reason, .. } if reason == "You're in control"),
        )
        .expect("refused");
    assert!(paused < refused);
    assert!(!ev.iter().any(|e| matches!(e, CursorEvent::Typing { .. })), "{ev:?}");
    let v = serde_json::to_value(&ev[refused]).unwrap();
    assert_eq!(
        (v["kind"].as_str(), v["reason"].as_str()),
        (Some("refused"), Some("You're in control"))
    );
}

#[test]
fn a_batch_step_that_fails_says_why() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig::default());
    let out = e.call(
        &ctx(None),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "press_key", "keys": "cmd+nonsense"}
        ]}),
    );
    let result = &out.body["results"][0];
    assert_eq!(result["status"], "failed", "{:?}", out.body);
    let message = result["message"].as_str().unwrap_or_default();
    assert!(
        message.contains("nonsense"),
        "the step's error text reaches the agent: {:?}",
        out.body
    );
}

#[test]
fn the_menu_guard_follows_the_deny_list_as_settings_change() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() });
    let guard = d.menu_guard.lock().unwrap().clone().expect("the engine sets a menu guard");
    assert!(!guard.denies_any());
    assert!(!guard.app_blocked("com.apple.Terminal", "Terminal"));
    e.set_config(PolicyConfig {
        denied_apps: vec!["com.apple.Terminal".into()],
        ..PolicyConfig::default()
    });
    assert!(guard.denies_any());
    assert!(guard.app_blocked("com.apple.Terminal", "Terminal"));
    assert!(!guard.app_blocked("com.apple.TextEdit", "TextEdit"));
    // Emptying the list again unblocks it at once.
    e.set_config(PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() });
    assert!(!guard.app_blocked("com.apple.Terminal", "Terminal"));
}

#[test]
fn a_name_for_several_apps_is_refused_before_anyone_is_asked() {
    // A desktop whose launch_app takes an identity (macOS: a bundle id) and
    // whose name resolves to two apps: refused with no approval and nothing
    // launched.
    let desktop = Arc::new(FakeDesktop::standard());
    *desktop.launch_names.lock().unwrap() =
        Some(vec!["com.example.One".into(), "com.example.Two".into()]);
    let e = engine(desktop.clone(), PolicyConfig::default());
    let out = e.call(&ctx(None), "launch_app", &json!({"app_id": "Twin"}));
    assert!(out.is_error, "{:?}", out.body);
    assert!(out.body["error"].as_str().unwrap().contains("names several apps"), "{:?}", out.body);
    assert!(!desktop.events().iter().any(|e| matches!(e, Event::Launch(_))));
}

#[test]
fn request_permission_obeys_the_mode_and_never_comes_from_another_machine() {
    let args = json!({"permission": "accessibility"});
    let off = engine(
        Arc::new(FakeDesktop::standard()),
        PolicyConfig { mode: Mode::Off, ..PolicyConfig::default() },
    );
    assert_eq!(
        off.call(&ctx(None), "request_permission", &args).code.as_deref(),
        Some("computer_use_off")
    );
    // Only the person at this machine can grant its OS permissions: an agent on
    // another of their machines never raises the prompt here.
    let on = engine(Arc::new(FakeDesktop::standard()), PolicyConfig::default());
    let mut remote = ctx(None);
    remote.origin = OriginKind::Remote { machine: "m".into(), same_account: true };
    assert_eq!(
        on.call(&remote, "request_permission", &args).code.as_deref(),
        Some("remote_not_allowed")
    );
}
