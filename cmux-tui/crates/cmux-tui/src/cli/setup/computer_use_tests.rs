use super::*;

#[test]
fn a_failed_helper_offers_restart_instead_of_waiting() {
    let step = next_step(&json!({"phase": "failed", "accessibility": null,
                                "screen_recording": null}))
    .expect("restart step");
    assert_eq!(step["kind"], "app");
    assert_eq!(step["command"], "cmux action run palette.computerUse.restart");
    let text = step["text"].as_str().unwrap();
    assert!(text.contains("did not respond"));
    assert!(text.contains("Settings > Agents"));
}

/// A missing grant names the app System Settings lists (the helper, not cmux) and its list,
/// Accessibility first, then Screen Recording once Accessibility is on.
#[test]
fn a_missing_grant_names_the_helper_app_to_turn_on() {
    let status = json!({"phase": "ready", "accessibility": false, "screen_recording": false,
                        "helper": "cmux NIGHTLY Helper"});
    let step = next_step(&status).expect("a grant is missing");
    assert_eq!(step["kind"], "grant");
    assert_eq!(step["pane"], "accessibility");
    assert_eq!(step["helper"], "cmux NIGHTLY Helper");
    let text = step["text"].as_str().unwrap_or_default();
    assert!(text.contains("Accessibility, turn on \u{201c}cmux NIGHTLY Helper\u{201d}"), "{text}");
    assert!(text.contains("Set Up Computer Use"), "{text}");
    assert!(!text.contains("Allow cmux Computer Use"), "{text}");

    let status = json!({"phase": "ready", "accessibility": true, "screen_recording": false,
                        "helper": "cmux NIGHTLY Helper"});
    let step = next_step(&status).expect("screen recording is missing");
    assert_eq!(step["pane"], "screen_recording");
    assert!(step["url"].as_str().unwrap_or_default().ends_with("Privacy_ScreenCapture"));

    let ready = json!({"phase": "ready", "accessibility": true, "screen_recording": true});
    assert!(next_step(&ready).is_none());
}

/// An app that names no helper still gets a step that says what to look for.
#[test]
fn a_status_without_a_helper_name_says_the_cmux_helper() {
    assert_eq!(helper_name(&json!({"helper": null})), "the cmux Computer Use helper");
    assert_eq!(helper_name(&json!({"helper": "  "})), "the cmux Computer Use helper");
    assert_eq!(helper_name(&json!({"helper": "cmux DEV Helper"})), "cmux DEV Helper");
}
