//! Whether this computer can share its screen now, and if not, why: one status for every OS host
//! (macOS, Linux X11 and portal, Windows), printed by `cmux-rd share-status` as one JSON line.
//!
//! Why (Lawrence, relayed by Leo 2026-11-16: "screen sharing is also black and not working"): an
//! iPhone viewing a Mac got "Video · Direct · 3 fps · 0 KB/s" over a black picture. The Mac said it
//! shared its screen, but its capture had no Screen Recording grant in effect, and nothing told
//! either side. A host that cannot capture must say so, and say why, before a viewer looks at
//! black.
//!
//! The probe runs in a fresh process each time (the app spawns it the way it spawns `permissions`
//! and `serve`), so a grant made in System Settings a moment ago is read as it is now, never the
//! answer a long-running app cached at launch.
//!
//! The decision ([`evaluate`]) is pure: the probes gather facts, and the rule and the sentences the
//! person reads live here, the same for every host and every viewer.

use crate::Res;
use serde::{Deserialize, Serialize};
use std::io::Write;

/// The one word a viewer switches on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShareState {
    /// The screen can be seen (and, when asked, controlled).
    Ready,
    /// The OS does not let this computer's screen be captured: macOS Screen Recording is off, or
    /// the person at a Wayland desktop declined the screen-sharing portal.
    NeedsScreenRecording,
    /// The screen can be seen but not controlled: macOS Accessibility is off.
    NeedsAccessibility,
    /// Capture was allowed but did not work: no display, no frame, a black frame, or an error.
    CaptureFailed,
}

/// The status a host reports and a viewer shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShareStatus {
    pub state: ShareState,
    /// One sentence for the person on the viewer, naming the host and the fix. Empty when ready.
    pub message: String,
    /// The pane the fix is in, for a host-side "Open Settings" (macOS `x-apple.systempreferences:`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settings: Option<String>,
    /// Whether a viewer sees the screen.
    pub can_view: bool,
    /// Whether a viewer's input reaches it.
    pub can_control: bool,
}

/// Which kind of host gathered the facts: the sentences name its own settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
// Each host OS builds only its own variants (the rule and its tests cover all of them).
#[allow(dead_code)]
pub enum HostOs {
    Mac,
    LinuxX11,
    LinuxPortal,
    Windows,
}

/// What one look at the display gave.
#[derive(Clone, Debug, PartialEq, Eq)]
// Each host OS probe makes only some of these (NoFrame is the Mac first-frame wait).
#[allow(dead_code)]
pub enum FrameProbe {
    /// Not looked at (`--frame no`, or the grant is already known missing).
    NotTried,
    /// A frame arrived; `black` when every sampled pixel is black.
    Frame { black: bool },
    /// The capture started but no frame arrived in time.
    NoFrame,
    /// The capture could not start.
    Failed(String),
}

/// The facts a host's probe gathered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    pub os: HostOs,
    /// The computer's name, as viewers list it.
    pub host: String,
    /// The app the OS lists the grant under ("cmux", or the screen sharing helper's name).
    pub grantee: String,
    /// macOS Screen Recording (None where the OS has no such grant).
    pub screen_recording: Option<bool>,
    /// macOS Accessibility (None where the OS has no such grant).
    pub accessibility: Option<bool>,
    /// The session asks for control, not only view.
    pub wants_control: bool,
    pub frame: FrameProbe,
}

const MAC_SCREEN_RECORDING_PANE: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
const MAC_ACCESSIBILITY_PANE: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

/// How long a frame probe waits for the first picture.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub const FRAME_PROBE_TIMEOUT_NS: u64 = 2_000_000_000;

/// The rule: no grant first (nothing else matters), then a capture that did not work, then
/// control without Accessibility (the screen still shows), else ready.
pub fn evaluate(f: &Facts) -> ShareStatus {
    let host = if f.host.trim().is_empty() { "This computer" } else { f.host.trim() };
    let cant = |why: &str| format!("{host} can't share its screen yet: {why}");
    if f.screen_recording == Some(false) {
        return ShareStatus {
            state: ShareState::NeedsScreenRecording,
            message: cant(&format!(
                "Screen Recording isn't allowed. On that Mac, open System Settings › Privacy & \
                 Security › Screen Recording and turn on {}.",
                f.grantee
            )),
            settings: Some(MAC_SCREEN_RECORDING_PANE.into()),
            can_view: false,
            can_control: false,
        };
    }
    let failed = |why: String, settings: Option<&str>| ShareStatus {
        state: ShareState::CaptureFailed,
        message: cant(&why),
        settings: settings.map(str::to_owned),
        can_view: false,
        can_control: false,
    };
    match (&f.frame, f.os) {
        (FrameProbe::Failed(reason), HostOs::LinuxPortal) if portal_declined(reason) => {
            return ShareStatus {
                state: ShareState::NeedsScreenRecording,
                message: cant(
                    "screen sharing wasn't allowed on that computer. Choose a screen in the \
                     sharing prompt there, then try again.",
                ),
                settings: None,
                can_view: false,
                can_control: false,
            };
        }
        (FrameProbe::Failed(reason), _) => {
            return failed(format!("{}.", sentence(reason)), None);
        }
        (FrameProbe::NoFrame, os) => {
            return failed(
                format!(
                    "no picture came from its display in 2 seconds.{}",
                    recheck_grant(os, &f.grantee)
                ),
                (os == HostOs::Mac).then_some(MAC_SCREEN_RECORDING_PANE),
            );
        }
        (FrameProbe::Frame { black: true }, os) => {
            return failed(
                format!("its screen comes through black.{}", recheck_grant(os, &f.grantee)),
                (os == HostOs::Mac).then_some(MAC_SCREEN_RECORDING_PANE),
            );
        }
        _ => {}
    }
    if f.wants_control && f.accessibility == Some(false) {
        return ShareStatus {
            state: ShareState::NeedsAccessibility,
            message: format!(
                "{host} shares its screen view only: Accessibility isn't allowed, so clicks and \
                 keys don't reach it. On that Mac, open System Settings › Privacy & Security › \
                 Accessibility and turn on {}.",
                f.grantee
            ),
            settings: Some(MAC_ACCESSIBILITY_PANE.into()),
            can_view: true,
            can_control: false,
        };
    }
    ShareStatus {
        state: ShareState::Ready,
        message: String::new(),
        settings: None,
        can_view: true,
        can_control: f.wants_control && f.os != HostOs::LinuxPortal,
    }
}

/// The hint after a missing or black picture: on a Mac, the grant (a grant macOS lists but has not
/// put into effect for the capturing process reads as black); elsewhere, a locked or asleep screen.
fn recheck_grant(os: HostOs, grantee: &str) -> String {
    match os {
        HostOs::Mac => format!(
            " On that Mac, check that System Settings › Privacy & Security › Screen Recording has \
             {grantee} turned on, and that the display is awake."
        ),
        HostOs::Windows => " Unlock that computer and wake its display, then try again.".into(),
        HostOs::LinuxX11 | HostOs::LinuxPortal => {
            " Wake that computer's display, then try again.".into()
        }
    }
}

/// A portal answer that means the person declined (or closed) the screen picker.
fn portal_declined(reason: &str) -> bool {
    let r = reason.to_ascii_lowercase();
    r.contains("cancel")
        || r.contains("denied")
        || r.contains("declined")
        || r.contains("did not allow")
}

/// `reason` as the end of a sentence: first letter kept, trailing punctuation dropped.
fn sentence(reason: &str) -> String {
    let trimmed = reason.trim().trim_end_matches(['.', '!', ':', ';']);
    if trimmed.is_empty() {
        "its screen capture did not start".into()
    } else {
        trimmed.into()
    }
}

/// Whether a sampled picture is black: every sample at most `black_level` plus a small margin
/// (encoder and scaler noise). A sleeping display, a blank grant and a locked secure desktop all
/// read this way; one bright pixel (a menu bar, a cursor drawn in) is enough to say not black.
pub fn is_black(samples: &[u8], black_level: u8) -> bool {
    !samples.is_empty() && samples.iter().all(|&s| s <= black_level.saturating_add(8))
}

/// Luma (BT.601, 0..255) of evenly spread pixels of a BGRX picture, about `cols * rows` of them.
pub fn bgrx_luma_grid(
    pixels: &[u8],
    width: usize,
    height: usize,
    stride: usize,
    cols: usize,
    rows: usize,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(cols * rows);
    if width == 0 || height == 0 || cols == 0 || rows == 0 {
        return out;
    }
    for r in 0..rows {
        let y = (r * 2 + 1) * height / (rows * 2);
        for c in 0..cols {
            let x = (c * 2 + 1) * width / (cols * 2);
            let at = y * stride + x * 4;
            if let Some(px) = pixels.get(at..at + 3) {
                let (b, g, r) = (u32::from(px[0]), u32::from(px[1]), u32::from(px[2]));
                out.push(((r * 77 + g * 150 + b * 29) >> 8) as u8);
            }
        }
    }
    out
}

/// `cmux-rd share-status [--scope view|control] [--frame yes|no] [--host NAME] [--grantee NAME]`:
/// gathers this host's facts and prints its [`ShareStatus`] as one JSON line. Exit 0 whatever the
/// state (the state is the answer); 1 only when the facts could not be read.
pub(crate) fn run(opts: &crate::args::Opts) -> Res<()> {
    let wants_control = match opts.str_or("scope", "control").as_str() {
        "view" => false,
        "control" => true,
        other => return Err(format!("scope {other}: use view or control").into()),
    };
    let frame = match opts.str_or("frame", "yes").as_str() {
        "yes" => true,
        "no" => false,
        other => return Err(format!("frame {other}: use yes or no").into()),
    };
    let host = opts.str_or("host", "");
    let grantee = opts.str_or("grantee", "cmux");
    let facts = probe::gather(probe::Ask { host, grantee, wants_control, frame })?;
    write_status(&mut std::io::stdout().lock(), &evaluate(&facts))
}

impl ShareStatus {
    /// The state's wire word (`needs_screen_recording`), for an app line's `status.state`.
    #[cfg_attr(not(feature = "link"), allow(dead_code))]
    pub fn state_word(&self) -> &'static str {
        match self.state {
            ShareState::Ready => "ready",
            ShareState::NeedsScreenRecording => "needs_screen_recording",
            ShareState::NeedsAccessibility => "needs_accessibility",
            ShareState::CaptureFailed => "capture_failed",
        }
    }
}

/// For `serve`, once a viewer said hello: the status that keeps this session from streaming
/// (no grant to capture), else None. Only the grants are read here: the session's own capture is
/// the frame probe, and its first-frame wait fails with its own reason.
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
pub(crate) fn blocking_session(
    scope: &str,
    host: Option<&str>,
    grantee: Option<&str>,
) -> Option<ShareStatus> {
    #[cfg(target_os = "macos")]
    {
        let grants = crate::permissions::read().ok()?;
        let status = evaluate(&Facts {
            os: HostOs::Mac,
            host: host.unwrap_or("This Mac").to_owned(),
            grantee: grantee.unwrap_or("cmux").to_owned(),
            screen_recording: Some(grants.screen_recording),
            accessibility: Some(grants.accessibility),
            wants_control: scope == "control",
            frame: FrameProbe::NotTried,
        });
        (!status.can_view).then_some(status)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (scope, host, grantee);
        None
    }
}

fn write_status(out: &mut impl Write, status: &ShareStatus) -> Res<()> {
    serde_json::to_writer(&mut *out, status)?;
    out.write_all(b"\n")?;
    Ok(())
}

mod probe {
    use super::*;

    pub struct Ask {
        pub host: String,
        pub grantee: String,
        pub wants_control: bool,
        pub frame: bool,
    }

    #[cfg(target_os = "macos")]
    pub fn gather(ask: Ask) -> Res<Facts> {
        let grants = crate::permissions::read()?;
        let host = if ask.host.is_empty() { "This Mac".to_owned() } else { ask.host };
        let frame =
            if !grants.screen_recording || !ask.frame { FrameProbe::NotTried } else { mac_frame() };
        Ok(Facts {
            os: HostOs::Mac,
            host,
            grantee: ask.grantee,
            screen_recording: Some(grants.screen_recording),
            accessibility: Some(grants.accessibility),
            wants_control: ask.wants_control,
            frame,
        })
    }

    #[cfg(target_os = "macos")]
    fn mac_frame() -> FrameProbe {
        // A small, slow capture: the probe needs one picture, not a stream.
        let mut capture =
            match crate::mac::capture::Capture::start_for_session("main", 10, Some(640), false) {
                Ok(c) => c,
                Err(e) => return FrameProbe::Failed(e.to_string()),
            };
        if capture.ready(FRAME_PROBE_TIMEOUT_NS).is_err() {
            return FrameProbe::NoFrame;
        }
        match capture.frames().newest().and_then(|(frame, _)| frame.luma_grid(32, 18)) {
            // 420v is video range: black is 16.
            Some(samples) => FrameProbe::Frame { black: is_black(&samples, 16) },
            None => FrameProbe::Failed("the captured frame could not be read".into()),
        }
    }

    #[cfg(target_os = "linux")]
    pub fn gather(ask: Ask) -> Res<Facts> {
        // The same rule as `CaptureBackend::choose`: a Wayland session captures through the portal.
        let wayland = std::env::var("XDG_SESSION_TYPE")
            .is_ok_and(|kind| kind.trim().eq_ignore_ascii_case("wayland"));
        let host = if ask.host.is_empty() { hostname() } else { ask.host };
        let (os, frame) = if wayland {
            // The portal asks the person at the screen on every new session, so the probe only
            // checks that the portal is there; the session's own status reports a decline.
            (HostOs::LinuxPortal, portal_present())
        } else {
            let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into());
            (HostOs::LinuxX11, if ask.frame { x11_frame(&display) } else { FrameProbe::NotTried })
        };
        Ok(Facts {
            os,
            host,
            grantee: ask.grantee,
            screen_recording: None,
            accessibility: None,
            wants_control: ask.wants_control,
            frame,
        })
    }

    #[cfg(target_os = "linux")]
    fn x11_frame(display: &str) -> FrameProbe {
        let mut capturer = match crate::capture::Capturer::new(display, false) {
            Ok(c) => c,
            Err(e) => {
                return FrameProbe::Failed(format!(
                    "the X display {display} could not be opened ({e})"
                ))
            }
        };
        let (w, h) = (capturer.width & !1, capturer.height & !1);
        let rect = crate::capture::Rect { x: 0, y: 0, w, h };
        match capturer.grab(rect) {
            Ok(pixels) => {
                let samples =
                    bgrx_luma_grid(pixels, w as usize, h as usize, w as usize * 4, 32, 18);
                FrameProbe::Frame { black: is_black(&samples, 0) }
            }
            Err(e) => {
                FrameProbe::Failed(format!("the X display {display} could not be read ({e})"))
            }
        }
    }

    #[cfg(all(target_os = "linux", feature = "portal"))]
    fn portal_present() -> FrameProbe {
        match crate::portal::ZbusPortal::connect() {
            Ok(_) => FrameProbe::NotTried,
            Err(e) => FrameProbe::Failed(e.to_string()),
        }
    }

    #[cfg(all(target_os = "linux", not(feature = "portal")))]
    fn portal_present() -> FrameProbe {
        FrameProbe::Failed(crate::capture_backend::PORTAL_NOT_BUILT_IN.to_owned())
    }

    #[cfg(target_os = "linux")]
    fn hostname() -> String {
        std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_owned()).unwrap_or_default()
    }

    #[cfg(windows)]
    pub fn gather(ask: Ask) -> Res<Facts> {
        let host = if ask.host.is_empty() {
            std::env::var("COMPUTERNAME").unwrap_or_default()
        } else {
            ask.host
        };
        let frame = if ask.frame {
            match crate::windows::probe_frame() {
                Ok(samples) => FrameProbe::Frame { black: is_black(&samples, 0) },
                Err(e) => FrameProbe::Failed(e.to_string()),
            }
        } else {
            FrameProbe::NotTried
        };
        Ok(Facts {
            os: HostOs::Windows,
            host,
            grantee: ask.grantee,
            screen_recording: None,
            accessibility: None,
            wants_control: ask.wants_control,
            frame,
        })
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    pub fn gather(_ask: Ask) -> Res<Facts> {
        Err("screen sharing status is read only on macOS, Linux and Windows".into())
    }
}

#[cfg(test)]
#[path = "share_status_tests.rs"]
mod tests;
