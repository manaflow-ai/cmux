//! Seeded secrets on the wire (cmux_egress::capture) through the git cache's upstream client: a caller's
//! git credential rides only in `Authorization`, to the upstream that checks it.
//! tests/egress_seeded.json names this test for `cmux_git_cache::server`.

use super::*;

#[test]
fn a_callers_credential_rides_only_in_authorization() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let credential = "Basic U0VFRGdpdENhY2hlQ3JlZGVudGlhbC03MWQ0";
    let dir = tempfile::tempdir().unwrap();
    let state = State::new(Config::new(dir.path().to_path_buf())).unwrap();
    let route = Route {
        owner: "seeded-owner".into(),
        repo: "seeded-repo".into(),
        action: Action::InfoRefs,
    };
    let mut headers = HeaderMap::new();
    headers.insert(header::AUTHORIZATION, HeaderValue::from_static(credential));
    let caller = caller_key(Some(credential.as_bytes()));
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _ = runtime.block_on(confirm(&state, &route, &headers, &caller));
    assert!(!cmux_egress::capture::requests().is_empty(), "the check reached the capture server");
    let places = cmux_egress::capture::leaks(credential);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
}
