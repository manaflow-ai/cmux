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
fn agents_cmux_mcp_is_on_unless_the_file_says_off() {
    use super::AgentsCmuxMcp as Choice;
    assert_eq!(Choice::from_config_text(""), Choice::On);
    assert_eq!(Choice::from_config_text("{}"), Choice::On);
    assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": "ask"}}"#), Choice::On);
    assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": "on"}}"#), Choice::On);
    assert_eq!(Choice::from_config_text(r#"{"agents.cmuxMcp": "off"}"#), Choice::Off);
    assert_eq!(
        Choice::from_config_text("{\n  // no\n  \"agents\": {\"cmuxMcp\": \"off\",},\n}"),
        Choice::Off
    );
    assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": true}}"#), Choice::On);
    // Settings writes the nested key; an older flat value never outvotes its `off`.
    assert_eq!(
        Choice::from_config_text(r#"{"agents.cmuxMcp": "ask", "agents": {"cmuxMcp": "off"}}"#),
        Choice::Off
    );
    assert_eq!(
        Choice::from_config_text("\u{feff}{\"agents\": {\"cmuxMcp\": \"off\"}}"),
        Choice::Off,
        "a BOM reads as the settings owner reads it"
    );
    assert_eq!(
        Choice::from_config_text("{not json"),
        Choice::On,
        "only an explicit off turns it off"
    );
    assert!(Choice::On.injects() && !Choice::Off.injects());
    assert_eq!(
        Choice::from_config_file(std::path::Path::new("/nonexistent/cmux-next.json")),
        Choice::On
    );
}

#[test]
fn an_agent_switched_off_gets_no_cmux_tools_under_a_yes() {
    use super::AgentsCmuxMcp as Choice;
    let on = r#"{"agents": {"cmuxMcp": "on"}}"#;
    assert_eq!(Choice::from_config_text_for(on, "claude"), Choice::On, "no switch: on");
    let codex_off = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpCodex": false}}"#;
    assert_eq!(Choice::from_config_text_for(codex_off, "codex"), Choice::Off);
    assert_eq!(Choice::from_config_text_for(codex_off, "claude"), Choice::On);
    let flat = r#"{"agents.cmuxMcp": "on", "agents.cmuxMcpClaude": false}"#;
    assert_eq!(Choice::from_config_text_for(flat, "claude"), Choice::Off, "flat key");
    let kept = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpClaude": true}}"#;
    assert_eq!(Choice::from_config_text_for(kept, "claude"), Choice::On);
    let not_bool = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpClaude": "no"}}"#;
    assert_eq!(Choice::from_config_text_for(not_bool, "claude"), Choice::On, "only false");
    let unset = r#"{"agents": {"cmuxMcpClaude": false}}"#;
    assert_eq!(Choice::from_config_text_for(unset, "claude"), Choice::Off, "on by default");
    assert_eq!(Choice::from_config_text_for(unset, "codex"), Choice::On, "on by default");
    let no = r#"{"agents": {"cmuxMcp": "off", "cmuxMcpClaude": true}}"#;
    assert_eq!(Choice::from_config_text_for(no, "claude"), Choice::Off);
    assert_eq!(Choice::from_config_text_for(codex_off, "gemini"), Choice::On, "no switch");
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
fn tailnet_carrier_is_off_unless_direct_only_or_on_is_named() {
    use super::TailnetCarrier::{DirectOnly, Off, On};
    use super::tailnet_carrier_from_config_text as carrier;
    assert_eq!(carrier(""), Off);
    assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"direct-only"}}"#), DirectOnly);
    assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"on"}}"#), On);
    assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"bogus"}}"#), Off);
    assert_eq!(carrier("{not json"), Off);
}

#[test]
fn agent_share_idle_minutes_is_fifteen_unless_the_file_names_a_value_in_range() {
    use super::agent_share_idle_minutes_from_config_text as minutes;
    assert_eq!(minutes(""), 15);
    assert_eq!(minutes("{}"), 15);
    assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 5}}"#), 5);
    assert_eq!(minutes("{\n  // short\n  \"remote\": {\"agentShareIdleMinutes\": 240,},\n}"), 240);
    assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 0}}"#), 15, "below the range");
    assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 241}}"#), 15, "above it");
    assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": "5"}}"#), 15, "not a number");
    assert_eq!(minutes("{not json"), 15);
    assert_eq!(super::agent_share_idle_minutes(), 15, "unit tests never read the developer's file");
}

#[test]
fn auto_cloud_is_the_files_boolean_flat_or_nested_and_false_wins() {
    use super::auto_cloud_from_config_text as auto_cloud;
    assert_eq!(auto_cloud(""), None);
    assert_eq!(auto_cloud("{}"), None);
    assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": true}}"#), Some(true));
    assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": false}}"#), Some(false));
    assert_eq!(auto_cloud(r#"{"cloud.autoCloud": true}"#), Some(true), "flat key");
    assert_eq!(
        auto_cloud("{\n  // AutoCloud\n  \"cloud\": {\"autoCloud\": true,},\n}"),
        Some(true)
    );
    assert_eq!(auto_cloud("\u{feff}{\"cloud\": {\"autoCloud\": true}}"), Some(true), "a BOM");
    assert_eq!(
        auto_cloud(r#"{"cloud.autoCloud": true, "cloud": {"autoCloud": false}}"#),
        Some(false),
        "a false in either form wins"
    );
    assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": "yes"}}"#), None, "not a boolean");
    assert_eq!(auto_cloud(r#"{"cloud": {"plan": "pro"}}"#), None);
    assert_eq!(auto_cloud("{not json"), None);
    assert_eq!(super::auto_cloud(), None, "unit tests never read the developer's file");
}

#[test]
fn auto_cloud_reads_the_file_again_at_each_call() {
    use super::auto_cloud_from_config_file as read;
    let path = std::env::temp_dir().join(format!("cmux-auto-cloud-{}.json", std::process::id()));
    std::fs::write(&path, r#"{"cloud": {"autoCloud": true}}"#).unwrap();
    assert_eq!(read(&path), Some(true));
    std::fs::write(&path, r#"{"cloud": {"autoCloud": false}}"#).unwrap();
    assert_eq!(read(&path), Some(false));
    std::fs::remove_file(&path).unwrap();
    assert_eq!(read(&path), None, "no file: no value");
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
