//! Phones and their ids: `xcrun simctl list devices -j` and `xcrun devicectl
//! list devices --json-output -` (Swift `SimctlDeviceList`,
//! `DevicectlDeviceList`, `PhoneDeviceID`, `PhoneCapabilities.names`).
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;

/// How a phone is run. The string form is the id's prefix.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PhoneMode {
    /// An iOS Simulator device, driven by `simctl`.
    #[serde(rename = "sim")]
    Simulator,
    /// A real iPhone paired over USB or Wi-Fi, driven by `devicectl`.
    #[serde(rename = "dev")]
    Device,
    /// An iOS virtual machine run by an external tool's local API.
    #[serde(rename = "vm")]
    VirtualMachine,
    /// An Android Virtual Device (by AVD name).
    #[serde(rename = "avd")]
    Emulator,
    /// A real Android phone, by its `adb` serial.
    #[serde(rename = "adb")]
    AndroidDevice,
}

impl PhoneMode {
    pub const ALL: [PhoneMode; 5] =
        [Self::Simulator, Self::Device, Self::VirtualMachine, Self::Emulator, Self::AndroidDevice];

    pub fn prefix(self) -> &'static str {
        match self {
            Self::Simulator => "sim",
            Self::Device => "dev",
            Self::VirtualMachine => "vm",
            Self::Emulator => "avd",
            Self::AndroidDevice => "adb",
        }
    }

    pub fn from_prefix(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.prefix() == text)
    }

    /// True for the Android modes, which the Android backend serves.
    pub fn is_android(self) -> bool {
        matches!(self, Self::Emulator | Self::AndroidDevice)
    }
}

/// A stable phone id: `sim:<udid>`, `dev:<udid>`, `vm:<name>`, `avd:<name>`, `adb:<serial>`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PhoneDeviceId {
    pub mode: PhoneMode,
    pub raw: String,
}

impl PhoneDeviceId {
    pub fn new(mode: PhoneMode, raw: impl Into<String>) -> Self {
        Self { mode, raw: raw.into() }
    }

    /// Parses the string form; None for any other text (an empty raw part included).
    pub fn parse(text: &str) -> Option<Self> {
        let (mode, raw) = text.split_once(':')?;
        let mode = PhoneMode::from_prefix(mode)?;
        if raw.is_empty() {
            return None;
        }
        Some(Self::new(mode, raw))
    }

    pub fn text(&self) -> String {
        format!("{}:{}", self.mode.prefix(), self.raw)
    }
}

/// What a listed phone can do right now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PhoneDeviceState {
    Shutdown,
    Booting,
    Ready,
    Disconnected,
    Unavailable { reason: String },
}

/// One listed phone. `id` is the string form.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PhoneDevice {
    pub id: String,
    pub name: String,
    pub model: String,
    pub os_version: String,
    pub state: PhoneDeviceState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport: Option<String>,
}

/// Why a tool's output could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unreadable(pub String);

fn string(value: &Value, key: &str) -> Result<String, Unreadable> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| Unreadable(format!("missing {key}")))
}

fn optional<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a str> {
    value?.get(key)?.as_str()
}

/// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` -> [27, 0]; None for other platforms.
pub fn ios_runtime(id: &str) -> Option<Vec<i64>> {
    let rest = id.strip_prefix("com.apple.CoreSimulator.SimRuntime.iOS-")?;
    let parts: Vec<i64> = rest
        .split('-')
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    (!parts.is_empty()).then_some(parts)
}

/// `...SimDeviceType.iPhone-18-Pro-Max` -> "iPhone 18 Pro Max". The type id,
/// not the user's name, so a renamed simulator still finds its frame.
pub fn simulator_model(type_id: Option<&str>, fallback: &str) -> String {
    let Some(rest) =
        type_id.and_then(|id| id.strip_prefix("com.apple.CoreSimulator.SimDeviceType."))
    else {
        return fallback.to_owned();
    };
    let words: Vec<&str> = rest.split('-').filter(|word| !word.is_empty()).collect();
    match words.first() {
        Some(&"iPhone") | Some(&"iPad") => words.join(" "),
        _ => fallback.to_owned(),
    }
}

/// The phones of a `simctl list devices -j` listing: iOS runtimes only,
/// booted first, then newest runtime first, then by name.
pub fn simctl_devices(json: &[u8]) -> Result<Vec<PhoneDevice>, Unreadable> {
    let listing: Value =
        serde_json::from_slice(json).map_err(|error| Unreadable(error.to_string()))?;
    let runtimes = listing
        .get("devices")
        .and_then(Value::as_object)
        .ok_or_else(|| Unreadable("missing devices".into()))?;
    let mut phones: Vec<(PhoneDevice, Vec<i64>)> = Vec::new();
    for (runtime_id, entries) in runtimes {
        let entries =
            entries.as_array().ok_or_else(|| Unreadable("devices is not a list".into()))?;
        // Decoded whole, as Swift's Decodable did: a malformed entry fails the listing.
        let mut parsed = Vec::with_capacity(entries.len());
        for entry in entries {
            let udid = string(entry, "udid")?;
            let name = string(entry, "name")?;
            let state = string(entry, "state")?;
            parsed.push((entry, udid, name, state));
        }
        let Some(runtime) = ios_runtime(runtime_id) else { continue };
        for (entry, udid, name, state) in parsed {
            let state = if entry.get("isAvailable").and_then(Value::as_bool) == Some(false) {
                PhoneDeviceState::Unavailable {
                    reason: entry
                        .get("availabilityError")
                        .and_then(Value::as_str)
                        .unwrap_or("unavailable")
                        .to_owned(),
                }
            } else {
                match state.as_str() {
                    "Booted" => PhoneDeviceState::Ready,
                    "Booting" => PhoneDeviceState::Booting,
                    _ => PhoneDeviceState::Shutdown,
                }
            };
            let model =
                simulator_model(entry.get("deviceTypeIdentifier").and_then(Value::as_str), &name);
            let os_version =
                format!("iOS {}", runtime.iter().map(i64::to_string).collect::<Vec<_>>().join("."));
            let device = PhoneDevice {
                id: PhoneDeviceId::new(PhoneMode::Simulator, udid).text(),
                name,
                model,
                os_version,
                state,
                transport: None,
            };
            phones.push((device, runtime.clone()));
        }
    }
    phones.sort_by(|(lhs, lhs_runtime), (rhs, rhs_runtime)| {
        let lhs_ready = lhs.state == PhoneDeviceState::Ready;
        let rhs_ready = rhs.state == PhoneDeviceState::Ready;
        rhs_ready
            .cmp(&lhs_ready)
            .then_with(|| rhs_runtime.cmp(lhs_runtime))
            .then_with(|| crate::natural::compare(&lhs.name, &rhs.name))
            .then(Ordering::Equal)
    });
    Ok(phones.into_iter().map(|(device, _)| device).collect())
}

/// The real iPhones and iPads of a `devicectl list devices` listing.
/// Simulated entries and other platforms are skipped.
pub fn devicectl_devices(json: &[u8]) -> Result<Vec<PhoneDevice>, Unreadable> {
    let output: Value =
        serde_json::from_slice(json).map_err(|error| Unreadable(error.to_string()))?;
    let devices = output
        .get("result")
        .and_then(|result| result.get("devices"))
        .and_then(Value::as_array)
        .ok_or_else(|| Unreadable("missing result.devices".into()))?;
    let mut phones = Vec::new();
    for entry in devices {
        let identifier = string(entry, "identifier")?;
        let hardware = entry.get("hardwareProperties").filter(|value| !value.is_null());
        let Some(_) = hardware else { continue };
        if optional(hardware, "reality") != Some("physical") {
            continue;
        }
        if !matches!(optional(hardware, "platform"), Some("iOS") | Some("iPadOS")) {
            continue;
        }
        let connection = entry.get("connectionProperties").filter(|value| !value.is_null());
        let properties = entry.get("deviceProperties").filter(|value| !value.is_null());
        // devicectl opens the tunnel on demand, so a paired device counts as
        // ready; a far-away one fails at its first command with the tool's error.
        let connected = optional(connection, "pairingState") == Some("paired");
        let transport = match optional(connection, "transportType") {
            Some("wired") => Some("usb".to_owned()),
            Some("localNetwork") => Some("wifi".to_owned()),
            _ => None,
        };
        let model = optional(hardware, "marketingName")
            .or(optional(hardware, "deviceType"))
            .unwrap_or("iPhone")
            .to_owned();
        let raw = optional(hardware, "udid").map(str::to_owned).unwrap_or(identifier);
        phones.push(PhoneDevice {
            id: PhoneDeviceId::new(PhoneMode::Device, raw).text(),
            name: optional(properties, "name").map(str::to_owned).unwrap_or_else(|| model.clone()),
            model,
            os_version: format!("iOS {}", optional(properties, "osVersionNumber").unwrap_or("?")),
            state: if connected { PhoneDeviceState::Ready } else { PhoneDeviceState::Disconnected },
            transport,
        });
    }
    Ok(phones)
}

/// The capability names the CLI and MCP report, in a stable order, for the
/// `PhoneCapabilities` bit set (bit 0 boot .. bit 15 accessibility).
pub const CAPABILITY_NAMES: [&str; 16] = [
    "boot",
    "screenshot",
    "record",
    "log",
    "open-url",
    "pasteboard",
    "touch",
    "keyboard",
    "live",
    "buttons",
    "appearance",
    "location",
    "locale",
    "apps",
    "rotate",
    "ui",
];

pub fn capability_names(bits: u64) -> Vec<&'static str> {
    CAPABILITY_NAMES
        .iter()
        .enumerate()
        .filter(|(bit, _)| bits & (1 << bit) != 0)
        .map(|(_, name)| *name)
        .collect()
}
