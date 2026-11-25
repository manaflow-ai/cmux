//! Agent runs on the local conversation owner (`conversation-runs-v1`): the
//! trajectory of one agent turn (its tool calls with inputs and outputs, its
//! reply segments, the files it changed, its pictures and recordings) as the
//! conversation shows it to its participants.
//!
//! The agent that works is the only writer (`conversation-run-append`, a
//! bound agent connection); the record lives beside the reducer head like
//! the per-person inbox state: no `rev` of the conversation, no
//! `conversation-changed`, no corpus case, no message. A run's `turn` is the
//! `client_msg_id` of the reply it ends with, so a page shows the run on that
//! reply. Values are absolute (a run's fields and each step are replaced by
//! id), so a retried append writes the same rows.

use std::collections::BTreeSet;

use cmux_conversation::{Part, ParticipantKind, Reject, valid_attachment_part};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{ConversationStore, attachments, load_head, rejected, to_i64};
use cmux_json::JsonSet as _;

/// Kept in the schema batch: `CREATE TABLE IF NOT EXISTS` needs no version
/// bump, and an older daemon ignores the tables.
pub(super) const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS conversation_run (
       conversation TEXT NOT NULL,
       run TEXT NOT NULL,
       author TEXT NOT NULL,
       turn TEXT,
       started_at INTEGER NOT NULL,
       rev INTEGER NOT NULL CHECK(rev >= 1),
       step_count INTEGER NOT NULL CHECK(step_count >= 0),
       run_json TEXT NOT NULL,
       PRIMARY KEY(conversation, run)
     ) WITHOUT ROWID;
     CREATE INDEX IF NOT EXISTS conversation_run_by_start
       ON conversation_run(conversation, started_at DESC, run DESC);
     CREATE INDEX IF NOT EXISTS conversation_run_by_turn
       ON conversation_run(conversation, turn);
     CREATE TABLE IF NOT EXISTS conversation_run_step (
       conversation TEXT NOT NULL,
       run TEXT NOT NULL,
       step TEXT NOT NULL,
       seq INTEGER NOT NULL CHECK(seq >= 1),
       rev INTEGER NOT NULL CHECK(rev >= 1),
       step_json TEXT NOT NULL,
       PRIMARY KEY(conversation, run, step)
     ) WITHOUT ROWID;
     CREATE INDEX IF NOT EXISTS conversation_run_step_by_rev
       ON conversation_run_step(conversation, run, rev);";

/// A running run written longer ago than this is stale (no work shows).
pub(crate) const STALE_RUN_MS: u64 = 30 * 60_000;
/// Runs started longer ago than this are not read for the Home rows.
const RUNNING_WINDOW_MS: u64 = 24 * 60 * 60_000;

/// Most steps one run keeps.
pub(crate) const MAX_RUN_STEPS: u64 = 2000;
/// Most steps in one append.
pub(crate) const MAX_APPEND_STEPS: usize = 64;
/// Most bytes of all steps of one append, as JSON.
pub(crate) const MAX_APPEND_BYTES: usize = 1024 * 1024;
/// Most bytes of a step's text, of a tool's output, and of a step's file texts together (each
/// of the three on its own).
pub(crate) const MAX_STEP_TEXT_BYTES: usize = 32 * 1024;
/// Most runs one conversation keeps: a new run past it drops the oldest finished ones.
pub(crate) const MAX_CONVERSATION_RUNS: u64 = 200;
/// Most bytes of a tool's input, as JSON.
pub(crate) const MAX_TOOL_INPUT_BYTES: usize = 16 * 1024;
/// Largest page of `conversation-run` steps and of `conversation-runs`.
pub(crate) const MAX_RUN_PAGE: u32 = 500;
pub(crate) const MAX_RUNS_PAGE: u32 = 200;

/// A run command the owner refused. The control socket reports it with
/// `error_code` [`RunRejected::CODE`] and the reason as the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunRejected(pub &'static str);

impl RunRejected {
    pub const CODE: &'static str = "run_rejected";
}

impl std::fmt::Display for RunRejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for RunRejected {}

fn refused(reason: &'static str) -> anyhow::Error {
    RunRejected(reason).into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RunStatus {
    Running,
    Done,
    Failed,
    Cancelled,
}

impl RunStatus {
    fn terminal(self) -> bool {
        !matches!(self, Self::Running)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum StepStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum StepKind {
    Talk,
    Thought,
    Tool,
    Note,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Usage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<u64>,
}

/// The agent session a run ran in (`acpmux`, `pi`, ...), so a page can link
/// to its full log while it lives.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SessionLink {
    pub kind: String,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

/// `conversation-run-append` `run`: the run's id and the summary fields this
/// append sets (an absent field keeps its value).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RunInput {
    pub id: String,
    #[serde(default)]
    pub turn: Option<String>,
    #[serde(default)]
    pub answers: Option<Vec<String>>,
    #[serde(default)]
    pub thread_root: Option<String>,
    #[serde(default)]
    pub status: Option<RunStatus>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub started_at: Option<u64>,
    #[serde(default)]
    pub usage: Option<Usage>,
    #[serde(default)]
    pub cost_usd: Option<f64>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub session: Option<SessionLink>,
    #[serde(default)]
    pub workspace: Option<String>,
}

/// The stored run, as every read and event shows it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Run {
    pub id: String,
    pub conversation: String,
    pub author: String,
    pub status: RunStatus,
    pub started_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<u64>,
    pub updated_at: u64,
    /// Increases by one for every step written and for every summary change.
    pub rev: u64,
    pub step_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answers: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Usage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionLink>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct FileChange {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Tool {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_truncated: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<FileChange>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Link {
    pub label: String,
    pub url: String,
}

/// One step as the agent writes it (the owner adds `seq`, `at` and `rev`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct StepInput {
    pub id: String,
    pub kind: StepKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<StepStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<Tool>,
    /// Attachment records of this conversation (the `attachment` part's
    /// fields without `type`): the step's pictures and recordings.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Map<String, Value>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<Link>,
}

/// What an append committed: the run after it and the steps it wrote (each
/// with its `seq`, `at` and `rev`).
#[derive(Debug, Clone)]
pub(crate) struct Appended {
    pub run: Run,
    pub steps: Vec<Value>,
}

/// One page of `conversation-run`.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct RunPage {
    pub run: Run,
    pub steps: Vec<Value>,
    pub has_more: bool,
}

/// A producer key: 1-128 of `[A-Za-z0-9_.:-]` (a turn key, a step id).
pub(crate) fn valid_key(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// One line of text: no control characters, at most `max` characters.
fn valid_line(value: &str, max: usize) -> bool {
    value.chars().count() <= max && !value.chars().any(char::is_control)
}

/// A link a page may open: http(s), or a cmux scheme (`cmux`, `cmux-<tag>`).
fn valid_url(url: &str) -> bool {
    if url.len() > 2048 || url.chars().any(|c| c.is_control() || c == ' ') {
        return false;
    }
    let Some((scheme, rest)) = url.split_once("://") else { return false };
    let cmux = scheme == "cmux"
        || scheme.strip_prefix("cmux-").is_some_and(|tag| {
            !tag.is_empty()
                && tag.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        });
    (scheme == "https" || scheme == "http" || cmux) && !rest.is_empty()
}

fn invalid(ok: bool) -> anyhow::Result<()> {
    if ok { Ok(()) } else { Err(refused("invalid_run")) }
}

fn validate_run(input: &RunInput) -> anyhow::Result<()> {
    invalid(valid_key(&input.id))?;
    invalid(input.turn.as_deref().is_none_or(valid_key))?;
    invalid(
        input
            .answers
            .as_ref()
            .is_none_or(|answers| answers.len() <= 16 && answers.iter().all(|id| valid_key(id))),
    )?;
    invalid(input.thread_root.as_deref().is_none_or(valid_key))?;
    invalid(input.title.as_deref().is_none_or(|title| valid_line(title, 200)))?;
    invalid(input.model.as_deref().is_none_or(|model| valid_line(model, 128)))?;
    invalid(input.harness.as_deref().is_none_or(|harness| valid_line(harness, 64)))?;
    invalid(input.workspace.as_deref().is_none_or(|workspace| valid_line(workspace, 128)))?;
    invalid(input.error.as_deref().is_none_or(|error| error.chars().count() <= 2000))?;
    invalid(input.cost_usd.is_none_or(|cost| cost.is_finite() && cost >= 0.0))?;
    invalid(input.session.as_ref().is_none_or(|session| {
        valid_line(&session.kind, 32)
            && !session.kind.is_empty()
            && valid_line(&session.id, 256)
            && !session.id.is_empty()
            && session.host.as_deref().is_none_or(|host| valid_line(host, 256))
    }))
}

fn validate_step(step: &StepInput) -> anyhow::Result<()> {
    invalid(valid_key(&step.id))?;
    invalid(step.text.as_deref().is_none_or(|text| text.len() <= MAX_STEP_TEXT_BYTES))?;
    invalid(step.links.len() <= 16)?;
    for link in &step.links {
        invalid(valid_line(&link.label, 200) && valid_url(&link.url))?;
    }
    invalid(step.attachments.len() <= 16)?;
    if let Some(tool) = &step.tool {
        invalid(valid_line(&tool.name, 128) && !tool.name.is_empty())?;
        invalid(tool.kind.as_deref().is_none_or(|kind| valid_line(kind, 32)))?;
        invalid(tool.title.as_deref().is_none_or(|title| title.chars().count() <= 2000))?;
        invalid(tool.output.as_deref().is_none_or(|output| output.len() <= MAX_STEP_TEXT_BYTES))?;
        if let Some(input) = &tool.input {
            invalid(serde_json::to_string(input)?.len() <= MAX_TOOL_INPUT_BYTES)?;
        }
        invalid(tool.files.len() <= 64)?;
        let mut file_bytes = 0;
        for file in &tool.files {
            invalid(valid_line(&file.path, 4096) && !file.path.is_empty())?;
            file_bytes += file.old_text.as_deref().map_or(0, str::len)
                + file.new_text.as_deref().map_or(0, str::len);
        }
        invalid(file_bytes <= MAX_STEP_TEXT_BYTES)?;
    }
    Ok(())
}

/// The step's attachments as `attachment` parts, each checked like a message part's.
fn attachment_parts(step: &StepInput) -> anyhow::Result<Vec<Part>> {
    step.attachments
        .iter()
        .map(|fields| {
            let mut value = Value::Object(fields.clone());
            value.set("type", json!("attachment"));
            let part: Part = serde_json::from_value(value).map_err(|_| refused("invalid_run"))?;
            invalid(matches!(part, Part::Attachment { .. }) && valid_attachment_part(&part))?;
            Ok(part)
        })
        .collect()
}

/// The `attachment_ref` key of a step, so a referenced record stays usable
/// and readable like one a message names. The run id's length keeps two
/// (run, step) pairs from sharing a key (both may contain `:`).
fn step_ref(run: &str, step: &str) -> String {
    format!("run:{}:{run}:{step}", run.len())
}

/// The `attachment_ref` keys of every step of a run start with this.
fn run_ref_prefix(run: &str) -> String {
    format!("run:{}:{run}:", run.len())
}

impl ConversationStore {
    /// Applies one append of `actor`'s run: the summary fields it names and
    /// each step by id. The actor must be an agent participant and the run
    /// its own.
    pub(crate) fn append_run(
        &mut self,
        conversation: &str,
        actor: &str,
        input: &RunInput,
        steps: &[StepInput],
    ) -> anyhow::Result<Appended> {
        validate_run(input)?;
        invalid(steps.len() <= MAX_APPEND_STEPS)?;
        let mut bytes = 0;
        for (index, step) in steps.iter().enumerate() {
            validate_step(step)?;
            invalid(!steps[..index].iter().any(|other| other.id == step.id))?;
            bytes += serde_json::to_string(step)?.len();
        }
        invalid(bytes <= MAX_APPEND_BYTES)?;
        let now = crate::workspace_registry::unix_epoch_ms()?;
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let head = load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let participant =
            head.participant(actor).ok_or_else(|| rejected(Reject::NotParticipant))?;
        if participant.kind != ParticipantKind::Agent {
            return Err(refused("not_agent"));
        }
        let existing = load_run(&transaction, conversation, &input.id)?;
        if existing.is_none() {
            prune_runs(&transaction, conversation)?;
        }
        let mut run = match existing {
            Some(run) if run.author != actor => return Err(refused("not_run_author")),
            Some(run) => run,
            None => Run {
                id: input.id.clone(),
                conversation: conversation.to_owned(),
                author: actor.to_owned(),
                status: RunStatus::Running,
                started_at: input.started_at.unwrap_or(now),
                ended_at: None,
                updated_at: now,
                rev: 0,
                step_count: 0,
                turn: None,
                answers: Vec::new(),
                thread_root: None,
                title: None,
                usage: None,
                cost_usd: None,
                model: None,
                harness: None,
                error: None,
                session: None,
                workspace: None,
            },
        };
        let before = serde_json::to_value(&run)?;
        merge_summary(&mut run, input, now);
        let mut written = Vec::with_capacity(steps.len());
        for step in steps {
            let parts = attachment_parts(step)?;
            attachments::check_parts(&transaction, conversation, actor, &parts)?;
            let existing: Option<(i64, String)> = transaction
                .query_row(
                    "SELECT seq, step_json FROM conversation_run_step
                     WHERE conversation = ?1 AND run = ?2 AND step = ?3",
                    params![conversation, run.id, step.id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let (seq, at) = match existing {
                Some((seq, json)) => {
                    let at = serde_json::from_str::<Value>(&json)?
                        .get("at")
                        .and_then(Value::as_u64)
                        .unwrap_or(now);
                    (u64::try_from(seq)?, at)
                }
                None => {
                    if run.step_count >= MAX_RUN_STEPS {
                        return Err(refused("run_full"));
                    }
                    run.step_count += 1;
                    (run.step_count, now)
                }
            };
            run.rev += 1;
            let mut value = serde_json::to_value(step)?;
            value.set("seq", json!(seq));
            value.set("at", json!(at));
            value.set("rev", json!(run.rev));
            transaction.execute(
                "INSERT INTO conversation_run_step(conversation, run, step, seq, rev, step_json)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(conversation, run, step) DO UPDATE
                 SET rev = excluded.rev, step_json = excluded.step_json",
                params![
                    conversation,
                    run.id,
                    step.id,
                    to_i64(seq)?,
                    to_i64(run.rev)?,
                    serde_json::to_string(&value)?
                ],
            )?;
            attachments::write_refs(
                &transaction,
                conversation,
                &step_ref(&run.id, &step.id),
                &parts,
            )?;
            written.push(value);
        }
        // A summary change is a revision of its own; an append that changes
        // nothing still answers the run as it is.
        let mut probe = run.clone();
        probe.rev = 0;
        probe.updated_at = 0;
        probe.step_count = 0;
        let mut previous: Run = serde_json::from_value(before)?;
        previous.rev = 0;
        previous.updated_at = 0;
        previous.step_count = 0;
        if probe != previous || (written.is_empty() && run.rev == 0) {
            run.rev += 1;
        }
        run.updated_at = now;
        transaction.execute(
            "INSERT INTO conversation_run(conversation, run, author, turn, started_at, rev, step_count, run_json)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(conversation, run) DO UPDATE
             SET turn = excluded.turn, started_at = excluded.started_at, rev = excluded.rev,
                 step_count = excluded.step_count, run_json = excluded.run_json",
            params![
                conversation,
                run.id,
                run.author,
                run.turn,
                to_i64(run.started_at)?,
                to_i64(run.rev)?,
                to_i64(run.step_count)?,
                serde_json::to_string(&run)?
            ],
        )?;
        transaction.commit()?;
        Ok(Appended { run, steps: written })
    }

    /// The authors of runs that run now, by conversation, for the Home rows
    /// (`home-inbox`): status running, started in the last day and written in
    /// the last [`STALE_RUN_MS`] (the Channels page's stale rule: a run its
    /// brain stopped writing is not work).
    pub(crate) fn running_run_authors(
        &mut self,
        now_ms: u64,
    ) -> anyhow::Result<std::collections::HashMap<String, Vec<String>>> {
        let since = to_i64(now_ms.saturating_sub(RUNNING_WINDOW_MS))?;
        let mut statement = self.connection.prepare(
            "SELECT run_json FROM conversation_run
                 WHERE started_at >= ?1 AND json_extract(run_json, '$.status') = 'running'",
        )?;
        let mut authors: std::collections::HashMap<String, Vec<String>> =
            std::collections::HashMap::new();
        for json in statement.query_map(params![since], |row| row.get::<_, String>(0))? {
            let run: Run = serde_json::from_str(&json?)?;
            if run.status == RunStatus::Running
                && now_ms.saturating_sub(run.updated_at) <= STALE_RUN_MS
            {
                let list = authors.entry(run.conversation).or_default();
                if !list.contains(&run.author) {
                    list.push(run.author);
                }
            }
        }
        Ok(authors)
    }

    /// The newest runs of a conversation (before `before_started_at`), or the
    /// runs whose `turn` is one of `turns`. Timestamp pages include all ties
    /// at the limit so the next strict `before_started_at` cursor skips none.
    pub(crate) fn runs(
        &mut self,
        conversation: &str,
        turns: Option<&[String]>,
        answers: Option<&[String]>,
        before_started_at: Option<u64>,
        limit: u32,
    ) -> anyhow::Result<(Vec<Run>, bool)> {
        if load_head(&self.connection, conversation)?.is_none() {
            return Err(rejected(Reject::UnknownConversation));
        }
        if let Some(answers) = answers {
            let mut statement = self
                .connection
                .prepare("SELECT run_json FROM conversation_run WHERE conversation = ?1")?;
            let wanted: std::collections::HashSet<&str> =
                answers.iter().map(String::as_str).collect();
            let mut runs = Vec::new();
            for json in statement.query_map(params![conversation], |row| row.get::<_, String>(0))? {
                let run: Run = serde_json::from_str(&json?)?;
                if run.answers.iter().any(|answer| wanted.contains(answer.as_str())) {
                    runs.push(run);
                }
            }
            return Ok((runs, false));
        }
        if let Some(turns) = turns {
            let mut statement = self.connection.prepare(
                "SELECT run_json FROM conversation_run WHERE conversation = ?1 AND turn = ?2",
            )?;
            let mut runs = Vec::new();
            for turn in turns {
                for json in statement
                    .query_map(params![conversation, turn], |row| row.get::<_, String>(0))?
                {
                    runs.push(serde_json::from_str(&json?)?);
                }
            }
            return Ok((runs, false));
        }
        let before = before_started_at.map(to_i64).transpose()?.unwrap_or(i64::MAX);
        let mut statement = self.connection.prepare(
            "SELECT run_json FROM conversation_run WHERE conversation = ?1 AND started_at < ?2
             ORDER BY started_at DESC, run DESC",
        )?;
        let mut runs: Vec<Run> = Vec::new();
        for json in
            statement.query_map(params![conversation, before], |row| row.get::<_, String>(0))?
        {
            let run: Run = serde_json::from_str(&json?)?;
            if runs.len() >= limit as usize
                && runs.last().is_some_and(|last| last.started_at != run.started_at)
            {
                return Ok((runs, true));
            }
            runs.push(run);
        }
        Ok((runs, false))
    }

    /// One run and its steps written after `after_rev`, oldest write first.
    pub(crate) fn run_page(
        &mut self,
        conversation: &str,
        run: &str,
        after_rev: u64,
        limit: u32,
    ) -> anyhow::Result<RunPage> {
        if load_head(&self.connection, conversation)?.is_none() {
            return Err(rejected(Reject::UnknownConversation));
        }
        let stored =
            load_run(&self.connection, conversation, run)?.ok_or_else(|| refused("unknown_run"))?;
        let mut statement = self.connection.prepare(
            "SELECT step_json FROM conversation_run_step
             WHERE conversation = ?1 AND run = ?2 AND rev > ?3 ORDER BY rev LIMIT ?4",
        )?;
        let mut steps = statement
            .query_map(
                params![conversation, run, to_i64(after_rev)?, i64::from(limit) + 1],
                |row| row.get::<_, String>(0),
            )?
            .map(|json| Ok(serde_json::from_str(&json?)?))
            .collect::<anyhow::Result<Vec<Value>>>()?;
        let has_more = steps.len() > limit as usize;
        steps.truncate(limit as usize);
        Ok(RunPage { run: stored, steps, has_more })
    }
}

fn merge_summary(run: &mut Run, input: &RunInput, now: u64) {
    if let Some(turn) = &input.turn {
        run.turn = Some(turn.clone());
    }
    if let Some(answers) = &input.answers {
        run.answers = answers.clone();
    }
    if let Some(root) = &input.thread_root {
        run.thread_root = Some(root.clone());
    }
    if let Some(title) = &input.title {
        run.title = (!title.is_empty()).then(|| title.clone());
    }
    if let Some(started_at) = input.started_at {
        run.started_at = started_at;
    }
    if let Some(usage) = &input.usage {
        run.usage = Some(usage.clone());
    }
    if let Some(cost) = input.cost_usd {
        run.cost_usd = Some(cost);
    }
    if let Some(model) = &input.model {
        run.model = Some(model.clone());
    }
    if let Some(harness) = &input.harness {
        run.harness = Some(harness.clone());
    }
    if let Some(error) = &input.error {
        run.error = (!error.is_empty()).then(|| error.clone());
    }
    if let Some(session) = &input.session {
        run.session = Some(session.clone());
    }
    if let Some(workspace) = &input.workspace {
        run.workspace = Some(workspace.clone());
    }
    if let Some(status) = input.status {
        // The end is stamped once, when the run leaves `running`; a run that
        // goes back to `running` (a retry) is open again.
        match (run.status.terminal(), status.terminal()) {
            (false, true) => run.ended_at = Some(now),
            (_, false) => run.ended_at = None,
            (true, true) => {}
        }
        run.status = status;
    }
}

/// Before a new run: drops the oldest finished runs (their steps and attachment references) so
/// the conversation keeps at most [`MAX_CONVERSATION_RUNS`] with the new one.
fn prune_runs(connection: &Connection, conversation: &str) -> anyhow::Result<()> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM conversation_run WHERE conversation = ?1",
        params![conversation],
        |row| row.get(0),
    )?;
    let excess = u64::try_from(count)?.saturating_add(1).saturating_sub(MAX_CONVERSATION_RUNS);
    if excess == 0 {
        return Ok(());
    }
    let mut statement = connection.prepare(
        "SELECT run, run_json FROM conversation_run WHERE conversation = ?1
         ORDER BY started_at ASC, run ASC",
    )?;
    let oldest = statement
        .query_map(params![conversation], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut dropped = 0;
    for (id, json) in oldest {
        if dropped >= excess {
            break;
        }
        let run: Run = serde_json::from_str(&json)?;
        if !run.status.terminal() {
            continue;
        }
        connection.execute(
            "DELETE FROM conversation_run_step WHERE conversation = ?1 AND run = ?2",
            params![conversation, id],
        )?;
        connection.execute(
            "DELETE FROM attachment_ref WHERE conversation = ?1 AND substr(message_id, 1, ?2) = ?3",
            params![conversation, i64::try_from(run_ref_prefix(&id).len())?, run_ref_prefix(&id)],
        )?;
        connection.execute(
            "DELETE FROM conversation_run WHERE conversation = ?1 AND run = ?2",
            params![conversation, id],
        )?;
        dropped += 1;
    }
    Ok(())
}

impl ConversationStore {
    /// The run a live frame names (`chief-live-v1`): `actor`, an agent
    /// participant, must be its author and the run still running.
    pub(crate) fn live_run(
        &self,
        conversation: &str,
        actor: &str,
        run: &str,
    ) -> anyhow::Result<()> {
        let head = load_head(&self.connection, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let participant =
            head.participant(actor).ok_or_else(|| rejected(Reject::NotParticipant))?;
        if participant.kind != ParticipantKind::Agent {
            return Err(refused("not_agent"));
        }
        let run =
            load_run(&self.connection, conversation, run)?.ok_or_else(|| refused("unknown_run"))?;
        if run.author != actor {
            return Err(refused("not_run_author"));
        }
        if run.status != RunStatus::Running {
            return Err(refused("run_not_running"));
        }
        Ok(())
    }

    /// Which of `runs` are running now (a live snapshot keeps only those).
    pub(crate) fn running_of(
        &self,
        conversation: &str,
        runs: &[String],
    ) -> anyhow::Result<BTreeSet<String>> {
        let mut running = BTreeSet::new();
        for id in runs {
            if load_run(&self.connection, conversation, id)?
                .is_some_and(|run| run.status == RunStatus::Running)
            {
                running.insert(id.clone());
            }
        }
        Ok(running)
    }
}

fn load_run(connection: &Connection, conversation: &str, run: &str) -> anyhow::Result<Option<Run>> {
    let json: Option<String> = connection
        .query_row(
            "SELECT run_json FROM conversation_run WHERE conversation = ?1 AND run = ?2",
            params![conversation, run],
            |row| row.get(0),
        )
        .optional()?;
    json.map(|json| Ok(serde_json::from_str(&json)?)).transpose()
}
