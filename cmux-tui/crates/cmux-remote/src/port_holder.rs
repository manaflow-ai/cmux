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
#[path = "port_holder_tests.rs"]
mod tests;
