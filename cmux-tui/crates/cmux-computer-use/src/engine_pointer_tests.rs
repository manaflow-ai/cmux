//! `move_pointer` through the engine on the fake desktop: it resolves its
//! target as `click` does (window pixels, an element's small id, a display
//! point hit-tested to its window), presses nothing, and keeps the policy.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::desktop::fake::{Event, FakeDesktop};

struct Recorder(Mutex<Vec<CursorEvent>>);
impl CursorSink for Recorder {
    fn show(&self, e: CursorEvent) {
        self.0.lock().unwrap().push(e);
    }
}

fn ctx() -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: None,
        origin: OriginKind::Local,
        tag: None,
    }
}

fn rig(config: PolicyConfig) -> (Arc<FakeDesktop>, Engine, Arc<Recorder>) {
    let d = Arc::new(FakeDesktop::standard());
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    let mut parts = EngineParts::new(d.clone());
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now);
    parts.sleep = Arc::new(move |t| {
        a.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    parts.config = config;
    parts.cursor = rec.clone();
    (d, Engine::new(parts), rec)
}

fn moves(d: &FakeDesktop) -> Vec<Event> {
    d.events().into_iter().filter(|e| matches!(e, Event::Move { .. })).collect()
}

#[test]
fn window_pixels_map_to_desktop_points_as_a_click_does() {
    let (d, e, rec) = rig(PolicyConfig::default());
    e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    rec.0.lock().unwrap().clear();
    // Window 1 is 800x600 pt at 100,100, at 2x downscaled to 1456 px wide.
    let k = 800.0 / 1456.0;
    let out = e.call(&ctx(), "move_pointer", &json!({"window_id": "1", "x": 728.0, "y": 364.0}));
    assert!(!out.is_error, "{}", out.body);
    let events = d.events();
    assert_eq!(events.len(), 1, "a hover presses nothing: {events:?}");
    let Event::Move { window, point: Some(p), element: None, delivery } = &events[0] else {
        panic!("{events:?}")
    };
    assert_eq!(window, "1");
    assert_eq!(*delivery, Delivery::Background);
    assert!((p.x - (100.0 + 728.0 * k)).abs() < 1e-6 && (p.y - (100.0 + 364.0 * k)).abs() < 1e-6);
    // The agent cursor glides there and does not click.
    let cursor = rec.0.lock().unwrap();
    assert!(matches!(cursor.first(), Some(CursorEvent::Move { at, .. }) if at == p));
    assert!(!cursor.iter().any(|c| matches!(c, CursorEvent::Click { .. })));
    // The result shows the window after the move, as click's does.
    assert!(out.body.get("state").is_some(), "{}", out.body);
}

#[test]
fn an_element_id_reaches_the_desktop_as_the_element() {
    let (d, e, _) = rig(PolicyConfig::default());
    let out = e.call(&ctx(), "move_pointer", &json!({"window_id": "1", "element_id": "e1"}));
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(
        moves(&d),
        vec![Event::Move {
            window: "1".into(),
            point: None,
            element: Some("e1".into()),
            delivery: Delivery::Background,
        }]
    );
}

#[test]
fn a_display_point_is_hit_tested_to_its_window_and_denied_apps_stay_denied() {
    let (d, e, _) = rig(PolicyConfig::default());
    e.call(&ctx(), "screenshot", &json!({}));
    // Display is 1000x800 pt at 2x -> 1456 px wide: (150, 150) pt is Safari.
    let k = 1456.0 / 1000.0;
    let out = e.call(&ctx(), "move_pointer", &json!({"x": 150.0 * k, "y": 150.0 * k}));
    assert!(!out.is_error, "{}", out.body);
    let [Event::Move { window, point: Some(p), .. }] = moves(&d).as_slice() else {
        panic!("{:?}", d.events())
    };
    assert_eq!(window, "1");
    assert!((p.x - 150.0).abs() < 1e-6 && (p.y - 150.0).abs() < 1e-6);
    // (250, 250) pt is 1Password, on top: denied, and nothing moves.
    let out = e.call(&ctx(), "move_pointer", &json!({"x": 250.0 * k, "y": 250.0 * k}));
    assert_eq!(out.code.as_deref(), Some("app_denied"));
    assert_eq!(moves(&d).len(), 1);
}

#[test]
fn a_move_needs_a_target_it_can_place() {
    let (d, e, _) = rig(PolicyConfig::default());
    // A window and no element or point.
    let out = e.call(&ctx(), "move_pointer", &json!({"window_id": "1"}));
    assert_eq!(out.code.as_deref(), Some("invalid_arguments"), "{}", out.body);
    assert!(out.body.to_string().contains("move_pointer needs element_id or x and y"));
    // Window pixels with no screenshot of the window.
    let out = e.call(&ctx(), "move_pointer", &json!({"window_id": "1", "x": 5.0, "y": 5.0}));
    assert_eq!(out.code.as_deref(), Some("no_screenshot"), "{}", out.body);
    // A display point with no display screenshot.
    let out = e.call(&ctx(), "move_pointer", &json!({"x": 5.0, "y": 5.0}));
    assert_eq!(out.code.as_deref(), Some("invalid_arguments"), "{}", out.body);
    assert!(out.body.to_string().contains("move_pointer with no window_id"));
    assert!(d.events().is_empty(), "{:?}", d.events());
}

#[test]
fn foreground_needs_its_setting_and_is_passed_on() {
    let args = json!({"window_id": "1", "element_id": "e1", "delivery": "foreground"});
    let (d, e, _) = rig(PolicyConfig::default());
    let out = e.call(&ctx(), "move_pointer", &args);
    assert_eq!(out.code.as_deref(), Some("foreground_not_allowed"), "{}", out.body);
    assert!(d.events().is_empty());

    let config = PolicyConfig { allow_foreground: true, ..PolicyConfig::default() };
    let (d, e, _) = rig(config);
    let out = e.call(&ctx(), "move_pointer", &args);
    assert!(!out.is_error, "{}", out.body);
    let [Event::Move { delivery, .. }] = moves(&d).as_slice() else { panic!("{:?}", d.events()) };
    assert_eq!(*delivery, Delivery::Foreground);
}

#[test]
fn move_pointer_is_an_acting_tool_with_click_targets() {
    let tool = tools::find("move_pointer").unwrap();
    assert!(tool.acts());
    assert!(tool.takes_delivery());
    let s = tool.schema();
    for key in ["window_id", "element_id", "x", "y", "delivery", "observe"] {
        assert!(s["properties"][key].is_object(), "{key}");
    }
    assert_eq!(s["required"], json!([]));
    // Says what it does to the person's focus and pointer.
    assert!(tool.description.contains("nothing takes focus"));
    assert!(tool.description.contains("moves the person's real pointer"));
}
