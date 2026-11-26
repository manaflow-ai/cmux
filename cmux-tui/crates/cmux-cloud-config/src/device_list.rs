//! Which of the device hub's records are one physical device: the decision behind
//! `CmuxNextDevices/DeviceHub.swift` `remoteDevices` (Screen Sharing's Your Devices, the
//! `macScreen.open --device` names), served as `cloud_identity_device_list`.
//!
//! Why (Leo's Settings > Screen Sharing, 2026-11-15: the Mac he sat on listed twice,
//! both Offline, while he sat on it): the hub keys a device by its identity, and an identity lives
//! in the Keychain under `<bundle id>.device-hub`. Every build of cmux with its own bundle id
//! (NIGHTLY, DEV, each tagged DEV build) is a new identity, so a new hub record with the same
//! Computer Name, and a renewal (`device_removed`, `device_key_mismatch`) leaves the old record
//! behind too. The list read every record but this build's own as another device, so the same
//! Mac showed as many rows, This Mac among them as an offline remote.
//!
//! The rule, machine id first: records with one `machineId` (the hub's per-account id of the
//! physical machine, PROTOCOL.md "One record per machine") are one device, and two machine ids are
//! two devices even under one name. A record without one (a build from before the field, or a
//! renewal's leftover) falls back to its name: records of one platform whose names fold to the same
//! key (letters and digits, lowercased: "Leo’s Mac" is "Leo's Mac") are one device, and such a
//! record joins the first machine whose records carry its name key. Records of this device's
//! machine, or (when this device has no machine id, or the record none) with this device's name
//! key, are this device (its other builds) and are not listed as remotes. Every other device lists
//! once, as the record a connect should reach: online, then sharing, then the newest seen.
//!
//! What the name fallback cannot tell: two physical devices with the same Computer Name, neither
//! with a machine id, read as one. The hub retires a renewal's leftover once the build registers
//! with a machine id, so the fallback only covers records from before the field.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// One hub record, as `GET /v1/devices` lists it (the fields this rule reads).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// `macos`, `ios`, `linux`, `windows`; absent reads as `macos` (records made before platforms).
    #[serde(default)]
    pub platform: Option<String>,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub mac_screen_shared: bool,
    /// Epoch seconds.
    #[serde(default)]
    pub last_seen_at: Option<f64>,
    /// Epoch seconds.
    #[serde(default)]
    pub created_at: Option<f64>,
    /// The hub's per-account id of the physical machine; absent or null for a record registered
    /// without a `machineKey`.
    #[serde(default)]
    pub machine_id: Option<String>,
}

/// This device: its id, and its name, platform and machine id for before the hub lists its record.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct This {
    pub id: String,
    #[serde(default)]
    pub machine_id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub platform: Option<String>,
}

/// One physical device other than this one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    /// The record to show and connect to.
    pub id: String,
    /// Every record of the device, `id` first, then the others in the hub's order.
    pub ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Listing {
    /// Every record of this device: its own id first, then its other builds' records.
    pub this_device: Vec<String>,
    /// The other devices, one each, in the hub's order of their first record.
    pub others: Vec<Machine>,
}

/// The key that makes records one device: the platform and the name's letters and digits,
/// lowercased, without macOS's name-conflict suffix. A name with neither keys by the record's id
/// (never merged).
pub fn key(id: &str, name: &str, platform: Option<&str>) -> String {
    let folded: String = without_conflict_suffix(name)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    let platform = platform.filter(|p| !p.is_empty()).unwrap_or("macos");
    if folded.is_empty() {
        format!("{platform}\u{0}#{id}")
    } else {
        format!("{platform}\u{0}{folded}")
    }
}

/// `name` without the " (2)" macOS adds to a Computer Name another device on the network already
/// uses ("lawrence's MacBook Pro (2)" listed beside the same Mac's older record, 2026-11-16): the
/// Mac the OS renamed is still one device.
fn without_conflict_suffix(name: &str) -> &str {
    let Some(inner) = name.trim_end().strip_suffix(')') else { return name };
    let Some((base, digits)) = inner.rsplit_once(" (") else { return name };
    if !base.is_empty() && !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        base
    } else {
        name
    }
}

/// Whether `a` is the better record of one device to show and connect to.
fn better(a: &Device, b: &Device) -> bool {
    let rank = |d: &Device| (d.online, d.mac_screen_shared);
    if rank(a) != rank(b) {
        return rank(a) > rank(b);
    }
    let seen = |d: &Device| d.last_seen_at.or(d.created_at).unwrap_or(f64::MIN);
    seen(a) > seen(b)
}

/// A non-empty machine id.
fn machine_of(id: Option<&str>) -> Option<&str> {
    id.filter(|m| !m.is_empty())
}

/// The group key of a machine id (never equal to a name [`key`]: no platform is `machine`).
fn machine_key(machine: &str, platform: Option<&str>) -> String {
    let platform = platform.filter(|p| !p.is_empty()).unwrap_or("macos");
    format!("machine\u{0}{platform}\u{0}{machine}")
}

/// The hub's records as physical devices: this device's records, and one entry per other device.
pub fn listing(this: &This, devices: &[Device]) -> Listing {
    // This device's keys: its listed record's (a name pinned in Settings) and the name it registers
    // with (the Computer Name now, after a rename or while its record is blank or not listed yet).
    let own = devices.iter().find(|d| d.id == this.id);
    let this_machine = machine_of(own.and_then(|d| d.machine_id.as_deref()))
        .or(machine_of(this.machine_id.as_deref()));
    // A record without a machine id joins the first machine (in the hub's order) whose records
    // carry its name key.
    let mut name_owner: HashMap<String, String> = HashMap::new();
    for device in devices.iter().filter(|d| d.id != this.id) {
        if let Some(machine) = machine_of(device.machine_id.as_deref()) {
            name_owner
                .entry(key(&device.id, &device.name, device.platform.as_deref()))
                .or_insert_with(|| machine_key(machine, device.platform.as_deref()));
        }
    }
    let platform = own.and_then(|d| d.platform.as_deref()).or(this.platform.as_deref());
    let this_keys: Vec<String> = own
        .map(|d| d.name.as_str())
        .into_iter()
        .chain(this.name.as_deref())
        .filter(|name| name.chars().any(char::is_alphanumeric))
        .map(|name| key(&this.id, name, platform))
        .collect();
    let mut this_device = vec![this.id.clone()];
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Vec<&Device>> = HashMap::new();
    for device in devices {
        if device.id == this.id {
            continue;
        }
        let name_key = key(&device.id, &device.name, device.platform.as_deref());
        let machine = machine_of(device.machine_id.as_deref());
        let is_this = match (this_machine, machine) {
            (Some(mine), Some(theirs)) => mine == theirs,
            _ => this_keys.contains(&name_key),
        };
        if is_this {
            this_device.push(device.id.clone());
            continue;
        }
        let k = match machine {
            Some(machine) => machine_key(machine, device.platform.as_deref()),
            None => name_owner.get(&name_key).cloned().unwrap_or(name_key),
        };
        groups
            .entry(k.clone())
            .or_insert_with(|| {
                order.push(k);
                Vec::new()
            })
            .push(device);
    }
    let others = order
        .iter()
        .filter_map(|k| groups.get(k))
        .filter_map(|records| {
            let best =
                records.iter().copied().reduce(|best, d| if better(d, best) { d } else { best })?;
            let mut ids = vec![best.id.clone()];
            ids.extend(records.iter().filter(|d| d.id != best.id).map(|d| d.id.clone()));
            Some(Machine { id: best.id.clone(), ids })
        })
        .collect();
    Listing { this_device, others }
}

/// What Your Devices can truly say while it lists nothing (Leo, 2026-11-19, ask-6a79af928f: "i simply
/// dont see ANYTHING on the scren sharing screen"). The hub is `ready` as soon as this device registers,
/// before the device list is read. The list comes after the socket connects, and that read can fail. Until
/// a read succeeds, an empty list means nothing, so "none of your devices" is said only after one.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryInput {
    /// The hub: `idle`, `starting`, `ready` or `failed`.
    #[serde(default)]
    pub status: String,
    /// Why the hub failed (with `failed`).
    #[serde(default)]
    pub status_detail: Option<String>,
    /// A device-list read succeeded since sign-in.
    #[serde(default)]
    pub listed: bool,
    /// Why the last device-list read failed; none once a read succeeds.
    #[serde(default)]
    pub list_error: Option<String>,
    /// The hub socket: `connected`, `connecting`, `reconnecting`, `disconnected`, `replaced`,
    /// `removed` or `signedOut`.
    #[serde(default)]
    pub connection: String,
    /// Why the socket's last attempt failed (with `reconnecting`).
    #[serde(default)]
    pub connection_detail: Option<String>,
    /// How many devices the page would list.
    #[serde(default)]
    pub shown: usize,
}

/// One state for Your Devices.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum Discovery {
    /// Rows to list.
    List,
    /// Registering, connecting, or waiting for the first read: never "none".
    Finding,
    /// The list cannot be read: `reason` for the app to word, `detail` the hub's or socket's own words.
    Failed { reason: FailReason, detail: Option<String> },
    /// A read succeeded and holds no device to show.
    None,
}

/// Why Your Devices cannot list.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FailReason {
    /// The hub did not take this device (its registration failed).
    Hub,
    /// The device-list read failed.
    List,
    /// The socket keeps failing, so the list was never read.
    Connection,
    /// Another connection of this device took over.
    Replaced,
    /// The hub removed this device.
    Removed,
    /// This device is signed out of the hub.
    SignedOut,
}

/// What Your Devices says for `input`. With rows, the list. Without them, "none" only after a read
/// succeeded; the reason when the hub, the read or the socket failed; otherwise "finding".
pub fn discovery(input: &DiscoveryInput) -> Discovery {
    if input.shown > 0 {
        return Discovery::List;
    }
    let failed =
        |reason, detail: Option<&String>| Discovery::Failed { reason, detail: detail.cloned() };
    if input.status == "failed" {
        return failed(FailReason::Hub, input.status_detail.as_ref());
    }
    match input.connection.as_str() {
        "replaced" => return failed(FailReason::Replaced, None),
        "removed" => return failed(FailReason::Removed, None),
        "signedOut" => return failed(FailReason::SignedOut, None),
        _ => {}
    }
    if let Some(error) = &input.list_error {
        return failed(FailReason::List, Some(error));
    }
    if input.listed {
        return Discovery::None;
    }
    if input.status == "ready" && input.connection == "reconnecting" {
        return failed(FailReason::Connection, input.connection_detail.as_ref());
    }
    Discovery::Finding
}

#[cfg(test)]
#[path = "device_list_tests.rs"]
mod tests;
