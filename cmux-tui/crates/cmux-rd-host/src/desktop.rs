//! The desktop a session streams: capture, encode and input injection for one OS behind
//! one trait, so the media session (stream.rs) and the shared engine (cmux-rd-engine) are
//! the same on every host. Linux: X11 damage, XShm and XTest (`x11.rs`). macOS:
//! ScreenCaptureKit, VideoToolbox from the captured IOSurface, and CGEvent (`mac/`).

use crate::stream::SessionCfg;
use crate::Res;
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use std::os::fd::RawFd;

pub trait Desktop {
    /// The streamed size in pixels (even).
    fn size(&self) -> (u32, u32);
    /// Readable when [`Desktop::drain`] has damage to report.
    fn fd(&self) -> RawFd;
    /// Takes every damage report queued since the last call, without blocking.
    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()>;
    /// Captures `damage` (the source may capture more) into the picture the next
    /// [`Desktop::encode`] encodes.
    fn capture(&mut self, damage: Rect) -> Res<()>;
    /// For the picked picture: when the display showed it and when the capture handed it over, on
    /// the protocol clock in µs, where the source knows them (measurement only: `CMUX_RD_TIMING_LOG`).
    fn picked_times(&self) -> Option<(u64, u64)> {
        None
    }
    /// Encodes the captured picture into `out` as Annex-B. Returns true for an IDR.
    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool>;
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn encoder_name(&self) -> String;
    /// Injects one viewer event as local input.
    fn inject(&mut self, event: &InputEvent) -> Res<()>;
    /// Releases every key and button the viewer holds.
    fn release_all(&mut self) -> Res<()>;
    /// Timed input work (Linux: a press waiting behind the agent's held button, removing
    /// the person master once idle). Returns when the session loop should call again.
    fn pump(&mut self) -> Res<Option<std::time::Duration>> {
        Ok(None)
    }
}

/// Receives capture setup states (`state` code, sentence) while a desktop opens: `cmux-rd serve`
/// prints them as `{"status":..}` lines for the app. Unset, the portal logs them on stderr.
/// Only the portal backend (feature `portal`, Linux) has setup states.
#[cfg(all(feature = "portal", target_os = "linux"))]
pub type StatusSink = Box<dyn Fn(&str, &str) + Send + Sync>;

#[cfg(all(feature = "portal", target_os = "linux"))]
static STATUS_SINK: std::sync::OnceLock<StatusSink> = std::sync::OnceLock::new();

/// Sets the process's status sink (once; later calls are ignored).
#[cfg(all(feature = "portal", target_os = "linux", feature = "link"))]
pub fn set_status_sink(sink: StatusSink) {
    let _ = STATUS_SINK.set(sink);
}

/// The stable status code and sentence of one portal handshake state.
#[cfg(all(feature = "portal", target_os = "linux"))]
pub(crate) fn portal_status(state: &crate::portal::PortalState) -> (&'static str, String) {
    use crate::portal::PortalState;
    let code = match state {
        PortalState::Connecting => "connecting",
        PortalState::CreatingSession => "creating_session",
        PortalState::Restoring => "restoring",
        PortalState::WaitingForConsent => "waiting_for_consent",
        PortalState::Streaming { .. } => "streaming",
    };
    (code, state.message())
}

#[cfg(all(test, feature = "portal", target_os = "linux"))]
mod tests {
    use crate::portal::PortalState;

    #[test]
    fn waiting_for_consent_reaches_the_app_as_a_status() {
        let (code, message) = super::portal_status(&PortalState::WaitingForConsent);
        assert_eq!(code, "waiting_for_consent");
        assert!(message.contains("allow sharing"), "{message}");
        assert_eq!(
            super::portal_status(&PortalState::Streaming { width: 4, height: 2 }).0,
            "streaming"
        );
    }
}

/// The desktop of this OS.
pub fn open(cfg: &SessionCfg) -> Res<Box<dyn Desktop>> {
    #[cfg(target_os = "linux")]
    return match cfg.capture {
        crate::capture_backend::CaptureBackend::X11 => {
            Ok(Box::new(crate::x11::X11Desktop::open(cfg)?))
        }
        // Wayland: xdg-desktop-portal ScreenCast and PipeWire (view-only). Its handshake
        // states (the person at the screen still has to allow sharing) go to the status sink.
        #[cfg(feature = "portal")]
        crate::capture_backend::CaptureBackend::Portal => {
            let mut opts = crate::portal::PortalOpts::default();
            if let Some(sink) = STATUS_SINK.get() {
                opts.on_state = Some(Box::new(move |state: crate::portal::PortalState| {
                    let (code, message) = portal_status(&state);
                    sink(code, &message);
                }));
            }
            Ok(Box::new(crate::portal::PortalDesktop::open(cfg, opts)?))
        }
        // A build without the portal backend ends the session with a clear reason.
        #[cfg(not(feature = "portal"))]
        backend @ crate::capture_backend::CaptureBackend::Portal => match backend.available() {
            Ok(()) => Err("portal capture has no desktop yet".into()),
            Err(reason) => Err(reason.into()),
        },
    };
    #[cfg(target_os = "macos")]
    return Ok(Box::new(crate::mac::MacDesktop::open(cfg)?));
}

/// The frame rate cap when neither `--max-fps` nor the viewer names one: macOS, the captured
/// display's refresh rate (120 on a 120 Hz panel), or 60 when it reads 0 or cannot be read; Linux,
/// 60 for the virtual X display.
pub fn default_max_fps(display: &str) -> u32 {
    #[cfg(target_os = "linux")]
    {
        let _ = display;
        60
    }
    #[cfg(target_os = "macos")]
    return crate::mac::capture::refresh_fps(display);
}
