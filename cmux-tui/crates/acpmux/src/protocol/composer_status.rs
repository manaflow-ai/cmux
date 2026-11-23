//! The agent pane's composer footer: one status dot and its rundown (`items`), and the
//! session's quiet metadata (`facts`). acpmux decides which items exist, their level, the
//! string-catalog key of their words, when the dot may show them (`showAt`) and their one
//! action; the pane only renders them (Leo: every health or transient status leaves the
//! transcript and the status rows and becomes one unobtrusive dot in the composer footer that
//! fades in only when something is worth knowing).
//!
//! Two carriers: a session summary's `composerStatus` ([`composer_status`], from the summary's
//! own fields, [`SessionFacts::from_summary`]), and `_acpmux/peer_state_changed`'s `status`
//! ([`machine_link_item`]), the machine-link item of a peer session's machine. The pane-local
//! kinds (`agentService`, `restoringSessions`, `sendsHeld`) are facts only the pane has; they
//! are named here so one table names every kind and its words.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::peer_state::{MachineLink, OfflineAction, OfflineReason};
use crate::session_liveness::StuckReason;

/// How long a transient link state (connecting, reconnecting, degraded, restarting) stays off
/// the dot: a blip that heals inside it is never shown.
pub const LINK_QUIET_MS: u64 = 10_000;

/// How much an item matters; ordered, `problem` worst.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum StatusLevel {
    /// Worth a glance; it heals on its own.
    Info,
    /// Something waits on time or on a person, and nothing is broken.
    Attention,
    /// Broken until a person acts.
    Problem,
}

impl StatusLevel {
    /// Every level, least first.
    pub const ALL: [Self; 3] = [Self::Info, Self::Attention, Self::Problem];
}

/// What an item is about. One words-key prefix each ([`StatusKind::words_prefix`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum StatusKind {
    /// The link to the machine a peer session runs on (`_acpmux/peer_state_changed` `status`).
    MachineLink,
    /// The account's rate limit holds the chat's turns (`rateLimitedUntil`, `rateLimitParked`).
    RateLimited,
    /// Its harness failed three times in a row (`stuckReason`).
    Stuck,
    /// A turn failed and the prompts behind it wait to be resumed (`queuePaused`).
    QueuePaused,
    /// Its harness refuses commands because its own sandbox did not start
    /// (`harnessSandboxFailing`).
    HarnessSandbox,
    /// Pane-local, never sent by acpmux: the pane's link to its agent service.
    AgentService,
    /// Pane-local, never sent by acpmux: the pane restores its sessions.
    RestoringSessions,
    /// Pane-local, never sent by acpmux: the pane holds sends it could not deliver yet.
    SendsHeld,
}

impl StatusKind {
    /// Every kind, in the order of the enum: a renderer's table test walks it.
    pub const ALL: [Self; 8] = [
        Self::MachineLink,
        Self::RateLimited,
        Self::Stuck,
        Self::QueuePaused,
        Self::HarnessSandbox,
        Self::AgentService,
        Self::RestoringSessions,
        Self::SendsHeld,
    ];

    /// Its wire word.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MachineLink => "machineLink",
            Self::RateLimited => "rateLimited",
            Self::Stuck => "stuck",
            Self::QueuePaused => "queuePaused",
            Self::HarnessSandbox => "harnessSandbox",
            Self::AgentService => "agentService",
            Self::RestoringSessions => "restoringSessions",
            Self::SendsHeld => "sendsHeld",
        }
    }

    /// The prefix every words key of this kind starts with: `status.<kind>`, then the end of
    /// the key or `.`.
    pub fn words_prefix(self) -> &'static str {
        match self {
            Self::MachineLink => "status.machineLink",
            Self::RateLimited => "status.rateLimited",
            Self::Stuck => "status.stuck",
            Self::QueuePaused => "status.queuePaused",
            Self::HarnessSandbox => "status.harnessSandbox",
            Self::AgentService => "status.agentService",
            Self::RestoringSessions => "status.restoringSessions",
            Self::SendsHeld => "status.sendsHeld",
        }
    }

    /// Whether acpmux emits it itself (the rest are the pane's own).
    pub fn emitted_by_daemon(self) -> bool {
        !matches!(self, Self::AgentService | Self::RestoringSessions | Self::SendsHeld)
    }
}

/// The one thing a person does about an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum StatusAction {
    /// Dial the machine again now (`_acpmux/peer_reconnect`).
    Reconnect,
    /// Resume the prompts a failed turn paused.
    ResumeQueue,
    /// Sign in again.
    SignIn,
    /// Update the machine.
    Update,
}

impl StatusAction {
    /// Every action, in the order of the enum.
    pub const ALL: [Self; 4] = [Self::Reconnect, Self::ResumeQueue, Self::SignIn, Self::Update];
}

/// One entry of the dot's rundown.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StatusItem {
    pub kind: StatusKind,
    pub level: StatusLevel,
    /// A string-catalog key (`status.machineLink.reconnecting`), never English.
    pub words: String,
    /// The machine or harness the words name as `{subject}`; absent when they name none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub subject: Option<String>,
    /// Since when it holds, ms since the epoch; absent when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub since: Option<u64>,
    /// When it ends on its own (a rate limit's reset), ms since the epoch; absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub until: Option<u64>,
    /// The dot shows it no earlier than this, ms since the epoch; absent: at once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub show_at: Option<u64>,
    /// The one thing a person does about it; absent when there is none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub action: Option<StatusAction>,
}

impl StatusItem {
    fn new(kind: StatusKind, level: StatusLevel, words: String) -> Self {
        Self {
            kind,
            level,
            words,
            subject: None,
            since: None,
            until: None,
            show_at: None,
            action: None,
        }
    }
}

/// What a footer fact is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum FactKind {
    /// The peer machine the session runs on (`text`); absent for this daemon's own.
    Machine,
    /// Its folder (`text`, the whole path).
    Folder,
    /// The branch its folder has checked out (`text`).
    Branch,
    /// Its harness profile (`text`).
    Harness,
    /// Its model (`text`).
    Model,
    /// How full its context is (`fraction`).
    Context,
    /// Its subagents that run now (`count`).
    Subagents,
    /// Its prompts that wait (`count`).
    Queued,
    /// Its running turn (`since`, the turn's start).
    Turn,
}

impl FactKind {
    /// Every kind, in footer order.
    pub const ALL: [Self; 9] = [
        Self::Machine,
        Self::Folder,
        Self::Branch,
        Self::Harness,
        Self::Model,
        Self::Context,
        Self::Turn,
        Self::Subagents,
        Self::Queued,
    ];

    /// Its text repeats one of the summary row's own fields (`peer`, `cwd`, `gitBranch`,
    /// `harness`, `model`): a census row leaves it out ([`census`]).
    pub fn repeats_row(self) -> bool {
        matches!(self, Self::Machine | Self::Folder | Self::Branch | Self::Harness | Self::Model)
    }
}

/// One piece of the footer's quiet metadata.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FooterFact {
    pub kind: FactKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub count: Option<u32>,
    /// The share of the context window used, 0 to 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub fraction: Option<f32>,
    /// The running turn's start, ms since the epoch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(default)]
    pub since: Option<u64>,
    /// Worth a counter in the footer row itself now; else the hover card lists it only.
    pub live: bool,
}

impl FooterFact {
    fn new(kind: FactKind) -> Self {
        Self { kind, text: None, count: None, fraction: None, since: None, live: false }
    }

    fn text(kind: FactKind, text: Option<&str>) -> Option<Self> {
        let text = text.map(str::trim).filter(|t| !t.is_empty())?;
        Some(Self { text: Some(text.to_owned()), ..Self::new(kind) })
    }

    fn counter(kind: FactKind, count: u64) -> Option<Self> {
        (count > 0).then(|| Self {
            count: Some(u32::try_from(count).unwrap_or(u32::MAX)),
            live: true,
            ..Self::new(kind)
        })
    }
}

/// A session's composer footer (`composerStatus`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = super::require_all)]
pub struct ComposerStatus {
    /// Worst level first, then the oldest `since` (an unknown one last).
    pub items: Vec<StatusItem>,
    /// In footer order (`FactKind::ALL`); a fact with nothing to say is left out.
    pub facts: Vec<FooterFact>,
}

/// What [`composer_status`] reads: the session summary's own fields, borrowed.
#[derive(Debug, Clone, Default)]
pub struct SessionFacts<'a> {
    pub peer: Option<&'a str>,
    pub cwd: Option<&'a str>,
    pub branch: Option<&'a str>,
    pub harness: Option<&'a str>,
    pub model: Option<&'a str>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
    pub subagents_live: Option<u64>,
    pub queued: u64,
    pub queue_paused: bool,
    pub rate_limited_until: Option<u64>,
    pub rate_limit_parked: Option<u64>,
    pub stuck_reason: Option<StuckReason>,
    pub stuck_since: Option<u64>,
    pub harness_sandbox_failing: bool,
    pub harness_sandbox_failed: Option<u64>,
    pub turn_started_at: Option<u64>,
}

impl<'a> SessionFacts<'a> {
    /// From a session summary as it goes on the wire (`Hub::session_summary`, or a peer's row
    /// with `peer`): a fixed set of key reads, no scan of the row.
    pub fn from_summary(summary: &'a Value) -> Self {
        let str_of = move |key: &str| summary.get(key).and_then(Value::as_str);
        let u64_of = move |key: &str| summary.get(key).and_then(Value::as_u64);
        let usage = summary.get("usageStats");
        let usage_of = move |key: &str| usage.and_then(|u| u.get(key)).and_then(Value::as_u64);
        // What runs below it now (`running_work`), else what its harness's records said last.
        let subagents_live = u64_of("subagentsRunning").or_else(|| usage_of("subagentsLive"));
        Self {
            peer: str_of("peer"),
            cwd: str_of("cwd"),
            branch: str_of("gitBranch"),
            harness: str_of("harness"),
            model: str_of("model"),
            context_tokens: usage_of("contextTokens"),
            context_window: usage_of("contextWindow"),
            subagents_live,
            queued: u64_of("queued").unwrap_or(0),
            queue_paused: summary.get("queuePaused").and_then(Value::as_bool).unwrap_or(false),
            rate_limited_until: u64_of("rateLimitedUntil"),
            rate_limit_parked: u64_of("rateLimitParked"),
            stuck_reason: summary
                .get("stuckReason")
                .filter(|r| !r.is_null())
                .and_then(|r| StuckReason::deserialize(r).ok()),
            stuck_since: u64_of("stuckSince"),
            harness_sandbox_failing: summary
                .get("harnessSandboxFailing")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            harness_sandbox_failed: u64_of("harnessSandboxFailed"),
            turn_started_at: summary
                .get("turn")
                .and_then(|t| t.get("startedAt"))
                .and_then(Value::as_u64),
        }
    }
}

/// The machine-link item for peer `peer`'s link in `link` since `since`, with the reason it
/// will not heal on its own (`reason`); `removed` when the peer was removed. None while the
/// link is up (connected) or paused on purpose.
pub fn machine_link_item(
    peer: &str,
    link: MachineLink,
    since: Option<u64>,
    reason: Option<OfflineReason>,
    removed: bool,
) -> Option<StatusItem> {
    use MachineLink::*;
    let kind = StatusKind::MachineLink;
    let (level, words, action, quiet) = match link {
        Connected | Paused => return None,
        _ if removed => (StatusLevel::Attention, "removed".to_owned(), None, false),
        Connecting => (StatusLevel::Info, "connecting".to_owned(), None, true),
        Reconnecting => (StatusLevel::Info, "reconnecting".to_owned(), None, true),
        Degraded => (StatusLevel::Info, "degraded".to_owned(), None, true),
        Restarting => (StatusLevel::Info, "restarting".to_owned(), None, true),
        Offline => {
            let words = match reason {
                Some(reason) => format!("offline.{}", offline_reason_word(reason)),
                None => "offline".to_owned(),
            };
            (StatusLevel::Attention, words, offline_action(reason), false)
        }
        AuthFailed => {
            (StatusLevel::Problem, "authFailed".to_owned(), Some(StatusAction::SignIn), false)
        }
        UpdateRequired => {
            (StatusLevel::Problem, "updateRequired".to_owned(), Some(StatusAction::Update), false)
        }
    };
    let mut item = StatusItem::new(kind, level, format!("{}.{words}", kind.words_prefix()));
    item.subject = Some(peer.to_owned());
    item.since = since;
    item.show_at = if quiet { since.map(|s| s.saturating_add(LINK_QUIET_MS)) } else { None };
    item.action = action;
    Some(item)
}

/// What a person can do from the dot about an offline link: dial again, unless its reason
/// names another remedy (`OfflineReason::action`) the dot has no button for.
fn offline_action(reason: Option<OfflineReason>) -> Option<StatusAction> {
    match reason.map(OfflineReason::action) {
        None | Some(OfflineAction::Reconnect) => Some(StatusAction::Reconnect),
        Some(OfflineAction::SignIn) => Some(StatusAction::SignIn),
        Some(
            OfflineAction::StartMachine | OfflineAction::RestartDaemon | OfflineAction::FreeDisk,
        ) => None,
    }
}

fn offline_reason_word(reason: OfflineReason) -> &'static str {
    match reason {
        OfflineReason::CredentialUnavailable => "credentialUnavailable",
        OfflineReason::MachineStopped => "machineStopped",
        OfflineReason::LoginNeeded => "loginNeeded",
        OfflineReason::RestartBudgetExceeded => "restartBudgetExceeded",
        OfflineReason::DiskFull => "diskFull",
    }
}

fn stuck_word(reason: StuckReason) -> &'static str {
    match reason {
        StuckReason::HarnessUnavailable => "harnessUnavailable",
        StuckReason::Capacity => "capacity",
        StuckReason::Auth => "auth",
        StuckReason::SpawnFailed => "spawnFailed",
    }
}

fn words(kind: StatusKind, rest: &str) -> String {
    format!("{}.{rest}", kind.words_prefix())
}

/// `status` as a census row (a session list, a `session_changed` without tools) carries it: none
/// when it has no item and no live fact, else without the facts that repeat the row's own fields.
/// The open chat's whole status rides on the reads that carry tools (`_acpmux/attach`,
/// `_acpmux/info`, and the `session_changed` of a chat the connection attached), so a list of
/// 5,000 rows does not carry 5,000 copies of every row's folder, branch, harness and model twice.
pub fn census(mut status: ComposerStatus) -> Option<ComposerStatus> {
    if status.items.is_empty() && !status.facts.iter().any(|fact| fact.live) {
        return None;
    }
    status.facts.retain(|fact| !fact.kind.repeats_row());
    Some(status)
}

/// The session's composer footer from its summary's facts: at most one item per kind and nine
/// facts, so its cost does not grow with the session.
pub fn composer_status(facts: &SessionFacts<'_>) -> ComposerStatus {
    let harness = facts.harness.map(str::to_owned);
    let mut items = Vec::new();
    if let Some(reason) = facts.stuck_reason {
        let mut item = StatusItem::new(
            StatusKind::Stuck,
            StatusLevel::Problem,
            words(StatusKind::Stuck, stuck_word(reason)),
        );
        item.subject = harness.clone();
        item.since = facts.stuck_since;
        item.action = (reason == StuckReason::Auth).then_some(StatusAction::SignIn);
        items.push(item);
    }
    if facts.harness_sandbox_failing {
        let mut item = StatusItem::new(
            StatusKind::HarnessSandbox,
            StatusLevel::Problem,
            words(StatusKind::HarnessSandbox, "failing"),
        );
        item.subject = harness.clone();
        item.since = facts.harness_sandbox_failed;
        items.push(item);
    }
    if let Some(parked) = facts.rate_limit_parked {
        let mut item = StatusItem::new(
            StatusKind::RateLimited,
            StatusLevel::Attention,
            words(StatusKind::RateLimited, "parked"),
        );
        item.subject = harness.clone();
        item.since = Some(parked);
        item.until = facts.rate_limited_until;
        items.push(item);
    } else if let Some(until) = facts.rate_limited_until {
        let mut item = StatusItem::new(
            StatusKind::RateLimited,
            StatusLevel::Attention,
            words(StatusKind::RateLimited, "until"),
        );
        item.subject = harness.clone();
        item.until = Some(until);
        items.push(item);
    }
    if facts.queue_paused {
        let mut item = StatusItem::new(
            StatusKind::QueuePaused,
            StatusLevel::Attention,
            words(StatusKind::QueuePaused, "paused"),
        );
        item.action = Some(StatusAction::ResumeQueue);
        items.push(item);
    }
    // Stable: equal items keep the order above.
    items.sort_by_key(|item| (std::cmp::Reverse(item.level), item.since.unwrap_or(u64::MAX)));

    let mut out = Vec::with_capacity(FactKind::ALL.len());
    out.extend(FooterFact::text(FactKind::Machine, facts.peer));
    out.extend(FooterFact::text(FactKind::Folder, facts.cwd));
    out.extend(FooterFact::text(FactKind::Branch, facts.branch));
    out.extend(FooterFact::text(FactKind::Harness, facts.harness));
    out.extend(FooterFact::text(FactKind::Model, facts.model));
    if let (Some(tokens), Some(window)) = (facts.context_tokens, facts.context_window)
        && window > 0
    {
        let fraction = (tokens as f64 / window as f64).clamp(0.0, 1.0) as f32;
        out.push(FooterFact { fraction: Some(fraction), ..FooterFact::new(FactKind::Context) });
    }
    if let Some(started) = facts.turn_started_at {
        out.push(FooterFact { since: Some(started), ..FooterFact::new(FactKind::Turn) });
    }
    out.extend(FooterFact::counter(FactKind::Subagents, facts.subagents_live.unwrap_or(0)));
    out.extend(FooterFact::counter(FactKind::Queued, facts.queued));
    ComposerStatus { items, facts: out }
}

#[cfg(test)]
#[path = "composer_status_tests.rs"]
mod tests;
