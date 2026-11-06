use std::sync::Mutex;

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

fn ctx(call: Option<&str>) -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: call.map(str::to_string),
        origin: OriginKind::Local,
    }
}

fn engine(desktop: Arc<FakeDesktop>, config: PolicyConfig) -> Engine {
    let mut parts = EngineParts::new(desktop);
    parts.config = config;
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
    let out = e.call(&ctx(Some("c1")), "click", &json!({"window_id": "1", "x": 1456.0, "y": 0.0}));
    assert!(!out.is_error, "{:?}", out.body);
    let Event::Click { point: Some(p), .. } = &d.events()[0] else { panic!("{:?}", d.events()) };
    assert!((p.x - (100.0 + 1456.0 * k)).abs() < 1e-6 && (p.y - 100.0).abs() < 1e-6);
}

#[test]
fn a_retried_call_id_does_not_click_twice() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    let args = json!({"window_id": "1", "element_id": "e1"});
    let first = e.call(&ctx(Some("same")), "click", &args);
    let second = e.call(&ctx(Some("same")), "click", &args);
    assert_eq!(first, second);
    assert_eq!(d.events().len(), 1);
    e.call(&ctx(Some("other")), "click", &args);
    assert_eq!(d.events().len(), 2);
}

#[test]
fn denied_apps_are_refused_and_redacted() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
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
    let mut parts = EngineParts::new(d.clone());
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
    let d = Arc::new(FakeDesktop::standard());
    let mut parts = EngineParts::new(d.clone());
    parts.takeover = Arc::new(Busy);
    let e = Engine::new(parts);
    let out = e.call(&ctx(None), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert_eq!(out.code.as_deref(), Some("person_in_control"));
    assert!(!e.call(&ctx(None), "screenshot", &json!({"window_id": "1"})).is_error);
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
    let mut parts = EngineParts::new(d.clone());
    parts.cursor = rec.clone();
    let e = Engine::new(parts);
    e.call(&ctx(None), "click", &json!({"window_id": "1", "x": 10, "y": 10}));
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
    let t = e.call(&ctx(None), "get_ui_tree", &json!({"window_id": "1"}));
    let f = &t.body["root"]["children"][0]["frame"];
    let k = 1456.0 / 800.0;
    assert_eq!(f["x"].as_f64().unwrap(), (10.0 * k as f64).round());
}

#[test]
fn off_refuses_everything_but_status() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig { mode: Mode::Off, ..PolicyConfig::default() });
    assert!(!e.call(&ctx(None), "status", &json!({})).is_error);
    assert_eq!(e.call(&ctx(None), "list_apps", &json!({})).code.as_deref(), Some("computer_use_off"));
}

#[test]
fn mcp_shape() {
    let mut out = ToolOutput::ok(json!({"a": 1}));
    out.png_base64 = Some("AAAA".into());
    let v = out.to_mcp();
    assert_eq!(v["content"][1]["type"], "image");
    assert_eq!(v["isError"], false);
}
