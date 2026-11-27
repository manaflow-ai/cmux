//! Seeded secrets through the daemon's cmux Cloud transport, on the wire
//! (cmux_egress::capture): the bearer rides only in `Authorization` on the calls that take one,
//! and the unauthenticated calls (attachment part URL, ranged blob read) carry none.
//! tests/egress_seeded.json names this test for the `cmux_tui::cloud_conversations_backend`
//! gate site.

use cmux_egress::capture;
use serde_json::json;

use super::{CloudBackend as _, RemoteCloudBackend};

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_cloud_bearer_rides_only_in_authorization() {
    capture::install().unwrap();
    let bearer = "SEEDcloudBackendBearer-4b6f";
    let backend = RemoteCloudBackend::in_space(Ok(None)).unwrap();
    let base = format!("https://{HOST}/seeded-backend");
    let _ =
        backend.post(&format!("{base}/v1/ops"), Some(bearer), Some("1"), &json!({"op": "seeded"}));
    let _ = backend.get(&format!("{base}/v1/read"), Some(bearer), None);
    let _ = backend.platform("POST", &format!("{base}/v1/host-replica"), bearer, &json!({}));
    let _ = backend.attachment_part_url(&format!("{base}/v1/part"), 1);
    let _ = backend.get_range(&format!("{base}/v1/blob"), 0, 1);
    let _ =
        backend.connect(&format!("wss://{HOST}/seeded-backend/v1/wire/socket"), Some(bearer), None);
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-backend/"))
        .collect();
    assert_eq!(sent.len(), 6, "{sent:?}");
    let places = capture::leaks(bearer);
    assert_eq!(places.len(), 4, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
    assert!(
        !places.iter().any(|place| place.contains("/v1/part") || place.contains("/v1/blob")),
        "{places:?}"
    );
}
