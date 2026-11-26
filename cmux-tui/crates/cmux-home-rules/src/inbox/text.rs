//! A row's words as rules, not strings (`HomeRowText`, `InviteWaiting`, `HomeAgentGlance`): Rust
//! picks the kind and the parts; Swift words and formats them in the person's locale.

use super::model::{Membership, Participant};
use serde::{Deserialize, Serialize};

/// `Date.distantPast`, seconds since 1970.
pub const DISTANT_PAST: f64 = -62_135_769_600.0;

/// Which form `homeListTime` shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ListTime {
    /// No time (`""`).
    None,
    /// Today: the short time.
    Time,
    /// `HomeConversationStrings.yesterday`.
    Yesterday,
    /// Two to six days ago: the weekday (`EEEE`).
    Weekday,
    /// Older or ahead: the short date.
    Date,
}

/// `Date.homeListTime`: `time` and `now` in seconds since 1970, `utc_offset` the calendar's
/// offset in seconds at those times.
pub fn list_time(time: f64, now: f64, utc_offset: f64) -> ListTime {
    if time <= DISTANT_PAST {
        return ListTime::None;
    }
    let day = |t: f64| ((t + utc_offset) / 86_400.0).floor() as i64;
    match day(now) - day(time) {
        0 => ListTime::Time,
        1 => ListTime::Yesterday,
        2..=6 => ListTime::Weekday,
        _ => ListTime::Date,
    }
}

/// The last message, as `homePreview` reads it (the caller strips Markdown: `HomeMarkdownPreview`
/// is MessagesLab's).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct LastMessage {
    pub retracted: bool,
    /// The row preview with Markdown markers stripped.
    pub stripped_preview: String,
    /// The message's plain text with Markdown markers stripped.
    pub stripped_plain_text: String,
    pub is_reply: bool,
    /// The newest reaction, if any.
    pub reaction: Option<Reaction>,
}

/// A reaction (`author`, `kind`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reaction {
    pub author: String,
    pub kind: String,
}

/// `HomeRowPreview`, with a reaction left for Swift to word
/// (`HomeConversationStrings.reaction(kind, by:, to:)`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Preview {
    Text {
        text: String,
        is_reply: bool,
    },
    Reaction {
        /// `true`: "You"; else `name`.
        by_me: bool,
        name: String,
        reaction: String,
        quoted: String,
    },
}

fn one_line(text: &str) -> String {
    text.replace('\n', " ")
}

/// `InboxRow.homePreview(me:)`.
pub fn preview(
    preview: &str,
    last: Option<&LastMessage>,
    participants: &[Participant],
    me: Option<&str>,
) -> Preview {
    let Some(last) = last.filter(|last| !last.retracted) else {
        return Preview::Text { text: one_line(preview), is_reply: false };
    };
    if let Some(reaction) = &last.reaction {
        let by_me = Some(reaction.author.as_str()) == me;
        let name = if by_me {
            String::new()
        } else {
            participants
                .iter()
                .find(|p| p.id == reaction.author)
                .map(|p| p.display_name.clone())
                .unwrap_or_default()
        };
        return Preview::Reaction {
            by_me,
            name,
            reaction: reaction.kind.clone(),
            quoted: one_line(&last.stripped_plain_text),
        };
    }
    Preview::Text { text: one_line(&last.stripped_preview), is_reply: last.is_reply }
}

/// `ConversationSummary.homeInviteWaiting(me:)`'s kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum InviteWaiting {
    /// `HomeConversationStrings.invitedLabel`.
    Invited,
    /// `HomeConversationStrings.waitingFor(name)`.
    WaitingFor { name: String },
}

/// `homeInviteWaiting(me:)`: the first invited peer, if any.
pub fn invite_waiting(participants: &[Participant], me: Option<&str>) -> Option<InviteWaiting> {
    let invited = participants
        .iter()
        .find(|p| Some(p.id.as_str()) != me && p.membership == Membership::Invited)?;
    let name = invited.visible_name();
    Some(if name.is_empty() { InviteWaiting::Invited } else { InviteWaiting::WaitingFor { name } })
}

/// `HomeAgentGlance.Status`, most urgent first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GlanceStatus {
    NeedsYou,
    Failed,
    Done,
    Idle,
    Working,
}

/// `StatusIndicatorState` a status shows by default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Indicator {
    /// `.waiting(kind: nil)`.
    Waiting,
    Error,
    Success,
    Idle,
    /// `.working(progress: nil)`.
    Working,
}

/// `HomeAgentGlance.Status.indicator`.
pub fn indicator(status: GlanceStatus) -> Indicator {
    match status {
        GlanceStatus::NeedsYou => Indicator::Waiting,
        GlanceStatus::Failed => Indicator::Error,
        GlanceStatus::Done => Indicator::Success,
        GlanceStatus::Idle => Indicator::Idle,
        GlanceStatus::Working => Indicator::Working,
    }
}

/// `HomeAgentGlance.shortlist`: indices of the `limit` most urgent agents, stable.
pub fn shortlist(statuses: &[GlanceStatus], limit: usize) -> Vec<usize> {
    let mut order: Vec<(GlanceStatus, usize)> =
        statuses.iter().copied().enumerate().map(|(i, status)| (status, i)).collect();
    order.sort();
    order.truncate(limit);
    order.into_iter().map(|(_, i)| i).collect()
}
