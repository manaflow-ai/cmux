//! The outcome of an acting call: `confirmed`, `no_effect` or `uncertain`,
//! with the reason, decided from what the engine saw ([`Facts`]).
//!
//! - `confirmed` only on positive evidence of the intended effect: the target
//!   reads it back (the route's own `confirmed`). Something else changing is
//!   not that evidence (an app redraws, a clock ticks, a click can do the
//!   wrong thing), so it stays `uncertain`, with what changed.
//! - `no_effect` only when the effect must show where the engine looked
//!   ([`crate::desktop::ActionOutcome::shows`]) and nothing changed there or
//!   anywhere it could tell: through a real settle wait the window's pixels
//!   stayed the same, every element was read and none changed, no window
//!   opened or closed on screen (any process), the pasteboard and the front
//!   app stayed, and the app sent no accessibility signal.
//! - `uncertain` otherwise, saying what was seen or what could not be known.
//!   Never `no_effect` for an effect that may not show (a button, a menu item,
//!   a chord, a click on a canvas) or that could be in a popover, a submenu,
//!   another window or another process unwatched.

use serde_json::{Value, json};

use crate::desktop::Signals;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Confirmed,
    NoEffect,
    Uncertain,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Confirmed => "confirmed",
            Outcome::NoEffect => "no_effect",
            Outcome::Uncertain => "uncertain",
        }
    }
}

/// What the engine knows about one acting call after it settled.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    /// The route's evidence (`confirmed`, `delivered`).
    pub evidence: String,
    /// Where the intended effect must show (`None`: it may not show).
    pub shows: Option<String>,
    /// The result reports a menu it opened, picked from or closed.
    pub menu: bool,
    /// Some(ms): an adaptive settle wait ran for ms (one capture or more);
    /// None: no real settle wait. no_effect also needs the window unchanged
    /// (`changes.pixels` "same"), which takes a second capture.
    pub settled_ms: Option<u64>,
    /// The state's `changes` evidence (pixels, elements, windows).
    pub changes: Option<Value>,
    /// The app's accessibility signals through the action and the settle;
    /// None: nobody listened.
    pub signals: Option<Signals>,
    /// What changed outside the window (windows of any process, the
    /// pasteboard, the front app); None: unknown.
    pub outside: Option<Vec<String>>,
    /// The state already matched before the action (the route's read-back).
    pub already: bool,
    /// The app answered an accessibility request after the settle; None:
    /// not asked.
    pub responsive: Option<bool>,
}

/// Appends `add` to a `; `-separated note.
pub fn append(note: &mut String, add: &str) {
    if !note.is_empty() {
        note.push_str("; ");
    }
    note.push_str(add);
}

#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub outcome: Outcome,
    pub reason: String,
}

fn count(changes: &Value, key: &str) -> u64 {
    match changes.get(key) {
        Some(Value::Bool(b)) => u64::from(*b),
        Some(v) => v.as_u64().unwrap_or(0),
        None => 0,
    }
}

fn kinds(s: &Signals) -> String {
    s.kinds.iter().map(|(k, n)| format!("{k} x{n}")).collect::<Vec<_>>().join(", ")
}

/// Everything the engine saw change, in words: in and over the window, and
/// outside it (the app elsewhere, other processes, the pasteboard).
fn seen(f: &Facts) -> (Vec<String>, Vec<String>) {
    let mut seen = Vec::new();
    let mut side = Vec::new();
    if let Some(c) = &f.changes {
        if c.get("pixels").and_then(Value::as_str) == Some("changed") {
            seen.push("the window's pixels changed".to_string());
        }
        let elements = count(c, "added") + count(c, "changed") + count(c, "removed");
        if elements > 0 {
            seen.push(format!("{elements} of its elements changed"));
        }
        if count(c, "focus_moved") > 0 {
            seen.push("its keyboard focus moved".into());
        }
        let windows = count(c, "windows_opened") + count(c, "windows_closed");
        if windows > 0 {
            seen.push(format!("{windows} window(s) over it opened or closed"));
        }
    }
    if let Some(s) = &f.signals {
        if s.in_window > 0 {
            seen.push(format!("the app reported {} change(s) in the window", s.in_window));
        }
        if s.elsewhere > 0 {
            side.push(format!(
                "the app reported {} change(s) outside the window (a menu, a popover, another window)",
                s.elsewhere
            ));
        }
        if s.total() > 0 {
            seen.push(format!("signals: {}", kinds(s)));
        }
    }
    if let Some(outside) = &f.outside {
        side.extend(outside.iter().cloned());
    }
    if f.menu {
        seen.push("a menu opened, was picked from or closed".into());
    }
    (seen, side)
}

/// What kept the engine from knowing that nothing happened.
fn unknowns(f: &Facts) -> Vec<&'static str> {
    let mut unknown = Vec::new();
    if f.shows.is_none() {
        unknown.push(
            "this action's effect may not show anywhere the engine can look (a button, a menu item, a key chord or a click on drawn content can act invisibly)",
        );
    }
    if f.settled_ms.is_none() {
        unknown.push("the window was not watched through a settle wait");
    }
    match &f.changes {
        None => unknown.push("the window's elements and pixels were not compared"),
        Some(c) => {
            if c.get("pixels").and_then(Value::as_str) != Some("same") {
                unknown.push("its pixels were not compared with a screenshot from before");
            }
            if c.get("elements_read").and_then(Value::as_str) != Some("all") {
                unknown.push("not every element of the window was read");
            }
            // A first look has nothing to compare its elements with.
            if c.get("first_look") == Some(&Value::Bool(true))
                || ["added", "changed", "removed"].iter().any(|k| c.get(*k).is_none())
            {
                unknown.push("there was no earlier look at the window's elements to compare with");
            }
        }
    }
    if f.signals.is_none() {
        unknown.push("the app's accessibility signals could not be watched");
    }
    if f.outside.is_none() {
        unknown.push("windows of other processes and the pasteboard could not be read");
    }
    if f.responsive != Some(true) {
        unknown.push("the app did not answer an accessibility request after the settle");
    }
    unknown
}

pub fn decide(f: &Facts) -> Verdict {
    let (mut seen, side) = seen(f);
    if f.evidence == "confirmed" {
        let mut reason = "the target reads back the intended effect".to_string();
        // Side effects: what changed outside the window.
        if !side.is_empty() {
            reason.push_str("; also changed outside the window: ");
            reason.push_str(&side.join("; "));
        }
        return Verdict { outcome: Outcome::Confirmed, reason };
    }
    seen.extend(side);
    if f.already {
        return Verdict {
            outcome: Outcome::Uncertain,
            reason: "the state already matched before the action, so nothing had to change and nothing shows it was done".into(),
        };
    }
    if !seen.is_empty() {
        return Verdict {
            outcome: Outcome::Uncertain,
            reason: format!(
                "something changed ({}), but nothing reads back that it is the intended effect: check the state before relying on it",
                seen.join("; ")
            ),
        };
    }
    let unknown = unknowns(f);
    if unknown.is_empty() {
        let ms = f.settled_ms.unwrap_or(0);
        return Verdict {
            outcome: Outcome::NoEffect,
            reason: format!(
                "nothing changed within {ms} ms: the window's pixels and elements stayed the same, no window opened or closed, the pasteboard and the front app stayed, and the app reported no change"
            ),
        };
    }
    Verdict {
        outcome: Outcome::Uncertain,
        reason: format!("nothing visible changed, but {}", unknown.join("; ")),
    }
}

/// Writes the verdict into an acting call's result body: `outcome`,
/// `outcome_reason`, the signals seen (`signals`, when any), and for
/// `no_effect` the older `evidence: no_visible_change` with its note.
pub fn attach(body: &mut Value, f: &Facts, verdict: &Verdict, note: impl FnOnce(u64) -> String) {
    body["outcome"] = json!(verdict.outcome.as_str());
    body["outcome_reason"] = json!(verdict.reason);
    if let Some(s) = f.signals.as_ref().filter(|s| s.total() > 0) {
        body["signals"] = serde_json::to_value(s).unwrap_or(Value::Null);
    }
    if verdict.outcome == Outcome::NoEffect {
        body["evidence"] = json!("no_visible_change");
        let note = note(f.settled_ms.unwrap_or(0));
        let note = match body.get("note").and_then(Value::as_str) {
            Some(n) if !n.is_empty() => format!("{n}; {note}"),
            _ => note,
        };
        body["note"] = json!(note);
    }
}

#[cfg(test)]
#[path = "outcome_tests.rs"]
mod tests;
