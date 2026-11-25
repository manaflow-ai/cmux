use super::*;
use serde_json::json;

const MINE: &str =
    "[\n  // mine\n  { \"key\": \"cmd+shift+y\", \"command\": \"toggleSidebar\" }\n]\n";

#[test]
fn a_binding_is_its_key_and_when_and_a_removal_is_its_own() {
    assert_eq!(id(&json!({"key": "Ctrl+Cmd+H", "command": "a"})).as_deref(), Some("cmd+ctrl+h"));
    assert_eq!(
        id(&json!({"key": "ctrl+k  s", "command": "a", "when": " terminalFocus "})).as_deref(),
        Some("ctrl+k s when terminalFocus")
    );
    assert_eq!(
        id(&json!({"key": "cmd+w", "command": "-closeTab"})).as_deref(),
        Some("cmd+w -closeTab")
    );
    assert_eq!(id(&json!({"command": "-closeTab"})).as_deref(), Some("-closeTab"));
    assert_eq!(id(&json!({"command": "a"})), None);
    assert_eq!(id(&json!(3)), None);
}

#[test]
fn composing_keeps_the_base_and_off_gives_it_back_byte_for_byte() {
    let vim = winners(["[{\"key\": \"ctrl+cmd+h\", \"command\": \"focusLeft\"}]"].into_iter());
    let composed = compose(Some(MINE), &vim).unwrap().unwrap();
    assert!(composed.starts_with("[\n  // mine\n  { \"key\": \"cmd+shift+y\""), "{composed}");
    assert!(composed.contains("focusLeft"));
    assert_eq!(compose(Some(MINE), &[]).unwrap().as_deref(), Some(MINE));
    assert_eq!(uncompose(Some(&composed), Some(MINE), &vim).as_deref(), Some(MINE));
    let fresh = compose(None, &vim).unwrap();
    assert_eq!(uncompose(fresh.as_deref(), None, &vim), None);
}

#[test]
fn the_higher_file_wins_a_key_and_a_base_key_is_replaced_in_place() {
    let low = "[{\"key\": \"cmd+shift+y\", \"command\": \"low\"}, {\"key\": \"ctrl+a\", \"command\": \"x\"}]";
    let high = "[{\"key\": \"cmd+shift+y\", \"command\": \"high\"}]";
    let wins = winners([high, low].into_iter());
    assert_eq!(wins.len(), 2);
    assert_eq!(wins[0].1["command"], "high");
    let composed = compose(Some(MINE), &wins).unwrap().unwrap();
    let parsed = bindings(&composed);
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].1["command"], "high", "replaced where the base had it");
    assert!(!composed.contains("toggleSidebar"));
    assert_eq!(
        uncompose(Some(&composed), Some(MINE), &wins).map(|t| bindings(&t)),
        Some(bindings(MINE))
    );
}

#[test]
fn a_hand_edit_to_a_composed_file_stays_in_the_base() {
    let vim = winners(["[{\"key\": \"ctrl+cmd+h\", \"command\": \"focusLeft\"}]"].into_iter());
    let composed = compose(Some(MINE), &vim).unwrap().unwrap();
    let edited =
        jsonc::array_append(&composed, &json!({"key": "cmd+9", "command": "mine2"})).unwrap();
    let base = uncompose(Some(&edited), Some(MINE), &vim).unwrap();
    let ids: Vec<String> = bindings(&base).into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, ["cmd+shift+y", "cmd+9"]);
}

#[test]
fn added_is_only_what_changed() {
    let new = compose(
        Some(MINE),
        &winners(["[{\"key\": \"ctrl+cmd+h\", \"command\": \"focusLeft\"}]"].into_iter()),
    )
    .unwrap()
    .unwrap();
    let added = added(MINE, &new).unwrap();
    let ids: Vec<String> = bindings(&added).into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, ["cmd+ctrl+h"]);
    assert_eq!(super::added(MINE, MINE), None);
}
