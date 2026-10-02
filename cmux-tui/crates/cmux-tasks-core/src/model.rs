//! Entities of one team's Tasks state. Deterministic containers only
//! (`BTreeMap`/`BTreeSet`), so a fold of the op log always yields the same
//! bytes when serialized.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};

use crate::ids::{AgentRef, Principal};
use crate::reduce::OpResult;

/// Workflow status categories. The rank orders them for the agent flow
/// (an automatic move never lowers the rank).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    Triage,
    Backlog,
    Unstarted,
    Started,
    Completed,
    Canceled,
}

impl Category {
    pub const ALL: [Category; 6] = [
        Self::Triage,
        Self::Backlog,
        Self::Unstarted,
        Self::Started,
        Self::Completed,
        Self::Canceled,
    ];

    /// Categories every team must keep at least one status in.
    pub const REQUIRED: [Category; 5] =
        [Self::Backlog, Self::Unstarted, Self::Started, Self::Completed, Self::Canceled];

    pub fn rank(self) -> u8 {
        match self {
            Self::Triage => 0,
            Self::Backlog => 1,
            Self::Unstarted => 2,
            Self::Started => 3,
            Self::Completed | Self::Canceled => 4,
        }
    }

    pub fn is_open(self) -> bool {
        self.rank() < 4
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.as_str() == text)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Triage => "triage",
            Self::Backlog => "backlog",
            Self::Unstarted => "unstarted",
            Self::Started => "started",
            Self::Completed => "completed",
            Self::Canceled => "canceled",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    #[default]
    None,
    Urgent,
    High,
    Medium,
    Low,
}

/// Ghostty palette index 0..=15; clients render it from the terminal theme.
pub type GhosttyColor = u8;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub id: String,
    pub name: String,
    pub category: Category,
    pub position: i64,
    pub color: GhosttyColor,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectState {
    Planned,
    Active,
    Paused,
    Completed,
    Canceled,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub state: ProjectState,
    pub lead: Option<Principal>,
    pub archived: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Label {
    pub id: String,
    pub name: String,
    pub color: GhosttyColor,
    pub archived: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Description {
    pub text: String,
    pub version: u64,
}

/// Why a task needs a person's attention (the inbox).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Attention {
    NeedsInput,
    Failed,
    Review,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub number: u64,
    pub title: String,
    pub description: Description,
    pub status: String,
    pub priority: Priority,
    /// The accountable principal (usually a person).
    pub assignee: Option<Principal>,
    /// The agent doing the work, when delegated.
    pub delegate: Option<AgentRef>,
    pub labels: BTreeSet<String>,
    pub project: Option<String>,
    pub parent: Option<String>,
    pub estimate: Option<u32>,
    /// `YYYY-MM-DD`.
    pub due: Option<String>,
    pub sort_key: String,
    pub attention: Option<Attention>,
    pub created_by: Principal,
    pub created_at: i64,
    pub updated_at: i64,
    pub started_at: Option<i64>,
    pub completed_at: Option<i64>,
    pub canceled_at: Option<i64>,
    /// Last explicit status change (any actor); the agent flow never
    /// overrides a change made after its session was created.
    pub manual_status_at: Option<i64>,
    pub archived: bool,
    pub deleted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelationKind {
    Blocks,
    Related,
    Duplicate,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Relation {
    pub id: String,
    pub kind: RelationKind,
    pub from: String,
    pub to: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub id: String,
    pub task: String,
    pub reply_to: Option<String>,
    pub author: Principal,
    pub body: String,
    pub version: u64,
    pub created_at: i64,
    pub edited_at: Option<i64>,
    pub deleted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Pending,
    Claimed,
    Working,
    AwaitingInput,
    Done,
    Failed,
    Canceled,
}

impl SessionStatus {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Done | Self::Failed | Self::Canceled)
    }

    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "pending" => Self::Pending,
            "claimed" => Self::Claimed,
            "working" => Self::Working,
            "awaiting_input" | "awaiting-input" => Self::AwaitingInput,
            "done" => Self::Done,
            "failed" => Self::Failed,
            "canceled" => Self::Canceled,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub content: String,
    pub status: PlanStepStatus,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionLinks {
    pub acp_session: Option<String>,
    pub workspace: Option<String>,
    pub host: Option<String>,
    pub vm: Option<String>,
    pub pr: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentSession {
    pub id: String,
    pub task: String,
    pub agent: AgentRef,
    pub status: SessionStatus,
    /// `local`, `vm` or `host:<id>`: where the dispatcher should run it.
    pub target: String,
    pub prompt: Option<String>,
    pub claimed_by: Option<String>,
    pub plan: Vec<PlanStep>,
    pub links: SessionLinks,
    pub created_by: Principal,
    pub created_at: i64,
    pub started_at: Option<i64>,
    pub ended_at: Option<i64>,
}

/// How task status follows agent activity (team setting).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentFlow {
    /// working -> default started status; done -> review status; never completes.
    #[default]
    Forward,
    Off,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamSettings {
    pub team: String,
    pub key_prefix: String,
    pub next_number: u64,
    pub default_status: String,
    pub started_status: String,
    pub review_status: Option<String>,
    pub agent_flow: AgentFlow,
}

/// One committed idempotency record (retained 7 days).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub fingerprint: String,
    pub result: OpResult,
    pub seq: u64,
    pub at: i64,
}

pub const LEDGER_RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// A team's whole Tasks state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    pub settings: TeamSettings,
    pub statuses: BTreeMap<String, Status>,
    pub labels: BTreeMap<String, Label>,
    pub projects: BTreeMap<String, Project>,
    pub tasks: BTreeMap<String, Task>,
    pub relations: BTreeMap<String, Relation>,
    pub comments: BTreeMap<String, Comment>,
    pub sessions: BTreeMap<String, AgentSession>,
    /// Last committed log sequence.
    pub seq: u64,
    /// `ledger_key(actor, key)` -> committed result.
    pub ledger: BTreeMap<String, LedgerEntry>,
    /// Ledger keys in commit order, for retention pruning.
    pub ledger_order: VecDeque<String>,
}

pub fn ledger_key(actor: &str, key: &str) -> String {
    format!("{actor}\u{1f}{key}")
}

impl State {
    /// A new team with the default workflow (Triage, Backlog, Todo, In
    /// Progress, In Review, Done, Canceled).
    pub fn new(team: &str, key_prefix: &str) -> Self {
        let defaults: [(&str, &str, Category, GhosttyColor); 7] = [
            ("st_triage", "Triage", Category::Triage, 13),
            ("st_backlog", "Backlog", Category::Backlog, 8),
            ("st_todo", "Todo", Category::Unstarted, 7),
            ("st_in_progress", "In Progress", Category::Started, 3),
            ("st_in_review", "In Review", Category::Started, 2),
            ("st_done", "Done", Category::Completed, 10),
            ("st_canceled", "Canceled", Category::Canceled, 8),
        ];
        let statuses = defaults
            .iter()
            .enumerate()
            .map(|(index, (id, name, category, color))| {
                let status = Status {
                    id: (*id).to_owned(),
                    name: (*name).to_owned(),
                    category: *category,
                    position: index as i64,
                    color: *color,
                };
                ((*id).to_owned(), status)
            })
            .collect();
        Self {
            settings: TeamSettings {
                team: team.to_owned(),
                key_prefix: key_prefix.to_owned(),
                next_number: 1,
                default_status: "st_backlog".to_owned(),
                started_status: "st_in_progress".to_owned(),
                review_status: Some("st_in_review".to_owned()),
                agent_flow: AgentFlow::Forward,
            },
            statuses,
            labels: BTreeMap::new(),
            projects: BTreeMap::new(),
            tasks: BTreeMap::new(),
            relations: BTreeMap::new(),
            comments: BTreeMap::new(),
            sessions: BTreeMap::new(),
            seq: 0,
            ledger: BTreeMap::new(),
            ledger_order: VecDeque::new(),
        }
    }

    pub fn task_key(&self, task: &Task) -> String {
        format!("{}-{}", self.settings.key_prefix, task.number)
    }

    pub fn category_of(&self, task: &Task) -> Option<Category> {
        self.statuses.get(&task.status).map(|s| s.category)
    }

    /// Resolve `CMX-12`, `task_…` or a unique id prefix to a live task id.
    pub fn resolve_task(&self, reference: &str) -> Option<String> {
        if let Some(task) = self.tasks.get(reference) {
            return (!task.deleted).then(|| task.id.clone());
        }
        let prefix = format!("{}-", self.settings.key_prefix);
        if let Some(number) = reference
            .strip_prefix(&prefix)
            .or_else(|| reference.strip_prefix(&prefix.to_ascii_lowercase()))
            .and_then(|n| n.parse::<u64>().ok())
        {
            return self
                .tasks
                .values()
                .find(|t| t.number == number && !t.deleted)
                .map(|t| t.id.clone());
        }
        if reference.len() >= 6 && reference.starts_with(crate::ids::prefix::TASK) {
            let mut matches = self
                .tasks
                .values()
                .filter(|t| !t.deleted && t.id.starts_with(reference));
            let first = matches.next()?;
            return matches.next().is_none().then(|| first.id.clone());
        }
        None
    }

    /// Resolve a status by id or case-insensitive name.
    pub fn resolve_status(&self, reference: &str) -> Option<String> {
        if self.statuses.contains_key(reference) {
            return Some(reference.to_owned());
        }
        self.statuses
            .values()
            .find(|s| s.name.eq_ignore_ascii_case(reference))
            .map(|s| s.id.clone())
    }

    /// Resolve a live label by id or case-insensitive name.
    pub fn resolve_label(&self, reference: &str) -> Option<String> {
        if let Some(label) = self.labels.get(reference) {
            return (!label.archived).then(|| label.id.clone());
        }
        self.labels
            .values()
            .find(|l| !l.archived && l.name.eq_ignore_ascii_case(reference))
            .map(|l| l.id.clone())
    }

    /// Resolve a live project by id or case-insensitive name.
    pub fn resolve_project(&self, reference: &str) -> Option<String> {
        if let Some(project) = self.projects.get(reference) {
            return (!project.archived).then(|| project.id.clone());
        }
        self.projects
            .values()
            .find(|p| !p.archived && p.name.eq_ignore_ascii_case(reference))
            .map(|p| p.id.clone())
    }

    pub fn live_tasks(&self) -> impl Iterator<Item = &Task> {
        self.tasks.values().filter(|t| !t.deleted)
    }

    /// Non-terminal sessions of a task.
    pub fn active_sessions<'a>(&'a self, task: &'a str) -> impl Iterator<Item = &'a AgentSession> + 'a {
        self.sessions
            .values()
            .filter(move |s| s.task == task && !s.status.is_terminal())
    }
}
