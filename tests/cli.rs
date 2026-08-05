use std::fs;
use std::thread;
use std::time::{Duration, Instant};

use assert_cmd::Command;
use predicates::prelude::*;
use serde_json::json;
use tempfile::TempDir;
use tiny_http::{Header, Response, Server};

#[test]
fn both_binary_names_show_the_same_help() {
    Command::cargo_bin("cr")
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("cr add opencode"));
    Command::cargo_bin("coderouter")
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("cr add codex"));
}

#[cfg(unix)]
#[test]
fn naked_executes_codex_without_coderouter_routing_environment() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let codex = root.path().join("codex");
    fs::write(
        &codex,
        "#!/bin/sh\nprintf '%s\\n' \"$*\"\nprintf 'route=%s\\n' \"${CODEROUTER_ROUTE_TOKEN-unset}\"\nexit 23\n",
    )
    .unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    Command::cargo_bin("cr")
        .unwrap()
        .args(["naked", "exec", "hello"])
        .env("PATH", path)
        .env("CODEROUTER_ROUTE_TOKEN", "secret")
        .assert()
        .code(23)
        .stdout(
            predicate::str::contains("exec hello").and(predicate::str::contains("route=unset")),
        );
}

#[cfg(unix)]
#[test]
fn codex_routes_directly_to_vercel_without_a_daemon() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    write_config(&root, "https://coderouter.dev");
    let codex = root.path().join("codex");
    fs::write(
        &codex,
        "#!/bin/sh\nprintf '%s\\n' \"$*\"\nprintf 'token=%s\\n' \"$CODEROUTER_ROUTE_TOKEN\"\n",
    )
    .unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    Command::cargo_bin("cr")
        .unwrap()
        .args(["codex", "exec", "hello"])
        .env("PATH", path)
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("model_provider=\"coderouter\"")
                .and(predicate::str::contains("https://coderouter.dev/v1"))
                .and(predicate::str::contains("token=route-secret")),
        );
}

#[cfg(unix)]
#[test]
fn opencode_uses_the_vercel_rewritten_provider_catalog() {
    use std::os::unix::fs::PermissionsExt;

    let server = MockServer::start(1, |path| match path {
        "/api/coderouter/opencode/config" => json!({
            "provider": {
                "go": {
                    "npm": "@ai-sdk/openai-compatible",
                    "options": {
                        "baseURL": "https://coderouter.dev/api/coderouter/opencode/proxy/go",
                        "apiKey": "route-secret"
                    }
                }
            }
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);
    let opencode = root.path().join("opencode");
    fs::write(
        &opencode,
        "#!/bin/sh\nprintf '%s\\n' \"$*\"\nprintf '%s\\n' \"$OPENCODE_CONFIG_CONTENT\"\n",
    )
    .unwrap();
    fs::set_permissions(&opencode, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    Command::cargo_bin("cr")
        .unwrap()
        .args(["opencode", "--version"])
        .env("PATH", path)
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("--version").and(predicate::str::contains(
                "coderouter.dev/api/coderouter/opencode/proxy",
            )),
        );
}

#[test]
fn bare_command_lists_vercel_accounts_without_debug_timing() {
    let server = MockServer::start(2, |path| match path {
        "/stack/auth/oauth/token" => json!({
            "access_token": "fresh-access",
            "refresh_token": "fresh-refresh"
        }),
        "/api/coderouter/accounts" => json!({
            "accounts": [{
                "provider": "codex",
                "label": "person@example.com",
                "state": "active",
                "usage": {
                    "plan_type": "pro",
                    "rate_limit": {
                        "primary_window": { "used_percent": 20 },
                        "secondary_window": { "used_percent": 50 }
                    }
                }
            }]
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);

    Command::cargo_bin("cr")
        .unwrap()
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("person@example.com")
                .and(predicate::str::contains("80% left"))
                .and(predicate::str::contains("50% weekly")),
        )
        .stderr(predicate::str::contains("cr timing:").not());
}

#[test]
fn login_uses_native_stack_and_vercel_session_exchange() {
    let server = MockServer::start(6, |path| match path {
        "/api/cli/config" => json!({
            "version": 3,
            "auth": {
                "apiUrl": "__BASE__/stack",
                "projectId": "project",
                "publishableClientKey": "publishable",
                "confirmUrl": "__BASE__/confirm"
            },
            "coderouter": {
                "sessionUrl": "__BASE__/api/coderouter/session",
                "accountsUrl": "__BASE__/api/coderouter/accounts",
                "openaiBaseUrl": "__BASE__/v1"
            }
        }),
        "/stack/auth/cli" => json!({
            "polling_code": "poll",
            "login_code": "copy-code"
        }),
        "/stack/auth/cli/poll" => json!({
            "status": "success",
            "refresh_token": "stack-refresh"
        }),
        "/stack/auth/oauth/token" => json!({
            "access_token": jwt_with_selected_team("team-1"),
            "refresh_token": "stack-refresh-2"
        }),
        "/stack/teams?user_id=me" => json!({
            "items": [{ "id": "team-1", "display_name": "CodeRouter" }]
        }),
        "/api/coderouter/session" => json!({
            "token": "route-secret",
            "expiresAt": "2026-09-01T00:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .args(["login", "--no-browser"])
        .env("CODEROUTER_API_URL", &server.base_url)
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("Authorize CodeRouter")
                .and(predicate::str::contains("login_code=copy-code"))
                .and(predicate::str::contains("Signed in to CodeRouter")),
        );
    let config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.path().join("coderouter/config.json")).unwrap())
            .unwrap();
    assert_eq!(config["routeToken"], "route-secret");
}

#[test]
fn idempotent_logout_is_local_and_fast() {
    let root = TempDir::new().unwrap();
    let started = Instant::now();
    let output = Command::cargo_bin("cr")
        .unwrap()
        .arg("logout")
        .env("CODEROUTER_DATA_DIR", root.path())
        .output()
        .unwrap();
    let elapsed = started.elapsed();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.trim(), "Already logged out.");
    assert!(!stdout.contains(" ms"));
    assert!(elapsed < Duration::from_secs(1), "logout took {elapsed:?}");
}

fn write_config(root: &TempDir, api_url: &str) {
    let directory = root.path().join("coderouter");
    fs::create_dir_all(&directory).unwrap();
    fs::write(
        directory.join("config.json"),
        serde_json::to_vec(&json!({
            "apiUrl": api_url,
            "stackApiUrl": format!("{api_url}/stack"),
            "stackProjectId": "project",
            "stackPublishableClientKey": "publishable",
            "stackAccessToken": "access",
            "stackRefreshToken": "refresh",
            "teamId": "team-1",
            "teamName": "CodeRouter",
            "routeToken": "route-secret",
            "routeTokenExpiresAt": "2026-09-01T00:00:00Z",
            "openaiBaseUrl": format!("{api_url}/v1")
        }))
        .unwrap(),
    )
    .unwrap();
}

struct MockServer {
    base_url: String,
}

impl MockServer {
    fn start(
        requests: usize,
        handler: impl Fn(&str) -> serde_json::Value + Send + 'static,
    ) -> Self {
        let server = Server::http("127.0.0.1:0").unwrap();
        let address = server.server_addr().to_ip().unwrap();
        let base_url = format!("http://{address}");
        let replacement = base_url.clone();
        thread::spawn(move || {
            for _ in 0..requests {
                let request = server.recv().unwrap();
                let value = handler(request.url());
                let body = serde_json::to_string(&value)
                    .unwrap()
                    .replace("__BASE__", &replacement);
                request
                    .respond(Response::from_string(body).with_header(
                        Header::from_bytes("content-type", "application/json").unwrap(),
                    ))
                    .unwrap();
            }
        });
        Self { base_url }
    }
}

fn jwt_with_selected_team(team_id: &str) -> String {
    use base64::Engine;
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&json!({ "selected_team_id": team_id })).unwrap());
    format!("header.{payload}.signature")
}
