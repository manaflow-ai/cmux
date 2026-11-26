//! The JSON door: one request with an `op` field, one reply. Failures the app
//! shows come back as `{"error": KIND, ...}` replies; only a request that does
//! not decode is an `Err`.
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{android, devices, input, log_tail, uiautomator};

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
}

/// Why the request itself could not be read.
#[derive(Debug)]
pub struct BadRequest(pub serde_json::Error);

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
        Request::PhoneId { id } => json!({ "id": devices::PhoneDeviceId::parse(&id) }),
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
