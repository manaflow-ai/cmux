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
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now.clone());
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
