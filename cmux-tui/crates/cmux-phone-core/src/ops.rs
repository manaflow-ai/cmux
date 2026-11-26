//! The JSON door: one request with an `op` field, one reply. Failures the app
//! shows come back as `{"error": KIND, ...}` replies; only a request that does
//! not decode is an `Err`.
use serde::Deserialize;
use serde_json::{Value, json};

use crate::devices::{PhoneDevice, PhoneDeviceId, PhoneMode};
use crate::recording::{PhoneInput, Recorder, Recording};
use crate::{
    android, devices, feedback, input, log_tail, recording, replica, service, uiautomator,
};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    /// `xcrun simctl list devices --json` output.
    SimctlDevices {
        output: String,
    },
    /// `xcrun devicectl list devices --json-output` file contents.
    DevicectlDevices {
        output: String,
    },
    /// Parses a phone id ("sim:UDID").
    PhoneId {
        id: String,
    },
    CapabilityNames {
        bits: u64,
    },
    /// `adb devices -l` output.
    AdbDevices {
        output: String,
    },
    /// `emulator -list-avds` output.
    AvdNames {
        output: String,
    },
    /// `adb emu avd name` output.
    AvdName {
        output: String,
    },
    AvdDisplayName {
        avd: String,
    },
    UsbModel {
        entry: android::AdbEntry,
    },
    /// `wm density` output.
    PixelsPerDp {
        output: String,
    },
    /// `wm size` output, the rotation (`settings get system user_rotation`) and
    /// the density; answers the screen in dp.
    ScreenPoints {
        size_output: String,
        density_output: String,
        rotation: Option<String>,
    },
    /// `cmd uimode night` output.
    NightMode {
        output: String,
    },
    FreeEmulatorPort {
        serials: Vec<String>,
    },
    AndroidInputCalls {
        input: android::AndroidInput,
        emulator: bool,
        scale: f64,
    },
    KeyStrokes {
        text: String,
    },
    MacKeyUsage {
        code: u16,
    },
    Tap {
        screen: (f64, f64),
        point: (f64, f64),
    },
    Swipe {
        screen: (f64, f64),
        from: (f64, f64),
        to: (f64, f64),
        seconds: f64,
    },
    DrawnRect {
        screen: (f64, f64),
        view: (f64, f64),
    },
    DevicePoint {
        screen: (f64, f64),
        view: (f64, f64),
        point: (f64, f64),
    },
    NormalizedViewPoint {
        screen: (f64, f64),
        view: (f64, f64),
        point: (f64, f64),
    },
    LogTail {
        ndjson: String,
        limit: usize,
    },
    UiautomatorTree {
        output: String,
        pixels_per_point: f64,
    },
    /// What a phone of `mode` can do (`live_input`: SimulatorKit's HID
    /// loaded; `android`: the Android SDK found).
    Capabilities {
        mode: PhoneMode,
        #[serde(default)]
        live_input: bool,
        #[serde(default)]
        android: bool,
    },
    /// An input's kind and the capability bit it needs; with `capabilities`,
    /// whether it may go to the phone `id`.
    InputCheck {
        input: PhoneInput,
        id: String,
        capabilities: u64,
    },
    /// A drag on the still frame (0...1 units) as a tap or swipe.
    TouchInput {
        screen: (f64, f64),
        from: (f64, f64),
        to: (f64, f64),
        seconds: f64,
    },
    /// The phone a command uses when none is named.
    DefaultDevice {
        #[serde(default)]
        recording: Option<PhoneDevice>,
        devices: Vec<PhoneDevice>,
    },
    /// A log command's argv as one shell line.
    ShellLine {
        argv: Vec<String>,
    },
    /// The still frame's file name for a phone id.
    FrameFile {
        id: String,
    },
    /// A new recording's id from the local time and a UUID.
    RecordingId {
        /// year, month, day, hour, minute, second.
        time: [u32; 6],
        uuid: String,
    },
    /// The files a new recording writes, or `already_recording`.
    RecorderStart {
        #[serde(default)]
        recorder: Option<Recorder>,
        id: String,
        capabilities: u64,
    },
    /// The recorder once its video (and maybe log) process started.
    RecorderBegin {
        id: String,
        device: PhoneDevice,
        started_at: String,
        video: String,
        #[serde(default)]
        log: Option<String>,
        uptime_nanos: i64,
    },
    /// Logs an input sent to `device_id`, when it is the recorded phone.
    RecorderNote {
        #[serde(default)]
        recorder: Option<Recorder>,
        input: PhoneInput,
        device_id: String,
        uptime_nanos: i64,
    },
    /// The stopped recording, or `not_recording`.
    RecorderStop {
        #[serde(default)]
        recorder: Option<Recorder>,
        #[serde(default)]
        notes: String,
        uptime_nanos: i64,
    },
    /// The files a stopped recording writes; `poster`: the poster frame was saved.
    RecordingFiles {
        recording: Recording,
        #[serde(default)]
        poster: bool,
    },
    /// `manifest.json` read back.
    RecordingRead {
        manifest: String,
    },
    /// One `events.jsonl` line's value for an input at `at` seconds.
    RecordingEvent {
        at: f64,
        input: PhoneInput,
    },
    /// The feedback message and attachments for a stopped recording.
    FeedbackClip {
        recording: Recording,
        /// The recording's `device-log.ndjson`, when it has one.
        #[serde(default)]
        log_ndjson: Option<String>,
        #[serde(default = "log_limit")]
        log_limit: usize,
        folder_url: String,
        #[serde(default)]
        strings: feedback::Strings,
    },
    /// The cloud host replica follower's defaults keys and host name limit.
    ReplicaKeys,
    /// The first step of one piece of lease work.
    ReplicaApply {
        want: replica::Want,
        #[serde(default)]
        renew: bool,
        #[serde(default)]
        published_user: Option<String>,
    },
    /// The purge step, given `cloud-host-replica-status`.
    ReplicaPurge {
        #[serde(default)]
        renew: bool,
        #[serde(default)]
        daemon: Option<i64>,
        #[serde(default)]
        purge_asked: Option<i64>,
        status: replica::Status,
    },
    /// `cloud-host-replica-set`'s fields once the token is read.
    ReplicaLease {
        #[serde(default)]
        origin: Option<String>,
        token: String,
        expires_at: u64,
        #[serde(default)]
        client_version: Option<String>,
        computer_name: String,
    },
}

/// Why the request itself could not be read.
#[derive(Debug)]
pub struct BadRequest(pub serde_json::Error);

fn log_limit() -> usize {
    8
}

fn recorder_error(error: recording::RecorderError) -> Value {
    json!({ "error": error.kind() })
}

fn unreadable(what: &str) -> Value {
    json!({ "error": "unreadable", "what": what })
}

fn answer(request: Request) -> Value {
    match request {
        Request::SimctlDevices { output } => match devices::simctl_devices(output.as_bytes()) {
            Ok(list) => json!({ "devices": list }),
            Err(devices::Unreadable(what)) => unreadable(&what),
        },
        Request::DevicectlDevices { output } => match devices::devicectl_devices(output.as_bytes())
        {
            Ok(list) => json!({ "devices": list }),
            Err(devices::Unreadable(what)) => unreadable(&what),
        },
        Request::PhoneId { id } => json!({ "id": PhoneDeviceId::parse(&id) }),
        Request::CapabilityNames { bits } => json!({ "names": devices::capability_names(bits) }),
        Request::AdbDevices { output } => json!({ "devices": android::adb_devices(&output) }),
        Request::AvdNames { output } => json!({ "names": android::avd_names(&output) }),
        Request::AvdName { output } => json!({ "name": android::avd_name(&output) }),
        Request::AvdDisplayName { avd } => json!({ "name": android::display_name(&avd) }),
        Request::UsbModel { entry } => json!({ "model": android::usb_model(&entry) }),
        Request::PixelsPerDp { output } => {
            json!({ "pixels_per_dp": android::pixels_per_dp(&output) })
        }
        Request::ScreenPoints { size_output, density_output, rotation } => {
            let Some(size) = android::wm_size(&size_output) else {
                return unreadable("the screen size");
            };
            let Some(scale) = android::pixels_per_dp(&density_output) else {
                return unreadable("the screen density");
            };
            let (width, height) = android::screen_points(size, scale, rotation.as_deref());
            json!({ "width": width, "height": height, "pixels_per_dp": scale })
        }
        Request::NightMode { output } => json!({ "dark": android::night_mode_is_dark(&output) }),
        Request::FreeEmulatorPort { serials } => {
            json!({ "port": android::free_emulator_port(serials.iter().map(String::as_str)) })
        }
        Request::AndroidInputCalls { input, emulator, scale } => {
            match android::input_calls(&input, emulator, scale) {
                Ok(calls) => json!({ "calls": calls }),
                Err(android::Unsupported { what }) => {
                    json!({ "error": "unsupported", "what": what })
                }
            }
        }
        Request::KeyStrokes { text } => json!({ "strokes": input::strokes(&text) }),
        Request::MacKeyUsage { code } => json!({ "usage": input::usage_for_mac_key_code(code) }),
        Request::Tap { screen, point } => touches(input::tap(screen, point)),
        Request::Swipe { screen, from, to, seconds } => {
            touches(input::swipe(screen, from, to, seconds))
        }
        Request::DrawnRect { screen, view } => json!({ "rect": input::drawn_rect(screen, view) }),
        Request::DevicePoint { screen, view, point } => {
            json!({ "point": input::device_point(screen, view, point) })
        }
        Request::NormalizedViewPoint { screen, view, point } => {
            json!({ "point": input::normalized_view_point(screen, view, point) })
        }
        Request::LogTail { ndjson, limit } => {
            json!({ "lines": log_tail::log_tail(ndjson.as_bytes(), limit) })
        }
        Request::UiautomatorTree { output, pixels_per_point } => {
            match uiautomator::parse(&output, pixels_per_point) {
                Ok(root) => json!({ "root": root }),
                Err(uiautomator::Unreadable) => unreadable("the UI Automator dump"),
            }
        }
        Request::Capabilities { mode, live_input, android } => {
            let bits = service::capabilities(mode, live_input, android);
            json!({ "bits": bits, "names": devices::capability_names(bits) })
        }
        Request::InputCheck { input, id, capabilities } => {
            let Some(id) = PhoneDeviceId::parse(&id) else { return unreadable("the phone id") };
            let kind = recording::kind(&input);
            let needs = recording::required_capability(&input);
            match service::check_input(&input, id.mode, capabilities) {
                Ok(()) => json!({ "kind": kind, "needs": needs, "allowed": true }),
                Err(refused) => json!({
                    "kind": kind, "needs": needs, "allowed": false,
                    "error": "unsupported", "mode": refused.mode, "what": refused.what,
                }),
            }
        }
        Request::TouchInput { screen, from, to, seconds } => {
            json!({ "input": service::touch_input(screen, from, to, seconds) })
        }
        Request::DefaultDevice { recording, devices } => {
            match service::default_device(recording.as_ref(), &devices) {
                Some(device) => json!({ "device": device }),
                None => json!({ "error": "unknown_device", "id": "(none)" }),
            }
        }
        Request::ShellLine { argv } => json!({ "line": service::shell_line(&argv) }),
        Request::FrameFile { id } => json!({ "file": service::frame_file(&id) }),
        Request::RecordingId { time, uuid } => {
            json!({ "id": recording::recording_id(time, &uuid) })
        }
        Request::RecorderStart { recorder, id, capabilities } => {
            let Some(id) = PhoneDeviceId::parse(&id) else { return unreadable("the phone id") };
            match recording::plan(recorder.is_some(), &id, capabilities) {
                Ok((video, log)) => json!({ "video": video, "log": log }),
                Err(error) => recorder_error(error),
            }
        }
        Request::RecorderBegin { id, device, started_at, video, log, uptime_nanos } => {
            json!({ "recorder": recording::begin(id, device, started_at, video, log, uptime_nanos) })
        }
        Request::RecorderNote { recorder, input, device_id, uptime_nanos } => {
            let Some(mut recorder) = recorder else {
                return json!({ "recorder": null, "noted": false });
            };
            let noted = recording::note(&mut recorder, &input, &device_id, uptime_nanos);
            json!({ "recorder": recorder, "noted": noted })
        }
        Request::RecorderStop { recorder, notes, uptime_nanos } => {
            match recording::stop(recorder, notes, uptime_nanos) {
                Ok(recording) => {
                    json!({ "recording": recording, "poster": recording::POSTER_FILE })
                }
                Err(error) => recorder_error(error),
            }
        }
        Request::RecordingFiles { mut recording, poster } => {
            if poster {
                recording.poster = Some(recording::POSTER_FILE.to_owned());
            }
            let files = recording::files(&recording);
            json!({
                "recording": recording,
                "manifest": files.manifest,
                "events_jsonl": files.events_jsonl,
                "notes_md": files.notes_md,
            })
        }
        Request::RecordingRead { manifest } => {
            match recording::read_manifest(manifest.as_bytes()) {
                Ok(recording) => json!({ "recording": recording }),
                Err(what) => {
                    json!({ "error": "unreadable", "what": format!("the recording manifest: {what}") })
                }
            }
        }
        Request::RecordingEvent { at, input } => {
            json!({ "event": recording::RecordingEvent::new(at, &input) })
        }
        Request::FeedbackClip { recording, log_ndjson, log_limit, folder_url, strings } => {
            let log = log_ndjson
                .map(|ndjson| log_tail::log_tail(ndjson.as_bytes(), log_limit))
                .unwrap_or_default();
            json!(feedback::clip(&recording, &log, &folder_url, &strings))
        }
        Request::ReplicaKeys => json!({
            "published_key": replica::PUBLISHED_KEY,
            "purge_asked_key": replica::PURGE_ASKED_KEY,
            "host_name_limit": replica::HOST_NAME_LIMIT,
        }),
        Request::ReplicaApply { want, renew, published_user } => {
            json!(replica::apply(&want, renew, published_user.as_deref()))
        }
        Request::ReplicaPurge { renew, daemon, purge_asked, status } => {
            json!(replica::purge(renew, daemon, purge_asked, &status))
        }
        Request::ReplicaLease { origin, token, expires_at, client_version, computer_name } => {
            json!({
                "lease": replica::lease(origin.as_deref(), token, expires_at, client_version, &computer_name)
            })
        }
    }
}

fn touches(result: Result<Vec<input::Touch>, input::OutsideScreen>) -> Value {
    match result {
        Ok(touches) => json!({ "touches": touches }),
        Err(input::OutsideScreen) => json!({ "error": "outside_screen" }),
    }
}

/// Answers one JSON request.
pub fn respond(request: &[u8]) -> Result<Vec<u8>, BadRequest> {
    let request: Request = serde_json::from_slice(request).map_err(BadRequest)?;
    serde_json::to_vec(&answer(request)).map_err(BadRequest)
}
