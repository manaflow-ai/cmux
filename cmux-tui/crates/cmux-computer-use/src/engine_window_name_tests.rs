use super::*;
use crate::desktop::Rect;

fn win(id: &str, app: &str, title: &str) -> Window {
    Window {
        id: id.into(),
        app_id: app.into(),
        pid: 1,
        title: title.into(),
        frame: Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 },
        on_screen: true,
        focused: false,
        minimized: false,
    }
}

fn names() -> HashMap<String, String> {
    HashMap::from([("com.apple.calculator".to_string(), "Calculator".to_string())])
}

#[test]
fn ids_are_left_alone() {
    for id in ["42", "a11y:/org/a11y/1", "sway:7", "hypr:0x55aa", "tl:3"] {
        assert!(looks_like_window_id(id), "{id}");
    }
    for name in ["CU Eval Form", "Calculator", "TextEdit", "Untitled: Notes", ""] {
        assert!(!looks_like_window_id(name), "{name}");
    }
}

#[test]
fn title_then_app_then_part_of_title() {
    let ws = vec![
        win("1", "python3", "CU Eval Form"),
        win("2", "com.apple.calculator", "Calculator"),
        win("3", "com.apple.TextEdit", "notes.txt"),
    ];
    assert_eq!(pick(&ws, &names(), "cu eval form").unwrap().id, "1");
    assert_eq!(pick(&ws, &names(), "Calculator").unwrap().id, "2");
    assert_eq!(pick(&ws, &names(), "com.apple.textedit").unwrap().id, "3");
    assert_eq!(pick(&ws, &names(), "notes").unwrap().id, "3");
}

#[test]
fn several_matches_are_refused_with_the_matches() {
    let ws = vec![win("1", "python3", "Invoice A"), win("2", "python3", "Invoice B")];
    let out = pick(&ws, &names(), "invoice").unwrap_err().to_json().to_string();
    assert!(
        out.contains("target_ambiguous") && out.contains("Invoice A") && out.contains("Invoice B"),
        "{out}"
    );
    // A whole title still picks one of two alike.
    assert_eq!(pick(&ws, &names(), "Invoice B").unwrap().id, "2");
}

#[test]
fn no_match_lists_every_window() {
    let ws = vec![win("1", "python3", "CU Eval Form")];
    let out = pick(&ws, &names(), "Safari").unwrap_err().to_json().to_string();
    assert!(out.contains("target_not_found") && out.contains("CU Eval Form"), "{out}");
}
