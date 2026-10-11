//! The install's port block (server.md 8.2) with a bind probe.
//!
//! `cmux_server_core::ports::allocate` picks the block from a set of ports
//! known to be in use. This probes only the block core proposes: a port
//! that fails to bind on `127.0.0.1` is added to the set and core is asked
//! again, until a whole block binds. The chosen port is persisted by the
//! caller and never moves after that.

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, TcpListener};

use cmux_server_core::ports::{self, Allocation, PortError};

use crate::error::{Error, Result};

fn free(port: u16) -> bool {
    TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok()
}

/// Allocates with `probe(port) == true` meaning free.
pub fn allocate_with(
    install_id: &str,
    persisted: Option<u16>,
    probe: impl Fn(u16) -> bool,
) -> Result<Allocation> {
    let mut in_use = BTreeSet::new();
    loop {
        let allocation = ports::allocate(install_id, &in_use, persisted).map_err(|e| match e {
            PortError::InvalidPersisted(p) => {
                Error::rejected(format!("postgres.port {p} in server.json is not usable"))
            }
            PortError::Exhausted => Error::unreachable("no free 32-port block in 15432..25432"),
        })?;
        if persisted.is_some() {
            return Ok(allocation);
        }
        let busy: Vec<u16> = allocation.block.ports().filter(|p| !probe(*p)).collect();
        if busy.is_empty() {
            return Ok(allocation);
        }
        in_use.extend(busy);
    }
}

/// Allocates against the real loopback interface.
pub fn allocate(install_id: &str, persisted: Option<u16>) -> Result<Allocation> {
    allocate_with(install_id, persisted, free)
}
