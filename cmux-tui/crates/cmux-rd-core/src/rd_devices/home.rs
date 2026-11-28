//! The home page's Your Devices (`MacScreenHomeDevices.swift`): which devices it lists, each row's state,
//! and what it says while the list is empty or out of reach. The views stay in Swift.

use super::Words;
use super::settings::Platform;
use serde::{Deserialize, Serialize};

/// What the home list needs of one hub device.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(default)]
pub struct HomeDevice {
    pub id: String,
    pub platform: Option<Platform>,
    pub online: bool,
    /// The hub reported presence (a device with no presence reads as reachable).
    pub online_known: bool,
    pub mac_screen_shared: bool,
    /// The access this Mac has on it (`none` blocks requests).
    pub access: Option<String>,
}

impl Default for HomeDevice {
    fn default() -> Self {
        HomeDevice {
            id: String::new(),
            platform: None,
            online: false,
            online_known: true,
            mac_screen_shared: false,
            access: None,
        }
    }
}

/// The home list shows every device but a phone that does not share its screen.
pub fn listed(devices: &[HomeDevice]) -> Vec<String> {
    devices
        .iter()
        .filter(|d| d.platform != Some(Platform::Ios) || d.mac_screen_shared)
        .map(|d| d.id.clone())
        .collect()
}

/// A row's state, in the order the row checks it.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RowState {
    Offline,
    NotViewable,
    Blocked,
    SharingOff,
    Usable,
}

pub fn row_state(d: &HomeDevice) -> RowState {
    if !d.online && d.online_known {
        RowState::Offline
    } else if d.platform == Some(Platform::Windows) {
        RowState::NotViewable
    } else if d.access.as_deref() == Some("none") {
        RowState::Blocked
    } else if d.mac_screen_shared {
        RowState::Usable
    } else {
        RowState::SharingOff
    }
}

/// Why the list could not be read.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ListFailure {
    Hub,
    Connection,
    Replaced,
    List,
    Removed,
    SignedOut,
}

/// Where reading the list stands.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "discovery")]
pub enum Discovery {
    NoDevices,
    List,
    Finding,
    Failed {
        reason: ListFailure,
        #[serde(default)]
        detail: String,
    },
}

fn loading() -> Words {
    Words::t("macScreen.home.devicesLoading", "Loading your devices…")
}

fn reason_words(reason: ListFailure) -> Words {
    match reason {
        ListFailure::Hub | ListFailure::Connection | ListFailure::Replaced => Words::t(
            "macScreen.home.listFailed.hub",
            "Can’t reach the device hub, so your other Macs can’t be listed yet. cmux keeps trying.",
        ),
        ListFailure::List => Words::t(
            "macScreen.home.listFailed.list",
            "Couldn’t load your devices. cmux tries again when the hub reconnects.",
        ),
        ListFailure::Removed | ListFailure::SignedOut => {
            Words::t("devices.status.removed", "This Mac left your devices.")
        }
    }
}

/// What the empty list says: none only once the list was read.
pub fn empty_note(discovery: &Discovery) -> Words {
    match discovery {
        Discovery::NoDevices => Words::t(
            "macScreen.home.noSharedDevices",
            "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.",
        ),
        Discovery::List | Discovery::Finding => loading(),
        Discovery::Failed { reason, detail } if detail.is_empty() => reason_words(*reason),
        Discovery::Failed { reason, detail } => Words {
            key: None,
            text: "%@ (%@)".into(),
            table: None,
            args: vec![reason_words(*reason), Words::said(detail.clone())],
        },
    }
}

/// The section without a hub: a note, or the sign-in prompt.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum SetupDevices {
    Note { text: Words },
    SignedOut { text: Words },
}

pub fn setup_devices(configured: bool, restoring: bool) -> SetupDevices {
    if !configured {
        SetupDevices::Note {
            text: Words::t(
                "macScreen.home.invalidHubAddress",
                "Mac Screen works through the device hub. The Device Hub Address in Settings › Development is not a valid web address; fix it, or clear it to use the built-in hub.",
            ),
        }
    } else if restoring {
        SetupDevices::Note { text: loading() }
    } else {
        SetupDevices::SignedOut {
            text: Words::t(
                "macScreen.home.devicesSignIn",
                "Sign in to cmux to see your other Macs here.",
            ),
        }
    }
}

/// The first-use card shows until this Mac has used Mac Screen or shares now.
pub fn shows_first_use(has_used_before: bool, is_sharing: bool) -> bool {
    !has_used_before && !is_sharing
}

#[cfg(test)]
mod tests {
    //! Ported from `MacScreenHomeDevicesTests` (Your Devices says none only after the list was read).
    use super::*;

    #[test]
    fn your_devices_says_none_only_after_the_list_was_read() {
        let none = empty_note(&Discovery::NoDevices).english();
        assert_eq!(empty_note(&Discovery::Finding), empty_note(&Discovery::List));
        assert_ne!(empty_note(&Discovery::Finding).english(), none);
        let failed =
            empty_note(&Discovery::Failed { reason: ListFailure::List, detail: "HTTP 503".into() })
                .english();
        assert!(failed.contains("HTTP 503") && failed != none);
        let hub =
            empty_note(&Discovery::Failed { reason: ListFailure::Replaced, detail: String::new() });
        assert_eq!(hub.key.as_deref(), Some("macScreen.home.listFailed.hub"));
    }

    #[test]
    fn rows_list_and_read_in_order() {
        let d = |id: &str, platform, shared| HomeDevice {
            id: id.into(),
            platform,
            online: true,
            mac_screen_shared: shared,
            ..Default::default()
        };
        let devices = [
            d("mac", Some(Platform::Macos), false),
            d("phone", Some(Platform::Ios), false),
            d("ipad", Some(Platform::Ios), true),
        ];
        assert_eq!(listed(&devices), ["mac", "ipad"]);
        assert_eq!(row_state(&devices[0]), RowState::SharingOff);
        assert_eq!(row_state(&devices[2]), RowState::Usable);
        assert_eq!(
            row_state(&HomeDevice { online: false, ..devices[2].clone() }),
            RowState::Offline
        );
        assert_eq!(
            row_state(&HomeDevice { online: false, online_known: false, ..devices[2].clone() }),
            RowState::Usable
        );
        assert_eq!(row_state(&d("pc", Some(Platform::Windows), true)), RowState::NotViewable);
        assert_eq!(
            row_state(&HomeDevice { access: Some("none".into()), ..devices[2].clone() }),
            RowState::Blocked
        );
        assert!(matches!(setup_devices(false, true), SetupDevices::Note { .. }));
        assert!(matches!(setup_devices(true, false), SetupDevices::SignedOut { .. }));
        assert!(shows_first_use(false, false) && !shows_first_use(false, true));
    }
}
