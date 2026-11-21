//! Screen Sharing's machine picker: the rows of the new tab ⌄ menu's Screen Sharing ▸ (and the
//! pane and tab menus' Screen Sharing ▸), served as `cloud_identity_screen_picker`.
//!
//! Why (Leo, 2026-11-18, c-b99282b1ed): "i should be able to see into any connected mac or linux
//! machine", "you should be able to click the chevron next to teh + of new tab and just go there",
//! and "idk why that was greyed". The ⌄ menu's Screen Sharing row only opened the Screen Sharing
//! page, where a machine that could not be viewed was a grey word.
//!
//! The rule: every machine the device hub lists that this Mac has a viewer for (a Mac or a Linux
//! desktop; a phone only when it shares, as the Screen Sharing page lists it) is one row, named,
//! with what it needs. A row opens that machine's screen in one click when it is online, sharing
//! and lets this Mac ask. Otherwise its row says why, and which side fixes it: the host turns on
//! Share This Mac (`share_this_mac`) or lets this Mac in, in its Settings › Devices
//! (`device_access`). Rows that open come first, then the ones the host can fix, then offline
//! ones, each in the hub's order. A machine with no viewer here (Windows, an unknown platform) is
//! not listed.

use serde::{Deserialize, Serialize};

/// One machine, as the app reads it from the device hub (``DeviceList``'s others).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// `macos`, `ios`, `linux`, ...; absent reads as `macos` (records made before platforms).
    #[serde(default)]
    pub platform: Option<String>,
    #[serde(default)]
    pub online: bool,
    /// Whether `online` is current (this Mac's hub link is up); while not, offline is not believed.
    #[serde(default = "yes")]
    pub online_known: bool,
    #[serde(default)]
    pub mac_screen_shared: bool,
    /// Whether the host lets this Mac ask (its access for this Mac is not None).
    #[serde(default = "yes")]
    pub allows_requests: bool,
}

fn yes() -> bool {
    true
}

/// What a row can do now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Opens the machine's screen.
    View,
    /// Online, Share This Mac is off there.
    SharingOff,
    /// Online and sharing, and it does not let this Mac in.
    NotAllowed,
    Offline,
}

/// What the host does so the row opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Fix {
    /// Turn on Share This Mac there (its one guided setup: the switch, Screen Recording, Accessibility).
    ShareThisMac,
    /// Let this Mac in, in its Settings › Devices.
    DeviceAccess,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub name: String,
    /// The SF Symbol the row draws.
    pub symbol: &'static str,
    pub state: State,
    /// Whether a click opens the screen (else it shows what `fix` needs).
    pub opens: bool,
    pub fix: Option<Fix>,
}

/// The picker's rows for `machines`, in the order the menu lists them.
pub fn rows(machines: &[Machine]) -> Vec<Row> {
    let mut rows: Vec<Row> = machines.iter().filter_map(row).collect();
    // Stable: each state keeps the hub's order.
    rows.sort_by_key(|row| match row.state {
        State::View => 0,
        State::SharingOff => 1,
        State::NotAllowed => 2,
        State::Offline => 3,
    });
    rows
}

fn row(machine: &Machine) -> Option<Row> {
    let name = machine.name.trim();
    if name.is_empty() {
        return None;
    }
    let platform = machine.platform.as_deref().filter(|p| !p.is_empty()).unwrap_or("macos");
    let symbol = match platform {
        "macos" => "desktopcomputer",
        "linux" => "pc",
        // A phone is listed only while it shares (the Screen Sharing page's rule).
        "ios" if machine.mac_screen_shared => "iphone",
        _ => return None,
    };
    // Offline counts only while this Mac's hub link is up; until then the hub's word may be stale.
    let state = if !machine.online && machine.online_known {
        State::Offline
    } else if !machine.mac_screen_shared {
        State::SharingOff
    } else if !machine.allows_requests {
        State::NotAllowed
    } else {
        State::View
    };
    let fix = match state {
        State::SharingOff => Some(Fix::ShareThisMac),
        State::NotAllowed => Some(Fix::DeviceAccess),
        State::View | State::Offline => None,
    };
    Some(Row {
        id: machine.id.clone(),
        name: name.to_owned(),
        symbol,
        state,
        opens: state == State::View,
        fix,
    })
}

#[cfg(test)]
#[path = "screen_picker_tests.rs"]
mod tests;
