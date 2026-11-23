use super::*;
use serde_json::json;

#[test]
fn modifiers_map_to_cdp_bits() {
    assert_eq!(modifier_bits(&json!({})).unwrap(), 0);
    assert_eq!(modifier_bits(&json!({"modifiers": ["Shift", "Meta"]})).unwrap(), 12);
    assert!(modifier_bits(&json!({"modifiers": ["Hyper"]})).is_err());
}

#[test]
fn virtual_key_codes_cover_letters_digits_and_editing_keys() {
    assert_eq!(virtual_key_code("KeyA", "a"), 65);
    assert_eq!(virtual_key_code("Digit7", "7"), 55);
    assert_eq!(virtual_key_code("F5", "F5"), 116);
    assert_eq!(virtual_key_code("Enter", "Enter"), 13);
    assert_eq!(virtual_key_code("ArrowDown", "ArrowDown"), 40);
    assert_eq!(virtual_key_code("", "Tab"), 9);
    assert_eq!(virtual_key_code("Fn", "Fn"), 0);
}

#[test]
fn enter_implies_carriage_return_without_command_modifiers() {
    assert_eq!(implied_text("Enter", 0), Some("\r"));
    assert_eq!(implied_text("Enter", 8), Some("\r"));
    assert_eq!(implied_text("Enter", 4), None);
    assert_eq!(implied_text("ArrowUp", 0), None);
}
