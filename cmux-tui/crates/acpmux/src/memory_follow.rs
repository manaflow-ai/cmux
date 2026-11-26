//! A chat's agent memory follows it when it moves (RFD 0167 row 17, "Memory shared by local and
//! cloud"). Before this, a chat moved from a Mac with `agents.memory.enabled` to a Cloud machine
//! or a peer whose settings file has no `agents.memory` keys started there with no
//! `cmux-agent-memory` server at all, and a target that had memory on searched its own index, not
//! the owner the chat used.
//!
//! - The source's `transfer_begin` answer (the move's manifest) carries [`MANIFEST_FIELD`]:
//!   `{owner, ownerArgs}` as the chat used memory there ([`outgoing`]). `owner` is the source's
//!   `agents.memory.owner`, else the owner the chat itself followed in with, else the source's
//!   own route back ([`route_back`]): a Mac that holds the index (memory on, no owner set, the
//!   common case) names its cmux-tui remote daemon through the hub carrier, `ws://127.0.0.1:PORT`
//!   `--via-machine KEY`, the route the person's other machines already use to reach it. A source
//!   that serves no remote daemon (`remoteDaemon` unset) or runs no carrier sends null: the target
//!   then searches its own index, which `cmux link memory` keeps carrying the files to.
//! - The target's `transfer_finish` records it in the chat's session env as daemon-set keys no
//!   client may send ([`apply`]; `session_env.rs` allows none of them): [`FOLLOWS_ENV`], and
//!   [`OWNER_ENV`] and [`OWNER_ARGS_ENV`] when there is an owner. Every spawn applies that env.
//! - `AgentTools::scoped` gives such a chat the memory server even when this machine's settings
//!   name no memory, and the owner's route in the server's env, which `optchat-chief agent-memory`
//!   uses when this machine's own `agents.memory.owner` is unset (its settings win).
//!
//! A machine whose settings say `agents.memory.enabled: false` keeps memory off for every chat
//! there, moved ones too: the person's switch on that machine wins.

use std::collections::BTreeMap;

use serde_json::{Value, json};

/// The manifest field a move carries.
pub const MANIFEST_FIELD: &str = "agentMemory";
/// `1`: the chat had memory where it came from.
pub const FOLLOWS_ENV: &str = "CMUX_AGENT_MEMORY_FOLLOWS";
/// The owner's `cmux remote` route the chat used (optchat-chief `agent_memory/settings.rs`).
pub const OWNER_ENV: &str = "CMUX_AGENT_MEMORY_OWNER";
/// That route's options, a JSON array of strings.
pub const OWNER_ARGS_ENV: &str = "CMUX_AGENT_MEMORY_OWNER_ARGS";

/// Longest route or option kept.
const MAX_TEXT: usize = 512;
/// Most route options kept.
const MAX_ARGS: usize = 16;

/// The memory a chat brought with it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Followed {
    pub owner: Option<String>,
    pub owner_args: Vec<String>,
}

/// `agents.memory.enabled` in `settings`: `Some(true)` or `Some(false)` only for a literal bool.
pub fn enabled(settings: Option<&str>) -> Option<bool> {
    let doc = crate::user_settings::document(settings?)?;
    crate::user_settings::value(&doc, "agents.memory.enabled")?.as_bool()
}

fn local_owner(settings: Option<&str>) -> Option<Followed> {
    let doc = crate::user_settings::document(settings?)?;
    let owner = crate::user_settings::value(&doc, "agents.memory.owner")?;
    let owner = clean(owner.as_str()?)?;
    let owner_args = match crate::user_settings::value(&doc, "agents.memory.ownerArgs") {
        Some(Value::Array(items)) => items.iter().filter_map(|v| clean(v.as_str()?)).collect(),
        _ => Vec::new(),
    };
    Some(Followed { owner: Some(owner), owner_args })
}

fn clean(text: &str) -> Option<String> {
    let text = text.trim();
    (!text.is_empty() && text.len() <= MAX_TEXT && !text.chars().any(char::is_control))
        .then(|| text.to_owned())
}

/// What this chat brought in (its session env), if it brought memory.
pub fn followed(session_env: &BTreeMap<String, String>) -> Option<Followed> {
    if session_env.get(FOLLOWS_ENV).map(String::as_str) != Some("1") {
        return None;
    }
    let owner = session_env.get(OWNER_ENV).and_then(|o| clean(o));
    let owner_args = owner
        .as_ref()
        .and_then(|_| session_env.get(OWNER_ARGS_ENV))
        .and_then(|a| serde_json::from_str::<Vec<String>>(a).ok())
        .unwrap_or_default();
    Some(Followed { owner, owner_args })
}

/// This machine as the owner of its own index, reached from the person's other machines: its
/// cmux-tui remote daemon (`remote_daemon`, the config's loopback `remoteDaemon`) through the hub
/// carrier whose node key is `carrier_key` (`cmux remote rpc ws://ADDR --via-machine KEY`,
/// `cmux_tui_service.rs`). None without both.
pub fn route_back(remote_daemon: Option<&str>, carrier_key: Option<&str>) -> Option<Followed> {
    let address = crate::config::loopback_daemon_address(remote_daemon?).ok()?;
    let key = clean(carrier_key?)?;
    Some(Followed {
        owner: Some(format!("ws://{address}/v1/link")),
        owner_args: vec!["--via-machine".to_owned(), key],
    })
}

/// The manifest field for a chat leaving this machine, from this machine's `settings`, the
/// chat's own session env and this machine's [`route_back`] (`here`); `None` when the chat had
/// no memory here.
pub fn outgoing(
    settings: Option<&str>,
    session_env: &BTreeMap<String, String>,
    here: Option<Followed>,
) -> Option<Value> {
    let brought = followed(session_env);
    let carried = match enabled(settings) {
        Some(false) => return None,
        Some(true) => local_owner(settings)
            .or_else(|| brought.filter(|b| b.owner.is_some()))
            .or(here)
            .unwrap_or_default(),
        None => brought?,
    };
    Some(json!({"owner": carried.owner, "ownerArgs": carried.owner_args}))
}

/// The field as a move's manifest holds it, checked: a route and options of plain text, at most
/// [`MAX_ARGS`] options. Anything else is no memory.
pub fn parse(field: &Value) -> Option<Followed> {
    let field = field.as_object()?;
    let owner = match field.get("owner") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(clean(s)?),
        Some(_) => return None,
    };
    let owner_args = match field.get("ownerArgs") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) if items.len() <= MAX_ARGS => {
            items.iter().map(|v| clean(v.as_str()?)).collect::<Option<Vec<_>>>()?
        }
        Some(_) => return None,
    };
    let owner_args = if owner.is_some() { owner_args } else { Vec::new() };
    Some(Followed { owner, owner_args })
}

/// Records what the move's `manifest` carried in the chat's session env, replacing whatever the
/// bundle held: the move's own answer decides.
pub fn apply(session_env: &mut BTreeMap<String, String>, manifest: &Value) {
    for key in [FOLLOWS_ENV, OWNER_ENV, OWNER_ARGS_ENV] {
        session_env.remove(key);
    }
    let Some(followed) = manifest.get(MANIFEST_FIELD).and_then(parse) else { return };
    session_env.insert(FOLLOWS_ENV.to_owned(), "1".to_owned());
    if let Some(owner) = followed.owner {
        session_env.insert(OWNER_ENV.to_owned(), owner);
        if !followed.owner_args.is_empty() {
            let args = serde_json::to_string(&followed.owner_args).unwrap_or_default();
            session_env.insert(OWNER_ARGS_ENV.to_owned(), args);
        }
    }
}

/// [`apply`] to a chat's `session.json` as a move's bundle holds it (`sessionEnv`).
pub fn apply_to_meta(meta: &mut Value, manifest: &Value) {
    let Some(meta) = meta.as_object_mut() else { return };
    let mut env: BTreeMap<String, String> = meta
        .get("sessionEnv")
        .and_then(|e| serde_json::from_value(e.clone()).ok())
        .unwrap_or_default();
    apply(&mut env, manifest);
    if env.is_empty() {
        meta.remove("sessionEnv");
    } else {
        meta.insert("sessionEnv".to_owned(), json!(env));
    }
}

/// The memory server's env for a chat that brought an owner.
pub fn server_env(followed: &Followed) -> Vec<(String, String)> {
    let Some(owner) = &followed.owner else { return Vec::new() };
    let mut env = vec![(OWNER_ENV.to_owned(), owner.clone())];
    if !followed.owner_args.is_empty() {
        let args = serde_json::to_string(&followed.owner_args).unwrap_or_default();
        env.push((OWNER_ARGS_ENV.to_owned(), args));
    }
    env
}

#[cfg(test)]
#[path = "memory_follow_tests.rs"]
mod tests;
