//! One Cloud machine as the app shows it ([`Machine`]), read from either server shape, and the
//! facts the app reads off it ([`Facts`]).
//!
//! The JSON is the app's own (`CloudMachine.swift` decodes it with no rules): camelCase fields,
//! timestamps in epoch milliseconds, statuses and reasons as their raw words. The app writes the
//! same JSON back when it asks a rule about a record it holds.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

use crate::json::{self, Strict, int, present};

/// A machine's status. The in-between states stay their own (cloud-machine-ops.ts
/// `CloudMachineStatus`): a pausing machine is not paused yet, and a deleting one is not gone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Status {
    Provisioning,
    Running,
    Failed,
    Paused,
    Destroyed,
    Unknown,
    /// A Pause Machine (or the idle auto-pause) the server accepted; the provider call has not
    /// landed yet, so the machine is not paused.
    Pausing,
    /// A Resume Machine the server accepted; the VM is starting again.
    Starting,
    /// A Kill Machine the server accepted; the VM is not gone yet.
    Deleting,
}

impl Status {
    pub const ALL: [Status; 9] = [
        Status::Provisioning,
        Status::Running,
        Status::Failed,
        Status::Paused,
        Status::Destroyed,
        Status::Unknown,
        Status::Pausing,
        Status::Starting,
        Status::Deleting,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Provisioning => "provisioning",
            Status::Running => "running",
            Status::Failed => "failed",
            Status::Paused => "paused",
            Status::Destroyed => "destroyed",
            Status::Unknown => "unknown",
            Status::Pausing => "pausing",
            Status::Starting => "starting",
            Status::Deleting => "deleting",
        }
    }

    /// The status a word names; `Unknown` for any other word.
    pub fn from_word(word: &str) -> Status {
        Status::ALL.into_iter().find(|status| status.as_str() == word).unwrap_or(Status::Unknown)
    }

    /// A machine whose daemon can be reached (or soon will be).
    pub fn is_live(self) -> bool {
        matches!(self, Status::Running | Status::Provisioning | Status::Starting)
    }

    /// A pause, resume or delete is on its way. Power actions wait until it ends.
    pub fn is_changing(self) -> bool {
        matches!(self, Status::Pausing | Status::Starting | Status::Deleting)
    }
}

impl Serialize for Status {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Status {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Status::from_word(&String::deserialize(deserializer)?))
    }
}

/// Why a paused machine is paused: cmux's idle auto-pause (`idle`) or a person or caller's Pause
/// Machine (`user`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PauseReason {
    Idle,
    User,
}

/// A provider operation a machine may advertise.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Snapshot,
    Restore,
    Fork,
    Exec,
    Stats,
    Restart,
    Ports,
    Desktop,
    Sizing,
    PersistentHome,
}

impl Operation {
    /// Every operation, in the contract's order.
    pub const ALL: [Operation; 10] = [
        Operation::Snapshot,
        Operation::Restore,
        Operation::Fork,
        Operation::Exec,
        Operation::Stats,
        Operation::Restart,
        Operation::Ports,
        Operation::Desktop,
        Operation::Sizing,
        Operation::PersistentHome,
    ];

    fn word(self) -> &'static str {
        match self {
            Operation::Snapshot => "snapshot",
            Operation::Restore => "restore",
            Operation::Fork => "fork",
            Operation::Exec => "exec",
            Operation::Stats => "stats",
            Operation::Restart => "restart",
            Operation::Ports => "ports",
            Operation::Desktop => "desktop",
            Operation::Sizing => "sizing",
            Operation::PersistentHome => "persistentHome",
        }
    }
}

/// Provider operations and session transports advertised for one machine.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Capabilities {
    pub snapshot: bool,
    pub restore: bool,
    pub fork: bool,
    pub exec: bool,
    pub stats: bool,
    pub restart: bool,
    pub ports: bool,
    pub desktop: bool,
    pub sizing: bool,
    pub persistent_home: bool,
    pub attach_transports: Vec<String>,
}

impl Capabilities {
    /// The operations a list of capability names advertises. Accepts the contract spelling
    /// (`persistentHome`) and snake case (`persistent_home`); names that are not provider
    /// operations (such as `agent_session`) are ignored.
    pub fn from_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Capabilities {
        let named: Vec<String> =
            names.into_iter().map(|name| name.replace('_', "").to_lowercase()).collect();
        let mut capabilities = Capabilities::default();
        for operation in Operation::ALL {
            if named.iter().any(|name| *name == operation.word().to_lowercase()) {
                capabilities.set(operation, true);
            }
        }
        capabilities
    }

    /// The web route's boolean object (`/api/vm`) or a list of names (the Cloud app server's).
    /// A list with another element type, or an object with a field of another type, fails.
    pub fn read(value: &Value) -> Strict<Capabilities> {
        if let Some(items) = value.as_array()
            && let Some(names) = items.iter().map(Value::as_str).collect::<Option<Vec<_>>>()
        {
            return Ok(Capabilities::from_names(names));
        }
        let object = json::object(value, "capabilities")?;
        let mut capabilities = Capabilities::default();
        for operation in Operation::ALL {
            capabilities.set(operation, json::boolean(object, operation.word())?.unwrap_or(false));
        }
        capabilities.attach_transports =
            json::strings(object, "attachTransports")?.unwrap_or_default();
        Ok(capabilities)
    }

    pub fn supports(&self, operation: Operation) -> bool {
        match operation {
            Operation::Snapshot => self.snapshot,
            Operation::Restore => self.restore,
            Operation::Fork => self.fork,
            Operation::Exec => self.exec,
            Operation::Stats => self.stats,
            Operation::Restart => self.restart,
            Operation::Ports => self.ports,
            Operation::Desktop => self.desktop,
            Operation::Sizing => self.sizing,
            Operation::PersistentHome => self.persistent_home,
        }
    }

    fn set(&mut self, operation: Operation, on: bool) {
        let field = match operation {
            Operation::Snapshot => &mut self.snapshot,
            Operation::Restore => &mut self.restore,
            Operation::Fork => &mut self.fork,
            Operation::Exec => &mut self.exec,
            Operation::Stats => &mut self.stats,
            Operation::Restart => &mut self.restart,
            Operation::Ports => &mut self.ports,
            Operation::Desktop => &mut self.desktop,
            Operation::Sizing => &mut self.sizing,
            Operation::PersistentHome => &mut self.persistent_home,
        };
        *field = on;
    }

    /// The advertised operations, in contract order.
    pub fn supported_operations(&self) -> Vec<Operation> {
        Operation::ALL.into_iter().filter(|operation| self.supports(*operation)).collect()
    }
}

/// Why the machine's last pause, resume or resize failed (the cmux-next backend's `error`): the
/// server answers those calls at once and runs the provider call after, so a failure only shows
/// on the record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeFailure {
    pub code: String,
    #[serde(default)]
    pub message: String,
    /// When it failed (epoch ms); nil when the server did not say.
    #[serde(default)]
    pub at: Option<f64>,
    /// What to show: the message, else the code.
    #[serde(default)]
    pub text: String,
}

impl ChangeFailure {
    pub fn new(code: String, message: String, at: Option<f64>) -> ChangeFailure {
        let text = if message.is_empty() { code.clone() } else { message.clone() };
        ChangeFailure { code, message, at, text }
    }

    /// The same failure as another (the app compares failures without their shown text).
    fn same(&self, other: &ChangeFailure) -> bool {
        self.code == other.code && self.message == other.message && self.at == other.at
    }

    pub(crate) fn same_option(left: Option<&ChangeFailure>, right: Option<&ChangeFailure>) -> bool {
        match (left, right) {
            (None, None) => true,
            (Some(left), Some(right)) => left.same(right),
            _ => false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Address {
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Size {
    pub name: Option<String>,
    pub cpu: Option<i64>,
    pub memory_mb: Option<i64>,
    pub storage_mb: Option<i64>,
}

/// Diagnostics from the idle auto-pause cron. Timestamps are epoch milliseconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IdlePauseDiagnostics {
    pub minutes: i64,
    #[serde(default)]
    pub last_checked_at: Option<i64>,
    #[serde(default)]
    pub idle_since: Option<i64>,
    #[serde(default)]
    pub last_api_activity_at: Option<i64>,
    pub private_address_known: bool,
    #[serde(default)]
    pub last_decision: Option<LastDecision>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastDecision {
    pub at: i64,
    pub outcome: String,
    pub reason: String,
    pub run: DecisionRun,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DecisionRun {
    pub checked: i64,
    pub elapsed_ms: i64,
}

impl IdlePauseDiagnostics {
    /// The diagnostics object, or nil when it is not one this client reads (best effort: an older
    /// or partly deployed server may omit it or send another shape). A malformed `lastDecision`
    /// drops only the decision.
    fn read(value: &Value) -> Option<IdlePauseDiagnostics> {
        let fields = value.as_object()?;
        let integer = |object: &Map<String, Value>, key: &str| object.get(key).and_then(int);
        let minutes = integer(fields, "minutes")?;
        let private_address_known = fields.get("privateAddressKnown")?.as_bool()?;
        let last_decision = fields.get("lastDecision").and_then(|value| {
            let decision = value.as_object()?;
            let run = decision.get("run")?.as_object()?;
            Some(LastDecision {
                at: integer(decision, "at")?,
                outcome: decision.get("outcome")?.as_str()?.to_owned(),
                reason: decision.get("reason")?.as_str()?.to_owned(),
                run: DecisionRun {
                    checked: integer(run, "checked")?,
                    elapsed_ms: integer(run, "elapsedMs")?,
                },
            })
        });
        Some(IdlePauseDiagnostics {
            minutes,
            last_checked_at: integer(fields, "lastCheckedAt"),
            idle_since: integer(fields, "idleSince"),
            last_api_activity_at: integer(fields, "lastApiActivityAt"),
            private_address_known,
            last_decision,
        })
    }
}

/// One Cloud machine. The id is the provider VM id (`vm-…`) or the cmux-next machine id (`vm_…`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub provider: String,
    pub status: Status,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub slug: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub image_version: Option<String>,
    #[serde(default)]
    pub created_at: Option<f64>,
    /// Person who created the machine, when the API supplies it.
    #[serde(default, alias = "createdByUserId")]
    pub created_by: Option<String>,
    /// The team that owns the machine (the cmux-next record's `team`); nil on a classic record.
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub address: Option<Address>,
    #[serde(default)]
    pub size: Option<Size>,
    /// Server-declared provider operations; nil when the record carried none (an older server,
    /// or a cmux-next record whose `capabilities` names are not provider operations).
    #[serde(default, rename = "capabilities", alias = "declaredCapabilities")]
    pub declared_capabilities: Option<Capabilities>,
    #[serde(default)]
    pub pause_reason: Option<PauseReason>,
    /// Minutes of idle before the server pauses this machine; 0 is Off.
    #[serde(default)]
    pub idle_pause_minutes: Option<i64>,
    #[serde(default)]
    pub idle_pause: Option<IdlePauseDiagnostics>,
    /// What one hour of this machine's size costs, in US dollars, from the server's rate table.
    #[serde(default)]
    pub hourly_rate_usd: Option<f64>,
    /// The classic server's row revision (epoch ms).
    #[serde(default)]
    pub updated_at: Option<f64>,
    /// The app server's row revision, decimal text (never truncated to a fixed width).
    #[serde(default)]
    pub server_revision: Option<String>,
    /// When the machine last started running (epoch ms); nil while it is paused.
    #[serde(default)]
    pub running_since: Option<f64>,
    /// When the server deletes the machine if it stays paused (the next record's `evict_at`,
    /// epoch ms); nil when the record does not say (an older server, or one not deleting yet).
    #[serde(default)]
    pub evict_at: Option<f64>,
    /// The auto-size pick a create with `autosize` answered (`{vcpus, memoryGb, pick, reason}`).
    #[serde(default)]
    pub size_pick: Option<Value>,
    /// Why the last pause, resume or resize failed; the next change clears it on the server.
    #[serde(default, rename = "error", alias = "lastChangeFailure")]
    pub last_change_failure: Option<ChangeFailure>,
    /// The newest unresolved Pause, Resume or Kill sent from this app (never read from a server).
    #[serde(default)]
    pub pending_change: Option<Status>,
    #[serde(default, rename = "pendingMutationID")]
    pub pending_mutation_id: Option<String>,
    #[serde(default, rename = "failedMutationID")]
    pub failed_mutation_id: Option<String>,
    /// The cmux-next record's `desktop`: the machine serves its agent display over the link.
    #[serde(default)]
    pub serves_desktop: bool,
}

impl Machine {
    /// A record with only an id and a status (tests and the app's stand-ins).
    pub fn new(id: &str, status: Status) -> Machine {
        Machine {
            id: id.to_owned(),
            provider: String::new(),
            status,
            display_name: None,
            slug: None,
            kind: None,
            image: None,
            image_version: None,
            created_at: None,
            created_by: None,
            team: None,
            address: None,
            size: None,
            declared_capabilities: None,
            pause_reason: None,
            idle_pause_minutes: None,
            idle_pause: None,
            hourly_rate_usd: None,
            updated_at: None,
            server_revision: None,
            running_since: None,
            evict_at: None,
            size_pick: None,
            last_change_failure: None,
            pending_change: None,
            pending_mutation_id: None,
            failed_mutation_id: None,
            serves_desktop: false,
        }
    }

    /// The status the app shows: a change sent from here, else the record's.
    pub fn shown_status(&self) -> Status {
        self.pending_change.unwrap_or(self.status)
    }

    /// The machine's name wherever cmux shows one: the person's name, else the generated slug.
    pub fn shown_name(&self) -> Option<&str> {
        [&self.display_name, &self.slug]
            .into_iter()
            .flatten()
            .map(String::as_str)
            .find(|name| !name.is_empty())
    }

    /// Sidebar and menu title: the shown name, else the id.
    pub fn title(&self) -> &str {
        self.shown_name().unwrap_or(&self.id)
    }

    /// The declared capabilities (or none), with `desktop` when the machine serves it.
    pub fn capabilities(&self) -> Capabilities {
        let mut capabilities = self.declared_capabilities.clone().unwrap_or_default();
        if self.serves_desktop {
            capabilities.desktop = true;
        }
        capabilities
    }

    /// Whether an action needing `operation` may be attempted: a declared set must advertise
    /// it, and a record without one keeps the behavior from before capabilities existed (the
    /// server refuses what its provider cannot do).
    pub fn allows(&self, operation: Operation) -> bool {
        if operation == Operation::Desktop && self.serves_desktop {
            return true;
        }
        self.declared_capabilities.as_ref().is_none_or(|declared| declared.supports(operation))
    }
}

/// A classic `/api/vm` record (list, detail, create, restore and fork). A malformed machine
/// field fails the record; display facts (the pause reason, idle facts, the cost, the running
/// start, the size pick, the change failure) drop themselves instead.
pub fn from_classic(value: &Value) -> Strict<Machine> {
    let c = json::object(value, "machine")?;
    let id = match c.get("id") {
        Some(Value::String(id)) => id.clone(),
        _ => return Err("id: missing".into()),
    };
    let mut machine = Machine::new(&id, Status::Provisioning);
    machine.provider = json::string(c, "provider")?.unwrap_or_default();
    // A create response carries no status; the machine is coming up.
    machine.status = match present(c, "status") {
        None => Status::Provisioning,
        Some(Value::String(word)) => Status::from_word(word),
        Some(_) => return Err("status: not a string".into()),
    };
    machine.display_name = json::string(c, "displayName")?;
    machine.slug = json::string(c, "slug")?;
    machine.kind = json::string(c, "kind")?;
    machine.image = json::string(c, "image")?;
    machine.image_version = json::string(c, "imageVersion")?;
    machine.created_at = json::number(c, "createdAt")?;
    // `createdByUserId`, else `createdBy` as `{userId, displayName}` or the earlier string.
    machine.created_by = match json::string(c, "createdByUserId")? {
        Some(user) => Some(user),
        None => match present(c, "createdBy") {
            None => None,
            Some(Value::String(user)) => Some(user.clone()),
            Some(Value::Object(creator)) => match creator.get("userId") {
                Some(Value::String(user)) => Some(user.clone()),
                _ => return Err("createdBy.userId: missing".into()),
            },
            Some(_) => return Err("createdBy: not a creator".into()),
        },
    };
    machine.address = present(c, "address")
        .map(|value| {
            let address = json::object(value, "address")?;
            Ok::<_, String>(Address {
                ipv4: json::string(address, "ipv4")?,
                ipv6: json::string(address, "ipv6")?,
            })
        })
        .transpose()?;
    machine.size = present(c, "size")
        .map(|value| {
            let size = json::object(value, "size")?;
            Ok::<_, String>(Size {
                name: json::string(size, "name")?,
                cpu: json::integer(size, "cpu")?,
                memory_mb: json::integer(size, "memoryMb")?,
                storage_mb: json::integer(size, "storageMb")?,
            })
        })
        .transpose()?;
    machine.declared_capabilities =
        present(c, "capabilities").map(Capabilities::read).transpose()?;
    machine.pause_reason = match c.get("pauseReason").and_then(Value::as_str) {
        Some("idle") => Some(PauseReason::Idle),
        Some("user") => Some(PauseReason::User),
        _ => None,
    };
    machine.idle_pause_minutes = c.get("idlePauseMinutes").and_then(int);
    machine.idle_pause = c.get("idlePause").and_then(IdlePauseDiagnostics::read);
    machine.updated_at = c.get("updatedAt").and_then(Value::as_f64);
    machine.hourly_rate_usd = c.get("hourlyRateUsd").and_then(Value::as_f64);
    machine.running_since = c.get("runningSince").and_then(Value::as_f64);
    machine.size_pick = c.get("sizePick").filter(|pick| size_pick(pick)).cloned();
    machine.last_change_failure = c.get("error").and_then(classic_failure);
    Ok(machine)
}

/// Whether `value` is an auto-size pick the app reads (`{vcpus, memoryGb, pick, reason}`).
fn size_pick(value: &Value) -> bool {
    let Some(pick) = value.as_object() else { return false };
    pick.get("vcpus").and_then(int).is_some()
        && pick.get("memoryGb").and_then(Value::as_f64).is_some()
        && pick.get("pick").and_then(Value::as_str).is_some()
        && pick.get("reason").and_then(Value::as_str).is_some()
}

/// The classic record's `error`: a code, with the message and the time when given.
fn classic_failure(value: &Value) -> Option<ChangeFailure> {
    let fields = value.as_object()?;
    let code = fields.get("code")?.as_str()?.to_owned();
    let message = match present(fields, "message") {
        None => String::new(),
        Some(Value::String(message)) => message.clone(),
        Some(_) => return None,
    };
    Some(ChangeFailure::new(code, message, fields.get("at").and_then(Value::as_f64)))
}

/// The first of `keys` the record carries, even as null (an older app server's spelling only
/// when the newer one is absent).
fn first<'a>(value: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

/// A record of the cmux-next backend (contract 1.2, cmux-cloud-wire's generated
/// `CloudMachine`), as the Cloud app server answers it; nil without an id.
pub fn from_next(value: &Value) -> Option<Machine> {
    let fields = value.as_object()?;
    let id = fields.get("id")?.as_str().filter(|id| !id.is_empty())?;
    let status = match fields.get("status").and_then(Value::as_str) {
        Some(
            word @ ("provisioning" | "starting" | "running" | "pausing" | "paused" | "deleting"
            | "failed"),
        ) => Status::from_word(word),
        _ => Status::Unknown,
    };
    let mut machine = Machine::new(id, status);
    machine.provider = "cmux-next".into();
    machine.display_name = json::text(fields.get("name"));
    // `capabilities` is the older guest/session name list (`agent_session`, `terminal`, ...), not
    // a provider feature gate: only the dedicated provider-operation field gates actions.
    machine.declared_capabilities =
        first(fields, &["provider_operations", "providerOperations", "provider_capabilities"])
            .and_then(|raw| match raw.as_array() {
                Some(names) => {
                    Some(Capabilities::from_names(names.iter().filter_map(Value::as_str)))
                }
                None => Capabilities::read(raw).ok(),
            });
    // The idle auto-pause fields, when the backend sends them (`/api/vm` names).
    machine.idle_pause_minutes = fields.get("idlePauseMinutes").and_then(int).or_else(|| {
        let policy = first(fields, &["idle_policy", "idlePolicy"])?.as_object()?;
        json::whole(policy.get("idle_seconds")?.as_f64()? / 60.0)
    });
    machine.idle_pause = fields.get("idlePause").and_then(IdlePauseDiagnostics::read);
    // Why cmux paused the machine by itself: `idle` and the cost backstop `no_report` are both its
    // own idle pause, which an attach resumes; a VM stopped from inside (`provider_stopped`,
    // `provider_paused`) and a person's pause (null) carry no reason the app shows.
    machine.pause_reason =
        match first(fields, &["pause_reason", "pauseReason"]).and_then(Value::as_str) {
            Some("idle" | "no_report") => Some(PauseReason::Idle),
            Some("user") => Some(PauseReason::User),
            _ => None,
        };
    machine.last_change_failure = fields.get("error").and_then(|error| {
        let error = error.as_object()?;
        let code = error.get("code")?.as_str().filter(|code| !code.is_empty())?;
        let message = json::text(error.get("message")).unwrap_or_default();
        Some(ChangeFailure::new(code.to_owned(), message, error.get("at").and_then(Value::as_f64)))
    });
    machine.server_revision = json::text(fields.get("revision"));
    // The machine serves `desktop` (cloud-machine-ops.ts CloudMachine.desktop); absent from an older server.
    machine.serves_desktop = fields.get("desktop").and_then(Value::as_bool).unwrap_or(false);
    machine.created_by = json::text(fields.get("creator"));
    machine.team = json::text(fields.get("team"));
    // The contract's `created_at` (epoch ms); the classic `createdAt` is never in this record.
    machine.created_at = fields.get("created_at").and_then(Value::as_f64);
    // When a machine left paused is deleted (cmux-platform `evict_at`, epoch ms); null or absent
    // while the server is not deleting paused machines, and a malformed value drops only itself.
    machine.evict_at = first(fields, &["evict_at", "evictAt"])
        .and_then(Value::as_f64)
        .filter(|at| at.is_finite() && *at > 0.0);
    Some(machine)
}

/// The name prefixes that tag a Cloud machine as agent or fleet infrastructure: VMs our agent
/// tooling makes under a person's account (lane hosts and peers `fs-…`, probes `sr2-…`, lane VMs
/// `lane-vm-…`, and `fleet-…` for any new kind). leo-workspace `tools/cloud-vm-up`
/// (`FLEET_NAME_PREFIXES`) names every VM it makes with one; the two lists stay the same.
pub const AGENT_INFRASTRUCTURE_PREFIXES: [&str; 4] = ["fleet-", "fs-", "sr2-", "lane-vm-"];

/// Whether a machine named `name` is agent infrastructure (trimmed, case-insensitive).
pub fn is_agent_infrastructure(name: Option<&str>) -> bool {
    let Some(name) = name.map(|name| name.trim().to_lowercase()).filter(|name| !name.is_empty())
    else {
        return false;
    };
    AGENT_INFRASTRUCTURE_PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

/// What the app reads off one record, in one answer.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts {
    /// The declared capabilities (or the empty set), with `desktop` when the machine serves it.
    pub capabilities: Capabilities,
    /// The operations an action may attempt (see [`Machine::allows`]).
    pub allowed: Vec<Operation>,
    /// The machine has run at least once: a running start, or running, pausing, paused or
    /// starting (a paused machine ran before it paused).
    pub has_run: bool,
    /// The machine is gone or going: not listed to phones.
    pub gone_for_phones: bool,
    /// Agent infrastructure by its shown name, not one of its owner's own machines: the right
    /// sidebar's Machines section leaves it out.
    pub agent_infrastructure: bool,
    /// Open Desktop's viewer when none is named (`rd` or `web`) for the signed-in user.
    pub desktop_viewer: &'static str,
}

/// The facts of `machine` for the signed-in `user`.
pub fn facts(machine: &Machine, user: Option<&str>) -> Facts {
    let capabilities = machine.capabilities();
    let shown = machine.shown_status();
    Facts {
        allowed: Operation::ALL
            .into_iter()
            .filter(|operation| machine.allows(*operation))
            .collect(),
        has_run: machine.running_since.is_some()
            || matches!(
                machine.status,
                Status::Running | Status::Pausing | Status::Paused | Status::Starting
            ),
        gone_for_phones: [machine.status, shown]
            .iter()
            .any(|status| matches!(status, Status::Destroyed | Status::Deleting)),
        agent_infrastructure: is_agent_infrastructure(machine.shown_name()),
        desktop_viewer: desktop_viewer(machine, &capabilities, user),
        capabilities,
    }
}

/// `rd` for a machine whose capabilities declare `desktop` (its image carries the `cmux-rd` host
/// on the agent display), `web` (noVNC) for one that declares none. A cmux-next machine that
/// serves its desktop gives the `rd` stream to its creator alone (the link token's mint refuses a
/// teammate), so anyone else keeps the noVNC page.
fn desktop_viewer(
    machine: &Machine,
    capabilities: &Capabilities,
    user: Option<&str>,
) -> &'static str {
    let declared = machine.declared_capabilities.as_ref().is_some_and(|declared| declared.desktop);
    if !machine.serves_desktop || declared {
        return if capabilities.desktop { "rd" } else { "web" };
    }
    match user {
        Some(user) if !user.is_empty() && machine.created_by.as_deref() == Some(user) => "rd",
        _ => "web",
    }
}

#[cfg(test)]
mod tests;
