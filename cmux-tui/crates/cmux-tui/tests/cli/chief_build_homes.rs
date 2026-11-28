//! One Chief per build identity (plans/cmux-next/home-state-ownership.md
//! section 0): the `cmux chief` CLI of one build never acts on another
//! build's Chief home. The stand-in brain holds the home's host lock as the
//! real brain does; `cmux chief shutdown` is the one documented stop.

use super::*;

/// A process that holds `lock` as a brain does (`pid`, generation, `flock`)
/// until it gets a signal.
fn stand_in_brain(lock: &std::path::Path) -> Child {
    fs::create_dir_all(lock.parent().unwrap()).unwrap();
    let brain = Command::new("python3")
        .arg("-c")
        .arg(
            "import fcntl, os, sys, time\n\
             f = open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX)\n\
             f.write(f'{os.getpid()}\\n1\\nflock\\n'); f.flush()\n\
             open(sys.argv[1] + '.ready', 'w').close()\n\
             time.sleep(600)\n",
        )
        .arg(lock)
        .spawn()
        .unwrap();
    let ready = lock.with_extension("lock.ready");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "the stand-in brain never took the lock");
        std::thread::sleep(Duration::from_millis(20));
    }
    brain
}

/// `cmux chief shutdown` as the CLI inside the app with `bundle_id`, for a
/// person whose home directory is `user_home`.
fn shutdown_as(bundle_id: &str, user_home: &std::path::Path) -> Output {
    let mut command = Command::new(bin());
    command.args(["chief", "shutdown"]).env("LC_ALL", "C").env("HOME", user_home);
    for key in [
        "CMUX_TUI_SOCKET",
        "CMUX_SOCKET_PATH",
        "CMUX_TAG",
        "CMUX_CHIEF_HOME",
        "CMUX_NEXT_CHIEF_HOME",
        "CMUX_NEXT_MUX_HOME",
        "CMUX_NEXT_CHIEF_ROOT",
        "CMUX_NEXT_CHIEF_ACCOUNT",
        "CMUX_NEXT_CHIEF_BUILD_ID",
        "CMUX_NEXT_CHIEF_ISOLATED",
        "CMUX_NEXT_NO_ACTIVATE",
        "CMUX_NEXT_SHOWCASE",
        "CMUX_NEXT_TEST_WINDOW_FRAME",
        "CMUX_NEXT_TEST_WINDOW_SCREEN",
    ] {
        command.env_remove(key);
    }
    command.env("CMUX_BUNDLE_ID", bundle_id).output().unwrap()
}

/// hq-6d, 2026-10-14: only NIGHTLY (`com.cmuxterm.app.nightly`) keeps the
/// shared `~/.cmux/chief/default`; cmux NEXT's NIGHTLY identity
/// (`com.cmuxterm.app.nightly.cmux-next`) and every other bundle have a home
/// of their own, so two NIGHTLY identities that run at the same time never
/// share one Chief. The other identity's shutdown leaves NIGHTLY's brain
/// running; NIGHTLY's own shutdown stops it.
#[test]
fn only_nightly_stops_the_brain_on_the_default_chief_home() {
    let user_home = unique_temp_dir("chief-build-homes");
    let lock = user_home.join(".cmux/chief/default/state/host.lock");
    let mut brain = stand_in_brain(&lock);
    let stop = |brain: &mut Child| {
        let _ = brain.kill();
        let _ = brain.wait();
        let _ = fs::remove_dir_all(&user_home);
    };
    for other in ["com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.rc", "com.cmuxterm.app"] {
        let output = shutdown_as(other, &user_home);
        let still_running = brain.try_wait().unwrap().is_none();
        if !still_running || !output.status.success() {
            stop(&mut brain);
        }
        assert_success(&output);
        assert!(still_running, "the CLI of {other} stopped NIGHTLY's brain on the default home");
    }
    let output = shutdown_as("com.cmuxterm.app.nightly", &user_home);
    // The CLI returns once the lock is free; the brain has ended by then.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut status = brain.try_wait().unwrap();
    while status.is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        status = brain.try_wait().unwrap();
    }
    stop(&mut brain);
    assert_success(&output);
    let status = status.expect("NIGHTLY's own shutdown ends its brain");
    assert!(!status.success(), "the brain ended by the signal: {status:?}");
}
