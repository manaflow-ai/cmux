use super::*;
use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt as _;
use std::sync::Mutex;

fn sh(dir: &Path, args: &[&str]) {
    git(dir, None, args, None).unwrap();
}

/// A checkout with a committed tree, an uncommitted edit and an untracked file (both in the
/// snapshot a fork starts from), and a gitignored file (never carried).
pub(crate) fn checkout() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path();
    sh(p, &["init", "-q", "-b", "main"]);
    sh(p, &["config", "user.email", "t@example.com"]);
    sh(p, &["config", "user.name", "t"]);
    std::fs::write(p.join(".gitignore"), "target/\n").unwrap();
    std::fs::write(p.join("keep.txt"), "keep\n").unwrap();
    std::fs::write(p.join("gone.txt"), "to be deleted\n").unwrap();
    std::fs::write(p.join("old_name.rs"), "fn moved() {}\n".repeat(20)).unwrap();
    std::fs::write(p.join("run.sh"), "#!/bin/sh\necho hi\n").unwrap();
    std::fs::write(p.join("blob.bin"), [0u8, 1, 2, 255, 254, 0, 10, 13]).unwrap();
    sh(p, &["add", "-A"]);
    sh(p, &["commit", "-q", "-m", "base"]);
    std::fs::write(p.join("keep.txt"), "keep, edited before the fork\n").unwrap();
    std::fs::write(p.join("untracked.txt"), "new before the fork\n").unwrap();
    std::fs::create_dir_all(p.join("target")).unwrap();
    std::fs::write(p.join("target/out"), "ignored\n").unwrap();
    dir
}

/// Copy a checkout as a fork's disk would be: every byte and mode, `.git` included.
pub(crate) fn fork_of(src: &Path) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let ok = std::process::Command::new("cp")
        .arg("-a")
        .arg(format!("{}/.", src.display()))
        .arg(dir.path())
        .status()
        .unwrap()
        .success();
    assert!(ok);
    dir
}

/// What a sub-agent does on its fork: delete a file, rename one, set an executable bit, edit a
/// binary, add a new executable, edit a file the parent had changed but not committed.
pub(crate) fn work_on(p: &Path) {
    std::fs::remove_file(p.join("gone.txt")).unwrap();
    std::fs::rename(p.join("old_name.rs"), p.join("new_name.rs")).unwrap();
    std::fs::set_permissions(p.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(p.join("blob.bin"), [0u8, 0, 0, 7, 255, 128, 13, 10, 0]).unwrap();
    std::fs::write(p.join("tool"), "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(p.join("tool"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(p.join("untracked.txt"), "new before the fork\nand after, on the fork\n")
        .unwrap();
    std::fs::write(p.join("no_newline"), "no newline at end").unwrap();
}

/// Every file under `p` but `.git`: its bytes and its executable bit.
pub(crate) fn files(p: &Path) -> BTreeMap<String, (Vec<u8>, bool)> {
    let mut out = BTreeMap::new();
    let mut stack = vec![p.to_owned()];
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).unwrap() {
            let e = e.unwrap();
            let path = e.path();
            let rel = path.strip_prefix(p).unwrap().to_string_lossy().into_owned();
            if rel == ".git" {
                continue;
            }
            let meta = std::fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                stack.push(path);
            } else {
                out.insert(
                    rel,
                    (std::fs::read(&path).unwrap(), meta.permissions().mode() & 0o111 != 0),
                );
            }
        }
    }
    out
}

#[test]
fn the_patch_round_trip_is_byte_exact_with_a_delete_a_rename_and_an_exec_bit() {
    let parent = checkout();
    let before_index = std::fs::read(parent.path().join(".git/index")).unwrap();
    let base = snapshot(parent.path()).unwrap();
    // Snapshotting never touches what the agent staged.
    assert_eq!(std::fs::read(parent.path().join(".git/index")).unwrap(), before_index);
    let fork = fork_of(parent.path());
    work_on(fork.path());
    let patch = capture(fork.path(), &base).unwrap();
    let text = String::from_utf8_lossy(&patch);
    assert!(text.contains("deleted file mode"), "{text}");
    assert!(
        text.contains("rename from old_name.rs") && text.contains("rename to new_name.rs"),
        "{text}"
    );
    assert!(text.contains("new mode 100755"), "{text}");
    assert!(text.contains("GIT binary patch"), "{text}");
    assert!(!text.contains("target/out"), "ignored files are never carried: {text}");

    let touched = apply(parent.path(), &patch).unwrap();
    assert_eq!(touched, 7);
    assert_eq!(files(parent.path()), files(fork.path()));
    assert!(!parent.path().join("gone.txt").exists());
    assert!(!parent.path().join("old_name.rs").exists());
    // The parent's index is the agent's, untouched by the apply.
    assert_eq!(std::fs::read(parent.path().join(".git/index")).unwrap(), before_index);
}

#[test]
fn an_unchanged_fork_gives_an_empty_patch_that_applies_as_nothing() {
    let parent = checkout();
    let base = snapshot(parent.path()).unwrap();
    let fork = fork_of(parent.path());
    let patch = capture(fork.path(), &base).unwrap();
    assert!(patch.is_empty(), "{}", String::from_utf8_lossy(&patch));
    let before = files(parent.path());
    assert_eq!(apply(parent.path(), &patch).unwrap(), 0);
    assert_eq!(files(parent.path()), before);
}

#[test]
fn a_patch_that_conflicts_changes_nothing_in_the_parent() {
    let parent = checkout();
    let base = snapshot(parent.path()).unwrap();
    let fork = fork_of(parent.path());
    work_on(fork.path());
    let patch = capture(fork.path(), &base).unwrap();
    // The parent edits the same file meanwhile.
    std::fs::write(parent.path().join("gone.txt"), "the parent changed it meanwhile\n").unwrap();
    let before = files(parent.path());
    assert!(apply(parent.path(), &patch).is_err());
    assert_eq!(files(parent.path()), before, "a refused patch leaves the checkout untouched");
}

#[test]
fn the_key_is_on_only_for_a_literal_true() {
    use serde_json::json;
    assert!(key_on(&json!({"cloud": {"autoCloud": true}})));
    assert!(!key_on(&json!({"cloud": {"autoCloud": false}})));
    assert!(!key_on(&json!({"cloud": {"autoCloud": "true"}})));
    assert!(!key_on(&json!({})));
}

#[derive(Default)]
struct FakeMachines {
    fail_fork: bool,
    fail_delete: bool,
    forks: Mutex<Vec<String>>,
    deleted: Mutex<Vec<String>>,
}

impl FakeMachines {
    fn forks(&self) -> Vec<String> {
        self.forks.lock().unwrap().clone()
    }
    fn deleted(&self) -> Vec<String> {
        self.deleted.lock().unwrap().clone()
    }
}

impl Machines for FakeMachines {
    async fn fork(&self, machine: &str, client_key: &str) -> Result<String, String> {
        assert!(client_key.starts_with("sub-fork-"));
        if self.fail_fork {
            return Err("POST /v1/machines/m/fork: 503 pool empty".into());
        }
        let id = format!("{machine}-fork-{}", self.forks.lock().unwrap().len());
        self.forks.lock().unwrap().push(id.clone());
        Ok(id)
    }
    async fn delete(&self, machine: &str) -> Result<(), String> {
        self.deleted.lock().unwrap().push(machine.to_owned());
        if self.fail_delete { Err("DELETE: 500".into()) } else { Ok(()) }
    }
}

/// Runs the "sub-agent" on a local copy of the checkout, as a fork would hold it.
enum FakeRun {
    Work,
    Fail,
    /// The parent edits a file the sub-agent deletes while it runs.
    Conflict,
    Hang,
}

impl SubRun for FakeRun {
    async fn run(&self, fork: &str, task: &Task) -> Result<Ran, String> {
        assert!(fork.contains("-fork-"));
        match self {
            FakeRun::Fail => Err("the sub-agent exited 1".into()),
            FakeRun::Hang => std::future::pending().await,
            FakeRun::Work | FakeRun::Conflict => {
                let disk = fork_of(&task.checkout);
                work_on(disk.path());
                if matches!(self, FakeRun::Conflict) {
                    std::fs::write(task.checkout.join("gone.txt"), "meanwhile\n").unwrap();
                }
                Ok(Ran {
                    report: format!("done: {}", task.prompt),
                    patch: capture(disk.path(), &task.base_tree)?,
                    first_output_ms: Some(42),
                    files_back_ms: None,
                })
            }
        }
    }
}

#[tokio::test]
async fn placed_on_a_fork_the_patch_lands_and_the_fork_is_deleted() {
    let parent = checkout();
    let machines = Arc::new(FakeMachines::default());
    let out = place(true, Some("m"), machines.clone(), &FakeRun::Work, "edit", parent.path()).await;
    let Outcome::Applied { fork, report, files: n, first_output_ms, fork_deleted, .. } = &out
    else {
        panic!("{out:?}")
    };
    assert_eq!(
        (fork.as_str(), report.as_str(), *n, *first_output_ms, *fork_deleted),
        ("m-fork-0", "done: edit", 7, Some(42), true)
    );
    assert!(!out.runs_here());
    assert_eq!(machines.deleted(), vec!["m-fork-0"]);
    assert!(parent.path().join("new_name.rs").exists() && !parent.path().join("gone.txt").exists());
}

#[tokio::test]
async fn with_the_key_off_nothing_is_placed_or_forked() {
    let parent = checkout();
    let before = files(parent.path());
    let machines = Arc::new(FakeMachines::default());
    let out =
        place(false, Some("m"), machines.clone(), &FakeRun::Work, "edit", parent.path()).await;
    assert_eq!(out, Outcome::Off);
    assert!(out.runs_here());
    assert!(machines.forks().is_empty() && machines.deleted().is_empty());
    assert_eq!(files(parent.path()), before);
}

#[tokio::test]
async fn off_cloud_it_falls_back_without_forking() {
    let parent = checkout();
    let machines = Arc::new(FakeMachines::default());
    let out = place(true, None, machines.clone(), &FakeRun::Work, "edit", parent.path()).await;
    assert!(
        matches!(out, Outcome::Fallback { cause: Cause::NotCloud, fork_deleted: None, .. }),
        "{out:?}"
    );
    assert!(machines.forks().is_empty());
}

#[tokio::test]
async fn a_checkout_that_is_not_git_falls_back_without_forking() {
    let dir = tempfile::tempdir().unwrap();
    let machines = Arc::new(FakeMachines::default());
    let out = place(true, Some("m"), machines.clone(), &FakeRun::Work, "edit", dir.path()).await;
    assert!(matches!(out, Outcome::Fallback { cause: Cause::Snapshot, .. }), "{out:?}");
    assert!(machines.forks().is_empty());
}

#[tokio::test]
async fn a_failed_fork_falls_back_with_its_cause() {
    let parent = checkout();
    let before = files(parent.path());
    let machines = Arc::new(FakeMachines { fail_fork: true, ..Default::default() });
    let out = place(true, Some("m"), machines.clone(), &FakeRun::Work, "edit", parent.path()).await;
    let Outcome::Fallback { cause: Cause::Fork, detail, fork_deleted: None } = &out else {
        panic!("{out:?}")
    };
    assert!(detail.contains("pool empty"));
    assert!(out.runs_here());
    assert!(machines.deleted().is_empty());
    assert_eq!(files(parent.path()), before);
}

#[tokio::test]
async fn a_failed_run_falls_back_and_deletes_the_fork() {
    let parent = checkout();
    let before = files(parent.path());
    let machines = Arc::new(FakeMachines::default());
    let out = place(true, Some("m"), machines.clone(), &FakeRun::Fail, "edit", parent.path()).await;
    assert!(
        matches!(out, Outcome::Fallback { cause: Cause::Run, fork_deleted: Some(true), .. }),
        "{out:?}"
    );
    assert_eq!(machines.deleted(), vec!["m-fork-0"]);
    assert_eq!(files(parent.path()), before);
}

#[tokio::test]
async fn a_patch_that_does_not_apply_falls_back_and_deletes_the_fork() {
    let parent = checkout();
    let machines = Arc::new(FakeMachines::default());
    let out =
        place(true, Some("m"), machines.clone(), &FakeRun::Conflict, "edit", parent.path()).await;
    assert!(
        matches!(out, Outcome::Fallback { cause: Cause::Apply, fork_deleted: Some(true), .. }),
        "{out:?}"
    );
    assert_eq!(machines.deleted(), vec!["m-fork-0"]);
    // Only the parent's own edit is there: nothing of the patch.
    assert_eq!(std::fs::read_to_string(parent.path().join("gone.txt")).unwrap(), "meanwhile\n");
    assert!(
        parent.path().join("old_name.rs").exists() && !parent.path().join("new_name.rs").exists()
    );
}

#[tokio::test]
async fn a_failed_delete_is_reported_and_never_undoes_the_result() {
    let parent = checkout();
    let machines = Arc::new(FakeMachines { fail_delete: true, ..Default::default() });
    let out = place(true, Some("m"), machines.clone(), &FakeRun::Work, "edit", parent.path()).await;
    assert!(matches!(out, Outcome::Applied { fork_deleted: false, .. }), "{out:?}");
    assert_eq!(machines.deleted(), vec!["m-fork-0"]);
}

#[tokio::test]
async fn a_cancelled_placement_still_deletes_its_fork() {
    let parent = checkout();
    let machines = Arc::new(FakeMachines::default());
    let placing = place(true, Some("m"), machines.clone(), &FakeRun::Hang, "edit", parent.path());
    let cancelled = tokio::time::timeout(std::time::Duration::from_millis(300), placing).await;
    assert!(cancelled.is_err(), "the hung run is cancelled");
    assert_eq!(machines.forks(), vec!["m-fork-0"]);
    // The guard's delete runs on the runtime after the drop.
    for _ in 0..100 {
        if !machines.deleted().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(machines.deleted(), vec!["m-fork-0"]);
}

#[test]
fn a_start_goes_to_a_fork_only_with_the_key_on_a_cloud_machine_and_a_working_sub_agent() {
    let fork = StartPlan::Fork { machine: "m".into() };
    assert_eq!(start_plan(true, true, Some("m")), fork);
    assert_eq!(start_plan(false, true, Some("m")), StartPlan::Today, "key off");
    assert_eq!(start_plan(true, false, Some("m")), StartPlan::Today, "read-only sub-agent");
    assert_eq!(start_plan(true, true, None), StartPlan::Today, "not on Cloud");
    assert_eq!(start_plan(true, true, Some("  ")), StartPlan::Today, "no machine id");
}

#[tokio::test]
async fn with_the_key_off_the_start_hook_does_nothing() {
    let parent = checkout();
    let before = files(parent.path());
    let objects = |p: &Path| git(p, None, &["count-objects", "-v"], None).unwrap();
    let before_objects = objects(parent.path());
    assert_eq!(on_start(&StartPlan::Today, "edit", None, parent.path()).await, None);
    assert_eq!(files(parent.path()), before);
    assert_eq!(objects(parent.path()), before_objects, "not even a snapshot is written");
}

#[tokio::test]
async fn without_cloud_credentials_the_start_hook_falls_back_and_changes_nothing() {
    let parent = checkout();
    let before = files(parent.path());
    // The test process has no CMUX_CLOUD_API_URL / CMUX_CLOUD_ACCESS_TOKEN.
    if std::env::var(API_ENV).is_ok() || std::env::var(TOKEN_ENV).is_ok() {
        return;
    }
    let out = on_start(&StartPlan::Fork { machine: "m".into() }, "edit", None, parent.path()).await;
    let Some(Outcome::Fallback { cause: Cause::Fork, ref detail, fork_deleted: None }) = out else {
        panic!("{out:?}")
    };
    assert!(detail.contains(API_ENV), "{detail}");
    assert!(out.unwrap().runs_here());
    assert_eq!(files(parent.path()), before);
}

#[test]
fn the_cloud_backend_reads_its_api_and_credential_and_names_what_is_missing() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| (*v).to_owned())
    };
    let missing = CloudMachines::from_env(env(&[(API_ENV, "https://api.example")])).err().unwrap();
    assert!(missing.contains(TOKEN_ENV), "{missing}");
    let blank = CloudMachines::from_env(env(&[(API_ENV, " "), (TOKEN_ENV, "t")])).err().unwrap();
    assert!(blank.contains(API_ENV), "{blank}");
    let ok = CloudMachines::from_env(env(&[
        (API_ENV, "https://api.example"),
        (TOKEN_ENV, "t"),
        (TEAM_ENV, "team"),
    ]))
    .unwrap();
    assert_eq!(ok.request.team.as_deref(), Some("team"));
}
