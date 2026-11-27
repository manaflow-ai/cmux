//! The `mapping` area: the owners' wire rows (local daemon, cloud, live frames) as Home rows, and the
//! decisions the Mac's Home sources make around them. This is the projection the Mac and iOS share.
//!
//! The Swift it replaces lives in `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine`: `HomeCoreMapping`
//! ([`core`]), `CloudHomeMapping` and `CloudHomeState` ([`cloud`]), `HomeInboxMapping` and
//! `HomeInboxSource` ([`inbox`]), `HomeLiveMapping` and `HomeAgentRunMapping` ([`live`]),
//! `DaemonHomeSource` and `HomeConversationSession` ([`source`]). I/O stays in Swift: every op takes the
//! rows it reads and answers the rows or decisions it makes.
//!
//! Wire rows come in as the daemon sends them (snake_case). Home core rows (`Participant`, `Message`,
//! `ConversationSummary`, ...) go out in the shape Swift's synthesized `Codable` reads ([`home`]), with
//! dates as seconds since 1970 (`JSONDecoder.dateDecodingStrategy = .secondsSince1970`).

pub mod cloud;
pub mod core;
pub mod home;
pub mod inbox;
pub mod live;
pub mod sha256;
pub mod source;
pub mod wire;

use crate::ops::OpError;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// This area's op names (without the `mapping.` prefix).
pub const OPS: &[&str] = &[
    "agentRun",
    "cloudIdentity",
    "cloudMessage",
    "cloudParticipant",
    "cloudParticipantRecord",
    "cloudParts",
    "cloudSnapshot",
    "cloudSummary",
    "cloudMissingHeads",
    "conversationEvent",
    "conversationPage",
    "date",
    "historyPage",
    "inboxAccept",
    "inboxEdit",
    "inboxEntrySummary",
    "inboxNote",
    "inboxOrdered",
    "inboxRows",
    "inboxSeed",
    "liveEvent",
    "message",
    "op",
    "part",
    "participant",
    "parts",
    "refStoredAs",
    "rejection",
    "requestLimits",
    "runChanged",
    "searchHits",
    "sessionStep",
    "summary",
    "talkRows",
    "thread",
    "threadPage",
    "timeKey",
];

/// Runs `mapping.NAME` from request bytes to reply bytes where the op has a typed path
/// ([`core::call_bytes`]); `None` sends the caller to [`call`].
pub fn call_bytes(name: &str, bytes: &[u8]) -> Option<Result<Vec<u8>, OpError>> {
    core::call_bytes(name, bytes)
}

/// Runs `mapping.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "date" => core::date_op(request),
        "participant" => core::participant_op(request),
        "part" => core::part_op(request),
        "message" => core::message_op(request),
        "summary" => core::summary_op(request),
        "thread" => core::thread_op(request),
        "threadPage" => core::thread_page_op(request),
        "conversationPage" => core::conversation_page_op(request),
        "historyPage" => core::history_page_op(request),
        "parts" => core::parts_op(request),
        "op" => core::op_op(request),
        "refStoredAs" => core::ref_stored_as_op(request),
        "cloudIdentity" => cloud::identity_op(request),
        "cloudParticipant" => cloud::participant_op(request),
        "cloudMessage" => cloud::message_op(request),
        "cloudSummary" => cloud::summary_op(request),
        "inboxEntrySummary" => cloud::entry_summary_op(request),
        "cloudParts" => cloud::parts_op(request),
        "cloudSnapshot" => cloud::snapshot_op(request),
        "cloudMissingHeads" => cloud::missing_heads_op(request),
        "cloudParticipantRecord" => cloud::participant_record_op(request),
        "inboxRows" => inbox::rows_op(request),
        "inboxOrdered" => inbox::ordered_op(request),
        "timeKey" => inbox::time_key_op(request),
        "inboxNote" => inbox::note_op(request),
        "inboxAccept" => inbox::accept_op(request),
        "inboxSeed" => inbox::seed_op(request),
        "inboxEdit" => inbox::edit_op(request),
        "liveEvent" => live::live_event_op(request),
        "runChanged" => live::run_changed_op(request),
        "talkRows" => live::talk_rows_op(request),
        "agentRun" => live::agent_run_op(request),
        "conversationEvent" => source::conversation_event_op(request),
        "rejection" => source::rejection_op(request),
        "requestLimits" => source::request_limits_op(request),
        "searchHits" => source::search_hits_op(request),
        "sessionStep" => source::session_step_op(request),
        _ => Err(OpError::Unknown),
    }
}

/// The account's ids, when a row comes from a cloud owner: the cloud names the user by its Worker id
/// (`participantId`) or `user_<stack id>` (`cloudId`); Home names it `localId` (`CloudIdentity`).
/// Without one, every id is itself (the local owner).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub cloud_id: String,
    pub local_id: String,
    #[serde(default)]
    pub display_name: String,
    pub participant_id: String,
}

impl Identity {
    /// An owner's participant id as Home's (`CloudIdentity.toHome`).
    pub fn to_home(&self, id: &str) -> String {
        if id == self.participant_id || id == self.cloud_id {
            self.local_id.clone()
        } else {
            id.to_string()
        }
    }

    /// Home's participant id as the cloud's (`CloudIdentity.toCloud`).
    pub fn to_cloud(&self, id: &str) -> String {
        if id == self.local_id { self.participant_id.clone() } else { id.to_string() }
    }
}

/// `to_home` through an optional identity (the local owner maps every id to itself).
pub(crate) fn author(identity: Option<&Identity>, id: &str) -> String {
    identity.map_or_else(|| id.to_string(), |identity| identity.to_home(id))
}

/// `Date.distantPast` in seconds since 1970 (0001-01-01T00:00:00Z).
pub const DISTANT_PAST: f64 = -62_135_769_600.0;

/// `HomeCoreMapping.date`: an `ISO8601DateFormatter` with `.withInternetDateTime` and
/// `.withFractionalSeconds`, in seconds since 1970. A time without its fraction does not parse
/// (the formatter requires it); the fraction counts to the millisecond, as Foundation's does.
pub fn parse_date(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let digits = |range: std::ops::Range<usize>| -> Option<i64> {
        let slice = b.get(range)?;
        if slice.is_empty() || !slice.iter().all(u8::is_ascii_digit) {
            return None;
        }
        Some(slice.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0')))
    };
    let at = |i: usize| b.get(i).copied();
    if b.len() < 20
        || at(4) != Some(b'-')
        || at(7) != Some(b'-')
        || at(10) != Some(b'T')
        || at(13) != Some(b':')
        || at(16) != Some(b':')
    {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(5..7)?, digits(8..10)?);
    let (hour, minute, second) = (digits(11..13)?, digits(14..16)?, digits(17..19)?);
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    if at(19) != Some(b'.') {
        return None;
    }
    let tail = b.get(20..)?;
    let count = tail.iter().take_while(|d| d.is_ascii_digit()).count();
    if count == 0 {
        return None;
    }
    let end = 20 + count;
    let fraction = tail.get(..count)?;
    let millis =
        (0..3).fold(0i64, |n, i| n * 10 + fraction.get(i).map_or(0, |d| i64::from(d - b'0')));
    let offset = match b.get(end..)? {
        [b'Z'] => 0,
        [sign @ (b'+' | b'-'), _, _, b':', _, _] => {
            let hours = digits(end + 1..end + 3)?;
            let minutes = digits(end + 4..end + 6)?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            let total = hours * 3600 + minutes * 60;
            if *sign == b'+' { total } else { -total }
        }
        _ => return None,
    };
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(seconds as f64 + millis as f64 / 1000.0)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub(crate) fn trimmed(text: &str) -> &str {
    text.trim()
}

/// Swift's `String.isHomeInternalID` (CmuxHomeCore `String+HomeInternalID.swift`): an owner's raw id
/// (`conv_…`, `user_…`, `agent_…`), never a name.
pub fn is_home_internal_id(text: &str) -> bool {
    const PREFIXES: &[&str] =
        &["addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm"];
    let Some((prefix, rest)) = text.split_once('_') else {
        return false;
    };
    PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Deserializes a field that may be any JSON: a wrong type reads as absent (Swift's `try?` decode).
pub(crate) fn lenient<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let value = Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).ok())
}
