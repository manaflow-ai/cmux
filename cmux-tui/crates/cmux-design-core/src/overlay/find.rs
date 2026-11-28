//! The find pill's pure rules (CmuxNextDesign/FindPill/FindPillView.swift).

/// `FindPillView.shouldForwardArrowKeyDown`: an arrow key (123...126) with no marked text and
/// at most Shift with Option or Command goes to the pill's field editor. Flags are
/// `NSEvent.ModifierFlags` names (`"shift"`, `"option"`, `"command"`, `"control"`, ...);
/// `numericPad`, `function` and `capsLock` never count.
pub fn should_forward_arrow(key_code: u16, flags: &[String], has_marked_text: bool) -> bool {
    if has_marked_text || !(123..=126).contains(&key_code) {
        return false;
    }
    let mut option = false;
    let mut command = false;
    for flag in flags {
        match flag.as_str() {
            "option" => option = true,
            "command" => command = true,
            "shift" | "numericPad" | "function" | "capsLock" => {}
            _ => return false,
        }
    }
    !(option && command)
}

/// `showCount(_:noMatches:canStep:)`'s chevrons: the caller's say, else enabled exactly when
/// there is a count and something matched.
pub fn steps_enabled(text: &str, no_matches: bool, can_step: Option<bool>) -> bool {
    can_step.unwrap_or(!text.is_empty() && !no_matches)
}
