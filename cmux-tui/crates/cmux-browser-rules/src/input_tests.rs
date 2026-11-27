use crate::input::{
    Button, MouseEventPlan, Point, code_for_key, flag, needs_shift, resolve, view_point,
};
use crate::ops;
use serde_json::json;

fn mods(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

#[test]
fn a_letter_resolves_to_its_virtual_key_and_text() {
    let stroke = resolve("a", "KeyA", Some("a"), &[]).unwrap();
    assert_eq!(stroke.key_code, 0x00);
    assert_eq!(stroke.modifier_flags, 0);
    assert_eq!(stroke.characters, "a");
    assert_eq!(stroke.characters_ignoring_modifiers, "a");
    assert!(!stroke.is_modifier);
    assert_eq!(stroke.editing_command, None);
}

#[test]
fn a_key_without_a_code_finds_one() {
    assert_eq!(code_for_key("a").as_deref(), Some("KeyA"));
    assert_eq!(code_for_key("Q").as_deref(), Some("KeyQ"));
    assert_eq!(code_for_key("7").as_deref(), Some("Digit7"));
    assert_eq!(code_for_key(" ").as_deref(), Some("Space"));
    assert_eq!(code_for_key("Enter").as_deref(), Some("Enter"));
    assert_eq!(code_for_key("/").as_deref(), Some("Slash"));
    assert_eq!(code_for_key("#").as_deref(), Some("Digit3"));
    assert_eq!(code_for_key("é"), None);
    assert_eq!(code_for_key("Unidentified"), None);
}

#[test]
fn an_uppercase_letter_or_shifted_symbol_holds_shift() {
    assert!(needs_shift("A"));
    assert!(needs_shift("#"));
    assert!(!needs_shift("a"));
    assert!(!needs_shift("Enter"));
    let stroke = resolve("A", "", None, &[]).unwrap();
    assert_eq!(stroke.key_code, 0x00);
    assert_eq!(stroke.modifier_flags, flag::SHIFT);
    assert_eq!(stroke.characters, "A");
    assert_eq!(stroke.characters_ignoring_modifiers, "a");
    let hash = resolve("#", "", None, &[]).unwrap();
    assert_eq!(hash.key_code, 0x14);
    assert_eq!(hash.characters, "#");
    assert_eq!(hash.characters_ignoring_modifiers, "3");
}

#[test]
fn a_modifier_key_is_a_flags_changed_event() {
    let stroke = resolve("Shift", "ShiftLeft", None, &mods(&["Control"])).unwrap();
    assert_eq!(stroke.key_code, 0x38);
    assert_eq!(stroke.modifier_flags, flag::SHIFT | flag::CONTROL);
    assert!(stroke.is_modifier);
    assert_eq!(stroke.characters, "");
    let caps = resolve("CapsLock", "CapsLock", None, &[]).unwrap();
    assert_eq!(caps.modifier_flags, flag::CAPS_LOCK);
}

#[test]
fn named_keys_carry_appkits_characters_and_flags() {
    let enter = resolve("Enter", "Enter", None, &[]).unwrap();
    assert_eq!((enter.key_code, enter.characters.as_str()), (0x24, "\r"));
    let up = resolve("ArrowUp", "ArrowUp", None, &[]).unwrap();
    assert_eq!(up.key_code, 0x7E);
    assert_eq!(up.characters, "\u{F700}");
    assert_eq!(up.modifier_flags, flag::FUNCTION | flag::NUMERIC_PAD);
    let f5 = resolve("F5", "F5", None, &[]).unwrap();
    assert_eq!(f5.key_code, 0x60);
    assert_eq!(f5.characters, "\u{F708}");
    assert_eq!(f5.modifier_flags, flag::FUNCTION);
    let pad = resolve("1", "Numpad1", Some("1"), &[]).unwrap();
    assert_eq!(pad.key_code, 0x53);
    assert_eq!(pad.modifier_flags, flag::NUMERIC_PAD);
}

#[test]
fn control_with_a_letter_sends_the_control_character() {
    let stroke = resolve("c", "KeyC", None, &mods(&["Control"])).unwrap();
    assert_eq!(stroke.characters, "\u{3}");
    assert_eq!(stroke.modifier_flags, flag::CONTROL);
    assert_eq!(stroke.editing_command, None);
}

#[test]
fn meta_shortcuts_send_their_editing_command() {
    let all = resolve("a", "KeyA", Some("a"), &mods(&["Meta"])).unwrap();
    assert_eq!(all.editing_command.as_deref(), Some("selectAll:"));
    assert_eq!(all.characters, "a");
    let undo = resolve("z", "KeyZ", None, &mods(&["Meta"])).unwrap();
    assert_eq!(undo.editing_command.as_deref(), Some("undo:"));
    let redo = resolve("z", "KeyZ", None, &mods(&["Meta", "Shift"])).unwrap();
    assert_eq!(redo.editing_command.as_deref(), Some("redo:"));
    let other = resolve("k", "KeyK", None, &mods(&["Meta", "Alt"])).unwrap();
    assert_eq!(other.editing_command, None);
    assert_eq!(other.modifier_flags, flag::COMMAND | flag::OPTION);
}

#[test]
fn a_key_with_no_virtual_key_resolves_to_none() {
    assert_eq!(resolve("é", "", Some("é"), &[]), None);
    assert_eq!(resolve("x", "IntlRo", None, &[]), None);
}

#[test]
fn a_move_while_a_button_is_held_is_a_drag() {
    let mut plan = MouseEventPlan::default();
    assert_eq!(plan.event_type("move", Button::Left), Some("mouseMoved"));
    assert_eq!(plan.event_type("down", Button::Left), Some("leftMouseDown"));
    assert_eq!(plan.event_type("move", Button::Left), Some("leftMouseDragged"));
    assert_eq!(plan.event_type("up", Button::Left), Some("leftMouseUp"));
    assert_eq!(plan.event_type("move", Button::Left), Some("mouseMoved"));
    assert_eq!(plan.event_type("down", Button::Middle), Some("otherMouseDown"));
    assert_eq!(plan.event_type("move", Button::Left), Some("otherMouseDragged"));
    assert_eq!(plan.event_type("wheel", Button::Left), None);
    assert_eq!(plan.held(), vec![Button::Middle]);
}

#[test]
fn a_css_point_scales_and_flips_into_the_view() {
    let css = Point { x: 10.0, y: 20.0 };
    assert_eq!(view_point(css, 2.0, 600.0, true), Point { x: 20.0, y: 40.0 });
    assert_eq!(view_point(css, 2.0, 600.0, false), Point { x: 20.0, y: 560.0 });
    assert_eq!(view_point(css, 0.0, 600.0, true), Point { x: 10.0, y: 20.0 });
}

#[test]
fn the_input_ops_answer_through_the_op_table() {
    let stroke = ops::call(
        "browser_rules_input_key_stroke",
        json!({"key": "a", "code": "", "modifiers": ["Meta"]}),
    )
    .unwrap();
    assert_eq!(
        stroke,
        json!({"keyCode": 0, "modifierFlags": flag::COMMAND, "characters": "a",
               "charactersIgnoringModifiers": "a", "isModifier": false,
               "editingCommand": "selectAll:"})
    );
    let none = ops::call("browser_rules_input_key_stroke", json!({"key": "é"})).unwrap();
    assert_eq!(none, json!(null));
    let mouse = ops::call(
        "browser_rules_input_mouse_event",
        json!({"held": ["right"], "type": "move", "button": "left"}),
    )
    .unwrap();
    assert_eq!(mouse, json!({"eventType": "rightMouseDragged", "held": ["right"]}));
    let point = ops::call(
        "browser_rules_input_view_point",
        json!({"css": {"x": 1.0, "y": 2.0}, "scale": 1.0, "viewHeight": 10.0, "flipped": false}),
    )
    .unwrap();
    assert_eq!(point, json!({"x": 1.0, "y": 8.0}));
}
