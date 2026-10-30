//! Installer process contract, including recovery across redeem/local-commit failures.
//! Ignored tests mutate passwd-rooted consent and run only in a disposable Unix account.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::{Output, Stdio};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent runs here. A disposable-account run points `ACPMUX_TEST_BINARY` at a relocated
// build the other UID can read (`machine_consent_home::binary`), so it survives the re-start.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&["ACPMUX_TEST_BINARY"]);

#[path = "support/machine_consent_home.rs"]
mod machine_consent_home;

const TOKEN: &str = "cmj_test_secret_never_print";
const FRESH_TOKEN: &str = "cmj_fresh_test_secret_never_print";
const CREDENTIAL: &str = "cmm_test_secret_never_print";
const PENDING: &str = "machine-join.pending.json";
const FINAL: &str = "machine-credential.json";

fn cli(home: &Path) -> Command {
    let mut command = Command::new(machine_consent_home::binary(daemon_env::bin()));
    command
        .env_clear()
        .envs(daemon_env::vars(home, daemon_env::Agents::Deny, &[]))
        .env("ACPMUX_HOME", home)
        .env_remove("CMUX_JOIN")
        .env_remove("CMUX_PLATFORM_ORIGIN")
        .env_remove("ACPMUX_SOCKET")
        .env_remove("ACPMUX_DAEMON")
        .kill_on_drop(true)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

// A finite script fails on an extra request or a missing request. poll bounds
// accept without a sleep/polling loop, so a CLI regression cannot hang the suite.
fn response_server(
    requests: usize,
    mut respond: impl FnMut(usize, &str, &str, &Value) -> Option<(u16, Value)> + Send + 'static,
) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        for index in 0..requests {
            let mut fd =
                libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            // SAFETY: one live pollfd and a valid listener; timeout is bounded.
            assert_eq!(
                unsafe { libc::poll(&mut fd, 1, 10_000) },
                1,
                "missing HTTP request {index}"
            );
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            let mut reader = BufReader::new(socket.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            assert!(!request.contains("cmj_") && !request.contains("cmm_"));
            let mut length = 0usize;
            let mut bearer = String::new();
            loop {
                let mut line = String::new();
                assert!(reader.read_line(&mut line).unwrap() > 0, "truncated HTTP headers");
                if line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    if key.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse().unwrap();
                    }
                    if key.eq_ignore_ascii_case("authorization") {
                        bearer = value.trim().to_owned();
                    }
                }
                assert!(!line.contains("cmj_"));
            }
            let mut bytes = vec![0; length];
            reader.read_exact(&mut bytes).unwrap();
            let body = if bytes.is_empty() {
                Value::Null
            } else {
                serde_json::from_slice(&bytes).unwrap()
            };
            if let Some((status, body)) = respond(index, &request, &bearer, &body) {
                let response = body.to_string();
                write!(socket, "HTTP/1.1 {status} response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
            }
        }
    });
    (origin, thread)
}

enum Step {
    Redeem(u16),
    LostReply,
    Live(Option<std::path::PathBuf>),
    Unknown,
    Revoked,
    Unavailable,
}

fn hub(steps: Vec<Step>, home: &Path, consent: &Path) -> (String, std::thread::JoinHandle<()>) {
    let home = home.to_owned();
    let consent = consent.to_owned();
    let mut proposal: Option<Value> = None;
    let mut generation = 1;
    let mut revoked = false;
    response_server(steps.len(), move |index, request, bearer, body| {
        let step = &steps[index];
        if matches!(step, Step::Redeem(_) | Step::LostReply) {
            assert!(request.starts_with("POST /v1/machines/join-tokens/redeem "));
            assert!(bearer.is_empty());
            assert!(body["token"] == TOKEN || body["token"] == FRESH_TOKEN);
            assert!(
                consent.join("enrolled.json").is_file(),
                "consent requirement must precede redeem"
            );
            let pending = read_json(&home.join(PENDING));
            assert!(pending["credential"] == body["proposedCredential"]);
            assert_eq!(std::fs::metadata(home.join(PENDING)).unwrap().mode() & 0o777, 0o600);
            assert!(!std::fs::read_to_string(home.join(PENDING)).unwrap().contains(TOKEN));
            let credential = body["proposedCredential"].as_str().expect("proposal missing");
            assert!(credential.starts_with("cmm_") && credential.len() == 47);
            if let Some(previous) = &proposal {
                if previous["proposedCredential"] == body["proposedCredential"] {
                    assert!(previous == body, "replay metadata must be immutable");
                } else {
                    if revoked {
                        assert!(body["token"] == FRESH_TOKEN);
                        assert!(body.get("replaceCredential").is_none());
                    } else {
                        assert!(body["replaceCredential"] == previous["proposedCredential"]);
                    }
                    generation += 1;
                }
            } else {
                assert!(body.get("replaceCredential").is_none());
            }
            proposal = Some(body.clone());
            revoked = false;
            return match step {
                Step::LostReply => None,
                Step::Redeem(status) => Some((
                    *status,
                    json!({"machineId":"machine_test", "teamId":"team_test", "joinTokenId":"join_test", "wgPublicKey":body["wgPublicKey"], "expiresAt":"2099-01-01T00:00:00.000Z"}),
                )),
                _ => unreachable!(),
            };
        }
        assert!(request.starts_with("GET /v1/machines/credentials/self "));
        assert_eq!(*body, Value::Null);
        let pending = proposal.as_ref().unwrap();
        assert!(bearer == format!("Bearer {}", pending["proposedCredential"].as_str().unwrap()));
        match step {
            Step::Live(obstacle) => {
                if let Some(path) = obstacle {
                    std::fs::create_dir(path).unwrap();
                }
                Some((
                    200,
                    json!({"machineId":"machine_test", "teamId":"team_test", "joinTokenId":"join_test", "wgPublicKey":pending["wgPublicKey"], "platform":pending["platform"], "hostname":pending["hostname"], "name":pending["name"], "credentialGeneration":generation, "expiresAt":"2099-01-01T00:00:00.000Z"}),
                ))
            }
            Step::Unknown => Some((401, json!({"code":"machine.unknown"}))),
            Step::Revoked => {
                revoked = true;
                Some((401, json!({"code":"machine.revoked"})))
            }
            Step::Unavailable => Some((503, json!({"error":TOKEN}))),
            _ => unreachable!(),
        }
    })
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
fn assert_redacted(output: &Output) {
    for text in [&output.stdout, &output.stderr] {
        let text = String::from_utf8_lossy(text);
        assert!(!text.contains("cmj_") && !text.contains("cmm_"), "secret in process output");
    }
}
fn assert_no_join_token_on_disk(home: &Path) {
    for entry in std::fs::read_dir(home).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            assert_no_join_token_on_disk(&path);
        } else {
            let bytes = std::fs::read(&path).unwrap();
            for token in [TOKEN, FRESH_TOKEN] {
                assert!(!bytes.windows(token.len()).any(|part| part == token.as_bytes()));
            }
        }
    }
}
async fn join(home: &Path, origin: Option<&str>, token: bool, replace: bool) -> Output {
    join_with_input(home, origin, token.then_some(TOKEN), replace).await
}
async fn join_with_input(
    home: &Path,
    origin: Option<&str>,
    token: Option<&str>,
    replace: bool,
) -> Output {
    let mut command = cli(home);
    command.args(["host", "join", "--json"]);
    if let Some(origin) = origin {
        command.args(["--hub", origin, "--name", "test"]);
    }
    if replace {
        command.arg("--replace");
    }
    let mut child = command.stdin(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take();
    if let Some(token) = token {
        input.as_mut().unwrap().write_all(format!("{token}\n").as_bytes()).await.unwrap();
        #[cfg(target_os = "linux")]
        for file in ["cmdline", "environ"] {
            let bytes = std::fs::read(format!("/proc/{}/{file}", child.id().unwrap())).unwrap();
            assert!(!bytes.windows(token.len()).any(|part| part == token.as_bytes()));
        }
        drop(input.take());
    }
    // Keep tokenless stdin open. Recovery must not require EOF or a new token.
    let output = tokio::time::timeout(Duration::from_secs(15), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    drop(input);
    assert_redacted(&output);
    assert_no_join_token_on_disk(home);
    output
}
fn assert_exit(output: &Output, code: i32) {
    assert_eq!(output.status.code(), Some(code), "{}", String::from_utf8_lossy(&output.stderr));
}
fn assert_complete(home: &Path, origin: &str) {
    assert!(!home.join(PENDING).exists());
    assert_eq!(std::fs::metadata(home.join(FINAL)).unwrap().mode() & 0o777, 0o600);
    let config = read_json(&home.join("config.json"));
    assert_eq!(config["meshRelay"]["credential"], "join");
    assert_eq!(config["meshRelay"]["url"], origin);
    assert_ne!(config["transport"]["wireguard"], true);
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn join_redeems_once_and_rerun_repairs_config_without_reading_stdin() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) =
        hub(vec![Step::Redeem(200), Step::Live(None)], home.path(), &consent.root);
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 0);
    server.join().unwrap();
    assert_complete(home.path(), &origin);
    std::fs::remove_file(home.path().join("config.json")).unwrap();
    std::fs::remove_file(consent.root.join("enrolled.json")).unwrap();
    let output = join(home.path(), None, false, false).await;
    assert_exit(&output, 0);
    assert_eq!(serde_json::from_slice::<Value>(&output.stdout).unwrap()["alreadyJoined"], true);
    assert!(consent.root.join("enrolled.json").is_file());
    assert_complete(home.path(), &origin);
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn lost_redeem_response_recovers_without_token_or_second_redeem() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = hub(vec![Step::LostReply, Step::Live(None)], home.path(), &consent.root);
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 4);
    let pending = read_json(&home.path().join(PENDING));
    assert!(!home.path().join(FINAL).exists());
    let output =
        cli(home.path()).args(["host", "join", "--status", "--json"]).output().await.unwrap();
    assert_exit(&output, 0);
    let status: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(status["joinIncomplete"], true);
    assert_eq!(status["credentialPresent"], false);
    assert_redacted(&output);
    assert_exit(&join(home.path(), None, false, false).await, 0);
    assert!(read_json(&home.path().join(FINAL))["credential"] == pending["credential"]);
    assert_complete(home.path(), &origin);
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn unknown_pending_requires_original_token_and_replays_the_same_proposal() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = hub(
        vec![Step::Redeem(503), Step::Unknown, Step::Unknown, Step::Redeem(200), Step::Live(None)],
        home.path(),
        &consent.root,
    );
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 4);
    let original = std::fs::read(home.path().join(PENDING)).unwrap();
    assert_exit(&join(home.path(), None, false, true).await, 2);
    assert!(std::fs::read(home.path().join(PENDING)).unwrap() == original);
    assert_exit(&join(home.path(), None, true, true).await, 0);
    assert_complete(home.path(), &origin);
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn local_commit_failures_keep_recovery_proof_until_both_writes_succeed() {
    let consent = machine_consent_home::ConsentHome::isolated();
    for file in [FINAL, "config.json"] {
        let home = tempfile::tempdir().unwrap();
        let target = home.path().join(file);
        let (origin, server) = hub(
            vec![Step::Redeem(200), Step::Live(Some(target.clone())), Step::Live(None)],
            home.path(),
            &consent.root,
        );
        assert_exit(&join(home.path(), Some(&origin), true, false).await, 5);
        let original = read_json(&home.path().join(PENDING));
        std::fs::remove_dir(&target).unwrap();
        // Even when the final credential exists, pending takes precedence over
        // alreadyJoined and forces authoritative recovery before success.
        let output = join(home.path(), None, false, false).await;
        assert_exit(&output, 0);
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["alreadyJoined"],
            false
        );
        assert!(read_json(&home.path().join(FINAL))["credential"] == original["credential"]);
        assert_complete(home.path(), &origin);
        server.join().unwrap();
    }
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn replacement_keeps_old_final_until_new_credential_is_recovered() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = hub(
        vec![
            Step::Redeem(200),
            Step::Live(None),
            Step::Live(None), // preflight the final credential before replacement
            Step::Redeem(503),
            Step::Unknown,
            Step::LostReply,
            Step::Live(None),
        ],
        home.path(),
        &consent.root,
    );
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 0);
    let old = std::fs::read(home.path().join(FINAL)).unwrap();
    assert_exit(&join(home.path(), Some(&origin), true, true).await, 4);
    assert!(std::fs::read(home.path().join(FINAL)).unwrap() == old);
    let pending = read_json(&home.path().join(PENDING));
    assert_exit(&join(home.path(), None, true, true).await, 4);
    assert!(std::fs::read(home.path().join(FINAL)).unwrap() == old);
    assert_exit(&join(home.path(), None, false, false).await, 0);
    let final_record = read_json(&home.path().join(FINAL));
    assert!(final_record["credential"] == pending["credential"]);
    assert_eq!(final_record["machine_id"], "machine_test");
    assert_eq!(final_record["credential_generation"], 2);
    assert_complete(home.path(), &origin);
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn pending_network_failure_and_revocation_preserve_proof_and_never_redeem() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) =
        hub(vec![Step::LostReply, Step::Unavailable, Step::Revoked], home.path(), &consent.root);
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 4);
    let original = std::fs::read(home.path().join(PENDING)).unwrap();
    assert_exit(&join(home.path(), None, true, true).await, 4);
    assert!(std::fs::read(home.path().join(PENDING)).unwrap() == original);
    let output = join(home.path(), None, false, false).await;
    assert_exit(&output, 3);
    assert!(String::from_utf8_lossy(&output.stderr).contains("revoked"));
    assert!(std::fs::read(home.path().join(PENDING)).unwrap() == original);

    assert!(!home.path().join(FINAL).exists());
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn explicit_replace_resets_only_a_definitively_revoked_pending_proposal() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = hub(
        vec![Step::LostReply, Step::Revoked, Step::Revoked, Step::Redeem(200), Step::Live(None)],
        home.path(),
        &consent.root,
    );
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 4);
    let original = std::fs::read(home.path().join(PENDING)).unwrap();
    assert_exit(&join(home.path(), None, false, false).await, 3);
    assert!(std::fs::read(home.path().join(PENDING)).unwrap() == original);
    let output = join_with_input(home.path(), None, Some(FRESH_TOKEN), true).await;
    assert_exit(&output, 0);
    let old: Value = serde_json::from_slice(&original).unwrap();
    let final_record = read_json(&home.path().join(FINAL));
    assert!(final_record["credential"] != old["credential"]);
    assert_complete(home.path(), &origin);
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn finalized_revoked_credential_is_reenrolled_without_replacement_proof() {
    let consent = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = hub(
        vec![
            Step::Redeem(200),
            Step::Live(None),
            Step::Unavailable,
            Step::Revoked,
            Step::Redeem(200),
            Step::Live(None),
        ],
        home.path(),
        &consent.root,
    );
    assert_exit(&join(home.path(), Some(&origin), true, false).await, 0);
    let original = std::fs::read(home.path().join(FINAL)).unwrap();
    assert_eq!(read_json(&home.path().join(FINAL))["revoked"], false);
    // An inconclusive preflight cannot discard the final proof or create a
    // replacement attempt. A later definitive revoke permits fresh enrollment.
    assert_exit(&join_with_input(home.path(), Some(&origin), Some(FRESH_TOKEN), true).await, 4);
    assert!(!home.path().join(PENDING).exists());
    assert!(std::fs::read(home.path().join(FINAL)).unwrap() == original);
    assert_exit(&join_with_input(home.path(), Some(&origin), Some(FRESH_TOKEN), true).await, 0);
    let old: Value = serde_json::from_slice(&original).unwrap();
    assert!(read_json(&home.path().join(FINAL))["credential"] != old["credential"]);
    assert_complete(home.path(), &origin);
    server.join().unwrap();
}

#[tokio::test]
#[ignore = "red path may mutate OS-account consent; run in a disposable Unix account"]
async fn secret_prefix_machine_name_is_refused_before_http_or_pending_write() {
    let _consent = machine_consent_home::ConsentHome::isolated();
    for name in ["cmm_builder", "cmj_builder"] {
        let home = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let mut child = cli(home.path())
            .args(["host", "join", "--hub", &origin, "--name", name])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        input.write_all(format!("{TOKEN}\n").as_bytes()).await.unwrap();
        drop(input);
        let output = tokio::time::timeout(Duration::from_secs(15), child.wait_with_output())
            .await
            .unwrap()
            .unwrap();
        assert_redacted(&output);
        assert_exit(&output, 2);
        assert!(!home.path().join(PENDING).exists());
        assert!(!home.path().join(FINAL).exists());
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }
}

#[tokio::test]
#[ignore = "mutates OS-account consent; run with --include-ignored in a disposable Unix account"]
async fn status_is_read_only_and_persists_revocation() {
    let _consent_home = machine_consent_home::ConsentHome::isolated();
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = response_server(1, |_, request, bearer, body| {
        assert!(request.starts_with("GET /v1/machines/credentials/self "));
        assert!(bearer == format!("Bearer {CREDENTIAL}"));
        assert_eq!(*body, Value::Null);
        Some((401, json!({"code":"machine.revoked"})))
    });
    let path = home.path().join(FINAL);
    std::fs::write(&path, json!({"credential":CREDENTIAL,"machine_id":"machine_test","team_id":"team_test","name":"test","hub_origin":origin,"last_heartbeat":"1234","revoked":false,"wgPublicKey":"key"}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        cli(home.path()).args(["host", "join", "--status", "--json"]).output(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_exit(&result, 0);
    let body: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(body["revoked"], true);
    assert!(body.get("lastRefusal").is_some());
    assert_eq!(body["helperConsent"]["state"], "unknown");
    assert_eq!(body["lastHeartbeat"], "1234");
    assert_eq!(body["daemonRunning"], false);
    assert_eq!(read_json(&path)["revoked"], true);
    server.join().unwrap();
}
#[tokio::test]
async fn cloud_argv_is_refused_even_with_status_and_hub() {
    let home = tempfile::tempdir().unwrap();
    for flags in [vec!["--status"], vec!["--hub", "https://example.com"], vec!["--replace"], vec![]]
    {
        let result =
            cli(home.path()).args(["host", "join", TOKEN]).args(flags).output().await.unwrap();
        assert_eq!(result.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&result.stderr).contains(TOKEN));
        assert!(!String::from_utf8_lossy(&result.stdout).contains(TOKEN));
    }
}

#[tokio::test]
async fn joined_machine_still_reads_legacy_ticket_from_stdin() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("machine-credential.json");
    std::fs::write(&path, json!({"credential":CREDENTIAL,"machine_id":"machine_test","team_id":"team_test","name":"test","hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"key"}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let ticket = acpmux::pairing::Ticket {
        url: "wss://example.com/acp".to_owned(),
        minter: "minter".to_owned(),
        role: acpmux::pairing::Role::Client,
        expires_ms: acpmux::store::now_ms() - 1000,
        secret: "ab".repeat(32),
    }
    .encode();
    let mut child = cli(home.path()).args(["host", "join"]).stdin(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(ticket.as_bytes()).await.unwrap();
    drop(input);
    let result = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("this ticket expired"));
}

#[tokio::test]
async fn unfinished_pipe_cannot_hold_the_join_lock_forever() {
    let home = tempfile::tempdir().unwrap();
    let mut child = cli(home.path()).args(["host", "join"]).stdin(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(b"cmj_incomplete").await.unwrap();
    let result = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
        .await
        .expect("join stdin must have a fixed deadline")
        .unwrap();
    assert_eq!(result.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&result.stderr).contains("cmj_incomplete"));
}
