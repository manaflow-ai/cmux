use super::*;
use crate::agent_credentials::{AgentCredential, CHATGPT_TOKEN, CLAUDE_OAUTH, OPENAI_KEY};
use crate::hub::NewRequest;
use crate::{chatgpt, routes};
use std::collections::BTreeMap;

const ROUTE: &str = "chatgpt-test";

fn fixture(root: &Path) -> (Arc<Hub>, HarnessProfile) {
    fixture_for(root, "codex", "chatgpt-plan", ROUTE)
}

#[tokio::test]
async fn chatgpt_plan_refuses_codex_acp_before_applying_its_grant() {
    let root = tempfile::tempdir().unwrap();
    let (hub, mut profile) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-adapter-grant");
    profile.argv = vec!["codex-acp".into()];
    let mut env = profile.env.clone();
    let error =
        hub.apply_route_for("codex-acp", None, None, false, &profile, &mut env).await.unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "chatgpt.app_server_required");
    assert_eq!(env, profile.env);
}

#[tokio::test]
async fn chatgpt_plan_default_rpcs_require_codex_app_server() {
    use crate::rpc::{Message, method};

    let root = tempfile::tempdir().unwrap();
    let (hub, profile) = fixture(root.path());
    let before = routes::set_binding(root.path(), "family:codex", None).unwrap();
    let (tx, input) = tokio::sync::mpsc::channel(8);
    let (output, mut rx) = tokio::sync::mpsc::channel(32);
    tokio::spawn(crate::server::serve_connection(hub.clone(), input, output));
    let mut call = async |id, method: &str, params| {
        tx.send(Message::request(id, method, params).to_line()).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let reply: Value = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .unwrap()
    };
    call(1, method::INITIALIZE, json!({"protocolVersion": 1})).await;

    // The family contains an app-server and an adapter. A shared default reaches both.
    let mut adapter = profile;
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    adapter.argv = vec!["python3".into(), fake.into()];
    hub.config.write().await.harnesses.insert("codex-acp".into(), adapter);
    let requests = [
        (method::MUX_ROUTE_DEFAULT_SET, json!({"scope": "family:codex", "routeId": ROUTE})),
        (method::MUX_ACCOUNT_SWITCH, json!({"account": ROUTE})),
    ];
    for (i, (method, params)) in requests.iter().enumerate() {
        let reply = call(i as i64 + 2, method, params.clone()).await;
        assert_eq!(reply["error"]["data"]["reason"], "chatgpt.app_server_required", "{reply}");
        assert_eq!(routes::bindings(root.path()), before);
    }

    let request = NewRequest {
        harness: Some("codex-acp".into()),
        cwd: Some(root.path().to_owned()),
        ..NewRequest::default()
    };
    let error = hub
        .new_session(NewRequest { route: Some(ROUTE.into()), ..request.clone() })
        .await
        .err()
        .unwrap();
    assert_eq!(error.data.unwrap()["reason"], "chatgpt.app_server_required");
    let session = hub.new_session(request).await.unwrap();
    let reply =
        call(4, method::MUX_CHAT_ROUTE_SET, json!({"sessionId": session.id, "routeId": ROUTE}))
            .await;
    assert_eq!(reply["error"]["data"]["reason"], "chatgpt.app_server_required", "{reply}");
    assert_eq!(routes::bindings(root.path()), before);

    hub.config.write().await.harnesses.remove("codex-acp");
    for (i, (method, params)) in requests.into_iter().enumerate() {
        let reply = call(i as i64 + 5, method, params).await;
        assert!(reply["error"].is_null(), "{reply}");
        assert_eq!(routes::bindings(root.path()).families["codex"], ROUTE);
        routes::set_binding(root.path(), "family:codex", None).unwrap();
    }
    hub.shutdown_all().await;
}

fn fixture_for(root: &Path, family: &str, kind: &str, id: &str) -> (Arc<Hub>, HarnessProfile) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let (argv, env) = if kind == "chatgpt-plan" {
        let app_server = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
        let codex = root.join("codex");
        crate::test_exec::write_executable(
            &codex,
            format!("#!/bin/sh\nexec python3 '{app_server}' \"$@\"\n"),
        );
        (
            vec![codex.to_string_lossy().into_owned(), "app-server".into()],
            json!({"CODEX_HOME": root.join("codex-home"), "FAKE_CODEX_APPROVALS": "1"}),
        )
    } else {
        (vec!["python3".into(), fake.into()], json!({}))
    };
    let mut config: crate::config::Config = serde_json::from_value(json!({
        "store": {"mode": "memory"},
        "harnesses": {"route-fake": {"argv": argv, "family": family, "env": env}},
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

fn api_key_route(root: &Path, provider: &str, family: &str, base_url: &str) -> routes::Route {
    let secret = root.join("selected-key");
    std::fs::write(&secret, "fixture-selected-key").unwrap();
    crate::private_file::owner_only(&secret);
    routes::Route {
        id: "selected-key".into(),
        file: serde_json::from_value(json!({
            "kind": "direct-api-key",
            "provider": provider,
            "families": [family],
            "openai_base_url": base_url,
            "secret": format!("file:{}", secret.display()),
        }))
        .unwrap(),
        path: root.join("selected-key.toml"),
    }
}

#[cfg(unix)]
#[tokio::test]
async fn selected_xai_keys_launch_grok_without_its_saved_login_or_model_keys() {
    let root = tempfile::tempdir().unwrap();
    let native = root.path().join(".grok");
    std::fs::create_dir(&native).unwrap();
    let auth = native.join("auth.json");
    let config = native.join("config.toml");
    std::fs::write(&auth, r#"{"fixture":{"access_token":"fixture-native-login"}}"#).unwrap();
    std::fs::write(&config, "[model.grok-build]\napi_key = \"fixture-model-key\"\n").unwrap();
    let profile: HarnessProfile = serde_json::from_value(json!({
        "argv": ["grok", "agent", "stdio"],
        "env": {
            "GROK_HOME": native,
            "GROK_AUTH_PATH": auth,
            "GROK_CONFIG_PATH": config,
            "GROK_AUTH": "fixture-inline-login",
            "GROK_DEPLOYMENT_KEY": "",
        }
    }))
    .unwrap();
    let route = api_key_route(root.path(), "xai", "grok", "https://api.x.ai/v1");
    let mut local = profile.clone();
    routes::apply(&mut local.env, &routes::env_for(&route, "grok", root.path()).unwrap());
    let mut delivered = profile.clone();
    let credential =
        AgentCredential::parse(&json!({"env": {"XAI_API_KEY": "fixture-selected-key"}})).unwrap();
    assert!(crate::agent_credentials::apply(
        &credential,
        "grok",
        &mut delivered.argv,
        &mut delivered.env,
    ));
    let id = uuid::Uuid::now_v7().to_string();
    for (selected, session) in [(local, None), (delivered, Some((id.as_str(), "grok")))] {
        let (cmd, scratch) =
            crate::agent::harness_command_ready("grok", &selected, root.path(), None, session)
                .await
                .unwrap();
        let env: BTreeMap<_, _> = crate::agent::command_env(&cmd).into_iter().collect();
        assert_eq!(env["XAI_API_KEY"], "fixture-selected-key");
        let home = Path::new(&env["GROK_HOME"]);
        assert_ne!(home, native.as_path());
        assert!(!home.join("auth.json").exists());
        assert!(!home.join("config.toml").exists());
        for key in ["GROK_AUTH_PATH", "GROK_AUTH", "GROK_CONFIG_PATH"] {
            assert!(!env.contains_key(key));
        }
        if session.is_some() {
            assert!(scratch.is_none());
            assert_eq!(std::fs::read_link(home.join("sessions")).unwrap(), native.join("sessions"));
            std::fs::remove_dir_all(home.parent().unwrap()).unwrap();
        } else {
            assert_eq!(scratch.unwrap().path(), home);
        }
    }
    let (cmd, scratch) =
        crate::agent::harness_command_ready("grok", &profile, root.path(), None, None)
            .await
            .unwrap();
    let env: BTreeMap<_, _> = crate::agent::command_env(&cmd).into_iter().collect();
    assert!(scratch.is_none());
    assert_eq!(Path::new(&env["GROK_HOME"]), native.as_path());
    assert_eq!(Path::new(&env["GROK_AUTH_PATH"]), auth.as_path());
    assert!(auth.is_file() && config.is_file());
}

#[test]
fn openrouter_launch_uses_the_selected_key_over_opencodes_saved_login() {
    let root = tempfile::tempdir().unwrap();
    let data = root.path().join("opencode");
    std::fs::create_dir(&data).unwrap();
    let saved = r#"{"openrouter":{"type":"api","key":"fixture-saved-key"}}"#;
    let auth = data.join("auth.json");
    std::fs::write(&auth, saved).unwrap();
    let mut profile: HarnessProfile = serde_json::from_value(json!({
        "argv": ["opencode", "acp"],
        "family": "openrouter",
        "env": {"XDG_DATA_HOME": root.path(), "OPENCODE_AUTH_CONTENT": saved}
    }))
    .unwrap();
    let route =
        api_key_route(root.path(), "openrouter", "openrouter", "https://openrouter.ai/api/v1");
    routes::apply(&mut profile.env, &routes::env_for(&route, "openrouter", root.path()).unwrap());
    let cmd =
        crate::agent::harness_command("openrouter", &profile, root.path(), None, None).unwrap();
    let env: BTreeMap<_, _> = crate::agent::command_env(&cmd).into_iter().collect();
    let config: Value = serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    assert_eq!(env["OPENROUTER_API_KEY"], "fixture-selected-key");
    assert_eq!(env["OPENCODE_AUTH_CONTENT"], "{}");
    assert_eq!(config["enabled_providers"], json!(["openrouter"]));
    assert_eq!(
        config["provider"]["openrouter"]["options"],
        json!({"baseURL": "https://openrouter.ai/api/v1", "apiKey": "{env:OPENROUTER_API_KEY}"})
    );
    assert!(!env["OPENCODE_CONFIG_CONTENT"].contains("fixture-selected-key"));
    assert_eq!(Path::new(&env["XDG_DATA_HOME"]), root.path());
    assert_eq!(std::fs::read_to_string(auth).unwrap(), saved);
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
async fn a_local_chatgpt_fork_does_not_copy_history_to_the_codex_cli_login() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    routes::set_binding(root.path(), "family:codex", None).unwrap();
    save_chatgpt(root.path(), "fixture-plan");
    let codex_home = root.path().join("codex-home");
    let rollouts = codex_home.join("sessions");
    std::fs::create_dir_all(&rollouts).unwrap();
    std::fs::write(codex_home.join("auth.json"), r#"{"tokens":{"access_token":"fixture-cli"}}"#)
        .unwrap();
    assert!(routes::codex_signed_in(Some(&codex_home)));
    let session = hub
        .new_session(NewRequest {
            cwd: Some(root.path().to_owned()),
            route: Some(ROUTE.into()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    hub.prompt(
        &session,
        vec![json!({"type": "text", "text": "plan-backed history"})],
        "test",
        false,
    )
    .await
    .unwrap();
    let sid = session.meta().agent_session_id.unwrap();
    let id = json!({"type": "session_meta", "payload": {"id": sid}});
    let turn = json!({"type": "event_msg", "payload": {"type": "task_started"}});
    std::fs::write(
        rollouts.join(format!("rollout-fixture-{sid}.jsonl")),
        format!("{id}\n{turn}\n"),
    )
    .unwrap();
    let fork = hub.fork(&session, None, None, Default::default(), None, None, true).await;
    let error = fork.err().expect("the fork must not copy plan-backed history");
    assert_eq!(error.data.unwrap()["reason"], "credentials.needed");
    assert_eq!(std::fs::read_dir(&rollouts).unwrap().count(), 1);
    assert!(hub.sessions().iter().all(|chat| chat.id == session.id));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn switching_local_chatgpt_plans_waits_for_background_work() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-first-plan");
    let second = "chatgpt-second";
    let (dir, _) = routes::places(&*hub.config.read().await);
    let route = routes::find(dir.as_deref(), ROUTE).unwrap();
    routes::add(dir.as_deref(), second, &route.file, false).unwrap();
    let mut record = chatgpt::store::read(root.path(), ROUTE).unwrap().unwrap();
    record.sub = "fixture-second-account".into();
    record.access_token = "fixture-second-plan".into();
    chatgpt::store::write(root.path(), second, &record).unwrap();

    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    let child = hub.child_for(&session).await.unwrap();
    let sid = session.meta().agent_session_id.unwrap();
    let process = |state: &str| {
        let update = json!({"params": {"update": {"sessionUpdate": "background_task_update",
            "toolCallId": "worker", "taskId": "worker", "state": state, "command": "serve"}}});
        let event = hub.append(&session, "in", "background_task_update", update);
        hub.note_process(&session, &event, None);
    };
    process("running");
    assert!(session.turn().is_none() && hub.holds_work_below(&session));
    let reply = hub.set_chat_route(&session, Some(second.into()), false).await.unwrap();
    assert_eq!(reply["applied"], "after-turn");
    assert!(Arc::ptr_eq(&child, &hub.child_for(&session).await.unwrap()));

    process("completed");
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert!(!Arc::ptr_eq(&child, &hub.child_for(&session).await.unwrap()));
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(sid.as_str()));
    assert_eq!(
        session.launch_env.lock().unwrap().as_ref().unwrap()[CHATGPT_TOKEN],
        "fixture-second-plan"
    );
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_local_chatgpt_plan_does_not_auto_fall_back_to_a_signed_in_codex_cli() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-selected-plan");
    let codex_home = root.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(codex_home.join("auth.json"), r#"{"tokens":{"access_token":"built-in"}}"#)
        .unwrap();
    assert!(routes::codex_signed_in(Some(&codex_home)));
    let session = hub
        .new_session(NewRequest {
            cwd: Some(root.path().to_owned()),
            route: Some(ROUTE.into()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    hub.child_for(&session).await.unwrap();

    let failure = hub.route_failure(&session, "HTTP 429: rate limit exceeded").await.unwrap();
    assert_eq!(failure["route"]["routeId"], ROUTE);
    assert!(failure.get("fallback").is_none());
    assert_eq!(routes::bindings(root.path()).chats[&session.id], ROUTE);
    assert!(!session.route_switch.load(Ordering::SeqCst));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_move_leaves_a_local_codex_chat_on_its_selected_chatgpt_plan() {
    let root = tempfile::tempdir().unwrap();
    let (hub, _) = fixture(root.path());
    save_chatgpt(root.path(), "fixture-plan-a");
    let (dir, _) = routes::places(&*hub.config.read().await);
    let plan = routes::find(dir.as_deref(), ROUTE).unwrap();
    routes::add(dir.as_deref(), "plan-b", &plan.file, false).unwrap();
    chatgpt::store::write(
        root.path(),
        "plan-b",
        &chatgpt::store::Record {
            client_id: chatgpt::CODEX_CLIENT_ID.into(),
            sub: "fixture-account-b".into(),
            access_token: "fixture-plan-b".into(),
            refresh_token: "fixture-refresh-b".into(),
            expires_at: chatgpt::now_unix() + 3600,
            ..Default::default()
        },
    )
    .unwrap();
    routes::update_bindings(root.path(), |bindings| {
        bindings.connection_order = vec!["plan-b".into(), ROUTE.into()];
    })
    .unwrap();
    let session = hub
        .new_session(NewRequest {
            cwd: Some(root.path().to_owned()),
            route: Some(ROUTE.into()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    hub.prompt(&session, prompt(), "test", false).await.unwrap();

    let result =
        hub.transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session.id})).await;
    assert!(result.is_err_and(|error| error.message.starts_with("transfer.account:")));
    assert!(session.moving().is_none());
    assert!(session.meta().moved_to.is_none());
    assert_eq!(routes::bindings(root.path()).chats[&session.id], ROUTE);
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    hub.shutdown_all().await;
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
async fn disconnected_subscription_cannot_take_another_turn_on_its_live_child() {
    for (family, kind, id, token_env) in [
        ("codex", "chatgpt-plan", ROUTE, CHATGPT_TOKEN),
        ("opencode", "kimi-plan", "kimi-test", crate::byo_endpoint::OPENAI_KEY_ENV),
    ] {
        let root = tempfile::tempdir().unwrap();
        let home = root.path();
        let (hub, _) = fixture_for(home, family, kind, id);
        let save = |token| {
            if family == "codex" {
                save_chatgpt(home, token);
            } else {
                save_kimi(home, id, token, crate::subscriptions::now() + 3600);
            }
        };
        save("fixture-before-disconnect");
        let session = hub
            .new_session(NewRequest { cwd: Some(home.to_owned()), ..NewRequest::default() })
            .await
            .unwrap();
        let before = hub.child_for(&session).await.unwrap().generation;
        let native_id = session.meta().agent_session_id.unwrap();
        let prompt = || vec![json!({"type": "text", "text": "hello"})];
        hub.prompt(&session, prompt(), "test", false).await.unwrap();
        assert_eq!(hub.child_for(&session).await.unwrap().generation, before);

        let dir = home.join("routes");
        let route = routes::find(Some(&dir), id).unwrap();
        let instance = route.file.credential_instance.as_deref().unwrap();
        let places = chatgpt::Places { routes: Some(dir.clone()), home: home.to_owned() };
        if family == "codex" {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let origin = format!("http://{}", listener.local_addr().unwrap());
            let attempted = Arc::new(AtomicBool::new(false));
            let received = attempted.clone();
            let revoke = tokio::spawn(async move {
                let app = axum::Router::new().route(
                    "/oauth/revoke",
                    axum::routing::post(move || async move {
                        received.store(true, Ordering::SeqCst);
                        axum::http::StatusCode::SERVICE_UNAVAILABLE
                    }),
                );
                axum::serve(listener, app).await.unwrap();
            });
            let service = chatgpt::Service::new(chatgpt::Endpoints::at(&origin));
            assert!(!service.remove(&places, id, instance).await.unwrap());
            assert!(attempted.load(Ordering::SeqCst));
            assert!(chatgpt::store::read(home, id).unwrap().is_none());
            revoke.abort();
        } else {
            hub.subscriptions
                .remove(crate::subscriptions::Provider::Kimi, places, id.into(), instance.into())
                .await
                .unwrap();
        }
        *session.work_below_since.lock().unwrap() = 1;
        let error = hub.prompt(&session, prompt(), "test", false).await.unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "reauth_required");
        assert_eq!(hub.child_for(&session).await.unwrap().generation, before);

        let replacement = routes::add(Some(&dir), id, &route.file, false).unwrap();
        assert_ne!(replacement.file.credential_instance, route.file.credential_instance);
        routes::set_binding(home, &format!("family:{family}"), Some(id)).unwrap();
        save("fixture-after-disconnect");
        let error = hub.prompt(&session, prompt(), "test", false).await.unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "reauth_required");
        assert_eq!(hub.child_for(&session).await.unwrap().generation, before);

        *session.work_below_since.lock().unwrap() = 0;
        hub.prompt(&session, prompt(), "test", false).await.unwrap();
        assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
        assert_eq!(session.meta().agent_session_id.as_deref(), Some(native_id.as_str()));
        {
            let launch = session.launch_env.lock().unwrap();
            assert_eq!(launch.as_ref().unwrap()[token_env], "fixture-after-disconnect");
        }
        hub.shutdown_all().await;
    }
}

#[tokio::test]
async fn switching_an_existing_opencode_chat_to_kimi_excludes_the_previous_provider() {
    let root = tempfile::tempdir().unwrap();
    let id = "kimi-test";
    let (hub, _) = fixture_for(root.path(), "opencode", "kimi-plan", id);
    routes::set_binding(root.path(), "family:opencode", None).unwrap();
    let previous_model = "openai/gpt-fixture";
    {
        let mut cfg = hub.config.write().await;
        let profile = cfg.harnesses.get_mut("route-fake").unwrap();
        profile.env.insert("OPENAI_API_KEY".into(), "fixture-openai-key".into());
        profile.env.insert(
            "OPENCODE_CONFIG_CONTENT".into(),
            json!({"enabled_providers": ["openai"], "model": previous_model}).to_string(),
        );
    }
    let session = hub
        .new_session(NewRequest { cwd: Some(root.path().to_owned()), ..NewRequest::default() })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    let native_id = session.meta().agent_session_id.unwrap();
    session.meta.lock().unwrap().config_options =
        Some(json!([{"id": "model", "type": "select", "currentValue": previous_model}]).into());
    let expires = crate::subscriptions::now() + 3600;
    save_kimi(root.path(), id, "fixture-kimi-grant", expires);

    let switched = hub.set_chat_route(&session, Some(id.into()), false).await.unwrap();
    assert_eq!(switched["applied"], "now");
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    assert_eq!(session.meta().agent_session_id.as_deref(), Some(native_id.as_str()));
    hub.prompt(
        &session,
        vec![json!({"type": "text", "text": "env: OPENCODE_CONFIG_CONTENT"})],
        "test",
        false,
    )
    .await
    .unwrap();
    let config: Value = hub
        .events(&session.id, 0, 100_000)
        .unwrap()
        .into_iter()
        .find_map(|record| {
            let text = record.msg.pointer("/params/update/content/text")?.as_str()?;
            serde_json::from_str(text.strip_prefix("OPENCODE_CONFIG_CONTENT=")?).ok()
        })
        .expect("the replacement agent reported its OpenCode config");
    assert_eq!(config["enabled_providers"], json!(["byo"]));
    assert_eq!(config["model"], "byo/kimi-for-coding");
    assert_eq!(config["small_model"], "byo/kimi-for-coding");
    assert_eq!(
        config["provider"]["byo"]["options"],
        json!({"baseURL": "https://api.kimi.ai/coding/v1", "apiKey": "{env:CMUX_BYO_API_KEY}"})
    );
    hub.shutdown_all().await;
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
        crate::test_exec::write_executable(
            &program,
            format!("#!/bin/sh\ngrant=${{{var}}}\n{program_body}\n"),
        );
        let mut argv = vec![program.to_string_lossy().into_owned()];
        if family == "codex" {
            argv.push("app-server".into());
            save_chatgpt(dir, TOKEN);
        } else {
            save_kimi(dir, id, TOKEN, crate::subscriptions::now() + 3600);
        }
        hub.config.write().await.harnesses.get_mut("route-fake").unwrap().argv = argv;
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
