//! A fresh folder from a warm mirror's objects through alternates (no clone, no carry), the
//! carry or the clone again whenever the mirror cannot be used, and the promisor sources in the
//! order git tries them.

use std::path::{Path, PathBuf};

use super::*;

fn notes(status: &Value) -> Vec<String> {
    status["notes"]
        .as_array()
        .map(|notes| notes.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// A bare mirror of "GitHub" as `wt` keeps one: `origin` the GitHub URL, its branches under
/// `refs/remotes/origin/`.
fn mirror(world: &World, name: &str, origin: &str) -> PathBuf {
    let mirror = world.home.join(name);
    let (from, to) = (world.remote.to_str().unwrap(), mirror.to_str().unwrap());
    git(&world.home.path, &["clone", "-q", "--bare", from, to]);
    git(&mirror, &["config", "remote.origin.url", origin]);
    git(&mirror, &["update-ref", "refs/remotes/origin/feature", &world.base]);
    mirror
}

fn config(folder: &Path, key: &str) -> String {
    git(folder, &["config", "--get", key])
}

#[test]
fn a_borrowed_seed_needs_no_remote_and_tracks_the_mirrors_branch() {
    let world = World::new("borrow");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let mirror = mirror(&world, "mirror.git", "git@github.com:o/n.git");
    // No GitHub at all: a clone or a fetch would fail the seed.
    std::fs::remove_dir_all(&world.remote).unwrap();
    let folder = world.home.join("work/project");
    let mut params = world.start_params(&folder, &snapshot);
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrowed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    let alternates = std::fs::read_to_string(folder.join(".git/objects/info/alternates")).unwrap();
    assert_eq!(alternates.trim(), mirror.join("objects").canonicalize().unwrap().to_str().unwrap());
    assert_eq!(git(&folder, &["remote", "get-url", "origin"]), URL);
    assert_eq!(config(&folder, "remote.origin.promisor"), "true");
    assert_eq!(config(&folder, "extensions.partialClone"), "origin");
    assert_eq!(
        git(&folder, &["rev-parse", "--abbrev-ref", "feature@{upstream}"]),
        "origin/feature"
    );
    assert!(!snapshot.bundle.exists(), "the applied bundle is deleted");
    git(&folder, &["fsck", "--connectivity-only", "--no-dangling"]);
}

#[test]
fn a_mirror_of_another_repository_clones_instead() {
    let mut world = World::new("borrow-other");
    // The `wt` mirror's fallback is a direct clone here, not the machine's warm mirror
    // (`tests/mirror.rs`), whose alternates would be in the folder too.
    world.mirrors = None;
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let mirror = mirror(&world, "mirror.git", "https://github.com/o/other.git");
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrow_failed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert!(!folder.join(".git/objects/info/alternates").exists());
}

#[test]
fn a_mirror_without_the_base_clones_instead() {
    let mut world = World::new("borrow-stale");
    // The `wt` mirror's fallback is a direct clone here, not the machine's warm mirror
    // (`tests/mirror.rs`), whose alternates would be in the folder too.
    world.mirrors = None;
    let mirror = mirror(&world, "mirror.git", URL);
    write(&world.mac.join("a"), "a\nnext\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "next"]);
    git(&world.mac, &["push", "-q", "origin", "HEAD:main"]);
    let base = git(&world.mac, &["rev-parse", "HEAD"]);
    let snapshot = world.snapshot("one", &[&base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["base"] = json!(base);
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrow_failed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert!(!folder.join(".git/objects/info/alternates").exists());
}

#[test]
fn promisors_become_remotes_in_the_order_git_tries_them() {
    let world = World::new("promisors");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let peer = mirror(&world, "peer.git", URL);
    let stranger = mirror(&world, "stranger.git", "https://github.com/o/other.git");
    let pack = world.home.join("carry.pack");
    let out = std::fs::File::create(&pack).unwrap();
    let mut child = Command::new("git")
        .arg("-C")
        .arg(&world.mac)
        .args(["pack-objects", "--revs", "--stdout", "-q"])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdin(std::process::Stdio::piped())
        .stdout(out)
        .spawn()
        .unwrap();
    use std::io::Write as _;
    let base = &world.base;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("--shallow {base}\n{base}\n").as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["carry"] = json!(pack);
    params["promisors"] = json!([stranger, peer, URL]);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"carried".to_owned()), "{status}");
    assert!(notes(&status).contains(&"promisor_skipped".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    // Config order is the order git tries; the `extensions.partialClone` one goes last.
    let promisors = git(&folder, &["config", "--get-regexp", r"^remote\..*\.promisor$"]);
    assert_eq!(promisors, "remote.cmux-promisor-1.promisor true\nremote.origin.promisor true");
    assert_eq!(config(&folder, "remote.cmux-promisor-1.url"), peer.to_str().unwrap());
    assert_eq!(config(&folder, "extensions.partialClone"), "origin");
}

#[test]
fn an_absent_mirror_clones_instead() {
    let world = World::new("promisors-none");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["mirror"] = json!(world.home.join("absent.git"));
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrow_failed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
}

#[test]
fn mirror_and_promisors_are_refused_where_they_cannot_apply() {
    let world = World::new("borrow-params");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let service = world.service();
    let refused = |params: &Value| start(&service, params).unwrap_err().code;
    let mut delta = world.start_params(&folder, &snapshot);
    delta["since"] = json!(world.base);
    delta["mirror"] = json!("/m");
    assert_eq!(refused(&delta), "seed.bad_request");
    let mut clone = clone_params(&folder, None);
    clone["promisors"] = json!([URL]);
    assert_eq!(refused(&clone), "seed.bad_request");
    for (key, value) in [
        ("mirror", json!("relative")),
        ("mirror", json!("/a/../b")),
        ("mirror", json!("/a\nb")),
        ("promisors", json!(["https://github.com/o/other.git"])),
        ("promisors", json!([URL, URL])),
        ("promisors", Value::from(vec!["/p"; 9])),
    ] {
        let mut params = world.start_params(&folder, &snapshot);
        params[key] = value.clone();
        assert_eq!(refused(&params), "seed.bad_request", "{key} {value}");
    }
}

#[test]
fn the_configured_mirror_folder_is_laid_out_as_wt_keeps_it() {
    let world = World::new("borrow-root");
    let root = world.home.join("mirrors");
    std::fs::create_dir_all(root.join("o/n.git")).unwrap();
    let root = root.to_str().unwrap();
    let found = run::borrow::mirror_under(root, URL);
    assert_eq!(found, Some(format!("{root}/o/n.git")));
    assert_eq!(run::borrow::mirror_under(root, "https://github.com/o/m.git"), None);
    assert_eq!(run::borrow::mirror_under("relative", URL), None);
}

/// A Cloud chat opened with a folder (clone only): the folder borrows a mirror baked before the
/// newest commit and fetches only that commit from `origin`, then checks out the default branch
/// or a tag as a clone would.
#[test]
fn a_clone_only_seed_borrows_a_stale_mirror_and_fetches_the_rest() {
    let world = World::new("borrow-clone");
    git(&world.mac, &["tag", "v1"]);
    git(&world.mac, &["push", "-q", "origin", "v1"]);
    let mirror = mirror(&world, "mirror.git", URL);
    write(&world.mac.join("a"), "a\nafter the mirror\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "after"]);
    git(&world.mac, &["push", "-q", "origin", "HEAD:main"]);
    let tip = git(&world.mac, &["rev-parse", "HEAD"]);
    let folder = world.home.join("default");
    let mut params = clone_params(&folder, None);
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrowed".to_owned()), "{status}");
    assert_eq!(status["head"], tip.as_str());
    assert_eq!(status["head_ref"], "refs/heads/main");
    assert_eq!(std::fs::read_to_string(folder.join("a")).unwrap(), "a\nafter the mirror\n");
    assert_eq!(git(&folder, &["status", "--porcelain"]), "");
    assert_eq!(git(&folder, &["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main");
    let alternates = std::fs::read_to_string(folder.join(".git/objects/info/alternates")).unwrap();
    assert_eq!(alternates.trim(), mirror.join("objects").canonicalize().unwrap().to_str().unwrap());
    assert_eq!(config(&folder, "remote.origin.promisor"), "true");
    git(&folder, &["fsck", "--connectivity-only", "--no-dangling"]);
    let tagged = world.home.join("tagged");
    let mut params = clone_params(&tagged, Some("v1"));
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"borrowed".to_owned()), "{status}");
    assert_eq!(status["head"], world.base.as_str());
    assert_eq!(status["head_ref"], Value::Null, "a tag is detached");
}

/// A clone-only seed whose mirror is another repository's, or absent, clones as before.
#[test]
fn a_clone_only_seed_without_a_usable_mirror_clones() {
    let mut world = World::new("borrow-clone-other");
    // The `wt` mirror's fallback is a direct clone here, not the machine's warm mirror
    // (`tests/mirror.rs`), whose alternates would be in the folder too.
    world.mirrors = None;
    let other = mirror(&world, "other.git", "https://github.com/o/other.git");
    for (name, mirror) in [("other", other), ("absent", world.home.join("absent.git"))] {
        let folder = world.home.join(name);
        let mut params = clone_params(&folder, None);
        params["mirror"] = json!(mirror);
        let status = seed(&world, &params);
        assert_eq!(status["state"], "done", "{name} {status}");
        assert!(notes(&status).contains(&"borrow_failed".to_owned()), "{name} {status}");
        assert_eq!(status["head"], world.base.as_str(), "{name}");
        assert!(!folder.join(".git/objects/info/alternates").exists(), "{name}");
    }
}

/// `git.seed.borrowable` (`git-seed-borrow-v1`): the machine says a fresh folder would borrow
/// its mirror exactly when the seed would, so the sender packs nothing only then.
#[test]
fn borrowable_answers_as_the_seed_would_borrow() {
    let world = World::new("borrowable");
    let service = world.service();
    let mirror = mirror(&world, "mirror.git", "git@github.com:o/n.git");
    let other = mirror(&world, "other.git", "https://github.com/o/other.git");
    let folder = world.home.join("work/project");
    let ask = |mirror: &Path, base: &str| {
        json!({
            "folder": folder, "url": URL, "repo": "o/n", "base": base, "mirror": mirror,
        })
    };
    let answer = |params: Value| service.call("git.seed.borrowable", &params).unwrap();
    assert_eq!(answer(ask(&mirror, &world.base)), json!({ "borrow": true }));
    assert_eq!(answer(ask(&other, &world.base))["why"], "other_repo");
    assert_eq!(answer(ask(&world.home.join("absent.git"), &world.base))["why"], "no_mirror");
    let missing = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(answer(ask(&mirror, missing))["why"], "no_base");
    // A folder that is a repository already takes no carry and no borrow.
    std::fs::create_dir_all(folder.join(".git")).unwrap();
    assert_eq!(answer(ask(&mirror, &world.base))["why"], "folder");
    // The seed itself borrows where the answer was true.
    std::fs::remove_dir_all(folder.join(".git")).unwrap();
    let snapshot = world.snapshot("one", &[&world.base]);
    let mut params = world.start_params(&folder, &snapshot);
    params["mirror"] = json!(mirror);
    let status = seed(&world, &params);
    assert!(notes(&status).contains(&"borrowed".to_owned()), "{status}");
}

#[test]
fn borrowable_refuses_what_a_seed_would_refuse() {
    let world = World::new("borrowable-refused");
    let service = world.service();
    let folder = world.home.join("project");
    let base = world.base.clone();
    for params in [
        json!({ "folder": folder, "url": "https://example.com/o/n.git", "repo": "o/n", "base": base }),
        json!({ "folder": folder, "url": URL, "repo": "o/n", "base": "nope" }),
        json!({ "folder": folder, "url": URL, "repo": "o/n", "base": base, "mirror": "relative" }),
        json!({ "folder": "relative", "url": URL, "repo": "o/n", "base": base }),
    ] {
        let refused = service.call("git.seed.borrowable", &params).unwrap_err();
        assert_eq!(refused.code, "seed.bad_request", "{params}");
    }
}
