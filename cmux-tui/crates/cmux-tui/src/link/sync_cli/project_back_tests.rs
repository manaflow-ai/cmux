use super::*;
use cmux_projection::manifest::Item;

fn file(path: &str) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size: 1, mtime_ns: 1, link: None }
}

#[test]
fn a_new_path_belongs_to_the_nearest_repository_the_manifest_lists() {
    let manifest = Manifest::build(
        1,
        vec![file("top.txt"), file("app/.git/HEAD"), file("app/src/a.rs"), file(".git/HEAD")],
    )
    .unwrap();
    assert_eq!(repository_of(&manifest, "app/src/new.rs").as_deref(), Some("app"));
    assert_eq!(repository_of(&manifest, "app/target/x.o").as_deref(), Some("app"));
    assert_eq!(repository_of(&manifest, "notes/n.md").as_deref(), Some(""));
    let plain = Manifest::build(1, vec![file("notes/n.md")]).unwrap();
    assert_eq!(repository_of(&plain, "notes/new.md"), None);
}

#[test]
fn ignored_new_paths_stay_on_the_machine_and_edits_of_listed_files_never_do() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().join("app");
    std::fs::create_dir_all(&repo).unwrap();
    let init = std::process::Command::new("git").arg("-C").arg(&repo).args(["init", "-q"]).status();
    assert!(init.unwrap().success());
    std::fs::write(repo.join(".gitignore"), "target/\n*.log\n").unwrap();
    let manifest = Manifest::build(
        1,
        vec![file("app/.git/HEAD"), file("app/.gitignore"), file("app/debug.log")],
    )
    .unwrap();
    let write = |path: &str, kind: Kind, replaces: Option<Kind>| way_back::Write {
        path: path.into(),
        kind,
        mode: 0o644,
        link: None,
        replaces,
    };
    let mut plan = Plan {
        writes: vec![
            write("app/target", Kind::Dir, None),
            write("app/target/debug/x.o", Kind::File, None),
            write("app/new.log", Kind::File, None),
            write("app/src/new.rs", Kind::File, None),
            // A file the manifest listed comes back even when git would ignore it now.
            write("app/debug.log", Kind::File, Some(Kind::File)),
        ],
        ..Plan::default()
    };
    let ignored = keep_ignored_home(root.path(), &manifest, &mut plan).unwrap();
    // The outermost ignored paths: a file under an ignored folder goes with it.
    assert_eq!(ignored, ["app/new.log", "app/target"]);
    let kept: Vec<&str> = plan.writes.iter().map(|write| write.path.as_str()).collect();
    assert_eq!(kept, ["app/src/new.rs", "app/debug.log"]);
}

#[test]
fn files_come_over_in_bounded_batches_in_order() {
    let paths: Vec<String> = (0..10_000).map(|n| format!("f{n:05}")).collect();
    let runs = batches(&paths, |_| 1);
    assert_eq!(runs.iter().map(|run| run.len()).collect::<Vec<_>>(), [4096, 4096, 1808]);
    assert_eq!(runs.concat(), paths);

    // Bytes cut too, and a file past the byte bound goes alone rather than never.
    let paths: Vec<String> = ["a", "huge", "b", "c"].map(String::from).to_vec();
    let size = |path: &str| if path == "huge" { BATCH_BYTES * 2 } else { BATCH_BYTES / 2 };
    let runs = batches(&paths, size);
    assert_eq!(runs, [&paths[0..1], &paths[1..2], &paths[2..4]]);
    assert!(batches(&[], |_| 0).is_empty());
}
