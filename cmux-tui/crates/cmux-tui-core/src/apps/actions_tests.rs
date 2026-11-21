use super::*;

#[test]
fn agent_exemptions_bind_apps_and_everything_else_needs_a_gesture() {
    assert_eq!(decide(Some("palette.auth.signIn")), ActionDecision::Refused("credentials"));
    assert_eq!(decide(Some("quit")), ActionDecision::Refused("endsApp"));
    assert_eq!(decide(Some("keepMacAwake")), ActionDecision::Refused("systemChange"));
    assert_eq!(decide(Some("taskManager.killProcess")), ActionDecision::Refused("liveInput"));
    assert_eq!(decide(Some("newWindow")), ActionDecision::NeedsGesture);
    assert_eq!(decide(Some("openSettings")), ActionDecision::NeedsGesture);
    assert_eq!(decide(Some("made.up")), ActionDecision::Unknown);
    assert_eq!(decide(None), ActionDecision::Unknown);
}

/// The person's own cmux-next.json actions (`cmuxConfig.<name>`) are not in the catalog: only
/// the customize app (the person's own folder) may run them, with a gesture like any action.
#[test]
fn only_the_customize_app_runs_the_persons_own_config_actions() {
    assert_eq!(
        decide_for("local/customize", Some("cmuxConfig.tests")),
        ActionDecision::NeedsGesture
    );
    assert_eq!(decide_for("local/customize", Some("newWindow")), ActionDecision::NeedsGesture);
    assert_eq!(decide_for("local/customize", Some("quit")), ActionDecision::Refused("endsApp"));
    assert_eq!(decide_for("local/customize", Some("cmuxConfig.")), ActionDecision::Unknown);
    assert_eq!(decide_for("local/spy", Some("cmuxConfig.tests")), ActionDecision::Unknown);
    assert_eq!(decide_for("cmux/demo", Some("cmuxConfig.tests")), ActionDecision::Unknown);
}
