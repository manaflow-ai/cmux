//! A folder of clones (issue 57201): which nested repositories swap, where each one's machine
//! repository lives, and what Bring Back reads of a swapped nested `.git` (the listing through
//! [`crate::layer::Layer::collect`] and the mark). No mount needed: [`prepare`] reads the `.git`
//! folder it is given, and the upper layer's link is made as [`run_nested`] leaves it.

use std::path::{Path, PathBuf};

use super::*;
use crate::layer::Layer;
use crate::manifest::Kind;

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn a_folder_of_clones_swaps_each_clone_and_nothing_below_one() {
    let dir = tempfile::tempdir().unwrap();
    let at = dir.path();
    for repo in ["cmux-pr-20415", "cmux-pr-38675", "work/deep/clone", "a/b/c/too-deep"] {
        std::fs::create_dir_all(at.join(repo).join(".git")).unwrap();
    }
    // Below a clone (its own work tree), in a hidden folder or build output: never a clone.
    std::fs::create_dir_all(at.join("cmux-pr-20415/sub/lib/.git")).unwrap();
    std::fs::create_dir_all(at.join(".claude/worktrees/x/.git")).unwrap();
    std::fs::create_dir_all(at.join("node_modules/pkg/.git")).unwrap();
    // A `.git` file (a linked worktree) is not a repository the swap copies.
    std::fs::create_dir_all(at.join("linked")).unwrap();
    std::fs::write(at.join("linked/.git"), "gitdir: /elsewhere\n").unwrap();
    assert_eq!(nested_repositories(at), ["cmux-pr-20415", "cmux-pr-38675", "work/deep/clone"]);

    // A folder that is a repository swaps by carry, and what is below it is its work tree.
    std::fs::create_dir_all(at.join(".git")).unwrap();
    assert!(nested_repositories(at).is_empty());
}

#[test]
fn each_nested_repository_has_its_own_machine_repository() {
    let state = Path::new("/state/chat-1");
    assert_eq!(local_dir(state, ""), state.join(LOCAL_DIR));
    let a = local_dir(state, "cmux-pr-20415");
    let b = local_dir(state, "cmux-pr-38675");
    assert_ne!(a, b);
    assert_ne!(a, local_dir(state, ""));
    assert_eq!(a, local_dir(state, "cmux-pr-20415"), "the same folder each time");
    assert_eq!(a.parent(), Some(state));
}

struct Swapped {
    _dir: tempfile::TempDir,
    mac: PathBuf,
    machine: PathBuf,
    state: PathBuf,
    local: PathBuf,
}

/// A Mac folder of clones with `app/` a clone of a public remote and one unpushed commit, its
/// `.git` swapped as [`run_nested`] does it (prepared, its packs and the nested list recorded,
/// the upper layer's `app/.git` a link), and the machine's work tree of it.
fn swapped() -> Swapped {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let public = root.join("public.git");
    std::fs::create_dir_all(&public).unwrap();
    sh(&public, &["init", "--bare", "--quiet", "-b", "main"]);
    sh(&public, &["config", "uploadpack.allowFilter", "true"]);
    sh(&public, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    let url = format!("file://{}", public.display());
    let mac = root.join("mac");
    std::fs::create_dir_all(&mac).unwrap();
    sh(&mac, &["clone", "--quiet", &url, "app"]);
    let app = mac.join("app");
    sh(&app, &["checkout", "--quiet", "-b", "main"]);
    for n in 0..3 {
        std::fs::write(app.join("README.md"), format!("version {n}\n")).unwrap();
        sh(&app, &["add", "-A"]);
        sh(&app, &["commit", "--quiet", "-m", &format!("pushed {n}")]);
    }
    sh(&app, &["push", "--quiet", "-u", "origin", "main"]);
    std::fs::write(app.join("unpushed.txt"), "only on the mac\n").unwrap();
    sh(&app, &["add", "unpushed.txt"]);
    sh(&app, &["commit", "--quiet", "-m", "unpushed"]);
    sh(&app, &["gc", "--quiet"]);

    let state = root.join("state");
    let local = local_dir(&state, "app");
    std::fs::create_dir_all(state.join("upper/app")).unwrap();
    prepare(&app.join(".git"), &local, &url).unwrap();
    record_swap_packs(&local).unwrap();
    record_nested(&state, "app").unwrap();
    std::os::unix::fs::symlink(&local, state.join("upper/app/.git")).unwrap();
    let machine = root.join("machine");
    std::fs::create_dir_all(&machine).unwrap();
    for name in ["README.md", "unpushed.txt"] {
        std::fs::copy(app.join(name), machine.join(name)).unwrap();
    }
    std::os::unix::fs::symlink(&local, machine.join(".git")).unwrap();
    Swapped { _dir: dir, mac: app, machine, state, local }
}

fn git_paths(layer: &Layer) -> Vec<(String, Kind)> {
    layer
        .upper
        .iter()
        .filter(|entry| entry.path.starts_with("app/.git"))
        .map(|entry| (entry.path.clone(), entry.kind))
        .collect()
}

#[test]
fn bring_back_reads_a_swapped_nested_git_without_the_packs_it_had_at_the_swap() {
    let s = swapped();
    assert!(!swap_packs(&s.local).is_empty(), "the swap's fetch made packs");
    let layer = Layer::collect(&s.state).unwrap();
    let paths = git_paths(&layer);
    assert!(paths.contains(&("app/.git".into(), Kind::Dir)), "{paths:?}");
    assert!(paths.contains(&("app/.git/HEAD".into(), Kind::File)), "{paths:?}");
    assert!(paths.contains(&("app/.git/index".into(), Kind::File)), "{paths:?}");
    assert!(
        !paths.iter().any(|(path, _)| path.starts_with("app/.git/objects/pack/pack-")),
        "the remote's and the Mac's objects stay on the machine: {paths:?}"
    );
    assert!(!layer.upper.iter().any(|entry| entry.kind == Kind::Link), "no link to the state");

    // The agent commits on the machine: a write of the chat, and its objects are listed.
    let before = crate::state::mark(&s.state).unwrap();
    std::fs::write(s.machine.join("made-here.txt"), "the machine's file\n").unwrap();
    sh(&s.machine, &["add", "made-here.txt"]);
    sh(&s.machine, &["commit", "--quiet", "-m", "on the machine"]);
    let commit = sh(&s.machine, &["rev-parse", "HEAD"]);
    let after = crate::state::mark(&s.state).unwrap();
    assert_ne!(before, after, "a commit in a nested machine repository keeps the projection");
    let layer = Layer::collect(&s.state).unwrap();
    assert_eq!(crate::state::mark(&s.state).unwrap(), after, "reading the layer writes nothing");

    // What the Mac's git leg does with them: the listed objects in a quarantine borrowing the
    // Mac's objects hold the new commit, and its whole history reads.
    let quarantine = s.mac.parent().unwrap().join("quarantine.git");
    sh(s.mac.parent().unwrap(), &["init", "--bare", "--quiet", "quarantine.git"]);
    let alternates = format!("{}\n", s.mac.join(".git/objects").display());
    std::fs::write(quarantine.join("objects/info/alternates"), alternates).unwrap();
    let mut copied = 0;
    for entry in &layer.upper {
        let Some(relative) = entry.path.strip_prefix("app/.git/objects/") else { continue };
        if entry.kind != Kind::File || relative.starts_with("info") {
            continue;
        }
        let from = s.local.join("objects").join(relative);
        let to = quarantine.join("objects").join(relative);
        std::fs::create_dir_all(to.parent().unwrap()).unwrap();
        std::fs::copy(from, to).unwrap();
        copied += 1;
    }
    assert!(copied >= 3, "the commit, its tree and the new blob: {copied}");
    sh(&quarantine, &["fsck", "--connectivity-only", "--no-dangling", commit.trim()]);
    let walked = sh(&quarantine, &["rev-list", commit.trim()]);
    assert_eq!(walked.lines().count(), 5, "the machine's commit on the Mac's four: {walked}");
}

#[test]
fn a_nested_list_entry_whose_link_is_gone_or_another_is_no_swap() {
    let s = swapped();
    assert_eq!(swapped_repositories(&s.state).unwrap(), [("app".to_owned(), s.local.clone())]);
    // Listed before its link exists (a swap cut short), or a path that is not plain.
    record_nested(&s.state, "never-linked").unwrap();
    std::fs::write(
        s.state.join(NESTED),
        format!("{}../escape\n", std::fs::read_to_string(s.state.join(NESTED)).unwrap()),
    )
    .unwrap();
    assert_eq!(swapped_repositories(&s.state).unwrap().len(), 1);
    // The agent replaced the link: its `.git` is no longer the swap's.
    std::fs::remove_file(s.state.join("upper/app/.git")).unwrap();
    std::os::unix::fs::symlink("/elsewhere", s.state.join("upper/app/.git")).unwrap();
    assert!(swapped_repositories(&s.state).unwrap().is_empty());
    let layer = Layer::collect(&s.state).unwrap();
    assert!(
        layer.upper.iter().any(|entry| entry.path == "app/.git" && entry.kind == Kind::Link),
        "an ordinary link stays a link"
    );
}
