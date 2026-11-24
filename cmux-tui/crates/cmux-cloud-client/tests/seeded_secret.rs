//! Seeded secrets through every client this crate builds, on the wire (cmux_egress::capture):
//! the bearer rides only in `Authorization`, the team only in `x-cmux-team`, and a client with
//! no credential sends neither. tests/egress_seeded.json names this test for the
//! `cmux_cloud_client` gate site.

use cmux_egress::capture;

const HOST: &str = "cloud-api.cmux.dev";

#[tokio::test]
async fn the_bearer_rides_only_in_authorization() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(None));
    capture::install().unwrap();
    let base = format!("https://{HOST}");
    let wait = std::time::Duration::from_secs(20);
    let bearer = "SEEDcloudClientBearer-6a1f";
    let team = "SEEDteam-2c8d";
    let (base, http) =
        cmux_cloud_client::http(&base, Some(bearer), Some(team), "seeded", wait).unwrap();
    http.get(format!("{base}/v1/seeded/me")).send().await.unwrap();
    http.post(format!("{base}/v1/seeded/post")).body("{\"n\":1}").send().await.unwrap();
    let (_, anonymous) = cmux_cloud_client::http(&base, None, None, "seeded", wait).unwrap();
    anonymous.get(format!("{base}/v1/seeded/anonymous")).send().await.unwrap();

    let sent = capture::requests_to(HOST);
    assert_eq!(sent.iter().filter(|r| r.target.starts_with("/v1/seeded/")).count(), 3, "{sent:?}");
    let places = capture::leaks(bearer);
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = capture::leaks(team);
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
    let anonymous = sent.iter().find(|r| r.target == "/v1/seeded/anonymous").unwrap();
    assert!(
        anonymous.headers.iter().all(|(n, _)| n != "authorization" && n != "x-cmux-team"),
        "{anonymous:?}"
    );
}
