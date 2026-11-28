//! Drives every lifecycle verb against a local mock of the cmux VM API and
//! checks the request the CLI sends, its output and its exit code.

use cmux_vm::exit;
use serde_json::{Value, json};
use wiremock::matchers::{body_json, header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";
const KEY: &str = "cmuxvm_sk_test";

fn vm(state: &str) -> Value {
    json!({
        "id": VM_ID,
        "displayName": null,
        "labels": {},
        "state": state,
        "resources": { "vcpus": 2, "memoryMib": 4096, "diskMib": 16384 },
        "idleTimeoutSeconds": 300,
        "maxRunSeconds": null,
        "autoDeleteSeconds": null,
        "createdAt": "2026-10-07T00:00:00.000Z",
        "updatedAt": "2026-10-07T00:00:00.000Z"
    })
}

struct Output {
    code: i32,
    stdout: String,
    stderr: String,
}

/// A terminal that answers every question with `answer`.
struct Tty {
    answer: &'static str,
    asked: usize,
}

impl cmux_vm::Prompt for Tty {
    fn is_interactive(&self) -> bool {
        true
    }

    fn ask(&mut self, _question: &str) -> std::io::Result<String> {
        self.asked += 1;
        Ok(format!("{}\n", self.answer))
    }
}

async fn cli_with_env(args: &[&str], env: &[(&str, &str)]) -> Output {
    cli_with_prompt(args, env, &mut cmux_vm::NoPrompt).await
}

async fn cli_with_prompt(
    args: &[&str],
    env: &[(&str, &str)],
    prompt: &mut dyn cmux_vm::Prompt,
) -> Output {
    let env: Vec<(String, String)> = env
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    let lookup = move |name: &str| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let argv = std::iter::once("cmux-vm").chain(args.iter().copied());
    let code = cmux_vm::run(argv, &lookup, prompt, &mut stdout, &mut stderr).await;
    Output {
        code,
        stdout: String::from_utf8(stdout).expect("utf-8 stdout"),
        stderr: String::from_utf8(stderr).expect("utf-8 stderr"),
    }
}

async fn cli(server: &MockServer, args: &[&str]) -> Output {
    let uri = server.uri();
    cli_with_env(
        args,
        &[("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())],
    )
    .await
}

fn authorized() -> wiremock::matchers::HeaderExactMatcher {
    header("authorization", format!("Bearer {KEY}").as_str())
}

fn json_stdout(out: &Output) -> Value {
    serde_json::from_str(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "stdout is not JSON ({e}): {}\nstderr: {}",
            out.stdout, out.stderr
        )
    })
}

#[tokio::test]
async fn create_sends_the_body_and_idempotency_key() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(authorized())
        .and(header("idempotency-key", "retry-1"))
        .and(body_json(
            json!({ "displayName": "dev box", "idleTimeoutSeconds": 300 }),
        ))
        .respond_with(ResponseTemplate::new(201).set_body_json(vm("starting")))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(
        &server,
        &[
            "--json",
            "create",
            "--name",
            "dev box",
            "--idle-timeout",
            "300",
            "--idempotency-key",
            "retry-1",
        ],
    )
    .await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out)["id"], VM_ID);
    assert_eq!(json_stdout(&out)["state"], "starting");
}

#[tokio::test]
async fn get_prints_the_vm() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(&server, &["get", VM_ID]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert!(out.stdout.contains(VM_ID), "stdout: {}", out.stdout);
    assert!(out.stdout.contains("running"), "stdout: {}", out.stdout);
}

#[tokio::test]
async fn list_passes_filters_and_returns_the_page() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/vms"))
        .and(authorized())
        .and(query_param("limit", "5"))
        .and(query_param("state", "running"))
        .and(query_param("cursor", "page-1"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "items": [vm("running")], "nextCursor": "page-2" })),
        )
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(
        &server,
        &[
            "--json", "list", "--limit", "5", "--state", "running", "--cursor", "page-1",
        ],
    )
    .await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    let page = json_stdout(&out);
    assert_eq!(page["items"][0]["id"], VM_ID);
    assert_eq!(page["nextCursor"], "page-2");
}

#[tokio::test]
async fn start_stop_pause_resume_post_to_their_action() {
    for (verb, state) in [
        ("start", "running"),
        ("stop", "stopped"),
        ("pause", "paused"),
        ("resume", "running"),
    ] {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(format!("/v1/vms/{VM_ID}/{verb}")))
            .and(authorized())
            .respond_with(ResponseTemplate::new(200).set_body_json(vm(state)))
            .expect(1)
            .mount(&server)
            .await;

        let out = cli(&server, &["--json", verb, VM_ID]).await;

        assert_eq!(out.code, exit::OK, "{verb}: stderr: {}", out.stderr);
        assert_eq!(json_stdout(&out)["state"], state, "{verb}");
    }
}

#[tokio::test]
async fn fork_sends_the_body() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/fork")))
        .and(authorized())
        .and(body_json(json!({ "displayName": "copy" })))
        .respond_with(ResponseTemplate::new(201).set_body_json(vm("starting")))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(&server, &["--json", "fork", VM_ID, "--name", "copy"]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out)["id"], VM_ID);
}

#[tokio::test]
async fn delete_reports_the_deleted_id() {
    let server = MockServer::start().await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(&server, &["--json", "delete", VM_ID, "--yes"]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out), json!({ "id": VM_ID, "deleted": true }));
}

#[tokio::test]
async fn team_flag_sends_the_team_header() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(authorized())
        .and(header("x-cmux-team-id", "team_42"))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(&server, &["--team", "team_42", "get", VM_ID]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
}

#[tokio::test]
async fn not_found_is_its_own_exit_code() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({ "_tag": "NotFound", "message": "VM not found" })),
        )
        .mount(&server)
        .await;

    let out = cli(&server, &["get", VM_ID]).await;

    assert_eq!(out.code, exit::NOT_FOUND, "stderr: {}", out.stderr);
    assert_ne!(exit::NOT_FOUND, exit::UNAUTHENTICATED);
    assert!(
        out.stderr.contains("VM not found"),
        "stderr: {}",
        out.stderr
    );
}

#[tokio::test]
async fn every_documented_error_status_has_a_distinct_exit_code() {
    let cases = [
        (400, "HttpApiDecodeError", exit::BAD_REQUEST),
        (401, "Unauthorized", exit::UNAUTHENTICATED),
        (402, "PaymentRequired", exit::PAYMENT_REQUIRED),
        (403, "Forbidden", exit::FORBIDDEN),
        (404, "NotFound", exit::NOT_FOUND),
        (409, "Conflict", exit::CONFLICT),
        (413, "PayloadTooLarge", exit::PAYLOAD_TOO_LARGE),
        (426, "UpgradeRequired", exit::UPGRADE_REQUIRED),
        (429, "QuotaExceeded", exit::QUOTA_EXCEEDED),
        (501, "NotImplemented", exit::NOT_AVAILABLE_YET),
        (503, "ServiceUnavailable", exit::SERVICE_UNAVAILABLE),
    ];
    let mut seen = std::collections::BTreeSet::new();
    for (status, tag, expected) in cases {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(format!("/v1/vms/{VM_ID}/stop")))
            .respond_with(
                ResponseTemplate::new(status)
                    .set_body_json(json!({ "_tag": tag, "message": format!("{tag} message") })),
            )
            .mount(&server)
            .await;

        let out = cli(&server, &["--json", "stop", VM_ID]).await;

        assert_eq!(out.code, expected, "HTTP {status}: stderr: {}", out.stderr);
        let error: Value = serde_json::from_str(&out.stderr)
            .unwrap_or_else(|e| panic!("HTTP {status}: stderr is not JSON ({e}): {}", out.stderr));
        assert_eq!(error["error"]["status"], status);
        assert_eq!(error["error"]["tag"], tag);
        assert_eq!(error["error"]["exitCode"], expected);
        assert!(
            seen.insert(expected),
            "exit code {expected} reused for HTTP {status}"
        );
    }
    assert!(!seen.contains(&exit::OK) && !seen.contains(&exit::USAGE));
}

#[tokio::test]
async fn not_implemented_says_not_available_yet() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/pause")))
        .respond_with(ResponseTemplate::new(501).set_body_json(
            json!({ "_tag": "NotImplemented", "message": "pauseVm is not available yet" }),
        ))
        .mount(&server)
        .await;

    let out = cli(&server, &["pause", VM_ID]).await;

    assert_eq!(out.code, exit::NOT_AVAILABLE_YET);
    assert!(
        out.stderr.contains("not available yet"),
        "stderr: {}",
        out.stderr
    );
}

#[tokio::test]
async fn a_non_json_error_body_keeps_its_status() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(404).set_body_string("<html>not here</html>"))
        .mount(&server)
        .await;

    let out = cli(&server, &["get", VM_ID]).await;

    assert_eq!(out.code, exit::NOT_FOUND, "stderr: {}", out.stderr);
}

#[tokio::test]
async fn a_missing_api_key_fails_as_auth_without_a_request() {
    let server = MockServer::start().await;
    Mock::given(wiremock::matchers::any())
        .respond_with(ResponseTemplate::new(500))
        .expect(0)
        .mount(&server)
        .await;

    let uri = server.uri();
    let out = cli_with_env(&["get", VM_ID], &[("CMUX_VM_BASE_URL", uri.as_str())]).await;

    assert_eq!(out.code, exit::UNAUTHENTICATED, "stderr: {}", out.stderr);
    assert!(
        out.stderr.contains("CMUX_VM_API_KEY"),
        "stderr: {}",
        out.stderr
    );
}

#[tokio::test]
async fn the_config_file_supplies_key_base_url_and_team() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(authorized())
        .and(header("x-cmux-team-id", "team_from_file"))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .expect(1)
        .mount(&server)
        .await;

    let dir = std::env::temp_dir().join(format!("cmux-vm-config-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let config = dir.join("vm.json");
    std::fs::write(
        &config,
        json!({ "apiKey": KEY, "baseUrl": server.uri(), "teamId": "team_from_file" }).to_string(),
    )
    .expect("write config");

    let config_path = config.to_string_lossy().into_owned();
    let out = cli_with_env(&["get", VM_ID], &[("CMUX_VM_CONFIG", config_path.as_str())]).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
}

/// The process exit status, not just the library's return value.
#[tokio::test(flavor = "multi_thread")]
async fn the_binary_exits_with_distinct_codes_for_not_found_and_auth() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/vms/vm_missing"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({ "_tag": "NotFound", "message": "VM not found" })),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/vms/vm_badkey"))
        .respond_with(
            ResponseTemplate::new(401)
                .set_body_json(json!({ "_tag": "Unauthorized", "message": "Invalid API key" })),
        )
        .mount(&server)
        .await;

    let run = |vm_id: &'static str| {
        let uri = server.uri();
        tokio::task::spawn_blocking(move || {
            std::process::Command::new(env!("CARGO_BIN_EXE_cmux-vm"))
                .args(["get", vm_id])
                .env_clear()
                .env("CMUX_VM_API_KEY", KEY)
                .env("CMUX_VM_BASE_URL", uri)
                .output()
                .expect("run cmux-vm")
        })
    };
    let not_found = run("vm_missing").await.expect("join");
    let unauthenticated = run("vm_badkey").await.expect("join");

    assert_eq!(not_found.status.code(), Some(exit::NOT_FOUND));
    assert_eq!(unauthenticated.status.code(), Some(exit::UNAUTHENTICATED));
}

#[tokio::test]
async fn json_output_matches_the_response_body() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .mount(&server)
        .await;

    let out = cli(&server, &["--json", "get", VM_ID]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out), vm("running"));
}

#[tokio::test]
async fn create_without_a_key_sends_a_generated_idempotency_key() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(wiremock::matchers::header_exists("idempotency-key"))
        .and(body_json(json!({})))
        .respond_with(ResponseTemplate::new(201).set_body_json(vm("starting")))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(&server, &["create"]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
}

#[tokio::test]
async fn an_unreachable_create_prints_the_key_to_retry_with() {
    // Nothing listens on port 9 (discard) on test hosts; the connection fails.
    let out = cli_with_env(
        &["create", "--idempotency-key", "retry-7"],
        &[
            ("CMUX_VM_API_KEY", KEY),
            ("CMUX_VM_BASE_URL", "http://127.0.0.1:9"),
        ],
    )
    .await;

    assert_eq!(out.code, exit::NETWORK, "stderr: {}", out.stderr);
    assert!(
        out.stderr.contains("--idempotency-key retry-7"),
        "stderr: {}",
        out.stderr
    );
}

#[tokio::test]
async fn flag_beats_env_beats_config_file() {
    let flag_server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(header("authorization", "Bearer key_from_env"))
        .and(header("x-cmux-team-id", "team_from_flag"))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .expect(1)
        .mount(&flag_server)
        .await;

    let dir = std::env::temp_dir().join(format!("cmux-vm-precedence-test-{}", std::process::id()));
    let config_dir = dir.join("cmux");
    std::fs::create_dir_all(&config_dir).expect("create temp dir");
    std::fs::write(
        config_dir.join("vm.json"),
        json!({
            "apiKey": "key_from_file",
            "baseUrl": "http://127.0.0.1:9",
            "teamId": "team_from_file"
        })
        .to_string(),
    )
    .expect("write config");

    // The default location ($XDG_CONFIG_HOME/cmux/vm.json) is read, the env
    // key beats the file's, the env base URL beats the file's, and the flag
    // team beats both the env and the file.
    let xdg = dir.to_string_lossy().into_owned();
    let uri = flag_server.uri();
    let out = cli_with_env(
        &["--team", "team_from_flag", "get", VM_ID],
        &[
            ("XDG_CONFIG_HOME", xdg.as_str()),
            ("CMUX_VM_API_KEY", "key_from_env"),
            ("CMUX_VM_BASE_URL", uri.as_str()),
            ("CMUX_VM_TEAM_ID", "team_from_env"),
        ],
    )
    .await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
}

#[tokio::test]
async fn bad_base_url_and_empty_team_are_usage_errors() {
    let out = cli_with_env(
        &["get", VM_ID],
        &[
            ("CMUX_VM_API_KEY", KEY),
            ("CMUX_VM_BASE_URL", "vm.cmux.dev"),
        ],
    )
    .await;
    assert_eq!(out.code, exit::USAGE, "stderr: {}", out.stderr);

    let out = cli_with_env(
        &["--team", "", "get", VM_ID],
        &[
            ("CMUX_VM_API_KEY", KEY),
            ("CMUX_VM_BASE_URL", "http://127.0.0.1:9"),
        ],
    )
    .await;
    assert_eq!(out.code, exit::USAGE, "stderr: {}", out.stderr);
}

#[tokio::test]
async fn json_output_keeps_fields_this_cli_does_not_know() {
    let mut body = vm("hibernating");
    body["region"] = json!("eu-west");
    body["resources"]["gpus"] = json!(1);
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(body.clone()))
        .mount(&server)
        .await;

    let out = cli(&server, &["--json", "get", VM_ID]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out), body);
}

#[tokio::test]
async fn usage_errors_are_json_with_the_json_flag() {
    let out = cli_with_env(&["--json", "get"], &[("CMUX_VM_API_KEY", KEY)]).await;

    assert_eq!(out.code, exit::USAGE, "stderr: {}", out.stderr);
    let error: Value = serde_json::from_str(out.stderr.trim())
        .unwrap_or_else(|e| panic!("stderr is not JSON ({e}): {}", out.stderr));
    assert_eq!(error["error"]["exitCode"], exit::USAGE);
    assert_eq!(error["error"]["tag"], "UsageError");
}

#[tokio::test]
async fn a_broken_default_config_only_warns_when_env_gives_every_value() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("running")))
        .mount(&server)
        .await;
    let dir =
        std::env::temp_dir().join(format!("cmux-vm-broken-config-test-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("cmux")).expect("create temp dir");
    std::fs::write(dir.join("cmux").join("vm.json"), "{ not json").expect("write config");
    let xdg = dir.to_string_lossy().into_owned();
    let uri = server.uri();

    let complete = cli_with_env(
        &["get", VM_ID],
        &[
            ("XDG_CONFIG_HOME", xdg.as_str()),
            ("CMUX_VM_API_KEY", KEY),
            ("CMUX_VM_BASE_URL", uri.as_str()),
        ],
    )
    .await;
    let incomplete = cli_with_env(
        &["get", VM_ID],
        &[("XDG_CONFIG_HOME", xdg.as_str()), ("CMUX_VM_API_KEY", KEY)],
    )
    .await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(complete.code, exit::OK, "stderr: {}", complete.stderr);
    assert!(
        complete.stderr.contains("warning"),
        "stderr: {}",
        complete.stderr
    );
    assert_eq!(
        incomplete.code,
        exit::USAGE,
        "stderr: {}",
        incomplete.stderr
    );
}

#[tokio::test]
async fn delete_without_a_terminal_needs_yes() {
    let server = MockServer::start().await;
    Mock::given(wiremock::matchers::any())
        .respond_with(ResponseTemplate::new(204))
        .expect(0)
        .mount(&server)
        .await;

    let out = cli(&server, &["--json", "delete", VM_ID]).await;

    assert_eq!(out.code, exit::USAGE, "stderr: {}", out.stderr);
    let error: Value = serde_json::from_str(out.stderr.trim()).expect("JSON error");
    assert!(
        error["error"]["message"]
            .as_str()
            .is_some_and(|m| m.contains("--yes")),
        "stderr: {}",
        out.stderr
    );
}

#[tokio::test]
async fn delete_at_a_terminal_needs_the_typed_vm_id() {
    let server = MockServer::start().await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let uri = server.uri();
    let env = [("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())];

    let mut wrong = Tty {
        answer: "yes",
        asked: 0,
    };
    let refused = cli_with_prompt(&["delete", VM_ID], &env, &mut wrong).await;
    let mut right = Tty {
        answer: VM_ID,
        asked: 0,
    };
    let confirmed = cli_with_prompt(&["delete", VM_ID], &env, &mut right).await;

    assert_eq!(refused.code, exit::CANCELLED, "stderr: {}", refused.stderr);
    assert_eq!(wrong.asked, 1);
    assert_eq!(confirmed.code, exit::OK, "stderr: {}", confirmed.stderr);
    assert_eq!(right.asked, 1);
}

/// The real binary with stdin that is not a terminal refuses a bare delete.
#[tokio::test(flavor = "multi_thread")]
async fn the_binary_refuses_delete_without_yes_when_stdin_is_not_a_terminal() {
    let output = tokio::task::spawn_blocking(|| {
        std::process::Command::new(env!("CARGO_BIN_EXE_cmux-vm"))
            .args(["delete", VM_ID])
            .env_clear()
            .env("CMUX_VM_API_KEY", KEY)
            .env("CMUX_VM_BASE_URL", "http://127.0.0.1:9")
            .stdin(std::process::Stdio::null())
            .output()
            .expect("run cmux-vm")
    })
    .await
    .expect("join");

    assert_eq!(output.status.code(), Some(exit::USAGE));
}

const SNAP_ID: &str = "snap_0123456789abcdefghjkmnpqrs";
const VM_KEY_ID: &str = "vmk_0123456789abcdefghjkmnpqrs";

fn snapshot() -> Value {
    json!({
        "id": SNAP_ID,
        "sourceVmId": VM_ID,
        "displayName": "base",
        "labels": {},
        "createdAt": "2026-10-07T00:00:00.000Z",
        "lastUsedAt": null,
        "ttlSeconds": 3600,
        "autoDeleteSeconds": null
    })
}

#[tokio::test]
async fn snapshot_create_sends_the_body_and_idempotency_key() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/snapshots")))
        .and(authorized())
        .and(header("idempotency-key", "snap-1"))
        .and(body_json(
            json!({ "displayName": "base", "ttlSeconds": 3600 }),
        ))
        .respond_with(ResponseTemplate::new(201).set_body_json(snapshot()))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(
        &server,
        &[
            "--json",
            "snapshot",
            "create",
            VM_ID,
            "--name",
            "base",
            "--ttl",
            "3600",
            "--idempotency-key",
            "snap-1",
        ],
    )
    .await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out)["id"], SNAP_ID);
}

#[tokio::test]
async fn snapshot_get_list_and_delete() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/snapshots/{SNAP_ID}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(snapshot()))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/snapshots"))
        .and(authorized())
        .and(query_param("sourceVmId", VM_ID))
        .and(query_param("limit", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "items": [{
                "id": SNAP_ID,
                "sourceVmId": VM_ID,
                "displayName": null,
                "labels": {},
                "createdAt": "2026-10-07T00:00:00.000Z"
            }],
            "nextCursor": "page-2"
        })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/snapshots/{SNAP_ID}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    let got = cli(&server, &["snapshot", "get", SNAP_ID]).await;
    assert_eq!(got.code, exit::OK, "stderr: {}", got.stderr);
    assert!(
        got.stdout.contains(SNAP_ID) && got.stdout.contains(VM_ID),
        "stdout: {}",
        got.stdout
    );

    let listed = cli(
        &server,
        &["snapshot", "list", "--vm", VM_ID, "--limit", "2"],
    )
    .await;
    assert_eq!(listed.code, exit::OK, "stderr: {}", listed.stderr);
    assert!(
        listed
            .stdout
            .contains("cmux-vm snapshot list --cursor page-2"),
        "stdout: {}",
        listed.stdout
    );

    let deleted = cli(&server, &["--json", "snapshot", "delete", SNAP_ID, "--yes"]).await;
    assert_eq!(deleted.code, exit::OK, "stderr: {}", deleted.stderr);
    assert_eq!(
        json_stdout(&deleted),
        json!({ "id": SNAP_ID, "deleted": true })
    );
}

#[tokio::test]
async fn snapshot_delete_and_key_revoke_need_confirmation() {
    let server = MockServer::start().await;
    Mock::given(wiremock::matchers::any())
        .respond_with(ResponseTemplate::new(204))
        .expect(0)
        .mount(&server)
        .await;
    let uri = server.uri();
    let env = [("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())];

    for args in [
        ["snapshot", "delete", SNAP_ID],
        ["api-key", "revoke", VM_KEY_ID],
    ] {
        let no_tty = cli(&server, &args).await;
        assert_eq!(
            no_tty.code,
            exit::USAGE,
            "{args:?}: stderr: {}",
            no_tty.stderr
        );
        assert!(
            no_tty.stderr.contains("--yes"),
            "{args:?}: stderr: {}",
            no_tty.stderr
        );

        let mut wrong = Tty {
            answer: "yes",
            asked: 0,
        };
        let refused = cli_with_prompt(&args, &env, &mut wrong).await;
        assert_eq!(
            refused.code,
            exit::CANCELLED,
            "{args:?}: stderr: {}",
            refused.stderr
        );
        assert_eq!(wrong.asked, 1);
    }
}

#[tokio::test]
async fn api_key_create_prints_the_secret_once_and_sends_scopes_and_resources() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/api-keys"))
        .and(authorized())
        .and(body_json(json!({
            "name": "ci",
            "scopes": ["vm:read", "snapshot:read"],
            "resourceAllowlist": [VM_ID, SNAP_ID],
            "expiresAt": "2026-11-01T00:00:00.000Z"
        })))
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({
            "id": VM_KEY_ID,
            "name": "ci",
            "scopes": ["vm:read", "snapshot:read"],
            "resourceAllowlist": [VM_ID, SNAP_ID],
            "createdAt": "2026-10-07T00:00:00.000Z",
            "expiresAt": "2026-11-01T00:00:00.000Z",
            "key": "cmuxvm_sk_new"
        })))
        .expect(1)
        .mount(&server)
        .await;

    let out = cli(
        &server,
        &[
            "api-key",
            "create",
            "--name",
            "ci",
            "--scope",
            "vm:read",
            "--scope",
            "snapshot:read",
            "--resource",
            VM_ID,
            "--resource",
            SNAP_ID,
            "--expires-at",
            "2026-11-01T00:00:00.000Z",
        ],
    )
    .await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert!(
        out.stdout.contains("cmuxvm_sk_new"),
        "stdout: {}",
        out.stdout
    );
    assert!(
        out.stdout.contains("shown only once"),
        "stdout: {}",
        out.stdout
    );
}

#[tokio::test]
async fn api_key_create_needs_a_scope_and_rejects_a_foreign_resource_id() {
    let no_scope = cli_with_env(
        &["api-key", "create", "--name", "ci"],
        &[("CMUX_VM_API_KEY", KEY)],
    )
    .await;
    assert_eq!(no_scope.code, exit::USAGE, "stderr: {}", no_scope.stderr);

    let bad_resource = cli_with_env(
        &[
            "api-key",
            "create",
            "--name",
            "ci",
            "--scope",
            "vm:read",
            "--resource",
            "team_1",
        ],
        &[
            ("CMUX_VM_API_KEY", KEY),
            ("CMUX_VM_BASE_URL", "http://127.0.0.1:9"),
        ],
    )
    .await;
    assert_eq!(
        bad_resource.code,
        exit::USAGE,
        "stderr: {}",
        bad_resource.stderr
    );
}

#[tokio::test]
async fn api_key_list_and_revoke() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/api-keys"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "items": [{
                "id": VM_KEY_ID,
                "name": "ci",
                "scopes": ["vm:read"],
                "resourceAllowlist": null,
                "createdBy": "user_1",
                "createdAt": "2026-10-07T00:00:00.000Z",
                "expiresAt": null,
                "revokedAt": null
            }]
        })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/api-keys/{VM_KEY_ID}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    let listed = cli(&server, &["api-key", "list"]).await;
    assert_eq!(listed.code, exit::OK, "stderr: {}", listed.stderr);
    assert!(
        listed.stdout.contains(VM_KEY_ID),
        "stdout: {}",
        listed.stdout
    );
    assert!(
        !listed.stdout.contains("cmuxvm_sk"),
        "stdout: {}",
        listed.stdout
    );

    let revoked = cli(
        &server,
        &["--json", "api-key", "revoke", VM_KEY_ID, "--yes"],
    )
    .await;
    assert_eq!(revoked.code, exit::OK, "stderr: {}", revoked.stderr);
    assert_eq!(
        json_stdout(&revoked),
        json!({ "id": VM_KEY_ID, "revoked": true })
    );
}

#[tokio::test]
async fn a_quota_error_names_its_budget() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/snapshots")))
        .respond_with(ResponseTemplate::new(429).set_body_json(json!({
            "_tag": "QuotaExceeded",
            "message": "snapshot limit reached",
            "budget": "snapshots"
        })))
        .mount(&server)
        .await;

    let json_out = cli(&server, &["--json", "snapshot", "create", VM_ID]).await;
    assert_eq!(
        json_out.code,
        exit::QUOTA_EXCEEDED,
        "stderr: {}",
        json_out.stderr
    );
    let error: Value = serde_json::from_str(json_out.stderr.trim()).expect("JSON error");
    assert_eq!(error["error"]["budget"], "snapshots");

    let human = cli(&server, &["snapshot", "create", VM_ID]).await;
    assert_eq!(human.code, exit::QUOTA_EXCEEDED);
    assert!(
        human.stderr.contains("budget snapshots"),
        "stderr: {}",
        human.stderr
    );
}

#[tokio::test]
async fn help_names_the_cmux_dev_default_base_url() {
    let out = cli_with_env(&["--help"], &[]).await;

    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert!(
        out.stdout.contains("default https://vm.cmux.dev"),
        "stdout: {}",
        out.stdout
    );
    assert_eq!(cmux_vm_client::DEFAULT_BASE_URL, "https://vm.cmux.dev");
}
