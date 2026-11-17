//! What the stage-0 launch window shows (docs/design/launch-shell-first.md, "Decision: stage 0 is
//! its own window"): whether it shows at all, at which frame, and whether the saved image may be
//! drawn or is stale (then the plain shell: chrome and background, no image). The record's format
//! is cmux-launch-record's; this crate decides from the windows it reads.
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

/// A rectangle in screen points (AppKit's coordinates).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// The image is drawn only when its pixel size is the frame times the scale, within this.
pub const IMAGE_SIZE_TOLERANCE_PX: i64 = 1;

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

/// A display as the app sees it now.
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
    /// `<build>/<window_id>/<generation>`: the image's file is `<image_dir>/<window_id>.<generation>.png`.
    pub image_key: String,
}

/// Why the plan is what it is. Only `Image` draws the saved image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Reason {
    Image = 0,
    /// No record and no state of an earlier run (`launch-times.jsonl`): a first launch ever.
    FreshInstall = 1,
    NoWindows = 2,
    /// The image's key names another build, or the record is v1 (no key).
    BuildDiffers = 3,
    LayoutDiffers = 4,
    ScaleDiffers = 5,
    AppearanceDiffers = 6,
    ImageUnreadable = 7,
    ImageSizeDiffers = 8,
    FullScreen = 9,
    /// No record, but an earlier run left its state: an upgrade from a build without the writer,
    /// whose session can restore a window anywhere.
    Upgrade = 10,
}

impl Reason {
    /// Stage 0 makes a window at all. Not when the real window's place cannot be known without
    /// the services (its display changed, it was full screen, or an earlier run's session the
    /// record never saw restores it): a window there would jump at the swap, so the launch is today's.
    pub fn shows_window(self) -> bool {
        !matches!(self, Self::Upgrade | Self::LayoutDiffers | Self::FullScreen)
    }

    /// Nothing to restore (a first launch ever, or no window open at the last quit): the app's
    /// default frame and the bare launch's content.
    pub fn uses_default_frame(self) -> bool {
        matches!(self, Self::FreshInstall | Self::NoWindows)
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
/// `prior_state`: an earlier run left its state beside the record (`launch-times.jsonl`).
pub fn plan(
    windows: Option<&[SavedWindow]>,
    prior_state: bool,
    image_dir: &Path,
    now: &Now<'_>,
) -> Plan {
    let Some(windows) = windows else {
        let reason = if prior_state { Reason::Upgrade } else { Reason::FreshInstall };
        return Plan { window: None, image: None, reason };
    };
    let Some(front) = windows.first().filter(|w| frame_is_usable(&w.frame)) else {
        return Plan { window: None, image: None, reason: Reason::NoWindows };
    };
    let (image, reason) = match image_for(front, image_dir, now) {
        Ok(path) => (Some(path), Reason::Image),
        Err(reason) => (None, reason),
    };
    Plan { window: Some(front.clone()), image, reason }
}

fn image_for(w: &SavedWindow, image_dir: &Path, now: &Now<'_>) -> Result<PathBuf, Reason> {
    // A v1 window has no scale, display or key: its image is stale, its frame still stands.
    if !(w.backing_scale > 0.0 && w.backing_scale.is_finite()) {
        return Err(Reason::BuildDiffers);
    }
    if w.fullscreen {
        return Err(Reason::FullScreen);
    }
    let display =
        now.displays.iter().find(|d| d.frame == w.screen_frame).ok_or(Reason::LayoutDiffers)?;
    if display.scale != w.backing_scale {
        return Err(Reason::ScaleDiffers);
    }
    let key = ImageKey::parse(&w.image_key).ok_or(Reason::ImageUnreadable)?;
    if key.build != now.build {
        return Err(Reason::BuildDiffers);
    }
    if key.window_id != w.id {
        return Err(Reason::ImageUnreadable);
    }
    if w.appearance_follows_system && w.appearance != now.appearance {
        return Err(Reason::AppearanceDiffers);
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

fn frame_is_usable(f: &Frame) -> bool {
    [f.x, f.y, f.width, f.height].iter().all(|n| n.is_finite()) && f.width > 0.0 && f.height > 0.0
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

    /// The image store's file for this key (cmux-launch-image: one flat folder, a path per window
    /// and generation, never reused). The build is not in the path: it is checked from the key, and
    /// the new build's first publish replaces the old images.
    pub fn path(&self, image_dir: &Path) -> PathBuf {
        image_dir.join(format!("{}.{}.png", self.window_id, self.generation))
    }
}

fn is_component(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.len() <= 128
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'+'))
}

/// The launch record's windows, front first, as the plan reads them. A v1 record's carry no scale
/// or key (`backing_scale` 0), so their image is stale and their frame stands.
pub fn saved_windows(record: &cmux_launch_record::LaunchRecord) -> Vec<SavedWindow> {
    let frame =
        |f: cmux_launch_record::Frame| Frame { x: f.x, y: f.y, width: f.width, height: f.height };
    record
        .windows()
        .map(|w| SavedWindow {
            id: w.id.to_owned(),
            frame: frame(w.frame),
            background_rgba: w.background_rgba,
            bar_rgba: w.bar_rgba,
            backing_scale: w.backing_scale,
            appearance: Appearance::from_u8(w.appearance),
            appearance_follows_system: w.appearance_follows_system != 0,
            screen_frame: frame(w.screen_frame),
            fullscreen: w.fullscreen != 0,
            image_key: w.image_key.to_owned(),
        })
        .collect()
}

/// An earlier run left its state in the app's support folder: every past build wrote
/// `launch-times.jsonl` there. One stat, read only when there is no record.
pub fn prior_state(support_dir: &Path) -> bool {
    support_dir.join("launch-times.jsonl").exists()
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

#[cfg(test)]
#[path = "plan_tests.rs"]
mod tests;
