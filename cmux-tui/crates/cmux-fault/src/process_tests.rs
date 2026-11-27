use super::Recorded;
use crate::trace::Trace;

#[test]
fn freeze_resume_and_kill_a_child_by_its_pid() {
    let trace = Trace::new();
    let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
    let sleeper = Recorded::child(&child, "sleep", &trace);
    assert!(sleeper.alive());
    assert!(sleeper.freeze() && sleeper.resume());
    assert!(sleeper.kill());
    let status = child.wait().unwrap();
    use std::os::unix::process::ExitStatusExt;
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    assert!(trace.lines().iter().any(|line| line.contains("fault kill sleep")));
}
