//! The stage-0 launch window's decisions (docs/design/launch-shell-first.md, "Decision: stage 0 is
//! its own window"): whether it shows, at which frame, and whether the saved image may be drawn or
//! is stale (then the plain shell: chrome and background, no image). And which input events it
//! holds, in order, for the real window. The app draws and replays; nothing here touches AppKit.
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

pub mod ffi;

pub use cmux_launch_record::Frame;

/// The image is drawn only when its pixel size is the frame times the scale, within this.
pub const IMAGE_SIZE_TOLERANCE_PX: i64 = 1;
/// Held events past which the window swaps at once. Typing never reaches it; nothing is dropped.
pub const INPUT_SWAP_AT: usize = 4096;

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
    /// `<build>/<window_id>/<generation>`: the image's file is `<image_dir>/<key>.png`.
    pub image_key: String,
}

/// Why the plan is what it is. Only `Image` draws the saved image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Reason {
    Image = 0,
    NoRecord = 1,
    NoWindows = 2,
    BuildDiffers = 3,
    LayoutDiffers = 4,
    ScaleDiffers = 5,
    AppearanceDiffers = 6,
    ImageUnreadable = 7,
    ImageSizeDiffers = 8,
    FullScreen = 9,
    /// A v1 record: no display or scale to check, so the saved frame may not be where the real
    /// window opens.
    OldRecord = 10,
}

impl Reason {
    /// Stage 0 makes a window at all. Not when the real window's place cannot be known without
    /// the services (its display changed, it was full screen, the record cannot say, or there is
    /// no record: a session the record never saw can still restore a window elsewhere): a window
    /// there would jump at the swap, so the launch is today's.
    pub fn shows_window(self) -> bool {
        !matches!(self, Self::NoRecord | Self::LayoutDiffers | Self::FullScreen | Self::OldRecord)
    }

    /// The record says no window was open: the app's default frame (the bare launch's).
    pub fn uses_default_frame(self) -> bool {
        self == Self::NoWindows
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
        return Plan { window: None, image: None, reason: Reason::NoRecord };
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
    if !(w.backing_scale > 0.0 && w.backing_scale.is_finite()) {
        return Err(Reason::OldRecord);
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

/// The saved windows of a launch record, front first. A v1 record's windows carry no scale or
/// key (`Reason::OldRecord`).
pub fn saved_windows(record: &cmux_launch_record::LaunchRecord) -> Vec<SavedWindow> {
    record
        .windows()
        .map(|w| SavedWindow {
            id: w.id.to_owned(),
            frame: w.frame,
            background_rgba: w.background_rgba,
            bar_rgba: w.bar_rgba,
            backing_scale: 0.0,
            appearance: Appearance::Light,
            appearance_follows_system: false,
            screen_frame: Frame { x: 0.0, y: 0.0, width: 0.0, height: 0.0 },
            fullscreen: false,
            image_key: String::new(),
        })
        .collect()
}

/// An input event's kind, as the stage-0 window sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum InputKind {
    Other = 0,
    KeyDown = 1,
    KeyUp = 2,
    FlagsChanged = 3,
    MouseDown = 4,
    MouseUp = 5,
    MouseDragged = 6,
    Scroll = 7,
    MouseMoved = 8,
}

impl InputKind {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::KeyDown,
            2 => Self::KeyUp,
            3 => Self::FlagsChanged,
            4 => Self::MouseDown,
            5 => Self::MouseUp,
            6 => Self::MouseDragged,
            7 => Self::Scroll,
            8 => Self::MouseMoved,
            _ => Self::Other,
        }
    }
}

/// What the stage-0 window does with one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Disposition {
    /// AppKit handles it as usual (hover, system events): nothing a person meant for the content.
    Pass = 0,
    /// Held, to be replayed to the real window in arrival order.
    Hold = 1,
    /// Held, and the window swaps now: `INPUT_SWAP_AT` events are waiting.
    HoldAndSwap = 2,
}

/// The disposition of an event arriving after `held` events were held. Every key and every
/// button, drag and scroll is held; none is ever dropped.
pub fn input_disposition(kind: InputKind, held: usize) -> Disposition {
    match kind {
        InputKind::Other | InputKind::MouseMoved => Disposition::Pass,
        _ if held + 1 >= INPUT_SWAP_AT => Disposition::HoldAndSwap,
        _ => Disposition::Hold,
    }
}

#[cfg(test)]
mod tests;
