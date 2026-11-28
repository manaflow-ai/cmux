use super::*;
use crate::store::care_tests::scratch;

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

fn clone_pair(name: &str) -> (PathBuf, PathBuf) {
    let base = scratch(name);
    let origin = base.join("origin");
    std::fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "-b", "main"]);
    std::fs::write(origin.join("a"), "1").unwrap();
    git(&origin, &["add", "a"]);
    git(&origin, &["commit", "-q", "-m", "one"]);
    let clone = base.join("clone");
    git(&base, &["clone", "-q", "origin", "clone"]);
    (base, clone)
}

#[test]
fn a_pushed_clean_clone_has_nothing_to_keep() {
    let (base, clone) = clone_pair("clone-pushed");
    let store = Store::open(base.join("store")).unwrap();
    assert_eq!(work(&clone).unwrap(), Work::Pushed);
    assert_eq!(archive(&clone, &store, 1).unwrap(), None);
}

#[test]
fn local_commits_are_bundled_and_verified_before_anything_goes() {
    let (base, clone) = clone_pair("clone-unpushed");
    std::fs::write(clone.join("b"), "2").unwrap();
    git(&clone, &["add", "b"]);
    git(&clone, &["commit", "-q", "-m", "local"]);
    let store = Store::open(base.join("store")).unwrap();
    assert_eq!(work(&clone).unwrap(), Work::Unpushed(1));
    let id = archive(&clone, &store, 5).unwrap().expect("archived");
    let bundle = store.dir.join("clones").join(format!("{id}.bundle"));
    assert!(bundle.exists());
    crate::git::user_git(&clone, &["bundle", "verify", &bundle.to_string_lossy()], LIMIT).unwrap();
}

#[test]
fn detached_commits_keep_the_clone() {
    let (base, clone) = clone_pair("clone-detached-preserve");
    git(&clone, &["checkout", "--detach", "-q"]);
    std::fs::write(clone.join("a"), "detached work").unwrap();
    git(&clone, &["commit", "-qam", "detached"]);
    let store = Store::open(base.join("store")).unwrap();
    assert!(work(&clone).is_err());
    assert!(archive(&clone, &store, 1).is_err());
}

#[test]
fn ignored_local_data_keeps_the_clone() {
    let (base, clone) = clone_pair("clone-ignored-preserve");
    std::fs::write(clone.join(".git/info/exclude"), ".env\nlocal-db/\n").unwrap();
    std::fs::create_dir_all(clone.join("local-db")).unwrap();
    std::fs::write(clone.join("local-db/data"), "local data").unwrap();
    std::fs::write(clone.join(".env"), "local config").unwrap();
    let store = Store::open(base.join("store")).unwrap();
    assert!(work(&clone).is_err());
    assert!(archive(&clone, &store, 1).is_err());
}

#[test]
fn linked_worktree_data_keeps_the_common_clone() {
    let (base, clone) = clone_pair("clone-linked-preserve");
    git(&clone, &["worktree", "add", "-qb", "linked", "../linked"]);
    let linked = base.join("linked");
    std::fs::write(linked.join("a"), "staged only").unwrap();
    git(&linked, &["add", "a"]);
    std::fs::write(linked.join("a"), "1").unwrap();
    let store = Store::open(base.join("store")).unwrap();
    assert!(work(&clone).is_err());
    assert!(archive(&clone, &store, 1).is_err());
}

#[test]
fn submodule_object_stores_keep_the_clone() {
    let (base, clone) = clone_pair("clone-modules-preserve");
    git(
        &clone,
        &["-c", "protocol.file.allow=always", "submodule", "add", "-q", "../origin", "dep"],
    );
    git(&clone, &["commit", "-qam", "add submodule"]);
    git(&clone, &["push", "-q", "origin", "HEAD:refs/heads/with-module"]);
    let module = clone.join("dep");
    git(&module, &["checkout", "-qb", "local-only"]);
    std::fs::write(module.join("a"), "local module work").unwrap();
    git(&module, &["commit", "-qam", "local module commit"]);
    git(&module, &["checkout", "--detach", "-q", "HEAD~1"]);
    assert!(crate::git::user_git(&clone, &["status", "--porcelain=v1"], LIMIT).unwrap().is_empty());
    let store = Store::open(base.join("store")).unwrap();
    assert!(work(&clone).is_err());
    assert!(archive(&clone, &store, 1).is_err());
}

#[test]
fn dirty_stashed_or_remoteless_clones_are_kept() {
    let (base, clone) = clone_pair("clone-dirty");
    std::fs::write(clone.join("loose"), "x").unwrap();
    assert!(work(&clone).unwrap_err().contains("uncommitted"));
    let store = Store::open(base.join("store")).unwrap();
    assert!(archive(&clone, &store, 1).is_err());
    let alone = base.join("alone");
    std::fs::create_dir_all(&alone).unwrap();
    git(&alone, &["init", "-q"]);
    assert!(work(&alone).unwrap_err().contains("no remote"));
}

#[test]
fn ignored_local_files_keep_the_clone_but_build_output_does_not() {
    let (_base, clone) = clone_pair("clone-ignored");
    std::fs::write(clone.join(".git/info/exclude"), ".env\ntarget/\nnode_modules/\n").unwrap();
    std::fs::create_dir_all(clone.join("target/debug")).unwrap();
    std::fs::write(clone.join("target/debug/bin"), "x").unwrap();
    std::fs::create_dir_all(clone.join("node_modules/pkg")).unwrap();
    std::fs::write(clone.join("node_modules/pkg/i.js"), "x").unwrap();
    assert_eq!(work(&clone).unwrap(), Work::Pushed);
    std::fs::write(clone.join(".env"), "SECRET=1").unwrap();
    let error = work(&clone).unwrap_err();
    assert!(error.contains("ignored local files") && error.contains(".env"), "{error}");
}

#[test]
fn a_clone_with_linked_worktrees_is_kept() {
    let (base, clone) = clone_pair("clone-linked");
    let linked = base.join("linked");
    git(&clone, &["worktree", "add", "-q", "-b", "side", &linked.to_string_lossy()]);
    assert!(work(&clone).unwrap_err().contains("linked worktrees"));
}
