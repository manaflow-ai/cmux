//! The clone from the machine's warm mirror (`run/mirror.rs`) on real git, against a `file://`
//! remote that serves partial clones as GitHub does: the second add of a repository borrows the
//! mirror and downloads nothing, an add whose own fetch fails never borrows it, and anything
//! that fails clones directly.

use std::path::Path;

use super::*;
use crate::git_seed::run::mirror;

fn notes(status: &Value) -> Vec<String> {
    status["notes"]
        .as_array()
        .map(|notes| notes.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// The mirror of [`URL`] under the world's mirrors folder.
fn mirror_of(world: &World) -> PathBuf {
    let root = std::fs::canonicalize(world.mirrors.as_ref().unwrap()).unwrap();
    root.join(format!("{}.git", mirror::key(URL)))
}

fn alternates(folder: &Path) -> Option<String> {
    std::fs::read_to_string(folder.join(".git/objects/info/alternates")).ok()
}

/// The objects a repository holds itself (loose and packed), not those it borrows.
fn own_objects(repo: &Path) -> u64 {
    let listed = git(repo, &["count-objects", "-v"]);
    listed
        .lines()
        .filter_map(|line| {
            let (name, value) = line.split_once(": ")?;
            matches!(name, "count" | "in-pack").then(|| value.parse::<u64>().unwrap())
        })
        .sum()
}

/// The ids of the objects of `commit` the repository lacks.
fn missing(repo: &Path, commit: &str) -> Vec<String> {
    git(repo, &["rev-list", "--objects", "--missing=print", "--no-walk", commit])
        .lines()
        .filter_map(|line| line.strip_prefix('?').map(str::to_owned))
        .collect()
}

/// A service as the world's, with the remote at `remote` instead.
fn service_at(world: &World, remote: &Path) -> GitSeedService {
    let config = Config {
        git: Git {
            extra_config: vec![
                format!("url.file://{}.insteadOf={URL}", remote.display()),
                "protocol.file.allow=always".into(),
            ],
        },
        credentials: Some(vec![Credential::Anonymous]),
        mirrors: world.mirrors.clone(),
    };
    GitSeedService::with_config(Roots::new([world.home.path.clone()]), config)
}

#[test]
fn a_second_add_borrows_the_warm_mirror_and_downloads_nothing() {
    let world = World::new("mirror-warm");
    let first = world.home.join("chats/one/n");
    let status = seed(&world, &clone_params(&first, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["mirror"], "miss", "the first add makes the mirror: {status}");
    let mirror = mirror_of(&world);
    assert_eq!(git(&mirror, &["config", "gc.auto"]), "0");
    assert_eq!(git(&mirror, &["config", "gc.pruneExpire"]), "never");
    assert!(missing(&mirror, &world.base).is_empty(), "the commit's files are in the mirror");
    let before = own_objects(&mirror);

    let second = world.home.join("chats/two/n");
    let status = seed(&world, &clone_params(&second, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["mirror"], "hit", "{status}");
    assert_eq!(own_objects(&mirror), before, "nothing new came into the mirror");
    assert_eq!(own_objects(&second), 0, "the folder holds no objects of its own");
    assert_eq!(alternates(&second).unwrap().trim(), mirror.join("objects").display().to_string());
    // As a direct blobless clone leaves it.
    assert_eq!(status["head"], world.base.as_str());
    assert_eq!(status["head_ref"], "refs/heads/main");
    assert_eq!(git(&second, &["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main");
    assert_eq!(
        git(&second, &["symbolic-ref", "refs/remotes/origin/HEAD"]),
        "refs/remotes/origin/main"
    );
    assert_eq!(git(&second, &["config", "remote.origin.url"]), URL);
    assert_eq!(git(&second, &["config", "remote.origin.promisor"]), "true");
    assert_eq!(git(&second, &["config", "remote.origin.partialclonefilter"]), "blob:none");
    assert_eq!(git(&second, &["status", "--porcelain"]), "");
    assert_eq!(std::fs::read_to_string(second.join("d/c")).unwrap(), "c\n");
    git(&second, &["fsck", "--no-progress", "--connectivity-only"]);
    // Commits made there are the folder's own; the mirror is untouched.
    write(&second.join("a"), "changed\n");
    git(&second, &["commit", "-q", "-a", "-m", "mine"]);
    assert_eq!(own_objects(&mirror), before);
    assert!(own_objects(&second) > 0);
}

#[test]
fn a_new_commit_on_the_remote_comes_into_the_mirror_on_the_next_add() {
    let world = World::new("mirror-new");
    let status = seed(&world, &clone_params(&world.home.join("one"), None));
    assert_eq!(status["state"], "done", "{status}");
    git(&world.mac, &["tag", "v1"]);
    write(&world.mac.join("a"), "a\nlater\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "later"]);
    git(&world.mac, &["push", "-q", "origin", "main", "v1"]);
    let tip = git(&world.mac, &["rev-parse", "HEAD"]);

    let latest = world.home.join("latest");
    let status = seed(&world, &clone_params(&latest, None));
    assert_eq!(status["mirror"], "hit", "{status}");
    assert_eq!(status["head"], tip.as_str());
    assert_eq!(std::fs::read_to_string(latest.join("a")).unwrap(), "a\nlater\n");
    assert!(missing(&mirror_of(&world), &tip).is_empty());

    let tagged = world.home.join("tagged");
    let status = seed(&world, &clone_params(&tagged, Some("v1")));
    assert_eq!(status["mirror"], "hit", "{status}");
    assert_eq!(status["head"], world.base.as_str(), "a tag the mirror fetched: {status}");
    assert_eq!(status["head_ref"], Value::Null);

    let pinned = world.home.join("pinned");
    let status = seed(&world, &clone_params(&pinned, Some(&world.base)));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["head"], world.base.as_str());
    assert_eq!(std::fs::read_to_string(pinned.join("a")).unwrap(), "a\n");
}

/// The security rule: the mirror holds what any add on the machine could read, so an add
/// borrows it only after its own fetch with its own GitHub paths succeeded. Here the second
/// caller cannot reach the repository (a private one it has no access to): it gets the
/// refusal, never the mirror's objects.
#[test]
fn an_add_whose_own_fetch_fails_never_borrows_the_mirror() {
    let world = World::new("mirror-private");
    let status = seed(&world, &clone_params(&world.home.join("allowed"), None));
    assert_eq!(status["state"], "done", "{status}");
    assert!(missing(&mirror_of(&world), &world.base).is_empty(), "the mirror is warm");

    let refused = service_at(&world, &world.home.join("no-access.git"));
    let folder = world.home.join("refused");
    let job = start(&refused, &clone_params(&folder, None)).unwrap();
    let status = wait(&refused, &job);
    assert_eq!(status["state"], "failed", "{status}");
    assert_eq!(status["mirror"], "miss", "{status}");
    assert!(notes(&status).contains(&"seed.mirror.fallback".to_owned()), "{status}");
    assert!(!folder.exists(), "nothing of the mirror reached the folder");
}

#[test]
fn a_mirror_that_cannot_be_made_leaves_the_direct_clone() {
    let mut world = World::new("mirror-broken");
    let blocked = world.home.join("not-a-folder");
    write(&blocked, "a file where the mirrors folder would be\n");
    world.mirrors = Some(blocked);
    let folder = world.home.join("direct");
    let status = seed(&world, &clone_params(&folder, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["mirror"], "miss", "{status}");
    assert!(notes(&status).contains(&"seed.mirror.fallback".to_owned()), "{status}");
    assert_eq!(alternates(&folder), None);
    assert_eq!(std::fs::read_to_string(folder.join("a")).unwrap(), "a\n");
}

#[test]
fn the_switch_off_clones_directly() {
    let mut world = World::new("mirror-off");
    world.mirrors = None;
    let folder = world.home.join("direct");
    let status = seed(&world, &clone_params(&folder, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["mirror"], "off", "{status}");
    assert_eq!(alternates(&folder), None);

    let home = Some(std::ffi::OsString::from("/home/u"));
    assert_eq!(mirror::root_for(Some("off"), home.clone()), None);
    assert_eq!(mirror::root_for(Some(" OFF "), home.clone()), None);
    assert_eq!(
        mirror::root_for(None, home.clone()),
        Some(PathBuf::from("/home/u/Projects/auto/.cmux-git-mirrors"))
    );
    assert_eq!(
        mirror::root_for(Some("on"), home),
        Some(PathBuf::from("/home/u/Projects/auto/.cmux-git-mirrors"))
    );
    assert_eq!(mirror::root_for(None, None), None);
    assert_eq!(mirror::root_for(None, Some("relative".into())), None);
}

/// AutoCloud start's mirror of a remote is this one: the same folder and name.
#[test]
fn the_mirror_name_is_autoclouds() {
    use sha2::Digest as _;
    let remote = "https://github.com/manaflow-ai/cmux.git";
    let digest = sha2::Sha256::digest(remote.as_bytes());
    let hex: String = digest[..8].iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(mirror::key(remote), hex);
    assert_eq!(hex.len(), 16);
}

/// Eight adds of one repository at once: one mirror, every folder whole.
#[test]
fn eight_adds_at_once_share_one_mirror() {
    let world = World::new("mirror-eight");
    let service = std::sync::Arc::new(world.service());
    let folders: Vec<PathBuf> = (0..8).map(|n| world.home.join(&format!("chats/{n}/n"))).collect();
    let jobs: Vec<String> = folders
        .iter()
        .map(|folder| start(&service, &clone_params(folder, None)).unwrap())
        .collect();
    for (job, folder) in jobs.iter().zip(&folders) {
        let status = wait(&service, job);
        assert_eq!(status["state"], "done", "{status}");
        assert!(matches!(status["mirror"].as_str(), Some("hit" | "miss")), "{status}");
        assert_eq!(git(folder, &["status", "--porcelain"]), "");
        assert_eq!(std::fs::read_to_string(folder.join("b")).unwrap(), "b\n");
    }
    let root = std::fs::canonicalize(world.mirrors.as_ref().unwrap()).unwrap();
    let mirrors: Vec<_> = std::fs::read_dir(&root)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| !name.ends_with(".lock") && !name.ends_with(".fetched"))
        .collect();
    assert_eq!(mirrors, vec![format!("{}.git", mirror::key(URL))], "one mirror, no leftovers");
}

/// An add that waited for the mirror while another add fetched into it makes no fetch of its
/// own: it proves its access with one `ls-remote` and borrows what that fetch brought. (A crowd
/// of 8 adds used to fetch in turn, each past the lock's wait, and 7 of them cloned directly.)
/// An add the remote refuses still never borrows.
#[test]
fn an_add_that_waited_for_a_fetch_reaches_the_remote_and_skips_its_own() {
    use cmux_file_lock::{FileLock, Kind};
    let world = World::new("mirror-crowd");
    let status = seed(&world, &clone_params(&world.home.join("first"), None));
    assert_eq!(status["state"], "done", "{status}");
    let mirror = mirror_of(&world);
    let lock_path = mirror.with_extension("lock");
    let take = || {
        let file = std::fs::OpenOptions::new().read(true).write(true).open(&lock_path).unwrap();
        FileLock::take_within(
            file,
            Kind::Exclusive,
            Duration::from_secs(5),
            Duration::from_millis(10),
        )
        .unwrap()
    };

    // A new commit on the remote the waiting add would fetch, were it to fetch.
    write(&world.mac.join("a"), "a\nlater\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "later"]);
    git(&world.mac, &["push", "-q", "origin", "main"]);

    let held = take();
    let service = world.service();
    let waiting = world.home.join("waiting");
    let job = start(&service, &clone_params(&waiting, None)).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    // The holder's fetch lands after the waiting add asked.
    std::fs::write(mirror.with_extension("fetched"), b"").unwrap();
    drop(held);
    let status = wait(&service, &job);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["mirror"], "hit", "{status}");
    assert_eq!(status["head"], world.base.as_str(), "no fetch of its own: {status}");

    let held = take();
    let refused = service_at(&world, &world.home.join("no-access.git"));
    let folder = world.home.join("refused");
    let job = start(&refused, &clone_params(&folder, None)).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    std::fs::write(mirror.with_extension("fetched"), b"").unwrap();
    drop(held);
    let status = wait(&refused, &job);
    assert_eq!(status["state"], "failed", "{status}");
    assert!(notes(&status).contains(&"seed.mirror.fallback".to_owned()), "{status}");
    assert!(!folder.exists(), "nothing of the mirror reached the folder");
}

/// A warm add whose commit and files the mirror holds already borrows it without the lock, so
/// a crowd of warm adds reads the mirror at once instead of taking turns. (8 warm adds of cmux
/// used to queue for minutes behind each other's turns.) Each still reaches the remote with
/// its own paths: an add the remote refuses never borrows, lock or no lock. A mirror behind
/// the remote still waits for the lock and fetches.
#[test]
fn a_ready_mirror_is_borrowed_while_another_add_holds_the_lock() {
    use cmux_file_lock::{FileLock, Kind};
    let world = World::new("mirror-lockfree");
    let status = seed(&world, &clone_params(&world.home.join("first"), None));
    assert_eq!(status["state"], "done", "{status}");
    let mirror = mirror_of(&world);
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(mirror.with_extension("lock"))
        .unwrap();
    let held = FileLock::take_within(
        file,
        Kind::Exclusive,
        Duration::from_secs(5),
        Duration::from_millis(10),
    )
    .unwrap();

    // 8 at once, the lock held all along (the lock's own wait is 30 min; `wait` gives 120 s).
    let service = std::sync::Arc::new(world.service());
    let folders: Vec<PathBuf> = (0..8).map(|n| world.home.join(&format!("crowd/{n}/n"))).collect();
    let jobs: Vec<String> = folders
        .iter()
        .map(|folder| start(&service, &clone_params(folder, None)).unwrap())
        .collect();
    for (job, folder) in jobs.iter().zip(&folders) {
        let status = wait(&service, job);
        assert_eq!(status["state"], "done", "{status}");
        assert_eq!(status["mirror"], "hit", "{status}");
        assert_eq!(status["head"], world.base.as_str(), "{status}");
        assert_eq!(git(folder, &["status", "--porcelain"]), "");
        assert_eq!(std::fs::read_to_string(folder.join("b")).unwrap(), "b\n");
        assert_eq!(own_objects(folder), 0, "everything borrowed");
        git(folder, &["fsck", "--no-progress", "--connectivity-only"]);
    }

    let refused = service_at(&world, &world.home.join("no-access.git"));
    let folder = world.home.join("refused");
    let job = start(&refused, &clone_params(&folder, None)).unwrap();
    let status = wait(&refused, &job);
    assert_eq!(status["state"], "failed", "{status}");
    assert!(notes(&status).contains(&"seed.mirror.fallback".to_owned()), "{status}");
    assert!(!folder.exists(), "nothing of the mirror reached the folder");
    drop(held);
}

/// A submodule comes from its own warm mirror, as the remote does: the second add's
/// submodule borrows the mirror (alternates) and downloads none of its objects again. (A warm
/// add of a repository with large submodules used to clone each one whole from GitHub.)
#[test]
fn a_submodule_comes_from_its_own_warm_mirror() {
    const SUB: &str = "https://github.com/o/sub.git";
    let world = World::new("mirror-sub");
    let lib = world.home.join("lib");
    std::fs::create_dir_all(&lib).unwrap();
    git(&lib, &["init", "-q", "-b", "main"]);
    write(&lib.join("x"), "x\n");
    git(&lib, &["add", "-A"]);
    git(&lib, &["commit", "-q", "-m", "lib"]);
    let sub_remote = world.home.join("sub.git");
    git(
        &world.home.path,
        &["clone", "-q", "--bare", lib.to_str().unwrap(), sub_remote.to_str().unwrap()],
    );
    git(&sub_remote, &["config", "uploadpack.allowFilter", "true"]);
    git(&sub_remote, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    let commit = git(&lib, &["rev-parse", "HEAD"]);
    write(
        &world.mac.join(".gitmodules"),
        &format!("[submodule \"lib\"]\n\tpath = lib\n\turl = {SUB}\n"),
    );
    git(&world.mac, &["update-index", "--add", "--cacheinfo", &format!("160000,{commit},lib")]);
    git(&world.mac, &["add", ".gitmodules"]);
    git(&world.mac, &["commit", "-q", "-m", "submodule"]);
    git(&world.mac, &["push", "-q", "origin", "main"]);
    let config = Config {
        git: Git {
            extra_config: vec![
                format!("url.file://{}.insteadOf={URL}", world.remote.display()),
                format!("url.file://{}.insteadOf={SUB}", sub_remote.display()),
                "protocol.file.allow=always".into(),
            ],
        },
        credentials: Some(vec![Credential::Anonymous]),
        mirrors: world.mirrors.clone(),
    };
    let service = GitSeedService::with_config(Roots::new([world.home.path.clone()]), config);
    let root = || std::fs::canonicalize(world.mirrors.as_ref().unwrap()).unwrap();
    let add = |name: &str| {
        let folder = world.home.join(name);
        let job = start(&service, &clone_params(&folder, None)).unwrap();
        let status = wait(&service, &job);
        assert_eq!(status["state"], "done", "{status}");
        assert!(!notes(&status).iter().any(|n| n.contains("fallback")), "{status}");
        assert_eq!(std::fs::read_to_string(folder.join("lib/x")).unwrap(), "x\n");
        folder
    };
    add("one");
    let sub_mirror = root().join(format!("{}.git", mirror::key(SUB)));
    assert!(missing(&sub_mirror, &commit).is_empty(), "the submodule's files are in its mirror");
    let before = own_objects(&sub_mirror);

    let second = add("two");
    let module = second.join(".git/modules/lib");
    assert_eq!(
        std::fs::read_to_string(module.join("objects/info/alternates")).unwrap().trim(),
        sub_mirror.join("objects").display().to_string()
    );
    assert_eq!(own_objects(&module), 0, "the submodule holds no objects of its own");
    assert_eq!(own_objects(&sub_mirror), before, "nothing new came into its mirror");
    assert_eq!(git(&second.join("lib"), &["rev-parse", "HEAD"]), commit);
    git(&second.join("lib"), &["fsck", "--no-progress", "--connectivity-only"]);
}

/// The numbers for the PR (`scripts/measure/cloud-add-repo-mirror.sh`): Cloud "Add repository"
/// of a real public GitHub repository through this service, as a machine runs it (no test
/// remote, the anonymous path), with the mirror off (today), on and cold (the add that makes
/// it), and on and warm (a second add into another chat's folder). Each row prints the seconds
/// and the bytes that came from GitHub: the pack bytes the add wrote (the folder's own objects
/// plus what the mirror gained) and, on Linux, the machine's received bytes over the same span.
/// Then 8 adds at once, off and warm. Ignored: it needs the network; run it with
/// `CMUX_SEED_MEASURE_URL=https://github.com/OWNER/REPO.git cargo test -p cmux-tui-core --lib
/// git_seed::tests::mirror::measure -- --ignored --nocapture`.
#[test]
#[ignore = "network: scripts/measure/cloud-add-repo-mirror.sh"]
fn measure_add_repository_cold_and_warm() {
    let Ok(url) = std::env::var("CMUX_SEED_MEASURE_URL") else { return };
    let runs: usize =
        std::env::var("CMUX_SEED_MEASURE_RUNS").ok().and_then(|n| n.parse().ok()).unwrap_or(3);
    let crowd: usize =
        std::env::var("CMUX_SEED_MEASURE_CROWD").ok().and_then(|n| n.parse().ok()).unwrap_or(8);
    let home = Home::new("mirror-measure");
    let service = |mirrors: Option<PathBuf>| {
        let config =
            Config { credentials: Some(vec![Credential::Anonymous]), mirrors, ..Config::default() };
        std::sync::Arc::new(GitSeedService::with_config(Roots::new([home.path.clone()]), config))
    };
    // `repo` is the URL's OWNER/NAME, as `check_url` requires.
    let repo = url.trim_start_matches("https://github.com/").trim_end_matches(".git").to_owned();
    let params = |folder: &Path| json!({ "folder": folder, "url": url, "repo": repo, "ref": null, "lfs": false });
    let finish = |service: &GitSeedService, job: &str| {
        let started = Instant::now();
        let deadline = started + Duration::from_secs(1800);
        let mut said = started;
        loop {
            let status = service.call("git.seed.status", &json!({ "job": job })).unwrap();
            if status["state"] != "running" {
                assert_eq!(status["state"], "done", "{status}");
                return status;
            }
            assert!(Instant::now() < deadline, "{status}");
            // A line every 30 s, so a stall reads apart from a slow clone.
            if said.elapsed() >= Duration::from_secs(30) {
                said = Instant::now();
                println!(
                    "WAIT job={job} after={:.0}s status={status}",
                    started.elapsed().as_secs_f64()
                );
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    };
    let mut folder_n = 0;
    let mut next = || {
        folder_n += 1;
        home.join(&format!("chats/{folder_n}/repo"))
    };
    // `crowd` adds at once (1: one add); the seconds, the pack bytes, the received bytes.
    let mut add = |mirrors: &Option<PathBuf>, count: usize| {
        let service = service(mirrors.clone());
        let folders: Vec<PathBuf> = (0..count).map(|_| next()).collect();
        let mirror_before = mirrors.as_ref().map(|root| tree_bytes(root)).unwrap_or(0);
        let rx = received();
        let started = Instant::now();
        let jobs: Vec<String> =
            folders.iter().map(|f| start(&service, &params(f)).expect("git.seed.start")).collect();
        let finished: Vec<Value> = jobs.iter().map(|job| finish(&service, job)).collect();
        // Where the seconds went (the first add's steps), so a slow row reads apart.
        println!("TIMINGS {}", finished[0]["timings"]);
        let states: Vec<String> = finished
            .iter()
            .map(|status| status["mirror"].as_str().unwrap_or("-").to_owned())
            .collect();
        let seconds = started.elapsed().as_secs_f64();
        let rx = rx.zip(received()).map(|(a, b)| b.saturating_sub(a));
        let mirror_after = mirrors.as_ref().map(|root| tree_bytes(root)).unwrap_or(0);
        // The folder's own objects and its submodules' (`.git/modules`).
        let own: u64 = folders
            .iter()
            .map(|f| tree_bytes(&f.join(".git/objects")) + tree_bytes(&f.join(".git/modules")))
            .sum();
        // One folder's fsck per row: every folder of a warm row borrows the same mirror, and
        // a connectivity walk of cmux's whole history is minutes each (8 of them ran a crowd
        // row past the fleet job's hour). The tests check every folder.
        git(&folders[0], &["fsck", "--no-progress", "--connectivity-only"]);
        (seconds, own + mirror_after.saturating_sub(mirror_before), rx, states.join(","))
    };
    let begin = |name: &str, run: usize| println!("START mode={name} run={run}");
    let row = |name: &str,
               run: usize,
               (seconds, bytes, rx, states): (f64, u64, Option<u64>, String)| {
        let rx = rx.map_or("n/a".to_owned(), |rx| format!("{:.1}", rx as f64 / 1e6));
        println!(
            "ROW mode={name} run={run} seconds={seconds:.2} pack_mb={:.1} rx_mb={rx} mirror={states}",
            bytes as f64 / 1e6
        );
    };
    // `CMUX_SEED_MEASURE_MODES=cold-x8,warm-x8`: only these rows (a warm row needs its cold
    // row before it, which makes the mirror), so a crowd fits one fleet job.
    let modes = std::env::var("CMUX_SEED_MEASURE_MODES").ok().filter(|modes| !modes.is_empty());
    let wanted = |name: &str| {
        modes.as_deref().is_none_or(|modes| modes.split(',').any(|m| m.trim() == name))
    };
    println!("URL {url} runs={runs} crowd={crowd} modes={}", modes.as_deref().unwrap_or("all"));
    for run in (1..=runs).filter(|_| ["off", "cold", "warm"].iter().any(|m| wanted(m))) {
        if wanted("off") {
            begin("off", run);
            row("off", run, add(&None, 1));
        }
        let mirrors = Some(home.join(&format!("mirrors-{run}")));
        for name in ["cold", "warm"].into_iter().filter(|name| wanted(name)) {
            begin(name, run);
            row(name, run, add(&mirrors, 1));
        }
    }
    if crowd > 1 {
        let mirrors = Some(home.join("mirrors-crowd"));
        for (name, mirrors) in [("off", None), ("cold", mirrors.clone()), ("warm", mirrors)] {
            let name = format!("{name}-x{crowd}");
            if !wanted(&name) {
                continue;
            }
            begin(&name, 1);
            row(&name, 1, add(&mirrors, crowd));
        }
    }
}

/// The bytes of the files under `path`.
fn tree_bytes(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .flatten()
        .map(|entry| match entry.file_type() {
            Ok(kind) if kind.is_dir() => tree_bytes(&entry.path()),
            Ok(_) => entry.metadata().map(|m| m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

/// The bytes this machine received on every interface but loopback (Linux).
fn received() -> Option<u64> {
    let table = std::fs::read_to_string("/proc/net/dev").ok()?;
    Some(
        table
            .lines()
            .skip(2)
            .filter_map(|line| line.split_once(':'))
            .filter(|(name, _)| name.trim() != "lo")
            .filter_map(|(_, fields)| fields.split_whitespace().next()?.parse::<u64>().ok())
            .sum(),
    )
}
