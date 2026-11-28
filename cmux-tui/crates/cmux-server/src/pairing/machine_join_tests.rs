use super::*;

#[test]
fn each_api_joins_its_own_platform_and_an_unknown_api_none() {
    use cmux_cloud_environment as e;
    assert_eq!(platform_for(e::PRODUCTION_API), Some(e::PRODUCTION_PLATFORM));
    assert_eq!(platform_for(&format!("{}/", e::STAGING_API)), Some(e::STAGING_PLATFORM));
    assert_eq!(platform_for(e::DEVELOPMENT_API), Some(e::DEVELOPMENT_PLATFORM));
    assert_eq!(platform_for("https://example.com"), None);
    assert_eq!(
        redeem(
            &MachineJoin::for_tests(&format!("cmj_{}", "a".repeat(43)), 1),
            "https://example.com",
            "box"
        ),
        failed("server.pair.machine_join_unknown_api")
    );
}

#[test]
fn the_token_never_shows_in_debug() {
    let token = format!("cmj_{}", "s".repeat(43));
    let join = MachineJoin::for_tests(&token, 7);
    assert!(join.well_formed());
    assert!(!format!("{join:?}").contains(&token));
    assert!(!MachineJoin::for_tests("cmj_short", 7).well_formed());
    assert!(!MachineJoin::for_tests(&format!("cmm_{}", "a".repeat(43)), 7).well_formed());
}

#[test]
fn a_join_without_its_update_timer_says_why_and_nothing_else() {
    let stderr = "Existing Computer Use helpers may remain ungated until they exit\n\
        acpmux update timer: XDG_CONFIG_HOME is set, so systemd reads user units from there\n";
    assert_eq!(
        timer_note(stderr).as_deref(),
        Some("acpmux-update.timer: XDG_CONFIG_HOME is set, so systemd reads user units from there")
    );
    // Other stderr is no note; nor is a secret-shaped or overlong one.
    assert_eq!(timer_note("Existing Computer Use helpers may remain ungated\n"), None);
    assert_eq!(timer_note(""), None);
    assert_eq!(timer_note("acpmux update timer: cmm_secret\n"), None);
    assert_eq!(timer_note(&format!("acpmux update timer: {}\n", "x".repeat(400))), None);
}
