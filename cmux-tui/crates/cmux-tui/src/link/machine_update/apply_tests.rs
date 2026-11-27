use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::time::{Duration, Instant};

use super::{
    AcpmuxLink, IN_PLACE_FLAG, Route, STORE_ACPMUX, STORE_CURRENT, StoreNext, acpmux_link, claim,
    claim_path, keep_previous, parse, relink, runs_a_store_entry, runs_this_install, status_names,
    stop, store_answer, store_next,
};

const INSTALL: &str = "/home/u/.cmux/bin/cmux-tui";

fn runs(running: &str) -> bool {
    runs_this_install(Path::new(running), Path::new(INSTALL), None)
}

#[test]
fn a_daemon_on_the_installed_binary_updates() {
    assert!(runs(INSTALL));
}

#[test]
fn a_daemon_on_a_replaced_copy_of_this_install_updates() {
    // An earlier update (or upgrade) renamed a new build over the binary while
    // this daemon kept running the old file, which the kernel now marks.
    assert!(runs("/home/u/.cmux/bin/cmux-tui (deleted)"));
    // The previous build an update kept beside it, or its rollback link.
    assert!(runs("/home/u/.cmux/bin/cmux-tui.prev"));
    assert!(runs("/home/u/.cmux/bin/cmux-tui.prev (deleted)"));
    assert!(runs("/home/u/.cmux/bin/.cmux-tui.rollback (deleted)"));
}

#[test]
fn a_daemon_on_the_file_now_kept_as_previous_updates() {
    let folder = tempfile::tempdir().unwrap();
    let install = folder.path().join("cmux-tui");
    let previous = folder.path().join("cmux-tui.prev");
    std::fs::write(&install, b"new").unwrap();
    std::fs::write(&previous, b"old").unwrap();
    let kept = std::fs::metadata(&previous).unwrap();
    let other = std::fs::metadata(&install).unwrap();
    let elsewhere = Path::new("/somewhere/else");
    assert!(runs_this_install(elsewhere, &install, Some((kept.dev(), kept.ino()))));
    assert!(!runs_this_install(elsewhere, &install, Some((other.dev(), other.ino() + 1_000_000))));
}

#[test]
fn a_foreign_binary_still_refuses() {
    for running in [
        "/usr/local/bin/cmux-tui",
        "/usr/local/bin/cmux-tui (deleted)",
        "/home/other/.cmux/bin/cmux-tui",
        "/home/other/.cmux/bin/cmux-tui (deleted)",
        "/home/u/.cmux/bin/cmux-tui-other",
        "/home/u/.cmux/bin/cmux",
        "/home/u/.cmux/bin/.cmux-tui.update-0123456789abcdef",
        "/home/u/.cmux/cmux-tui (deleted)",
        "cmux-tui (deleted)",
        "",
    ] {
        assert!(!runs(running), "{running}");
    }
}

#[test]
fn a_daemon_that_ignores_sigterm_is_stopped_with_sigkill() {
    // An ignored signal stays ignored across exec: this sleep ignores SIGTERM,
    // as a daemon whose stop never finished did.
    let mut child = std::process::Command::new("sh")
        .args(["-c", "trap '' TERM; exec sleep 60"])
        .spawn()
        .unwrap();
    let pid = i32::try_from(child.id()).unwrap();
    // Reap it at once so a dead child is not a zombie that still answers signal 0.
    let reaper = std::thread::spawn(move || child.wait());
    std::thread::sleep(Duration::from_millis(200));
    // SAFETY: a signal to the child this test started.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    let started = Instant::now();
    assert!(stop(pid, Duration::from_millis(300), Duration::from_secs(10)));
    assert!(started.elapsed() < Duration::from_secs(10));
    let status = reaper.join().unwrap().unwrap();
    use std::os::unix::process::ExitStatusExt as _;
    assert_eq!(status.signal(), Some(libc::SIGKILL));
}

#[test]
fn a_daemon_that_stops_on_sigterm_is_not_killed() {
    let mut child = std::process::Command::new("sleep").arg("60").spawn().unwrap();
    let pid = i32::try_from(child.id()).unwrap();
    let reaper = std::thread::spawn(move || child.wait());
    // SAFETY: a signal to the child this test started.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    assert!(stop(pid, Duration::from_secs(10), Duration::from_secs(10)));
    use std::os::unix::process::ExitStatusExt as _;
    assert_eq!(reaper.join().unwrap().unwrap().signal(), Some(libc::SIGTERM));
}

fn id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|file| (file.dev(), file.ino()))
}

/// Keeps `previous` for a daemon that runs the file at `ran`, open as the
/// step opens it, with the identity of `runs`.
fn keep(install: &Path, previous: &Path, ran: &Path, runs: &Path) {
    let running = std::fs::File::open(ran).unwrap();
    keep_previous(install, previous, &running, id(runs).unwrap()).unwrap();
}

/// A folder with an installed build B, a kept build A and a deleted build R
/// standing in for the file a daemon runs after its path was replaced.
fn builds() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    let install = folder.path().join("cmux-tui");
    let previous = folder.path().join("cmux-tui.prev");
    let running = folder.path().join("running");
    std::fs::write(&install, b"B").unwrap();
    std::fs::write(&previous, b"A").unwrap();
    std::fs::write(&running, b"R").unwrap();
    (folder, install, previous, running)
}

#[test]
fn a_daemon_on_the_installed_binary_keeps_it_as_previous() {
    let (_folder, install, previous, running) = builds();
    keep(&install, &previous, &running, &install);
    assert_eq!(id(&previous), id(&install));
}

#[test]
fn a_daemon_on_the_kept_build_keeps_it_as_previous() {
    // An update installed B while the daemon kept running A, now kept as
    // previous: rolling back must go to A, which served, not to B.
    let (_folder, install, previous, running) = builds();
    let kept = id(&previous);
    keep(&install, &previous, &running, &previous);
    assert_eq!(id(&previous), kept);
    assert_eq!(std::fs::read(&previous).unwrap(), b"A");
}

#[test]
fn a_daemon_on_a_deleted_build_keeps_a_copy_of_it_as_previous() {
    let (_folder, install, previous, running) = builds();
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(&running, std::fs::Permissions::from_mode(0o755)).unwrap();
    // The daemon's binary is open before its path goes, as the step holds it.
    let open = std::fs::File::open(&running).unwrap();
    let ran = id(&running).unwrap();
    std::fs::remove_file(&running).unwrap();
    keep_previous(&install, &previous, &open, ran).unwrap();
    assert_eq!(std::fs::read(&previous).unwrap(), b"R");
    assert_eq!(std::fs::metadata(&previous).unwrap().permissions().mode() & 0o777, 0o755);
    assert_eq!(std::fs::read(&install).unwrap(), b"B");
    assert!(!install.with_file_name(".cmux-tui.prev.part").exists());
}

/// The step reads the daemon's binary only as the peer of its socket: here
/// this test process listens, so the peer is this test binary.
#[cfg(target_os = "linux")]
#[test]
fn the_daemon_binary_is_the_socket_peers_and_only_for_its_pid() {
    use super::daemon_binary;
    let folder = tempfile::tempdir().unwrap();
    let socket = folder.path().join("daemon.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let own = std::env::current_exe().unwrap();
    let pid = i32::try_from(std::process::id()).unwrap();
    let daemon = daemon_binary(&socket, pid).expect("the listener's binary");
    assert_eq!(std::fs::canonicalize(&daemon.path).unwrap(), std::fs::canonicalize(&own).unwrap());
    assert_eq!(Some(daemon.id), id(&own));
    // Another pid (the Mac's stale read: the daemon restarted since) is the
    // quiet `busy`, and nothing is read.
    let refused = daemon_binary(&socket, pid + 1).err().expect("another pid is refused");
    assert_eq!(refused, ("busy", super::RESTARTED.to_owned()));
    // No listener: nothing is read.
    let missing = daemon_binary(&folder.path().join("none.sock"), pid).err().expect("no socket");
    assert_eq!(missing.0, "failed");
}

#[test]
fn a_second_run_of_one_update_finds_its_outcome_claimed() {
    let folder = tempfile::tempdir().unwrap();
    let result = folder.path().join(".cmux-tui.update-0123456789abcdef.json");
    assert_eq!(claim_path(&result), folder.path().join(".cmux-tui.update-0123456789abcdef.lock"));
    let first = claim(&result).expect("the first run claims the outcome");
    // A start sent again while the first run checks: it writes nothing.
    assert!(claim(&result).is_none());
    // Another update (its own nonce) is not held by it; the folder lock orders those.
    assert!(claim(&folder.path().join(".cmux-tui.update-fedcba9876543210.json")).is_some());
    drop(first);
    assert!(claim(&result).is_some());
}

fn parsed(extra: &[&str]) -> Option<super::Args> {
    let sha = "a".repeat(64);
    let mut args: Vec<String> = [
        "--sha256",
        sha.as_str(),
        "--install",
        "/home/cmux/.cmux/bin/cmux-tui",
        "--daemon-pid",
        "42",
        "--result",
        "/home/cmux/.cmux/bin/.cmux-tui.update-0123456789abcdef.json",
    ]
    .map(str::to_owned)
    .to_vec();
    args.extend(extra.iter().map(|word| (*word).to_owned()));
    parse(&args)
}

fn route_of(extra: &[&str]) -> Option<Route> {
    parsed(extra).map(|args| args.route)
}

/// The Mac names the store route for a machine whose daemon runs from the store; an
/// older Mac names none (the work route), and any other route is refused.
#[test]
fn the_route_is_work_unless_the_mac_names_the_store() {
    assert_eq!(route_of(&[]), Some(Route::Work));
    assert_eq!(route_of(&["--route", "work"]), Some(Route::Work));
    assert_eq!(route_of(&["--route", "store"]), Some(Route::Store));
    assert_eq!(route_of(&["--route", "elsewhere"]), None);
    assert_eq!(route_of(&["--route"]), None);
}

/// `cmux host update install`'s answer: its state and detail, `unknown` for anything else.
#[test]
fn the_updaters_answer_is_read_from_its_last_json_line() {
    let line = |state: &str| format!("noise\n{{\"state\":\"{state}\",\"detail\":\"why\"}}\n");
    for state in ["updating", "current", "older", "off", "rolled-back-before", "failed"] {
        assert_eq!(store_answer(&line(state)), (state, "why".to_owned()));
    }
    assert_eq!(
        store_answer("sudo: a password is required"),
        ("unknown", "sudo: a password is required".to_owned())
    );
    assert_eq!(store_answer(&line("dancing")).0, "unknown");
}

/// The in-place flag takes no value, comes once, and only with the store route.
#[test]
fn the_in_place_flag_is_parsed_only_on_the_store_route() {
    let in_place = |extra: &[&str]| parsed(extra).map(|args| args.in_place);
    assert_eq!(in_place(&["--route", "store"]), Some(false));
    assert_eq!(in_place(&["--route", "store", IN_PLACE_FLAG]), Some(true));
    assert_eq!(in_place(&[IN_PLACE_FLAG, "--route", "store"]), Some(true));
    assert_eq!(in_place(&[IN_PLACE_FLAG]), None);
    assert_eq!(in_place(&["--route", "work", IN_PLACE_FLAG]), None);
    assert_eq!(in_place(&["--route", "store", IN_PLACE_FLAG, IN_PLACE_FLAG]), None);
    assert_eq!(in_place(&["--route", "store", IN_PLACE_FLAG, "yes"]), None);
}

/// A store that refuses the build as older gets it in place only for the explicit ask;
/// an updater turned off or a build rolled back before stays the machine's own decision.
#[test]
fn only_an_older_refusal_with_the_flag_installs_in_place() {
    assert_eq!(store_next("older", true), StoreNext::InPlace);
    assert_eq!(store_next("older", false), StoreNext::Foreign);
    for in_place in [false, true] {
        assert_eq!(store_next("off", in_place), StoreNext::Foreign);
        assert_eq!(store_next("rolled-back-before", in_place), StoreNext::Foreign);
        assert_eq!(store_next("updating", in_place), StoreNext::Wait);
        assert_eq!(store_next("current", in_place), StoreNext::Wait);
        assert_eq!(store_next("failed", in_place), StoreNext::Failed);
        assert_eq!(store_next("unknown", in_place), StoreNext::Failed);
    }
}

#[test]
fn a_daemon_in_place_replaces_only_a_store_entry() {
    let entry = format!("/opt/cmux/store/{}/cmux-tui", "a".repeat(64));
    assert!(runs_a_store_entry(Path::new(&entry)));
    for other in [
        "/home/cmux/.cmux/bin/cmux-tui",
        "/opt/cmux/store/notasha/cmux-tui",
        "/opt/cmux/current/bin/cmux-tui",
        &format!("{entry} (deleted)"),
        &format!("/opt/cmux/store/{}/acpmux", "a".repeat(64)),
    ] {
        assert!(!runs_a_store_entry(Path::new(other)), "{other}");
    }
}

#[test]
fn the_acpmux_link_follows_the_work_link_only_from_the_store() {
    let install = Path::new(INSTALL);
    assert_eq!(acpmux_link(Some(Path::new(STORE_ACPMUX)), install), AcpmuxLink::Relink);
    assert_eq!(acpmux_link(Some(install), install), AcpmuxLink::Follows);
    assert_eq!(acpmux_link(Some(Path::new("/usr/local/bin/acpmux")), install), AcpmuxLink::Other);
    assert_eq!(acpmux_link(None, install), AcpmuxLink::Other);
}

/// The in-place install renames the staged build over the store link, and the rollback
/// makes the link again: the work link is never missing, and nothing is left beside it.
#[test]
fn the_store_link_is_replaced_by_the_build_and_put_back() {
    let folder = tempfile::tempdir().unwrap();
    let install = folder.path().join("cmux-tui");
    let staged = folder.path().join(".cmux-tui.update-0123456789abcdef");
    std::os::unix::fs::symlink(STORE_CURRENT, &install).unwrap();
    std::fs::write(&staged, b"new").unwrap();
    std::fs::rename(&staged, &install).unwrap();
    let now = std::fs::symlink_metadata(&install).unwrap();
    assert!(now.is_file());
    assert_eq!(std::fs::read(&install).unwrap(), b"new");
    // A part left by an earlier run does not stop the rollback.
    std::fs::write(folder.path().join(".cmux-tui.store-part"), b"planted").unwrap();
    relink(&install, Path::new(STORE_CURRENT), ".cmux-tui.store-part").unwrap();
    assert_eq!(std::fs::read_link(&install).unwrap(), Path::new(STORE_CURRENT));
    assert!(!folder.path().join(".cmux-tui.store-part").exists());
    let names: Vec<_> =
        std::fs::read_dir(folder.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, ["cmux-tui"]);
}

/// A daemon that holds a person key is not dumpable, so its executable is read from its own
/// `daemon status`: the update is done once that names the installed build, and only then.
#[test]
fn a_daemon_status_names_the_binary_it_runs() {
    let binary = Path::new("/opt/cmux/store/abc/cmux-tui");
    assert!(status_names(r#"{"pid":7,"exe":"/opt/cmux/store/abc/cmux-tui"}"#, binary));
    assert!(!status_names(r#"{"pid":7,"exe":"/opt/cmux/store/old/cmux-tui"}"#, binary));
    assert!(!status_names(r#"{"pid":7}"#, binary), "an older daemon names no executable");
    assert!(!status_names("", binary), "no daemon answered");
}
