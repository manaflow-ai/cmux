use super::*;
use serde_json::json;

fn kinds(widget: Value) -> Vec<(&'static str, String)> {
    widget_contributions(&widget, "Clock").into_iter().map(|row| (row.kind, row.title)).collect()
}

/// A widget shows up once per place it names, in both places when it
/// names none; a place cmux does not know is skipped, not an error.
#[test]
fn a_widget_shows_up_once_per_place() {
    let clock = |kind| (kind, "Clock".to_string());
    let sidebar = json!({ "options": { "places": ["sidebar"], "sizes": ["small"] } });
    assert_eq!(kinds(sidebar), [clock("sidebarWidget")]);
    assert_eq!(kinds(json!({})), [clock("newTab"), clock("sidebarWidget")]);
    let titled = json!({
        "title": { "en": "World Clock", "ja": "世界時計" },
        "options": { "places": ["newtab", "sidebar", "newtab", "dock"] },
    });
    let world = |kind| (kind, "World Clock".to_string());
    assert_eq!(kinds(titled), [world("newTab"), world("sidebarWidget")]);
    assert!(kinds(Value::Null).is_empty());
}
