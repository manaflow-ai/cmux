//! The machine's link facts from `cloud.machine.connect_info` (contract
//! 1.7): a READ, so it mints no link token. Attach uses it as the readiness
//! check before a carrier starts (host id, state, the services this install
//! may dial); files use its daemon capabilities as their gate
//! (crate::fs::link_files).

use crate::api::models::ConnectInfo;
use crate::api::{CloudError, ControlPlane, Request, codes, decode_answer};
use crate::ops::Server;
use serde_json::json;

/// `cloud.machine.connect_info {machine}`, checked: the host id is a plain
/// id (it becomes an argv value, so nothing that could read as a flag or
/// carry control characters). The op itself drops a machine the backend no
/// longer knows from the projection.
pub(crate) fn connect_info<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
) -> Result<ConnectInfo, CloudError> {
    const OP: &str = "cloud.machine.connect_info";
    let answer = server.handle(&Request::new(OP, json!({ "machine": machine })))?;
    let info: ConnectInfo = decode_answer(OP, answer)?;
    let plain = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
    let host = info.host.as_str();
    if host.is_empty() || host.len() > 128 || host.starts_with('-') || !host.chars().all(plain) {
        return Err(CloudError::new(codes::BAD_RESPONSE, "cmux Cloud answered a bad host id"));
    }
    Ok(info)
}
