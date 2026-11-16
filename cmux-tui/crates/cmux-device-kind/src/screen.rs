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
    /// A screen through the device hub: a Mac's (cmux Remote's screen worker on that Mac), a
    /// Linux desktop's (`cmux-rd linux-host`) or a Windows PC's (`cmux-rd windows-host`). The hub only lists a machine once it registered;
    /// `cmux_window_rules::screen_share::plan` refuses one it does not list.
    Hub,
    /// A Cloud machine's desktop.
    Cloud,
}

/// Why a machine has nothing to press.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum NoScreen {
    Offline,
    /// A headless Linux server or VM: it has no desktop to share.
    NoDesktop,
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
/// - a Mac or a Linux desktop: View through the device hub while it is connected, else offline;
/// - a Cloud machine: View its desktop (opening it resumes a paused machine);
/// - a headless Linux server or VM: it has no desktop to share;
/// - an iPhone or iPad: it cannot share its screen;
/// - a kind nothing tells: a Mac or a Windows PC by its OS as above; anything else (a Linux one may be a desktop
///   or a server) is listed as unknown, so no row gets a button that may be dead.
pub fn offer(kind: DeviceKind, os: Option<&str>, connected: bool) -> Screen {
    let hub = || {
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
        | DeviceKind::MacPro
        | DeviceKind::LinuxDesktop => hub(),
        DeviceKind::Cloud => Screen::View { route: ScreenRoute::Cloud },
        DeviceKind::LinuxServer => none(NoScreen::NoDesktop),
        DeviceKind::IPhone | DeviceKind::IPad => none(NoScreen::Phone),
        DeviceKind::Generic => match os.map(str::to_ascii_lowercase).as_deref() {
            Some("macos" | "darwin" | "windows") => hub(),
            Some("ios" | "ipados" | "android") => none(NoScreen::Phone),
            _ => none(NoScreen::Unknown),
        },
    }
}

#[cfg(test)]
#[path = "screen_tests.rs"]
mod tests;
