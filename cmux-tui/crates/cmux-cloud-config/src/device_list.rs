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
//! The rule: records of one platform whose names fold to the same key (letters and digits,
//! lowercased: "Leo’s Mac" is "Leo's Mac") are one device. Records with this device's key are
//! this device (its other builds) and are not listed as remotes. Every other group lists once, as
//! the record a connect should reach: online, then sharing, then the newest seen.
//!
//! What it cannot tell: two physical devices with the same Computer Name on one account read as
//! one. macOS keeps Computer Names unique on a network, and the hub has no machine id to tell
//! them apart (a hub-side machine id is the follow-up that removes the name rule).

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
}

/// This device: its id, and its name and platform for before the hub lists its record.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct This {
    pub id: String,
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
/// lowercased. A name with neither keys by the record's id (never merged).
pub fn key(id: &str, name: &str, platform: Option<&str>) -> String {
    let folded: String =
        name.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect();
    let platform = platform.filter(|p| !p.is_empty()).unwrap_or("macos");
    if folded.is_empty() {
        format!("{platform}\u{0}#{id}")
    } else {
        format!("{platform}\u{0}{folded}")
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

/// The hub's records as physical devices: this device's records, and one entry per other device.
pub fn listing(this: &This, devices: &[Device]) -> Listing {
    // This device's keys: its listed record's (a name pinned in Settings) and the name it registers
    // with (the Computer Name now, after a rename or while its record is blank or not listed yet).
    let own = devices.iter().find(|d| d.id == this.id);
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
        let k = key(&device.id, &device.name, device.platform.as_deref());
        if this_keys.contains(&k) {
            this_device.push(device.id.clone());
            continue;
        }
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
