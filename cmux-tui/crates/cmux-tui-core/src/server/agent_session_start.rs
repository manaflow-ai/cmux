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
//! absolute; acpmux checks it), and on the caller's own Cloud VM a mode (`mode`, below). No command, env, policy, peer, preset,
//! workspace or MCP server param exists (an unknown field is dropped unread).
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
//! the person's own start mode (`permission_mode`, [`start_policy`]: policy `ask` only when
//! that is `ask`). Under full access a Claude chat with no pick then moves to Claude Code's Auto,
//! keeping Bypass permissions where Claude Code refuses it ([`cloud_default_mode`]). A Mac, an SSH
//! host and a team VM keep the rule above ([`AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY`]).
//!
//! There, and only there, the person's own mode pick (`mode`,
//! [`AGENT_SESSION_START_MODE_CAPABILITY`]) is what the chat starts in (Leo, 2026-11-10: "but
//! shouldnt the user be allowed to just go through with stuff?"): acpmux gets it as
//! `_meta.acpmux.mode` and applies it under its own start rules (`hub/start_gate.rs`). A pick
//! that asks keeps policy `ask`. A pick that does not ask (Claude Code's Bypass permissions, the
//! Codex bridge's full access) starts with no policy of the start's own: policy `ask` would hold
//! every tool call whatever the mode (acpmux's policy gate, W5-L) and refuse the move to it
//! (`refuse_wider_mode`), so the pick could never apply. A start on any other host (a Mac, an SSH
//! host, a team VM, a teammate's connection) ignores `mode`: policy `ask` and the asking-mode rule
//! hold there as before.
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

#[path = "agent_session_prewarm.rs"]
mod prewarm;
pub(crate) use prewarm::chat_folder_prewarm_on;
pub(super) use prewarm::prewarm;
pub use prewarm::{AGENT_SESSION_PREWARM_CAPABILITY, AGENT_SESSION_PREWARM_CHAT_FOLDER_CAPABILITY};
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
/// `mode` on `agent-session-start`: the permission mode the person picked for the chat, applied
/// only on the caller's own Cloud VM (module docs). Elsewhere the param is ignored.
pub const AGENT_SESSION_START_MODE_CAPABILITY: &str = "agent-session-start-mode-v1";
/// On a Cloud VM with the caller's `vm_kind: "owner"`, `agent-session-start`
/// starts any agent (Codex and opencode too) without the asking-mode rule.
/// Advertised only where this machine reads as a Cloud VM with no team
/// evidence (never a Mac, an SSH host or a team VM):
/// the person's own disposable VM is the boundary (Leo, 2026-10-30, on
/// ChatGPT's "Where should this chat run?": "we should just have it").
pub const AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY: &str = "agent-session-start-owner-cloud-v1";
/// `permission_mode` on `agent-session-start` (`fullAccess`, `standard` or `ask`): the person's
/// `agents.defaultPermissionMode` on the caller's app, which a start on the caller's own Cloud VM
/// takes as a new chat on that app takes it ([`start_policy`]). Advertised wherever the start is
/// served; a start anywhere but the caller's own Cloud VM reads the field and keeps policy `ask`.
pub const AGENT_SESSION_START_PERMISSION_MODE_CAPABILITY: &str =
    "agent-session-start-permission-mode-v1";

/// `credentials: {env: {NAME: value}}` on `agent-session-start`, and the `agent-session-credentials
/// {surface, env, vm_kind}` refresh: the owner's model credential for the chat's agent, from the
/// owner's own app on the owner's own Cloud VM only ([`credentials_admitted`]), relayed to acpmux
/// (`_meta.acpmux.credentials`, `agent/credentials.update`), which holds it in memory for that agent
/// alone (acpmux `agent_credentials.rs`). Advertised only where the owner-Cloud start is.
pub const AGENT_SESSION_START_CREDENTIALS_CAPABILITY: &str = "agent-session-start-credentials-v1";
/// A Codex credential (an OpenAI key or a ChatGPT sign-in's token) on `agent-session-start` reaches
/// Codex: acpmux puts its provider override after `app-server`, where codex keeps it (an older
/// acpmux put it before, codex dropped it, and the chat ran on no key). The app updates a machine
/// that lacks this before a Codex start carries a credential (cmux#45774). Advertised beside
/// [`AGENT_SESSION_START_CREDENTIALS_CAPABILITY`].
pub const AGENT_SESSION_START_CODEX_CREDENTIALS_CAPABILITY: &str =
    "agent-session-start-codex-credentials-v1";

/// Historical capability for the Revision 3 endpoint launch credential.
pub const AGENT_SESSION_START_ENDPOINT_CREDENTIALS_CAPABILITY: &str =
    "agent-session-start-endpoint-credentials-v1";

/// The subscription credential capability used by earlier clients.
pub const AGENT_SESSION_START_SUBSCRIPTION_CREDENTIALS_CAPABILITY: &str =
    "agent-session-start-subscription-credentials-v1";

/// The owner's start can select Claude's machine login for the new chat.
pub(in crate::server) const CLAUDE_MACHINE_LOGIN_CAPABILITY: &str =
    "agent-session-start-claude-machine-login-v1";

/// A Cloud VM creator's start can select Claude's team gateway for the new chat.
pub(in crate::server) const CLAUDE_TEAM_ROUTE_CAPABILITY: &str =
    "agent-session-start-claude-team-route-v1";

pub(in crate::server) const CREDENTIAL_REATTACH_CAPABILITY: &str =
    "agent-session-credential-reattach-v1";

/// Credential writes require the tab's durable session id, and launches accept a scoped connection.
pub(in crate::server) const BOUND_CREDENTIALS_CAPABILITY: &str =
    "agent-session-bound-credentials-v1";

/// The names a credential may set (acpmux `agent_credentials::NAMES`).
const CREDENTIAL_NAMES: &[&str] = &[
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "CMUX_CHATGPT_ACCESS_TOKEN",
];
const MAX_CREDENTIAL_BYTES: usize = 16 * 1024;

/// A launch credential as the caller sends it. Never printed: no `Debug`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(in crate::server) struct StartCredentials {
    pub(in crate::server) env: std::collections::BTreeMap<String, String>,
    pub(in crate::server) endpoint: Option<StartEndpoint>,
    pub(in crate::server) connection: Option<String>,
}

/// Endpoint metadata, bounded here and checked by acpmux before launch.
#[derive(Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in crate::server) struct StartEndpoint {
    kind: EndpointKind,
    base_url: String,
    models: Vec<String>,
}

#[derive(Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
enum EndpointKind {
    Anthropic,
    OpenAi,
}

impl StartCredentials {
    /// One known name and a token-shaped value, with optional endpoint and connection metadata.
    pub(in crate::server) fn valid(&self) -> bool {
        self.connection.as_deref().is_none_or(|connection| {
            let (id, digest) = connection
                .split_once(':')
                .map_or((connection, None), |(id, digest)| (id, Some(digest)));
            (1..=64).contains(&id.len())
                && !id.starts_with('-')
                && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && digest.is_none_or(|digest| {
                    digest.len() == 64
                        && digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
                && !self.env.values().any(|value| {
                    connection == value.as_str()
                        || (value.len() >= 6 && connection.contains(value.as_str()))
                })
        }) && self.env.len() == 1
            && self.env.iter().all(|(name, value)| {
                let known = match &self.endpoint {
                    None => {
                        CREDENTIAL_NAMES.contains(&name.as_str())
                            || (name == "ANTHROPIC_AUTH_TOKEN" && value.starts_with("sk-ant-oat"))
                            || matches!(
                                name.as_str(),
                                "GEMINI_API_KEY" | "GOOGLE_API_KEY" | "XAI_API_KEY"
                            )
                    }
                    Some(endpoint) => {
                        let expected = match endpoint.kind {
                            EndpointKind::Anthropic => "ANTHROPIC_AUTH_TOKEN",
                            EndpointKind::OpenAi => "CMUX_BYO_API_KEY",
                        };
                        name == expected
                            && endpoint.base_url.starts_with("https://")
                            && endpoint.base_url.len() <= 2048
                            && (1..=100).contains(&endpoint.models.len())
                            && endpoint.models.iter().all(|model| (1..=200).contains(&model.len()))
                    }
                };
                known
                    && (1..=MAX_CREDENTIAL_BYTES).contains(&value.len())
                    && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~+/=:".contains(&b))
            })
    }

    pub(in crate::server) fn wire(&self) -> Value {
        let mut wire = json!({"env": self.env});
        if let Some(endpoint) = &self.endpoint {
            wire["endpoint"] = json!(endpoint);
        }
        if let Some(connection) = &self.connection {
            wire["connection"] = json!(connection);
        }
        wire
    }
}

/// Whether a credential may be set by `client`: only on the caller's own Cloud VM (its `vm_kind:
/// "owner"`, the Cloud API's answer for the machine's creator alone, on a VM that is not a team
/// VM, where every member's agents run as one Unix user and could read it), never from a phone's
/// channel, and never through a teammate's or guest's proxied link (the caller checks `author`).
pub(in crate::server) fn credentials_admitted(
    mux: &Mux,
    client: u64,
    vm_kind: &Option<Option<String>>,
) -> bool {
    mux.agent_host_gate(client, vm_word(vm_kind)).is_ok()
        && mux.control_clients.agent_sessions.starts.owner_cloud(vm_word(vm_kind) == Some("owner"))
        && !mux.control_clients.supports_capability(client, super::CLOUD_MOBILE_CHAT_CAPABILITY)
}

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
    endpoint_harnesses: std::sync::OnceLock<Vec<&'static str>>,
    /// One acpmux start at a time; the others connect after it.
    start_lock: Mutex<()>,
    starting: Mutex<HashSet<SurfaceId>>,
}

fn installed_endpoint_harnesses() -> Vec<&'static str> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH").unwrap_or_default();
    [
        ("gemini", "agent-session-start-endpoint-harness:gemini"),
        ("grok", "agent-session-start-endpoint-harness:grok"),
    ]
    .into_iter()
    .filter_map(|(harness, capability)| {
        std::env::split_paths(&path)
            .any(|dir| {
                std::fs::metadata(dir.join(harness)).is_ok_and(|metadata| {
                    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
                })
            })
            .then_some(capability)
    })
    .collect()
}

impl AgentSessionStarts {
    pub(crate) fn set_starter(&self, starter: Option<AcpmuxStarter>) {
        *self.starter.lock().unwrap_or_else(|e| e.into_inner()) = starter;
    }

    pub(crate) fn set_host(&self, host: AgentStartHostSource) {
        if matches!(host(), AgentStartHost::OwnerCloud | AgentStartHost::UnknownCloud) {
            self.endpoint_harnesses.get_or_init(installed_endpoint_harnesses);
        }
        *self.host.lock().unwrap_or_else(|e| e.into_inner()) = Some(host);
    }

    pub(super) fn endpoint_harnesses(&self) -> &[&'static str] {
        self.endpoint_harnesses.get().map_or(&[], Vec::as_slice)
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

    fn is_team_vm(&self) -> bool {
        let source = self.host.lock().unwrap_or_else(|e| e.into_inner()).clone();
        matches!(source.map(|read| read()), Some(AgentStartHost::TeamVm))
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
pub(super) struct StartParams {
    surface: SurfaceId,
    #[serde(default)]
    harness: Option<String>,
    #[serde(default)]
    model: Option<String>,
    /// The permission mode the person picked (module docs): applied only on the caller's own
    /// Cloud VM, ignored on any other host.
    #[serde(default)]
    mode: Option<String>,
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
    /// The caller's `agents.defaultPermissionMode` (`fullAccess`, `standard`, `ask`): read only on
    /// the caller's own Cloud VM ([`start_policy`]).
    #[serde(default)]
    permission_mode: Option<String>,
    /// The owner's model credential for the agent ([`AGENT_SESSION_START_CREDENTIALS_CAPABILITY`]).
    #[serde(default)]
    credentials: Option<StartCredentials>,
    #[serde(default)]
    claude_machine_login: bool,
    #[serde(default)]
    claude_team_route: bool,
}

impl StartParams {
    #[cfg(test)]
    fn valid(&self) -> bool {
        self.invalid_field().is_none()
    }

    /// The first param out of bounds, by name (the bad request's `data.field`); none when all hold.
    pub(super) fn invalid_field(&self) -> Option<&'static str> {
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
            let id =
                match self.credentials.as_ref().and_then(|credential| credential.endpoint.as_ref())
                {
                    Some(endpoint) if matches!(endpoint.kind, EndpointKind::OpenAi) => {
                        model.strip_prefix("byo/").unwrap_or(model)
                    }
                    _ => model,
                };
            (1..=200).contains(&id.len())
                && !model.starts_with('-')
                && !model.chars().any(|c| c.is_whitespace() || c.is_control())
                && !model.contains(['{', '}', '$', '"', '\\', '\''])
        });
        let permission_mode_ok =
            self.permission_mode.as_deref().is_none_or(|mode| PERMISSION_MODES.contains(&mode));
        let mode_ok = permission_mode_ok
            && self.mode.as_deref().is_none_or(|mode| {
                (1..=64).contains(&mode.len())
                    && mode.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
            });
        let credentials_ok = self.credentials.as_ref().is_none_or(StartCredentials::valid);
        [
            ("harness", harness_ok),
            ("cwd", cwd_ok),
            ("person_instance", instance_ok),
            ("model", model_ok),
            ("permission_mode", permission_mode_ok),
            ("mode", mode_ok),
            ("credentials", credentials_ok),
        ]
        .into_iter()
        .find_map(|(field, ok)| (!ok).then_some(field))
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
    if let Some(field) = params.invalid_field() {
        return super::bad_field::refuse_field(writer, id, Some(field));
    }
    let chooses_credential = params.credentials.is_some() || params.claude_machine_login;
    if chooses_credential && mux.control_clients.agent_sessions.starts.is_team_vm() {
        return refuse(writer, id, Refusal::PersonalConnectionOnTeamVm);
    }
    if let Err(refusal) = mux.agent_host_gate(client, vm_word(&params.vm_kind)) {
        return refuse(writer, id, refusal);
    }
    if let Err(refusal) = startable(mux, params.surface) {
        return refuse(writer, id, refusal);
    }
    // A credential only from the owner's own app on the owner's own Cloud VM.
    if chooses_credential && !credentials_admitted(mux, client, &params.vm_kind) {
        return refuse(writer, id, Refusal::OwnerOnly);
    }
    // A team route carries no personal credential. The Cloud VM's creator can select it
    // on a shared VM as well, under the start's existing host and phone gates.
    if params.claude_team_route
        && (!mux.control_clients.agent_sessions.starts.on_cloud_vm()
            || vm_word(&params.vm_kind) != Some("owner")
            || mux.control_clients.supports_capability(client, super::CLOUD_MOBILE_CHAT_CAPABILITY))
    {
        return refuse(writer, id, Refusal::OwnerOnly);
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
        return super::bad_field::refuse_field(writer, id, Some("cwd"));
    }
    // A chat never starts in `/`, above the home folder, or in the home folder
    // unless the person chose it (cx-1bhjj), as on the Mac.
    let Some(cwd) = params.cwd.as_deref() else {
        return super::bad_field::refuse_field(writer, id, Some("cwd"));
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
pub(super) fn startable(mux: &Mux, surface: SurfaceId) -> Result<(), Refusal> {
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
    let (link, catalog) = ready_catalog(&socket, link, cwd, params.harness.as_deref(), until)
        .map_err(|r| (r, None))?;
    let result = still_keyed(&link, &params).and_then(|()| {
        start_and_bind(mux, client, &link, &catalog, &params, phone, checks, until, timings)
            .map_err(|StartRefused(refusal, data)| (refusal, data))
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
    harness: Option<&str>,
    until: Instant,
) -> Result<(Arc<AcpmuxLink>, Value), Refusal> {
    // `forStart` with the start's harness: acpmux resolves it as `session/new` would before it
    // answers (acpmux `hub/rediscover.rs`), so a harness its startup PATH missed is in this
    // catalog and the start is not refused `harness_missing` (`start_family`) for it.
    let params = json!({"cwd": cwd, "forStart": true, "harness": harness});
    loop {
        match ask(&link, until, "_acpmux/harnesses", params.clone()) {
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

/// A start's refusal with its typed facts for `data`, when it has any.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct StartRefused(Refusal, Option<Value>);

/// acpmux's `data.reason` for a route that cannot serve a spawn (`routes::RouteError::reason`).
const ROUTE_REASONS: [&str; 3] = ["route.unavailable", "route.not_found", "route.invalid"];

/// acpmux's `data.reason` when it is a short code (letters, digits, `._-`, at most 64): the only
/// part of an acpmux error a start's refusal passes on (as `Refused::of_prompt` does).
fn acpmux_reason(data: &Value) -> Option<String> {
    data.get("reason")
        .and_then(Value::as_str)
        .filter(|code| {
            (1..=64).contains(&code.len())
                && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
        .map(str::to_owned)
}

impl From<Refusal> for StartRefused {
    fn from(refusal: Refusal) -> Self {
        Self(refusal, None)
    }
}

impl StartRefused {
    /// acpmux's answer to `session/new`. An agent that said it is not signed in (acpmux's
    /// `agent.sign_in_required`) is `sign_in_required` with the harness and the kind of sign-in
    /// failure, so the app names the agent and offers its sign-in (hq#11225); never the agent's
    /// own message text. Anything else is [`Refusal::of`].
    pub(super) fn of_session_new(error: LinkError) -> Self {
        if let LinkError::Rpc(_, data) = &error
            && data.get("reason").and_then(Value::as_str) == Some("agent.sign_in_required")
        {
            // A profile such as `providers/deepseek` by its last part, as the tab's brand mark.
            let harness = data
                .pointer("/details/harness")
                .and_then(Value::as_str)
                .and_then(|harness| harness.rsplit('/').next())
                .filter(|harness| validate_harness(harness).is_ok());
            let kind = data
                .get("errorKind")
                .and_then(Value::as_str)
                .filter(|kind| matches!(*kind, "auth.signed_out" | "auth.expired"));
            let mut facts = json!({"reason": "agent.sign_in_required"});
            if let Some(harness) = harness {
                facts.insert("harness", json!(harness));
            }
            if let Some(kind) = kind {
                facts.insert("errorKind", json!(kind));
            }
            return Self(Refusal::SignInRequired, Some(facts));
        }
        if let LinkError::Rpc(_, data) = &error
            && data.get("reason").and_then(Value::as_str) == Some("credentials.key_refused")
            && let Some(provider) = data.get("provider").and_then(Value::as_str).filter(|name| {
                matches!(
                    *name,
                    "Anthropic" | "OpenAI" | "Gemini" | "Vertex AI" | "xAI" | "OpenAI-compatible"
                )
            })
        {
            return Self(
                Refusal::ConnectionKeyRefused,
                Some(json!({"reason": "credentials.key_refused", "provider": provider})),
            );
        }
        // A route the agent's profile binds that cannot serve it here (acpmux `route.*` from
        // `apply_route`): the cmux router harness on a Cloud machine, which runs no signed-in
        // local router. The route's reason only, never acpmux's message (hq#11225).
        if let LinkError::Rpc(_, data) = &error
            && let Some(reason) = data
                .get("reason")
                .and_then(Value::as_str)
                .filter(|reason| ROUTE_REASONS.contains(reason))
        {
            return Self(Refusal::RouteUnavailable, Some(json!({"reason": reason})));
        }
        // A permission policy the agent cannot keep (acpmux `policy_unenforceable`: a remote
        // start asks for `ask`, and an ACP agent with no mode that asks cannot hold it) is
        // `not_asking`, the refusal the app names, with the harness acpmux named.
        if let LinkError::Rpc(_, data) = &error
            && data.get("reason").and_then(Value::as_str) == Some("policy_unenforceable")
        {
            let mut facts = json!({"reason": "policy_unenforceable"});
            if let Some(harness) = data
                .get("harness")
                .and_then(Value::as_str)
                .filter(|harness| validate_harness(harness).is_ok())
            {
                facts.insert("harness", json!(harness));
            }
            return Self(Refusal::NotAsking, Some(facts));
        }
        // Any other refusal keeps acpmux's reason code (`data.reason`, never its message text),
        // so the app and the CLI can say why: a bare `agent_session.refused` named no cause
        // (the carrier drill, cmuxterm-hq run 43973035740).
        let reason = match &error {
            LinkError::Rpc(_, data) => acpmux_reason(data),
            _ => None,
        };
        Self(Refusal::of(error), reason.map(|reason| json!({"reason": reason})))
    }

    /// The start's refusal with `harness`, the agent the start asked for, named in its facts:
    /// a route refusal, whose acpmux error does not name it. A valid harness id only.
    pub(super) fn naming(mut self, harness: Option<&str>) -> Self {
        if let (Refusal::RouteUnavailable, Some(facts), Some(harness)) =
            (self.0, self.1.as_mut(), harness.filter(|h| validate_harness(h).is_ok()))
            && facts.get("harness").is_none()
        {
            facts.insert("harness", json!(harness));
        }
        self
    }
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
) -> Result<Value, StartRefused> {
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
        return Err(Refusal::NotAsking.into());
    }
    // The family the start resolves to, from acpmux's own catalog, before
    // any agent process exists: a Codex alias or a default harness of a
    // refused family never starts (but on the caller's own Cloud VM).
    let family = start_family(catalog, params.harness.as_deref())?;
    if (params.claude_machine_login || params.claude_team_route)
        && (family != "claude"
            || params.credentials.is_some()
            || (params.claude_machine_login && params.claude_team_route))
    {
        return Err(Refusal::BadRequest.into());
    }
    // A phone's family is held to its own floor instead: acpmux refuses Codex as a Web family,
    // but a Codex bridge session holds to the phone floor in `ask`, which only the session's
    // `cloudMobileAsks` can tell from Codex's adapter (`settle_phone_mode`).
    if !owner_cloud && !phone && refused_family(&table, &family) {
        return Err(Refusal::NotAsking.into());
    }
    if phone && phone_modes(&family).is_empty() {
        return Err(Refusal::NotAsking.into());
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
        return Err(Refusal::UntrustedFolder.into());
    }
    // The person's own pick on their own Cloud VM (module docs); never a phone's start, never
    // another host's. With no pick, the person's `agents.defaultPermissionMode`
    // (`permission_mode`, [`start_policy`]) decides the policy there.
    let permission_mode = params.permission_mode.as_deref();
    let picked = params.mode.as_deref().filter(|_| owner_cloud && !phone);
    let mut meta = match picked {
        Some(mode) if !mode_asks(&table, &family, mode) => json!({"mode": mode}),
        Some(mode) => json!({"policy": "ask", "mode": mode}),
        None => match start_policy(owner_cloud, phone, permission_mode) {
            Some(policy) => json!({"policy": policy}),
            None => json!({}),
        },
    };
    if let Some(harness) = &params.harness {
        meta.insert("harness", json!(harness));
    }
    if let Some(model) = &params.model {
        meta.insert("model", json!(model));
    }
    // Admitted in `start` (the owner's own Cloud VM); acpmux keeps it for this agent in memory.
    if let Some(credentials) = &params.credentials {
        meta.insert("credentials", credentials.wire());
    }
    if params.claude_machine_login {
        meta.insert("claudeMachineLogin", json!(true));
    }
    if params.claude_team_route {
        meta.insert("claudeTeamRoute", json!(true));
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
        .map_err(|error| StartRefused::of_session_new(error).naming(params.harness.as_deref()));
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
        if picked.is_none() && permission_mode == Some("standard") {
            settle_standard_mode(link, &session);
        }
        let family = session_family(link, until, &session).map_err(end)?;
        if let Some(mode) = cloud_default_mode(picked, permission_mode, &family) {
            settle_cloud_default_mode(link, &session, mode);
        }
        family
    } else {
        settle_asking_mode(link, until, &session).map_err(end)?
    };
    // The trust answer for the family the session actually runs.
    if !folder_trusted(&trust, Some(&family)) {
        return Err(end(Refusal::UntrustedFolder).into());
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

/// The values `permission_mode` takes (acpmux `start_mode.rs` `DefaultMode`).
const PERMISSION_MODES: [&str; 3] = ["fullAccess", "standard", "ask"];

/// The policy a start gives its new session. Anywhere but the caller's own Cloud VM, and for a phone
/// there, `ask`, whatever the caller says: the session then runs in a mode that asks. On the caller's
/// own Cloud VM (a disposable machine the person owns, where they can already run any command in a
/// terminal) the chat starts as a new chat on the caller's app starts, from the person's
/// `agents.defaultPermissionMode` (`permission_mode`): `ask` keeps policy `ask`; `fullAccess` and
/// `standard` give no policy, so acpmux's start level there applies (`hub/start_mode.rs`), and a mode
/// the person picks later is not held to an asking one (`hub/policy_mode.rs`). An app that sends no
/// `permission_mode` (before the param) keeps `ask`.
fn start_policy(
    owner_cloud: bool,
    phone: bool,
    permission_mode: Option<&str>,
) -> Option<&'static str> {
    match (owner_cloud && !phone, permission_mode) {
        (true, Some("fullAccess" | "standard")) => None,
        _ => Some("ask"),
    }
}

/// Claude Code's own mode, Auto (acpmux `claude_stdio::OWN_MODE`).
const CLAUDE_AUTO: &str = "auto";

/// The mode a start on the caller's own Cloud VM moves its new chat to after it started, when the
/// person picked none and their start level is full access: Claude Code's Auto for a Claude chat
/// (Lawrence 2026-11-20: "we need to support auto mode for cloud mode for claude harness"; the
/// default is Auto where Claude Code takes it, else Bypass permissions). The chat starts at the
/// machine's full-access level (Bypass permissions) and acpmux takes the move without the person
/// (`hub/start_mode.rs` `may_move_without_person`); a Claude Code that refuses Auto keeps Bypass
/// permissions ([`settle_cloud_default_mode`]). Any other family, a pick, and any other level: none.
fn cloud_default_mode(
    picked: Option<&str>,
    permission_mode: Option<&str>,
    family: &str,
) -> Option<&'static str> {
    let claude = family == "claude" || family.starts_with("claude-");
    (picked.is_none() && permission_mode == Some("fullAccess") && claude).then_some(CLAUDE_AUTO)
}

/// Moves a new chat on the caller's own Cloud VM to `mode` ([`cloud_default_mode`]). Soft, as
/// acpmux's start level is: a harness that does not offer it, or refuses it, keeps the mode it
/// started in.
fn settle_cloud_default_mode(link: &AcpmuxLink, session: &str, mode: &str) {
    let params = json!({"sessionId": session, "modeId": mode});
    let _ = link.call("session/set_mode", params, CALL_TIMEOUT);
}

/// `standard` on the caller's own Cloud VM: the harness's own start mode, which for a session that
/// started in a mode that does not ask (the machine's start level) is its family's asking default.
/// Soft, as acpmux's start level is: a refusal leaves the session as it started.
fn settle_standard_mode(link: &AcpmuxLink, session: &str) {
    let Ok(table) = link.call("_acpmux/web_modes", json!({"sessionId": session}), CALL_TIMEOUT)
    else {
        return;
    };
    let family = table.pointer("/session/family").and_then(Value::as_str).unwrap_or_default();
    let modes: Vec<&str> = table
        .pointer(&format!("/families/{}", family.replace('~', "~0").replace('/', "~1")))
        .and_then(Value::as_array)
        .map(|modes| modes.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let current = table.pointer("/session/mode").and_then(Value::as_str);
    if let (Some(current), Some(default)) = (current, modes.first())
        && !modes.contains(&current)
    {
        let params = json!({"sessionId": session, "modeId": default});
        let _ = link.call("session/set_mode", params, CALL_TIMEOUT);
    }
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

/// The family a start resolves to ([`catalog_family`]). An agent the catalog does not have is
/// not installed on this machine: `harness_missing` naming it (a valid harness id only), never
/// `not_asking`, which says the agent has no mode that asks first (hq#11225: pi on a Cloud
/// machine, whose image ships `pi` but not the `pi-acp` adapter acpmux runs it through).
fn start_family(catalog: &Value, harness: Option<&str>) -> Result<String, StartRefused> {
    catalog_family(catalog, harness).ok_or_else(|| {
        let mut facts = json!({"reason": "agent.not_installed"});
        if let Some(harness) = harness.filter(|harness| validate_harness(harness).is_ok()) {
            facts.insert("harness", json!(harness));
        }
        StartRefused(Refusal::HarnessMissing, Some(facts))
    })
}

fn refused_family(table: &Value, family: &str) -> bool {
    table
        .get("refusedFamilies")
        .and_then(Value::as_array)
        .is_some_and(|refused| refused.iter().any(|name| name.as_str() == Some(family)))
}

/// Whether `mode` asks before it acts for `family`: acpmux's remote table
/// (`_acpmux/web_modes` `families`) lists it, or it is the Codex bridge's
/// `ask` or `read-only`, which the table leaves out because it refuses Codex
/// for the Web (acpmux `start_mode::NARROW_MODES`).
fn mode_asks(table: &Value, family: &str, mode: &str) -> bool {
    let listed = table
        .pointer(&format!("/families/{}", family.replace('~', "~0").replace('/', "~1")))
        .and_then(Value::as_array)
        .is_some_and(|modes| modes.iter().any(|listed| listed.as_str() == Some(mode)));
    listed || (family == "codex" && matches!(mode, "ask" | "read-only"))
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
#[path = "agent_session_start_tests.rs"]
mod tests;
