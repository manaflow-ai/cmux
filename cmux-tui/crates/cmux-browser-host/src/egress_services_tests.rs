//! The cmux service check reads the kernel's view of who listens on a
//! loopback port.

use super::*;

#[test]
fn cmux_executables_are_services() {
    for name in
        ["cmux", "acpmux", "chatmux-relay", "cmux-browser-host", "cmux-tui (deleted)", "chrome"]
    {
        assert!(is_service_name(name), "{name}");
    }
    for name in ["node", "bun", "python3", "postgres", "cmux_browser_host-0123abcd"] {
        assert!(!is_service_name(name), "{name}");
    }
}

#[test]
fn listening_rows_are_read_by_port_and_state() {
    let table = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4242 1 0 100 0 0 10 0\n\
   1: 0100007F:0BB8 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 4343 1 0 20 4 30 10 -1\n\
   2: 00000000:0BB9 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4444 1 0 100 0 0 10 0\n";
    assert_eq!(parse_listening(table, 3000), vec![4242], "LISTEN only, not the connection");
    assert_eq!(parse_listening(table, 3001), vec![4444]);
    assert!(parse_listening(table, 3002).is_empty());
}

/// A real listener held by a process whose executable is named `cmux-*`
/// is refused; this test process's own listener (not a cmux name) and an
/// unused port are allowed.
#[cfg(target_os = "linux")]
#[test]
fn a_port_held_by_a_cmux_executable_is_refused() {
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    let own = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let own_port = own.local_addr().unwrap().port();
    let check = system_check();
    let at = |port: u16| SocketAddr::from(([127, 0, 0, 1], port));
    assert_eq!(check(at(own_port)), None, "a dev server of a non-cmux process");
    // A copy of a listener program named like a cmux service.
    let dir = std::env::temp_dir().join(format!("cmux-egress-svc-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let probe = dir.join("cmux-probe");
    std::fs::copy("/usr/bin/python3", &probe).unwrap();
    let mut child = Command::new(&probe)
        .args(["-c", "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1], flush=True); sys.stdin.read()"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let port: u16 = line.trim().parse().unwrap();
    let refused = check(at(port));
    drop(child.stdin.take());
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    let refused = refused.expect("the cmux service port is refused");
    assert!(refused.contains("cmux-probe"), "{refused}");
    drop(own);
    let unused = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let unused_port = unused.local_addr().unwrap().port();
    drop(unused);
    assert_eq!(check(at(unused_port)), None, "nobody listens");
}
