use super::NewWorkspacePlacement as Placement;
use super::resume_agents_from_config_text as resume_agents;

#[test]
fn agents_resume_after_restart_unless_the_file_says_no() {
    assert!(resume_agents(""));
    assert!(resume_agents("{}"));
    assert!(resume_agents(r#"{"sessions": {"resumeAgents": true}}"#));
    assert!(!resume_agents("{\n  // off\n  \"sessions\": {\"resumeAgents\": false,},\n}"));
    assert!(!resume_agents(r#"{"sessions": {"resumeAgents": "yes"}}"#), "not a boolean");
    assert!(!resume_agents("{not json"), "an unreadable file never runs a resume");
}

#[test]
fn ultra_is_auto_unless_the_file_says_otherwise() {
    use super::UltraConnection::{Always, Auto, Off};
    use super::ultra_from_config_text as ultra;
    assert_eq!(ultra(""), Auto);
    assert_eq!(ultra("{}"), Auto);
    assert_eq!(ultra(r#"{"remote": {"endSharingOnQuit": true}}"#), Auto);
    assert_eq!(ultra(r#"{"remote": {"ultra": "off"}}"#), Off);
    assert_eq!(ultra(r#"{"remote": {"ultra": "always"}}"#), Always);
    assert_eq!(
        ultra("{\n  // lossy hotel Wi-Fi\n  \"remote\": {\"ultra\": \"always\",},\n}"),
        Always
    );
    assert_eq!(ultra(r#"{"remote": {"ultra": "auto", "ultraMode": true}}"#), Auto);
    assert_eq!(ultra(r#"{"remote": {"ultraMode": true}}"#), Always, "the retired toggle on");
    assert_eq!(ultra(r#"{"remote": {"ultraMode": false}}"#), Auto, "and off: Auto");
    assert_eq!(ultra(r#"{"remote": {"ultra": true}}"#), Auto, "not a choice");
    assert_eq!(ultra("{not json"), Auto);
    assert_eq!(super::ultra(), Auto, "unit tests never read the developer's file");
}

#[test]
fn new_placement_reads_cmux_json_with_the_app_default() {
    assert_eq!(Placement::from_config_text(""), Placement::Top);
    assert_eq!(Placement::from_config_text("{}"), Placement::Top);
    assert_eq!(
        Placement::from_config_text(r#"{"workspaces": {"newPlacement": "top"}}"#),
        Placement::Top
    );
    assert_eq!(
        Placement::from_config_text(
            "{\n  // order\n  \"workspaces\": {\"newPlacement\": \"bottom\",},\n}"
        ),
        Placement::Bottom
    );
    assert_eq!(
        Placement::from_config_text(r#"{"workspaces": {"newPlacement": "afterCurrent"}}"#),
        Placement::AfterCurrent
    );
    assert_eq!(
        Placement::from_config_text(r#"{"workspaces": {"newPlacement": "sideways"}}"#),
        Placement::Top
    );
    assert_eq!(Placement::from_config_text("{not json"), Placement::Top);
}

#[test]
fn a_scoped_placement_wins_and_nests() {
    assert_eq!(Placement::current(), Placement::Top);
    let outer = Placement::Bottom.set_for_test();
    Placement::AfterCurrent.scoped(|| assert_eq!(Placement::current(), Placement::AfterCurrent));
    assert_eq!(Placement::current(), Placement::Bottom);
    drop(outer);
    assert_eq!(Placement::current(), Placement::Top);
}

#[test]
fn a_changed_settings_file_is_read_again() {
    let path = std::env::temp_dir().join(format!("cmux-new-placement-{}.json", std::process::id()));
    std::fs::write(&path, r#"{"workspaces": {"newPlacement": "bottom"}}"#).unwrap();
    assert_eq!(Placement::from_config_file(&path), Placement::Bottom);
    std::fs::write(&path, r#"{"workspaces": {"newPlacement": "afterCurrent", "x": 1}}"#).unwrap();
    assert_eq!(Placement::from_config_file(&path), Placement::AfterCurrent);
    std::fs::remove_file(&path).unwrap();
    assert_eq!(Placement::from_config_file(&path), Placement::Top);
    assert_eq!(
        Placement::from_config_file(&std::env::temp_dir()),
        Placement::Top,
        "a directory is not read"
    );
}
