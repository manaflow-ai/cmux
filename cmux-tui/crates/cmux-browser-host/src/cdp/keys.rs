//! Driver input values to CDP `Input.*` parameters.

use crate::protocol::DriverError;
use serde_json::Value;

/// CDP modifier bits: Alt=1, Control=2, Meta=4, Shift=8.
pub fn modifier_bits(params: &Value) -> Result<i64, DriverError> {
    let Some(list) = params.get("modifiers") else {
        return Ok(0);
    };
    if list.is_null() {
        return Ok(0);
    }
    let list =
        list.as_array().ok_or_else(|| DriverError::invalid("modifiers: expected an array"))?;
    let mut bits = 0;
    for name in list {
        bits |= match name.as_str() {
            Some("Alt") => 1,
            Some("Control") => 2,
            Some("Meta") => 4,
            Some("Shift") => 8,
            _ => {
                return Err(DriverError::invalid(format!(
                    "modifiers: expected Alt, Control, Meta or Shift, got {name}"
                )));
            }
        };
    }
    Ok(bits)
}

/// CDP mouse button name and its `buttons` bit.
pub fn mouse_button(name: Option<&str>) -> Result<(&'static str, i64), DriverError> {
    match name {
        None | Some("left") => Ok(("left", 1)),
        Some("right") => Ok(("right", 2)),
        Some("middle") => Ok(("middle", 4)),
        Some(other) => Err(DriverError::invalid(format!(
            "button: expected left, right or middle, got {other:?}"
        ))),
    }
}

/// Windows virtual key code for a `KeyboardEvent.code` (Chromium needs it
/// for keys whose default action is not text: Enter, Tab, arrows, editing).
pub fn virtual_key_code(code: &str, key: &str) -> i64 {
    if let Some(letter) = code.strip_prefix("Key")
        && letter.len() == 1
        && let Some(c) = letter.chars().next()
        && c.is_ascii_uppercase()
    {
        return i64::from(u32::from(c));
    }
    if let Some(digit) = code.strip_prefix("Digit")
        && let Ok(n) = digit.parse::<i64>()
        && (0..=9).contains(&n)
    {
        return 48 + n;
    }
    if let Some(n) = code.strip_prefix('F').and_then(|n| n.parse::<i64>().ok())
        && (1..=24).contains(&n)
    {
        return 111 + n;
    }
    match code {
        "Backspace" => 8,
        "Tab" => 9,
        "Enter" | "NumpadEnter" => 13,
        "ShiftLeft" | "ShiftRight" => 16,
        "ControlLeft" | "ControlRight" => 17,
        "AltLeft" | "AltRight" => 18,
        "Pause" => 19,
        "CapsLock" => 20,
        "Escape" => 27,
        "Space" => 32,
        "PageUp" => 33,
        "PageDown" => 34,
        "End" => 35,
        "Home" => 36,
        "ArrowLeft" => 37,
        "ArrowUp" => 38,
        "ArrowRight" => 39,
        "ArrowDown" => 40,
        "Insert" => 45,
        "Delete" => 46,
        "MetaLeft" => 91,
        "MetaRight" => 92,
        "ContextMenu" => 93,
        "Semicolon" => 186,
        "Equal" => 187,
        "Comma" => 188,
        "Minus" => 189,
        "Period" => 190,
        "Slash" => 191,
        "Backquote" => 192,
        "BracketLeft" => 219,
        "Backslash" => 220,
        "BracketRight" => 221,
        "Quote" => 222,
        _ => match key {
            "Enter" => 13,
            "Tab" => 9,
            "Backspace" => 8,
            "Escape" => 27,
            _ => 0,
        },
    }
}

/// Text a key inserts when the runtime did not send `text`: Enter inserts
/// "\r" as in Chromium's own keyboard, other non-character keys insert nothing.
pub fn implied_text(key: &str, modifiers: i64) -> Option<&'static str> {
    // Alt, Control or Meta held: no text (the runtime's rule for `text`).
    if modifiers & 0b0111 != 0 {
        return None;
    }
    match key {
        "Enter" => Some("\r"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
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
}
