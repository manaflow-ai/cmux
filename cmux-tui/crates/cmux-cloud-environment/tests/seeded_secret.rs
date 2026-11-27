//! Seeded secrets through the client-config fetch, on the wire (cmux_egress::capture): the fetch
//! is a header-less GET of `/v1/client-config` that carries nothing of the selection it resolves
//! (the person's home path, the state path). tests/egress_seeded.json
//! names this test for the `cmux_cloud_environment::client_config` gate site.

use cmux_egress::capture;

#[tokio::test]
async fn the_client_config_fetch_carries_no_person_state() {
    cmux_build_space::init_process(Ok(None));
    capture::install().unwrap();
    let person = "SEEDpersonHome-e4b7";
    let home = std::env::temp_dir().join(format!("{person}-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let resolver =
        cmux_cloud_environment::Resolver::with_state_root("com.cmuxterm.app.debug", &home, None)
            .unwrap();
    let selection = resolver.resolve(Some("prod")).unwrap();
    let origin = selection.configuration.api_origin.clone();
    let host = origin.strip_prefix("https://").unwrap().to_owned();
    let state_path = selection.state_path.clone();
    // The capture server answers `200 {}`, which is not a client-config: the resolve fails after
    // the request is sent, and that request is what this test reads.
    let _ = resolver.client_config(selection).await;
    let _ = std::fs::remove_dir_all(&home);

    let sent = capture::requests_to(&host);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!((sent[0].method.as_str(), sent[0].target.as_str()), ("GET", "/v1/client-config"));
    assert!(sent[0].body.is_empty(), "{sent:?}");
    for (name, _) in &sent[0].headers {
        assert!(!matches!(name.as_str(), "authorization" | "cookie" | "x-cmux-team"), "{sent:?}");
    }
    for secret in [person, state_path.as_str()] {
        assert!(capture::leaks(secret).is_empty(), "{secret}: {:?}", capture::leaks(secret));
    }
}
