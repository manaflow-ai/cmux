use super::ops::{
    Endpoint, HelloIr, HelloOpRef, PageEngine, PageManifest, PageProvider, ProviderHello,
};
use super::*;
use crate::catalog::{DIFF_SOURCE, catalog};
use crate::token::{ROUTER_AUDIENCE, Verifier, verify_signature};

fn router() -> Arc<Router> {
    let router = Router::new(SigningKey::from_seed(&[1; 32]), catalog());
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

fn op(name: &str, kind: &str, scope: &str) -> HelloOpRef {
    HelloOpRef { name: name.into(), kind: kind.into(), scope: scope.into() }
}

fn hello(app: &str, namespaces: &[&str], ops: Vec<HelloOpRef>) -> ProviderHello {
    ProviderHello {
        proto: PROTO.into(),
        app: app.into(),
        namespaces: namespaces.iter().map(|ns| (*ns).to_owned()).collect(),
        ops,
        events: Vec::new(),
        interfaces: Vec::new(),
        ir: HelloIr { version: "0.1.0".into(), sha256: catalog().digest() },
        endpoints: vec![Endpoint::ws("ws://127.0.0.1:4000/")],
        credential: None,
    }
}

fn status_op() -> HelloOpRef {
    op("cmux.git.status", "read", "git:read")
}

fn spawned(app: &str) -> Admission {
    Admission::Spawned(app.to_owned())
}

fn with_credential(mut hello: ProviderHello, credential: &str) -> ProviderHello {
    hello.credential = Some(credential.into());
    hello
}

#[test]
fn admits_a_first_party_provider_and_finds_it() {
    let router = router();
    let welcome = router
        .admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![status_op()]))
        .unwrap();
    assert_eq!(welcome.provider, "cmux.git");
    assert_eq!(URL_SAFE_NO_PAD.decode(welcome.router_key).unwrap(), router.public_key());
    assert_eq!(router.provider_of("cmux.git.status").unwrap().app_id, "cmux.git");
    router.disconnect(1);
    assert_eq!(router.provider_of("cmux.git.status").unwrap_err().code, NO_PROVIDER);
}

#[test]
fn refuses_ops_and_namespaces_outside_the_app() {
    let router = router();
    let say = || op("com.example.hello.greet.say", "read", "hello:read");
    let cases = [
        hello(
            "com.example.hello",
            &["com.example.hello"],
            vec![op("com.example.other.say", "read", "x")],
        ),
        hello("com.example.hello", &["cmux"], vec![]),
        hello("com.example.hello", &["com.example"], vec![]),
        hello(
            "com.example.hello",
            &["com.example.hello"],
            vec![op("com.example.hello", "read", "x")],
        ),
        ProviderHello {
            proto: "cmux.pane/9".into(),
            ..hello("com.example.hello", &["com.example.hello"], vec![say()])
        },
    ];
    for case in cases {
        let error = router
            .admit(1, &Admission::SelfStarted, with_credential(case.clone(), "secret"))
            .unwrap_err();
        assert_eq!(error.code, REFUSED, "{case:?}");
    }
    let undeclared =
        hello("cmux.git", &["cmux.git"], vec![op("cmux.git.push", "mutation", "git:write")]);
    assert_eq!(router.admit(2, &spawned("cmux.git"), undeclared).unwrap_err().code, REFUSED);
    let wrong_scope =
        hello("cmux.git", &["cmux.git"], vec![op("cmux.git.status", "read", "git:write")]);
    assert_eq!(router.admit(2, &spawned("cmux.git"), wrong_scope).unwrap_err().code, REFUSED);
}

#[test]
fn self_started_needs_its_credential_and_spawned_needs_its_app_id() {
    let router = router();
    let say = op("com.example.hello.greet.say", "read", "hello:read");
    let request = hello("com.example.hello", &["com.example.hello"], vec![say]);
    assert!(router.admit(1, &Admission::SelfStarted, request.clone()).is_err());
    assert!(
        router
            .admit(1, &Admission::SelfStarted, with_credential(request.clone(), "wrong"))
            .is_err()
    );
    assert!(router.admit(1, &spawned("cmux.git"), request.clone()).is_err());
    assert!(router.admit(1, &Admission::SelfStarted, with_credential(request, "secret")).is_ok());
}

#[test]
fn namespaces_are_reserved_and_live_overlap_is_refused() {
    let router = router();
    router.admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![])).unwrap();
    let overlap = router
        .admit(2, &spawned("cmux.agent"), hello("cmux.agent", &["cmux"], vec![]))
        .unwrap_err();
    assert_eq!(overlap.code, REFUSED);
    let octo = with_credential(hello("octo.diff_tools", &["octo.diff_tools"], vec![]), "octo");
    router.admit(3, &Admission::SelfStarted, octo.clone()).unwrap();
    router.disconnect(3);
    let duplicate =
        AppRecord { app_id: "octo.diff_tools".into(), credential: None, grants: vec![] };
    assert!(router.register_app(duplicate).is_err());
    router.admit(4, &Admission::SelfStarted, octo).unwrap();
}

#[test]
fn app_ids_are_publisher_dot_name() {
    assert_eq!(namespace_for("octo/diff-tools"), "octo.diff_tools");
    assert!(valid_app_id("octo.diff_tools"));
    assert!(valid_app_id("cmux"));
    assert!(!valid_app_id("octo"));
    assert!(!valid_app_id("octo.diff-tools"));
    assert!(!valid_app_id("Octo.diff"));
}

#[test]
fn interfaces_list_names_live_implementations() {
    let router = router();
    let mut octo = with_credential(hello("octo.diff_tools", &["octo.diff_tools"], vec![]), "octo");
    octo.interfaces = vec![DIFF_SOURCE.into()];
    router.admit(1, &Admission::SelfStarted, octo.clone()).unwrap();
    let listed = router.interfaces_list(Some(DIFF_SOURCE));
    assert_eq!(listed.interfaces.len(), 1);
    assert_eq!(listed.interfaces[0].providers[0].app_id, "octo.diff_tools");
    assert!(router.interfaces_list(Some("cmux.viewer/1")).interfaces.is_empty());
    router.disconnect(1);
    octo.interfaces = vec!["octo.unknown/1".into()];
    assert!(router.admit(2, &Admission::SelfStarted, octo).is_err());
}

#[test]
fn refuses_non_loopback_endpoints() {
    let router = router();
    let mut request = hello("cmux.git", &["cmux.git"], vec![]);
    request.endpoints = vec![Endpoint::ws("ws://10.0.0.1:4000/")];
    assert!(router.admit(1, &spawned("cmux.git"), request).is_err());
}

#[test]
fn mints_only_granted_scopes_for_the_audience_namespaces() {
    let router = router();
    router.admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![])).unwrap();
    let request = MintRequest {
        sub: "surface-1".into(),
        app: "cmux.agent".into(),
        ns: vec!["cmux.git".into()],
        scopes: vec!["git:read".into()],
        roots: vec![],
        origin: Some("HTTP://127.0.0.1:4100/".into()),
        aud: "cmux.git".into(),
        ttl: Duration::from_secs(60),
    };
    let token = router.mint(request.clone()).unwrap();
    let claims = Verifier::new(router.public_key(), "cmux.git")
        .verify(&token, crate::token::now(), Some("http://127.0.0.1:4100"))
        .unwrap();
    assert!(claims.allows("cmux.git.status", "git:read"));
    let mut ungranted = request.clone();
    ungranted.scopes = vec!["git:write".into()];
    assert_eq!(router.mint(ungranted).unwrap_err().code, error::FORBIDDEN);
    let mut foreign = request.clone();
    foreign.ns = vec!["com.example.hello".into()];
    assert_eq!(router.mint(foreign).unwrap_err().code, error::FORBIDDEN);
    let mut long = request;
    long.ttl = Duration::from_secs(3600);
    assert!(router.mint(long).is_err());
}

fn diff_page() -> PageManifest {
    PageManifest {
        id: "octo.diff_tools.viewer".into(),
        route: "/diff".into(),
        entry: "pages/diff/index.html".into(),
        namespace: "octo.diff_tools".into(),
        provider: PageProvider::External,
        consumes: vec!["cmux.git.status".into()],
        scopes: vec![],
        engines: vec![PageEngine::Webkit, PageEngine::Browser],
    }
}

#[test]
fn pages_register_and_resolve_with_scoped_data_tokens() {
    let router = router();
    router
        .admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![status_op()]))
        .unwrap();
    router.register_page("octo.diff_tools", diff_page()).unwrap();
    assert_eq!(router.pages_list().pages, vec![diff_page()]);
    let origin = "cmux-page://octo.diff_tools.viewer";
    let page_token =
        router.mint_page_token("octo.diff_tools.viewer", "instance-1", Some(origin), &[]).unwrap();
    let page = Verifier::new(router.public_key(), ROUTER_AUDIENCE)
        .verify(&page_token, crate::token::now(), Some(origin))
        .unwrap();
    assert_eq!(page.page.as_deref(), Some("octo.diff_tools.viewer"));
    assert_eq!(page.scopes, ["git:read"]);
    let admission = Admission::Page(page);

    let resolved = router.resolve_for(&admission, "cmux.git").unwrap();
    assert_eq!(resolved.endpoint, Endpoint::ws("ws://127.0.0.1:4000/"));
    assert_eq!(resolved.ir, router.ir_digest());
    let data = Verifier::new(router.public_key(), "cmux.git")
        .verify(resolved.token.as_deref().unwrap(), crate::token::now(), Some(origin))
        .unwrap();
    assert!(data.allows("cmux.git.status", "git:read"));
    // A page that does not consume a namespace gets no token for it.
    router
        .register_app(AppRecord { app_id: "cmux.other".into(), credential: None, grants: vec![] })
        .unwrap();
    router.admit(2, &spawned("cmux.other"), hello("cmux.other", &["cmux.other"], vec![])).unwrap();
    assert_eq!(router.resolve_for(&admission, "cmux.other").unwrap_err().code, error::FORBIDDEN);
    // A native caller gets the endpoint and no token.
    assert_eq!(router.resolve_for(&Admission::SelfStarted, "cmux.git").unwrap().token, None);
}

#[test]
fn third_party_pages_need_install_grants_and_their_own_namespace() {
    let router = router();
    let mut greedy = diff_page();
    greedy.scopes = vec!["fs:write".into()];
    assert!(router.register_page("octo.diff_tools", greedy).is_err());
    let mut squatter = diff_page();
    squatter.id = "cmux.settings".into();
    assert!(router.register_page("octo.diff_tools", squatter).is_err());
}

#[test]
fn refresh_renews_own_tokens_only() {
    let router = router();
    router
        .admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![status_op()]))
        .unwrap();
    router.register_page("octo.diff_tools", diff_page()).unwrap();
    let token = router.mint_page_token("octo.diff_tools.viewer", "instance-1", None, &[]).unwrap();
    let claims = verify_signature(&router.public_key(), &token).unwrap();
    let admission = Admission::Page(claims);
    let refreshed = router.refresh(&admission, &token).unwrap();
    let fresh = verify_signature(&router.public_key(), &refreshed.token).unwrap();
    assert_eq!((fresh.sub.as_str(), fresh.aud.as_str()), ("instance-1", ROUTER_AUDIENCE));
    let data = router.resolve_for(&admission, "cmux.git").unwrap().token.unwrap();
    assert!(router.refresh(&admission, &data).is_ok());
    let other = router.mint_page_token("octo.diff_tools.viewer", "instance-2", None, &[]).unwrap();
    assert_eq!(router.refresh(&admission, &other).unwrap_err().code, error::FORBIDDEN);
    assert!(router.refresh(&admission, "not.a.token").is_err());
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

#[test]
fn first_party_ir_must_match_the_router_and_third_party_is_recorded() {
    let router = router();
    let mut stale = hello("cmux.git", &["cmux.git"], vec![]);
    stale.ir.sha256 = "ab".into();
    let refused = router.admit(1, &spawned("cmux.git"), stale).unwrap_err();
    assert_eq!(refused.code, error::BAD_MESSAGE);
    assert_eq!(refused.details.unwrap()["reason"], "ir_mismatch");
    let mut octo = with_credential(hello("octo.diff_tools", &["octo.diff_tools"], vec![]), "octo");
    octo.ir.sha256 = "ab".into();
    router.admit(2, &Admission::SelfStarted, octo).unwrap();
    let state = router.state();
    assert_eq!(state.live[&2].ir_sha256, "ab");
}

#[test]
fn page_tokens_never_carry_server_only_scopes() {
    let router = router();
    let mut settings = diff_page();
    settings.id = "cmux.settings".into();
    settings.namespace = "cmux.settings".into();
    settings.consumes = vec![];
    settings.scopes = vec!["settings:read".into(), "process:spawn:git".into()];
    router.register_page("cmux.agent", settings).unwrap();
    let token = router.mint_page_token("cmux.settings", "instance-1", None, &[]).unwrap();
    let claims = verify_signature(&router.public_key(), &token).unwrap();
    assert_eq!(claims.scopes, ["settings:read"]);
}

#[test]
fn the_host_mints_gestures_bound_to_op_provider_and_page() {
    use crate::gesture::{GESTURE_TYPE, GestureClaims};
    use crate::token::verify_jws;
    let router = router();
    router
        .admit(1, &spawned("cmux.git"), hello("cmux.git", &["cmux.git"], vec![status_op()]))
        .unwrap();
    router.register_page("octo.diff_tools", diff_page()).unwrap();
    let page = router.mint_page_token("octo.diff_tools.viewer", "instance-1", None, &[]).unwrap();
    let params = |op: &str, aud: Option<&str>| ops::GestureMintParams {
        page: page.clone(),
        op: op.into(),
        aud: aud.map(str::to_owned),
    };
    let minted = router.mint_gesture(params("cmux.git.status", None)).unwrap();
    let claims: GestureClaims =
        verify_jws(&router.public_key(), &minted.token, GESTURE_TYPE).unwrap();
    assert_eq!(
        (claims.sub.as_str(), claims.aud.as_str(), claims.op.as_str()),
        ("instance-1", "cmux.git", "cmux.git.status")
    );
    assert!(claims.exp <= crate::token::now() + crate::gesture::GESTURE_TTL_SECS);
    // A capability token is not a gesture token, and the other way round.
    assert!(verify_jws::<GestureClaims>(&router.public_key(), &page, GESTURE_TYPE).is_err());
    assert!(verify_signature(&router.public_key(), &minted.token).is_err());
    assert!(router.mint_gesture(params(crate::gesture::ANY_VIEW, None)).is_err());
    assert!(router.mint_gesture(params(crate::gesture::ANY_VIEW, Some("cmux.git"))).is_ok());
}

#[cfg(unix)]
#[tokio::test]
async fn only_the_host_may_call_gesture_mint() {
    use crate::envelope::Role;
    use crate::rpc::{NoHandler, Peer};
    let router = router();
    for admission in [Admission::SelfStarted, Admission::Spawned("cmux.git".into())] {
        let (ours, theirs) = crate::transport::memory_pair();
        tokio::spawn(router.clone().serve_connection(theirs, admission));
        let (peer, _) = Peer::start(ours, Role::Connecting, Arc::new(NoHandler));
        let params = serde_json::json!({ "page": "x", "op": "cmux.git.status" });
        let refused = peer.call("cmux.router.gesture.mint", params).await.unwrap_err();
        assert_eq!(refused.code, error::FORBIDDEN);
        assert_eq!(refused.details.unwrap()["reason"], "server_only");
    }
}
