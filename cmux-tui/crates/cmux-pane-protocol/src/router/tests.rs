use super::*;
use crate::catalog::{DIFF_SOURCE, catalog};

fn router() -> Arc<Router> {
    let router = Router::new(SigningKey::from_seed(&[1; 32]).unwrap(), catalog());
    for (app_id, credential, grants) in [
        ("cmux.git", None, vec!["git:read".to_owned()]),
        ("com.example.hello", Some("secret".to_owned()), vec!["hello:read".to_owned()]),
        ("octo.diff_tools", Some("octo".to_owned()), vec!["git:read".to_owned()]),
        ("cmux.agent", None, vec!["git:read".to_owned()]),
    ] {
        router.register_app(AppRecord { app_id: app_id.into(), credential, grants }).unwrap();
    }
    router
}

#[cfg(unix)]
#[tokio::test]
async fn control_connection_refuses_to_relay_data_plane_ops() {
    use crate::envelope::Role;
    use crate::rpc::{NoHandler, Peer};
    let router = router();
    let (ours, theirs) = crate::transport::memory_pair();
    tokio::spawn(router.clone().serve_connection(theirs, Admission::SelfStarted));
    let (peer, _) = Peer::start(ours, Role::Connecting, Arc::new(NoHandler));
    let refused =
        peer.call("cmux.git.status", serde_json::json!({ "cwd": "/" })).await.unwrap_err();
    assert_eq!(refused.code, error::NOT_ROUTED);
    let missing = peer
        .call("cmux.router.resolve", serde_json::json!({ "namespace": "cmux.git" }))
        .await
        .unwrap_err();
    assert_eq!(missing.code, NO_PROVIDER);
    let bad = peer
        .call("cmux.router.interfaces.list", serde_json::json!({ "name": 1 }))
        .await
        .unwrap_err();
    assert_eq!(bad.code, error::INVALID_PARAMS);
    let listed = peer.call("cmux.router.interfaces.list", serde_json::json!({})).await.unwrap();
    assert_eq!(listed["interfaces"][0]["name"], DIFF_SOURCE);
}
