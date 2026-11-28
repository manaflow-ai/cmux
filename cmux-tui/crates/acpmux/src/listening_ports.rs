//! This machine's TCP LISTEN ports, loopback included: a dev server the person just started
//! shows here, for `machine_info` and for an own machine asking over the machine-call service
//! ([`crate::machine_call_service::PORTS_LIST`]). Port numbers only, distinct and sorted; never
//! a command line or a process.
//!
//! - Linux: `/proc/net/tcp` and `/proc/net/tcp6` (`cmux_host::cloud::workload::parse_listeners`).
//! - macOS: the `net.inet.tcp.pcblist64` table (`cmux-tcp-listeners`), which a sandboxed process
//!   may see filtered to its own user's sockets; that is the user whose dev servers matter.
//! - Elsewhere, or a table that does not read: `None` (unknown, not "nothing listens").

use serde_json::{Value, json};

use crate::rpc::RpcError;

/// The listening ports here, or `None` when they cannot be read.
pub fn here() -> Option<Vec<u16>> {
    #[cfg(target_os = "linux")]
    {
        let read = |table: &str| std::fs::read_to_string(format!("/proc/{table}"));
        let mut tables = vec![read("net/tcp").ok()?];
        match read("net/tcp6") {
            Ok(text) => tables.push(text),
            // A kernel without IPv6: nothing listens there.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
        from_proc_tables(&tables)
    }
    #[cfg(target_os = "macos")]
    {
        cmux_tcp_listeners::system_listeners().map(|table| cmux_tcp_listeners::ports(&table))
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
    }
}

/// The distinct sorted ports of `/proc/net/tcp`-format tables; `None` when one does not parse.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn from_proc_tables(tables: &[String]) -> Option<Vec<u16>> {
    let mut ports = Vec::new();
    for text in tables {
        ports
            .extend(cmux_host::cloud::workload::parse_listeners(text)?.into_iter().map(|(p, _)| p));
    }
    ports.sort_unstable();
    ports.dedup();
    Some(ports)
}

/// The `ports_list` answer: `{"ports":[{"port":N}]}`, or a refusal when the table is unreadable.
pub fn answer(ports: Option<Vec<u16>>) -> Result<Value, RpcError> {
    let Some(ports) = ports else {
        return Err(RpcError::internal("this machine's listening-port table could not be read")
            .with_data(json!({"reason": "ports.unreadable"})));
    };
    Ok(json!({"ports": ports.into_iter().map(|port| json!({"port": port})).collect::<Vec<_>>()}))
}

/// The `ports_list` method here, read off the async runtime.
pub async fn run_here() -> Result<Value, RpcError> {
    let ports = tokio::task::spawn_blocking(here)
        .await
        .map_err(|error| RpcError::internal(format!("the port read stopped: {error}")))?;
    answer(ports)
}

#[cfg(test)]
#[path = "listening_ports_tests.rs"]
mod tests;
