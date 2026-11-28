use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{Value, json};

use super::{KimiRegion, Provider, Service, Status, oauth::Endpoints};
use crate::chatgpt::Places;
use crate::routes;

#[derive(Clone)]
struct Fake {
    base: String,
    provider: Provider,
    ttl: u64,
    tokens: Arc<Mutex<VecDeque<Value>>>,
    calls: Arc<Mutex<Vec<String>>>,
    block_refresh_write: Arc<Mutex<Option<std::path::PathBuf>>>,
    copilot_enabled: bool,
}

async fn discovery(State(fake): State<Fake>) -> Json<Value> {
    Json(json!({
        "issuer": fake.base,
        "device_authorization_endpoint": format!("{}/oauth2/device/code", fake.base),
        "token_endpoint": format!("{}/oauth2/token", fake.base),
        "revocation_endpoint": format!("{}/oauth2/revoke", fake.base),
    }))
}

async fn device(State(fake): State<Fake>, headers: HeaderMap, body: Bytes) -> Json<Value> {
    let url = match fake.provider {
        Provider::Grok => {
            let body = std::str::from_utf8(&body).unwrap();
            assert!(body.contains("client_id=b1a00492-073a-47ea-816f-4c329264a828"));
            assert!(body.contains("offline_access"));
            "https://accounts.x.ai/oauth2/device"
        }
        Provider::Kimi => {
            assert_eq!(headers["user-agent"], "cmux");
            assert_eq!(headers["x-msh-platform"], "cmux");
            assert!(!headers["x-msh-device-id"].is_empty());
            let body = std::str::from_utf8(&body).unwrap();
            assert_eq!(body, "client_id=17e5f671-d194-4dfb-9706-5516cb48c098");
            "https://www.kimi.ai/code/authorize_device"
        }
        Provider::Copilot => {
            let body: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(body, json!({"client_id": "Ov23li8tweQw6odWQebz", "scope": "read:user"}));
            "https://github.com/login/device"
        }
    };
    Json(json!({
        "device_code": "secret-device-code", "user_code": "TEST-1234",
        "verification_uri": url, "expires_in": fake.ttl, "interval": 1,
    }))
}

async fn copilot_user(State(fake): State<Fake>, headers: HeaderMap) -> Json<Value> {
    assert_eq!(headers["authorization"], "Bearer fixture-access");
    assert_eq!(headers["x-github-api-version"], "2025-04-01");
    Json(json!({
        "chat_enabled": fake.copilot_enabled,
        "endpoints": {"api": "https://api.business.githubcopilot.com"},
    }))
}

async fn kimi_user(headers: HeaderMap) -> Response {
    match headers.get("authorization").and_then(|value| value.to_str().ok()) {
        Some("Bearer fixture-other") => {
            Json(json!({"user_id": "other-subject", "nickname": "Other name"})).into_response()
        }
        Some("Bearer fixture-same" | "Bearer fixture-access") => {
            Json(json!({"user_id": "saved-subject", "nickname": "Saved name"})).into_response()
        }
        Some("Bearer fixture-no-identity") => {
            Json(json!({"nickname": "Saved name"})).into_response()
        }
        _ => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

async fn token(State(fake): State<Fake>, body: Bytes) -> Response {
    fake.calls.lock().unwrap().push(String::from_utf8(body.to_vec()).unwrap());
    if let Some(path) = fake.block_refresh_write.lock().unwrap().take() {
        // Replace the file after the daemon reads it. A rename over a directory must fail.
        std::fs::rename(&path, path.with_extension("stale.json")).unwrap();
        std::fs::create_dir(path).unwrap();
    }
    let reply = fake
        .tokens
        .lock()
        .unwrap()
        .pop_front()
        .unwrap_or_else(|| json!({"error": "authorization_pending"}));
    match reply.as_str() {
        Some("rate-limited") => StatusCode::TOO_MANY_REQUESTS.into_response(),
        Some("malformed") => "not JSON".into_response(),
        Some("unauthorized") => StatusCode::UNAUTHORIZED.into_response(),
        Some("forbidden") => {
            (StatusCode::FORBIDDEN, Json(json!({"error": "invalid_token"}))).into_response()
        }
        _ => Json(reply).into_response(),
    }
}

async fn revoke(State(fake): State<Fake>, body: Bytes) {
    fake.calls.lock().unwrap().push(String::from_utf8(body.to_vec()).unwrap());
}

async fn fixture(
    provider: Provider,
    ttl: u64,
    tokens: Vec<Value>,
    copilot_enabled: bool,
) -> (Arc<Service>, Fake, tempfile::TempDir, Places) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let fake = Fake {
        base: base.clone(),
        provider,
        ttl,
        tokens: Arc::new(Mutex::new(tokens.into())),
        calls: Arc::new(Mutex::new(Vec::new())),
        block_refresh_write: Arc::default(),
        copilot_enabled,
    };
    let router = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/oauth2/device/code", post(device))
        .route("/oauth2/token", post(token))
        .route("/oauth2/revoke", post(revoke))
        .route("/api/oauth/device_authorization", post(device))
        .route("/api/oauth/token", post(token))
        .route("/login/device/code", post(device))
        .route("/login/oauth/access_token", post(token))
        .route("/copilot_internal/user", get(copilot_user))
        .route("/coding/v1/me", get(kimi_user))
        .route("/user", get(|| async { Json(json!({"id": 42, "login": "fixture-user"})) }))
        .with_state(fake.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let root = tempfile::tempdir().unwrap();
    let places =
        Places { routes: Some(root.path().join("routes")), home: root.path().join("state") };
    let service = Arc::new(Service::new(Endpoints {
        grok_issuer: base.clone(),
        github: base.clone(),
        github_api: base.clone(),
        kimi_global: base.clone(),
        kimi_china: "http://127.0.0.1:0".into(),
        kimi_global_api: format!("{base}/coding/v1"),
        ..Default::default()
    }));
    (service, fake, root, places)
}

#[tokio::test]
async fn kimi_device_poll_retries_rate_limits_and_a_malformed_reply() {
    let provider = Provider::Kimi;
    let (service, fake, _root, places) = fixture(provider, 30, vec![
        json!("rate-limited"),
        json!("malformed"),
        json!({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600}),
    ], true).await;
    let begun = service.begin(provider, places, None, None, || {}).await.unwrap();
    let done = service.wait(&begun.attempt, Duration::from_secs(20)).await.unwrap();
    assert!(matches!(done, Status::Done(_)));
    assert_eq!(fake.calls.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn rotated_subscription_survives_and_retries_a_failed_write() {
    let provider = Provider::Grok;
    let (service, fake, _root, places) = fixture(provider, 30, vec![
        json!({"access_token": "fixture-fresh", "refresh_token": "fixture-rotated", "expires_in": 3600}),
        json!({"access_token": "fixture-newest", "refresh_token": "fixture-rotated-again", "expires_in": 7200}),
    ], true).await;
    let id = "grok-fixture";
    provider
        .write(
            &places.home,
            id,
            &super::Record {
                access_token: "fixture-expired".into(),
                refresh_token: "fixture-stale".into(),
                expires_at: 1,
                region: None,
                device_id: None,
                sub: None,
                login: None,
                email: None,
            },
        )
        .unwrap();
    let path = provider.path(&places.home, id).unwrap();
    let held = path.with_extension("stale.json");
    *fake.block_refresh_write.lock().unwrap() = Some(path.clone());
    let margin = super::LOCAL_MARGIN;
    assert_eq!(service.token(provider, &places.home, id, margin).await.unwrap().0, "fixture-fresh");
    assert_eq!(service.token(provider, &places.home, id, margin).await.unwrap().0, "fixture-fresh");
    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(held, path).unwrap();
    assert_eq!(provider.read(&places.home, id).unwrap().unwrap().refresh_token, "fixture-stale");
    assert_eq!(service.token(provider, &places.home, id, margin).await.unwrap().0, "fixture-fresh");
    assert_eq!(provider.read(&places.home, id).unwrap().unwrap().refresh_token, "fixture-rotated");
    assert_eq!(service.token(provider, &places.home, id, 3600).await.unwrap().0, "fixture-newest");
    let calls = fake.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(calls[0].contains("refresh_token=fixture-stale"));
    assert!(calls[1].contains("refresh_token=fixture-rotated"));
}

#[tokio::test]
async fn subscription_device_success_refresh_and_remove() {
    for provider in [Provider::Grok, Provider::Copilot] {
        let (service, fake, _root, places) = fixture(provider, 30, vec![
            json!({"error": "authorization_pending"}),
            json!({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 1}),
            json!({"access_token": "fixture-next", "refresh_token": "fixture-rotated", "expires_in": 3600}),
        ], true).await;
        let begun = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
        assert_eq!(begun.user_code, "TEST-1234");
        assert!(!begun.url.contains("secret-device-code"));
        assert!(matches!(
            service.wait(&begun.attempt, Duration::ZERO).await.unwrap(),
            Status::Pending
        ));
        let done = service.wait(&begun.attempt, Duration::from_secs(8)).await.unwrap();
        let Status::Done(id) = done else { panic!("device approval did not complete") };
        let route = routes::find(places.routes.as_deref(), &id).unwrap();
        assert_eq!(route.file.kind, provider.kind());
        assert!(route.file.secret.is_none());
        assert!(provider.signed_in(&places.home, &id));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(provider.path(&places.home, &id).unwrap())
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o077, 0);
        }
        let (access, expiry) = service.token(provider, &places.home, &id, 300).await.unwrap();
        if provider == Provider::Grok {
            assert_eq!(begun.url, "https://accounts.x.ai/oauth2/device");
            assert_eq!(access, "fixture-next");
            assert!(expiry > now_plus(300));
            assert!(
                fake.calls
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|body| body.contains("grant_type=refresh_token"))
            );
        } else {
            assert_eq!((access.as_str(), expiry), ("fixture-access", 0));
            assert_eq!(fake.calls.lock().unwrap().len(), 2);
            assert_eq!(
                service.oauth.copilot_endpoint(&access).await.unwrap().as_deref(),
                Some("https://api.business.githubcopilot.com"),
            );
        }
        let instance =
            routes::find(places.routes.as_deref(), &id).unwrap().file.credential_instance.unwrap();
        service.remove(provider, places.clone(), id.clone(), instance).await.unwrap();
        assert!(!provider.signed_in(&places.home, &id));
        assert!(routes::find(places.routes.as_deref(), &id).is_err());
        if provider == Provider::Grok {
            assert!(
                fake.calls
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|body| body.contains("token=fixture-rotated"))
            );
        }
    }
}

fn now_plus(seconds: i64) -> i64 {
    super::now() + seconds
}

#[tokio::test]
async fn subscription_device_expiry_and_cancel_keep_no_connection() {
    for provider in [Provider::Grok, Provider::Copilot] {
        let (service, _fake, _root, places) = fixture(provider, 1, vec![], true).await;
        let cancelled = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
        assert!(matches!(service.cancel(&cancelled.attempt).await.unwrap(), Status::Cancelled));
        let expired = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
        assert!(matches!(
            service.wait(&expired.attempt, Duration::from_secs(5)).await.unwrap(),
            Status::Failed("expired_token")
        ));
        assert!(routes::load(places.routes.as_deref()).0.is_empty());
    }
}

#[tokio::test]
async fn subscription_grok_keeps_the_full_device_approval_window() {
    let (service, _, _root, places) = fixture(Provider::Grok, 1800, vec![], true).await;
    let begun = service.begin(Provider::Grok, places, None, None, || {}).await.unwrap();
    assert_eq!(begun.url, "https://accounts.x.ai/oauth2/device");
    assert!((1799..=1800).contains(&(begun.expires_at - super::now())));
    assert!(matches!(service.cancel(&begun.attempt).await.unwrap(), Status::Cancelled));
}

#[tokio::test]
async fn subscription_copilot_entitlement_failure_saves_no_connection() {
    let (service, fake, _root, places) =
        fixture(Provider::Copilot, 30, vec![json!({"access_token": "fixture-access"})], false)
            .await;
    let begun = service.begin(Provider::Copilot, places.clone(), None, None, || {}).await.unwrap();
    let result = service.wait(&begun.attempt, Duration::from_secs(5)).await.unwrap();
    assert!(matches!(result, Status::Failed("no_copilot_access")));
    assert!(routes::load(places.routes.as_deref()).0.is_empty());
    assert!(!places.home.join("copilot").exists());
    let calls = fake.calls.lock().unwrap();
    let poll: Value = serde_json::from_str(&calls[0]).unwrap();
    assert_eq!(poll["grant_type"], "urn:ietf:params:oauth:grant-type:device_code");
}

#[tokio::test]
async fn kimi_device_sign_in_saves_region_and_refreshes_through_the_same_host() {
    let (service, fake, _root, places) = fixture(Provider::Kimi, 30, vec![
        json!({"error": "authorization_pending"}),
        json!({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 20}),
        json!({"access_token": "fixture-rotated", "refresh_token": "fixture-refresh-rotated", "expires_in": 3600}),
    ], true).await;
    let begun = service
        .begin(Provider::Kimi, places.clone(), None, Some(KimiRegion::Global), || {})
        .await
        .unwrap();
    assert_eq!(begun.user_code, "TEST-1234");
    assert_eq!(begun.url, "https://www.kimi.ai/code/authorize_device");
    let Status::Done(id) = service.wait(&begun.attempt, Duration::from_secs(5)).await.unwrap()
    else {
        panic!("Kimi sign-in did not complete");
    };
    assert_eq!(
        routes::find(places.routes.as_deref(), &id).unwrap().file.kind,
        routes::RouteKind::KimiPlan
    );
    let (access, expiry, region) =
        service.grant(Provider::Kimi, &places.home, &id, 30).await.unwrap();
    assert_eq!(access, "fixture-rotated");
    assert!(expiry > super::now());
    assert_eq!(region, Some(KimiRegion::Global));
    assert_eq!(region.map(KimiRegion::base_url), Some("https://api.kimi.ai/coding/v1"));
    let calls = fake.calls.lock().unwrap();
    assert!(calls[0].contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"));
    assert!(calls[2].contains("refresh_token=fixture-refresh"));
}

#[tokio::test]
async fn kimi_device_sign_in_cancels_without_saving() {
    let (service, _fake, _root, places) = fixture(Provider::Kimi, 30, vec![], true).await;
    let begun = service
        .begin(Provider::Kimi, places.clone(), None, Some(KimiRegion::Global), || {})
        .await
        .unwrap();
    assert!(matches!(service.cancel(&begun.attempt).await.unwrap(), Status::Cancelled));
    assert!(
        routes::load(places.routes.as_deref())
            .0
            .iter()
            .all(|route| route.file.kind != routes::RouteKind::KimiPlan)
    );
}

#[tokio::test]
async fn copilot_joins_and_labels_the_account_and_refuses_a_duplicate() {
    let provider = Provider::Copilot;
    let (service, _fake, _root, places) = fixture(
        provider,
        40,
        vec![json!({"access_token": "fixture-access"}), json!({"access_token": "fixture-access"})],
        true,
    )
    .await;
    let begun = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
    let joined = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
    assert_eq!(begun.attempt, joined.attempt);
    let Status::Done(id) = service.wait(&joined.attempt, Duration::from_secs(10)).await.unwrap()
    else {
        panic!("the expected approval did not complete");
    };
    let route = routes::find(places.routes.as_deref(), &id).unwrap();
    assert_eq!(route.name(), "GitHub Copilot (fixture-user)");
    let again = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
    assert!(matches!(
        service.wait(&again.attempt, Duration::from_secs(10)).await.unwrap(),
        Status::Failed("already_signed_in")
    ));
    assert_eq!(routes::load(places.routes.as_deref()).0.len(), 1);
}

#[cfg(unix)]
#[tokio::test]
async fn copilot_refusal_does_not_erase_a_newer_sign_in() {
    let home = tempfile::tempdir().unwrap();
    let mut record = super::Record {
        access_token: "fixture-new".into(),
        refresh_token: String::new(),
        expires_at: 0,
        region: None,
        device_id: None,
        sub: None,
        login: None,
        email: None,
    };
    let id = "copilot-fixture";
    Provider::Copilot.write(home.path(), id, &record).unwrap();
    assert!(
        !Provider::forget_lapsed_copilot(home.path().to_owned(), id.into(), "fixture-old".into())
            .await
            .unwrap()
    );
    assert!(Provider::Copilot.signed_in(home.path(), id));

    assert!(
        Provider::forget_lapsed_copilot(
            home.path().to_owned(),
            id.into(),
            std::mem::take(&mut record.access_token)
        )
        .await
        .unwrap()
    );
    assert!(!Provider::Copilot.signed_in(home.path(), id));
    assert!(matches!(
        Service::default().token(Provider::Copilot, home.path(), id, 0).await,
        Err("signed_out")
    ));
}

#[tokio::test]
async fn subscription_disconnect_reports_keychain_delete_failure_and_can_retry() {
    for provider in [Provider::Kimi, Provider::Grok, Provider::Copilot] {
        let (service, fake, _root, places) = fixture(provider, 30, vec![], true).await;
        let id = provider.name();
        let record = super::Record {
            access_token: "fixture-access".into(),
            refresh_token: if provider == Provider::Copilot { "" } else { "fixture-refresh" }
                .into(),
            expires_at: if provider == Provider::Copilot { 0 } else { 1 },
            region: (provider == Provider::Kimi).then_some(KimiRegion::Global),
            device_id: None,
            sub: Some("fixture-subject".into()),
            login: None,
            email: None,
        };
        super::save(provider, &places, id, false, &record).unwrap();
        let store = provider.store(&places.home);
        store.refuse_test_delete(id, crate::subscription_store::Error::KeychainOtherBuild);
        let instance =
            routes::find(places.routes.as_deref(), id).unwrap().file.credential_instance.unwrap();
        assert_eq!(
            service.remove(provider, places.clone(), id.into(), instance.clone()).await,
            Err("keychain_other_build")
        );
        assert!(provider.path(&places.home, id).unwrap().exists());
        assert!(routes::find(places.routes.as_deref(), id).is_ok());
        assert!(store.has_test_item(id));

        store.allow_test_item(id);
        if provider == Provider::Grok {
            assert!(fake.calls.lock().unwrap()[0].contains("token=fixture-refresh"));
            store.refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);
            assert_eq!(
                service.remove(provider, places.clone(), id.into(), instance.clone()).await,
                Err("keychain_other_build")
            );
            assert_eq!(fake.calls.lock().unwrap().len(), 1);
            assert!(routes::find(places.routes.as_deref(), id).is_ok());
            store.allow_test_item(id);
        }
        service.remove(provider, places.clone(), id.into(), instance).await.unwrap();
        assert!(!store.has_test_item(id));
        assert!(!provider.path(&places.home, id).unwrap().exists());
        assert!(routes::find(places.routes.as_deref(), id).is_err());
        if provider == Provider::Grok {
            assert_eq!(fake.calls.lock().unwrap().len(), 2);
        }
    }
}

#[tokio::test]
async fn grok_disconnect_revokes_the_pending_refresh_before_a_route_backup_failure() {
    let provider = Provider::Grok;
    let (service, fake, _root, places) = fixture(provider, 30, vec![], true).await;
    let id = "grok-fixture";
    let mut record = super::Record {
        access_token: "fixture-access".into(),
        refresh_token: "fixture-stored-refresh".into(),
        expires_at: 1,
        region: None,
        device_id: None,
        sub: None,
        login: None,
        email: None,
    };
    super::save(provider, &places, id, false, &record).unwrap();
    record.refresh_token = "fixture-pending-refresh".into();
    service
        .pending_writes
        .lock()
        .unwrap()
        .insert((provider, places.home.clone(), id.into()), Arc::new(record));
    let instance =
        routes::find(places.routes.as_deref(), id).unwrap().file.credential_instance.unwrap();
    let backups = places.home.join("route-backups");
    std::fs::write(&backups, "blocks backup directory creation").unwrap();
    assert_eq!(
        service.remove(provider, places.clone(), id.into(), instance.clone()).await,
        Err("storage")
    );
    {
        let calls = fake.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert!(calls[0].contains("token=fixture-pending-refresh"));
        assert!(calls[1].contains("token=fixture-stored-refresh"));
    }
    assert!(routes::find(places.routes.as_deref(), id).is_ok());
    std::fs::remove_file(backups).unwrap();
    service.remove(provider, places.clone(), id.into(), instance).await.unwrap();
    assert!(routes::find(places.routes.as_deref(), id).is_err());
    assert_eq!(fake.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn disconnect_removes_retired_grok_and_copilot_grants_after_access_is_restored() {
    use crate::subscription_store::Error;

    for provider in [Provider::Grok, Provider::Copilot] {
        let (service, fake, _root, places) = fixture(provider, 30, vec![], true).await;
        let id = provider.name();
        let mut record = super::Record {
            access_token: "fixture-retired-access".into(),
            refresh_token: if provider == Provider::Grok { "fixture-retired-refresh" } else { "" }
                .into(),
            expires_at: if provider == Provider::Grok { 1 } else { 0 },
            region: None,
            device_id: None,
            sub: None,
            login: None,
            email: None,
        };
        super::save(provider, &places, id, false, &record).unwrap();
        let store = provider.store(&places.home);
        let retired = store.test_account(id);
        store.refuse_test_item(id, Error::KeychainOtherBuild);
        record.access_token = "fixture-active-access".into();
        if provider == Provider::Grok {
            record.refresh_token = "fixture-active-refresh".into();
        }
        super::save(provider, &places, id, true, &record).unwrap();
        let active = store.test_account(id);
        assert_ne!(active, retired);
        let foreign = Provider::Kimi.store(&places.home);
        let mut kimi = record.clone();
        kimi.region = Some(KimiRegion::Global);
        foreign.write(id, &kimi).unwrap();
        let foreign_account = foreign.test_account(id);

        let instance =
            routes::find(places.routes.as_deref(), id).unwrap().file.credential_instance.unwrap();
        assert_eq!(
            service.remove(provider, places.clone(), id.into(), instance.clone()).await,
            Err("keychain_other_build")
        );
        assert!(store.has_test_item(&active));
        assert!(routes::find(places.routes.as_deref(), id).is_ok());
        assert!(fake.calls.lock().unwrap().is_empty());

        store.allow_test_item(&retired);
        assert!(store.has_test_item(&retired));
        service.remove(provider, places.clone(), id.into(), instance).await.unwrap();
        assert!(!store.has_test_item(&active));
        assert!(!store.has_test_item(&retired));
        assert!(foreign.has_test_item(&foreign_account));
        assert!(routes::find(places.routes.as_deref(), id).is_err());
        if provider == Provider::Grok {
            let calls = fake.calls.lock().unwrap();
            assert_eq!(calls.len(), 2);
            assert!(calls[0].contains("token=fixture-active-refresh"));
            assert!(calls[1].contains("token=fixture-retired-refresh"));
        }
    }
}

#[tokio::test]
async fn kimi_reapproval_requires_the_saved_subject_before_replacing_the_grant() {
    let provider = Provider::Kimi;
    let approvals = [
        "fixture-no-identity",
        "fixture-access",
        "fixture-unavailable",
        "fixture-other",
        "fixture-same",
    ]
    .into_iter()
    .map(|token| {
        json!({
            "access_token": token, "refresh_token": format!("{token}-refresh"), "expires_in": 3600,
        })
    })
    .collect();
    let (service, _fake, _root, places) = fixture(provider, 30, approvals, true).await;
    let first = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
    assert!(matches!(
        service.wait(&first.attempt, Duration::from_secs(5)).await.unwrap(),
        Status::Failed("bad_reply")
    ));
    assert!(routes::load(places.routes.as_deref()).0.is_empty());
    assert!(!provider.store(&places.home).directory().exists());

    let first = service.begin(provider, places.clone(), None, None, || {}).await.unwrap();
    let Status::Done(id) = service.wait(&first.attempt, Duration::from_secs(5)).await.unwrap()
    else {
        panic!("the Kimi profile did not bind the approval");
    };
    let first_grant = provider.read(&places.home, &id).unwrap().unwrap();
    assert_eq!(first_grant.sub.as_deref(), Some("saved-subject"));

    for expected in ["provider_error", "different_account"] {
        let begun =
            service.begin(provider, places.clone(), Some(id.clone()), None, || {}).await.unwrap();
        let outcome = service.wait(&begun.attempt, Duration::from_secs(5)).await.unwrap();
        assert!(matches!(outcome, Status::Failed(code) if code == expected));
        let saved = provider.read(&places.home, &id).unwrap().unwrap();
        assert_eq!(saved.refresh_token, first_grant.refresh_token);
        assert_eq!(saved.sub.as_deref(), Some("saved-subject"));
        assert_eq!(
            routes::find(places.routes.as_deref(), &id).unwrap().name(),
            "Kimi Code (Saved name)"
        );
    }

    let begun =
        service.begin(provider, places.clone(), Some(id.clone()), None, || {}).await.unwrap();
    let outcome = service.wait(&begun.attempt, Duration::from_secs(5)).await.unwrap();
    assert!(matches!(outcome, Status::Done(route) if route == id));
    let saved = provider.read(&places.home, &id).unwrap().unwrap();
    assert_eq!(saved.refresh_token, "fixture-same-refresh");
    assert_eq!(saved.sub.as_deref(), Some("saved-subject"));
}

#[tokio::test]
async fn kimi_refresh_only_discards_grant_on_unauthorized_or_invalid_grant() {
    let provider = Provider::Kimi;
    let (service, _fake, _root, places) = fixture(
        provider,
        30,
        vec![json!("forbidden"), json!("unauthorized"), json!({"error": "invalid_grant"})],
        true,
    )
    .await;
    let id = "kimi-fixture";
    let record = super::Record {
        access_token: "fixture-access".into(),
        refresh_token: "fixture-refresh".into(),
        expires_at: 1,
        region: Some(KimiRegion::Global),
        device_id: None,
        sub: Some("saved-subject".into()),
        login: None,
        email: None,
    };
    provider.write(&places.home, id, &record).unwrap();
    assert!(matches!(service.grant(provider, &places.home, id, 0).await, Err("provider_error")));
    assert!(provider.read(&places.home, id).unwrap().is_some());

    for _ in 0..2 {
        assert!(matches!(
            service.grant(provider, &places.home, id, 0).await,
            Err("reauth_required")
        ));
        let cleared = provider.read(&places.home, id).unwrap().unwrap();
        assert!(cleared.refresh_token.is_empty());
        assert_eq!(cleared.sub.as_deref(), Some("saved-subject"));
        assert!(!provider.signed_in(&places.home, id));
        provider.write(&places.home, id, &record).unwrap();
    }
}
