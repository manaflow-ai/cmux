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
        tokio::task::block_in_place(|| mint(path, session))
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
    let mut link = DaemonLink::connect(socket, MINT_TIMEOUT)?;
    link.mint(session)
}

#[cfg(not(unix))]
fn mint(_socket: &std::path::Path, _session: &str) -> Option<String> {
    None
}

/// One connection to the cmux session daemon (`cmux.protocol/2`, one JSON line each way) as
/// the local user: a launch credential's mint, and the app pane's reply in place
/// (`server/app_reply.rs`).
#[cfg(unix)]
pub(crate) struct DaemonLink {
    reader: std::io::BufReader<std::os::unix::net::UnixStream>,
    timeout: std::time::Duration,
}

#[cfg(unix)]
impl DaemonLink {
    /// A connection to `socket` whose every request waits at most `timeout`.
    pub(crate) fn connect(socket: &std::path::Path, timeout: std::time::Duration) -> Option<Self> {
        let stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
        stream.set_read_timeout(Some(timeout)).ok()?;
        stream.set_write_timeout(Some(timeout)).ok()?;
        Some(Self { reader: std::io::BufReader::new(stream), timeout })
    }

    /// A launch credential for the ACP session `session` (`credential.mint {acp_session}`).
    pub(crate) fn mint(&mut self, session: &str) -> Option<String> {
        let minted = self
            .call("credential.mint", serde_json::json!({"acp_session": session}), None, None)
            .ok()?;
        let credential = minted.get("credential")?.as_str()?;
        (!credential.is_empty()).then(|| credential.to_owned())
    }

    /// `operation` on this machine's current session with `params`, as `credential`'s holder
    /// when one is given, under `idempotency_key`: its `result`, or the daemon's `error`
    /// (`Value::Null` when no answer came).
    pub(crate) fn call(
        &mut self,
        operation: &str,
        mut params: serde_json::Value,
        credential: Option<&str>,
        idempotency_key: Option<&str>,
    ) -> Result<serde_json::Value, serde_json::Value> {
        use serde_json::Value;
        use std::io::{BufRead, Read, Write};
        let id = format!("acpmux-{}", uuid::Uuid::now_v7().simple());
        params["machine"] = Value::from("current");
        params["session"] = Value::from("current");
        let mut request = serde_json::json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if let Some(credential) = credential {
            request["credential"] = Value::from(credential);
        }
        if let Some(key) = idempotency_key {
            request["idempotency_key"] = Value::from(key);
        }
        let mut line = serde_json::to_vec(&request).map_err(|_| Value::Null)?;
        line.push(b'\n');
        self.reader.get_mut().write_all(&line).map_err(|_| Value::Null)?;
        let deadline = std::time::Instant::now() + self.timeout;
        while std::time::Instant::now() < deadline {
            let mut reply = String::new();
            let read = (&mut self.reader).take(MAX_REPLY_BYTES).read_line(&mut reply);
            if read.map_err(|_| Value::Null)? == 0 {
                return Err(Value::Null);
            }
            let Ok(reply) = serde_json::from_str::<Value>(&reply) else { continue };
            if reply.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                continue;
            }
            if reply.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
            }
            return Err(reply.get("error").cloned().unwrap_or(Value::Null));
        }
        Err(Value::Null)
    }
}
