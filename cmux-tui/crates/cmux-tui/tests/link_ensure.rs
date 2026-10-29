//! `cmux link ensure`, `stop` and `status` at the CLI boundary (cx-rtipa
//! S1): an app starts the per-user link on demand, and links of separate
//! state directories (a tagged DEV app's and the release app's) never share
//! a socket or a registration, also with one runtime directory.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// One temporary home with a shared runtime base (`TMPDIR`) for every link.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        // Short: the runtime base holds Unix socket paths.
        let root = PathBuf::from("/tmp").join(format!(
            "cle-{name}-{}-{}",
            std::process::id(),
            stamp % 1_000_000
        ));
        std::fs::create_dir_all(root.join("home")).unwrap();
        std::fs::create_dir_all(root.join("run")).unwrap();
        Self { root }
    }

    /// A state root (`CMUX_TUI_STATE_DIR`) of one app, e.g. one tag.
    fn app(&self, name: &str) -> App {
        let state_root = self.root.join(name);
        std::fs::create_dir_all(&state_root).unwrap();
        App { root: self.root.clone(), state_root }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        for name in ["a", "b", "c"] {
            let app = App { root: self.root.clone(), state_root: self.root.join(name) };
            if app.state_root.exists() {
                let _ =
                    app.cmux(&["link", "stop", "--state-dir", app.state_dir().to_str().unwrap()]);
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct App {
    root: PathBuf,
    state_root: PathBuf,
}

impl App {
    fn state_dir(&self) -> PathBuf {
        self.state_root.join("link")
    }

    fn cmux(&self, args: &[&str]) -> Output {
        self.cmux_in(&self.root.join("run"), args)
    }

    /// `cmux` with `run` as its `TMPDIR` (the runtime base).
    fn cmux_in(&self, run: &Path, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(args)
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", run)
            .env_remove("XDG_RUNTIME_DIR")
            .env("CMUX_TUI_STATE_DIR", &self.state_root)
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = self.cmux(args);
        assert!(
            out.status.success(),
            "{args:?} failed: {}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let text = String::from_utf8_lossy(&out.stdout);
        let line = text.lines().last().unwrap_or_default();
        serde_json::from_str(line).unwrap_or_else(|e| panic!("{args:?}: not JSON ({e}): {text}"))
    }

    fn ensure(&self, extra: &[&str]) -> Value {
        let dir = self.state_dir();
        let mut args = vec!["link", "ensure", "--state-dir", dir.to_str().unwrap()];
        args.extend_from_slice(extra);
        self.json(&args)
    }

    fn status(&self) -> Value {
        let dir = self.state_dir();
        self.json(&["link", "status", "--state-dir", dir.to_str().unwrap()])
    }

    fn stop(&self) -> Value {
        let dir = self.state_dir();
        self.json(&["link", "stop", "--state-dir", dir.to_str().unwrap()])
    }

    fn registration(&self) -> PathBuf {
        self.state_root.join("link.json")
    }
}

fn pid(value: &Value) -> u32 {
    u32::try_from(value["pid"].as_u64().unwrap_or_else(|| panic!("no pid in {value}"))).unwrap()
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// `cmux link dial` against `socket` gets an answer from that link: no
/// paired install has this id.
fn dial_answers(app: &App, socket: &Path) {
    let out =
        app.cmux(&["link", "dial", "--host", "inst_nobody", "--socket", socket.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "dial: {stderr}");
    assert!(stderr.contains("unknown_host"), "dial: {stderr}");
}

#[test]
fn link_ensure_starts_one_link_and_keeps_it() {
    let base = Scratch::new("one");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    assert_eq!(first["status"], "started", "{first}");
    let second = app.ensure(&[]);
    assert_eq!(second["status"], "running", "{second}");
    assert_eq!(pid(&first), pid(&second));
    assert_eq!(first["socket"], second["socket"]);
    let status = app.status();
    assert_eq!(status["running"], true, "{status}");
    assert_eq!(pid(&status), pid(&first));
    assert_eq!(status["install"], "inst_app_a");
    assert!(app.registration().exists());
    dial_answers(&app, Path::new(first["socket"].as_str().unwrap()));
    // The link outlives the `ensure` that started it.
    assert!(alive(pid(&first)));
}

#[test]
fn link_ensure_refuses_another_install_or_port() {
    let base = Scratch::new("mis");
    let app = base.app("a");
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let dir = app.state_dir();
    let out = app.cmux(&[
        "link",
        "ensure",
        "--state-dir",
        dir.to_str().unwrap(),
        "--install",
        "inst_other",
    ]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("install_mismatch"));
    let out = app.cmux(&["link", "ensure", "--state-dir", dir.to_str().unwrap(), "--port", "4101"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("port_mismatch"));
}

/// The app owns its link (`--handoff`): after a sign-out and a new sign-in
/// (a new install), ensure stops the old link and starts one as the new
/// install, with a new WireGuard key and no paired peers. Nothing is
/// deleted: when the old install comes back, it gets its own key and peers.
#[test]
fn link_ensure_with_handoff_switches_installs_and_keeps_each_ones_key_and_peers() {
    let base = Scratch::new("reinst");
    let app = base.app("a");
    let dir = app.state_dir();
    let dir = dir.to_str().unwrap();
    let key = |app: &App| app.json(&["link", "show", "--state-dir", dir])["public_key"].clone();
    let peers =
        |app: &App| app.json(&["link", "peer", "list", "--state-dir", dir])["peers"].clone();
    let old = app.ensure(&["--install", "inst_old", "--port", "0", "--handoff"]);
    app.json(&[
        "link",
        "peer",
        "add",
        "--state-dir",
        dir,
        "--install",
        "inst_peer",
        "--user",
        "u_old",
        "--team",
        "t_old",
        "--public-key",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]);
    let old_key = key(&app);
    let old_peers = peers(&app);
    assert_eq!(old_peers.as_array().map(Vec::len), Some(1), "{old_peers}");

    let new = app.ensure(&["--install", "inst_new", "--handoff"]);
    assert_eq!(new["status"], "restarted", "{new}");
    assert_ne!(pid(&new), pid(&old));
    assert!(!alive(pid(&old)), "the old link still runs");
    assert_eq!(app.status()["install"], "inst_new");
    assert_eq!(app.status()["port"], 0, "the port stays");
    assert_ne!(key(&app), old_key, "a new install got the old install's key");
    assert_eq!(peers(&app), serde_json::json!([]), "the old install's peers carried over");

    let back = app.ensure(&["--install", "inst_old", "--handoff"]);
    assert_eq!(back["status"], "restarted", "{back}");
    assert_eq!(key(&app), old_key, "the old install did not get its key back");
    assert_eq!(peers(&app), old_peers, "the old install did not get its peers back");
}

/// Without `--handoff` (a CLI), a running link that serves another session
/// socket is refused, never reported as the link that was asked for; with
/// it (the app), the link restarts with the asked-for session socket.
#[test]
fn link_ensure_refuses_or_restarts_a_link_that_serves_another_session_socket() {
    let base = Scratch::new("served");
    let app = base.app("a");
    let first = app.ensure(&[
        "--install",
        "inst_app_a",
        "--port",
        "0",
        "--session-socket",
        "/tmp/one.sock",
    ]);
    assert_eq!(app.status()["session_socket"], "/tmp/one.sock");
    let dir = app.state_dir();
    let out = app.cmux(&[
        "link",
        "ensure",
        "--state-dir",
        dir.to_str().unwrap(),
        "--session-socket",
        "/tmp/two.sock",
    ]);
    assert!(!out.status.success(), "a mismatched link was reported as running");
    assert!(String::from_utf8_lossy(&out.stderr).contains("config_mismatch"));
    assert_eq!(pid(&app.status()), pid(&first), "the refused ensure touched the link");
    let again = app.ensure(&["--session-socket", "/tmp/two.sock", "--handoff"]);
    assert_eq!(again["status"], "restarted", "{again}");
    assert_eq!(app.status()["session_socket"], "/tmp/two.sock");
    // The server config is compared by its bytes too.
    let config = base.root.join("server.json");
    std::fs::write(&config, "{}").unwrap();
    let config = config.to_str().unwrap();
    app.ensure(&["--session-socket", "/tmp/two.sock", "--server-config", config, "--handoff"]);
    std::fs::write(config, "{ }").unwrap();
    let out = app.cmux(&[
        "link",
        "ensure",
        "--state-dir",
        dir.to_str().unwrap(),
        "--session-socket",
        "/tmp/two.sock",
        "--server-config",
        config,
    ]);
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("config_mismatch"),
        "a changed server.json passed"
    );
}

/// A link of another state folder that shares the registration folder is
/// never reported or stopped (the registration names its socket).
#[test]
fn link_status_and_stop_ignore_a_link_of_another_state_folder() {
    let base = Scratch::new("other");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let other = app.state_root.join("other");
    let other = other.to_str().unwrap();
    let status = app.json(&["link", "status", "--state-dir", other]);
    assert_eq!(status["running"], false, "{status}");
    let stopped = app.json(&["link", "stop", "--state-dir", other]);
    assert_eq!(stopped["stopped"], false, "{stopped}");
    assert!(alive(pid(&first)), "stop of another state folder ended this link");
    assert_eq!(pid(&app.status()), pid(&first));
}

/// Two ensures at once start one link; a second `serve` of the same state
/// directory refuses at its lock.
#[test]
fn link_ensure_at_once_starts_one_link_and_a_second_serve_refuses() {
    let base = Scratch::new("race");
    let app = base.app("a");
    app.json(&[
        "link",
        "init",
        "--state-dir",
        app.state_dir().to_str().unwrap(),
        "--install",
        "inst_app_a",
        "--port",
        "0",
    ]);
    let answers: Vec<Value> = std::thread::scope(|scope| {
        let runs: Vec<_> = (0..4).map(|_| scope.spawn(|| app.ensure(&[]))).collect();
        runs.into_iter().map(|run| run.join().unwrap()).collect()
    });
    let pids: std::collections::BTreeSet<u32> = answers.iter().map(pid).collect();
    assert_eq!(pids.len(), 1, "two links started: {answers:?}");
    assert_eq!(answers.iter().filter(|a| a["status"] == "started").count(), 1, "{answers:?}");
    let out = app.cmux(&["link", "serve", "--state-dir", app.state_dir().to_str().unwrap()]);
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("already runs"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// `stop` reports a link stopped only after its process is gone, and a link
/// that does not end is an error, not a stopped link.
#[test]
fn link_stop_waits_for_the_process_and_fails_for_a_link_that_does_not_end() {
    let base = Scratch::new("hang");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let link = pid(&first);
    // SAFETY: the pid of the link this test started, read from its answer.
    assert_eq!(unsafe { libc::kill(link as libc::pid_t, libc::SIGSTOP) }, 0);
    let dir = app.state_dir();
    let out = app.cmux(&["link", "stop", "--state-dir", dir.to_str().unwrap()]);
    assert!(!out.status.success(), "a link that did not end was reported stopped");
    assert!(String::from_utf8_lossy(&out.stderr).contains("stop_timeout"));
    // SAFETY: as above.
    assert_eq!(unsafe { libc::kill(link as libc::pid_t, libc::SIGCONT) }, 0);
    // The SIGTERM is still pending; a fresh link answers to `ensure` after
    // a real stop of whatever runs now.
    let _ = app.cmux(&["link", "stop", "--state-dir", dir.to_str().unwrap()]);
    let second = app.ensure(&[]);
    let stopped = app.stop();
    assert_eq!(stopped["stopped"], true, "{stopped}");
    assert!(!alive(pid(&second)), "stop answered before the process was gone");
}

/// A link that is ending has removed its registration and socket but still
/// runs, and holds `link.lock` until it exits. `stop` must not answer that
/// no link runs (the next `ensure` would start a link that cannot take the
/// lock and exits: "the link did not start"); it waits for the lock, and a
/// link that never lets go is `stop_timeout`. The test holds the lock in the
/// ending link's place, so the order is fixed, not raced.
#[test]
fn link_stop_waits_for_an_ending_link_that_still_holds_its_lock() {
    use std::os::fd::AsRawFd as _;
    let base = Scratch::new("ending");
    let app = base.app("a");
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    assert_eq!(app.stop()["stopped"], true);
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(app.state_dir().join("link.lock"))
        .expect("the link's lock file");
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let dir = app.state_dir();
    let out = app.cmux(&["link", "stop", "--state-dir", dir.to_str().unwrap()]);
    assert!(
        !out.status.success(),
        "stop answered while a link of this state directory still ran: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("stop_timeout"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // The ending link is gone: stop answers at once, and ensure starts one.
    drop(lock);
    assert_eq!(app.stop()["stopped"], false);
    let started = app.ensure(&[]);
    assert_eq!(started["status"], "started", "{started}");
    assert_eq!(app.stop()["stopped"], true);
}

/// A link that is ending drops its listener before it removes its
/// registration: for that moment its registration still names its own
/// socket and a live pid, no connect reaches it, and it still holds
/// `link.lock`. `stop` must wait for the lock then too, not answer "no link
/// runs". The test writes that registration (its own live pid, the link's
/// own socket, no listener) and holds the lock in the ending link's place.
#[test]
fn link_stop_waits_for_an_ending_link_whose_registration_is_still_there() {
    use std::os::fd::AsRawFd as _;
    let base = Scratch::new("ending-reg");
    let app = base.app("a");
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let mut ending: Value = serde_json::from_slice(
        &std::fs::read(app.registration()).expect("the link's registration"),
    )
    .expect("registration JSON");
    assert_eq!(app.stop()["stopped"], true);
    ending["pid"] = Value::from(std::process::id());
    std::fs::write(app.registration(), serde_json::to_vec(&ending).unwrap()).unwrap();
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(app.state_dir().join("link.lock"))
        .expect("the link's lock file");
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let dir = app.state_dir();
    let out = app.cmux(&["link", "stop", "--state-dir", dir.to_str().unwrap()]);
    assert!(
        !out.status.success(),
        "stop answered while a link of this state directory still ran: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("stop_timeout"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // The ending link is gone: it removed its registration and let go.
    std::fs::remove_file(app.registration()).unwrap();
    drop(lock);
    assert_eq!(app.stop()["stopped"], false);
    let started = app.ensure(&[]);
    assert_eq!(started["status"], "started", "{started}");
    assert_eq!(app.stop()["stopped"], true);
}

/// The link never binds its socket in a folder that other users may open.
#[test]
fn link_ensure_refuses_a_socket_folder_open_to_other_users() {
    use std::os::unix::fs::PermissionsExt;
    let base = Scratch::new("perm");
    let app = base.app("a");
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let folder = base.root.join("run").join(format!("cmux-tui-{uid}"));
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();
    let dir = app.state_dir();
    let out = app.cmux(&[
        "link",
        "ensure",
        "--state-dir",
        dir.to_str().unwrap(),
        "--install",
        "inst_app_a",
        "--port",
        "0",
    ]);
    assert!(!out.status.success(), "the link bound in an open folder");
    assert!(!app.registration().exists());
}

/// A bad install id (it would name archive files) is refused before
/// anything changes: the running link, its key and its peers stay.
#[test]
fn link_ensure_refuses_a_bad_install_id_before_it_changes_anything() {
    let base = Scratch::new("badid");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let dir = app.state_dir();
    let d = dir.to_str().unwrap();
    app.json(&[
        "link",
        "peer",
        "add",
        "--state-dir",
        d,
        "--install",
        "inst_peer",
        "--user",
        "u_a",
        "--team",
        "t_a",
        "--public-key",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]);
    let key = std::fs::read(dir.join("private.key")).unwrap();
    let peers = std::fs::read(dir.join("peers.json")).unwrap();
    let out = app.cmux(&["link", "ensure", "--state-dir", d, "--install", "x/y", "--handoff"]);
    assert!(!out.status.success(), "a bad install id was accepted");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("invalid_install"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(alive(pid(&first)), "the running link was stopped");
    assert_eq!(pid(&app.status()), pid(&first));
    assert_eq!(std::fs::read(dir.join("private.key")).unwrap(), key, "the key changed");
    assert_eq!(std::fs::read(dir.join("peers.json")).unwrap(), peers, "the peers changed");
    let moved: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .filter(|name| {
            name.starts_with("private.key.") || (name.starts_with("peers.") && name != "peers.json")
        })
        .collect();
    assert!(moved.is_empty(), "archive files appeared: {moved:?}");
}

/// The app starts its link with its own fixed runtime base; a CLI caller
/// with another `TMPDIR` still finds, reports and stops that link of its
/// state directory (the registration names the socket; its name, not its
/// folder, ties it to the state directory).
#[test]
fn link_status_and_stop_find_the_link_from_another_tmpdir() {
    let base = Scratch::new("tmpdir");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let other = base.root.join("run2");
    std::fs::create_dir_all(&other).unwrap();
    let dir = app.state_dir();
    let d = dir.to_str().unwrap();
    let status = app.cmux_in(&other, &["link", "status", "--state-dir", d]);
    let status: Value = serde_json::from_slice(status.stdout.trim_ascii()).unwrap();
    assert_eq!(status["running"], true, "{status}");
    assert_eq!(pid(&status), pid(&first));
    let again = app.cmux_in(&other, &["link", "ensure", "--state-dir", d]);
    let again: Value = serde_json::from_slice(again.stdout.trim_ascii()).unwrap();
    assert_eq!(again["status"], "running", "a second link started: {again}");
    // A registered socket whose folder others may open is not used.
    {
        use std::os::unix::fs::PermissionsExt;
        let socket = PathBuf::from(first["socket"].as_str().unwrap());
        let folder = socket.parent().unwrap().to_path_buf();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();
        let open = app.cmux_in(&other, &["link", "status", "--state-dir", d]);
        let open: Value = serde_json::from_slice(open.stdout.trim_ascii()).unwrap();
        let refused = app.cmux_in(&other, &["link", "stop", "--state-dir", d]);
        let refused: Value = serde_json::from_slice(refused.stdout.trim_ascii()).unwrap();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(open["running"], false, "a socket in an open folder was used: {open}");
        assert_eq!(refused["stopped"], false, "a socket in an open folder was stopped: {refused}");
        assert!(alive(pid(&first)));
    }
    let stopped = app.cmux_in(&other, &["link", "stop", "--state-dir", d]);
    let stopped: Value = serde_json::from_slice(stopped.stdout.trim_ascii()).unwrap();
    assert_eq!(stopped["stopped"], true, "{stopped}");
    assert!(!alive(pid(&first)));
}

/// After a sign-out the app archives the install (`link archive`): the key
/// and peers go into its archive and the config goes, so an ensure without
/// `--install` cannot start the link as that account; the same install
/// signing in again gets its key and peers back. Refused while it runs.
#[test]
fn link_archive_puts_the_install_away_and_the_same_install_gets_it_back() {
    let base = Scratch::new("archive");
    let app = base.app("a");
    let dir = app.state_dir();
    let d = dir.to_str().unwrap();
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    app.json(&[
        "link",
        "peer",
        "add",
        "--state-dir",
        d,
        "--install",
        "inst_peer",
        "--user",
        "u_a",
        "--team",
        "t_a",
        "--public-key",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]);
    let key = app.json(&["link", "show", "--state-dir", d])["public_key"].clone();
    let busy = app.cmux(&["link", "archive", "--state-dir", d]);
    assert!(!busy.status.success(), "archived while the link runs");
    assert!(String::from_utf8_lossy(&busy.stderr).contains("link_running"));
    app.stop();
    let archived = app.json(&["link", "archive", "--state-dir", d]);
    assert_eq!(archived["archived"], true, "{archived}");
    assert!(!dir.join("config.json").exists() && !dir.join("private.key").exists());
    let out = app.cmux(&["link", "ensure", "--state-dir", d]);
    assert!(!out.status.success(), "an ensure without --install started the archived install");
    assert!(app.status()["running"] == false);
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    assert_eq!(
        app.json(&["link", "show", "--state-dir", d])["public_key"],
        key,
        "the install did not get its key back"
    );
    let peers = app.json(&["link", "peer", "list", "--state-dir", d])["peers"].clone();
    assert_eq!(
        peers.as_array().map(Vec::len),
        Some(1),
        "the install did not get its peers back: {peers}"
    );
}

/// A restore never overwrites a current key that was not archived first.
#[test]
fn link_ensure_refuses_to_restore_over_an_unarchived_key() {
    use std::os::unix::fs::PermissionsExt;
    let base = Scratch::new("orphan");
    let app = base.app("a");
    let dir = app.state_dir();
    let d = dir.to_str().unwrap();
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    app.stop();
    app.json(&["link", "archive", "--state-dir", d]);
    std::fs::write(dir.join("private.key"), b"stray").unwrap();
    std::fs::set_permissions(dir.join("private.key"), std::fs::Permissions::from_mode(0o600))
        .unwrap();
    let out =
        app.cmux(&["link", "ensure", "--state-dir", d, "--install", "inst_app_a", "--port", "0"]);
    assert!(!out.status.success(), "a restore overwrote an unarchived key");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("unarchived_key"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(std::fs::read(dir.join("private.key")).unwrap(), b"stray");
    assert!(dir.join("private.key.inst_app_a").exists(), "the archive went");
}

#[test]
fn link_ensure_needs_an_install_the_first_time() {
    let base = Scratch::new("first");
    let app = base.app("a");
    let dir = app.state_dir();
    let out = app.cmux(&["link", "ensure", "--state-dir", dir.to_str().unwrap()]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--install"));
    assert!(!app.registration().exists());
}

#[test]
fn link_ensure_gives_two_state_dirs_two_links_on_one_runtime_dir() {
    let base = Scratch::new("two");
    let tag = base.app("a");
    let release = base.app("b");
    let a = tag.ensure(&["--install", "inst_tag", "--port", "0"]);
    let b = release.ensure(&["--install", "inst_release", "--port", "0"]);
    assert_eq!(a["status"], "started", "{a}");
    assert_eq!(b["status"], "started", "{b}");
    assert_ne!(pid(&a), pid(&b));
    assert_ne!(a["socket"], b["socket"], "two links share a socket");
    assert_ne!(tag.registration(), release.registration());
    assert_eq!(tag.status()["install"], "inst_tag");
    assert_eq!(release.status()["install"], "inst_release");
    dial_answers(&tag, Path::new(a["socket"].as_str().unwrap()));
    dial_answers(&release, Path::new(b["socket"].as_str().unwrap()));
    // Stopping one leaves the other running.
    assert_eq!(tag.stop()["stopped"], true);
    assert_eq!(tag.status()["running"], false);
    assert_eq!(pid(&release.status()), pid(&b));
}

#[test]
fn link_stop_ends_the_registered_link_and_its_registration() {
    let base = Scratch::new("stop");
    let app = base.app("a");
    let started = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let stopped = app.stop();
    assert_eq!(stopped["stopped"], true, "{stopped}");
    assert!(!app.registration().exists(), "link.json stayed after stop");
    assert!(!Path::new(started["socket"].as_str().unwrap()).exists(), "socket stayed after stop");
    assert_eq!(app.status()["running"], false);
    assert_eq!(app.stop()["stopped"], false);
}

#[test]
fn link_ensure_restarts_a_link_that_died() {
    let base = Scratch::new("dead");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let dead = pid(&first);
    // SAFETY: the pid of the link this test started, read from its answer.
    assert_eq!(unsafe { libc::kill(dead as libc::pid_t, libc::SIGKILL) }, 0);
    // A killed link leaves its registration; `ensure` must not trust it.
    let mut reaped = false;
    for _ in 0..200 {
        if !alive(dead) {
            reaped = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(reaped, "the killed link {dead} is still alive");
    assert_eq!(app.status()["running"], false);
    let again = app.ensure(&[]);
    assert_eq!(again["status"], "started", "{again}");
    assert_ne!(pid(&again), dead);
    dial_answers(&app, Path::new(again["socket"].as_str().unwrap()));
}
