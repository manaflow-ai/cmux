//! `git.push` against a local bare remote and a remote that only asks for
//! credentials.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;

use serde_json::{Value, json};

use super::{
    call, commit_all, executable, git, git_output, inherit, ok, refused, repository, session,
    temporary, write,
};
use crate::Mux;

/// A repository with one commit and an empty bare remote named origin.
fn with_remote(name: &str) -> (PathBuf, PathBuf) {
    let repository = repository(name);
    write(&repository, "a.txt", "a\n");
    commit_all(&repository, "base");
    let remote = temporary(&format!("{name}-remote"));
    git(&remote, &["init", "-q", "--bare"]);
    git(&repository, &["remote", "add", "origin", &remote.to_string_lossy()]);
    (repository, remote)
}

fn push(mux: &Arc<Mux>, repository: &Path, fields: Value, key: &str) -> Value {
    call(mux, "git.push", repository, fields, key)
}

#[test]
fn push_creates_the_upstream_and_a_second_push_is_up_to_date() {
    let (repository, remote) = with_remote("push-new");
    let head = git(&repository, &["rev-parse", "HEAD"]);
    let mux = session("push-new");
    let first = ok(&push(&mux, &repository, json!({"expected_head": head}), "k-push"));
    let value = &first["value"];
    assert_eq!(value["remote"], "origin");
    assert_eq!(value["branch"], "main");
    assert_eq!(value["upstream"], "origin/main");
    assert_eq!(value["pushed_commit"], head.as_str());
    assert_eq!((value["created_upstream"].as_bool(), value["up_to_date"].as_bool()), (Some(true), Some(false)));
    assert!(value.get("previous_remote_commit").is_none(), "{value}");
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), head);
    assert_eq!(git(&repository, &["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main");

    let replay = ok(&push(&mux, &repository, json!({"expected_head": head}), "k-push"));
    assert_eq!((replay["replayed"].as_bool(), &replay["value"]), (Some(true), value));

    let again = ok(&push(&mux, &repository, json!({}), "k-push-again"));
    assert_eq!(again["value"]["up_to_date"], true);
    assert_eq!(again["value"]["created_upstream"], false);

    write(&repository, "a.txt", "a2\n");
    let next = commit_all(&repository, "next");
    let forward = ok(&push(&mux, &repository, json!({}), "k-push-forward"));
    assert_eq!(forward["value"]["previous_remote_commit"], head.as_str());
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), next);
}

#[test]
fn push_refuses_a_non_fast_forward_and_never_forces() {
    let (repository, remote) = with_remote("push-nff");
    let mux = session("push-nff");
    ok(&push(&mux, &repository, json!({}), "k-nff-first"));
    let other = temporary("push-nff-other");
    git(&other, &["clone", "-q", &remote.to_string_lossy(), "."]);
    write(&other, "b.txt", "theirs\n");
    let theirs = commit_all(&other, "theirs");
    git(&other, &["push", "-q", "origin", "main"]);
    write(&repository, "a.txt", "ours\n");
    commit_all(&repository, "ours");
    let (reason, extra) = refused(&push(&mux, &repository, json!({}), "k-nff"));
    assert_eq!(reason, "rejected_non_fast_forward");
    assert!(extra["ref_status"].as_str().unwrap().contains("rejected"), "{extra}");
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), theirs);
}

#[test]
fn push_names_a_missing_remote_a_detached_head_and_a_moved_branch() {
    let repository = repository("push-none");
    write(&repository, "a.txt", "a\n");
    let head = commit_all(&repository, "base");
    let mux = session("push-none");
    assert_eq!(refused(&push(&mux, &repository, json!({}), "k-none")).0, "no_remote");
    let url = json!({"remote": "https://example.invalid/repo.git"});
    assert_eq!(refused(&push(&mux, &repository, url, "k-url")).0, "no_remote");
    let stale = json!({"expected_head": "0".repeat(40)});
    assert_eq!(refused(&push(&mux, &repository, stale, "k-stale")).0, "head_moved");
    let bad = push(&mux, &repository, json!({"branch": "main:refs/heads/x"}), "k-bad");
    assert_eq!(bad["error"]["code"], "validation.invalid", "{bad}");
    git(&repository, &["checkout", "-q", "--detach", &head]);
    assert_eq!(refused(&push(&mux, &repository, json!({}), "k-detached")).0, "detached_head");
}

#[test]
fn push_reports_a_remote_hook_rejection_with_its_message() {
    let (repository, remote) = with_remote("push-hook");
    let script = "#!/bin/sh\necho 'main is protected here' >&2\nexit 1\n";
    executable(&remote.join("hooks/pre-receive"), script);
    let mux = session("push-hook");
    let (reason, extra) = refused(&push(&mux, &repository, json!({}), "k-hook"));
    assert_eq!(reason, "rejected_by_remote");
    assert!(extra["output"].as_str().unwrap().contains("main is protected here"), "{extra}");
    assert!(git_output(&remote, &["rev-parse", "--verify", "refs/heads/main"]).status.code() != Some(0));
}

#[test]
fn push_reports_a_local_pre_push_hook() {
    let (repository, remote) = with_remote("push-pre-push");
    executable(&repository.join(".git/hooks/pre-push"), "#!/bin/sh\necho 'tests failed' >&2\nexit 1\n");
    let mux = session("push-pre-push");
    let (reason, extra) = refused(&push(&mux, &repository, json!({}), "k-pre-push"));
    assert_eq!(reason, "hook_failed");
    assert!(extra["output"].as_str().unwrap().contains("tests failed"), "{extra}");
    assert!(git_output(&remote, &["rev-parse", "--verify", "refs/heads/main"]).status.code() != Some(0));
}

/// A remote that asks for credentials: git never prompts and never runs an
/// askpass program the daemon inherited.
#[test]
fn push_never_prompts_for_credentials() {
    let (repository, _) = with_remote("push-auth");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { break };
            let mut request = Vec::new();
            let mut chunk = [0_u8; 4096];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                match stream.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => request.extend_from_slice(&chunk[..read]),
                }
            }
            let _ = stream.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"cmux\"\r\n\
                  Content-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    });
    let url = format!("http://127.0.0.1:{port}/repo.git");
    git(&repository, &["remote", "set-url", "origin", &url]);
    let marker = temporary("push-auth-marker").join("asked");
    let askpass = temporary("push-auth-askpass").join("askpass");
    executable(&askpass, &format!("#!/bin/sh\ntouch '{}'\necho secret\n", marker.display()));
    let askpass = askpass.to_string_lossy().into_owned();
    inherit(&[
        ("GIT_ASKPASS", Some(askpass.as_str())),
        ("SSH_ASKPASS", Some(askpass.as_str())),
        ("DISPLAY", Some(":0")),
    ]);
    let mux = session("push-auth");
    let (reason, extra) = refused(&push(&mux, &repository, json!({}), "k-auth"));
    assert_eq!(reason, "auth_failed", "{extra}");
    assert!(!marker.exists(), "an inherited askpass program ran");
}

#[test]
fn push_names_an_unreachable_remote() {
    let (repository, _) = with_remote("push-network");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let url = format!("http://127.0.0.1:{port}/repo.git");
    git(&repository, &["remote", "set-url", "origin", &url]);
    let mux = session("push-network");
    let (reason, extra) = refused(&push(&mux, &repository, json!({}), "k-network"));
    assert_eq!(reason, "network_failed", "{extra}");
}
