//! A child started with `spawn_owned` (and every process it starts) dies
//! with its parent, however the parent ends, and with its handle.
//!
//! The parent is this test binary run again as `parent_helper`: it spawns a
//! shell that starts a long `sleep` (the grandchild) and itself sleeps,
//! prints both pids, and blocks. The test SIGKILLs the helper and watches
//! the two pids.

#![cfg(unix)]

/// One module name for every test here, so a fleet step can select them
/// (`--arg test --arg owned_child::`).
mod owned_child {
    use cmux_process::{Command, GRACE, Stdio};
    use std::io::{BufRead, BufReader};
    use std::time::{Duration, Instant};

    const MODE: &str = "CMUX_PROCESS_TEST_PARENT_MODE";
    /// How long a child may outlive its parent's death.
    const DEATH_LIMIT: Duration = Duration::from_secs(2);

    /// Not a test on its own: the parent process of the tests below.
    /// `owned`: `spawn_owned`; `plain`: a group of its own and nothing else
    /// (what the call sites did before).
    #[test]
    fn parent_helper() {
        let Ok(mode) = std::env::var(MODE) else { return };
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 300 & echo; echo owned-test-grandchild=$!; exec sleep 301"]);
        let child_pid = if mode == "owned" {
            let child = command.spawn_owned().unwrap();
            let pid = child.id();
            std::mem::forget(child);
            pid
        } else {
            let child = command.process_group(0).spawn().unwrap();
            child.id()
        };
        // On a line of its own: libtest prints the test's name before it.
        println!("\nowned-test-child={child_pid}");
        loop {
            std::thread::sleep(Duration::from_secs(300));
        }
    }

    /// Run `parent_helper` in `mode`; its pid, the child's and the grandchild's.
    fn start_parent(mode: &str) -> (std::process::Child, i32, i32) {
        let mut parent = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "owned_child::parent_helper", "--nocapture", "--test-threads=1"])
            .env(MODE, mode)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(parent.stdout.take().unwrap()).lines();
        let (mut child, mut grandchild) = (None, None);
        while child.is_none() || grandchild.is_none() {
            let line = lines.next().expect("the helper printed both pids").unwrap();
            if let Some(pid) = line.strip_prefix("owned-test-child=") {
                child = Some(pid.parse().unwrap());
            } else if let Some(pid) = line.strip_prefix("owned-test-grandchild=") {
                grandchild = Some(pid.parse().unwrap());
            }
        }
        (parent, child.unwrap(), grandchild.unwrap())
    }

    /// The process exists and is not a zombie (a zombie has ended; its new
    /// parent reaps it).
    fn alive(pid: i32) -> bool {
        // SAFETY: signal 0 only checks that the pid exists.
        if unsafe { libc::kill(pid, 0) } != 0 {
            return false;
        }
        #[cfg(target_os = "linux")]
        if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat"))
            && let Some(state) =
                stat.rsplit(')').next().and_then(|rest| rest.split_whitespace().next())
        {
            return state != "Z";
        }
        true
    }

    /// How long until every pid is gone, or `None` past `limit`. Checked
    /// every 10 ms: the test watches processes it does not own.
    fn gone_within(pids: &[i32], limit: Duration) -> Option<Duration> {
        let started = Instant::now();
        while started.elapsed() < limit {
            if pids.iter().all(|pid| !alive(*pid)) {
                return Some(started.elapsed());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }

    fn sigkill(parent: &mut std::process::Child) {
        parent.kill().unwrap();
        parent.wait().unwrap();
    }

    fn kill_pids(pids: &[i32]) {
        for pid in pids {
            // SAFETY: the test's own leftovers, checked alive just before.
            unsafe { libc::kill(*pid, libc::SIGKILL) };
        }
    }

    #[test]
    fn a_child_and_its_grandchild_die_when_the_parent_is_killed_right_after_the_spawn() {
        let (mut parent, child, grandchild) = start_parent("owned");
        sigkill(&mut parent);
        let took = gone_within(&[child, grandchild], DEATH_LIMIT);
        kill_pids(&[child, grandchild]);
        let took = took.expect("the child or grandchild outlived its parent by 2 s");
        eprintln!("owned, killed at once: gone in {took:?}");
    }

    #[test]
    fn a_child_and_its_grandchild_die_when_the_parent_is_killed_later() {
        let (mut parent, child, grandchild) = start_parent("owned");
        std::thread::sleep(Duration::from_millis(500));
        assert!(alive(child) && alive(grandchild), "the child runs while its parent does");
        sigkill(&mut parent);
        let took = gone_within(&[child, grandchild], DEATH_LIMIT);
        kill_pids(&[child, grandchild]);
        let took = took.expect("the child or grandchild outlived its parent by 2 s");
        eprintln!("owned, killed after 500 ms: gone in {took:?}");
    }

    /// The fixture sees the bug: a child in a plain process group lives on
    /// after its parent's SIGKILL (the behavior before `spawn_owned`).
    #[test]
    fn a_plain_group_child_outlives_its_killed_parent() {
        let (mut parent, child, grandchild) = start_parent("plain");
        sigkill(&mut parent);
        let took = gone_within(&[child, grandchild], DEATH_LIMIT);
        let survived = alive(child) && alive(grandchild);
        kill_pids(&[child, grandchild]);
        assert!(
            took.is_none() && survived,
            "a plain child died with its parent: the fixture is wrong"
        );
        eprintln!("plain group: child and grandchild still alive 2 s after the parent's SIGKILL");
    }

    /// Dropping the handle ends a child that ignores SIGTERM, and its
    /// grandchild, within the grace, and reaps the child (no zombie).
    #[test]
    fn drop_kills_the_group_and_reaps_within_the_grace() {
        let mut child = Command::new("/bin/sh")
            .args(["-c", "trap '' TERM; sleep 300 & echo $!; while :; do sleep 1; done"])
            .stdout(Stdio::piped())
            .spawn_owned()
            .unwrap();
        let pid = child.id() as i32;
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let grandchild: i32 = line.trim().parse().unwrap();
        assert_ne!(child.group_id(), pid, "the watchdog leads the group");
        let started = Instant::now();
        drop(child);
        let took = started.elapsed();
        assert!(took < GRACE + Duration::from_secs(1), "the drop took {took:?}");
        // Reaped: this process has no such child any more.
        // SAFETY: waitpid on a pid this test spawned.
        let reaped = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
        assert_eq!(reaped, -1, "the child was not reaped");
        let gone = gone_within(&[pid, grandchild], Duration::from_secs(1));
        kill_pids(&[grandchild]);
        assert!(gone.is_some(), "the grandchild outlived the drop");
        eprintln!("drop of a child ignoring SIGTERM: {took:?}");
    }

    /// A child that ends on SIGTERM is not held for the grace.
    #[test]
    fn drop_of_a_child_that_ends_on_sigterm_is_quick() {
        let child = Command::new("/bin/sleep").arg("300").spawn_owned().unwrap();
        let started = Instant::now();
        drop(child);
        let took = started.elapsed();
        assert!(took < Duration::from_millis(500), "the drop took {took:?}");
        eprintln!("drop of a child ending on SIGTERM: {took:?}");
    }
}
