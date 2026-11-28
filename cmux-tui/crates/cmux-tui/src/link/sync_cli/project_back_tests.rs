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
fn detach_record_preserves_manual_names_and_disambiguates_shared_folders() {
    let record = |name: &str| Recorded {
        name: name.to_owned(),
        remote: "/remote/shared".into(),
        local: "/local/shared".into(),
    };
    let manual = record("manual");
    assert_eq!(detach_record([manual.clone()].into_iter(), None).unwrap(), manual);
    let other = record("chat-page-key");
    let records = [manual.clone(), other.clone()];
    assert!(detach_record(records.clone().into_iter(), None).is_err());
    assert!(detach_record(records.clone().into_iter(), Some("chat-removing")).is_err());
    assert_eq!(detach_record(records.into_iter(), Some(&other.name)).unwrap(), other);
}

#[test]
fn detach_reports_server_cleanup_failure_without_losing_the_detached_state() {
    let detached = json!({"data": {"mark": "retained-edits", "was_mounted": true}});
    let failure = anyhow::anyhow!("permission denied").context("opening the registration lock");
    let answer = detached_answer(&detached, Err(failure));
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["detached"], true);
    assert_eq!(answer["mark"], "retained-edits");
    assert_eq!(answer["was_mounted"], true);
    assert_eq!(answer["server_stopped"], false);
    assert_eq!(answer["error_code"], "projection.stop_failed");
    assert_eq!(
        answer["error"],
        "the folder detached, but its server could not be stopped: opening the registration lock: permission denied"
    );
}

#[test]
fn detach_distinguishes_stopping_its_server_from_leaving_a_replacement_running() {
    let detached = json!({"data": {"mark": "retained-edits", "was_mounted": false}});
    for stopped in [false, true] {
        let answer = detached_answer(&detached, Ok(stopped));
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["detached"], true);
        assert_eq!(answer["server_stopped"], stopped);
        assert_eq!(answer["was_mounted"], false);
        assert!(answer.get("error").is_none());
    }
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
