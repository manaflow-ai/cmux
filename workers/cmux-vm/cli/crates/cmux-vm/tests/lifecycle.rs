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
        "state": state,
        "resources": { "vcpus": 2, "memoryMib": 4096, "diskMib": 16384 },
        "idleTimeoutSeconds": 300,
        "createdAt": "2026-10-07T00:00:00.000Z",
        "updatedAt": "2026-10-07T00:00:00.000Z"
    })
}

struct Output {
    code: i32,
    stdout: String,
    stderr: String,
}

async fn cli_with_env(args: &[&str], env: &[(&str, &str)]) -> Output {
    let env: Vec<(String, String)> = env
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    let lookup = move |name: &str| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let argv = std::iter::once("cmux-vm").chain(args.iter().copied());
    let code = cmux_vm::run(argv, &lookup, &mut stdout, &mut stderr).await;
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

    let out = cli(&server, &["--json", "delete", VM_ID]).await;

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
