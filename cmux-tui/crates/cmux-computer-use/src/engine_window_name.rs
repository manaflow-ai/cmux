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
    #[allow(
        clippy::indexing_slicing,
        reason = "serde_json assignment creates the requested window_id path"
    )]
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
#[path = "engine_window_name_tests.rs"]
mod tests;
