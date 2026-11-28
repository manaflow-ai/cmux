//! `_acpmux/agent_login/start|finish|cancel|api_key` (`crate::agent_login`):
//! the chat's sign-in card runs the agent's own sign-in on the machine this
//! daemon runs on. Part of the request handler (`requests.rs`).
//!
//! Who may ask: this machine's unix socket and app, and the owner's own peer
//! daemon (the person's Mac, forwarding its app's card for a chat that lives
//! here: `vm_boundary::owner`). Never a Web client, a paired device, or a peer
//! forwarding for one, or an agent-bound connection. The sign-in becomes this machine's,
//! for every chat on it. The program is always the agent's own CLI; nothing the caller sends
//! names a program, path or env.
//!
//! A request that names a chat (`sessionId`) is forwarded whole to the peer
//! the chat lives on (`peer_forward.rs`), so the card names its chat on every
//! call and the sign-in runs on the chat's machine. After a sign-in, a named
//! chat's agent restarts now when it is between turns (`restarted`), so its
//! next prompt uses the new sign-in; in a turn it restarts when the turn ends
//! (`restarted: false`), never cutting the turn.
//!
//! Settings recovery uses `recover_start` and `recover_finish` with an exact
//! `recoverySession` so an older daemon can refuse the scoped operation.
//!
//! `start {agent: "claude@gateway"}` (`agent_login::GATEWAY_SUFFIX`) is the card's third way in:
//! no sign-in runs; the chat's agent uses cmux's gateway (the team's CodeRouter account)
//! when the image says the team has one
//! (`Machine::gateway_access`), and answers `{gateway: true, restarted}`; else `no_gateway`.

use super::{Conn, ConnAuth, Origin};
use crate::agent_login::{self as login, Agent, Cli, LoginError, Machine, reason};
use crate::config::{Config, HarnessKind, HarnessProfile};
use crate::hub::{Control, Hub};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;

/// The methods `handle` answers.
pub(super) const METHODS: &[&str] = &[
    method::MUX_AGENT_LOGIN_START,
    method::MUX_AGENT_LOGIN_FINISH,
    method::MUX_AGENT_LOGIN_RECOVER_START,
    method::MUX_AGENT_LOGIN_RECOVER_FINISH,
    method::MUX_AGENT_LOGIN_CANCEL,
    method::MUX_AGENT_LOGIN_API_KEY,
    method::MUX_AGENT_LOGIN_STATUS,
    method::MUX_AGENT_LOGIN_LOGOUT,
];

/// `error.data.reason` when a caller that is not the person's own asks.
pub const REMOTE_REFUSED: &str = "remote_refused";

pub(super) fn error(e: LoginError) -> RpcError {
    let code = match e.reason {
        reason::UNSUPPORTED_AGENT
        | reason::UNSUPPORTED
        | reason::RECOVERY_MISMATCH
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
        let names: Vec<_> = Agent::ALL.iter().map(|a| a.name()).collect();
        error(LoginError::new(
            reason::UNSUPPORTED_AGENT,
            format!("agent must be one of {}, not {name:?}", names.join(", ")),
        ))
    })
}

fn text<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty())
}

fn recovery_id(params: &Value) -> Result<Option<&str>, RpcError> {
    params
        .get("recoverySession")
        .map(|value| {
            value
                .as_str()
                .filter(|id| !id.is_empty())
                .ok_or_else(|| RpcError::invalid_params("recoverySession must be a chat id"))
        })
        .transpose()
}

/// Whether a connection of `origin` that presented `auth` may run a sign-in here (module docs).
/// The one owner rule for every sign-in on this machine: `account_sign_in.rs` asks it too.
pub(super) fn allowed(origin: Origin, auth: ConnAuth, params: &Value) -> bool {
    let control = super::remote_guard::control_of(origin, auth, params);
    match origin {
        Origin::Local => auth == ConnAuth::LocalSocket && control == Control::Local,
        Origin::LocalApp => auth == ConnAuth::LocalApp && control == Control::Local,
        Origin::Peer => crate::hub::vm_boundary::owner(auth, control, params),
        Origin::Web => false,
    }
}

/// Check the owner carrier before routing can lose the original caller's identity.
pub(super) fn authorize(conn: &Conn, params: &Value) -> Result<(), RpcError> {
    if conn.caller().is_some() || conn.agent_side() || !allowed(conn.origin, conn.auth, params) {
        return Err(RpcError::new(
            -32000,
            "an agent sign-in runs only from this machine, its cmux app, or its owner's own machine",
        )
        .with_data(json!({"reason": REMOTE_REFUSED})));
    }
    Ok(())
}

/// How this daemon starts `agent` (`crate::agent_login` docs): the `claude`,
/// `codex`, `gemini` or `grok` harness profile when it runs that CLI itself
/// (Gemini's and Grok's: the profile's program is `gemini` or `grok`), else the CLI on
/// the login PATH. The profile's env and Codex's global options come along;
/// values that refer to a secret store are left out (nothing here asks one).
pub(super) fn cli_for(cfg: &Config, agent: Agent, selected: Option<HarnessProfile>) -> Option<Cli> {
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
        Agent::Gemini | Agent::Grok => p.argv.first().is_some_and(|program| {
            Path::new(program).file_name().and_then(|f| f.to_str()) == Some(agent.name())
        }),
        // `cursor-agent acp` (or the `agent` link to it): the same program signs in.
        Agent::Cursor => p.kind == HarnessKind::Acp && cursor_launch(&p.argv),
        // `opencode acp`: its env (XDG_DATA_HOME) says where its `auth.json` is.
        Agent::OpenCode => p.kind == HarnessKind::Acp && opencode_launch(&p.argv),
        // gh is no harness: always `gh` on the login PATH.
        Agent::Github => false,
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
        None => vec![crate::config::which(agent.program())?],
    };
    let (command, args) = argv.split_first()?;
    let program = match agent {
        Agent::Codex => env.get("CODEX_PATH").filter(|p| !p.is_empty()).cloned(),
        Agent::Claude
        | Agent::Gemini
        | Agent::Grok
        | Agent::Cursor
        | Agent::Github
        | Agent::OpenCode => None,
    }
    .unwrap_or_else(|| command.clone());
    let globals = match agent {
        Agent::Codex => crate::cli::harness_login::codex_globals(args).to_vec(),
        Agent::Claude
        | Agent::Gemini
        | Agent::Grok
        | Agent::Cursor
        | Agent::Github
        | Agent::OpenCode => Vec::new(),
    };
    Some(Cli { program, globals, env })
}

/// Whether `argv` runs Cursor's CLI: `cursor-agent` (or `agent`), then `acp`.
fn cursor_launch(argv: &[String]) -> bool {
    let program = argv.first().and_then(|p| std::path::Path::new(p).file_name());
    matches!(program.and_then(|p| p.to_str()), Some("cursor-agent" | "agent"))
        && argv.get(1).is_some_and(|a| a == "acp")
}

/// Whether `argv` runs OpenCode's CLI: `opencode`, then `acp`.
fn opencode_launch(argv: &[String]) -> bool {
    let program = argv.first().and_then(|p| std::path::Path::new(p).file_name());
    program.and_then(|p| p.to_str()) == Some("opencode") && argv.get(1).is_some_and(|a| a == "acp")
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

pub(super) fn machine(hub: &Hub) -> Machine {
    Machine { root: hub.vm_marker_root(), home: dirs::home_dir().unwrap_or_default() }
}

/// The account environment used by the machine-wide Claude sign-in and status RPCs.
pub(crate) fn claude_machine_login_env(
    cfg: &Config,
) -> Option<std::collections::BTreeMap<String, String>> {
    let cli = cli_for(cfg, Agent::Claude, None)?;
    Some(
        ["HOME", "CLAUDE_CONFIG_DIR"]
            .into_iter()
            .filter_map(|key| cli.var(key).map(|value| (key.to_owned(), value)))
            .collect(),
    )
}

/// After a sign-in: the machine's launcher picks the own sign-in, and the
/// named chat's agent restarts (module docs). Whether it restarted now.
async fn signed_in(
    hub: &Arc<Hub>,
    agent: Agent,
    params: &Value,
    store: &Path,
    recovery: Option<&str>,
) -> Result<bool, RpcError> {
    // The chat config may have changed while the browser was open. Apply the result
    // only if the sign-in still belongs to the same account.
    let (current, route) = cli(hub, agent, params).await?;
    if current.store(agent) != store {
        return Err(RpcError::invalid_params(
            "the chat's account changed during sign-in; start again",
        ));
    }
    // Alternate account homes are scoped to this chat; do not flip the machine-wide
    // launcher mode away from team routing for the canonical account.
    let recovery = recovery_session(hub, agent, text(params, "sessionId"), recovery, store).await?;
    let machine = machine(hub);
    let canonical = machine.home.join(agent.home_dir_name());
    if recovery.is_none()
        && current.store(agent) == canonical
        && let Err(e) = machine.choose_own(agent)
    {
        tracing::warn!(agent = agent.name(), error = %e, "agent login: record the own sign-in choice");
    }
    if let Some(session) = recovery {
        let switched = hub.use_claude_machine_login(&session).await?;
        let changed = hub.login_changed(agent.name(), store, None).await;
        let ids = std::collections::BTreeSet::from([session.id.clone()]);
        let restarted = switched && hub.restart_harnesses(None, Some(&ids)).await.now > 0;
        changed?;
        return Ok(restarted);
    }
    hub.login_changed(agent.name(), store, route.as_deref()).await?;
    if cfg!(target_os = "macos") && matches!(agent, Agent::Grok | Agent::Cursor) {
        super::connections::announce_later(hub);
    }
    let Some(key) = text(params, "sessionId") else {
        return if agent == Agent::Claude {
            restart_claude_account(hub, store).await
        } else {
            Ok(false)
        };
    };
    let session = hub.resolve(key)?;
    let ids = std::collections::BTreeSet::from([session.id.clone()]);
    let done = hub.restart_harnesses(None, Some(&ids)).await;
    Ok(done.now > 0)
}

/// A Settings recovery uses the exact local chat and the machine's own account store.
async fn recovery_session(
    hub: &Hub,
    agent: Agent,
    session: Option<&str>,
    recovery: Option<&str>,
    store: &Path,
) -> Result<Option<Arc<crate::hub::Session>>, RpcError> {
    let Some(id) = recovery else { return Ok(None) };
    if agent != Agent::Claude || session.is_some() {
        return Err(RpcError::invalid_params("recovery requires a Claude chat on this machine"));
    }
    let session = hub.session_get(id).ok_or_else(|| {
        error(LoginError::new(reason::UNKNOWN_SESSION, "no such chat on this machine"))
    })?;
    let (profile, route) = hub.login_profile(&session, "claude").await?;
    hub.check_claude_recovery(&session, route.as_deref()).await?;
    if !cli_for(&*hub.config.read().await, Agent::Claude, Some(profile))
        .is_some_and(|cli| cli.store(Agent::Claude) == store)
    {
        return Err(RpcError::invalid_params("this chat uses a different Claude account store"));
    }
    Ok(Some(session))
}

/// Restart only chats that already use the Claude account being changed.
async fn restart_claude_account(hub: &Arc<Hub>, store: &Path) -> Result<bool, RpcError> {
    let mut ids = std::collections::BTreeSet::new();
    for session in hub.sessions() {
        if !hub.has_delivered_credential(&session)
            && let Ok((profile, None)) = hub.login_profile(&session, "claude").await
        {
            let matches = cli_for(&*hub.config.read().await, Agent::Claude, Some(profile))
                .is_some_and(|cli| cli.store(Agent::Claude) == store);
            if matches {
                ids.insert(session.id.clone());
            }
        }
    }
    Ok(hub.restart_harnesses(None, Some(&ids)).await.now > 0)
}

/// A named Claude chat saves its gateway choice before restarting. A machine-wide choice
/// is recorded in the image's account preference. Returns whether a chat restarted now.
pub(crate) async fn use_gateway(
    hub: &Arc<Hub>,
    agent: Agent,
    session_id: Option<&str>,
) -> Result<bool, RpcError> {
    let machine = machine(hub);
    if machine.gateway_access(agent).await != Some(true) {
        return Err(error(LoginError::new(
            reason::NO_GATEWAY,
            format!("cmux's gateway does not serve {} for this machine's team", agent.name()),
        )));
    }
    let session = session_id.map(|key| hub.resolve(key)).transpose()?;
    if agent == Agent::Claude
        && let Some(session) = &session
    {
        hub.select_claude_gateway(session, false).await?;
    } else {
        match machine.choose_team(agent) {
            Ok(true) => {}
            Ok(false) => {
                return Err(error(LoginError::new(reason::NO_GATEWAY, "not a cmux Cloud machine")));
            }
            Err(e) => {
                return Err(error(LoginError::new(
                    reason::FAILED,
                    format!("record the gateway choice: {e}"),
                )));
            }
        }
    }
    let Some(session) = session else { return Ok(false) };
    let ids = std::collections::BTreeSet::from([session.id.clone()]);
    let done = hub.restart_harnesses(None, Some(&ids)).await;
    if let Some((_, error)) = done.failed.first() {
        return Err(RpcError::internal(error.clone()));
    }
    Ok(done.now > 0)
}

pub(super) async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let scoped =
        matches!(m, method::MUX_AGENT_LOGIN_RECOVER_START | method::MUX_AGENT_LOGIN_RECOVER_FINISH);
    let recovery =
        if scoped || matches!(m, method::MUX_AGENT_LOGIN_START | method::MUX_AGENT_LOGIN_FINISH) {
            recovery_id(params)?
        } else {
            None
        };
    if scoped && (recovery.is_none() || params.get("sessionId").is_some()) {
        return Err(error(LoginError::new(
            reason::RECOVERY_MISMATCH,
            "recovery requires a Claude chat on this machine",
        )));
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
    if m == method::MUX_AGENT_LOGIN_START
        && let Some(agent) = text(params, "agent").and_then(login::gateway_agent)
    {
        let restarted = use_gateway(hub, agent, text(params, "sessionId")).await?;
        return Ok(json!({"gateway": true, "restarted": restarted}));
    }
    if m != method::MUX_AGENT_LOGIN_CANCEL {
        machine(hub).refuse_shared().map_err(error)?;
    }
    match m {
        method::MUX_AGENT_LOGIN_STATUS | method::MUX_AGENT_LOGIN_LOGOUT => {
            let agent = agent_of(params)?;
            if agent != Agent::Claude || params.get("sessionId").is_some() {
                return Err(error(LoginError::new(
                    reason::UNSUPPORTED,
                    "expected Claude's machine login",
                )));
            }
            let (cli, _) = cli(hub, agent, params).await?;
            if m == method::MUX_AGENT_LOGIN_STATUS {
                return login::claude_status(&machine(hub), &cli).await.map_err(error);
            }
            login::claude_logout(&machine(hub), &cli).await.map_err(error)?;
            hub.login_changed("claude", &cli.store(agent), None).await?;
            restart_claude_account(hub, &cli.store(agent)).await?;
            Ok(json!({"signedIn": false}))
        }
        method::MUX_AGENT_LOGIN_START | method::MUX_AGENT_LOGIN_RECOVER_START => {
            let agent = agent_of(params)?;
            // A key-only agent (Gemini, OpenCode) has no sign-in page: say so before looking for
            // its CLI, so the answer is `unsupported` whether or not it is installed here.
            if !agent.signs_in_by_link() {
                return Err(error(LoginError::new(
                    reason::UNSUPPORTED,
                    format!("{} signs in on this machine with an API key", agent.name()),
                )));
            }
            let (cli, _) = cli(hub, agent, params).await?;
            recovery_session(hub, agent, text(params, "sessionId"), recovery, &cli.store(agent))
                .await?;
            let mut api_key = None;
            if agent == Agent::Claude
                && text(params, "sessionId").is_none()
                && params["reuseExisting"] == true
            {
                login::check_claude_login_available(&cli).await.map_err(error)?;
                let status = login::claude_status(&machine(hub), &cli).await.map_err(error)?;
                if status["signedIn"] == true {
                    login::check_claude_login_available(&cli).await.map_err(error)?;
                    signed_in(hub, agent, params, &cli.store(agent), recovery).await?;
                    return Ok(status);
                }
                api_key = status["apiKey"].as_bool();
            }
            let s = login::start(&machine(hub), &cli, agent, recovery.map(str::to_owned))
                .await
                .map_err(error)?;
            let mut reply = json!({
                "loginId": s.login_id,
                "url": s.url,
                "needsCode": s.needs_code,
                "expiresAtMs": s.expires_at_ms,
            });
            if let Some(obj) = reply.as_object_mut() {
                if let Some(api_key) = api_key {
                    obj.insert("apiKey".into(), json!(api_key));
                }
                if let Some(code) = s.user_code {
                    obj.insert("userCode".into(), json!(code));
                }
                // Claude's automatic link: its approve reaches Claude's own
                // listener on this machine, with no code to paste.
                if let (Some(url), Some(port)) = (s.auto_url, s.callback_port) {
                    obj.insert("autoUrl".into(), json!(url));
                    obj.insert("callbackPort".into(), json!(port));
                }
            }
            Ok(reply)
        }
        method::MUX_AGENT_LOGIN_FINISH | method::MUX_AGENT_LOGIN_RECOVER_FINISH => {
            let id = text(params, "loginId").ok_or_else(|| {
                error(LoginError::new(reason::UNKNOWN_LOGIN, "loginId is required"))
            })?;
            // No code: Codex's device flow, or Claude after an automatic link.
            let code = params.get("code").and_then(Value::as_str);
            let done = login::finish(id, code, recovery).await.map_err(error)?;
            // A repeated recovery finish must still verify the chat switched.
            let restarted = if done.signed_in && (done.fresh || done.recovery_session.is_some()) {
                let recovery = done.recovery_session.as_deref();
                let machine_params = json!({});
                signed_in(
                    hub,
                    done.agent,
                    if recovery.is_some() { &machine_params } else { params },
                    &done.store,
                    recovery,
                )
                .await?
            } else {
                false
            };
            Ok(
                json!({"signedIn": done.signed_in, "restarted": restarted, "agent": done.agent.name()}),
            )
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
            let restarted = signed_in(hub, agent, params, &cli.store(agent), None).await?;
            Ok(json!({"saved": true, "restarted": restarted}))
        }
        other => Err(RpcError::method_not_found(other)),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::agent_credentials::{AgentCredential, CLAUDE_OAUTH};
    use crate::hub::NewRequest;

    #[tokio::test]
    async fn recovery_uses_the_requested_chat_after_a_retry_and_blocks_redelivery() {
        let home = tempfile::tempdir().unwrap();
        let launcher = home.path().join("claude");
        std::os::unix::fs::symlink("/usr/bin/false", &launcher).unwrap();
        let mut config: Config = serde_json::from_value(json!({
            "store": {"mode": "memory"},
            "harnesses": {"claude": {"argv": [launcher], "kind": "claude-stdio",
                "env": {"CLAUDE_CONFIG_DIR": home.path()}}},
            "defaultHarness": "claude"
        }))
        .unwrap();
        config.path = Some(home.path().join("config.json"));
        config.profile_sources = crate::config::ProfileSources::none();
        config.profile_sources.cmux_json = Some(home.path().join("cmux.json"));
        let (routes_dir, state) = crate::routes::places(&config);
        let routes_dir = routes_dir.unwrap();
        std::fs::create_dir_all(&routes_dir).unwrap();
        std::fs::write(
            routes_dir.join("work-claude.toml"),
            "kind = \"claude-token\"\nfamilies = [\"claude\"]\nsecret = \"env:FIXTURE_CLAUDE_TOKEN\"\n",
        )
        .unwrap();
        assert_eq!(
            crate::routes::find(Some(&routes_dir), "work-claude").unwrap().file.kind,
            crate::routes::RouteKind::ClaudeToken
        );
        let store = crate::store::open(&config.store, home.path()).unwrap();
        let hub = Hub::new(config, store);
        let cli_home = cli(&hub, Agent::Claude, &json!({})).await.unwrap().0.store(Agent::Claude);
        let mut chats = Vec::new();
        for id in ["work-claude", "legacy-claude", "claude-token-2"] {
            let credential = AgentCredential::parse(&json!({
                "connection": id, "env": {CLAUDE_OAUTH: "sk-ant-oat01-fixture"}
            }))
            .unwrap();
            let session = hub
                .new_session(NewRequest {
                    cwd: Some(home.path().to_owned()),
                    credential: Some(credential.clone()),
                    ..NewRequest::default()
                })
                .await
                .unwrap();
            hub.edit_test_meta(&session, |meta| {
                meta.last_turn =
                    Some(json!({"status": "error", "errorText": "OAuth token revoked"}));
                if id == "legacy-claude" {
                    meta.claude_token_recovery =
                        Some(crate::store::ClaudeTokenRecovery::LegacyRejected);
                }
            });
            chats.push((session, credential));
        }
        let (target, token) = &chats[0];
        let (other, _) = &chats[2];
        signed_in(&hub, Agent::Claude, &json!({}), &cli_home, None).await.unwrap();
        assert_eq!(hub.credential_status(&target.id).await.unwrap()["held"], true);

        hub.edit_test_meta(target, |meta| {
            meta.last_turn = Some(json!({"status": "error", "errorText": "a later retry failed"}));
        });
        // An upgraded daemon may have only the saved connection id until the Mac reconnects.
        hub.revoke_credential(&target.id).await.unwrap();
        let binding = format!("chat:{}", target.id);
        crate::routes::set_binding(&state, &binding, Some("work-claude")).unwrap();
        assert_eq!(hub.credential_status(&target.id).await.unwrap()["connection"], "work-claude");
        signed_in(&hub, Agent::Claude, &json!({}), &cli_home, Some(&target.id)).await.unwrap();

        let status = hub.credential_status(&target.id).await.unwrap();
        assert_eq!(status["claudeTokenRecovery"], "machineLogin");
        assert!(status["connection"].is_null());
        assert_eq!(status["held"], false);
        assert!(hub.update_credential(&target.id, token.clone(), false).await.is_err());
        let persisted: crate::store::SessionMeta =
            serde_json::from_value(serde_json::to_value(target.meta()).unwrap()).unwrap();
        assert_eq!(
            persisted.claude_token_recovery,
            Some(crate::store::ClaudeTokenRecovery::MachineLogin)
        );
        assert!(persisted.credential_connection.is_none());

        let (legacy, _) = &chats[1];
        hub.revoke_credential(&legacy.id).await.unwrap();
        signed_in(&hub, Agent::Claude, &json!({}), &cli_home, Some(&legacy.id)).await.unwrap();
        let status = hub.credential_status(&legacy.id).await.unwrap();
        assert_eq!(status["claudeTokenRecovery"], "machineLogin");
        assert!(status["connection"].is_null());
        assert_eq!(status["held"], false);

        let status = hub.credential_status(&other.id).await.unwrap();
        assert_eq!(status["connection"], "claude-token-2");
        assert_eq!(status["held"], true);
        assert!(status["claudeTokenRecovery"].is_null());
    }
}
