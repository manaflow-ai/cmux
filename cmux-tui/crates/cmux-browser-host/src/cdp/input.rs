//! Trusted input through `Input.dispatch*` (events reach the page with
//! `isTrusted === true`, as the WebKit driver's native events do).

use super::driver::Inner;
use super::keys::{implied_text, modifier_bits, mouse_button, virtual_key_code};
use crate::protocol::{DriverError, required_str, timeout_of};
use serde_json::{Value, json};
use std::time::Instant;

impl Inner {
    pub(super) fn mouse(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let kind = required_str(params, "type")?;
        let modifiers = modifier_bits(params)?;
        let (button, bit) = mouse_button(params.get("button").and_then(Value::as_str))?;
        let click_count = params.get("clickCount").and_then(Value::as_i64).unwrap_or(1);
        let (x, y, buttons) = {
            let mut state = self.lock();
            let tab = state
                .tabs
                .get_mut(&session.target_id)
                .ok_or_else(|| DriverError::closed(format!("Tab {} closed", session.target_id)))?;
            let x = params.get("x").and_then(Value::as_f64).unwrap_or(tab.mouse.0);
            let y = params.get("y").and_then(Value::as_f64).unwrap_or(tab.mouse.1);
            tab.mouse = (x, y);
            match kind {
                "down" => tab.buttons |= bit,
                "up" => tab.buttons &= !bit,
                _ => {}
            }
            (x, y, tab.buttons)
        };
        let mut event = json!({"x": x, "y": y, "modifiers": modifiers, "buttons": buttons});
        match kind {
            "move" => {
                event["type"] = json!("mouseMoved");
                event["button"] = json!(pressed_button(buttons));
            }
            "down" => {
                event["type"] = json!("mousePressed");
                event["button"] = json!(button);
                event["clickCount"] = json!(click_count);
            }
            "up" => {
                event["type"] = json!("mouseReleased");
                event["button"] = json!(button);
                event["clickCount"] = json!(click_count);
            }
            "wheel" => {
                event["type"] = json!("mouseWheel");
                event["button"] = json!("none");
                event["deltaX"] =
                    json!(params.get("deltaX").and_then(Value::as_f64).unwrap_or(0.0));
                event["deltaY"] =
                    json!(params.get("deltaY").and_then(Value::as_f64).unwrap_or(0.0));
            }
            other => return Err(DriverError::invalid(format!("Unknown mouse event {other}"))),
        }
        self.send_until(&session, "Input.dispatchMouseEvent", event, deadline)?;
        Ok(Value::Null)
    }

    pub(super) fn key(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let kind = required_str(params, "type")?;
        let key = required_str(params, "key")?;
        let code = params.get("code").and_then(Value::as_str).unwrap_or("");
        let modifiers = modifier_bits(params)?;
        let location = params.get("location").and_then(Value::as_i64).unwrap_or(0);
        let vk = virtual_key_code(code, key);
        {
            let mut state = self.lock();
            if let Some(tab) = state.tabs.get_mut(&session.target_id) {
                let same = |held: &(String, String, i64)| {
                    if code.is_empty() { held.0 == key } else { held.1 == code }
                };
                match kind {
                    "down" if !tab.held_keys.iter().any(same) => {
                        tab.held_keys.push((key.to_owned(), code.to_owned(), location));
                    }
                    "up" => tab.held_keys.retain(|held| !same(held)),
                    _ => {}
                }
            }
        }
        let mut event = json!({
            "key": key,
            "code": code,
            "modifiers": modifiers,
            "windowsVirtualKeyCode": vk,
            "nativeVirtualKeyCode": vk,
            "location": location,
            "isKeypad": location == 3,
            "autoRepeat": params.get("autoRepeat").and_then(Value::as_bool).unwrap_or(false),
        });
        match kind {
            "down" => {
                let text = params
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !text.is_empty())
                    .or_else(|| implied_text(key, modifiers));
                match text {
                    Some(text) => {
                        event["type"] = json!("keyDown");
                        event["text"] = json!(text);
                        event["unmodifiedText"] = json!(text);
                    }
                    None => event["type"] = json!("rawKeyDown"),
                }
                let commands = mac_editing_commands(code, modifiers);
                if !commands.is_empty() {
                    event["commands"] = json!(commands);
                }
            }
            "up" => event["type"] = json!("keyUp"),
            other => return Err(DriverError::invalid(format!("Unknown key event {other}"))),
        }
        self.send_until(&session, "Input.dispatchKeyEvent", event, deadline)?;
        Ok(Value::Null)
    }

    /// Releases what the sessions left pressed in a tab (driver-protocol.md
    /// "Sessions and tabs"): a key-up per held key, last pressed first, with
    /// the modifiers still held, then a button-up per held mouse button at
    /// the last mouse position. Trusted events, like every input.
    pub(super) fn release_held_input(&self, target_id: &str) -> Result<(), DriverError> {
        let (keys, buttons, (x, y)) = {
            let mut state = self.lock();
            let Some(tab) = state.tabs.get_mut(target_id) else { return Ok(()) };
            let held = (std::mem::take(&mut tab.held_keys), tab.buttons, tab.mouse);
            tab.buttons = 0;
            held
        };
        if keys.is_empty() && buttons == 0 {
            return Ok(());
        }
        let session = self.session(&json!({"targetId": target_id}))?;
        let deadline = Instant::now() + super::driver::INTERNAL_TIMEOUT;
        let modifier = |key: &str| match key {
            "Alt" => 1,
            "Control" => 2,
            "Meta" => 4,
            "Shift" => 8,
            _ => 0,
        };
        for (i, (key, code, location)) in keys.iter().enumerate().rev() {
            let modifiers: i64 = keys[..i].iter().map(|held| modifier(&held.0)).fold(0, |a, b| a | b);
            let vk = virtual_key_code(code, key);
            let event = json!({
                "type": "keyUp", "key": key, "code": code, "modifiers": modifiers,
                "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk,
                "location": location, "isKeypad": *location == 3,
            });
            self.send_until(&session, "Input.dispatchKeyEvent", event, deadline)?;
        }
        let mut left = buttons;
        for (bit, button) in [(1, "left"), (2, "right"), (4, "middle")] {
            if buttons & bit == 0 {
                continue;
            }
            left &= !bit;
            let event = json!({
                "type": "mouseReleased", "x": x, "y": y, "button": button,
                "buttons": left, "clickCount": 1, "modifiers": 0,
            });
            self.send_until(&session, "Input.dispatchMouseEvent", event, deadline)?;
        }
        Ok(())
    }

    pub(super) fn insert_text(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let text = required_str(params, "text")?;
        self.send_until(
            &session,
            "Input.insertText",
            json!({"text": text}),
            Instant::now() + timeout_of(params),
        )?;
        Ok(Value::Null)
    }
}

fn pressed_button(buttons: i64) -> &'static str {
    if buttons & 1 != 0 {
        "left"
    } else if buttons & 2 != 0 {
        "right"
    } else if buttons & 4 != 0 {
        "middle"
    } else {
        "none"
    }
}

/// macOS Chromium runs editing shortcuts from `commands` (as Playwright does);
/// without them Meta+A or Meta+Backspace type nothing. Other platforms handle
/// these keys natively.
fn mac_editing_commands(code: &str, modifiers: i64) -> Vec<&'static str> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    editing_commands(code, modifiers)
}

/// The macOS editing command table, independent of the build platform.
pub(super) fn editing_commands(code: &str, modifiers: i64) -> Vec<&'static str> {
    const ALT: i64 = 1;
    const CONTROL: i64 = 2;
    const META: i64 = 4;
    const SHIFT: i64 = 8;
    let shift = modifiers & SHIFT != 0;
    let command = match (modifiers & (ALT | CONTROL | META), code) {
        (META, "KeyA") => "selectAll",
        (META, "KeyZ") if shift => "redo",
        (META, "KeyZ") => "undo",
        (META, "Backspace") => "deleteToBeginningOfLine",
        (ALT, "Backspace") => "deleteWordBackward",
        (META, "ArrowLeft") if shift => "moveToBeginningOfLineAndModifySelection",
        (META, "ArrowLeft") => "moveToBeginningOfLine",
        (META, "ArrowRight") if shift => "moveToEndOfLineAndModifySelection",
        (META, "ArrowRight") => "moveToEndOfLine",
        (META, "ArrowUp") if shift => "moveToBeginningOfDocumentAndModifySelection",
        (META, "ArrowUp") => "moveToBeginningOfDocument",
        (META, "ArrowDown") if shift => "moveToEndOfDocumentAndModifySelection",
        (META, "ArrowDown") => "moveToEndOfDocument",
        (ALT, "ArrowLeft") if shift => "moveWordLeftAndModifySelection",
        (ALT, "ArrowLeft") => "moveWordLeft",
        (ALT, "ArrowRight") if shift => "moveWordRightAndModifySelection",
        (ALT, "ArrowRight") => "moveWordRight",
        _ => return Vec::new(),
    };
    vec![command]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pressed_button_prefers_left() {
        assert_eq!(pressed_button(0), "none");
        assert_eq!(pressed_button(6), "right");
        assert_eq!(pressed_button(7), "left");
    }

    #[test]
    fn editing_commands_follow_mac_shortcuts() {
        assert_eq!(editing_commands("KeyA", 4), vec!["selectAll"]);
        assert_eq!(editing_commands("KeyZ", 12), vec!["redo"]);
        assert_eq!(editing_commands("ArrowLeft", 9), vec!["moveWordLeftAndModifySelection"]);
        assert!(editing_commands("KeyA", 0).is_empty());
        assert!(editing_commands("KeyA", 6).is_empty(), "Control+Meta+A is not select all");
    }
}
