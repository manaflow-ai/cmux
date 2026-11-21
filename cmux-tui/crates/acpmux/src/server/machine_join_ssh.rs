//! Door A for the app (cmuxterm-hq docs/design/remote-spin-up.md, section 2.1): the composer's
//! machine menu and the Add a Device card list the machines this computer reaches but has not
//! added, and one click joins one.
//!
//! - `_acpmux/machine_candidates {}` -> `{candidates: [{name, address, os, found, online, mine}],
//!   tailnet}`: the online nodes of the person's tailnet and the concrete hosts of `~/.ssh/config`,
//!   without this machine and the machines already peers here.
//! - `_acpmux/machine_join_ssh {host, name?, accessToken, hub?, joinId?, confirmed?}` -> the
//!   join's outcome
//!   (`cli/ssh_join.rs`: `{ok, host, machine?, platform?, seconds, failure?: {kind, message,
//!   next}}`). While it runs, each step goes to the caller as
//!   `_acpmux/machine_join_progress {joinId, host, step, state, detail, seconds}`, so the app can
//!   show "Setting up gcp-3 · installing 6 s". A `$/cancel_request` stops it and its ssh.
//!   A host that is not a tailnet node the tailnet says this person owns answers
//!   `failure.kind: needs_confirmation` with `confirm: {host, login}` and runs nothing; the app
//!   asks once, naming both, and calls again with `confirmed: true`.
//!
//! Both are this computer's own app only (the local socket, or the agent pane proven by its
//! LocalApp token), and only the person (`hub/person.rs`): an agent or a
//! script on this machine may not add machines with the person's sign-in. The access token is
//! used for the hub's requests only, never logged or sent on.

use std::sync::Arc;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, Origin};
use crate::cli::ssh_join;
use crate::hub::Hub;
use crate::rpc::{Message, RpcError, method};

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_MACHINE_JOIN_SSH | method::MUX_MACHINE_CANDIDATES) {
        return None;
    }
    if let Err(refused) = local(conn, m) {
        return Some(Err(refused));
    }
    Some(match m {
        method::MUX_MACHINE_JOIN_SSH => join(conn, params).await,
        _ => candidates(hub).await,
    })
}

/// Who may ask: the local socket (the CLI, the app's own lines) and the app's agent pane, proven by
/// this launch's LocalApp token (the composer's machine menu, webviews machineJoin.ts). Never the
/// web listener or a peer. The pane's host adds the access token; the page never holds it.
pub(super) fn served_to(origin: Origin) -> bool {
    matches!(origin, Origin::Local | Origin::LocalApp)
}

fn local(conn: &Conn, m: &str) -> Result<(), RpcError> {
    if !served_to(conn.origin) {
        return Err(RpcError::method_not_found(&format!("{m} (this computer's own app only)")));
    }
    if !conn.is_person() {
        return Err(crate::hub::person::person_required("adding a machine to cmux"));
    }
    Ok(())
}

async fn join(conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let text = |key: &str| {
        params.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
    };
    let host = text("host").ok_or_else(|| RpcError::invalid_params("host is required"))?;
    let access = text("accessToken")
        .map(|token| Zeroizing::new(token.to_owned()))
        .ok_or_else(|| RpcError::invalid_params("accessToken is required"))?;
    let join_id =
        text("joinId").map_or_else(|| format!("join-{}", uuid::Uuid::now_v7()), str::to_owned);
    let request = ssh_join::Request {
        host: host.to_owned(),
        name: text("name").map(str::to_owned),
        hub: text("hub").map(str::to_owned),
    };
    let confirmed = params.get("confirmed").and_then(Value::as_bool) == Some(true);
    if !confirmed {
        let probe_host = request.host.clone();
        let ask = tokio::task::spawn_blocking(move || {
            unconfirmed_answer(false, &probe_host, |host| {
                let owned = crate::tailnet::Tailnet::locate()
                    .and_then(|t| t.status())
                    .is_ok_and(|status| ssh_join::owned_tailnet_node(&status, host));
                let login =
                    if owned { None } else { ssh_join::ssh_login(&ssh_join::ssh_program(), host) };
                (owned, login)
            })
        })
        .await
        .map_err(|_| RpcError::internal("the host check stopped"))?;
        if let Some(mut ask) = ask {
            ask.set("joinId", json!(join_id));
            return Ok(ask);
        }
    }
    let progress_conn = Arc::clone(conn);
    let progress_id = join_id.clone();
    let progress_host = request.host.clone();
    let mut emit = move |step: ssh_join::Progress| {
        let mut note = serde_json::to_value(&step).unwrap_or_default();
        note.set("joinId", json!(progress_id));
        note.set("host", json!(progress_host));
        progress_conn.send(&Message::notification(method::MUX_MACHINE_JOIN_PROGRESS, note));
    };
    let outcome = ssh_join::join_as(&request, access, &mut emit).await;
    tracing::info!(
        host = %request.host,
        ok = outcome.ok,
        seconds = outcome.seconds,
        kind = ?outcome.failure.as_ref().map(|f| f.kind),
        "machine join over ssh"
    );
    let mut answer = outcome.to_value();
    answer.set("joinId", json!(join_id));
    Ok(answer)
}

/// One click joins without asking only a tailnet node the tailnet says this person owns; any
/// other host joins once the person confirmed it, named with its ssh login. `check` answers
/// whether `host` is such a node and, when not, the login ssh would use. `Some` is the
/// refusal that runs nothing (`needs_confirmation` with `confirm: {host, login}`).
pub(super) fn unconfirmed_answer(
    confirmed: bool,
    host: &str,
    check: impl FnOnce(&str) -> (bool, Option<String>),
) -> Option<Value> {
    if confirmed {
        return None;
    }
    let (owned, login) = check(host);
    if owned {
        return None;
    }
    let failure = ssh_join::needs_confirmation(host, login.as_deref());
    Some(json!({
        "ok": false, "host": host, "seconds": 0,
        "failure": failure, "confirm": {"host": host, "login": login},
    }))
}

async fn candidates(hub: &Arc<Hub>) -> Result<Value, RpcError> {
    let peers = hub.peers();
    let listed = tokio::task::spawn_blocking(move || {
        let tailnet = crate::tailnet::Tailnet::locate().and_then(|t| t.status());
        let ssh_hosts = crate::ssh_config_hosts::ssh_config_targets();
        let error = tailnet.as_ref().err().map(|e| format!("{e:#}"));
        list(tailnet.as_ref().ok(), &ssh_hosts, &peers, error)
    })
    .await
    .map_err(|_| RpcError::internal("the candidate list stopped"))?;
    Ok(listed)
}

/// The not-yet-added machines: online tailnet nodes other than this one and the peers here, then
/// the `~/.ssh/config` hosts no tailnet row already names.
pub(super) fn list(
    tailnet: Option<&crate::tailnet::Status>,
    ssh_hosts: &[crate::ssh_config_hosts::SshConfigHost],
    peers: &[Value],
    tailnet_error: Option<String>,
) -> Value {
    let mut rows = Vec::new();
    let mut named = std::collections::HashSet::new();
    if let Some(status) = tailnet {
        for c in crate::cli::host_candidates::candidates(status, peers) {
            if c.already_peer || !c.online {
                continue;
            }
            let address = if c.dns_name.is_empty() {
                c.ip.clone().unwrap_or_default()
            } else {
                c.dns_name.clone()
            };
            if address.is_empty() {
                continue;
            }
            named.insert(c.name.to_ascii_lowercase());
            named.insert(address.to_ascii_lowercase());
            rows.push(json!({
                "name": c.name, "address": address, "os": c.os, "found": "tailnet",
                "online": c.online, "mine": c.mine,
            }));
        }
    }
    let peer_hosts: Vec<String> = peers
        .iter()
        .filter_map(|p| p.get("url").and_then(Value::as_str))
        .filter_map(crate::cli::host_candidates::url_host)
        .map(|h| h.to_ascii_lowercase())
        .collect();
    for host in ssh_hosts {
        let alias = host.alias.to_ascii_lowercase();
        let target = host.host_name.as_deref().unwrap_or(&host.alias).to_ascii_lowercase();
        let short = target.split('.').next().unwrap_or_default().to_owned();
        if [&alias, &target, &short].iter().any(|n| named.contains(*n) || peer_hosts.contains(*n)) {
            continue;
        }
        named.insert(alias);
        rows.push(json!({
            "name": host.alias, "address": host.alias, "os": Value::Null, "found": "ssh-config",
            "online": Value::Null, "mine": true,
        }));
    }
    let mut answer = json!({"candidates": rows});
    if let Some(error) = tailnet_error {
        answer.set("tailnet", json!({"error": error}));
    }
    answer
}

#[cfg(test)]
#[path = "machine_join_ssh_tests.rs"]
mod tests;
