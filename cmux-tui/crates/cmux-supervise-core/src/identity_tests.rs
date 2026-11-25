use super::*;

#[test]
fn this_process_is_alive_and_a_reused_pid_or_another_boot_is_dead() {
    let me = current().expect("this process reads");
    assert_eq!(check(&me), Liveness::Alive);
    let reused = Identity { start_time: me.start_time + 1, ..me.clone() };
    assert_eq!(check(&reused), Liveness::Dead, "a pid with another start time was reused");
    let rebooted = Identity {
        pid: me.pid,
        start_time: me.start_time,
        pgid: me.pgid,
        boot_id: "another-boot".into(),
    };
    assert_eq!(check(&rebooted), Liveness::Dead, "a record from another boot is dead");
    let gone = Identity { pid: i32::MAX as u32, ..me };
    assert_eq!(check(&gone), Liveness::Dead);
}

#[test]
fn an_exited_child_holds_its_pid_until_reaped_then_reads_gone() {
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let pid = child.id();
    let before = of(pid).expect("a child that just started reads");
    // Wait for the exit without reaping, so the pid stays a zombie.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: waitid on our own child with WNOWAIT leaves it unreaped.
    let rc = unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
    assert_eq!(rc, 0);
    assert_eq!(check(&before), Liveness::Alive, "a zombie still holds its pid");
    child.wait().unwrap();
    assert_eq!(read(pid), Read::Gone, "reaped, the pid is free");
    assert_eq!(check(&before), Liveness::Dead);
}
