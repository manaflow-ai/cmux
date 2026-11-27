//! Raw protocol handlers for agent runs on the local conversation owner
//! (`conversation-runs-v1`, conversation_runs.rs): an agent writes the
//! trajectory of its turn, every trusted local connection (Unix or an
//! authenticated page) reads it, and `subscribe` streams each append to the
//! connections that asked for runs.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::conversations::decode;
use super::{Mux, MuxEvent};
use crate::conversation_store::ConversationEvent;
use crate::conversation_store::runs::{
    MAX_RUN_PAGE, MAX_RUNS_PAGE, RunInput, RunStatus, StepInput, valid_key,
};

/// `conversation-run-append`, `conversation-runs`, `conversation-run` and the
/// `conversation-run-changed` event on `subscribe` for a connection that
/// echoes this capability in `set-client-info`.
pub const CONVERSATION_RUNS_CAPABILITY: &str = "conversation-runs-v1";
/// Exact answer-ID lookup for silent runs whose start predates the visible message window.
pub const CONVERSATION_RUN_ANSWERS_CAPABILITY: &str = "conversation-run-answers-v1";

/// `conversation-run-append`: the bound agent's own run (`run.id` and the
/// summary fields it sets) and up to 64 steps, each replaced by id.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AppendParams {
    conversation: String,
    run: Value,
    #[serde(default)]
    steps: Vec<Value>,
}

/// `conversation-runs`: the newest runs (`limit` 1-200, default 50, below
/// `before_started_at`), or the runs of the given reply keys (`turns`, at
/// most 200).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunsParams {
    conversation: String,
    #[serde(default)]
    turns: Option<Vec<String>>,
    #[serde(default)]
    answers: Option<Vec<String>>,
    #[serde(default)]
    before_started_at: Option<u64>,
    #[serde(default)]
    limit: Option<u32>,
}

/// `conversation-run`: one run and its steps written after `after_rev`
/// (default 0: every step), oldest write first, `limit` 1-500 (default 500).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunParams {
    conversation: String,
    run: String,
    #[serde(default)]
    after_rev: u64,
    #[serde(default)]
    limit: Option<u32>,
}

fn require_local(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_owner_client(client) && !mux.is_remote_client(client),
        "conversation runs require a trusted local connection"
    );
    Ok(())
}

/// The agent writes its run; the owner stamps the author (the connection's
/// principal, an agent participant) and publishes `conversation-run-changed`.
pub(super) fn append(mux: &Mux, client: u64, params: AppendParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let AppendParams { conversation, run, steps } = params;
    let input: RunInput = decode(run, "run")?;
    let steps = steps
        .into_iter()
        .enumerate()
        .map(|(index, step)| decode::<StepInput>(step, &format!("steps[{index}]")))
        .collect::<anyhow::Result<Vec<_>>>()?;
    let actor = mux.conversation_principal(client);
    let appended = mux.conversation_write(
        |store| store.append_run(&conversation, &actor, &input, &steps),
        |appended| {
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Run {
                conversation: conversation.clone(),
                run: serde_json::to_value(&appended.run).ok()?,
                steps: appended.steps.clone(),
            })))
        },
    )?;
    // The run ended: its live text (`chief-live-v1`) goes; a talk or thought
    // step's row frees that step's ended stream.
    let rows: Vec<String> = appended
        .steps
        .iter()
        .filter(|step| matches!(step["kind"].as_str(), Some("talk" | "thought")))
        .filter_map(|step| step["id"].as_str().map(str::to_owned))
        .collect();
    mux.conversation_live_rows(
        &conversation,
        &appended.run.id,
        appended.run.status != RunStatus::Running,
        &rows,
    );
    Ok(json!({"run": appended.run, "steps": appended.steps}))
}

pub(super) fn runs(mux: &Mux, client: u64, params: RunsParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let RunsParams { conversation, turns, answers, before_started_at, limit } = params;
    let limit = limit.unwrap_or(50);
    anyhow::ensure!(
        (1..=MAX_RUNS_PAGE).contains(&limit),
        "bad request: limit must be 1-{MAX_RUNS_PAGE}"
    );
    if let Some(turns) = &turns {
        anyhow::ensure!(
            turns.len() <= MAX_RUNS_PAGE as usize && turns.iter().all(|turn| valid_key(turn)),
            "bad request: turns must be at most {MAX_RUNS_PAGE} keys"
        );
    }
    if let Some(answers) = &answers {
        anyhow::ensure!(
            answers.len() <= MAX_RUNS_PAGE as usize
                && answers.iter().all(|answer| !answer.is_empty() && answer.len() <= 128),
            "bad request: answers must be at most {MAX_RUNS_PAGE} keys"
        );
    }
    let (runs, has_more) = mux.with_conversations(|store| {
        store.runs(&conversation, turns.as_deref(), answers.as_deref(), before_started_at, limit)
    })?;
    Ok(json!({"runs": runs, "has_more": has_more}))
}

pub(super) fn run(mux: &Mux, client: u64, params: RunParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let RunParams { conversation, run, after_rev, limit } = params;
    let limit = limit.unwrap_or(MAX_RUN_PAGE);
    anyhow::ensure!(
        (1..=MAX_RUN_PAGE).contains(&limit),
        "bad request: limit must be 1-{MAX_RUN_PAGE}"
    );
    let page =
        mux.with_conversations(|store| store.run_page(&conversation, &run, after_rev, limit))?;
    Ok(serde_json::to_value(page)?)
}
