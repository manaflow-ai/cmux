use super::*;

/// The parent of a host is read whatever bytes the name of its program
/// has.
#[cfg(target_os = "linux")]
#[test]
fn the_parent_of_a_host_is_read_for_each_program_name() {
    let child = cmux_tui_platform::CutNameChild::start("host-scope").expect("child");
    assert_eq!(parent_pid(child.id()), Some(std::process::id()));
}

/// The move is complete only when the host's own cgroup names its scope:
/// the host forks the shell right after Launch, and a shell forked
/// before the move stays in the daemon unit (cx-6so.49 Cloud proof:
/// a `systemctl restart` then killed it after the 90 s stop timeout).
#[test]
fn a_host_counts_as_placed_only_when_its_cgroup_names_its_scope() {
    let placed = "0::/cmuxhosts.slice/cmux-terminal-host-4242.scope\n";
    assert!(cgroup_names_scope(placed, 4242));
    assert!(!cgroup_names_scope(placed, 424));
    assert!(!cgroup_names_scope("0::/system.slice/cmux-tui-daemon.service\n", 4242));
    assert_eq!(HOST_SLICE, "cmuxhosts.slice", "a dash in a slice name nests slices");
}

#[test]
fn scope_request_names_the_host_pid_and_the_host_slice() {
    let args = busctl_args(4242);
    let joined = args.join(" ");
    assert!(
        joined.contains("StartTransientUnit ssa(sv)a(sa(sv)) cmux-terminal-host-4242.scope fail 3"),
        "{joined}"
    );
    assert!(joined.contains("PIDs au 1 4242"), "{joined}");
    assert!(joined.contains(&format!("Slice s {HOST_SLICE}")), "{joined}");
    assert!(joined.ends_with("CollectMode s inactive-or-failed 0"), "{joined}");
}

#[cfg(target_os = "linux")]
#[test]
fn only_this_processs_child_is_recognized() {
    let mut child = Command::new("sleep").arg("5").spawn().unwrap();
    assert_eq!(parent_pid(child.id()), Some(std::process::id()));
    assert_ne!(parent_pid(1), Some(std::process::id()));
    let _ = child.kill();
    let _ = child.wait();
}
