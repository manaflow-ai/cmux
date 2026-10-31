//! The verbs over the second round of tenant routes (update, snapshot update,
//! file mkdir/rm/exists, resumable uploads, session and identity, vpc update
//! and ips, tunnel list and update, firewall rules and evaluate, domain, tls)
//! against a local mock of the cmux VM API: the request each sends, its output
//! and its exit code.

use cmux_vm::exit;
use serde_json::{Value, json};
use wiremock::matchers::{body_json, body_partial_json, header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";
const MESH: &str = "mesh_0123456789abcdefghjkmnpqrs";
const DEVICE: &str = "dev_0123456789abcdefghjkmnpqrs";
const TUNNEL: &str = "tun_0123456789abcdefghjkmnpqrs";
const SESSION: &str = "vcs_0123456789abcdefghjkmnpqrs";
const KEY: &str = "cmuxvm_sk_test";
const SNAP: &str = "snap_0123456789abcdefghjkmnpqrs";
const TOKEN_ID: &str = "vct_0123456789abcdefghjkmnpqrs";
const DOMAIN: &str = "dom_0123456789abcdefghjkmnpqrs";
const VERIFICATION: &str = "dvr_0123456789abcdefghjkmnpqrs";
const RULE: &str = "tlsr_0123456789abcdefghjkmnpqrs";
const FWA: &str = "fwa_0123456789abcdefghjkmnpqrs";
const FWR: &str = "fwr_0123456789abcdef0123456789abcdef";

struct Output {
    code: i32,
    stdout: String,
    stderr: String,
}

/// A terminal that answers every question with `answer`.
struct Tty {
    answer: &'static str,
}

impl cmux_vm::Prompt for Tty {
    fn is_interactive(&self) -> bool {
        true
    }

    fn ask(&mut self, _question: &str) -> std::io::Result<String> {
        Ok(format!("{}\n", self.answer))
    }
}

async fn run(server: &MockServer, args: &[&str], prompt: &mut dyn cmux_vm::Prompt) -> Output {
    let uri = server.uri();
    let env = [
        ("CMUX_VM_API_KEY", KEY.to_owned()),
        ("CMUX_VM_BASE_URL", uri),
    ];
    let lookup = move |name: &str| env.iter().find(|(k, _)| *k == name).map(|(_, v)| v.clone());
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let argv = std::iter::once("cmux-vm").chain(args.iter().copied());
    let code = cmux_vm::run(argv, &lookup, prompt, &mut stdout, &mut stderr).await;
    Output {
        code,
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    }
}

async fn cli(server: &MockServer, args: &[&str]) -> Output {
    run(server, args, &mut cmux_vm::NoPrompt).await
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

fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-vm-parity-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn vm_body(name: Option<&str>, labels: Value) -> Value {
    json!({
        "id": VM_ID, "displayName": name, "labels": labels, "state": "running",
        "resources": {"vcpus": 2, "memoryMib": 4096, "diskMib": 16384},
        "idleTimeoutSeconds": 300, "maxRunSeconds": null, "autoDeleteSeconds": null,
        "createdAt": "2026-10-25T00:00:00Z", "updatedAt": "2026-10-25T00:00:01Z"
    })
}

fn snapshot_body(name: Option<&str>, ttl: Value) -> Value {
    json!({
        "id": SNAP, "sourceVmId": VM_ID, "displayName": name, "labels": {"k": "v"},
        "createdAt": "2026-10-25T00:00:00Z", "lastUsedAt": null, "ttlSeconds": ttl,
        "autoDeleteSeconds": null
    })
}

#[tokio::test]
async fn update_sends_name_labels_and_limits_and_clears_with_null() {
    let server = MockServer::start().await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(body_json(
            json!({"displayName": "box", "labels": {"team": "a", "env": "dev"},
            "idleTimeoutSeconds": -1, "maxRunSeconds": 3600}),
        ))
        .and(authorized())
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(vm_body(Some("box"), json!({"team": "a", "env": "dev"}))),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/vms/{VM_ID}")))
        .and(body_json(json!({"displayName": null, "labels": {}})))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(vm_body(None, json!({}))))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "update",
            VM_ID,
            "--name",
            "box",
            "--label",
            "team=a",
            "--label",
            "env=dev",
            "--idle",
            "-1",
            "--max-run",
            "3600",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("box"), "{}", out.stdout);
    assert!(out.stdout.contains("team=a"), "{}", out.stdout);
    let out = cli(
        &server,
        &["--json", "update", VM_ID, "--clear-name", "--clear-labels"],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["labels"], json!({}));
    let out = cli(&server, &["update", VM_ID]).await;
    assert_eq!(out.code, exit::USAGE, "an update needs a change");
    let out = cli(&server, &["update", VM_ID, "--name", "a", "--clear-name"]).await;
    assert_eq!(out.code, exit::USAGE);
}

#[tokio::test]
async fn snapshot_update_and_rename_set_retention_or_clear_it() {
    let server = MockServer::start().await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/snapshots/{SNAP}")))
        .and(body_json(
            json!({"displayName": "base", "ttlSeconds": 86400}),
        ))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(snapshot_body(Some("base"), json!(86400))),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/snapshots/{SNAP}")))
        .and(body_json(
            json!({"ttlSeconds": null, "autoDeleteSeconds": null}),
        ))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(snapshot_body(Some("base"), Value::Null)),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "snapshot", "rename", SNAP, "--name", "base", "--ttl", "86400",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("base"), "{}", out.stdout);
    let out = cli(
        &server,
        &[
            "--json",
            "snapshot",
            "update",
            SNAP,
            "--no-ttl",
            "--no-auto-delete",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["ttlSeconds"], Value::Null);
    let out = cli(
        &server,
        &["snapshot", "update", SNAP, "--ttl", "60", "--no-ttl"],
    )
    .await;
    assert_eq!(out.code, exit::USAGE);
}

#[tokio::test]
async fn file_mkdir_rm_and_exists_use_their_routes() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/files/directories")))
        .and(body_json(json!({"path": "/srv/app"})))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/files")))
        .and(query_param("path", "/srv/app"))
        .respond_with(ResponseTemplate::new(204))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/exists")))
        .and(query_param("path", "/srv/app"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"exists": true})))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/exists")))
        .and(query_param("path", "/nope"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"exists": false})))
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "file", "mkdir", VM_ID, "/srv/app"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["created"], true);
    let out = cli(&server, &["fs", "rm", VM_ID, "/srv/app"]).await;
    assert_eq!(out.code, exit::USAGE, "rm needs --yes without a terminal");
    let out = run(
        &server,
        &["fs", "rm", VM_ID, "/srv/app"],
        &mut Tty { answer: "/srv" },
    )
    .await;
    assert_eq!(out.code, exit::CANCELLED);
    let out = run(
        &server,
        &["fs", "rm", VM_ID, "/srv/app"],
        &mut Tty { answer: "/srv/app" },
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(
        &server,
        &["--json", "file", "rm", VM_ID, "/srv/app", "--yes"],
    )
    .await;
    assert_eq!(json_stdout(&out)["removed"], true);
    let out = cli(&server, &["file", "exists", VM_ID, "/srv/app"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["--json", "file", "exists", VM_ID, "/nope"]).await;
    assert_eq!(out.code, exit::NO);
    assert_eq!(json_stdout(&out), json!({"exists": false}));
    assert!(
        out.stderr.is_empty(),
        "a plain no prints nothing: {}",
        out.stderr
    );
}

/// Matches a JSON request body without a `headers` field.
fn without_headers(request: &wiremock::Request) -> bool {
    serde_json::from_slice::<Value>(&request.body).is_ok_and(|body| body.get("headers").is_none())
}

fn upload_state(received: u64) -> Value {
    json!({"uploadId": "upl_1", "path": "/root/big.bin", "size": 10, "receivedBytes": received, "maxChunkBytes": 4})
}

#[tokio::test]
async fn a_resumable_push_sends_chunks_resumes_after_a_failure_and_commits() {
    let server = MockServer::start().await;
    let dir = temp_dir("routes-resumable");
    let local = dir.join("big.bin");
    std::fs::write(&local, b"0123456789").unwrap();
    let uploads = format!("/v1/vms/{VM_ID}/files/uploads");
    Mock::given(method("POST"))
        .and(path(uploads.clone()))
        .and(body_json(json!({"path": "/root/big.bin", "size": 10,
            "sha256": "84d89877f0d4041efb6bf91a16f0248f2fd573e6af05c19f96bedb9f882f7882"})))
        .respond_with(ResponseTemplate::new(201).set_body_json(upload_state(0)))
        .expect(1)
        .mount(&server)
        .await;
    let chunk = format!("{uploads}/upl_1");
    Mock::given(method("PUT"))
        .and(path(chunk.clone()))
        .and(query_param("offset", "0"))
        .and(header("content-length", "4"))
        .respond_with(ResponseTemplate::new(200).set_body_json(upload_state(4)))
        .expect(1)
        .mount(&server)
        .await;
    // The first try at offset 4 fails; the CLI reads the progress and resends.
    Mock::given(method("PUT"))
        .and(path(chunk.clone()))
        .and(query_param("offset", "4"))
        .respond_with(
            ResponseTemplate::new(503)
                .set_body_json(json!({"_tag": "Unavailable", "message": "busy"})),
        )
        .up_to_n_times(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(chunk.clone()))
        .and(query_param("offset", "4"))
        .respond_with(ResponseTemplate::new(200).set_body_json(upload_state(8)))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(chunk.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_json(upload_state(4)))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(chunk.clone()))
        .and(query_param("offset", "8"))
        .and(header("content-length", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(upload_state(10)))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("{chunk}/commit")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(chunk.clone()))
        .respond_with(ResponseTemplate::new(204))
        .expect(0)
        .mount(&server)
        .await;
    let remote = format!("{VM_ID}:/root/big.bin");
    let out = cli(
        &server,
        &[
            "--json",
            "push",
            local.to_str().unwrap(),
            &remote,
            "--resumable",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["bytes"], 10);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn a_rejected_chunk_abandons_the_upload() {
    let server = MockServer::start().await;
    let dir = temp_dir("routes-abort");
    let local = dir.join("big.bin");
    std::fs::write(&local, b"0123456789").unwrap();
    let uploads = format!("/v1/vms/{VM_ID}/files/uploads");
    Mock::given(method("POST"))
        .and(path(uploads.clone()))
        .and(body_partial_json(
            json!({"path": "/root/big.bin", "mode": 420}),
        ))
        .respond_with(ResponseTemplate::new(201).set_body_json(upload_state(0)))
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("{uploads}/upl_1")))
        .respond_with(
            ResponseTemplate::new(400)
                .set_body_json(json!({"_tag": "BadRequest", "message": "overrun"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("{uploads}/upl_1")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "file",
            "write",
            VM_ID,
            "/root/big.bin",
            local.to_str().unwrap(),
            "--resumable",
            "--mode",
            "644",
        ],
    )
    .await;
    assert_eq!(out.code, exit::BAD_REQUEST, "{}", out.stderr);
    let out = cli(
        &server,
        &["file", "write", VM_ID, "/root/x", "-", "--resumable"],
    )
    .await;
    assert_eq!(out.code, exit::USAGE, "stdin cannot resume");
    std::fs::remove_dir_all(dir).unwrap();
}

/// One-chunk upload state (the whole 10-byte file fits in a chunk).
fn whole_upload_state(received: u64) -> Value {
    json!({"uploadId": "upl_1", "path": "/root/big.bin", "size": 10, "receivedBytes": received, "maxChunkBytes": 16})
}

/// Mounts begin and the one chunk of a 10-byte resumable upload, and returns
/// the local file and the upload's path.
async fn mount_sent_upload(server: &MockServer, name: &str) -> (std::path::PathBuf, String) {
    let dir = temp_dir(name);
    let local = dir.join("big.bin");
    std::fs::write(&local, b"0123456789").unwrap();
    let uploads = format!("/v1/vms/{VM_ID}/files/uploads");
    Mock::given(method("POST"))
        .and(path(uploads.clone()))
        .respond_with(ResponseTemplate::new(201).set_body_json(whole_upload_state(0)))
        .expect(1)
        .mount(server)
        .await;
    let chunk = format!("{uploads}/upl_1");
    Mock::given(method("PUT"))
        .and(path(chunk.clone()))
        .and(query_param("offset", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_json(whole_upload_state(10)))
        .expect(1)
        .mount(server)
        .await;
    (local, chunk)
}

async fn write_resumable(server: &MockServer, local: &std::path::Path) -> Output {
    cli(
        server,
        &[
            "--json",
            "file",
            "write",
            VM_ID,
            "/root/big.bin",
            local.to_str().unwrap(),
            "--resumable",
        ],
    )
    .await
}

#[tokio::test]
async fn a_commit_already_running_after_a_lost_answer_is_polled_until_it_settles() {
    let server = MockServer::start().await;
    let (local, upload) = mount_sent_upload(&server, "routes-commit-409").await;
    // The first commit's answer was lost upstream; the retry finds it running.
    Mock::given(method("POST"))
        .and(path(format!("{upload}/commit")))
        .respond_with(
            ResponseTemplate::new(409).set_body_json(
                json!({"_tag": "Conflict", "message": "A commit is already running"}),
            ),
        )
        .up_to_n_times(1)
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(upload.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_json(whole_upload_state(10)))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("{upload}/commit")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(upload.clone()))
        .respond_with(ResponseTemplate::new(204))
        .expect(0)
        .mount(&server)
        .await;
    let out = write_resumable(&server, &local).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["bytes"], 10);
}

/// The target's stat, its content when read back, and the expected exit code.
type LostCommitCase = (Option<Value>, Option<&'static [u8]>, i32);

#[tokio::test]
async fn a_lost_commit_answer_then_upload_not_found_is_success_only_when_the_file_is_there() {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let stat_of = |size: u64, mtime: Value| {
        Some(
            json!({"kind": "file", "size": size, "mode": 420, "mtime": mtime, "owner": "root", "group": "root"}),
        )
    };
    let cases: [LostCommitCase; 6] = [
        // The commit finished: modified after the upload began; nothing is read back.
        (stat_of(10, json!(now)), None, exit::OK),
        // An older file of the same size is there: not the upload.
        (stat_of(10, json!(1_000_000_000)), None, exit::UNEXPECTED),
        // No modification time: the content is read back and matches.
        (stat_of(10, Value::Null), Some(b"0123456789"), exit::OK),
        // No modification time and a same-size file with other content.
        (
            stat_of(10, Value::Null),
            Some(b"abcdefghij"),
            exit::UNEXPECTED,
        ),
        // The upload expired: an older, different file is there.
        (stat_of(3, Value::Null), None, exit::UNEXPECTED),
        // The upload expired and nothing was ever written.
        (None, None, exit::UNEXPECTED),
    ];
    for (stat, content, expected) in cases {
        let server = MockServer::start().await;
        let (local, upload) = mount_sent_upload(&server, "routes-commit-lost").await;
        Mock::given(method("POST"))
            .and(path(format!("{upload}/commit")))
            .respond_with(
                ResponseTemplate::new(503)
                    .set_body_json(json!({"_tag": "Unavailable", "message": "lost"})),
            )
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path(upload.clone()))
            .respond_with(
                ResponseTemplate::new(404)
                    .set_body_json(json!({"_tag": "NotFound", "message": "Upload not found"})),
            )
            .expect(1)
            .mount(&server)
            .await;
        let stat_response = match &stat {
            Some(body) => ResponseTemplate::new(200).set_body_json(body),
            None => ResponseTemplate::new(404)
                .set_body_json(json!({"_tag": "NotFound", "message": "No such file"})),
        };
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM_ID}/files/stat")))
            .and(query_param("path", "/root/big.bin"))
            .respond_with(stat_response)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM_ID}/files/content")))
            .and(query_param("path", "/root/big.bin"))
            .respond_with(
                ResponseTemplate::new(200).set_body_bytes(content.unwrap_or_default().to_vec()),
            )
            .expect(u64::from(content.is_some()))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path(upload.clone()))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;
        let out = write_resumable(&server, &local).await;
        assert_eq!(out.code, expected, "stat {stat:?}: {}", out.stderr);
        if expected != exit::OK {
            assert!(
                out.stderr.contains("without a confirmed commit"),
                "{}",
                out.stderr
            );
        }
        server.verify().await;
    }
}

#[tokio::test]
async fn a_rate_limited_chunk_waits_for_retry_after_before_resuming() {
    let server = MockServer::start().await;
    let (local, upload) = mount_sent_upload(&server, "routes-retry-after").await;
    // The chunk mount above answers the resend; this one answers first.
    Mock::given(method("PUT"))
        .and(path(upload.clone()))
        .and(query_param("offset", "0"))
        .respond_with(
            ResponseTemplate::new(429)
                .insert_header("retry-after", "1")
                .set_body_json(
                    json!({"_tag": "QuotaExceeded", "message": "slow down", "budget": "rate"}),
                ),
        )
        .up_to_n_times(1)
        .expect(1)
        .with_priority(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(upload.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_json(whole_upload_state(0)))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("{upload}/commit")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let started = std::time::Instant::now();
    let out = write_resumable(&server, &local).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(
        started.elapsed() >= std::time::Duration::from_secs(1),
        "the retry waited only {:?}",
        started.elapsed()
    );
}

#[tokio::test]
async fn session_verbs_read_retarget_and_mint_tokens_shown_only_with_json() {
    let server = MockServer::start().await;
    let summary = json!({"id": SESSION, "vmId": VM_ID, "linuxUser": "dev", "createdAt": "2026-10-25T00:00:00Z"});
    let base = format!("/v1/vms/{VM_ID}/client-sessions/{SESSION}");
    Mock::given(method("GET"))
        .and(path(base.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_json(&summary))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("{base}/linux-user")))
        .and(body_json(json!({"linuxUser": "ops"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": SESSION, "vmId": VM_ID, "linuxUser": "ops", "createdAt": "2026-10-25T00:00:00Z"})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("{base}/tokens")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"tokens": [{"id": TOKEN_ID, "sessionId": SESSION}]})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let token = json!({"id": TOKEN_ID, "sessionId": SESSION, "vmId": VM_ID, "token": "secret-token-2",
        "providerVmId": "p1", "linuxUser": "dev", "apiBaseUrl": "https://api.example",
        "ssh": {"host": "ssh.example", "user": "p1+dev"}, "createdAt": "2026-10-25T00:00:00Z"});
    Mock::given(method("POST"))
        .and(path(format!("{base}/tokens")))
        .respond_with(ResponseTemplate::new(201).set_body_json(&token))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("{base}/tokens/{TOKEN_ID}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["session", "get", VM_ID, SESSION]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("dev"));
    let out = cli(
        &server,
        &["--json", "identity", "permissions", VM_ID, SESSION],
    )
    .await;
    assert_eq!(json_stdout(&out), summary);
    let out = cli(&server, &["session", "set-user", VM_ID, SESSION, "ops"]).await;
    assert!(out.stdout.contains("ops"), "{}", out.stderr);
    let out = cli(&server, &["identity", "tokens", VM_ID, SESSION]).await;
    assert!(out.stdout.contains(TOKEN_ID), "{}", out.stderr);
    let out = cli(&server, &["session", "token-create", VM_ID, SESSION]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(!out.stdout.contains("secret-token-2"), "{}", out.stdout);
    // The new token's id is `id` here (`tokenId` only on session create).
    assert!(out.stdout.contains(TOKEN_ID), "{}", out.stdout);
    let out = cli(
        &server,
        &["--json", "session", "token-create", VM_ID, SESSION],
    )
    .await;
    assert_eq!(json_stdout(&out)["token"], "secret-token-2");
    let out = cli(
        &server,
        &["session", "token-revoke", VM_ID, SESSION, TOKEN_ID],
    )
    .await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "revoke needs --yes without a terminal"
    );
    let out = cli(
        &server,
        &[
            "--json",
            "identity",
            "token-revoke",
            VM_ID,
            SESSION,
            TOKEN_ID,
            "--yes",
        ],
    )
    .await;
    assert_eq!(json_stdout(&out), json!({"id": TOKEN_ID, "revoked": true}));
    let out = cli(&server, &["session", "get", VM_ID, "vcs_../x"]).await;
    assert_eq!(out.code, exit::USAGE);
}

#[tokio::test]
async fn session_list_all_pages_through_the_team_and_identity_keeps_its_vm_form() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/client-sessions"))
        .and(query_param("limit", "50"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"sessions": [
            {"id": SESSION, "vmId": VM_ID, "linuxUser": "dev", "createdAt": "2026-10-25T00:00:00Z"}
        ], "nextCursor": SESSION})),
        )
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/identity")))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"id": VM_ID, "scheme": "sha256-v1", "fingerprint": "a".repeat(64)}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["session", "list", "--all", "--limit", "50"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains(VM_ID), "{}", out.stdout);
    assert!(out.stdout.contains("--cursor"), "{}", out.stdout);
    let out = cli(&server, &["identity", "list", "--all", "--limit", "50"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["session", "list"]).await;
    assert_eq!(out.code, exit::USAGE, "a VM or --all is needed");
    let out = cli(&server, &["session", "list", VM_ID, "--all"]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(&server, &["--json", "identity", VM_ID]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["scheme"], "sha256-v1");
    let out = cli(&server, &["identity"]).await;
    assert_eq!(out.code, exit::USAGE);
}

#[tokio::test]
async fn vpc_update_and_ips_and_tunnel_list_and_update() {
    let server = MockServer::start().await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/meshes/{MESH}")))
        .and(body_json(json!({"displayName": "lab2"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": MESH, "displayName": "lab2", "ipv4Cidr": "10.8.0.0/24", "createdAt": "2026-10-25T00:00:00Z"})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/meshes/{MESH}")))
        .and(body_json(json!({"displayName": null})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": MESH, "displayName": null, "ipv4Cidr": "10.8.0.0/24", "createdAt": "2026-10-25T00:00:00Z"})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/meshes/{MESH}/addresses")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"meshId": MESH, "items": [
            {"kind": "vm", "id": VM_ID, "ipv4": "10.8.0.2"}, {"kind": "device", "id": DEVICE, "ipv4": null}]})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/tunnels"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [
            {"id": TUNNEL, "deviceId": DEVICE, "meshId": MESH, "name": "laptop", "createdAt": "2026-10-25T00:00:00Z"}]})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PATCH"))
        .and(path(format!("/v1/devices/{DEVICE}")))
        .and(body_json(json!({"name": "work laptop"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": DEVICE, "meshId": MESH, "name": "work laptop",
            "wgPublicKey": "w", "installPublicKey": null, "tunnelId": TUNNEL, "createdAt": "2026-10-25T00:00:00Z"})))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["vpc", "update", MESH, "--name", "lab2"]).await;
    assert!(out.stdout.contains("lab2"), "{}", out.stderr);
    let out = cli(&server, &["--json", "mesh", "update", MESH, "--clear-name"]).await;
    assert_eq!(json_stdout(&out)["displayName"], Value::Null);
    let out = cli(&server, &["vpc", "update", MESH]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(&server, &["vpc", "ips", MESH]).await;
    assert!(out.stdout.contains("10.8.0.2"), "{}", out.stderr);
    let out = cli(&server, &["tunnel", "list"]).await;
    assert!(
        out.stdout.contains("laptop") && out.stdout.contains(TUNNEL),
        "{}",
        out.stderr
    );
    let out = cli(
        &server,
        &["tunnel", "update", DEVICE, "--name", "work laptop"],
    )
    .await;
    assert!(out.stdout.contains("work laptop"), "{}", out.stderr);
}

#[tokio::test]
async fn firewall_rules_rule_and_evaluate_exit_by_the_verdict() {
    let server = MockServer::start().await;
    let rule = json!({"id": FWR, "meshId": MESH, "deviceId": DEVICE, "vmId": VM_ID, "source": "tunnel",
        "protocol": "tcp", "port": 22, "createdAt": "2026-10-25T00:00:00Z"});
    Mock::given(method("GET"))
        .and(path(format!("/v1/meshes/{MESH}/acl/rules")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"meshId": MESH, "aclVersion": 3, "items": [rule.clone()]})),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/meshes/{MESH}/acl/rules/{FWR}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&rule))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/meshes/{MESH}/acl/evaluate")))
        .and(body_json(json!({"src": DEVICE, "dst": VM_ID, "protocol": "tcp", "port": 22})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"meshId": MESH, "aclVersion": 3, "allowed": true, "path": "firewall", "ruleIndex": 0})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/meshes/{MESH}/acl/evaluate")))
        .and(body_json(json!({"src": DEVICE, "dst": VM_ID, "protocol": "udp"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"meshId": MESH, "aclVersion": 3, "allowed": false, "path": "firewall", "ruleIndex": null})))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["firewall", "rules", MESH]).await;
    assert!(
        out.stdout.contains(FWR) && out.stdout.contains("22"),
        "{}",
        out.stderr
    );
    let out = cli(&server, &["--json", "firewall", "rule", MESH, FWR]).await;
    assert_eq!(json_stdout(&out), rule);
    let out = cli(&server, &["firewall", "rule", MESH, "fwr_x"]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(
        &server,
        &[
            "firewall", "evaluate", MESH, "--from", DEVICE, "--to", VM_ID, "--port", "22",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("allowed"));
    let out = cli(
        &server,
        &[
            "--json", "firewall", "evaluate", MESH, "--from", DEVICE, "--to", VM_ID, "--proto",
            "udp",
        ],
    )
    .await;
    assert_eq!(out.code, exit::NO);
    assert_eq!(json_stdout(&out)["allowed"], false);
    assert!(out.stderr.is_empty(), "{}", out.stderr);
}

#[tokio::test]
async fn domain_verbs_print_the_record_verify_and_release() {
    let server = MockServer::start().await;
    let verification = json!({"id": VERIFICATION, "domain": "example.com", "state": "pending",
        "record": {"name": "_cmux.example.com", "type": "TXT", "value": "cmux-verify=abc"},
        "createdAt": "2026-10-25T00:00:00Z", "verifiedAt": null});
    let domain = json!({"id": DOMAIN, "domain": "example.com", "verifiedAt": "2026-10-25T00:01:00Z",
        "dns": {"routing": {"name": "*.example.com", "type": "CNAME", "value": "edge.example.net"}, "wildcardCertificate": null}});
    Mock::given(method("POST"))
        .and(path("/v1/domain-verifications"))
        .and(body_json(json!({"domain": "example.com"})))
        .respond_with(ResponseTemplate::new(201).set_body_json(&verification))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/domain-verifications"))
        .and(query_param("state", "pending"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"items": [verification.clone()]})),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/domain-verifications/{VERIFICATION}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&verification))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!(
            "/v1/domain-verifications/{VERIFICATION}/verify"
        )))
        .respond_with(ResponseTemplate::new(200).set_body_json(&domain))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/domain-verifications/{VERIFICATION}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/domains"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(
                json!({"items": [domain.clone()], "managedSuffix": "--t1.vm.example"}),
            ),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/domains/{DOMAIN}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&domain))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/domains/{DOMAIN}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let cert = json!({"domain": "*.example.com", "wildcard": true, "active": false, "notAfter": "2027-01-01T00:00:00Z", "generation": 1});
    Mock::given(method("GET"))
        .and(path("/v1/certificates"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [cert.clone()]})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/domains/{DOMAIN}/wildcard-certificate")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&cert))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["domain", "verify-create", "example.com"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(
        out.stdout.contains("TXT _cmux.example.com cmux-verify=abc"),
        "{}",
        out.stdout
    );
    assert!(
        out.stdout
            .contains(&format!("domain verify {VERIFICATION}")),
        "{}",
        out.stdout
    );
    let out = cli(&server, &["domain", "verifications", "--state", "pending"]).await;
    assert!(out.stdout.contains(VERIFICATION), "{}", out.stderr);
    let out = cli(&server, &["--json", "domain", "verification", VERIFICATION]).await;
    assert_eq!(json_stdout(&out), verification);
    let out = cli(&server, &["domain", "verify", VERIFICATION]).await;
    assert!(out.stdout.contains("CNAME"), "{}", out.stderr);
    let out = cli(
        &server,
        &["domain", "verification-delete", VERIFICATION, "--yes"],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["domains", "list"]).await;
    assert!(
        out.stdout.contains("example.com") && out.stdout.contains("--t1.vm.example"),
        "{}",
        out.stderr
    );
    let out = cli(&server, &["domain", "get", DOMAIN]).await;
    assert!(out.stdout.contains(DOMAIN), "{}", out.stderr);
    let out = cli(&server, &["domain", "delete", DOMAIN]).await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "release needs --yes without a terminal"
    );
    let out = run(
        &server,
        &["domain", "delete", DOMAIN],
        &mut Tty { answer: DOMAIN },
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["domain", "certs"]).await;
    assert!(out.stdout.contains("*.example.com"), "{}", out.stderr);
    let out = cli(&server, &["--json", "domain", "wildcard", DOMAIN]).await;
    assert_eq!(json_stdout(&out)["wildcard"], true);
    let out = cli(&server, &["domain", "get", "example.com"]).await;
    assert_eq!(out.code, exit::USAGE);
}

#[tokio::test]
async fn tls_rules_build_from_flags_or_a_file_and_hide_header_values() {
    let server = MockServer::start().await;
    let rule = json!({"id": RULE, "domain": "app.example.com", "protocol": "http", "direction": "ingress",
        "source": {"public": true}, "destination": {"vmId": VM_ID, "port": 8080}, "forwardAuthId": null,
        "match": null, "headerNames": ["x-secret"], "description": null,
        "createdAt": "2026-10-25T00:00:00Z", "updatedAt": "2026-10-25T00:00:00Z"});
    Mock::given(method("POST"))
        .and(path("/v1/tls-rules"))
        .and(body_partial_json(
            json!({"domain": "app.example.com", "source": {"public": true},
            "destination": {"vmId": VM_ID, "port": 8080}, "headers": {"x-secret": "s3cret"}}),
        ))
        .respond_with(ResponseTemplate::new(201).set_body_json(&rule))
        .expect(1)
        .mount(&server)
        .await;
    // An update sends the headers again, or (with --clear-headers) none.
    Mock::given(method("PUT"))
        .and(path(format!("/v1/tls-rules/{RULE}")))
        .and(body_partial_json(
            json!({"domain": "app.example.com", "protocol": "tcp",
            "destination": {"vmId": VM_ID, "port": 8080}, "headers": {"x-secret": "s3cret"}}),
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(&rule))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("/v1/tls-rules/{RULE}")))
        .and(body_partial_json(json!({"protocol": "tcp"})))
        .and(without_headers)
        .respond_with(ResponseTemplate::new(200).set_body_json(&rule))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/tls-rules"))
        .and(query_param("vmId", VM_ID))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [rule.clone()]})))
        .expect(1)
        .mount(&server)
        .await;
    // Read once by the refused update, once by `tls get`.
    Mock::given(method("GET"))
        .and(path(format!("/v1/tls-rules/{RULE}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&rule))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/tls-rules/{RULE}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let dir = temp_dir("routes-tls");
    let headers = dir.join("headers.json");
    std::fs::write(&headers, br#"{"x-secret": "s3cret"}"#).unwrap();
    let out = cli(
        &server,
        &[
            "tls",
            "create",
            "--host",
            "app.example.com",
            "--vm",
            VM_ID,
            "--port",
            "8080",
            "--headers-file",
            headers.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(
        out.stdout.contains("x-secret") && !out.stdout.contains("s3cret"),
        "{}",
        out.stdout
    );
    // `tls get --json` output, edited, is a valid --file.
    let edited = dir.join("rule.json");
    let mut file_rule = rule.clone();
    file_rule["protocol"] = json!("tcp");
    std::fs::write(&edited, serde_json::to_vec(&file_rule).unwrap()).unwrap();
    // The file has headerNames but no header values: sending it as is would
    // clear the rule's secret header, so it is refused.
    let out = cli(
        &server,
        &["tls", "update", RULE, "--file", edited.to_str().unwrap()],
    )
    .await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    assert!(
        out.stderr.contains("x-secret") && out.stderr.contains("--clear-headers"),
        "{}",
        out.stderr
    );
    let out = cli(
        &server,
        &[
            "tls",
            "update",
            RULE,
            "--file",
            edited.to_str().unwrap(),
            "--headers-file",
            headers.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(
        &server,
        &[
            "tls",
            "update",
            RULE,
            "--file",
            edited.to_str().unwrap(),
            "--clear-headers",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(
        &server,
        &[
            "tls",
            "update",
            RULE,
            "--file",
            edited.to_str().unwrap(),
            "--clear-headers",
            "--headers-file",
            headers.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "--clear-headers contradicts new headers"
    );
    let out = cli(&server, &["tls", "list", "--vm", VM_ID]).await;
    assert!(
        out.stdout.contains(RULE) && out.stdout.contains(":8080"),
        "{}",
        out.stderr
    );
    let out = cli(&server, &["--json", "tls", "get", RULE]).await;
    assert_eq!(json_stdout(&out), rule);
    let out = cli(&server, &["tls", "create", "--host", "a.example.com"]).await;
    assert_eq!(out.code, exit::USAGE, "--host needs --vm and --port");
    let out = cli(&server, &["tls", "delete", RULE]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(&server, &["--json", "tls", "delete", RULE, "--yes"]).await;
    assert_eq!(json_stdout(&out), json!({"id": RULE, "deleted": true}));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn tls_forward_auth_round_trips_through_a_file() {
    let server = MockServer::start().await;
    let check = json!({"id": FWA, "url": "https://auth.example.com/check", "headerNames": ["authorization"],
        "authResponseHeaders": ["x-user"], "protectedCookies": [], "timeoutMs": 2000,
        "createdAt": "2026-10-25T00:00:00Z", "updatedAt": "2026-10-25T00:00:00Z"});
    Mock::given(method("POST"))
        .and(path("/v1/tls-forward-auths"))
        .and(body_partial_json(json!({"url": "https://auth.example.com/check", "headers": {"authorization": "Bearer t"}, "timeoutMs": 2000})))
        .respond_with(ResponseTemplate::new(201).set_body_json(&check))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("/v1/tls-forward-auths/{FWA}")))
        .and(body_partial_json(
            json!({"url": "https://auth.example.com/check", "authResponseHeaders": ["x-user"],
            "timeoutMs": 2000}),
        ))
        .and(without_headers)
        .respond_with(ResponseTemplate::new(200).set_body_json(&check))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/tls-forward-auths"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [check.clone()]})))
        .expect(1)
        .mount(&server)
        .await;
    // Read once by the refused update, once by `get`.
    Mock::given(method("GET"))
        .and(path(format!("/v1/tls-forward-auths/{FWA}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&check))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/tls-forward-auths/{FWA}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let dir = temp_dir("routes-fwa");
    let create = dir.join("create.json");
    std::fs::write(
        &create,
        br#"{"url": "https://auth.example.com/check", "headers": {"authorization": "Bearer t"}, "timeoutMs": 2000}"#,
    )
    .unwrap();
    let out = cli(
        &server,
        &[
            "tls",
            "forward-auth",
            "create",
            "--file",
            create.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(!out.stdout.contains("Bearer t"), "{}", out.stdout);
    let update = dir.join("update.json");
    std::fs::write(&update, serde_json::to_vec(&check).unwrap()).unwrap();
    // `get --json` output names the header but not its value: refused, so
    // the check's authorization header is not cleared by accident.
    let out = cli(
        &server,
        &[
            "tls",
            "forward-auth",
            "update",
            FWA,
            "--file",
            update.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::USAGE, "{}", out.stderr);
    assert!(out.stderr.contains("authorization"), "{}", out.stderr);
    let out = cli(
        &server,
        &[
            "tls",
            "forward-auth",
            "update",
            FWA,
            "--file",
            update.to_str().unwrap(),
            "--clear-headers",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["tls", "forward-auth", "list"]).await;
    assert!(out.stdout.contains(FWA), "{}", out.stderr);
    let out = cli(&server, &["--json", "tls", "forward-auth", "get", FWA]).await;
    assert_eq!(json_stdout(&out), check);
    let out = cli(&server, &["tls", "forward-auth", "delete", FWA, "--yes"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    std::fs::remove_dir_all(dir).unwrap();
}
