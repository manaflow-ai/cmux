//! `git.checkpoint.*` through the catalog dispatcher, against real
//! temporary repositories and a durable session.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::resource_router::handle_resource_message;
use crate::{Mux, SurfaceOptions};

#[path = "compare_tests.rs"]
mod compare;

fn temporary(name: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let folder =
        std::env::temp_dir().join(format!("cmux-ckpt-{name}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&folder).unwrap();
    fs::canonicalize(folder).unwrap()
}

/// A fresh repository on `main`.
fn repository(name: &str) -> PathBuf {
    let folder = temporary(name);
    git(&folder, &["init", "-q", "-b", "main"]);
    folder
}

/// Runs the setup's git without the machine's git config; raw stdout.
fn git_bytes(directory: &Path, args: &[&str]) -> Vec<u8> {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let home = std::env::temp_dir().join("cmux-ckpt-home");
    fs::create_dir_all(&home).unwrap();
    command.env("HOME", home).env("GIT_CONFIG_NOSYSTEM", "1");
    let output = command
        .args(["-c", "user.name=cmux test", "-c", "user.email=test@example.invalid"])
        .args(["-c", "commit.gpgsign=false", "--no-optional-locks"])
        .args(args)
        .current_dir(directory)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    output.stdout
}

fn git(directory: &Path, args: &[&str]) -> String {
    String::from_utf8(git_bytes(directory, args)).unwrap().trim().to_string()
}

fn write(directory: &Path, path: &str, contents: &[u8]) {
    let path = directory.join(path);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

fn commit_all(directory: &Path, message: &str) -> String {
    git(directory, &["add", "-A"]);
    git(directory, &["commit", "-q", "-m", message]);
    git(directory, &["rev-parse", "HEAD"])
}

/// A session with durable state, as the daemon runs one.
fn session(name: &str) -> (Arc<Mux>, PathBuf) {
    let root = temporary(&format!("state-{name}"));
    let mux =
        Mux::open_persistent(format!("ckpt-{name}"), SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

fn call(mux: &Arc<Mux>, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{}", operation.replace('.', "-")),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        message["idempotency_key"] = json!(key);
    }
    handle_resource_message(mux, &message.to_string()).unwrap()
}

fn ok(envelope: Value) -> Value {
    assert_eq!(envelope["ok"], true, "{envelope}");
    envelope["result"].clone()
}

fn failure(envelope: &Value) -> (String, Value) {
    assert_eq!(envelope["ok"], false, "{envelope}");
    (envelope["error"]["code"].as_str().unwrap().to_string(), envelope["error"]["details"].clone())
}

/// `operation.failed`'s machine reason; the explanation is in
/// `extra.message`.
fn failed_code(envelope: &Value) -> String {
    let (code, details) = failure(envelope);
    assert_eq!(code, "operation.failed", "{envelope}");
    assert!(details["extra"]["message"].is_string(), "{envelope}");
    assert!(details["extra"].get("code").is_none(), "{envelope}");
    details["reason"].as_str().unwrap_or_default().to_string()
}

fn create(mux: &Arc<Mux>, repository: &Path, fields: Value, key: &str) -> Value {
    let mut params = fields;
    params["path"] = json!(repository.to_string_lossy());
    call(mux, "git.checkpoint.create", params, Some(key))
}

fn read(mux: &Arc<Mux>, operation: &str, repository: &Path, fields: Value) -> Value {
    let mut params = fields;
    params["path"] = json!(repository.to_string_lossy());
    call(mux, operation, params, None)
}

/// HEAD, the raw index file and porcelain status: what capture must leave
/// exactly as it found them.
fn observed(repository: &Path) -> (String, Vec<u8>, Vec<u8>) {
    let status = git_bytes(
        repository,
        &["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored"],
    );
    let index = fs::read(repository.join(".git/index")).unwrap();
    (git(repository, &["rev-parse", "HEAD"]), index, status)
}

/// One entry of a tree in the checkpoint: (mode, raw blob bytes).
fn stored(repository: &Path, object: &str, tree: &str, path: &str) -> Option<(String, Vec<u8>)> {
    let listing =
        git_bytes(repository, &["ls-tree", "-z", &format!("{object}:{tree}"), "--", path]);
    let entry = listing.split(|byte| *byte == 0).find(|entry| !entry.is_empty())?;
    let tab = entry.iter().position(|byte| *byte == b'\t').unwrap();
    assert_eq!(&entry[tab + 1..], path.as_bytes());
    let header = String::from_utf8_lossy(&entry[..tab]).into_owned();
    let mut fields = header.split(' ');
    let mode = fields.next().unwrap().to_string();
    let _kind = fields.next();
    let oid = fields.next().unwrap();
    Some((mode, git_bytes(repository, &["cat-file", "blob", oid])))
}

fn skipped(record: &Value) -> Vec<(String, String)> {
    record["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|skip| {
            (skip["path"].as_str().unwrap().to_string(), skip["code"].as_str().unwrap().to_string())
        })
        .collect()
}

fn checkpoint_refs(repository: &Path) -> Vec<String> {
    let refs = git(repository, &["for-each-ref", "--format=%(refname)", "refs/cmux/checkpoints/"]);
    refs.lines().map(str::to_string).collect()
}

/// a.txt staged and changed again; run.sh made executable; bin.dat
/// changed; wdel.txt deleted in the worktree only; gone.txt removed from
/// the index; untracked link, a name with a space and a newline, extra.txt
/// and an ignored debug.log.
fn worked_repository(name: &str) -> PathBuf {
    let repository = repository(name);
    write(&repository, "a.txt", b"one\n");
    write(&repository, "run.sh", b"#!/bin/sh\necho hi\n");
    write(&repository, "bin.dat", &[0, 1, 2, 255]);
    write(&repository, "wdel.txt", b"bye\n");
    write(&repository, "gone.txt", b"gone\n");
    write(&repository, ".gitignore", b"*.log\n");
    commit_all(&repository, "first");
    write(&repository, "a.txt", b"two\n");
    git(&repository, &["add", "a.txt"]);
    write(&repository, "a.txt", b"three\n");
    fs::set_permissions(repository.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
    write(&repository, "bin.dat", &[255, 0, 13, 10, 0]);
    fs::remove_file(repository.join("wdel.txt")).unwrap();
    git(&repository, &["rm", "-q", "gone.txt"]);
    std::os::unix::fs::symlink("a.txt", repository.join("link")).unwrap();
    write(&repository, "dir with space/new\nline.txt", b"odd name\n");
    write(&repository, "extra.txt", b"not chosen\n");
    write(&repository, "debug.log", b"ignored\n");
    repository
}

#[test]
fn capture_stores_staged_and_worktree_bytes_and_modes_without_touching_the_repository() {
    let (mux, _root) = session("round-trip");
    let repository = worked_repository("round-trip");
    let marker = repository.join("hook-ran");
    let hook = repository.join(".git/hooks/reference-transaction");
    fs::create_dir_all(hook.parent().unwrap()).unwrap();
    fs::write(&hook, format!("#!/bin/sh\necho ran >> '{}'\n", marker.display())).unwrap();
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    let before = observed(&repository);

    let result = ok(create(
        &mux,
        &repository,
        json!({"include_untracked":["link","dir with space/new\nline.txt"]}),
        "round-trip-1",
    ));

    assert_eq!(observed(&repository), before, "capture changed HEAD, the index or the tree");
    assert!(!marker.exists(), "a hook ran during capture");
    assert_eq!(result["replayed"], false);
    assert!(result["revision"].as_str().unwrap().parse::<u64>().is_ok(), "{result}");
    assert_eq!(result["value"]["revision"], "1");
    let record = &result["value"];
    let object = record["object_id"].as_str().unwrap();
    let reference = record["ref"].as_str().unwrap();
    assert_eq!(
        reference,
        format!(
            "refs/cmux/checkpoints/{}/{}",
            record["worktree_id"].as_str().unwrap(),
            record["checkpoint_id"].as_str().unwrap()
        )
    );
    assert_eq!(git(&repository, &["rev-parse", reference]), object);
    assert_eq!(git(&repository, &["rev-list", "--count", object]), "1", "no parent commit");
    assert!(git(&repository, &["branch", "--list"]).lines().all(|line| !line.contains("cmux")));

    // Staged and unstaged versions of one file.
    let staged = stored(&repository, object, "index", "a.txt").unwrap();
    assert_eq!(staged, ("100644".to_string(), b"two\n".to_vec()));
    let worktree = stored(&repository, object, "worktree", "a.txt").unwrap();
    assert_eq!(worktree, ("100644".to_string(), b"three\n".to_vec()));
    // The executable bit, in the worktree only.
    assert_eq!(stored(&repository, object, "index", "run.sh").unwrap().0, "100644");
    assert_eq!(stored(&repository, object, "worktree", "run.sh").unwrap().0, "100755");
    // Raw binary bytes.
    let binary = stored(&repository, object, "worktree", "bin.dat").unwrap();
    assert_eq!(binary.1, vec![255, 0, 13, 10, 0]);
    // A worktree deletion is absent from the worktree tree only; a staged
    // deletion from both.
    assert!(stored(&repository, object, "index", "wdel.txt").is_some());
    assert!(stored(&repository, object, "worktree", "wdel.txt").is_none());
    assert!(stored(&repository, object, "index", "gone.txt").is_none());
    assert!(stored(&repository, object, "worktree", "gone.txt").is_none());
    // Selected untracked files: a link as a link, an odd name byte for byte.
    let link = stored(&repository, object, "untracked", "link").unwrap();
    assert_eq!(link, ("120000".to_string(), b"a.txt".to_vec()));
    let odd = stored(&repository, object, "untracked", "dir with space/new\nline.txt").unwrap();
    assert_eq!(odd.1, b"odd name\n");
    assert!(stored(&repository, object, "untracked", "extra.txt").is_none());
    assert!(stored(&repository, object, "untracked", "debug.log").is_none());

    // The eligible file left out and the ignored one are reported.
    let skips = skipped(record);
    assert!(skips.contains(&("extra.txt".into(), "not_selected".into())), "{skips:?}");
    assert!(skips.contains(&("debug.log".into(), "ignored".into())), "{skips:?}");
    assert_eq!(record["complete"], false);
    assert_eq!(record["skipped_total"], skips.len());
    assert_eq!(record["included"]["untracked"], 2);
    assert_eq!(record["base"]["head"], git(&repository, &["rev-parse", "HEAD"]));
    assert_eq!(record["base"]["branch"], "main");
    assert_eq!(record["base"]["detached"], false);
    assert!(record["expires_at"].is_string());
    assert_eq!(record["pins"], json!([]));
    assert_eq!(record["limits"]["max_untracked_file_bytes"], 10_000_000);

    let metadata =
        git_bytes(&repository, &["cat-file", "blob", &format!("{object}:metadata.json")]);
    let metadata: Value = serde_json::from_slice(&metadata).unwrap();
    assert_eq!(metadata["checkpoint_id"], record["checkpoint_id"]);
    mux.shutdown();
}

#[test]
fn a_clean_repository_is_captured_complete_and_eligible_selects_every_candidate() {
    let (mux, _root) = session("complete");
    let repository = repository("complete");
    write(&repository, "src/lib.rs", b"pub fn f() {}\n");
    commit_all(&repository, "first");
    let clean = ok(create(&mux, &repository, json!({}), "complete-1"));
    assert_eq!(clean["value"]["complete"], true, "{clean}");
    assert_eq!(clean["value"]["skipped"], json!([]));
    assert_eq!(clean["value"]["coverage"]["omitted"], 0);

    write(&repository, "notes.md", b"new\n");
    write(&repository, "big.bin", &vec![7; 10_000_001]);
    let eligible =
        ok(create(&mux, &repository, json!({"include_untracked":"eligible"}), "complete-2"));
    let record = &eligible["value"];
    let object = record["object_id"].as_str().unwrap();
    assert!(stored(&repository, object, "untracked", "notes.md").is_some());
    assert!(stored(&repository, object, "untracked", "big.bin").is_none());
    assert_eq!(skipped(record), vec![("big.bin".to_string(), "over_limit".to_string())]);
    assert_eq!(record["skipped"][0]["bytes"], 10_000_001);
    assert_eq!(record["complete"], false);
    mux.shutdown();
}

#[test]
fn a_reused_key_replays_its_first_result_and_other_arguments_conflict() {
    let (mux, _root) = session("replay");
    let repository = worked_repository("replay");
    let first = ok(create(&mux, &repository, json!({}), "replay-1"));
    let again = ok(create(&mux, &repository, json!({}), "replay-1"));
    assert_eq!(again["replayed"], true);
    assert_eq!(again["value"], first["value"]);
    assert_eq!(checkpoint_refs(&repository).len(), 1, "a replay captured again");

    let conflict = create(&mux, &repository, json!({"include_untracked":"eligible"}), "replay-1");
    let (code, details) = failure(&conflict);
    assert_eq!(code, "idempotency.conflict");
    assert_eq!(details["idempotency_key"], "replay-1");
    assert_eq!(details["committed_operation"], "git.checkpoint.create");

    // An uncertain reply is recovered by key or by id.
    let id = first["value"]["checkpoint_id"].as_str().unwrap();
    let by_key =
        ok(read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"replay-1"})));
    assert_eq!(by_key, first["value"]);
    let by_id = ok(read(&mux, "git.checkpoint.get", &repository, json!({"checkpoint_id":id})));
    assert_eq!(by_id, first["value"]);
    let missing = read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"never"}));
    let (code, details) = failure(&missing);
    assert_eq!(code, "resource.not_found");
    assert_eq!(details["scope"], "git_checkpoint");
    // Both lookups at once breaks the catalog's one_of, so the router refuses it before dispatch.
    let both = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"test-get-both",
        "operation":"git.checkpoint.get",
        "params":{
            "machine":"current",
            "session":"current",
            "path":repository.to_string_lossy(),
            "checkpoint_id":id,
            "idempotency_key":"replay-1",
        },
    });
    let refused = handle_resource_message(&mux, &both.to_string()).unwrap_err();
    assert_eq!(refused.code, "validation.invalid");
    mux.shutdown();
}

#[test]
fn list_pages_newest_first_and_offers_untracked_candidates() {
    let (mux, _root) = session("list");
    let repository = worked_repository("list");
    let first = ok(create(&mux, &repository, json!({}), "list-1"));
    let second = ok(create(&mux, &repository, json!({}), "list-2"));

    let page = ok(read(&mux, "git.checkpoint.list", &repository, json!({"limit":1})));
    assert_eq!(page["repository_id"], first["value"]["repository_id"]);
    assert_eq!(page["worktree_id"], first["value"]["worktree_id"]);
    assert_eq!(page["checkpoints"], json!([second["value"]]));
    assert!(page.get("candidates").is_none());
    let cursor = page["next_cursor"].as_str().unwrap();
    let rest = ok(read(&mux, "git.checkpoint.list", &repository, json!({"cursor":cursor})));
    assert_eq!(rest["checkpoints"], json!([first["value"]]));
    assert_eq!(rest["next_cursor"], Value::Null);

    let listed =
        ok(read(&mux, "git.checkpoint.list", &repository, json!({"include_candidates":true})));
    assert_eq!(listed["limits"]["max_untracked_file_bytes"], 10_000_000);
    let candidates = listed["candidates"].as_array().unwrap();
    let find = |path: &str| candidates.iter().find(|candidate| candidate["path"] == path).cloned();
    assert_eq!(find("extra.txt").unwrap()["eligible"], true);
    assert_eq!(find("extra.txt").unwrap()["bytes"], 11);
    assert_eq!(find("link").unwrap()["eligible"], true);
    let ignored = find("debug.log").unwrap();
    assert_eq!(
        (ignored["eligible"].clone(), ignored["reason"].clone()),
        (json!(false), json!("ignored"))
    );
    mux.shutdown();
}

#[test]
fn pins_commute_replay_and_managed_pins_cannot_be_unpinned() {
    let (mux, _root) = session("pins");
    let repository = worked_repository("pins");
    let created = ok(create(&mux, &repository, json!({}), "pins-create"));
    let id = created["value"]["checkpoint_id"].as_str().unwrap().to_string();
    let pin = |pin_id: &str, key: &str| {
        let fields = json!({"checkpoint_id":id,"pin_id":pin_id,"reason":"keep"});
        let mut params = fields;
        params["path"] = json!(repository.to_string_lossy());
        call(&mux, "git.checkpoint.pin", params, Some(key))
    };
    let user = ok(pin("user:review", "pin-1"));
    assert_eq!(user["value"]["revision"], "2");
    assert_eq!(user["value"]["pins"], json!([{"pin_id":"user:review","reason":"keep"}]));
    assert_eq!(user["value"]["expires_at"], Value::Null, "a pinned record does not expire");
    let handoff = ok(pin("handoff:h1", "pin-2"));
    assert_eq!(handoff["value"]["pins"].as_array().unwrap().len(), 2);
    assert_eq!(handoff["value"]["revision"], "3");
    // The first key replays its first result, not the current record.
    let replay = ok(pin("user:review", "pin-1"));
    assert_eq!(
        (replay["replayed"].clone(), replay["value"].clone()),
        (json!(true), user["value"].clone())
    );

    let unpin = |pin_id: &str, key: &str| {
        let mut params = json!({"checkpoint_id":id,"pin_id":pin_id});
        params["path"] = json!(repository.to_string_lossy());
        call(&mux, "git.checkpoint.unpin", params, Some(key))
    };
    assert_eq!(failed_code(&unpin("handoff:h1", "unpin-1")), "managed_pin");
    assert_eq!(failed_code(&unpin("restore:r1", "unpin-2")), "managed_pin");
    let unpinned = ok(unpin("user:review", "unpin-3"));
    assert_eq!(unpinned["value"]["pins"], json!([{"pin_id":"handoff:h1","reason":"keep"}]));
    let current = ok(read(&mux, "git.checkpoint.get", &repository, json!({"checkpoint_id":id})));
    assert_eq!(current, unpinned["value"]);
    assert_eq!(checkpoint_refs(&repository).len(), 1, "unpin never deletes a checkpoint");

    let unknown = format!("ckpt_{}", "0".repeat(32));
    let mut params = json!({"checkpoint_id":unknown,"pin_id":"user:x","reason":"keep"});
    params["path"] = json!(repository.to_string_lossy());
    let missing = call(&mux, "git.checkpoint.pin", params, Some("pin-missing"));
    assert_eq!(failure(&missing).0, "resource.not_found");
    mux.shutdown();
}

#[test]
fn unsupported_index_modes_refuse_and_publish_nothing() {
    let (mux, _root) = session("unsupported");
    let repository = repository("unsupported");
    write(&repository, "a.txt", b"a\n");
    write(&repository, "b.txt", b"b\n");
    commit_all(&repository, "first");
    write(&repository, "new.txt", b"new\n");
    git(&repository, &["add", "-N", "new.txt"]);
    assert_eq!(failed_code(&create(&mux, &repository, json!({}), "ita")), "unsupported_index");
    git(&repository, &["rm", "-q", "--cached", "new.txt"]);

    git(&repository, &["update-index", "--skip-worktree", "b.txt"]);
    assert_eq!(failed_code(&create(&mux, &repository, json!({}), "skip")), "unsupported_index");
    git(&repository, &["update-index", "--no-skip-worktree", "b.txt"]);

    git(&repository, &["update-index", "--assume-unchanged", "a.txt"]);
    assert_eq!(failed_code(&create(&mux, &repository, json!({}), "assume")), "unsupported_index");
    assert!(checkpoint_refs(&repository).is_empty());
    mux.shutdown();
}

#[test]
fn bounds_selections_and_identities_are_checked_before_anything_is_published() {
    let (mux, _root) = session("bounds");
    let repository = worked_repository("bounds");
    let over = create(&mux, &repository, json!({"limits":{"max_bytes":1}}), "bounds-1");
    assert_eq!(failed_code(&over), "budget_exceeded");
    let unknown = create(&mux, &repository, json!({"include_untracked":["nope.txt"]}), "bounds-2");
    assert_eq!(failure(&unknown).0, "validation.invalid");
    let traversal = create(&mux, &repository, json!({"include_untracked":["../x"]}), "bounds-3");
    assert_eq!(failure(&traversal).0, "validation.invalid");
    let elsewhere = format!("repo_{}", "0".repeat(32));
    let moved = create(&mux, &repository, json!({"expected_repository_id":elsewhere}), "bounds-4");
    assert_eq!(failed_code(&moved), "repository_changed");
    assert!(checkpoint_refs(&repository).is_empty());

    // An excluded path is in neither tree and is reported.
    let excluded = ok(create(&mux, &repository, json!({"exclude_paths":["bin.dat"]}), "bounds-5"));
    let object = excluded["value"]["object_id"].as_str().unwrap();
    assert!(stored(&repository, object, "index", "bin.dat").is_none());
    assert!(stored(&repository, object, "worktree", "bin.dat").is_none());
    assert!(skipped(&excluded["value"]).contains(&("bin.dat".into(), "excluded".into())));
    mux.shutdown();
}

#[test]
fn checkpoints_and_keys_survive_a_restart() {
    let root = temporary("state-restart");
    let repository = worked_repository("restart");
    let mux = Mux::open_persistent("ckpt-restart", SurfaceOptions::default(), &root).unwrap();
    let first = ok(create(&mux, &repository, json!({}), "restart-1"));
    mux.shutdown();
    drop(mux);

    let mux = Mux::open_persistent("ckpt-restart", SurfaceOptions::default(), &root).unwrap();
    let again = ok(create(&mux, &repository, json!({}), "restart-1"));
    assert_eq!(
        (again["replayed"].clone(), again["value"].clone()),
        (json!(true), first["value"].clone())
    );
    let by_key =
        ok(read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"restart-1"})));
    assert_eq!(by_key, first["value"]);
    assert_eq!(checkpoint_refs(&repository).len(), 1);
    mux.shutdown();
}

#[test]
fn an_in_memory_session_and_a_folder_outside_a_repository_refuse() {
    let memory = Mux::new_for_test("ckpt-memory", SurfaceOptions::default());
    let repository = worked_repository("memory");
    assert_eq!(
        failed_code(&create(&memory, &repository, json!({}), "memory-1")),
        "no_state_directory"
    );

    let (mux, _root) = session("outside");
    let outside = temporary("outside");
    assert_eq!(failed_code(&create(&mux, &outside, json!({}), "outside-1")), "not_a_repository");
    mux.shutdown();
}

#[test]
fn identify_advertises_git_checkpoints() {
    assert_eq!(super::super::CHECKPOINTS_CAPABILITY, "git-checkpoints-v1");
}

fn pin_call(mux: &Arc<Mux>, repository: &Path, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = fields;
    params["path"] = json!(repository.to_string_lossy());
    call(mux, operation, params, Some(key))
}

/// A second worktree of `repository` on a new branch, in its own unique
/// directory: a fixed `$TMPDIR/<name>-second` collided with the worktree an
/// earlier or parallel run left behind ("already exists").
fn second_worktree(repository: &Path, name: &str) -> PathBuf {
    let worktree = temporary(&format!("{name}-second")).join("worktree");
    let target = worktree.to_string_lossy().into_owned();
    git(repository, &["worktree", "add", "-q", "-b", name, &target]);
    fs::canonicalize(worktree).unwrap()
}

fn record_file(mux: &Arc<Mux>, record: &Value) -> PathBuf {
    mux.session_state_directory()
        .unwrap()
        .join("git-checkpoints/records")
        .join(record["repository_id"].as_str().unwrap())
        .join(format!("{}.json", record["checkpoint_id"].as_str().unwrap()))
}

#[test]
fn refusals_name_their_reason_and_explain_in_extra_message() {
    let (mux, _root) = session("reasons");
    let repository = worked_repository("reasons");
    let created = ok(create(&mux, &repository, json!({}), "reasons-1"));
    let id = created["value"]["checkpoint_id"].clone();
    let fields = json!({"checkpoint_id":id,"pin_id":"handoff:h1"});
    let refused = pin_call(&mux, &repository, "git.checkpoint.unpin", fields, "reasons-2");
    let (code, details) = failure(&refused);
    assert_eq!(code, "operation.failed");
    assert_eq!(details["operation"], "git.checkpoint.unpin");
    assert_eq!(details["reason"], "managed_pin");
    assert!(details["extra"]["message"].as_str().is_some_and(|text| text.contains("handoff:h1")));
    assert_eq!(details["extra"]["pin_id"], "handoff:h1");
    assert!(details["extra"].get("code").is_none());
    mux.shutdown();
}

#[test]
fn mutations_are_recorded_in_the_session_resource_mutation_ledger() {
    let (mux, _root) = session("ledger");
    let repository = worked_repository("ledger");
    let count =
        || mux.workspace_registry.lock().unwrap().resource_mutation_count_for_test().unwrap();
    let before = count();
    let created = ok(create(&mux, &repository, json!({}), "ledger-1"));
    assert_eq!(count(), before + 1, "create is not in resource_mutations");
    ok(create(&mux, &repository, json!({}), "ledger-1"));
    assert_eq!(count(), before + 1, "a replay recorded a second mutation");
    let actor = mux.workspace_registry.lock().unwrap().resource_mutation_actor_for_test("ledger-1");
    assert_eq!(actor.unwrap().as_deref(), Some("user:user_local"), "the caller is not recorded");
    let id = created["value"]["checkpoint_id"].clone();
    let fields = json!({"checkpoint_id":id,"pin_id":"user:a","reason":"keep"});
    ok(pin_call(&mux, &repository, "git.checkpoint.pin", fields, "ledger-2"));
    assert_eq!(count(), before + 2, "pin is not in resource_mutations");
    mux.shutdown();
}

#[test]
fn a_key_reused_for_a_target_that_now_resolves_elsewhere_is_refused() {
    let (mux, _root) = session("moved");
    let repository = worked_repository("moved");
    let other = second_worktree(&repository, "moved");
    let link = repository.parent().unwrap().join(format!("moved-link-{}", std::process::id()));
    let _ = fs::remove_file(&link);
    std::os::unix::fs::symlink(&repository, &link).unwrap();
    ok(create(&mux, &link, json!({}), "moved-1"));
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(&other, &link).unwrap();
    let again = create(&mux, &link, json!({}), "moved-1");
    assert_eq!(failed_code(&again), "repository_changed");
    assert_eq!(checkpoint_refs(&repository).len(), 1, "the refused retry published a checkpoint");
    mux.shutdown();
}

fn other_worktree_id(mux: &Arc<Mux>, worktree: &Path) -> String {
    let listed = ok(read(mux, "git.checkpoint.list", worktree, json!({})));
    listed["worktree_id"].as_str().unwrap().to_string()
}

#[test]
fn key_lookup_finds_only_creates_of_the_same_worktree() {
    let (mux, _root) = session("scoped");
    let repository = worked_repository("scoped");
    let other = second_worktree(&repository, "scoped");
    let created = ok(create(&mux, &repository, json!({}), "scoped-1"));
    let elsewhere = read(&mux, "git.checkpoint.get", &other, json!({"idempotency_key":"scoped-1"}));
    assert_eq!(failure(&elsewhere).0, "resource.not_found", "another worktree saw the key");
    let id = created["value"]["checkpoint_id"].clone();
    let fields = json!({"checkpoint_id":id,"pin_id":"user:a","reason":"keep"});
    ok(pin_call(&mux, &repository, "git.checkpoint.pin", fields, "scoped-pin"));
    let pin_key =
        read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"scoped-pin"}));
    assert_eq!(failure(&pin_key).0, "resource.not_found", "a pin key resolved as a create");
    let own =
        ok(read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"scoped-1"})));
    assert_eq!(own["checkpoint_id"], id);
    mux.shutdown();
}

#[test]
fn a_reused_key_conflicts_before_the_managed_pin_check() {
    let (mux, _root) = session("order");
    let repository = worked_repository("order");
    let created = ok(create(&mux, &repository, json!({}), "order-1"));
    let id = created["value"]["checkpoint_id"].clone();
    let fields = json!({"checkpoint_id":id,"pin_id":"user:a","reason":"keep"});
    ok(pin_call(&mux, &repository, "git.checkpoint.pin", fields, "order-2"));
    let fields = json!({"checkpoint_id":id,"pin_id":"handoff:h1"});
    let reused = pin_call(&mux, &repository, "git.checkpoint.unpin", fields, "order-2");
    let (code, details) = failure(&reused);
    assert_eq!(code, "idempotency.conflict", "{reused}");
    assert_eq!(details["committed_operation"], "git.checkpoint.pin");
    mux.shutdown();
}

#[test]
fn a_create_that_stopped_after_publishing_its_ref_is_finished_by_its_retry() {
    let (mux, _root) = session("crash");
    let repository = worked_repository("crash");
    super::seams::CRASH_AFTER_PUBLISH.with(|crash| crash.set(true));
    let crashed = create(&mux, &repository, json!({}), "crash-1");
    super::seams::CRASH_AFTER_PUBLISH.with(|crash| crash.set(false));
    assert_eq!(crashed["ok"], false, "the simulated crash did not stop the create: {crashed}");
    let refs = checkpoint_refs(&repository);
    assert_eq!(refs.len(), 1, "the ref was not published before the crash");
    let pending =
        read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"crash-1"}));
    assert_eq!(failure(&pending).0, "resource.not_found");

    let retried = ok(create(&mux, &repository, json!({}), "crash-1"));
    assert_eq!(retried["replayed"], true);
    let record = &retried["value"];
    assert_eq!(refs[0], record["ref"].as_str().unwrap());
    assert_eq!(git(&repository, &["rev-parse", &refs[0]]), record["object_id"].as_str().unwrap());
    assert_eq!(checkpoint_refs(&repository).len(), 1, "the retry captured a second checkpoint");
    let found =
        ok(read(&mux, "git.checkpoint.get", &repository, json!({"idempotency_key":"crash-1"})));
    assert_eq!(&found, record);
    mux.shutdown();
}

#[test]
fn a_file_that_changes_during_capture_refuses_with_repository_changed() {
    let (mux, _root) = session("racing");
    let repository = worked_repository("racing");
    let path = repository.join("a.txt");
    let rewrite: Box<dyn Fn()> =
        Box::new(move || fs::write(&path, b"changed again, longer\n").unwrap());
    super::seams::AFTER_HASHING.with(|hook| *hook.borrow_mut() = Some(rewrite));
    let raced = create(&mux, &repository, json!({}), "racing-1");
    super::seams::AFTER_HASHING.with(|hook| hook.borrow_mut().take());
    assert_eq!(failed_code(&raced), "repository_changed");
    assert!(checkpoint_refs(&repository).is_empty());
    mux.shutdown();
}

#[test]
fn credential_files_are_never_stored() {
    let (mux, _root) = session("secrets");
    let repository = repository("secrets");
    write(&repository, "README.md", b"readme\n");
    commit_all(&repository, "first");
    let credentials = [
        ".git-credentials",
        ".npmrc",
        ".pypirc",
        ".netrc",
        ".aws/credentials",
        "config/credentials",
        "app.jks",
        "release.keystore",
        "client.p12",
        "client.pfx",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa_work",
        ".env",
        ".env.local",
    ];
    for path in credentials {
        write(&repository, path, b"secret\n");
    }
    write(&repository, "id_ed25519.pub", b"ssh-ed25519 AAAA\n");
    write(&repository, "notes.txt", b"notes\n");
    let created =
        ok(create(&mux, &repository, json!({"include_untracked":"eligible"}), "secrets-1"));
    let record = &created["value"];
    let object = record["object_id"].as_str().unwrap();
    let skips = skipped(record);
    for path in credentials {
        assert!(skips.contains(&(path.to_string(), "credential".to_string())), "{path}: {skips:?}");
        assert!(stored(&repository, object, "untracked", path).is_none(), "{path} was stored");
    }
    assert!(stored(&repository, object, "untracked", "id_ed25519.pub").is_some());
    assert!(stored(&repository, object, "untracked", "notes.txt").is_some());
    mux.shutdown();
}

#[test]
fn untracked_links_store_their_target_and_never_what_it_points_at() {
    let (mux, _root) = session("links");
    let repository = repository("links");
    write(&repository, "src/lib.rs", b"pub fn f() {}\n");
    commit_all(&repository, "first");
    let outside = temporary("links-outside").join("secret.txt");
    fs::write(&outside, b"outside the repository\n").unwrap();
    std::os::unix::fs::symlink("src", repository.join("to-folder")).unwrap();
    std::os::unix::fs::symlink(&outside, repository.join("to-outside")).unwrap();
    let selected = json!({"include_untracked":["to-folder","to-outside"]});
    let created = ok(create(&mux, &repository, selected, "links-1"));
    let object = created["value"]["object_id"].as_str().unwrap();
    let folder = stored(&repository, object, "untracked", "to-folder").unwrap();
    assert_eq!(folder, ("120000".to_string(), b"src".to_vec()));
    let away = stored(&repository, object, "untracked", "to-outside").unwrap();
    assert_eq!(away, ("120000".to_string(), outside.to_string_lossy().as_bytes().to_vec()));
    mux.shutdown();
}

#[test]
fn a_create_prunes_expired_unpinned_checkpoints() {
    let (mux, _root) = session("prune");
    let repository = worked_repository("prune");
    let old = ok(create(&mux, &repository, json!({}), "prune-1"))["value"].clone();
    let kept = ok(create(&mux, &repository, json!({}), "prune-2"))["value"].clone();
    let fields = json!({"checkpoint_id":kept["checkpoint_id"],"pin_id":"user:a","reason":"keep"});
    ok(pin_call(&mux, &repository, "git.checkpoint.pin", fields, "prune-pin"));
    let eight_days_ago = super::record::now_ms() - 8 * 24 * 60 * 60 * 1000;
    for record in [&old, &kept] {
        let path = record_file(&mux, record);
        let mut stored: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        stored["created_at_ms"] = json!(eight_days_ago);
        fs::write(&path, serde_json::to_vec(&stored).unwrap()).unwrap();
    }
    ok(create(&mux, &repository, json!({}), "prune-3"));
    let refs = checkpoint_refs(&repository);
    assert!(!refs.contains(&old["ref"].as_str().unwrap().to_string()), "{refs:?}");
    assert!(
        refs.contains(&kept["ref"].as_str().unwrap().to_string()),
        "a pinned record was pruned"
    );
    let gone = read(
        &mux,
        "git.checkpoint.get",
        &repository,
        json!({"checkpoint_id":old["checkpoint_id"]}),
    );
    assert_eq!(failure(&gone).0, "resource.not_found");
    mux.shutdown();
}

#[test]
fn a_create_sweeps_only_its_worktrees_orphaned_refs() {
    let (mux, _root) = session("sweep");
    let repository = worked_repository("sweep");
    let worktree = other_worktree_id(&mux, &repository);
    let head = git(&repository, &["rev-parse", "HEAD"]);
    let orphan = format!("refs/cmux/checkpoints/{worktree}/ckpt_{}", "1".repeat(32));
    let foreign = format!("refs/cmux/checkpoints/wt_{}/ckpt_{}", "2".repeat(32), "3".repeat(32));
    for name in [orphan.as_str(), foreign.as_str(), "refs/cmux/other/keep"] {
        git(&repository, &["update-ref", name, &head]);
    }
    let created = ok(create(&mux, &repository, json!({}), "sweep-1"));
    let refs = git(&repository, &["for-each-ref", "--format=%(refname)", "refs/cmux/"]);
    assert!(!refs.lines().any(|name| name == orphan), "the orphan stayed: {refs}");
    assert!(refs.lines().any(|name| name == foreign), "another worktree's ref was swept");
    assert!(refs.lines().any(|name| name == "refs/cmux/other/keep"));
    assert!(refs.lines().any(|name| name == created["value"]["ref"].as_str().unwrap()));
    mux.shutdown();
}

#[test]
fn ignored_paths_do_not_count_against_the_candidate_budget() {
    let (mux, _root) = session("ignored");
    let repository = repository("ignored");
    write(&repository, ".gitignore", b"*.log\n");
    commit_all(&repository, "first");
    for index in 0..1001 {
        write(&repository, &format!("run-{index:04}.log"), b"log\n");
    }
    write(&repository, "notes.md", b"notes\n");
    let listed =
        ok(read(&mux, "git.checkpoint.list", &repository, json!({"include_candidates":true})));
    assert_eq!(listed["ignored_total"], 1001);
    let candidates = listed["candidates"].as_array().unwrap();
    let ignored = candidates.iter().filter(|candidate| candidate["reason"] == "ignored").count();
    assert!(ignored <= 200, "{ignored} ignored candidates listed");
    assert!(candidates.iter().any(|candidate| candidate["path"] == "notes.md"));
    mux.shutdown();
}

#[test]
fn reads_do_not_wait_behind_a_running_capture() {
    use std::sync::mpsc;
    use std::time::Duration;

    let (mux, _root) = session("unblocked");
    let repository = worked_repository("unblocked");
    let created = ok(create(&mux, &repository, json!({}), "unblocked-1"));
    let id = created["value"]["checkpoint_id"].clone();
    let store = super::store::Store::open(&mux, "git.checkpoint.create").unwrap();
    let (held, holding) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        store.exclusive(|| {
            held.send(()).unwrap();
            let _ = released.recv();
        });
    });
    holding.recv().unwrap();
    let (done, answered) = mpsc::channel();
    let (reader_mux, path) = (mux.clone(), repository);
    let reader = std::thread::spawn(move || {
        let got = read(&reader_mux, "git.checkpoint.get", &path, json!({"checkpoint_id":id}));
        let listed = read(&reader_mux, "git.checkpoint.list", &path, json!({}));
        let _ = done.send((got, listed));
    });
    let answer = answered.recv_timeout(Duration::from_secs(10));
    release.send(()).unwrap();
    holder.join().unwrap();
    reader.join().unwrap();
    let (got, listed) = answer.expect("get and list waited behind the checkpoint lock");
    assert_eq!(ok(got), created["value"]);
    assert_eq!(ok(listed)["checkpoints"].as_array().unwrap().len(), 1);
    mux.shutdown();
}
