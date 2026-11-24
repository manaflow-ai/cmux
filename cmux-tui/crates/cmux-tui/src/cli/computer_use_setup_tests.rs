use super::*;

fn grant_report() -> Value {
    json!({
        "state": "needs_user",
        "before": {"phase": "ready", "accessibility": false, "screen_recording": false,
                   "helper": "cmux NIGHTLY Helper"},
        "after": {"phase": "ready", "accessibility": false, "screen_recording": false,
                  "helper": "cmux NIGHTLY Helper"},
        "user_action": {
            "kind": "grant",
            "text": "In System Settings > Privacy & Security > Accessibility, turn on \u{201c}cmux NIGHTLY Helper\u{201d}",
            "pane": "accessibility",
        },
    })
}

/// A missing grant opens the window; anything else (off, waiting, policy, ready) does not.
#[test]
fn only_a_missing_grant_opens_the_window() {
    assert!(opens_window(&grant_report()));
    for kind in ["approval", "wait", "policy", "app", "declined"] {
        let report = json!({"state": "needs_user", "user_action": {"kind": kind}});
        assert!(!opens_window(&report), "{kind}");
    }
    assert!(!opens_window(&json!({"state": "ok", "user_action": null})));
}

/// Ready means on and answered with both grants (setup reports ok or changed).
#[test]
fn ready_is_ok_or_changed_with_a_ready_phase() {
    let ready =
        |state: &str, phase: &str| is_ready(&json!({"state": state, "after": {"phase": phase}}));
    assert!(ready("ok", "ready"));
    assert!(ready("changed", "ready"));
    assert!(!ready("needs_user", "ready"));
    assert!(!ready("ok", "starting"));
    assert!(!ready("planned", "off"));
}

/// The person reads that the window is open, which app to turn on, and what macOS will ask.
#[test]
fn a_missing_grant_reads_as_the_next_step_with_the_helper_named() {
    let mut report = grant_report();
    report.set("window", json!("opened"));
    let text = human(&report);
    assert!(text.starts_with("Set Up Computer Use is open in cmux.\n"), "{text}");
    assert!(text.contains("turn on \u{201c}cmux NIGHTLY Helper\u{201d}"), "{text}");
    assert!(text.contains("Quit & Reopen, choose Later"), "{text}");
}

/// Once ready, the quick test's checks are listed, and a failed one says how to fix it.
#[test]
fn the_quick_test_lists_each_check() {
    let mut report =
        json!({"state": "ok", "after": {"phase": "ready", "helper": "cmux DEV Helper"}});
    report.set("test", json!({"ok": true, "checks": [
        {"name": "screen_capture", "ok": true, "detail": "Screen Recording: granted", "fix": null},
        {"name": "input", "ok": true, "detail": "input events: granted", "fix": null},
    ]}));
    let text = human(&report);
    assert!(
        text.starts_with(
            "Computer Use is ready.\ncmux DEV Helper has Accessibility and Screen Recording"
        ),
        "{text}"
    );
    assert!(text.contains("Quick test passed:\n  ok   Screen Recording: granted\n"), "{text}");

    report.set(
        "test",
        json!({"ok": false, "checks": [
            {"name": "displays", "ok": false, "detail": "no display", "fix": "Unlock the screen."},
        ]}),
    );
    let text = human(&report);
    assert!(text.starts_with("Computer Use is on, but the quick test failed:"), "{text}");
    assert!(text.contains("  FAIL no display\n       fix: Unlock the screen.\n"), "{text}");
}

/// `setup` takes its three flags and refuses anything else.
#[test]
fn setup_parses_its_flags() {
    use super::super::{Request, parse};
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        parse(&words(&["setup"])),
        Ok(Request::Setup { dry_run: false, window: true, json: false })
    );
    assert_eq!(
        parse(&words(&["setup", "--dry-run", "--no-window", "--json"])),
        Ok(Request::Setup { dry_run: true, window: false, json: true })
    );
    assert!(parse(&words(&["setup", "--machine", "m"])).is_err());
}
