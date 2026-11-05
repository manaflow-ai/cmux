//! The Cloud agent's file contracts and wire shapes (pure). They are the
//! ones the interim Bun agent (`images/cmux-vm/guest/vm-agent.ts`) used, so
//! the driver, the bake and the backend see no change.

use crate::json::JsonField;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// The driver writes the one-time bind token here (create, retry, restore).
pub const BIND_FILE: &str = "/var/lib/cmux/bind.json";
/// Written by a successful bind, before `bind.json` is removed (0600).
pub const BOUND_FILE: &str = "/var/lib/cmux/bound.json";
/// This VM's kind for processes that cannot read /var/lib/cmux (0700 root):
/// `owner` or `team`, root-owned, 0644. Informational: it records the kind
/// cmux assigned, and acpmux does not trust it for any decision (#26227).
/// The Cloud backend writes it at create, the devbox's cmux-vm-kind-sync
/// writes the kind it fetched, and a team enroll records `team`. The owner
/// write here ([`super::client::record_owner_kind`]) never replaces an
/// existing record.
pub const VM_KIND_FILE: &str = "/etc/cmux/vm-kind";
pub const STATE_DIR: &str = "/var/lib/cmux";
pub const INSTALL_KEY_FILE: &str = "/var/lib/cmux/install/key.json";
pub const WG_KEY_FILE: &str = "/var/lib/cmux/wg/key.json";
/// JSON lines `{"activity": {...}}`, `{"acp_activity": {...}}`, `{"event": {...}}`
/// or `{"resume": true}` (root and group cmux).
pub const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// Diagnostic: the last report's outcome (never a secret).
pub const AGENT_STATE_FILE: &str = "/run/cmux-vm-agent/state.json";
/// The bake-recorded identify answer, used when the daemon does not answer.
pub const DAEMON_INFO_FILE: &str = "/etc/cmux/daemon.json";
/// The daemon's control socket path (the bake records it).
pub const DAEMON_SOCKET_FILE: &str = "/etc/cmux/daemon-socket";

/// Daemon capabilities a Cloud client gates on; bind accepts at most 32, so
/// only these travel, plus the agent's own.
pub const CLOUD_GATED_DAEMON_CAPABILITIES: [&str; 2] = ["fs-v1", "loopback-forward-v1"];
pub const AGENT_CAPABILITY: &str = "vm-agent-v1";
/// Advertised when the image serves link service `desktop`: its
/// [`DESKTOP_SOCKET_UNIT`] is installed, and this receiver build knows the
/// service. The platform grants `desktop` (to the machine's creator only)
/// only to a machine whose daemon block carries it.
pub const DESKTOP_CAPABILITY: &str = "link-desktop-v1";
/// The image's socket unit of the agent display's `cmux.rd/1` host
/// (`/run/cmux-rd/desktop.sock`, root 0600).
pub const DESKTOP_SOCKET_UNIT: &str = "/etc/systemd/system/cmux-agent-rd.socket";
/// Advertised only while the activity stream to the daemon is live.
pub const ACTIVITY_CAPABILITY: &str = "activity";
/// Advertised with `activity` while acpmux's `acp_activity` lines arrive (each within
/// [`ACP_ACTIVITY_TTL_MS`] of the last): the report's `active_sessions` also counts acpmux's
/// sessions at work (a turn running, queued or waiting on a permission or question, a
/// background task or subagent), and their agents' actions move `last_agent_action_at`. The
/// Cloud short-idle-pauses a machine only when its report advertises this, so a chat mid-turn
/// with no app attached is never paused, also not right after the agent restarted.
pub const ACTIVITY_TURNS_CAPABILITY: &str = "activity-turns";
/// Advertised with `activity-turns` while every acpmux daemon whose count holds also says what
/// each of its sessions at work waits on: the report's `activity.phases`
/// (`{"relayed": bool, "turns": [{"phase", "since", ...}]}`, one entry per acpmux session at
/// work; acpmux `daemon/cloud_activity.rs` names the phases). The Cloud sleeps a machine inside
/// its turns only from a report that advertises this (cmux#34298).
pub const ACTIVITY_PHASES_CAPABILITY: &str = "activity-phases";
/// How long acpmux's count of sessions at work holds without a new `acp_activity` line
/// (acpmux renews it every 20 s, `daemon/cloud_activity.rs`): a
/// daemon that died mid-turn does not keep the machine awake for good.
pub const ACP_ACTIVITY_TTL_MS: u64 = 90_000;
/// The daemon capability that serves `subscribe-activity`.
pub const DAEMON_ACTIVITY_CAPABILITY: &str = "vm-activity-v1";

pub const STATUS_REPORT_OP: &str = "cloud.vm.status.report";
pub const EVENT_EMIT_OP: &str = "cloud.vm.event.emit";
pub const ATTENTION_EMIT_OP: &str = "cloud.vm.attention.emit";

pub const VM_EVENT_KINDS: [&str; 9] = [
    "agent.started",
    "agent.finished",
    "agent.needs_input",
    "notification",
    "browser.lease.changed",
    "cua.session.started",
    "cua.session.ended",
    "service.port.opened",
    "service.port.closed",
];
pub const VM_EVENT_DATA_MAX_BYTES: usize = 4096;

pub const DEFAULT_HEARTBEAT_MS: u64 = 3_600_000;
/// The latest-wins window between two reports.
pub const REPORT_MIN_INTERVAL_MS: u64 = 10_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Env {
    Dev,
    Stg,
    Prod,
}

impl Env {
    /// The only API origin each environment may bind to.
    pub fn api_origin(self) -> &'static str {
        match self {
            Env::Dev => cmux_cloud_environment::DEVELOPMENT_API,
            Env::Stg => cmux_cloud_environment::STAGING_API,
            Env::Prod => cmux_cloud_environment::PRODUCTION_API,
        }
    }

    /// The connector owner for this environment. Socket callers cannot
    /// choose an origin and redirect the machine's bearer elsewhere.
    pub fn platform_origin(self) -> &'static str {
        match self {
            Env::Dev => cmux_cloud_environment::DEVELOPMENT_PLATFORM,
            Env::Stg => cmux_cloud_environment::STAGING_PLATFORM,
            Env::Prod => cmux_cloud_environment::PRODUCTION_PLATFORM,
        }
    }

    /// The Worker's ENVIRONMENT, named in the auth challenge prefix.
    pub fn auth_environment(self) -> &'static str {
        match self {
            Env::Dev => "development",
            Env::Stg => "staging",
            Env::Prod => "production",
        }
    }

    fn parse(raw: &str) -> Option<Env> {
        match raw {
            "dev" => Some(Env::Dev),
            "stg" => Some(Env::Stg),
            "prod" => Some(Env::Prod),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindFile {
    pub team: String,
    pub machine: String,
    pub bind_token: String,
    pub api_origin: String,
    pub env: Env,
}

fn prefixed_id(raw: &str, prefix: &str) -> bool {
    raw.strip_prefix(prefix).is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

fn bind_token_ok(raw: &str) -> bool {
    (16..=256).contains(&raw.len())
        && raw.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `bind.json`, refused unless every field has its shape and the origin is
/// the environment's own.
pub fn parse_bind_file(text: &str) -> Result<BindFile, String> {
    let raw: Value = serde_json::from_str(text).map_err(|_| "bind.json is not JSON".to_owned())?;
    let field = |key: &str| raw.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let (team, machine, bind_token) = (field("team"), field("machine"), field("bind_token"));
    if !prefixed_id(&team, "team_") {
        return Err("bind.json: bad team".to_owned());
    }
    if !prefixed_id(&machine, "vm_") {
        return Err("bind.json: bad machine".to_owned());
    }
    if !bind_token_ok(&bind_token) {
        return Err("bind.json: bad bind_token".to_owned());
    }
    let Some(env) = Env::parse(&field("env")) else {
        return Err("bind.json: unknown env".to_owned());
    };
    let api_origin = field("api_origin");
    if api_origin != env.api_origin() {
        return Err(format!("bind.json: api_origin is not the {} origin", field("env")));
    }
    Ok(BindFile { team, machine, bind_token, api_origin, env })
}

/// `bound.json`: what the machine needs to report after a restart.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Bound {
    pub machine: String,
    pub team: String,
    pub host: String,
    pub epoch: u64,
    pub install: String,
    pub user: String,
    pub grant: String,
    pub env: Env,
    pub api_origin: String,
    pub keyset: Value,
    pub bound_at: u64,
}

/// The daemon block of bind and of every status report.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonInfo {
    pub version: String,
    pub capabilities: Vec<String>,
}

impl DaemonInfo {
    /// The same block with `activity` on (the stream is live) or off, `activity-turns` with it
    /// while acpmux's count is known (`turns`), and `activity-phases` with that while acpmux's
    /// phases are known too (`phases`).
    pub fn with_activity(&self, on: bool, turns: bool, phases: bool) -> DaemonInfo {
        let mut capabilities: Vec<String> =
            self.capabilities.iter().filter(|c| !is_activity_capability(c)).cloned().collect();
        if on {
            capabilities.push(ACTIVITY_CAPABILITY.to_owned());
            if turns {
                capabilities.push(ACTIVITY_TURNS_CAPABILITY.to_owned());
                if phases {
                    capabilities.push(ACTIVITY_PHASES_CAPABILITY.to_owned());
                }
            }
        }
        DaemonInfo { version: self.version.clone(), capabilities }
    }

    pub fn to_json(&self) -> Value {
        json!({ "version": self.version, "capabilities": self.capabilities })
    }
}

fn is_activity_capability(c: &str) -> bool {
    c == ACTIVITY_CAPABILITY || c == ACTIVITY_TURNS_CAPABILITY || c == ACTIVITY_PHASES_CAPABILITY
}

/// The daemon block from one `identify` answer's `data`: version plus the
/// first 12 characters of the build commit, the Cloud-gated capabilities the
/// daemon advertises, then the agent's own.
pub fn daemon_info_from_identify(identify: &Value, activity_sender: bool) -> DaemonInfo {
    let advertised: Vec<&str> = identify
        .field("capabilities")
        .as_array()
        .map(|caps| caps.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut capabilities: Vec<String> = CLOUD_GATED_DAEMON_CAPABILITIES
        .iter()
        .filter(|c| advertised.contains(c))
        .map(|c| (*c).to_owned())
        .collect();
    capabilities.push(AGENT_CAPABILITY.to_owned());
    if activity_sender {
        capabilities.push(ACTIVITY_CAPABILITY.to_owned());
    }
    let version = identify.field("version").as_str().filter(|v| !v.is_empty()).unwrap_or("unknown");
    let build = identify
        .field("build_commit")
        .as_str()
        .filter(|b| !b.is_empty())
        .map(|b| format!("+{}", b.chars().take(12).collect::<String>()))
        .unwrap_or_default();
    let version: String = format!("{version}{build}").chars().take(64).collect();
    DaemonInfo { version, capabilities }
}

/// Times and counts only; absent times stay absent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Activity {
    pub active_sessions: u64,
    pub last_user_input_at: Option<u64>,
    pub last_agent_action_at: Option<u64>,
    /// acpmux's `phases` block, while every daemon whose count holds sent one
    /// ([`ACTIVITY_PHASES_CAPABILITY`]).
    pub phases: Option<Value>,
    /// When a person last prompted one of acpmux's chats (Unix ms), the newest any daemon sent:
    /// the Cloud keeps the machine running for a while after it (cmux-platform `IdlePolicy.ts`,
    /// the post-chat warm window).
    pub last_person_prompt_at: Option<u64>,
}

impl Activity {
    pub fn to_json(&self) -> Value {
        let mut out = Map::new();
        out.insert("active_sessions".to_owned(), json!(self.active_sessions));
        if let Some(at) = self.last_user_input_at {
            out.insert("last_user_input_at".to_owned(), json!(at));
        }
        if let Some(at) = self.last_agent_action_at {
            out.insert("last_agent_action_at".to_owned(), json!(at));
        }
        if let Some(phases) = &self.phases {
            out.insert("phases".to_owned(), phases.clone());
        }
        if let Some(at) = self.last_person_prompt_at {
            out.insert("last_person_prompt_at".to_owned(), json!(at));
        }
        Value::Object(out)
    }
}

impl Activity {
    /// The report's activity from the daemon's (or the socket's `activity` lines) and acpmux's
    /// sessions at work: the counts add up, the newest agent action wins, and acpmux's person's
    /// prompt time rides along.
    pub fn with_acp(
        &self,
        acp_sessions: u64,
        acp_action_at: Option<u64>,
        acp_phases: Option<Value>,
        acp_prompt_at: Option<u64>,
    ) -> Activity {
        Activity {
            active_sessions: self.active_sessions.saturating_add(acp_sessions),
            last_user_input_at: self.last_user_input_at,
            last_agent_action_at: self.last_agent_action_at.max(acp_action_at),
            phases: acp_phases,
            last_person_prompt_at: acp_prompt_at,
        }
    }
}

/// A partial activity update: a field that is `None` keeps its last value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ActivityChange {
    pub active_sessions: Option<u64>,
    pub last_user_input_at: Option<u64>,
    pub last_agent_action_at: Option<u64>,
}

impl ActivityChange {
    pub fn apply(&self, to: &mut Activity) {
        if let Some(n) = self.active_sessions {
            to.active_sessions = n;
        }
        if self.last_user_input_at.is_some() {
            to.last_user_input_at = self.last_user_input_at;
        }
        if self.last_agent_action_at.is_some() {
            to.last_agent_action_at = self.last_agent_action_at;
        }
    }

    /// `{"active_sessions": n, "last_user_input_at": ms, ...}` from the
    /// agent socket; unknown keys are ignored.
    pub fn from_json(v: &Value) -> ActivityChange {
        ActivityChange {
            active_sessions: v.field("active_sessions").as_u64(),
            last_user_input_at: v.field("last_user_input_at").as_u64(),
            last_agent_action_at: v.field("last_agent_action_at").as_u64(),
        }
    }
}

/// The daemon's activity (`subscribe-activity`) as a report change:
/// sessions = attached clients + live agents; only positive times count.
pub fn activity_from_daemon(a: &Value) -> ActivityChange {
    let count = |key: &str| a[key].as_u64().unwrap_or(0);
    let time = |key: &str| a[key].as_u64().filter(|ms| *ms > 0);
    ActivityChange {
        active_sessions: Some(count("attached_clients") + count("live_agents")),
        last_user_input_at: time("last_user_input_at_ms"),
        last_agent_action_at: time("last_agent_action_at_ms"),
    }
}

/// The heartbeat deadline: `CMUX_VM_AGENT_HEARTBEAT_MS` (1 s to 1 h) is a
/// test override honored only on a dev-bound machine.
pub fn heartbeat_ms_for(env: Env, raw: Option<&str>) -> u64 {
    match (env, raw.and_then(|r| r.parse::<u64>().ok())) {
        (Env::Dev, Some(ms)) if (1_000..=DEFAULT_HEARTBEAT_MS).contains(&ms) => ms,
        _ => DEFAULT_HEARTBEAT_MS,
    }
}

/// A v1 event kind with at most 4 KB of data.
pub fn check_event(kind: &str, data: &Value) -> Result<(), String> {
    if !VM_EVENT_KINDS.contains(&kind) {
        return Err(format!("unknown event kind {kind}"));
    }
    if data.to_string().len() > VM_EVENT_DATA_MAX_BYTES {
        return Err("event data over 4 KB".to_owned());
    }
    Ok(())
}

/// `retry_after_ms` from an op answer's error details (0 when absent).
pub fn retry_after_ms(body: &Value) -> u64 {
    body.field("error").field("details").field("retry_after_ms").as_u64().unwrap_or(0)
}
