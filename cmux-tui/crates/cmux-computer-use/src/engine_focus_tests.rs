//! The focus guard through the fake desktop.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use super::*;
use crate::desktop::FocusSnapshot;
use crate::desktop::fake::{Event, FakeDesktop};

/// The person's input as a counter (a detector that watches, when `.1`).
/// With `.2` set, the person acts once right after the first reading.
struct Counter(AtomicU64, bool, AtomicBool);
impl PersonActivity for Counter {
    fn wait_idle(&self, _limit: Duration) -> bool {
        true
    }
    fn input_count(&self) -> Option<u64> {
        let n = self.0.load(Ordering::SeqCst);
        if self.2.swap(false, Ordering::SeqCst) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
        self.1.then_some(n)
    }
}

/// The person types into their own app (TextEdit, pid 30) with window 30.
fn person() -> FocusSnapshot {
    FocusSnapshot {
        pid: 30,
        app_id: "com.apple.TextEdit".into(),
        window_id: Some("30".into()),
        top_pid: Some(30),
        pointer: None,
    }
}

/// Safari (pid 10, window 1) took the front.
fn safari_front() -> FocusSnapshot {
    FocusSnapshot {
        pid: 10,
        app_id: "com.apple.Safari".into(),
        window_id: Some("1".into()),
        top_pid: Some(10),
        pointer: None,
    }
}

fn ctx(call: &str) -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: Some(call.into()),
        origin: OriginKind::Local,
    }
}

struct Rig {
    desktop: Arc<FakeDesktop>,
    person: Arc<Counter>,
    engine: Engine,
    audit: PathBuf,
}

fn rig_with(desktop: FakeDesktop, watched: bool) -> Rig {
    let desktop = Arc::new(desktop);
    *desktop.focus.lock().unwrap() = Some(person());
    let counter = Arc::new(Counter(AtomicU64::new(0), watched, AtomicBool::new(false)));
    let mut parts = EngineParts::new(desktop.clone());
    let a = Arc::new(AtomicU64::new(0));
    let b = a.clone();
    parts.sleep = Arc::new(move |d| {
        a.fetch_add(d.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    parts.takeover = counter.clone();
    let dir = std::env::temp_dir().join(format!(
        "cmux-cu-focus-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    parts.state_dir = Some(dir.clone());
    Rig { desktop, person: counter, engine: Engine::new(parts), audit: dir.join("audit.jsonl") }
}

static NEXT: AtomicU64 = AtomicU64::new(0);

fn rig() -> Rig {
    rig_with(FakeDesktop::standard(), true)
}

fn click(r: &Rig, call: &str) -> ToolOutput {
    r.engine.call(&ctx(call), "click", &json!({"window_id": "1", "element_id": "e1"}))
}

#[test]
fn focus_that_stays_is_reported_kept() {
    let r = rig();
    let out = click(&r, "c1");
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["focus"], json!({"kept": true}));
    assert!(r.desktop.restores().is_empty());
}

#[test]
fn a_target_that_activates_itself_is_put_back() {
    let r = rig();
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = click(&r, "c1");
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["focus"], json!({"kept": true, "restored_from": "com.apple.Safari"}));
    assert_eq!(r.desktop.restores(), vec![person()]);
    assert_eq!(r.desktop.focus.lock().unwrap().clone(), Some(person()));
    let audit = std::fs::read_to_string(&r.audit).unwrap();
    let line: Value = serde_json::from_str(audit.lines().last().unwrap()).unwrap();
    assert_eq!(line["focus"]["restored_from"], "com.apple.Safari");
}

#[test]
fn a_late_activation_is_caught_after_the_settle_wait() {
    let r = rig();
    // Readings: 1 before acting, 2 right after; the app activates by the 3rd
    // (after the settle wait).
    *r.desktop.steal_on_read.lock().unwrap() = Some((3, safari_front()));
    let out = click(&r, "c1");
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari");
    assert_eq!(r.desktop.restores().len(), 1);
}

#[test]
fn focus_the_person_moved_is_never_put_back() {
    let r = rig();
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    // The person clicks Safari's Dock icon while the call runs: their input
    // count moves between the guard's two readings.
    r.person.2.store(true, Ordering::SeqCst);
    let out = click(&r, "c1");
    assert_eq!(
        out.body["focus"],
        json!({"kept": false, "moved_by": "person", "moved_to": "com.apple.Safari"})
    );
    assert!(r.desktop.restores().is_empty(), "never restores over the person");
}

#[test]
fn unwatched_and_unrelated_focus_changes_are_reported_not_restored() {
    // No detector: a change to an app the call did not touch may be the person's.
    let r = rig_with(FakeDesktop::standard(), false);
    let mail = FocusSnapshot {
        pid: 40,
        app_id: "com.apple.mail".into(),
        window_id: Some("40".into()),
        top_pid: Some(40),
        pointer: None,
    };
    *r.desktop.steal_on_input.lock().unwrap() = Some(mail);
    let out = click(&r, "c1");
    assert_eq!(out.body["focus"]["kept"], false);
    assert_eq!(out.body["focus"]["moved_to"], "com.apple.mail");
    assert!(r.desktop.restores().is_empty());

    // Unwatched, but the target itself took focus: that is the call's doing.
    let r = rig_with(FakeDesktop::standard(), false);
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = click(&r, "c2");
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari");
}

#[test]
fn a_window_raised_over_the_persons_without_activation_is_put_back() {
    let r = rig();
    *r.desktop.steal_on_input.lock().unwrap() =
        Some(FocusSnapshot { top_pid: Some(10), ..person() });
    let out = click(&r, "c1");
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari");
}

#[test]
fn a_launched_app_that_activates_late_is_put_back() {
    let r = rig();
    let launched = FocusSnapshot {
        pid: 99,
        app_id: "com.example.App".into(),
        window_id: Some("99".into()),
        top_pid: Some(99),
        pointer: None,
    };
    // Activates half a second after it reported launched.
    *r.desktop.steal_on_read.lock().unwrap() = Some((6, launched));
    let out = r.engine.call(&ctx("l1"), "launch_app", &json!({"app_id": "com.example.App"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["focus"]["restored_from"], "com.example.App");
    assert!(matches!(r.desktop.events()[0], Event::Launch(_)));
}

#[test]
fn a_failed_restore_is_reported() {
    let mut d = FakeDesktop::standard();
    d.restore_works = false;
    let r = rig_with(d, true);
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = click(&r, "c1");
    assert_eq!(out.body["focus"]["kept"], false);
    assert!(out.body["focus"]["not_restored"].is_string());
}

#[test]
fn foreground_delivery_and_observation_are_not_guarded() {
    let r = rig();
    let out = r.engine.call(&ctx("s"), "screenshot", &json!({"window_id": "1"}));
    assert!(out.body.get("focus").is_none());
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    r.engine.set_config(PolicyConfig { allow_foreground: true, ..PolicyConfig::default() });
    let out = r.engine.call(
        &ctx("f"),
        "click",
        &json!({"window_id": "1", "element_id": "e1", "delivery": "foreground"}),
    );
    assert!(out.body.get("focus").is_none(), "{:?}", out.body);
    assert!(r.desktop.restores().is_empty());
}

#[test]
fn a_desktop_that_cannot_tell_adds_nothing() {
    let r = rig();
    *r.desktop.focus.lock().unwrap() = None;
    let out = click(&r, "c1");
    assert!(out.body.get("focus").is_none());
}

#[test]
fn a_batch_is_guarded_once() {
    let r = rig();
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = r.engine.call(
        &ctx("b"),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "click", "element_id": "e1"},
            {"action": "type_text", "text": "hi"},
        ]}),
    );
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari");
    assert_eq!(r.desktop.restores().len(), 1);
}

#[test]
fn a_tool_without_delivery_is_guarded_whatever_delivery_it_names() {
    // perform_action, set_value, scroll and launch_app have no delivery: they
    // always act in the background and are authorized that way. Naming
    // "delivery": "foreground" on them skipped the focus guard, even with
    // foreground input off, so a target that activated itself kept focus.
    let r = rig();
    for (tool, args) in [
        (
            "perform_action",
            json!({"window_id": "1", "element_id": "e1", "action": "press", "delivery": "foreground"}),
        ),
        (
            "set_value",
            json!({"window_id": "1", "element_id": "e1", "value": "x", "delivery": "foreground"}),
        ),
        ("scroll", json!({"window_id": "1", "x": 5, "y": 5, "dy": 3, "delivery": "foreground"})),
        ("launch_app", json!({"app_id": "com.apple.Safari", "delivery": "foreground"})),
    ] {
        *r.desktop.focus.lock().unwrap() = Some(person());
        *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
        let out = r.engine.call(&ctx(tool), tool, &args);
        assert!(!out.is_error, "{tool}: {:?}", out.body);
        assert_eq!(
            out.body["focus"]["restored_from"], "com.apple.Safari",
            "{tool}: {:?}",
            out.body
        );
    }
}

#[test]
fn a_batch_is_unguarded_only_when_every_step_asks_for_foreground() {
    let r = rig();
    r.engine.set_config(PolicyConfig { allow_foreground: true, ..PolicyConfig::default() });
    // One step that names foreground on a tool without delivery, one background
    // step: guarded (it used to skip the guard for the whole batch).
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = r.engine.call(
        &ctx("b1"),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "set_value", "element_id": "e1", "value": "x", "delivery": "foreground"},
            {"action": "type_text", "text": "hi"},
        ]}),
    );
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);
    // Every step foreground on tools that take it: raised on purpose, not guarded.
    *r.desktop.focus.lock().unwrap() = Some(person());
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let restores = r.desktop.restores().len();
    let out = r.engine.call(
        &ctx("b2"),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "click", "element_id": "e1", "delivery": "foreground"},
            {"action": "type_text", "text": "hi", "delivery": "foreground"},
        ]}),
    );
    assert!(!out.is_error, "{:?}", out.body);
    assert!(out.body.get("focus").is_none(), "{:?}", out.body);
    assert_eq!(r.desktop.restores().len(), restores);
}

/// Safari (pid 10) in front with another of its windows (an About or
/// Settings window) as the key window.
fn safari_other_window() -> FocusSnapshot {
    FocusSnapshot { window_id: Some("9".into()), ..safari_front() }
}

fn ctx_in(session: &str, call: &str) -> CallContext {
    CallContext { session: session.into(), ..ctx(call) }
}

/// The agent (session s1) brings Safari forward on purpose: a foreground
/// click with foreground input allowed.
fn agent_raises_safari(r: &Rig) {
    r.engine.set_config(PolicyConfig { allow_foreground: true, ..PolicyConfig::default() });
    *r.desktop.steal_on_input.lock().unwrap() = Some(safari_front());
    let out = r.engine.call(
        &ctx("raise"),
        "click",
        &json!({"window_id": "1", "element_id": "e1", "delivery": "foreground"}),
    );
    assert!(!out.is_error, "{:?}", out.body);
}

/// A background click on Safari that brings `then` forward.
fn background_click(r: &Rig, session: &str, call: &str, then: FocusSnapshot) -> ToolOutput {
    *r.desktop.steal_on_input.lock().unwrap() = Some(then);
    r.engine.call(&ctx_in(session, call), "click", &json!({"window_id": "1", "element_id": "e1"}))
}

#[test]
fn a_window_of_the_app_the_agent_brought_forward_stays() {
    let r = rig();
    agent_raises_safari(&r);
    // A background press opens Safari's About window as the key window: the
    // agent's work in the app it put in front (a task graded on the front
    // window failed when it was put back behind the main window).
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_eq!(
        out.body["focus"],
        json!({"kept": false, "moved_by": "agent_foreground", "moved_to": "com.apple.Safari"}),
        "{:?}",
        out.body
    );
    assert!(r.desktop.restores().is_empty());
    // The record follows: another of its windows next is still the agent's.
    let back = FocusSnapshot { window_id: Some("1".into()), ..safari_front() };
    let out = background_click(&r, "s1", "c3", back);
    assert_eq!(out.body["focus"]["moved_by"], "agent_foreground", "{:?}", out.body);
}

#[test]
fn the_person_using_the_app_ends_the_agents_front_app() {
    let r = rig();
    agent_raises_safari(&r);
    // The person clicks in Safari (their input count moves): from then on a
    // Safari window coming forward is put back, as before.
    r.person.0.fetch_add(1, Ordering::SeqCst);
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);
}

#[test]
fn another_apps_window_over_the_agents_front_app_is_put_back() {
    // A desktop with TextEdit (pid 30, window 30) besides Safari.
    let mut desktop = FakeDesktop::standard();
    desktop.apps.push(crate::desktop::App {
        id: "com.apple.TextEdit".into(),
        name: "TextEdit".into(),
        pid: 30,
        ..desktop.apps[0].clone()
    });
    let mut textedit = desktop.windows.iter().find(|w| w.id == "1").unwrap().clone();
    textedit.id = "30".into();
    textedit.app_id = "com.apple.TextEdit".into();
    textedit.pid = 30;
    desktop.windows.push(textedit);
    let r = rig_with(desktop, true);
    agent_raises_safari(&r);
    // A background click on TextEdit orders a TextEdit window above Safari
    // without activating it: not the agent's front app's own window, so the
    // window-above rule holds and it is put back.
    let over = FocusSnapshot { top_pid: Some(30), ..safari_front() };
    *r.desktop.steal_on_input.lock().unwrap() = Some(over);
    let out = r.engine.call(&ctx("c2"), "click", &json!({"window_id": "30", "element_id": "e1"}));
    assert!(out.body["focus"].get("restored_from").is_some(), "{:?}", out.body);
}

#[test]
fn a_foreground_call_on_the_persons_own_front_app_records_nothing() {
    let r = rig();
    r.engine.set_config(PolicyConfig { allow_foreground: true, ..PolicyConfig::default() });
    // Safari is already the person's front app when the agent types into it
    // with foreground delivery: it did not bring Safari forward.
    *r.desktop.focus.lock().unwrap() = Some(safari_front());
    let out = r.engine.call(
        &ctx("t"),
        "type_text",
        &json!({"window_id": "1", "text": "x", "delivery": "foreground"}),
    );
    assert!(!out.is_error, "{:?}", out.body);
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);
}

#[test]
fn the_agents_front_app_is_its_own_session_only() {
    let r = rig();
    agent_raises_safari(&r);
    let out = background_click(&r, "s2", "c2", safari_other_window());
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);
}

#[test]
fn turning_foreground_off_or_ending_the_session_ends_the_agents_front_app() {
    let r = rig();
    agent_raises_safari(&r);
    r.engine.set_config(PolicyConfig { allow_foreground: false, ..PolicyConfig::default() });
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);

    let r = rig();
    agent_raises_safari(&r);
    r.engine.end_session("s1");
    *r.desktop.focus.lock().unwrap() = Some(safari_front());
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_eq!(out.body["focus"]["restored_from"], "com.apple.Safari", "{:?}", out.body);
}

#[test]
fn with_no_input_counter_nothing_is_exempt() {
    let r = rig_with(FakeDesktop::standard(), false);
    agent_raises_safari(&r);
    let out = background_click(&r, "s1", "c2", safari_other_window());
    assert_ne!(out.body["focus"]["moved_by"], "agent_foreground", "{:?}", out.body);
}

#[test]
fn every_tool_that_takes_delivery_authorizes_foreground_as_such() {
    // asks_foreground trusts a tool's foreground only when the tool lists
    // delivery in its schema; this ties that list to what the tools do: with
    // foreground input off, each of them refuses foreground before acting.
    let r = rig();
    let delivery_tools: Vec<&str> =
        tools::TOOLS.iter().filter(|t| t.takes_delivery()).map(|t| t.name).collect();
    assert_eq!(delivery_tools, ["click", "type_text", "press_key", "drag"]);
    for name in delivery_tools {
        let args = match name {
            "click" => json!({"window_id": "1", "element_id": "e1"}),
            "type_text" => json!({"window_id": "1", "text": "x"}),
            "press_key" => json!({"window_id": "1", "keys": "a"}),
            _ => json!({"window_id": "1", "from_x": 1, "from_y": 1, "to_x": 5, "to_y": 5}),
        };
        let mut args = args;
        args["delivery"] = json!("foreground");
        let events = r.desktop.events().len();
        let out = r.engine.call(&ctx(name), name, &args);
        assert_eq!(out.code.as_deref(), Some("foreground_not_allowed"), "{name}: {:?}", out.body);
        assert_eq!(r.desktop.events().len(), events, "{name} acted");
    }
}
