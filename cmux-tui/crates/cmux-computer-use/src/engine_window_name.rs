//! A `window_id` given as the window's title or its app's name.
//!
//! An agent told "in the CU Eval Form window, ..." otherwise spends a whole
//! model turn on `list_windows` only to learn the id it passes next (the
//! Computer Use suite's streams on 2026-11-22: every task opened with
//! `list_windows` then `get_ui_tree`, and model turns were 69% of wall time).
//! So every window-scoped tool also takes the title or the app's name, and the
//! engine turns it into the id before anything reads it.
//!
//! Only a value that is not shaped like an id is looked up: ids are digits
//! (macOS CGWindowID, X11, an HWND) or `prefix:rest` with no whitespace
//! (`a11y:`, `sway:`, `hypr:`, `tl:`), so an id call costs nothing more. The
//! match, in order: a window's id; its whole title, any case; its app's id or
//! name, any case; part of its title, any case. The first rule with a single
//! match wins; several matches under a rule are refused with the matches, so
//! two windows alike are never guessed between, and no match is refused with
//! every window, the answer `list_windows` would have given.

use std::collections::HashMap;

use serde_json::{Value, json};

use super::{Engine, ToolOutput, args_str};
use crate::desktop::Window;

/// Whether `given` reads as a window id rather than a title or app name.
pub(super) fn looks_like_window_id(given: &str) -> bool {
    if given.is_empty() || given.chars().any(char::is_whitespace) {
        return false;
    }
    if given.bytes().all(|b| b.is_ascii_digit()) {
        return true;
    }
    match given.split_once(':') {
        Some((prefix, rest)) => {
            !prefix.is_empty()
                && prefix.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
                && !rest.is_empty()
        }
        None => false,
    }
}

/// The one window `given` names among `windows` (front to back), or the
/// refusal that lists the candidates. `names` maps a lowercased app id to the
/// app's display name.
pub(super) fn pick<'a>(
    windows: &'a [Window],
    names: &HashMap<String, String>,
    given: &str,
) -> Result<&'a Window, ToolOutput> {
    let want = given.trim().to_lowercase();
    let app_name = |w: &Window| names.get(&w.app_id.to_ascii_lowercase()).map(|n| n.to_lowercase());
    let rules: [&dyn Fn(&Window) -> bool; 4] = [
        &|w| w.id == given,
        &|w| w.title.to_lowercase() == want,
        &|w| w.app_id.to_lowercase() == want || app_name(w).is_some_and(|n| n == want),
        &|w| !want.is_empty() && w.title.to_lowercase().contains(&want),
    ];
    for rule in rules {
        let hits: Vec<&Window> = windows.iter().filter(|w| rule(w)).collect();
        match hits.as_slice() {
            [] => continue,
            [one] => return Ok(one),
            many => {
                return Err(ToolOutput::error(
                    "target_ambiguous",
                    format!(
                        "{} windows match {given:?}; pass one window_id:\n{}",
                        many.len(),
                        listing(many.iter().copied(), names)
                    ),
                ));
            }
        }
    }
    Err(ToolOutput::error(
        "target_not_found",
        format!(
            "no window has the id, title or app {given:?}; the windows, front to back:\n{}",
            listing(windows.iter(), names)
        ),
    ))
}

fn listing<'a>(
    windows: impl Iterator<Item = &'a Window>,
    names: &HashMap<String, String>,
) -> String {
    windows
        .take(30)
        .map(|w| {
            let app = names.get(&w.app_id.to_ascii_lowercase()).unwrap_or(&w.app_id);
            format!("{}  {}  {:?}", w.id, app, w.title)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

impl Engine {
    /// `args` with a `window_id` given by title or app name replaced by the
    /// window's id; None when there is nothing to replace.
    pub(super) fn window_by_name(&self, args: &Value) -> Result<Option<Value>, ToolOutput> {
        let Some(given) = args_str(args, "window_id") else { return Ok(None) };
        if looks_like_window_id(given) {
            return Ok(None);
        }
        let windows = self.windows()?;
        let id = pick(&windows, &self.app_names(), given)?.id.clone();
        let mut out = args.clone();
        out["window_id"] = json!(id);
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
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
            out.contains("target_ambiguous")
                && out.contains("Invoice A")
                && out.contains("Invoice B"),
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
}
