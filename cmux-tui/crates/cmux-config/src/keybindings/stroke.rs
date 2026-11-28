//! One keystroke of a binding in keybindings.json syntax (`cmd+shift+p`,
//! `ctrl+k`, `f5`): modifiers joined by `+`, then one key token. The
//! normalized form puts modifiers in the order cmd, shift, opt, ctrl and
//! names keys like the app's parser (`Shortcut` in CmuxNextSettings), so
//! the app reads every stroke this module accepts.

/// Key names the app understands besides one character and `f1`..`f20`.
const NAMED_KEYS: &[&str] = &[
    "left",
    "right",
    "up",
    "down",
    "tab",
    "return",
    "escape",
    "delete",
    "space",
    "home",
    "end",
    "pageup",
    "pagedown",
    "plus",
    "comma",
    "period",
    "slash",
    "backslash",
    "semicolon",
    "quote",
    "backtick",
    "minus",
    "leftbracket",
    "rightbracket",
];

/// Aliases of key names, mapped to the name in [`NAMED_KEYS`].
const KEY_ALIASES: &[(&str, &str)] = &[
    ("arrowleft", "left"),
    ("leftarrow", "left"),
    ("arrowright", "right"),
    ("rightarrow", "right"),
    ("arrowup", "up"),
    ("uparrow", "up"),
    ("arrowdown", "down"),
    ("downarrow", "down"),
    ("enter", "return"),
    ("esc", "escape"),
    ("backspace", "delete"),
    ("spacebar", "space"),
    ("dot", "period"),
    ("apostrophe", "quote"),
    ("grave", "backtick"),
    ("hyphen", "minus"),
    ("equals", "plus"),
    ("openbracket", "leftbracket"),
    ("closebracket", "rightbracket"),
];

/// `text` in normal form, or `None` when it is not one stroke.
pub fn normalize(text: &str) -> Option<String> {
    let text = text.trim();
    // `cmd++` is the plus key.
    let (modifiers_text, key) = match text.strip_suffix("++") {
        Some(head) => (head, "+"),
        None => match text.rsplit_once('+') {
            Some((head, key)) => (head, key),
            None => ("", text),
        },
    };
    let (mut cmd, mut shift, mut opt, mut ctrl) = (false, false, false, false);
    for token in modifiers_text.split('+').filter(|token| !token.is_empty()) {
        match token.to_ascii_lowercase().as_str() {
            "cmd" | "command" | "meta" | "⌘" => cmd = true,
            "shift" | "⇧" => shift = true,
            "opt" | "option" | "alt" | "⌥" => opt = true,
            "ctrl" | "control" | "ctl" | "⌃" => ctrl = true,
            _ => return None,
        }
    }
    let key = key_name(key)?;
    let mut parts: Vec<&str> = Vec::new();
    for (on, name) in [(cmd, "cmd"), (shift, "shift"), (opt, "opt"), (ctrl, "ctrl")] {
        if on {
            parts.push(name);
        }
    }
    let mut out = parts.join("+");
    if !out.is_empty() {
        out.push('+');
    }
    out.push_str(&key);
    Some(out)
}

fn key_name(token: &str) -> Option<String> {
    if token == "+" {
        return Some("plus".into());
    }
    let lower = token.to_lowercase();
    if NAMED_KEYS.contains(&lower.as_str()) {
        return Some(lower);
    }
    if let Some((_, name)) = KEY_ALIASES.iter().find(|(alias, _)| *alias == lower) {
        return Some((*name).into());
    }
    if let Some(number) = lower.strip_prefix('f').and_then(|digits| digits.parse::<u8>().ok())
        && (1..=20).contains(&number)
    {
        return Some(lower);
    }
    (lower.chars().count() == 1).then_some(lower)
}

/// Whether the stroke has Command or Control (only those start a binding).
pub fn has_command_or_control(stroke: &str) -> bool {
    stroke.split('+').any(|part| part == "cmd" || part == "ctrl") && stroke != "plus"
}
