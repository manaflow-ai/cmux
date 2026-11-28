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
