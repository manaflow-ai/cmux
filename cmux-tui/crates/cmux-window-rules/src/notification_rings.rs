//! The attention ring and read rules of the notification service (the
//! macOS app's `NotificationCenterService` and its `+Lookup` extension):
//! which panes ring and with what generation, which looks read a tab (its
//! unread notification, an agent's needs-you request, Mark as Unread, a
//! finished agent turn), what Dismiss Highlight reads and hides, the
//! burst of agent turn ends that pulses once, where an arriving
//! notification goes (read on sight, kept unread, held for its OSC 7501
//! record, delivered), whether a banner's reply may type, and whether a
//! workspace's unread mark is sent again.
//!
//! The app reads its tab models, the settings and its own view state
//! (which tab a window shows, the dismissed generations, the held tabs)
//! into [`Tab`] facts, asks here, and applies the answer: the ring it
//! draws, the daemon read it sends, the blink. Pure, no I/O.

use serde::{Deserialize, Serialize};

/// The bit a marked tab's ring generation carries, apart from notification
/// ids (`NotificationCenterService.markRingBase`).
pub const MARK_RING_BASE: u64 = 1 << 63;
/// The bit an agent's attention ring carries, apart from manual marks
/// (`NotificationCenterService.attentionRingBase`).
pub const ATTENTION_RING_BASE: u64 = 1 << 62;
/// The banner id prefix of a tab's notification (`cmux-notification-<id>`).
pub const BANNER_PREFIX: &str = "cmux-notification-";
/// Turn ends closer together than this pulse once; the rest ring at rest
/// (`NotificationCenterService.burstWindow`, cmuxterm-hq#2959).
pub const BURST_WINDOW_MS: f64 = 900.0;
/// How long a throttled workspace mark send counts as in flight
/// (`WorkspaceUnreadMark.echoWindow`).
pub const ECHO_WINDOW_MS: f64 = 2000.0;

/// What brought the person to a tab (`NotificationTrigger`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Trigger {
    /// The pane became the focused pane of the key window while cmux is active.
    #[default]
    Focus,
    /// A mouse-down in the pane.
    Click,
    /// A key typed into the pane's terminal or page.
    Keystroke,
    /// The notification was opened: jump to unread, a banner click.
    Open,
    /// The `timeout` dismissal deadline passed.
    Timeout,
}

impl Trigger {
    /// A click, a key or opening it: the person went into the tab.
    fn goes_in(self) -> bool {
        matches!(self, Trigger::Click | Trigger::Keystroke | Trigger::Open)
    }
}

/// One tab's facts, as the app reads them from its model and view state.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    /// The tab has an unread notification (`TabModel.hasUnread`).
    pub has_unread: bool,
    /// The unread marker's notification id; none rings as 1.
    pub notification: Option<u64>,
    /// Mark as Unread is on (`TabModel.markedUnread`).
    pub marked_unread: bool,
    /// The mark's generation (`TabModel.markedUnreadGeneration`).
    pub marked_generation: u64,
    /// The mark generation Dismiss Highlight hid (`dismissedMarks`), 0: none.
    pub dismissed_mark: u64,
    /// An agent's needs-you request is on the tab (`TabModel.attention`).
    pub attention: bool,
    /// Dismiss Highlight or a look hid that request's ring (`AttentionRingHides`).
    pub attention_hidden: bool,
    /// The request's generation (`TabModel.attentionGeneration`).
    pub attention_generation: u64,
    /// The tab is an agent chat (`TabModel.agentSession` is set).
    pub agent_chat: bool,
    /// The chat is thinking, on any machine (`AgentTurnStateStore.isWorking`).
    pub working: bool,
    /// The generation of a finished agent turn not looked at yet (`agentFinished`).
    pub finished: Option<u64>,
    /// That finish rings at rest: one of a burst (`quietAgentFinishes`).
    pub quiet: bool,
    /// The tab is the focused content of the key window while cmux is active (`isViewed`).
    pub viewed: bool,
    /// A strip press holds the tab: its focus is no look yet (`viewHolds`).
    pub held: bool,
    /// The person went into the tab and its ring blinks out (`entryReads`).
    pub entry_read: bool,
    /// A key may read the tab now (`TabModel.keyMayRead`: no rolled-back read's backoff).
    pub key_may_read: bool,
    /// The dismissal policy clears the tab's notification source under the
    /// asked trigger (`NotificationPolicy.clears(trigger, for: source)`).
    pub clears_source: bool,
}

impl Tab {
    /// The tab shows unread (`TabModel.showsUnread`): a notification, a mark or a request.
    pub fn shows_unread(&self) -> bool {
        self.has_unread || self.marked_unread || self.attention
    }
}

/// The generation of `tab`'s unread ring, or none when it draws none
/// (`NotificationCenterService.unreadRing(of:dismissed:)`): derived from the
/// tab's unread state alone. An unread notification rings unless Dismiss
/// Highlight hid it (`dismissed`, the workspace's newest dismissed
/// notification id); a manual mark rings unless this mark was dismissed; an
/// agent's request rings unless its ring was hidden. A mark's generation
/// sits above every notification id, so its ring restarts.
pub fn unread_ring(tab: &Tab, dismissed: u64) -> Option<u64> {
    if !tab.shows_unread() {
        return None;
    }
    if tab.has_unread {
        let generation = tab.notification.unwrap_or(1);
        if generation > dismissed {
            return Some(generation);
        }
    }
    if tab.marked_unread && tab.marked_generation > tab.dismissed_mark {
        return Some(MARK_RING_BASE | tab.marked_generation);
    }
    if !tab.attention || tab.attention_hidden {
        return None;
    }
    let bases = MARK_RING_BASE | ATTENTION_RING_BASE;
    Some(bases | (tab.attention_generation & !bases))
}

/// The policy and settings a read rule reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReadPolicy {
    /// The dismissal policy clears agent notifications under the trigger
    /// (`NotificationPolicy.clears(trigger, for: .agent)`).
    pub clears_agent: bool,
    /// Agent chats draw the turn-end ring (`attention.rings(agentChat: true)`).
    pub rings_chat: bool,
}

/// Whether going into `tab` by `trigger` reads its ring
/// (`NotificationCenterService.reads(_:_:turn:)`): it clears every reason the
/// ring draws for, an unread notification, a needs-you request, a mark (a
/// click only) and a finished turn (`turn`), by the policy.
pub fn reads(trigger: Trigger, tab: &Tab, turn: bool, policy: ReadPolicy) -> bool {
    let finished = turn && tab.finished.is_some() && tab.agent_chat && policy.rings_chat;
    (tab.has_unread || tab.attention || tab.marked_unread || finished)
        && (!tab.has_unread || tab.clears_source)
        && (!tab.marked_unread || trigger == Trigger::Click)
        && (!tab.attention || policy.clears_agent)
        && (!finished || policy.clears_agent)
}

/// A viewed tab reads its notifications and needs-you requests at once
/// (cmux#42210), so it draws no ring (a mark stays). A tab a strip press
/// holds is no look yet (cmux#46908) (`readsOnSight`). `policy` is the
/// `focus` trigger's and `tab.clears_source` its source's under `focus`.
pub fn reads_on_sight(tab: &Tab, policy: ReadPolicy) -> bool {
    reads(Trigger::Focus, tab, false, policy) && tab.viewed && !tab.held
}

/// One pane and the tab a window shows in it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ShownPane {
    pub pane: String,
    pub tab: Tab,
}

/// A workspace's facts for its attention marks.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MarkFacts {
    /// `notifications.attention.style` is `none`.
    pub style_none: bool,
    /// The workspace is muted.
    pub muted: bool,
    /// The workspace is this Mac's (finished turns are recorded here only).
    pub local: bool,
    /// The workspace's newest dismissed notification id (Dismiss Highlight).
    pub dismissed: u64,
    /// The `focus` trigger's agent policy, and whether agent chats ring.
    pub policy: ReadPolicy,
    /// A terminal draws the ring (`attention.rings(agentChat: false)`).
    pub rings_terminal: bool,
    pub panes: Vec<ShownPane>,
}

/// Where a mark's color comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MarkColor {
    /// The ring's own color (a marked tab with no notification has no source).
    Ring,
    /// The tab's notification source's override.
    Source,
    /// The agent source's override (a finished turn).
    Agent,
}

/// One pane's attention mark (`AttentionMark`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneMark {
    pub pane: String,
    pub generation: u64,
    pub agent_chat: bool,
    pub quiet: bool,
    pub color: MarkColor,
}

/// Attention marks for a workspace's panes
/// (`NotificationCenterService.attentionMarks(for:shownTab:)`): every pane
/// whose shown tab reads unread rings, agent chats included, unless the
/// workspace is muted or the style is `none`. A pane showing a read tab
/// draws none, nor does one read on sight. A chat that is thinking rings
/// nothing (Leo, 2026-11-06); one whose turn ended rings until the person
/// goes into it, only with the opt-in agent chat ring. An unread tab rings
/// whatever kind it is, as its dot shows (cmux#34447).
pub fn marks(facts: &MarkFacts) -> Vec<PaneMark> {
    if facts.style_none || facts.muted {
        return Vec::new();
    }
    let mut marks = Vec::new();
    for shown in &facts.panes {
        let tab = &shown.tab;
        if reads_on_sight(tab, facts.policy) || (tab.agent_chat && tab.working) {
            continue;
        }
        let chat_look = tab.agent_chat && facts.policy.rings_chat;
        if chat_look && facts.local {
            if let Some(generation) = tab.finished {
                marks.push(PaneMark {
                    pane: shown.pane.clone(),
                    generation,
                    agent_chat: true,
                    quiet: tab.quiet,
                    color: MarkColor::Agent,
                });
                continue;
            }
        }
        let rings = if chat_look { facts.policy.rings_chat } else { facts.rings_terminal };
        if !rings {
            continue;
        }
        let Some(generation) = unread_ring(tab, facts.dismissed) else { continue };
        marks.push(PaneMark {
            pane: shown.pane.clone(),
            generation,
            agent_chat: chat_look,
            quiet: false,
            color: if tab.has_unread { MarkColor::Source } else { MarkColor::Ring },
        });
    }
    marks
}

/// A workspace's panes for the entry reads, each with its tabs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EntryPane {
    pub pane: String,
    pub tabs: Vec<Tab>,
}

/// The facts of [`entered`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EntryFacts {
    /// The panes whose mark just went away.
    pub removed: Vec<String>,
    /// A focus blinks a ring out (`attention.flashesOnEntry(.focus)`).
    pub flashes_on_focus: bool,
    /// The service holds any entry read at all.
    pub any_entry_reads: bool,
    /// The `focus` trigger's policy.
    pub policy: ReadPolicy,
    pub panes: Vec<EntryPane>,
}

/// Of the panes in `removed`, those the person went into, focus included
/// (cmux#42210: its ring is read on sight, maybe before the focus read):
/// their ring blinks out (`NotificationCenterService.takeEntryReads`).
pub fn entered(facts: &EntryFacts) -> Vec<String> {
    let on_sight = !facts.removed.is_empty() && facts.flashes_on_focus;
    if !facts.any_entry_reads && !on_sight {
        return Vec::new();
    }
    facts
        .panes
        .iter()
        .filter(|pane| facts.removed.contains(&pane.pane))
        .filter(|pane| {
            pane.tabs
                .iter()
                .any(|tab| tab.entry_read || (on_sight && reads_on_sight(tab, facts.policy)))
        })
        .map(|pane| pane.pane.clone())
        .collect()
}

/// The facts of one look at a tab ([`interaction`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InteractionFacts {
    pub trigger: Trigger,
    /// The tab's daemon is this Mac's (or unknown).
    pub local: bool,
    /// The tab's daemon is another machine's without `notification-ack-v1`.
    pub owner_cannot_ack: bool,
    /// The look blinks a read ring out (`attention.flashesOnEntry(trigger)`).
    pub flashes: bool,
    /// The trigger's agent policy.
    pub policy: ReadPolicy,
    pub tab: Tab,
}

/// What a look does to a tab's notification.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Ack {
    /// Nothing: no unread notification, or the policy keeps it.
    #[default]
    None,
    /// The policy reads it, but its machine's daemon cannot take the read.
    Refused,
    /// Read it.
    Read,
}

/// The plan of one look ([`interaction`]), in the order the app applies it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Interaction {
    /// The look ends a strip press's hold on the tab.
    pub ends_hold: bool,
    /// The look sees the tab's workspace's status symbols.
    pub sees_workspace: bool,
    /// The look reads the chat's finished turn.
    pub reads_turn: bool,
    /// The look hides the agent's needs-you ring.
    pub hides_attention: bool,
    /// The look reads Mark as Unread.
    pub reads_mark: bool,
    pub ack: Ack,
    /// A ring this look reads blinks out.
    pub entry_read: bool,
}

/// One read rule on every machine (`NotificationCenterService.interacted(_:tab:owner:)`,
/// `dismissAttention`, `readMark`): the policy decides, the tab's daemon is
/// told. Going into a tab a strip press held ends the hold. A finished turn
/// is read on this Mac only. Going into a tab an agent marked hides its
/// ring (a click, a key, opening it, or focus under the `focus` dismissal).
/// A click or a key (once its backoff passed) reads Mark as Unread; focus
/// keeps it. A key reads a notification only past its backoff too, and a
/// remote daemon without `notification-ack-v1` cannot take the read.
pub fn interaction(facts: &InteractionFacts) -> Interaction {
    let trigger = facts.trigger;
    let tab = &facts.tab;
    let reads_turn = facts.local && tab.finished.is_some() && facts.policy.clears_agent;
    let hides_attention = tab.attention
        && (trigger.goes_in() || (trigger == Trigger::Focus && facts.policy.clears_agent));
    let key_reads = trigger != Trigger::Keystroke || tab.key_may_read;
    let reads_mark = tab.marked_unread
        && (trigger == Trigger::Click || (trigger == Trigger::Keystroke && tab.key_may_read));
    let ack = if !tab.has_unread || !tab.clears_source || !key_reads {
        Ack::None
    } else if facts.owner_cannot_ack {
        Ack::Refused
    } else {
        Ack::Read
    };
    Interaction {
        ends_hold: trigger.goes_in(),
        sees_workspace: matches!(trigger, Trigger::Focus | Trigger::Click | Trigger::Open),
        reads_turn,
        hides_attention,
        reads_mark,
        ack,
        entry_read: facts.flashes && (reads_turn || reads_mark || ack == Ack::Read),
    }
}

/// The facts of Dismiss Highlight ([`dismiss_highlight`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HighlightFacts {
    /// The workspace is this Mac's.
    pub local: bool,
    /// A read blinks its ring out (`attention.flashesOnRead`).
    pub flashes_on_read: bool,
    /// The workspace's newest dismissed notification id so far.
    pub dismissed: u64,
    /// Every tab of the workspace, in tree order.
    pub tabs: Vec<Tab>,
}

/// What Dismiss Highlight does to one tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HighlightStep {
    /// The tab's index in [`HighlightFacts::tabs`].
    pub index: usize,
    /// Forget the chat's finished turn (this Mac's only).
    pub clears_turn: bool,
    /// The mark generation to keep hidden, when the tab is marked.
    pub hides_mark: Option<u64>,
    /// Hide the agent's needs-you ring.
    pub hides_attention: bool,
    /// The ring blinks out.
    pub entry_read: bool,
}

/// Dismiss Highlight's plan.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Highlight {
    /// Each tab that shows unread or holds a finished turn: it is read too.
    pub steps: Vec<HighlightStep>,
    /// The newest unread notification id, when above the dismissed one: the
    /// workspace's new dismissed id.
    pub through: Option<u64>,
}

/// Dismiss Highlight (cx-epgo, `NotificationCenterService.dismissHighlight`):
/// reads the workspace as classic's dismiss did (cmux#42210): every unread
/// notification, manual mark and agent request goes, and each ring blinks
/// out. The hides keep a ring hidden where a daemon cannot take the read,
/// until a newer notification or mark comes.
pub fn dismiss_highlight(facts: &HighlightFacts) -> Highlight {
    let newest = facts
        .tabs
        .iter()
        .filter(|tab| tab.has_unread)
        .map(|tab| tab.notification.unwrap_or(1))
        .max()
        .unwrap_or(0);
    let steps = facts
        .tabs
        .iter()
        .enumerate()
        .filter(|(_, tab)| tab.shows_unread() || tab.finished.is_some())
        .map(|(index, tab)| HighlightStep {
            index,
            clears_turn: facts.local && tab.finished.is_some(),
            hides_mark: tab.marked_unread.then_some(tab.marked_generation),
            hides_attention: tab.attention,
            entry_read: facts.flashes_on_read,
        })
        .collect();
    Highlight { steps, through: (newest > facts.dismissed).then_some(newest) }
}

/// The facts of an agent chat's turn end ([`turn_ended`]).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TurnEndFacts {
    /// Agent chats draw the turn-end ring (`notifications.attention.agentChats`).
    pub rings: bool,
    /// Milliseconds since the last pulse; none: no pulse yet.
    pub since_pulse_ms: Option<f64>,
    /// The last finish generation handed out.
    pub generation: u64,
    /// Whether each of the chat's tabs is viewed now.
    pub viewed: Vec<bool>,
}

/// One tab a turn end rings.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnRing {
    /// The tab's index in [`TurnEndFacts::viewed`].
    pub index: usize,
    pub generation: u64,
    /// It rings at rest: within the burst window of the last pulse.
    pub quiet: bool,
}

/// What a turn end records.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnEnd {
    pub rings: Vec<TurnRing>,
    /// The last finish generation handed out now.
    pub generation: u64,
    /// A ring pulsed: the last pulse is now.
    pub pulsed: bool,
}

/// An agent chat's turn ended (`NotificationCenterService.agentTurnEnded`):
/// with the agent chat ring on, ring the chat's tabs the person is not
/// looking at until they go in. A burst pulses once: a finish within
/// [`BURST_WINDOW_MS`] of the last pulse rings at rest (cmuxterm-hq#2959).
pub fn turn_ended(facts: &TurnEndFacts) -> TurnEnd {
    let mut end = TurnEnd { generation: facts.generation, ..TurnEnd::default() };
    if !facts.rings {
        return end;
    }
    let mut since = facts.since_pulse_ms;
    for (index, viewed) in facts.viewed.iter().enumerate() {
        if *viewed {
            continue;
        }
        end.generation = end.generation.wrapping_add(1);
        let quiet = since.is_some_and(|ms| ms < BURST_WINDOW_MS);
        if !quiet {
            since = Some(0.0);
            end.pulsed = true;
        }
        end.rings.push(TurnRing { index, generation: end.generation, quiet });
    }
    end
}

/// The facts of a banner's reply ([`reply_allowed`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReplyFacts {
    /// The banner's id.
    pub banner: String,
    pub text_empty: bool,
    /// The banner's tab is in the store.
    pub located: bool,
    /// The tab is a terminal.
    pub pty: bool,
    /// The tab's notification marker, when it has one.
    pub marker: Option<u64>,
    pub marker_unread: bool,
}

/// Whether a reply banner's text may be typed into its terminal
/// (`NotificationCenterService.reply`): only while the banner's
/// notification is still the tab's unread one, so a banner left from an
/// earlier launch, or one a newer notification replaced, never types into
/// whatever runs there now.
pub fn reply_allowed(facts: &ReplyFacts) -> bool {
    if facts.text_empty || !facts.located || !facts.pty || !facts.marker_unread {
        return false;
    }
    let Some(marker) = facts.marker else { return false };
    facts.banner.strip_prefix(BANNER_PREFIX) == Some(marker.to_string().as_str())
}

/// The facts of an arriving notification, after the policy decided ([`arrival`]).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ArrivalFacts {
    /// A terminal's notification while `desktop-notifications = false`.
    pub terminal_off: bool,
    /// Its tab is in the store.
    pub located: bool,
    /// The policy reads it at once (`Decision.acknowledge`).
    pub acknowledge: bool,
    /// An agent's finished turn.
    pub finished_turn: bool,
    /// The tab is visible to the person now.
    pub visible: bool,
    /// The tab still holds an earlier unread ask or error.
    pub holds_other_ask: bool,
    /// The dismissal reads a pane on sight for its source
    /// (`NotificationPolicy.clears(.focus, for: source)`).
    pub clears_focus: bool,
    /// Its terminal's OSC 7501 record is known.
    pub program: bool,
    /// A terminal's notification.
    pub terminal_source: bool,
    /// Its title reads like an OSC 7501 alert
    /// (`ProgramStatusNotification.looksLikeAlert`).
    pub looks_like_alert: bool,
}

/// Where an arriving notification goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ArrivalRoute {
    /// Terminal notifications are off: read it, nothing more.
    TerminalOff,
    /// No tab holds it: the workspace's notification path.
    Untracked,
    /// The policy reads it on sight.
    ReadOnSight,
    /// Seen landing, kept unread for a click in its pane: no banner.
    KeepSeen,
    /// Seen landing: read at once.
    ReadSeen,
    /// Wait for its OSC 7501 record before delivering.
    HoldForRecord,
    Deliver,
}

/// Where an arriving notification goes (`NotificationCenterService.arrive`).
/// A turn that finished in front of the person is already seen (cx-slk1h)
/// when the dismissal reads a pane on sight; under `click` its ring stays
/// until the pane is clicked or typed in. An agent that asks or fails stays
/// unread even there, and so does an earlier ask or error the tab still
/// holds. A terminal alert with no OSC 7501 record yet waits for it.
pub fn arrival(facts: &ArrivalFacts) -> ArrivalRoute {
    if facts.terminal_off {
        return ArrivalRoute::TerminalOff;
    }
    if !facts.located {
        return ArrivalRoute::Untracked;
    }
    if facts.acknowledge {
        return ArrivalRoute::ReadOnSight;
    }
    if facts.finished_turn && facts.visible && !facts.holds_other_ask {
        return seen(facts.clears_focus);
    }
    if !facts.program && facts.terminal_source && facts.looks_like_alert {
        return ArrivalRoute::HoldForRecord;
    }
    ArrivalRoute::Deliver
}

/// A notification the person saw land (a visible finished turn, an OSC 7501
/// done for a visible terminal, cx-kxa2): read at once when the dismissal
/// reads a pane on sight, else kept unread for a click.
pub fn seen(clears_focus: bool) -> ArrivalRoute {
    if clears_focus { ArrivalRoute::ReadSeen } else { ArrivalRoute::KeepSeen }
}

/// A workspace mark's last send.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LastSend {
    pub marked: bool,
    /// Milliseconds since it went out.
    pub ago_ms: f64,
}

/// The facts of [`mark_needs_send`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MarkSend {
    /// The value to send.
    pub marked: bool,
    /// The value the workspace's tree holds.
    pub current: bool,
    pub last: Option<LastSend>,
    /// Typing asks: a repeat within [`ECHO_WINDOW_MS`] counts as in flight.
    pub throttled: bool,
}

/// Whether a workspace's Mark as Unread must go out
/// (`WorkspaceUnreadMark.needsSend`): when the tree or the last send
/// differs, so a clear asked for before a mark's echo arrives is not
/// dropped. Throttled, the same value sent within the echo window counts as
/// still in flight.
pub fn mark_needs_send(facts: &MarkSend) -> bool {
    if let Some(last) = facts.last {
        if facts.throttled && last.marked == facts.marked && last.ago_ms < ECHO_WINDOW_MS {
            return false;
        }
    }
    facts.current != facts.marked || facts.last.is_some_and(|last| last.marked != facts.marked)
}

#[cfg(test)]
#[path = "notification_rings_tests.rs"]
mod tests;
