//! System alerts on macOS ([`crate::alerts`]): the window server's on-screen
//! list with no layer filter, kept to the system agents' dialogs, and each
//! one's texts and button titles read through the Accessibility API.
//!
//! Nothing here takes a picture, moves the pointer or changes focus. A
//! password field is noticed and never read. The one action is `AXPress` on
//! the button [`crate::alerts::check`] allowed, after the alert was read
//! again and found unchanged.

use super::ax::{self, Ax};
use super::roles;
use super::sys::*;
use super::workspace;
use crate::alerts::{self, RawAlert};
use crate::desktop::{DResult, DesktopError};

const LIST_ON_SCREEN_ONLY: u32 = 1 << 0;
const LIST_EXCLUDE_DESKTOP: u32 = 1 << 4;
/// A dialog is larger than this; smaller windows of the same agents are
/// their helpers.
const MIN_SIDE: f64 = 40.0;
const MAX_NODES: usize = 400;
const MAX_DEPTH: usize = 12;
const MAX_TEXT_CHARS: usize = 600;
/// A system agent showing a modal panel can answer slowly.
const READ_TIMEOUT_SECONDS: f32 = 3.0;

struct Candidate {
    id: u32,
    pid: i32,
    owner: String,
    layer: i64,
    name: String,
}

fn candidates() -> Vec<Candidate> {
    // SAFETY: returns a +1 CFArray of CFDictionaries (or null).
    let Some(array) = Cf::created(unsafe {
        CGWindowListCopyWindowInfo(LIST_ON_SCREEN_ONLY | LIST_EXCLUDE_DESKTOP, 0)
    }) else {
        return Vec::new();
    };
    array
        .items()
        .iter()
        .filter_map(|d| {
            let owner = d.get("kCGWindowOwnerName")?.as_string()?;
            let layer = d.get("kCGWindowLayer").and_then(|v| v.as_i64()).unwrap_or(0);
            if !alerts::is_alert_window(&owner, layer) {
                return None;
            }
            let bounds = d.get("kCGWindowBounds")?;
            let side = |k: &str| bounds.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
            let alpha = d.get("kCGWindowAlpha").and_then(|v| v.as_f64()).unwrap_or(1.0);
            if alpha <= 0.0 || side("Width") < MIN_SIDE || side("Height") < MIN_SIDE {
                return None;
            }
            Some(Candidate {
                id: d.get("kCGWindowNumber")?.as_i64()? as u32,
                pid: d.get("kCGWindowOwnerPID")?.as_i64()? as i32,
                owner,
                layer,
                name: d.get("kCGWindowName").and_then(|v| v.as_string()).unwrap_or_default(),
            })
        })
        .collect()
}

fn clip(text: String) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() <= MAX_TEXT_CHARS {
        return text;
    }
    text.chars().take(MAX_TEXT_CHARS).collect()
}

/// What one walk of an alert's window found: its texts and buttons in tree
/// order, the button elements beside their titles.
#[derive(Default)]
struct Read {
    texts: Vec<String>,
    buttons: Vec<(String, Ax)>,
    secure_field: bool,
    nodes: usize,
}

impl Read {
    fn walk(&mut self, el: &Ax, depth: usize) {
        if depth > MAX_DEPTH || self.nodes >= MAX_NODES {
            return;
        }
        self.nodes += 1;
        let role = el.string("AXRole").unwrap_or_default();
        // Noticed, never read, never entered. AppKit's secure field is role
        // AXTextField with subrole AXSecureTextField, so the subrole decides.
        if roles::is_secure(&role, el.string("AXSubrole").as_deref()) {
            self.secure_field = true;
            return;
        }
        match role.as_str() {
            // What a person typed is not the alert's text.
            "AXTextField" | "AXTextArea" | "AXComboBox" => return,
            "AXStaticText" => {
                let text = el.value_text().or_else(|| el.string("AXTitle")).unwrap_or_default();
                let text = clip(text);
                if !text.is_empty() {
                    self.texts.push(text);
                }
                return;
            }
            "AXButton" => {
                let subrole = el.string("AXSubrole").unwrap_or_default();
                let title = match subrole.as_str() {
                    "AXCloseButton" => "Close".to_string(),
                    "AXMinimizeButton" | "AXZoomButton" | "AXFullScreenButton"
                    | "AXToolbarButton" => String::new(),
                    _ => clip(
                        el.string("AXTitle")
                            .filter(|t| !t.trim().is_empty())
                            .or_else(|| el.string("AXDescription"))
                            .unwrap_or_default(),
                    ),
                };
                if !title.is_empty() {
                    self.buttons.push((title, el.clone()));
                }
                return;
            }
            _ => {}
        }
        for child in el.elements("AXChildren") {
            self.walk(&child, depth + 1);
        }
    }
}

/// One candidate read through accessibility: the alert, and its buttons'
/// elements (empty when it could not be read).
fn read(c: &Candidate) -> (RawAlert, Vec<(String, Ax)>) {
    let mut alert = RawAlert {
        window_id: c.id.to_string(),
        pid: c.pid.max(0) as u32,
        owner: c.owner.clone(),
        bundle_id: workspace::app_for_pid(c.pid)
            .and_then(|app| app.bundle_id)
            .filter(|b| !b.is_empty())
            .unwrap_or_else(|| alerts::known_bundle_id(&c.owner).to_string()),
        layer: c.layer,
        title: c.name.clone(),
        ..RawAlert::default()
    };
    if !ax::trusted() {
        alert.unreadable = Some("the accessibility permission is not granted".into());
        return (alert, Vec::new());
    }
    let Some(app) = Ax::application(c.pid) else {
        alert.unreadable = Some("its process has no accessibility element".into());
        return (alert, Vec::new());
    };
    let _slow = app.timeout_until_drop(READ_TIMEOUT_SECONDS, ax::MESSAGE_TIMEOUT_SECONDS);
    let windows = match app.try_elements("AXWindows") {
        Ok(windows) => windows,
        Err(e) => {
            alert.unreadable = Some(ax::ax_error(e, "reading its windows").to_string());
            return (alert, Vec::new());
        }
    };
    let Some(window) = windows.iter().find(|w| w.window_id() == Some(c.id)) else {
        alert.unreadable = Some("accessibility does not list this window".into());
        return (alert, Vec::new());
    };
    if let Some(title) = window.string("AXTitle").filter(|t| !t.trim().is_empty()) {
        alert.title = clip(title);
    }
    let mut found = Read::default();
    found.walk(window, 0);
    alert.texts = found.texts;
    alert.buttons = found.buttons.iter().map(|(title, _)| title.clone()).collect();
    alert.secure_field = found.secure_field;
    (alert, found.buttons)
}

pub fn list() -> Vec<RawAlert> {
    candidates().iter().map(|c| read(c).0).collect()
}

/// Presses `title` on `alert`, if the alert reads now exactly as it did
/// when the press was allowed.
pub fn press(alert: &RawAlert, title: &str) -> DResult<()> {
    if !ax::trusted() {
        return Err(DesktopError::PermissionMissing("accessibility".into()));
    }
    let Some(candidate) = candidates().into_iter().find(|c| c.id.to_string() == alert.window_id)
    else {
        return Err(DesktopError::TargetNotFound(format!("alert {}", alert.window_id)));
    };
    let (now, buttons) = read(&candidate);
    if now != *alert {
        return Err(DesktopError::Failed(format!(
            "alert {} changed since it was read; call list_alerts again",
            alert.window_id
        )));
    }
    let mut matching = buttons.iter().filter(|(t, _)| t == title);
    let (Some((_, button)), None) = (matching.next(), matching.next()) else {
        return Err(DesktopError::TargetNotFound(format!(
            "exactly one button {title:?} on alert {}",
            alert.window_id
        )));
    };
    button.perform("AXPress").map_err(|e| ax::ax_error(e, &format!("pressing {title:?}")))
}
