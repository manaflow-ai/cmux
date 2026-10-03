//! `git.commit` and `git.push` through the catalog dispatcher, against real
//! temporary repositories, a local bare remote and a durable session. The
//! runner's inherited environment is a temporary home, so the machine's git
//! config never reaches a test.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::commit::seams::LOSE_REPLY;
use super::user_run::seams::INHERITED;
use crate::resource_router::handle_resource_message;
use crate::{Mux, SurfaceOptions};

#[path = "push_tests.rs"]
mod push;

pub(super) fn temporary(name: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let folder =
        std::env::temp_dir().join(format!("cmux-gitw-{name}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&folder).unwrap();
    fs::canonicalize(folder).unwrap()
}

/// The runner sees a fresh home and no `EMAIL`, plus `extra`, as if the
/// daemon had inherited them.
pub(super) fn inherit(extra: &[(&str, Option<&str>)]) {
    let home = temporary("home");
    let mut overrides = vec![
        ("HOME".to_string(), Some(home.to_string_lossy().into_owned())),
        ("XDG_CONFIG_HOME".to_string(), Some(home.join("xdg").to_string_lossy().into_owned())),
        ("EMAIL".to_string(), None),
    ];
    for (name, value) in extra {
        overrides.push(((*name).to_string(), value.map(str::to_string)));
    }
    INHERITED.with(|inherited| *inherited.borrow_mut() = overrides);
}

/// A fresh repository on `main` with a local identity, and the runner's
/// environment reset.
pub(super) fn repository(name: &str) -> PathBuf {
    inherit(&[]);
    let folder = temporary(name);
    git(&folder, &["init", "-q", "-b", "main"]);
    git(&folder, &["config", "user.name", "cmux test"]);
    git(&folder, &["config", "user.email", "test@example.invalid"]);
    git(&folder, &["config", "commit.gpgsign", "false"]);
    folder
}

/// Runs the setup's git without the machine's git config; trimmed stdout.
pub(super) fn git(directory: &Path, args: &[&str]) -> String {
    let output = git_output(directory, args);
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

pub(super) fn git_output(directory: &Path, args: &[&str]) -> std::process::Output {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let home = std::env::temp_dir().join("cmux-gitw-setup-home");
    fs::create_dir_all(&home).unwrap();
    command
        .env("HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(["-c", "user.name=cmux setup", "-c", "user.email=setup@example.invalid"])
        .args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"])
        .args(args)
        .current_dir(directory)
        .output()
        .unwrap()
}

pub(super) fn write(directory: &Path, path: &str, contents: &str) {
    let path = directory.join(path);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

pub(super) fn executable(path: &Path, script: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, script).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

pub(super) fn commit_all(directory: &Path, message: &str) -> String {
    git(directory, &["add", "-A"]);
    git(directory, &["commit", "-q", "-m", message]);
    git(directory, &["rev-parse", "HEAD"])
}

/// A session with durable state, as the daemon runs one.
pub(super) fn session(name: &str) -> Arc<Mux> {
    let root = temporary(&format!("state-{name}"));
    Mux::open_persistent(format!("gitw-{name}"), SurfaceOptions::default(), &root).unwrap()
}

pub(super) fn call(
    mux: &Arc<Mux>,
    operation: &str,
    repository: &Path,
    fields: Value,
    key: &str,
) -> Value {
    let mut params = fields;
    params["path"] = json!(repository.to_string_lossy());
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{}", operation.replace('.', "-")),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    handle_resource_message(mux, &message.to_string()).unwrap()
}

pub(super) fn ok(envelope: &Value) -> Value {
    assert_eq!(envelope["ok"], true, "{envelope}");
    envelope["result"].clone()
}

/// `operation.failed`'s machine reason and its `extra`.
pub(super) fn refused(envelope: &Value) -> (String, Value) {
    assert_eq!(envelope["ok"], false, "{envelope}");
    assert_eq!(envelope["error"]["code"], "operation.failed", "{envelope}");
    let details = &envelope["error"]["details"];
    assert!(details["extra"]["message"].is_string(), "{envelope}");
    (details["reason"].as_str().unwrap().to_string(), details["extra"].clone())
}

fn error_code(envelope: &Value) -> String {
    assert_eq!(envelope["ok"], false, "{envelope}");
    envelope["error"]["code"].as_str().unwrap().to_string()
}

fn commit(mux: &Arc<Mux>, repository: &Path, fields: Value, key: &str) -> Value {
    call(mux, "git.commit", repository, fields, key)
}

fn committed_files(repository: &Path, revision: &str) -> Vec<String> {
    let listing =
        git(repository, &["show", "--name-only", "--format=", "--end-of-options", revision]);
    let mut files: Vec<String> = listing.lines().map(str::to_string).collect();
    files.sort();
    files
}

#[test]
fn commit_takes_the_index_as_it_is_and_replays_its_key() {
    let repository = repository("staged");
    let base = {
        write(&repository, "a.txt", "one\n");
        write(&repository, "b.txt", "one\n");
        commit_all(&repository, "base")
    };
    write(&repository, "a.txt", "one\ntwo\nthree\n");
    write(&repository, "b.txt", "changed\n");
    git(&repository, &["add", "a.txt"]);
    // The daemon's own git state never reaches the user's git.
    inherit(&[("GIT_DIR", Some("/nonexistent")), ("GIT_INDEX_FILE", Some("/nonexistent/index"))]);
    let mux = session("staged");
    let fields = json!({"message": "Add lines\n\nBody", "expected_head": base});
    let first = ok(&commit(&mux, &repository, fields.clone(), "k-staged"));
    let value = &first["value"];
    let head = git(&repository, &["rev-parse", "HEAD"]);
    assert_eq!(first["replayed"], false);
    assert_eq!(value["commit"], head.as_str());
    assert_eq!(value["parent"], base.as_str());
    assert_eq!(value["branch"], "main");
    assert_eq!(value["summary"], "Add lines");
    assert_eq!(value["root"], repository.to_string_lossy().as_ref());
    assert_eq!((value["files_changed"].as_u64(), value["additions"].as_u64()), (Some(1), Some(2)));
    assert_eq!(committed_files(&repository, "HEAD"), ["a.txt"]);
    assert_eq!(git(&repository, &["diff", "--name-only"]), "b.txt");

    let replay = ok(&commit(&mux, &repository, fields, "k-staged"));
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], first["value"]);
    assert_eq!(git(&repository, &["rev-parse", "HEAD"]), head);

    let other = json!({"message": "Something else"});
    assert_eq!(error_code(&commit(&mux, &repository, other, "k-staged")), "idempotency.conflict");
}

#[test]
fn commit_paths_commits_exactly_those_and_keeps_other_staged_changes() {
    let repository = repository("paths");
    write(&repository, "a.txt", "a\n");
    write(&repository, "b.txt", "b\n");
    write(&repository, "gone.txt", "gone\n");
    commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    write(&repository, "b.txt", "b2\n");
    git(&repository, &["add", "b.txt"]);
    write(&repository, "dir/new*.txt", "new\n");
    write(&repository, "dir/newer.txt", "literal paths never glob\n");
    fs::remove_file(repository.join("gone.txt")).unwrap();
    let mux = session("paths");
    let fields = json!({"message": "Pick", "paths": ["a.txt", "dir/new*.txt", "gone.txt"]});
    ok(&commit(&mux, &repository, fields, "k-paths"));
    assert_eq!(committed_files(&repository, "HEAD"), ["a.txt", "dir/new*.txt", "gone.txt"]);
    assert_eq!(git(&repository, &["diff", "--cached", "--name-only"]), "b.txt");
    assert_eq!(git(&repository, &["ls-files", "--others"]), "dir/newer.txt");

    for paths in [json!(["../outside"]), json!(["/abs"]), json!([".git/config"]), json!(["./a"])] {
        let envelope = commit(&mux, &repository, json!({"message": "m", "paths": paths}), "k-bad");
        assert_eq!(error_code(&envelope), "validation.invalid", "{paths}");
    }
    let both = json!({"message": "m", "paths": ["a.txt"], "all": true});
    assert_eq!(error_code(&commit(&mux, &repository, both, "k-both")), "validation.invalid");
    let missing = json!({"message": "m", "paths": ["nowhere.txt"]});
    assert_eq!(refused(&commit(&mux, &repository, missing, "k-missing")).0, "path_not_found");
}

#[test]
fn commit_all_takes_tracked_changes_and_untracked_files_only_when_asked() {
    let repository = repository("all");
    write(&repository, "a.txt", "a\n");
    commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    write(&repository, "new.txt", "new\n");
    write(&repository, ".gitignore", "ignored.txt\n");
    write(&repository, "ignored.txt", "secret\n");
    let mux = session("all");
    ok(&commit(&mux, &repository, json!({"message": "Tracked", "all": true}), "k-all"));
    assert_eq!(committed_files(&repository, "HEAD"), ["a.txt"]);
    let fields = json!({"message": "Untracked", "all": true, "include_untracked": true});
    ok(&commit(&mux, &repository, fields, "k-untracked"));
    assert_eq!(committed_files(&repository, "HEAD"), [".gitignore", "new.txt"]);
    let lone = json!({"message": "m", "include_untracked": true});
    assert_eq!(error_code(&commit(&mux, &repository, lone, "k-lone")), "validation.invalid");
}

#[test]
fn commit_refuses_nothing_head_moved_and_merges_in_progress() {
    let repository = repository("refusals");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    let mux = session("refusals");
    let (reason, extra) = refused(&commit(&mux, &repository, json!({"message": "m"}), "k-none"));
    assert_eq!(reason, "nothing_to_commit");
    assert!(extra["output"].as_str().unwrap().contains("nothing"), "{extra}");

    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let stale = json!({"message": "m", "expected_head": "0".repeat(40)});
    let (reason, extra) = refused(&commit(&mux, &repository, stale, "k-stale"));
    assert_eq!(reason, "head_moved");
    assert_eq!(extra["head"], base.as_str());

    fs::write(repository.join(".git/MERGE_HEAD"), format!("{base}\n")).unwrap();
    let (reason, extra) = refused(&commit(&mux, &repository, json!({"message": "m"}), "k-merge"));
    assert_eq!((reason.as_str(), extra["state"].as_str()), ("merge_in_progress", Some("merge")));
    fs::remove_file(repository.join(".git/MERGE_HEAD")).unwrap();
    assert_eq!(git(&repository, &["rev-parse", "HEAD"]), base);
}

#[test]
fn commit_keeps_comment_lines_and_amends() {
    let repository = repository("message");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("message");
    let fields = json!({"message": "#123 fix\n\n# not a comment\n"});
    let first = ok(&commit(&mux, &repository, fields, "k-hash"));
    assert_eq!(first["value"]["summary"], "#123 fix");
    assert_eq!(git(&repository, &["log", "-1", "--format=%B"]), "#123 fix\n\n# not a comment");
    let amend = json!({"message": "Reworded", "amend": true});
    let amended = ok(&commit(&mux, &repository, amend, "k-amend"));
    assert_eq!(amended["value"]["parent"], base.as_str());
    assert_ne!(amended["value"]["commit"], first["value"]["commit"]);
    assert_eq!(git(&repository, &["log", "-1", "--format=%s"]), "Reworded");
}

#[test]
fn commit_recovers_a_lost_reply_without_committing_twice() {
    let repository = repository("lost");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("lost");
    let fields = json!({"message": "Lost reply", "expected_head": base});
    LOSE_REPLY.with(|lose| lose.set(true));
    assert_eq!(refused(&commit(&mux, &repository, fields.clone(), "k-lost")).0, "store_failed");
    let made = git(&repository, &["rev-parse", "HEAD"]);
    assert_ne!(made, base);
    // The retry finds HEAD past expected_head and reports the first commit.
    let retry = ok(&commit(&mux, &repository, fields.clone(), "k-lost"));
    assert_eq!(retry["replayed"], true);
    assert_eq!(retry["value"]["commit"], made.as_str());
    assert_eq!(git(&repository, &["rev-parse", "HEAD^"]), base);
    assert_eq!(ok(&commit(&mux, &repository, fields, "k-lost"))["value"]["commit"], made.as_str());
}

#[test]
fn commit_never_takes_a_terminal_commit_for_its_own() {
    let repository = repository("terminal");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    commit_all(&repository, "Same message");
    write(&repository, "a.txt", "a3\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("terminal");
    let fields = json!({"message": "Same message", "expected_head": base});
    assert_eq!(refused(&commit(&mux, &repository, fields, "k-terminal")).0, "head_moved");
}

#[test]
fn commit_reports_a_failing_hook_and_no_verify_skips_it() {
    let repository = repository("hook");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    let script = "#!/bin/sh\necho 'lint: a.txt has a problem' >&2\nexit 1\n";
    executable(&repository.join(".git/hooks/pre-commit"), script);
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("hook");
    let (reason, extra) = refused(&commit(&mux, &repository, json!({"message": "m"}), "k-hook"));
    assert_eq!(reason, "hook_failed");
    assert!(extra["output"].as_str().unwrap().contains("lint: a.txt has a problem"), "{extra}");
    assert_eq!(git(&repository, &["rev-parse", "HEAD"]), base);
    let skipped = json!({"message": "m", "no_verify": true});
    ok(&commit(&mux, &repository, skipped, "k-no-verify"));
    assert_eq!(git(&repository, &["rev-parse", "HEAD^"]), base);
}

#[test]
fn commit_cuts_hook_output_at_16_kib() {
    let repository = repository("long-hook");
    write(&repository, "a.txt", "a\n");
    commit_all(&repository, "base");
    let script = "#!/bin/sh\ni=0\nwhile [ $i -lt 4000 ]; do echo 'xxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done\nexit 1\n";
    executable(&repository.join(".git/hooks/pre-commit"), script);
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("long-hook");
    let (reason, extra) = refused(&commit(&mux, &repository, json!({"message": "m"}), "k-long"));
    assert_eq!(reason, "hook_failed");
    let output = extra["output"].as_str().unwrap();
    assert!(output.len() <= 16 * 1024 && output.len() > 8 * 1024, "{}", output.len());
}

#[test]
fn commit_names_a_missing_identity() {
    let repository = repository("identity");
    git(&repository, &["config", "--unset", "user.name"]);
    git(&repository, &["config", "--unset", "user.email"]);
    git(&repository, &["config", "user.useConfigOnly", "true"]);
    write(&repository, "a.txt", "a\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("identity");
    let envelope = commit(&mux, &repository, json!({"message": "m"}), "k-identity");
    assert_eq!(refused(&envelope).0, "identity_missing");
}
