//! Drives every lifecycle verb against a local mock of the cmux VM API and
//! checks the request the CLI sends, its output and its exit code.

use cmux_vm::exit;
use serde_json::{Value, json};
use wiremock::matchers::{body_json, body_string_contains, header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn approved_server_codes_redeem_without_account_configuration_or_headers() {
    let server = MockServer::start().await;
    let mesh = "mesh_00000000000000000000000000";
    let id = "dev_00000000000000000000000000";
    let install =
        "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
    let wg = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
    let code = "msc_00000000000000000000000000";
    let binding = json!({"name":"server","wgPublicKey":wg,"installPublicKey":install});
    let grant = json!({"code":code,"deviceId":id,"meshId":mesh,"tenantId":"team_alpha","expiresAt":"2026-10-19T00:10:00Z","binding":binding});
    let dir = std::env::temp_dir().join(format!("cmux-server-code-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("request.json");
    std::fs::write(&file, serde_json::to_vec(&binding).unwrap()).unwrap();
    Mock::given(method("POST"))
        .and(path(format!("/v1/meshes/{mesh}/overlay-server-codes")))
        .and(authorized())
        .and(body_json(&binding))
        .respond_with(ResponseTemplate::new(201).set_body_json(&grant))
        .expect(1)
        .mount(&server)
        .await;
    let output = cli(
        &server,
        &[
            "--json",
            "device",
            "server-code",
            mesh,
            "--request",
            file.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    assert_eq!(json_stdout(&output), grant);
    let request = json!({"code":code,"name":"server","wgPublicKey":wg,"installPublicKey":install,"signedAt":1792370000000_i64,"nonce":"AAECAwQFBgcICQoLDA0ODw","signature":"A".repeat(86)+"=="});
    let mut local = request.clone();
    local["privateKey"] = json!("must-not-be-sent");
    std::fs::write(&file, serde_json::to_vec(&local).unwrap()).unwrap();
    let receipt = json!({"id":id,"meshId":mesh,"name":"server","wgPublicKey":wg,"installPublicKey":install,"createdAt":"2026-10-19T00:00:00Z","kind":"server","transport":"overlay"});
    Mock::given(method("POST"))
        .and(path(format!(
            "/v1/meshes/{mesh}/overlay-server-enrollments"
        )))
        .and(body_json(&request))
        .respond_with(ResponseTemplate::new(201).set_body_json(&receipt))
        .expect(2)
        .mount(&server)
        .await;
    let uri = server.uri();
    let args = [
        "--json",
        "device",
        "redeem-server-code",
        mesh,
        "--request",
        file.to_str().unwrap(),
    ];
    let output = cli_with_env(&args, &[("CMUX_VM_BASE_URL", uri.as_str())]).await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    assert_eq!(json_stdout(&output), receipt);
    // Existing ambient credentials must not accompany this request either.
    let output = cli(&server, &args).await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    for request in server
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|r| r.url.path().ends_with("/overlay-server-enrollments"))
    {
        assert!(!request.headers.contains_key("authorization"));
        assert!(!request.headers.contains_key("x-cmux-team-id"));
    }
    assert!(!output.stderr.contains(code));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn signed_server_codes_do_not_follow_redirects_or_echo_invalid_files() {
    let server = MockServer::start().await;
    let destination = MockServer::start().await;
    let mesh = "mesh_00000000000000000000000000";
    let code = "msc_00000000000000000000000000";
    let request = json!({"code":code,"name":"server","wgPublicKey":"dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=","installPublicKey":"BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=","signedAt":1792370000000_i64,"nonce":"AAECAwQFBgcICQoLDA0ODw","signature":"A".repeat(86)+"=="});
    let dir =
        std::env::temp_dir().join(format!("cmux-server-code-redirect-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("signed.json");
    std::fs::write(&file, serde_json::to_vec(&request).unwrap()).unwrap();
    Mock::given(method("POST"))
        .and(path(format!(
            "/v1/meshes/{mesh}/overlay-server-enrollments"
        )))
        .respond_with(
            ResponseTemplate::new(307)
                .insert_header("Location", format!("{}/leak", destination.uri())),
        )
        .expect(1)
        .mount(&server)
        .await;
    let uri = server.uri();
    let args = [
        "--json",
        "device",
        "redeem-server-code",
        mesh,
        "--request",
        file.to_str().unwrap(),
    ];
    let output = cli_with_env(&args, &[("CMUX_VM_BASE_URL", uri.as_str())]).await;
    assert_ne!(output.code, exit::OK);
    assert!(destination.received_requests().await.unwrap().is_empty());
    std::fs::write(&file, format!("{code} privateKey invalid-json")).unwrap();
    let output = cli_with_env(&args, &[("CMUX_VM_BASE_URL", uri.as_str())]).await;
    assert_eq!(output.code, exit::USAGE);
    assert!(!output.stderr.contains(code));
    assert!(!output.stderr.contains("privateKey"));
    std::fs::write(&file, "x".repeat(16_385)).unwrap();
    let output = cli_with_env(&args, &[("CMUX_VM_BASE_URL", uri.as_str())]).await;
    assert_eq!(output.code, exit::USAGE);
    assert!(output.stderr.contains("16 KiB"));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn provider_free_server_enrollment_and_policy_use_their_own_routes() {
    let server = MockServer::start().await;
    let mesh = "mesh_00000000000000000000000000";
    let id = "dev_00000000000000000000000000";
    let install =
        "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
    let wg = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
    let request = json!({"name":"server","wgPublicKey":wg,"installPublicKey":install,"signedAt":1792370000000_i64,"nonce":"AAECAwQFBgcICQoLDA0ODw","signature":"A".repeat(86)+"=="});
    let dir = std::env::temp_dir().join(format!("cmux-overlay-server-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("enroll.json");
    let mut local = request.clone();
    local["privateKey"] = json!("must-not-be-sent");
    std::fs::write(&file, serde_json::to_vec(&local).unwrap()).unwrap();
    let receipt = json!({"id":id,"meshId":mesh,"name":"server","wgPublicKey":wg,"installPublicKey":install,"createdAt":"2026-10-19T00:00:00Z","kind":"server","transport":"overlay"});
    Mock::given(method("POST"))
        .and(path(format!("/v1/meshes/{mesh}/overlay-servers")))
        .and(authorized())
        .and(body_json(&request))
        .respond_with(ResponseTemplate::new(201).set_body_json(&receipt))
        .expect(1)
        .mount(&server)
        .await;
    let output = cli(
        &server,
        &[
            "--json",
            "device",
            "enroll-server",
            mesh,
            "--request",
            file.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    assert_eq!(json_stdout(&output), receipt);
    let policy = json!({"tenantId":"team_alpha","deviceId":id,"meshId":mesh,"wgPublicKey":wg,"installPublicKey":install,"aclVersion":0,"policyDigest":"a".repeat(64),"peers":[]});
    Mock::given(method("GET"))
        .and(path(format!("/v1/overlay-servers/{id}/policy")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&policy))
        .expect(1)
        .mount(&server)
        .await;
    let output = cli(&server, &["--json", "device", "server-policy", id]).await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    assert_eq!(json_stdout(&output), policy);
    Mock::given(method("GET"))
        .and(path(format!("/v1/overlay-servers/{id}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(1)
        .mount(&server)
        .await;
    assert_eq!(
        json_stdout(&cli(&server, &["--json", "device", "get-server", id]).await),
        receipt
    );
    let list = json!({"items":[receipt]});
    Mock::given(method("GET"))
        .and(path(format!("/v1/meshes/{mesh}/overlay-servers")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&list))
        .expect(1)
        .mount(&server)
        .await;
    assert_eq!(
        json_stdout(&cli(&server, &["--json", "device", "servers", mesh]).await),
        list
    );
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/overlay-servers/{id}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    assert_eq!(
        cli(&server, &["device", "revoke-server", id]).await.code,
        exit::USAGE
    );
    let revoked = cli(&server, &["--json", "device", "revoke-server", id, "--yes"]).await;
    assert_eq!(revoked.code, exit::OK, "{}", revoked.stderr);
    assert_eq!(json_stdout(&revoked), json!({"id":id,"revoked":true}));
    std::fs::remove_dir_all(dir).unwrap();
    assert_eq!(server.received_requests().await.unwrap().len(), 5);
}

#[tokio::test]
async fn device_overlay_policy_is_a_single_authorized_read_with_direction_preserved() {
    let server = MockServer::start().await;
    let device = "dev_00000000000000000000000000";
    let receipt = json!({
        "deviceId":device,"meshId":"mesh_00000000000000000000000000",
        "wgPublicKey":"dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=",
        "installPublicKey":"BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=",
        "aclVersion":4,"policyDigest":"a".repeat(64),"peers":[{
          "deviceId":"dev_00000000000000000000000001",
          "wgPublicKey":"dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=",
          "installPublicKey":"BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=",
          "inbound":[],"outbound":[{"protocol":"tcp","port":4100}]
        }],"futureField":"kept"
    });
    Mock::given(method("GET"))
        .and(path(format!("/v1/devices/{device}/overlay-policy")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(2)
        .mount(&server)
        .await;
    let output = cli(&server, &["--json", "device", "overlay-policy", device]).await;
    assert_eq!(output.code, exit::OK, "{}", output.stderr);
    assert_eq!(json_stdout(&output), receipt);
    let human = cli(&server, &["device", "overlay-policy", device]).await;
    assert_eq!(human.code, exit::OK, "{}", human.stderr);
    assert!(
        human.stdout.contains("outbound tcp:4100"),
        "{}",
        human.stdout
    );
    assert!(
        !human.stdout.contains("inbound tcp:4100"),
        "{}",
        human.stdout
    );
    let invalid = cli(&server, &["device", "overlay-policy", "vm_not_a_device"]).await;
    assert_eq!(invalid.code, exit::USAGE);
    assert_eq!(server.received_requests().await.unwrap().len(), 2);
}

#[tokio::test]
async fn pending_history_advances_bounded_index_work_without_polling_or_exposing_it_as_empty() {
    let server = MockServer::start().await;
    let cursor = format!("i1_{}", "a".repeat(32));
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .and(|request: &wiremock::Request| {
            request.url.query_pairs().all(|(key, _)| key != "cursor")
        })
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"items":[], "nextCursor":cursor, "pendingIndex":"building"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let receipt = json!({"items":[], "nextCursor":null, "pendingIndex":"ready"});
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .and(query_param("cursor", cursor.as_str()))
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "creation", "list", "--pending"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), receipt);
    assert_eq!(server.received_requests().await.unwrap().len(), 2);
}

#[tokio::test]
async fn pending_history_refuses_an_older_api_that_ignored_the_filter() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"items":[], "nextCursor":null})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["creation", "list", "--pending"]).await;
    assert_eq!(out.code, exit::UNEXPECTED);
    assert!(out.stderr.contains("pending history"));
    assert!(!out.stdout.contains("no creations"));
}

#[tokio::test]
async fn pending_history_respects_the_index_budget_and_rejects_a_stalled_cursor() {
    let server = MockServer::start().await;
    let cursor = format!("i1_{}", "c".repeat(32));
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"items":[], "nextCursor":cursor, "pendingIndex":"building"})),
        )
        .expect(2)
        .mount(&server)
        .await;
    let bounded = cli(
        &server,
        &["creation", "list", "--pending", "--index-pages", "1"],
    )
    .await;
    assert_eq!(bounded.code, exit::OK, "{}", bounded.stderr);
    assert!(
        bounded
            .stdout
            .contains(&format!("--pending --index-pages 1 --cursor {cursor}"))
    );
    assert!(!bounded.stdout.contains("no pending creations"));
    let stalled = cli(
        &server,
        &["creation", "list", "--pending", "--cursor", &cursor],
    )
    .await;
    assert_eq!(stalled.code, exit::UNEXPECTED);
    assert!(stalled.stderr.contains("made no progress"));
}

#[tokio::test]
async fn pending_history_preserves_the_page_anchor_when_backfill_interrupts_pagination() {
    let server = MockServer::start().await;
    let anchor = format!("001fffffffffffff-{}", "b".repeat(64));
    let page_cursor = format!("p1_{anchor}");
    let index_cursor = format!("i1_{}_{anchor}", "a".repeat(32));
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .and(query_param("cursor", page_cursor.as_str()))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"items":[], "nextCursor":index_cursor, "pendingIndex":"building"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    let receipt = json!({"items":[], "nextCursor":null, "pendingIndex":"ready"});
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .and(query_param("cursor", index_cursor.as_str()))
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "creation",
            "list",
            "--pending",
            "--cursor",
            &page_cursor,
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), receipt);
    assert_eq!(server.received_requests().await.unwrap().len(), 2);
}

#[tokio::test]
async fn pending_history_reports_incomplete_legacy_work_and_preserves_the_view_in_its_cursor_hint()
{
    let server = MockServer::start().await;
    let cursor = format!("p1_001fffffffffffff-{}", "b".repeat(64));
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("state", "pending"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(
                json!({"items":[], "nextCursor":cursor, "pendingIndex":"unavailable"}),
            ),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["creation", "list", "--pending"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("pending history is incomplete"));
    assert!(
        out.stdout
            .contains(&format!("creation list --pending --cursor {cursor}"))
    );
}

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
async fn list_created_by_me_sends_caller_selector() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/vms"))
        .and(authorized())
        .and(query_param("createdBy", "caller"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"items": [], "nextCursor": null})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "list", "--created-by-me"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), json!({"items": [], "nextCursor": null}));
}

#[tokio::test]
async fn snapshot_list_created_by_me_sends_caller_selector() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/snapshots"))
        .and(authorized())
        .and(query_param("createdBy", "caller"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"items": [], "nextCursor": null})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "snapshot", "list", "--created-by-me"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), json!({"items": [], "nextCursor": null}));
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

#[tokio::test]
async fn create_with_an_approved_image_revision() {
    let server = MockServer::start().await;
    let mut response = vm("starting");
    response["bootImage"] =
        json!({ "id": "cloud-standard", "revision": "r1", "displayName": "Cloud standard" });
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(body_json(
            json!({ "image": { "id": "cloud-standard", "revision": "r1" } }),
        ))
        .respond_with(ResponseTemplate::new(201).set_body_json(response))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "create",
            "--image",
            "cloud-standard",
            "--image-revision",
            "r1",
            "--json",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["bootImage"]["revision"], "r1");
}

#[tokio::test]
async fn list_approved_images_as_json() {
    let server = MockServer::start().await;
    let response = json!({ "items": [{ "id": "cloud-standard", "revision": "r1", "displayName": "Cloud standard" }] });
    Mock::given(method("GET"))
        .and(path("/v1/vm-images"))
        .respond_with(ResponseTemplate::new(200).set_body_json(&response))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["image", "list", "--json"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), response);
}

#[tokio::test]
async fn image_flags_are_paired_and_exclude_snapshot_without_http() {
    let server = MockServer::start().await;
    for args in [
        vec!["create", "--image", "cloud-standard"],
        vec!["create", "--image-revision", "r1"],
        vec![
            "create",
            "--image",
            "cloud-standard",
            "--image-revision",
            "r1",
            "--snapshot",
            "snap_fixture",
        ],
    ] {
        let out = cli(&server, &args).await;
        assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    }
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn image_create_requires_the_requested_receipt_without_deleting_or_retrying() {
    for receipt in [
        json!(null),
        json!({"id": "other", "revision": "r1"}),
        json!({"id": "cloud-standard", "revision": "r0"}),
    ] {
        let server = MockServer::start().await;
        let mut response = vm("starting");
        response["bootImage"] = receipt;
        Mock::given(method("POST"))
            .and(path("/v1/vms"))
            .respond_with(ResponseTemplate::new(201).set_body_json(response))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(
            &server,
            &[
                "--json",
                "create",
                "--image",
                "cloud-standard",
                "--image-revision",
                "r1",
                "--idempotency-key",
                "image-retry-key",
            ],
        )
        .await;
        assert_ne!(out.code, exit::OK);
        assert!(out.stdout.is_empty());
        assert!(out.stderr.contains(VM_ID), "{}", out.stderr);
        assert!(out.stderr.contains("image-retry-key"), "{}", out.stderr);
        assert!(out.stderr.contains("may have succeeded"), "{}", out.stderr);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn an_unvalidated_vm_id_is_not_reflected_in_a_missing_image_receipt_error() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .respond_with(
            ResponseTemplate::new(201).set_body_json(json!({"id": "private-provider-reference"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "create",
            "--image",
            "cloud-standard",
            "--image-revision",
            "r1",
        ],
    )
    .await;
    assert_ne!(out.code, exit::OK);
    assert!(out.stdout.is_empty());
    assert!(!out.stderr.contains("private-provider-reference"));
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn explicit_public_egress_is_sent_and_requires_confirmation() {
    for confirmed in [true, false] {
        let server = MockServer::start().await;
        let mut response = vm("starting");
        if confirmed {
            response["initialNetwork"] = json!({"publicEgress": true, "httpsProxyHosts": []});
        }
        Mock::given(method("POST"))
            .and(path("/v1/vms"))
            .and(body_json(json!({"initialNetwork": {"publicEgress": true}})))
            .respond_with(ResponseTemplate::new(201).set_body_json(response))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(&server, &["--json", "create", "--public-egress"]).await;
        assert_eq!(out.code == exit::OK, confirmed, "{}", out.stderr);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn image_list_human_output_includes_revision() {
    let server = MockServer::start().await;
    Mock::given(method("GET")).and(path("/v1/vm-images"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [{"id": "cloud-standard", "revision": "r1", "displayName": "Cloud standard"}]})))
        .expect(1).mount(&server).await;
    let out = cli(&server, &["image", "list"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("cloud-standard"));
    assert!(out.stdout.contains("r1"));
}

#[tokio::test]
async fn resize_sends_resource_floors_and_retry_key() {
    let server = MockServer::start().await;
    let mut response = vm("running");
    response["resources"]["diskMib"] = json!(65536);
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/resize")))
        .and(authorized())
        .and(header("idempotency-key", "resize-retry"))
        .and(body_json(json!({"resources": {"diskMib": 65536}})))
        .respond_with(ResponseTemplate::new(200).set_body_json(response))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "resize",
            VM_ID,
            "--disk-mib",
            "65536",
            "--idempotency-key",
            "resize-retry",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["id"], VM_ID);
    assert_eq!(json_stdout(&out)["resources"]["diskMib"], 65536);
}

#[tokio::test]
async fn resize_human_output_confirms_all_requested_axes() {
    let server = MockServer::start().await;
    let mut response = vm("running");
    response["resources"] = json!({"vcpus": 8, "memoryMib": 16384, "diskMib": 65536});
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/resize")))
        .and(body_json(
            json!({"resources": {"vcpus": 8, "memoryMib": 16384, "diskMib": 65536}}),
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(response))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "resize",
            VM_ID,
            "--vcpus",
            "8",
            "--memory-mib",
            "16384",
            "--disk-mib",
            "65536",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("16384 MiB"));
    assert!(out.stdout.contains("65536 MiB"));
}

#[tokio::test]
async fn resize_rejects_invalid_or_missing_resource_axes_without_http() {
    let server = MockServer::start().await;
    for args in [
        vec!["resize", VM_ID],
        vec!["resize", VM_ID, "--vcpus", "1"],
        vec!["resize", VM_ID, "--memory-mib", "65537"],
        vec!["resize", VM_ID, "--disk-mib", "16384.5"],
        vec!["resize", "private-provider-reference", "--vcpus", "8"],
    ] {
        let out = cli(&server, &args).await;
        assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
        if args[1] == "private-provider-reference" {
            assert!(out.stderr.contains("invalid VM id"), "{}", out.stderr);
            assert!(
                !out.stderr.contains("invalid --idempotency-key"),
                "{}",
                out.stderr
            );
        }
    }
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn resize_refuses_insufficient_or_wrong_vm_receipts_and_retains_the_key() {
    for wrong_id in [false, true] {
        let server = MockServer::start().await;
        let mut response = vm("running");
        if wrong_id {
            response["id"] = json!("vm_00000000000000000000000000");
            response["resources"]["diskMib"] = json!(65536);
        }
        Mock::given(method("POST"))
            .and(path(format!("/v1/vms/{VM_ID}/resize")))
            .respond_with(ResponseTemplate::new(200).set_body_json(response))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(
            &server,
            &[
                "--json",
                "resize",
                VM_ID,
                "--disk-mib",
                "65536",
                "--idempotency-key",
                "resize-receipt",
            ],
        )
        .await;
        assert_ne!(out.code, exit::OK);
        assert!(out.stdout.is_empty());
        assert!(out.stderr.contains("resize-receipt"), "{}", out.stderr);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn resize_provider_failure_reports_the_actual_generated_key_without_retrying() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/resize")))
        .and(wiremock::matchers::header_exists("idempotency-key"))
        .respond_with(ResponseTemplate::new(503).set_body_json(
            json!({"_tag": "ServiceUnavailable", "message": "VM service unavailable"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "resize", VM_ID, "--disk-mib", "65536"]).await;
    assert_eq!(out.code, exit::SERVICE_UNAVAILABLE, "{}", out.stderr);
    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    let key = requests[0]
        .headers
        .get("idempotency-key")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(out.stderr.contains(key), "{}", out.stderr);
    assert!(out.stdout.is_empty());
}

#[tokio::test]
async fn retire_confirms_the_exact_vm_for_json_and_human_callers() {
    let server = MockServer::start().await;
    let receipt = json!({"id": VM_ID, "state": "paused", "retired": true});
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/retire")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(2)
        .mount(&server)
        .await;
    let json_out = cli(&server, &["--json", "retire", VM_ID, "--yes"]).await;
    assert_eq!(json_out.code, exit::OK, "{}", json_out.stderr);
    assert_eq!(json_stdout(&json_out), receipt);
    let human = cli(&server, &["retire", VM_ID, "--yes"]).await;
    assert_eq!(human.code, exit::OK, "{}", human.stderr);
    assert!(human.stdout.contains("retired"));
    assert!(human.stdout.contains(VM_ID));
}

#[tokio::test]
async fn retire_needs_confirmation_and_a_valid_public_id_before_http() {
    let server = MockServer::start().await;
    for args in [
        vec!["retire", VM_ID],
        vec!["retire", "private-provider-reference", "--yes"],
    ] {
        let out = cli(&server, &args).await;
        assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
        assert!(out.stdout.is_empty());
    }
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn retire_refuses_ordinary_pause_wrong_id_and_incomplete_receipts() {
    for receipt in [
        vm("paused"),
        json!({"id": VM_ID, "state": "running", "retired": true}),
        json!({"id": "vm_00000000000000000000000000", "state": "paused", "retired": true}),
        json!({"id": VM_ID, "state": "paused", "retired": false}),
    ] {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(format!("/v1/vms/{VM_ID}/retire")))
            .respond_with(ResponseTemplate::new(200).set_body_json(receipt))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(&server, &["--json", "retire", VM_ID, "--yes"]).await;
        assert_ne!(out.code, exit::OK);
        assert!(out.stdout.is_empty());
        assert!(out.stderr.contains("unconfirmed"), "{}", out.stderr);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn retire_interactive_confirmation_requires_the_exact_vm_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/retire")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"id": VM_ID, "state": "stopped", "retired": true})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let uri = server.uri();
    let env = [("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())];
    let mut refused = Tty {
        answer: "wrong-vm",
        asked: 0,
    };
    let out = cli_with_prompt(&["retire", VM_ID], &env, &mut refused).await;
    assert_eq!(out.code, exit::CANCELLED, "{}", out.stderr);
    assert!(out.stderr.contains("nothing was retired"));
    assert!(server.received_requests().await.unwrap().is_empty());
    let mut accepted = Tty {
        answer: VM_ID,
        asked: 0,
    };
    let out = cli_with_prompt(&["--json", "retire", VM_ID], &env, &mut accepted).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(accepted.asked, 1);
    assert_eq!(json_stdout(&out)["retired"], true);
}

#[tokio::test]
async fn file_stat_preserves_public_metadata_and_uses_one_read_request() {
    let server = MockServer::start().await;
    let stat = json!({"kind": "file", "size": 12, "mode": 416, "mtime": null, "owner": "ubuntu", "group": "staff"});
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/stat")))
        .and(query_param("path", "/srv/team/a b"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&stat))
        .expect(2)
        .mount(&server)
        .await;
    let json_out = cli(&server, &["--json", "file", "stat", VM_ID, "/srv/team/a b"]).await;
    assert_eq!(json_out.code, exit::OK, "{}", json_out.stderr);
    assert_eq!(json_stdout(&json_out), stat);
    let human = cli(&server, &["file", "stat", VM_ID, "/srv/team/a b"]).await;
    assert_eq!(human.code, exit::OK, "{}", human.stderr);
    assert!(human.stdout.contains("0640"));
    assert!(human.stdout.contains("unknown"));
    assert!(human.stdout.contains("ubuntu"));
}

#[tokio::test]
async fn file_stat_rejects_invalid_paths_and_private_ids_without_http() {
    let server = MockServer::start().await;
    for (id, path) in [
        (VM_ID, "relative"),
        (VM_ID, "/srv/../etc"),
        ("private-provider-reference", "/safe"),
    ] {
        let out = cli(&server, &["--json", "file", "stat", id, path]).await;
        assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
        assert!(out.stdout.is_empty());
    }
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn file_stat_reports_missing_paths_without_retry_or_guest_execution() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/stat")))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({"_tag": "NotFound", "message": "File not found"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "file", "stat", VM_ID, "/missing"]).await;
    assert_eq!(out.code, exit::NOT_FOUND, "{}", out.stderr);
    assert!(out.stdout.is_empty());
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn file_stat_human_output_escapes_guest_control_characters() {
    let server = MockServer::start().await;
    Mock::given(method("GET")).and(path(format!("/v1/vms/{VM_ID}/files/stat")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"kind": "file", "size": 0, "mode": 384, "mtime": 0, "owner": "bad\u{1b}[2J\nname", "group": "users"})))
        .expect(1).mount(&server).await;
    let out = cli(&server, &["file", "stat", VM_ID, "/saved"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(!out.stdout.contains('\u{1b}'));
    assert!(out.stdout.contains("\\nname"));
}

#[tokio::test]
async fn file_stat_round_trips_numeric_and_unknown_modification_times() {
    for mtime in [
        json!(-1),
        json!(1790812800_i64),
        json!(253402300799_i64),
        json!(null),
    ] {
        let server = MockServer::start().await;
        let stat = json!({"kind": "file", "size": 12, "mode": 416, "mtime": mtime, "owner": "ubuntu", "group": "staff"});
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM_ID}/files/stat")))
            .respond_with(ResponseTemplate::new(200).set_body_json(&stat))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(&server, &["--json", "file", "stat", VM_ID, "/saved"]).await;
        assert_eq!(out.code, exit::OK, "{}", out.stderr);
        assert_eq!(json_stdout(&out), stat);
    }
}

#[tokio::test]
async fn identity_reads_the_exact_public_allocation_for_json_and_humans() {
    let server = MockServer::start().await;
    let receipt = json!({"id": VM_ID, "scheme": "sha256-v1", "fingerprint": "a".repeat(64)});
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/identity")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(2)
        .mount(&server)
        .await;
    let json_out = cli(&server, &["--json", "identity", VM_ID]).await;
    assert_eq!(json_out.code, exit::OK, "{}", json_out.stderr);
    assert_eq!(json_stdout(&json_out), receipt);
    let human = cli(&server, &["identity", VM_ID]).await;
    assert_eq!(human.code, exit::OK, "{}", human.stderr);
    assert!(human.stdout.contains("sha256-v1"));
    assert!(human.stdout.contains(&"a".repeat(64)));
}

#[tokio::test]
async fn identity_refuses_foreign_or_unrecognized_receipts_without_retry() {
    for receipt in [
        json!({"id": "vm_00000000000000000000000000", "scheme": "sha256-v1", "fingerprint": "a".repeat(64)}),
        json!({"id": VM_ID, "scheme": "other", "fingerprint": "a".repeat(64)}),
        json!({"id": VM_ID, "scheme": "sha256-v1", "fingerprint": "invalid"}),
    ] {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM_ID}/identity")))
            .respond_with(ResponseTemplate::new(200).set_body_json(receipt))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(&server, &["--json", "identity", VM_ID]).await;
        assert_ne!(out.code, exit::OK);
        assert!(out.stdout.is_empty());
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn identity_checks_presence_only_when_requested_and_requires_a_receipt() {
    for presence in [Some("present"), Some("missing"), None, Some("unknown")] {
        let server = MockServer::start().await;
        let mut receipt =
            json!({"id": VM_ID, "scheme": "sha256-v1", "fingerprint": "a".repeat(64)});
        if let Some(value) = presence {
            receipt["presence"] = json!(value);
        }
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM_ID}/identity")))
            .and(wiremock::matchers::query_param("checkPresence", "true"))
            .and(authorized())
            .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(&server, &["--json", "identity", VM_ID, "--check-presence"]).await;
        if matches!(presence, Some("present" | "missing")) {
            assert_eq!(out.code, exit::OK, "{}", out.stderr);
            assert_eq!(json_stdout(&out), receipt);
        } else {
            assert_ne!(out.code, exit::OK);
            assert!(out.stdout.is_empty());
        }
    }
}

#[tokio::test]
async fn creation_status_and_reconcile_send_only_the_original_key() {
    for (verb, http_method, route) in [
        ("get", "GET", "/v1/vm-creations/by-key"),
        ("reconcile", "POST", "/v1/vm-creations/by-key/reconcile"),
    ] {
        let server = MockServer::start().await;
        let receipt = json!({"state":"pending", "id":VM_ID});
        Mock::given(method(http_method))
            .and(path(route))
            .and(authorized())
            .and(header("idempotency-key", "original-create"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
            .expect(1)
            .mount(&server)
            .await;
        let out = cli(
            &server,
            &[
                "--json",
                "creation",
                verb,
                "--idempotency-key",
                "original-create",
            ],
        )
        .await;
        assert_eq!(out.code, exit::OK, "{}", out.stderr);
        assert_eq!(json_stdout(&out), receipt);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn creation_list_sends_bounded_cursor_and_preserves_public_recovery_handles() {
    let server = MockServer::start().await;
    let cursor = "a".repeat(64);
    let receipt = json!({
        "items":[{"creationKey":"vcr_00000000000000000000000001", "createdAt":"2026-10-18T00:00:00Z",
          "operation":"create", "displayName":"agent", "state":"pending", "id":VM_ID}],
        "nextCursor":null
    });
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .and(query_param("cursor", cursor.as_str()))
        .and(query_param("limit", "7"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json", "creation", "list", "--limit", "7", "--cursor", &cursor,
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), receipt);
    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].headers.get("idempotency-key").is_none());
}

#[tokio::test]
async fn creation_list_keeps_empty_filtered_pages_and_rejects_invalid_arguments() {
    let server = MockServer::start().await;
    let cursor = "b".repeat(64);
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"items":[], "nextCursor":cursor})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["creation", "list"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("no creations on this page"));
    assert!(
        out.stdout
            .contains(&format!("creation list --cursor {cursor}"))
    );
    for args in [
        vec!["creation", "list", "--limit", "0"],
        vec!["creation", "list", "--cursor", "invalid"],
    ] {
        let invalid = cli(&server, &args).await;
        assert_eq!(invalid.code, exit::USAGE, "{}", invalid.stderr);
    }
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn creation_list_rejects_a_malformed_public_handle_even_in_json_mode() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/vm-creations"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items":[{
            "creationKey":"not-a-server-handle", "createdAt":"2026-10-18T00:00:00Z",
            "operation":"create", "displayName":null, "state":"pending", "id":VM_ID
        }], "nextCursor":null})))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "creation", "list"]).await;
    assert_eq!(out.code, exit::UNEXPECTED, "{}", out.stderr);
}

#[tokio::test]
async fn creation_reconcile_retains_pending_and_reports_missing_without_retry() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vm-creations/by-key/reconcile"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({"_tag":"NotFound", "message":"VM creation not found"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "creation",
            "reconcile",
            "--idempotency-key",
            "unknown",
        ],
    )
    .await;
    assert_eq!(out.code, exit::NOT_FOUND, "{}", out.stderr);
    let invalid = cli(&server, &["creation", "get", "--idempotency-key", ""]).await;
    assert_eq!(invalid.code, exit::USAGE, "{}", invalid.stderr);
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn creation_cancel_requires_confirmation_and_preserves_cancelling_receipts() {
    let server = MockServer::start().await;
    let receipt = json!({"state":"cancelling", "id":VM_ID});
    Mock::given(method("POST"))
        .and(path("/v1/vm-creations/by-key/cancel"))
        .and(header("idempotency-key", "original-create"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&receipt))
        .expect(2)
        .mount(&server)
        .await;
    let refused = cli(
        &server,
        &[
            "--json",
            "creation",
            "cancel",
            "--idempotency-key",
            "original-create",
        ],
    )
    .await;
    assert_eq!(refused.code, exit::USAGE);
    assert!(server.received_requests().await.unwrap().is_empty());
    let mut tty = Tty {
        answer: "no",
        asked: 0,
    };
    let uri = server.uri();
    let env = [("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())];
    let args = [
        "--json",
        "creation",
        "cancel",
        "--idempotency-key",
        "original-create",
    ];
    let declined = cli_with_prompt(&args, &env, &mut tty).await;
    assert_eq!(declined.code, exit::CANCELLED);
    tty.answer = "cancel";
    let accepted = cli_with_prompt(&args, &env, &mut tty).await;
    assert_eq!(accepted.code, exit::OK, "{}", accepted.stderr);
    assert_eq!(json_stdout(&accepted), receipt);
    let scripted = cli(
        &server,
        &[
            "--json",
            "creation",
            "cancel",
            "--idempotency-key",
            "original-create",
            "--yes",
        ],
    )
    .await;
    assert_eq!(scripted.code, exit::OK, "{}", scripted.stderr);
    assert_eq!(json_stdout(&scripted), receipt);
}

#[tokio::test]
async fn exec_posts_the_command_and_prints_the_guest_output() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/exec")))
        .and(authorized())
        .and(body_json(
            json!({ "command": "acpmux run -m claude hi", "timeoutMs": 5000 }),
        ))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "exitCode": 0, "stdout": "tenant ok\n", "stderr": "" })),
        )
        .expect(2)
        .mount(&server)
        .await;

    let out = cli(
        &server,
        &[
            "exec",
            VM_ID,
            "--timeout-ms",
            "5000",
            "--",
            "acpmux",
            "run",
            "-m",
            "claude",
            "hi",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(out.stdout, "tenant ok\n");

    let out = cli(
        &server,
        &[
            "--json",
            "exec",
            VM_ID,
            "--timeout-ms",
            "5000",
            "--",
            "acpmux run -m claude hi",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "stderr: {}", out.stderr);
    assert_eq!(json_stdout(&out)["stdout"], "tenant ok\n");
}

#[tokio::test]
async fn exec_fails_when_the_command_fails() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/exec")))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({ "exitCode": 127, "stdout": "", "stderr": "acpmux: not found\n" }),
        ))
        .mount(&server)
        .await;
    let out = cli(&server, &["exec", VM_ID, "--", "acpmux", "--version"]).await;
    assert_eq!(out.code, exit::UNEXPECTED);
    assert!(out.stderr.contains("acpmux: not found"), "{}", out.stderr);
}

#[cfg(unix)]
#[tokio::test]
async fn client_sessions_keep_tokens_private_and_confirm_revoke() {
    let server = MockServer::start().await;
    let session = "vcs_00000000000000000000000000";
    let response = json!({"id":session,"vmId":VM_ID,"providerVmId":"provider-vm",
        "linuxUser":"dev","token":"one-time-secret","createdAt":"now", "ssh":{"host":"ssh.example.test","user":"provider-vm+dev"}});
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .and(authorized())
        .and(body_json(json!({"linuxUser":"dev"})))
        .respond_with(ResponseTemplate::new(201).set_body_json(&response))
        .expect(2)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &["client-session", "create", VM_ID, "--user", "dev"],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("ssh provider-vm+dev@ssh.example.test"));
    assert!(out.stdout.contains("one-time-secret"));
    assert!(out.stdout.contains("shown once"));
    assert!(!out.stderr.contains("one-time-secret"));
    let dir = std::env::temp_dir().join(format!("cmux-client-session-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir(&dir).unwrap();
    let file = dir.join("token");
    let args = [
        "--json",
        "client-session",
        "create",
        VM_ID,
        "--user",
        "dev",
        "--token-file",
        file.to_str().unwrap(),
    ];
    let out = cli(&server, &args).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "one-time-secret");
    assert!(json_stdout(&out).get("token").is_none());
    assert!(!out.stdout.contains("one-time-secret"));
    assert!(!out.stderr.contains("one-time-secret"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(json_stdout(&out)["ssh"]["host"], "ssh.example.test");
    let refused = cli(&server, &args).await;
    assert_eq!(refused.code, exit::USAGE, "{}", refused.stderr);
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "one-time-secret");
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions")))
        .and(authorized())
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"sessions":[response],"token":"unexpected-secret"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "client-session", "list", VM_ID]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["sessions"][0]["id"], session);
    assert!(!out.stdout.contains("secret"));
    let refused = cli(&server, &["client-session", "revoke", VM_ID, session]).await;
    assert_eq!(refused.code, exit::USAGE);
    assert!(refused.stderr.contains(session));
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions/{session}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &["client-session", "revoke", VM_ID, session, "--yes"],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains(session) && out.stdout.contains(VM_ID));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn client_session_create_json_carries_the_token_and_ssh_line() {
    let server = MockServer::start().await;
    let session = "vcs_00000000000000000000000001";
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .and(body_json(json!({})))
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({
            "id": session, "vmId": VM_ID, "providerVmId": "provider-vm",
            "linuxUser": "ubuntu", "token": "one-time-secret",
            "apiBaseUrl": "https://api.example.test", "createdAt": "now",
            "ssh": {"host": "ssh.example.test", "user": "provider-vm+ubuntu"},
            "future": "dropped"
        })))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "client-session", "create", VM_ID]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let body = json_stdout(&out);
    assert_eq!(body["token"], "one-time-secret");
    assert_eq!(body["sshLine"], "provider-vm+ubuntu@ssh.example.test");
    assert_eq!(body["apiBaseUrl"], "https://api.example.test");
    assert!(body.get("future").is_none());
}

#[tokio::test]
async fn client_session_create_hints_a_revoke_only_when_a_session_may_exist() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({"_tag": "NotFound", "message": "VM not found"})),
        )
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .respond_with(
            ResponseTemplate::new(503)
                .set_body_json(json!({"_tag": "ServiceUnavailable", "message": "try again"})),
        )
        .mount(&server)
        .await;
    let missing = cli(&server, &["client-session", "create", VM_ID]).await;
    assert_eq!(missing.code, exit::NOT_FOUND, "{}", missing.stderr);
    assert!(!missing.stderr.contains("revoke"), "{}", missing.stderr);
    let unavailable = cli(&server, &["client-session", "create", VM_ID]).await;
    assert_eq!(
        unavailable.code,
        exit::SERVICE_UNAVAILABLE,
        "{}",
        unavailable.stderr
    );
    assert!(
        unavailable.stderr.contains("revoke"),
        "{}",
        unavailable.stderr
    );
}

#[tokio::test]
async fn client_session_revoke_at_a_terminal_needs_the_typed_session_id() {
    let server = MockServer::start().await;
    let session = "vcs_00000000000000000000000002";
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions/{session}")))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let uri = server.uri();
    let env = [("CMUX_VM_API_KEY", KEY), ("CMUX_VM_BASE_URL", uri.as_str())];
    let args = ["client-session", "revoke", VM_ID, session];
    let mut wrong = Tty {
        answer: "yes",
        asked: 0,
    };
    let refused = cli_with_prompt(&args, &env, &mut wrong).await;
    assert_eq!(refused.code, exit::CANCELLED, "{}", refused.stderr);
    assert_eq!(wrong.asked, 1);
    let mut typed = Tty {
        answer: session,
        asked: 0,
    };
    let revoked = cli_with_prompt(&args, &env, &mut typed).await;
    assert_eq!(revoked.code, exit::OK, "{}", revoked.stderr);
    assert_eq!(typed.asked, 1);
}

#[tokio::test]
async fn run_exits_with_the_command_status_when_cleanup_fails() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "id": VM_ID })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({ "id": VM_ID, "state": "running" })),
        )
        .mount(&server)
        .await;
    // Every exec answers "3" with no output: the work directory, the launch,
    // then a poll that reads exit status 3 and nothing more.
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/exec")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "exitCode": 0, "stdout": "3\n\n\n", "stderr": "" })),
        )
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(500))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["run", "--", "exit", "3"]).await;
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        out.stderr
            .contains(&format!("vm {VM_ID} was not cleaned up")),
        "{}",
        out.stderr
    );
    assert!(out.stderr.contains("delete"), "{}", out.stderr);
}

#[tokio::test]
async fn run_fails_fast_and_deletes_a_vm_whose_answer_has_no_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "id": VM_ID })))
        .expect(1)
        .mount(&server)
        .await;
    // A successful answer without a state: never treated as "starting",
    // which would keep a billable VM polling for the whole boot deadline.
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        cli(&server, &["run", "--", "true"]),
    )
    .await
    .expect("run kept polling a VM whose answer has no state");
    assert_ne!(out.code, 0, "{}", out.stderr);
    assert!(out.stderr.contains("state"), "{}", out.stderr);
}

/// A stored token whose JSON cannot be read names a recovery that works:
/// `token revoke` removes the local copy it cannot revoke (#29706).
// The file store; macOS keeps the token in the login Keychain.
#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn revoke_removes_an_unreadable_stored_token() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("cmux-vm-unreadable-token-{}", std::process::id()));
    let file = dir.join("cmux").join("vm-token.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let store = |text: &str| {
        std::fs::write(&file, text).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    };
    store("{not json");
    let xdg = dir.to_string_lossy().into_owned();
    let env = [("XDG_CONFIG_HOME", xdg.as_str())];

    let status = cli_with_env(&["token", "status"], &env).await;
    assert_ne!(status.code, exit::OK);
    assert!(status.stderr.contains("token revoke"), "{}", status.stderr);
    assert!(status.stderr.contains("expires"), "{}", status.stderr);
    // Every other verb refuses it with the same advice.
    let get = cli_with_env(&["get", VM_ID], &env).await;
    assert_eq!(get.code, exit::UNAUTHENTICATED, "{}", get.stderr);
    assert!(get.stderr.contains("token revoke"), "{}", get.stderr);

    // Nothing is sent anywhere (no server): the key cannot be read to revoke.
    let revoke = cli_with_env(&["token", "revoke"], &env).await;
    assert_eq!(revoke.code, exit::OK, "{}", revoke.stderr);
    assert!(revoke.stdout.contains("removed"), "{}", revoke.stdout);
    assert!(revoke.stdout.contains("expires"), "{}", revoke.stdout);
    assert!(!file.exists());
    let status = cli_with_env(&["token", "status"], &env).await;
    assert_eq!(status.code, exit::UNAUTHENTICATED, "{}", status.stderr);
    assert!(
        status.stderr.contains("no stored VM token"),
        "{}",
        status.stderr
    );

    store("[]");
    let revoke = cli_with_env(&["--json", "token", "revoke"], &env).await;
    assert_eq!(revoke.code, exit::OK, "{}", revoke.stderr);
    assert_eq!(
        json_stdout(&revoke),
        json!({"id": null, "revoked": false, "removed": true})
    );
    assert!(!file.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The guest command that removes the run's archives on every exit path.
const REMOVE_ARCHIVES: &str = "rm -f /tmp/cmux-run.tgz /tmp/cmux-pull.tgz /tmp/cmux-pull.tgz.rc";

/// A server for a kept run: the VM is created, runs, and is paused once.
/// Every exec not matched by a test's own mocks answers exit status 0 with
/// no output: a work directory of "0", then a poll that reads status 0.
async fn kept_run_server() -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "id": VM_ID })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({ "id": VM_ID, "state": "running" })),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/pause")))
        .respond_with(ResponseTemplate::new(200).set_body_json(vm("paused")))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/exec")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "exitCode": 0, "stdout": "0\n\n\n", "stderr": "" })),
        )
        .with_priority(10)
        .mount(&server)
        .await;
    server
}

/// Answers the guest commands that contain `needle` with `exit_code`.
async fn exec_answers(server: &MockServer, needle: &str, exit_code: i32, times: u64) {
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/exec")))
        .and(body_string_contains(needle))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "exitCode": exit_code,
            "stdout": "",
            "stderr": if exit_code == 0 { "" } else { "refused by the test" },
        })))
        .with_priority(1)
        .expect(times)
        .mount(server)
        .await;
}

fn sync_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-vm-run-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("main.rs"), "fn main() {}").unwrap();
    dir
}

#[tokio::test]
async fn a_kept_run_removes_a_partly_uploaded_sync_archive() {
    let server = kept_run_server().await;
    exec_answers(&server, "cat > /tmp/cmux-run.tgz", 1, 1).await;
    exec_answers(&server, REMOVE_ARCHIVES, 0, 1).await;
    let dir = sync_dir("upload-fails");
    let out = cli(
        &server,
        &[
            "run",
            "--sync",
            "--keep",
            "--dir",
            dir.to_str().unwrap(),
            "--",
            "true",
        ],
    )
    .await;
    assert_ne!(out.code, 0, "{}", out.stderr);
    assert!(
        out.stderr.contains(&format!("vm {VM_ID} paused")),
        "{}",
        out.stderr
    );
    server.verify().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_kept_run_removes_a_sync_archive_that_failed_to_unpack() {
    let server = kept_run_server().await;
    exec_answers(&server, "cat > /tmp/cmux-run.tgz", 0, 1).await;
    exec_answers(&server, "tar -xzf /tmp/cmux-run.tgz", 2, 1).await;
    exec_answers(&server, REMOVE_ARCHIVES, 0, 1).await;
    let dir = sync_dir("unpack-fails");
    let out = cli(
        &server,
        &[
            "run",
            "--sync",
            "--keep",
            "--dir",
            dir.to_str().unwrap(),
            "--",
            "true",
        ],
    )
    .await;
    assert_ne!(out.code, 0, "{}", out.stderr);
    assert!(!out.stderr.contains("could not remove"), "{}", out.stderr);
    server.verify().await;
    // The unpack itself removes the archive once tar ends, failure included.
    let requests = server.received_requests().await.unwrap();
    let unpack = requests
        .iter()
        .map(|request| String::from_utf8_lossy(&request.body).into_owned())
        .find(|body| body.contains("tar -xzf /tmp/cmux-run.tgz"))
        .unwrap();
    assert!(
        unpack.contains("r=$?; rm -f /tmp/cmux-run.tgz; [ $r -eq 0 ]"),
        "{unpack}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_kept_run_reports_pull_archives_it_could_not_remove() {
    let server = kept_run_server().await;
    exec_answers(&server, "tar -czf", 1, 1).await;
    exec_answers(&server, REMOVE_ARCHIVES, 1, 1).await;
    let dir = sync_dir("pull-cleanup-fails");
    let out = cli(
        &server,
        &[
            "run",
            "--pull",
            "dist",
            "--keep",
            "--dir",
            dir.to_str().unwrap(),
            "--",
            "true",
        ],
    )
    .await;
    assert_ne!(out.code, 0, "{}", out.stderr);
    assert!(
        out.stderr
            .contains("could not remove the run's archives from the kept VM"),
        "{}",
        out.stderr
    );
    assert!(out.stderr.contains(REMOVE_ARCHIVES), "{}", out.stderr);
    assert!(
        out.stderr.contains(&format!("vm {VM_ID} paused")),
        "{}",
        out.stderr
    );
    server.verify().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A server that counts the creates a `run` makes and refuses each, so a run
/// that gets past its argument checks stops at the create.
async fn refusing_creates(creates: u64) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .respond_with(ResponseTemplate::new(403).set_body_json(json!({
            "error": { "code": "forbidden", "message": "refused by the test" }
        })))
        .expect(creates)
        .mount(&server)
        .await;
    server
}

#[tokio::test]
async fn run_refuses_a_command_over_the_env_value_limit_before_creating_a_vm() {
    // The API limits an env value to 32 KiB counted as JavaScript string
    // length (UTF-16 code units); the whole command goes in one.
    let under = refusing_creates(2).await;
    let out = cli(&under, &["run", "--", &"x".repeat(32 * 1024)]).await;
    assert_ne!(out.code, exit::USAGE, "{}", out.stderr);
    // Two UTF-16 units each: 16 Ki of them is exactly the limit.
    let out = cli(&under, &["run", "--", &"\u{1F600}".repeat(16 * 1024)]).await;
    assert_ne!(out.code, exit::USAGE, "{}", out.stderr);
    under.verify().await;

    let over = refusing_creates(0).await;
    let out = cli(&over, &["run", "--", &"x".repeat(32 * 1024 + 1)]).await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    assert!(out.stderr.contains("32 KiB"), "{}", out.stderr);
    let out = cli(&over, &["run", "--", &"\u{1F600}".repeat(16 * 1024 + 1)]).await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    // Several words are quoted one by one; the quoted line is what counts.
    let half = "it's".repeat(4 * 1024);
    let out = cli(&over, &["run", "--", "echo", &half, &half]).await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    over.verify().await;
}

#[tokio::test]
async fn run_refuses_a_pull_list_over_the_exec_command_limit_before_creating_a_vm() {
    // Every --pull path is named twice in one guest exec command, which the
    // API limits to 64 KiB.
    let paths: Vec<String> = (0..1000).map(|i| format!("out/{i:036}")).collect();
    let mut args = vec!["run".to_owned()];
    for path in &paths {
        args.extend(["--pull".to_owned(), path.clone()]);
    }
    args.extend(["--".to_owned(), "true".to_owned()]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let over = refusing_creates(0).await;
    let out = cli(&over, &args).await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    assert!(out.stderr.contains("--pull"), "{}", out.stderr);
    over.verify().await;

    let under = refusing_creates(1).await;
    let out = cli(&under, &["run", "--pull", &paths[0], "--", "true"]).await;
    assert_ne!(out.code, exit::USAGE, "{}", out.stderr);
    under.verify().await;
}
