use super::*;

#[test]
fn the_quiet_socket_is_the_main_one_s_sibling_and_skipped_when_it_does_not_fit() {
    assert_eq!(
        quiet_path(Path::new("/tmp/a/carrier.sock")),
        Some(PathBuf::from("/tmp/a/carrier.sock.quiet"))
    );
    // A main path that just fits leaves no room for the suffix.
    let long = format!("/{}", "x".repeat(cmux_unix_socket::MAX_PATH_BYTES - 1));
    assert!(cmux_unix_socket::fits(Path::new(&long)));
    assert_eq!(quiet_path(Path::new(&long)), None);
}

#[test]
fn a_paused_or_pausing_machine_is_asleep_and_nothing_else_is() {
    for status in ["paused", "pausing"] {
        assert!(asleep(status), "{status}");
    }
    for status in ["running", "starting", "provisioning", "deleting", "failed", ""] {
        assert!(!asleep(status), "{status}");
    }
}

#[test]
fn an_asleep_read_stands_for_the_recheck_time_and_no_longer() {
    let mark = Asleep::new(RECHECK);
    let start = Instant::now();
    assert_eq!(mark.look(start), Look::Read, "nothing read yet: read");
    assert_eq!(mark.saw(start, Ok("paused")), Some(Seen::Asleep));
    assert_eq!(mark.look(start), Look::Cached(Seen::Asleep));
    assert_eq!(
        mark.look(start + RECHECK - Duration::from_millis(1)),
        Look::Cached(Seen::Asleep),
        "no second read inside the recheck time"
    );
    assert_eq!(mark.look(start + RECHECK), Look::Read, "the recheck time is up: read again");
    assert_eq!(RECHECK, Duration::from_secs(30));
}

#[test]
fn a_running_read_or_a_stream_clears_the_mark_and_a_failed_read_closes_too() {
    let mark = Asleep::new(RECHECK);
    let start = Instant::now();
    assert_eq!(mark.saw(start, Err(())), Some(Seen::Unread));
    assert_eq!(mark.look(start), Look::Cached(Seen::Unread), "a failed read never dials");
    assert_eq!(mark.saw(start, Ok("running")), None, "running: dial");
    assert_eq!(mark.look(start), Look::Read);
    assert_eq!(mark.saw(start, Ok("paused")), Some(Seen::Asleep));
    mark.clear();
    assert_eq!(mark.look(start), Look::Read, "a session cleared the mark");
}

#[test]
fn a_refusal_writes_one_quiet_line_and_no_route_line() {
    let line = refusal_line("vm_x", Seen::Asleep, true, Duration::from_millis(3));
    assert_eq!(line, "carrier.quiet machine=vm_x outcome=asleep seen=cached ms=3\n");
    assert!(!line.contains("cloud.connect"));
    assert_eq!(
        skipped_line("vm_x", "too_long"),
        "carrier.quiet machine=vm_x socket=skipped reason=too_long\n"
    );
}
