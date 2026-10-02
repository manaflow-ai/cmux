use std::fs;
#[cfg(all(unix, debug_assertions))]
use std::path::Path;
#[cfg(all(unix, debug_assertions))]
use std::process::Command as StdCommand;
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
        .stdout(
            predicate::str::contains("cr add opencode")
                .and(predicate::str::contains("cr capabilities --json"))
                .and(predicate::str::contains("__cmux-handoff").not()),
        );
    Command::cargo_bin("coderouter")
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(
            predicate::str::contains("cr add codex")
                .and(predicate::str::contains("cr capabilities --json"))
                .and(predicate::str::contains("__cmux-handoff").not()),
        );
}

#[test]
fn both_binary_names_report_strict_credential_free_capabilities() {
    let expected = json!({
        "product": "coderouter",
        "cliVersion": env!("CARGO_PKG_VERSION"),
        "protocolVersion": 2,
        "authModes": ["standalone-stack", "cmux-socket-v1"],
        "features": ["route-session", "organization-scope"],
    });

    for binary in ["coderouter", "cr"] {
        let root = TempDir::new().unwrap();
        let config = root.path().join("coderouter");
        fs::create_dir_all(&config).unwrap();
        // A capability probe must not need to parse or use the saved session.
        fs::write(config.join("config.json"), b"not-json").unwrap();

        let output = Command::cargo_bin(binary)
            .unwrap()
            .args(["capabilities", "--json"])
            .env("CODEROUTER_DATA_DIR", root.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{binary} capabilities failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            output.stderr.is_empty(),
            "{binary} capabilities wrote to stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value, expected);
        assert_eq!(value.as_object().unwrap().len(), 5);
    }
}

#[test]
fn capabilities_rejects_non_json_arguments_without_emitting_json() {
    let output = Command::cargo_bin("coderouter")
        .unwrap()
        .args(["capabilities", "--json", "--extra"])
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8(output.stderr).unwrap(),
        "coderouter: usage: coderouter capabilities --json\n"
    );
}

#[cfg(unix)]
#[test]
fn obsolete_handoff_markers_fail_routed_commands_without_saved_fallback() {
    use std::os::unix::fs::PermissionsExt;

    for marker in ["CODEROUTER_HANDOFF_FD", "CODEROUTER_CMUX_HANDOFF_SOCKET"] {
        let root = TempDir::new().unwrap();
        write_config(&root, "https://saved-route.example");
        let child_ran = root.path().join("child-ran");
        let codex = root.path().join("codex");
        fs::write(
            &codex,
            format!("#!/bin/sh\ntouch '{}'\n", child_ran.display()),
        )
        .unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!(
            "{}:{}",
            root.path().display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let output = Command::cargo_bin("cr")
            .unwrap()
            .args(["codex", "exec", "hello"])
            .env("PATH", &path)
            .env("CODEROUTER_DATA_DIR", root.path())
            .env(marker, "obsolete")
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("handoff marker is obsolete"));
        assert!(!child_ran.exists());

        let hidden_output = Command::cargo_bin("cr")
            .unwrap()
            .args([
                "__cmux-handoff-v2",
                "/tmp/coderouter-obsolete-marker.sock",
                "f99a68dd0ed7ed7f32ac0423736870a1ec31dfbe654e2afef6860cc587839f41",
                "--",
                "codex",
                "exec",
                "hello",
            ])
            .env("PATH", &path)
            .env("CODEROUTER_DATA_DIR", root.path())
            .env(marker, "obsolete")
            .output()
            .unwrap();
        assert!(!hidden_output.status.success());
        assert!(
            String::from_utf8_lossy(&hidden_output.stderr).contains("handoff marker is obsolete")
        );
        assert!(!child_ran.exists());
    }
}

#[test]
fn obsolete_handoff_markers_do_not_affect_credential_free_management() {
    for marker in ["CODEROUTER_HANDOFF_FD", "CODEROUTER_CMUX_HANDOFF_SOCKET"] {
        Command::cargo_bin("cr")
            .unwrap()
            .args(["capabilities", "--json"])
            .env(marker, "obsolete")
            .assert()
            .success();
    }
}

#[cfg(unix)]
#[test]
fn hidden_handoff_socket_failures_have_one_safe_public_error() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;

    let root = TempDir::new().unwrap();
    let binding = "f99a68dd0ed7ed7f32ac0423736870a1ec31dfbe654e2afef6860cc587839f41";
    let socket_path = root.path().join("malicious-handoff.sock");
    let listener = UnixListener::bind(&socket_path).unwrap();
    let peer = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        BufReader::new(stream.try_clone().unwrap())
            .read_line(&mut request)
            .unwrap();
        assert!(request.contains("coderouter.handoff.begin"));
        stream.write_all(b"raw-peer-secret\n").unwrap();
    });
    let malformed = Command::cargo_bin("cr")
        .unwrap()
        .args([
            "__cmux-handoff-v2",
            socket_path.to_str().unwrap(),
            binding,
            "--",
            "codex",
            "exec",
            "hello",
        ])
        .env("CODEROUTER_DATA_DIR", root.path())
        .output()
        .unwrap();
    peer.join().unwrap();
    assert!(!malformed.status.success());
    let malformed_stderr = String::from_utf8_lossy(&malformed.stderr);
    assert!(malformed_stderr.contains("coderouter handoff is invalid or no longer available"));
    for forbidden in ["raw-peer-secret", "response is invalid", "socket closed"] {
        assert!(!malformed_stderr.contains(forbidden));
    }

    let missing_path = root.path().join("missing-handoff.sock");
    let unavailable = Command::cargo_bin("cr")
        .unwrap()
        .args([
            "__cmux-handoff-v2",
            missing_path.to_str().unwrap(),
            binding,
            "--",
            "codex",
            "exec",
            "hello",
        ])
        .env("CODEROUTER_DATA_DIR", root.path())
        .output()
        .unwrap();
    assert!(!unavailable.status.success());
    let unavailable_stderr = String::from_utf8_lossy(&unavailable.stderr);
    assert!(unavailable_stderr.contains("coderouter handoff is invalid or no longer available"));
    assert!(!unavailable_stderr.contains("could not connect"));
    assert!(!unavailable_stderr.contains(missing_path.to_string_lossy().as_ref()));
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
fn authenticated_telemetry_is_allowlisted_and_never_captures_naked_arguments() {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::mpsc;

    let server = Server::http("127.0.0.1:0").unwrap();
    let address = server.server_addr().to_ip().unwrap();
    let base_url = format!("http://{address}");
    let (sent, received) = mpsc::channel();
    thread::spawn(move || {
        let mut request = server.recv().unwrap();
        assert_eq!(request.url(), "/api/coderouter/analytics");
        let authorization = request
            .headers()
            .iter()
            .find(|header| header.field.equiv("Authorization"))
            .map(|header| header.value.as_str().to_owned());
        let mut body = String::new();
        request.as_reader().read_to_string(&mut body).unwrap();
        request.respond(Response::empty(204)).unwrap();
        sent.send((authorization, body)).unwrap();
    });

    let root = TempDir::new().unwrap();
    write_config(&root, &base_url);
    let config_path = root.path().join("coderouter/config.json");
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(&config_path).unwrap()).unwrap();
    config["teamName"] = json!("very-private-team-name");
    fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();
    let codex = root.path().join("codex");
    fs::write(&codex, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let sensitive = [
        "private-child-subcommand",
        "/Users/alice/private/project",
        "sk-secret-token",
        "person@example.com",
        "private prompt",
    ];
    Command::cargo_bin("cr")
        .unwrap()
        .arg("naked")
        .args(sensitive)
        .env("PATH", path)
        .env("CODEROUTER_DATA_DIR", root.path())
        .env_remove("DO_NOT_TRACK")
        .env_remove("CODEROUTER_TELEMETRY_DISABLED")
        .assert()
        .success();

    let (authorization, body) = received.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(authorization.as_deref(), Some("Bearer route-secret"));
    let payload: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(payload["events"].as_array().unwrap().len(), 2);
    assert_eq!(
        payload["events"][0]["event"],
        "coderouter_cli_command_started"
    );
    assert_eq!(
        payload["events"][1]["event"],
        "coderouter_cli_command_completed"
    );
    assert_eq!(payload["events"][0]["properties"]["command"], "agent");
    assert_eq!(payload["events"][0]["properties"]["agent"], "codex");
    assert_eq!(payload["events"][0]["properties"]["mode"], "direct");
    for value in sensitive {
        assert!(!body.contains(value), "telemetry leaked {value:?}");
    }
    for forbidden in [
        "team-1",
        "very-private-team-name",
        "access",
        "refresh",
        "route-secret",
        "accountId",
        "teamId",
        "userId",
        "email",
        "path",
        "arguments",
    ] {
        assert!(!body.contains(forbidden), "telemetry leaked {forbidden:?}");
    }
}

#[cfg(unix)]
#[test]
fn telemetry_opt_out_sends_no_request() {
    use std::os::unix::fs::PermissionsExt;

    for variable in ["DO_NOT_TRACK", "CODEROUTER_TELEMETRY_DISABLED"] {
        let server = Server::http("127.0.0.1:0").unwrap();
        let address = server.server_addr().to_ip().unwrap();
        let base_url = format!("http://{address}");
        let root = TempDir::new().unwrap();
        write_config(&root, &base_url);
        let codex = root.path().join("codex");
        fs::write(&codex, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!(
            "{}:{}",
            root.path().display(),
            std::env::var("PATH").unwrap_or_default()
        );
        Command::cargo_bin("cr")
            .unwrap()
            .arg("naked")
            .env("PATH", path)
            .env("CODEROUTER_DATA_DIR", root.path())
            .env_remove("DO_NOT_TRACK")
            .env_remove("CODEROUTER_TELEMETRY_DISABLED")
            .env(variable, "1")
            .assert()
            .success();

        assert!(
            server
                .recv_timeout(Duration::from_millis(350))
                .unwrap()
                .is_none(),
            "{variable} should prevent the telemetry request"
        );
    }
}

#[cfg(unix)]
#[test]
fn codex_routes_directly_to_vercel_without_a_daemon() {
    use std::os::unix::fs::PermissionsExt;

    let server = MockServer::start(1, |path| match path {
        "/api/coderouter/session" => json!({}),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);
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
                .and(predicate::str::contains(format!("{}/v1", server.base_url)))
                .and(predicate::str::contains("token=route-secret")),
        );
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn handoff_exchanges_once_disables_analytics_and_isolates_child_credentials() {
    use std::os::unix::fs::PermissionsExt;

    let route_token = valid_route_token();
    let lease = valid_handoff_lease();
    let (base_url, received) = start_handoff_server(
        200,
        json!({
            "teamId": "team-handoff",
            "token": route_token,
            "expiresAt": "2099-08-13T12:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
    );
    let root = TempDir::new().unwrap();
    // Handoff exchange must not parse or update the durable Stack session.
    fs::create_dir_all(root.path().join("coderouter")).unwrap();
    fs::write(root.path().join("coderouter/config.json"), b"not-json").unwrap();
    let codex = root.path().join("codex");
    fs::write(
        &codex,
        "#!/bin/sh\nprintf 'route=%s\\n' \"${CODEROUTER_ROUTE_TOKEN-unset}\"\nprintf 'handoff=%s\\n' \"${CODEROUTER_HANDOFF_FD-unset}\"\nprintf 'cmux_compat=%s\\n' \"${CODEROUTER_CMUX_HANDOFF_COMPAT-unset}\"\nprintf 'test_origin=%s\\n' \"${CODEROUTER_HANDOFF_TEST_ORIGIN-unset}\"\nprintf 'api_url=%s\\n' \"${CODEROUTER_API_URL-unset}\"\nprintf 'data_dir=%s\\n' \"${CODEROUTER_DATA_DIR-unset}\"\nprintf 'stack_access=%s\\n' \"${STACK_ACCESS_TOKEN-unset}\"\nprintf 'stack_refresh=%s\\n' \"${STACK_REFRESH_TOKEN-unset}\"\nprintf 'github_pat=%s\\n' \"${GITHUB_PAT-unset}\"\nprintf 'http_proxy=%s\\n' \"${HTTP_PROXY-unset}\"\nprintf 'https_proxy=%s\\n' \"${HTTPS_PROXY-unset}\"\nprintf 'all_proxy=%s\\n' \"${ALL_PROXY-unset}\"\nprintf 'no_proxy=%s\\n' \"${NO_PROXY-unset}\"\nprintf 'ssl_cert_file=%s\\n' \"${SSL_CERT_FILE-unset}\"\nprintf 'ssl_cert_dir=%s\\n' \"${SSL_CERT_DIR-unset}\"\nprintf 'ssl_keylog=%s\\n' \"${SSLKEYLOGFILE-unset}\"\nprintf 'node_extra_ca=%s\\n' \"${NODE_EXTRA_CA_CERTS-unset}\"\nprintf 'node_options=%s\\n' \"${NODE_OPTIONS-unset}\"\nprintf 'lease=%s\\n' \"${CODEROUTER_HANDOFF_LEASE-unset}\"\nprintf 'args=%s\\n' \"$*\"\n",
    )
    .unwrap();
    {
        use std::io::Write as _;
        let mut script = fs::OpenOptions::new().append(true).open(&codex).unwrap();
        writeln!(
            script,
            "printf 'cmux_socket=%s\\n' \"${{CMUX_SOCKET-unset}}\""
        )
        .unwrap();
        writeln!(
            script,
            "printf 'cmux_socket_capability=%s\\n' \"${{CMUX_SOCKET_CAPABILITY-unset}}\""
        )
        .unwrap();
        writeln!(
            script,
            "printf 'cmux_socket_path=%s\\n' \"${{CMUX_SOCKET_PATH-unset}}\""
        )
        .unwrap();
        writeln!(
            script,
            "printf 'cmux_socket_password=%s\\n' \"${{CMUX_SOCKET_PASSWORD-unset}}\""
        )
        .unwrap();
    }
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

    let output = run_cr_with_handoff(&base_url, &root, &codex, lease.as_bytes(), &[]);
    assert!(
        output.status.success(),
        "handoff command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains(&format!("route={route_token}")));
    assert!(stdout.contains("handoff=unset"));
    assert!(stdout.contains("cmux_compat=unset"));
    assert!(stdout.contains("test_origin=unset"));
    assert!(stdout.contains("api_url=unset"));
    assert!(stdout.contains("data_dir=unset"));
    assert!(stdout.contains("stack_access=unset"));
    assert!(stdout.contains("stack_refresh=unset"));
    assert!(stdout.contains("github_pat=unset"));
    assert!(stdout.contains("http_proxy=unset"));
    assert!(stdout.contains("https_proxy=unset"));
    assert!(stdout.contains("all_proxy=unset"));
    assert!(stdout.contains("no_proxy=unset"));
    assert!(stdout.contains("ssl_cert_file=unset"));
    assert!(stdout.contains("ssl_cert_dir=unset"));
    assert!(stdout.contains("ssl_keylog=unset"));
    assert!(stdout.contains("node_extra_ca=unset"));
    assert!(stdout.contains("node_options=unset"));
    assert!(stdout.contains("cmux_socket=unset"));
    assert!(stdout.contains("cmux_socket_capability=unset"));
    assert!(stdout.contains("cmux_socket_path=unset"));
    assert!(stdout.contains("cmux_socket_password=unset"));
    assert!(stdout.contains("lease=unset"));
    assert!(!stdout.contains(&lease));

    let capture = received.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(capture.path, "/api/coderouter/handoff/exchange");
    assert_eq!(capture.body, format!("{{\"lease\":\"{lease}\"}}"));
    assert!(
        capture
            .headers
            .iter()
            .all(|(name, _)| !name.eq_ignore_ascii_case("authorization"))
    );
    assert!(
        capture
            .headers
            .iter()
            .all(|(name, _)| !name.eq_ignore_ascii_case("x-stack-refresh-token"))
    );
    assert!(received.recv_timeout(Duration::from_millis(450)).is_err());
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn replay_expiry_and_revocation_fail_closed_without_saved_route_fallback() {
    use std::os::unix::fs::PermissionsExt;

    for status in [401_u16, 401_u16, 401_u16] {
        let lease = valid_handoff_lease();
        let (base_url, received) = start_handoff_server(
            status,
            json!({
                "error": "invalid_handoff_lease",
                "message": "lease is not available"
            }),
        );
        let root = TempDir::new().unwrap();
        // This route is deliberately valid. The handoff marker must prevent
        // the CLI from silently using it after exchange failure.
        write_config(&root, &base_url);
        let marker = root.path().join("child-ran");
        let codex = root.path().join("codex");
        fs::write(&codex, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

        let output = run_cr_with_handoff(&base_url, &root, &codex, lease.as_bytes(), &[]);
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("handoff is invalid or no longer available"));
        assert!(!stderr.contains(&lease));
        assert!(!marker.exists());
        let capture = received.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(capture.path, "/api/coderouter/handoff/exchange");
        assert!(received.recv_timeout(Duration::from_millis(450)).is_err());
    }
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn ambient_and_saved_origins_cannot_steer_the_handoff_exchange() {
    use std::os::unix::fs::PermissionsExt;

    let lease = valid_handoff_lease();
    let (base_url, received) = start_handoff_server(
        200,
        json!({
            "teamId": "team-handoff",
            "token": valid_route_token(),
            "expiresAt": "2099-08-13T12:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
    );
    let root = TempDir::new().unwrap();
    write_config(&root, "https://saved-evil.example");
    let codex = root.path().join("codex");
    fs::write(&codex, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

    let output = run_cr_with_handoff(
        &base_url,
        &root,
        &codex,
        lease.as_bytes(),
        &[("CODEROUTER_API_URL", "https://evil.example")],
    );
    assert!(
        output.status.success(),
        "handoff command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let capture = received.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(capture.path, "/api/coderouter/handoff/exchange");
    assert_eq!(capture.body, format!("{{\"lease\":\"{lease}\"}}"));
    for forbidden in ["authorization", "x-stack-refresh-token", "x-cmux-team-id"] {
        assert!(
            capture
                .headers
                .iter()
                .all(|(name, _)| !name.eq_ignore_ascii_case(forbidden))
        );
    }
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn handoff_opencode_catalog_ignores_hostile_proxy_and_ca_environment() {
    use std::os::unix::fs::PermissionsExt;

    let route_token = valid_route_token();
    let returned_token = route_token.clone();
    let server = MockServer::start(2, move |path| match path {
        "/api/coderouter/handoff/exchange" => json!({
            "teamId": "team-handoff",
            "token": returned_token,
            "expiresAt": "2099-08-13T12:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
        "/api/coderouter/opencode/config" => json!({
            "provider": {
                "go": {
                    "npm": "@ai-sdk/openai-compatible",
                    "options": {
                        "baseURL": "__BASE__/v1",
                        "apiKey": route_token,
                    },
                    "models": { "model-1": { "name": "Model One" } }
                }
            }
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    fs::create_dir_all(root.path().join("coderouter")).unwrap();
    fs::write(root.path().join("coderouter/config.json"), b"not-json").unwrap();
    let opencode = root.path().join("opencode");
    fs::write(
        &opencode,
        "#!/bin/sh\nprintf '%s\\n' \"$OPENCODE_CONFIG_CONTENT\"\n",
    )
    .unwrap();
    fs::set_permissions(&opencode, fs::Permissions::from_mode(0o755)).unwrap();

    let lease = valid_handoff_lease();
    let output = run_agent_with_handoff(
        &server.base_url,
        &root,
        &opencode,
        "opencode",
        lease.as_bytes(),
        &[],
    );
    assert!(
        output.status.success(),
        "handoff OpenCode command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("model-1"));
    assert!(stdout.contains(&valid_route_token()));
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn handoff_pi_models_ignore_hostile_proxy_and_ca_environment() {
    use std::os::unix::fs::PermissionsExt;

    let route_token = valid_route_token();
    let server = MockServer::start(2, move |path| {
        if path == "/api/coderouter/handoff/exchange" {
            return json!({
                "teamId": "team-handoff",
                "token": route_token,
                "expiresAt": "2099-08-13T12:00:00Z",
                "openaiBaseUrl": "__BASE__/v1"
            });
        }
        assert!(path.starts_with("/v1/models?client_version="));
        json!({
            "models": [{
                "slug": "gpt-test",
                "display_name": "GPT Test",
                "context_window": 128000,
                "max_output_tokens": 16000
            }]
        })
    });
    let root = TempDir::new().unwrap();
    fs::create_dir_all(root.path().join("coderouter")).unwrap();
    fs::write(root.path().join("coderouter/config.json"), b"not-json").unwrap();
    let pi = root.path().join("pi");
    fs::write(
        &pi,
        "#!/bin/sh\nextension=\"$2\"\ngrep -q 'openai-codex-responses' \"$extension\"\n",
    )
    .unwrap();
    fs::set_permissions(&pi, fs::Permissions::from_mode(0o755)).unwrap();

    let lease = valid_handoff_lease();
    let output = run_agent_with_handoff(&server.base_url, &root, &pi, "pi", lease.as_bytes(), &[]);
    assert!(
        output.status.success(),
        "handoff Pi command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(all(unix, debug_assertions))]
#[test]
fn hosted_team_mismatch_fails_before_provider_launch() {
    use std::os::unix::fs::PermissionsExt;

    let lease = valid_handoff_lease();
    let (base_url, received) = start_handoff_server(
        200,
        json!({
            "teamId": "different-team",
            "token": valid_route_token(),
            "expiresAt": "2099-08-13T12:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
    );
    let root = TempDir::new().unwrap();
    write_config(&root, "https://saved-route.example");
    let marker = root.path().join("child-ran");
    let codex = root.path().join("codex");
    fs::write(&codex, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

    let output = run_cr_with_handoff(&base_url, &root, &codex, lease.as_bytes(), &[]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid team binding"));
    assert!(!stderr.contains(&lease));
    assert!(!marker.exists());
    let capture = received.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(capture.path, "/api/coderouter/handoff/exchange");
}

#[cfg(unix)]
#[test]
fn opencode_uses_the_vercel_rewritten_provider_catalog() {
    use std::os::unix::fs::PermissionsExt;

    let server = MockServer::start(2, |path| match path {
        "/api/coderouter/session" => json!({}),
        "/api/coderouter/opencode/config" => json!({
            "provider": {
                "go": {
                    "npm": "@ai-sdk/openai-compatible",
                    "options": {
                        "baseURL": "https://coderouter.dev/api/coderouter/opencode/proxy/go",
                        "apiKey": "route-secret"
                    },
                    "models": { "model-1": { "name": "Model One" } }
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
            predicate::str::contains("--model go/model-1 --version").and(predicate::str::contains(
                "coderouter.dev/api/coderouter/opencode/proxy",
            )),
        );
}

#[cfg(unix)]
#[test]
fn pi_uses_an_ephemeral_coderouter_provider() {
    use std::os::unix::fs::PermissionsExt;

    let server = MockServer::start(2, |path| {
        if path == "/api/coderouter/session" {
            return json!({});
        }
        assert!(path.starts_with("/v1/models?client_version="));
        json!({
            "models": [{
                "slug": "gpt-test",
                "display_name": "GPT Test",
                "context_window": 128000,
                "max_output_tokens": 16000
            }]
        })
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);
    let pi = root.path().join("pi");
    fs::write(
        &pi,
        "#!/bin/sh\nprintf '%s\\n' \"$*\"\nextension=\"$2\"\ngrep -q 'openai-codex-responses' \"$extension\"\ngrep -q 'x-coderouter-route-token' \"$extension\"\ngrep -q 'delete process.env.CODEROUTER_ROUTE_TOKEN' \"$extension\"\n! grep -q 'route-secret' \"$extension\"\n",
    )
    .unwrap();
    fs::set_permissions(&pi, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    Command::cargo_bin("cr")
        .unwrap()
        .args(["pi", "--version"])
        .env("PATH", path)
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("--provider coderouter")
                .and(predicate::str::contains("--model gpt-test"))
                .and(predicate::str::contains("--version")),
        );
}

#[test]
fn bare_command_lists_vercel_accounts_without_debug_timing() {
    let server = MockServer::start(2, |path| match path {
        "/api/coderouter/session" => json!({}),
        "/api/coderouter/accounts" => json!({
            "usageAgeSeconds": 8,
            "cacheMaxAgeSeconds": 15,
            "accounts": [{
                "provider": "codex",
                "label": "person@example.com",
                "state": "active",
                "usage": {
                    "plan_type": "pro",
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 20,
                            "limit_window_seconds": 18000,
                            "reset_after_seconds": 3600
                        },
                        "secondary_window": {
                            "used_percent": 50,
                            "limit_window_seconds": 604800,
                            "reset_after_seconds": 172800
                        }
                    },
                    "additional_rate_limits": [{
                        "limit_name": "GPT-5.3-Codex-Spark",
                        "rate_limit": {
                            "primary_window": {
                                "used_percent": 1,
                                "limit_window_seconds": 604800,
                                "reset_after_seconds": 561600
                            },
                            "secondary_window": null
                        }
                    }],
                    "credits": { "balance": "0" },
                    "rate_limit_reset_credits": { "available_count": 0 }
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
        .env("COLUMNS", "180")
        .env_remove("NO_COLOR")
        .env_remove("CR_NO_COLOR")
        .env("TERM", "xterm-256color")
        .env("FORCE_COLOR", "1")
        .assert()
        .success()
        .stdout(
            predicate::str::contains("Codex accounts")
                .and(predicate::str::contains("Account"))
                .and(predicate::str::contains("State"))
                .and(predicate::str::contains("Use"))
                .and(predicate::str::contains("5h"))
                .and(predicate::str::contains("7d"))
                .and(predicate::str::contains("Spark wk"))
                .and(predicate::str::contains("person@example.com"))
                .and(predicate::str::contains("80%/1h"))
                .and(predicate::str::contains("50%/2d"))
                .and(predicate::str::contains("99%/6d"))
                .and(predicate::str::contains("Usage cached 8s ago"))
                .and(predicate::str::contains("\u{1b}[")),
        )
        .stderr(predicate::str::contains("cr timing:").not());
}

#[test]
fn revoked_route_token_is_renewed_without_browser_login() {
    let server = MockServer::start_status(6, |path| match path {
        "/api/coderouter/session" => (401, json!({ "error": "unauthorized" })),
        "/stack/auth/oauth/token" => (
            200,
            json!({
                "access_token": "fresh-access",
                "refresh_token": "fresh-refresh"
            }),
        ),
        "/api/cli/config" => (
            200,
            json!({
                "version": 3,
                "auth": {
                    "apiUrl": "__BASE__/stack",
                    "projectId": "project",
                    "publishableClientKey": "publishable",
                    "confirmUrl": "__BASE__/confirm"
                },
                "coderouter": {
                    "sessionUrl": "__BASE__/api/coderouter/renew",
                    "openaiBaseUrl": "__BASE__/v1"
                }
            }),
        ),
        "/api/coderouter/renew" => (
            200,
            json!({
                "token": "renewed-route-secret",
                "expiresAt": "2026-10-01T00:00:00Z",
                "openaiBaseUrl": "__BASE__/v1"
            }),
        ),
        "/api/coderouter/accounts" => (200, json!({ "accounts": [] })),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);

    Command::cargo_bin("cr")
        .unwrap()
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::str::contains("No accounts configured."));

    let config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.path().join("coderouter/config.json")).unwrap())
            .unwrap();
    assert_eq!(config["routeToken"], "renewed-route-secret");
    assert_eq!(config["stackRefreshToken"], "fresh-refresh");
}

#[test]
fn remove_deletes_the_selected_subscription() {
    let server = MockServer::start(4, |path| match path {
        "/api/coderouter/session" => json!({}),
        "/api/coderouter/accounts" => json!({
            "accounts": [{
                "id": "00000000-0000-4000-8000-000000000001",
                "provider": "codex",
                "label": "person@example.com",
                "state": "active"
            }]
        }),
        "/stack/auth/oauth/token" => json!({
            "access_token": "fresh-access",
            "refresh_token": "fresh-refresh"
        }),
        "/api/coderouter/accounts/00000000-0000-4000-8000-000000000001" => json!({
            "removed": true,
            "lastAccount": false,
            "legacyCleanupPending": false
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);
    Command::cargo_bin("cr")
        .unwrap()
        .args(["remove", "person@example.com", "--yes"])
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::str::contains("Subscription removed."));
}

#[test]
fn login_persists_an_explicit_self_hosted_server() {
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
            "items": [{ "id": "team-1", "display_name": "coderouter" }]
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
        .args(["login", "--no-browser", "--server", &server.base_url])
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(
            predicate::str::contains("Authorize coderouter")
                .and(predicate::str::contains("login_code=copy-code"))
                .and(predicate::str::contains("Signed in to coderouter")),
        );
    let config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.path().join("coderouter/config.json")).unwrap())
            .unwrap();
    assert_eq!(config["routeToken"], "route-secret");
    assert_eq!(config["apiUrl"], server.base_url);
    assert_eq!(config["openaiBaseUrl"], format!("{}/v1", server.base_url));
}

#[test]
fn login_accepts_a_one_time_stack_code_without_a_browser() {
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
        "/stack/auth/otp/sign-in" => json!({
            "access_token": "otp-access",
            "refresh_token": "otp-refresh"
        }),
        "/stack/auth/oauth/token" => json!({
            "access_token": jwt_with_selected_team("team-1"),
            "refresh_token": "stack-refresh"
        }),
        "/stack/teams?user_id=me" => json!({
            "items": [{ "id": "team-1", "display_name": "coderouter" }]
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
        .args(["login", "--code", "one-time-sign-in-code"])
        .env("CODEROUTER_API_URL", &server.base_url)
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::str::contains("Signed in to coderouter"))
        .stdout(predicate::str::contains("Authorize coderouter").not());
}

#[test]
fn upgrade_is_a_supported_headless_command() {
    Command::cargo_bin("cr")
        .unwrap()
        .args(["upgrade", "--no-browser"])
        .assert()
        .success()
        .stdout(
            predicate::str::contains("Upgrade cmux Pro or Team")
                .and(predicate::str::contains("https://cmux.com/pricing"))
                .and(predicate::str::contains("unknown coderouter command").not()),
        );
}

#[test]
fn org_current_reads_the_durable_local_scope() {
    let root = TempDir::new().unwrap();
    write_config(&root, "https://coderouter.dev");

    Command::cargo_bin("cr")
        .unwrap()
        .args(["org", "current"])
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::eq("coderouter (team-1)\n"));
}

#[test]
fn org_switch_authorizes_the_membership_before_persisting_the_new_scope() {
    let server = MockServer::start(4, |path| match path {
        "/stack/auth/oauth/token" => json!({
            "access_token": jwt_with_selected_team("team-1"),
            "refresh_token": "fresh-refresh"
        }),
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
        "/stack/teams?user_id=me" => json!({
            "items": [
                { "id": "team-1", "display_name": "coderouter" },
                { "id": "team-2", "display_name": "Acme" },
                { "id": "team-3", "display_name": "team-2" }
            ]
        }),
        "/api/coderouter/session" => json!({
            "token": "route-team-2",
            "expiresAt": "2026-10-01T00:00:00Z",
            "openaiBaseUrl": "__BASE__/v1"
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);

    Command::cargo_bin("cr")
        .unwrap()
        .args(["org", "switch", "team-2"])
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::eq("Switched coderouter to Acme (team-2).\n"));

    let config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.path().join("coderouter/config.json")).unwrap())
            .unwrap();
    assert_eq!(config["teamId"], "team-2");
    assert_eq!(config["teamName"], "Acme");
    assert_eq!(config["routeToken"], "route-team-2");
    assert_eq!(config["stackRefreshToken"], "fresh-refresh");
}

#[test]
fn org_list_uses_the_server_permission_filtered_organization_catalog() {
    let server = MockServer::start(3, |path| match path {
        "/stack/auth/oauth/token" => json!({
            "access_token": jwt_with_selected_team("team-1"),
            "refresh_token": "fresh-refresh"
        }),
        "/api/cli/config" => json!({
            "version": 4,
            "auth": {
                "apiUrl": "__BASE__/stack",
                "projectId": "project",
                "publishableClientKey": "publishable",
                "confirmUrl": "__BASE__/confirm"
            },
            "coderouter": {
                "sessionUrl": "__BASE__/api/coderouter/session",
                "accountsUrl": "__BASE__/api/coderouter/accounts",
                "organizationsUrl": "__BASE__/api/coderouter/organizations",
                "openaiBaseUrl": "__BASE__/v1"
            }
        }),
        "/api/coderouter/organizations" => json!({
            "selectedTeamId": "team-1",
            "teams": [
                {
                    "id": "team-1",
                    "name": "cmux",
                    "personal": false,
                    "permissions": { "use": true, "manageAccounts": true }
                }
            ]
        }),
        _ => panic!("unexpected path {path}"),
    });
    let root = TempDir::new().unwrap();
    write_config(&root, &server.base_url);

    Command::cargo_bin("cr")
        .unwrap()
        .args(["org", "list"])
        .env("CODEROUTER_DATA_DIR", root.path())
        .assert()
        .success()
        .stdout(predicate::eq("*\tcmux\tteam-1\n"))
        .stdout(predicate::str::contains("workspace").not());
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
    assert!(elapsed < Duration::from_secs(2), "logout took {elapsed:?}");
}

#[cfg(all(unix, debug_assertions))]
fn run_cr_with_handoff(
    base_url: &str,
    root: &TempDir,
    codex: &Path,
    lease: &[u8],
    overrides: &[(&str, &str)],
) -> std::process::Output {
    run_agent_with_handoff(base_url, root, codex, "codex", lease, overrides)
}

#[cfg(all(unix, debug_assertions))]
fn run_agent_with_handoff(
    base_url: &str,
    root: &TempDir,
    executable: &Path,
    agent: &str,
    lease: &[u8],
    overrides: &[(&str, &str)],
) -> std::process::Output {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;

    let socket_path = root.path().join("coderouter-handoff.sock");
    let listener = UnixListener::bind(&socket_path).unwrap();
    let lease = String::from_utf8(lease.to_vec()).unwrap();
    let socket_worker = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let request: serde_json::Value = serde_json::from_str(&request_line).unwrap();
        assert_eq!(request["id"], "coderouter-handoff-begin");
        assert_eq!(request["method"], "coderouter.handoff.begin");
        assert_eq!(request["params"]["protocolVersion"], 2);
        let challenge = "A".repeat(43);
        writeln!(
            stream,
            "{}",
            json!({
                "id": "coderouter-handoff-begin",
                "ok": true,
                "result": { "protocolVersion": 2, "challenge": challenge }
            })
        )
        .unwrap();
        request_line.clear();
        reader.read_line(&mut request_line).unwrap();
        let complete: serde_json::Value = serde_json::from_str(&request_line).unwrap();
        assert_eq!(complete["id"], "coderouter-handoff-complete");
        assert_eq!(complete["method"], "coderouter.handoff.complete");
        assert_eq!(complete["params"]["protocolVersion"], 2);
        assert_eq!(complete["params"]["challenge"], "A".repeat(43));
        let response = json!({
            "id": "coderouter-handoff-complete",
            "ok": true,
            "result": {
                "teamId": "team-handoff",
                "lease": lease,
                "expiresAt": "2099-08-13T12:00:00Z",
            }
        });
        writeln!(stream, "{response}").unwrap();
        thread::sleep(Duration::from_millis(50));
    });

    let path = format!(
        "{}:{}",
        executable.parent().unwrap().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut command = StdCommand::new(assert_cmd::cargo::cargo_bin("cr"));
    command
        .args([
            "__cmux-handoff-v2",
            socket_path.to_str().unwrap(),
            "f99a68dd0ed7ed7f32ac0423736870a1ec31dfbe654e2afef6860cc587839f41",
            "--",
            agent,
            "exec",
            "hello",
        ])
        .env("PATH", path)
        .env("CODEROUTER_DATA_DIR", root.path())
        .env("CODEROUTER_HANDOFF_TEST_ORIGIN", base_url)
        .env("CODEROUTER_ROUTE_TOKEN", "saved-route-must-not-reach-child")
        .env("HTTP_PROXY", "http://127.0.0.1:9")
        .env("HTTPS_PROXY", "http://127.0.0.1:9")
        .env("ALL_PROXY", "http://127.0.0.1:9")
        .env("NO_PROXY", "")
        .env("SSL_CERT_FILE", "/tmp/hostile-ca.pem")
        .env("SSL_CERT_DIR", "/tmp/hostile-ca-dir")
        .env("SSLKEYLOGFILE", "/tmp/hostile-tls-keys.log")
        .env("NODE_EXTRA_CA_CERTS", "/tmp/hostile-node-ca.pem")
        .env(
            "NODE_OPTIONS",
            "--tls-keylog=/tmp/hostile-node-tls-keys.log --use-openssl-ca",
        )
        .env("CMUX_SOCKET", "/tmp/ambient-cmux.sock")
        .env("CMUX_SOCKET_CAPABILITY", "ambient-cmux-capability")
        .env("CMUX_SOCKET_PATH", "/tmp/ambient-cmux-path.sock")
        .env("CMUX_SOCKET_PASSWORD", "ambient-cmux-password")
        .env(
            "CODEROUTER_HANDOFF_LEASE",
            "ambient-lease-must-not-reach-child",
        )
        .env(
            "CODEROUTER_CMUX_HANDOFF_COMPAT",
            "ambient-compatibility-marker-must-not-reach-child",
        )
        .env("STACK_ACCESS_TOKEN", "stack-access-must-not-reach-child")
        .env("STACK_REFRESH_TOKEN", "stack-refresh-must-not-reach-child")
        .env("GITHUB_PAT", "github-pat-must-not-reach-child");
    for (name, value) in overrides {
        command.env(name, value);
    }
    let output = command.output().unwrap();
    socket_worker.join().unwrap();
    output
}

#[cfg(all(unix, debug_assertions))]
struct HandoffCapture {
    path: String,
    body: String,
    headers: Vec<(String, String)>,
}

#[cfg(all(unix, debug_assertions))]
fn start_handoff_server(
    status: u16,
    payload: serde_json::Value,
) -> (String, std::sync::mpsc::Receiver<HandoffCapture>) {
    use std::sync::mpsc;

    let server = Server::http("127.0.0.1:0").unwrap();
    let address = server.server_addr().to_ip().unwrap();
    let base_url = format!("http://{address}");
    let replacement = base_url.clone();
    let (sent, received) = mpsc::channel();
    thread::spawn(move || {
        // Keep the listener alive for one short second-request window. A
        // handoff command must not emit a second analytics request.
        for index in 0..2 {
            let timeout = if index == 0 {
                Duration::from_secs(3)
            } else {
                Duration::from_millis(350)
            };
            let Ok(Some(mut request)) = server.recv_timeout(timeout) else {
                return;
            };
            let path = request.url().to_owned();
            let headers = request
                .headers()
                .iter()
                .map(|header| {
                    (
                        header.field.as_str().as_str().to_owned(),
                        header.value.as_str().to_owned(),
                    )
                })
                .collect();
            let mut request_body = String::new();
            request
                .as_reader()
                .read_to_string(&mut request_body)
                .unwrap();
            let response_body = serde_json::to_string(&payload)
                .unwrap()
                .replace("__BASE__", &replacement);
            request
                .respond(
                    Response::from_string(response_body)
                        .with_status_code(status)
                        .with_header(
                            Header::from_bytes("content-type", "application/json").unwrap(),
                        ),
                )
                .unwrap();
            sent.send(HandoffCapture {
                path,
                body: request_body,
                headers,
            })
            .unwrap();
        }
    });
    (base_url, received)
}

#[cfg(all(unix, debug_assertions))]
fn valid_handoff_lease() -> String {
    format!("crh_{}", "B".repeat(43))
}

#[cfg(all(unix, debug_assertions))]
fn valid_route_token() -> String {
    format!("crt_{}", "A".repeat(43))
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
            "teamName": "coderouter",
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

    fn start_status(
        requests: usize,
        handler: impl Fn(&str) -> (u16, serde_json::Value) + Send + 'static,
    ) -> Self {
        let server = Server::http("127.0.0.1:0").unwrap();
        let address = server.server_addr().to_ip().unwrap();
        let base_url = format!("http://{address}");
        let replacement = base_url.clone();
        thread::spawn(move || {
            for _ in 0..requests {
                let request = server.recv().unwrap();
                let (status, value) = handler(request.url());
                let body = serde_json::to_string(&value)
                    .unwrap()
                    .replace("__BASE__", &replacement);
                request
                    .respond(
                        Response::from_string(body)
                            .with_status_code(status)
                            .with_header(
                                Header::from_bytes("content-type", "application/json").unwrap(),
                            ),
                    )
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
