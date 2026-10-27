//! A launch credential for each agent session (plans/cmux-next/identity.md
//! section 2; bead cx-55d27): the cmux session daemon that `CMUX_TUI_SOCKET`
//! names in acpmux's own environment mints one for the session
//! (`credential.mint {acp_session}`), and the agent gets it as
//! `CMUX_LAUNCH_CREDENTIAL` next to that same `CMUX_TUI_SOCKET`. Its `cmux`
//! calls (an agent message, for one) then reach the daemon as that ACP
//! session, a verified sender.
//!
//! A credential never comes from anywhere else: whatever acpmux inherited or
//! a preset sets is removed first, because it names some other terminal or
//! session. Minting never holds up a launch: without the variable, a daemon
//! on the socket, or an answer within [`MINT_TIMEOUT`], the agent starts
//! without one and its messages go out unverified.

use crate::config::LAUNCH_CREDENTIAL_ENV;

/// The variable naming the cmux session daemon socket.
pub const SESSION_SOCKET_ENV: &str = "CMUX_TUI_SOCKET";

/// How long a launch waits for the daemon's credential.
#[cfg(unix)]
const MINT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
/// The longest reply line read from the daemon.
#[cfg(unix)]
const MAX_REPLY_BYTES: u64 = 64 * 1024;

/// Sets the agent's launch credential on `cmd`: one minted for `session`, or
/// none (removed) without a session or a daemon that mints one. No agent acts
/// as the terminal that started acpmux, not even through a preset, nor as the
/// Chief whose host started it (`config::CHIEF_CREDENTIAL_ENV`).
pub(crate) fn apply(cmd: &mut tokio::process::Command, session: Option<&str>) {
    cmd.env_remove(LAUNCH_CREDENTIAL_ENV);
    for key in crate::config::CHIEF_CREDENTIAL_ENV {
        cmd.env_remove(key);
    }
    let Some(session) = session else { return };
    let Some(socket) = std::env::var_os(SESSION_SOCKET_ENV).filter(|s| !s.is_empty()) else {
        return;
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let path = std::path::Path::new(&socket);
    let minted = if multi_thread {
        cmux_hang_watch::tokio::block_in_place(|| mint(path, session))
    } else {
        mint(path, session)
    };
    if let Some(credential) = minted {
        cmd.env(LAUNCH_CREDENTIAL_ENV, credential).env(SESSION_SOCKET_ENV, &socket);
    }
}

/// One `credential.mint` on a new connection to `socket`, as the local user
/// (acpmux removed its own credential at start, `main.rs`).
#[cfg(unix)]
fn mint(socket: &std::path::Path, session: &str) -> Option<String> {
    use std::io::{BufRead, BufReader, Read, Write};
    let stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(MINT_TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(MINT_TIMEOUT)).ok()?;
    let id = format!("acpmux-mint-{}", uuid::Uuid::now_v7().simple());
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": "credential.mint",
        "params": {"machine": "current", "session": "current", "acp_session": session},
    });
    let mut line = serde_json::to_vec(&request).ok()?;
    line.push(b'\n');
    (&stream).write_all(&line).ok()?;
    let deadline = std::time::Instant::now() + MINT_TIMEOUT;
    let mut reader = BufReader::new((&stream).take(MAX_REPLY_BYTES));
    while std::time::Instant::now() < deadline {
        let mut reply = String::new();
        if reader.read_line(&mut reply).ok()? == 0 {
            return None;
        }
        let Ok(reply) = serde_json::from_str::<serde_json::Value>(&reply) else { continue };
        if reply.get("id").and_then(serde_json::Value::as_str) != Some(id.as_str()) {
            continue;
        }
        if reply.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
            return None;
        }
        let credential = reply.pointer("/result/credential")?.as_str()?;
        return (!credential.is_empty()).then(|| credential.to_owned());
    }
    None
}

#[cfg(not(unix))]
fn mint(_socket: &std::path::Path, _session: &str) -> Option<String> {
    None
}
