use super::*;

#[test]
fn busy_port_message_names_the_address_the_lookup_and_the_flag() {
    let address: SocketAddr = "127.0.0.1:47911".parse().unwrap();
    let busy = io::Error::from(io::ErrorKind::AddrInUse);
    let lookup = if cfg!(any(target_os = "linux", target_os = "android")) {
        "ss -ltnp 'sport = :47911'"
    } else if cfg!(windows) {
        "Get-NetTCPConnection -State Listen -LocalPort 47911 | Select-Object OwningProcess"
    } else {
        "netstat -anv -p tcp | grep LISTEN | grep '[.]47911 '"
    };
    assert_eq!(
        bind_failure_message(address, &busy),
        format!(
            "could not bind WebSocket on 127.0.0.1:47911: port 47911 is already in use. \
                 See who holds it with `{lookup}`, stop that listener, or pick a free port \
                 with --remote-ws 127.0.0.1:PORT"
        )
    );
    let v6: SocketAddr = "[::1]:47911".parse().unwrap();
    assert!(bind_failure_message(v6, &busy).ends_with("--remote-ws [::1]:PORT"));
    let scoped: SocketAddr = "[fe80::1%3]:47911".parse().unwrap();
    assert!(bind_failure_message(scoped, &busy).ends_with("--remote-ws [fe80::1%3]:PORT"));
    let denied = bind_failure_message(address, &io::Error::from(io::ErrorKind::PermissionDenied));
    assert!(denied.starts_with("could not bind WebSocket on 127.0.0.1:47911: "), "{denied}");
    assert!(!denied.contains("--remote-ws"), "{denied}");
}

/// A real second bind of a held port gets the busy-port message.
#[test]
fn a_real_busy_port_gets_the_busy_port_message() {
    let held = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = held.local_addr().unwrap();
    let error = std::net::TcpListener::bind(address).unwrap_err();
    let message = bind_failure_message(address, &error);
    assert!(message.contains("is already in use"), "{message}");
    assert!(message.contains(&format!(":{}", address.port())), "{message}");
}
