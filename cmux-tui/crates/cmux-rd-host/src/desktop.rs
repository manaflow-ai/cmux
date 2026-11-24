//! The desktop a session streams, in two halves for one OS, so the media session (stream.rs)
//! and the shared engine (cmux-rd-engine) are the same on every host: [`Desktop`] (damage and
//! input injection, on the session's loop thread) and [`FrameSource`] (capture and encode, on
//! the session's encode thread, encode_thread.rs), so viewer input never waits behind an
//! encode. Linux: X11 damage, XShm and XTest (`x11.rs`). macOS: ScreenCaptureKit, VideoToolbox
//! from the captured IOSurface, and CGEvent (`mac/`).

use crate::stream::SessionCfg;
use crate::Res;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_proto::InputEvent;
use std::os::fd::RawFd;

/// The capture and encode half: runs on the session's encode thread. It owns its own capture
/// connection, or a handle to the capture's shared newest picture, never the input side.
pub trait FrameSource: Send {
    /// Captures `damage` (the source may capture more) into the picture the next
    /// [`FrameSource::encode`] encodes.
    fn capture(&mut self, damage: Rect) -> Res<()>;
    /// For the picked picture: when the display showed it and when the capture handed it over, on
    /// the protocol clock in µs, where the source knows them (measurement only: `CMUX_RD_TIMING_LOG`).
    fn picked_times(&self) -> Option<(u64, u64)> {
        None
    }
    /// Encodes the captured picture into `out` as Annex-B. Returns true for an IDR.
    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool>;
    fn set_bitrate(&mut self, kbps: u32);
    /// The encoder profile for the next frame, and whether that frame refines a still screen
    /// (ultra). An encoder without an ultra mode keeps its settings.
    fn set_profile(&mut self, _profile: EncodeProfile, _refine: bool) {}
    /// Whether [`FrameSource::set_profile`] changes the encoder's settings. A source without an
    /// ultra mode says no, and the stats line then names no profile rather than one it never ran.
    fn applies_profile(&self) -> bool {
        false
    }
    /// Pixels of damage in the next frame (ultra's frame-size guard sizes the frame from it).
    fn set_changed_pixels(&mut self, _pixels: u64) {}
    fn kbps(&self) -> u32;
    fn encoder_name(&self) -> String;
    /// The picture the next [`FrameSource::encode`] makes, from the engine's resolution ladder
    /// (design D5): its size (the source scales the stream down to it) and QP ceiling. Set
    /// before each capture; `None` (no ladder): the full stream, no ceiling. The default
    /// ignores it and encodes the full stream (the Linux and Windows sources today; the macOS
    /// source scales on the GPU).
    fn set_picture(&mut self, _picture: Option<cmux_rd_core::resolution::Picture>) {}
    /// Why the last [`FrameSource::encode`] made an IDR it was not asked for (the encoder's
    /// [`cmux_encode::VideoEncoder::idr_cause`]).
    fn idr_cause(&self) -> Option<&'static str> {
        None
    }
}

/// Both halves of one opened desktop.
pub type Halves = (Box<dyn Desktop>, Box<dyn FrameSource>);

/// The loop thread's half: what changed on screen, and the viewer's input.
pub trait Desktop {
    /// The streamed size in pixels (even).
    fn size(&self) -> (u32, u32);
    /// Readable when [`Desktop::drain`] has damage to report.
    fn fd(&self) -> RawFd;
    /// Takes every damage report queued since the last call, without blocking.
    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()>;
    /// Injects one viewer event as local input.
    fn inject(&mut self, event: &InputEvent) -> Res<()>;
    /// Releases every key and button the viewer holds.
    fn release_all(&mut self) -> Res<()>;
    /// Timed input work (Linux: a press waiting behind the agent's held button, removing
    /// the person master once idle). Returns when the session loop should call again.
    fn pump(&mut self) -> Res<Option<std::time::Duration>> {
        Ok(None)
    }
    /// SECURITY: called once before the session's first frame, on a desktop that may have opened
    /// before the app's newest `exclude_windows` line (`cmux-rd serve` opens it during the
    /// handshake): returns once the newest picture leaves those windows out (macOS), else the
    /// session ends. Desktops without window exclusions have nothing to wait for.
    fn ready_for_start(&mut self) -> Res<()> {
        Ok(())
    }
    /// Reads the cursor, for a desktop opened with cursor metadata (cap `cursor`): it left
    /// the cursor out of its pictures. `None`: this desktop draws the cursor in the picture.
    fn cursor(&mut self) -> Option<crate::cursor::CursorSample> {
        None
    }
}

/// Whether this OS's desktop can report the cursor as metadata (`Desktop::cursor`), so a
/// host offers the `cursor` cap: macOS reads the system cursor; Linux does not yet (X11
/// and the portal keep their own cursor handling).
pub fn reports_cursor() -> bool {
    #[cfg(target_os = "macos")]
    {
        synthetic_size().is_none() && crate::mac::cursor::available()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Whether this OS's frame source encodes the resolution ladder's smaller picture
/// (`FrameSource::set_picture`), so a host offers the `video.scaled` cap: the macOS capture
/// and synthetic sources scale on the GPU; the Linux and Windows sources always encode the
/// full stream.
pub fn scales_pictures() -> bool {
    #[cfg(target_os = "macos")]
    {
        true
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
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

/// The desktop of this OS. `cursor_metadata`: the viewer draws the cursor (cap `cursor`), so
/// a desktop that [`reports_cursor`] leaves it out of its pictures.
pub fn open(cfg: &SessionCfg, cursor_metadata: bool) -> Res<Halves> {
    #[cfg(not(target_os = "macos"))]
    let _ = cursor_metadata;
    // The portal shares what the person picks in its dialog; it cannot be told one window.
    #[cfg(target_os = "linux")]
    if let (crate::capture_backend::CaptureBackend::Portal, Some(id)) = (cfg.capture, cfg.window) {
        return Err(format!(
            "window {id:#x}: sharing one window needs X11 capture (this session uses the portal)"
        )
        .into());
    }
    #[cfg(target_os = "linux")]
    return match cfg.capture {
        crate::capture_backend::CaptureBackend::X11 => crate::x11::open(cfg),
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
            crate::portal::open_desktop(cfg, opts)
        }
        // A build without the portal backend ends the session with a clear reason.
        #[cfg(not(feature = "portal"))]
        backend @ crate::capture_backend::CaptureBackend::Portal => match backend.available() {
            Ok(()) => Err("portal capture has no desktop yet".into()),
            Err(reason) => Err(reason.into()),
        },
    };
    #[cfg(all(target_os = "macos", feature = "bench"))]
    if let Some(source) = crate::synthetic::selected() {
        return crate::mac::synthetic::open(cfg, source);
    }
    #[cfg(target_os = "macos")]
    return crate::mac::open(cfg, cursor_metadata);
}

/// The size of the generated picture `--source synthetic` picked instead of the display (macOS
/// bench builds; src/synthetic.rs), else None.
#[cfg(target_os = "macos")]
fn synthetic_size() -> Option<(u32, u32)> {
    #[cfg(feature = "bench")]
    return crate::synthetic::selected().map(|source| source.size);
    #[cfg(not(feature = "bench"))]
    None
}

/// The displays a viewer may pick, the index of the one `which` picks, and their
/// CGDirectDisplayIDs (macOS). A synthetic source is one display of its own size, listed without
/// asking ScreenCaptureKit (which needs the grant), with no id.
#[cfg_attr(not(feature = "link"), allow(dead_code))]
#[cfg(target_os = "macos")]
pub fn displays(which: &str) -> Res<crate::mac::capture::Displays> {
    match synthetic_size() {
        Some(size) => Ok((vec![size], 0, Vec::new())),
        None => crate::mac::capture::displays(which),
    }
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
    return match synthetic_size() {
        Some(_) => crate::mac::capture::FALLBACK_FPS,
        None => crate::mac::capture::refresh_fps(display),
    };
}
