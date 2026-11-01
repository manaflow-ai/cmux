//! `cmux agents chat steer|rename|set|close|move` and their MCP tools (#27879): the rest of what
//! a person does to a chat in the GUI, so an agent (a Chief turn, a script) drives a chat it
//! started the same way.
//!
//! - `steer` sends text into the running turn, as the composer's Steer does
//!   (`_meta.acpmux.steer`); with no running turn it runs next. It goes in as this agent's
//!   message (`kind: agent_message` provenance), never as the person's words.
//! - `rename` names the chat's tabs, as a tab's Rename does, and acpmux's own name for it
//!   (`_acpmux/rename`) when the name is one acpmux takes (`session_name.rs`).
//! - `set` changes its model (`session/set_model`), effort (`session/set_config_option`
//!   `effort`) or mode (`session/set_mode`), as its pickers do. acpmux decides whether this
//!   caller may widen a mode (`hub/person.rs`): an agent never widens one past its own.
//! - `close` closes every tab of the app that shows the chat, as a person closes a tab; the
//!   chat keeps running and stays in All Chats.
//! - `move` moves that tab to another workspace's first screen.
//!
//! Each reaches only chats of this cmux session (`chat::scoped_chat`), as `send` does; `steer`
//! never reaches the caller's own chat.

use serde_json::{Value, json};

use super::super::command::CommandPlan;
use super::super::mcp::{self, CallFailure, FailureKind};
use super::super::{GlobalArgs, Surface, UsageError, wire};
use super::chat;

/// `chat set <chat>` flags: at least one of them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct ChatSettings {
    pub target: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: Option<String>,
}

/// `chat set <chat> [--model M] [--effort E] [--mode M]` (the words after the chat).
pub(in crate::cli) fn parse_set(
    target: String,
    words: &[&str],
) -> Result<ChatSettings, UsageError> {
    let mut settings = ChatSettings { target, ..ChatSettings::default() };
    let mut index = 0;
    while let Some(&word) = words.get(index) {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (word, None),
        };
        let value = match inline {
            Some(value) => value,
            None => {
                index += 1;
                *words.get(index).ok_or_else(|| {
                    UsageError::new(format!("agents chat set: {flag} needs a value"))
                })?
            }
        };
        if value.is_empty() {
            return Err(UsageError::new(format!("agents chat set: {flag} needs a value")));
        }
        let slot = match flag {
            "--model" => &mut settings.model,
            "--effort" => &mut settings.effort,
            "--mode" => &mut settings.mode,
            other => {
                return Err(UsageError::new(format!(
                    "agents chat set: unknown flag {other:?}; use --model, --effort or --mode"
                )));
            }
        };
        *slot = Some(value.to_owned());
        index += 1;
    }
    if settings.model.is_none() && settings.effort.is_none() && settings.mode.is_none() {
        return Err(UsageError::new("agents chat set: give --model, --effort or --mode"));
    }
    Ok(settings)
}

fn not_run(code: &str, message: impl Into<String>) -> CallFailure {
    CallFailure {
        kind: FailureKind::NotRun,
        error: json!({"code": code, "message": message.into(), "details": {}, "retryable": false}),
        idempotency_key: None,
    }
}

fn receipt(action: &str, origin: &str, result: Value) -> Value {
    json!({"schema_version": 1, "action": action, "origin": origin, "result": result})
}

/// The provenance of a steer this caller sends: its own chat when it runs in one, else the
/// cmux CLI; `id` is the prompt's id and its thread.
fn steer_provenance(chat: &str, id: &str) -> Value {
    let from = ["CMUX_AGENT_SESSION", "ACPMUX_SESSION_ID"]
        .into_iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.trim().is_empty()))
        .map_or_else(|| "cmux-cli".to_owned(), |own| format!("acp:{own}"));
    let mut provenance = json!({"kind": "agent_message", "from": from, "to": format!("acp:{chat}"),
                                "msgId": id, "threadId": id});
    if let Some(name) = std::env::var("ACPMUX_SESSION_NAME")
        .ok()
        .map(|name| name.chars().take(64).collect::<String>())
        .filter(|name| !name.trim().is_empty() && !name.contains('\n'))
    {
        cmux_json::JsonSet::set(&mut provenance, "fromName", json!(name));
    }
    provenance
}

pub(in crate::cli) fn steer(
    global: &GlobalArgs,
    target: &str,
    text: &str,
    idempotency_key: Option<&str>,
    origin: &str,
) -> Result<Value, CallFailure> {
    let found = chat::scoped_chat(global, target)?;
    chat::refuse_own_chat(&found.id, target)?;
    let id = match idempotency_key {
        Some(key) => key.to_owned(),
        None => uuid::Uuid::new_v4().to_string(),
    };
    let provenance = steer_provenance(&found.id, &id);
    chat::acp::prompt(&found.id, text, &id, Some(&provenance), found.socket(), true).map_err(
        |error| CallFailure {
            kind: FailureKind::InProgress,
            error: json!({"code": "chat.unavailable",
                          "message": format!("cannot steer {}: {error}", found.id),
                          "details": {}, "retryable": true}),
            idempotency_key: Some(id.clone()),
        },
    )?;
    let mut value = receipt(
        "chat.steer",
        origin,
        json!({"chat": found.id, "prompt_id": id,
                                                          "state": "accepted"}),
    );
    cmux_json::JsonSet::set(&mut value, "idempotency_key", json!(id));
    Ok(value)
}

pub(in crate::cli) fn rename(
    global: &GlobalArgs,
    target: &str,
    name: &str,
    origin: &str,
) -> Result<Value, CallFailure> {
    let found = chat::scoped_chat(global, target)?;
    // The name a person sees: each tab that shows the chat, as the tab's Rename does
    // (`rename-surface`). No app, or no tab yet: none.
    let mut tabs = Vec::new();
    if let Ok(app) =
        mcp::agent_app(global, "snapshot.get", json!({}), super::super::app::READ_TIMEOUT, None)
    {
        chat_tabs(&app["topology"], &found.id, &mut tabs);
    }
    for tab in &tabs {
        resource_change(global, &["tab".into(), tab.clone(), "rename".into(), name.to_owned()])?;
    }
    // acpmux's own name (`acpmux attach NAME`, the list row) takes only a word safe for a shell
    // (`session_name.rs`); "27879: helper" stays the tabs' name alone.
    let session_name = acpmux::session_name::validate(name).is_ok();
    if session_name {
        chat::acp::call(
            acpmux::rpc::method::MUX_RENAME,
            json!({"sessionId": found.id, "newName": name}),
            found.socket(),
        )
        .map_err(|error| {
            not_run("chat.unavailable", format!("cannot rename {}: {error}", found.id))
        })?;
    } else if tabs.is_empty() {
        return Err(not_run(
            "chat.no_tab",
            format!(
                "no tab shows chat {} and {name:?} is no acpmux session name (letters, digits, \
                 '-', '_' and '.'); open a tab with `cmux agent open {}` first",
                found.id, found.id
            ),
        ));
    }
    Ok(receipt(
        "chat.rename",
        origin,
        json!({"chat": found.id, "name": name, "renamed_tabs": tabs, "session_name": session_name}),
    ))
}

pub(in crate::cli) fn set(
    global: &GlobalArgs,
    settings: &ChatSettings,
    origin: &str,
) -> Result<Value, CallFailure> {
    let found = chat::scoped_chat(global, &settings.target)?;
    let chat = found.id.as_str();
    // The mode's name for this chat's harness (`full-access` included).
    let harness = settings.mode.as_ref().and_then(|_| {
        chat::acp::lookup(chat, found.socket())
            .ok()
            .and_then(|(_, info)| info["harness"].as_str().map(str::to_owned))
    });
    let mode = settings
        .mode
        .as_deref()
        .map(|mode| super::chat_control::harness_mode(mode, harness.as_deref()));
    let mut changes = Vec::new();
    if let Some(model) = &settings.model {
        changes.push((
            "model",
            acpmux::rpc::method::SESSION_SET_MODEL,
            json!({"sessionId": chat, "modelId": model}),
        ));
    }
    if let Some(effort) = &settings.effort {
        changes.push((
            "effort",
            acpmux::rpc::method::SESSION_SET_CONFIG_OPTION,
            json!({"sessionId": chat, "configId": "effort", "value": effort}),
        ));
    }
    if let Some(mode) = &mode {
        changes.push((
            "mode",
            acpmux::rpc::method::SESSION_SET_MODE,
            json!({"sessionId": chat, "modeId": mode}),
        ));
    }
    let mut result = json!({"chat": chat});
    for (field, method, params) in changes {
        let value = params.get("modelId").or(params.get("value")).or(params.get("modeId")).cloned();
        chat::acp::call(method, params, found.socket()).map_err(|error| {
            // What changed before this refusal stays changed; the message says which.
            not_run(
                "chat.set_refused",
                format!("cannot set {field} of {chat}: {error}; set so far: {result}"),
            )
        })?;
        cmux_json::JsonSet::set(&mut result, field, value.unwrap_or(Value::Null));
    }
    Ok(receipt("chat.set", origin, result))
}

/// The ids of the app's tabs that show `chat` (`kind: conversation`, `agent_session`), anywhere
/// in its topology.
fn chat_tabs(topology: &Value, chat: &str, out: &mut Vec<String>) {
    match topology {
        Value::Object(object) => {
            if object.get("kind").and_then(Value::as_str) == Some("conversation")
                && object.get("agent_session").and_then(Value::as_str) == Some(chat)
                && let Some(id) = object.get("id").and_then(Value::as_str)
                && !out.iter().any(|known| known == id)
            {
                out.push(id.to_owned());
            }
            object.values().for_each(|value| chat_tabs(value, chat, out));
        }
        Value::Array(items) => items.iter().for_each(|value| chat_tabs(value, chat, out)),
        _ => {}
    }
}

/// The app's tabs that show the chat `target` names; refused when none does.
fn tabs_of(global: &GlobalArgs, target: &str) -> Result<(String, Vec<String>), CallFailure> {
    let found = chat::scoped_chat(global, target)?;
    let app =
        mcp::agent_app(global, "snapshot.get", json!({}), super::super::app::READ_TIMEOUT, None)
            .map_err(|error| CallFailure {
                kind: FailureKind::NotRun,
                error,
                idempotency_key: None,
            })?;
    let mut tabs = Vec::new();
    chat_tabs(&app["topology"], &found.id, &mut tabs);
    if tabs.is_empty() {
        return Err(not_run(
            "chat.no_tab",
            format!("no tab shows chat {}; open one with `cmux agent open {}`", found.id, found.id),
        ));
    }
    Ok((found.id, tabs))
}

/// One daemon change, from the words of a `cmux` resource command.
fn resource_change(global: &GlobalArgs, words: &[String]) -> Result<Value, CallFailure> {
    let mut plan = match super::super::command::parse(words, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) | Err(_) => return Err(not_run("usage.invalid", format!("cannot run {words:?}"))),
    };
    plan.idempotency_key =
        Some(wire::random_idempotency_key().map_err(|error| not_run("usage.invalid", error.0))?);
    mcp::agent_resource(global, plan).map_err(|error| CallFailure {
        kind: FailureKind::NotRun,
        error,
        idempotency_key: None,
    })
}

pub(in crate::cli) fn close(
    global: &GlobalArgs,
    target: &str,
    origin: &str,
) -> Result<Value, CallFailure> {
    let (chat, tabs) = tabs_of(global, target)?;
    for tab in &tabs {
        resource_change(global, &["tab".into(), tab.clone(), "close".into()])?;
    }
    Ok(receipt("chat.close", origin, json!({"chat": chat, "closed_tabs": tabs})))
}

pub(in crate::cli) fn move_to(
    global: &GlobalArgs,
    target: &str,
    workspace: &str,
    origin: &str,
) -> Result<Value, CallFailure> {
    let (chat, tabs) = tabs_of(global, target)?;
    let snapshot = mcp::agent_resource(global, super::snapshot_plan())
        .map_err(|error| CallFailure { kind: FailureKind::NotRun, error, idempotency_key: None })?;
    let list = |name: &str| snapshot[name].as_array().cloned().unwrap_or_default();
    let workspaces = list("workspaces");
    let found = workspaces
        .iter()
        .find(|item| item["id"] == workspace)
        .or_else(|| {
            let named: Vec<&Value> =
                workspaces.iter().filter(|item| item["name"] == workspace).collect();
            (named.len() == 1).then(|| named[0])
        })
        .and_then(|item| item["id"].as_str().map(str::to_owned))
        .ok_or_else(|| {
            not_run(
                "selector.not_found",
                format!("no workspace {workspace:?} in this cmux session"),
            )
        })?;
    let screen = list("screens")
        .iter()
        .find(|screen| screen["workspace_id"] == found.as_str())
        .and_then(|screen| screen["id"].as_str().map(str::to_owned))
        .ok_or_else(|| not_run("selector.not_found", format!("workspace {found} has no screen")))?;
    // The chat's first tab moves; another tab of it stays where the person put it.
    let tab = &tabs[0];
    resource_change(
        global,
        &[
            "tab".into(),
            tab.clone(),
            "move".into(),
            "--workspace".into(),
            found.clone(),
            "--screen".into(),
            screen.clone(),
        ],
    )?;
    Ok(receipt(
        "chat.move",
        origin,
        json!({"chat": chat, "tab": tab, "workspace": found,
                                            "screen": screen}),
    ))
}

#[cfg(test)]
mod tests {
    use super::{chat_tabs, parse_set};
    use serde_json::json;

    #[test]
    fn set_needs_a_change_and_reads_each_flag() {
        assert!(parse_set("c".into(), &[]).is_err());
        let set = parse_set("c".into(), &["--model", "claude-opus-5-5", "--effort=high"]).unwrap();
        assert_eq!(set.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(set.effort.as_deref(), Some("high"));
        assert_eq!(set.mode, None);
        assert!(parse_set("c".into(), &["--policy", "ask"]).is_err());
    }

    #[test]
    fn a_chat_s_tabs_are_found_anywhere_in_the_topology() {
        let topology = json!({"windows": [{"panes": [{"tabs": [
            {"id": "tab_a", "kind": "conversation", "agent_session": "s1"},
            {"id": "tab_b", "kind": "browser"},
            {"id": "tab_c", "kind": "conversation", "agent_session": "s2"},
        ]}]}, {"tabs": [{"id": "tab_d", "kind": "conversation", "agent_session": "s1"}]}]});
        let mut tabs = Vec::new();
        chat_tabs(&topology, "s1", &mut tabs);
        assert_eq!(tabs, ["tab_a", "tab_d"]);
    }
}
