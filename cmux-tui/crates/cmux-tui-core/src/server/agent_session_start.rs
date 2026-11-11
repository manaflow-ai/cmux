//! Remote agent session start (`agent-session-start-v1`): a trusted local
//! client (an app on another Mac, through the SSH or Cloud carrier) starts
//! a new chat for an agent tab of THIS daemon's store in this machine's own
//! acpmux, and the daemon binds it to the tab. The app then shows the chat
//! through `agent-session-attach-v1` (the parent module); no acpmux port is
//! opened.
//!
//! `agent-session-start {surface, harness?, model?, cwd?}` answers
//! `{surface, session, conversation}` once acpmux made the session and the
//! store recorded it on the tab (`bind-conversation-tab-session` with
//! expected null, this daemon being the writer).
//!
//! Scope: the tab must be an `agent_session` tab of this store with no
//! session yet, whose record names this store as its host
//! (`registry:<identify.session_id>`), so a tab recorded for another
//! machine never starts here. The client names only an agent kind
//! (`harness`, resolved by acpmux from its own config), an optional model (`model`), and a folder (`cwd`,
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
//! Except on the caller's own Cloud VM ([`AgentStartHost::OwnerCloud`] or
//! [`AgentStartHost::UnknownCloud`] with the caller's `vm_kind: "owner"`,
//! the Cloud API's answer for it): that machine is a disposable sandbox the
//! person owns, so any agent starts there, Codex and opencode included, in
//! its own default mode (still with policy `ask`). A Mac, an SSH host and a
//! team VM keep the rule above ([`AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY`]).
//!
//! acpmux runs on demand: when nothing listens on the socket, the daemon
//! starts it once through the binary's starter (`cmux acp daemon start`,
//! as `cmux acp` does) and connects again; otherwise
//! `agent_session.acpmux_unavailable`.
//!
//! The answer also carries `timings_ms`, this machine's own clock for each
//! phase of the start ([`StartTimings`]): the keyed gate, the acpmux connect
//! (and whether it had to start acpmux), the checks before the agent, the
//! harness's `session/new`, the mode settle and the bind. The app logs it
//! beside its own start steps, so a Cloud start's `start` step splits into
//! the harness launch and everything around it (cmuxterm-hq probe rows).
//! Durations only: no folder, harness or session value is in it.

use crate::panic_free::JsonFields;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_link::{AcpmuxLink, LinkError, Patience};
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::{ConversationTabRecord, validate_harness};

pub const AGENT_SESSION_START_CAPABILITY: &str = "agent-session-start-v1";
/// A start may omit `cwd`; the daemon creates a fresh Cloud chat folder.
pub const AGENT_SESSION_START_NO_CWD_CAPABILITY: &str = "agent-session-start-no-cwd-v1";
/// `require_person_key` and `person_instance` on `agent-session-start`, and
/// its typed `agent_session.needs_keyed_start` refusal (cx-0w0jj).
pub const AGENT_SESSION_START_KEYED_REASON_CAPABILITY: &str = "agent-session-start-keyed-reason-v1";
/// `vm_kind` on `agent-session-start`: the caller's word that the Cloud API
/// answered `vmKind: "owner"` for it on this link, which a start on a Cloud
/// VM needs ([`AgentStartHost::OwnerCloud`]). Any other value says the caller
/// knows this machine is a Cloud VM it does not own: refused on any host, as
/// a guest's root can remove every sign of a Cloud VM here.
pub const AGENT_SESSION_START_VM_KIND_CAPABILITY: &str = "agent-session-start-vm-kind-v1";
/// `model` on `agent-session-start` is relayed to acpmux's first `session/new`.
pub const AGENT_SESSION_START_MODEL_CAPABILITY: &str = "agent-session-start-model-v1";
/// On a Cloud VM with the caller's `vm_kind: "owner"`, `agent-session-start`
/// starts any agent (Codex and opencode too) without the asking-mode rule.
/// Advertised only where this machine reads as a Cloud VM with no team
/// evidence (never a Mac, an SSH host or a team VM):
/// the person's own disposable VM is the boundary (Leo, 2026-10-30, on
/// ChatGPT's "Where should this chat run?": "we should just have it").
pub const AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY: &str = "agent-session-start-owner-cloud-v1";

/// Starts the binary's acpmux daemon (blocking; acpmux bounds its own start).
pub type AcpmuxStarter = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

/// What kind of machine this daemon runs on, as the binary reads it from the
/// machine's own identity at each start. A remote start is served on
/// [`AgentStartHost::Allowed`], and on any Cloud VM (a team VM included) only
/// when the caller says the Cloud API answered `vmKind: "owner"` for it
/// (`vm_kind`); a daemon that was never told refuses (fail closed).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum AgentStartHost {
    /// A Mac or an SSH host (not a Cloud VM).
    Allowed,
    /// A Cloud VM whose own record says `owner`. The guest's root writes that
    /// record (agents keep sudo there), so it never allows anything by
    /// itself: a start, a chat move in and folder trust each need the
    /// caller's `vm_kind: "owner"`.
    OwnerCloud,
    /// A Cloud VM whose kind the daemon cannot tell: as [`Self::OwnerCloud`].
    UnknownCloud,
    /// A team VM: shared by a team. A remote start goes on only on the
    /// caller's `vm_kind: "owner"`, which the Cloud API gives the machine's
    /// creator alone; anyone else is refused (hq-84 rule for teammates until
    /// the team's chat grants exist).
    TeamVm,
}

/// Starts that may run at once on one daemon.
const MAX_STARTS: usize = 8;
const MAX_CWD_BYTES: usize = 4096;
/// How each acpmux call of a start waits ([`AcpmuxLink::call_while_alive_until`]): a harness spawning
/// and answering `session/new` in a big folder, or reading its catalog there, on a machine under
/// load, takes as long as it takes while acpmux still answers beside it. Was a fixed 60 s for
/// `session/new` and 5 s for each check, which failed the starts of a 1.9 GB and a 20,000-file
/// folder with `agent_session.timeout` while acpmux was still working (cmux#40385's matrix). A
/// silent acpmux fails the start within `quiet + probe` (the status answer reads the host's
/// load, so a busy machine gets 30 s for it); the ceiling, one for the whole start, is the login
/// finish's. This covers the catalog read (`_acpmux/harnesses`) too: a starting acpmux holds that
/// answer until its login shell read and catalog reload end (`Hub::harnesses_reply`), and the app
/// restarts acpmux with a person key just before a Cloud chat's start, so a fixed 5 s refused it
/// `agent_session.timeout` while acpmux was about to answer (cmuxterm-hq run 42837396397).
pub(super) const START_PATIENCE: Patience = Patience {
    quiet: Duration::from_secs(10),
    probe: Duration::from_secs(30),
    ceiling: Duration::from_secs(15 * 60),
};
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a start waits for an acpmux that went away under its catalog read (restarting) to
/// listen again ([`ready_catalog`]), and the pause between connects.
const RECONNECT_WAIT: Duration = Duration::from_secs(20);
const RECONNECT_PAUSE: Duration = Duration::from_millis(200);
/// How long after a `session/new` failed as a timeout its answer is still waited for, to end the
/// session acpmux made for a start that already gave up (Codex review of cmux#40640 at
/// 00411eb5: an agent spawned after the start stopped waiting stayed bound to no tab).
const LATE_SESSION_GRACE: Duration = Duration::from_secs(300);

/// One acpmux call of a start, waiting on acpmux's liveness ([`START_PATIENCE`]) until the
/// start's one ceiling, `until`.
fn ask(link: &AcpmuxLink, until: Instant, method: &str, params: Value) -> Result<Value, LinkError> {
    link.call_while_alive_until(method, params, START_PATIENCE, until)
}
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
    /// kind is read again for every call, so a bind or team enroll that
    /// lands after the daemon started counts at once. `caller_owns_vm`: the
    /// call's `vm_kind` is exactly `owner` (the Cloud API's answer for the
    /// caller on its link). A Cloud VM goes on only on that word, never on
    /// its own record. On a team VM the same word lets the caller in: the
    /// Cloud API answers `owner` per caller, for the machine's creator only
    /// (web vmKindForCaller since #28788), so a teammate who did not create
    /// it still gets [`Refusal::TeamVmBlocked`] (Leo, 2026-10-31: "we can't
    /// simply block always").
    fn host_gate(&self, caller_owns_vm: bool) -> Result<(), Refusal> {
        let source = self.host.lock().unwrap_or_else(|e| e.into_inner()).clone();
        match source.map(|read| read()) {
            Some(AgentStartHost::Allowed) => Ok(()),
            Some(
                AgentStartHost::OwnerCloud | AgentStartHost::UnknownCloud | AgentStartHost::TeamVm,
            ) if caller_owns_vm => Ok(()),
            Some(AgentStartHost::TeamVm) => Err(Refusal::TeamVmBlocked),
            _ => Err(Refusal::HostUnverified),
        }
    }

    /// Whether a start runs on the caller's own Cloud VM: this machine is a
    /// Cloud VM with no team evidence and the caller's `vm_kind` is exactly
    /// `owner`. Never a Mac or an SSH host (not a disposable sandbox of the
    /// person's), never a team VM. Read again at each start.
    pub(super) fn owner_cloud(&self, caller_owns_vm: bool) -> bool {
        let source = self.host.lock().unwrap_or_else(|e| e.into_inner()).clone();
        caller_owns_vm
            && matches!(
                source.map(|read| read()),
                Some(AgentStartHost::OwnerCloud | AgentStartHost::UnknownCloud)
            )
    }

    /// Whether this machine is a Cloud VM of any kind (a team VM included), as
    /// the machine kind gate reads it at each call.
    pub(super) fn on_cloud_vm(&self) -> bool {
        let source = self.host.lock().unwrap_or_else(|e| e.into_inner()).clone();
        matches!(
            source.map(|read| read()),
            Some(
                AgentStartHost::OwnerCloud | AgentStartHost::UnknownCloud | AgentStartHost::TeamVm
            )
        )
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

/// This machine's own clock for each phase of one start, in ms (module
/// docs). A phase the start never reached stays None and is left out.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct StartTimings {
    keyed_gate: Option<u64>,
    acpmux_connect: Option<u64>,
    /// The connect found nothing listening and started acpmux first.
    acpmux_started: bool,
    checks: Option<u64>,
    session_new: Option<u64>,
    settle: Option<u64>,
    bind: Option<u64>,
    total: Option<u64>,
}

/// Milliseconds since `since`, saturating.
fn ms_since(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

impl StartTimings {
    /// The answer's `timings_ms`: each phase reached, and `acpmux_started`.
    pub(crate) fn wire(&self) -> Value {
        let mut out = serde_json::Map::new();
        for (name, value) in [
            ("keyed_gate", self.keyed_gate),
            ("acpmux_connect", self.acpmux_connect),
            ("checks", self.checks),
            ("session_new", self.session_new),
            ("settle", self.settle),
            ("bind", self.bind),
            ("total", self.total),
        ] {
            if let Some(value) = value {
                out.insert(name.to_owned(), json!(value));
            }
        }
        out.insert("acpmux_started".to_owned(), json!(self.acpmux_started));
        Value::Object(out)
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
    #[serde(default)]
    model: Option<String>,
    /// The selected folder on the machine. A missing folder is allowed only
    /// for the caller's own Cloud VM, where Rust creates `~/chats/<id>`.
    #[serde(default)]
    cwd: Option<String>,
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
    /// The Cloud API's `vmKind` for the caller on its link to this machine,
    /// as the caller read it. Only the exact `owner` lets a start run on a
    /// Cloud VM; any other value, `null` included, refuses the start. The
    /// outer `None` is an absent field (a caller from before the param).
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
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
        let instance_ok = self.person_instance.as_deref().is_none_or(|instance| {
            (1..=128).contains(&instance.len())
                && instance.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
        });
        let model_ok = self.model.as_deref().is_none_or(|model| {
            (1..=200).contains(&model.len())
                && !model.starts_with('-')
                && !model.chars().any(|c| c.is_whitespace() || c.is_control())
                && !model.contains(['{', '}', '$', '"', '\\', '\''])
        });
        harness_ok && cwd_ok && instance_ok && model_ok
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
    mut params: StartParams,
    writer: &MessageWriter,
) -> bool {
    if !params.valid() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    if let Err(refusal) = mux.agent_host_gate(client, vm_word(&params.vm_kind)) {
        return refuse(writer, id, refusal);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    // On the caller's own Cloud VM a new chat with no folder gets a fresh
    // per-chat folder. Non-Cloud hosts retain the required-folder behavior.
    let own = super::agent_session_trust::callers_own_cloud_vm(mux, &params.vm_kind);
    if let Some(work) = super::agent_session_trust::owner_cloud_cwd(
        own,
        params.cwd.as_deref(),
        params.home_confirmed,
        params.surface,
    ) {
        params.cwd = Some(work);
    }
    // A pre-capability Cloud caller cannot send the owner word, so preserve
    // its historical work-folder start. Non-Cloud callers still need to send
    // an explicit folder.
    if params.cwd.is_none() && mux.control_clients.agent_sessions.starts.on_cloud_vm() {
        params.cwd = super::agent_session_folders::own_work_folder(true)
            .map(|path| path.to_string_lossy().into_owned());
    }
    if params.cwd.is_none() {
        return refuse(writer, id, Refusal::BadRequest);
    }
    // A chat never starts in `/`, above the home folder, or in the home folder
    // unless the person chose it (cx-1bhjj), as on the Mac.
    let Some(cwd) = params.cwd.as_deref() else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    if let Err(refusal) = super::agent_session_trust::home_rule(cwd, params.home_confirmed) {
        return refuse(writer, id, refusal);
    }
    // A phone's start (the Cloud mobile carrier, `cloud-mobile-chat-v1`) gets the phone's floor.
    // Read here, before the worker: a phone that leaves mid-start must not lift it.
    let phone =
        mux.control_clients.supports_capability(client, super::CLOUD_MOBILE_CHAT_CAPABILITY);
    let Some(slot) = AgentSessionStarts::reserve(mux, params.surface) else {
        return refuse(writer, id, Refusal::Limit);
    };
    let surface = params.surface;
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-start".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let began = Instant::now();
            let mut timings = StartTimings::default();
            let gated = keyed_gate(&socket, &params);
            timings.keyed_gate = Some(ms_since(began));
            let result = match gated {
                Ok(()) => run(&worker_mux, client, socket, params, phone, &mut timings),
                Err(refused) => Err(refused),
            };
            drop(slot);
            timings.total = Some(ms_since(began));
            match result {
                Ok(mut data) => {
                    data.insert("timings_ms", timings.wire());
                    // Before the answer: the caller may close the tab as soon as it reads it
                    // (phone_carrier.rs).
                    worker_mux.control_clients.remember_started_tab(client, surface);
                    ok(&worker_writer, worker_id, data)
                }
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
    keyed_by(status.as_ref(), params)
}

/// [`keyed_gate`] again on `link`, the acpmux the start runs on: the gate read the acpmux that
/// listened before the start, and a restart since ([`ready_catalog`]) brings a run the caller may
/// hold no key for, whose permission prompts it then could not approve.
fn still_keyed(link: &AcpmuxLink, params: &StartParams) -> Result<(), (Refusal, Option<Value>)> {
    if !params.require_person_key {
        return Ok(());
    }
    let status = link
        .call("_acpmux/status", json!({}), CALL_TIMEOUT)
        .map_err(|_| (Refusal::NeedsKeyedStart, Some(keyed_restart_reason(Some(&json!({}))))))?;
    keyed_by(Some(&status), params)
}

/// Ok when `status` (`_acpmux/status`; None: acpmux does not run) holds a person key for the
/// caller's `person_instance`, else the typed `needs_keyed_start` refusal.
fn keyed_by(status: Option<&Value>, params: &StartParams) -> Result<(), (Refusal, Option<Value>)> {
    let keyed = status.is_some_and(|status| {
        status.get("personKey").and_then(Value::as_bool) == Some(true)
            && params.person_instance.is_some()
            && status.get("personInstance").and_then(Value::as_str)
                == params.person_instance.as_deref()
    });
    if keyed {
        return Ok(());
    }
    Err((Refusal::NeedsKeyedStart, Some(keyed_restart_reason(status))))
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
    phone: bool,
    timings: &mut StartTimings,
) -> Result<Value, (Refusal, Option<Value>)> {
    let began = Instant::now();
    let (link, started) = connect_noting(mux, &socket).map_err(|r| (r, None))?;
    (timings.acpmux_connect, timings.acpmux_started) = (Some(ms_since(began)), started);
    let checks = Instant::now();
    let until = checks + START_PATIENCE.ceiling;
    let cwd = params.cwd.as_deref().ok_or((Refusal::BadRequest, None))?;
    let (link, catalog) = ready_catalog(&socket, link, cwd, until).map_err(|r| (r, None))?;
    let result = still_keyed(&link, &params).and_then(|()| {
        start_and_bind(mux, client, &link, &catalog, &params, phone, checks, until, timings)
            .map_err(|r| (r, None))
    });
    link.close();
    result
}

/// acpmux's catalog for a start in `cwd`, read as long as acpmux is alive ([`START_PATIENCE`]:
/// a starting acpmux holds it until its `catalog_ready`), by `until`. An acpmux that goes away
/// under the read, or is not listening yet, is one restarting (the app's keyed restart for remote
/// approvals, 0.3 s before the start in cmuxterm-hq run 42837396397): the read connects again and
/// asks again until `until`. It never runs the starter again: the restart brings its own acpmux,
/// and a second start here would race it. The read changes nothing, so asking twice is safe; what
/// the start changes comes after it, on the link this returns.
fn ready_catalog(
    socket: &std::path::Path,
    mut link: Arc<AcpmuxLink>,
    cwd: &str,
    until: Instant,
) -> Result<(Arc<AcpmuxLink>, Value), Refusal> {
    loop {
        match ask(&link, until, "_acpmux/harnesses", json!({"cwd": cwd})) {
            Ok(catalog) => return Ok((link, catalog)),
            Err(LinkError::Closed) if Instant::now() < until => link.close(),
            Err(error) => {
                link.close();
                return Err(Refusal::of(error));
            }
        }
        // A restart brings its acpmux up in seconds; one that stays down is gone.
        let back_by = until.min(Instant::now() + RECONNECT_WAIT);
        link = loop {
            std::thread::sleep(RECONNECT_PAUSE);
            match AcpmuxLink::connect(socket, |_| {}) {
                Ok(link) => break link,
                Err(_) if Instant::now() < back_by => {}
                Err(_) => return Err(Refusal::Unavailable),
            }
        };
    }
}

/// A link to acpmux, starting it once when nothing listens (also an
/// `agent-update-apply`, `agent_update.rs`).
pub(in crate::server) fn connect(
    mux: &Mux,
    socket: &std::path::Path,
) -> Result<Arc<AcpmuxLink>, Refusal> {
    connect_noting(mux, socket).map(|(link, _)| link)
}

/// [`connect`], and whether this call ran the starter (nothing listened).
fn connect_noting(mux: &Mux, socket: &std::path::Path) -> Result<(Arc<AcpmuxLink>, bool), Refusal> {
    let open = || AcpmuxLink::connect(socket, |_| {});
    if let Ok(link) = open() {
        return Ok((link, false));
    }
    let starts = &mux.control_clients.agent_sessions.starts;
    let starter = starts.starter().ok_or(Refusal::AcpmuxUnavailable)?;
    let _one_start = starts.start_lock.lock().unwrap_or_else(|e| e.into_inner());
    // Another start may have brought acpmux up while this one waited.
    if let Ok(link) = open() {
        return Ok((link, false));
    }
    starter().map_err(|_| Refusal::AcpmuxUnavailable)?;
    open().map(|link| (link, true)).map_err(|_| Refusal::AcpmuxUnavailable)
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

/// `phone`: the caller declared `cloud-mobile-chat-v1` (read before the start's worker).
/// `timings`: each phase reached, on this machine's clock.
/// `catalog`: acpmux's catalog for the start's folder ([`ready_catalog`]); `checks`: when the
/// checks before the agent began (the readiness wait included); `until`: the start's one ceiling.
#[allow(clippy::too_many_arguments)]
fn start_and_bind(
    mux: &Arc<Mux>,
    client: u64,
    link: &Arc<AcpmuxLink>,
    catalog: &Value,
    params: &StartParams,
    phone: bool,
    checks: Instant,
    until: Instant,
    timings: &mut StartTimings,
) -> Result<Value, Refusal> {
    let cwd = params.cwd.as_deref().ok_or(Refusal::BadRequest)?;
    let owner_cloud = mux
        .control_clients
        .agent_sessions
        .starts
        .owner_cloud(vm_word(&params.vm_kind) == Some("owner"));
    // A phone's start gets the phone's floor, also on the caller's own Cloud VM: an acpmux that
    // holds Cloud mobile prompts to it, a family the floor has a mode for, and that mode before
    // the start answers.
    let table = ask(link, until, "_acpmux/web_modes", json!({})).map_err(Refusal::of)?;
    if phone && table.get("cloudMobileStrictFloor").and_then(Value::as_u64) != Some(1) {
        return Err(Refusal::NotAsking);
    }
    // The family the start resolves to, from acpmux's own catalog, before
    // any agent process exists: a Codex alias or a default harness of a
    // refused family never starts (but on the caller's own Cloud VM).
    let family = catalog_family(catalog, params.harness.as_deref()).ok_or(Refusal::NotAsking)?;
    // A phone's family is held to its own floor instead: acpmux refuses Codex as a Web family,
    // but a Codex bridge session holds to the phone floor in `ask`, which only the session's
    // `cloudMobileAsks` can tell from Codex's adapter (`settle_phone_mode`).
    if !owner_cloud && !phone && refused_family(&table, &family) {
        return Err(Refusal::NotAsking);
    }
    if phone && phone_modes(&family).is_empty() {
        return Err(Refusal::NotAsking);
    }
    // The folder must be trusted before an agent starts there (an agent can
    // run the folder's own hooks and settings at start); this daemon reaches
    // acpmux over its unix socket, which acpmux's trust gate does not hold;
    // only the person answers it (`agent-session-trust`, from the app).
    let trust = ask(link, until, "acp.trust.get", json!({"cwd": cwd})).map_err(Refusal::of)?;
    // The caller's own Cloud VM's work folder reads trusted (no question).
    let trust = super::agent_session_trust::owner_cloud_trust(
        super::agent_session_trust::callers_own_cloud_vm(mux, &params.vm_kind),
        trust,
    );
    if !folder_trusted(&trust, params.harness.as_deref()) {
        return Err(Refusal::UntrustedFolder);
    }
    let mut meta = json!({"policy": "ask"});
    if let Some(harness) = &params.harness {
        meta.insert("harness", json!(harness));
    }
    if let Some(model) = &params.model {
        meta.insert("model", json!(model));
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
    timings.checks = Some(ms_since(checks));
    let spawn = Instant::now();
    // acpmux goes on spawning the agent after a start stops waiting: a session it makes later is
    // bound to no tab, so it ends as soon as its answer comes.
    let created = link
        .call_while_alive_or_late(
            "session/new",
            new,
            START_PATIENCE,
            until,
            LATE_SESSION_GRACE,
            |link, late| {
                if let Some(session) = late.get("sessionId").and_then(Value::as_str) {
                    let kill = json!({"sessionId": session, "purge": true});
                    let _ = link.call("_acpmux/kill", kill, CALL_TIMEOUT);
                }
            },
        )
        .map_err(Refusal::of);
    timings.session_new = Some(ms_since(spawn));
    let created = created?;
    let settle = Instant::now();
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
    let family = if phone {
        settle_phone_mode(link, until, &session).map_err(end)?
    } else if owner_cloud {
        session_family(link, until, &session).map_err(end)?
    } else {
        settle_asking_mode(link, until, &session).map_err(end)?
    };
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
    timings.settle = Some(ms_since(settle));
    let bind = Instant::now();
    // The tab may have closed, or another start bound it, meanwhile.
    let actor = super::super::origin_gate::connection_actor(mux, client);
    let _rebinding = mux.control_clients.agent_sessions.rebinding();
    let bound = mux
        .bind_conversation_tab_session_as(&actor, params.surface, &session, None, harness)
        .map_err(|_| end(startable(mux, params.surface).err().unwrap_or(Refusal::Refused)));
    timings.bind = Some(ms_since(bind));
    let (record, _) = bound?;
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

/// The family acpmux reports for `session` (`_acpmux/web_modes`), with no
/// mode rule: a start on the caller's own Cloud VM. None is refused.
fn session_family(link: &AcpmuxLink, until: Instant, session: &str) -> Result<String, Refusal> {
    let table = ask(link, until, "_acpmux/web_modes", json!({"sessionId": session}))
        .map_err(Refusal::of)?;
    table
        .pointer("/session/family")
        .and_then(Value::as_str)
        .filter(|family| !family.is_empty())
        .map(str::to_owned)
        .ok_or(Refusal::Refused)
}

/// acpmux's remote rule for a new session: its family is not refused and
/// its mode asks (no mode counts as asking), else it moves to the family's
/// asking default; anything else is refused. Returns the session's family.
fn settle_asking_mode(link: &AcpmuxLink, until: Instant, session: &str) -> Result<String, Refusal> {
    let read = || {
        ask(link, until, "_acpmux/web_modes", json!({"sessionId": session})).map_err(Refusal::of)
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
            ask(link, until, "session/set_mode", json!({"sessionId": session, "modeId": default}))
                .map_err(|_| Refusal::NotAsking)?;
            if asks(&read()?).0 { Ok(family) } else { Err(Refusal::NotAsking) }
        }
    }
}

/// The modes a phone's chat may run in, by family, in the order a start tries them: acpmux's
/// Cloud mobile floor (`Hub::cloud_mobile_mode_asks`), which has the last word on each.
fn phone_modes(family: &str) -> &'static [&'static str] {
    match family {
        "claude" => &["default", "plan"],
        "codex" => &["ask"],
        _ => &[],
    }
}

/// A phone's new session: acpmux says its mode holds to the Cloud mobile floor
/// (`cloudMobileAsks`, which reads the harness profile the session actually runs), else it moves
/// to the family's phone modes in turn until acpmux says so; anything else is refused (the caller
/// ends the session). Returns the session's family.
fn settle_phone_mode(link: &AcpmuxLink, until: Instant, session: &str) -> Result<String, Refusal> {
    let read = || -> Result<(String, bool), Refusal> {
        let table = ask(link, until, "_acpmux/web_modes", json!({"sessionId": session}))
            .map_err(Refusal::of)?;
        let family =
            table.pointer("/session/family").and_then(Value::as_str).unwrap_or_default().to_owned();
        let asks = table.pointer("/session/cloudMobileAsks").and_then(Value::as_bool) == Some(true);
        Ok((family, asks))
    };
    let (family, asks) = read()?;
    if family.is_empty() {
        return Err(Refusal::NotAsking);
    }
    if asks {
        return Ok(family);
    }
    for mode in phone_modes(&family) {
        let set =
            ask(link, until, "session/set_mode", json!({"sessionId": session, "modeId": mode}));
        if set.is_ok() && read()? == (family.clone(), true) {
            return Ok(family);
        }
    }
    Err(Refusal::NotAsking)
}

/// A call's `vm_kind` (decoded with `present_nullable`) as the gate reads it:
/// absent is no word, and an explicit `null` is a word that is not `owner`.
pub(crate) fn vm_word(vm_kind: &Option<Option<String>>) -> Option<&str> {
    vm_kind.as_ref().map(|kind| kind.as_deref().unwrap_or_default())
}

impl Mux {
    /// The machine kind gate of a start, a guarded chat move in
    /// (`agent_transfer.rs`) and folder trust, read again at each call:
    /// Native token connections use the signed role bound before their first
    /// frame. Missing Native roles never fall back to the request. Other
    /// connections retain the caller API answer (only exact `owner`). Any other
    /// word says the caller knows this machine is a Cloud VM it does not own:
    /// refused on any host, as a guest's root can remove every Cloud sign here.
    pub(crate) fn agent_host_gate(
        &self,
        client: u64,
        vm_kind: Option<&str>,
    ) -> Result<(), Refusal> {
        let signed = {
            let state = self.control_clients.state.lock().map_err(|_| Refusal::HostUnverified)?;
            state.clients.get(&client).ok_or(Refusal::HostUnverified)?.native_vm_kind
        };
        let vm_kind = match signed {
            Some(Some(cmux_link::token::VmKind::Team)) => return Err(Refusal::TeamVmBlocked),
            Some(None) => return Err(Refusal::HostUnverified),
            Some(Some(cmux_link::token::VmKind::Owner)) => {
                if vm_kind.is_some_and(|kind| kind != "owner") {
                    return Err(Refusal::HostUnverified);
                }
                Some("owner")
            }
            None => vm_kind,
        };
        self.control_clients.agent_sessions.starts.host_gate(vm_kind == Some("owner"))?;
        match vm_kind {
            Some(kind) if kind != "owner" => Err(Refusal::HostUnverified),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A call on a Cloud VM (a start, a chat move in, folder trust) runs only
    /// on the caller's `vm_kind: "owner"`; the VM's own `owner` record never
    /// allows it. On a team VM that word (the creator's, from the Cloud API)
    /// lets the call in too; without it a team VM still says so.
    #[test]
    fn a_call_on_a_cloud_vm_needs_the_callers_owner_word() {
        use AgentStartHost::{Allowed, OwnerCloud, TeamVm, UnknownCloud};
        let starts = AgentSessionStarts::default();
        assert_eq!(starts.host_gate(true), Err(Refusal::HostUnverified));
        let unverified = Err(Refusal::HostUnverified);
        let team = Err(Refusal::TeamVmBlocked);
        let cases = [
            (Allowed, Ok(()), Ok(())),
            (OwnerCloud, Ok(()), unverified),
            (UnknownCloud, Ok(()), unverified),
            (TeamVm, Ok(()), team),
        ];
        for (host, owner_word, no_word) in cases {
            starts.set_host(Arc::new(move || host));
            assert_eq!(starts.host_gate(true), owner_word, "{host:?}");
            assert_eq!(starts.host_gate(false), no_word, "{host:?}");
        }
    }

    /// The answer's `timings_ms` names each phase the start reached, in ms,
    /// and whether it started acpmux; a phase it never reached is left out.
    #[test]
    fn timings_name_each_phase_reached() {
        let none = StartTimings::default().wire();
        assert_eq!(none, json!({"acpmux_started": false}));
        let all = StartTimings {
            keyed_gate: Some(1),
            acpmux_connect: Some(2),
            acpmux_started: true,
            checks: Some(3),
            session_new: Some(1800),
            settle: Some(4),
            bind: Some(5),
            total: Some(1815),
        };
        assert_eq!(
            all.wire(),
            json!({"keyed_gate": 1, "acpmux_connect": 2, "acpmux_started": true, "checks": 3,
                   "session_new": 1800, "settle": 4, "bind": 5, "total": 1815})
        );
        let gated = StartTimings { keyed_gate: Some(7), total: Some(7), ..Default::default() };
        assert_eq!(gated.wire(), json!({"keyed_gate": 7, "total": 7, "acpmux_started": false}));
    }

    /// Only a Cloud VM with no team evidence, and only on the caller's owner
    /// word, lifts the asking-mode rule; a Mac or SSH host and a team VM never.
    #[test]
    fn only_the_callers_own_cloud_vm_starts_any_agent() {
        use AgentStartHost::{Allowed, OwnerCloud, TeamVm, UnknownCloud};
        let starts = AgentSessionStarts::default();
        assert!(!starts.owner_cloud(true));
        for (host, any_agent) in
            [(Allowed, false), (OwnerCloud, true), (UnknownCloud, true), (TeamVm, false)]
        {
            starts.set_host(Arc::new(move || host));
            assert_eq!(starts.owner_cloud(true), any_agent, "{host:?}");
            assert!(!starts.owner_cloud(false), "{host:?}");
        }
    }
}
