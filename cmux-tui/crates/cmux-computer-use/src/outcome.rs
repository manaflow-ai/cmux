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

/// Everything the engine saw change, in a few words each: in and over the
/// window, and outside it (the app elsewhere, other processes, the
/// pasteboard). Signal kinds are not repeated: the result's `signals` has them.
fn seen(f: &Facts) -> (Vec<String>, Vec<String>) {
    let mut seen = Vec::new();
    let mut side = Vec::new();
    if let Some(c) = &f.changes {
        if c.get("pixels").and_then(Value::as_str) == Some("changed") {
            seen.push("pixels".to_string());
        }
        let elements = count(c, "added") + count(c, "changed") + count(c, "removed");
        if elements > 0 {
            seen.push(format!("{elements} elements"));
        }
        if count(c, "focus_moved") > 0 {
            seen.push("focus".into());
        }
        let windows = count(c, "windows_opened") + count(c, "windows_closed");
        if windows > 0 {
            seen.push(format!("{windows} windows over it (opened or closed)"));
        }
    }
    if let Some(s) = &f.signals {
        if s.in_window > 0 {
            seen.push("app signals".into());
        }
        if s.elsewhere > 0 {
            side.push("app signals outside the window (a menu, popover or other window)".into());
        }
    }
    if let Some(outside) = &f.outside {
        side.extend(outside.iter().cloned());
    }
    if f.menu {
        seen.push("a menu (opened, picked from or closed)".into());
    }
    (seen, side)
}

/// What kept the engine from knowing that nothing happened.
fn unknowns(f: &Facts) -> Vec<&'static str> {
    let mut unknown = Vec::new();
    if f.shows.is_none() {
        unknown.push("its effect may not show");
    }
    if f.settled_ms.is_none() {
        unknown.push("no settle wait");
    }
    match &f.changes {
        None => unknown.push("elements and pixels not compared"),
        Some(c) => {
            if c.get("pixels").and_then(Value::as_str) != Some("same") {
                unknown.push("pixels not compared");
            }
            if c.get("elements_read").and_then(Value::as_str) != Some("all") {
                unknown.push("not every element read");
            }
            // A first look has nothing to compare its elements with.
            if c.get("first_look") == Some(&Value::Bool(true))
                || ["added", "changed", "removed"].iter().any(|k| c.get(*k).is_none())
            {
                unknown.push("no earlier look to compare elements with");
            }
        }
    }
    if f.signals.is_none() {
        unknown.push("app signals not watched");
    }
    if f.outside.is_none() {
        unknown.push("other windows and the pasteboard not read");
    }
    if f.responsive != Some(true) {
        unknown.push("the app did not answer after the settle");
    }
    unknown
}

pub fn decide(f: &Facts) -> Verdict {
    let (mut seen, side) = seen(f);
    if f.evidence == "confirmed" {
        // `outcome` says it; the reason only names side effects (what
        // changed outside the window), else it is empty and left out.
        let reason = if side.is_empty() {
            String::new()
        } else {
            format!("also changed outside the window: {}", side.join(", "))
        };
        return Verdict { outcome: Outcome::Confirmed, reason };
    }
    seen.extend(side);
    if f.already {
        return Verdict {
            outcome: Outcome::Uncertain,
            reason: "already in that state before the action; nothing shows this action did it"
                .into(),
        };
    }
    if !seen.is_empty() {
        return Verdict {
            outcome: Outcome::Uncertain,
            reason: format!(
                "changed: {}; nothing reads back the intended effect: check before relying on it",
                seen.join(", ")
            ),
        };
    }
    let unknown = unknowns(f);
    if unknown.is_empty() {
        let ms = f.settled_ms.unwrap_or(0);
        return Verdict {
            outcome: Outcome::NoEffect,
            reason: format!("nothing changed anywhere watched within {ms} ms"),
        };
    }
    Verdict {
        outcome: Outcome::Uncertain,
        reason: format!(
            "nothing visible changed, but {}: check the state before relying on it",
            unknown.join("; ")
        ),
    }
}

/// Writes the verdict into an acting call's result body: `outcome`,
/// `outcome_reason` (left out when empty: a confirmed with no side effects),
/// the signals seen (`signals`, when any), and for
/// `no_effect` the older `evidence: no_visible_change` with its note.
pub fn attach(body: &mut Value, f: &Facts, verdict: &Verdict, note: impl FnOnce(u64) -> String) {
    body["outcome"] = json!(verdict.outcome.as_str());
    if verdict.reason.is_empty() {
        if let Some(o) = body.as_object_mut() {
            o.remove("outcome_reason");
        }
    } else {
        body["outcome_reason"] = json!(verdict.reason);
    }
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
mod tests {
    use super::*;

    fn quiet() -> Facts {
        Facts {
            evidence: "delivered".into(),
            shows: Some("text".into()),
            menu: false,
            settled_ms: Some(1000),
            changes: Some(json!({
                "pixels": "same", "elements_read": "all", "added": 0, "changed": 0,
                "removed": 0, "renumbered": 0, "focus_moved": false,
                "windows_opened": 0, "windows_closed": 0
            })),
            signals: Some(Signals::default()),
            outside: Some(vec![]),
            already: false,
            responsive: Some(true),
        }
    }

    #[test]
    fn nothing_changed_where_the_effect_must_show_is_no_effect() {
        let v = decide(&quiet());
        assert_eq!(v.outcome, Outcome::NoEffect, "{}", v.reason);
        assert!(v.reason.contains("within 1000 ms"));
    }

    #[test]
    fn a_read_back_is_confirmed_and_names_side_effects() {
        let mut f = quiet();
        f.evidence = "confirmed".into();
        let v = decide(&f);
        assert_eq!(v.outcome, Outcome::Confirmed);
        assert_eq!(v.reason, "", "the outcome says it");
        f.outside = Some(vec!["the pasteboard changed".into()]);
        f.signals = Some(Signals { elsewhere: 1, ..Signals::default() });
        let v = decide(&f);
        assert_eq!(v.outcome, Outcome::Confirmed);
        assert!(v.reason.contains("pasteboard") && v.reason.contains("popover"), "{}", v.reason);
    }

    /// Something changing is not the intended effect (a FP of the truth
    /// matrix: a press that did nothing while the app redrew).
    #[test]
    fn a_change_without_a_read_back_is_uncertain() {
        for change in [
            |f: &mut Facts| f.changes.as_mut().unwrap()["pixels"] = json!("changed"),
            |f: &mut Facts| f.changes.as_mut().unwrap()["changed"] = json!(2),
            |f: &mut Facts| f.changes.as_mut().unwrap()["focus_moved"] = json!(true),
            |f: &mut Facts| f.changes.as_mut().unwrap()["windows_opened"] = json!(1),
            |f: &mut Facts| f.signals = Some(Signals { in_window: 1, ..Signals::default() }),
            |f: &mut Facts| f.signals = Some(Signals { elsewhere: 1, ..Signals::default() }),
            |f: &mut Facts| f.outside = Some(vec!["1 window(s) opened on screen".into()]),
            |f: &mut Facts| f.menu = true,
        ] {
            let mut f = quiet();
            change(&mut f);
            let v = decide(&f);
            assert_eq!(v.outcome, Outcome::Uncertain, "{f:?}");
            assert!(v.reason.starts_with("changed: "), "{}", v.reason);
        }
    }

    /// The FNs of the truth matrix: a popover's button and a submenu's item
    /// act where the window shows nothing; never no_effect.
    #[test]
    fn an_effect_that_may_not_show_is_never_no_effect() {
        let mut f = quiet();
        f.shows = None;
        let v = decide(&f);
        assert_eq!(v.outcome, Outcome::Uncertain);
        assert!(v.reason.contains("may not show"), "{}", v.reason);
    }

    #[test]
    fn anything_unknown_is_uncertain() {
        for unknown in [
            |f: &mut Facts| f.settled_ms = None,
            |f: &mut Facts| f.changes = None,
            |f: &mut Facts| f.changes.as_mut().unwrap()["pixels"] = json!("unknown"),
            |f: &mut Facts| f.changes.as_mut().unwrap()["elements_read"] = json!("partial"),
            |f: &mut Facts| f.signals = None,
            |f: &mut Facts| f.outside = None,
            // Review (3): a first look has no element baseline.
            |f: &mut Facts| f.changes.as_mut().unwrap()["first_look"] = json!(true),
            |f: &mut Facts| {
                f.changes.as_mut().unwrap().as_object_mut().unwrap().remove("added");
            },
            // Review (10): a stalled app does nothing, so nothing shows.
            |f: &mut Facts| f.responsive = Some(false),
            |f: &mut Facts| f.responsive = None,
        ] {
            let mut f = quiet();
            unknown(&mut f);
            let v = decide(&f);
            assert_eq!(v.outcome, Outcome::Uncertain, "{f:?}");
            assert!(v.reason.starts_with("nothing visible changed, but"), "{}", v.reason);
        }
    }

    /// Review (8): an action whose state already matched (Command-A with
    /// everything selected, the caret already there) is not done by it.
    #[test]
    fn an_already_matching_state_is_uncertain() {
        let mut f = quiet();
        f.already = true;
        let v = decide(&f);
        assert_eq!(v.outcome, Outcome::Uncertain);
        assert!(v.reason.contains("already in that state"), "{}", v.reason);
    }

    #[test]
    fn attach_writes_the_outcome_and_keeps_the_older_marker_for_no_effect() {
        let f = quiet();
        let mut body = json!({"evidence": "delivered", "note": "n"});
        attach(&mut body, &f, &decide(&f), |ms| format!("no visible change within {ms} ms"));
        assert_eq!(body["outcome"], "no_effect");
        assert_eq!(body["evidence"], "no_visible_change");
        assert_eq!(body["note"], "n; no visible change within 1000 ms");
        let mut f = quiet();
        f.signals = Some(Signals { in_window: 2, ..Signals::default() });
        let mut body = json!({"evidence": "delivered"});
        attach(&mut body, &f, &decide(&f), |_| String::new());
        assert_eq!(body["outcome"], "uncertain");
        assert_eq!(body["evidence"], "delivered");
        assert_eq!(body["signals"]["in_window"], 2);
    }
}
