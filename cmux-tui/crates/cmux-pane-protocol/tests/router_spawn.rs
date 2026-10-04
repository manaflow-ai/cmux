//! The router spawns a provider on an inherited socketpair, admits it, mints
//! a token, and a page then talks to the provider directly.
#![cfg(unix)]

mod common;

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::time::Duration;

use cmux_pane_protocol::catalog::catalog;
use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::envelope::Role;
use cmux_pane_protocol::example::{APP_ID, SCOPE};
use cmux_pane_protocol::router::ops::{EndpointKind, ProviderInfo, ResolveOp, ResolveParams};
use cmux_pane_protocol::router::{self, AppRecord, MintRequest, Router};
use cmux_pane_protocol::rpc::{NoHandler, Peer};
use cmux_pane_protocol::token::SigningKey;
use cmux_pane_protocol::{error, transport, ws};
use common::{next_envelope, send};
use serde_json::json;

const PROVIDER: &str = env!("CARGO_BIN_EXE_pane-protocol-example-provider");
const PAGE_ORIGIN: &str = "http://127.0.0.1:4100";

fn router(credential: Option<&str>) -> Arc<Router> {
    let router = Router::new(SigningKey::generate().unwrap(), catalog());
    let app = |app_id: &str, credential: Option<&str>, grants: &[&str]| AppRecord {
        app_id: app_id.into(),
        credential: credential.map(str::to_owned),
        grants: grants.iter().map(|grant| (*grant).to_owned()).collect(),
    };
    router.register_app(app(APP_ID, credential, &[SCOPE])).unwrap();
    router.register_app(app("cmux.agent", None, &[SCOPE])).unwrap();
    router
}

async fn wait_for_provider(router: &Router) -> ProviderInfo {
    for _ in 0..200 {
        if let Ok(info) = router.provider_of(APP_ID) {
            return info;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("provider never said hello");
}

async fn page_greets(router: &Router, info: &ProviderInfo) {
    let endpoint = info
        .endpoints
        .iter()
        .find(|endpoint| endpoint.kind == EndpointKind::Ws)
        .expect("ws endpoint");
    let url = endpoint.url.clone().unwrap();
    let port: u16 =
        url.trim_start_matches("ws://127.0.0.1:").trim_end_matches('/').parse().unwrap();
    let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let token = router
        .mint(MintRequest {
            sub: "page-1".into(),
            app: "cmux.agent".into(),
            ns: vec![APP_ID.into()],
            scopes: vec![SCOPE.into()],
            roots: vec![],
            origin: Some(PAGE_ORIGIN.into()),
            aud: APP_ID.into(),
            ttl: Duration::from_secs(60),
        })
        .unwrap();
    let mut page = ws::connect(address, &url, Some(PAGE_ORIGIN)).await.unwrap();
    send(&page, Envelope::Auth { token }).await;
    assert!(matches!(next_envelope(&mut page).await, Some(Envelope::Ok { .. })));
    send(
        &page,
        Envelope::Call {
            id: 1,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "router" }),
            cap: None,
            gesture: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut page).await,
        Some(Envelope::Ok { id: 1, value: json!({ "message": "hello, router" }) })
    );
}

#[tokio::test]
async fn spawned_provider_is_admitted_and_serves_pages_directly() {
    let router = router(None);
    let mut command = std::process::Command::new(PROVIDER);
    command.env("CMUX_PANE_ALLOWED_ORIGINS", PAGE_ORIGIN).env_remove("CMUX_PANE_ROUTER_SOCKET");
    let mut child = router.spawn_provider(APP_ID, command).unwrap();
    let info = wait_for_provider(&router).await;
    assert_eq!(info.app_id, APP_ID);
    page_greets(&router, &info).await;
    child.kill().await.unwrap();
    for _ in 0..200 {
        if router.provider_of(APP_ID).is_err() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("router kept a dead provider");
}

#[tokio::test]
async fn spawned_as_another_app_is_refused() {
    let router = router(None);
    router
        .register_app(AppRecord {
            app_id: "octo.diff_tools".into(),
            credential: None,
            grants: vec![],
        })
        .unwrap();
    let mut command = std::process::Command::new(PROVIDER);
    command.env_remove("CMUX_PANE_ROUTER_SOCKET");
    let mut child = router.spawn_provider("octo.diff_tools", command).unwrap();
    // The provider's hello names com.example.hello, so it is refused and exits.
    let status =
        tokio::time::timeout(Duration::from_secs(10), child.wait()).await.unwrap().unwrap();
    assert!(!status.success());
    assert!(router.provider_of(APP_ID).is_err());
}

#[tokio::test]
async fn self_started_provider_connects_to_the_0600_socket_with_its_credential() {
    let router = router(Some("example-secret"));
    let directory = tempfile::Builder::new().prefix("pp").tempdir_in("/tmp").unwrap();
    let socket = directory.path().join("run/router.sock");
    let _listener = router::listen(router.clone(), &socket).unwrap();
    assert_eq!(std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(
        std::fs::metadata(socket.parent().unwrap()).unwrap().permissions().mode() & 0o777,
        0o700
    );

    // Without the credential: refused.
    let mut refused = tokio::process::Command::new(PROVIDER)
        .env("CMUX_PANE_ROUTER_SOCKET", &socket)
        .env_remove("CMUX_PANE_APP_CREDENTIAL")
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let status =
        tokio::time::timeout(Duration::from_secs(10), refused.wait()).await.unwrap().unwrap();
    assert!(!status.success());

    let mut child = tokio::process::Command::new(PROVIDER)
        .env("CMUX_PANE_ROUTER_SOCKET", &socket)
        .env("CMUX_PANE_APP_CREDENTIAL", "example-secret")
        .env("CMUX_PANE_ALLOWED_ORIGINS", PAGE_ORIGIN)
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let info = wait_for_provider(&router).await;
    page_greets(&router, &info).await;

    // A surface on the same socket can discover the provider but cannot use
    // the router as a relay to it.
    let stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
    let (surface, _) = Peer::start(transport::unix(stream), Role::Connecting, Arc::new(NoHandler));
    let resolved =
        surface.call_op::<ResolveOp>(&ResolveParams { namespace: APP_ID.into() }).await.unwrap();
    assert_eq!((resolved.app_id.as_str(), resolved.token.as_deref()), (APP_ID, None));
    assert_eq!(resolved.ir, catalog().digest());
    let relay =
        surface.call("com.example.hello.greet.say", json!({ "name": "x" })).await.unwrap_err();
    assert_eq!(relay.code, error::NOT_ROUTED);
    child.kill().await.unwrap();
}

#[tokio::test]
async fn a_page_resolves_through_the_router_then_calls_the_provider_directly() {
    use cmux_local_auth::ListenerPolicy;
    use cmux_pane_protocol::router::ops::{PageManifest, PageProvider};

    let router = router(None);
    let page_id = "com.example.hello.page";
    let origin = format!("cmux-page://{page_id}");
    router
        .register_page(
            APP_ID,
            PageManifest {
                id: page_id.into(),
                route: "/hello".into(),
                entry: "pages/hello/index.html".into(),
                namespace: APP_ID.into(),
                provider: PageProvider::Process { command: PROVIDER.into(), args: vec![] },
                consumes: vec!["com.example.hello.greet.say".into()],
                scopes: vec![],
                engines: vec![],
            },
        )
        .unwrap();
    let mut command = std::process::Command::new(PROVIDER);
    command.env_remove("CMUX_PANE_ROUTER_SOCKET");
    let mut child = router.spawn_provider(APP_ID, command).unwrap();
    wait_for_provider(&router).await;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let router_address = listener.local_addr().unwrap();
    tokio::spawn(
        router.clone().serve_pages_ws(listener, ListenerPolicy::loopback(router_address.port())),
    );
    let page_token = router.mint_page_token(page_id, "instance-1", Some(&origin), &[]).unwrap();
    let mut control =
        ws::connect(router_address, &format!("ws://{router_address}/"), Some(&origin))
            .await
            .unwrap();
    send(&control, Envelope::Auth { token: page_token }).await;
    assert!(matches!(next_envelope(&mut control).await, Some(Envelope::Ok { id: 0, .. })));
    send(
        &control,
        Envelope::Call {
            id: 1,
            op: "cmux.router.resolve".into(),
            params: json!({ "namespace": APP_ID }),
            cap: None,
            gesture: None,
        },
    )
    .await;
    let Some(Envelope::Ok { id: 1, value }) = next_envelope(&mut control).await else {
        panic!("resolve failed")
    };
    let url = value["endpoint"]["url"].as_str().unwrap().to_owned();
    let token = value["token"].as_str().unwrap().to_owned();
    // The router refuses to carry the call itself.
    send(
        &control,
        Envelope::Call {
            id: 2,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "x" }),
            cap: None,
            gesture: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut control).await.unwrap().error_body().unwrap().code,
        error::NOT_ROUTED
    );

    let port: u16 =
        url.trim_start_matches("ws://127.0.0.1:").trim_end_matches('/').parse().unwrap();
    let provider_address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let mut data = ws::connect(provider_address, &url, Some(&origin)).await.unwrap();
    send(&data, Envelope::Auth { token }).await;
    assert!(matches!(next_envelope(&mut data).await, Some(Envelope::Ok { id: 0, .. })));
    send(
        &data,
        Envelope::Call {
            id: 1,
            op: "com.example.hello.greet.say".into(),
            params: json!({ "name": "page" }),
            cap: None,
            gesture: None,
        },
    )
    .await;
    assert_eq!(
        next_envelope(&mut data).await,
        Some(Envelope::Ok { id: 1, value: json!({ "message": "hello, page" }) })
    );
    child.kill().await.unwrap();
}
