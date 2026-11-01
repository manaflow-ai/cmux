//! Wire tests of the cloud lease gate (`cloud-lease-app-only-v1`,
//! plans/cmux-next/home-cloud-proxy.md section 3, cmux#13742): the human's
//! lease is the verified cmux app's. Another same-uid process on the socket
//! cannot replace or clear it, and only the app sends `origin: "user"`.

use std::time::{Duration, Instant};

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::tests::captured_writer;
use super::super::*;
use crate::cloud_conversations::testing::FakeBackend;
use crate::cloud_conversations::{CloudConversations, ServiceOptions};

const APP_BASE: &str = "https://api.cmux.test";

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

/// A daemon with a scripted cloud, the verified app's connection and a plain
/// same-uid socket client.
fn daemon() -> (Arc<Mux>, u64, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("cloud-lease-gate", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = ServiceOptions {
        linger: Duration::ZERO,
        api_origins: vec![APP_BASE.into(), "https://other.example".into()],
        ..ServiceOptions::default()
    };
    assert!(
        mux.install_cloud_conversations(CloudConversations::with_options(backend.clone(), options))
    );
    let app = mux.control_clients.register(ClientTransport::Unix, writer());
    set_role_for_test(&mux, app, "main");
    set_verified_app_for_test(&mux, app, true);
    let plain = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, app, plain, backend)
}

/// The reply line of `request` through the full request path.
fn reply(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let (writer, outbound) = captured_writer();
    let request: Request = serde_json::from_value(request).unwrap();
    assert!(handle_request(mux, client, request, &writer));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(line) = outbound.try_pop() {
            return serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn set(base: &str, token: &str) -> Value {
    json!({"id":1,"cmd":"cloud-session-set","api_base_url":base,"access_token":token,
           "expires_at":4_102_444_800_000_u64})
}

fn user_op() -> Value {
    json!({"id":2,"cmd":"cloud-conversation-op","idempotency_key":"dm-1","origin":"user",
           "op":{"kind":"dm.open","peer":"user_00000000000000000002"}})
}

fn assert_forbidden(reply: &Value, what: &str) {
    assert_eq!(reply["ok"], false, "{what}: {reply}");
    assert_eq!(reply["error_code"], "cloud_conversation_rejected", "{what}: {reply}");
    assert_eq!(reply["reason"], "forbidden", "{what}: {reply}");
    assert_eq!(reply["retryable"], false, "{what}: {reply}");
    assert!(
        reply["error"].as_str().unwrap_or_default().contains("verified cmux app"),
        "{what}: {reply}"
    );
}

#[test]
fn identify_advertises_the_app_only_lease() {
    let (mux, _, plain, _) = daemon();
    let identity = reply(&mux, plain, json!({"id":1,"cmd":"identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "cloud-lease-app-only-v1"), "{identity}");
}

#[test]
fn the_verified_app_sets_clears_and_sends_as_the_user() {
    let (mux, app, _, backend) = daemon();
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);
    backend.reply("/v1/ops", 200, json!({"ok":true,"op":"dm.open",
        "value":{"conversation":{"id":"conv_dm_0123456789ABCDEFGHJKMNPQRS","owner":"cloud"}},"revision":"1",
        "transaction":"tx-dm","idempotency_key":"dm-1","replayed":false,"stream":"conv:conv_dm_0123456789ABCDEFGHJKMNPQRS","sequence":1}));
    let sent = reply(&mux, app, user_op());
    assert_eq!(sent["ok"], true, "{sent}");
    let posted = backend.posted();
    assert_eq!(posted.len(), 1);
    assert_eq!(posted[0].body["origin"], "user");
    assert_eq!(posted[0].bearer, "app.jwt");
    let cleared = reply(&mux, app, json!({"id":3,"cmd":"cloud-session-clear"}));
    assert_eq!(cleared["data"], json!({"state":"signed_out"}), "{cleared}");
}

#[test]
fn a_plain_client_cannot_replace_clear_or_speak_for_the_apps_lease() {
    let (mux, app, plain, backend) = daemon();
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);

    assert_forbidden(&reply(&mux, plain, set("https://attacker.example", "other.jwt")), "set");
    assert_forbidden(&reply(&mux, plain, json!({"id":3,"cmd":"cloud-session-clear"})), "clear");
    assert_forbidden(&reply(&mux, plain, user_op()), "origin user");
    assert!(backend.posted().is_empty(), "a refused op sends nothing");

    // The app's lease is untouched.
    let status = reply(&mux, plain, json!({"id":4,"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
    assert_eq!(status["data"]["api_base_url"], APP_BASE, "{status}");
}

#[test]
fn a_daemon_without_an_app_lease_keeps_a_headless_brain_working() {
    // optchat-chief leases its own chief token to a daemon of its own, where
    // no app ever connects; it never claims origin user.
    let (mux, _, plain, _) = daemon();
    assert_eq!(reply(&mux, plain, set(APP_BASE, "chief.jwt"))["ok"], true);
    assert_forbidden(&reply(&mux, plain, user_op()), "origin user without the app");
    let cleared = reply(&mux, plain, json!({"id":3,"cmd":"cloud-session-clear"}));
    assert_eq!(cleared["ok"], true, "{cleared}");
}

#[test]
fn the_app_takes_over_a_lease_another_client_set() {
    let (mux, app, plain, _) = daemon();
    assert_eq!(reply(&mux, plain, set("https://other.example", "other.jwt"))["ok"], true);
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);
    assert_forbidden(&reply(&mux, plain, set("https://other.example", "again.jwt")), "set");
}

const PLATFORM_BASE: &str = "https://cmux-platform-development.debussy.workers.dev";

fn environment(action: &str, params: Value) -> Value {
    json!({"id":11,"cmd":"cloud-environment","action":action,"params":params,
        "platform_origin":PLATFORM_BASE,"access_token":"install.jwt"})
}

#[test]
fn cloud_environment_reads_and_patch_use_the_install_token_and_never_return_secret_values() {
    let (mux, app, plain, backend) = daemon();
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);
    let record = json!({"id":"env_default","name":"Default","is_default":true,
        "setup_script":null,"env_vars":[],"secrets":[{"name":"TOKEN","updated_at":"now","value":"never-return"}],
        "network":{"mode":"full","package_managers":true,"domains":[]}});
    backend.reply("/v1/cloud-environments", 200, json!([record.clone()]));
    let listed = reply(&mux, app, environment("list", json!({})));
    assert_eq!(listed["ok"], true, "{listed}");
    assert_eq!(listed["data"][0]["secrets"], json!([{"name":"TOKEN","updated_at":"now"}]));
    backend.reply("/v1/cloud-environments/env_default", 200, record.clone());
    let read = reply(&mux, app, environment("get", json!({"id":"env_default"})));
    assert_eq!(read["data"]["name"], "Default", "{read}");
    let patch = json!({"setup_script":null,"env_vars":[],"set_secrets":[{"name":"TOKEN","value":"write-only"}],
        "remove_secrets":["OLD"],"network":{"mode":"limited","package_managers":false,"domains":["example.com"]}});
    backend.reply("/v1/cloud-environments/env_default", 200, record);
    let updated =
        reply(&mux, app, environment("update", json!({"id":"env_default","patch":patch})));
    assert_eq!(updated["ok"], true, "{updated}");
    assert!(!updated.to_string().contains("never-return"));
    let patched = backend.patched.lock().unwrap();
    assert_eq!(patched.len(), 1);
    assert_eq!(patched[0].url, format!("{PLATFORM_BASE}/v1/cloud-environments/env_default"));
    assert_eq!(patched[0].body, patch, "null and write-only values reach PATCH unchanged");
    assert_eq!(patched[0].bearer, "install.jwt");
    drop(patched);
    assert!(backend.got().iter().all(|read| read.bearer == "install.jwt"));
    assert_forbidden(&reply(&mux, plain, environment("list", json!({}))), "environment read");
    assert_forbidden(
        &reply(&mux, plain, environment("update", json!({"id":"env_default","patch":{}}))),
        "environment write",
    );
}

#[test]
fn cloud_environment_rejects_path_injection_unknown_patch_and_keeps_platform_error_code() {
    let (mux, app, _, backend) = daemon();
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);
    for request in [
        environment("get", json!({"id":"../auth/token"})),
        environment("list", json!({"url":"https://elsewhere"})),
        environment("update", json!({"id":"env_default","patch":{"scope":"team"}})),
    ] {
        assert_eq!(reply(&mux, app, request)["ok"], false);
    }
    assert!(backend.got().is_empty());
    assert!(backend.patched.lock().unwrap().is_empty());
    backend.reply("/v1/cloud-environments/env_default", 409,
        json!({"error":{"code":"cloud_environment.default_locked","message":"invalid secret write-only"}}));
    let refused = reply(
        &mux,
        app,
        environment("update", json!({"id":"env_default","patch":{"name":"Renamed"}})),
    );
    assert_eq!(refused["error_code"], "cloud_environment.default_locked", "{refused}");
    assert!(!refused.to_string().contains("write-only"));
}

#[test]
fn cloud_environment_derive_uses_install_token_and_request_diagnostics_redact_secrets() {
    let (mux, app, _, backend) = daemon();
    assert_eq!(reply(&mux, app, set(APP_BASE, "app.jwt"))["ok"], true);
    let params = json!({"repo":"owner/project","ref":"main","environment":"env_default"});
    backend.reply(
        "/v1/environments/derive",
        200,
        json!({"setup":{"script":"#!/bin/bash\nbun install"}}),
    );
    let derived = reply(&mux, app, environment("derive", params.clone()));
    assert_eq!(derived["data"]["setup"]["script"], "#!/bin/bash\nbun install", "{derived}");
    assert_eq!(backend.posted()[0].body, params);
    assert_eq!(backend.posted()[0].bearer, "install.jwt");
    let request: super::EnvironmentParams = serde_json::from_value(json!({"action":"update","platform_origin":PLATFORM_BASE,"access_token":"credential-secret",
        "params":{"id":"env_default","patch":{"set_secrets":[{"name":"TOKEN","value":"sensitive"}]}}})).unwrap();
    assert!(!format!("{request:?}").contains("sensitive"));
    assert!(!format!("{request:?}").contains("credential-secret"));
}

#[test]
fn cloud_environment_works_without_a_home_lease_and_keeps_flat_platform_errors() {
    let (mux, app, _, backend) = daemon();
    let status = reply(&mux, app, json!({"id":1,"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "signed_out", "{status}");
    backend.reply("/v1/cloud-environments", 200, json!([]));
    let listed = reply(&mux, app, environment("list", json!({})));
    assert_eq!(listed["data"], json!([]), "{listed}");
    assert_eq!(backend.got()[0].bearer, "install.jwt");
    for (status, code, retryable) in [
        (400, "cloud_environment.invalid", false),
        (503, "cloud_environment.secrets_unavailable", true),
    ] {
        backend.reply("/v1/cloud-environments/env_default", status,
            json!({"_tag":"CloudEnvironmentError","code":code,"message":"submitted write-only-secret"}));
        let refused =
            reply(&mux, app, environment("update", json!({"id":"env_default","patch":{}})));
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error_code"], code, "{refused}");
        assert_eq!(refused["retryable"], retryable, "{refused}");
        assert!(!refused.to_string().contains("write-only-secret"));
    }
}

#[test]
fn cloud_environment_rejects_untrusted_origins_before_sending_the_install_token() {
    let (mux, app, _, backend) = daemon();
    for origin in [
        "https://attacker.example",
        "https://cmux-platform-development.debussy.workers.dev.attacker.example",
        "http://cmux-platform-development.debussy.workers.dev",
        "https://cmux-platform-development.debussy.workers.dev:8443",
        "https://user:password@cmux-platform-development.debussy.workers.dev",
        "https://cmux-platform-development.debussy.workers.dev/path",
        "https://cmux-platform-development.debussy.workers.dev?next=elsewhere",
        "https://cmux-platform-development.debussy.workers.dev#fragment",
    ] {
        let mut request = environment("list", json!({}));
        request["platform_origin"] = json!(origin);
        let refused = reply(&mux, app, request);
        assert_eq!(refused["ok"], false, "{origin}: {refused}");
    }
    assert!(backend.got().is_empty());
    assert!(backend.posted().is_empty());
    assert!(backend.patched.lock().unwrap().is_empty());
}
