//! Seeded secrets through the egress gate: a caller's GitHub credential rides to github.com
//! only in `authorization`, never in a target or body.

use base64::Engine as _;

#[tokio::test]
async fn seeded_secrets_ride_only_where_github_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let token = "ghp_SEEDgitCacheToken-5c1e";
    let dir = tempfile::tempdir().unwrap();
    let state =
        cmux_git_cache::State::new(cmux_git_cache::Config::new(dir.path().to_path_buf())).unwrap();
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, cmux_git_cache::router(state)).await.unwrap() });
    let basic = base64::engine::general_purpose::STANDARD.encode(format!("x-access-token:{token}"));
    // The capture server answers `200 {}`; the proxy's answer to the caller does not matter here.
    let _ = reqwest::Client::new()
        .get(format!("http://{proxy}/github.com/seed-owner/seed-repo.git/info/refs"))
        .query(&[("service", "git-upload-pack")])
        .header("authorization", format!("Basic {basic}"))
        .send()
        .await;
    let sent = cmux_egress::capture::requests_to("github.com");
    assert!(!sent.is_empty(), "the proxy reached github.com through the gate");
    let places = cmux_egress::capture::leaks(&basic);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    assert!(
        cmux_egress::capture::leaks(token).iter().all(|p| p.ends_with(": header authorization"))
    );
}
