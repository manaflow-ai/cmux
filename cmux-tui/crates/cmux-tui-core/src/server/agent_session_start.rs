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
//! absolute; acpmux checks it). No command, env, policy, mode, peer, preset,
//! workspace or MCP server param exists (unknown fields are a bad request).
//! The daemon itself names the tab's workspace to acpmux on `session/new`
//! (`_meta.acpmux.workspaceId`, which picks the session's display), from the
//! tab's place in this store; a tab with no workspace, or whose workspace key
//! is not a UUID, sends none, and acpmux then gives the session no display.
//! It sends no session env: `CMUX_WORKSPACE_ID` there would also change the
//! agent-message hold, pooled starts and route bindings for these chats.
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

use crate::panic_free::JsonFields;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_link::AcpmuxLink;
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::{ConversationTabRecord, validate_harness};

pub const AGENT_SESSION_START_CAPABILITY: &str = "agent-session-start-v1";
/// `require_person_key` and `person_instance` on `agent-session-start`, and
/// its typed `agent_session.needs_keyed_start` refusal (cx-0w0jj).
pub const AGENT_SESSION_START_KEYED_REASON_CAPABILITY: &str = "agent-session-start-keyed-reason-v1";

/// Starts the binary's acpmux daemon (blocking; acpmux bounds its own start).
pub type AcpmuxStarter = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

/// What kind of machine this daemon runs on, as the binary reads it from the
/// machine's own identity at each start (never from a request). A remote start
/// is served only on [`AgentStartHost::Allowed`]; a daemon that was never
/// told refuses (fail closed).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum AgentStartHost {
    /// A Mac, an SSH host, or a Cloud VM bound to one owner.
    Allowed,
    /// A Cloud VM whose kind the daemon cannot tell.
    UnknownCloud,
    /// A team VM: shared by a team, so no remote start (hq-84 rule until the
    /// team policy for local-control sessions exists).
    TeamVm,
}

/// Starts that may run at once on one daemon.
const MAX_STARTS: usize = 8;
const MAX_CWD_BYTES: usize = 4096;
/// A harness spawns and answers `session/new` (a cold agent can take long).
const NEW_TIMEOUT: Duration = Duration::from_secs(60);
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// Reads this machine's [`AgentStartHost`] (a few file checks), at each start.
pub type AgentStartHostSource = Arc<dyn Fn() -> AgentStartHost + Send + Sync>;

/// The starter and the tabs being started.
#[derive(Default)]
pub(crate) struct AgentSessionStarts {
    starter: Mutex<Option<AcpmuxStarter>>,
    host: Mutex<Option<AgentStartHostSource>>,
    /// One acpmux start at a time; the others connect after it.
    start_lock: Mutex<()>,
    starting: Mutex<HashSet<SurfaceId>>,
}

impl AgentSessionStarts {
    pub(crate) fn set_starter(&self, starter: Option<AcpmuxStarter>) {
        *self.starter.lock().unwrap_or_else(|e| e.into_inner()) = starter;
    }

    pub(crate) fn set_host(&self, host: AgentStartHostSource) {
        *self.host.lock().unwrap_or_else(|e| e.into_inner()) = Some(host);
    }

    /// Ok on an allowed host; the refusal otherwise (also when unset). The
    /// kind is read again for every start, so a bind or team enroll that
    /// lands after the daemon started counts at once.
    fn host_gate(&self) -> Result<(), Refusal> {
        let source = self.host.lock().unwrap_or_else(|e| e.into_inner()).clone();
        match source.map(|read| read()) {
            Some(AgentStartHost::Allowed) => Ok(()),
            Some(AgentStartHost::TeamVm) => Err(Refusal::TeamVmBlocked),
            Some(AgentStartHost::UnknownCloud) | None => Err(Refusal::HostUnverified),
        }
    }

    fn starter(&self) -> Option<AcpmuxStarter> {
        self.starter.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Takes `surface`'s start slot; None while it starts or at the cap.
    /// The slot is given back when the returned guard drops (also on a panic).
    fn reserve(mux: &Arc<Mux>, surface: SurfaceId) -> Option<StartSlot> {
        let starts = &mux.control_clients.agent_sessions.starts;
        let mut starting = starts.starting.lock().unwrap_or_else(|e| e.into_inner());
        (starting.len() < MAX_STARTS && starting.insert(surface))
            .then(|| StartSlot { mux: mux.clone(), surface })
    }
}

/// A taken start slot.
struct StartSlot {
    mux: Arc<Mux>,
    surface: SurfaceId,
}

impl Drop for StartSlot {
    fn drop(&mut self) {
        let starts = &self.mux.control_clients.agent_sessions.starts;
        starts.starting.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.surface);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StartParams {
    surface: SurfaceId,
    #[serde(default)]
    harness: Option<String>,
    cwd: String,
    /// The person chose the home folder as the chat's folder (`agent-session-trust`'s rule).
    #[serde(default)]
    home_confirmed: bool,
    /// The caller signs relayed allows with a person key of its own (cx-0w0jj):
    /// the start runs only when acpmux holds a key for `person_instance`,
    /// else the typed `needs_keyed_start` refusal says whether a keyed
    /// restart can lose nothing.
    #[serde(default)]
    require_person_key: bool,
    /// The acpmux run (`personInstance`) the caller holds a key for.
    #[serde(default)]
    person_instance: Option<String>,
}

impl StartParams {
    fn valid(&self) -> bool {
        let harness_ok = self.harness.as_deref().is_none_or(|harness| {
            (1..=64).contains(&harness.len())
                && harness.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        });
        let cwd = &self.cwd;
        let cwd_ok = (1..=MAX_CWD_BYTES).contains(&cwd.len())
            && cwd.starts_with('/')
            && !cwd.chars().any(char::is_control);
        let instance_ok = self.person_instance.as_deref().is_none_or(|instance| {
            (1..=128).contains(&instance.len())
                && instance.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
        });
        harness_ok && cwd_ok && instance_ok
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
    if let Err(refusal) = mux.control_clients.agent_sessions.starts.host_gate() {
        return refuse(writer, id, refusal);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    // A chat never starts in `/`, above the home folder, or in the home folder
    // unless the person chose it (cx-1bhjj), as on the Mac.
    if let Err(refusal) = super::agent_session_trust::home_rule(&params.cwd, params.home_confirmed)
    {
        return refuse(writer, id, refusal);
    }
    let Some(slot) = AgentSessionStarts::reserve(mux, params.surface) else {
        return refuse(writer, id, Refusal::Limit);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-start".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = match keyed_gate(&socket, &params) {
                Ok(()) => run(&worker_mux, client, socket, params).map_err(|r| (r, None)),
                Err(refused) => Err(refused),
            };
            drop(slot);
            match result {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err((refusal, None)) => refuse(&worker_writer, worker_id, refusal),
                Err((refusal, Some(data))) => {
                    super::refuse_with_data(&worker_writer, worker_id, refusal, data)
                }
            };
        });
    // A failed spawn drops the closure and with it the slot.
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// cx-0w0jj: with `require_person_key`, the start runs only when this
/// machine's acpmux holds a person key for the caller's `person_instance`.
/// Otherwise `needs_keyed_start` with [`keyed_restart_reason`] (never the
/// run id or any key material). Nothing listening is acpmux not running: the
/// gate never starts an acpmux without a key.
fn keyed_gate(
    socket: &std::path::Path,
    params: &StartParams,
) -> Result<(), (Refusal, Option<Value>)> {
    if !params.require_person_key {
        return Ok(());
    }
    // Only nothing listening (no socket, or refused) is "acpmux does not run".
    // Any other connect error, and a status that cannot be read, is an
    // unknown fact: not safe, and the client starts without its key.
    let unknown = || (Refusal::NeedsKeyedStart, Some(keyed_restart_reason(Some(&json!({})))));
    let status = match AcpmuxLink::connect(socket, |_| {}) {
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            None
        }
        Err(_) => return Err(unknown()),
        Ok(link) => {
            let status = link.call("_acpmux/status", json!({}), CALL_TIMEOUT);
            link.close();
            Some(status.map_err(|_| unknown())?)
        }
    };
    let keyed = status.as_ref().is_some_and(|status| {
        status.get("personKey").and_then(Value::as_bool) == Some(true)
            && params.person_instance.is_some()
            && status.get("personInstance").and_then(Value::as_str)
                == params.person_instance.as_deref()
    });
    if keyed {
        return Ok(());
    }
    Err((Refusal::NeedsKeyedStart, Some(keyed_restart_reason(status.as_ref()))))
}

/// The ONE rule for whether a keyed restart of this machine's acpmux can
/// lose nothing, from its `_acpmux/status` (None: it does not run): it is
/// ready, keeps agent hosts across a restart, and runs no live agent and no
/// proxied peer session. An unknown or missing fact is not safe.
pub(crate) fn keyed_restart_reason(status: Option<&Value>) -> Value {
    let count = |key: &str| status.and_then(|status| status.get(key)).and_then(Value::as_u64);
    let flag = |key: &str| status.and_then(|status| status.get(key)).and_then(Value::as_bool);
    let (live_agents, remote_sessions) = match status {
        None => (Some(0), Some(0)),
        Some(_) => (count("liveAgents"), count("remoteSessions")),
    };
    let safe_to_restart = status.is_none()
        || (flag("ready") == Some(true)
            && flag("agentHosts") == Some(true)
            && live_agents == Some(0)
            && remote_sessions == Some(0));
    json!({
        "reason": "needs_keyed_start",
        "safe_to_restart": safe_to_restart,
        "live_agents": live_agents,
        "remote_sessions": remote_sessions,
    })
}

/// Ok when `surface` is an unbound agent tab whose record names this store.
fn startable(mux: &Mux, surface: SurfaceId) -> Result<(), Refusal> {
    let runtime = mux.surface(surface).ok_or(Refusal::UnknownTab)?;
    match mux.conversation_tab_of(&runtime) {
        Some(ConversationTabRecord::AgentSession { host, session, .. })
            if host == store_host(mux) =>
        {
            if session.is_some() {
                Err(Refusal::Bound)
            } else {
                Ok(())
            }
        }
        _ => Err(Refusal::UnknownTab),
    }
}

fn run(
    mux: &Arc<Mux>,
    client: u64,
    socket: PathBuf,
    params: StartParams,
) -> Result<Value, Refusal> {
    let link = connect(mux, &socket)?;
    let result = start_and_bind(mux, client, &link, &params);
    link.close();
    result
}

/// A link to acpmux, starting it once when nothing listens (also an
/// `agent-update-apply`, `agent_update.rs`).
pub(in crate::server) fn connect(
    mux: &Mux,
    socket: &std::path::Path,
) -> Result<Arc<AcpmuxLink>, Refusal> {
    let open = || AcpmuxLink::connect(socket, |_| {});
    if let Ok(link) = open() {
        return Ok(link);
    }
    let starts = &mux.control_clients.agent_sessions.starts;
    let starter = starts.starter().ok_or(Refusal::AcpmuxUnavailable)?;
    let _one_start = starts.start_lock.lock().unwrap_or_else(|e| e.into_inner());
    // Another start may have brought acpmux up while this one waited.
    if let Ok(link) = open() {
        return Ok(link);
    }
    starter().map_err(|_| Refusal::AcpmuxUnavailable)?;
    open().map_err(|_| Refusal::AcpmuxUnavailable)
}

/// Runs `restart` (an acpmux handoff, `agent_update.rs`: the running acpmux
/// stopped, this binary's started) under the start lock, so no start here
/// runs while acpmux is down; then a link to the acpmux that answers. A failed
/// restart still connects once (another process may have started acpmux),
/// and is logged.
pub(in crate::server) fn restart_with(
    mux: &Mux,
    socket: &std::path::Path,
    restart: impl FnOnce() -> Result<(), String>,
) -> Option<Arc<AcpmuxLink>> {
    let starts = &mux.control_clients.agent_sessions.starts;
    let _one_start = starts.start_lock.lock().unwrap_or_else(|e| e.into_inner());
    if let Err(error) = restart() {
        eprintln!("cmux-tui: acpmux handoff for an agent update failed: {error}");
    }
    AcpmuxLink::connect(socket, |_| {}).ok()
}

fn start_and_bind(
    mux: &Arc<Mux>,
    client: u64,
    link: &AcpmuxLink,
    params: &StartParams,
) -> Result<Value, Refusal> {
    let table = link.call("_acpmux/web_modes", json!({}), CALL_TIMEOUT).map_err(Refusal::of)?;
    // The family the start resolves to, from acpmux's own catalog, before
    // any agent process exists: a Codex alias or a default harness of a
    // refused family never starts.
    let catalog = link
        .call("_acpmux/harnesses", json!({"cwd": params.cwd}), CALL_TIMEOUT)
        .map_err(Refusal::of)?;
    let family = catalog_family(&catalog, params.harness.as_deref()).ok_or(Refusal::NotAsking)?;
    if refused_family(&table, &family) {
        return Err(Refusal::NotAsking);
    }
    // The folder must be trusted before an agent starts there (an agent can
    // run the folder's own hooks and settings at start); this daemon reaches
    // acpmux over its unix socket, which acpmux's trust gate does not hold;
    // only the person answers it (`agent-session-trust`, from the app).
    let trust = link
        .call("acp.trust.get", json!({"cwd": params.cwd}), CALL_TIMEOUT)
        .map_err(Refusal::of)?;
    if !folder_trusted(&trust, params.harness.as_deref()) {
        return Err(Refusal::UntrustedFolder);
    }
    let mut meta = json!({"policy": "ask"});
    if let Some(harness) = &params.harness {
        meta.insert("harness", json!(harness));
    }
    // The workspace of the tab, read here and never taken from the client:
    // acpmux gives the session that workspace's display (none without it).
    if let Some(workspace) = mux.surface_workspace_key(params.surface) {
        meta.insert("workspaceId", json!(workspace));
    }
    // The folder acpmux checked (its canonical path), so a symlink changed
    // after the trust answer cannot move the agent elsewhere.
    let cwd = trust.get("cwd").and_then(Value::as_str).ok_or(Refusal::UntrustedFolder)?;
    let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}});
    let created = link.call("session/new", new, NEW_TIMEOUT).map_err(Refusal::of)?;
    let session = created
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|session| !session.is_empty())
        .ok_or(Refusal::Refused)?
        .to_string();
    let end = |refusal: Refusal| {
        let _ =
            link.call("_acpmux/kill", json!({"sessionId": session, "purge": true}), CALL_TIMEOUT);
        refusal
    };
    let family = settle_asking_mode(link, &session).map_err(end)?;
    // The trust answer for the family the session actually runs.
    if !folder_trusted(&trust, Some(&family)) {
        return Err(end(Refusal::UntrustedFolder));
    }
    // The agent the session runs, as acpmux answered it (`_meta.acpmux.harness`
    // of `session/new`; a profile such as `providers/deepseek` by its last
    // part), else its family: the tab's brand mark (cx-w4bbw).
    let harness =
        [created.pointer("/_meta/acpmux/harness").and_then(Value::as_str), Some(family.as_str())]
            .into_iter()
            .flatten()
            .filter_map(|harness| harness.rsplit('/').next())
            .find(|harness| validate_harness(harness).is_ok());
    // The tab may have closed, or another start bound it, meanwhile.
    let actor = super::super::origin_gate::connection_actor(mux, client);
    let _rebinding = mux.control_clients.agent_sessions.rebinding();
    let (record, _) = mux
        .bind_conversation_tab_session_as(&actor, params.surface, &session, None, harness)
        .map_err(|_| end(startable(mux, params.surface).err().unwrap_or(Refusal::Refused)))?;
    Ok(json!({"surface": params.surface, "session": session, "conversation": record.wire()}))
}

/// acpmux `trust::session_level` is `trusted`: its own decision for the
/// folder, else (no decision) the agent's own level for claude and codex,
/// else the folder level. Anything else (unknown, untrusted, unreadable) is
/// not trusted.
fn folder_trusted(trust: &Value, family: Option<&str>) -> bool {
    let level = |pointer: &str| trust.pointer(pointer).and_then(Value::as_str);
    let level = if trust.get("decided").and_then(Value::as_bool) == Some(true) {
        level("/level")
    } else {
        match family {
            Some(family @ ("claude" | "codex")) => level(&format!("/harnesses/{family}")),
            _ => level("/level"),
        }
    };
    level == Some("trusted")
}

/// The family `harness` (else the default harness) resolves to in acpmux's
/// catalog (`_acpmux/harnesses`): a family name is its own family, a
/// harness its profile's family. None for a name the catalog does not know
/// (a folder profile, which a remote start never uses, or a typo).
fn catalog_family(catalog: &Value, harness: Option<&str>) -> Option<String> {
    let head = match harness {
        Some(harness) => harness.to_owned(),
        None => catalog.get("defaultHarness").and_then(Value::as_str)?.to_owned(),
    };
    if catalog.get("families").and_then(Value::as_object).is_some_and(|f| f.contains_key(&head)) {
        return Some(head);
    }
    catalog
        .get("harnesses")
        .and_then(|harnesses| harnesses.get(&head))
        .and_then(|profile| profile.get("family"))
        .and_then(Value::as_str)
        .filter(|family| !family.is_empty())
        .map(str::to_owned)
}

fn refused_family(table: &Value, family: &str) -> bool {
    table
        .get("refusedFamilies")
        .and_then(Value::as_array)
        .is_some_and(|refused| refused.iter().any(|name| name.as_str() == Some(family)))
}

/// acpmux's remote rule for a new session: its family is not refused and
/// its mode asks (no mode counts as asking), else it moves to the family's
/// asking default; anything else is refused. Returns the session's family.
fn settle_asking_mode(link: &AcpmuxLink, session: &str) -> Result<String, Refusal> {
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
    let family =
        table.pointer("/session/family").and_then(Value::as_str).unwrap_or_default().to_string();
    match asks(&table) {
        (true, _) => Ok(family),
        (false, None) => Err(Refusal::NotAsking),
        (false, Some(default)) => {
            link.call(
                "session/set_mode",
                json!({"sessionId": session, "modeId": default}),
                CALL_TIMEOUT,
            )
            .map_err(|_| Refusal::NotAsking)?;
            if asks(&read()?).0 { Ok(family) } else { Err(Refusal::NotAsking) }
        }
    }
}

impl Mux {
    /// The machine kind gate of `agent-session-start` (team VM, Cloud VM of
    /// unknown kind, or never told), read again at each call; a guarded
    /// chat move in (`agent_transfer.rs`) takes the same rule.
    pub(crate) fn agent_host_gate(&self) -> Result<(), Refusal> {
        self.control_clients.agent_sessions.starts.host_gate()
    }
}
