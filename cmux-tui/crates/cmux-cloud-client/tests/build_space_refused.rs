//! A dev build launched without a usable build space: no client is built, so
//! nothing reaches nightly's data.

#[test]
fn a_process_with_an_unusable_build_space_builds_no_client() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(cmux_build_space::testing::refused());
    let timeout = std::time::Duration::from_secs(5);
    let error =
        cmux_cloud_client::http("https://cloud-api.cmux.dev", Some("tok"), None, "t", timeout)
            .expect_err("refused");
    assert!(error.to_string().contains("refusing to call cmux Cloud"), "{error}");
    assert!(cmux_cloud_client::client("https://cloud-api.cmux.dev", "tok", None, "t").is_err());
    assert!(cmux_cloud_client::anonymous_client("https://cloud-api.cmux.dev", "t").is_err());
}
