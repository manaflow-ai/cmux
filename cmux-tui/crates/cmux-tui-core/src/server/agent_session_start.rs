//! Remote agent session start (`agent-session-start-v1`): a trusted local
//! client (an app on another Mac, through the SSH or Cloud carrier) starts
//! a new chat for an agent tab of THIS daemon's store in this machine's own
//! acpmux, and the daemon binds it to the tab. The app then shows the chat
//! through `agent-session-attach-v1` (the parent module); no acpmux port is
//! opened.
//!
//! `agent-session-start {surface, harness?, cwd?}` answers
//! `{surface, session, conversation}` once acpmux made the session and the
//! store recorded it on the tab (`bind-conversation-tab-session` with
//! expected null, this daemon being the writer).
//!
//! Scope: the tab must be an `agent_session` tab of this store with no
//! session yet, whose record names this store as its host
//! (`registry:<identify.session_id>`), so a tab recorded for another
//! machine never starts here. The client names only an agent kind
//! (`harness`, resolved by acpmux from its own config) and a folder (`cwd`,
//! absolute; acpmux checks it). No command, env, policy, mode, peer, preset
//! or MCP server param exists (unknown fields are a bad request).
//!
//! Permissions: the session always starts with policy `ask`, whatever the
//! daemon default is, and must end up in a mode acpmux's remote table
//! (`_acpmux/web_modes`) says asks before acting: a family that table
//! refuses (Codex, opencode) is refused before or after the start, and a
//! session that starts in a mode that does not ask is moved to its family's
//! asking default, or ended and refused. This mirrors what acpmux does for a
//! remote WebSocket `session/new` (plans/cmux-next/acp-remote-guard.md),
//! because this daemon reaches acpmux over its unix socket, where acpmux's
//! own remote guard does not run.
//!
//! acpmux runs on demand: when nothing listens on the socket, the daemon
//! starts it once through the binary's starter (`cmux acp daemon start`,
//! as `cmux acp` does) and connects again; otherwise
//! `agent_session.acpmux_unavailable`.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_link::AcpmuxLink;
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;

pub const AGENT_SESSION_START_CAPABILITY: &str = "agent-session-start-v1";

/// Starts the binary's acpmux daemon (blocking; acpmux bounds its own start).
pub type AcpmuxStarter = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

/// Starts that may run at once on one daemon.
const MAX_STARTS: usize = 8;
const MAX_CWD_BYTES: usize = 4096;
/// A harness spawns and answers `session/new` (a cold agent can take long).
const NEW_TIMEOUT: Duration = Duration::from_secs(60);
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// The starter and the tabs being started.
#[derive(Default)]
pub(crate) struct AgentSessionStarts {
    starter: Mutex<Option<AcpmuxStarter>>,
    starting: Mutex<HashSet<SurfaceId>>,
}

impl AgentSessionStarts {
    pub(crate) fn set_starter(&self, starter: Option<AcpmuxStarter>) {
        *self.starter.lock().unwrap_or_else(|e| e.into_inner()) = starter;
    }

    fn starter(&self) -> Option<AcpmuxStarter> {
        self.starter.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub(crate) fn has_starter(&self) -> bool {
        self.starter.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// Takes `surface`'s start slot; false while it starts or at the cap.
    fn reserve(&self, surface: SurfaceId) -> bool {
        let mut starting = self.starting.lock().unwrap_or_else(|e| e.into_inner());
        starting.len() < MAX_STARTS && starting.insert(surface)
    }

    fn release(&self, surface: SurfaceId) {
        self.starting.lock().unwrap_or_else(|e| e.into_inner()).remove(&surface);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StartParams {
    surface: SurfaceId,
    #[serde(default)]
    harness: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
}

impl StartParams {
    fn valid(&self) -> bool {
        let harness_ok = self.harness.as_deref().is_none_or(|harness| {
            (1..=64).contains(&harness.len())
                && harness.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        });
        let cwd_ok = self.cwd.as_deref().is_none_or(|cwd| {
            (1..=MAX_CWD_BYTES).contains(&cwd.len())
                && cwd.starts_with('/')
                && !cwd.chars().any(char::is_control)
        });
        harness_ok && cwd_ok
    }
}

/// This store's host value in an agent tab record.
pub(crate) fn store_host(mux: &Mux) -> String {
    format!("registry:{}", mux.registry_identity().0)
}

/// `agent-session-start` of a trusted local connection (the parent checked
/// trust and the acpmux socket).
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: StartParams,
    writer: &MessageWriter,
) -> bool {
    if !params.valid() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    let starts = &mux.control_clients.agent_sessions.starts;
    if !starts.reserve(params.surface) {
        return refuse(writer, id, Refusal::Limit);
    }
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let surface = params.surface;
    let spawned = std::thread::Builder::new()
        .name("mux-agent-start".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = run(&worker_mux, client, socket, params);
            worker_mux.control_clients.agent_sessions.starts.release(surface);
            match result {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        starts.release(surface);
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// Ok when `surface` is an unbound agent tab whose record names this store.
fn startable(mux: &Mux, surface: SurfaceId) -> Result<(), Refusal> {
    let runtime = mux.surface(surface).ok_or(Refusal::UnknownTab)?;
    match mux.conversation_tab_of(&runtime) {
        Some(ConversationTabRecord::AgentSession { host, session, .. })
            if host == store_host(mux) =>
        {
            if session.is_some() { Err(Refusal::Bound) } else { Ok(()) }
        }
        _ => Err(Refusal::UnknownTab),
    }
}

fn run(mux: &Arc<Mux>, client: u64, socket: PathBuf, params: StartParams) -> Result<Value, Refusal> {
    let link = connect(mux, &socket)?;
    let result = start_and_bind(mux, client, &link, &params);
    link.close();
    result
}

/// A link to acpmux, starting it once when nothing listens.
fn connect(mux: &Mux, socket: &std::path::Path) -> Result<Arc<AcpmuxLink>, Refusal> {
    let open = || AcpmuxLink::connect(socket, |_| {});
    if let Ok(link) = open() {
        return Ok(link);
    }
    let starter =
        mux.control_clients.agent_sessions.starts.starter().ok_or(Refusal::AcpmuxUnavailable)?;
    starter().map_err(|_| Refusal::AcpmuxUnavailable)?;
    open().map_err(|_| Refusal::AcpmuxUnavailable)
}

fn start_and_bind(
    mux: &Arc<Mux>,
    client: u64,
    link: &AcpmuxLink,
    params: &StartParams,
) -> Result<Value, Refusal> {
    let table = link.call("_acpmux/web_modes", json!({}), CALL_TIMEOUT).map_err(Refusal::of)?;
    if let Some(harness) = &params.harness
        && refused_family(&table, harness)
    {
        return Err(Refusal::NotAsking);
    }
    let mut meta = json!({"policy": "ask"});
    if let Some(harness) = &params.harness {
        meta["harness"] = json!(harness);
    }
    let mut new = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
    if let Some(cwd) = &params.cwd {
        new["cwd"] = json!(cwd);
    }
    let created = link.call("session/new", new, NEW_TIMEOUT).map_err(Refusal::of)?;
    let session = created
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|session| !session.is_empty())
        .ok_or(Refusal::Refused)?
        .to_string();
    let end = |refusal: Refusal| {
        let _ = link.call("_acpmux/kill", json!({"sessionId": session, "purge": true}), CALL_TIMEOUT);
        refusal
    };
    settle_asking_mode(link, &session).map_err(end)?;
    // The tab may have closed, or another start bound it, meanwhile.
    let actor = super::super::origin_gate::connection_actor(mux, client);
    let (record, _) = mux
        .bind_conversation_tab_session_as(&actor, params.surface, &session, None)
        .map_err(|_| end(startable(mux, params.surface).err().unwrap_or(Refusal::Refused)))?;
    Ok(json!({"surface": params.surface, "session": session, "conversation": record.wire()}))
}

fn refused_family(table: &Value, family: &str) -> bool {
    table
        .get("refusedFamilies")
        .and_then(Value::as_array)
        .is_some_and(|refused| refused.iter().any(|name| name.as_str() == Some(family)))
}

/// acpmux's remote rule for a new session: its family is not refused and
/// its mode asks (no mode counts as asking), else it moves to the family's
/// asking default; anything else is refused.
fn settle_asking_mode(link: &AcpmuxLink, session: &str) -> Result<(), Refusal> {
    let read = || {
        link.call("_acpmux/web_modes", json!({"sessionId": session}), CALL_TIMEOUT)
            .map_err(Refusal::of)
    };
    let asks = |table: &Value| -> (bool, Option<String>) {
        let family = table.pointer("/session/family").and_then(Value::as_str).unwrap_or_default();
        let modes: Vec<&str> = table
            .pointer(&format!("/families/{}", family.replace('~', "~0").replace('/', "~1")))
            .and_then(Value::as_array)
            .map(|modes| modes.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let default = modes.first().map(|mode| mode.to_string());
        if family.is_empty() || refused_family(table, family) {
            return (false, None);
        }
        let asks = match table.pointer("/session/mode").and_then(Value::as_str) {
            None => true,
            Some(mode) => modes.contains(&mode),
        };
        (asks, default)
    };
    let table = read()?;
    match asks(&table) {
        (true, _) => Ok(()),
        (false, None) => Err(Refusal::NotAsking),
        (false, Some(default)) => {
            link.call(
                "session/set_mode",
                json!({"sessionId": session, "modeId": default}),
                CALL_TIMEOUT,
            )
            .map_err(|_| Refusal::NotAsking)?;
            if asks(&read()?).0 { Ok(()) } else { Err(Refusal::NotAsking) }
        }
    }
}
