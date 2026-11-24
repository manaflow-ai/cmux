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
    assert_eq!(decide(&f).outcome, Outcome::Confirmed);
    f.outside = Some(vec!["the pasteboard changed".into()]);
    f.signals = Some(Signals { elsewhere: 1, ..Signals::default() });
    let v = decide(&f);
    assert_eq!(v.outcome, Outcome::Confirmed);
    assert!(
        v.reason.contains("pasteboard") && v.reason.contains("a menu, a popover"),
        "{}",
        v.reason
    );
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
        assert!(v.reason.starts_with("something changed"), "{}", v.reason);
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
    assert!(v.reason.contains("already matched"), "{}", v.reason);
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
