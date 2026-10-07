//! The ops `cloud.port.list`, `cloud.port.forward`, `cloud.port.close` and
//! `cloud.browser.open`.

use super::listener::Listener;
use super::{Edge, Forward, MAX_LISTENERS};
use crate::api::{CloudError, ControlPlane, Origin, args, codes};
use crate::link::Carrier;
use crate::link::LinkSupervisor;
use crate::ops::Server;
use crate::proxy;
use serde_json::{Map, Value, json};

pub const PORT_LIMIT: &str = "cmux.cloud.port_limit";
pub const PROXY_REFUSED: &str = "cmux.cloud.proxy_refused";
pub const LISTEN_FAILED: &str = "cmux.cloud.listen_failed";

pub(crate) const LIST: &str = "cloud.port.list";
pub(crate) const FORWARD: &str = "cloud.port.forward";
pub(crate) const CLOSE: &str = "cloud.port.close";
pub(crate) const BROWSER_OPEN: &str = "cloud.browser.open";

pub(crate) fn serves(name: &str) -> bool {
    matches!(name, LIST | FORWARD | CLOSE | BROWSER_OPEN)
}

/// Ops whose answer is live listener state: never replayed from the ledger
/// (a recorded `localPort` may be closed). Each is idempotent by itself:
/// one forward per (machine, port), one route per machine.
pub(crate) fn live_state_op(name: &str) -> bool {
    matches!(name, FORWARD | CLOSE | BROWSER_OPEN)
}

fn port_arg(map: &Map<String, Value>) -> Result<u16, CloudError> {
    args::int(map, "port", 1, 65_535, 1)?
        .and_then(|p| u16::try_from(p).ok())
        .ok_or_else(|| CloudError::invalid("port is required (1 to 65535)"))
}

fn record(machine: &str, port: u16, forward: &Forward) -> Value {
    json!({
        "machine": machine,
        "port": port,
        "host": "127.0.0.1",
        "localPort": forward.local_port,
        "generation": forward.generation,
        "state": if forward.down.is_some() { "down" } else { "up" },
        "reason": forward.down,
    })
}

pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
) -> Result<Value, CloudError> {
    match name {
        LIST => {
            let map = args::object(raw, &["machine"])?;
            let only =
                if map.contains_key("machine") { Some(args::id(map, "machine")?) } else { None };
            let (edge, links) = server.edge_parts();
            edge.reconcile(links);
            let forwards: Vec<Value> = edge
                .forwards
                .iter()
                .filter(|((m, _), _)| only.is_none_or(|o| o == m))
                .map(|((m, p), f)| record(m, *p, f))
                .collect();
            Ok(json!({ "forwards": forwards }))
        }
        FORWARD => {
            let map = args::object(raw, &["machine", "port"])?;
            let machine = args::id(map, "machine")?.to_owned();
            let port = port_arg(map)?;
            let carrier = link(server, &machine, origin, key)?;
            let (edge, links) = server.edge_parts();
            let at = (machine.clone(), port);
            let forward = ensure(edge, links, &carrier, Slot::Forward(&at), port)?;
            Ok(record(&machine, port, forward))
        }
        CLOSE => {
            let map = args::object(raw, &["machine", "port"])?;
            let machine = args::id(map, "machine")?.to_owned();
            let port = port_arg(map)?;
            let (edge, _) = server.edge_parts();
            let closed = match edge.forwards.remove(&(machine.clone(), port)) {
                Some(mut forward) => {
                    forward.close("closed");
                    true
                }
                None => false,
            };
            Ok(json!({ "machine": machine, "port": port, "closed": closed }))
        }
        BROWSER_OPEN => browser_open(server, raw, origin, key),
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// The machine's carrier, connecting (and starting a paused machine) when
/// no link is up.
fn link<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    origin: Origin,
    key: Option<&str>,
) -> Result<Carrier, CloudError> {
    crate::link::ops::connect(server, machine, origin, key.map(|k| format!("{k}/start")))
}

enum Slot<'a> {
    Forward(&'a (String, u16)),
    Proxy(&'a str),
}

/// The live forward or route in `slot` for `carrier`: the one that exists
/// when it is up on this link generation, else a new listener.
fn ensure<'e>(
    edge: &'e mut Edge,
    links: &LinkSupervisor,
    carrier: &Carrier,
    slot: Slot<'_>,
    port: u16,
) -> Result<&'e Forward, CloudError> {
    edge.reconcile(links);
    let current = match &slot {
        Slot::Forward(at) => edge.forwards.get(*at),
        Slot::Proxy(machine) => edge.proxies.get(*machine),
    };
    let live = current.is_some_and(|f| f.down.is_none() && f.generation == carrier.generation);
    if !live {
        if edge.listeners() >= MAX_LISTENERS {
            return Err(CloudError::new(
                PORT_LIMIT,
                format!("at most {MAX_LISTENERS} port forwards and browser routes are open"),
            ));
        }
        let handler = match &slot {
            Slot::Forward(_) => edge.forward_handler(carrier, "localhost", port),
            Slot::Proxy(_) => proxy::handler(std::sync::Arc::clone(&edge.tunnel), carrier.clone()),
        };
        let listener = Listener::bind(handler).map_err(|e| {
            CloudError::new(LISTEN_FAILED, format!("could not listen on 127.0.0.1: {e}"))
        })?;
        let forward = Forward {
            local_port: listener.local_addr().port(),
            listener: Some(listener),
            generation: carrier.generation,
            down: None,
        };
        // Replacing a record drops (and closes) a down listener, if any.
        match &slot {
            Slot::Forward(at) => edge.forwards.insert((*at).clone(), forward),
            Slot::Proxy(machine) => edge.proxies.insert((*machine).to_owned(), forward),
        };
    }
    Ok(match slot {
        Slot::Forward(at) => &edge.forwards[at],
        Slot::Proxy(machine) => &edge.proxies[machine],
    })
}

/// `cloud.browser.open`: the proxy route a browser tab uses to reach
/// `host:port` on the machine. It opens no browser (the browser host owns
/// tabs, cloud-app.md 5.3).
fn browser_open<C: ControlPlane>(
    server: &mut Server<C>,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
) -> Result<Value, CloudError> {
    let map = args::object(raw, &["machine", "port", "host", "path"])?;
    let machine = args::id(map, "machine")?.to_owned();
    let port = port_arg(map)?;
    let host = proxy::normal_host(args::text(map, "host", 253)?.unwrap_or("localhost"));
    if !proxy::is_machine_host(&host) {
        return Err(CloudError::new(
            PROXY_REFUSED,
            format!(
                "{host} is not the Cloud machine; the browser route reaches only its localhost"
            ),
        ));
    }
    let path = args::text(map, "path", 2048)?.unwrap_or("/");
    if !path.starts_with('/') || path.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(CloudError::invalid("path must start with / and have no spaces"));
    }
    let carrier = link(server, &machine, origin, key)?;
    let (edge, links) = server.edge_parts();
    let route = ensure(edge, links, &carrier, Slot::Proxy(&machine), port)?;
    let authority =
        if host.contains(':') && !host.starts_with('[') { format!("[{host}]") } else { host };
    Ok(json!({
        "machine": machine,
        "proxy": { "kind": "http", "host": "127.0.0.1", "port": route.local_port },
        "url": format!("http://{authority}:{port}{path}"),
        "generation": route.generation,
    }))
}
