//! Seeded secrets on the wire (cmux_egress::capture) through the headless route's exec client:
//! the person's cmux credential rides only in `Authorization` and the team only in `x-cmux-team`.
//! tests/egress_seeded.json names this test for `cmux_tui::cli::cloud_start_chat::direct`.

use super::*;

#[test]
fn seeded_secrets_ride_only_where_the_cmux_api_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "SEEDdirectCredential-9e27";
    let team = "SEEDdirectTeam-14d0";
    let env = |key: &str| match key {
        "CMUX_CLOUD_API_URL" => Some(cmux_cloud_environment::PRODUCTION_API.to_owned()),
        "CMUX_CLOUD_ACCESS_TOKEN" => Some(credential.to_owned()),
        "CMUX_CLOUD_TEAM" => Some(team.to_owned()),
        _ => None,
    };
    let mut api = Api::from_env(env).unwrap();
    // The capture server answers `200 {}`: the session mint reads no session and the exec ends.
    let _ = api.exec("vm_seeded", "true", 1_000);
    let sent = cmux_egress::capture::requests_to("cloud-api.cmux.dev");
    assert!(!sent.is_empty(), "the mint reached the capture server");
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(
        places.iter().all(|p| p.ends_with(": header x-cmux-team") || p.ends_with(": target")),
        "{places:?}"
    );
}
