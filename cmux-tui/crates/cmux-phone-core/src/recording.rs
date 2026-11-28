//! Recordings (Swift `PhoneRecorder`, `PhoneRecording`, `PhoneRecordingEvent`,
//! `PhoneInput.kind`/`requiredCapability`): what each input is called and
//! needs, the timed event it becomes, the one-at-a-time recorder state, and
//! the files a finished recording is written as. The app starts and stops
//! the video and log processes and writes the files Rust hands it.
use serde::{Deserialize, Serialize};

use crate::android::{AndroidInput, PhoneButton, swift_double};
use crate::devices::{PhoneDevice, PhoneDeviceId, PhoneDeviceState};

/// One input sent through cmux: the same shape the Android backend reads.
pub type PhoneInput = AndroidInput;

/// The short kind name used in `events.jsonl` ("tap", "swipe", ...).
pub fn kind(input: &PhoneInput) -> &'static str {
    match input {
        PhoneInput::Tap { .. } => "tap",
        PhoneInput::Swipe { .. } => "swipe",
        PhoneInput::Text { .. } => "text",
        PhoneInput::Button { .. } => "button",
        PhoneInput::OpenUrl { .. } => "open-url",
        PhoneInput::Pasteboard => "pasteboard",
        PhoneInput::Appearance { .. } => "appearance",
        PhoneInput::Location { .. } => "location",
        PhoneInput::Locale { .. } => "locale",
        PhoneInput::Install { .. } => "install",
        PhoneInput::Launch { .. } => "launch",
        PhoneInput::SoftwareKeyboard => "software-keyboard",
    }
}

/// The `PhoneCapabilities` bit the backend needs for this input.
pub fn required_capability(input: &PhoneInput) -> u64 {
    use crate::service::caps;
    match input {
        PhoneInput::Tap { .. } | PhoneInput::Swipe { .. } => caps::TOUCH,
        PhoneInput::Text { .. } => caps::KEYBOARD,
        PhoneInput::Button { .. } | PhoneInput::SoftwareKeyboard => caps::BUTTONS,
        PhoneInput::OpenUrl { .. } => caps::OPEN_URL,
        PhoneInput::Pasteboard => caps::PASTEBOARD,
        PhoneInput::Appearance { .. } => caps::APPEARANCE,
        PhoneInput::Location { .. } => caps::LOCATION,
        PhoneInput::Locale { .. } => caps::LOCALE,
        PhoneInput::Install { .. } | PhoneInput::Launch { .. } => caps::APPS,
    }
}

/// Swift `PhoneButton.rawValue`.
pub fn button_raw_value(button: PhoneButton) -> &'static str {
    match button {
        PhoneButton::Home => "home",
        PhoneButton::Lock => "lock",
        PhoneButton::VolumeUp => "volume-up",
        PhoneButton::VolumeDown => "volume-down",
        PhoneButton::Siri => "siri",
        PhoneButton::Back => "back",
        PhoneButton::AppSwitch => "app-switch",
    }
}

/// A point on the phone screen in device points, top-left origin.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PhonePoint {
    pub x: f64,
    pub y: f64,
}

/// One input sent through cmux during a recording, one line of
/// `events.jsonl`. Fields are in key order, as Swift's sorted-keys encoder
/// writes them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordingEvent {
    /// Seconds since the recording started; lines up with the video.
    pub at: f64,
    /// Text typed, URL opened or button pressed. Clipboard text is not kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub point: Option<PhonePoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<PhonePoint>,
}

/// `URL.lastPathComponent` of a file path.
fn last_path_component(path: &str) -> String {
    match path.split('/').rfind(|part| !part.is_empty()) {
        Some(part) => part.to_owned(),
        None if path.starts_with('/') => "/".to_owned(),
        None => String::new(),
    }
}

impl RecordingEvent {
    pub fn new(at: f64, input: &PhoneInput) -> Self {
        let mut event = RecordingEvent {
            at,
            detail: None,
            kind: kind(input).to_owned(),
            point: None,
            to: None,
        };
        match input {
            PhoneInput::Tap { x, y } => event.point = Some(PhonePoint { x: *x, y: *y }),
            PhoneInput::Swipe { from_x, from_y, to_x, to_y, .. } => {
                event.point = Some(PhonePoint { x: *from_x, y: *from_y });
                event.to = Some(PhonePoint { x: *to_x, y: *to_y });
            }
            PhoneInput::Text { text } => event.detail = Some(text.clone()),
            PhoneInput::Button { button } => {
                event.detail = Some(button_raw_value(*button).to_owned());
            }
            PhoneInput::OpenUrl { url } => event.detail = Some(url.clone()),
            PhoneInput::Pasteboard | PhoneInput::SoftwareKeyboard => {}
            PhoneInput::Appearance { dark } => {
                event.detail = Some(if *dark { "dark" } else { "light" }.to_owned());
            }
            PhoneInput::Location { latitude, longitude } => {
                event.detail =
                    Some(format!("{},{}", swift_double(*latitude), swift_double(*longitude)));
            }
            PhoneInput::Locale { identifier } => event.detail = Some(identifier.clone()),
            PhoneInput::Install { path } => event.detail = Some(last_path_component(path)),
            PhoneInput::Launch { package } => event.detail = Some(package.clone()),
        }
        event
    }
}

/// Seconds between two uptime readings (nanoseconds), to the millisecond, as
/// Swift's `Duration.components` arithmetic gives them.
pub fn elapsed_seconds(started_nanos: i64, now_nanos: i64) -> f64 {
    let elapsed = i128::from(now_nanos) - i128::from(started_nanos);
    let whole = elapsed.div_euclid(1_000_000_000);
    let atto = elapsed.rem_euclid(1_000_000_000) * 1_000_000_000;
    let seconds = whole as f64 + atto as f64 / 1e18;
    (seconds * 1000.0).round() / 1000.0
}

/// The video file name: `screen.mp4` for real iPhones and Android, else `screen.mov`.
pub fn video_file(id: &PhoneDeviceId) -> String {
    format!("screen.{}", crate::service::video_extension(id.mode))
}

pub const LOG_FILE: &str = "device-log.ndjson";
pub const POSTER_FILE: &str = "poster.png";
pub const EVENTS_FILE: &str = "events.jsonl";
pub const NOTES_FILE: &str = "notes.md";
pub const MANIFEST_FILE: &str = "manifest.json";

/// A finished (or running) recording; the folder stays the app's.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Recording {
    pub id: String,
    pub device: PhoneDevice,
    /// ISO 8601, as the app formats it.
    pub started_at: String,
    /// Seconds; zero while running.
    pub duration: f64,
    pub video: String,
    #[serde(default)]
    pub log: Option<String>,
    #[serde(default)]
    pub poster: Option<String>,
    #[serde(default)]
    pub events: Vec<RecordingEvent>,
    #[serde(default)]
    pub notes: String,
}

/// The recorder's state between calls: the running recording and the uptime
/// it started at. The app keeps it and passes it back.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Recorder {
    pub recording: Recording,
    pub started_nanos: i64,
}

/// Why a recorder call cannot go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecorderError {
    AlreadyRecording,
    NotRecording,
}

impl RecorderError {
    pub fn kind(self) -> &'static str {
        match self {
            Self::AlreadyRecording => "already_recording",
            Self::NotRecording => "not_recording",
        }
    }
}

/// The files a new recording writes into: the video, and the log when the
/// device streams one. Refused while another recording runs.
pub fn plan(
    active: bool,
    id: &PhoneDeviceId,
    capabilities: u64,
) -> Result<(String, Option<&'static str>), RecorderError> {
    if active {
        return Err(RecorderError::AlreadyRecording);
    }
    let log = (capabilities & crate::service::caps::DEVICE_LOG != 0).then_some(LOG_FILE);
    Ok((video_file(id), log))
}

/// The recorder once the video (and maybe the log) started.
pub fn begin(
    id: String,
    device: PhoneDevice,
    started_at: String,
    video: String,
    log: Option<String>,
    uptime_nanos: i64,
) -> Recorder {
    Recorder {
        recording: Recording {
            id,
            device,
            started_at,
            duration: 0.0,
            video,
            log,
            poster: None,
            events: Vec::new(),
            notes: String::new(),
        },
        started_nanos: uptime_nanos,
    }
}

/// Logs an input sent to the recorded phone; false (and unchanged) for another phone.
pub fn note(
    recorder: &mut Recorder,
    input: &PhoneInput,
    device_id: &str,
    uptime_nanos: i64,
) -> bool {
    if recorder.recording.device.id != device_id {
        return false;
    }
    let at = elapsed_seconds(recorder.started_nanos, uptime_nanos);
    recorder.recording.events.push(RecordingEvent::new(at, input));
    true
}

/// The stopped recording, with its length and notes; no poster yet.
pub fn stop(
    recorder: Option<Recorder>,
    notes: String,
    uptime_nanos: i64,
) -> Result<Recording, RecorderError> {
    let Some(recorder) = recorder else { return Err(RecorderError::NotRecording) };
    let mut recording = recorder.recording;
    recording.duration = elapsed_seconds(recorder.started_nanos, uptime_nanos);
    recording.notes = notes;
    Ok(recording)
}

/// `20261019-174203-1a2b`: the local time, then the first four characters of
/// a UUID, lowercased. Sorts by time, unique enough for one Mac.
pub fn recording_id(time: [u32; 6], uuid: &str) -> String {
    let [year, month, day, hour, minute, second] = time;
    let suffix: String = uuid.chars().take(4).collect::<String>().to_lowercase();
    format!("{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}-{suffix}")
}

// The manifest on disk is Swift's Codable shape (camelCase keys, the state as
// `{"ready":{}}`), so recordings written before and after the move read alike.

#[derive(Serialize, Deserialize)]
struct ManifestDevice {
    id: String,
    model: String,
    name: String,
    #[serde(rename = "osVersion")]
    os_version: String,
    state: ManifestState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transport: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ManifestState {
    Shutdown {},
    Booting {},
    Ready {},
    Disconnected {},
    Unavailable { reason: String },
}

#[derive(Serialize, Deserialize)]
struct Manifest {
    device: ManifestDevice,
    duration: f64,
    events: Vec<RecordingEvent>,
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    log: Option<String>,
    notes: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    poster: Option<String>,
    #[serde(rename = "startedAt")]
    started_at: String,
    video: String,
}

impl From<&PhoneDeviceState> for ManifestState {
    fn from(state: &PhoneDeviceState) -> Self {
        match state {
            PhoneDeviceState::Shutdown => Self::Shutdown {},
            PhoneDeviceState::Booting => Self::Booting {},
            PhoneDeviceState::Ready => Self::Ready {},
            PhoneDeviceState::Disconnected => Self::Disconnected {},
            PhoneDeviceState::Unavailable { reason } => {
                Self::Unavailable { reason: reason.clone() }
            }
        }
    }
}

impl From<ManifestState> for PhoneDeviceState {
    fn from(state: ManifestState) -> Self {
        match state {
            ManifestState::Shutdown {} => Self::Shutdown,
            ManifestState::Booting {} => Self::Booting,
            ManifestState::Ready {} => Self::Ready,
            ManifestState::Disconnected {} => Self::Disconnected,
            ManifestState::Unavailable { reason } => Self::Unavailable { reason },
        }
    }
}

/// The three files `stop` writes besides the media: `manifest.json`
/// (pretty, sorted keys), `events.jsonl` (one sorted-keys line per event)
/// and `notes.md`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RecordingFiles {
    pub manifest: String,
    pub events_jsonl: String,
    pub notes_md: String,
}

pub fn files(recording: &Recording) -> RecordingFiles {
    let device = &recording.device;
    let manifest = Manifest {
        device: ManifestDevice {
            id: device.id.clone(),
            model: device.model.clone(),
            name: device.name.clone(),
            os_version: device.os_version.clone(),
            state: (&device.state).into(),
            transport: device.transport.clone(),
        },
        duration: recording.duration,
        events: recording.events.clone(),
        id: recording.id.clone(),
        log: recording.log.clone(),
        notes: recording.notes.clone(),
        poster: recording.poster.clone(),
        started_at: recording.started_at.clone(),
        video: recording.video.clone(),
    };
    let mut events_jsonl = String::new();
    for event in &recording.events {
        // A struct of strings and numbers always serializes.
        events_jsonl.push_str(&serde_json::to_string(event).unwrap_or_default());
        events_jsonl.push('\n');
    }
    RecordingFiles {
        manifest: serde_json::to_string_pretty(&manifest).unwrap_or_default(),
        events_jsonl,
        notes_md: recording.notes.clone(),
    }
}

/// Reads `manifest.json` back; Err names what did not read.
pub fn read_manifest(manifest: &[u8]) -> Result<Recording, String> {
    let manifest: Manifest = serde_json::from_slice(manifest).map_err(|error| error.to_string())?;
    if PhoneDeviceId::parse(&manifest.device.id).is_none() {
        return Err(format!("not a phone id: {}", manifest.device.id));
    }
    Ok(Recording {
        id: manifest.id,
        device: PhoneDevice {
            id: manifest.device.id,
            name: manifest.device.name,
            model: manifest.device.model,
            os_version: manifest.device.os_version,
            state: manifest.device.state.into(),
            transport: manifest.device.transport,
        },
        started_at: manifest.started_at,
        duration: manifest.duration,
        video: manifest.video,
        log: manifest.log,
        poster: manifest.poster,
        events: manifest.events,
        notes: manifest.notes,
    })
}
