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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_machine_login_uses_the_ready_account_despite_guest_routes_and_keys() {
    let mut daemon = Daemon::with_env(
        "claude-own",
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
        r#"{"env":{"ANTHROPIC_BASE_URL":"https://settings.test"},"permissions":{"deny":["Bash"]}}"#,
    )
    .unwrap();
    std::fs::write(
        &launcher,
        format!(
            r#"#!/bin/sh
if [ "$1 $2 $3" = "auth status --json" ]; then
  if [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    echo '{{"loggedIn":true,"authMethod":"claude.ai"}}'
  else
    echo '{{"loggedIn":false}}'
  fi
  exit 0
fi
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
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
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
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let status = rpc.call("_acpmux/agent_login/status", json!({"agent": "claude"})).await;
    assert_eq!(status["signedIn"], true);
    rpc.call("_acpmux/route/add", json!({
        "id": "guest-api", "kind": "custom-anthropic", "families": ["claude"],
        "anthropicBaseUrl": "https://guest.test", "auth": "api-key", "secret": "env:FIXTURE_ROUTE_KEY"
    }))
    .await;
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
