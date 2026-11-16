#![cfg_attr(not(unix), allow(dead_code))]
//! "My agents can turn screen sharing and control on my machines" (docs/cmux-remote.md, Agents):
//! the daemon's side of the account's standing permission.
//!
//! The permission lives in the device hub, one value per account; only the cmux app's full hub
//! session writes it, after a person's click. This module never turns it on. It decides, per
//! request, whether a change an agent asked for runs with no dialog:
//!
//! 1. An agent (a local Unix connection to this daemon that is not the verified app and not a
//!    page: the same OS user on this Mac, whose daemon is this Mac's) asks for a ticket
//!    (`remote-host-call agent.ticket {action: share|unshare, device?, agent}`). A ticket names
//!    the agent session as the daemon sees it (its claimed session id and name, and the
//!    connection's process id), is single-use and lives [`TICKET_TTL`].
//! 2. The agent hands the ticket to the cmux app (`remote.confirm {..., agent_ticket}`). The app
//!    redeems it over its verified connection (`agent.redeem`), passing what only it knows: the
//!    hub's current value of the permission and the signed-in account. [`AgentShare::redeem`]
//!    decides: permission on, signed in, the target of the same account, a live ticket: no
//!    dialog, and the app makes the change with its full hub session. Anything else: the app
//!    shows its dialog, exactly as with no ticket.
//! 3. Every decision writes a row to the host audit log (`audit.jsonl` in the host folder) naming the
//!    agent session and the device, and every agent-made change carries a notice the app shows
//!    on that Mac ("Studio is now shared · Turn Off").
//! 4. Sharing an agent turned on turns itself off after `remote.agentShareIdleMinutes` (15)
//!    minutes with no viewer: [`AutoOff`], a timer thread with a stop condition, armed on the
//!    agent's share, re-armed when the last viewer leaves, held while a viewer is connected,
//!    and cancelled when the person turns sharing on or off themselves.
//!
//! The permission itself (`allow_agents`) is never an agent ticket's action: turning it on
//! is the person's, in Settings or on the app's dialog.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// How long a ticket waits for the app to redeem it.
pub(crate) const TICKET_TTL: Duration = Duration::from_secs(60);
/// Tickets held at once; the oldest goes first.
const MAX_TICKETS: usize = 32;
/// Notices kept for `remote-host-status` (the newest last).
const MAX_NOTICES: usize = 8;
/// The app action a notice's Turn Off runs.
pub(crate) const TURN_OFF_ACTION: &str = "macScreen.stopSharingThisMac";
/// The longest agent session id or name kept.
const MAX_LABEL: usize = 200;

/// A refusal with a stable code (`agents.*`, `origin.forbidden`, `bad_request`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Refused {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

fn refused(code: &'static str, message: impl Into<String>) -> Refused {
    Refused { code, message: message.into() }
}

/// Who called, as `remote_host_command::caller` classified the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Caller {
    /// The verified cmux app (`HelloRole::Main` with a proof).
    App,
    /// Any other local Unix connection of this OS user: an agent, a terminal.
    LocalAgent { pid: Option<u32> },
}

/// The agent session behind a request, as the daemon sees it: the session id and name the agent
/// claims (`ACPMUX_SESSION_ID` or `CMUX_AGENT_SESSION`, `ACPMUX_SESSION_NAME`) and the process
/// id of its connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Actor {
    pub(crate) session: Option<String>,
    pub(crate) name: Option<String>,
    pub(crate) pid: Option<u32>,
}

impl Actor {
    fn from_params(agent: Option<&Value>, pid: Option<u32>) -> Self {
        let text = |key: &str| {
            agent
                .and_then(|agent| agent.get(key))
                .and_then(Value::as_str)
                .map(|value| {
                    value.chars().filter(|c| !c.is_control()).take(MAX_LABEL).collect::<String>()
                })
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        };
        Self { session: text("session"), name: text("name"), pid }
    }

    pub(crate) fn json(&self) -> Value {
        json!({"session": self.session, "name": self.name, "pid": self.pid})
    }

    /// How a notice and the hub's audit row name it: its name, else its session id.
    pub(crate) fn label(&self) -> String {
        self.name.clone().or_else(|| self.session.clone()).unwrap_or_else(|| "an agent".into())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    Share,
    Unshare,
}

impl Action {
    fn word(self) -> &'static str {
        match self {
            Self::Share => "share",
            Self::Unshare => "unshare",
        }
    }
}

struct Ticket {
    action: Action,
    device: Option<String>,
    actor: Actor,
    minted: Instant,
}

/// Where decisions go: the audit log, the notices the app shows, and the call that turns this
/// Mac's sharing off when the timer fires (cmux Remote's host session may turn it off).
struct Sink {
    audit: Box<dyn Fn(Value) + Send + Sync>,
    notices: Mutex<(u64, Vec<Value>)>,
    turn_off: OnceLock<Box<dyn Fn() -> Result<(), String> + Send + Sync>>,
}

impl Sink {
    fn notice(&self, mut notice: Value) -> Value {
        let mut notices = lock(&self.notices);
        notices.0 += 1;
        if let Some(fields) = notice.as_object_mut() {
            fields.insert("seq".into(), json!(notices.0));
        }
        notices.1.push(notice.clone());
        let excess = notices.1.len().saturating_sub(MAX_NOTICES);
        notices.1.drain(..excess);
        notice
    }
}

/// The daemon's agent-sharing state: open tickets, the auto-off timer and the decision log.
pub(crate) struct AgentShare {
    tickets: Mutex<HashMap<String, Ticket>>,
    auto_off: Arc<AutoOff>,
    sink: Arc<Sink>,
    ttl: Duration,
    idle: Box<dyn Fn() -> Duration + Send + Sync>,
}

impl Default for AgentShare {
    fn default() -> Self {
        Self::new(
            Box::new(append_host_audit),
            Box::new(|| {
                Duration::from_secs(60 * cmux_tui_util::user_settings::agent_share_idle_minutes())
            }),
            TICKET_TTL,
        )
    }
}

impl AgentShare {
    /// `audit` takes each decision's row; `idle` is how long a share may go with no viewer.
    pub(crate) fn new(
        audit: Box<dyn Fn(Value) + Send + Sync>,
        idle: Box<dyn Fn() -> Duration + Send + Sync>,
        ttl: Duration,
    ) -> Self {
        let sink = Arc::new(Sink {
            audit,
            notices: Mutex::new((0, Vec::new())),
            turn_off: OnceLock::new(),
        });
        let fired = Arc::clone(&sink);
        let auto_off = AutoOff::new(Box::new(move |armed: Armed| {
            let result = fired.turn_off.get().map_or(Ok(()), |turn_off| turn_off());
            (fired.audit)(json!({
                "event": "remote_host.agent_share_auto_off",
                "agent": armed.actor.json(),
                "device": armed.device,
                "idle_minutes": armed.idle.as_secs() / 60,
                "idle_seconds": armed.idle.as_secs(),
                "turned_off": result.is_ok(),
                "error": result.err(),
            }));
            fired.notice(json!({
                "kind": "auto_off",
                "device_name": armed.device.get("name").cloned().unwrap_or(Value::Null),
                "agent": armed.actor.label(),
                "idle_minutes": armed.idle.as_secs() / 60,
            }));
        }));
        Self { tickets: Mutex::new(HashMap::new()), auto_off, sink, ttl, idle }
    }

    /// The call the timer makes to turn this Mac's sharing off (set once, by the daemon).
    pub(crate) fn set_turn_off(&self, turn_off: Box<dyn Fn() -> Result<(), String> + Send + Sync>) {
        let _ = self.sink.turn_off.set(turn_off);
    }

    /// `agent.ticket`: a single-use ticket for one change an agent asks the app to make.
    pub(crate) fn ticket(&self, caller: Caller, params: &Value) -> Result<Value, Refused> {
        let Caller::LocalAgent { pid } = caller else {
            return Err(refused(
                "bad_request",
                "the cmux app makes its own changes; tickets are for agents",
            ));
        };
        let actor = Actor::from_params(params.get("agent"), pid);
        let action = match params.get("action").and_then(Value::as_str) {
            Some("share") => Action::Share,
            Some("unshare") => Action::Unshare,
            Some("allow_agents") => {
                return Err(self.refuse(
                    &actor,
                    "allow_agents",
                    refused(
                        "agents.person_only",
                        "letting agents share your machines is the person's choice: Settings, or the cmux dialog",
                    ),
                ));
            }
            _ => return Err(refused("bad_request", "agent.ticket needs action: share or unshare")),
        };
        let device = match params.get("device") {
            None | Some(Value::Null) => None,
            Some(Value::String(device))
                if !device.trim().is_empty()
                    && device.len() <= MAX_LABEL
                    && action == Action::Share =>
            {
                Some(device.trim().to_owned())
            }
            Some(_) => {
                return Err(refused(
                    "bad_request",
                    "device is a device id or name, with action share",
                ));
            }
        };
        let id = mint_id().map_err(|message| refused("agents.unavailable", message))?;
        let mut tickets = lock(&self.tickets);
        let ttl = self.ttl;
        tickets.retain(|_, ticket| ticket.minted.elapsed() < ttl);
        while tickets.len() >= MAX_TICKETS {
            let Some(oldest) =
                tickets.iter().min_by_key(|(_, ticket)| ticket.minted).map(|(id, _)| id.clone())
            else {
                break;
            };
            tickets.remove(&oldest);
        }
        tickets.insert(id.clone(), Ticket { action, device, actor, minted: Instant::now() });
        Ok(json!({"ticket": id, "expires_in_s": ttl.as_secs()}))
    }

    /// `agent.redeem {ticket, allowed, account, this_device: {id, name}, target?: {id, name,
    /// account}}` from the verified app: whether the change runs with no dialog.
    ///
    /// `{dialog: false, action, on, agent, device, target?, idle_minutes, notice}`: the app makes
    /// it with no dialog. `{dialog: true, reason}`: the app asks the person, as with no ticket.
    pub(crate) fn redeem(&self, caller: Caller, params: &Value) -> Result<Value, Refused> {
        if caller != Caller::App {
            return Err(refused(
                "origin.forbidden",
                "cmux Remote agent tickets are redeemed by the cmux app",
            ));
        }
        let text =
            |value: Option<&Value>| value.and_then(Value::as_str).unwrap_or_default().to_owned();
        let this_device = json!({
            "id": text(params.pointer("/this_device/id")),
            "name": text(params.pointer("/this_device/name")),
        });
        let id = text(params.get("ticket"));
        let ticket = {
            let mut tickets = lock(&self.tickets);
            tickets.remove(&id).filter(|ticket| ticket.minted.elapsed() < self.ttl)
        };
        let Some(ticket) = ticket else {
            return Ok(self.ask_person(
                &Actor::default(),
                None,
                &this_device,
                "agents.ticket_invalid",
            ));
        };
        if params.get("allowed").and_then(Value::as_bool) != Some(true) {
            return Ok(self.ask_person(
                &ticket.actor,
                Some(ticket.action),
                &this_device,
                "agents.not_allowed",
            ));
        }
        let account = text(params.get("account"));
        if account.is_empty() {
            return Ok(self.ask_person(
                &ticket.actor,
                Some(ticket.action),
                &this_device,
                "agents.signed_out",
            ));
        }
        let target = match (&ticket.device, params.get("target")) {
            (None, _) => None,
            (Some(asked), Some(target)) if target.is_object() => {
                let owner = text(target.get("account"));
                if owner != account {
                    return Err(self.refuse(
                        &ticket.actor,
                        ticket.action.word(),
                        refused(
                            "agents.other_account",
                            format!("{asked} is not a device of this account: your agents share only your own machines"),
                        ),
                    ));
                }
                Some(
                    json!({"id": text(target.get("id")), "name": text(target.get("name")), "asked": asked}),
                )
            }
            (Some(asked), _) => {
                return Err(self.refuse(
                    &ticket.actor,
                    ticket.action.word(),
                    refused(
                        "agents.other_account",
                        format!("{asked} is not a device of this account"),
                    ),
                ));
            }
        };
        let on = ticket.action == Action::Share;
        let idle = (self.idle)();
        let shared = target.clone().unwrap_or_else(|| this_device.clone());
        (self.sink.audit)(json!({
            "event": if on { "remote_host.agent_share_on" } else { "remote_host.agent_share_off" },
            "agent": ticket.actor.json(),
            "device": this_device,
            "target": target,
            "account": account,
            "via": "daemon",
        }));
        if target.is_none() {
            if on {
                self.auto_off.arm(Armed {
                    actor: ticket.actor.clone(),
                    device: this_device.clone(),
                    idle,
                    deadline: None,
                });
            } else {
                self.auto_off.cancel();
            }
        }
        let notice = self.sink.notice(json!({
            "kind": if on { "shared" } else { "unshared" },
            "device_name": shared.get("name").cloned().unwrap_or(Value::Null),
            "agent": ticket.actor.label(),
            // Turn Off works on this Mac; another Mac turns off there.
            "turn_off": if on && target.is_none() { json!(TURN_OFF_ACTION) } else { Value::Null },
        }));
        Ok(json!({
            "dialog": false,
            "action": ticket.action.word(),
            "on": on,
            "agent": ticket.actor.json(),
            "agent_label": ticket.actor.label(),
            "device": this_device,
            "target": target,
            "idle_minutes": idle.as_secs() / 60,
            "notice": notice,
        }))
    }

    /// Sharing went off through the daemon (`screen.share {on: false}`): the timer has nothing
    /// left to turn off.
    pub(crate) fn sharing_off(&self) {
        self.auto_off.cancel();
    }

    /// `agent.person {on}` from the verified app: the person turned sharing on or off
    /// themselves, so an agent's share no longer turns itself off.
    pub(crate) fn person(&self, caller: Caller) -> Result<Value, Refused> {
        if caller != Caller::App {
            return Err(refused(
                "origin.forbidden",
                "only the cmux app reports the person's change",
            ));
        }
        let was = self.auto_off.cancel();
        Ok(json!({"cancelled": was}))
    }

    /// The host's status said whether a viewer is connected (its `busy`).
    pub(crate) fn viewer(&self, connected: bool) {
        self.auto_off.viewer(connected);
    }

    /// Writes a refusal's row; returns the refusal.
    pub(crate) fn refuse(&self, actor: &Actor, action: &str, refusal: Refused) -> Refused {
        (self.sink.audit)(json!({
            "event": "remote_host.agent_share_refused",
            "agent": actor.json(),
            "action": action,
            "code": refusal.code,
            "message": refusal.message,
            "via": "daemon",
        }));
        refusal
    }

    /// A refused caller before it reached this module (a page, another transport).
    pub(crate) fn refuse_caller(
        &self,
        method: &str,
        params: &Value,
        code: &'static str,
        message: &str,
    ) {
        let actor = Actor::from_params(params.get("agent"), None);
        let action = params.get("action").and_then(Value::as_str).unwrap_or(method).to_owned();
        let _ = self.refuse(&actor, &action, refused(code, message));
    }

    fn ask_person(
        &self,
        actor: &Actor,
        action: Option<Action>,
        device: &Value,
        reason: &str,
    ) -> Value {
        (self.sink.audit)(json!({
            "event": "remote_host.agent_share_asks_person",
            "agent": actor.json(),
            "action": action.map(Action::word),
            "device": device,
            "reason": reason,
            "via": "daemon",
        }));
        json!({"dialog": true, "reason": reason})
    }

    /// `agent_share` in `remote-host-status`: whether an agent's share is armed, until when,
    /// and the latest notices (the app's only).
    pub(crate) fn status(&self) -> Value {
        let (armed, viewer) = self.auto_off.snapshot();
        let notices = lock(&self.sink.notices).1.clone();
        json!({
            "active": armed.is_some(),
            "agent": armed.as_ref().map(|armed| armed.actor.json()),
            "viewer": viewer,
            "off_in_s": armed.as_ref().and_then(|armed| armed.deadline).map(|deadline| deadline.saturating_duration_since(Instant::now()).as_secs()),
            "notices": notices,
        })
    }
}

/// One armed auto-off: whose share, on which device, how long with no viewer, and when (none
/// while a viewer is connected).
#[derive(Debug, Clone)]
pub(crate) struct Armed {
    pub(crate) actor: Actor,
    pub(crate) device: Value,
    pub(crate) idle: Duration,
    pub(crate) deadline: Option<Instant>,
}

#[derive(Default)]
struct OffState {
    armed: Option<Armed>,
    viewer: bool,
    thread: bool,
}

/// The auto-off timer: one thread while armed, waiting on a condition variable until the
/// deadline or a change (no polling). It stops when disarmed (fired, cancelled, re-armed into
/// a new deadline it picks up on its next wake).
pub(crate) struct AutoOff {
    state: Mutex<OffState>,
    changed: Condvar,
    fire: Box<dyn Fn(Armed) + Send + Sync>,
}

impl AutoOff {
    pub(crate) fn new(fire: Box<dyn Fn(Armed) + Send + Sync>) -> Arc<Self> {
        Arc::new(Self { state: Mutex::new(OffState::default()), changed: Condvar::new(), fire })
    }

    /// Arms (or re-arms) the timer for an agent's share: the countdown runs while no viewer
    /// is connected.
    pub(crate) fn arm(self: &Arc<Self>, mut armed: Armed) {
        let mut state = lock(&self.state);
        armed.deadline = (!state.viewer).then(|| Instant::now() + armed.idle);
        state.armed = Some(armed);
        self.wake(state);
    }

    /// Disarms; whether it was armed.
    pub(crate) fn cancel(self: &Arc<Self>) -> bool {
        let mut state = lock(&self.state);
        let was = state.armed.take().is_some();
        self.changed.notify_all();
        drop(state);
        was
    }

    /// A viewer connected (the countdown holds) or the last one left (it starts again).
    pub(crate) fn viewer(self: &Arc<Self>, connected: bool) {
        let mut state = lock(&self.state);
        if state.viewer == connected {
            return;
        }
        state.viewer = connected;
        if let Some(armed) = state.armed.as_mut() {
            armed.deadline = (!connected).then(|| Instant::now() + armed.idle);
        }
        self.wake(state);
    }

    fn snapshot(&self) -> (Option<Armed>, bool) {
        let state = lock(&self.state);
        (state.armed.clone(), state.viewer)
    }

    /// Wakes the timer thread, starting one when armed and none runs.
    fn wake(self: &Arc<Self>, mut state: MutexGuard<'_, OffState>) {
        self.changed.notify_all();
        if state.armed.is_none() || state.thread {
            return;
        }
        state.thread = true;
        drop(state);
        let timer = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("remote-agent-auto-off".into())
            .spawn(move || timer.run());
        if spawned.is_err() {
            lock(&self.state).thread = false;
        }
    }

    fn run(&self) {
        let mut state = lock(&self.state);
        loop {
            let Some(deadline) = state.armed.as_ref().map(|armed| armed.deadline) else {
                // Stop condition: nothing armed.
                state.thread = false;
                return;
            };
            match deadline {
                None => {
                    state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
                }
                Some(deadline) => {
                    let now = Instant::now();
                    if now >= deadline {
                        let fired = state.armed.take();
                        state.thread = false;
                        drop(state);
                        if let Some(fired) = fired {
                            (self.fire)(fired);
                        }
                        return;
                    }
                    state = self
                        .changed
                        .wait_timeout(state, deadline - now)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
    }
}

/// 32 random bytes as hex: a ticket nobody can guess.
fn mint_id() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| format!("cannot mint a ticket: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The host's state folder, from its one resolver (`cmux-tui`'s `remote_host::config::dir`:
/// `serve --dir`, `CMUX_HOST_DIR` or the home's host folder), set once at daemon start.
static HOST_DIR: OnceLock<std::path::PathBuf> = OnceLock::new();

/// Sets the folder of the host audit log; the daemon calls it once, before any agent asks.
pub fn set_host_dir(dir: std::path::PathBuf) {
    let _ = HOST_DIR.set(dir);
}

/// Appends `entry` to the host audit log, `audit.jsonl` in the host folder ([`set_host_dir`]),
/// owner-only, the file `cmux host` and `cmux remote-host` write. A failure is printed, never
/// fatal to the decision already made.
fn append_host_audit(entry: Value) {
    let Some(dir) = HOST_DIR.get() else {
        eprintln!("cmux-tui: cmux Remote audit log: the host folder is not known; row not written");
        return;
    };
    if let Err(error) = append_in(dir, entry) {
        eprintln!("cmux-tui: cmux Remote audit log: {error}");
    }
}

pub(crate) fn append_in(dir: &std::path::Path, mut entry: Value) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir)?;
    crate::platform::restrict_directory(dir)?;
    let path = dir.join("audit.jsonl");
    if let Some(fields) = entry.as_object_mut() {
        let seconds = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or_default();
        fields.insert("ts_unix".into(), json!(seconds));
    }
    let mut line = serde_json::to_vec(&entry)?;
    line.push(b'\n');
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&path)?;
    crate::platform::restrict_file(&path)?;
    file.write_all(&line)
}

#[cfg(test)]
#[path = "agent_share_tests.rs"]
mod tests;
