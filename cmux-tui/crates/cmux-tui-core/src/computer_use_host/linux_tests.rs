use super::*;

#[test]
fn session_vars_come_from_the_daemon_first() {
    let own = |name: &str| match name {
        "DISPLAY" => Some(OsString::from(":1")),
        "XDG_RUNTIME_DIR" => Some(OsString::from("/nonexistent-run")),
        "WAYLAND_DISPLAY" => Some(OsString::new()),
        _ => None,
    };
    let env = session_env(own);
    assert!(env.contains(&("DISPLAY".into(), ":1".into())));
    assert!(!env.iter().any(|(k, _)| k == "WAYLAND_DISPLAY"));
    assert_eq!(
        parse_environment("DISPLAY=:0\nBROKEN\nA=b=c\n"),
        [("DISPLAY".to_string(), ":0".to_string()), ("A".into(), "b=c".into())]
    );
}

#[test]
fn the_headless_switch_reaches_the_worker() {
    let own = |name: &str| (name == "CMUX_CU_HEADLESS").then(|| OsString::from("0"));
    assert_eq!(process_env(own), [("CMUX_CU_HEADLESS".to_string(), OsString::from("0"))]);
}

/// A scratch dir with an executable `name` holding `script`.
fn script(name: &str, script: &str) -> (PathBuf, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!(
        "cmux-cu-starter-{}-{}",
        std::process::id(),
        uuid_like()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    (dir, path)
}

fn uuid_like() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
        ^ std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
            as u64
}

fn trusted_for_test(_: &Path) -> Result<(), String> {
    Ok(())
}

/// The variables of a Cloud VM's starter, as agent-tools.ts writes them, plus ones it must not pass.
const CLOUD_STARTER: &str = "#!/bin/sh\n\
    echo starting the display >&2\n\
    echo DISPLAY=:99\n\
    echo XAUTHORITY=/home/cmux/.cache/cmux-display/Xauthority-99\n\
    echo DBUS_SESSION_BUS_ADDRESS=unix:path=/run/cmux-agent-a11y-99/bus\n\
    echo CMUX_CU_HEADLESS=1\n\
    echo PATH=/opt/cmux/agent-tools/cua-refuse:/usr/bin:/bin\n\
    echo CMUX_CU_NO_NEW_PRIVS=1\n\
    echo LD_PRELOAD=/tmp/evil.so\n\
    echo not a variable\n";

fn get<'a>(env: &'a [(String, OsString)], key: &str) -> Option<&'a str> {
    env.iter().find(|(k, _)| k == key).and_then(|(_, v)| v.to_str())
}

#[test]
fn without_a_display_the_machines_desktop_starter_gives_the_worker_its_desktop() {
    let (dir, starter) = script("computer-use-desktop", CLOUD_STARTER);
    let own = |name: &str| match name {
        "PATH" => Some(OsString::from("/usr/bin:/bin")),
        "HOME" => Some(OsString::from("/home/cmux")),
        "XDG_RUNTIME_DIR" => Some(OsString::from("/nonexistent-run")),
        _ => None,
    };
    let env = worker_env(own, &starter, trusted_for_test).expect("the starter's desktop");
    assert_eq!(get(&env, "DISPLAY"), Some(":99"));
    assert_eq!(get(&env, "XAUTHORITY"), Some("/home/cmux/.cache/cmux-display/Xauthority-99"));
    assert_eq!(
        get(&env, "DBUS_SESSION_BUS_ADDRESS"),
        Some("unix:path=/run/cmux-agent-a11y-99/bus")
    );
    assert_eq!(get(&env, "CMUX_CU_HEADLESS"), Some("1"));
    assert_eq!(get(&env, NO_NEW_PRIVS_ENV), Some("1"));
    // The starter's PATH (the refusing tools first) replaces the daemon's, once.
    assert_eq!(get(&env, "PATH"), Some("/opt/cmux/agent-tools/cua-refuse:/usr/bin:/bin"));
    assert_eq!(env.iter().filter(|(k, _)| k == "PATH").count(), 1);
    assert_eq!(get(&env, "HOME"), Some("/home/cmux"));
    // Only the worker's variables: never a loader variable or a stray line.
    assert!(get(&env, "LD_PRELOAD").is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_daemon_with_a_display_never_runs_the_starter() {
    let (dir, starter) = script(
        "computer-use-desktop",
        &format!("#!/bin/sh\ntouch {}/ran\necho DISPLAY=:99\n", "$(dirname \"$0\")"),
    );
    let own = |name: &str| (name == "DISPLAY").then(|| OsString::from(":1"));
    let env = worker_env(own, &starter, trusted_for_test).expect("the daemon's own desktop");
    assert_eq!(get(&env, "DISPLAY"), Some(":1"));
    assert!(!dir.join("ran").exists(), "the starter ran although the daemon has a display");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn an_untrusted_starter_never_runs() {
    let (dir, starter) = script(
        "computer-use-desktop",
        "#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\necho DISPLAY=:99\n",
    );
    let refuse = |path: &Path| Err(format!("{} is not owned by root", path.display()));
    let error =
        worker_env(|_| None, &starter, refuse).expect_err("an untrusted starter gives no desktop");
    assert!(error.contains("not owned by root"), "{error}");
    assert!(!dir.join("ran").exists(), "an untrusted starter ran");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_starter_that_fails_says_why() {
    let (dir, starter) = script(
        "computer-use-desktop",
        "#!/bin/sh\necho 'cmux-agent-display@99.service did not start' >&2\nexit 3\n",
    );
    let error = worker_env(|_| None, &starter, trusted_for_test).expect_err("no desktop");
    assert!(error.contains("cmux-agent-display@99.service did not start"), "{error}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_starter_whose_display_keeps_its_output_open_still_returns() {
    // Xvfb started straight from the starter inherits its stdout and stderr.
    let (dir, starter) =
        script("computer-use-desktop", "#!/bin/sh\nsleep 30 &\necho DISPLAY=:99\necho up >&2\n");
    let started = std::time::Instant::now();
    let env = worker_env(|_| None, &starter, trusted_for_test).expect("desktop");
    assert_eq!(get(&env, "DISPLAY"), Some(":99"));
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_starter_that_prints_no_display_gives_no_desktop() {
    let (dir, starter) = script("computer-use-desktop", "#!/bin/sh\necho CMUX_CU_HEADLESS=1\n");
    let error = worker_env(|_| None, &starter, trusted_for_test).expect_err("no display");
    assert!(error.contains("no graphical session"), "{error}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn without_a_starter_or_a_display_there_is_no_desktop() {
    let missing = std::env::temp_dir().join(format!("cmux-cu-no-starter-{}", uuid_like()));
    let error = worker_env(|_| None, &missing, trusted_for_test).expect_err("no desktop");
    assert!(error.contains("no graphical session"), "{error}");
}

#[test]
fn the_real_trust_check_refuses_a_starter_the_user_owns() {
    // Tests never run as root here: the user's own file is exactly what an agent could plant.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let (dir, starter) = script(
        "computer-use-desktop",
        "#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\necho DISPLAY=:99\n",
    );
    let error = run_starter(&starter, super::super::config::trusted).expect_err("untrusted");
    assert!(error.contains("not owned by root"), "{error}");
    assert!(!dir.join("ran").exists());
    let _ = std::fs::remove_dir_all(dir);
}
