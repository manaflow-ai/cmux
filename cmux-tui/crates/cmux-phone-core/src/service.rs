//! The phone service's rules (Swift `PhoneService`, `PhoneCapabilities`,
//! `XcodePhoneBackend`/`AndroidPhoneBackend.capabilities`, `videoExtension`):
//! what each kind of phone can do, which phone a command uses when none is
//! named, whether an input may go, and how a drag on the still frame becomes
//! a tap or a swipe.
use serde::Serialize;

use crate::devices::{PhoneDevice, PhoneDeviceId, PhoneDeviceState, PhoneMode};
use crate::recording::{PhoneInput, kind, required_capability};

/// `PhoneCapabilities` bits (bit 0 boot .. bit 15 accessibility).
pub mod caps {
    pub const BOOT: u64 = 1 << 0;
    pub const SCREENSHOT: u64 = 1 << 1;
    pub const RECORD_VIDEO: u64 = 1 << 2;
    pub const DEVICE_LOG: u64 = 1 << 3;
    pub const OPEN_URL: u64 = 1 << 4;
    pub const PASTEBOARD: u64 = 1 << 5;
    pub const TOUCH: u64 = 1 << 6;
    pub const KEYBOARD: u64 = 1 << 7;
    pub const LIVE_SCREEN: u64 = 1 << 8;
    pub const BUTTONS: u64 = 1 << 9;
    pub const APPEARANCE: u64 = 1 << 10;
    pub const LOCATION: u64 = 1 << 11;
    pub const LOCALE: u64 = 1 << 12;
    pub const APPS: u64 = 1 << 13;
    pub const ROTATE: u64 = 1 << 14;
    pub const ACCESSIBILITY: u64 = 1 << 15;
}

/// What a phone of `mode` can do. `live_input`: SimulatorKit's HID transport
/// loaded (simulators then take touches, keys and buttons and stream live).
/// `android`: the Android SDK was found (else Android phones can do nothing).
pub fn capabilities(mode: PhoneMode, live_input: bool, android: bool) -> u64 {
    use caps::*;
    match mode {
        PhoneMode::Simulator => {
            let base = BOOT
                | SCREENSHOT
                | RECORD_VIDEO
                | DEVICE_LOG
                | OPEN_URL
                | PASTEBOARD
                | APPEARANCE
                | LOCATION
                | LOCALE
                | APPS;
            if live_input { base | TOUCH | KEYBOARD | BUTTONS | LIVE_SCREEN } else { base }
        }
        PhoneMode::Device => SCREENSHOT | RECORD_VIDEO,
        PhoneMode::VirtualMachine => 0,
        PhoneMode::Emulator | PhoneMode::AndroidDevice if !android => 0,
        PhoneMode::Emulator | PhoneMode::AndroidDevice => {
            let base = SCREENSHOT
                | RECORD_VIDEO
                | DEVICE_LOG
                | OPEN_URL
                | TOUCH
                | KEYBOARD
                | BUTTONS
                | APPEARANCE
                | APPS
                | ACCESSIBILITY
                | LIVE_SCREEN;
            if mode == PhoneMode::Emulator {
                base | BOOT | LOCATION | ROTATE | LOCALE
            } else {
                base
            }
        }
    }
}

/// The screen video's extension: simctl writes `.mov`; devicectl and adb `.mp4`.
pub fn video_extension(mode: PhoneMode) -> &'static str {
    match mode {
        PhoneMode::Device | PhoneMode::Emulator | PhoneMode::AndroidDevice => "mp4",
        PhoneMode::Simulator | PhoneMode::VirtualMachine => "mov",
    }
}

/// Why an input is refused before any command runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Refused {
    pub mode: PhoneMode,
    pub what: &'static str,
}

/// Whether `input` may go to a phone with `capabilities`; refused with the
/// input's kind otherwise (Swift `PhoneError.unsupported`).
pub fn check_input(input: &PhoneInput, mode: PhoneMode, capabilities: u64) -> Result<(), Refused> {
    if capabilities & required_capability(input) != 0 {
        Ok(())
    } else {
        Err(Refused { mode, what: kind(input) })
    }
}

fn mode_of(device: &PhoneDevice) -> Option<PhoneMode> {
    PhoneDeviceId::parse(&device.id).map(|id| id.mode)
}

/// The phone a command uses when none is named: the recorded one, else the
/// first ready simulator, else the first ready phone, else the first simulator.
pub fn default_device<'a>(
    recording: Option<&'a PhoneDevice>,
    devices: &'a [PhoneDevice],
) -> Option<&'a PhoneDevice> {
    if recording.is_some() {
        return recording;
    }
    let is_sim = |device: &&PhoneDevice| mode_of(device) == Some(PhoneMode::Simulator);
    let mut ready = devices.iter().filter(|device| device.state == PhoneDeviceState::Ready);
    ready.clone().find(is_sim).or_else(|| ready.next()).or_else(|| devices.iter().find(is_sim))
}

/// Moves under this share of the screen (0...1 units) are a tap, not a drag.
pub const TAP_SLOP: f64 = 0.02;
/// The shortest swipe the service sends, in seconds.
pub const SHORTEST_TOUCH_SWIPE: f64 = 0.1;

/// A tap or swipe the person made on the tab's still frame, in 0...1 screen
/// coordinates, as the input it sends (`screen` is the size in points).
pub fn touch_input(
    screen: (f64, f64),
    from: (f64, f64),
    to: (f64, f64),
    seconds: f64,
) -> PhoneInput {
    let (a_x, a_y) = (from.0 * screen.0, from.1 * screen.1);
    let moved = (to.0 - from.0).hypot(to.1 - from.1) > TAP_SLOP;
    if moved {
        PhoneInput::Swipe {
            from_x: a_x,
            from_y: a_y,
            to_x: to.0 * screen.0,
            to_y: to.1 * screen.1,
            seconds: seconds.max(SHORTEST_TOUCH_SWIPE),
        }
    } else {
        PhoneInput::Tap { x: a_x, y: a_y }
    }
}

/// The shell line that streams a log, for a terminal tab: every word single-quoted.
pub fn shell_line(argv: &[String]) -> String {
    argv.iter().map(|word| crate::android::quoted(word)).collect::<Vec<_>>().join(" ")
}

/// The still frame a phone tab shows: one file per device, rewritten.
pub fn frame_file(id: &str) -> String {
    format!("frame-{}.png", id.replace(':', "-"))
}
