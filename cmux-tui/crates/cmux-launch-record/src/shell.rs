//! The stage-0 launch window's plan (docs/design/launch-shell-first.md, "Decision: stage 0 is
//! its own window"): whether it shows, at which frame, and whether the saved image may be drawn or
//! is stale (then the plain shell: chrome and background, no image). Ported from cmux-launch-shell
//! (cmux#45089) so the record and its one plan live in one crate. Nothing here touches AppKit.
use std::ffi::c_char;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::{Frame, LaunchRecord, WindowView, c_string, frame_is_usable};

/// The image is drawn only when its pixel size is the frame times the scale, within this.
pub const IMAGE_SIZE_TOLERANCE_PX: i64 = 1;
/// Files in the support directory that show an earlier launch left state, so a missing record
/// means it was lost rather than never written (`Reason::NoRecordPriorState`).
pub const PRIOR_STATE_MARKERS: &[&str] = &["launch-times.jsonl"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Appearance {
    Light = 0,
    Dark = 1,
}

impl Appearance {
    pub fn from_u8(v: u8) -> Self {
        if v == 1 { Self::Dark } else { Self::Light }
    }
}

/// A display as the app sees it now. The plan matches displays by frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Display {
    pub frame: Frame,
    pub scale: f64,
}

/// What is true at this launch.
#[derive(Debug, Clone, Copy)]
pub struct Now<'a> {
    /// The running app's build (CFBundleVersion and commit), the first part of every image key.
    pub build: &'a str,
    pub appearance: Appearance,
    pub displays: &'a [Display],
    /// Where `PRIOR_STATE_MARKERS` live; `None` skips that check.
    pub support_dir: Option<&'a Path>,
}

/// One saved window, as the launch record holds it. A v1 record has no scale or key
/// (`backing_scale` 0, `image_key` empty).
#[derive(Debug, Clone, PartialEq)]
pub struct SavedWindow {
    pub id: String,
    pub frame: Frame,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub backing_scale: f64,
    pub appearance: Appearance,
    /// The theme follows the system's appearance, so a changed system appearance makes the image stale.
    pub appearance_follows_system: bool,
    /// The display the window was on, when written.
    pub screen_frame: Frame,
    pub fullscreen: bool,
    /// `<build>/<window_id>/<generation>`: the image's file is `<image_dir>/<key>.png`.
    pub image_key: String,
}

impl SavedWindow {
    pub fn from_view(w: &WindowView<'_>) -> Self {
        Self {
            id: w.id.to_owned(),
            frame: w.frame,
            background_rgba: w.background_rgba,
            bar_rgba: w.bar_rgba,
            backing_scale: w.backing_scale,
            appearance: Appearance::from_u8(w.appearance),
            appearance_follows_system: w.appearance_follows_system != 0,
            screen_frame: w.screen_frame,
            fullscreen: w.fullscreen != 0,
            image_key: w.image_key.to_owned(),
        }
    }
}

/// The saved windows of a launch record, front first. A v1 record's windows read with scale 0
/// and no key, so their images are stale (`Reason::BuildDiffers`).
pub fn saved_windows(record: &LaunchRecord) -> Vec<SavedWindow> {
    record.windows().map(|w| SavedWindow::from_view(&w)).collect()
}

/// Why the plan is what it is. Only `Image` draws the saved image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Reason {
    Image = 0,
    NoRecord = 1,
    NoWindows = 2,
    /// Another build's image, or a v1 record (no build in its key).
    BuildDiffers = 3,
    LayoutDiffers = 4,
    ScaleDiffers = 5,
    AppearanceDiffers = 6,
    ImageUnreadable = 7,
    ImageSizeDiffers = 8,
    FullScreen = 9,
    /// No readable record, but an earlier launch left state (`PRIOR_STATE_MARKERS`).
    NoRecordPriorState = 10,
}

impl Reason {
    /// Stage 0 makes a window at all. Not when the real window's place cannot be known without
    /// the services (its display changed, it was full screen, or a record that should exist is
    /// gone): a window there would jump at the swap, so the launch is today's.
    pub fn shows_window(self) -> bool {
        !matches!(self, Self::NoRecordPriorState | Self::LayoutDiffers | Self::FullScreen)
    }

    /// No saved frame (a first launch, or no window was open): the app's default frame.
    pub fn uses_default_frame(self) -> bool {
        matches!(self, Self::NoRecord | Self::NoWindows)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    /// The front saved window, when there is one.
    pub window: Option<SavedWindow>,
    /// The image to draw; set only for `Reason::Image`.
    pub image: Option<PathBuf>,
    pub reason: Reason,
}

/// Decides stage 0 from the saved windows (front first; `None`: no readable record).
pub fn plan(windows: Option<&[SavedWindow]>, image_dir: &Path, now: &Now<'_>) -> Plan {
    let Some(windows) = windows else {
        let prior = now.support_dir.is_some_and(has_prior_state);
        let reason = if prior { Reason::NoRecordPriorState } else { Reason::NoRecord };
        return Plan { window: None, image: None, reason };
    };
    let Some(front) = windows.first().filter(|w| frame_is_usable(w.frame)) else {
        return Plan { window: None, image: None, reason: Reason::NoWindows };
    };
    let (image, reason) = match image_for(front, image_dir, now) {
        Ok(path) => (Some(path), Reason::Image),
        Err(reason) => (None, reason),
    };
    Plan { window: Some(front.clone()), image, reason }
}

fn has_prior_state(dir: &Path) -> bool {
    PRIOR_STATE_MARKERS.iter().any(|m| std::fs::metadata(dir.join(m)).is_ok_and(|m| m.is_file()))
}

/// The window's saved image when it may be drawn now, else the first reason it may not. The
/// reasons that make no window (full screen, layout) come first, so a stale image never puts a
/// window where the real one will not open; the plain-shell reasons follow in numeric order.
pub fn image_for(w: &SavedWindow, image_dir: &Path, now: &Now<'_>) -> Result<PathBuf, Reason> {
    // A v1 record has no scale: it cannot say which build or display its image is for.
    if !(w.backing_scale > 0.0 && w.backing_scale.is_finite()) {
        return Err(Reason::BuildDiffers);
    }
    if w.fullscreen {
        return Err(Reason::FullScreen);
    }
    let display =
        now.displays.iter().find(|d| d.frame == w.screen_frame).ok_or(Reason::LayoutDiffers)?;
    if now.build.is_empty() || w.image_key.split('/').next() != Some(now.build) {
        return Err(Reason::BuildDiffers);
    }
    if display.scale != w.backing_scale {
        return Err(Reason::ScaleDiffers);
    }
    if w.appearance_follows_system && w.appearance != now.appearance {
        return Err(Reason::AppearanceDiffers);
    }
    let key = ImageKey::parse(&w.image_key).ok_or(Reason::ImageUnreadable)?;
    if key.window_id != w.id {
        return Err(Reason::ImageUnreadable);
    }
    let path = key.path(image_dir);
    let (width, height) = png_size(&path).ok_or(Reason::ImageUnreadable)?;
    let expected = |points: f64| (points * w.backing_scale).round() as i64;
    if (i64::from(width) - expected(w.frame.width)).abs() > IMAGE_SIZE_TOLERANCE_PX
        || (i64::from(height) - expected(w.frame.height)).abs() > IMAGE_SIZE_TOLERANCE_PX
    {
        return Err(Reason::ImageSizeDiffers);
    }
    Ok(path)
}

/// An image-store key, `<build>/<window_id>/<generation>`. Each part is one path component, so a
/// key never names a file outside the store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageKey<'a> {
    pub build: &'a str,
    pub window_id: &'a str,
    pub generation: u64,
}

impl<'a> ImageKey<'a> {
    pub fn parse(key: &'a str) -> Option<Self> {
        let mut parts = key.split('/');
        let (build, window_id, generation) = (parts.next()?, parts.next()?, parts.next()?);
        if parts.next().is_some() || !is_component(build) || !is_component(window_id) {
            return None;
        }
        if generation.is_empty() || !generation.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Some(Self { build, window_id, generation: generation.parse().ok()? })
    }

    pub fn format(build: &str, window_id: &str, generation: u64) -> Option<String> {
        (is_component(build) && is_component(window_id))
            .then(|| format!("{build}/{window_id}/{generation}"))
    }

    pub fn path(&self, image_dir: &Path) -> PathBuf {
        image_dir.join(self.build).join(self.window_id).join(format!("{}.png", self.generation))
    }
}

fn is_component(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.len() <= 128
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'+'))
}

/// A PNG's pixel size from its first 24 bytes (signature and IHDR); never reads the image.
pub fn png_size(path: &Path) -> Option<(u32, u32)> {
    let mut head = [0u8; 24];
    File::open(path).ok()?.read_exact(&mut head).ok()?;
    if head[..8] != *b"\x89PNG\r\n\x1a\n" || head[12..16] != *b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(head[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(head[20..24].try_into().ok()?);
    (width > 0 && height > 0).then_some((width, height))
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchShellDisplay {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

#[repr(C)]
pub struct CmuxLaunchShellNow {
    /// NUL-terminated UTF-8: the running app's build.
    pub build: *const c_char,
    /// 0 light, 1 dark: the system's appearance now.
    pub appearance: u8,
    pub displays: *const CmuxLaunchShellDisplay,
    pub display_count: usize,
    /// Null, or the NUL-terminated directory holding `PRIOR_STATE_MARKERS`.
    pub support_dir: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchShellPlan {
    pub frame_x: f64,
    pub frame_y: f64,
    pub frame_width: f64,
    pub frame_height: f64,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub appearance: u8,
    /// `Reason` (0 image, 1 no record, 2 no windows, 3 build, 4 layout, 5 scale, 6 appearance,
    /// 7 image unreadable, 8 image size, 9 full screen, 10 no record but prior state).
    pub reason: u8,
    pub shows_window: bool,
    /// No saved frame: the app's default frame.
    pub uses_default_frame: bool,
    pub window_id: [c_char; 65],
    /// Empty unless `reason` is 0.
    pub image_path: [c_char; 1025],
}

impl Default for CmuxLaunchShellPlan {
    fn default() -> Self {
        Self {
            frame_x: 0.0,
            frame_y: 0.0,
            frame_width: 0.0,
            frame_height: 0.0,
            background_rgba: [0; 4],
            bar_rgba: [0; 4],
            appearance: 0,
            reason: Reason::NoRecord as u8,
            shows_window: false,
            uses_default_frame: false,
            window_id: [0; 65],
            image_path: [0; 1025],
        }
    }
}

fn copy_fit(dst: &mut [c_char], s: &str) -> bool {
    if s.len() >= dst.len() || s.contains('\0') {
        return false;
    }
    for (d, b) in dst.iter_mut().zip(s.bytes()) {
        *d = b as c_char;
    }
    dst[s.len()] = 0;
    true
}

/// The displays of a `CmuxLaunchShellNow`; null or a count of 0 is none.
///
/// # Safety
/// A non-null `p` is valid for reads of `n` displays.
pub(crate) unsafe fn displays_from_c(p: *const CmuxLaunchShellDisplay, n: usize) -> Vec<Display> {
    if p.is_null() || n == 0 {
        return Vec::new();
    }
    unsafe { std::slice::from_raw_parts(p, n) }
        .iter()
        .map(|d| Display {
            frame: Frame { x: d.x, y: d.y, width: d.width, height: d.height },
            scale: d.scale,
        })
        .collect()
}

/// Fills `out` with stage 0's plan from the launch record at `record_path` and the image store
/// at `image_dir`. False only for a null `out` or `now`, or a non-UTF-8 argument; a missing or
/// unreadable record is a plan (`reason` 1, or 10 with prior state in `now.support_dir`), not a
/// failure. A plan whose id does not fit comes back as no windows (`reason` 2); one whose image
/// path does not fit comes back without the image (`reason` 7).
///
/// # Safety
/// `record_path`, `image_dir`, `now.build` and `now.support_dir` are null or NUL-terminated
/// strings; `now.displays` is valid for reads of `now.display_count` displays (or null with a
/// count of 0); `out` is null or valid for writes of one `CmuxLaunchShellPlan`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_shell_plan(
    record_path: *const c_char,
    image_dir: *const c_char,
    now: *const CmuxLaunchShellNow,
    out: *mut CmuxLaunchShellPlan,
) -> bool {
    if out.is_null() || now.is_null() {
        return false;
    }
    let o = unsafe { &mut *out };
    *o = CmuxLaunchShellPlan::default();
    let now = unsafe { &*now };
    let (Some(build), Some(record_path), Some(image_dir)) =
        (unsafe { c_string(now.build) }, unsafe { c_string(record_path) }, unsafe {
            c_string(image_dir)
        })
    else {
        return false;
    };
    let support_dir = if now.support_dir.is_null() {
        None
    } else {
        let Some(dir) = (unsafe { c_string(now.support_dir) }) else { return false };
        Some(Path::new(dir))
    };
    let displays = unsafe { displays_from_c(now.displays, now.display_count) };
    let now = Now {
        build,
        appearance: Appearance::from_u8(now.appearance),
        displays: &displays,
        support_dir,
    };
    let windows = LaunchRecord::read(record_path).map(|r| saved_windows(&r));
    let plan = plan(windows.as_deref(), Path::new(image_dir), &now);
    let mut reason = plan.reason;
    if let Some(w) = &plan.window {
        if !copy_fit(&mut o.window_id, &w.id) {
            reason = Reason::NoWindows;
            *o = CmuxLaunchShellPlan {
                reason: reason as u8,
                shows_window: reason.shows_window(),
                uses_default_frame: reason.uses_default_frame(),
                ..Default::default()
            };
            return true;
        }
        (o.frame_x, o.frame_y, o.frame_width, o.frame_height) =
            (w.frame.x, w.frame.y, w.frame.width, w.frame.height);
        (o.background_rgba, o.bar_rgba, o.appearance) =
            (w.background_rgba, w.bar_rgba, w.appearance as u8);
    }
    if let Some(path) = &plan.image
        && !path.to_str().is_some_and(|p| copy_fit(&mut o.image_path, p))
    {
        o.image_path[0] = 0;
        reason = Reason::ImageUnreadable;
    }
    o.reason = reason as u8;
    o.shows_window = reason.shows_window();
    o.uses_default_frame = reason.uses_default_frame();
    true
}

#[cfg(test)]
mod tests;
