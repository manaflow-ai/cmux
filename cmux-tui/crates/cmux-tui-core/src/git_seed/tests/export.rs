//! `git.seed.export`: the machine's changes since a seed, as one bundle the
//! Mac can fetch, and nothing when nothing changed.

use super::*;

/// A seeded folder (the Mac's `dirty_branch`) and the seed's commits.
fn seeded(label: &str) -> (World, PathBuf, Snapshot) {
    let world = World::new(label);
    dirty_branch(&world);
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("work/project");
    let status = seed(&world, &world.start_params(&folder, &first));
    assert_eq!(status["state"], "done", "{status}");
    (world, folder, first)
}

fn export_params(folder: &Path, since: &Snapshot, bundle: &Path) -> Value {
    json!({ "folder": folder, "since_work": since.work, "since_head": since.head, "bundle": bundle })
}

/// Runs one export to its end; its last status.
fn export(service: &GitSeedService, params: &Value) -> Value {
    let answer = service.call("git.seed.export", params).unwrap();
    wait(service, answer["job"].as_str().unwrap())
}

/// The bundle's refs fetched into a bare copy of the Mac's repository, as
/// the Mac's quarantine does: `refs/cmux-back/*` by name.
fn fetch_bundle(world: &World, bundle: &Path) -> PathBuf {
    let into = world.home.join("fetched.git");
    if !into.exists() {
        git(
            &world.home.path,
            &["clone", "-q", "--mirror", world.mac.to_str().unwrap(), into.to_str().unwrap()],
        );
    }
    git(&into, &["bundle", "verify", "-q", bundle.to_str().unwrap()]);
    git(
        &into,
        &[
            "-c",
            "transfer.fsckObjects=true",
            "fetch",
            "-q",
            bundle.to_str().unwrap(),
            "+refs/cmux-back/*:refs/cmux-back/*",
        ],
    );
    into
}

#[test]
fn an_export_of_an_unchanged_seed_is_unchanged_and_writes_nothing() {
    let (world, folder, first) = seeded("export-same");
    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let status = export(&service, &export_params(&folder, &first, &bundle));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["unchanged"], true, "{status}");
    assert_eq!(status["work"], first.work.as_str(), "the same commit as the Mac's WORK");
    assert_eq!(status["index"], first.index.as_str());
    assert_eq!(status["head"], first.head.as_str());
    assert_eq!(status["bundle_bytes"], 0);
    assert!(!bundle.exists(), "nothing to download");
}

#[test]
fn an_export_carries_commits_edits_adds_deletes_and_staged_changes() {
    let (world, folder, first) = seeded("export-all");
    write(&folder.join("b"), "b\nunpushed\ncommitted on the machine\n");
    git(&folder, &["commit", "-q", "-a", "-m", "on the machine"]);
    write(&folder.join("a"), "a\nedited on the machine\n");
    write(&folder.join("made.txt"), "made\n");
    std::fs::remove_file(folder.join("d/c")).unwrap();
    write(&folder.join("d/new"), "new\nstaged on the machine\n");
    git(&folder, &["add", "d/new"]);
    write(&folder.join("ignored/build.out"), "ignored\n");
    write(&folder.join(".env"), "SECRET=1\n");
    let inner = folder.join("inner");
    std::fs::create_dir_all(&inner).unwrap();
    git(&inner, &["init", "-q"]);

    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let status = export(&service, &export_params(&folder, &first, &bundle));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["unchanged"], false);
    assert_eq!(status["head_ref"], "refs/heads/feature");
    assert_eq!(status["head"], git(&folder, &["rev-parse", "HEAD"]).as_str());
    assert!(status["bundle_bytes"].as_u64().unwrap() > 0);
    let left_out: Vec<&str> =
        status["left_out"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(left_out.contains(&".env") && left_out.contains(&"inner/"), "{left_out:?}");
    let mode = std::fs::metadata(&bundle).unwrap().permissions();
    assert_eq!(std::os::unix::fs::PermissionsExt::mode(&mode) & 0o777, 0o600);

    let heads = git(&world.home.path, &["bundle", "list-heads", bundle.to_str().unwrap()]);
    for name in ["head", "index", "work"] {
        assert!(heads.contains(&format!("refs/cmux-back/{name}")), "{heads}");
    }
    let fetched = fetch_bundle(&world, &bundle);
    let work = status["work"].as_str().unwrap();
    let files = git(&fetched, &["ls-tree", "-r", "--name-only", work]);
    let files: Vec<&str> = files.lines().collect();
    assert!(files.contains(&"made.txt") && files.contains(&"d/new"), "{files:?}");
    assert!(!files.contains(&"d/c"), "the delete");
    for left in [".env", "inner", "ignored/build.out"] {
        assert!(!files.iter().any(|file| file.starts_with(left)), "{left}: {files:?}");
    }
    assert_eq!(git(&fetched, &["show", &format!("{work}:a")]), "a\nedited on the machine");
    let index = status["index"].as_str().unwrap();
    assert_eq!(
        git(&fetched, &["rev-parse", &format!("{index}^{{tree}}")]),
        git(&folder, &["write-tree"])
    );
    assert_eq!(git(&fetched, &["rev-parse", &format!("{work}^1")]), index);
    // Recorded on the machine, out of gc's reach.
    assert_eq!(git(&folder, &["rev-parse", "refs/cmux-back/work"]), work);
    // The same state exports to the same commits.
    let again = world.home.join("again.bundle");
    let second = export(&service, &export_params(&folder, &first, &again));
    assert_eq!(second["work"], status["work"]);
}

/// A delta seed may build on an export the Mac merged back: `since` is the
/// export's WORK.
#[test]
fn a_delta_seed_builds_on_an_export() {
    let (world, folder, first) = seeded("export-delta");
    write(&folder.join("a"), "a\nfrom the machine\n");
    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let status = export(&service, &export_params(&folder, &first, &bundle));
    assert_eq!(status["state"], "done", "{status}");
    // The Mac takes the machine's state as it is (what a clean pull does).
    let mac = &world.mac;
    git(mac, &["fetch", "-q", bundle.to_str().unwrap(), "+refs/cmux-back/*:refs/back/*"]);
    let (work, index) = (status["work"].as_str().unwrap(), status["index"].as_str().unwrap());
    git(mac, &["read-tree", "-u", "--reset", work]);
    git(mac, &["read-tree", index]);
    let exported = Snapshot {
        bundle,
        head_ref: first.head_ref.clone(),
        head: status["head"].as_str().unwrap().to_owned(),
        index: index.to_owned(),
        work: work.to_owned(),
        stash: first.stash,
    };
    write(&mac.join("b"), "b\nnext from the mac\n");
    let next = world.snapshot("two", &[&exported.work, &exported.head]);
    let mut params = world.start_params(&folder, &next);
    params["since"] = exported.work.clone().into();
    params["base"] = exported.work.into();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(mac));
}

#[test]
fn an_export_is_refused_outside_a_seed_or_into_its_folder() {
    let (world, folder, first) = seeded("export-bad");
    let service = world.service();
    let inside = folder.join("back.bundle");
    let refusal =
        service.call("git.seed.export", &export_params(&folder, &first, &inside)).unwrap_err();
    assert_eq!(refusal.code, "seed.bad_request", "a bundle in the folder");
    let plain = world.home.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let bundle = world.home.join("back.bundle");
    let refusal =
        service.call("git.seed.export", &export_params(&plain, &first, &bundle)).unwrap_err();
    assert_eq!(refusal.code, "seed.since_mismatch");
    let mut params = export_params(&folder, &first, &bundle);
    params["since_work"] = "--upload-pack=x".into();
    assert_eq!(service.call("git.seed.export", &params).unwrap_err().code, "seed.bad_request");
    params["since_work"] = "0".repeat(40).into();
    let status = export(&service, &params);
    assert_eq!(status["error_code"], "seed.since_mismatch", "{status}");
    assert!(!bundle.exists());
}

/// A secret whose name is not UTF-8 stays out of WORK: it is excluded by
/// its raw name, never by a lossy spelling.
#[test]
fn a_secret_with_a_non_utf8_name_never_goes() {
    use std::os::unix::ffi::OsStrExt as _;
    let (world, folder, first) = seeded("export-nonutf8");
    let name = std::ffi::OsStr::from_bytes(b".env-\xff");
    std::fs::write(folder.join(name), "SECRET=1\n").unwrap();
    write(&folder.join("a"), "a\nchanged\n");
    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let status = export(&service, &export_params(&folder, &first, &bundle));
    assert_eq!(status["state"], "done", "{status}");
    let fetched = fetch_bundle(&world, &bundle);
    let work = status["work"].as_str().unwrap();
    let files = git(&fetched, &["ls-tree", "-r", "-z", "--name-only", work]);
    assert!(!files.contains(".env"), "{files:?}");
    let grep = Command::new("git")
        .arg("-C")
        .arg(&fetched)
        .args(["grep", "-q", "SECRET", work])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(!grep.success(), "the secret's contents went in WORK");
}

/// A retry of a finished export whose answer was lost is the same job,
/// even though its bundle now exists.
#[test]
fn a_retried_export_returns_the_same_job() {
    let (world, folder, first) = seeded("export-retry");
    write(&folder.join("a"), "a\nchanged\n");
    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let params = export_params(&folder, &first, &bundle);
    let job = service.call("git.seed.export", &params).unwrap()["job"].clone();
    assert_eq!(wait(&service, job.as_str().unwrap())["state"], "done");
    assert!(bundle.exists());
    assert_eq!(service.call("git.seed.export", &params).unwrap()["job"], job);
}

/// A change to the stash alone is a change: its objects go in a bundle.
#[test]
fn a_stash_only_change_is_exported() {
    let (world, folder, first) = seeded("export-stash");
    // `b` is clean in the seed: stashing only it leaves WORK as it was.
    write(&folder.join("b"), "b\nunpushed\nstashed on the machine\n");
    git(&folder, &["stash", "push", "-q", "--", "b"]);
    let service = world.service();
    let bundle = world.home.join("back.bundle");
    let status = export(&service, &export_params(&folder, &first, &bundle));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["work"], first.work.as_str(), "the working tree is the seed's");
    assert_eq!(status["unchanged"], false, "{status}");
    let stash = status["stash"].as_str().unwrap();
    let fetched = fetch_bundle(&world, &bundle);
    assert_eq!(git(&fetched, &["rev-parse", "refs/cmux-back/stash"]), stash);
}
