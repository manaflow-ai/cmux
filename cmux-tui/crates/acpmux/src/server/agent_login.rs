//! `_acpmux/agent_login/start|finish|cancel|api_key` (`crate::agent_login`):
//! the chat's sign-in card runs the agent's own sign-in on the machine this
//! daemon runs on. Part of the request handler (`requests.rs`).
//!
//! Who may ask: this machine's unix socket and app, and the owner's own peer
//! daemon (the person's Mac, forwarding its app's card for a chat that lives
//! here: `vm_boundary::owner`). Never a Web client, a paired device, or a peer
//! forwarding for one: the sign-in becomes this machine's, for every chat on
//! it. The program is always the agent's own CLI; nothing the caller sends
//! names a program, path or env.
//!
//! A request that names a chat (`sessionId`) is forwarded whole to the peer
//! the chat lives on (`peer_forward.rs`), so the card names its chat on every
//! call and the sign-in runs on the chat's machine. After a sign-in, a named
//! chat's agent restarts now when it is between turns (`restarted`), so its
//! next prompt uses the new sign-in; in a turn it restarts when the turn ends
//! (`restarted: false`), never cutting the turn.

use super::{Conn, Origin};
use crate::agent_login::{self as login, Agent, Cli, LoginError, Machine, reason};
use crate::config::{Config, HarnessKind, HarnessProfile};
use crate::hub::{Control, Hub};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The methods `handle` answers.
pub(super) const METHODS: &[&str] = &[
    method::MUX_AGENT_LOGIN_START,
    method::MUX_AGENT_LOGIN_FINISH,
    method::MUX_AGENT_LOGIN_CANCEL,
    method::MUX_AGENT_LOGIN_API_KEY,
];

/// `error.data.reason` when a caller that is not the person's own asks.
pub const REMOTE_REFUSED: &str = "remote_refused";

fn error(e: LoginError) -> RpcError {
    let code = match e.reason {
        reason::UNSUPPORTED_AGENT
        | reason::BAD_CODE
        | reason::UNKNOWN_LOGIN
        | reason::UNKNOWN_SESSION => -32602,
        _ => -32000,
    };
    RpcError::new(code, e.message).with_data(json!({"reason": e.reason}))
}

fn agent_of(params: &Value) -> Result<Agent, RpcError> {
    let name = params.get("agent").and_then(Value::as_str).unwrap_or_default();
    Agent::parse(name).ok_or_else(|| {
        error(LoginError::new(
            reason::UNSUPPORTED_AGENT,
            format!("agent must be \"claude\" or \"codex\", not {name:?}"),
        ))
    })
}

fn text<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty())
}

/// Whether `conn` may run a sign-in here (module docs).
fn allowed(conn: &Conn, params: &Value) -> bool {
    let control = super::remote_guard::control_of(conn.origin, conn.auth, params);
    match conn.origin {
        Origin::Local | Origin::LocalApp => control == Control::Local,
        Origin::Peer => crate::hub::vm_boundary::owner(conn.auth, control, params),
        Origin::Web => false,
    }
}

/// How this daemon starts `agent` (`crate::agent_login` docs): the `claude`
/// or `codex` harness profile when it runs that CLI itself, else the CLI on
/// the login PATH. The profile's env and Codex's global options come along;
/// values that refer to a secret store are left out (nothing here asks one).
fn cli_for(cfg: &Config, agent: Agent, selected: Option<HarnessProfile>) -> Option<Cli> {
    let cwd = std::env::temp_dir();
    let home = dirs::home_dir().unwrap_or_default();
    let selected = selected.or_else(|| {
        let mut profile = cfg.harnesses.get(agent.name())?.clone();
        let mut env = cfg.defaults_for(agent.name()).env;
        env.extend(profile.env);
        profile.env = env;
        Some(profile)
    });
    let native = |p: &&HarnessProfile| match agent {
        Agent::Claude => p.kind == HarnessKind::ClaudeStdio && p.argv.len() == 1,
        Agent::Codex => crate::codex_app_server::is_profile_launch(&p.argv),
    };
    let profile =
        selected.as_ref().filter(native).or_else(|| cfg.harnesses.get(agent.name()).filter(native));
    let model = cfg.defaults_for(agent.name()).model.unwrap_or_default();
    let expand = |v: &str| crate::hub::expand_env_value(v, &cwd, &home, &model);
    let env: std::collections::BTreeMap<String, String> = selected
        .as_ref()
        .into_iter()
        .flat_map(|p| p.env.iter())
        .map(|(k, v)| (k.clone(), expand(v)))
        .filter(|(_, v)| !v.contains("${"))
        .collect();
    let argv: Vec<String> = match profile {
        Some(p) => p.argv.iter().map(|a| expand(a)).collect(),
        None => vec![crate::config::which(agent.name())?],
    };
    let (command, args) = argv.split_first()?;
    let program = match agent {
        Agent::Codex => env.get("CODEX_PATH").filter(|p| !p.is_empty()).cloned(),
        Agent::Claude => None,
    }
    .unwrap_or_else(|| command.clone());
    let globals = match agent {
        Agent::Codex => crate::cli::harness_login::codex_globals(args).to_vec(),
        Agent::Claude => Vec::new(),
    };
    Some(Cli { program, globals, env })
}

async fn cli(hub: &Hub, agent: Agent, params: &Value) -> Result<(Cli, Option<String>), RpcError> {
    let (selected, route) = match text(params, "sessionId") {
        Some(key) => {
            let session = hub.resolve(key)?;
            let (profile, route) = hub.login_profile(&session, agent.name()).await?;
            (Some(profile), route)
        }
        None => (None, None),
    };
    let cfg = hub.config.read().await;
    cli_for(&cfg, agent, selected).map(|cli| (cli, route)).ok_or_else(|| {
        error(LoginError::new(
            reason::CLI_MISSING,
            format!("{} is not installed on this machine", agent.name()),
        ))
    })
}

fn machine(hub: &Hub) -> Machine {
    Machine { root: hub.vm_marker_root(), home: dirs::home_dir().unwrap_or_default() }
}

/// After a sign-in: the machine's launcher picks the own sign-in, and the
/// named chat's agent restarts (module docs). Whether it restarted now.
async fn signed_in(
    hub: &Arc<Hub>,
    agent: Agent,
    params: &Value,
    store: &std::path::Path,
) -> Result<bool, RpcError> {
    // Finishing a login may name a different chat, or its config may have changed while
    // the browser was open. Never apply one account's success to another account.
    let (current, route) = cli(hub, agent, params).await?;
    if current.store(agent) != store {
        return Err(RpcError::invalid_params(
            "the chat's account changed during sign-in; start again",
        ));
    }
    if let Err(e) = machine(hub).choose_own(agent) {
        tracing::warn!(agent = agent.name(), error = %e, "agent login: record the own sign-in choice");
    }
    hub.login_changed(agent.name(), store, route.as_deref()).await?;
    let Some(key) = text(params, "sessionId") else { return Ok(false) };
    let session = hub.resolve(key)?;
    let ids = std::collections::BTreeSet::from([session.id.clone()]);
    let done = hub.restart_harnesses(None, Some(&ids)).await;
    Ok(done.now > 0)
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if !allowed(conn, params) {
        return Err(RpcError::new(
            -32000,
            "an agent sign-in runs only from this machine, its cmux app, or its owner's own machine",
        )
        .with_data(json!({"reason": REMOTE_REFUSED})));
    }
    // A named chat this daemon does not have: never run the sign-in here in its place (a chat
    // on a peer was forwarded before this; one that resolves nowhere is stale or not mirrored
    // yet, and this machine's own sign-in is not the one asked for).
    // A cancel only stops a sign-in by its id: it always may.
    if m != method::MUX_AGENT_LOGIN_CANCEL
        && let Some(key) = text(params, "sessionId")
        && hub.resolve(key).is_err()
    {
        return Err(error(LoginError::new(
            reason::UNKNOWN_SESSION,
            format!("no chat {key:?} here: open the chat again"),
        )));
    }
    match m {
        method::MUX_AGENT_LOGIN_START => {
            let agent = agent_of(params)?;
            let (cli, _) = cli(hub, agent, params).await?;
            let s = login::start(&machine(hub), &cli, agent).await.map_err(error)?;
            let mut reply = json!({
                "loginId": s.login_id,
                "url": s.url,
                "needsCode": s.needs_code,
                "expiresAtMs": s.expires_at_ms,
            });
            if let (Some(code), Some(obj)) = (s.user_code, reply.as_object_mut()) {
                obj.insert("userCode".into(), json!(code));
            }
            Ok(reply)
        }
        method::MUX_AGENT_LOGIN_FINISH => {
            let id = text(params, "loginId").ok_or_else(|| {
                error(LoginError::new(reason::UNKNOWN_LOGIN, "loginId is required"))
            })?;
            let code = params.get("code").and_then(Value::as_str);
            let done = login::finish(id, code).await.map_err(error)?;
            let restarted =
                done.signed_in && signed_in(hub, done.agent, params, &done.store).await?;
            Ok(json!({"signedIn": done.signed_in, "restarted": restarted}))
        }
        method::MUX_AGENT_LOGIN_CANCEL => {
            let id = text(params, "loginId").ok_or_else(|| {
                error(LoginError::new(reason::UNKNOWN_LOGIN, "loginId is required"))
            })?;
            login::cancel(id);
            Ok(json!({}))
        }
        method::MUX_AGENT_LOGIN_API_KEY => {
            let agent = agent_of(params)?;
            let key = params.get("key").and_then(Value::as_str).unwrap_or_default();
            let (cli, _) = cli(hub, agent, params).await?;
            login::save_api_key(&machine(hub), &cli, agent, key).await.map_err(error)?;
            let restarted = signed_in(hub, agent, params, &cli.store(agent)).await?;
            Ok(json!({"saved": true, "restarted": restarted}))
        }
        other => Err(RpcError::method_not_found(other)),
    }
}
