use super::*;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

/// A shell leading its own process group, killed with its group and reaped
/// when the test ends.
struct Group(Child);

impl Group {
    fn start(script: &str) -> Self {
        let child = Command::new("/bin/sh")
            .args(["-c", script])
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("start sh");
        Self(child)
    }

    fn pid(&self) -> u32 {
        self.0.id()
    }

    /// The next pid the shell prints.
    fn printed_pid(&mut self) -> u32 {
        let mut line = String::new();
        BufReader::new(self.0.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        line.trim().parse().expect("a pid")
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        // SAFETY: the group this test started.
        unsafe { libc::killpg(self.0.id() as libc::pid_t, libc::SIGKILL) };
        let _ = self.0.wait();
    }
}

/// Whether this test process runs best-effort already (cargo under
/// `nice -n 10`): a child it starts does too.
fn inherited() -> bool {
    is_background(std::process::id()).expect("read this process")
}

#[test]
fn process_priority_reads_back_background_after_best_effort_and_not_after_user_visible() {
    let group = Group::start("exec sleep 30");
    let pid = group.pid();
    let baseline = inherited();
    assert_eq!(is_background(pid), Ok(baseline), "a child starts at its parent's priority");
    if !reversible() {
        // Linux without root or RLIMIT_NICE: nothing is lowered that could not come back.
        assert_eq!(set_group(pid, ProcessPriority::BestEffort), Err(PriorityError::NotReversible));
        assert_eq!(is_background(pid), Ok(baseline), "unchanged");
        return;
    }
    // macOS: another process cannot take off a policy the child inherited.
    if cfg!(target_os = "macos") && baseline {
        return;
    }
    set_group(pid, ProcessPriority::BestEffort).unwrap();
    assert_eq!(is_background(pid), Ok(true));
    set_group(pid, ProcessPriority::UserVisible).unwrap();
    assert_eq!(is_background(pid), Ok(false));
}

#[test]
fn process_priority_a_child_forked_while_best_effort_inherits_it() {
    if !reversible() {
        return;
    }
    let mut group = Group::start("read go; sleep 30 & echo $!; wait");
    let leader = group.pid();
    set_group(leader, ProcessPriority::BestEffort).unwrap();
    writeln!(group.0.stdin.as_mut().unwrap(), "go").unwrap();
    let child = group.printed_pid();
    assert_eq!(is_background(child), Ok(true));
    set_group(leader, ProcessPriority::UserVisible).unwrap();
    assert_eq!(is_background(leader), Ok(false));
    // Linux changes the whole group; macOS only the leader (no group form).
    #[cfg(target_os = "linux")]
    assert_eq!(is_background(child), Ok(false));
}

#[test]
#[cfg(target_os = "linux")]
fn process_priority_reaches_every_process_of_the_group_on_linux() {
    if !reversible() {
        return;
    }
    let mut group = Group::start("sleep 30 & echo $!; wait");
    let member = group.printed_pid();
    set_group(group.pid(), ProcessPriority::BestEffort).unwrap();
    assert_eq!(is_background(member), Ok(true));
    set_group(group.pid(), ProcessPriority::UserVisible).unwrap();
    assert_eq!(is_background(member), Ok(false));
}

#[test]
fn process_priority_of_a_group_that_ended_is_gone() {
    if !reversible() {
        return;
    }
    let mut child =
        Command::new("/bin/sh").args(["-c", "exit 0"]).process_group(0).spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    let error = set_group(pid, ProcessPriority::BestEffort).unwrap_err();
    assert!(error.is_gone(), "{error}");
    assert!(set_group(0, ProcessPriority::BestEffort).unwrap_err().is_gone(), "0 is no group");
}
