//! `cmux-cloud-start-core::app_state` over the JSON channel (`cloud_state_*`): the app's Cloud
//! state that is not a request or a view. A creation from the click to its open terminal and its
//! run's steps (`CloudMachineCreation`, `CloudCreations`, `CloudCreationFlow`), the signed-out
//! sign-in continuation, the fronted chats (`CloudFrontedChats`) and the access asks and revokes
//! (`CloudAccessAsks`, `CloudAccessRevokes`). The app holds each state between calls, sends it
//! with one action and keeps the state the answer returns; it runs the effects the answer lists.

use std::collections::BTreeMap;

use cmux_cloud_start_core::app_state::access::{self, Asks, Chat, Listed, Revokes};
use cmux_cloud_start_core::app_state::creation::{self, Creation, Creations, Event, RefusalSource};
use cmux_cloud_start_core::app_state::flow::{self, BootstrapAt, Continuation, RunError};
use cmux_cloud_start_core::app_state::fronted::{self, Entry, Front, Fronted, Tab};
use cmux_cloud_start_core::machine_bootstrap::Run;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_state_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(answer: T) -> Result<Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct New {
    id: String,
    #[serde(default)]
    window_id: Option<String>,
    #[serde(default)]
    machine_id: Option<String>,
    now_ms: u64,
}

#[derive(Deserialize)]
struct Apply {
    creation: Creation,
    event: Event,
}

#[derive(Deserialize)]
struct Finished {
    run: Run,
}

#[derive(Deserialize)]
struct Refused {
    source: RefusalSource,
}

/// One action on the creations in flight.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
enum CreationsAction {
    /// List a creation and show it in its window (`start`).
    Start {
        creation: Box<Creation>,
    },
    /// One event of one creation.
    Apply {
        id: String,
        event: Event,
    },
    #[serde(rename_all = "camelCase")]
    Retry {
        id: String,
        now_ms: u64,
    },
    Dismiss {
        id: String,
        #[serde(default)]
        shown: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    RunEnded {
        id: String,
        error: RunError,
        task_cancelled: bool,
        started_by_person: bool,
    },
    #[serde(rename_all = "camelCase")]
    LingerEnds {
        id: String,
        task_cancelled: bool,
    },
    Remove {
        id: String,
    },
    End {
        id: String,
    },
    #[serde(rename_all = "camelCase")]
    MachineRemoved {
        machine_id: String,
    },
    ByRow {
        row: String,
    },
    #[serde(rename_all = "camelCase")]
    Opens {
        #[serde(default)]
        workspace_id: Option<String>,
        #[serde(default)]
        shown: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    ShownIn {
        window_id: String,
    },
    #[serde(rename_all = "camelCase")]
    BootstrapStep {
        id: String,
        at: BootstrapAt,
        task_cancelled: bool,
        needs_script: bool,
        needs_machine_config: bool,
    },
}

#[derive(Deserialize)]
struct CreationsStep {
    #[serde(default)]
    creations: Creations,
    action: CreationsAction,
}

/// The answer of an action on the creations, before the state is added.
fn creations_step(creations: &mut Creations, action: CreationsAction) -> Result<Value, i32> {
    let missing = || json!({ "missing": true });
    Ok(match action {
        CreationsAction::Start { creation } => {
            json!({ "shown": flow::start(creations, *creation) })
        }
        CreationsAction::Apply { id, event } => match creations.creation_mut(&id) {
            Some(creation) => json!({ "effects": creation.apply(event) }),
            None => missing(),
        },
        CreationsAction::Retry { id, now_ms } => match creations.creation_mut(&id) {
            Some(creation) => json!({ "effects": flow::retry(creation, now_ms) }),
            None => missing(),
        },
        CreationsAction::Dismiss { id, shown } => {
            let (effects, clear) = flow::dismiss(creations, &id, shown.as_deref());
            json!({ "effects": effects, "clearWindow": clear })
        }
        CreationsAction::RunEnded { id, error, task_cancelled, started_by_person } => {
            match creations.creation_mut(&id) {
                Some(creation) => json!({
                    "runEnd": flow::run_ended(creation, error, task_cancelled, started_by_person)
                }),
                None => missing(),
            }
        }
        CreationsAction::LingerEnds { id, task_cancelled } => match creations.creation(&id) {
            Some(creation) => json!({ "ends": flow::linger_ends(creation, task_cancelled) }),
            None => json!({ "ends": false }),
        },
        CreationsAction::Remove { id } => json!({ "removed": creations.remove(&id) }),
        CreationsAction::End { id } => json!({ "effects": creations.end(&id) }),
        CreationsAction::MachineRemoved { machine_id } => {
            let ended: Vec<Value> = creations
                .machine_removed(&machine_id)
                .into_iter()
                .map(|(id, effects)| json!({ "id": id, "effects": effects }))
                .collect();
            json!({ "ended": ended })
        }
        CreationsAction::ByRow { row } => json!({ "creation": creations.by_row(&row) }),
        CreationsAction::Opens { workspace_id, shown } => {
            json!({ "opens": creations.opens(workspace_id.as_deref(), shown.as_deref()) })
        }
        CreationsAction::ShownIn { window_id } => {
            json!({ "shown": creations.shown_in(&window_id) })
        }
        CreationsAction::BootstrapStep {
            id,
            at,
            task_cancelled,
            needs_script,
            needs_machine_config,
        } => match creations.creation(&id) {
            Some(creation) => json!({
                "step": flow::bootstrap_step(creation, at, task_cancelled, needs_script, needs_machine_config)
            }),
            None => json!({ "step": flow::BootstrapStep::Stop }),
        },
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunPlan {
    has_session: bool,
    needs_bootstrap: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Scope {
    #[serde(default)]
    expected_user: Option<String>,
    #[serde(default)]
    current_user: Option<String>,
    #[serde(default)]
    expected_team: Option<String>,
    #[serde(default)]
    current_team: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
enum ContinuationAction {
    Reserve,
    Begin {
        expected: u64,
        #[serde(default)]
        cancelled: bool,
    },
    Finish {
        expected: u64,
        succeeded: bool,
        #[serde(default)]
        cancelled: bool,
    },
    Cancel,
    #[serde(rename_all = "camelCase")]
    CancelExpected {
        expected: u64,
    },
    #[serde(rename_all = "camelCase")]
    ScopeChanged {
        survives: bool,
    },
}

#[derive(Deserialize)]
struct ContinuationStep {
    #[serde(default)]
    continuation: Continuation,
    action: ContinuationAction,
}

fn continuation_step(handoff: &mut Continuation, action: ContinuationAction) -> Value {
    match action {
        ContinuationAction::Reserve => json!({ "expected": handoff.reserve() }),
        ContinuationAction::Begin { expected, cancelled } => {
            json!({ "go": handoff.begin(expected, cancelled) })
        }
        ContinuationAction::Finish { expected, succeeded, cancelled } => {
            json!({ "signedIn": handoff.finish(expected, succeeded, cancelled) })
        }
        ContinuationAction::Cancel => {
            handoff.cancel();
            json!({})
        }
        ContinuationAction::CancelExpected { expected } => {
            handoff.cancel_expected(expected);
            json!({})
        }
        ContinuationAction::ScopeChanged { survives } => {
            handoff.scope_changed(survives);
            json!({})
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
enum FrontedAction {
    Hold { workspace: String },
    Front { mac: Tab, front: Front },
    Gone { tab: Tab },
    FrontOf { mac: Tab },
    MacShowing { cloud: Tab },
    MacShowingWorkspace { workspace: String },
    Restore { entries: Vec<Entry> },
    Read,
}

#[derive(Deserialize)]
struct FrontedStep {
    #[serde(default)]
    fronted: Fronted,
    action: FrontedAction,
}

fn fronted_step(fronts: &mut Fronted, action: FrontedAction) -> Value {
    match action {
        FrontedAction::Hold { workspace } => {
            fronts.hold(workspace);
            json!({})
        }
        FrontedAction::Front { mac, front } => {
            fronts.front(mac, front);
            json!({})
        }
        FrontedAction::Gone { tab } => json!({ "gone": fronts.gone(&tab) }),
        FrontedAction::FrontOf { mac } => json!({ "front": fronts.front_of(&mac) }),
        FrontedAction::MacShowing { cloud } => json!({ "mac": fronts.mac_showing(&cloud) }),
        FrontedAction::MacShowingWorkspace { workspace } => {
            json!({ "mac": fronts.mac_showing_workspace(&workspace) })
        }
        FrontedAction::Restore { entries } => {
            fronts.restore(entries);
            json!({})
        }
        FrontedAction::Read => json!({}),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
enum RevokesAction {
    Add {
        chat: Chat,
    },
    AnswerStarted {
        chat: Chat,
    },
    AnswerEnded {
        chat: Chat,
        live: bool,
    },
    #[serde(rename_all = "camelCase")]
    MayRun {
        chat: Chat,
        now_ms: u64,
    },
    #[serde(rename_all = "camelCase")]
    Due {
        now_ms: u64,
    },
    RunStarted {
        chat: Chat,
    },
    #[serde(rename_all = "camelCase")]
    RunEnded {
        chat: Chat,
        ok: bool,
        now_ms: u64,
        #[serde(default = "first_revoke_backoff")]
        first_backoff_ms: u64,
    },
}

fn first_revoke_backoff() -> u64 {
    access::REVOKE_FIRST_BACKOFF_MS
}

#[derive(Deserialize)]
struct RevokesStep {
    #[serde(default)]
    revokes: Revokes,
    action: RevokesAction,
}

fn revokes_step(revokes: &mut Revokes, action: RevokesAction) -> Value {
    match action {
        RevokesAction::Add { chat } => revokes.add(chat),
        RevokesAction::AnswerStarted { chat } => revokes.answer_started(chat),
        RevokesAction::AnswerEnded { chat, live } => revokes.answer_ended(chat, live),
        RevokesAction::MayRun { chat, now_ms } => {
            return json!({ "mayRun": revokes.may_run(&chat, now_ms) });
        }
        RevokesAction::Due { now_ms } => return json!({ "due": revokes.due(now_ms) }),
        RevokesAction::RunStarted { chat } => revokes.run_started(chat),
        RevokesAction::RunEnded { chat, ok, now_ms, first_backoff_ms } => {
            revokes.run_ended(chat, ok, now_ms, first_backoff_ms);
        }
    }
    json!({})
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
enum AsksAction {
    BeginTriage,
    #[serde(rename_all = "camelCase")]
    Machine {
        machine_id: String,
        now_ms: u64,
        sync_ms: u64,
    },
    #[serde(rename_all = "camelCase")]
    TriageFailed {
        machine_id: String,
        #[serde(default)]
        code: Option<String>,
        now_ms: u64,
        poll_ms: u64,
    },
    #[serde(rename_all = "camelCase")]
    TriageOk {
        machine_id: String,
    },
    Listed {
        triage: u64,
        listed: BTreeMap<String, Vec<String>>,
    },
    AnswerStarted {
        id: String,
    },
    AnswerEnded {
        id: String,
    },
    Cards {
        listed: Vec<Listed>,
        #[serde(default)]
        failures: Vec<String>,
    },
}

#[derive(Deserialize)]
struct AsksStep {
    #[serde(default)]
    asks: Asks,
    action: AsksAction,
}

fn asks_step(asks: &mut Asks, action: AsksAction) -> Value {
    match action {
        AsksAction::BeginTriage => json!({ "triage": asks.begin_triage() }),
        AsksAction::Machine { machine_id, now_ms, sync_ms } => {
            json!({ "machine": asks.machine(&machine_id, now_ms, sync_ms) })
        }
        AsksAction::TriageFailed { machine_id, code, now_ms, poll_ms } => {
            json!({ "delayMs": asks.triage_failed(&machine_id, code.as_deref(), now_ms, poll_ms) })
        }
        AsksAction::TriageOk { machine_id } => {
            asks.triage_ok(&machine_id);
            json!({})
        }
        AsksAction::Listed { triage, listed } => json!({ "listed": asks.listed(triage, listed) }),
        AsksAction::AnswerStarted { id } => {
            asks.answer_started(id);
            json!({})
        }
        AsksAction::AnswerEnded { id } => {
            asks.answer_ended(&id);
            json!({})
        }
        AsksAction::Cards { listed, failures } => {
            json!({ "cards": access::cards(asks, &listed, &failures) })
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PollRound {
    has_cli: bool,
    moved_chats: usize,
    #[serde(default)]
    cloud_disabled: bool,
    revokes_empty: bool,
    poll_ms: u64,
}

#[derive(Deserialize)]
struct AnswerFailure {
    ok: bool,
    #[serde(default)]
    code: Option<String>,
}

/// `answer` with `key: state` added (each stateful op answers its next state beside its answer).
fn with_state<T: serde::Serialize>(mut answer: Value, key: &str, state: &T) -> Result<Value, i32> {
    let Value::Object(fields) = &mut answer else { return Err(ERR_INVALID) };
    fields.insert(key.to_owned(), value(state)?);
    Ok(answer)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // A creation as it starts (listed at once, before any request goes out).
        b"cloud_state_creation_new" => {
            let new: New = read(request)?;
            json!({ "creation": Creation::new(new.id, new.window_id, new.machine_id, new.now_ms) })
        }
        // One event of one creation the app holds alone: its next state and the effects to run.
        b"cloud_state_creation_apply" => {
            let Apply { mut creation, event } = read(request)?;
            let effects = creation.apply(event);
            json!({ "creation": creation, "effects": effects })
        }
        // A bootstrap's end, from its status file's run.
        b"cloud_state_completion" => {
            let finished: Finished = read(request)?;
            json!({ "completion": creation::completion(&finished.run) })
        }
        // The paid plan a refusal offers, if any.
        b"cloud_state_pro_refusal" => {
            let refused: Refused = read(request)?;
            json!({ "refusal": creation::pro_refusal(&refused.source) })
        }
        // One action on the creations in flight: its answer and the next creations.
        b"cloud_state_creations" => {
            let CreationsStep { mut creations, action } = read(request)?;
            let answer = creations_step(&mut creations, action)?;
            with_state(answer, "creations", &creations)?
        }
        b"cloud_state_run_plan" => {
            let plan: RunPlan = read(request)?;
            value(flow::run_plan(plan.has_session, plan.needs_bootstrap))?
        }
        b"cloud_state_scope_holds" => {
            let scope: Scope = read(request)?;
            json!({ "holds": flow::scope_holds(
                scope.expected_user.as_deref(),
                scope.current_user.as_deref(),
                scope.expected_team.as_deref(),
                scope.current_team.as_deref(),
            ) })
        }
        b"cloud_state_continuation" => {
            let ContinuationStep { mut continuation, action } = read(request)?;
            let answer = continuation_step(&mut continuation, action);
            let pending = continuation.is_pending();
            let answer = with_state(answer, "continuation", &continuation)?;
            with_state(answer, "pending", &pending)?
        }
        // One action on the fronted chats: its answer, the next state, and what the defaults key
        // keeps (null: the key goes).
        b"cloud_state_fronted" => {
            let FrontedStep { mut fronted, action } = read(request)?;
            let answer = fronted_step(&mut fronted, action);
            let answer = with_state(answer, "persisted", &fronted.persisted())?;
            let answer = with_state(answer, "workspaceIds", &fronted.workspace_ids())?;
            with_state(answer, "fronted", &fronted)?
        }
        b"cloud_state_revokes" => {
            let RevokesStep { mut revokes, action } = read(request)?;
            let answer = revokes_step(&mut revokes, action);
            let empty = revokes.is_empty();
            let answer = with_state(answer, "empty", &empty)?;
            with_state(answer, "revokes", &revokes)?
        }
        b"cloud_state_asks" => {
            let AsksStep { mut asks, action } = read(request)?;
            let answer = asks_step(&mut asks, action);
            with_state(answer, "asks", &asks)?
        }
        b"cloud_state_poll" => {
            let round: PollRound = read(request)?;
            value(access::poll(
                round.has_cli,
                round.moved_chats,
                round.cloud_disabled,
                round.revokes_empty,
                round.poll_ms,
            ))?
        }
        b"cloud_state_answer_failure_shows" => {
            let failure: AnswerFailure = read(request)?;
            json!({ "shows": access::answer_failure_shows(failure.ok, failure.code.as_deref()) })
        }
        // The constants the app's views and timers read.
        b"cloud_state_constants" => json!({
            "rowPrefix": creation::ROW_PREFIX,
            "failedRowLingersMs": flow::FAILED_ROW_LINGERS_MS,
            "frontedDefaultsKey": fronted::DEFAULTS_KEY,
            "revokeFirstBackoffMs": access::REVOKE_FIRST_BACKOFF_MS,
            "revokeLongestBackoffMs": access::REVOKE_LONGEST_BACKOFF_MS,
            "triageLongestBackoffMs": access::TRIAGE_LONGEST_BACKOFF_MS,
            "triageUnavailableBackoffMs": access::TRIAGE_UNAVAILABLE_BACKOFF_MS,
            "unavailableCode": access::UNAVAILABLE_CODE,
            "maximumShown": access::MAXIMUM_SHOWN,
        }),
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
