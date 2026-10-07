//! The `desktop/1` service vocabulary (plans/cmux-next/ios-next/c3-rd.md
//! 2.3): control messages of a remote desktop session between a phone and
//! the Mac that proxies it, carried as rd `Control::Service { service:
//! "desktop/1", body }`. The Swift implementation (CmuxRemoteDesktop
//! `DesktopMessage`) replays the same vectors,
//! schemas/remote-desktop/desktop.json.

use serde::{Deserialize, Serialize};

/// The service name in `Control::Service`.
pub const SERVICE: &str = "desktop/1";

/// View only, or view and control.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    View,
    Control,
}

/// Session state the Mac reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    WaitingConsent,
    AuthRequired,
    Live,
    Paused,
}

/// What a session shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetKind {
    Display,
    Window,
    Vnc,
}

/// The target's full size in target pixels (input coordinates), scale and label.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TargetInfo {
    pub kind: TargetKind,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub name: String,
}

/// One window offered by `desktop.windows`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Window {
    pub id: u32,
    pub app: String,
    pub title: String,
}

/// A target rectangle shown at an encode size. Views the Mac starts itself
/// have `seq` at or above [`HOST_SEQ_BASE`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct View {
    pub seq: u32,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
}

/// First seq of views the Mac starts (resize, display switch).
pub const HOST_SEQ_BASE: u32 = 0x8000_0000;

impl View {
    /// The rd datagram `stream` that carries this view's frames: the low 15
    /// bits of `seq`, bit 15 set for views the Mac started.
    pub fn stream(&self) -> u16 {
        let host = if self.seq >= HOST_SEQ_BASE { 0x8000 } else { 0 };
        (self.seq & 0x7fff) as u16 | host
    }
}

/// A password in a message; Debug never prints it.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Password(pub String);

impl std::fmt::Debug for Password {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

/// One `desktop/1` message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum DesktopMessage {
    #[serde(rename = "desktop.view")]
    View(View),
    #[serde(rename = "desktop.view_applied")]
    ViewApplied(View),
    #[serde(rename = "desktop.target")]
    Target { target: TargetInfo },
    #[serde(rename = "desktop.select")]
    Select { display: u32 },
    #[serde(rename = "desktop.windows.list")]
    WindowsList,
    #[serde(rename = "desktop.windows")]
    Windows { windows: Vec<Window> },
    #[serde(rename = "desktop.mode")]
    Mode { mode: Mode },
    #[serde(rename = "desktop.mode_applied")]
    ModeApplied {
        mode: Mode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "desktop.clipboard.push")]
    ClipboardPush { seq: u32, text: String },
    #[serde(rename = "desktop.clipboard.pull")]
    ClipboardPull { seq: u32 },
    #[serde(rename = "desktop.clipboard")]
    Clipboard {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u32>,
        text: String,
    },
    #[serde(rename = "desktop.auth")]
    Auth { password: Password },
    #[serde(rename = "desktop.state")]
    State {
        state: State,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "desktop.ended")]
    Ended { reason: String },
}
