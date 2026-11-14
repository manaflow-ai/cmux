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
