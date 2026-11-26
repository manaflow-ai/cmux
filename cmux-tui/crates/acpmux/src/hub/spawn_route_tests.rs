use super::*;
use crate::agent_credentials::{AgentCredential, CHATGPT_TOKEN, CLAUDE_OAUTH, OPENAI_KEY};
use crate::hub::NewRequest;
use crate::{chatgpt, routes};

const ROUTE: &str = "chatgpt-test";

fn fixture(root: &Path) -> (Arc<Hub>, HarnessProfile) {
    fixture_for(root, "codex", "chatgpt-plan", ROUTE)
}

fn fixture_for(root: &Path, family: &str, kind: &str, id: &str) -> (Arc<Hub>, HarnessProfile) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "store": {"mode": "memory"},
        "harnesses": {"route-fake": {"argv": ["python3", fake], "family": family}},
        "defaultHarness": "route-fake",
    }))
    .unwrap();
    config.path = Some(root.join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(root.join("cmux.json"));
    let (dir, _) = routes::places(&config);
    let route = serde_json::from_value(json!({"kind": kind, "families": [family]})).unwrap();
    routes::add(dir.as_deref(), id, &route, false).unwrap();
    routes::set_binding(root, &format!("family:{family}"), Some(id)).unwrap();
    let profile = config.harnesses["route-fake"].clone();
    let store = crate::store::open(&config.store, root).unwrap();
    (Hub::new(config, store), profile)
}

fn save_chatgpt(root: &Path, token: &str) {
    chatgpt::store::write(
        root,
        ROUTE,
        &chatgpt::store::Record {
            client_id: chatgpt::CODEX_CLIENT_ID.into(),
            sub: "fixture-account".into(),
            access_token: token.into(),
            refresh_token: "fixture-refresh".into(),
            expires_at: chatgpt::now_unix() + 3600,
            ..Default::default()
        },
    )
    .unwrap();
}

fn save_kimi(root: &Path, id: &str, token: &str, expiry: i64) {
    crate::subscription_store::Store::new(root, "kimi")
        .write(
            id,
            &json!({
                "access_token": token,
                "refresh_token": "fixture-refresh",
                "expires_at": expiry,
                "region": "global",
            }),
        )
        .unwrap();
}

#[tokio::test]
async fn a_mismatched_cloud_credential_keeps_the_machine_route() {
    let root = tempfile::tempdir().unwrap();
    let (hub, profile) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-machine-access");
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let claude =
        AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: "sk-ant-oat01-fixture"}})).unwrap();
    let spawn = hub
        .spawn_profile_with(&session.meta(), &profile, &Default::default(), Some(&claude))
        .await
        .unwrap();
    assert_eq!(spawn.env.get(CHATGPT_TOKEN).map(String::as_str), Some("fixture-machine-access"));
    assert!(!spawn.env.contains_key(CLAUDE_OAUTH));
    assert!(!spawn.env.contains_key(crate::agent_credentials::MARKER));

    let codex = AgentCredential::parse(&json!({"env": {OPENAI_KEY: "sk-fixture"}})).unwrap();
    let spawn = hub
        .spawn_profile_with(&session.meta(), &profile, &Default::default(), Some(&codex))
        .await
        .unwrap();
    assert_eq!(spawn.env.get(OPENAI_KEY).map(String::as_str), Some("sk-fixture"));
    assert!(!spawn.env.contains_key(CHATGPT_TOKEN));
}

#[tokio::test]
async fn local_chatgpt_refresh_resumes_the_chat_before_the_next_turn() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-before-refresh");
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    let native_id = session.meta().agent_session_id.unwrap();
    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before);

    // Another chat refreshed the shared account while this child kept its old token.
    save_chatgpt(root.path(), "fixture-after-refresh");
    session
        .launch_env
        .lock()
        .unwrap()
        .as_mut()
        .unwrap()
        .insert(chatgpt::LOCAL_EXPIRY_ENV.into(), (chatgpt::now_unix() + 1).to_string());
    *session.work_below_since.lock().unwrap() = 1;
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before);
    *session.work_below_since.lock().unwrap() = 0;
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(native_id.as_str()));
    let launch_env = session.launch_env.lock().unwrap();
    assert_eq!(launch_env.as_ref().unwrap()[CHATGPT_TOKEN], "fixture-after-refresh");
}

#[tokio::test]
async fn a_local_chatgpt_plan_token_echo_is_redacted_from_the_journal() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    let token = "fixture-chatgpt-credential-echo";
    save_chatgpt(root.path(), token);
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.prompt(
        &session,
        vec![json!({"type": "text", "text": format!("env: {CHATGPT_TOKEN}")})],
        "test",
        false,
    )
    .await
    .unwrap();
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let log = serde_json::to_string(&records).unwrap();
    assert!(log.contains(&format!("{CHATGPT_TOKEN}=[redacted]")));
    assert!(!log.contains(token));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn local_kimi_refresh_replaces_the_launch_grant_before_a_turn() {
    let root = tempfile::tempdir().unwrap();
    let id = "kimi-test";
    let (hub, _) = fixture_for(root.path(), "opencode", "kimi-plan", id);
    let now = crate::subscriptions::now();
    save_kimi(root.path(), id, "kimi-before-refresh", now + 3600);
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    let native_id = session.meta().agent_session_id.unwrap();
    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before);
    {
        let mut launch = session.launch_env.lock().unwrap();
        let env = launch.as_mut().unwrap();
        assert_eq!(env[crate::subscriptions::LOCAL_KIMI_EXPIRY], (now + 3600).to_string());
        env.insert(crate::subscriptions::LOCAL_KIMI_EXPIRY.into(), (now - 1).to_string());
    }
    save_kimi(root.path(), id, "kimi-after-refresh", now + 7200);
    *session.work_below_since.lock().unwrap() = 1;
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before);
    *session.work_below_since.lock().unwrap() = 0;
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(native_id.as_str()));
    let launch = session.launch_env.lock().unwrap();
    assert_eq!(launch.as_ref().unwrap()[crate::byo_endpoint::OPENAI_KEY_ENV], "kimi-after-refresh");
}

#[tokio::test]
async fn adopted_chatgpt_without_a_launch_snapshot_uses_the_accounts_expiry() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-live-token");
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let stored = chatgpt::store::read(root.path(), ROUTE).unwrap().unwrap();
    let expiry = hub.legacy_adopted_chatgpt_expiry(&session, None).await;
    assert_eq!(expiry, Some(stored.expires_at));
    assert!(expiry.unwrap() - chatgpt::now_unix() > chatgpt::REFRESH_MARGIN_SECS);
}

#[tokio::test]
async fn a_local_claude_chat_cannot_switch_to_a_cloud_token() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture_for(root.path(), "claude", "direct-subscription", "ordinary");
    let (dir, _) = routes::places(&*hub.config.read().await);
    let id = routes::add_claude_token(dir.as_deref(), "keychain:fixture/token", None).unwrap().id;
    let req = || NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() };
    let session = hub.new_session(req()).await.unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;

    let error = hub.set_chat_route(&session, Some(id.clone()), false).await.unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "route.unavailable");
    assert!(routes::bindings(root.path()).chats.get(&session.id).is_none());
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before);

    let start = hub.new_session(NewRequest { route: Some(id.into()), ..req() }).await;
    assert_eq!(start.err().unwrap().data.unwrap()["reason"], "route.unavailable");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_later_chat_route_supersedes_an_explicit_claude_team_launch() {
    let root = tempfile::tempdir().unwrap();
    let id = "another-account";
    let (hub, _) = fixture_for(root.path(), "claude", "direct-subscription", id);
    routes::set_binding(root.path(), "family:claude", None).unwrap();
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    {
        let mut meta = session.meta.lock().unwrap();
        meta.session_env.insert("CMUX_CLAUDE_AUTH".into(), "team".into());
        meta.session_env.insert(crate::claude_cloud_auth::REQUIRED_TEAM.into(), "1".into());
    }

    let result = hub.set_chat_route(&session, Some(id.into()), false).await.unwrap();
    assert_eq!(result["applied"], "now");
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    {
        let launched = session.launch_env.lock().unwrap();
        let env = launched.as_ref().unwrap();
        assert_eq!(env.get(routes::NAME_KEY).map(String::as_str), Some(id));
        assert!(!env.contains_key(crate::claude_cloud_auth::TEAM_MARKER));
    }
    hub.shutdown_all().await;
}

#[tokio::test]
async fn an_old_grok_caller_cannot_read_the_new_binding() {
    use crate::rpc::{Message, method};
    use std::time::Duration;

    let root = tempfile::tempdir().unwrap();
    let id = "grok-other";
    let (hub, _) = fixture_for(root.path(), "grok", "grok-plan", id);
    routes::set_binding(root.path(), "family:grok", None).unwrap();
    crate::subscription_store::Store::new(root.path(), "grok")
        .write(
            id,
            &json!({
                "access_token": "fixture-grok-other-account",
                "refresh_token": "fixture-refresh",
                "expires_at": crate::subscriptions::now() + 3600,
            }),
        )
        .unwrap();
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.child_for(&session).await.unwrap();

    let (incoming, in_rx) = tokio::sync::mpsc::channel(8);
    let (out_tx, mut outgoing) = tokio::sync::mpsc::channel(64);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let mut call = async |seq: i64, name: &str, params: Value| {
        incoming.send(Message::request(seq, name, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let v: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                if v["id"] == seq {
                    return v;
                }
            }
        })
        .await
        .unwrap()
    };
    let initialized = call(
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "_meta": {
            "acpmux": {"callerSession": {"sessionId": session.id,
                                        "token": crate::hub::person::caller_token(&session.id)}}
        }}),
    )
    .await;
    assert!(initialized.get("error").is_none());
    assert_eq!(
        initialized["result"]["_meta"]["acpmux"]["callerSessionId"].as_str(),
        Some(session.id.as_str()),
    );

    let prompting = tokio::spawn({
        let hub = hub.clone();
        let session = session.clone();
        async move {
            hub.prompt(
                &session,
                vec![json!({"type": "text", "text": "ticking:100:20"})],
                "test",
                false,
            )
            .await
        }
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while session.turn().is_none() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let moved =
        call(2, method::MUX_CHAT_ROUTE_SET, json!({"sessionId": session.id, "routeId": id})).await;
    assert_eq!(moved["result"]["applied"], "after-turn");
    let reply = call(3, method::MUX_CONNECTIONS_GROK_HOOK, json!({"id": id})).await;
    assert_eq!(reply["error"]["code"], -32601);
    assert!(reply.get("result").is_none());

    let _ = prompting.await.unwrap();
    hub.shutdown_all().await;
}

#[tokio::test]
async fn delivered_endpoints_do_not_launch_without_a_destination_guard() {
    let root = tempfile::tempdir().unwrap();
    let (hub, profile) = fixture_for(root.path(), "opencode", "direct-subscription", "ordinary");
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    // A public IP passes the previous preflight without requiring DNS or network access.
    let payload = json!({
        "env": {crate::byo_endpoint::OPENAI_KEY_ENV: "fixture-endpoint-key"},
        "endpoint": {"kind": "openai", "baseUrl": "https://8.8.8.8/v1", "models": ["model"]},
    });
    let error =
        crate::agent_credentials::requested(Some(&json!({"credentials": payload}))).err().unwrap();
    assert_eq!(error.data.unwrap()["reason"], "credentials.endpoint_unavailable");

    // A recovered grant can bypass wire parsing. It must also be refused at spawn.
    let credential = AgentCredential::parse(&payload).unwrap();
    let result = hub
        .spawn_profile_with(&session.meta(), &profile, &Default::default(), Some(&credential))
        .await;
    assert_eq!(result.err().unwrap().data.unwrap()["reason"], "credentials.endpoint_unavailable");
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn completion_uses_the_selected_subscription_and_redacts_its_grant() {
    use std::os::unix::fs::PermissionsExt;

    const TOKEN: &str = "fixture-completion-subscription-grant";
    for (family, kind, var) in [
        ("codex", "chatgpt-plan", CHATGPT_TOKEN),
        ("opencode", "kimi-plan", crate::byo_endpoint::OPENAI_KEY_ENV),
    ] {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path();
        let id = if family == "codex" { ROUTE } else { "kimi-test" };
        let (hub, _) = fixture_for(dir, family, kind, id);
        let program = dir.join(family);
        let program_body = if family == "codex" {
            r#"
test "$1" = exec && test "$2" = -c || exit 10
test "$3" = 'model_provider="openai_chatgpt_plan"' || exit 11
case " $* " in
  *'model_providers.openai_chatgpt_plan.base_url="https://chatgpt.com/backend-api/codex"'*) ;;
  *) exit 12 ;;
esac
case " $* " in
  *'model_providers.openai_chatgpt_plan.env_key="CMUX_CHATGPT_ACCESS_TOKEN"'*) ;;
  *) exit 13 ;;
esac
case " $* " in
  *' fixture-failure '*) echo "rejected: $grant" >&2; exit 1 ;;
esac
while [ "$1" != --output-last-message ]; do shift || exit 3; done
printf '%s\n' "$grant" > "$2"
"#
        } else {
            r#"
case " $* " in
  *' --model byo/kimi-for-coding '*) ;;
  *) exit 10 ;;
esac
case "$OPENCODE_CONFIG_CONTENT" in
  *'"baseURL":"https://api.kimi.ai/coding/v1"'*) ;;
  *) exit 11 ;;
esac
case "$OPENCODE_CONFIG_CONTENT" in
  *'"enabled_providers":["byo"]'*) ;;
  *) exit 12 ;;
esac
case "$OPENCODE_CONFIG_CONTENT" in
  *'"permission":{"*":"deny"}'*) ;;
  *) exit 13 ;;
esac
while [ "$1" != --file ]; do shift || exit 3; done
if [ "$(cat "$2")" = fixture-failure ]; then echo "rejected: $grant" >&2; exit 1; fi
printf '%s\n' "$grant"
"#
        };
        std::fs::write(&program, format!("#!/bin/sh\ngrant=${{{var}}}\n{program_body}\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        hub.config.write().await.harnesses.get_mut("route-fake").unwrap().argv =
            vec![program.to_string_lossy().into_owned()];
        if family == "codex" {
            save_chatgpt(dir, TOKEN);
        } else {
            save_kimi(dir, id, TOKEN, crate::subscriptions::now() + 3600);
        }
        let request = |fail| {
            json!({
                "prompt": if fail { "fixture-failure" } else { "fixture" },
                "harness": "route-fake",
                "model": if family == "codex" {
                    Some(if fail { "fixture-failure" } else { "fixture-model" })
                } else {
                    None
                }
            })
        };

        let local = crate::server::Origin::Local;
        let mut success = request(false);
        if family == "opencode" {
            success.as_object_mut().unwrap().remove("model");
        }
        let success = hub.complete(local, &success).await.unwrap();
        assert_eq!(success["text"], "[redacted]");
        let mut failure = request(true);
        if family == "opencode" {
            failure["model"] = json!(crate::subscriptions::KIMI_MODEL);
        }
        let rpc = hub.complete(local, &failure).await.unwrap_err();
        assert!(rpc.message.contains("rejected: [redacted]"));
        assert!(!rpc.message.contains(TOKEN));
        assert!(!rpc.data.unwrap().to_string().contains(TOKEN));
        if family == "opencode" {
            let wrong = json!({
                "prompt": "fixture", "harness": "route-fake", "model": "ambient/another-model"
            });
            assert!(
                hub.complete(local, &wrong).await.unwrap_err().message.contains("model not found")
            );
        }
    }
}
