//! Shortcuts: the key chords an extension's command answers anywhere in the app.
//!
//! A catalog op's `keyboard` entry whose key holds Command, Control or Option
//! (`{"key": "cmd+shift+k"}`) is a shortcut. `apps-list` gives each palette command its
//! shortcuts as `shortcuts: [{"key": "k", "modifiers": ["cmd", "shift"]}]`, the shape the Mac
//! app's binding table reads (`opt` for Option), and the app registers the command under its own
//! action id, so the person rebinds it in Settings > Keyboard like a built-in shortcut. A bare
//! key or Shift and a key is a page key (`page_keys.rs`) or nothing: an extension never takes a
//! key a person types.
//!
//! The key is one character (a letter, a digit or punctuation) or `space`; named keys such as
//! `enter` or `f5` are not routed yet. The entry's `when` is not read: a shortcut runs wherever
//! the command's palette entry does.

use serde_json::{Value, json};

/// The most shortcuts one op answers.
const MAX_SHORTCUTS: usize = 4;

/// One chord in the app's wire shape, or None for a key that is not a routable chord.
fn chord(key: &str) -> Option<Value> {
    let mut parts: Vec<&str> = key.split('+').collect();
    // `cmd++` is Command and the plus key.
    if key.ends_with("++") {
        parts.truncate(parts.len().saturating_sub(2));
        parts.push("+");
    }
    let (last, modifiers) = parts.split_last()?;
    let key = match *last {
        "space" => " ".to_string(),
        k if k.chars().count() == 1 => k.to_lowercase(),
        _ => return None,
    };
    let mut names: Vec<&str> = Vec::new();
    for modifier in modifiers {
        let name = match *modifier {
            "cmd" => "cmd",
            "ctrl" => "ctrl",
            "alt" => "opt",
            "shift" => "shift",
            _ => return None,
        };
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names.iter().any(|n| *n != "shift").then(|| json!({ "key": key, "modifiers": names }))
}

/// The shortcuts an op's catalog entry asks for.
pub(super) fn shortcuts(entry: &Value) -> Vec<Value> {
    entry
        .get("keyboard")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|k| k.get("key").and_then(Value::as_str))
        .filter_map(chord)
        .take(MAX_SHORTCUTS)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chords_with_command_control_or_option_are_shortcuts() {
        let entry = json!({ "keyboard": [
            { "key": "cmd+shift+k" },
            { "key": "alt+/", "when": "browserFocused" },
            { "key": "f", "when": "browserFocused" },
            { "key": "shift+f" },
            { "key": "cmd+enter" },
            { "key": "ctrl+space" },
            { "key": "cmd++" },
            { "key": "hyper+k" }
        ] });
        assert_eq!(
            shortcuts(&entry),
            vec![
                json!({ "key": "k", "modifiers": ["cmd", "shift"] }),
                json!({ "key": "/", "modifiers": ["opt"] }),
                json!({ "key": " ", "modifiers": ["ctrl"] }),
                json!({ "key": "+", "modifiers": ["cmd"] }),
            ]
        );
        assert!(shortcuts(&json!({ "palette": { "title": "Go" } })).is_empty());
    }
}
