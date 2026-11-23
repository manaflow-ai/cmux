//! `cmux ssh HOST` over the hub carrier: no sshd, no keys, nothing installed on HOST.
//!
//! When HOST names one of this person's machines that this machine's acpmux hub book lists
//! (what `acpmux machine ls` prints), acpmux already serves one local unix socket per such
//! machine (`acpmux/src/machine_routes.rs`, read with `_acpmux/machine_routes`). Each connection
//! to that socket is one hub carrier circuit to the machine's own cmux-tui session daemon
//! (`CircuitService::CmuxTuiSession`), the route the app opens as `ServerReach.Route.unix`.
//! `cmux ssh HOST` attaches the TUI to it, as `cmux attach --socket` attaches to a local one.
//!
//! The carrier goes first, only for a bare machine name with no other option (`user@`, `:port`
//! and every option are ssh's). A name the book does not list (any other ssh host), or no
//! acpmux here, goes to system ssh as before, saying nothing. A listed machine that refuses
//! (`carrier.off`, `consent_required`, ...) prints its one-line reason, then goes to ssh, unless
//! `--carrier` asked for the carrier only. `--ssh` skips the carrier.
//!
//! Cost: one local `_acpmux/machine_routes` read before the attach (a second only after a
//! refused attach, to read why); no extra circuit, since the attach's circuit is the probe.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::anyhow;
use serde_json::{Value, json};

use crate::localization::catalog;
use crate::session::RemoteSession;

/// acpmux's read of the person's other machines and their local route sockets.
const ROUTES_METHOD: &str = "_acpmux/machine_routes";
/// One local acpmux call: connect, read the routes.
const ROUTES_BUDGET: Duration = Duration::from_secs(15);

/// Which way `cmux ssh` goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Way {
    /// The carrier when HOST is a listed machine, else system ssh.
    Auto,
    /// `--carrier`: the carrier or the refusal.
    CarrierOnly,
    /// `--ssh`: system ssh, as before the carrier.
    SshOnly,
}

/// `--carrier` and `--ssh` taken out of `cmux ssh`'s arguments, and the rest in order. A word
/// after `--ssh-arg` is that option's value, never one of these.
pub(super) fn split_way(args: &[String]) -> anyhow::Result<(Way, Vec<String>)> {
    let (mut carrier, mut ssh) = (false, false);
    let mut rest = Vec::with_capacity(args.len());
    let mut previous: Option<&str> = None;
    for argument in args {
        let is_value = previous == Some("--ssh-arg");
        previous = Some(argument.as_str());
        match argument.as_str() {
            "--carrier" if !is_value => carrier = true,
            "--ssh" if !is_value => ssh = true,
            _ => rest.push(argument.clone()),
        }
    }
    let way = match (carrier, ssh) {
        (true, true) => return Err(anyhow!(catalog().remote_client.ssh_carrier_and_ssh)),
        (true, false) => Way::CarrierOnly,
        (false, true) => Way::SshOnly,
        (false, false) => Way::Auto,
    };
    Ok((way, rest))
}

/// The machine name the carrier may reach: the destination alone, a bare host name (no `user@`,
/// no `:port`), with no other option.
pub(super) fn carrier_host(rest: &[String]) -> Option<&str> {
    match rest {
        [host] if is_machine_name(host) => Some(host),
        _ => None,
    }
}

fn is_machine_name(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with(['-', '.'])
        && host.chars().all(|c| c.is_ascii_alphanumeric() || "-._".contains(c))
}

/// Why the carrier did not take this `cmux ssh`: acpmux's `{reason, error}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Refusal {
    pub reason: String,
    pub error: String,
}

impl Refusal {
    fn new(reason: &str, error: impl Into<String>) -> Self {
        Self { reason: reason.to_owned(), error: error.into() }
    }

    /// The carrier does not apply here (no acpmux, or a name the book does not list): ssh takes
    /// it as it always did, with nothing printed.
    pub(super) fn is_quiet(&self) -> bool {
        matches!(self.reason.as_str(), "machine.unlisted" | "acpmux.off")
    }

    fn of(value: &Value) -> Option<Self> {
        let reason = value.get("reason").and_then(Value::as_str)?;
        let error = value.get("error").and_then(Value::as_str).unwrap_or(reason);
        Some(Self::new(reason, error))
    }
}

/// A listed machine's route: its hub `daemonId` and the local socket that carries a circuit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Route {
    pub daemon_id: String,
    pub socket: PathBuf,
}

/// The route to `host` in a `_acpmux/machine_routes` answer, or why there is none. Names match
/// without regard to ASCII case, as host names do; of two machines with one name, the first
/// with a socket.
pub(super) fn pick(answer: &Value, host: &str) -> Result<Route, Refusal> {
    let machines = answer.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let named: Vec<&Value> = machines
        .iter()
        .filter(|m| {
            m.get("host").and_then(Value::as_str).is_some_and(|h| h.eq_ignore_ascii_case(host))
        })
        .collect();
    if named.is_empty() {
        return Err(Refusal::new(
            "machine.unlisted",
            format!("the hub lists no machine named {host} for this account"),
        ));
    }
    if answer.get("carrier").and_then(Value::as_bool) != Some(true) {
        let why = answer.get("carrierReason").and_then(Value::as_str);
        return Err(Refusal::new(
            "carrier.off",
            match why {
                Some(why) => format!("this machine's hub carrier is off ({why})"),
                None => {
                    "this machine's hub carrier is off (not joined, or no WireGuard key)".into()
                }
            },
        ));
    }
    let routed = named.iter().find_map(|m| {
        let socket = m.get("socket").and_then(Value::as_str).filter(|s| !s.is_empty())?;
        let daemon_id = m.get("daemonId").and_then(Value::as_str)?;
        (m.get("route").and_then(Value::as_str) == Some("unix"))
            .then(|| Route { daemon_id: daemon_id.to_owned(), socket: socket.into() })
    });
    routed.ok_or_else(|| {
        named.iter().find_map(|m| m.get("refusal").and_then(Refusal::of)).unwrap_or_else(|| {
            Refusal::new("route.unavailable", format!("acpmux has no route to {host}"))
        })
    })
}

/// What the route to `daemon_id` recorded about its last circuit (the far end's refusal), if
/// anything.
pub(super) fn recorded_refusal(answer: &Value, daemon_id: &str) -> Option<Refusal> {
    answer
        .get("machines")?
        .as_array()?
        .iter()
        .find(|m| m.get("daemonId").and_then(Value::as_str) == Some(daemon_id))?
        .get("refusal")
        .and_then(Refusal::of)
}

/// `cmux ssh`'s carrier step: the attached session and its label, or None for ssh to take it.
/// With `--carrier` a refusal is the error; otherwise a listed machine's refusal is one stderr
/// line before ssh runs.
pub(super) fn reach(
    rest: &[String],
    way: Way,
) -> anyhow::Result<Option<(Arc<RemoteSession>, String)>> {
    let messages = &catalog().remote_client;
    let Some(host) = carrier_host(rest) else {
        if way == Way::CarrierOnly {
            return Err(anyhow!(messages.ssh_carrier_needs_machine));
        }
        return Ok(None);
    };
    match open(host) {
        Ok(remote) => Ok(Some((remote, host.to_owned()))),
        Err(refusal) => {
            let line = messages.ssh_carrier_refused(host, &refusal.reason, &refusal.error);
            if way == Way::CarrierOnly {
                return Err(anyhow!(line));
            }
            if !refusal.is_quiet() {
                eprintln!("{line}; {}", messages.ssh_carrier_falls_back);
            }
            Ok(None)
        }
    }
}

/// Attach to `host`'s cmux-tui session over its route socket.
fn open(host: &str) -> Result<Arc<RemoteSession>, Refusal> {
    let acpmux = crate::acp::daemon_socket_path()
        .filter(|socket| socket.exists())
        .ok_or_else(|| Refusal::new("acpmux.off", "no acpmux runs on this machine"))?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Refusal::new("acpmux.off", format!("could not start Tokio: {e}")))?;
    let routes = |runtime: &tokio::runtime::Runtime| runtime.block_on(read_routes(&acpmux));
    let route = pick(&routes(&runtime)?, host)?;
    RemoteSession::connect(&route.socket).map_err(|error| {
        // The route records the far end's refusal before it lets the connection go.
        routes(&runtime)
            .ok()
            .and_then(|answer| recorded_refusal(&answer, &route.daemon_id))
            .unwrap_or_else(|| Refusal::new("machine.unreachable", format!("{error:#}")))
    })
}

async fn read_routes(socket: &std::path::Path) -> Result<Value, Refusal> {
    let read = async {
        let client = acpmux::client::Client::connect_without_caller(socket)
            .await
            .map_err(|e| Refusal::new("acpmux.off", format!("{e:#}")))?;
        client.request(ROUTES_METHOD, json!({})).await.map_err(|e| {
            match e.downcast_ref::<acpmux::client::DaemonError>() {
                // An acpmux from before the routes: the carrier does not apply.
                Some(owner) if owner.0.code == -32601 => {
                    Refusal::new("acpmux.off", owner.0.message.clone())
                }
                Some(owner) => owner
                    .0
                    .data
                    .as_ref()
                    .and_then(Refusal::of)
                    .unwrap_or_else(|| Refusal::new("acpmux.refused", owner.0.message.clone())),
                None => Refusal::new("acpmux.off", format!("{e:#}")),
            }
        })
    };
    tokio::time::timeout(ROUTES_BUDGET, read).await.unwrap_or_else(|_| {
        Err(Refusal::new(
            "acpmux.slow",
            format!("acpmux gave no routes in {}s", ROUTES_BUDGET.as_secs()),
        ))
    })
}

#[cfg(test)]
#[path = "ssh_carrier_tests.rs"]
mod tests;
