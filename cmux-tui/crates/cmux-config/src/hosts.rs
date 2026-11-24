//! `machines.hosts` in cmux-next.json: the computers a person declares by
//! hand, each one a label and the addresses cmux tries in order, with an
//! optional icon and id (CMUX-673). The sidebar lists them and
//! `cmux hosts check` says which ones answer from here.
//!
//! ```json
//! "machines": { "hosts": [
//!   { "label": "studio", "endpoints": ["studio.local", "ssh://leo@100.64.0.7:2222"], "icon": "desktopcomputer" },
//!   { "label": "build box", "endpoint": "build-1" }
//! ] }
//! ```
//!
//! A host needs a non-blank `label` (at most [`MAX_LABEL`] characters, unique
//! ignoring case) and either `endpoints` (a non-empty list) or one `endpoint`.
//! An endpoint is an ssh destination: `ssh://[user@]host[:port]`, or what
//! `ssh` itself takes (`[user@]host`, an `~/.ssh/config` alias). `icon` and
//! `id` are optional strings. The Swift (`HostsSetting.accepts`) and
//! webviews (`validate.ts isHost`) checks are the same rule.

use serde::Serialize;
use serde_json::Value;

/// The key's path in cmux-next.json.
pub const PATH: [&str; 2] = ["machines", "hosts"];

/// The longest label, in characters.
pub const MAX_LABEL: usize = 64;

/// The most endpoints one host may list.
pub const MAX_ENDPOINTS: usize = 16;

/// One declared host, as the file has it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct HostDecl {
    pub label: String,
    pub endpoints: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

/// Where ssh dials one endpoint: the destination `ssh` takes and the port
/// when the endpoint names one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SshEndpoint {
    /// `[user@]host`, as `ssh` takes it (an alias stays an alias).
    pub destination: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

/// Whether `value` is a valid `machines.hosts` list: every item a host and
/// no two labels the same ignoring case.
pub fn accepts(value: &Value) -> bool {
    let Some(items) = value.as_array() else { return false };
    let mut labels = std::collections::BTreeSet::new();
    items
        .iter()
        .all(|item| host(item).is_some_and(|decl| labels.insert(decl.label.trim().to_lowercase())))
}

/// The hosts of a `machines.hosts` value, in file order, and one problem per
/// item that is not a host (or repeats an earlier label). A value that is
/// not a list is one problem and no hosts.
pub fn parse(value: &Value) -> (Vec<HostDecl>, Vec<String>) {
    let Some(items) = value.as_array() else {
        return (Vec::new(), vec!["machines.hosts: expected a list of hosts".to_owned()]);
    };
    let mut hosts: Vec<HostDecl> = Vec::new();
    let mut problems = Vec::new();
    for (index, item) in items.iter().enumerate() {
        match host(item) {
            Some(decl) if hosts.iter().any(|seen| same_label(&seen.label, &decl.label)) => {
                problems.push(format!("machines.hosts[{index}]: the label {:?} is used twice", decl.label));
            }
            Some(decl) => hosts.push(decl),
            None => problems.push(format!(
                "machines.hosts[{index}]: expected {{\"label\": NAME, \"endpoints\": [ADDRESS, ...]}}"
            )),
        }
    }
    (hosts, problems)
}

/// The host with label `label`, ignoring case.
pub fn find<'a>(hosts: &'a [HostDecl], label: &str) -> Option<&'a HostDecl> {
    hosts.iter().find(|host| same_label(&host.label, label))
}

fn same_label(a: &str, b: &str) -> bool {
    a.trim().to_lowercase() == b.trim().to_lowercase()
}

/// One item as a host, or `None` when it is not one.
pub fn host(value: &Value) -> Option<HostDecl> {
    let members = value.as_object()?;
    let label = members.get("label")?.as_str()?;
    if label.trim().is_empty() || label.chars().count() > MAX_LABEL {
        return None;
    }
    let endpoints: Vec<String> = match (members.get("endpoints"), members.get("endpoint")) {
        (Some(list), None) => {
            let list = list.as_array()?;
            if list.is_empty() || list.len() > MAX_ENDPOINTS {
                return None;
            }
            list.iter().map(|item| item.as_str().map(str::to_owned)).collect::<Option<_>>()?
        }
        (None, Some(one)) => vec![one.as_str()?.to_owned()],
        _ => return None,
    };
    if !endpoints.iter().all(|endpoint| ssh_endpoint(endpoint).is_some()) {
        return None;
    }
    let text = |key: &str| match members.get(key) {
        None => Some(None),
        Some(Value::String(text)) => Some(Some(text.clone())),
        Some(_) => None,
    };
    Some(HostDecl {
        label: label.trim().to_owned(),
        endpoints,
        icon: text("icon")?,
        id: text("id")?,
    })
}

/// An endpoint as an ssh destination, or `None` when it is not one: blank,
/// with whitespace or control characters, starting with `-` (ssh would read
/// an option), another scheme than `ssh://`, or an `ssh://` address with no
/// host or a bad port.
pub fn ssh_endpoint(endpoint: &str) -> Option<SshEndpoint> {
    if endpoint.is_empty()
        || endpoint.starts_with('-')
        || endpoint.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return None;
    }
    let Some((scheme, rest)) = endpoint.split_once("://") else {
        return Some(SshEndpoint { destination: endpoint.to_owned(), port: None });
    };
    if !scheme.eq_ignore_ascii_case("ssh") {
        return None;
    }
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    if authority.contains('/') {
        return None;
    }
    let (user, host_port) = match authority.rsplit_once('@') {
        Some((user, host_port)) if !user.is_empty() => (Some(user), host_port),
        Some(_) => return None,
        None => (None, authority),
    };
    let (host, port) = split_port(host_port)?;
    if host.is_empty() || host.starts_with('-') {
        return None;
    }
    let destination = match user {
        Some(user) => format!("{user}@{host}"),
        None => host.to_owned(),
    };
    Some(SshEndpoint { destination, port })
}

/// `host[:port]` or `[v6][:port]`.
fn split_port(text: &str) -> Option<(&str, Option<u16>)> {
    if let Some(rest) = text.strip_prefix('[') {
        let (host, after) = rest.split_once(']')?;
        return match after.strip_prefix(':') {
            Some(port) => Some((host, Some(port_number(port)?))),
            None if after.is_empty() => Some((host, None)),
            None => None,
        };
    }
    match text.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => Some((host, Some(port_number(port)?))),
        Some(_) => None,
        None => Some((text, None)),
    }
}

fn port_number(text: &str) -> Option<u16> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse::<u16>().ok().filter(|port| *port > 0)
}

#[cfg(test)]
#[path = "hosts_tests.rs"]
mod tests;
