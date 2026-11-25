use super::*;

#[test]
fn a_refusal_reads_back_its_reason() {
    let refused = refusal_of("waiting for the person on that machine (consent_required)");
    assert_eq!(refused["reason"], "consent_required");
    assert_eq!(refused["error"], "waiting for the person on that machine");
    let odd = refusal_of("the machine closed the circuit before answering");
    assert_eq!(odd["reason"], "machine.unreachable");
}

#[test]
fn a_route_socket_is_short_and_beside_the_daemons() {
    let daemon = Path::new("/tmp/acpmux-501/acpmux.sock");
    let socket = socket_for(daemon, "a2V5LW9mLW1hY2hpbmUtYg==");
    assert_eq!(socket.parent(), daemon.parent());
    assert!(socket.file_name().unwrap().len() <= 32);
    // Never longer than the daemon's own: a socket path that fits for the daemon fits for
    // each route (sockaddr_un holds 107 bytes).
    // A daemon socket 106 bytes long, as a deep test home makes it (its route was 121).
    let deep = format!("/{}/acpmux.sock", "d".repeat(93));
    for daemon in ["/tmp/acpmux-501/acpmux.sock", deep.as_str(), "/run/a.sock"] {
        let daemon = Path::new(daemon);
        let route = socket_for(daemon, "a2V5LW9mLW1hY2hpbmUtYg==");
        assert!(
            route.as_os_str().len() <= daemon.as_os_str().len().max(16),
            "{} is longer than {}",
            route.display(),
            daemon.display()
        );
    }
    assert_ne!(socket, socket_for(daemon, "another-key"));
    let other = Path::new("/tmp/acpmux-501/other.sock");
    assert_ne!(socket_for(daemon, "k"), socket_for(other, "k"), "two daemons never share a route");
}
