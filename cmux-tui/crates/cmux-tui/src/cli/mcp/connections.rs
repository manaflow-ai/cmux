//! `cmux mcp ls|tools NAME|audit|rm|auth|key|policy|approve-tools`: the person's MCP server
//! connections (plans/cmux-next/mcp-connect-DESIGN.md row 3c), through the app, which relays to
//! its acpmux on the person's line.
//!
//! An agent can run the CLI, so the CLI never adds trust. `ls`, `tools NAME` and `audit` read;
//! `rm` removes a connection (less access); `auth`, `key`, `policy` and `approve-tools` change
//! nothing: they open Settings > MCP Servers at the connection, where the person clicks. Approving
//! held tools (new or changed after a key or a sign-in) adds trust, so only the person's click in
//! Settings sends `_acpmux/mcp_approve_tools`. The CLI never takes a key as an argument, so a key
//! cannot reach a shell history or an agent's transcript.

use std::time::Duration;

use serde_json::{Value, json};

use super::messages::messages;

/// How long the app may take: it opens a person line to acpmux for each request.
pub(super) const TIMEOUT: Duration = Duration::from_secs(25);

/// What Settings must show when the CLI may not act itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Handoff {
    /// Sign in again (OAuth).
    Auth,
    /// Give or replace a key.
    Key,
    /// Change a tool's policy.
    Policy,
    /// Approve the tools held after they changed.
    ApproveTools,
}

/// One `cmux mcp` connection command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Command {
    List,
    Tools(String),
    Audit { limit: Option<u64> },
    Remove(String),
    Open { name: String, handoff: Handoff },
}

/// The command `args` (after `mcp`) names, `None` when they are not a connection command
/// (`serve`, a bare `tools`), or a usage error. Never echoes an argument after `key NAME`: it
/// may be a key.
pub(super) fn parse(args: &[String]) -> Option<Result<Command, String>> {
    let text = messages();
    let (verb, rest) = args.split_first()?;
    let name = |rest: &[String]| match rest {
        [name] if !name.trim().is_empty() && !name.starts_with('-') => Ok(name.trim().to_owned()),
        _ => Err(text.connections_usage.to_owned()),
    };
    Some(match verb.as_str() {
        "ls" | "list" if rest.is_empty() => Ok(Command::List),
        "ls" | "list" => Err(text.connections_usage.to_owned()),
        "tools" if rest.is_empty() => return None,
        "tools" => name(rest).map(Command::Tools),
        "audit" => match rest {
            [] => Ok(Command::Audit { limit: None }),
            [flag, value] if flag == "--limit" => value
                .parse::<u64>()
                .ok()
                .filter(|limit| (1..=1000).contains(limit))
                .map(|limit| Command::Audit { limit: Some(limit) })
                .ok_or_else(|| text.connections_usage.to_owned()),
            _ => Err(text.connections_usage.to_owned()),
        },
        "rm" | "remove" => name(rest).map(Command::Remove),
        "auth" => name(rest).map(|name| Command::Open { name, handoff: Handoff::Auth }),
        "approve-tools" => {
            name(rest).map(|name| Command::Open { name, handoff: Handoff::ApproveTools })
        }
        "key" => match rest {
            [only] => name(std::slice::from_ref(only))
                .map(|name| Command::Open { name, handoff: Handoff::Key }),
            [_, _, ..] => Err(text.key_not_taken.to_owned()),
            [] => Err(text.connections_usage.to_owned()),
        },
        // `policy NAME [TOOL always|ask|never]`: the tool and policy are only what the person
        // means to change; Settings does it on their click.
        "policy" => match rest {
            [] => Err(text.connections_usage.to_owned()),
            [name, ..] => {
                let name = name.trim();
                if name.is_empty() || name.starts_with('-') {
                    Err(text.connections_usage.to_owned())
                } else {
                    Ok(Command::Open { name: name.to_owned(), handoff: Handoff::Policy })
                }
            }
        },
        _ => return None,
    })
}

/// What a command printed: the JSON value, and the human text.
#[derive(Debug, PartialEq)]
pub(super) struct Outcome {
    pub json: Value,
    pub human: String,
}

/// Runs `command` through `call` (an app control method and its params, answering its result
/// or the app's error). Only `rm` and `open` change anything, and `open` changes no trust.
pub(super) fn execute(
    command: &Command,
    call: &mut dyn FnMut(&str, Value) -> Result<Value, Value>,
) -> Result<Outcome, Value> {
    let text = messages();
    match command {
        Command::List => {
            let listed = call("mcp.servers.list", json!({}))?;
            Ok(Outcome { human: list_text(&listed), json: listed })
        }
        Command::Tools(name) => {
            let listed = call("mcp.servers.list", json!({}))?;
            let row = find(&listed, name)?;
            let tools = row.get("tools").cloned().unwrap_or_else(|| json!([]));
            let held = held_names(row);
            let mut human = String::new();
            for tool in tools.as_array().into_iter().flatten() {
                let name = field(tool, "name").as_str().unwrap_or_default();
                let mark = if held.contains(&name) { text.held_mark } else { "" };
                human.push_str(&format!(
                    "{}\t{}{}\n",
                    name,
                    field(tool, "policy").as_str().unwrap_or("ask"),
                    mark
                ));
            }
            if human.is_empty() {
                human = format!("{}\n", text.no_tools);
            }
            Ok(Outcome {
                json: json!({
                    "id": field(row, "id"),
                    "name": field(row, "name"),
                    "tools": tools,
                    "held": held,
                }),
                human,
            })
        }
        Command::Audit { limit } => {
            let params = limit.map_or_else(|| json!({}), |limit| json!({"limit": limit}));
            let audit = call("mcp.servers.audit", params)?;
            let mut human = String::new();
            for line in field(&audit, "lines").as_array().into_iter().flatten() {
                human.push_str(&line.to_string());
                human.push('\n');
            }
            if human.is_empty() {
                human = format!("{}\n", text.audit_empty);
            }
            Ok(Outcome { json: audit, human })
        }
        Command::Remove(name) => {
            let removed = call("mcp.servers.remove", json!({"connection": name}))?;
            let shown = field(&removed, "name").as_str().unwrap_or(name);
            Ok(Outcome {
                human: format!("{}\n", text.removed.replace("{name}", shown)),
                json: removed,
            })
        }
        Command::Open { name, handoff } => {
            // Resolve first, so an unknown name fails here instead of opening an empty page.
            let listed = call("mcp.servers.list", json!({}))?;
            let row = find(&listed, name)?;
            let id = field(row, "id").as_str().unwrap_or_default().to_owned();
            let shown = field(row, "name").as_str().unwrap_or(name).to_owned();
            call("mcp.servers.open", json!({"connection": id, "focus": true}))?;
            let line = match handoff {
                Handoff::Auth => text.opened_auth,
                Handoff::Key => text.opened_key,
                Handoff::Policy => text.opened_policy,
                Handoff::ApproveTools => text.opened_approve_tools,
            };
            Ok(Outcome {
                json: json!({"opened": "settings.mcpServers", "id": id, "name": shown}),
                human: format!("{}\n", line.replace("{name}", &shown)),
            })
        }
    }
}

/// `value`'s member `key`, or null (no index: the panic ratchet counts `value[key]`).
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

/// The tools of `row` that wait for the person's approval (its `held` list; none from an older
/// daemon).
fn held_names(row: &Value) -> Vec<&str> {
    field(row, "held").as_array().into_iter().flatten().filter_map(Value::as_str).collect()
}

/// The row `reference` names in a `mcp.servers.list` result: its name (any case) or its id.
fn find<'a>(listed: &'a Value, reference: &str) -> Result<&'a Value, Value> {
    field(listed, "connections")
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| {
            field(row, "id").as_str() == Some(reference)
                || field(row, "name")
                    .as_str()
                    .is_some_and(|name| name.eq_ignore_ascii_case(reference))
        })
        .ok_or_else(|| {
            json!({
                "code": "not_found",
                "message": messages().not_found.replace("{name}", reference),
                "details": {},
            })
        })
}

/// One line per connection: name, state, scope, publisher and whether it is verified, tool count,
/// URL.
fn list_text(listed: &Value) -> String {
    let text = messages();
    let rows = field(listed, "connections").as_array().map(Vec::as_slice).unwrap_or_default();
    if rows.is_empty() {
        return format!("{}\n", text.no_connections);
    }
    let mut out = String::new();
    for row in rows {
        let verified = if field(row, "verified").as_bool() == Some(true) {
            text.verified
        } else {
            text.unverified
        };
        let tools = field(row, "tools").as_array().map_or(0, Vec::len);
        let held = held_names(row).len();
        let held = if held == 0 {
            String::new()
        } else {
            format!(", {}", text.held_count.replace("{count}", &held.to_string()))
        };
        out.push_str(&format!(
            "{}\t{}\t{}\t{} ({})\t{}{}\t{}\n",
            field(row, "name").as_str().unwrap_or_default(),
            field(row, "state").as_str().unwrap_or_default(),
            field(row, "scope").as_str().unwrap_or_default(),
            field(row, "publisher").as_str().unwrap_or_default(),
            verified,
            text.tool_count.replace("{count}", &tools.to_string()),
            held,
            field(row, "url").as_str().unwrap_or_default(),
        ));
    }
    out
}
