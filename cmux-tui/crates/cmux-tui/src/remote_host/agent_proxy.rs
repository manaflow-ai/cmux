//! A line-only carrier for shared chats. Never forward resource or stream envelopes.
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Shutdown, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::{audit, config, grant, shares::Role, tailnet::Identity};

const MAX_FRAME: usize = 128 * 1024;

pub(super) fn filter(
    config: &config::Config,
    author: &Value,
    generation: &str,
    mut frame: Value,
) -> Result<Value, &'static str> {
    let login = author["login"].as_str().ok_or("scope_not_granted")?;
    if !config.enabled
        || !matches!(grant::check(config, login),
        grant::Check::Granted(scopes) if scopes.contains(&grant::Scope::Agents))
    {
        return Err("scope_not_granted");
    }
    let cmd = frame["cmd"].as_str().ok_or("scope_not_granted")?;
    // No `agent-session-permission`: answering the host's tool asks stays the owner's until
    // acpmux refuses a teammate's allow itself (`permission.owner_only`, design section 7).
    if !matches!(
        cmd,
        "agent-session-attach"
            | "agent-session-observe"
            | "agent-session-events"
            | "agent-session-prompt"
            | "agent-session-cancel"
            | "agent-session-detach"
    ) || frame.get("protocol").is_some()
        || frame.get("method").is_some()
    {
        return Err("scope_not_granted");
    }
    let surface = frame["surface"].as_u64().ok_or("agent_session.not_shared")?;
    let share = config
        .shares
        .iter()
        .find(|s| {
            s.surface == surface
                && config::same_login(&s.login, login)
                && !generation.is_empty()
                && s.generation == generation
                && !s.session.is_empty()
        })
        .ok_or("agent_session.not_shared")?;
    if share.role == Role::Guest
        && !matches!(cmd, "agent-session-observe" | "agent-session-events" | "agent-session-detach")
    {
        return Err("scope_not_granted");
    }
    let object = frame.as_object_mut().ok_or("scope_not_granted")?;
    object.remove("author");
    object.remove("_meta");
    object.insert("_host_author".into(), author.clone());
    // The consented chat, never one the teammate names: the daemon refuses the frame when the
    // surface shows another chat now.
    object.insert("_host_session".into(), Value::String(share.session.clone()));
    Ok(frame)
}

fn line(reader: &mut impl BufRead, limit: usize) -> io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    reader.take(limit as u64 + 1).read_until(b'\n', &mut bytes)?;
    if bytes.is_empty() {
        return Ok(None);
    }
    if bytes.len() > limit || bytes.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            crate::localization::catalog().host_share.frame_too_long,
        ));
    }
    Ok(Some(bytes))
}

fn send(to: &mut impl Write, frame: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *to, frame)?;
    to.write_all(b"\n")?;
    to.flush()
}

pub(super) fn run(
    tcp: TcpStream,
    daemon: super::serve::DaemonStream,
    identity: Identity,
    peer: IpAddr,
) -> io::Result<()> {
    run_with_config(tcp, daemon, identity, peer, config::load)
}

fn run_with_config(
    tcp: TcpStream,
    mut daemon: super::serve::DaemonStream,
    identity: Identity,
    peer: IpAddr,
    load: impl Fn() -> anyhow::Result<config::Config>,
) -> io::Result<()> {
    let login = identity.login.unwrap_or_default().trim().to_ascii_lowercase();
    let author = json!({"id": format!("tailnet:{login}"), "name": login, "login": login, "node": identity.node});
    // The same-user socket attests this preface. No peer bytes precede it.
    daemon.set_read_timeout(Some(Duration::from_secs(5)))?;
    daemon.set_write_timeout(Some(Duration::from_secs(5)))?;
    send(
        &mut daemon,
        &json!({"cmd": "agent-session-proxy-bind", "id": "host-bind", "author": author}),
    )?;
    let mut daemon_read = BufReader::new(daemon.try_clone_box()?);
    let ack = line(&mut daemon_read, MAX_FRAME)?
        .ok_or_else(|| io::Error::from(io::ErrorKind::UnexpectedEof))?;
    let ack: Value = serde_json::from_slice(&ack)?;
    if ack["ok"] != true || ack["id"] != "host-bind" {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            crate::localization::catalog().host_share.proxy_refused,
        ));
    }
    daemon.set_read_timeout(None)?;
    let tcp_close = tcp.try_clone()?;
    tcp.set_nodelay(true)?;
    tcp.set_write_timeout(Some(Duration::from_secs(5)))?;
    let output = Arc::new(Mutex::new(tcp.try_clone()?));
    let replies = output.clone();
    let down = std::thread::spawn(move || {
        // Serialize whole daemon lines with refusals, so responses never interleave.
        while let Ok(Some(bytes)) = line(&mut daemon_read, 16 * 1024 * 1024) {
            let mut out = replies.lock().unwrap_or_else(|e| e.into_inner());
            if out.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = tcp_close.shutdown(Shutdown::Both);
    });
    let mut input = BufReader::new(tcp);
    let result = (|| {
        loop {
            let bytes = match line(&mut input, MAX_FRAME) {
                Ok(Some(bytes)) => bytes,
                Ok(None) => break,
                Err(error) => {
                    audit::append(
                        &json!({"decision": "refused", "login": login, "node": identity.node, "peer": peer, "reason": "scope_not_granted"}),
                    );
                    send(
                        &mut *output.lock().unwrap_or_else(|e| e.into_inner()),
                        &json!({"ok": false, "error_code": "scope_not_granted"}),
                    )?;
                    return Err(error);
                }
            };
            let frame: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let config = load().map_err(io::Error::other)?;
            // The attach client's handshake reveals no inventory and grants no role.
            if matches!(frame["cmd"].as_str(), Some("identify" | "set-client-info"))
                && frame.get("protocol").is_none()
                && frame.get("method").is_none()
                && config.enabled
                && matches!(grant::check(&config, &login),
                    grant::Check::Granted(scopes) if scopes.contains(&grant::Scope::Agents))
            {
                let data = if frame["cmd"] == "identify" { ack["data"].clone() } else { json!({}) };
                send(
                    &mut *output.lock().unwrap_or_else(|e| e.into_inner()),
                    &json!({"id": frame["id"], "ok": true, "data": data}),
                )?;
                continue;
            }
            match filter(
                &config,
                &author,
                ack["data"]["generation"].as_str().unwrap_or_default(),
                frame.clone(),
            ) {
                Ok(frame) => send(&mut daemon, &frame)?,
                Err(code) => {
                    audit::append(
                        &json!({"decision": "refused", "login": login, "node": identity.node,
                        "peer": peer, "op": frame["cmd"], "surface": frame["surface"], "reason": code}),
                    );
                    send(
                        &mut *output.lock().unwrap_or_else(|e| e.into_inner()),
                        &json!({"id": frame["id"], "ok": false, "error_code": code, "error": code}),
                    )?;
                }
            }
        }
        Ok(())
    })();
    let _ = daemon.shutdown(Shutdown::Both);
    let _ = input.get_ref().shutdown(Shutdown::Both);
    let _ = down.join();
    result
}

#[cfg(all(test, unix))]
mod tests;
