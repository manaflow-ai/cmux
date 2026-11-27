//! The web client's routes (cmuxterm-hq docs/rfd/0083-cmux-web-client.md, Deeplinks). They mirror
//! the app's grammar, so a link pasted in a chat, the cmux.com page and the web client's own URL
//! all name a place the same way:
//!
//! - `/m/<machine>/agent/<harness>/<session>[?message=<id>]`: one agent chat on one machine.
//! - `/m/<machine>/ws/<workspace>`: one workspace (`ws_<32 hex>`) on one machine.
//! - `/deeplink/agent?harness=&session=[&host=&machine=&message=]`: the agent link's page, on the
//!   web client's own site ([`crate::agent_link`]).
//! - A whole pasted link: `cmux://agent/<harness>/<session>?...`, `cmux://workspace/ws_<hex>
//!   [?machine=machine_<hex>]` (in any build's scheme, `cmux-nightly`, `cmux-dev-<tag>`), or
//!   `https://cmux.com/deeplink/agent?...`.
//!
//! `<machine>` is a machine id (`machine_<32 hex>`) or a machine's name (`my-vm`). Of a query
//! only `message` is read; a repeated, empty or malformed one names nothing, as every hint of an
//! agent link. A route is an address: nothing here starts, prompts or runs anything.
//! `schemas/deeplinks/web-routes.json` holds the vectors; the web host's reader
//! (`webviews/src/web-host/route.ts`) runs the ones that are paths.

use crate::agent_link::{self, decode, is_harness, is_id, is_machine};

/// The machine a route names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Machine {
    /// `machine_<32 hex>`, the id every cmux link's `?machine=` carries.
    Id(String),
    /// A machine's name, as `acpmux ls` and an agent link's `?host=` give it.
    Name(String),
}

impl Machine {
    fn segment(&self) -> &str {
        match self {
            Machine::Id(v) | Machine::Name(v) => v,
        }
    }
}

/// Where an address points.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    /// One agent chat. `session` is the harness's own session id (or acpmux's); `machine` is
    /// None only for a link that names no machine.
    Agent { machine: Option<Machine>, harness: String, session: String, message: Option<String> },
    /// One workspace.
    Workspace { machine: Option<Machine>, workspace: String },
}

/// Why an address names no route. [`RouteError::code`] is the stable name the vectors and the
/// web host use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteError {
    /// Not one of the route forms: another path, host or scheme.
    NotARoute,
    /// The machine segment is neither a machine id nor a machine name.
    Machine,
    /// The harness segment is not a harness (`^[a-z0-9-]{1,64}$`).
    Harness,
    /// The session segment is not a session id.
    Session,
    /// The workspace segment is not a `ws_<32 hex>` id.
    Workspace,
    /// An agent link that names no usable harness or session (its reader's reason).
    Link(String),
}

impl RouteError {
    pub fn code(&self) -> &'static str {
        match self {
            RouteError::NotARoute => "not-a-route",
            RouteError::Machine => "machine",
            RouteError::Harness => "harness",
            RouteError::Session => "session",
            RouteError::Workspace => "workspace",
            RouteError::Link(_) => "link",
        }
    }
}

impl std::fmt::Display for RouteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RouteError::NotARoute => f.write_str("this address is not a cmux chat or workspace"),
            RouteError::Machine => {
                f.write_str("the address names no machine cmux knows how to read")
            }
            RouteError::Harness => f.write_str("the address names no agent harness"),
            RouteError::Session => f.write_str("the address names no chat session"),
            RouteError::Workspace => f.write_str("the address names no workspace"),
            RouteError::Link(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for RouteError {}

impl Route {
    /// The web client's own path for this route, which [`parse`] reads back the same. An agent
    /// route with no machine is the `/deeplink/agent` page's; a workspace with none has no path.
    pub fn path(&self) -> Option<String> {
        match self {
            Route::Agent { machine: Some(m), harness, session, message } => Some(format!(
                "/m/{}/agent/{harness}/{session}{}",
                m.segment(),
                message.as_ref().map(|v| format!("?message={v}")).unwrap_or_default()
            )),
            Route::Agent { machine: None, harness, session, message } => Some(format!(
                "/deeplink/agent?harness={harness}&session={session}{}",
                message.as_ref().map(|v| format!("&message={v}")).unwrap_or_default()
            )),
            Route::Workspace { machine: Some(m), workspace } => {
                Some(format!("/m/{}/ws/{workspace}", m.segment()))
            }
            Route::Workspace { machine: None, .. } => None,
        }
    }
}

/// The route `address` names: a web client path (`/m/...`, `/deeplink/agent?...`) or a whole
/// pasted cmux link. Surrounding whitespace is ignored; anything else around it is not a route.
pub fn parse(address: &str) -> Result<Route, RouteError> {
    let address = address.trim();
    if address.is_empty() || address.len() > MAX_ADDRESS || address.contains(char::is_whitespace) {
        return Err(RouteError::NotARoute);
    }
    if address.starts_with('/') {
        return parse_path(address);
    }
    if let Some(rest) = address.strip_prefix("https://") {
        // The host is everything before the first path, query or fragment mark.
        let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
        return match host {
            "cmux.com" | "www.cmux.com" => agent(agent_link::find(address)),
            _ => Err(RouteError::NotARoute),
        };
    }
    let (scheme, rest) = address.split_once("://").ok_or(RouteError::NotARoute)?;
    if !is_scheme(scheme) {
        return Err(RouteError::NotARoute);
    }
    if rest.starts_with("agent/") || rest == "agent" || rest.starts_with("agent?") {
        // The agent link's reader takes the release scheme; every build's link reads the same.
        return agent(agent_link::find(&format!("cmux://{rest}")));
    }
    let (path, query) = split_query(rest);
    match path.split('/').collect::<Vec<_>>().as_slice() {
        ["workspace", id] => {
            let workspace = decode(id).filter(|v| is_workspace(v)).ok_or(RouteError::Workspace)?;
            let machine = single(query, "machine", &is_machine).map(Machine::Id);
            Ok(Route::Workspace { machine, workspace })
        }
        _ => Err(RouteError::NotARoute),
    }
}

/// Longer than any address cmux writes: a pasted wall of text is never read as one.
const MAX_ADDRESS: usize = 2048;

fn parse_path(address: &str) -> Result<Route, RouteError> {
    let (path, query) = split_query(address);
    let path = path.strip_suffix('/').filter(|p| !p.is_empty()).unwrap_or(path);
    if path == "/deeplink/agent" {
        return agent(agent_link::find(&format!("https://cmux.com/deeplink/agent?{query}")));
    }
    let segments: Vec<&str> = path.split('/').skip(1).collect();
    let (machine, rest) = match segments.as_slice() {
        ["m", machine, rest @ ..] => (machine_segment(machine)?, rest),
        _ => return Err(RouteError::NotARoute),
    };
    match rest {
        ["agent", harness, session] => {
            let harness = decode(harness).filter(|v| is_harness(v)).ok_or(RouteError::Harness)?;
            let session =
                decode(session).filter(|v| is_id(v, 256, ":")).ok_or(RouteError::Session)?;
            let message = single(query, "message", &|v| is_id(v, 200, ""));
            Ok(Route::Agent { machine: Some(machine), harness, session, message })
        }
        ["ws", workspace] => {
            let workspace =
                decode(workspace).filter(|v| is_workspace(v)).ok_or(RouteError::Workspace)?;
            Ok(Route::Workspace { machine: Some(machine), workspace })
        }
        _ => Err(RouteError::NotARoute),
    }
}

/// An agent link's answer as a route: its machine id, else its host, names the machine.
fn agent(found: Option<Result<agent_link::AgentLink, String>>) -> Result<Route, RouteError> {
    let link = found.ok_or(RouteError::NotARoute)?.map_err(RouteError::Link)?;
    let machine = link.machine.map(Machine::Id).or(link.host.map(Machine::Name));
    Ok(Route::Agent {
        machine,
        harness: link.harness,
        session: link.session,
        message: link.message,
    })
}

fn machine_segment(raw: &str) -> Result<Machine, RouteError> {
    let value = decode(raw).ok_or(RouteError::Machine)?;
    if value.starts_with("machine_") {
        return if is_machine(&value) { Ok(Machine::Id(value)) } else { Err(RouteError::Machine) };
    }
    if is_id(&value, 64, "") { Ok(Machine::Name(value)) } else { Err(RouteError::Machine) }
}

/// `rest` before its `?` (and any `#`), and the query between them.
fn split_query(rest: &str) -> (&str, &str) {
    let rest = rest.split_once('#').map_or(rest, |(before, _)| before);
    rest.split_once('?').unwrap_or((rest, ""))
}

/// The one value of `key` in `query` when it is there once and `ok` takes it.
fn single(query: &str, key: &str, ok: &dyn Fn(&str) -> bool) -> Option<String> {
    let mut values = query
        .replace("&amp;", "&")
        .split('&')
        .filter_map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            (decode(k).as_deref() == Some(key)).then(|| decode(v))
        })
        .collect::<Vec<_>>();
    if values.len() != 1 {
        return None;
    }
    values.pop().flatten().filter(|v| ok(v))
}

/// `cmux` or a build's `cmux-<tag>` scheme.
fn is_scheme(v: &str) -> bool {
    v == "cmux"
        || v.strip_prefix("cmux-").is_some_and(|tag| {
            !tag.is_empty()
                && tag.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

/// `^ws_[0-9a-f]{32}$`
fn is_workspace(v: &str) -> bool {
    v.strip_prefix("ws_").is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

#[cfg(test)]
#[path = "route_tests.rs"]
mod tests;
