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
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

/// Adds `credential` to `request` when the rules above allow it; true when
/// it did (the caller re-encodes the request then).
pub(super) fn attach(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    let own_socket = std::env::var_os("CMUX_TUI_SOCKET").map(PathBuf::from);
    let Some(credential) = for_socket(crate::startup_env::launch_credential(), own_socket, socket)
    else {
        return false;
    };
    if !advertises(reader) {
        return false;
    }
    request["credential"] = Value::String(credential);
    true
}

fn for_socket(credential: Option<String>, own: Option<PathBuf>, socket: &Path) -> Option<String> {
    let credential = credential.filter(|credential| !credential.is_empty())?;
    let own = own.filter(|path| !path.as_os_str().is_empty())?;
    let same = own == socket
        || matches!(
            (std::fs::canonicalize(&own), std::fs::canonicalize(socket)),
            (Ok(own), Ok(target)) if own == target
        );
    same.then_some(credential)
}

/// One `identify` on the connection; false on any doubt (the request then
/// goes without a credential, which is the pre-P8 behavior).
fn advertises(reader: &mut BufReader<Box<dyn transport::Stream>>) -> bool {
    let Ok(id) = super::wire::random_request_id() else { return false };
    let request = json!({"id": id, "cmd": "identify"});
    let Ok(encoded) = serde_json::to_vec(&request) else { return false };
    let sent = reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().write_all(b"\n"))
        .and_then(|()| reader.get_mut().flush());
    if sent.is_err() {
        return false;
    }
    let Ok(Some(response)) = super::wire::read_envelope(reader, false) else { return false };
    if response.get("id").and_then(Value::as_str) != Some(id.as_str())
        || response.get("ok").and_then(Value::as_bool) != Some(true)
    {
        return false;
    }
    crate::session::parse_identity_capabilities(response.get("data").unwrap_or(&Value::Null))
        .is_ok_and(|capabilities| capabilities.contains(LAUNCH_CREDENTIAL_CAPABILITY))
}
