//! Seeded secrets on the wire (cmux_egress::capture) through the cache's upstream client: the
//! caller's git credential rides only in `Authorization`, and only to github.com.
//! tests/egress_seeded.json names this test for `cmux_git_cache::server`.

use base64::Engine;

#[tokio::test]
async fn the_callers_credential_rides_only_in_authorization_to_github() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let secret = "SEEDgitCacheToken-6f3d";
    let basic =
        base64::engine::general_purpose::STANDARD.encode(format!("x-access-token:{secret}"));
    let tmp = tempfile::tempdir().unwrap();
    // The default upstream (https://github.com): the capture server answers it `200 {}`.
    let mut cfg = cmux_git_cache::Config::new(tmp.path().join("cache"));
    cfg.stats_file = Some(tmp.path().join("stats.json"));
    let state = cmux_git_cache::State::new(cfg).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, cmux_git_cache::app(state)).await.unwrap() });
    let client =
        reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).build().unwrap();
    let url = format!("http://{proxy}/github.com/o/r.git/info/refs?service=git-upload-pack");
    let _ = client.get(&url).header("authorization", format!("Basic {basic}")).send().await;
    let sent = cmux_egress::capture::requests();
    assert!(!sent.is_empty(), "the cache asked upstream");
    assert!(sent.iter().all(|r| r.host == "github.com"), "{sent:?}");
    let places = cmux_egress::capture::leaks(secret);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
}
