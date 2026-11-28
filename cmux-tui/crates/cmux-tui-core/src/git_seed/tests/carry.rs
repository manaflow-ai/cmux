//! `git-seed-carry-v1`: a fresh folder from the sender's depth-1 pack of the base, with no
//! clone and no GitHub, and the clone again whenever the pack cannot be used.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::*;

/// The sender's pack of `base` as `link/seed/carry.rs` makes it (`--shallow BASE`, deltas
/// reused), at `<home>/<name>.pack`.
fn carry_pack(world: &World, base: &str, name: &str) -> PathBuf {
    let out = world.home.join(&format!("{name}.pack"));
    let mut child = Command::new("git")
        .arg("-C")
        .arg(&world.mac)
        .args(["pack-objects", "--revs", "--stdout", "-q", "--delta-base-offset"])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(Stdio::piped())
        .stdout(std::fs::File::create(&out).unwrap())
        .spawn()
        .unwrap();
    use std::io::Write as _;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("--shallow {base}\n{base}\n").as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
    out
}

fn notes(status: &Value) -> Vec<String> {
    status["notes"]
        .as_array()
        .map(|notes| notes.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn shallow(folder: &Path) -> String {
    std::fs::read_to_string(folder.join(".git/shallow")).unwrap_or_default().trim().to_owned()
}

#[test]
fn a_carried_seed_needs_no_remote_and_reproduces_everything() {
    let world = World::new("carry");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let pack = carry_pack(&world, &world.base, "carry");
    // No GitHub at all: a clone or a fetch would fail the seed.
    std::fs::remove_dir_all(&world.remote).unwrap();
    let folder = world.home.join("work/project");
    let mut params = world.start_params(&folder, &snapshot);
    params["carry"] = json!(pack);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"carried".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert_eq!(git(&folder, &["symbolic-ref", "HEAD"]), "refs/heads/feature");
    assert_eq!(shallow(&folder), world.base, "the base is the shallow boundary");
    assert_eq!(git(&folder, &["remote", "get-url", "origin"]), URL);
    assert!(!pack.exists(), "the uploaded pack is deleted");
    assert!(!snapshot.bundle.exists(), "the applied bundle is deleted");
    git(&folder, &["fsck", "--connectivity-only", "--no-dangling"]);
}

#[test]
fn a_carried_seed_takes_a_delta_after_it() {
    let world = World::new("carry-delta");
    dirty_branch(&world);
    let first = world.snapshot("one", &[&world.base]);
    let pack = carry_pack(&world, &world.base, "carry");
    std::fs::remove_dir_all(&world.remote).unwrap();
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &first);
    params["carry"] = json!(pack);
    assert_eq!(seed(&world, &params)["state"], "done");
    let mac = &world.mac;
    write(&mac.join("added"), "added\n");
    let second = world.snapshot("two", &[&first.work, &first.head]);
    let mut params = world.start_params(&folder, &second);
    params["since"] = first.work.clone().into();
    params["base"] = first.work.into();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(mac));
}

#[test]
fn a_bad_pack_clones_instead() {
    let world = World::new("carry-bad");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let pack = world.home.join("bad.pack");
    std::fs::write(&pack, b"PACK not really").unwrap();
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["carry"] = json!(pack);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"carry_failed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert_eq!(shallow(&folder), "", "a clone is not shallow");
}

#[test]
fn a_pack_without_the_base_tree_clones_instead() {
    let world = World::new("carry-thin");
    write(&world.mac.join("a"), "a\nnext\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "next"]);
    git(&world.mac, &["push", "-q", "origin", "HEAD:main"]);
    let base = git(&world.mac, &["rev-parse", "HEAD"]);
    // Only what `next` added over the old base: its blobs of `b` and `d/c` are missing.
    let pack = world.home.join("thin.pack");
    let mut child = Command::new("git")
        .arg("-C")
        .arg(&world.mac)
        .args(["pack-objects", "--revs", "--stdout", "-q"])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdin(Stdio::piped())
        .stdout(std::fs::File::create(&pack).unwrap())
        .spawn()
        .unwrap();
    use std::io::Write as _;
    let old = &world.base;
    child.stdin.take().unwrap().write_all(format!("{base}\n^{old}\n").as_bytes()).unwrap();
    assert!(child.wait().unwrap().success());
    let snapshot = world.snapshot("one", &[&base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["base"] = json!(base);
    params["carry"] = json!(pack);
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(notes(&status).contains(&"carry_failed".to_owned()), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
}

#[test]
fn a_folder_with_a_repository_already_fetches_and_ignores_the_pack() {
    let world = World::new("carry-again");
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    write(&world.mac.join("a"), "a\nagain\n");
    let second = world.snapshot("two", &[&world.base]);
    let mut params = world.start_params(&folder, &second);
    params["carry"] = json!(carry_pack(&world, &world.base, "carry"));
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(!notes(&status).iter().any(|note| note.starts_with("carr")), "{status}");
    assert_eq!(state(&folder), state(&world.mac));
}

#[test]
fn carry_is_refused_on_a_delta_and_a_clone_only_start() {
    let world = World::new("carry-params");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["since"] = json!(world.base);
    params["carry"] = json!(world.home.join("x.pack"));
    let refused = start(&world.service(), &params).unwrap_err();
    assert_eq!(refused.code, "seed.bad_request");
    let mut clone = clone_params(&folder, None);
    clone["carry"] = json!(world.home.join("x.pack"));
    assert_eq!(start(&world.service(), &clone).unwrap_err().code, "seed.bad_request");
}
