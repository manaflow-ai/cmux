//! A move's export (`git.seed.export` with `move`): a folder that is no seed moves to a
//! second machine as git from its upstream, its last changes follow as a delta, and the
//! chat can move back to the first machine as a delta too. The folder's seed records
//! are never touched.

use super::*;

/// The first machine's own clone (no seed): `main` tracks `origin/main`, the remote is
/// the GitHub URL as configured, and the chat's work is on a branch of its own: an
/// unpushed commit, a stash, staged and unstaged edits, an add, a deletion, an untracked
/// file and an ignored one.
fn cloned(world: &World) -> PathBuf {
    let one = world.home.join("one");
    git(&world.home.path, &["clone", "-q", world.remote.to_str().unwrap(), one.to_str().unwrap()]);
    git(&one, &["remote", "set-url", "origin", URL]);
    git(&one, &["checkout", "-q", "-b", "feature", "--track", "origin/main"]);
    write(&one.join("b"), "b\nunpushed\n");
    git(&one, &["commit", "-q", "-a", "-m", "unpushed"]);
    write(&one.join("a"), "a\nstashed\n");
    git(&one, &["stash", "-q"]);
    write(&one.join("a"), "a\nstaged\n");
    git(&one, &["add", "a"]);
    write(&one.join("a"), "a\nstaged\nunstaged\n");
    write(&one.join("d/new"), "new\n");
    git(&one, &["add", "d/new"]);
    std::fs::remove_file(one.join("gone")).unwrap();
    write(&one.join("untracked/u.txt"), "untracked\n");
    write(&one.join("ignored/big"), "ignored\n");
    one
}

/// Runs a move's export of `folder` to its end; its last status.
fn export_move(
    world: &World,
    folder: &Path,
    from: &str,
    since: Option<&Value>,
    name: &str,
) -> Value {
    let service = world.service();
    let bundle = world.home.join(&format!("{name}.bundle"));
    let mut params = json!({ "folder": folder, "bundle": bundle, "move": from });
    if let Some(since) = since {
        params["since_work"] = since["work"].clone();
        params["since_head"] = since["head"].clone();
    }
    let answer = service.call("git.seed.export", &params).unwrap();
    let status = wait(&service, answer["job"].as_str().unwrap());
    assert_eq!(status["state"], "done", "{status}");
    status
}

/// The export's bundle as a seed applies it: `refs/cmux-move/*` renamed `refs/cmux-seed/*`
/// in the header, as the Mac does.
fn as_seed(world: &World, name: &str) -> PathBuf {
    let path = world.home.join(&format!("{name}.bundle"));
    let mut bytes = std::fs::read(&path).unwrap();
    let end = bytes.windows(2).position(|pair| pair == b"\n\n").unwrap();
    let header = String::from_utf8(bytes[..end].to_vec()).unwrap();
    let renamed = header.replace(" refs/cmux-move/", " refs/cmux-seed/");
    bytes.splice(..end, renamed.into_bytes());
    std::fs::write(&path, bytes).unwrap();
    path
}

/// A seed of `folder` from an export's answer: whole from its base, or a delta on `since`.
fn seed_from(
    world: &World,
    folder: &Path,
    exported: &Value,
    name: &str,
    since: Option<&str>,
) -> Value {
    let mut params = json!({
        "folder": folder,
        "url": URL,
        "repo": "o/n",
        "base": since.map_or(exported["since_work"].clone(), Value::from),
        "bundle": as_seed(world, name),
        "head_ref": exported["head_ref"],
        "head": exported["head"],
        "index": exported["index"],
        "work": exported["work"],
        "stash": exported["stash"],
        "sparse": Value::Null,
        "lfs": false,
    });
    if let Some(since) = since {
        params["since"] = since.into();
    }
    seed(world, &params)
}

fn refs(folder: &Path, prefix: &str) -> String {
    git(folder, &["for-each-ref", "--format=%(refname) %(objectname)", prefix])
}

#[test]
fn a_clone_moves_from_its_upstream_then_its_last_changes_then_back() {
    let world = World::new("move-upstream");
    let one = cloned(&world);
    let two = world.home.join("two");

    // The bulk: from the tip `main` tracks, which GitHub has. Only the work goes.
    let bulk = export_move(&world, &one, "upstream", None, "bulk");
    assert_eq!(bulk["url"], URL, "the remote as configured: {bulk}");
    assert_eq!(bulk["since_work"], world.base.as_str(), "the upstream tip: {bulk}");
    assert_eq!(bulk["since_head"], world.base.as_str());
    assert!(refs(&one, "refs/cmux-back").is_empty(), "a move keeps out of the seed's records");
    assert!(refs(&one, "refs/cmux-seed").is_empty());
    assert_eq!(git(&one, &["rev-parse", "refs/cmux-move/work"]), bulk["work"].as_str().unwrap());
    let status = seed_from(&world, &two, &bulk, "bulk", None);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&two), state(&one));
    assert!(!two.join("ignored/big").exists(), "ignored files stay");

    // The frozen pass: what the chat did since, on the bulk.
    write(&one.join("a"), "a\nstaged\nunstaged\nfrozen\n");
    write(&one.join("added"), "added\n");
    std::fs::remove_file(one.join("untracked/u.txt")).unwrap();
    let frozen = export_move(&world, &one, "since", Some(&bulk), "frozen");
    assert_eq!(frozen["unchanged"], false, "{frozen}");
    let status = seed_from(&world, &two, &frozen, "frozen", bulk["work"].as_str());
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&two), state(&one));
    assert!(!two.join("untracked/u.txt").exists());
    let again = export_move(&world, &one, "since", Some(&frozen), "again");
    assert_eq!(again["unchanged"], true, "nothing changed since: {again}");

    // The chat works on the second machine, then moves back: the first still has the
    // folder as it left it, so only the second's changes since go.
    write(&two.join("from-two"), "two\n");
    write(&two.join("d/c"), "c\ntwo\n");
    let back = export_move(&world, &two, "seed", None, "back");
    assert_eq!(back["since_work"], frozen["work"], "the second's seed is the move's: {back}");
    let status = seed_from(&world, &one, &back, "back", back["since_work"].as_str());
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&one), state(&two));
    assert_eq!(std::fs::read_to_string(one.join("from-two")).unwrap(), "two\n");
}

#[test]
fn a_move_back_onto_a_folder_that_changed_since_is_refused_and_changes_nothing() {
    let world = World::new("move-back-changed");
    let one = cloned(&world);
    let two = world.home.join("two");
    let bulk = export_move(&world, &one, "upstream", None, "bulk");
    assert_eq!(seed_from(&world, &two, &bulk, "bulk", None)["state"], "done");
    // Someone worked in the first machine's folder after the chat left.
    write(&one.join("theirs"), "theirs\n");
    let before = state(&one);
    write(&two.join("from-two"), "two\n");
    let back = export_move(&world, &two, "seed", None, "back");
    let status = seed_from(&world, &one, &back, "back", back["since_work"].as_str());
    assert_eq!(status["error_code"], "seed.machine_changed", "{status}");
    assert_eq!(state(&one), before);
    assert_eq!(std::fs::read_to_string(one.join("theirs")).unwrap(), "theirs\n");
}

#[test]
fn a_move_export_needs_its_base() {
    let world = World::new("move-params");
    let one = cloned(&world);
    let service = world.service();
    let bundle = world.home.join("x.bundle");
    let call = |params: Value| service.call("git.seed.export", &params).unwrap_err().code;
    assert_eq!(
        call(json!({ "folder": one, "bundle": bundle, "move": "since" })),
        "seed.bad_request",
        "a move's own last export names its commits"
    );
    assert_eq!(
        call(
            json!({ "folder": one, "bundle": bundle, "move": "upstream", "since_work": world.base, "since_head": world.base })
        ),
        "seed.bad_request"
    );
    assert_eq!(
        call(json!({ "folder": one, "bundle": bundle, "move": "sideways" })),
        "seed.bad_request"
    );
    // A clone that is no seed has no seed to move from.
    let answer = service
        .call("git.seed.export", &json!({ "folder": one, "bundle": bundle, "move": "seed" }))
        .unwrap();
    let status = wait(&service, answer["job"].as_str().unwrap());
    assert_eq!(status["error_code"], "seed.since_mismatch", "{status}");
    // Nor a plain export.
    let plain = json!({ "folder": one, "bundle": bundle, "since_work": world.base, "since_head": world.base });
    let answer = service.call("git.seed.export", &plain).unwrap();
    assert_eq!(
        wait(&service, answer["job"].as_str().unwrap())["error_code"],
        "seed.since_mismatch"
    );
}

#[test]
fn a_move_back_never_writes_over_an_ignored_file_the_other_machine_now_tracks() {
    let world = World::new("move-back-ignored");
    let one = cloned(&world);
    let two = world.home.join("two");
    let bulk = export_move(&world, &one, "upstream", None, "bulk");
    assert_eq!(seed_from(&world, &two, &bulk, "bulk", None)["state"], "done");
    // The chat starts tracking a path the first machine ignores, and someone edits that
    // ignored file on the first machine after the chat left.
    write(&two.join("ignored/big"), "from two\n");
    git(&two, &["add", "-f", "ignored/big"]);
    write(&one.join("ignored/big"), "edited on one\n");
    let before = state(&one);
    let back = export_move(&world, &two, "seed", None, "back");
    let status = seed_from(&world, &one, &back, "back", back["since_work"].as_str());
    assert_eq!(status["error_code"], "seed.machine_changed", "{status}");
    assert_eq!(std::fs::read_to_string(one.join("ignored/big")).unwrap(), "edited on one\n");
    assert_eq!(state(&one), before);
    // Without that file, the same move back goes through.
    std::fs::remove_file(one.join("ignored/big")).unwrap();
    let status = seed_from(&world, &one, &back, "back", back["since_work"].as_str());
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(std::fs::read_to_string(one.join("ignored/big")).unwrap(), "from two\n");
}

#[test]
fn a_check_answers_whether_the_folder_is_as_its_record_left_it_and_writes_nothing() {
    let world = World::new("move-check");
    let one = cloned(&world);
    let bulk = export_move(&world, &one, "upstream", None, "bulk");
    let recorded = refs(&one, "refs/cmux-move");
    let since = json!({ "head": bulk["head"], "work": bulk["work"] });
    let check = export_move(&world, &one, "check", Some(&since), "check");
    assert_eq!(check["unchanged"], true, "{check}");
    write(&one.join("theirs"), "theirs\n");
    let check = export_move(&world, &one, "check", Some(&since), "check-changed");
    assert_eq!(check["unchanged"], false, "{check}");
    assert_eq!(check["bundle_bytes"], 0);
    assert_eq!(refs(&one, "refs/cmux-move"), recorded, "a check records nothing");
    assert!(!world.home.join("check-changed.bundle").exists(), "nor writes a bundle");
}

#[test]
fn a_github_repository_is_the_same_in_every_url_form() {
    use super::super::run::same_github_repo;
    let https = "https://github.com/Acme/App.git";
    for other in [
        "https://github.com/acme/app",
        "git@github.com:acme/app.git",
        "ssh://git@github.com/Acme/App.git",
        "https://github.com/acme/app/",
    ] {
        assert!(same_github_repo(https, other), "{other}");
    }
    for other in [
        "https://github.com/acme/other.git",
        "https://example.com/acme/app.git",
        "https://user:token@github.com/acme/app.git",
    ] {
        assert!(!same_github_repo(https, other), "{other}");
    }
}
