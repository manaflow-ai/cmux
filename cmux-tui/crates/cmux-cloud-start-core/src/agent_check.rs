//! Whether a Cloud start's agent can run, asked before any machine is made or claimed (red 1 of
//! the Cloud composer journey, 2026-11-10: a start leased a machine, then its Claude answered
//! "You've hit your weekly limit · resets Nov 14, 1pm (UTC)", so every start paid for a machine its
//! agent could not use). Leo, 2026-11-10: "i already told you to test these".
//!
//! The app gives a Claude start the person's own Claude login (`harness_login`). Before the lease it
//! asks Anthropic once with that login for the cheapest possible answer (one token of the smallest
//! model) and hands this module the reply's status and its `anthropic-ratelimit-unified-*` headers,
//! the same headers Claude Code turns into its `rate_limit_event`. [`check`] reads them: a login
//! whose limit is used up refuses the start at once, naming the window, when it resets, and what to
//! do instead. Anything else (an allowed answer, a login the provider rejected, a reply with no
//! limit headers, a probe that never answered) lets the start go on: this check only ever
//! refuses a start it knows cannot run.
//!
//! Pure, as the rest of this crate: the app makes the request and asks here.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The header prefix Anthropic reports a subscription login's limits under.
const UNIFIED: &str = "anthropic-ratelimit-unified-";

/// How long an answer that the limit is not used up stands before the next start asks again.
pub const ALLOWED_FRESH_SECONDS: i64 = 5 * 60;
/// How long a used-up answer with no reset time stands.
pub const SPENT_UNKNOWN_RESET_SECONDS: i64 = 15 * 60;

/// The refusal's code, beside the copy cap's `copy.too_large`.
pub const CODE: &str = "agent.limit_reached";

/// The limit window a used-up answer names (Claude Code's `rateLimitType` words).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Window {
    /// `five_hour`.
    Session,
    /// `seven_day`.
    Weekly,
    /// `seven_day_opus`.
    WeeklyOpus,
    /// `seven_day_sonnet`.
    WeeklySonnet,
    /// A claim this crate does not know, or none.
    Unknown,
}

impl Window {
    fn from_claim(claim: &str) -> Self {
        match claim.trim() {
            "five_hour" => Self::Session,
            "seven_day" => Self::Weekly,
            "seven_day_opus" => Self::WeeklyOpus,
            "seven_day_sonnet" => Self::WeeklySonnet,
            _ => Self::Unknown,
        }
    }

    /// The header infix of this window's own reset (`5h`, `7d`), when it has one. A model's own weekly
    /// window has none: its reset is the unified one, which is the representative claim's.
    fn infix(self) -> Option<&'static str> {
        match self {
            Self::Session => Some("5h"),
            Self::Weekly => Some("7d"),
            Self::WeeklyOpus | Self::WeeklySonnet | Self::Unknown => None,
        }
    }

    /// Whether a used-up window stops a start of `model` (the start's `--model` or the composer's pick;
    /// None: the harness default). A model's own weekly window stops only a start of that model; one
    /// whose model is unknown goes on, since this check never refuses a start that could run.
    fn stops(self, model: Option<&str>) -> bool {
        let family = |name: &str| model.is_some_and(|m| m.to_ascii_lowercase().contains(name));
        match self {
            Self::WeeklyOpus => family("opus"),
            Self::WeeklySonnet => family("sonnet"),
            Self::Session | Self::Weekly | Self::Unknown => true,
        }
    }

    /// The window in the refusal's words.
    fn words(self) -> &'static str {
        match self {
            Self::Session => "5-hour limit",
            Self::Weekly => "weekly limit",
            Self::WeeklyOpus => "weekly Opus limit",
            Self::WeeklySonnet => "weekly Sonnet limit",
            Self::Unknown => "usage limit",
        }
    }
}

/// The probe's reply: its HTTP status and its headers (any case; only the unified ones are read).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Probe {
    pub status: u16,
    pub headers: BTreeMap<String, String>,
}

/// A used-up limit: which window, and when it resets (unix seconds), if the reply said.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limit {
    pub window: Window,
    pub resets_at: Option<i64>,
}

/// The used-up limit `probe` reports, or None when it reports none (or no limits at all).
///
/// Used up: the unified status is `rejected`, or the reply is a 429 carrying unified headers. The
/// window is the reply's representative claim, else the first of the 7-day and 5-hour windows whose
/// own status is `rejected`. The reset is that window's own (a model's weekly window has none), else
/// the unified one.
pub fn limit(probe: &Probe) -> Option<Limit> {
    let unified: BTreeMap<String, &str> = probe
        .headers
        .iter()
        .filter_map(|(k, v)| {
            let k = k.trim().to_ascii_lowercase();
            k.strip_prefix(UNIFIED).map(|rest| (rest.to_owned(), v.trim()))
        })
        .collect();
    if unified.is_empty() {
        return None;
    }
    let status = unified.get("status").copied().unwrap_or("");
    if status != "rejected" && probe.status != 429 {
        return None;
    }
    let claimed = unified.get("representative-claim").map(|c| Window::from_claim(c));
    let window = match claimed {
        Some(window) if window != Window::Unknown => window,
        _ if unified.get("7d-status").copied() == Some("rejected") => Window::Weekly,
        _ if unified.get("5h-status").copied() == Some("rejected") => Window::Session,
        _ => Window::Unknown,
    };
    let seconds =
        |key: &str| unified.get(key).and_then(|v| v.parse::<i64>().ok()).filter(|t| *t > 0);
    let resets_at = window
        .infix()
        .and_then(|infix| seconds(&format!("{infix}-reset")))
        .or_else(|| seconds("reset"));
    Some(Limit { window, resets_at })
}

/// What [`check`] reads: the start's agent (as `harness_login::login_provider` reads it) and model
/// (None: the harness default), the probe's reply when the app made one, and the time now (unix
/// seconds).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Request {
    pub harness: Option<String>,
    pub model: Option<String>,
    pub probe: Option<Probe>,
    pub now: i64,
}

/// A start refused before its lease: a code and the person's words (what is wrong, and what to do).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refusal {
    pub code: String,
    pub message: String,
}

/// [`check`]'s answer: the refusal (None: start), the limit it read, and until when (unix seconds) the
/// app may answer the same without asking Anthropic again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub refusal: Option<Refusal>,
    pub limit: Option<Limit>,
    pub fresh_until: i64,
}

/// Whether a start of `harness` asks Anthropic before its lease: a Claude start only.
pub fn probes(harness: Option<&str>) -> bool {
    crate::harness_login::login_provider(harness) == Some(crate::harness_login::Provider::Claude)
}

/// The start's answer. A Claude start whose probe reports a used-up limit that has not reset yet,
/// in a window that stops its model ([`Window::stops`]), is refused; every other start goes on.
pub fn check(request: &Request) -> Answer {
    let found = request
        .probe
        .as_ref()
        .filter(|_| probes(request.harness.as_deref()))
        .and_then(limit)
        .filter(|l| l.resets_at.is_none_or(|at| at > request.now))
        .filter(|l| l.window.stops(request.model.as_deref()));
    let Some(found) = found else {
        let fresh_until =
            if request.probe.is_some() { request.now + ALLOWED_FRESH_SECONDS } else { request.now };
        return Answer { refusal: None, limit: None, fresh_until };
    };
    let message = match found.resets_at {
        Some(at) => format!(
            "Claude's {} is used up until {}. Pick Codex, or start after then.",
            found.window.words(),
            utc_words(at, request.now)
        ),
        None => format!(
            "Claude's {} is used up. Pick Codex, or start once it resets.",
            found.window.words()
        ),
    };
    Answer {
        refusal: Some(Refusal { code: CODE.to_owned(), message }),
        limit: Some(found),
        fresh_until: found.resets_at.unwrap_or(request.now + SPENT_UNKNOWN_RESET_SECONDS),
    }
}

const MONTHS: [&str; 12] =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// `at` (unix seconds) as Claude Code says a reset, in UTC: "Nov 14, 1pm UTC", "Nov 14, 1:30pm
/// UTC"; the day is left out when `at` is on the same UTC day as `now` ("3pm UTC").
pub fn utc_words(at: i64, now: i64) -> String {
    let (_, month, day) = civil(at.div_euclid(86_400));
    let same_day = at.div_euclid(86_400) == now.div_euclid(86_400);
    let seconds = at.rem_euclid(86_400);
    let (hour, minute) = (seconds / 3600, (seconds % 3600) / 60);
    let (twelve, half) = match hour {
        0 => (12, "am"),
        1..=11 => (hour, "am"),
        12 => (12, "pm"),
        _ => (hour - 12, "pm"),
    };
    let time =
        if minute == 0 { format!("{twelve}{half}") } else { format!("{twelve}:{minute:02}{half}") };
    if same_day {
        format!("{time} UTC")
    } else {
        let name = MONTHS.get(usize::try_from(month - 1).unwrap_or(0)).copied().unwrap_or("Jan");
        format!("{name} {day}, {time} UTC")
    }
}

/// The proleptic Gregorian (year, month 1-12, day 1-31) of `days` since 1970-01-01 (Howard
/// Hinnant's `civil_from_days`).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests;
