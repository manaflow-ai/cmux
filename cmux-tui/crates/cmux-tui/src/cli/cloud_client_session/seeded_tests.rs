//! Seeded secrets through `cmux vm access`'s client-session mint, on the wire
//! (cmux_egress::capture): the cmux credential rides only in `Authorization`, never in the
//! route, query or body, and is never printed. tests/egress_seeded.json names this test for
//! the `cmux_tui::cli::cloud_client_session` gate site.

use cmux_egress::capture;

use super::*;

const HOST: &str = "cloud-api.cmux.dev";
const VM: &str = "vm_seededclientsess0001";

#[test]
fn the_credential_rides_only_in_authorization() {
    capture::install().unwrap();
    cmux_build_space::init_process(Ok(None));
    let credential = "SEEDclientSessionCredential-2a71";
    let words: Vec<String> = ["create", "--target", VM, "--team", "team_seeded"]
        .iter()
        .map(|w| (*w).to_owned())
        .collect();
    let command = parse(&words).unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    // The capture server answers `200 {}`, which holds no session: the mint is refused after
    // its one request.
    let _ =
        run(&command, &format!("https://{HOST}"), credential, OutputMode::Json, &mut out, &mut err);
    let sent: Vec<_> =
        capture::requests_to(HOST).into_iter().filter(|r| r.target.contains(VM)).collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    let places = capture::leaks(credential);
    assert_eq!(places, [format!("{HOST} POST {}: header authorization", sent[0].target)]);
    for printed in [&out, &err] {
        assert!(!String::from_utf8_lossy(printed).contains(credential));
    }
}
