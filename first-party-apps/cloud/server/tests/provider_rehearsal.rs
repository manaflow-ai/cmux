mod wire_common;

use cmux_cloud::{Request, Server};
use serde_json::{Value, json};
use wire_common::WireFake;

#[test]
fn rehearsal_is_local_even_signed_out_and_matches_the_preview() {
    let fixtures: Value = serde_json::from_str(include_str!(
        "../../../../webviews/src/pages/cloud/providerRehearsal.fixtures.json"
    ))
    .unwrap();
    let mut fake = WireFake::load();
    fake.signed_in = false;
    let mut server = Server::new(fake);
    for scenario in ["lifecycle", "enrollment_failure", "cleanup_failure"] {
        let request = Request::new(
            "cmux.cloud.provider.rehearse",
            json!({"enabled":true,"scenario":scenario}),
        );
        assert_eq!(server.handle(&request).unwrap(), fixtures[scenario]);
        assert!(server.handle(&request.key("not-a-mutation")).is_err());
    }
    assert!(server.handle(&Request::new("cloud.provider.rehearse", json!({}))).is_err());
    assert!(server.control_plane().calls.is_empty(), "a rehearsal must never reach the backend");
}
