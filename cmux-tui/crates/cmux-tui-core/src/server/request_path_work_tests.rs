//! Request-path moves outside server/ and mux/ (p02-threads 231): a git
//! request and `machine-listening-tcp` run their child processes on a work
//! item, so the request thread answers at once and never waits on git, ss or
//! netstat (Chrome posts blocking work to a MayBlock task runner,
//! base/task/task_traits.h; base/threading/scoped_blocking_call.h checks it).
//!
//! Each request runs on a thread that disallows blocking, in panic mode (as
//! `CMUX_DAEMON_BLOCKING=panic` sets it for a whole daemon), so a child
//! process left on the request thread fails the test at its call site.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::SurfaceOptions;
use cmux_threads::blocking::{BlockingMode, set_mode, with_blocking_disallowed};
use serde_json::{Value, json};

use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, Mux, OutboundItem, QueuedSink,
    Request, handle_request, handle_resource_connection_message,
};

fn scratch(name: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let dir = std::env::temp_dir().join(format!(
        "cmux-request-path-work-{name}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn git(directory: &Path, arguments: &[&str]) -> String {
    let output = cmux_process::Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {arguments:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A repository on branch `main` with one commit and an `origin` (a bare
/// repository next to it); returns the repository and the remote.
fn repository_with_remote(root: &Path) -> (PathBuf, PathBuf) {
    let remote = root.join("remote.git");
    let repo = root.join("repo");
    std::fs::create_dir_all(&remote).unwrap();
    std::fs::create_dir_all(&repo).unwrap();
    git(&remote, &["init", "--quiet", "--bare"]);
    git(&repo, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "."]);
    git(
        &repo,
        &["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "one"],
    );
    git(&repo, &["remote", "add", "origin", &remote.to_string_lossy()]);
    (repo, remote)
}

/// A local client of `mux` whose replies queue in the returned outbound.
fn client(mux: &Arc<Mux>) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    (client, writer, outbound)
}

/// Runs `f` with `mux` on a new thread that disallows blocking, in panic
/// mode; a blocking call in `f` panics there and fails the test. The handle
/// is dropped after the disallowed scope (a last handle's drop joins the
/// daemon's threads, which a request thread never does).
fn on_request_thread<R: Send + 'static>(
    mux: &Arc<Mux>,
    f: impl FnOnce(&Arc<Mux>) -> R + Send + 'static,
) -> R {
    let mux = Arc::clone(mux);
    set_mode(BlockingMode::Panic);
    let thread = std::thread::spawn(move || {
        let value = with_blocking_disallowed(|| f(&mux));
        drop(mux);
        value
    });
    match thread.join() {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

/// The next reply `outbound` carries, waiting for a work item's answer.
fn next_reply(outbound: &BoundedOutbound) -> Value {
    loop {
        match outbound.recv() {
            Some(OutboundItem::Text(text)) => {
                return serde_json::from_str(&text.to_string()).unwrap();
            }
            Some(OutboundItem::Flush(flushed)) => {
                let _ = flushed.send(());
            }
            None => panic!("the connection closed before an answer"),
        }
    }
}

/// `git.push` from a request thread: git runs on a work item and the reply
/// arrives from there with the pushed commit.
#[test]
fn git_push_runs_off_the_request_thread() {
    let root = scratch("push");
    let (repo, remote) = repository_with_remote(&root);
    let tip = git(&repo, &["rev-parse", "HEAD"]);
    let mux = Mux::new("request-path-work-push", SurfaceOptions::default());
    let (client, writer, outbound) = client(&mux);
    let line = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "push-1",
        "operation": "git.push",
        "params": {"machine": "current", "session": "current", "path": repo.to_string_lossy()},
        "idempotency_key": "request-path-work-push-1",
    })
    .to_string();
    let request = crate::resource_router::parse_resource_request(&line).expect("a valid git.push");

    let kept_open = on_request_thread(&mux, move |mux| {
        handle_resource_connection_message(mux, client, request, &writer)
    });

    assert!(kept_open);
    let reply = next_reply(&outbound);
    assert_eq!(reply["id"], json!("push-1"), "{reply}");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["result"]["pushed_commit"], json!(tip), "{reply}");
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), tip);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// A git read from a request thread answers from its work item too.
#[test]
fn git_status_runs_off_the_request_thread() {
    let root = scratch("status");
    let (repo, _) = repository_with_remote(&root);
    let mux = Mux::new("request-path-work-status", SurfaceOptions::default());
    let (client, writer, outbound) = client(&mux);
    let line = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "status-1",
        "operation": "git.status",
        "params": {"machine": "current", "session": "current", "path": repo.to_string_lossy()},
    })
    .to_string();
    let request =
        crate::resource_router::parse_resource_request(&line).expect("a valid git.status");

    on_request_thread(&mux, move |mux| {
        handle_resource_connection_message(mux, client, request, &writer)
    });

    let reply = next_reply(&outbound);
    assert_eq!(reply["id"], json!("status-1"), "{reply}");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["result"]["branch"], json!("main"), "{reply}");
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// `machine-listening-tcp` runs ss or netstat on a work item; the reply (the
/// listing, or why there is none) still names the request.
#[test]
fn machine_listening_tcp_runs_off_the_request_thread() {
    let mux = Mux::new("request-path-work-tcp", SurfaceOptions::default());
    let (client, writer, outbound) = client(&mux);
    let request = Request { id: Some(json!(7)), cmd: Command::MachineListeningTcp };

    assert!(on_request_thread(&mux, move |mux| handle_request(mux, client, request, &writer)));

    let reply = next_reply(&outbound);
    assert_eq!(reply["id"], json!(7), "{reply}");
    assert!(reply["ok"] == json!(false) || reply["data"]["stdout"].is_string(), "{reply}");
    mux.shutdown();
}
