//! Seeded secrets through `cmux machine`'s platform client, on the wire
//! (cmux_egress::capture): the credential rides only in `Authorization`, never in a path or
//! body, and the team only in `x-cmux-team`. tests/egress_seeded.json names this test for the
//! `cmux_tui::cli::machine_join` gate site.

use std::time::Duration;

use cmux_egress::capture;
use serde_json::json;

use super::Platform;

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_machine_credential_rides_only_in_authorization() {
    capture::install().unwrap();
    cmux_build_space::init_process(Ok(None));
    let credential = "SEEDmachineJoinCredential-80f4";
    let platform = Platform::new(
        format!("https://{HOST}/seeded-join"),
        credential.to_owned(),
        Duration::from_secs(10),
    )
    .unwrap_or_else(|_| panic!("the platform client builds"))
    .with_team(Some("team_seeded".into()));
    let _ = platform.post("/v1/machines/join-tokens", json!({"name": "seeded-box"}));
    let _ = platform.delete("/v1/machines/vm_seeded");
    let _ = platform.credentials();
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-join/"))
        .collect();
    assert_eq!(sent.len(), 3, "{sent:?}");
    let places = capture::leaks(credential);
    assert_eq!(places.len(), 3, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}
