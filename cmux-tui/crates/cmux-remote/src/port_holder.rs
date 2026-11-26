//! Plain words for a failed listener bind: the address, how to see who
//! holds it, and the flag that picks another. cmux never scans processes
//! (plans/cmux-next/pty-holder.md), so it names the command, not the holder.

use std::io;
use std::net::SocketAddr;

/// The message for a failed WebSocket bind of `address`.
pub fn bind_failure_message(address: SocketAddr, error: &io::Error) -> String {
    if error.kind() != io::ErrorKind::AddrInUse {
        return format!("could not bind WebSocket on {address}: {error}");
    }
    let port = address.port();
    let host = match address {
        SocketAddr::V4(addr) => addr.ip().to_string(),
        SocketAddr::V6(addr) if addr.scope_id() != 0 => {
            format!("[{}%{}]", addr.ip(), addr.scope_id())
        }
        SocketAddr::V6(addr) => format!("[{}]", addr.ip()),
    };
    format!(
        "could not bind WebSocket on {address}: port {port} is already in use. \
         See who holds it with `{}`, stop that listener, or pick a free port \
         with --remote-ws {host}:PORT",
        holder_command(port),
    )
}

fn holder_command(port: u16) -> String {
    if cfg!(any(target_os = "linux", target_os = "android")) {
        format!("ss -ltnp 'sport = :{port}'")
    } else if cfg!(windows) {
        format!(
            "Get-NetTCPConnection -State Listen -LocalPort {port} | Select-Object OwningProcess"
        )
    } else {
        format!("netstat -anv -p tcp | grep LISTEN | grep '[.]{port} '")
    }
}

#[cfg(test)]
mod tests {
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
        let denied =
            bind_failure_message(address, &io::Error::from(io::ErrorKind::PermissionDenied));
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
}
