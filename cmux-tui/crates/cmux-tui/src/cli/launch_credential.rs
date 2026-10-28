//! The CLI and `cmux mcp` send the caller's launch credential
//! (plans/cmux-next/identity.md section 3) so the daemon records the caller's
//! terminal or ACP session as the actor. The credential goes only to the
//! session its terminal belongs to (`CMUX_TUI_SOCKET` names that socket) and
//! only to a daemon that advertises `launch-credential-v1`: an older daemon
//! refuses the unknown envelope member, so it gets the request without one
//! (as the plain local user) instead of a dead end.

use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};

use cmux_tui_core::launch_credential::LAUNCH_CREDENTIAL_CAPABILITY;

use super::capability_cache::CapabilityCache;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

/// Adds `credential` to `request` when the rules above allow it; true when
/// it did (the caller re-encodes the request then).
pub(super) fn attach(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    let Some(credential) = for_connection(reader, socket) else { return false };
    request["credential"] = Value::String(credential);
    true
}

/// The credential this connection's requests may carry, by the rules above.
pub(super) fn for_connection(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
) -> Option<String> {
    let own_socket = super::caller_env::var_os("CMUX_TUI_SOCKET").map(PathBuf::from);
    let credential = for_socket(super::caller_env::launch_credential(), own_socket, socket)?;
    advertises(reader, socket, LAUNCH_CREDENTIAL_CAPABILITY).then_some(credential)
}

fn for_socket(credential: Option<String>, own: Option<PathBuf>, socket: &Path) -> Option<String> {
    let credential = credential.filter(|credential| !credential.is_empty())?;
    let own = own.filter(|path| !path.as_os_str().is_empty())?;
    let same = own == socket
        || matches!(
            (cmux_blocking::fs::canonicalize(&own), cmux_blocking::fs::canonicalize(socket)),
            (Ok(own), Ok(target)) if own == target
        );
    same.then_some(credential)
}

/// Whether the daemon on this connection serves `capability`, a capability
/// a daemon keeps for its whole life: remembered per daemon process
/// ([`CapabilityCache`]), else one `identify` on the connection. False on
/// any doubt (the request then goes without a credential, which is the
/// pre-P8 behavior).
pub(super) fn advertises(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    capability: &str,
) -> bool {
    let cache = CapabilityCache::for_user();
    let peer = reader.get_ref().peer_process_key();
    if let Some(peer) = peer.as_deref()
        && let Some(capabilities) = cache.load(socket, peer)
    {
        return capabilities.iter().any(|known| known == capability);
    }
    let Some(capabilities) = identify_capabilities(reader) else { return false };
    if let Some(peer) = peer.as_deref() {
        cache.store(socket, peer, &capabilities);
    }
    capabilities.iter().any(|known| known == capability)
}

/// The capabilities one `identify` on the connection reports.
fn identify_capabilities(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
) -> Option<Vec<String>> {
    let Ok(id) = super::wire::random_request_id() else { return None };
    let request = json!({"id": id, "cmd": "identify"});
    let Ok(encoded) = serde_json::to_vec(&request) else { return None };
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().write_all(b"\n"))
        .and_then(|()| reader.get_mut().flush())
        .ok()?;
    let Ok(Some(response)) = super::wire::read_envelope(reader, false) else { return None };
    if response.get("id").and_then(Value::as_str) != Some(id.as_str())
        || response.get("ok").and_then(Value::as_bool) != Some(true)
    {
        return None;
    }
    crate::session::parse_identity_capabilities(response.get("data").unwrap_or(&Value::Null))
        .ok()
        .map(|capabilities| capabilities.into_iter().collect())
}
