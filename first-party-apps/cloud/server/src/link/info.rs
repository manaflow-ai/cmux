//! The machine's link facts from `cloud.machine.connect_info` (contract
//! 1.7): a READ, so it mints no link token. Attach uses it as the readiness
//! check before a carrier starts (host id, state, the services this install
//! may dial); files use its daemon capabilities as their gate
//! (crate::fs::link_files). Answers are cached ([`InfoCache`]).

use crate::api::models::ConnectInfo;
use crate::api::{CloudError, ControlPlane, Request, codes, decode_answer};
use crate::clock::{Clock, SystemClock};
use crate::ops::Server;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;

/// `cloud.machine.connect_info {machine}`, checked: the host id is a plain
/// id (it becomes an argv value, so nothing that could read as a flag or
/// carry control characters). The op itself drops a machine the backend no
/// longer knows from the projection.
pub(crate) fn connect_info<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
) -> Result<ConnectInfo, CloudError> {
    const OP: &str = "cloud.machine.connect_info";
    if let Some(info) = server.attach_mut().infos.get(machine) {
        return Ok(info);
    }
    let answer = server.handle(&Request::new(OP, json!({ "machine": machine })))?;
    let info: ConnectInfo = decode_answer(OP, answer)?;
    let plain = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
    let host = info.host.as_str();
    if host.is_empty() || host.len() > 128 || host.starts_with('-') || !host.chars().all(plain) {
        return Err(CloudError::new(codes::BAD_RESPONSE, "cmux Cloud answered a bad host id"));
    }
    server.attach_mut().infos.put(machine, info.clone());
    Ok(info)
}

/// How long a cached answer serves (contract 1.7 cache rule 1: at most
/// 300 s, or until a newer machine record).
pub const INFO_TTL_MS: u64 = 300_000;

/// `connect_info` answers by machine, each with the time it was read. Only
/// the loop thread touches it. Dropped on: expiry, a team event for the
/// machine (upsert or removed), a link down or revoked, and a start.
pub(crate) struct InfoCache {
    entries: BTreeMap<String, (u64, ConnectInfo)>,
    clock: Arc<dyn Clock>,
}

impl Default for InfoCache {
    fn default() -> Self {
        Self { entries: BTreeMap::new(), clock: Arc::new(SystemClock) }
    }
}

impl InfoCache {
    pub(crate) fn set_clock(&mut self, clock: Arc<dyn Clock>) {
        self.clock = clock;
    }

    pub(crate) fn get(&mut self, machine: &str) -> Option<ConnectInfo> {
        let now = self.clock.now_unix_ms();
        match self.entries.get(machine) {
            Some((at, info)) if now.saturating_sub(*at) < INFO_TTL_MS => Some(info.clone()),
            Some(_) => {
                self.entries.remove(machine);
                None
            }
            None => None,
        }
    }

    pub(crate) fn put(&mut self, machine: &str, info: ConnectInfo) {
        let now = self.clock.now_unix_ms();
        self.entries.insert(machine.to_owned(), (now, info));
    }

    /// Forgets every machine (a sign-out).
    pub(crate) fn clear(&mut self) {
        self.entries.clear();
    }

    pub(crate) fn forget(&mut self, machine: &str) {
        self.entries.remove(machine);
    }
}
