//! The notices the macOS app posts beside a tab's own notification, and the
//! small read rules around them: a Cloud hand-off's and a sandboxed Run's
//! banner (its sound, delivery, words and what a click opens), an agent's
//! Needs you banner (which marks post, which banners go, what Show opens),
//! Mark Tab Unread's toggle, the tab a pane shows, the entry blink, a
//! finished `cmux status run` and an OSC 7501 program alert
//! (`HandoffNotices`, `SandboxRunNotices`, `AttentionBanners`,
//! `AttentionBannerLifecycle`, `TabUnreadMark`, `FinishedStatusRunTracker`,
//! `StatusBehaviorSettings.notifies`, `ProgramStatusNotification`,
//! `AttentionSettings.flashesOnEntry`).
//!
//! The app reads its models, the settings and the platform's answers (is the
//! tab viewed, did the reveal work, which banners Notification Center holds)
//! into facts, asks here, and does what the answer says: the banner, the
//! sound, the daemon write, the tab it opens. The localized words stay with
//! the app; the answers name them. Pure, no I/O.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// A hand-off's banner id prefix (`HandoffNotices.bannerPrefix`).
pub const HANDOFF_PREFIX: &str = "handoff.";
/// A sandboxed Run's banner id prefix (`SandboxRunNotices.bannerPrefix`).
pub const SANDBOX_RUN_PREFIX: &str = "sandbox-run.";
/// A Needs you banner's id prefix (`AttentionBannerLifecycle.attentionBannerPrefix`).
pub const ATTENTION_PREFIX: &str = "cmux-attention.";
/// The longest tab id a Needs you banner may name, in UTF-8 bytes.
pub const ATTENTION_TAB_LIMIT: usize = 256;
/// A banner title longer than this many characters is cut, with an ellipsis.
pub const TITLE_LIMIT: usize = 120;
/// What a cut title keeps before its ellipsis.
const TITLE_KEEP: usize = 119;
/// How much of a hand-off's summary its banner shows, in characters.
pub const DETAIL_LIMIT: usize = 240;
/// The key prefix of the entries `cmux status run` writes (`run:<pid>`).
pub const RUN_KEY_PREFIX: &str = "run:";
/// The daemon's notification title limit (terminal_metadata.rs), in characters.
pub const PROGRAM_TITLE_LIMIT: usize = 256;
/// The daemon's notification body limit (terminal_metadata.rs), in characters.
pub const PROGRAM_BODY_LIMIT: usize = 1024;

/// How a followed Run or hand-off ended (`SandboxRunEnd.Outcome`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Succeeded,
    #[default]
    Failed,
    TimedOut,
    Cancelled,
    /// A hand-off's turn stopped for the person.
    NeedsYou,
}

/// Which notice a banner is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Notice {
    /// A chat handed off to a Cloud machine (`HandoffNotices`).
    #[default]
    Handoff,
    /// A sandboxed Run sent from a New Tab page (`SandboxRunNotices`).
    SandboxRun,
    /// A tab an agent marked as needing the person (`AttentionBanners`).
    Attention,
}

/// The sound a notice plays (`NotificationSoundEvent`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SoundEvent {
    Finished,
    NeedsInput,
    Error,
    Bell,
    Message,
}

/// The sound event a notice's arrival is decided under. A hand-off that
/// stops for the person and a Run that was cancelled play the message
/// sound; a Needs you banner plays its classified sound, else needs-input.
pub fn sound_event(notice: Notice, outcome: Outcome, classified: Option<SoundEvent>) -> SoundEvent {
    match (notice, outcome) {
        (Notice::Attention, _) => classified.unwrap_or(SoundEvent::NeedsInput),
        (_, Outcome::Succeeded) => SoundEvent::Finished,
        (Notice::Handoff, Outcome::NeedsYou) | (Notice::SandboxRun, Outcome::Cancelled) => {
            SoundEvent::Message
        }
        _ => SoundEvent::Error,
    }
}

/// Whether a decided notice goes on to the sound gate and delivery: not when
/// the policy reads it at once, nor while desktop posting is off.
pub fn goes_on(acknowledge: bool, posting_enabled: bool) -> bool {
    !acknowledge && posting_enabled
}

/// How a notice is delivered once the sound gate admitted its decision.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Delivery {
    /// A banner is posted.
    pub banner: bool,
    /// The banner carries the system's default sound.
    pub default_sound: bool,
    /// The app plays the decided sound itself; `Some(true)` with a banner.
    pub play: Option<bool>,
}

/// The delivery of a decision: the banner when `desktop`, its default sound
/// when the sound is `default`; any other sound (or any sound without a
/// banner) the app plays itself.
pub fn delivery(desktop: bool, sound: Option<&str>) -> Delivery {
    let is_default = sound == Some("default");
    Delivery {
        banner: desktop,
        default_sound: desktop && is_default,
        play: sound.filter(|_| !is_default || !desktop).map(|_| desktop),
    }
}

/// Swift's `Character.isNewline`, per scalar.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Foundation's `CharacterSet.whitespaces`: white space but no line break.
fn is_space(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

/// The first line of `text` that holds more than white space, trimmed.
fn first_line(text: &str) -> Option<&str> {
    text.split(is_newline).map(|line| line.trim_matches(is_space)).find(|line| !line.is_empty())
}

/// `text`'s first `limit` characters (grapheme clusters, as Swift counts).
fn prefix(text: &str, limit: usize) -> &str {
    match text.grapheme_indices(true).nth(limit) {
        Some((end, _)) => text.get(..end).unwrap_or(text),
        None => text,
    }
}

/// A banner title: cut to 119 characters and an ellipsis past [`TITLE_LIMIT`].
pub fn title(line: &str) -> String {
    if line.graphemes(true).nth(TITLE_LIMIT).is_some() {
        format!("{}…", prefix(line, TITLE_KEEP))
    } else {
        line.to_owned()
    }
}

/// `text` cut to `limit` characters (the daemon's notification limits).
fn clipped(text: &str, limit: usize) -> &str {
    prefix(text, limit)
}

/// What a hand-off's banner reads from its end.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HandoffFacts {
    pub outcome: Outcome,
    /// The summary in the wait's `{handoff}`, nil for none or a replayed end.
    pub summary: Option<String>,
    /// The record's task (the summary it was made with).
    pub task: String,
    /// The title of the tab showing the chat, if any.
    pub chat: Option<String>,
}

/// The state line of a hand-off's banner, worded by the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HandoffState {
    NeedsYou,
    Done,
    Failed,
}

/// A hand-off banner's words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HandoffText {
    /// The title; none: the app's untitled wording ("Cloud task").
    pub title: Option<String>,
    pub state: HandoffState,
    /// The summary line under the state, none when the body is the state alone.
    pub detail: Option<String>,
}

/// A hand-off banner's words: the chat's title (else the summary's first
/// line), then what happened and, once it finished, the summary unless the
/// title already is it.
pub fn handoff_text(facts: &HandoffFacts) -> HandoffText {
    let summary = facts.summary.as_deref().unwrap_or(&facts.task);
    let first = first_line(summary);
    let chat = facts.chat.as_deref().map(str::trim).filter(|chat| !chat.is_empty());
    let named = chat.or(first);
    let state = match facts.outcome {
        Outcome::NeedsYou => HandoffState::NeedsYou,
        Outcome::Succeeded => HandoffState::Done,
        Outcome::Failed | Outcome::TimedOut | Outcome::Cancelled => HandoffState::Failed,
    };
    let detail = summary.trim();
    let detail = (facts.outcome != Outcome::NeedsYou && !detail.is_empty() && named != first)
        .then(|| prefix(detail, DETAIL_LIMIT).to_owned());
    HandoffText { title: named.map(title), state, detail }
}

/// The body line of a Run's banner, worded by the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunBody {
    Succeeded,
    Failed,
    TimedOut,
    Cancelled,
}

/// A Run banner's words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunText {
    pub title: String,
    pub body: RunBody,
}

/// A Run banner's words: the task's first line, then how the Run ended (a Run
/// never stops for the person; such an end reads as a failure).
pub fn sandbox_run_text(task: &str, outcome: Outcome) -> RunText {
    let body = match outcome {
        Outcome::Succeeded => RunBody::Succeeded,
        Outcome::Failed | Outcome::NeedsYou => RunBody::Failed,
        Outcome::TimedOut => RunBody::TimedOut,
        Outcome::Cancelled => RunBody::Cancelled,
    };
    RunText { title: title(first_line(task).unwrap_or("")), body }
}

/// The notice a banner id names and the id after its prefix.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Banner {
    pub notice: Notice,
    /// The hand-off or Run id, or the marked tab's id.
    pub id: String,
}

/// The notice banner `id` names; none for any other banner. A Needs you
/// banner names a tab only when the rest is not empty and at most
/// [`ATTENTION_TAB_LIMIT`] bytes.
pub fn banner(id: &str) -> Option<Banner> {
    if let Some(rest) = id.strip_prefix(HANDOFF_PREFIX) {
        return Some(Banner { notice: Notice::Handoff, id: rest.to_owned() });
    }
    if let Some(rest) = id.strip_prefix(SANDBOX_RUN_PREFIX) {
        return Some(Banner { notice: Notice::SandboxRun, id: rest.to_owned() });
    }
    attention_tab(id).map(|tab| Banner { notice: Notice::Attention, id: tab.to_owned() })
}

/// The banner id of `notice` for `id`.
pub fn banner_id(notice: Notice, id: &str) -> String {
    let prefix = match notice {
        Notice::Handoff => HANDOFF_PREFIX,
        Notice::SandboxRun => SANDBOX_RUN_PREFIX,
        Notice::Attention => ATTENTION_PREFIX,
    };
    format!("{prefix}{id}")
}

/// The tab a Needs you banner names (`AttentionBannerLifecycle.attentionTab`).
pub fn attention_tab(banner: &str) -> Option<&str> {
    banner
        .strip_prefix(ATTENTION_PREFIX)
        .filter(|tab| !tab.is_empty() && tab.len() <= ATTENTION_TAB_LIMIT)
}

/// What changed in the marked tabs since the last list.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionChanges {
    /// The marks to post, as indices into the current list.
    pub post: Vec<usize>,
    /// The banner ids to withdraw (a mark that cleared or was replaced).
    pub withdraw: Vec<String>,
}

/// What changed between the marked tabs (by row key) `previous` and
/// `current`: a mark that is new posts, one that went is withdrawn. No
/// previous list is the first of this launch: its marks post nothing, as
/// notifications that came before launch do not.
pub fn attention_changes(previous: Option<&[String]>, current: &[String]) -> AttentionChanges {
    let Some(previous) = previous else { return AttentionChanges::default() };
    let before: std::collections::HashSet<&str> = previous.iter().map(String::as_str).collect();
    let now: std::collections::HashSet<&str> = current.iter().map(String::as_str).collect();
    AttentionChanges {
        post: current
            .iter()
            .enumerate()
            .filter(|(_, tab)| !before.contains(tab.as_str()))
            .map(|(index, _)| index)
            .collect(),
        withdraw: previous
            .iter()
            .filter(|tab| !now.contains(tab.as_str()))
            .map(|tab| banner_id(Notice::Attention, tab))
            .collect(),
    }
}

/// The marks that post, as indices into `current`: the watch's eligible
/// requests when it classified them (a request seen while the tree was not
/// ready is not diffed away), else the new marks.
pub fn attention_posts(
    previous: Option<&[String]>,
    current: &[String],
    eligible: Option<&[String]>,
) -> Vec<usize> {
    match eligible {
        Some(eligible) => {
            let eligible: std::collections::HashSet<&str> =
                eligible.iter().map(String::as_str).collect();
            current
                .iter()
                .enumerate()
                .filter(|(_, tab)| eligible.contains(tab.as_str()))
                .map(|(index, _)| index)
                .collect()
        }
        None => attention_changes(previous, current).post,
    }
}

/// The Needs you banners Notification Center kept from an earlier launch:
/// `retained` less the ones this launch posted.
pub fn attention_stale(retained: &[String], current_launch: &[String]) -> Vec<String> {
    let posted: std::collections::HashSet<&str> =
        current_launch.iter().map(String::as_str).collect();
    retained
        .iter()
        .filter(|id| id.starts_with(ATTENTION_PREFIX) && !posted.contains(id.as_str()))
        .cloned()
        .collect()
}

/// What a Needs you banner's Show does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AttentionShow {
    /// The banner is no Needs you banner: another notice may take it.
    NotOurs,
    /// Taken, nothing to open (the app's services have not started).
    Nothing,
    /// Taken, but its request is gone (an earlier launch's, or replaced).
    Gone,
    /// Open the tab, as Search Tabs does.
    Open,
}

/// The facts a Needs you banner's Show reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AttentionShowFacts {
    pub banner: String,
    /// The shared marked-tab list exists (the app's services started).
    pub shared: bool,
    /// This launch posted the banner and has not withdrawn it.
    pub posted: bool,
    /// The marked tabs now, by row key.
    pub marked: Vec<String>,
}

/// What Show on a Needs you banner does: only a banner this launch posted
/// whose request is still a tab's live mark opens it.
pub fn attention_show(facts: &AttentionShowFacts) -> AttentionShow {
    let Some(tab) = attention_tab(&facts.banner) else { return AttentionShow::NotOurs };
    if !facts.shared {
        return AttentionShow::Nothing;
    }
    if !facts.posted || !facts.marked.iter().any(|marked| marked == tab) {
        return AttentionShow::Gone;
    }
    AttentionShow::Open
}

/// What a click on a hand-off's banner does once the tab showing its chat
/// was tried.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HandoffOpen {
    /// Nothing more: shown, unknown, or an incognito chat (it never opens
    /// outside its window).
    Nothing,
    /// The app comes forward: the hand-off names no host this app knows.
    Activate,
    /// A new workspace on the session's host opens the chat.
    OpenWorkspace,
}

/// The facts a hand-off banner's click reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HandoffOpenFacts {
    /// The follower still knows the hand-off (ended or followed).
    pub found: bool,
    /// A tab shows the chat and revealing it worked.
    pub revealed: bool,
    pub incognito: bool,
    /// The record names the session's acpmux host.
    pub has_host: bool,
}

/// What a hand-off banner's click does.
pub fn handoff_open(facts: HandoffOpenFacts) -> HandoffOpen {
    if !facts.found || facts.revealed || facts.incognito {
        HandoffOpen::Nothing
    } else if !facts.has_host {
        HandoffOpen::Activate
    } else {
        HandoffOpen::OpenWorkspace
    }
}

/// What a click on a Run's banner does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunOpen {
    /// Nothing: the Run is forgotten, or its incognito tab is gone.
    Nothing,
    /// The tab that sent the Run, which shows its card.
    ShowTab,
    /// A new workspace whose chat shows the card.
    NewWorkspace,
}

/// The facts a Run banner's click reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunOpenFacts {
    /// The follower still keeps the ended Run.
    pub found: bool,
    /// The sending tab's page may still show an answer older than the end.
    pub stale: bool,
    /// The sending tab is still in the tree.
    pub tab: bool,
    pub incognito: bool,
}

/// What a Run banner's click does.
pub fn sandbox_run_open(facts: RunOpenFacts) -> RunOpen {
    if !facts.found {
        RunOpen::Nothing
    } else if !facts.stale && facts.tab {
        RunOpen::ShowTab
    } else if facts.incognito {
        RunOpen::Nothing
    } else {
        RunOpen::NewWorkspace
    }
}

/// A daemon capability a mark write needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MarkCapability {
    /// `tab-attention-request-id`: a conditional clear of an agent's mark.
    TabAttentionRequestId,
    /// `tab-mark-unread-v1`: the durable Mark Tab Unread flag.
    TabMarkUnread,
}

/// One write of a Mark Tab Unread toggle, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MarkStep {
    /// Acknowledge the tab's unread notification.
    Acknowledge,
    /// Clear Mark as Unread.
    ClearMark,
    /// Clear the agent's needs-you mark.
    ClearAttention,
    /// Mark the tab unread.
    Mark,
}

/// The facts a Mark Tab Unread toggle reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToggleFacts {
    /// The tab shows unread: a notification, the mark, or both.
    pub shows_unread: bool,
    pub has_unread: bool,
    pub marked_unread: bool,
    /// An agent's needs-you mark is on the tab.
    pub attention: bool,
    /// The tab's daemon clears an agent's mark conditionally.
    pub attention_supported: bool,
    /// The tab's daemon keeps the mark for this tab.
    pub mark_supported: bool,
}

/// A toggle's plan: the refusal, else its writes in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TogglePlan {
    /// The capability the tab's daemon lacks; nothing is written.
    pub refuse: Option<MarkCapability>,
    pub steps: Vec<MarkStep>,
}

/// Mark Tab Unread's toggle: a tab that shows unread is read (its
/// notification, its mark and an agent's mark); one that shows read is
/// marked. Every write is checked first: a daemon that cannot clear an
/// agent's mark conditionally refuses the whole read, so nothing is left
/// half done; clearing a mark the daemon cannot keep is nothing to do.
pub fn tab_unread_toggle(facts: ToggleFacts) -> TogglePlan {
    if !facts.shows_unread {
        return match mark_write(MarkWrite::Mark, facts.mark_supported) {
            WriteStep::Refuse(capability) => TogglePlan { refuse: Some(capability), steps: vec![] },
            _ => TogglePlan { refuse: None, steps: vec![MarkStep::Mark] },
        };
    }
    if facts.attention && !facts.attention_supported {
        return TogglePlan { refuse: Some(MarkCapability::TabAttentionRequestId), steps: vec![] };
    }
    let mut steps = Vec::new();
    if facts.has_unread {
        steps.push(MarkStep::Acknowledge);
    }
    if facts.marked_unread
        && mark_write(MarkWrite::ClearMark, facts.mark_supported) == WriteStep::Send
    {
        steps.push(MarkStep::ClearMark);
    }
    if facts.attention {
        steps.push(MarkStep::ClearAttention);
    }
    TogglePlan { refuse: None, steps }
}

/// One mark write on its own (`TabUnreadMark.set`, `clearAttention`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MarkWrite {
    #[default]
    Mark,
    ClearMark,
    ClearAttention,
}

/// What one mark write does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "step", content = "capability")]
pub enum WriteStep {
    /// Send it.
    Send,
    /// Nothing: a clear of a mark the daemon cannot keep.
    Nothing,
    /// Refuse: the daemon lacks the capability (restart it).
    Refuse(MarkCapability),
}

/// What mark write `write` does on a daemon that `supported` it: without
/// the capability, a mark or an agent mark's clear is refused, and clearing
/// Mark as Unread does nothing (that daemon holds no mark).
pub fn mark_write(write: MarkWrite, supported: bool) -> WriteStep {
    match (write, supported) {
        (_, true) => WriteStep::Send,
        (MarkWrite::ClearMark, false) => WriteStep::Nothing,
        (MarkWrite::Mark, false) => WriteStep::Refuse(MarkCapability::TabMarkUnread),
        (MarkWrite::ClearAttention, false) => {
            WriteStep::Refuse(MarkCapability::TabAttentionRequestId)
        }
    }
}

/// The `viewed` tabs that `previous` did not hold: the tabs that came into
/// view and so clear their mark. A tab marked while viewed keeps the mark
/// until it leaves view and comes back.
pub fn entered(viewed: &[String], previous: &[String]) -> Vec<String> {
    let before: std::collections::HashSet<&str> = previous.iter().map(String::as_str).collect();
    viewed.iter().filter(|tab| !before.contains(tab.as_str())).cloned().collect()
}

/// The tab a pane shows: the one its strip selects when it holds it, else
/// the daemon's default tab, clamped into the pane. None for an empty pane.
pub fn shown_tab(count: usize, selected: Option<usize>, default_index: i64) -> Option<usize> {
    let last = count.checked_sub(1)?;
    if let Some(selected) = selected.filter(|selected| *selected <= last) {
        return Some(selected);
    }
    Some(usize::try_from(default_index.max(0)).unwrap_or(usize::MAX).min(last))
}

/// What brought the person to a tab (`NotificationTrigger`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Trigger {
    #[default]
    Focus,
    Click,
    Keystroke,
    Open,
    Timeout,
}

/// Whether going into a tab by `trigger` blinks its ring out
/// (`AttentionSettings.flashesOnEntry`): under the read flash, any look but
/// the timeout, and a key only under the typing flash.
pub fn flashes_on_entry(trigger: Trigger, flashes_on_read: bool, flashes_on_typing: bool) -> bool {
    match trigger {
        Trigger::Timeout => false,
        Trigger::Keystroke => flashes_on_read && flashes_on_typing,
        Trigger::Focus | Trigger::Click | Trigger::Open => flashes_on_read,
    }
}

/// One `cmux status run` entry, by workspace and key.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunKey {
    pub workspace: String,
    pub key: String,
}

/// One status entry, as far as a finish reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StatusEntry {
    pub key: String,
    /// `busy|success|error|waiting|info`, none for a plain line.
    pub state: Option<String>,
}

/// One workspace's status entries.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceStatus {
    pub workspace: String,
    pub entries: Vec<StatusEntry>,
}

/// A finished run, by its place in the statuses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinishedRun {
    /// The index of the workspace status.
    pub status: usize,
    /// The index of the entry in it.
    pub entry: usize,
}

/// The runs that finished between two looks, and the runs busy now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunsUpdate {
    /// In the statuses' order.
    pub finished: Vec<FinishedRun>,
    /// What the next look passes as `running`.
    pub running: Vec<RunKey>,
}

/// The `cmux status run`s that finished since the look that saw `running`
/// busy (`FinishedStatusRunTracker.update`). A run counts only when it was
/// seen busy first: a finished entry already there (a relaunch, a
/// reconnect) is no news, one that stays counts once, and one that went
/// away while busy never counts.
pub fn runs_finished(running: &[RunKey], statuses: &[WorkspaceStatus]) -> RunsUpdate {
    let was: std::collections::HashSet<(&str, &str)> =
        running.iter().map(|run| (run.workspace.as_str(), run.key.as_str())).collect();
    let mut update = RunsUpdate::default();
    for (status_index, status) in statuses.iter().enumerate() {
        for (entry_index, entry) in status.entries.iter().enumerate() {
            if !entry.key.starts_with(RUN_KEY_PREFIX) {
                continue;
            }
            match entry.state.as_deref() {
                Some("busy") => update
                    .running
                    .push(RunKey { workspace: status.workspace.clone(), key: entry.key.clone() }),
                Some("success" | "error")
                    if was.contains(&(status.workspace.as_str(), entry.key.as_str())) =>
                {
                    update.finished.push(FinishedRun { status: status_index, entry: entry_index });
                }
                _ => {}
            }
        }
    }
    update
}

/// Where a terminal is for the person (`TerminalVisibility`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Visibility {
    /// Its tab is the selected tab of its pane.
    pub tab_selected: bool,
    /// Its pane is on screen in its window.
    pub pane_on_screen: bool,
    /// Its window is key, or at least not occluded.
    pub window_shown: bool,
    /// cmux is the active app.
    pub app_active: bool,
}

impl Visibility {
    /// The person can see the terminal now.
    pub fn is_visible(self) -> bool {
        self.tab_selected && self.pane_on_screen && self.window_shown && self.app_active
    }
}

/// Whether a finished `cmux status run` notifies: it ran at least
/// `minimum_seconds` (no duration counts as instant), and its terminal is
/// not visible unless `when_visible` is on.
pub fn run_notifies(
    duration_ms: Option<u64>,
    minimum_seconds: f64,
    when_visible: bool,
    visibility: Visibility,
) -> bool {
    let seconds = std::time::Duration::from_millis(duration_ms.unwrap_or(0)).as_secs_f64();
    seconds >= minimum_seconds && (when_visible || !visibility.is_visible())
}

/// A daemon notification's level (`NotificationLevel`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    #[default]
    Info,
    Warning,
    Error,
}

/// An OSC 7501 record's state (`ProgramStatusRecord.State`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgramState {
    #[default]
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

/// A blocked record's kind (`ProgramStatusRecord.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgramKind {
    Permission,
    Question,
    Auth,
}

/// One OSC 7501 record, as far as an alert reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProgramRecord {
    pub state: ProgramState,
    pub kind: Option<ProgramKind>,
    pub title: Option<String>,
    pub app: Option<String>,
    pub msg: Option<String>,
    pub updated_seq: u64,
}

/// Why a program notified (`ProgramStatusNotification.Reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgramReason {
    Permission,
    Question,
    Auth,
    /// Blocked without a kind.
    Input,
    Failed,
    Done,
}

const PROGRAM_REASONS: [ProgramReason; 6] = [
    ProgramReason::Permission,
    ProgramReason::Question,
    ProgramReason::Auth,
    ProgramReason::Input,
    ProgramReason::Failed,
    ProgramReason::Done,
];

impl ProgramReason {
    /// A record's reason to notify; none while it works or idles.
    pub fn of(record: &ProgramRecord) -> Option<Self> {
        match record.state {
            ProgramState::Blocked => Some(match record.kind {
                Some(ProgramKind::Permission) => Self::Permission,
                Some(ProgramKind::Question) => Self::Question,
                Some(ProgramKind::Auth) => Self::Auth,
                None => Self::Input,
            }),
            ProgramState::Error => Some(Self::Failed),
            ProgramState::Done => Some(Self::Done),
            ProgramState::Working | ProgramState::Idle => None,
        }
    }

    /// The daemon's wording (program_status.rs `raise_alert`).
    pub fn verb(self) -> &'static str {
        match self {
            Self::Permission => "needs approval",
            Self::Question => "asks a question",
            Self::Auth => "needs sign-in",
            Self::Input => "needs input",
            Self::Failed => "failed",
            Self::Done => "is done",
        }
    }

    /// The level the daemon posts it at: a wait warns, a failure errs.
    pub fn level(self) -> Level {
        match self {
            Self::Permission | Self::Question | Self::Auth | Self::Input => Level::Warning,
            Self::Failed => Level::Error,
            Self::Done => Level::Info,
        }
    }
}

/// The record a `terminal` notification was posted for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramMatch {
    /// The index of the record.
    pub record: usize,
    pub reason: ProgramReason,
}

/// The OSC 7501 record a notification with `title`, `body` and `level` was
/// posted for ("<title, else app, else A program> <verb>", the record's
/// message as the body, clipped to the daemon's limits); none for any other
/// terminal notification. Among several the newest report wins (the last
/// of equals, as Swift's `max` keeps).
pub fn program_match(
    title: &str,
    body: &str,
    level: Level,
    records: &[ProgramRecord],
) -> Option<ProgramMatch> {
    let mut best: Option<(usize, &ProgramRecord, ProgramReason)> = None;
    for (index, record) in records.iter().enumerate() {
        let Some(reason) = ProgramReason::of(record) else { continue };
        if reason.level() != level {
            continue;
        }
        let name = record.title.as_deref().or(record.app.as_deref()).unwrap_or("A program");
        let posted = format!("{name} {}", reason.verb());
        if clipped(&posted, PROGRAM_TITLE_LIMIT) != title
            || clipped(record.msg.as_deref().unwrap_or(""), PROGRAM_BODY_LIMIT) != body
        {
            continue;
        }
        if best.is_none_or(|(_, held, _)| held.updated_seq <= record.updated_seq) {
            best = Some((index, record, reason));
        }
    }
    best.map(|(record, _, reason)| ProgramMatch { record, reason })
}

/// Whether a `terminal` notification reads like an OSC 7501 alert ("<name>
/// <verb>" at the verb's level) whose record may not have arrived yet.
pub fn looks_like_alert(title: &str, level: Level) -> bool {
    PROGRAM_REASONS.iter().any(|reason| {
        let suffix = format!(" {}", reason.verb());
        reason.level() == level
            && title.ends_with(&suffix)
            && title.graphemes(true).count() > suffix.graphemes(true).count()
    })
}

/// Whether a program alert shows at all: `done` only for a terminal the
/// person cannot see (Lawrence, cx-kxa2); the rest follow the normal rules.
pub fn program_notifies(reason: ProgramReason, visibility: Visibility) -> bool {
    reason != ProgramReason::Done || !visibility.is_visible()
}

#[cfg(test)]
#[path = "notification_notices_tests.rs"]
mod tests;
