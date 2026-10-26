//! The provider-vocabulary verbs (file, push/pull/scp, ssh, session, terminal,
//! vpc, tunnel, firewall, https-proxy) against a local mock of the cmux VM
//! API: the request each sends, its output and its exit code.

use cmux_vm::exit;
use serde_json::{Value, json};
use wiremock::matchers::{body_bytes, body_json, header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";
const MESH: &str = "mesh_0123456789abcdefghjkmnpqrs";
const DEVICE: &str = "dev_0123456789abcdefghjkmnpqrs";
const TUNNEL: &str = "tun_0123456789abcdefghjkmnpqrs";
const SESSION: &str = "vcs_0123456789abcdefghjkmnpqrs";
const KEY: &str = "cmuxvm_sk_test";

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

#[tokio::test]
async fn fs_is_an_alias_of_file_and_ls_lists_entries() {
    let server = MockServer::start().await;
    let list = json!({"entries": [{"kind": "directory", "name": "src"}, {"kind": "file", "name": "a.txt"}]});
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/entries")))
        .and(query_param("path", "/root"))
        .and(authorized())
        .respond_with(ResponseTemplate::new(200).set_body_json(&list))
        .expect(2)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "fs", "ls", VM_ID, "/root"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), list);
    let out = cli(&server, &["file", "ls", VM_ID, "/root"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("src/"), "{}", out.stdout);
    assert!(out.stdout.contains("a.txt"), "{}", out.stdout);
}

#[tokio::test]
async fn file_write_streams_the_file_with_its_length_and_octal_mode() {
    let server = MockServer::start().await;
    let dir = temp_dir("write");
    let local = dir.join("hello.txt");
    std::fs::write(&local, b"hello world").unwrap();
    Mock::given(method("PUT"))
        .and(path(format!("/v1/vms/{VM_ID}/files/content")))
        .and(query_param("path", "/root/hello.txt"))
        .and(query_param("mode", "420"))
        .and(header("content-length", "11"))
        .and(body_bytes(b"hello world".to_vec()))
        .and(authorized())
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "file",
            "write",
            VM_ID,
            "/root/hello.txt",
            local.to_str().unwrap(),
            "--mode",
            "0644",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["bytes"], 11);
    let out = cli(
        &server,
        &["file", "write", VM_ID, "/root/x", dir.to_str().unwrap()],
    )
    .await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "a directory is refused: {}",
        out.stderr
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn file_read_prints_bytes_or_saves_them_and_refuses_json_without_out() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/content")))
        .and(query_param("path", "/etc/hostname"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"box\n".to_vec()))
        .mount(&server)
        .await;
    let out = cli(&server, &["file", "read", VM_ID, "/etc/hostname"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(out.stdout, "box\n");
    let out = cli(&server, &["--json", "file", "read", VM_ID, "/etc/hostname"]).await;
    assert_eq!(out.code, exit::USAGE);
    let dir = temp_dir("read");
    let saved = dir.join("hostname");
    let out = cli(
        &server,
        &[
            "--json",
            "file",
            "read",
            VM_ID,
            "/etc/hostname",
            "--out",
            saved.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(std::fs::read(&saved).unwrap(), b"box\n");
    assert!(!dir.join("hostname.cmux-vm-partial").exists());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn scp_into_a_guest_directory_keeps_the_file_name() {
    let server = MockServer::start().await;
    let dir = temp_dir("scp");
    let local = dir.join("app.tar");
    std::fs::write(&local, b"tar").unwrap();
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/stat")))
        .and(query_param("path", "/srv"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"kind": "directory", "size": 0, "mode": 493, "mtime": null, "owner": "root", "group": "root"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("/v1/vms/{VM_ID}/files/content")))
        .and(query_param("path", "/srv/app.tar"))
        .respond_with(ResponseTemplate::new(204))
        .expect(2)
        .mount(&server)
        .await;
    let remote = format!("{VM_ID}:/srv");
    let out = cli(&server, &["scp", local.to_str().unwrap(), &remote]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    // A trailing slash needs no stat.
    let remote = format!("{VM_ID}:/srv/");
    let out = cli(&server, &["push", local.to_str().unwrap(), &remote]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(&server, &["scp", "a", "b"]).await;
    assert_eq!(out.code, exit::USAGE);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn pull_into_a_local_directory_takes_the_guest_name() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/files/content")))
        .and(query_param("path", "/var/log/syslog"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"log".to_vec()))
        .expect(1)
        .mount(&server)
        .await;
    let dir = temp_dir("pull");
    let remote = format!("{VM_ID}:/var/log/syslog");
    let out = cli(&server, &["--json", "pull", &remote, dir.to_str().unwrap()]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(std::fs::read(dir.join("syslog")).unwrap(), b"log");
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn session_create_shows_the_token_only_with_json() {
    let server = MockServer::start().await;
    let session = json!({
        "id": SESSION, "vmId": VM_ID, "token": "secret-session-token", "providerVmId": "p1",
        "linuxUser": "dev", "apiBaseUrl": "https://api.example", "ssh": {"host": "ssh.example", "user": "p1+dev"},
        "createdAt": "2026-10-25T00:00:00Z"
    });
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .and(body_json(json!({"linuxUser": "dev"})))
        .and(authorized())
        .respond_with(ResponseTemplate::new(201).set_body_json(&session))
        .expect(2)
        .mount(&server)
        .await;
    let human = cli(
        &server,
        &["session", "create", VM_ID, "--linux-user", "dev"],
    )
    .await;
    assert_eq!(human.code, exit::OK, "{}", human.stderr);
    assert!(
        !human.stdout.contains("secret-session-token"),
        "{}",
        human.stdout
    );
    assert!(!human.stderr.contains("secret-session-token"));
    assert!(human.stdout.contains(SESSION));
    let json_out = cli(
        &server,
        &["--json", "session", "create", VM_ID, "--linux-user", "dev"],
    )
    .await;
    assert_eq!(json_stdout(&json_out)["token"], "secret-session-token");
}

#[tokio::test]
async fn session_revoke_and_terminal_close_need_confirmation() {
    let server = MockServer::start().await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions/{SESSION}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/terminals/7")))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"sessionId": 7, "exitCode": null})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["session", "revoke", VM_ID, SESSION]).await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "no terminal and no --yes: {}",
        out.stderr
    );
    let out = run(
        &server,
        &["session", "revoke", VM_ID, SESSION],
        &mut Tty { answer: "nope" },
    )
    .await;
    assert_eq!(out.code, exit::CANCELLED);
    let out = run(
        &server,
        &["session", "revoke", VM_ID, SESSION],
        &mut Tty { answer: SESSION },
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    let out = cli(
        &server,
        &["--json", "session", "revoke", VM_ID, SESSION, "--yes"],
    )
    .await;
    assert_eq!(json_stdout(&out), json!({"id": SESSION, "revoked": true}));
    let out = cli(&server, &["terminal", "close", VM_ID, "7"]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(
        &server,
        &["--json", "terminal", "close", VM_ID, "7", "--yes"],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["sessionId"], 7);
}

#[tokio::test]
async fn terminal_list_passes_the_user_filter() {
    let server = MockServer::start().await;
    let list = json!({"items": [{"sessionId": 1, "state": "running", "user": "dev", "name": "main", "cols": 80, "rows": 24, "createdAt": "2026-10-25T00:00:00Z", "exitCode": null}]});
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM_ID}/terminals")))
        .and(query_param("user", "dev"))
        .respond_with(ResponseTemplate::new(200).set_body_json(&list))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["terminal", "list", VM_ID, "--user", "dev"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("80x24"), "{}", out.stdout);
}

#[tokio::test]
async fn ssh_prints_no_json_and_names_the_session_route() {
    let server = MockServer::start().await;
    let out = cli(&server, &["--json", "ssh", VM_ID]).await;
    assert_eq!(out.code, exit::USAGE);
    assert!(out.stderr.contains("session create"), "{}", out.stderr);
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn vpc_verbs_use_the_mesh_routes_and_mesh_is_an_alias() {
    let server = MockServer::start().await;
    let mesh = json!({"id": MESH, "displayName": "lab", "ipv4Cidr": "10.8.0.0/24", "createdAt": "2026-10-25T00:00:00Z"});
    Mock::given(method("POST"))
        .and(path("/v1/meshes"))
        .and(body_json(json!({"displayName": "lab"})))
        .and(header("idempotency-key", "k-1"))
        .respond_with(ResponseTemplate::new(201).set_body_json(&mesh))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/v1/meshes"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"items": [mesh.clone()]})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("PUT"))
        .and(path(format!("/v1/meshes/{MESH}/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"meshId": MESH, "vmId": VM_ID, "ipv4": "10.8.0.2", "attachedAt": "2026-10-25T00:00:00Z"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/meshes/{MESH}/vms/{VM_ID}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/meshes/{MESH}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "--json",
            "vpc",
            "create",
            "--name",
            "lab",
            "--idempotency-key",
            "k-1",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out), mesh);
    let out = cli(&server, &["mesh", "list"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("10.8.0.0/24"));
    let out = cli(&server, &["vpc", "attach", MESH, VM_ID]).await;
    assert!(out.stdout.contains("10.8.0.2"), "{}", out.stderr);
    let out = cli(&server, &["--json", "vpc", "detach", MESH, VM_ID]).await;
    assert_eq!(json_stdout(&out)["detached"], true);
    let out = cli(&server, &["vpc", "delete", MESH]).await;
    assert_eq!(
        out.code,
        exit::USAGE,
        "delete needs --yes without a terminal"
    );
    let out = cli(&server, &["vpc", "delete", MESH, "--yes"]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
}

#[tokio::test]
async fn tunnel_get_reads_a_tunnel_or_a_device_and_codes_are_shown_once() {
    let server = MockServer::start().await;
    let tunnel = json!({"id": TUNNEL, "meshId": MESH, "deviceId": DEVICE, "endpointHost": "wg.example", "endpointPort": 51820,
        "serverPublicKey": "k", "interfaceAddress": "10.8.0.9/32", "meshAddress": "10.8.0.9", "allowedIps": ["10.8.0.0/24"],
        "mtu": 1280, "persistentKeepaliveSeconds": 25});
    Mock::given(method("GET"))
        .and(path(format!("/v1/tunnels/{TUNNEL}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(&tunnel))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path(format!("/v1/devices/{DEVICE}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id": DEVICE, "meshId": MESH, "name": "laptop",
            "wgPublicKey": "w", "installPublicKey": null, "tunnelId": TUNNEL, "createdAt": "2026-10-25T00:00:00Z"})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/v1/meshes/{MESH}/enrollment-codes")))
        .and(body_json(json!({})))
        .respond_with(ResponseTemplate::new(201).set_body_json(
            json!({"code": "mec_0123456789abcdefghjkmnpqrs", "meshId": MESH, "expiresAt": "2026-10-25T00:10:00Z"}),
        ))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/devices/{DEVICE}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(&server, &["--json", "tunnel", "get", TUNNEL]).await;
    assert_eq!(json_stdout(&out), tunnel);
    let out = cli(&server, &["tunnels", "get", DEVICE]).await;
    assert!(out.stdout.contains("laptop"), "{}", out.stderr);
    let out = cli(&server, &["tunnel", "get", "nonsense"]).await;
    assert_eq!(out.code, exit::USAGE);
    let out = cli(&server, &["tunnel", "enrollment-code", MESH]).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("mec_0123456789abcdefghjkmnpqrs"));
    let out = cli(&server, &["--json", "tunnel", "delete", DEVICE, "--yes"]).await;
    assert_eq!(json_stdout(&out), json!({"id": DEVICE, "deleted": true}));
}

#[tokio::test]
async fn firewall_set_applies_edited_get_output_at_its_version() {
    let server = MockServer::start().await;
    let rule = json!({"src": ["dev:*"], "dst": ["vm:*"], "allow": ["tcp:22"]});
    Mock::given(method("PUT"))
        .and(path(format!("/v1/meshes/{MESH}/acl")))
        .and(body_json(
            json!({"expectedVersion": 4, "rules": [rule.clone()]}),
        ))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"meshId": MESH, "version": 5, "ruleCount": 1,
            "rulesCreated": 1, "rulesDeleted": 0, "applyMs": 12})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let dir = temp_dir("acl");
    let file = dir.join("acl.json");
    std::fs::write(
        &file,
        serde_json::to_vec(
            &json!({"meshId": MESH, "version": 4, "rules": [rule], "updatedAt": null}),
        )
        .unwrap(),
    )
    .unwrap();
    let out = cli(
        &server,
        &[
            "--json",
            "firewall",
            "set",
            MESH,
            "--file",
            file.to_str().unwrap(),
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert_eq!(json_stdout(&out)["version"], 5);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn https_proxy_set_sends_destination_and_headers() {
    let server = MockServer::start().await;
    Mock::given(method("PUT"))
        .and(path(format!("/v1/vms/{VM_ID}/https-proxies/api.internal")))
        .and(body_json(
            json!({"destination": "https://api.example.com", "headers": {"x-team": "a"}}),
        ))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"id": VM_ID, "hostname": "api.internal"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let out = cli(
        &server,
        &[
            "https-proxy",
            "set",
            VM_ID,
            "api.internal",
            "--destination",
            "https://api.example.com",
            "--header",
            "x-team=a",
        ],
    )
    .await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(out.stdout.contains("api.internal"));
}
