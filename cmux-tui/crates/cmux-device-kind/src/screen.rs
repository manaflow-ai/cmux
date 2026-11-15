//! What the Screen Sharing page offers for a linked machine, by its kind.
//!
//! The decision is made here so every view (the Mac app's Screen Sharing page, the CLI's
//! `cmux device list --json`, the web) shows the same thing; a view only draws it.

use crate::DeviceKind;
use serde::Serialize;

/// How the page reaches a machine's screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ScreenRoute {
    /// A Mac's screen through the device hub (cmux Remote's screen worker on that Mac).
    Hub,
    /// A Cloud machine's desktop.
    Cloud,
}

/// Why a machine has nothing to press.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum NoScreen {
    Offline,
    NoDisplay,
    Linux,
    Phone,
    Unknown,
}

/// What the page offers for one machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum Screen {
    View { route: ScreenRoute },
    None { reason: NoScreen },
}

/// The offer for a machine of `kind` (its OS when the kind says nothing), connected or not.
///
/// - a Mac: View through the device hub while it is connected, else offline;
/// - a Cloud machine: View its desktop (opening it resumes a paused machine);
/// - a Linux server or VM: no display to share;
/// - a Linux desktop: cmux does not share a Linux screen yet;
/// - an iPhone or iPad: it cannot share its screen;
/// - a kind nothing tells: its OS decides as above, else the machine is listed as unknown.
pub fn offer(kind: DeviceKind, os: Option<&str>, connected: bool) -> Screen {
    let mac = || {
        if connected {
            Screen::View { route: ScreenRoute::Hub }
        } else {
            Screen::None { reason: NoScreen::Offline }
        }
    };
    let none = |reason| Screen::None { reason };
    match kind {
        DeviceKind::MacBook
        | DeviceKind::MacMini
        | DeviceKind::IMac
        | DeviceKind::MacStudio
        | DeviceKind::MacPro => mac(),
        DeviceKind::Cloud => Screen::View { route: ScreenRoute::Cloud },
        DeviceKind::LinuxServer => none(NoScreen::NoDisplay),
        DeviceKind::LinuxDesktop => none(NoScreen::Linux),
        DeviceKind::IPhone | DeviceKind::IPad => none(NoScreen::Phone),
        DeviceKind::Generic => match os.map(str::to_ascii_lowercase).as_deref() {
            Some("macos" | "darwin") => mac(),
            Some("linux") => none(NoScreen::Linux),
            Some("ios" | "ipados" | "android") => none(NoScreen::Phone),
            _ => none(NoScreen::Unknown),
        },
    }
}

#[cfg(test)]
#[path = "screen_tests.rs"]
mod tests;
