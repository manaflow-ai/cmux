//! The Chief's computer in the profile: the control bar's line (`HomeChiefComputerControlBar.swift`) and the
//! Computer section's rules (`HomeChiefComputerSection.swift`): whether it shows, the note on its screen and
//! when it reads the computer again. The reads, the feed and the drawing stay in Swift.

use super::format;
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// A new frame about once a second while the computer runs.
pub const FRAME_INTERVAL_MS: u64 = 900;
/// The state is read again this often while the card is open.
pub const STATUS_INTERVAL_MS: u64 = 8000;

/// The computer section's texts (`home.engine.computer.*`), over the English ones.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Texts {
    /// `home.engine.computer.chiefDriving` (`%@ is using the computer`).
    pub chief_driving_format: String,
    pub you_drive: String,
    pub connecting: String,
    pub unavailable: String,
    pub asleep: String,
    pub waking: String,
}

impl Default for Texts {
    fn default() -> Self {
        Texts {
            chief_driving_format: "%@ is using the computer".into(),
            you_drive: "You\u{2019}re in control".into(),
            connecting: "Connecting\u{2026}".into(),
            unavailable: "Computer isn\u{2019}t available".into(),
            asleep: "Computer is asleep".into(),
            waking: "Waking up\u{2026}".into(),
        }
    }
}

fn texts(request: &Value) -> Texts {
    request.get("strings").and_then(|value| Texts::deserialize(value).ok()).unwrap_or_default()
}

/// Who holds the computer's lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Holder {
    Chief,
    Human,
}

/// The lease as the owner reports it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Control {
    pub holder: Holder,
    #[serde(default)]
    pub reason: Option<String>,
}

/// The bar's one button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    TakeOver,
    GiveBack,
}

/// What the control bar shows.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Line {
    pub status: String,
    pub action: Action,
}

/// The bar's line for `control` (nil: not known yet). The Chief's own reason, when it asked the person to
/// take over, stands in place of "You're in control".
pub fn control_line(control: Option<&Control>, chief: &str, texts: &Texts) -> Option<Line> {
    let control = control?;
    Some(match control.holder {
        Holder::Chief => {
            Line { status: format(&texts.chief_driving_format, &[chief]), action: Action::TakeOver }
        }
        Holder::Human => {
            let reason = control.reason.as_deref().unwrap_or("").trim();
            let status =
                if reason.is_empty() { texts.you_drive.clone() } else { reason.to_string() };
            Line { status, action: Action::GiveBack }
        }
    })
}

/// The computer's state on the card.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Live,
    Unavailable,
    Asleep,
    Waking,
}

/// The parts of a status read the section keeps.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Status {
    pub entitled: Option<bool>,
    pub provisioning: bool,
    pub provision_error: Option<Value>,
}

/// What the section knows between reads.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Section {
    pub entitled: bool,
    pub provisioning: bool,
    pub provision_failed: bool,
}

/// What the section shows after a read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Shows {
    /// Hidden.
    Hidden,
    /// The shown computer again, as unavailable (a failed read keeps a shown section).
    KeepUnavailable,
    /// The computer the status describes (`HomeChiefComputer(status:paid:chief:)`).
    FromStatus,
}

/// After a status read (`status` nil: the read failed): what the section keeps and what it shows.
pub fn section_after(
    section: Section,
    status: Option<&Status>,
    paid: bool,
    shown: bool,
) -> (Section, Shows) {
    let mut section = section;
    if let Some(status) = status {
        section.entitled = status.entitled.unwrap_or(section.entitled);
        section.provisioning = status.provisioning;
        section.provision_failed =
            status.provision_error.as_ref().is_some_and(|error| !error.is_null());
    }
    let shows = if !(paid || section.entitled) {
        Shows::Hidden
    } else if status.is_none() {
        if shown { Shows::KeepUnavailable } else { Shows::Hidden }
    } else {
        Shows::FromStatus
    };
    (section, shows)
}

/// What the screen says, and its sleeping face.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub note: Option<String>,
    pub sleep_face: bool,
    pub awake: bool,
}

/// The note on the screen for `state`: "Connecting…" while it runs with no frame and no live feed yet.
pub fn note(state: State, has_image: bool, feed_live: bool, texts: &Texts) -> Note {
    let note = match state {
        State::Live => (!has_image && !feed_live).then(|| texts.connecting.clone()),
        State::Unavailable => Some(texts.unavailable.clone()),
        State::Asleep => Some(texts.asleep.clone()),
        State::Waking => Some(texts.waking.clone()),
    };
    Note {
        note,
        sleep_face: matches!(state, State::Asleep | State::Waking),
        awake: state == State::Waking,
    }
}

/// One read's plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Poll {
    /// Whether this read asks for the status (8 s since the last; nil: now).
    pub reads_status: bool,
    /// The wait before the next read.
    pub wait_ms: u64,
    /// The time since the status read that the next read starts from.
    pub next_since_ms: u64,
}

/// The status is read when 8 s have passed since the last (`since` nil: now). While the computer runs
/// and its screen is on show, the next read comes after a frame's 900 ms, else after 8 s. `live` is the
/// state after this read's status.
pub fn poll(since_ms: Option<u64>, live: bool, watches_screen: bool) -> Poll {
    let since = since_ms.unwrap_or(STATUS_INTERVAL_MS);
    let reads_status = since >= STATUS_INTERVAL_MS;
    let wait_ms = if live && watches_screen { FRAME_INTERVAL_MS } else { STATUS_INTERVAL_MS };
    let next_since_ms = if reads_status { 0 } else { since } + wait_ms;
    Poll { reads_status, wait_ms, next_since_ms }
}

// MARK: Ops

#[derive(Deserialize, Default)]
#[serde(default)]
struct LineRequest {
    control: Option<Control>,
    chief: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SectionRequest {
    section: Section,
    status: Option<Status>,
    paid: bool,
    shown: bool,
}

#[derive(Serialize)]
struct SectionReply {
    section: Section,
    shows: Shows,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteRequest {
    state: State,
    #[serde(default)]
    has_image: bool,
    #[serde(default)]
    feed_live: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PollRequest {
    since_ms: Option<u64>,
    live: bool,
    watches_screen: bool,
}

impl Default for PollRequest {
    fn default() -> Self {
        PollRequest { since_ms: None, live: false, watches_screen: true }
    }
}

fn object(request: &Value) -> Value {
    if request.is_null() { Value::Object(Map::new()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let request = &object(request);
    match name {
        "controlLine" => {
            let parsed: LineRequest = ops::parse(request)?;
            ops::reply(&control_line(parsed.control.as_ref(), &parsed.chief, &texts(request)))
        }
        "computerSection" => {
            let parsed: SectionRequest = ops::parse(request)?;
            let (section, shows) =
                section_after(parsed.section, parsed.status.as_ref(), parsed.paid, parsed.shown);
            ops::reply(&SectionReply { section, shows })
        }
        "computerNote" => {
            let parsed: NoteRequest = ops::parse(request)?;
            ops::reply(&note(parsed.state, parsed.has_image, parsed.feed_live, &texts(request)))
        }
        "computerPoll" => {
            let parsed: PollRequest = ops::parse(request)?;
            ops::reply(&poll(parsed.since_ms, parsed.live, parsed.watches_screen))
        }
        _ => Err(OpError::Unknown),
    }
}
