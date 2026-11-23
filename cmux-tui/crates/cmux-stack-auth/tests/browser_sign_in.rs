//! Browser enrollment exercises the existing Stack wire flow without any daemon credential.

mod fake;

use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_stack_auth::{BrowserSignIn, BrowserSignInError, StackClient, StackConfig};
use fake::{ok, serve, status, token};
use serde_json::json;

const ORIGIN: &str = "https://browser.example.test";
const CALLBACK: &str = "https://account.example.test/auth/callback";

fn client(origin: &str) -> StackClient {
    let mut config = StackConfig::new(origin, "browser-project", "public-key");
    config.transport_retries = 0;
    StackClient::new(config).unwrap()
}

fn key() -> String {
    STANDARD.encode([7_u8; 32])
}

#[tokio::test]
async fn browser_sign_in_returns_only_its_own_token_and_bound_device_key() {
    let access = token(600, 600, "browser-session");
    let minted = access.clone();
    let (origin, log) = serve(move |seen| match seen.target.as_str() {
        "/api/v1/auth/otp/send-sign-in-code" => {
            assert_eq!(
                seen.json(),
                json!({"email": "owner@example.test", "callback_url": CALLBACK})
            );
            ok(json!({"nonce": "OpaqueNONCE"}))
        }
        "/api/v1/auth/otp/sign-in" => {
            assert_eq!(seen.json(), json!({"code": "ab12cdOpaqueNONCE"}));
            ok(json!({"access_token": minted, "refresh_token": "never-returned"}))
        }
        "/api/v1/users/me" => {
            assert_eq!(seen.header("x-hexclave-access-token").as_deref(), Some(minted.as_str()));
            ok(json!({"id": "owner"}))
        }
        _ => panic!("unexpected Stack route"),
    });
    let stack = client(&origin);
    let attempt =
        BrowserSignIn::start(&stack, ORIGIN, "owner", &key(), " owner@example.test ", CALLBACK)
            .await
            .unwrap();
    assert!(!format!("{attempt:?}").contains("OpaqueNONCE"));
    let enrollment = attempt.complete(&stack, ORIGIN, " AB12CD ").await.unwrap();
    assert_eq!(enrollment.access_token, access);
    assert_eq!(enrollment.public_key, key());
    assert_eq!(
        serde_json::to_value(&enrollment).unwrap(),
        json!({"accessToken": access, "publicKey": key()})
    );
    assert!(!format!("{enrollment:?}").contains(&access));
    let requests = log.lock().unwrap();
    assert_eq!(requests.len(), 3);
    for request in &requests[..2] {
        assert_eq!(request.header("authorization"), None);
        assert_eq!(request.header("x-hexclave-access-token"), None);
        assert_eq!(request.header("x-hexclave-refresh-token"), None);
    }
}

#[tokio::test]
async fn browser_sign_in_rejects_other_accounts_and_restricted_users() {
    for user in [json!({"id": "other"}), json!({"id": "owner", "is_restricted": true}), json!({})] {
        let (origin, _) = serve(move |seen| match seen.target.as_str() {
            "/api/v1/auth/otp/send-sign-in-code" => ok(json!({"nonce": "nonce"})),
            "/api/v1/auth/otp/sign-in" => ok(json!({
                "access_token": token(600, 600, "other"), "refresh_token": "refresh"
            })),
            "/api/v1/users/me" => ok(user.clone()),
            _ => panic!("unexpected Stack route"),
        });
        let stack = client(&origin);
        let attempt =
            BrowserSignIn::start(&stack, ORIGIN, "owner", &key(), "a@example.test", CALLBACK)
                .await
                .unwrap();
        assert_eq!(
            attempt.complete(&stack, ORIGIN, "123456").await.unwrap_err(),
            BrowserSignInError::AccountMismatch
        );
    }
}

#[tokio::test]
async fn browser_sign_in_binds_origin_and_expires_before_exchanging_a_code() {
    let (origin, log) = serve(|_| ok(json!({"nonce": "nonce"})));
    let stack = client(&origin);
    let attempt = BrowserSignIn::start(&stack, ORIGIN, "owner", &key(), "a@example.test", CALLBACK)
        .await
        .unwrap();
    assert_eq!(
        attempt.complete(&stack, "https://other.example.test", "123456").await.unwrap_err(),
        BrowserSignInError::InvalidOrigin
    );
    let attempt = BrowserSignIn::start(&stack, ORIGIN, "owner", &key(), "a@example.test", CALLBACK)
        .await
        .unwrap();
    // Advance only after network IO: the deadline must not require a five-minute test sleep.
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(301)).await;
    assert_eq!(
        attempt.complete(&stack, ORIGIN, "123456").await.unwrap_err(),
        BrowserSignInError::Expired
    );
    assert_eq!(log.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn browser_sign_in_rejects_invalid_inputs_without_sending_email() {
    let (origin, log) = serve(|_| panic!("invalid input reached Stack"));
    let stack = client(&origin);
    for origin in [
        "null",
        "http://example.test",
        "https://user@example.test",
        "https://example.test/path",
        "https://example.test?token=secret",
        "https://example.test/#secret",
    ] {
        assert_eq!(
            BrowserSignIn::start(&stack, origin, "owner", &key(), "a@example.test", CALLBACK)
                .await
                .unwrap_err(),
            BrowserSignInError::InvalidOrigin
        );
    }
    for key in ["bad".to_owned(), STANDARD.encode([1_u8; 31]), STANDARD.encode([1_u8; 33])] {
        assert_eq!(
            BrowserSignIn::start(&stack, ORIGIN, "owner", &key, "a@example.test", CALLBACK)
                .await
                .unwrap_err(),
            BrowserSignInError::InvalidPublicKey
        );
    }
    assert_eq!(
        BrowserSignIn::start(&stack, ORIGIN, "", &key(), "a@example.test", CALLBACK)
            .await
            .unwrap_err(),
        BrowserSignInError::InvalidInput
    );
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn browser_sign_in_does_not_expose_stack_errors_or_treat_an_outage_as_a_bad_code() {
    for (status_code, expected) in [
        (400, BrowserSignInError::CodeRefused),
        (429, BrowserSignInError::RateLimited),
        (503, BrowserSignInError::Unavailable),
    ] {
        let (origin, _) = serve(move |seen| {
            if seen.target.ends_with("/send-sign-in-code") {
                ok(json!({"nonce": "nonce"}))
            } else {
                status(status_code, json!({"error": "secret-provider-response"}))
            }
        });
        let stack = client(&origin);
        let attempt =
            BrowserSignIn::start(&stack, ORIGIN, "owner", &key(), "a@example.test", CALLBACK)
                .await
                .unwrap();
        let error = attempt.complete(&stack, ORIGIN, "123456").await.unwrap_err();
        assert_eq!(error, expected);
        assert!(!format!("{error:?} {error}").contains("secret-provider-response"));
    }
}
