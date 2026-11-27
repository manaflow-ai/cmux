//! A Cloud machine create's rules, the app's `CloudMachineCreateFlow` and
//! `CloudMachineCreation` moved here (cmuxterm-hq `docs/rfd/drafts/why-swift.md`:
//! Rust owns state, lists and rules; Swift is the platform shell): the plan gate,
//! the default machine, the create's params, the same-key backoff, the approval
//! loop as a step machine, which failure offers an upgrade, the bootstrap left
//! to do and the creation's key bookkeeping. The app makes the calls and the
//! prompts each step names, and sends back what they answered.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// The last known plan limits (`CloudMachineLimits`).
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    #[serde(default)]
    pub max_active_vms: Option<i64>,
    #[serde(default)]
    pub active_vm_count: i64,
    #[serde(default)]
    pub plan_id: Option<String>,
}

/// Whether the plan lets a create go out.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "gate", rename_all = "snake_case")]
pub enum Gate {
    Allowed,
    /// A free plan: no machine at all.
    FreePlan,
    /// At the plan's cap of `max` running machines.
    AtLimit {
        max: i64,
    },
}

/// The plan gate from the last known limits; unknown limits, or a cap the
/// server makes room at (`makes_room`), leave it to the server.
pub fn gate(limits: Option<&Limits>, makes_room: bool) -> Gate {
    let Some(limits) = limits else { return Gate::Allowed };
    if limits.max_active_vms == Some(0)
        || limits.plan_id.as_deref().is_some_and(|plan| plan.to_lowercase() == "free")
    {
        return Gate::FreePlan;
    }
    match limits.max_active_vms {
        Some(max) if limits.active_vm_count >= max && !makes_room => Gate::AtLimit { max },
        _ => Gate::Allowed,
    }
}

/// The default machine: 2 vCPU, 4 GB, 20 GB disk (the platform's spare size).
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub name: Option<String>,
    pub cpu: i64,
    pub memory_mb: i64,
    pub disk_mb: i64,
}

pub const DEFAULT_CPU: i64 = 2;
pub const DEFAULT_MEMORY_MB: i64 = 4096;
pub const DEFAULT_DISK_MB: i64 = 20480;

/// `name` trimmed; empty is none.
pub fn trimmed(name: Option<&str>) -> Option<String> {
    name.map(str::trim).filter(|name| !name.is_empty()).map(str::to_owned)
}

/// The default machine named `name` (trimmed; empty is none).
pub fn named(name: Option<&str>) -> Machine {
    Machine {
        name: trimmed(name),
        cpu: DEFAULT_CPU,
        memory_mb: DEFAULT_MEMORY_MB,
        disk_mb: DEFAULT_DISK_MB,
    }
}

/// A create's bootstrap script, as the app holds it.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Script {
    pub kind: String,
    pub contents_base64: String,
    #[serde(default)]
    pub repo: Option<String>,
}

/// What a create sends: the machine sized by the app (`atLeast`), its
/// environment and the request's options.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CreateInput {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub environment: Option<String>,
    /// Explicit infrastructure provider; absent preserves the platform default.
    #[serde(default)]
    pub provider: Option<String>,
    /// The size the app read off the request (`CloudMachineRequest.atLeast`); the default machine's when none.
    #[serde(default)]
    pub cpu: Option<i64>,
    #[serde(default)]
    pub memory_mb: Option<i64>,
    #[serde(default)]
    pub disk_mb: Option<i64>,
    #[serde(default)]
    pub size_name: Option<String>,
    #[serde(default)]
    pub persistent: bool,
    #[serde(default)]
    pub script: Option<Script>,
    /// A machine config's contents in base64: `Some("")` for one with no contents.
    #[serde(default)]
    pub machine_config_base64: Option<String>,
}

/// The op, its args (what the approval holds) and the options the backend
/// checks before the op goes out (never sent).
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CreateParams {
    pub op: &'static str,
    pub args: Value,
    pub options: Value,
}

pub const CREATE_OP: &str = "cloud.machine.create";
pub const BOOT_OP: &str = "cloud.environment.boot";

/// The create's params: `cloud.environment.boot` in an environment, else `cloud.machine.create`.
pub fn create_params(input: &CreateInput) -> CreateParams {
    let machine = named(input.name.as_deref());
    let mut args = Map::new();
    args.insert(
        "size".into(),
        json!({
            "cpu": input.cpu.unwrap_or(machine.cpu),
            "memory_mb": input.memory_mb.unwrap_or(machine.memory_mb),
            "disk_mb": input.disk_mb.unwrap_or(machine.disk_mb),
        }),
    );
    if let Some(name) = machine.name {
        args.insert("name".into(), json!(name));
    }
    if let Some(environment) = &input.environment {
        args.insert("environment".into(), json!(environment));
    }
    if let Some(provider) = &input.provider {
        args.insert("provider".into(), json!(provider));
    }
    let mut options = args.clone();
    if let Some(size) = &input.size_name {
        options.insert("size_name".into(), json!(size));
    }
    if input.persistent {
        options.insert("idle_seconds".into(), json!(0));
    }
    if let Some(script) = &input.script {
        options.insert(
            "bootstrap".into(),
            json!({ "kind": script.kind, "contents_base64": script.contents_base64, "repo": script.repo }),
        );
    }
    if let Some(config) = &input.machine_config_base64 {
        options.insert("machine_config_base64".into(), json!(config));
    }
    CreateParams {
        op: if input.environment.is_none() { CREATE_OP } else { BOOT_OP },
        args: Value::Object(args),
        options: Value::Object(options),
    }
}

/// 250 ms, 500 ms, then 1 s between the same-key calls after the approval.
pub fn backoff_ms(attempt: i64) -> u64 {
    match attempt {
        ..=1 => 250,
        2 => 500,
        _ => 1000,
    }
}

/// The most same-key calls after the approval: enough that their backoffs add
/// up to `patience_ms`, so a clock that stands still still ends at this count.
pub fn waits(patience_ms: u64) -> i64 {
    let (mut waited, mut attempt) = (0u64, 1i64);
    while waited < patience_ms {
        waited += backoff_ms(attempt);
        attempt += 1;
    }
    attempt
}

/// The approval loop's state between steps.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    /// A person already confirmed in this flow.
    pub confirmed: bool,
    /// The request an earlier attempt with this key answered.
    #[serde(default)]
    pub earlier: Option<String>,
    /// The request this attempt knows is answered.
    #[serde(default)]
    pub approved: Option<String>,
    /// When this attempt learned the approval was answered.
    #[serde(default)]
    pub since_ms: u64,
    pub attempt: i64,
    pub waits: i64,
    pub patience_ms: u64,
    /// Passes begun (each one call).
    pub passes: i64,
    /// The pending request the last call named, while it is asked or answered.
    #[serde(default)]
    pub request: Option<String>,
}

/// What the app heard since the last step.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// The flow begins.
    Start {
        confirmed: bool,
        #[serde(default)]
        earlier: Option<String>,
        patience_ms: u64,
        now_ms: u64,
    },
    /// The call answered.
    Answered,
    /// The call answered `approval_pending`, naming `request` (or not).
    Pending {
        #[serde(default)]
        request: Option<String>,
        now_ms: u64,
    },
    /// The person answered the prompt.
    Asked { yes: bool },
    /// The approval answer went out: `done`, `already_answered` (an earlier attempt
    /// answered it and was cancelled before recording that) or `answered_elsewhere`.
    Approved { outcome: ApproveOutcome, now_ms: u64 },
    /// The backoff pause ended.
    Paused,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApproveOutcome {
    Done,
    AlreadyAnswered,
    AnsweredElsewhere,
}

/// What the app does next.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "do", rename_all = "snake_case")]
pub enum Effect {
    /// Call the op with the key.
    Call,
    /// Await the work beside the first call, then return the answer.
    Done,
    /// Ask the person about `request`.
    Ask { request: String },
    /// Note `request` is being answered (`onAnswering`), await the work beside, then answer it.
    Approve { request: String },
    /// Tell the caller `request` is answered (`onApproved`).
    RecordApproved { request: String },
    /// Wait `ms` (the backoff of `attempt`).
    Pause { attempt: i64, ms: u64 },
    /// End with this failure.
    Fail { failure: Failure },
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Failure {
    Declined,
    StillPending { request: String },
    NoApprovalRequest,
}

/// The state and what to do after one event.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Step {
    pub state: Approval,
    pub effects: Vec<Effect>,
}

fn next_pass(mut state: Approval, mut effects: Vec<Effect>) -> Step {
    // `for _ in 0...max(waits, 0)`: waits + 1 passes.
    if state.passes <= state.waits.max(0) {
        state.passes += 1;
        effects.push(Effect::Call);
    } else {
        let request = state.approved.clone().unwrap_or_default();
        effects.push(Effect::Fail { failure: Failure::StillPending { request } });
    }
    Step { state, effects }
}

fn fail(state: Approval, failure: Failure) -> Step {
    Step { state, effects: vec![Effect::Fail { failure }] }
}

/// One step of the approval loop: the first call, then same-key calls for
/// `patience_ms` after the approval, each pass returning, failing, or waiting one backoff.
pub fn step(state: Approval, event: Event) -> Step {
    match event {
        Event::Start { confirmed, earlier, patience_ms, now_ms } => next_pass(
            Approval {
                confirmed,
                earlier,
                approved: None,
                since_ms: now_ms,
                attempt: 0,
                waits: waits(patience_ms),
                patience_ms,
                passes: 0,
                request: None,
            },
            vec![],
        ),
        Event::Answered => Step { state, effects: vec![Effect::Done] },
        Event::Pending { request, now_ms } => {
            let mut state = state;
            let Some(request) = request else {
                return fail(state, Failure::NoApprovalRequest);
            };
            if state.approved.is_none() && state.earlier.as_deref() == Some(request.as_str()) {
                state.approved = Some(request.clone());
                state.since_ms = now_ms;
            }
            if let Some(approved) = &state.approved {
                let held = now_ms.saturating_sub(state.since_ms);
                if *approved != request || held >= state.patience_ms || state.attempt >= state.waits
                {
                    return fail(state, Failure::StillPending { request });
                }
                let attempt = state.attempt;
                return Step {
                    state,
                    effects: vec![Effect::Pause { attempt, ms: backoff_ms(attempt) }],
                };
            }
            state.request = Some(request.clone());
            if !state.confirmed {
                return Step { state, effects: vec![Effect::Ask { request }] };
            }
            Step { state, effects: vec![Effect::Approve { request }] }
        }
        Event::Asked { yes } => {
            let mut state = state;
            if !yes {
                return fail(state, Failure::Declined);
            }
            state.confirmed = true;
            let request = state.request.clone().unwrap_or_default();
            Step { state, effects: vec![Effect::Approve { request }] }
        }
        Event::Approved { outcome, now_ms } => {
            let mut state = state;
            let request = state.request.take().unwrap_or_default();
            state.approved = Some(request.clone());
            state.since_ms = now_ms;
            state.attempt = 1;
            let effects = match outcome {
                ApproveOutcome::AnsweredElsewhere => vec![],
                ApproveOutcome::Done | ApproveOutcome::AlreadyAnswered => {
                    vec![Effect::RecordApproved { request }]
                }
            };
            next_pass(state, effects)
        }
        Event::Paused => {
            let mut state = state;
            state.attempt += 1;
            next_pass(state, vec![])
        }
    }
}

/// Which plan a refusal offers, and whether the app's own gate offered it.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RefusalInput {
    /// The Cloud API's `planRequired` (its message, link and plan pass through in the app).
    PlanRequired,
    /// The create flow's own gate refused for a free plan.
    FreePlan,
    /// The gate refused at the cap.
    AtLimit,
    /// An app op failure with `code` and its details' `plan`.
    OpFailure {
        code: String,
        #[serde(default)]
        plan: Option<String>,
    },
    Other,
}

/// The upgrade a failure offers: `plan`, and whether this App offered it itself.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ProOffer {
    pub plan: &'static str,
    pub offered: bool,
}

/// The app op code of a plan refusal (`CloudAppOpFailure.planRequired`).
pub const PLAN_REQUIRED_CODE: &str = "cmux.cloud.plan_required";

/// The upgrade `input` offers, if any; `None` for a `PlanRequired` too (its fields pass through in the app).
pub fn pro_offer(input: &RefusalInput, plan_required_code: &str) -> Option<ProOffer> {
    match input {
        RefusalInput::FreePlan => Some(ProOffer { plan: "pro", offered: true }),
        RefusalInput::OpFailure { code, plan } if code == plan_required_code => Some(ProOffer {
            plan: if plan.as_deref() == Some("max") { "max" } else { "pro" },
            offered: false,
        }),
        _ => None,
    }
}

/// One part of a creation's bootstrap: `requested`, and its start's status if it started.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct Part {
    #[serde(default)]
    pub requested: bool,
    #[serde(default)]
    pub status: Option<String>,
}

/// A requested part that has not started yet, or whose start failed.
pub fn needs(part: &Part) -> bool {
    part.requested && part.status.as_deref().is_none_or(|status| status == "failed")
}

/// The bootstrap work a creation has left.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Needs {
    pub script: bool,
    pub machine_config: bool,
    pub bootstrap: bool,
}

pub fn bootstrap_needs(script: &Part, machine_config: &Part) -> Needs {
    let (script, machine_config) = (needs(script), needs(machine_config));
    Needs { script, machine_config, bootstrap: script || machine_config }
}

/// A creation's key and what it sent under it (`CloudMachineRequest`'s create fields).
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CreateKey {
    pub idempotency_key: String,
    #[serde(default)]
    pub was_sent: bool,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub route: Option<String>,
    #[serde(default)]
    pub approved_request: Option<String>,
    #[serde(default)]
    pub answering_request: Option<String>,
}

/// A change to a creation's key.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "change", rename_all = "snake_case")]
pub enum KeyChange {
    /// The create went to `team` on `route`; the first send's team and route stay.
    Sent {
        #[serde(default)]
        team: Option<String>,
        route: String,
    },
    /// The person answered `request` for `key`.
    Approved { request: String, key: String },
    /// An attempt with `key` is about to answer `request`.
    Answering { request: String, key: String },
    /// The server refused `key`'s create outright: a new key (`new_key`, the app's UUID) for a Retry.
    Renew { key: String, new_key: String },
}

/// `key` after `change`; nothing changes for a key the creation moved on from.
pub fn change_key(mut key: CreateKey, change: KeyChange) -> CreateKey {
    match change {
        KeyChange::Sent { team, route } => {
            if !key.was_sent {
                key.team = team;
                key.route = Some(route);
            }
            key.was_sent = true;
        }
        KeyChange::Approved { request, key: sent } => {
            if key.idempotency_key == sent {
                key.approved_request = Some(request);
            }
        }
        KeyChange::Answering { request, key: sent } => {
            if key.idempotency_key == sent {
                key.answering_request = Some(request);
            }
        }
        KeyChange::Renew { key: sent, new_key } => {
            if key.idempotency_key == sent {
                // A new key has no route yet (the app's `idempotencyKey` didSet): its first send picks one.
                key = CreateKey { idempotency_key: new_key, ..CreateKey::default() };
            }
        }
    }
    key
}

/// A Retry's phase: `requesting` with no machine yet, else `created`.
pub fn restart_phase(has_session: bool) -> &'static str {
    if has_session { "created" } else { "requesting" }
}

#[cfg(test)]
mod tests;
