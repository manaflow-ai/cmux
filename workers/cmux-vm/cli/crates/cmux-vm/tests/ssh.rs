//! `ssh VM` revokes the client session it minted on every way out: ssh's own
//! exit, a failure, and a SIGHUP or SIGTERM sent to cmux-vm while ssh runs.
//! SIGINT and SIGQUIT belong to ssh (it gets them from the terminal) and do
//! not end cmux-vm. A shell script named by `CMUX_VM_SSH` stands in for ssh;
//! it signals its parent, this test process, the way a terminal or a process
//! manager would. In its own test binary so a regression (a signal that kills
//! the process) cannot take other tests down with it.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;

use cmux_vm::exit;
use serde_json::json;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";
const SESSION: &str = "vcs_0123456789abcdefghjkmnpqrs";
const KEY: &str = "cmuxvm_sk_test";

struct Output {
    code: i32,
    stderr: String,
}

/// A fake ssh: a shell script with `body`, in a fresh directory.
fn fake_ssh(name: &str, body: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-vm-ssh-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("ssh");
    std::fs::write(&script, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

/// Mounts the session create and expects exactly one revoke.
async fn mount_session(server: &MockServer) {
    let session = json!({
        "id": SESSION, "vmId": VM_ID, "token": "secret-session-token",
        "linuxUser": "dev", "ssh": {"host": "ssh.example", "user": "p1+dev"},
        "createdAt": "2026-10-25T00:00:00Z"
    });
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .respond_with(ResponseTemplate::new(201).set_body_json(&session))
        .expect(1)
        .mount(server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions/{SESSION}")))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(server)
        .await;
}

async fn ssh(server: &MockServer, program: &std::path::Path) -> Output {
    let env = [
        ("CMUX_VM_API_KEY", KEY.to_owned()),
        ("CMUX_VM_BASE_URL", server.uri()),
        ("CMUX_VM_SSH", program.to_str().unwrap().to_owned()),
    ];
    let lookup = move |name: &str| env.iter().find(|(k, _)| *k == name).map(|(_, v)| v.clone());
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let code = cmux_vm::run(
        ["cmux-vm", "ssh", VM_ID],
        &lookup,
        &mut cmux_vm::NoPrompt,
        &mut stdout,
        &mut stderr,
    )
    .await;
    Output {
        code,
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    }
}

/// One test, run in order: every signal listener in the process hears every
/// signal, so these scenarios must not overlap.
#[tokio::test(flavor = "multi_thread")]
async fn the_session_is_revoked_on_every_way_out_and_interrupts_belong_to_ssh() {
    // ssh's own exit code passes through.
    let server = MockServer::start().await;
    mount_session(&server).await;
    let out = ssh(&server, &fake_ssh("exit", "exit 3")).await;
    assert_eq!(out.code, 3, "{}", out.stderr);
    assert!(
        !out.stderr.contains("secret-session-token"),
        "{}",
        out.stderr
    );
    server.verify().await;

    // Ctrl-C and Ctrl-\ at the terminal reach the whole process group: ssh
    // handles them and cmux-vm keeps waiting for it.
    let server = MockServer::start().await;
    mount_session(&server).await;
    let program = fake_ssh("interrupt", "kill -INT $PPID\nkill -QUIT $PPID\nexit 0");
    let out = ssh(&server, &program).await;
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    server.verify().await;

    // cmux-vm is told to stop while ssh keeps running: the session is revoked
    // first, then ssh is stopped.
    for (signal, number) in [("TERM", 15), ("HUP", 1)] {
        let server = MockServer::start().await;
        mount_session(&server).await;
        let program = fake_ssh(
            &format!("signal-{signal}"),
            &format!("kill -{signal} $PPID\nexec sleep 30"),
        );
        let out = ssh(&server, &program).await;
        assert_eq!(out.code, 128 + number, "SIG{signal}: {}", out.stderr);
        assert!(
            out.stderr.contains("was revoked"),
            "SIG{signal}: {}",
            out.stderr
        );
        server.verify().await;
    }

    // The final revoke hangs: cmux-vm gives up after its bound (10 s, far
    // below the 120 s API timeout) and prints the exact revoke command.
    let server = MockServer::start().await;
    let session = json!({
        "id": SESSION, "vmId": VM_ID, "token": "secret-session-token",
        "linuxUser": "dev", "ssh": {"host": "ssh.example", "user": "p1+dev"},
        "createdAt": "2026-10-25T00:00:00Z"
    });
    Mock::given(method("POST"))
        .and(path(format!("/v1/vms/{VM_ID}/client-session")))
        .respond_with(ResponseTemplate::new(201).set_body_json(&session))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path(format!("/v1/vms/{VM_ID}/client-sessions/{SESSION}")))
        .respond_with(ResponseTemplate::new(204).set_delay(std::time::Duration::from_secs(60)))
        .mount(&server)
        .await;
    let started = std::time::Instant::now();
    let out = ssh(&server, &fake_ssh("slow-revoke", "exit 0")).await;
    let elapsed = started.elapsed();
    assert!(elapsed < std::time::Duration::from_secs(30), "{elapsed:?}");
    assert_eq!(out.code, exit::OK, "{}", out.stderr);
    assert!(
        out.stderr
            .contains(&format!("cmux-vm session revoke {VM_ID} {SESSION} --yes")),
        "{}",
        out.stderr
    );
}
