//! The Android backend's rules (Swift `AndroidDeviceList`,
//! `AndroidPhoneBackend`): `adb` and `emulator` output, the argv each input
//! becomes, densities and the screen size in dp.
use serde::{Deserialize, Serialize};

/// Lines as Swift's `split(whereSeparator: \.isNewline)` gives them: no empty ones.
fn lines(text: &str) -> impl DoubleEndedIterator<Item = &str> {
    text.split(['\n', '\r', '\u{0B}', '\u{0C}', '\u{85}', '\u{2028}', '\u{2029}'])
        .filter(|line| !line.is_empty())
}

/// Swift's `split(separator:)`: no empty parts.
fn parts(text: &str, separator: char) -> impl DoubleEndedIterator<Item = &str> {
    text.split(separator).filter(|part| !part.is_empty())
}

/// Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not newlines.
fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|ch: char| {
        ch.is_whitespace()
            && !matches!(ch, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// One `adb devices -l` row.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdbEntry {
    pub serial: String,
    /// "device", "offline", "unauthorized".
    pub state: String,
    /// The `model:` field ("Pixel_7"), when adb reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

impl AdbEntry {
    pub fn is_emulator(&self) -> bool {
        self.serial.starts_with("emulator-")
    }
}

/// Parses `adb devices -l`.
pub fn adb_devices(output: &str) -> Vec<AdbEntry> {
    lines(output)
        .filter_map(|line| {
            let fields: Vec<&str> =
                line.split([' ', '\t']).filter(|field| !field.is_empty()).collect();
            if fields.len() < 2 || line.starts_with("List of devices") || line.starts_with('*') {
                return None;
            }
            let model = fields[2..]
                .iter()
                .find_map(|field| field.strip_prefix("model:"))
                .map(str::to_owned);
            Some(AdbEntry { serial: fields[0].to_owned(), state: fields[1].to_owned(), model })
        })
        .collect()
}

/// The AVD names of `emulator -list-avds` (its INFO lines skipped).
pub fn avd_names(output: &str) -> Vec<String> {
    lines(output).filter(|line| !line.starts_with("INFO")).map(str::to_owned).collect()
}

/// The AVD name `adb emu avd name` answers (the first line that is not "OK").
pub fn avd_name(output: &str) -> Option<String> {
    lines(output).map(trim_spaces).find(|line| !line.is_empty() && *line != "OK").map(str::to_owned)
}

/// `Pixel_8_API_35` -> "Pixel 8 API 35".
pub fn display_name(avd: &str) -> String {
    avd.replace('_', " ")
}

/// A USB phone's name: adb's model with spaces, else its serial.
pub fn usb_model(entry: &AdbEntry) -> String {
    entry.model.as_deref().map(display_name).unwrap_or_else(|| entry.serial.clone())
}

/// Pixels per dp from `wm density` ("Physical density: 420", then "Override
/// density: 360" when set; the last line wins). None when unreadable or not positive.
pub fn pixels_per_dp(output: &str) -> Option<f64> {
    let last = lines(output).next_back()?;
    let dpi: f64 = trim_spaces(parts(last, ':').next_back()?).parse().ok()?;
    (dpi > 0.0).then_some(dpi / 160.0)
}

/// The natural pixel size from `wm size` ("Physical size: 1080x2400"; an
/// "Override size" line follows when set; the last wins).
pub fn wm_size(output: &str) -> Option<(f64, f64)> {
    let last = lines(output).next_back()?;
    let dims: Vec<f64> = parts(parts(last, ':').next_back()?, 'x')
        .filter_map(|part| trim_spaces(part).parse().ok())
        .collect();
    (dims.len() == 2).then(|| (dims[0], dims[1]))
}

/// The screen in dp in the current orientation: `wm size` is the natural
/// (portrait) size; screencap and taps follow `user_rotation`.
pub fn screen_points(size: (f64, f64), pixels_per_dp: f64, rotation: Option<&str>) -> (f64, f64) {
    let rotation: i64 = rotation.and_then(|text| text.parse().ok()).unwrap_or(0);
    let (w, h) = if rotation % 2 == 1 { (size.1, size.0) } else { size };
    (w / pixels_per_dp, h / pixels_per_dp)
}

/// `cmd uimode night` answers "Night mode: yes|no|auto"; auto reads as light.
pub fn night_mode_is_dark(output: &str) -> bool {
    output.to_lowercase().ends_with("yes")
}

/// One single-quoted word for the device's `sh`.
pub fn quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// The first free emulator console port (even, 5554 through 5682), given
/// the adb serials already running. None past 64 emulators.
pub fn free_emulator_port<'a>(serials: impl IntoIterator<Item = &'a str>) -> Option<u16> {
    let taken: Vec<i64> = serials
        .into_iter()
        .filter_map(|serial| serial.strip_prefix("emulator-"))
        .filter_map(|port| port.parse().ok())
        .collect();
    (5554..=5682).step_by(2).find(|port| !taken.contains(&i64::from(*port)))
}

/// A phone's hardware button.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PhoneButton {
    Home,
    Lock,
    VolumeUp,
    VolumeDown,
    Siri,
    Back,
    AppSwitch,
}

pub fn keycode(button: PhoneButton) -> &'static str {
    match button {
        PhoneButton::Home => "KEYCODE_HOME",
        PhoneButton::Lock => "KEYCODE_POWER",
        PhoneButton::VolumeUp => "KEYCODE_VOLUME_UP",
        PhoneButton::VolumeDown => "KEYCODE_VOLUME_DOWN",
        PhoneButton::Siri => "KEYCODE_ASSIST",
        PhoneButton::Back => "KEYCODE_BACK",
        PhoneButton::AppSwitch => "KEYCODE_APP_SWITCH",
    }
}

/// A point in dp as the device's pixels, rounded half away from zero.
pub fn px(points: f64, scale: f64) -> String {
    // Saturating like Swift's Int(_:) of a finite value in range.
    ((points * scale).round() as i64).to_string()
}

/// Swift's `String(Double)`: the shortest round-trip digits, with ".0" on whole
/// numbers and an exponent below 1e-4 or from 2^53 up.
pub fn swift_double(value: f64) -> String {
    if value.is_nan() {
        return "nan".into();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf".into() } else { "-inf".into() };
    }
    let magnitude = value.abs();
    if magnitude != 0.0 && !(1e-4..(1u64 << 53) as f64).contains(&magnitude) {
        let text = format!("{value:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
        let mantissa =
            if mantissa.contains('.') { mantissa.to_owned() } else { format!("{mantissa}.0") };
        let (sign, digits) =
            exponent.strip_prefix('-').map_or(("+", exponent), |digits| ("-", digits));
        return format!("{mantissa}e{sign}{digits:0>2}");
    }
    let text = format!("{value}");
    if text.contains('.') { text } else { format!("{text}.0") }
}

/// What a phone input is, as far as the Android backend reads it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AndroidInput {
    Tap { x: f64, y: f64 },
    Swipe { from_x: f64, from_y: f64, to_x: f64, to_y: f64, seconds: f64 },
    Text { text: String },
    Button { button: PhoneButton },
    OpenUrl { url: String },
    Appearance { dark: bool },
    Location { latitude: f64, longitude: f64 },
    Locale { identifier: String },
    Install { path: String },
    Launch { package: String },
    Pasteboard,
    SoftwareKeyboard,
}

/// One `adb -s SERIAL <args>` call the input runs, with its name for errors
/// and its deadline.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AdbCall {
    pub args: Vec<String>,
    pub name: &'static str,
    pub deadline_seconds: u32,
}

/// Why an input cannot run on this phone.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Unsupported {
    /// The input's kind, as Swift's `PhoneInput.kind` names it.
    pub what: String,
}

fn call(args: &[&str], name: &'static str) -> AdbCall {
    AdbCall { args: args.iter().map(|arg| (*arg).to_owned()).collect(), name, deadline_seconds: 30 }
}

/// The adb calls that send `input` (after `-s SERIAL`), in order. `scale` is
/// pixels per dp, needed by taps and swipes only.
pub fn input_calls(
    input: &AndroidInput,
    emulator: bool,
    scale: f64,
) -> Result<Vec<AdbCall>, Unsupported> {
    let unsupported = |what: &str| Unsupported { what: what.to_owned() };
    Ok(match input {
        AndroidInput::Tap { x, y } => {
            vec![call(&["shell", "input", "tap", &px(*x, scale), &px(*y, scale)], "adb input tap")]
        }
        AndroidInput::Swipe { from_x, from_y, to_x, to_y, seconds } => vec![call(
            &[
                "shell",
                "input",
                "swipe",
                &px(*from_x, scale),
                &px(*from_y, scale),
                &px(*to_x, scale),
                &px(*to_y, scale),
                &(((seconds * 1000.0).round()) as i64).to_string(),
            ],
            "adb input swipe",
        )],
        // `input text` reads %s as a space; the device shell parses the one quoted argument.
        AndroidInput::Text { text } => {
            vec![call(
                &["shell", &format!("input text {}", quoted(&text.replace(' ', "%s")))],
                "adb input text",
            )]
        }
        AndroidInput::Button { button } => {
            vec![call(&["shell", "input", "keyevent", keycode(*button)], "adb input keyevent")]
        }
        AndroidInput::OpenUrl { url } => {
            vec![call(
                &["shell", &format!("am start -a android.intent.action.VIEW -d {}", quoted(url))],
                "adb am start",
            )]
        }
        AndroidInput::Pasteboard => return Err(unsupported("pasteboard")),
        AndroidInput::SoftwareKeyboard => return Err(unsupported("software-keyboard")),
        AndroidInput::Appearance { dark } => {
            vec![call(
                &["shell", "cmd", "uimode", "night", if *dark { "yes" } else { "no" }],
                "adb cmd uimode",
            )]
        }
        AndroidInput::Location { latitude, longitude } => {
            if !emulator {
                return Err(unsupported("location"));
            }
            vec![call(
                &["emu", "geo", "fix", &swift_double(*longitude), &swift_double(*latitude)],
                "adb emu geo fix",
            )]
        }
        AndroidInput::Locale { identifier } => {
            // Emulator images allow adb root; restarting zygote applies the locale to every app.
            if !emulator {
                return Err(unsupported("locale"));
            }
            let tag = identifier.replace('_', "-");
            vec![
                call(&["root"], "adb root"),
                call(
                    &[
                        "shell",
                        &format!(
                            "setprop persist.sys.locale {} && setprop ctl.restart zygote",
                            quoted(&tag)
                        ),
                    ],
                    "adb setprop locale",
                ),
            ]
        }
        AndroidInput::Install { path } => {
            vec![AdbCall { deadline_seconds: 300, ..call(&["install", "-r", path], "adb install") }]
        }
        AndroidInput::Launch { package } => vec![call(
            &["shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
            "adb monkey",
        )],
    })
}
