//! The relaunch cover: what makes an update's relaunch (or a scripted `cmux app quit
//! --keep-sessions` and reopen) look like nothing happened. Before the old process quits it saves
//! every window's frame, display, stacking order, key window and a picture of its content
//! (`CoverManifest`, written beside the launch record as `relaunch-cover/manifest.json`, one PNG
//! per window). The new process reads it once (`take`), decides whether the pictures may still be
//! shown (`cover_plan`: never a stale one), opens each window at its saved frame with the picture
//! over it, and swaps to the live content as each surface reports ready (`Reveal`), in one of three
//! styles the debug setting picks (`SwapStyle`) so they can be compared.
//!
//! Prior art: macOS state restoration (a window's frame and order come back before its content),
//! browsers' session restore (the tab strip and the last painted page first, live pages behind),
//! and this app's own pieces: the stage-0 plan (`plan`), the terminals' last frames and the agent
//! pages' last pages, which each cover one pane. This crate decides; the app captures and draws.
use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::plan::{Display, Frame, png_size};

/// The manifest format this build reads and writes. Any other version is dropped.
pub const MANIFEST_VERSION: u32 = 1;
/// The manifest's file name inside the cover folder.
pub const MANIFEST_FILE: &str = "manifest.json";
/// A cover older than this when the new process reads it is never shown: whatever the person did
/// since (or a relaunch that failed and was retried by hand) makes the picture a lie. An update's
/// relaunch reads it within a few seconds of the quit.
pub const DEFAULT_MAX_AGE_MS: u64 = 20_000;
/// A picture's pixel size may differ from its frame times its scale by this much.
pub const IMAGE_SIZE_TOLERANCE_PX: i64 = 1;
/// The crossfade style's fade.
pub const CROSSFADE_MS: u32 = 120;
/// The progressive style's fade for each surface's region.
pub const PROGRESSIVE_FADE_MS: u32 = 80;
/// Past this after the windows opened, every cover still up goes (with the style's fade): a
/// surface that never reports must not leave a frozen picture standing.
pub const REVEAL_DEADLINE_MS: u64 = 2_500;

fn is_component(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.len() <= 128
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'+'))
}

/// Why the old process wrote the cover.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverCause {
    /// Sparkle's install and relaunch.
    Update,
    /// `cmux app quit --keep-sessions` (scripts, `nightly-swap`, `cmux app try`).
    KeepSessionsQuit,
}

/// A rectangle as serialized: AppKit screen points for a window, top-left content points for a
/// surface.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    fn usable(&self) -> bool {
        [self.x, self.y, self.width, self.height].iter().all(|n| n.is_finite())
            && self.width > 0.0
            && self.height > 0.0
    }
}

impl From<Rect> for Frame {
    fn from(r: Rect) -> Self {
        Frame { x: r.x, y: r.y, width: r.width, height: r.height }
    }
}

/// One surface (pane content: terminal, agent page, browser) the cover stands in for. Its rect is
/// where it was drawn in the window's content view, top-left origin, in points.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CoverSurface {
    pub id: String,
    pub rect: Rect,
}

/// One window as it was at the quit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CoverWindow {
    pub id: String,
    pub frame: Rect,
    /// The display it was on (its frame) and that display's scale.
    pub screen_frame: Rect,
    pub scale: f64,
    /// 0 is frontmost.
    pub order: u32,
    pub key: bool,
    pub fullscreen: bool,
    /// The picture's file name inside the cover folder (`<id>.png`).
    pub image: String,
    pub surfaces: Vec<CoverSurface>,
}

/// Everything the old process saved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CoverManifest {
    pub version: u32,
    pub cause: CoverCause,
    /// Wall clock, ms since the Unix epoch, when the pictures were taken.
    pub written_at_ms: u64,
    /// The build that wrote it (for diagnostics; an update's new build reads the old one's cover).
    pub build: String,
    pub windows: Vec<CoverWindow>,
}

impl CoverManifest {
    /// Whether every name in it is safe to join to the cover folder and every number usable.
    pub fn is_well_formed(&self) -> bool {
        let mut ids = BTreeSet::new();
        self.version == MANIFEST_VERSION
            && self.windows.iter().all(|w| {
                is_component(&w.id)
                    && is_component(&w.image)
                    && ids.insert(w.id.as_str())
                    && w.frame.usable()
                    && w.screen_frame.usable()
                    && w.scale.is_finite()
                    && w.scale > 0.0
                    && w.surfaces.iter().all(|s| !s.id.is_empty() && s.rect.usable())
            })
            && self.windows.iter().filter(|w| w.key).count() <= 1
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn from_json(text: &str) -> Option<Self> {
        serde_json::from_str::<Self>(text).ok().filter(Self::is_well_formed)
    }
}

/// Writes the manifest into `dir` atomically (a temporary file renamed over it). The pictures are
/// written first by the app; a manifest that is not well formed is refused, never written.
pub fn write(dir: &Path, manifest: &CoverManifest) -> std::io::Result<PathBuf> {
    if !manifest.is_well_formed() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "cover manifest"));
    }
    fs::create_dir_all(dir)?;
    let path = dir.join(MANIFEST_FILE);
    let temporary = dir.join(format!("{MANIFEST_FILE}.{}.tmp", std::process::id()));
    {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(manifest.to_json().as_bytes())?;
        file.sync_all()?;
    }
    fs::rename(&temporary, &path)?;
    Ok(path)
}

/// Reads the manifest in `dir` and removes it, so a cover is shown by one launch at most (a crash
/// right after, or a later plain launch, never shows it again). The pictures stay until
/// `clear_images` (the new process drops them once every cover is gone).
pub fn take(dir: &Path) -> Option<CoverManifest> {
    let path = dir.join(MANIFEST_FILE);
    let text = fs::read_to_string(&path).ok();
    let _ = fs::remove_file(&path);
    CoverManifest::from_json(&text?)
}

/// Removes every picture in `dir` named by `manifest` (the only files this module ever puts there
/// besides the manifest).
pub fn clear_images(dir: &Path, manifest: &CoverManifest) {
    for w in &manifest.windows {
        if is_component(&w.image) {
            let _ = fs::remove_file(dir.join(&w.image));
        }
    }
}

/// What is true in the new process when it decides.
#[derive(Debug, Clone, Copy)]
pub struct CoverNow<'a> {
    pub now_ms: u64,
    pub max_age_ms: u64,
    pub displays: &'a [Display],
    /// The windows this launch is about to open (the restore's window records), any order. The
    /// cover is shown only when it is exactly this set.
    pub restoring: &'a [&'a str],
}

/// Why the cover is or is not shown. Only `Show` draws anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum CoverReason {
    Show = 0,
    NoManifest = 1,
    /// Older than `max_age_ms`, or written in the future (the clock moved).
    Stale = 2,
    /// The windows this launch opens are not the ones the cover saved.
    WindowSetChanged = 3,
    /// A window's display is gone, moved or changed scale.
    LayoutChanged = 4,
    ImageUnreadable = 5,
    ImageSizeDiffers = 6,
    /// A full-screen window opens in its own space; a picture over it would jump.
    FullScreen = 7,
    NoWindows = 8,
}

/// The decision, and the windows to cover front first (empty unless `Show`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CoverPlan {
    pub reason: CoverReason,
    /// The window whose picture failed, when one did.
    pub failed_window: Option<String>,
    pub windows: Vec<PlannedWindow>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PlannedWindow {
    pub id: String,
    pub frame: Rect,
    pub order: u32,
    pub key: bool,
    /// Absolute.
    pub image_path: PathBuf,
    pub surfaces: Vec<CoverSurface>,
}

impl CoverPlan {
    fn none(reason: CoverReason, failed_window: Option<&str>) -> Self {
        Self { reason, failed_window: failed_window.map(str::to_owned), windows: Vec::new() }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// All or nothing: one window that cannot be covered drops the whole cover, because a relaunch
/// where some windows show their old picture and one shows a blank reads as a glitch, not as
/// continuity. The windows still open at their saved frames either way (the restore does that).
pub fn cover_plan(manifest: Option<&CoverManifest>, dir: &Path, now: &CoverNow<'_>) -> CoverPlan {
    let Some(m) = manifest.filter(|m| m.is_well_formed()) else {
        return CoverPlan::none(CoverReason::NoManifest, None);
    };
    if m.windows.is_empty() {
        return CoverPlan::none(CoverReason::NoWindows, None);
    }
    if now.now_ms < m.written_at_ms || now.now_ms - m.written_at_ms > now.max_age_ms {
        return CoverPlan::none(CoverReason::Stale, None);
    }
    let saved: BTreeSet<&str> = m.windows.iter().map(|w| w.id.as_str()).collect();
    let restoring: BTreeSet<&str> = now.restoring.iter().copied().collect();
    if saved != restoring {
        return CoverPlan::none(CoverReason::WindowSetChanged, None);
    }
    let mut windows = Vec::with_capacity(m.windows.len());
    for w in &m.windows {
        if w.fullscreen {
            return CoverPlan::none(CoverReason::FullScreen, Some(&w.id));
        }
        let screen = Frame::from(w.screen_frame);
        let Some(display) = now.displays.iter().find(|d| d.frame == screen) else {
            return CoverPlan::none(CoverReason::LayoutChanged, Some(&w.id));
        };
        if display.scale != w.scale {
            return CoverPlan::none(CoverReason::LayoutChanged, Some(&w.id));
        }
        let path = dir.join(&w.image);
        let Some((width, height)) = png_size(&path) else {
            return CoverPlan::none(CoverReason::ImageUnreadable, Some(&w.id));
        };
        let expected = |points: f64| (points * w.scale).round() as i64;
        if (i64::from(width) - expected(w.frame.width)).abs() > IMAGE_SIZE_TOLERANCE_PX
            || (i64::from(height) - expected(w.frame.height)).abs() > IMAGE_SIZE_TOLERANCE_PX
        {
            return CoverPlan::none(CoverReason::ImageSizeDiffers, Some(&w.id));
        }
        windows.push(PlannedWindow {
            id: w.id.clone(),
            frame: w.frame,
            order: w.order,
            key: w.key,
            image_path: path,
            surfaces: w.surfaces.clone(),
        });
    }
    windows.sort_by_key(|w| w.order);
    CoverPlan { reason: CoverReason::Show, failed_window: None, windows }
}

/// How a window's cover gives way to its live content (the debug setting
/// `launch.relaunchCoverSwap`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum SwapStyle {
    /// The whole window's picture goes in one frame once every surface in it is ready.
    Instant = 0,
    /// Same moment, a `CROSSFADE_MS` fade.
    Crossfade = 1,
    /// Each surface's region of the picture fades (`PROGRESSIVE_FADE_MS`) as that surface is
    /// ready; the rest (chrome, sidebar) goes with the last one.
    Progressive = 2,
}

impl SwapStyle {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Instant,
            2 => Self::Progressive,
            _ => Self::Crossfade,
        }
    }

    fn window_fade_ms(self) -> u32 {
        match self {
            Self::Instant | Self::Progressive => 0,
            Self::Crossfade => CROSSFADE_MS,
        }
    }
}

/// One thing the app does to a cover.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "step", rename_all = "snake_case")]
pub enum RevealStep {
    /// Fade out this surface's region of the window's picture.
    Surface { window: String, surface: String, fade_ms: u32 },
    /// Remove the window's picture (what is left of it) over `fade_ms`.
    Window { window: String, fade_ms: u32 },
}

#[derive(Debug, Clone)]
struct WindowReveal {
    id: String,
    pending: BTreeSet<String>,
    done: bool,
}

/// The new process's bookkeeping of which surfaces are live, per window.
#[derive(Debug, Clone)]
pub struct Reveal {
    style: SwapStyle,
    deadline_ms: u64,
    windows: Vec<WindowReveal>,
}

impl Reveal {
    /// `opened_ms`: when the covered windows were put on screen (any monotonic clock, the same one
    /// every later call passes).
    pub fn new(style: SwapStyle, plan: &CoverPlan, opened_ms: u64) -> Self {
        let windows = plan
            .windows
            .iter()
            .map(|w| WindowReveal {
                id: w.id.clone(),
                pending: w.surfaces.iter().map(|s| s.id.clone()).collect(),
                done: false,
            })
            .collect();
        Self { style, deadline_ms: opened_ms.saturating_add(REVEAL_DEADLINE_MS), windows }
    }

    pub fn style(&self) -> SwapStyle {
        self.style
    }

    pub fn is_done(&self) -> bool {
        self.windows.iter().all(|w| w.done)
    }

    /// When `tick` must next be called, while any cover is up.
    pub fn next_deadline_ms(&self) -> Option<u64> {
        (!self.is_done()).then_some(self.deadline_ms)
    }

    /// Starts every window with no surface to wait for (a window showing only chrome): its cover
    /// goes at once. Call right after `new`.
    pub fn start(&mut self) -> Vec<RevealStep> {
        let style = self.style;
        let mut steps = Vec::new();
        for w in self.windows.iter_mut().filter(|w| !w.done && w.pending.is_empty()) {
            w.done = true;
            steps
                .push(RevealStep::Window { window: w.id.clone(), fade_ms: style.window_fade_ms() });
        }
        steps
    }

    /// A surface drew its live content (or was closed, or never existed in the restored layout:
    /// either way nothing more will come for it). Unknown windows and surfaces, and repeats, do
    /// nothing.
    pub fn surface_ready(&mut self, window: &str, surface: &str, now_ms: u64) -> Vec<RevealStep> {
        if now_ms >= self.deadline_ms {
            return self.tick(now_ms);
        }
        let style = self.style;
        let Some(w) = self.windows.iter_mut().find(|w| w.id == window && !w.done) else {
            return Vec::new();
        };
        if !w.pending.remove(surface) {
            return Vec::new();
        }
        let mut steps = Vec::new();
        if style == SwapStyle::Progressive {
            steps.push(RevealStep::Surface {
                window: w.id.clone(),
                surface: surface.to_owned(),
                fade_ms: PROGRESSIVE_FADE_MS,
            });
        }
        if w.pending.is_empty() {
            w.done = true;
            steps
                .push(RevealStep::Window { window: w.id.clone(), fade_ms: style.window_fade_ms() });
        }
        steps
    }

    /// The live window does not match the picture (a pane moved, the window was resized, a
    /// different workspace shows): keeping the picture up would be the layout jump this exists to
    /// hide, so it goes now, with a crossfade whatever the style.
    pub fn mismatch(&mut self, window: &str) -> Vec<RevealStep> {
        let Some(w) = self.windows.iter_mut().find(|w| w.id == window && !w.done) else {
            return Vec::new();
        };
        w.done = true;
        w.pending.clear();
        vec![RevealStep::Window { window: w.id.clone(), fade_ms: CROSSFADE_MS }]
    }

    /// Past the deadline every cover still up goes, with a crossfade whatever the style (a frozen
    /// picture snapping away is worse than one fading).
    pub fn tick(&mut self, now_ms: u64) -> Vec<RevealStep> {
        if now_ms < self.deadline_ms {
            return Vec::new();
        }
        let mut steps = Vec::new();
        for w in self.windows.iter_mut().filter(|w| !w.done) {
            w.done = true;
            w.pending.clear();
            steps.push(RevealStep::Window { window: w.id.clone(), fade_ms: CROSSFADE_MS });
        }
        steps
    }
}

#[cfg(test)]
#[path = "relaunch_cover_tests.rs"]
mod tests;
