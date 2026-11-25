//! A nightly or stable process (no build space): no client this crate builds
//! sends `x-cmux-build-space`.

use cmux_build_space::testing::Heads;

#[tokio::test]
async fn a_nightly_process_sends_no_build_space() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(None));
    let heads = Heads::start().await.unwrap();
    let timeout = std::time::Duration::from_secs(5);
    let (base, http) =
        cmux_cloud_client::http(&heads.base_url, Some("tok"), None, "t", timeout).unwrap();
    let _ = http.get(format!("{base}/v1/me")).send().await;
    heads.wait_for(1).await;
    assert_eq!(heads.spaces(), vec![None], "{:?}", heads.all());
}
