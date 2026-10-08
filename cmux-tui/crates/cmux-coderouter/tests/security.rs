use cmux_coderouter::{
    ApiFamily, BODY_LIMIT, InstallSecretStore, KeyRing, KeyScope, LoopbackAddr,
    RandomInstallSecretStore, Secret, spawn_data_plane,
};
use reqwest::{Client, StatusCode};
use std::{collections::BTreeSet, net::SocketAddr, sync::Arc};
use tokio::sync::RwLock;

fn scope() -> KeyScope {
    KeyScope {
        harness: "claude".into(),
        session: "session-1".into(),
        surfaces: vec!["surface-1".into()],
        families: BTreeSet::from([ApiFamily::AnthropicMessages, ApiFamily::OpenAiResponses]),
        expires_at: u64::MAX,
    }
}
async fn running_install(id: &str) -> (SocketAddr, tokio::task::JoinHandle<()>, String) {
    running_install_with_scope(id, scope()).await
}
async fn running_install_with_scope(
    id: &str,
    key_scope: KeyScope,
) -> (SocketAddr, tokio::task::JoinHandle<()>, String) {
    let store: Arc<dyn InstallSecretStore> = Arc::new(RandomInstallSecretStore::new(id).unwrap());
    let mut ring = KeyRing::new(store).unwrap();
    let key = ring.mint("key", key_scope).unwrap().expose().clone();
    let (address, task) = spawn_data_plane(Arc::new(RwLock::new(ring))).await.unwrap();
    (address, task, key)
}

#[tokio::test]
async fn api_family_scope_mismatch_is_forbidden() {
    let mut key_scope = scope();
    key_scope.families = BTreeSet::from([ApiFamily::AnthropicMessages]);
    let (address, task, key) = running_install_with_scope("family", key_scope).await;
    let response = client()
        .post(format!("http://{address}/v1/responses"))
        .header("authorization", format!("Bearer {key}"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    task.abort();
}
fn client() -> Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Client::builder().redirect(reqwest::redirect::Policy::none()).build().unwrap()
}
async fn post(client: &Client, address: SocketAddr, key: &str) -> reqwest::Response {
    client
        .post(format!("http://{address}/v1/messages"))
        .header("authorization", format!("Bearer {key}"))
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn real_listener_refuses_origin_rebinding_fetch_and_options() {
    let (address, task, key) = running_install("origin").await;
    let client = client();
    let url = format!("http://{address}/v1/messages");
    assert_eq!(
        client
            .post(&url)
            .header("authorization", format!("Bearer {key}"))
            .header("origin", "https://evil.example")
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        client
            .post(&url)
            .header("authorization", format!("Bearer {key}"))
            .header("sec-fetch-site", "cross-site")
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        client
            .post(&url)
            .header("authorization", format!("Bearer {key}"))
            .header("host", "evil.example")
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::MISDIRECTED_REQUEST
    );
    assert_eq!(
        client
            .request(reqwest::Method::OPTIONS, &url)
            .header("authorization", format!("Bearer {key}"))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::FORBIDDEN
    );
    task.abort();
}

#[tokio::test]
async fn fresh_install_secrets_are_random_and_cross_install_keys_are_refused() {
    let (address_a, task_a, key_a) = running_install("install-a").await;
    let (address_b, task_b, _) = running_install("install-b").await;
    assert_eq!(post(&client(), address_b, &key_a).await.status(), StatusCode::UNAUTHORIZED);
    assert_ne!(address_a, address_b);
    task_a.abort();
    task_b.abort();
}

#[tokio::test]
async fn valid_key_reaches_phase_three_placeholder_and_body_limit_is_enforced() {
    let (address, task, key) = running_install("valid").await;
    let client = client();
    assert_eq!(post(&client, address, &key).await.status(), StatusCode::NOT_IMPLEMENTED);
    let response = client
        .post(format!("http://{address}/v1/messages"))
        .header("authorization", format!("Bearer {key}"))
        .body(vec![0u8; BODY_LIMIT + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    task.abort();
}

#[test]
fn loopback_refuses_unspecified_and_public_addresses() {
    for address in ["0.0.0.0:0", "[::]:0", "192.168.1.2:80", "[2001:db8::1]:80"] {
        assert!(LoopbackAddr::try_from(address.parse::<SocketAddr>().unwrap()).is_err());
    }
}
#[test]
fn secret_debug_is_redacted() {
    assert_eq!(format!("{:?}", Secret::new("test-secret-canary".to_owned())), "<redacted>");
}
#[test]
fn panic_payload_is_discarded() {
    if std::env::var_os("CODEROUTER_PANIC_CHILD").is_some() {
        cmux_coderouter::install_panic_hook();
        panic!("test-secret-canary");
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "panic_payload_is_discarded", "--nocapture"])
        .env("CODEROUTER_PANIC_CHILD", "1")
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.contains("test-secret-canary"));
    assert!(stderr.contains("security.rs:"));
}

/// The data plane has no open mode: a request with no key, a key in another
/// scheme, an empty bearer or a wrong key of the same install gets 401.
#[tokio::test]
async fn missing_or_wrong_keys_are_unauthorized() {
    let (address, task, key) = running_install("missing").await;
    let client = client();
    let url = format!("http://{address}/v1/messages");
    assert_eq!(client.post(&url).send().await.unwrap().status(), StatusCode::UNAUTHORIZED);
    for authorization in
        [format!("Basic {key}"), "Bearer ".to_owned(), key.clone(), format!("Bearer {key}x")]
    {
        let status =
            client.post(&url).header("authorization", authorization).send().await.unwrap().status();
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    task.abort();
}
