//! Seeded secrets through the blob fetcher, on the wire (cmux_egress::capture): the store
//! grant rides only in `Authorization`, never in the blob URL. tests/egress_seeded.json names
//! this test for the `cmux_tui_core::blob_fetch` gate site.

use cmux_egress::capture;

use super::{Store, fetch_blob};

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_store_grant_rides_only_in_authorization() {
    capture::install().unwrap();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let grant = "SEEDblobFetchGrant-7e31";
    let store = Store { origin: format!("https://{HOST}/seeded-blob"), grant: grant.to_owned() };
    let sha = "ab".repeat(32);
    runtime.block_on(async {
        let client = cmux_egress::client_builder("cmux_tui_core::blob_fetch")
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        // The capture server answers `200 {}`: a digest mismatch, after one request.
        let _ = fetch_blob(&client, &store, &sha, 2).await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-blob/"))
        .collect();
    assert!(!sent.is_empty(), "{sent:?}");
    let places = capture::leaks(grant);
    assert_eq!(places.len(), sent.len(), "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}
