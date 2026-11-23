//! `batch` through the engine and the fake desktop: the per-step list, every
//! `require` guard, each reason a batch stops, `wait_for` and `target`
//! references (resolved, ambiguous, stale, not found).

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::desktop::Signals;
use crate::desktop::fake::{Event, FakeDesktop};
use crate::stop::{STOPPED_CODE, Stops};

fn ctx() -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: None,
        origin: OriginKind::Local,
        tag: None,
    }
}

/// An engine whose time moves only when it sleeps; `on_sleep` sees every
/// sleep (with the stops, to stop the session from inside a call).
fn rig_with(
    d: Arc<FakeDesktop>,
    on_sleep: impl Fn(Duration, &Stops) + Send + Sync + 'static,
) -> (Engine, Arc<Mutex<Vec<Duration>>>) {
    let mut parts = EngineParts::new(d);
    let now = Arc::new(AtomicU64::new(0));
    let slept = Arc::new(Mutex::new(Vec::new()));
    let (a, b, rec, stops) = (now.clone(), now, slept.clone(), parts.stops.clone());
    parts.sleep = Arc::new(move |t| {
        on_sleep(t, &stops);
        rec.lock().unwrap().push(t);
        a.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    parts.config.settle = SettleMode::Adaptive;
    (Engine::new(parts), slept)
}

fn rig(d: Arc<FakeDesktop>) -> Engine {
    rig_with(d, |_, _| {}).0
}

fn el(id: &str, role: &str, name: &str) -> Element {
    Element { id: id.into(), role: role.into(), name: name.into(), ..Element::default() }
}

fn framed(mut e: Element, x: f64, y: f64) -> Element {
    e.frame = Some(Rect { x, y, width: 80.0, height: 22.0 });
    e.actions = vec!["press".into()];
    e
}

/// Gives every element an identity from its place in the tree.
fn identify(e: &mut Element, seed: u64) {
    e.identity = Some(seed);
    for (i, c) in e.children.iter_mut().enumerate() {
        identify(c, seed * 31 + i as u64 + 1);
    }
}

/// TextEdit-like window 1: a document and a Save… button; with `sheet`, a
/// Save sheet with a name field (`name` its value) and a Save button.
fn doc(sheet: bool, name: &str, save_label: &str) -> Element {
    let mut text = framed(el("t", "text_area", "Document"), 120.0, 160.0);
    text.value = "hello".into();
    let open = framed(el("o", "button", "Save…"), 120.0, 400.0);
    let mut children = vec![text, open];
    if sheet {
        let mut field = framed(el("f", "text_field", "Save As"), 300.0, 200.0);
        field.value = name.into();
        let save = framed(el("s", "button", save_label), 300.0, 260.0);
        let cancel = framed(el("c", "button", "Cancel"), 400.0, 260.0);
        children.push(Element {
            children: vec![field, save, cancel],
            ..framed(el("sh", "sheet", "Save"), 250.0, 150.0)
        });
    }
    let mut root = Element {
        children,
        ..Element {
            frame: Some(Rect { x: 100.0, y: 100.0, width: 800.0, height: 600.0 }),
            ..el("w", "window", "Untitled")
        }
    };
    identify(&mut root, 1);
    root
}

fn desktop_with(tree: Element) -> Arc<FakeDesktop> {
    let d = Arc::new(FakeDesktop::standard());
    *d.tree.lock().unwrap() = Some(tree);
    d
}

fn batch(e: &Engine, actions: Value) -> ToolOutput {
    e.call(&ctx(), "batch", &json!({"window_id": "1", "actions": actions}))
}

fn step(out: &ToolOutput, i: usize) -> &Value {
    &out.body["results"][i]
}

fn walks(d: &FakeDesktop) -> u32 {
    *d.walks.lock().unwrap()
}

/// The reply lists every step with its own outcome, reason, read-back and
/// what changed during it; the model never has to guess which step did what.
#[test]
fn every_step_reports_its_own_outcome_and_changes() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    assert!(!e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    // The second step's effect: the document's text changes.
    let mut typed = doc(false, "", "Save");
    typed.children[0].value = "hello world".into();
    let after_first = walks(&d) + 2;
    d.trees_from_walk.lock().unwrap().push((after_first, typed));
    let out = batch(
        &e,
        json!([
            {"action": "set_value", "element_id": "t", "value": "hello"},
            {"action": "type_text", "element_id": "t", "text": " world"},
            {"action": "press_key", "keys": "cmd+s"}
        ]),
    );
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(out.body["completed"], 3);
    assert_eq!(out.body["of"], 3);
    assert_eq!(out.body["stopped"], false);
    assert!(out.body.get("stopped_at").is_none());
    for i in 0..3 {
        let s = step(&out, i);
        assert_eq!(s["step"], i, "{}", out.body);
        assert_eq!(s["status"], "done", "{}", out.body);
        assert!(s["outcome"].is_string() && s["outcome_reason"].is_string(), "{}", out.body);
        assert!(s["changes"].is_string(), "{}", out.body);
        assert!(s.get("state").is_none() && s.get("expect").is_none(), "{}", out.body);
    }
    assert_eq!(step(&out, 0)["action"], "set_value");
    assert_eq!(step(&out, 0)["outcome"], "confirmed", "{}", out.body);
    assert_eq!(step(&out, 0)["read_back"], "value", "{}", out.body);
    assert_eq!(
        step(&out, 0)["changes"],
        "no change in the window's elements\n(its pixels were not compared)"
    );
    // Only the step that changed the text shows the change.
    let second = step(&out, 1)["changes"].as_str().unwrap();
    assert!(second.contains("hello world"), "{second}");
    assert!(!step(&out, 2)["changes"].as_str().unwrap().contains("hello world"), "{}", out.body);
    // One state for the whole batch, at its end.
    assert!(out.body["state"].is_object(), "{}", out.body);
    assert_eq!(d.events().len(), 3);
}

#[test]
fn require_confirmed_lets_a_confirmed_step_through() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d);
    let out = batch(
        &e,
        json!([
            {"action": "set_value", "element_id": "t", "value": "x", "require": "confirmed"},
            {"action": "press_key", "keys": "Return"}
        ]),
    );
    assert_eq!(step(&out, 0)["require"], "confirmed", "{}", out.body);
    assert_eq!(step(&out, 0)["require_met"], true, "{}", out.body);
    assert_eq!(step(&out, 1)["status"], "done", "{}", out.body);
    assert_eq!(out.body["stopped"], false);
}

/// A step that only delivered (uncertain) stops a `require: confirmed`
/// batch; the steps after it report not run, never success.
#[test]
fn require_confirmed_stops_at_an_uncertain_step() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let out = batch(
        &e,
        json!([
            {"action": "click", "element_id": "o", "require": "confirmed"},
            {"action": "type_text", "text": "never"},
            {"action": "press_key", "keys": "Return"}
        ]),
    );
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(step(&out, 0)["status"], "done", "it acted: {}", out.body);
    assert_eq!(step(&out, 0)["outcome"], "uncertain", "{}", out.body);
    assert_eq!(step(&out, 0)["require_met"], false, "{}", out.body);
    let at = &out.body["stopped_at"];
    assert_eq!(at["step"], 0);
    assert_eq!(at["code"], "requirement_not_met");
    let reason = at["reason"].as_str().unwrap();
    assert!(reason.contains("required confirmed") && reason.contains("uncertain"), "{reason}");
    for i in 1..3 {
        assert_eq!(step(&out, i)["status"], "not_run", "{}", out.body);
        assert!(step(&out, i).get("outcome").is_none(), "{}", out.body);
    }
    assert_eq!(out.body["completed"], 1);
    assert_eq!(out.body["stopped"], true);
    assert_eq!(d.events().len(), 1, "nothing after the stop ran");
}

/// A desktop and engine where a delivered click that changes nothing is
/// `no_effect` (the agent has a look and a screenshot to compare with).
fn no_effect_rig() -> (Arc<FakeDesktop>, Engine) {
    let d = Arc::new(FakeDesktop::standard());
    *d.shows.lock().unwrap() = Some("text".into());
    *d.signals.lock().unwrap() = Some(Signals::default());
    *d.reads_back.lock().unwrap() = Some(false);
    let e = rig(d.clone());
    assert!(!e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    assert!(!e.call(&ctx(), "screenshot", &json!({"window_id": "1"})).is_error);
    (d, e)
}

#[test]
fn require_not_no_effect_stops_at_a_step_that_did_nothing() {
    let (d, e) = no_effect_rig();
    let out = batch(
        &e,
        json!([
            {"action": "click", "x": 10, "y": 100, "require": "not_no_effect"},
            {"action": "press_key", "keys": "Return"}
        ]),
    );
    assert_eq!(step(&out, 0)["outcome"], "no_effect", "{}", out.body);
    assert_eq!(step(&out, 0)["require_met"], false, "{}", out.body);
    assert_eq!(out.body["stopped_at"]["code"], "requirement_not_met");
    assert!(
        out.body["stopped_at"]["reason"].as_str().unwrap().contains("not_no_effect"),
        "{}",
        out.body
    );
    assert_eq!(step(&out, 1)["status"], "not_run");
    assert_eq!(d.events().len(), 1);
}

/// The default guard stops only on an error: a no_effect or uncertain step
/// goes on (and says so in its own entry).
#[test]
fn by_default_only_an_error_stops_the_batch() {
    let (d, e) = no_effect_rig();
    let out = batch(
        &e,
        json!([
            {"action": "click", "x": 10, "y": 100},
            {"action": "press_key", "keys": "cmd+nonsense"},
            {"action": "press_key", "keys": "Return"}
        ]),
    );
    assert_eq!(step(&out, 0)["outcome"], "no_effect", "{}", out.body);
    assert!(step(&out, 0).get("require").is_none());
    assert_eq!(step(&out, 1)["status"], "failed", "{}", out.body);
    assert_eq!(step(&out, 1)["code"], "invalid_arguments");
    assert_eq!(out.body["stopped_at"]["step"], 1);
    assert_eq!(out.body["stopped_at"]["code"], "invalid_arguments");
    assert_eq!(step(&out, 2)["status"], "not_run");
    assert_eq!(d.events().len(), 1);
}

/// `require: not_no_effect` lets an uncertain step through.
#[test]
fn require_not_no_effect_lets_an_uncertain_step_through() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d);
    let out = batch(
        &e,
        json!([
            {"action": "click", "element_id": "o", "require": "not_no_effect"},
            {"action": "press_key", "keys": "Return"}
        ]),
    );
    assert_eq!(step(&out, 0)["outcome"], "uncertain", "{}", out.body);
    assert_eq!(step(&out, 0)["require_met"], true, "{}", out.body);
    assert_eq!(step(&out, 1)["status"], "done");
}

/// perform_action names its accessibility action as `perform` in a batch.
#[test]
fn a_perform_action_step_takes_perform() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let out =
        batch(&e, json!([{"action": "perform_action", "element_id": "o", "perform": "press"}]));
    assert_eq!(step(&out, 0)["status"], "done", "{}", out.body);
    assert!(
        matches!(&d.events()[0], Event::Action { element, action, .. } if element == "o" && action == "press"),
        "{:?}",
        d.events()
    );
    let out = batch(&e, json!([{"action": "perform_action", "element_id": "o"}]));
    assert!(step(&out, 0)["message"].as_str().unwrap().contains("\"perform\""), "{}", out.body);
}

/// Open a sheet, wait for it, fill it by role and label, require confirmed:
/// the flow a batch is for.
#[test]
fn wait_for_a_sheet_then_fill_it_by_role_and_label() {
    let d = desktop_with(doc(false, "", "Save"));
    let (e, slept) = rig_with(d.clone(), |_, _| {});
    // The sheet shows a few reads after the click (an animation).
    let later = walks(&d) + 6;
    d.trees_from_walk.lock().unwrap().push((later, doc(true, "", "Save")));
    let out = batch(
        &e,
        json!([
            {"action": "click", "element_id": "o"},
            {"action": "wait_for", "target": {"role": "sheet"}, "timeout_ms": 5000},
            {"action": "set_value", "target": {"role": "text_field", "label": "save as"}, "value": "notes", "require": "confirmed"},
            {"action": "click", "target": {"role": "button", "label": "Save"}}
        ]),
    );
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(out.body["completed"], 4, "{}", out.body);
    let waited = step(&out, 1);
    assert!(waited["met"].as_str().unwrap().starts_with("appeared: ["), "{}", out.body);
    assert!(waited["met"].as_str().unwrap().contains("sheet \"Save\""), "{}", out.body);
    assert!(waited["reads"].as_u64().unwrap() >= 2, "{}", out.body);
    assert_eq!(waited["watched"], false);
    assert!(waited["changes"].as_str().unwrap().contains("+ "), "{}", out.body);
    // Unwatched, the wait reads again every 150 ms (no fixed sleep for the whole wait).
    assert!(slept.lock().unwrap().contains(&Duration::from_millis(150)));
    let fill = step(&out, 2);
    assert_eq!(
        fill["target"]["matched"].as_str().unwrap().split("] ").nth(1),
        Some("text_field \"Save As\"")
    );
    assert_eq!(fill["outcome"], "confirmed", "{}", out.body);
    assert_eq!(fill["require_met"], true);
    // Only the sheet's Save button: the window's "Save…" does not match the label.
    assert!(step(&out, 3)["target"]["matched"].as_str().unwrap().ends_with("button \"Save\""));
    let events = d.events();
    assert!(
        matches!(&events[1], Event::SetValue { element, value, .. } if element == "f" && value == "notes"),
        "{events:?}"
    );
    assert!(
        matches!(&events[2], Event::Click { element: Some(el), .. } if el == "s"),
        "{events:?}"
    );
}

/// With the app's accessibility watch listening, a wait_for reads again on
/// each signal (and every 500 ms as a backstop).
#[test]
fn a_watched_wait_for_rechecks_less_often() {
    let d = desktop_with(doc(false, "", "Save"));
    *d.signals.lock().unwrap() = Some(Signals::default());
    let (e, slept) = rig_with(d.clone(), |_, _| {});
    // The agent has looked at the window: a window's first read walks a
    // small tree twice (a web view filled on first read), so the reads
    // counted below are one walk each.
    assert!(!e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    slept.lock().unwrap().clear();
    let later = walks(&d) + 2;
    d.trees_from_walk.lock().unwrap().push((later, doc(true, "", "Save")));
    let out = batch(&e, json!([{"action": "wait_for", "target": {"role": "sheet"}}]));
    assert_eq!(step(&out, 0)["watched"], true, "{}", out.body);
    assert_eq!(step(&out, 0)["reads"], 2, "{}", out.body);
    // The one sleep before the batch's own state: a recheck of 500 ms.
    assert_eq!(slept.lock().unwrap()[0], Duration::from_millis(500));
}

#[test]
fn a_wait_for_that_times_out_stops_the_batch() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let out = batch(
        &e,
        json!([
            {"action": "wait_for", "target": {"role": "sheet"}, "timeout_ms": 1000},
            {"action": "click", "target": {"role": "button", "label": "Save"}}
        ]),
    );
    assert!(!out.is_error, "{}", out.body);
    let s = step(&out, 0);
    assert_eq!(s["status"], "failed");
    assert_eq!(s["code"], "wait_timeout");
    let message = s["message"].as_str().unwrap();
    assert!(message.contains("waited 1050 ms") || message.contains("waited 1000 ms"), "{message}");
    assert!(message.contains("an element with role \"sheet\" to appear"), "{message}");
    assert!(message.contains("no element matched"), "{message}");
    assert_eq!(out.body["stopped_at"]["code"], "wait_timeout");
    assert_eq!(step(&out, 1)["status"], "not_run");
    assert!(d.events().is_empty());
}

#[test]
fn wait_for_disappears_and_values() {
    // The sheet closes three reads in.
    let d = desktop_with(doc(true, "", "Save"));
    let e = rig(d.clone());
    // Looked at first, so each read below is one walk (see above).
    assert!(!e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"})).is_error);
    let later = walks(&d) + 3;
    d.trees_from_walk.lock().unwrap().push((later, doc(false, "", "Save")));
    let out = batch(
        &e,
        json!([{"action": "wait_for", "target": {"role": "sheet"}, "until": "disappears"}]),
    );
    assert_eq!(step(&out, 0)["status"], "done", "{}", out.body);
    assert_eq!(step(&out, 0)["met"], "gone: no element matches role \"sheet\"");
    assert_eq!(step(&out, 0)["reads"], 3);

    // A value that fills in: equals and contains.
    let d = desktop_with(doc(true, "", "Save"));
    let e = rig(d.clone());
    let later = walks(&d) + 2;
    d.trees_from_walk.lock().unwrap().push((later, doc(true, "notes.txt", "Save")));
    let out = batch(
        &e,
        json!([
            {"action": "wait_for", "target": {"role": "text_field"}, "value_contains": "notes"},
            {"action": "wait_for", "target": {"role": "text_field"}, "value_equals": "notes.txt"}
        ]),
    );
    assert_eq!(out.body["completed"], 2, "{}", out.body);
    assert!(step(&out, 0)["met"].as_str().unwrap().ends_with("= \"notes.txt\""), "{}", out.body);

    // A value that never comes: the timeout says what it is now.
    let out = batch(
        &e,
        json!([{"action": "wait_for", "target": {"role": "text_field"}, "value_equals": "other", "timeout_ms": 300}]),
    );
    assert_eq!(step(&out, 0)["code"], "wait_timeout", "{}", out.body);
    assert!(
        step(&out, 0)["message"].as_str().unwrap().contains("value is \"notes.txt\""),
        "{}",
        out.body
    );
}

/// A value read cut short says so when the wait times out: text past the cut
/// can never match.
#[test]
fn a_wait_on_a_clipped_value_says_it_is_clipped() {
    let mut tree = doc(false, "", "Save");
    tree.children[0].value = format!("{}…", "x".repeat(2000));
    let d = desktop_with(tree);
    let e = rig(d);
    let out = batch(
        &e,
        json!([{"action": "wait_for", "target": {"role": "text_area"}, "value_contains": "line 120", "timeout_ms": 300}]),
    );
    let message = step(&out, 0)["message"].as_str().unwrap();
    assert!(message.contains("read cut short"), "{message}");
}

/// A met value condition shows the value short, not a whole document.
#[test]
fn a_met_value_is_shown_short() {
    let mut tree = doc(false, "", "Save");
    tree.children[0].value = format!("start {}", "x".repeat(3000));
    let e = rig(desktop_with(tree));
    let out = batch(
        &e,
        json!([{"action": "wait_for", "target": {"role": "text_area"}, "value_contains": "start"}]),
    );
    let met = step(&out, 0)["met"].as_str().unwrap();
    assert!(met.chars().count() < 200, "{met}");
}

/// wait_for an element id: gone when the element is; an id the window never
/// had is refused at once.
#[test]
fn wait_for_an_element_id() {
    let d = desktop_with(doc(true, "", "Save"));
    let e = rig(d.clone());
    let tree = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "format": "json"}));
    let root: Element = serde_json::from_value(tree.body["root"].clone()).unwrap();
    fn id_of(e: &Element, role: &str) -> Option<String> {
        if e.role == role {
            return Some(e.id.clone());
        }
        e.children.iter().find_map(|c| id_of(c, role))
    }
    let sheet = id_of(&root, "sheet").expect("the sheet has an id");
    let later = walks(&d) + 2;
    d.trees_from_walk.lock().unwrap().push((later, doc(false, "", "Save")));
    let out =
        batch(&e, json!([{"action": "wait_for", "element_id": sheet, "until": "disappears"}]));
    assert_eq!(
        step(&out, 0)["met"],
        format!("gone: element [{sheet}] is no longer in the window"),
        "{}",
        out.body
    );

    let out = batch(&e, json!([{"action": "wait_for", "element_id": "999"}]));
    assert_eq!(step(&out, 0)["code"], "stale_element", "{}", out.body);
}

/// Two elements match: refused as ambiguous, never one picked, and nothing
/// acts.
#[test]
fn an_ambiguous_target_is_refused() {
    let d = desktop_with(doc(true, "", "Save"));
    let e = rig(d.clone());
    let out = batch(&e, json!([{"action": "click", "target": {"role": "button", "text": "save"}}]));
    let s = step(&out, 0);
    assert_eq!(s["status"], "failed", "{}", out.body);
    assert_eq!(s["code"], "ambiguous_element");
    let message = s["message"].as_str().unwrap();
    assert!(message.starts_with("2 elements of window 1 match"), "{message}");
    assert!(
        message.contains("button \"Save…\"") && message.contains("button \"Save\""),
        "{message}"
    );
    assert_eq!(out.body["stopped_at"]["code"], "ambiguous_element");
    assert!(d.events().is_empty());
    // A wait_for on an ambiguous match is refused too.
    let out =
        batch(&e, json!([{"action": "wait_for", "target": {"role": "button", "text": "save"}}]));
    assert_eq!(step(&out, 0)["code"], "ambiguous_element", "{}", out.body);
}

/// The element a target resolved to is replaced before the action reaches
/// it: the same use-time check as an id refuses it as stale.
#[test]
fn a_target_replaced_before_use_is_stale() {
    let d = desktop_with(doc(true, "", "Save"));
    let e = rig(d.clone());
    // The resolve read is the next walk; the click's own read the one after,
    // where the same element now reads "Delete".
    let later = walks(&d) + 2;
    d.trees_from_walk.lock().unwrap().push((later, doc(true, "", "Delete")));
    let out =
        batch(&e, json!([{"action": "click", "target": {"role": "button", "label": "Save"}}]));
    assert_eq!(step(&out, 0)["code"], "stale_element", "{}", out.body);
    assert!(d.events().is_empty(), "{:?}", d.events());
}

#[test]
fn a_target_that_matches_nothing_is_not_found() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let out =
        batch(&e, json!([{"action": "click", "target": {"role": "button", "label": "Nope"}}]));
    assert_eq!(step(&out, 0)["code"], "target_not_found", "{}", out.body);
    assert!(d.events().is_empty());
}

/// A target is read only where the agent may look: a denied app's window is
/// refused before its tree is read.
#[test]
fn a_target_in_a_denied_app_is_refused_before_reading() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let before = walks(&d);
    let out = e.call(
        &ctx(),
        "batch",
        &json!({"window_id": "2", "actions": [{"action": "click", "target": {"role": "button"}}]}),
    );
    assert_eq!(step(&out, 0)["code"], "app_denied", "{}", out.body);
    assert_eq!(walks(&d), before);
}

/// Every step is checked before any runs: a malformed step anywhere means
/// nothing ran.
#[test]
fn a_malformed_step_runs_nothing() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    for (bad, words) in [
        (json!({"action": "click", "element_id": "o", "require": "maybe"}), "require \"maybe\""),
        (
            json!({"action": "press_key", "keys": "a", "target": {"role": "button"}}),
            "takes no target",
        ),
        (json!({"action": "click", "element_id": "o", "target": {"role": "button"}}), "not both"),
        (json!({"action": "click", "target": {"colour": "red"}}), "not \"colour\""),
        (
            json!({"action": "wait_for", "target": {"role": "sheet"}, "timeout": 5}),
            "not \"timeout\"",
        ),
        (json!({"action": "wait_for", "until": "appears"}), "needs element_id or target"),
        (
            json!({"action": "wait_for", "target": {"role": "x"}, "timeout_ms": 100001}),
            "timeout_ms",
        ),
        (
            json!({"action": "wait_for", "target": {"role": "x"}, "require": "confirmed"}),
            "require is for acting steps",
        ),
        (json!({"action": "launch_app", "app_id": "x"}), "cannot run in a batch"),
    ] {
        let out = batch(&e, json!([{"action": "press_key", "keys": "Return"}, bad]));
        assert_eq!(out.body["completed"], 0, "{bad}: {}", out.body);
        assert_eq!(step(&out, 0)["status"], "not_run", "{bad}: {}", out.body);
        assert_eq!(step(&out, 1)["status"], "failed", "{bad}: {}", out.body);
        assert_eq!(out.body["stopped_at"]["step"], 1);
        let message = step(&out, 1)["message"].as_str().unwrap();
        assert!(
            message.contains(words) && message.contains("Nothing in this batch ran"),
            "{bad}: {message}"
        );
    }
    assert!(d.events().is_empty());
}

/// The batch's waits together are bounded, and no step starts past the
/// bound.
#[test]
fn a_batch_is_bounded_in_time() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    let out = batch(
        &e,
        json!([
            {"action": "wait", "ms": 100000},
            {"action": "wait_for", "target": {"role": "sheet"}, "timeout_ms": 30000}
        ]),
    );
    assert_eq!(out.code.as_deref(), Some("invalid_arguments"), "{}", out.body);
    assert!(out.body["error"].as_str().unwrap().contains("130 s"), "{}", out.body);

    let out = batch(
        &e,
        json!([
            {"action": "wait", "ms": 100000},
            {"action": "wait", "ms": 20000},
            {"action": "click", "element_id": "o"}
        ]),
    );
    assert_eq!(out.body["stopped_at"]["code"], "batch_time_limit", "{}", out.body);
    assert_eq!(out.body["stopped_at"]["step"], 2);
    assert_eq!(step(&out, 2)["status"], "not_run");
    assert!(d.events().is_empty());
}

/// The person's Stop during a wait_for ends it at its next read; the reply
/// still lists every step.
#[test]
fn a_stop_during_wait_for_ends_the_batch() {
    let d = desktop_with(doc(false, "", "Save"));
    let (e, _) = rig_with(d.clone(), |t, stops| {
        if t == Duration::from_millis(150) {
            stops.stop("s1");
        }
    });
    let out = batch(
        &e,
        json!([
            {"action": "wait_for", "target": {"role": "sheet"}},
            {"action": "click", "element_id": "o"}
        ]),
    );
    assert_eq!(out.code.as_deref(), Some(STOPPED_CODE), "{}", out.body);
    assert_eq!(out.body["stopped_at"]["code"], STOPPED_CODE, "{}", out.body);
    assert_eq!(out.body["results"][1]["status"], "not_run", "{}", out.body);
    assert!(d.events().is_empty());
}

/// The batch's state compares with what the agent saw before the batch, not
/// with a step's capture it never saw.
#[test]
fn the_batch_state_compares_with_the_agents_last_screenshot() {
    let d = desktop_with(doc(false, "", "Save"));
    let e = rig(d.clone());
    assert!(!e.call(&ctx(), "screenshot", &json!({"window_id": "1"})).is_error);
    // The app redraws after the first step's capture.
    *d.repaint_from.lock().unwrap() = Some((3, 9));
    let out = batch(
        &e,
        json!([{"action": "click", "element_id": "o"}, {"action": "press_key", "keys": "Return"}]),
    );
    assert_eq!(out.body["state"]["unchanged"], false, "{}", out.body);
    assert!(out.png_base64.is_some());
}
