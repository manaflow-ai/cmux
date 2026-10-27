//! Request-path moves outside server/ and mux/ (p02-threads 231): a git
//! request and `machine-listening-tcp` run their child processes on a work
//! item, so the request thread answers at once and never waits on git, ss or
//! netstat (Chrome posts blocking work to a MayBlock task runner,
//! base/task/task_traits.h; base/threading/scoped_blocking_call.h checks it).
//!
//! Each request runs on a thread that disallows blocking, in panic mode (as
//! `CMUX_DAEMON_BLOCKING=panic` sets it for a whole daemon), so a child
//! process left on the request thread fails the test at its call site.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::SurfaceOptions;
use crate::resource_router::ParsedResourceRequest;
use cmux_threads::blocking::{BlockingMode, with_blocking_disallowed, with_mode};
use cmux_threads::work::{Lane, LaneStats, Priority, Shutdown};
use serde_json::{Value, json};

use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, Mux, OutboundItem, QueuedSink,
    Request, RequestSpan, handle_request, handle_resource_connection_message,
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
/// mode for that thread only (`with_mode`, so the other tests of this
/// binary keep the process mode); a blocking call in `f` panics there and
/// fails the test. The handle
/// is dropped after the disallowed scope (a last handle's drop joins the
/// daemon's threads, which a request thread never does).
fn on_request_thread<R: Send + 'static>(
    mux: &Arc<Mux>,
    f: impl FnOnce(&Arc<Mux>) -> R + Send + 'static,
) -> R {
    let mux = Arc::clone(mux);
    let thread = std::thread::spawn(move || {
        let value = with_mode(BlockingMode::Panic, || with_blocking_disallowed(|| f(&mux)));
        drop(mux);
        value
    });
    match thread.join() {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

/// Dispatches `request` with a span that starts now.
fn handle_resource_connection_message_now(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let mut span = RequestSpan::for_resource(mux.request_stats(), request.envelope.operation);
    handle_resource_connection_message(mux, client, request, writer, &mut span)
}

/// The next reply `outbound` carries, waiting for a work item's answer.
fn next_reply(outbound: &BoundedOutbound) -> Value {
    loop {
        match outbound.recv() {
            Some(
                OutboundItem::Text(text)
                | OutboundItem::Frame(_, text)
                | OutboundItem::Chunk { text, .. },
            ) => {
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
        handle_resource_connection_message_now(mux, client, request, &writer)
    });

    assert!(kept_open);
    let reply = next_reply(&outbound);
    assert_eq!(reply["id"], json!("push-1"), "{reply}");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["result"]["value"]["pushed_commit"], json!(tip), "{reply}");
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
        handle_resource_connection_message_now(mux, client, request, &writer)
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

const WAIT: Duration = Duration::from_secs(20);

/// A v2 request of `operation` on the repository at `path`.
fn v2(
    id: &str,
    operation: &str,
    path: &Path,
    params: Value,
    key: Option<&str>,
) -> ParsedResourceRequest {
    let mut fields =
        json!({"machine": "current", "session": "current", "path": path.to_string_lossy()});
    if let (Some(fields), Value::Object(params)) = (fields.as_object_mut(), params) {
        fields.extend(params);
    }
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": operation,
        "params": fields,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    crate::resource_router::parse_resource_request(&envelope.to_string()).expect("a valid request")
}

/// Installs `body` as the repository's `name` hook.
fn hook(repo: &Path, name: &str, body: &str) {
    let path = repo.join(".git/hooks").join(name);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn system_lane(mux: &Mux) -> LaneStats {
    mux.work.stats().into_iter().find(|stats| stats.lane == Lane::System).unwrap()
}

fn until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Seven pushes stalled in a pre-push hook (one runs it, six wait on the
/// repository's push lock) hold no System slot: a git.status from another
/// client answers at once, other System work still runs, and shutdown
/// does not wait for them. Before `will_block` they filled the lane.
#[test]
fn stalled_pushes_hold_no_system_slot_and_never_delay_shutdown() {
    const PUSHES: usize = 7;
    let root = scratch("stalled");
    let (repo, _) = repository_with_remote(&root);
    let (started, release) = (root.join("hook-started"), root.join("release"));
    let wait_for_release = format!(
        "touch '{}'\nwhile [ ! -e '{}' ]; do sleep 0.05; done",
        started.display(),
        release.display()
    );
    hook(&repo, "pre-push", &wait_for_release);
    let mux = Mux::new("request-path-work-stalled", SurfaceOptions::default());
    let mut pushes = Vec::new();
    for n in 0..PUSHES {
        let (client, writer, outbound) = client(&mux);
        let key = format!("request-path-work-stalled-{n}");
        let request = v2(&format!("push-{n}"), "git.push", &repo, json!({}), Some(&key));
        assert!(handle_resource_connection_message_now(&mux, client, request, &writer));
        pushes.push(outbound);
    }
    until("every push to wait outside the lane's count", || {
        started.exists() && system_lane(&mux).blocked == PUSHES
    });

    let (client, writer, outbound) = client(&mux);
    let asked = Instant::now();
    let status = v2("status-1", "git.status", &repo, json!({}), None);
    assert!(handle_resource_connection_message_now(&mux, client, status, &writer));
    let reply = next_reply(&outbound);
    assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!("status-1"), json!(true)));
    assert!(asked.elapsed() < Duration::from_secs(5), "status took {:?}", asked.elapsed());
    let probe =
        mux.work.run(Priority::UserVisible, Lane::System, Shutdown::ContinueOnShutdown, || "ran");
    until("a UserVisible System item to run", || probe.try_wait().is_some());

    let began = Instant::now();
    let report = mux.work.shutdown_until(began + Duration::from_secs(2));
    assert_eq!(report.unfinished, 0, "shutdown waits for no git item");
    assert!(began.elapsed() < Duration::from_millis(500), "shutdown took {:?}", began.elapsed());

    std::fs::write(&release, "").unwrap();
    let replies: Vec<Value> = pushes.iter().map(|outbound| next_reply(outbound)).collect();
    let ids: Vec<Value> = replies.iter().map(|reply| reply["id"].clone()).collect();
    assert_eq!(ids, (0..PUSHES).map(|n| json!(format!("push-{n}"))).collect::<Vec<_>>());
    assert!(replies.iter().any(|reply| reply["ok"] == json!(true)), "{replies:?}");
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// One connection's git.commit then git.push, sent back to back: the push
/// runs after the commit and pushes the new commit, as on the connection's
/// own thread before. A slow pre-commit hook gives a push that ran beside
/// the commit time to read the old HEAD.
#[test]
fn a_connections_commit_then_push_pushes_the_new_commit() {
    let root = scratch("commit-push");
    let (repo, remote) = repository_with_remote(&root);
    git(&repo, &["config", "user.name", "t"]);
    git(&repo, &["config", "user.email", "t@example.com"]);
    let before = git(&repo, &["rev-parse", "HEAD"]);
    hook(&repo, "pre-commit", "sleep 1");
    std::fs::write(repo.join("a.txt"), "two\n").unwrap();
    let mux = Mux::new("request-path-work-commit-push", SurfaceOptions::default());
    let (client, writer, outbound) = client(&mux);
    let commit = v2(
        "commit-1",
        "git.commit",
        &repo,
        json!({"message": "two", "all": true}),
        Some("request-path-work-commit-1"),
    );
    let push = v2("push-2", "git.push", &repo, json!({}), Some("request-path-work-push-2"));

    assert!(handle_resource_connection_message_now(&mux, client, commit, &writer));
    assert!(handle_resource_connection_message_now(&mux, client, push, &writer));

    let committed = next_reply(&outbound);
    assert_eq!(committed["id"], json!("commit-1"), "{committed}");
    assert_eq!(committed["ok"], json!(true), "{committed}");
    let pushed = next_reply(&outbound);
    assert_eq!(pushed["id"], json!("push-2"), "{pushed}");
    let head = git(&repo, &["rev-parse", "HEAD"]);
    assert_ne!(head, before, "the commit moved HEAD");
    assert_eq!(pushed["result"]["value"]["pushed_commit"], json!(head), "{pushed}");
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), head);
    until("the sequence to end", || mux.git_sequences.active() == 0);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
