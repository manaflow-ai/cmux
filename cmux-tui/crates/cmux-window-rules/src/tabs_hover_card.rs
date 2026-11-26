//! What a tab's hover card says, row by row (`TabHoverCardLines`): the
//! title; where the tab is (a page's host, a folder and branch, its badges);
//! what it is doing and for how long; the program's own status words; its
//! memory. The answer names each row's words by key and carries the numbers;
//! the app picks the localized text and formats bytes, CPU and durations.

use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// CPU of at least half a core is worth naming next to the memory; less is noise.
pub const NOTABLE_CPU: f64 = 0.5;
/// Output this recent reads as "Output · 12s"; older, the shell reads as "Idle · 5m".
pub const RECENT_OUTPUT: f64 = 60.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    #[default]
    Other,
    Terminal,
    Browser,
    AgentChat,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Activity {
    Working,
    NeedsInput,
    Idle,
    Failed,
    Running,
    Done,
}

/// The tab's status mark (`TabStatus`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    #[default]
    None,
    NeedsInput,
    Success,
    Failure,
}

/// The facts of one tab the card reads (`TabItem` and its `TabHoverFacts`).
/// Times are seconds on one clock (the app sends Foundation reference dates).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Item {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    /// A browser tab's subtitle's host as the app's URL parser reads it
    /// (`TabHoverCardLines.host`); read only for a browser tab.
    pub host: Option<String>,
    pub kind: Kind,
    pub activity: Option<Activity>,
    pub since: Option<f64>,
    pub model: Option<String>,
    pub branch: Option<String>,
    pub last_output: Option<f64>,
    pub former_name: Option<String>,
    pub status: Status,
    pub status_detail: Option<String>,
    /// The browser profile badge's name.
    pub profile_badge: Option<String>,
    pub machine_badge_help: Option<String>,
    /// The theme badge's name.
    pub theme_badge: Option<String>,
    pub is_dormant: bool,
}

/// One tab's resource sample (`TabResourceReport`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Sample {
    pub id: String,
    pub available: bool,
    pub process_count: i64,
    pub memory_bytes: u64,
    pub cpu: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Title {
    /// `Strings.untitled`.
    Untitled,
    /// `Strings.formerlyKnownAs(title, former:)`.
    Formerly {
        title: String,
        former: String,
    },
    Plain {
        title: String,
    },
}

/// One part of the place row, joined with " · ".
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum PlacePart {
    /// `Strings.browserProfile(name)`.
    Profile {
        name: String,
    },
    Machine {
        text: String,
    },
    /// `Strings.axTheme(name)`.
    Theme {
        name: String,
    },
    /// The host, or the folder and branch joined with " · ".
    Where {
        text: String,
    },
}

/// A status row's word.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Word {
    /// `Strings.hoverWorking`.
    Working,
    /// `Strings.axNeedsInput`.
    NeedsInput,
    /// `Strings.hoverIdle`.
    Idle,
    /// `Strings.axFailure`.
    Failure,
    /// `Strings.axBusy`.
    Busy,
    /// `Strings.axSuccess`.
    Success,
    /// `Strings.hoverOutput`.
    Output,
}

/// The status row: its parts in order, joined with " · ". `elapsed` is
/// whole seconds, at least one, for the app's abbreviated one-unit format.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusLine {
    pub word: Option<Word>,
    pub elapsed: Option<f64>,
    pub model: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Memory {
    /// `Strings.hoverHibernated`.
    Hibernated,
    /// `Strings.hoverHibernatedWasUsing(memory)`.
    HibernatedWasUsing { bytes: u64 },
    /// `Strings.hoverMemory("–")`: nothing measured yet.
    Dash,
    /// `Strings.hoverMemory(memory)`.
    Memory { bytes: u64 },
    /// `Strings.hoverMemoryCPU(memory, cpu)`.
    MemoryCpu { bytes: u64, cpu: f64 },
}

/// The color of the status row's dot (`HoverCardTone`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Tone {
    Working,
    Attention,
    Danger,
    Secondary,
    Success,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Lines {
    pub title: Title,
    pub place: Option<Vec<PlacePart>>,
    pub status: Option<StatusLine>,
    pub detail: Option<String>,
    pub memory: Option<Memory>,
    pub tone: Option<Tone>,
}

/// The card of `item`. `report` is the tab's latest sample, or for a
/// hibernated page the last one before it hibernated.
pub fn make(item: &Item, report: Option<&[Sample]>, now: f64) -> Lines {
    // A folder the title already names (a shell at `~` titled `~`) is said once.
    let folder = match &item.subtitle {
        Some(subtitle) if same(subtitle, &item.title) => None,
        other => other.as_deref(),
    };
    let where_ = if item.kind == Kind::Browser {
        item.subtitle.as_ref().and(item.host.clone())
    } else {
        joined([folder, item.branch.as_deref()])
    };
    let mut place = Vec::new();
    if let Some(name) = &item.profile_badge {
        place.push(PlacePart::Profile { name: name.clone() });
    }
    if let Some(text) = item.machine_badge_help.as_ref().filter(|t| !t.is_empty()) {
        place.push(PlacePart::Machine { text: text.clone() });
    }
    if let Some(name) = &item.theme_badge {
        place.push(PlacePart::Theme { name: name.clone() });
    }
    if let Some(text) = where_.filter(|t| !t.is_empty()) {
        place.push(PlacePart::Where { text });
    }
    Lines {
        title: title(item),
        place: (!place.is_empty()).then_some(place),
        status: status(item, now).or_else(|| exit_status(item)).or_else(|| output(item, now)),
        detail: item.status_detail.clone().filter(|d| !d.is_empty()),
        memory: memory(item, report),
        tone: tone(item),
    }
}

/// The tab's title; a blank page's address is no title.
pub fn title(item: &Item) -> Title {
    if item.title.is_empty() || (item.kind == Kind::Browser && is_blank(&item.title)) {
        return Title::Untitled;
    }
    if let Some(former) = &item.former_name
        && !former.is_empty()
        && !same(former, &item.title)
    {
        return Title::Formerly { title: item.title.clone(), former: former.clone() };
    }
    Title::Plain { title: item.title.clone() }
}

/// An `about:` address (`about:blank`), which names no page. Swift's
/// `hasPrefix` matches whole characters: a mark on the colon is no `about:`.
pub fn is_blank(address: &str) -> bool {
    let lower = address.to_lowercase();
    let mut clusters = lower.graphemes(true);
    "about:".chars().all(|c| {
        clusters.next().is_some_and(|g| {
            let mut buf = [0u8; 4];
            same(g, c.encode_utf8(&mut buf))
        })
    })
}

/// The color of what the tab is doing, None when it reports nothing.
pub fn tone(item: &Item) -> Option<Tone> {
    match item.activity {
        Some(Activity::Working | Activity::Running) => return Some(Tone::Working),
        Some(Activity::NeedsInput) => return Some(Tone::Attention),
        Some(Activity::Failed) => return Some(Tone::Danger),
        Some(Activity::Idle) => return Some(Tone::Secondary),
        Some(Activity::Done) => return Some(Tone::Success),
        None => {}
    }
    match item.status {
        Status::Failure => Some(Tone::Danger),
        Status::Success => Some(Tone::Success),
        Status::NeedsInput => Some(Tone::Attention),
        Status::None => item.last_output.map(|_| Tone::Secondary),
    }
}

/// "Working · 3m · Opus 5.5"; None for a tab doing nothing it reports.
pub fn status(item: &Item, now: f64) -> Option<StatusLine> {
    let word = item.activity.map(|activity| match activity {
        Activity::Working => Word::Working,
        Activity::NeedsInput => Word::NeedsInput,
        Activity::Idle => Word::Idle,
        Activity::Failed => Word::Failure,
        Activity::Running => Word::Busy,
        Activity::Done => Word::Success,
    });
    let elapsed = word.and(item.since).map(|since| elapsed(since, now));
    let model = item.model.clone().filter(|m| !m.is_empty());
    if word.is_none() && elapsed.is_none() && model.is_none() {
        return None;
    }
    Some(StatusLine { word, elapsed, model })
}

/// A plain shell at its prompt: "Output · 12s" when it printed under
/// `RECENT_OUTPUT` ago, "Idle · 5m" after.
pub fn output(item: &Item, now: f64) -> Option<StatusLine> {
    let at = item.last_output?;
    let word = if now - at < RECENT_OUTPUT { Word::Output } else { Word::Idle };
    Some(StatusLine { word: Some(word), elapsed: Some(elapsed(at, now)), model: None })
}

/// A terminal whose last command ended: "Done" or "Failed".
pub fn exit_status(item: &Item) -> Option<StatusLine> {
    if item.kind != Kind::Terminal {
        return None;
    }
    let word = match item.status {
        Status::Success => Word::Success,
        Status::Failure => Word::Failure,
        Status::None | Status::NeedsInput => return None,
    };
    Some(StatusLine { word: Some(word), elapsed: None, model: None })
}

/// The memory row; None only for a kind of tab that has no memory row.
/// Whether the row shows depends on the tab, never on a sample.
pub fn memory(item: &Item, report: Option<&[Sample]>) -> Option<Memory> {
    let tab = report.and_then(|tabs| tabs.iter().find(|t| t.id == item.id));
    if item.is_dormant {
        return Some(match tab {
            Some(tab) if measured(tab) && tab.memory_bytes > 0 => {
                Memory::HibernatedWasUsing { bytes: tab.memory_bytes }
            }
            _ => Memory::Hibernated,
        });
    }
    if item.kind == Kind::Other {
        return None;
    }
    let Some(tab) = tab.filter(|t| measured(t)) else { return Some(Memory::Dash) };
    Some(match tab.cpu {
        Some(cpu) if cpu >= NOTABLE_CPU => Memory::MemoryCpu { bytes: tab.memory_bytes, cpu },
        _ => Memory::Memory { bytes: tab.memory_bytes },
    })
}

/// Whether a sample measured the tab's own processes.
pub fn measured(tab: &Sample) -> bool {
    tab.available && tab.process_count > 0
}

/// Whole seconds since `date`, at least one, also for a start ahead of the clock.
pub fn elapsed(date: f64, now: f64) -> f64 {
    (now - date).floor().max(1.0)
}

fn joined<'a>(parts: impl IntoIterator<Item = Option<&'a str>>) -> Option<String> {
    let parts: Vec<&str> = parts.into_iter().flatten().filter(|p| !p.is_empty()).collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// Swift's `String ==`: canonical equivalence.
fn same(a: &str, b: &str) -> bool {
    a == b || a.nfd().eq(b.nfd())
}

#[cfg(test)]
#[path = "tabs_hover_card_tests.rs"]
mod tests;
