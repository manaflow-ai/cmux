//! The carry end to end against real git: a source checkout read by the script the CLI runs, its
//! work carried by `carry_worktree` into a machine whose shell is `sh` in a temp folder (its home
//! rewritten from [`MACHINE_HOME`]). Prints one `nothing-lost:` line of what arrived.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::*;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn sh(script: &str) -> Result<String, String> {
    use std::io::Write as _;
    let mut child = Command::new("sh")
        .arg("-s")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(script.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).into_owned())
    }
}

/// A machine that is a folder here.
struct Machine {
    home: PathBuf,
}

impl Machine {
    fn here(&self, text: &str) -> String {
        text.replace(MACHINE_HOME, self.home.to_str().unwrap())
    }
}

impl Cloud for Machine {
    fn create_machine(&mut self, _: &str, _: Option<&str>, _: &str) -> Result<Created, String> {
        unreachable!()
    }
    fn deliver_secrets(&mut self, _: &str, _: &[String]) -> Result<Vec<String>, String> {
        unreachable!()
    }
    fn write_file(&mut self, _: &str, path: &str, text: &str) -> Result<(), String> {
        let path = PathBuf::from(self.here(path));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).map_err(|e| e.to_string())
    }
    fn exec(&mut self, _: &str, command: &str) -> Result<String, String> {
        sh(&self.here(command))
    }
    fn delete_machine(&mut self, _: &str) -> Result<(), String> {
        unreachable!()
    }
}

/// `git status --porcelain` with the file contents it names, for comparing two trees.
fn state(dir: &Path) -> String {
    let status = git(dir, &["status", "--porcelain", "--untracked-files=all"]);
    let mut out = status.clone();
    for line in status.lines() {
        let path = &line[3..];
        let text = std::fs::read_to_string(dir.join(path)).unwrap_or_else(|_| "<gone>".into());
        out.push_str(&format!("\n{path}={text}"));
    }
    out
}

/// Carries `source` into a machine whose clone (when `origin`) is made first, and says what arrived.
fn carry(tmp: &Path, source: &Path, origin: Option<&Path>) -> (PathBuf, String) {
    let home = tmp.join("machine");
    let checkout = home.join("work/app");
    std::fs::create_dir_all(home.join("work")).unwrap();
    if let Some(origin) = origin {
        git(tmp, &["clone", "--quiet", origin.to_str().unwrap(), checkout.to_str().unwrap()]);
    }
    let index_before = std::fs::read(source.join(".git/index")).ok();
    let work = parse_work(&sh(&work_script(source.to_str().unwrap())).unwrap()).unwrap();
    assert_eq!(std::fs::read(source.join(".git/index")).ok(), index_before, "index touched");
    let mut machine = Machine { home: home.clone() };
    let mut done = Vec::new();
    let said =
        carry_worktree(&mut machine, &mut done, "m1", &work, &format!("{MACHINE_HOME}/work/app"))
            .unwrap();
    (checkout, said)
}

#[test]
fn dirty_files_and_unpushed_commits_arrive_exactly_through_a_bundle() {
    let tmp = tempfile::tempdir().unwrap();
    let tmp = tmp.path();
    let (origin, src) = (tmp.join("origin.git"), tmp.join("src"));
    git(tmp, &["init", "--quiet", "--bare", origin.to_str().unwrap()]);
    git(tmp, &["clone", "--quiet", origin.to_str().unwrap(), src.to_str().unwrap()]);
    for (file, text) in [("a.txt", "one\n"), ("gone.txt", "bye\n"), ("keep.txt", "k\n")] {
        std::fs::write(src.join(file), text).unwrap();
    }
    git(&src, &["add", "."]);
    git(&src, &["commit", "--quiet", "-m", "first"]);
    git(&src, &["push", "--quiet", "-u", "origin", "HEAD:main"]);
    // Unpushed: a side branch merged back (a merge commit) and a second local branch.
    git(&src, &["checkout", "--quiet", "-b", "side"]);
    std::fs::write(src.join("side.txt"), "s\n").unwrap();
    git(&src, &["add", "side.txt"]);
    git(&src, &["commit", "--quiet", "-m", "side"]);
    git(&src, &["checkout", "--quiet", "main"]);
    std::fs::write(src.join("a.txt"), "two\n").unwrap();
    git(&src, &["commit", "--quiet", "-am", "second"]);
    git(&src, &["merge", "--quiet", "--no-ff", "-m", "merge side", "side"]);
    git(&src, &["tag", "-a", "v1", "-m", "v1"]);
    // Dirty: a change, a deletion, a staged new file and an untracked one.
    std::fs::write(src.join("a.txt"), "three\n").unwrap();
    std::fs::remove_file(src.join("gone.txt")).unwrap();
    std::fs::write(src.join("staged.txt"), "st\n").unwrap();
    git(&src, &["add", "staged.txt"]);
    std::fs::write(src.join("new.txt"), "fresh\n").unwrap();

    let (dst, said) = carry(tmp, &src, Some(&origin));
    let head_kept = git(&src, &["rev-parse", "HEAD"]) == git(&dst, &["rev-parse", "HEAD"]);
    let merges = git(&dst, &["rev-list", "--merges", "--count", "HEAD"]);
    let side_kept = git(&src, &["rev-parse", "side"]) == git(&dst, &["rev-parse", "side"]);
    let tag_kept = git(&dst, &["tag", "--list", "v1"]) == "v1";
    let branch = git(&dst, &["symbolic-ref", "--short", "HEAD"]);
    // The staged file arrives untracked: a move keeps the files, not what was staged.
    let sorted = |s: String| {
        let mut l: Vec<&str> = s.lines().collect();
        l.sort_unstable();
        l.join("\n")
    };
    let want = sorted(state(&src).replace("A  staged.txt", "?? staged.txt"));
    let got = sorted(state(&dst));
    let tree_kept = got == want;
    eprintln!(
        "nothing-lost: remote head_kept={head_kept} merges={merges} side_kept={side_kept} \
         tag_kept={tag_kept} tree_kept={tree_kept} ({said})"
    );
    assert!(head_kept && side_kept && tag_kept, "{said}");
    assert_eq!((merges.as_str(), branch.as_str()), ("1", "main"));
    assert_eq!(got, want);
    assert!(said.contains("3 commit(s) and 4 changed file(s)"), "{said}");
}

#[test]
fn a_checkout_with_no_remote_arrives_with_its_whole_history() {
    let tmp = tempfile::tempdir().unwrap();
    let tmp = tmp.path();
    let src = tmp.join("src");
    std::fs::create_dir_all(&src).unwrap();
    git(&src, &["init", "--quiet"]);
    for n in 1..=3 {
        std::fs::write(src.join(format!("f{n}.txt")), format!("{n}\n")).unwrap();
        git(&src, &["add", "."]);
        git(&src, &["commit", "--quiet", "-m", &format!("c{n}")]);
    }
    std::fs::write(src.join("f1.txt"), "changed\n").unwrap();
    std::fs::write(src.join("loose.txt"), "l\n").unwrap();

    let (dst, said) = carry(tmp, &src, None);
    let commits = git(&dst, &["rev-list", "--count", "HEAD"]);
    let files = git(&dst, &["ls-files"]).lines().count();
    let head_kept = git(&src, &["rev-parse", "HEAD"]) == git(&dst, &["rev-parse", "HEAD"]);
    let tree_kept = state(&dst) == state(&src);
    eprintln!(
        "nothing-lost: no-remote commits={commits}/3 tracked_files={files}/3 \
         head_kept={head_kept} tree_kept={tree_kept} ({said})"
    );
    assert_eq!((commits.as_str(), files), ("3", 3));
    assert!(head_kept && tree_kept, "{said}");
}

#[test]
fn a_checkout_with_no_commits_yet_arrives_as_untracked_files() {
    let tmp = tempfile::tempdir().unwrap();
    let tmp = tmp.path();
    let src = tmp.join("src");
    std::fs::create_dir_all(&src).unwrap();
    git(&src, &["init", "--quiet"]);
    std::fs::write(src.join("draft.txt"), "d\n").unwrap();
    let (dst, _) = carry(tmp, &src, None);
    assert_eq!(state(&dst), state(&src));
}
