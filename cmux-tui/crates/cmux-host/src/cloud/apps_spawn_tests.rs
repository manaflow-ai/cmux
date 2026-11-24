//! `apps.spawn`, `apps.status` and `apps.stop` (`apps_spawn.rs`).

use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::apps_spawn::{
    AppUser, AppUsers, AppsRun, RunPaths, SpawnAsk, VersionAsk, answer, check_run, check_spawn,
    isolated, keeps_tree, open_log, spawn_env, staged_archive, start_plan, stat_of, still_running,
};

fn me() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

fn spawn_line(version_dir: &Path) -> Value {
    json!({
        "slug": "web", "version": 1, "versionDir": version_dir.display().to_string(),
        "subdir": "site", "cmd": "node server.js", "setup": "npm ci", "port": 41000,
        "env": {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "TZ": "UTC", "MODE": "prod"}
    })
}

/// `<dir>/apps/web/v1` with `src.tar` holding `src/<files>`.
fn staged(dir: &Path, files: &[(&str, &str)]) -> PathBuf {
    let version = dir.join("apps/web/v1");
    let src = dir.join("tree");
    std::fs::create_dir_all(&version).unwrap();
    for (name, body) in files {
        let path = src.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }
    std::fs::create_dir_all(&src).unwrap();
    let status = std::process::Command::new("tar")
        .arg("-cf")
        .arg(version.join("src.tar"))
        .arg("-C")
        .arg(&src)
        .arg(".")
        .status()
        .unwrap();
    assert!(status.success());
    version
}

#[test]
fn a_spawn_ask_is_checked() {
    let ask = check_spawn(&spawn_line(Path::new("/s/apps/web/v1"))).unwrap();
    assert_eq!(ask.port, 41000);
    assert_eq!(ask.setup.as_deref(), Some("npm ci"));
    assert_eq!(ask.subdir, "site");
    for (key, value) in [
        ("slug", json!("We b")),
        ("version", json!(0)),
        ("versionDir", json!("relative/apps/web/v1")),
        ("subdir", json!("../etc")),
        ("subdir", json!("/etc")),
        ("cmd", json!("")),
        ("port", json!(80)),
        ("env", json!({"HOME": "/root"})),
        ("env", json!({"PORT": "1"})),
        ("env", json!({"BAD KEY": "x"})),
        ("env", json!({"N": 1})),
    ] {
        let mut line = spawn_line(Path::new("/s/apps/web/v1"));
        line[key] = value.clone();
        assert!(check_spawn(&line).is_err(), "{key}={value} was accepted");
    }
    assert_eq!(
        check_run("apps.stop", &json!({"slug": "web", "version": 2})),
        Ok(AppsRun::Stop(VersionAsk { slug: "web".into(), version: 2 }))
    );
}

#[test]
fn the_app_environment_is_the_asked_allowlist_plus_home_and_port_only() {
    let asked = vec![
        ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
        ("TZ".to_owned(), "UTC".to_owned()),
        ("MODE".to_owned(), "prod".to_owned()),
    ];
    let env = spawn_env(&asked, Path::new("/var/lib/cmux-apps/1000/web/v1"), 41000);
    let keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["HOME", "MODE", "PATH", "PORT", "TZ"]);
    // Nothing of the agent's own environment comes along.
    let bare = spawn_env(&[], Path::new("/h"), 41000);
    assert_eq!(
        bare,
        [("HOME".to_owned(), "/h".to_owned()), ("PORT".to_owned(), "41000".to_owned())]
    );
}

#[test]
fn the_app_user_must_be_kept_off_the_agent_socket() {
    let user = AppUser { name: "cmux-app".into(), uid: 990, gid: 990 };
    assert!(isolated(&user, &[990], Some(1001), 1000));
    assert!(!isolated(&user, &[990, 1001], Some(1001), 1000), "in group cmux");
    assert!(!isolated(&user, &[990], Some(1001), 990), "the asking user");
    let root = AppUser { name: "root".into(), uid: 0, gid: 0 };
    assert!(!isolated(&root, &[0], None, 1000));
}

#[test]
fn only_the_askers_own_staged_version_is_copied() {
    let dir = tempfile::tempdir().unwrap();
    let version = staged(dir.path(), &[("site/server.js", "x")]);
    let ask = |version_dir: PathBuf| SpawnAsk {
        version_dir,
        ..check_spawn(&spawn_line(Path::new("/s/apps/web/v1"))).unwrap()
    };
    assert!(staged_archive(&ask(version.clone()), me()).is_ok());
    // Another user's directory.
    assert!(staged_archive(&ask(version.clone()), me().wrapping_add(1)).is_err());
    // Not a version directory of this slug and number.
    let other = dir.path().join("apps/web/v2");
    std::fs::create_dir_all(&other).unwrap();
    assert!(staged_archive(&ask(other), me()).is_err());
    // A symlinked version directory.
    let linked = dir.path().join("elsewhere/apps/web/v1");
    std::fs::create_dir_all(linked.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&version, &linked).unwrap();
    assert!(staged_archive(&ask(linked), me()).is_err());
    // A symlinked archive.
    let tar = version.join("src.tar");
    std::fs::rename(&tar, dir.path().join("real.tar")).unwrap();
    std::os::unix::fs::symlink(dir.path().join("real.tar"), &tar).unwrap();
    assert!(staged_archive(&ask(version), me()).is_err());
}

#[test]
fn a_symlinked_app_log_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("target");
    std::fs::write(&target, "keep").unwrap();
    let log = dir.path().join("app.log");
    std::os::unix::fs::symlink(&target, &log).unwrap();
    let refused = open_log(&log, me(), me()).unwrap_err();
    assert!(refused.contains("symbolic link"), "{refused}");
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "keep");

    let linked = dir.path().join("linked.log");
    std::fs::hard_link(&target, &linked).unwrap();
    assert!(open_log(&linked, me(), me()).is_err(), "a second hard link was opened");

    let plain = dir.path().join("plain.log");
    // SAFETY: getegid has no preconditions.
    let gid = unsafe { libc::getegid() };
    assert!(open_log(&plain, me(), gid).is_ok());
}

/// A fake `proc` entry for `pid`, state `state`, started at `start` ticks.
fn fake_stat(root: &Path, pid: u32, state: char, start: u64) {
    let dir = root.join(pid.to_string());
    std::fs::create_dir_all(&dir).unwrap();
    let fields: Vec<String> = (4..=21).map(|n| n.to_string()).collect();
    let stat = format!("{pid} (sh -c x) {state} {} {start} 0 0\n", fields.join(" "));
    std::fs::write(dir.join("stat"), stat).unwrap();
}

#[test]
fn a_pid_counts_only_with_its_recorded_start_time() {
    let dir = tempfile::tempdir().unwrap();
    fake_stat(dir.path(), 4242, 'S', 777);
    assert_eq!(stat_of(dir.path(), 4242), Some(('S', 777)));
    assert!(still_running(dir.path(), 4242, 777, me()));
    assert!(!still_running(dir.path(), 4242, 778, me()), "a reused pid");
    assert!(!still_running(dir.path(), 4242, 777, me().wrapping_add(1)), "another owner");
    fake_stat(dir.path(), 4243, 'Z', 777);
    assert!(!still_running(dir.path(), 4243, 777, me()), "a zombie");
}

struct Fixed(AppUser);

impl AppUsers for Fixed {
    fn ensure(&self) -> Result<AppUser, String> {
        Ok(self.0.clone())
    }
}

#[test]
fn a_reused_pid_is_neither_alive_nor_stopped() {
    let dir = tempfile::tempdir().unwrap();
    let paths = RunPaths { proc_root: dir.path().join("proc"), run_root: dir.path().join("run") };
    let slug_dir = paths.run_root.join(me().to_string()).join("web");
    std::fs::create_dir_all(&slug_dir).unwrap();
    std::fs::write(
        slug_dir.join("v1.run.json"),
        json!({"pid": 4242, "startTime": 777, "uid": me()}).to_string(),
    )
    .unwrap();
    // Pid 4242 now is another process, started later.
    fake_stat(&paths.proc_root, 4242, 'S', 900);
    let users = Fixed(AppUser { name: "cmux-app".into(), uid: 990, gid: 990 });
    let ask = |key: &str| check_run(key, &json!({"slug": "web", "version": 1}));
    let status = answer(&paths, ask("apps.status"), Some(me()), &users);
    assert_eq!(status["alive"], false, "{status}");
    let stop = answer(&paths, ask("apps.stop"), Some(me()), &users);
    assert_eq!(stop["stopped"], false, "{stop}");
    // Another user sees none of this user's versions.
    let theirs = answer(&paths, ask("apps.status"), Some(me().wrapping_add(1)), &users);
    assert_eq!(theirs["alive"], false);
    assert_eq!(answer(&paths, ask("apps.status"), None, &users)["ok"], false);
}

/// Waits (bounded) until `path` holds `needle`.
fn log_with(path: &Path, needle: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        if text.contains(needle) || Instant::now() > deadline {
            return text;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// As root, a real start: the process runs as the app user, not the asker, and the agent
/// socket (mode 0660, group `cmux` or root) is not writable to it.
#[test]
fn a_spawned_app_runs_as_another_user_off_the_agent_socket() {
    if me() != 0 {
        eprintln!(
            "skipped: starting an app as another user needs root (run under the fleet's root lane)"
        );
        return;
    }
    let Some(nobody) = nobody() else {
        eprintln!("skipped: no `nobody` account");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let socket = dir.path().join("agent.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o660)).unwrap();
    let version = staged(dir.path(), &[("site/hello.txt", "hi")]);
    let paths = RunPaths { proc_root: PathBuf::from("/proc"), run_root: dir.path().join("run") };
    let mut line = spawn_line(&version);
    line["setup"] = Value::Null;
    line["cmd"] = json!(format!(
        "echo uid=$(id -u); if test -w {sock}; then echo socket=open; else echo socket=refused; fi; cat hello.txt; exec sleep 30",
        sock = socket.display()
    ));
    let users = Fixed(nobody.clone());
    let started = answer(&paths, check_run("apps.spawn", &line), Some(0), &users);
    assert_eq!(started["ok"], true, "{started}");
    let pid = u32::try_from(started["pid"].as_u64().unwrap()).unwrap();
    let log = PathBuf::from(started["log"].as_str().unwrap());
    let text = log_with(&log, "hi");
    assert!(text.contains(&format!("uid={}", nobody.uid)), "{text}");
    assert!(text.contains("socket=refused"), "{text}");
    assert_ne!(std::fs::metadata(format!("/proc/{pid}")).unwrap().uid(), 0, "runs as the asker");
    assert_eq!(started["startTime"].as_u64(), stat_of(Path::new("/proc"), pid).map(|(_, s)| s));

    let ask = |key: &str| check_run(key, &json!({"slug": "web", "version": 1}));
    assert_eq!(answer(&paths, ask("apps.status"), Some(0), &users)["alive"], true);
    assert_eq!(answer(&paths, ask("apps.stop"), Some(0), &users)["stopped"], true);

    // A symlinked app.log in the run directory refuses the next start.
    std::fs::remove_file(&log).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", &log).unwrap();
    let refused = answer(&paths, check_run("apps.spawn", &line), Some(0), &users);
    assert_eq!(refused["ok"], false);
    assert!(refused["error"]["message"].as_str().unwrap().contains("symbolic link"), "{refused}");
}

fn nobody() -> Option<AppUser> {
    let name = std::ffi::CString::new("nobody").unwrap();
    // SAFETY: getpwnam takes a NUL-terminated name; the entry is read at once.
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    // SAFETY: a non-null entry points to a valid passwd record.
    (!entry.is_null()).then(|| unsafe {
        AppUser { name: "nobody".into(), uid: (*entry).pw_uid, gid: (*entry).pw_gid }
    })
}

#[test]
fn loader_variables_are_refused_outright() {
    for key in [
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        "GCONV_PATH",
        "GLIBC_TUNABLES",
        "MALLOC_CHECK_",
        "LOCPATH",
        "NLSPATH",
        "HOSTALIASES",
        "RESOLV_HOST_CONF",
    ] {
        let mut line = spawn_line(Path::new("/s/apps/web/v1"));
        line["env"] = json!({ key: "/tmp/evil.so" });
        let refused = check_spawn(&line);
        assert!(refused.is_err(), "{key} was accepted");
    }
}

#[test]
fn the_root_side_exec_gets_no_loader_variable_and_no_app_directory() {
    let mut ask = check_spawn(&spawn_line(Path::new("/s/apps/web/v1"))).unwrap();
    // Even an ask that slipped a loader variable past the check never reaches root's exec.
    ask.env.push(("LD_PRELOAD".to_owned(), "/tmp/evil.so".to_owned()));
    let user = AppUser { name: "cmux-app".into(), uid: 990, gid: 990 };
    let run = Path::new("/var/lib/cmux-apps/1000/web/v1");
    let plan = start_plan(&user, &ask, run);
    // Root runs setpriv from `/` with exactly the app's environment (setpriv keeps it across
    // the drop): the allowed variables, HOME and PORT, and no loader variable.
    assert_eq!(plan.root_env, spawn_env(&ask.env, run, 41000));
    assert!(plan.root_env.iter().all(|(k, _)| !k.starts_with("LD_")), "{:?}", plan.root_env);
    assert!(plan.root_env.contains(&("PORT".to_owned(), "41000".to_owned())));
    assert!(plan.root_env.contains(&("HOME".to_owned(), run.display().to_string())));
    assert!(plan.root_env.contains(&("MODE".to_owned(), "prod".to_owned())));
    assert_eq!(plan.root_dir, PathBuf::from("/"));
    assert_eq!(plan.program, "/usr/bin/setpriv");
    let dash = plan.args.iter().position(|a| a == "--").unwrap();
    // After the drop: straight into the shell, no `env -i K=V ...` on the command line.
    assert_eq!(plan.args[dash + 1..dash + 3], ["/bin/sh".to_owned(), "-c".to_owned()]);
    assert!(plan.args.iter().all(|a| !a.contains("LD_PRELOAD")));
    // The chdir into src/<subdir> happens in the shell, as the app user.
    let script = plan.args.iter().skip_while(|a| a.as_str() != "-c").nth(1).unwrap();
    assert!(script.starts_with("cd -- \"$1\" ||"), "{script}");
    assert!(plan.args.contains(&run.join("src/site").display().to_string()));
}

#[test]
fn no_variable_value_is_on_the_planned_command_line() {
    // `/proc/<pid>/cmdline` is world-readable: an app's secrets (the platform's `process-env`)
    // must reach it only through the environment, never as an argument.
    let secret = "sk_live_only_for_web";
    let mut line = spawn_line(Path::new("/s/apps/web/v1"));
    line["env"]["STRIPE_KEY"] = json!(secret);
    let ask = check_spawn(&line).unwrap();
    let user = AppUser { name: "cmux-app".into(), uid: 990, gid: 990 };
    let run = Path::new("/var/lib/cmux-apps/1000/web/v1");
    let plan = start_plan(&user, &ask, run);
    assert!(plan.root_env.contains(&("STRIPE_KEY".to_owned(), secret.to_owned())));
    for arg in std::iter::once(&plan.program).chain(&plan.args) {
        assert!(!arg.contains(secret), "a secret is in argv: {arg}");
        assert!(!arg.contains("STRIPE_KEY"), "an app variable is in argv: {arg}");
        assert!(!arg.contains("MODE=prod"), "an app variable is in argv: {arg}");
    }
}

#[test]
fn only_a_restart_reuses_an_unpacked_tree() {
    assert!(keeps_tree(true, true), "a restart runs the tree it first started from");
    assert!(!keeps_tree(true, false), "a restart with no tree unpacks one");
    assert!(!keeps_tree(false, true), "a fresh start replaces an old tree");
    assert!(!keeps_tree(false, false));
    let mut line = spawn_line(Path::new("/s/apps/web/v1"));
    assert!(!check_spawn(&line).unwrap().restart);
    line["restart"] = json!(true);
    assert!(check_spawn(&line).unwrap().restart);
}

/// Runs `f` on a thread; `None` when it didn't return within 5 s (it blocked).
fn within<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx.recv_timeout(Duration::from_secs(5)).ok()
}

fn mkfifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: mkfifo takes a NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}

#[test]
fn a_fifo_app_log_is_refused_without_blocking() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("app.log");
    mkfifo(&log);
    // SAFETY: getegid has no preconditions.
    let gid = unsafe { libc::getegid() };
    let opened = within(move || open_log(&log, me(), gid).map(|_| ()));
    let refused = opened.expect("opening a FIFO app.log blocked");
    assert!(refused.is_err());
}

#[test]
fn a_fifo_src_tar_is_refused_without_blocking() {
    let dir = tempfile::tempdir().unwrap();
    let version = dir.path().join("apps/web/v1");
    std::fs::create_dir_all(&version).unwrap();
    mkfifo(&version.join("src.tar"));
    let ask = SpawnAsk {
        version_dir: version,
        ..check_spawn(&spawn_line(Path::new("/s/apps/web/v1"))).unwrap()
    };
    let opened = within(move || staged_archive(&ask, me()).map(|_| ()));
    let refused = opened.expect("opening a FIFO src.tar blocked");
    assert!(refused.is_err());
}

/// As root: a fresh start over an existing tree replaces it, and a failed unpack leaves the
/// tree that was there, never a partial one.
#[test]
fn a_fresh_start_replaces_the_tree_and_a_failed_unpack_leaves_none_half_done() {
    if me() != 0 {
        eprintln!(
            "skipped: unpacking as another user needs root (run under the fleet's root lane)"
        );
        return;
    }
    let Some(nobody) = nobody() else {
        eprintln!("skipped: no `nobody` account");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let paths = RunPaths { proc_root: PathBuf::from("/proc"), run_root: dir.path().join("run") };
    let users = Fixed(nobody);
    let ask = |version: &Path, restart: bool| {
        let mut line = spawn_line(version);
        line["setup"] = Value::Null;
        line["cmd"] = json!("cat hello.txt; exec sleep 30");
        line["restart"] = json!(restart);
        check_run("apps.spawn", &line)
    };
    let stop = |paths: &RunPaths| {
        answer(
            paths,
            check_run("apps.stop", &json!({"slug": "web", "version": 1})),
            Some(0),
            &users,
        )
    };

    let first = staged(&dir.path().join("a"), &[("site/hello.txt", "one")]);
    let started = answer(&paths, ask(&first, false), Some(0), &users);
    assert_eq!(started["ok"], true, "{started}");
    let run = PathBuf::from(started["runDir"].as_str().unwrap());
    stop(&paths);

    let second = staged(&dir.path().join("b"), &[("site/hello.txt", "two")]);
    let again = answer(&paths, ask(&second, false), Some(0), &users);
    assert_eq!(again["ok"], true, "{again}");
    assert_eq!(std::fs::read_to_string(run.join("src/site/hello.txt")).unwrap(), "two");
    stop(&paths);

    // A restart keeps the tree even with another archive staged.
    let third = staged(&dir.path().join("c"), &[("site/hello.txt", "three")]);
    let restarted = answer(&paths, ask(&third, true), Some(0), &users);
    assert_eq!(restarted["ok"], true, "{restarted}");
    assert_eq!(std::fs::read_to_string(run.join("src/site/hello.txt")).unwrap(), "two");
    stop(&paths);

    // A broken archive: the start is refused and the old tree is whole.
    std::fs::write(third.join("src.tar"), b"not a tar archive").unwrap();
    let broken = answer(&paths, ask(&third, false), Some(0), &users);
    assert_eq!(broken["ok"], false, "{broken}");
    assert_eq!(std::fs::read_to_string(run.join("src/site/hello.txt")).unwrap(), "two");
    let leftovers: Vec<String> = std::fs::read_dir(&run)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("src."))
        .collect();
    assert!(leftovers.is_empty(), "partial trees left: {leftovers:?}");
}
