//! The answers of the Cloud actions someone reads: a person sees `text` in a
//! sheet (its title is the app's), a CLI, MCP or script run gets `text` and
//! `fields` as `action.run`'s result. `text` none: the app's own words for
//! "nothing" (no ports, no previews, no forwards).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::args::PortNames;
use crate::{Fields, Said, time};

/// What an action found.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Answer {
    /// None: the app's localized "nothing here" for this answer.
    pub text: Option<String>,
    pub copyable: bool,
    pub fields: Fields,
}

fn object(value: Value) -> Fields {
    match value {
        Value::Object(map) => map,
        _ => Fields::new(),
    }
}

fn answer(text: impl Into<String>, fields: Value) -> Answer {
    Answer { text: Some(text.into()), copyable: true, fields: object(fields) }
}

fn lines_or(lines: &[String], none: &str) -> String {
    if lines.is_empty() { none.to_owned() } else { lines.join("\n") }
}

fn get<'a>(record: &'a Value, name: &str) -> Option<&'a str> {
    record.get(name).and_then(Value::as_str)
}

/// The facts an answer is made of, by kind (`kind`, camel case), as the Cloud API returned them.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Found {
    /// `cloud files-list`: `[{kind, name, size}]`.
    #[serde(rename_all = "camelCase")]
    FilesList {
        path: String,
        entries: Vec<Value>,
    },
    /// `cloud file-read`: utf8 text, else base64.
    #[serde(rename_all = "camelCase")]
    FileRead {
        path: String,
        text: Option<String>,
        data_base64: String,
        size: Option<i64>,
    },
    #[serde(rename_all = "camelCase")]
    FileStat {
        path: String,
        file_kind: String,
        size: Option<i64>,
        mode: Option<u32>,
    },
    /// `cloud prepare-scp`'s endpoint.
    #[serde(rename_all = "camelCase")]
    Scp {
        host: String,
        port: i64,
        username: String,
        host_public_key: String,
        expires_at_unix: i64,
    },
    Domains {
        items: Vec<Value>,
    },
    Publications {
        items: Vec<Value>,
    },
    ApiKeys {
        items: Vec<Value>,
    },
    Networks {
        items: Vec<Value>,
    },
    /// The daemon's listening ports.
    #[serde(rename_all = "camelCase")]
    Ports {
        machine_id: String,
        ports: Vec<i64>,
    },
    /// `cloud port-list`'s forwards (`cloud.port.list`'s records).
    #[serde(rename_all = "camelCase")]
    PortList {
        machine_id: String,
        forwards: Vec<Value>,
    },
    /// `cloud machine-tools`: the probe's run.
    #[serde(rename_all = "camelCase")]
    Tools {
        machine_id: String,
        exit_code: i64,
        stdout: String,
    },
}

/// The answer of `found`.
pub fn of(found: &Found) -> Answer {
    match found {
        Found::FilesList { path, entries } => {
            let lines: Vec<String> = entries
                .iter()
                .map(|entry| {
                    let mut line =
                        if get(entry, "kind") == Some("directory") { "d" } else { "-" }.to_owned();
                    line += &format!(" {}", get(entry, "name").unwrap_or(""));
                    if let Some(size) = entry.get("size").and_then(Value::as_i64) {
                        line += &format!(" {size} bytes");
                    }
                    line
                })
                .collect();
            answer(lines_or(&lines, "(empty)"), json!({"path": path, "count": entries.len()}))
        }
        Found::FileRead { path, text, data_base64, size } => {
            let mut fields = object(
                json!({"path": path, "encoding": if text.is_some() { "utf8" } else { "base64" }}),
            );
            if text.is_none() {
                fields.insert("data_base64".into(), json!(data_base64));
            }
            if let Some(size) = size {
                fields.insert("size".into(), json!(size));
            }
            Answer {
                text: Some(text.clone().unwrap_or_else(|| data_base64.clone())),
                copyable: true,
                fields,
            }
        }
        Found::FileStat { path, file_kind, size, mode } => {
            let mut body = vec![format!("kind: {file_kind}")];
            let mut fields = object(json!({"path": path, "kind": file_kind}));
            if let Some(size) = size {
                body.push(format!("size: {size} bytes"));
                fields.insert("size".into(), json!(size));
            }
            if let Some(mode) = mode {
                body.push(format!("mode: {mode:o}"));
                fields.insert("mode".into(), json!(format!("{mode:o}")));
            }
            Answer { text: Some(body.join("\n")), copyable: true, fields }
        }
        Found::Scp { host, port, username, host_public_key, expires_at_unix } => answer(
            [
                format!("host: {host}"),
                format!("port: {port}"),
                format!("user: {username}"),
                format!("host key: {host_public_key}"),
                format!("expires: {}", time::described(*expires_at_unix)),
            ]
            .join("\n"),
            json!({"host": host, "port": port, "user": username, "host_key": host_public_key, "expires_at": expires_at_unix}),
        ),
        Found::Domains { items } => {
            let lines: Vec<String> = items
                .iter()
                .map(|d| {
                    let name = get(d, "hostname").or_else(|| get(d, "id")).unwrap_or("(unnamed)");
                    let verification = get(d, "verificationState").unwrap_or("unknown");
                    let certificate = get(d, "certificateState").unwrap_or("unknown");
                    format!("{name} (verification: {verification}, certificate: {certificate})")
                })
                .collect();
            answer(lines_or(&lines, "(none)"), json!({"count": items.len()}))
        }
        Found::Publications { items } => {
            let lines: Vec<String> = items
                .iter()
                .map(|p| {
                    let name = get(p, "hostname").or_else(|| get(p, "id")).unwrap_or("(unnamed)");
                    let state = get(p, "state").unwrap_or("unknown");
                    let access = get(p, "accessMode")
                        .map(|mode| format!(", access: {mode}"))
                        .unwrap_or_default();
                    format!("{name} ({state}{access})")
                })
                .collect();
            answer(lines_or(&lines, "(none)"), json!({"count": items.len()}))
        }
        Found::ApiKeys { items } => {
            let lines: Vec<String> = items
                .iter()
                .map(|k| {
                    format!(
                        "{} {} (…{})",
                        get(k, "id").unwrap_or(""),
                        get(k, "name").unwrap_or(""),
                        get(k, "hint").unwrap_or("")
                    )
                })
                .collect();
            answer(lines_or(&lines, "(none)"), json!({"count": items.len()}))
        }
        Found::Networks { items } => {
            let lines: Vec<String> = items
                .iter()
                .map(|n| {
                    [
                        get(n, "id").unwrap_or("").to_owned(),
                        format!("({})", get(n, "scope").unwrap_or("")),
                        get(n, "cidr").unwrap_or("").to_owned(),
                    ]
                    .join(" ")
                })
                .collect();
            answer(lines.join("\n"), json!({"count": items.len()}))
        }
        Found::Ports { machine_id, ports } => {
            let listed: Vec<String> = ports.iter().map(i64::to_string).collect();
            Answer {
                text: (!ports.is_empty()).then(|| listed.join("\n")),
                copyable: !ports.is_empty(),
                fields: object(json!({"machine_id": machine_id, "ports": listed.join(",")})),
            }
        }
        Found::PortList { machine_id, forwards } => {
            let forwards: Vec<Fields> = forwards.iter().map(forward_fields).collect();
            let lines: Vec<String> = forwards
                .iter()
                .filter_map(|f| {
                    Some(format!("{} -> {}", f.get("port")?.as_i64()?, f.get("url")?.as_str()?))
                })
                .collect();
            Answer {
                text: (!lines.is_empty()).then(|| lines.join("\n")),
                copyable: true,
                fields: object(json!({"machine_id": machine_id, "forwards": forwards})),
            }
        }
        Found::Tools { machine_id, exit_code, stdout } => {
            answer(stdout.clone(), json!({"machine_id": machine_id, "exit_code": exit_code}))
        }
    }
}

/// A forward record of `cloud.port.list` / `cloud.port.forward` as result fields.
#[allow(
    clippy::cast_possible_truncation,
    reason = "ports arrive as JSON numbers; a whole port number converts exactly"
)]
pub fn forward_fields(record: &Value) -> Fields {
    let mut fields = Fields::new();
    if let Some(machine) = get(record, "machine") {
        fields.insert("machine_id".into(), json!(machine));
    }
    if let Some(port) = record.get("port").and_then(Value::as_f64) {
        fields.insert("port".into(), json!(port as i64));
    }
    if let Some(local) = record.get("localPort").and_then(Value::as_f64) {
        let local = local as i64;
        fields.insert("local_port".into(), json!(local));
        fields.insert("url".into(), json!(format!("http://127.0.0.1:{local}/")));
    }
    for name in ["state", "reason"] {
        if let Some(value) = get(record, name) {
            fields.insert(name.into(), json!(value));
        }
    }
    fields
}

/// `cloud port-forward`'s answer: the forward, whose `url` is the text. A forward with no local
/// port is refused.
pub fn forward(record: &Value, names: &PortNames) -> Result<Answer, Said> {
    let fields = forward_fields(record);
    let url = fields
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| names.said("portFailed", &["no local port"]))?;
    Ok(Answer { text: Some(url.to_owned()), copyable: true, fields })
}

/// The platform's share link of a port (`url`, `linkId`, `expiresAt`).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShareLink {
    pub url: String,
    pub link_id: String,
    pub expires_at: i64,
}

/// `cloud machine-link`: the machine's target and address (its text: the address, else the
/// target); with a port, its private URL and the platform's share `link`, whose URL is the text.
/// A port on a machine whose provider opens no port links, or with no link to give, is refused
/// as `noLink` with the machine and port named.
pub fn machine_link(
    names: &PortNames,
    ipv4: Option<&str>,
    allows_ports: bool,
    link: Option<&ShareLink>,
) -> Result<Answer, Said> {
    let machine_id = names.id.as_str();
    let mut fields =
        object(json!({"machine_id": machine_id, "target": format!("machine:{machine_id}")}));
    let Some(port) = names.port else {
        if let Some(address) = ipv4 {
            fields.insert("address".into(), json!(address));
        }
        let text = ipv4.map_or_else(|| format!("machine:{machine_id}"), str::to_owned);
        return Ok(Answer { text: Some(text), copyable: true, fields });
    };
    machine_link_port(names, allows_ports)?;
    let link = link.ok_or_else(|| names.said("portNoLink", &[]))?;
    fields.insert("port".into(), json!(port));
    if let Some(address) = ipv4 {
        fields.insert("private_url".into(), json!(format!("http://{address}:{port}")));
    }
    fields.insert("url".into(), json!(link.url));
    fields.insert("linkId".into(), json!(link.link_id));
    fields.insert("expiresAt".into(), json!(link.expires_at));
    Ok(Answer { text: Some(link.url.clone()), copyable: true, fields })
}

/// Whether `machine-link --port` may ask the platform for a share link: only on a machine whose
/// provider opens port links (else `portNoLink`). The app asks before it makes the link.
pub fn machine_link_port(names: &PortNames, allows_ports: bool) -> Result<(), Said> {
    if allows_ports { Ok(()) } else { Err(names.said("portNoLink", &[])) }
}

/// Whether a platform share link may be handed out: a URL as the app's URL parser reads one
/// (RFC 3986 characters only, every `%` escape whole, a host that is a name or a closed IPv6
/// literal, a numeric port), `https`, with no user or password.
pub fn share_link_ok(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else { return false };
    if !scheme.eq_ignore_ascii_case("https") || !url.chars().all(is_url_character) {
        return false;
    }
    if !escapes_whole(url) {
        return false;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') {
        return false;
    }
    let (host, port) = if let Some(literal) = authority.strip_prefix('[') {
        let Some((inside, after)) = literal.split_once(']') else { return false };
        let ipv6 = inside.contains(':')
            && inside.chars().all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.');
        if !ipv6 {
            return false;
        }
        match after {
            "" => (inside, None),
            _ => match after.strip_prefix(':') {
                Some(port) => (inside, Some(port)),
                None => return false,
            },
        }
    } else {
        match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    let host_ok = !host.is_empty()
        && (authority.starts_with('[')
            || host.chars().all(|c| c.is_ascii_alphanumeric() || "-._~!$&'()*+,;=%".contains(c)));
    host_ok && port.is_none_or(|port| !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()))
}

/// RFC 3986's characters: unreserved, reserved and `%`.
fn is_url_character(c: char) -> bool {
    c.is_ascii_alphanumeric() || "-._~:/?#[]@!$&'()*+,;=%".contains(c)
}

/// Every `%` followed by two hex digits.
fn escapes_whole(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.iter().enumerate().filter(|&(_, &byte)| byte == b'%').all(|(at, _)| {
        bytes
            .get(at.saturating_add(1)..at.saturating_add(3))
            .is_some_and(|hex| hex.iter().all(u8::is_ascii_hexdigit))
    })
}

/// What `cmux vm tools` runs: the login shell, where each common tool is (or "missing"), and the
/// zsh and gh versions.
pub const TOOLS_PROBE: &str = concat!(
    "printf 'shell: '; printf '%s\\n' \"$SHELL\"; ",
    "for tool in zsh git gh htop btop node bun python3; do if command -v \"$tool\" >/dev/null 2>&1; then printf '%-8s %s\\n' \"$tool\" \"$(command -v \"$tool\")\"; else printf '%-8s missing\\n' \"$tool\"; fi; done; ",
    "zsh --version 2>/dev/null || true; ",
    "gh --version 2>/dev/null | head -n 1 || true"
);

#[cfg(test)]
#[path = "answers/tests.rs"]
mod tests;
