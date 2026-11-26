//! Seeded secrets through the link sync store client, on the wire (cmux_egress::capture): the
//! store credential rides only in `Authorization`, on the missing-blobs query and on each blob
//! upload, never in a path or body. tests/egress_seeded.json names this test for the
//! `cmux_tui::link::sync_cli::store` gate site.

use cmux_egress::capture;

use super::{Client, Config};

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_store_credential_rides_only_in_authorization() {
    capture::install().unwrap();
    cmux_build_space::init_process(Ok(None));
    let credential = "SEEDsyncStoreCredential-e5c9";
    let client = Client::new(&Config {
        origin: format!("https://{HOST}/seeded-store/"),
        credential: credential.to_owned(),
    })
    .unwrap();
    let sha = "cd".repeat(32);
    // The capture server answers `200 {}`: no `missing` list, so this is an error, after one call.
    let _ = client.missing(std::slice::from_ref(&sha));
    let _ = client.put_blobs(vec![(sha, b"seeded blob".to_vec())]);
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-store/"))
        .collect();
    assert_eq!(sent.len(), 2, "{sent:?}");
    let places = capture::leaks(credential);
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}
