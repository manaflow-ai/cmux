//! A guest start must launch Claude with the account selected by the owner.

use super::*;
use std::os::unix::fs::PermissionsExt;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_claude_auth_refuses_a_launcher_that_can_pick_another_provider() {
    let mut daemon = Daemon::new("claude-auth", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {
                "claude-fake": {
                    "argv": ["python3", FAKE], "family": "claude",
                    "env": {"CMUX_CLAUDE_AUTH": "own"}
                }
            },
            "defaultHarness": "claude-fake",
            "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    for meta in [json!({"claudeTeamRoute": true}), json!({"claudeMachineLogin": true})] {
        let refused = rpc
            .reply(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        assert_eq!(refused["error"]["data"]["reason"], "route.unavailable");
        assert!(refused.get("result").is_none());
    }
}

fn claude_account_daemon(tag: &str, pin_harness_home: bool) -> Daemon {
    let mut daemon = Daemon::with_env(
        tag,
        "approve-all",
        &[("FIXTURE_ROUTE_KEY", "route-key"), ("CLAUDE_CODE_OAUTH_TOKEN", "inherited-token")],
    );
    daemon.sigterm();
    let launcher = daemon.home.join("claude");
    let own = daemon.home.join("signed-in-account");
    std::fs::create_dir(&own).unwrap();
    std::fs::write(own.join(".credentials.json"), r#"{"claudeAiOauth":{"accessToken":"fixture"}}"#)
        .unwrap();
    std::fs::create_dir(daemon.home.join(".claude")).unwrap();
    std::fs::write(
        daemon.home.join(".claude/settings.json"),
        r#"{"env":{"ANTHROPIC_BASE_URL":"https://settings.test","ANTHROPIC_API_KEY":"settings-key"},"permissions":{"deny":["Bash"]}}"#,
    )
    .unwrap();
    std::fs::write(
        &launcher,
        format!(
            r#"#!/bin/sh
case "$1 $2" in
  "auth status")
    if [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
      echo '{{"loggedIn":true,"authMethod":"claude.ai"}}'
    else
      echo '{{"loggedIn":false}}'
    fi
    exit 0
    ;;
  "auth login")
    echo 'visit: https://claude.com/cai/oauth/authorize?code=true&state=s1 '
    read -r code
    [ "$code" = fixture-code ] || exit 1
    echo '{{"claudeAiOauth":{{}}}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
    exit
    ;;
  "auth logout") rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"; exit ;;
esac
if [ -n "$ANTHROPIC_API_KEY" ]; then
  export FIXTURE_CLAUDE_API_KEY_SET=yes
fi
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN$CMUX_CLAUDE_TEAM_API_KEY$CMUX_CLAUDE_TEAM_BASE_URL" ]; then
  export FIXTURE_CLAUDE_OVERRIDE_SET=yes
fi
if [ "$1" = "--settings" ]; then
  export FIXTURE_CLAUDE_SETTINGS="$2"
  case "$*" in
    *--setting-sources*) export FIXTURE_CLAUDE_SETTING_SOURCES_OVERRIDDEN=yes ;;
  esac
fi
exec python3 "{FAKE}" "$@"
"#,
        ),
    )
    .unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut config = json!({
            "harnesses": {
                "claude": {
                    "argv": [launcher], "kind": "claude-stdio", "env": {"CLAUDE_CONFIG_DIR": own}
                },
                "claude-fake": {
                    "argv": [launcher], "family": "claude",
                    "env": {
                        "CMUX_CLAUDE_AUTH": "team",
                        "ANTHROPIC_API_KEY": "profile-key", "ANTHROPIC_BASE_URL": "https://profile.test",
                        "CMUX_CLAUDE_TEAM_API_KEY": "team-key", "CMUX_CLAUDE_TEAM_BASE_URL": "https://team.test"
                    }
                }
            },
            "defaultHarness": "claude-fake", "permissionPolicy": "approve-all"
    });
    if pin_harness_home {
        config["harnesses"]["claude-fake"]["env"]["CLAUDE_CONFIG_DIR"] = json!(own);
    }
    std::fs::write(daemon.home.join("config.json"), config.to_string()).unwrap();
    daemon.start();
    daemon
}

async fn guest_api_route(rpc: &mut Rpc) {
    rpc.call("_acpmux/route/add", json!({
        "id": "guest-api", "kind": "custom-anthropic", "families": ["claude"],
        "anthropicBaseUrl": "https://guest.test", "auth": "api-key", "secret": "env:FIXTURE_ROUTE_KEY"
    }))
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_machine_login_uses_the_ready_account_despite_guest_routes_and_keys() {
    let daemon = claude_account_daemon("claude-own", false);
    let own = daemon.home.join("signed-in-account");
    let mut rpc = daemon.rpc().await;
    let status = rpc.call("_acpmux/agent_login/status", json!({"agent": "claude"})).await;
    assert_eq!(status["signedIn"], true);
    guest_api_route(&mut rpc).await;
    let alternate = daemon.home.join("route-account");
    rpc.call("_acpmux/route/add", json!({
        "id": "guest-account", "kind": "direct-subscription", "families": ["claude"], "accountHome": alternate
    }))
    .await;
    for (scope, route) in [("global", "guest-api"), ("family:claude", "guest-account")] {
        rpc.call("_acpmux/route/default.set", json!({"scope": scope, "routeId": route})).await;
        let normal = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
        let normal = normal["sessionId"].as_str().unwrap();
        if scope == "global" {
            assert_eq!(
                agent_env(&daemon, normal, "ANTHROPIC_BASE_URL").await,
                "https://guest.test"
            );
            assert_eq!(agent_env(&daemon, normal, "FIXTURE_CLAUDE_API_KEY_SET").await, "yes");
            assert_eq!(agent_env(&daemon, normal, "CMUX_CLAUDE_AUTH").await, "team");
        } else {
            assert_eq!(
                agent_env(&daemon, normal, "CLAUDE_CONFIG_DIR").await,
                alternate.to_str().unwrap()
            );
        }
        let started = rpc
            .call(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"claudeMachineLogin": true}}}),
            )
            .await;
        let session = started["sessionId"].as_str().unwrap();
        assert_eq!(agent_env(&daemon, session, "CMUX_CLAUDE_AUTH").await, "own");
        assert_eq!(agent_env(&daemon, session, "CLAUDE_CONFIG_DIR").await, own.to_str().unwrap());
        for key in
            ["ANTHROPIC_BASE_URL", "FIXTURE_CLAUDE_API_KEY_SET", "FIXTURE_CLAUDE_OVERRIDE_SET"]
        {
            assert_eq!(agent_env(&daemon, session, key).await, "", "{scope}: {key}");
        }
        let settings: Value =
            serde_json::from_str(&agent_env(&daemon, session, "FIXTURE_CLAUDE_SETTINGS").await)
                .unwrap();
        assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "");
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "");
        assert_eq!(settings["apiKeyHelper"], "");
        assert!(settings.get("permissions").is_none());
        assert_eq!(
            agent_env(&daemon, session, "FIXTURE_CLAUDE_SETTING_SOURCES_OVERRIDDEN").await,
            "",
        );
    }
}

async fn setup_token_chat(daemon: &Daemon, rpc: &mut Rpc) -> String {
    let started = rpc.call("session/new", json!({
        "cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"credentials": {
            "connection": "claude-token", "env": {"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-fixture"}
        }}}
    })).await;
    started["sessionId"].as_str().unwrap().to_owned()
}

async fn recover_token_chat(rpc: &mut Rpc, session: &str) {
    let status = rpc
        .call(
            "_acpmux/agent_login/recover_start",
            json!({
                "agent": "claude", "reuseExisting": true, "recoverySession": session
            }),
        )
        .await;
    assert_eq!(status["signedIn"], true);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_claude_fork_through_a_turn_keeps_the_explicit_machine_account() {
    let mut daemon =
        Daemon::with_env("own-fork", "approve-all", &[("FIXTURE_ROUTE_KEY", "route-key")]);
    daemon.sigterm();
    let launcher = daemon.home.join("claude");
    let own = daemon.home.join("signed-in-account");
    let other = daemon.home.join("harness-account");
    std::fs::write(&launcher, format!("#!/bin/sh\nexec python3 \"{FAKE_CLAUDE}\" \"$@\"\n"))
        .unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {
                "claude": {
                    "argv": [launcher], "kind": "claude-stdio", "env": {"CLAUDE_CONFIG_DIR": own}
                },
                "claude-fork": {
                    "argv": [launcher], "kind": "claude-stdio", "env": {"CLAUDE_CONFIG_DIR": other}
                }
            },
            "defaultHarness": "claude-fork", "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    guest_api_route(&mut rpc).await;
    rpc.call(
        "_acpmux/route/default.set",
        json!({"scope": "family:claude", "routeId": "guest-api"}),
    )
    .await;
    let started = rpc.call("session/new", json!({
        "cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"claudeMachineLogin": true}}
    })).await;
    let parent = started["sessionId"].as_str().unwrap();
    assert_eq!(agent_env(&daemon, parent, "CLAUDE_CONFIG_DIR").await, own.to_str().unwrap());
    let turn = daemon.wait_event(parent, "completed turn", |e| e["kind"] == "turn_result");
    assert_eq!(agent_env(&daemon, parent, "CMUX_CLAUDE_AUTH").await, "own");
    daemon.wait_event(parent, "later completed turn", |e| {
        e["kind"] == "turn_result" && e["seq"].as_u64() > turn["seq"].as_u64()
    });
    let fork =
        rpc.call("acp.session.fork", json!({"sessionId": parent, "throughSeq": turn["seq"]})).await;
    let child = fork["sessionId"].as_str().unwrap();
    assert_eq!(agent_env(&daemon, child, "CLAUDE_CONFIG_DIR").await, own.to_str().unwrap());
    assert_eq!(agent_env(&daemon, child, "CMUX_CLAUDE_AUTH").await, "own");
    assert_eq!(agent_env(&daemon, child, "ANTHROPIC_BASE_URL").await, "");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn recovered_claude_uses_the_machine_login_over_profile_and_project_provider_settings() {
    let daemon = claude_account_daemon("recovery-env", true);
    let mut rpc = daemon.rpc().await;
    let session = setup_token_chat(&daemon, &mut rpc).await;
    let old_host = daemon.host_record(&session)["host_pid"].clone();
    recover_token_chat(&mut rpc, &session).await;

    assert_eq!(agent_env(&daemon, &session, "CMUX_CLAUDE_AUTH").await, "own");
    assert_eq!(agent_env(&daemon, &session, "FIXTURE_CLAUDE_API_KEY_SET").await, "");
    assert_eq!(agent_env(&daemon, &session, "FIXTURE_CLAUDE_OVERRIDE_SET").await, "");
    let settings: Value =
        serde_json::from_str(&agent_env(&daemon, &session, "FIXTURE_CLAUDE_SETTINGS").await)
            .unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "");
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "");
    assert_eq!(settings["apiKeyHelper"], "");
    assert_ne!(daemon.host_record(&session)["host_pid"], old_host);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_owner_fork_of_recovered_claude_keeps_the_machine_login() {
    let daemon = claude_account_daemon("rec-fork", true);
    let mut rpc = daemon.rpc().await;
    guest_api_route(&mut rpc).await;
    rpc.call(
        "_acpmux/route/default.set",
        json!({"scope": "family:claude", "routeId": "guest-api"}),
    )
    .await;
    let parent = setup_token_chat(&daemon, &mut rpc).await;
    recover_token_chat(&mut rpc, &parent).await;
    assert_eq!(agent_env(&daemon, &parent, "CMUX_CLAUDE_AUTH").await, "own");
    let turn = daemon.wait_event(&parent, "completed turn", |e| e["kind"] == "turn_result");
    let fork =
        rpc.call("acp.session.fork", json!({"sessionId": parent, "throughSeq": turn["seq"]})).await;
    let child = fork["sessionId"].as_str().unwrap();

    assert_eq!(agent_env(&daemon, child, "ANTHROPIC_BASE_URL").await, "");
    assert_eq!(agent_env(&daemon, child, "FIXTURE_CLAUDE_API_KEY_SET").await, "");
    assert_eq!(agent_env(&daemon, child, "CMUX_CLAUDE_AUTH").await, "own");
    assert_eq!(
        agent_env(&daemon, child, "CLAUDE_CONFIG_DIR").await,
        daemon.home.join("signed-in-account").to_str().unwrap()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn recovered_claude_keeps_the_machine_login_on_a_cold_start_with_a_new_guest_default() {
    let mut daemon = claude_account_daemon("recovery-cold", true);
    let mut rpc = daemon.rpc().await;
    let session = setup_token_chat(&daemon, &mut rpc).await;
    recover_token_chat(&mut rpc, &session).await;
    assert_eq!(agent_env(&daemon, &session, "CMUX_CLAUDE_AUTH").await, "own");
    let meta: Value =
        serde_json::from_slice(&std::fs::read(daemon.saved_meta_path(&session)).unwrap()).unwrap();
    assert_eq!(meta["claudeLoginRestartPending"], false);
    let host = daemon.host_record(&session)["host_pid"].clone();
    let paused = rpc.call("_acpmux/pause", json!({"sessionId": session})).await;
    assert_eq!(paused["paused"], true);
    guest_api_route(&mut rpc).await;
    rpc.call(
        "_acpmux/route/default.set",
        json!({"scope": "family:claude", "routeId": "guest-api"}),
    )
    .await;
    drop(rpc);
    daemon.sigterm();
    daemon.start();

    assert_eq!(agent_env(&daemon, &session, "ANTHROPIC_BASE_URL").await, "");
    assert_eq!(agent_env(&daemon, &session, "CMUX_CLAUDE_AUTH").await, "own");
    assert_eq!(
        agent_env(&daemon, &session, "CLAUDE_CONFIG_DIR").await,
        daemon.home.join("signed-in-account").to_str().unwrap()
    );
    assert_ne!(daemon.host_record(&session)["host_pid"], host);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn claude_account_actions_follow_the_chat_launch_when_a_guest_default_exists() {
    let daemon = claude_account_daemon("login-scope", true);
    let mut rpc = daemon.rpc().await;
    guest_api_route(&mut rpc).await;
    rpc.call("_acpmux/route/default.set", json!({"scope": "global", "routeId": "guest-api"})).await;
    let recovered = setup_token_chat(&daemon, &mut rpc).await;
    recover_token_chat(&mut rpc, &recovered).await;
    let saved = setup_token_chat(&daemon, &mut rpc).await;
    let machine = rpc.call("session/new", json!({
        "cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"claudeMachineLogin": true}}
    })).await;
    let machine = machine["sessionId"].as_str().unwrap();
    // Finish the recovery's pending restart before checking which chats account actions restart.
    assert_eq!(agent_env(&daemon, &recovered, "CMUX_CLAUDE_AUTH").await, "own");
    let host = |chat: &str| daemon.host_record(chat)["host_pid"].clone();
    let saved_host = host(&saved);
    let original_machine = host(machine);
    let original_recovered = host(&recovered);
    let login = rpc.call("_acpmux/agent_login/start", json!({"agent": "claude"})).await;
    let finished = rpc
        .call(
            "_acpmux/agent_login/finish",
            json!({
                "loginId": login["loginId"], "code": "fixture-code"
            }),
        )
        .await;
    assert_eq!(finished["signedIn"], true);
    assert_eq!(finished["restarted"], true);
    assert_ne!(host(machine), original_machine);
    assert_ne!(host(&recovered), original_recovered);
    assert_eq!(host(&saved), saved_host);

    let signed_in_machine = host(machine);
    let signed_in_recovered = host(&recovered);
    let logout = rpc.call("_acpmux/agent_login/logout", json!({"agent": "claude"})).await;
    assert_eq!(logout["signedIn"], false);
    assert_ne!(host(machine), signed_in_machine);
    assert_ne!(host(&recovered), signed_in_recovered);
    assert_eq!(host(&saved), saved_host);
}
