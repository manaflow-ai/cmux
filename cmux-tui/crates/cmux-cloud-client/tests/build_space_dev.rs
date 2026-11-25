//! A dev build's process (`CMUX_BUILD_SPACE=dev:<slug>`): every client this
//! crate builds sends `x-cmux-build-space` on every request, with a bearer or
//! without one.

use cmux_build_space::testing::{Heads, space};

const UA: &str = "cmux-test";
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

#[tokio::test]
async fn a_dev_process_sends_its_build_space_on_every_client() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(Some(space("my-tag-2"))));
    let heads = Heads::start().await.unwrap();

    let (base, http) =
        cmux_cloud_client::http(&heads.base_url, Some("tok"), Some("team_1"), UA, TIMEOUT).unwrap();
    let _ = http.get(format!("{base}/v1/me")).send().await;
    let (base, http) = cmux_cloud_client::http(&heads.base_url, None, None, UA, TIMEOUT).unwrap();
    let _ = http.post(format!("{base}/v1/ops")).body("{}").send().await;

    heads.wait_for(2).await;
    assert_eq!(heads.spaces(), vec![Some("dev:my-tag-2".to_owned()); 2], "{:?}", heads.all());
}
