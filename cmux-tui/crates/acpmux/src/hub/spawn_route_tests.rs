use super::*;
use crate::agent_credentials::{AgentCredential, CHATGPT_TOKEN, CLAUDE_OAUTH, OPENAI_KEY};
use crate::hub::NewRequest;
use crate::{chatgpt, routes};

const ROUTE: &str = "chatgpt-test";

fn fixture(root: &Path) -> (Arc<Hub>, HarnessProfile) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "store": {"mode": "memory"},
        "harnesses": {"codex-fake": {"argv": ["python3", fake], "family": "codex"}},
        "defaultHarness": "codex-fake",
    }))
    .unwrap();
    config.path = Some(root.join("config.json"));
    config.profile_sources = crate::config::ProfileSources::none();
    config.profile_sources.cmux_json = Some(root.join("cmux.json"));
    let (dir, _) = routes::places(&config);
    let route =
        serde_json::from_value(json!({"kind": "chatgpt-plan", "families": ["codex"]})).unwrap();
    routes::add(dir.as_deref(), ROUTE, &route, false).unwrap();
    routes::set_binding(root, "family:codex", Some(ROUTE)).unwrap();
    let profile = config.harnesses["codex-fake"].clone();
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
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(native_id.as_str()));
    let launch_env = session.launch_env.lock().unwrap();
    assert_eq!(launch_env.as_ref().unwrap()[CHATGPT_TOKEN], "fixture-after-refresh");
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
