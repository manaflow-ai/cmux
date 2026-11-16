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
//! Machine keys first: the hub lists each record's `machine` (its per-account key for the machine
//! the record's client runs on, PROTOCOL.md "One record per machine"). Records with one key are
//! one device, records with two keys are two devices whatever their names, and the name rule
//! above only places records that carry no key (clients from before machine ids), joining the
//! first machine whose records carry the same name. Two Macs with one Computer Name read as one
//! only while one of them runs a build that sends no machine id.

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
    /// The hub's per-account key for the record's machine (`machine`, PROTOCOL.md "One record
    /// per machine"): one key is one machine, two keys are two machines whatever their names.
    /// Absent for records from clients that send no machine id.
    #[serde(default)]
    pub machine: Option<String>,
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
    let this_machine = own.and_then(|d| d.machine.as_deref()).filter(|m| !m.is_empty());
    let machine_of = |d: &Device| d.machine.clone().filter(|m| !m.is_empty());
    // A record with a machine key is that machine's. A record without one (a client from before
    // machine ids) joins the first machine whose records carry its name, else its name's group.
    let mut name_to_machine: HashMap<String, String> = HashMap::new();
    for device in devices {
        if let Some(machine) = machine_of(device) {
            name_to_machine
                .entry(key(&device.id, &device.name, device.platform.as_deref()))
                .or_insert(format!("machine\u{0}{machine}"));
        }
    }
    let mut this_device = vec![this.id.clone()];
    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Vec<&Device>> = HashMap::new();
    for device in devices {
        if device.id == this.id {
            continue;
        }
        let name_key = key(&device.id, &device.name, device.platform.as_deref());
        let mine = match (machine_of(device), this_machine) {
            // Another machine's key is another machine, even with this one's name.
            (Some(machine), Some(own)) => machine == own,
            // This build sends no machine id: the name is all it can go by.
            (_, None) | (None, _) => this_keys.contains(&name_key),
        };
        if mine {
            this_device.push(device.id.clone());
            continue;
        }
        let k = match machine_of(device) {
            Some(machine) => format!("machine\u{0}{machine}"),
            None => name_to_machine.get(&name_key).cloned().unwrap_or(name_key),
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

#[cfg(test)]
#[path = "device_list_tests.rs"]
mod tests;
