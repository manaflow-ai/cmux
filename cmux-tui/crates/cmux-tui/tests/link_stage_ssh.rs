//! `cmux link stage ssh`: puts this Mac's git working copy on an SSH host
//! so a chat can move there (cmuxterm-hq#2580). The host is this machine
//! under another home: a fake `ssh` on PATH runs the remote command locally
//! with `HOME` set to the host's home, so git, the push and the worktree are
//! all real.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

/// A Mac with one repository and a host reached through the fake ssh.
struct World {
    _dir: tempfile::TempDir,
    bin: PathBuf,
    host_home: PathBuf,
    repo: PathBuf,
}

const FAKE_SSH: &str = r#"#!/bin/sh
# ssh [options] [--] DESTINATION COMMAND...: runs COMMAND here, as the host.
[ -z "$FAKE_SSH_DOWN" ] || { echo "ssh: connect to host mini: Connection refused" >&2; exit 255; }
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -o|-p|-l|-i|-F|-J) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
echo "$1" >> "$FAKE_SSH_LOG"
shift
exec env HOME="$FAKE_HOST_HOME" sh -c "$*"
"#;

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

impl World {
    /// `app/` on branch `feat` with a commit, then: `kept.txt` changed and
    /// staged, `src/main.rs` changed, `gone.txt` deleted, `new.txt`
    /// untracked and `build/out` ignored.
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let ssh = bin.join("ssh");
        std::fs::write(&ssh, FAKE_SSH).unwrap();
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let host_home = dir.path().join("host");
        std::fs::create_dir_all(&host_home).unwrap();
        let repo = dir.path().join("mac").join("app");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "feat"]);
        git(&repo, &["remote", "add", "origin", "git@github.com:manaflow-ai/app.git"]);
        write(&repo.join(".gitignore"), "build/\n");
        write(&repo.join("kept.txt"), "kept 1\n");
        write(&repo.join("gone.txt"), "gone\n");
        write(&repo.join("src/main.rs"), "fn main() {}\n");
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", "one"]);
        write(&repo.join("kept.txt"), "kept 2\n");
        git(&repo, &["add", "kept.txt"]);
        write(&repo.join("src/main.rs"), "fn main() { moved() }\n");
        std::fs::remove_file(repo.join("gone.txt")).unwrap();
        write(&repo.join("new.txt"), "new\n");
        write(&repo.join("build/out"), "ignored\n");
        Self { _dir: dir, bin, host_home, repo }
    }

    fn stage_with(&self, folder: &Path, extra: &[(&str, &str)]) -> (i32, Value) {
        let path = format!("{}:{}", self.bin.display(), std::env::var("PATH").unwrap_or_default());
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["link", "stage", "ssh", "--to", "leo@mini", "--key", "acp_chat_1"])
            .arg(folder)
            .env("PATH", path)
            .env("FAKE_HOST_HOME", &self.host_home)
            .env("FAKE_SSH_LOG", self._dir.path().join("ssh.log"))
            .env_remove("FAKE_SSH_DOWN")
            .env_remove("GIT_SSH_COMMAND")
            .env_remove("GIT_SSH");
        for (key, value) in extra {
            command.env(key, value);
        }
        let output = command.output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().last().unwrap_or_else(|| {
            panic!("no answer; stderr: {}", String::from_utf8_lossy(&output.stderr))
        });
        (output.status.code().unwrap(), serde_json::from_str(line).unwrap())
    }

    fn stage(&self, folder: &Path) -> (i32, Value) {
        self.stage_with(folder, &[])
    }

    fn tree(&self) -> PathBuf {
        self.host_home.join("work/cmux-moves/app-acp_chat_1")
    }
}

#[test]
fn stage_ssh_a_stage_lays_the_working_copy_on_the_host_as_uncommitted_changes_on_the_same_branch() {
    let world = World::new();
    let head = git(&world.repo, &["rev-parse", "HEAD"]);
    let status_here = git(&world.repo, &["status", "--porcelain"]);
    let (code, answer) = world.stage(&world.repo.join("src"));
    assert_eq!(code, 0, "{answer}");
    let tree = world.tree();
    assert_eq!(answer["folder"], tree.to_string_lossy().as_ref());
    assert_eq!(answer["cwd"], tree.join("src").to_string_lossy().as_ref());
    assert_eq!(answer["repo"], world.host_home.join("work/app").to_string_lossy().as_ref());
    assert_eq!(answer["head"], head.as_str());
    assert_eq!(answer["branch"], "feat");
    assert_eq!(answer["reused"], false);

    assert_eq!(git(&tree, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&tree, &["symbolic-ref", "--short", "HEAD"]), "feat");
    assert_eq!(read(&tree.join("kept.txt")), "kept 2\n");
    assert_eq!(read(&tree.join("src/main.rs")), "fn main() { moved() }\n");
    assert!(!tree.join("gone.txt").exists());
    assert_eq!(read(&tree.join("new.txt")), "new\n");
    assert!(!tree.join("build").exists(), "ignored files stay here");
    // Changes stay uncommitted there (the staged one is unstaged, as git's
    // index does not travel).
    let status_there = git(&tree, &["status", "--porcelain"]);
    assert_eq!(
        status_there.lines().collect::<Vec<_>>(),
        [" D gone.txt", " M kept.txt", " M src/main.rs", "?? new.txt"],
        "here: {status_here}"
    );
    // The host's repository is a clone of the same project.
    let host_repo = world.host_home.join("work/app");
    assert_eq!(
        git(&host_repo, &["remote", "get-url", "origin"]),
        "git@github.com:manaflow-ai/app.git"
    );
    // This Mac's working copy is untouched.
    assert_eq!(git(&world.repo, &["status", "--porcelain"]), status_here);
    assert_eq!(git(&world.repo, &["rev-parse", "HEAD"]), head);
}

#[test]
fn stage_ssh_a_rerun_reuses_an_untouched_stage_and_rebuilds_it_after_a_change_here() {
    let world = World::new();
    assert_eq!(world.stage(&world.repo).0, 0);
    let (code, again) = world.stage(&world.repo);
    assert_eq!(code, 0, "{again}");
    assert_eq!(again["reused"], true);
    assert_eq!(again["cwd"], world.tree().to_string_lossy().as_ref());

    write(&world.repo.join("new.txt"), "newer\n");
    git(&world.repo, &["add", "-A"]);
    git(&world.repo, &["commit", "-q", "-m", "two"]);
    let (code, rebuilt) = world.stage(&world.repo);
    assert_eq!(code, 0, "{rebuilt}");
    assert_eq!(rebuilt["reused"], false);
    let tree = world.tree();
    assert_eq!(read(&tree.join("new.txt")), "newer\n");
    assert_eq!(git(&tree, &["rev-parse", "HEAD"]), git(&world.repo, &["rev-parse", "HEAD"]));
    assert_eq!(git(&tree, &["symbolic-ref", "--short", "HEAD"]), "feat");
    assert_eq!(git(&tree, &["status", "--porcelain"]), "");
}

#[test]
fn stage_ssh_a_stage_never_overwrites_work_done_on_the_host() {
    let world = World::new();
    assert_eq!(world.stage(&world.repo).0, 0);
    let tree = world.tree();
    write(&tree.join("agent.txt"), "the moved chat wrote this\n");
    write(&world.repo.join("kept.txt"), "kept 3\n");
    let (code, answer) = world.stage(&world.repo);
    assert_eq!(
        (code, answer["error_code"].as_str()),
        (1, Some("stage.target_changed")),
        "{answer}"
    );
    assert_eq!(read(&tree.join("agent.txt")), "the moved chat wrote this\n");
    assert_eq!(read(&tree.join("kept.txt")), "kept 2\n");
}

#[test]
fn stage_ssh_a_host_clone_of_another_project_is_refused() {
    let world = World::new();
    let other = world.host_home.join("work/app");
    std::fs::create_dir_all(&other).unwrap();
    git(&other, &["init", "-q"]);
    git(&other, &["remote", "add", "origin", "https://github.com/someone/else.git"]);
    let (code, answer) = world.stage(&world.repo);
    assert_eq!((code, answer["error_code"].as_str()), (1, Some("stage.repo_mismatch")), "{answer}");
    assert!(!world.tree().exists());
}

#[test]
fn stage_ssh_a_host_clone_of_the_same_project_over_https_is_used() {
    let world = World::new();
    let same = world.host_home.join("work/app");
    std::fs::create_dir_all(&same).unwrap();
    git(&same, &["init", "-q"]);
    git(&same, &["remote", "add", "origin", "https://github.com/manaflow-ai/app"]);
    let (code, answer) = world.stage(&world.repo);
    assert_eq!(code, 0, "{answer}");
    assert_eq!(answer["repo"], same.to_string_lossy().as_ref());
}

#[test]
fn stage_ssh_a_folder_outside_git_and_an_unreachable_host_are_refused_before_anything_changes() {
    let world = World::new();
    let plain = world.repo.parent().unwrap().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let (code, answer) = world.stage(&plain);
    assert_eq!((code, answer["error_code"].as_str()), (1, Some("stage.not_git")), "{answer}");

    let (code, answer) = world.stage_with(&world.repo, &[("FAKE_SSH_DOWN", "1")]);
    assert_eq!((code, answer["error_code"].as_str()), (1, Some("ssh_unreachable")), "{answer}");
    assert!(!world.host_home.join("work").exists());
}

#[test]
fn stage_ssh_usage_refuses_a_destination_that_reads_as_an_option_and_a_relative_folder() {
    let bin = env!("CARGO_BIN_EXE_cmux-tui");
    let run =
        |args: &[&str]| Command::new(bin).args(["link", "stage"]).args(args).output().unwrap();
    assert!(run(&["ssh", "--help"]).status.success());
    for bad in [
        &["ssh", "--to", "-oProxyCommand=touch /tmp/x", "--key", "k", "/tmp"][..],
        &["ssh", "--to", "mini", "--key", "k", "relative"],
        &["ssh", "--to", "mini", "--key", "..", "/tmp"],
        &["cloud", "--to", "mini", "--key", "k", "/tmp"],
    ] {
        assert_eq!(run(bad).status.code(), Some(64), "{bad:?}");
    }
}
