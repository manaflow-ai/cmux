//! Bounded launch record consumed by the cmux shell before the app core.
//! The reader owns only the bounded file buffer; fields are views into it.
use std::ffi::{CStr, c_char};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Version 2 adds scale, appearance, full screen and the display frame, and
/// replaces the image path with an image key. Version 1 records still read.
pub const FORMAT_VERSION: u16 = 2;
pub const MAX_BYTES: usize = 64 * 1024;
const MAGIC: &[u8; 8] = b"CMUXLR01";
/// Smallest encoded v2 window: empty strings, no tabs. Bounds FFI counts.
const WINDOW_MIN_BYTES: usize = 103;
/// The plan's inline image path buffer, NUL included.
pub const IMAGE_PATH_CAPACITY: usize = 1024;
/// More displays than any Mac drives; a larger count is a caller bug.
const MAX_DISPLAYS: usize = 1024;
/// Files in the support directory that show an earlier launch left state, so a
/// missing record means it was lost rather than never written.
pub const PRIOR_STATE_MARKERS: &[&str] = &["launch-times.jsonl"];

/// Startup work is explicitly classified so a new task cannot accidentally
/// move ahead of the first committed frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum LaunchStage {
    Shell = 0,
    Visible = 1,
    Rest = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LaunchTask {
    pub name: &'static str,
    pub stage: LaunchStage,
}

/// The only stage-0 operations permitted by the shell-first design.
pub const STAGE_ZERO_ALLOWLIST: &[&str] = &[
    "read_launch_record",
    "make_window",
    "put_saved_image",
    "commit_first_frame",
    "finish_launching",
];

pub fn stage_zero_task_is_allowed(task: LaunchTask) -> bool {
    task.stage != LaunchStage::Shell || STAGE_ZERO_ALLOWLIST.contains(&task.name)
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Debug, Clone, PartialEq)]
pub struct WindowRecord {
    pub id: String,
    pub frame: Frame,
    pub display_id: u32,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    /// `<build>/<window_id>/<generation>`, relative to the image directory.
    pub image_key: String,
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub backing_scale: f64,
    /// 0 light, 1 dark.
    pub appearance: u8,
    pub appearance_follows_system: u8,
    pub fullscreen: u8,
    /// The frame of the window's display when the record was written.
    pub screen_frame: Frame,
    pub visible_workspace_id: String,
    pub visible_tab_ids: Vec<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SidebarRow {
    pub id: String,
    pub title: String,
    pub icon_key: String,
}
/// Windows are written in order, front window first.
#[derive(Debug, Clone, PartialEq)]
pub struct LaunchRecordData {
    pub windows: Vec<WindowRecord>,
    pub sidebar_rows: Vec<SidebarRow>,
    pub session_socket_path: String,
}

pub struct LaunchRecord {
    bytes: Vec<u8>,
    version: u16,
    windows: usize,
    sidebar_rows: usize,
    windows_start: usize,
    sidebar_start: usize,
    socket: (usize, usize),
}
impl std::fmt::Debug for LaunchRecord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaunchRecord")
            .field("bytes", &self.bytes.len())
            .field("version", &self.version)
            .field("windows", &self.windows)
            .field("sidebar_rows", &self.sidebar_rows)
            .finish()
    }
}
impl LaunchRecord {
    pub fn read(path: impl AsRef<Path>) -> Option<Self> {
        let file = File::open(path).ok()?;
        let length = file.metadata().ok()?.len();
        if length > MAX_BYTES as u64 {
            return None;
        }
        let mut bytes = vec![0; length as usize];
        let mut file = file;
        file.read_exact(&mut bytes).ok()?;
        let mut extra = [0u8; 1];
        if file.read(&mut extra).ok()? != 0 {
            return None;
        }
        Self::from_bytes(bytes)
    }
    pub fn from_bytes(bytes: Vec<u8>) -> Option<Self> {
        if bytes.len() > MAX_BYTES {
            return None;
        }
        let mut p = Parser::new(&bytes);
        if p.take(8)? != MAGIC {
            return None;
        }
        let version = p.u16()?;
        if !(1..=FORMAT_VERSION).contains(&version) {
            return None;
        };
        let windows = p.u16()? as usize;
        let sidebar_rows = p.u16()? as usize;
        let windows_start = p.position();
        for _ in 0..windows {
            parse_window(&mut p, version)?;
        }
        let sidebar_start = p.position();
        for _ in 0..sidebar_rows {
            parse_sidebar(&mut p)?;
        }
        let socket = p.string_span()?;
        if p.position() != bytes.len() {
            return None;
        }
        Some(Self { bytes, version, windows, sidebar_rows, windows_start, sidebar_start, socket })
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn version(&self) -> u16 {
        self.version
    }
    pub fn window_count(&self) -> usize {
        self.windows
    }
    /// Front window first, in the order the writer was given.
    pub fn windows(&self) -> WindowIter<'_> {
        WindowIter { record: self, index: 0, pos: self.windows_start }
    }
    pub fn sidebar_rows(&self) -> SidebarIter<'_> {
        SidebarIter { record: self, index: 0, pos: self.sidebar_start }
    }
    pub fn session_socket_path(&self) -> &str {
        span_str(&self.bytes, self.socket).unwrap_or("")
    }
    pub fn front_window(&self) -> Option<WindowView<'_>> {
        self.windows().next()
    }
}
/// A v1 window reads with an empty image key, scale 0 (unknown), light,
/// not following the system, not full screen and a zero screen frame.
pub struct WindowView<'a> {
    bytes: &'a [u8],
    pub id: &'a str,
    pub frame: Frame,
    pub display_id: u32,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub image_key: &'a str,
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub backing_scale: f64,
    pub appearance: u8,
    pub appearance_follows_system: u8,
    pub fullscreen: u8,
    pub screen_frame: Frame,
    pub visible_workspace_id: &'a str,
    tabs_start: usize,
    tabs: usize,
}
impl<'a> WindowView<'a> {
    pub fn visible_tab_ids(&self) -> TabIter<'a> {
        TabIter { bytes: self.bytes, pos: self.tabs_start, left: self.tabs }
    }
}
pub struct SidebarView<'a> {
    pub id: &'a str,
    pub title: &'a str,
    pub icon_key: &'a str,
}
pub struct WindowIter<'a> {
    record: &'a LaunchRecord,
    index: usize,
    pos: usize,
}
impl<'a> Iterator for WindowIter<'a> {
    type Item = WindowView<'a>;
    fn next(&mut self) -> Option<Self::Item> {
        if self.index >= self.record.windows {
            return None;
        }
        let (v, end) = decode_window(&self.record.bytes, self.pos, self.record.version)?;
        self.pos = end;
        self.index += 1;
        Some(v)
    }
}
pub struct SidebarIter<'a> {
    record: &'a LaunchRecord,
    index: usize,
    pos: usize,
}
impl<'a> Iterator for SidebarIter<'a> {
    type Item = SidebarView<'a>;
    fn next(&mut self) -> Option<Self::Item> {
        if self.index >= self.record.sidebar_rows {
            return None;
        }
        let (v, end) = decode_sidebar(&self.record.bytes, self.pos)?;
        self.pos = end;
        self.index += 1;
        Some(v)
    }
}
pub struct TabIter<'a> {
    bytes: &'a [u8],
    pos: usize,
    left: usize,
}
impl<'a> Iterator for TabIter<'a> {
    type Item = &'a str;
    fn next(&mut self) -> Option<Self::Item> {
        if self.left == 0 {
            return None;
        }
        let (s, end) = read_span(self.bytes, self.pos)?;
        self.pos = end;
        self.left -= 1;
        span_str(self.bytes, s)
    }
}

/// A display as the shell sees it now.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Display {
    pub display_id: u32,
    pub frame: Frame,
    pub backing_scale: f64,
}
/// What the shell knows about this launch before the app core runs.
#[derive(Debug, Clone, Copy)]
pub struct LaunchNow<'a> {
    /// CFBundleVersion and commit; image keys start with it and a slash.
    pub build: &'a str,
    pub appearance: u8,
    pub displays: &'a [Display],
    /// Where `PRIOR_STATE_MARKERS` live; `None` skips the check.
    pub support_dir: Option<&'a Path>,
}
/// The record as the shell found it.
#[derive(Debug, Clone, Copy)]
pub enum SavedRecord<'a> {
    /// No file at the record path.
    Missing,
    /// A file that cannot be read or does not parse.
    Unusable,
    Read(&'a LaunchRecord),
}
impl<'a> SavedRecord<'a> {
    pub fn from_read(path: &Path, record: Option<&'a LaunchRecord>) -> Self {
        match record {
            Some(r) => Self::Read(r),
            None if fs::symlink_metadata(path)
                .is_err_and(|e| e.kind() == io::ErrorKind::NotFound) =>
            {
                Self::Missing
            }
            None => Self::Unusable,
        }
    }
}
/// Why the saved image can or cannot be shown; the first failure wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PlanReason {
    ImageOk = 0,
    NoRecord = 1,
    NoWindows = 2,
    BuildDiffers = 3,
    LayoutDiffers = 4,
    ScaleDiffers = 5,
    AppearanceDiffers = 6,
    ImageMissing = 7,
    ImageSizeDiffers = 8,
    FullScreen = 9,
    /// No record file, but a prior-state marker exists in the support directory.
    NoRecordPriorState = 10,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ShellPlan {
    pub frame: Frame,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub appearance: u8,
    /// Set only with `PlanReason::ImageOk`; fits `IMAGE_PATH_CAPACITY`.
    pub image_path: Option<PathBuf>,
    pub reason: PlanReason,
}
impl ShellPlan {
    fn empty(reason: PlanReason) -> Self {
        Self {
            frame: Frame::default(),
            background_rgba: [0; 4],
            bar_rgba: [0; 4],
            appearance: 0,
            image_path: None,
            reason,
        }
    }
}

/// True iff every saved window's display is present with the same frame and scale.
pub fn layout_matches(record: &LaunchRecord, now: &[Display]) -> bool {
    record.windows().all(|w| {
        now.iter().any(|d| {
            d.display_id == w.display_id
                && d.frame == w.screen_frame
                && d.backing_scale == w.backing_scale
        })
    })
}

/// The first-frame plan for the front window. `image_dir` must be absolute.
pub fn shell_plan(record: SavedRecord<'_>, image_dir: &Path, now: &LaunchNow<'_>) -> ShellPlan {
    shell_plan_with(record, image_dir, now, |p| fs::metadata(p).is_ok_and(|m| m.is_file()))
}

/// `shell_plan` with the regular-file check (image, markers) supplied by the caller.
pub fn shell_plan_with(
    record: SavedRecord<'_>,
    image_dir: &Path,
    now: &LaunchNow<'_>,
    is_file: impl Fn(&Path) -> bool,
) -> ShellPlan {
    let prior_state = |d: &Path| PRIOR_STATE_MARKERS.iter().any(|m| is_file(&d.join(m)));
    let record = match record {
        SavedRecord::Read(r) => r,
        SavedRecord::Missing if now.support_dir.is_some_and(prior_state) => {
            return ShellPlan::empty(PlanReason::NoRecordPriorState);
        }
        SavedRecord::Missing | SavedRecord::Unusable => {
            return ShellPlan::empty(PlanReason::NoRecord);
        }
    };
    let Some(w) = record.front_window() else { return ShellPlan::empty(PlanReason::NoWindows) };
    // A window with no usable frame cannot be drawn, so there is no window to plan.
    if !frame_is_usable(w.frame) {
        return ShellPlan::empty(PlanReason::NoWindows);
    }
    let verdict = image_verdict(record.version(), &w, image_dir, now, is_file);
    let (image_path, reason) = match verdict {
        Ok(path) => (Some(path), PlanReason::ImageOk),
        Err(reason) => (None, reason),
    };
    ShellPlan {
        frame: w.frame,
        background_rgba: w.background_rgba,
        bar_rgba: w.bar_rgba,
        appearance: w.appearance,
        image_path,
        reason,
    }
}

fn image_verdict(
    version: u16,
    w: &WindowView<'_>,
    image_dir: &Path,
    now: &LaunchNow<'_>,
    is_file: impl Fn(&Path) -> bool,
) -> Result<PathBuf, PlanReason> {
    // v1 stored no build in its image path, so its image is always stale.
    let same_build = version >= 2
        && !now.build.is_empty()
        && w.image_key.strip_prefix(now.build).is_some_and(|rest| rest.starts_with('/'));
    if !same_build {
        return Err(PlanReason::BuildDiffers);
    }
    let display = now.displays.iter().find(|d| d.display_id == w.display_id);
    let Some(display) = display.filter(|d| d.frame == w.screen_frame) else {
        return Err(PlanReason::LayoutDiffers);
    };
    if display.backing_scale != w.backing_scale {
        return Err(PlanReason::ScaleDiffers);
    }
    if w.appearance_follows_system != 0 && now.appearance != w.appearance {
        return Err(PlanReason::AppearanceDiffers);
    }
    // The key is plain relative segments inside the image directory, and the
    // path fits the plan's buffer.
    let key = Path::new(w.image_key);
    let path = image_dir.join(key);
    if !image_dir.is_absolute()
        || w.image_key.split('/').any(|s| matches!(s, "" | "." | ".."))
        || path.as_os_str().len() >= IMAGE_PATH_CAPACITY
        || path.to_str().is_none_or(|p| p.contains('\0'))
        || !is_file(&path)
    {
        return Err(PlanReason::ImageMissing);
    }
    let fits = |pixels: u32, points: f64| (pixels as f64 - points * w.backing_scale).abs() <= 1.0;
    if !fits(w.image_pixel_width, w.frame.width) || !fits(w.image_pixel_height, w.frame.height) {
        return Err(PlanReason::ImageSizeDiffers);
    }
    if w.fullscreen != 0 {
        return Err(PlanReason::FullScreen);
    }
    Ok(path)
}

fn frame_is_usable(f: Frame) -> bool {
    [f.x, f.y, f.width, f.height].iter().all(|n| n.is_finite()) && f.width > 0.0 && f.height > 0.0
}

pub fn write_atomic(path: impl AsRef<Path>, record: &LaunchRecordData) -> io::Result<()> {
    let bytes = encode(record).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let path = path.as_ref();
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let tmp = parent.join(format!(
        ".{}.{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("launch-record"),
        std::process::id(),
        stamp
    ));
    // A failed exclusive create owns no file; never remove another writer's temp.
    let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    let result: io::Result<()> = (|| {
        f.write_all(&bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}
fn encode(r: &LaunchRecordData) -> Result<Vec<u8>, &'static str> {
    if r.windows.len() > u16::MAX as usize || r.sidebar_rows.len() > u16::MAX as usize {
        return Err("too many records");
    };
    let mut o = Vec::with_capacity(1024);
    o.extend_from_slice(MAGIC);
    put_u16(&mut o, FORMAT_VERSION as usize);
    put_u16(&mut o, r.windows.len());
    put_u16(&mut o, r.sidebar_rows.len());
    for w in &r.windows {
        put_string(&mut o, &w.id)?;
        put_frame(&mut o, w.frame);
        o.extend_from_slice(&w.display_id.to_le_bytes());
        o.extend_from_slice(&w.background_rgba);
        o.extend_from_slice(&w.bar_rgba);
        put_string(&mut o, &w.image_key)?;
        o.extend_from_slice(&w.image_pixel_width.to_le_bytes());
        o.extend_from_slice(&w.image_pixel_height.to_le_bytes());
        o.extend_from_slice(&w.backing_scale.to_le_bytes());
        put_frame(&mut o, w.screen_frame);
        o.extend_from_slice(&[w.appearance, w.appearance_follows_system, w.fullscreen]);
        put_string(&mut o, &w.visible_workspace_id)?;
        if w.visible_tab_ids.len() > u16::MAX as usize {
            return Err("too many tabs");
        };
        put_u16(&mut o, w.visible_tab_ids.len());
        for t in &w.visible_tab_ids {
            put_string(&mut o, t)?
        }
    }
    for s in &r.sidebar_rows {
        put_string(&mut o, &s.id)?;
        put_string(&mut o, &s.title)?;
        put_string(&mut o, &s.icon_key)?
    }
    put_string(&mut o, &r.session_socket_path)?;
    if o.len() > MAX_BYTES {
        return Err("record exceeds 64 KiB");
    };
    Ok(o)
}
fn put_frame(o: &mut Vec<u8>, f: Frame) {
    for n in [f.x, f.y, f.width, f.height] {
        o.extend_from_slice(&n.to_le_bytes())
    }
}
fn put_u16(o: &mut Vec<u8>, n: usize) {
    o.extend_from_slice(&(n as u16).to_le_bytes())
}
fn put_string(o: &mut Vec<u8>, s: &str) -> Result<(), &'static str> {
    if s.len() > u16::MAX as usize {
        return Err("string must be <= 65535 bytes");
    };
    if o.len().saturating_add(2).saturating_add(s.len()) > MAX_BYTES {
        return Err("record exceeds 64 KiB");
    }
    put_u16(o, s.len());
    o.extend_from_slice(s.as_bytes());
    Ok(())
}
struct Parser<'a> {
    b: &'a [u8],
    p: usize,
}
impl<'a> Parser<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, p: 0 }
    }
    fn position(&self) -> usize {
        self.p
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let e = self.p.checked_add(n)?;
        let v = self.b.get(self.p..e)?;
        self.p = e;
        Some(v)
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn string_span(&mut self) -> Option<(usize, usize)> {
        let n = self.u16()? as usize;
        let s = self.p;
        std::str::from_utf8(self.take(n)?).ok()?;
        Some((s, n))
    }
}
fn parse_window(p: &mut Parser<'_>, version: u16) -> Option<()> {
    p.string_span()?;
    p.take(32 + 4 + 4 + 4)?;
    p.string_span()?;
    p.take(8)?;
    if version >= 2 {
        // Scale, screen frame, appearance, follows system, full screen.
        p.take(8 + 32 + 3)?;
    }
    p.string_span()?;
    let n = p.u16()? as usize;
    for _ in 0..n {
        p.string_span()?;
    }
    Some(())
}
fn parse_sidebar(p: &mut Parser<'_>) -> Option<()> {
    p.string_span()?;
    p.string_span()?;
    p.string_span()?;
    Some(())
}
fn read_span(b: &[u8], at: usize) -> Option<((usize, usize), usize)> {
    let n = u16::from_le_bytes(b.get(at..at + 2)?.try_into().ok()?) as usize;
    let s = at + 2;
    let e = s.checked_add(n)?;
    b.get(s..e)?;
    Some(((s, n), e))
}
fn span_str(b: &[u8], (s, n): (usize, usize)) -> Option<&str> {
    std::str::from_utf8(b.get(s..s + n)?).ok()
}
fn read_f64(b: &[u8], p: &mut usize) -> Option<f64> {
    let v = f64::from_le_bytes(b.get(*p..*p + 8)?.try_into().ok()?);
    *p += 8;
    Some(v)
}
fn read_frame(b: &[u8], p: &mut usize) -> Option<Frame> {
    Some(Frame {
        x: read_f64(b, p)?,
        y: read_f64(b, p)?,
        width: read_f64(b, p)?,
        height: read_f64(b, p)?,
    })
}
fn decode_window(b: &[u8], mut p: usize, version: u16) -> Option<(WindowView<'_>, usize)> {
    let (idsp, e) = read_span(b, p)?;
    p = e;
    let frame = read_frame(b, &mut p)?;
    let display_id = u32::from_le_bytes(b.get(p..p + 4)?.try_into().ok()?);
    p += 4;
    let bg = b.get(p..p + 4)?.try_into().ok()?;
    p += 4;
    let bar = b.get(p..p + 4)?.try_into().ok()?;
    p += 4;
    let (img, e) = read_span(b, p)?;
    p = e;
    let iw = u32::from_le_bytes(b.get(p..p + 4)?.try_into().ok()?);
    p += 4;
    let ih = u32::from_le_bytes(b.get(p..p + 4)?.try_into().ok()?);
    p += 4;
    // v1 stored an image path, not a key; it is never shown, so expose no key.
    let (image_key, backing_scale, screen_frame, flags) = if version >= 2 {
        let scale = read_f64(b, &mut p)?;
        let screen = read_frame(b, &mut p)?;
        let flags: [u8; 3] = b.get(p..p + 3)?.try_into().ok()?;
        p += 3;
        (span_str(b, img)?, scale, screen, flags)
    } else {
        ("", 0.0, Frame::default(), [0; 3])
    };
    let (ws, e) = read_span(b, p)?;
    p = e;
    let tabs = u16::from_le_bytes(b.get(p..p + 2)?.try_into().ok()?) as usize;
    p += 2;
    let ts = p;
    for _ in 0..tabs {
        p = read_span(b, p)?.1
    }
    Some((
        WindowView {
            bytes: b,
            id: span_str(b, idsp)?,
            frame,
            display_id,
            background_rgba: bg,
            bar_rgba: bar,
            image_key,
            image_pixel_width: iw,
            image_pixel_height: ih,
            backing_scale,
            appearance: flags[0],
            appearance_follows_system: flags[1],
            fullscreen: flags[2],
            screen_frame,
            visible_workspace_id: span_str(b, ws)?,
            tabs_start: ts,
            tabs,
        },
        p,
    ))
}
fn decode_sidebar(b: &[u8], p: usize) -> Option<(SidebarView<'_>, usize)> {
    let (a, p) = read_span(b, p)?;
    let (c, p) = read_span(b, p)?;
    let (d, p) = read_span(b, p)?;
    Some((
        SidebarView { id: span_str(b, a)?, title: span_str(b, c)?, icon_key: span_str(b, d)? },
        p,
    ))
}
/// v2 fields follow the v1 fields so their offsets are unchanged.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchWindow {
    pub frame_x: f64,
    pub frame_y: f64,
    pub frame_width: f64,
    pub frame_height: f64,
    pub display_id: u32,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub window_id: [c_char; 65],
    pub image_key: [c_char; 1025],
    pub backing_scale: f64,
    pub screen_frame_x: f64,
    pub screen_frame_y: f64,
    pub screen_frame_width: f64,
    pub screen_frame_height: f64,
    pub appearance: u8,
    pub appearance_follows_system: u8,
    pub fullscreen: u8,
}

/// v2 fields follow the v1 fields so their offsets are unchanged.
#[repr(C)]
pub struct CmuxLaunchWindowInput {
    pub frame_x: f64,
    pub frame_y: f64,
    pub frame_width: f64,
    pub frame_height: f64,
    pub display_id: u32,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub window_id: *const c_char,
    pub image_key: *const c_char,
    pub visible_workspace_id: *const c_char,
    pub visible_tab_ids: *const *const c_char,
    pub visible_tab_count: usize,
    pub backing_scale: f64,
    pub screen_frame_x: f64,
    pub screen_frame_y: f64,
    pub screen_frame_width: f64,
    pub screen_frame_height: f64,
    pub appearance: u8,
    pub appearance_follows_system: u8,
    pub fullscreen: u8,
}

#[repr(C)]
pub struct CmuxLaunchSidebarInput {
    pub id: *const c_char,
    pub title: *const c_char,
    pub icon_key: *const c_char,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchDisplay {
    pub display_id: u32,
    pub frame_x: f64,
    pub frame_y: f64,
    pub frame_width: f64,
    pub frame_height: f64,
    pub backing_scale: f64,
}

#[repr(C)]
pub struct CmuxLaunchNow {
    pub build: *const c_char,
    pub appearance: u8,
    pub displays: *const CmuxLaunchDisplay,
    pub n: usize,
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
    pub reason: u8,
    pub image_path: [c_char; IMAGE_PATH_CAPACITY],
}

unsafe fn c_string<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p).to_str().ok() }
}

unsafe fn input_data(
    windows: *const CmuxLaunchWindowInput,
    window_count: usize,
    sidebars: *const CmuxLaunchSidebarInput,
    sidebar_count: usize,
    socket: *const c_char,
) -> Option<LaunchRecordData> {
    // A window needs at least WINDOW_MIN_BYTES encoded bytes; a sidebar row needs six.
    // Reject impossible counts before allocating or dereferencing an array.
    if window_count > MAX_BYTES / WINDOW_MIN_BYTES
        || sidebar_count > MAX_BYTES / 6
        || (window_count != 0 && windows.is_null())
        || (sidebar_count != 0 && sidebars.is_null())
    {
        return None;
    }
    let mut output = LaunchRecordData {
        windows: Vec::with_capacity(window_count),
        sidebar_rows: Vec::with_capacity(sidebar_count),
        session_socket_path: unsafe { c_string(socket)? }.to_owned(),
    };
    for i in 0..window_count {
        let w = unsafe { &*windows.add(i) };
        let id = unsafe { c_string(w.window_id)? }.to_owned();
        let image_key = unsafe { c_string(w.image_key)? }.to_owned();
        let workspace = unsafe { c_string(w.visible_workspace_id)? }.to_owned();
        if w.visible_tab_count > MAX_BYTES / 2
            || (w.visible_tab_count != 0 && w.visible_tab_ids.is_null())
        {
            return None;
        }
        let mut tabs = Vec::with_capacity(w.visible_tab_count);
        for j in 0..w.visible_tab_count {
            tabs.push(unsafe { c_string(*w.visible_tab_ids.add(j))? }.to_owned());
        }
        output.windows.push(WindowRecord {
            id,
            frame: Frame {
                x: w.frame_x,
                y: w.frame_y,
                width: w.frame_width,
                height: w.frame_height,
            },
            display_id: w.display_id,
            background_rgba: w.background_rgba,
            bar_rgba: w.bar_rgba,
            image_key,
            image_pixel_width: w.image_pixel_width,
            image_pixel_height: w.image_pixel_height,
            backing_scale: w.backing_scale,
            appearance: w.appearance,
            appearance_follows_system: w.appearance_follows_system,
            fullscreen: w.fullscreen,
            screen_frame: Frame {
                x: w.screen_frame_x,
                y: w.screen_frame_y,
                width: w.screen_frame_width,
                height: w.screen_frame_height,
            },
            visible_workspace_id: workspace,
            visible_tab_ids: tabs,
        });
    }
    for i in 0..sidebar_count {
        let s = unsafe { &*sidebars.add(i) };
        output.sidebar_rows.push(SidebarRow {
            id: unsafe { c_string(s.id)? }.to_owned(),
            title: unsafe { c_string(s.title)? }.to_owned(),
            icon_key: unsafe { c_string(s.icon_key)? }.to_owned(),
        });
    }
    Some(output)
}

/// Writes a bounded launch record through the app FFI. Null pointers, invalid UTF-8,
/// impossible counts and records over 64 KiB return false without touching the destination.
/// `windows[0]` is the front window.
///
/// # Safety
/// Non-null pointers must reference readable, NUL-terminated strings or arrays
/// of the supplied lengths for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_record_write(
    path: *const c_char,
    windows: *const CmuxLaunchWindowInput,
    window_count: usize,
    sidebars: *const CmuxLaunchSidebarInput,
    sidebar_count: usize,
    socket: *const c_char,
) -> bool {
    let Some(path) = (unsafe { c_string(path) }) else { return false };
    let Some(data) =
        (unsafe { input_data(windows, window_count, sidebars, sidebar_count, socket) })
    else {
        return false;
    };
    write_atomic(path, &data).is_ok()
}
impl Default for CmuxLaunchWindow {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}
impl Default for CmuxLaunchShellPlan {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}
fn copy_c(dst: &mut [c_char], s: &str) {
    // The caller has validated capacity and embedded NULs.
    for (d, b) in dst.iter_mut().zip(s.bytes()) {
        *d = b as c_char;
    }
    dst[s.len()] = 0;
}
/// Fills `o` from `w`; false when a string does not fit or the frame is unusable.
fn fill_window(w: &WindowView<'_>, o: &mut CmuxLaunchWindow) -> bool {
    if w.id.len() >= o.window_id.len()
        || w.image_key.len() >= o.image_key.len()
        || w.id.contains('\0')
        || w.image_key.contains('\0')
        || !frame_is_usable(w.frame)
    {
        return false;
    }
    *o = CmuxLaunchWindow {
        frame_x: w.frame.x,
        frame_y: w.frame.y,
        frame_width: w.frame.width,
        frame_height: w.frame.height,
        display_id: w.display_id,
        background_rgba: w.background_rgba,
        bar_rgba: w.bar_rgba,
        image_pixel_width: w.image_pixel_width,
        image_pixel_height: w.image_pixel_height,
        backing_scale: w.backing_scale,
        screen_frame_x: w.screen_frame.x,
        screen_frame_y: w.screen_frame.y,
        screen_frame_width: w.screen_frame.width,
        screen_frame_height: w.screen_frame.height,
        appearance: w.appearance,
        appearance_follows_system: w.appearance_follows_system,
        fullscreen: w.fullscreen,
        ..Default::default()
    };
    copy_c(&mut o.window_id, w.id);
    copy_c(&mut o.image_key, w.image_key);
    true
}
unsafe fn read_at(path: *const c_char) -> Option<LaunchRecord> {
    LaunchRecord::read(unsafe { c_string(path)? })
}
unsafe fn displays_from(p: *const CmuxLaunchDisplay, n: usize) -> Option<Vec<Display>> {
    if n > MAX_DISPLAYS || (n != 0 && p.is_null()) {
        return None;
    }
    let raw = if n == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(p, n) } };
    Some(
        raw.iter()
            .map(|d| Display {
                display_id: d.display_id,
                frame: Frame {
                    x: d.frame_x,
                    y: d.frame_y,
                    width: d.frame_width,
                    height: d.frame_height,
                },
                backing_scale: d.backing_scale,
            })
            .collect(),
    )
}
/// Returns false with a zeroed output when the record is unusable.
///
/// # Safety
/// `out`, if non-null, must be writable and aligned. `path`, if non-null,
/// must point to a readable NUL-terminated string for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_record_front_window(
    path: *const c_char,
    out: *mut CmuxLaunchWindow,
) -> bool {
    if out.is_null() {
        return false;
    }
    let o = unsafe { &mut *out };
    *o = CmuxLaunchWindow::default();
    let Some(record) = (unsafe { read_at(path) }) else { return false };
    let Some(w) = record.front_window() else { return false };
    if !fill_window(&w, o) {
        *o = CmuxLaunchWindow::default();
        return false;
    }
    true
}
/// Returns the record's window count and fills the first `min(count, cap)`
/// entries, front window first. Returns 0 when the record or any window is
/// unusable, with the entries it wrote zeroed.
///
/// # Safety
/// `out` must be writable for `cap` entries unless `cap` is 0. `path`, if
/// non-null, must point to a readable NUL-terminated string for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_record_windows(
    path: *const c_char,
    out: *mut CmuxLaunchWindow,
    cap: usize,
) -> usize {
    if cap != 0 && out.is_null() {
        return 0;
    }
    let Some(record) = (unsafe { read_at(path) }) else { return 0 };
    let count = record.window_count();
    let filled = cap.min(count);
    let out = if filled == 0 {
        &mut [][..]
    } else {
        unsafe { std::slice::from_raw_parts_mut(out, filled) }
    };
    let mut all = true;
    for (i, w) in record.windows().enumerate() {
        let mut one = CmuxLaunchWindow::default();
        all &= fill_window(&w, &mut one);
        if !all {
            break;
        }
        if let Some(slot) = out.get_mut(i) {
            *slot = one;
        }
    }
    if !all {
        out.fill(CmuxLaunchWindow::default());
        return 0;
    }
    count
}
/// True iff every saved window's display is in `now` with the same frame and scale.
/// False for a missing or unreadable record.
///
/// # Safety
/// `now` must be readable for `n` entries unless `n` is 0. `path`, if
/// non-null, must point to a readable NUL-terminated string for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_record_layout_matches(
    path: *const c_char,
    now: *const CmuxLaunchDisplay,
    n: usize,
) -> bool {
    let Some(displays) = (unsafe { displays_from(now, n) }) else { return false };
    let Some(record) = (unsafe { read_at(path) }) else { return false };
    layout_matches(&record, &displays)
}
/// Fills `out` with the first-frame plan; false (output zeroed) only for null
/// or non-UTF-8 arguments. A missing record is a plan with reason 1, or 10 when
/// a prior-state marker is in `now->support_dir` (null skips that check).
///
/// # Safety
/// `out`, if non-null, must be writable and aligned. Non-null strings must be
/// NUL-terminated, and `now->displays` readable for `now->n` entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_shell_plan(
    record_path: *const c_char,
    image_dir: *const c_char,
    now: *const CmuxLaunchNow,
    out: *mut CmuxLaunchShellPlan,
) -> bool {
    if out.is_null() || now.is_null() {
        return false;
    }
    let o = unsafe { &mut *out };
    *o = CmuxLaunchShellPlan::default();
    let now = unsafe { &*now };
    let (Some(record_path), Some(image_dir), Some(build), Some(displays)) = (unsafe {
        (
            c_string(record_path),
            c_string(image_dir),
            c_string(now.build),
            displays_from(now.displays, now.n),
        )
    }) else {
        return false;
    };
    let support_dir = if now.support_dir.is_null() {
        None
    } else {
        let Some(dir) = (unsafe { c_string(now.support_dir) }) else { return false };
        Some(Path::new(dir))
    };
    let record = LaunchRecord::read(record_path);
    let saved = SavedRecord::from_read(Path::new(record_path), record.as_ref());
    let now = LaunchNow { build, appearance: now.appearance, displays: &displays, support_dir };
    let plan = shell_plan(saved, Path::new(image_dir), &now);
    o.frame_x = plan.frame.x;
    o.frame_y = plan.frame.y;
    o.frame_width = plan.frame.width;
    o.frame_height = plan.frame.height;
    o.background_rgba = plan.background_rgba;
    o.bar_rgba = plan.bar_rgba;
    o.appearance = plan.appearance;
    o.reason = plan.reason as u8;
    // The plan checked the path is UTF-8, NUL-free and fits the buffer.
    if let Some(path) = plan.image_path.as_deref().and_then(Path::to_str) {
        copy_c(&mut o.image_path, path);
    }
    true
}
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    const BUILD: &str = "1234-abcdef0";
    const SCREEN: Frame = Frame { x: 0., y: 0., width: 1512., height: 982. };
    fn window(id: &str) -> WindowRecord {
        WindowRecord {
            id: id.into(),
            frame: Frame { x: 100., y: 50., width: 800., height: 600. },
            display_id: 7,
            background_rgba: [1, 2, 3, 4],
            bar_rgba: [5, 6, 7, 8],
            image_key: format!("{BUILD}/{id}/3"),
            image_pixel_width: 1600,
            image_pixel_height: 1200,
            backing_scale: 2.0,
            appearance: 1,
            appearance_follows_system: 1,
            fullscreen: 0,
            screen_frame: SCREEN,
            visible_workspace_id: "ws".into(),
            visible_tab_ids: vec!["tab".into()],
        }
    }
    fn sample() -> LaunchRecordData {
        LaunchRecordData {
            windows: vec![window("w")],
            sidebar_rows: vec![SidebarRow {
                id: "s".into(),
                title: "Side".into(),
                icon_key: "folder".into(),
            }],
            session_socket_path: "/tmp/sock".into(),
        }
    }
    /// The v1 encoding, as the previous writer produced it.
    fn encode_v1(r: &LaunchRecordData) -> Vec<u8> {
        let mut o = Vec::from(&MAGIC[..]);
        for n in [1, r.windows.len(), r.sidebar_rows.len()] {
            put_u16(&mut o, n);
        }
        for w in &r.windows {
            put_string(&mut o, &w.id).unwrap();
            put_frame(&mut o, w.frame);
            o.extend_from_slice(&w.display_id.to_le_bytes());
            o.extend_from_slice(&w.background_rgba);
            o.extend_from_slice(&w.bar_rgba);
            put_string(&mut o, "/tmp/f.png").unwrap();
            o.extend_from_slice(&w.image_pixel_width.to_le_bytes());
            o.extend_from_slice(&w.image_pixel_height.to_le_bytes());
            put_string(&mut o, &w.visible_workspace_id).unwrap();
            put_u16(&mut o, w.visible_tab_ids.len());
            for t in &w.visible_tab_ids {
                put_string(&mut o, t).unwrap();
            }
        }
        for s in &r.sidebar_rows {
            for v in [&s.id, &s.title, &s.icon_key] {
                put_string(&mut o, v).unwrap();
            }
        }
        put_string(&mut o, &r.session_socket_path).unwrap();
        o
    }
    fn displays() -> Vec<Display> {
        vec![
            Display { display_id: 3, frame: Frame { x: 1512., ..SCREEN }, backing_scale: 1.0 },
            Display { display_id: 7, frame: SCREEN, backing_scale: 2.0 },
        ]
    }
    fn plan_for(data: &LaunchRecordData, displays: &[Display], appearance: u8) -> ShellPlan {
        let record = LaunchRecord::from_bytes(encode(data).unwrap()).unwrap();
        let now = LaunchNow { build: BUILD, appearance, displays, support_dir: None };
        shell_plan_with(SavedRecord::Read(&record), Path::new("/images"), &now, |_| true)
    }
    fn reason(data: &LaunchRecordData) -> PlanReason {
        plan_for(data, &displays(), 1).reason
    }
    #[test]
    fn round_trip() {
        let b = encode(&sample()).unwrap();
        let r = LaunchRecord::from_bytes(b).unwrap();
        let w = r.front_window().unwrap();
        assert_eq!(w.id, "w");
        assert_eq!(w.visible_tab_ids().collect::<Vec<_>>(), vec!["tab"]);
        assert_eq!(r.session_socket_path(), "/tmp/sock")
    }
    #[test]
    fn round_trip_every_v2_field() {
        let mut data = sample();
        let w = &mut data.windows[0];
        w.backing_scale = 1.5;
        w.appearance = 1;
        w.appearance_follows_system = 0;
        w.fullscreen = 1;
        w.screen_frame = Frame { x: -1920., y: 120.5, width: 1920., height: 1080. };
        w.visible_tab_ids = vec!["a".into(), "b".into()];
        let r = LaunchRecord::from_bytes(encode(&data).unwrap()).unwrap();
        assert_eq!(r.version(), 2);
        let v = r.front_window().unwrap();
        let w = &data.windows[0];
        let back = WindowRecord {
            id: v.id.into(),
            frame: v.frame,
            display_id: v.display_id,
            background_rgba: v.background_rgba,
            bar_rgba: v.bar_rgba,
            image_key: v.image_key.into(),
            image_pixel_width: v.image_pixel_width,
            image_pixel_height: v.image_pixel_height,
            backing_scale: v.backing_scale,
            appearance: v.appearance,
            appearance_follows_system: v.appearance_follows_system,
            fullscreen: v.fullscreen,
            screen_frame: v.screen_frame,
            visible_workspace_id: v.visible_workspace_id.into(),
            visible_tab_ids: v.visible_tab_ids().map(String::from).collect(),
        };
        assert_eq!(&back, w);
        // And through the FFI writer and reader.
        let dir = TestDir::new();
        let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
        let c = |s: &str| std::ffi::CString::new(s).unwrap();
        let (id, key, ws, tabs) = (c(&w.id), c(&w.image_key), c("ws"), [c("a"), c("b")]);
        let tab_ptrs = tabs.iter().map(|t| t.as_ptr()).collect::<Vec<_>>();
        let input = CmuxLaunchWindowInput {
            frame_x: w.frame.x,
            frame_y: w.frame.y,
            frame_width: w.frame.width,
            frame_height: w.frame.height,
            display_id: w.display_id,
            background_rgba: w.background_rgba,
            bar_rgba: w.bar_rgba,
            image_pixel_width: w.image_pixel_width,
            image_pixel_height: w.image_pixel_height,
            window_id: id.as_ptr(),
            image_key: key.as_ptr(),
            visible_workspace_id: ws.as_ptr(),
            visible_tab_ids: tab_ptrs.as_ptr(),
            visible_tab_count: 2,
            backing_scale: w.backing_scale,
            screen_frame_x: w.screen_frame.x,
            screen_frame_y: w.screen_frame.y,
            screen_frame_width: w.screen_frame.width,
            screen_frame_height: w.screen_frame.height,
            appearance: w.appearance,
            appearance_follows_system: w.appearance_follows_system,
            fullscreen: w.fullscreen,
        };
        let socket = c("/tmp/sock");
        assert!(unsafe {
            cmux_launch_record_write(path.as_ptr(), &input, 1, std::ptr::null(), 0, socket.as_ptr())
        });
        let mut written = data.clone();
        written.sidebar_rows.clear();
        assert_eq!(fs::read(dir.record()).unwrap(), encode(&written).unwrap());
        let mut out = CmuxLaunchWindow::default();
        assert!(unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
        assert_eq!(
            (out.backing_scale, out.appearance, out.appearance_follows_system, out.fullscreen),
            (1.5, 1, 0, 1)
        );
        assert_eq!(
            [
                out.screen_frame_x,
                out.screen_frame_y,
                out.screen_frame_width,
                out.screen_frame_height
            ],
            [-1920., 120.5, 1920., 1080.]
        );
        assert_eq!(
            unsafe { CStr::from_ptr(out.image_key.as_ptr()) }.to_str().unwrap(),
            w.image_key
        );
    }
    #[test]
    fn rejects() {
        let mut b = encode(&sample()).unwrap();
        b.push(0);
        assert!(LaunchRecord::from_bytes(b).is_none());
        for version in [0, FORMAT_VERSION + 1] {
            let mut b = encode(&sample()).unwrap();
            b[8..10].copy_from_slice(&version.to_le_bytes());
            assert!(LaunchRecord::from_bytes(b).is_none())
        }
        // A v2 body labelled v1 does not parse as v1.
        let mut b = encode(&sample()).unwrap();
        b[8] = 1;
        assert!(LaunchRecord::from_bytes(b).is_none())
    }
    #[test]
    fn v1_record_reads_with_defaults_and_is_stale() {
        let data = sample();
        let r = LaunchRecord::from_bytes(encode_v1(&data)).unwrap();
        assert_eq!(r.version(), 1);
        let w = r.front_window().unwrap();
        assert_eq!((w.id, w.frame, w.display_id), ("w", data.windows[0].frame, 7));
        assert_eq!((w.image_pixel_width, w.image_pixel_height), (1600, 1200));
        assert_eq!(w.visible_tab_ids().collect::<Vec<_>>(), vec!["tab"]);
        assert_eq!((w.image_key, w.backing_scale, w.screen_frame), ("", 0.0, Frame::default()));
        assert_eq!((w.appearance, w.appearance_follows_system, w.fullscreen), (0, 0, 0));
        assert_eq!(r.sidebar_rows().next().unwrap().title, "Side");
        assert_eq!(r.session_socket_path(), "/tmp/sock");
        let now =
            LaunchNow { build: BUILD, appearance: 0, displays: &displays(), support_dir: None };
        let plan = shell_plan_with(SavedRecord::Read(&r), Path::new("/images"), &now, |_| true);
        assert_eq!(plan.reason, PlanReason::BuildDiffers);
        assert_eq!(plan.frame, data.windows[0].frame);
        assert_eq!(plan.image_path, None);
        assert!(!layout_matches(&r, &displays()));
    }
    #[test]
    fn plan_image_ok() {
        let plan = plan_for(&sample(), &displays(), 1);
        assert_eq!(plan.reason, PlanReason::ImageOk);
        assert_eq!(plan.image_path, Some(PathBuf::from(format!("/images/{BUILD}/w/3"))));
        assert_eq!(plan.frame, sample().windows[0].frame);
        assert_eq!(
            (plan.background_rgba, plan.bar_rgba, plan.appearance),
            ([1, 2, 3, 4], [5, 6, 7, 8], 1)
        );
    }
    #[test]
    fn plan_no_record_and_no_windows_are_zeroed() {
        let now = LaunchNow { build: BUILD, appearance: 0, displays: &[], support_dir: None };
        for saved in [SavedRecord::Missing, SavedRecord::Unusable] {
            assert_eq!(
                shell_plan_with(saved, Path::new("/images"), &now, |_| true),
                ShellPlan::empty(PlanReason::NoRecord)
            );
        }
        let mut data = sample();
        data.windows.clear();
        assert_eq!(plan_for(&data, &displays(), 1), ShellPlan::empty(PlanReason::NoWindows));
        data.windows.push(window("w"));
        data.windows[0].frame.width = f64::NAN;
        assert_eq!(plan_for(&data, &displays(), 1), ShellPlan::empty(PlanReason::NoWindows));
    }
    #[test]
    fn plan_missing_record_with_and_without_prior_state() {
        let support = Path::new("/support");
        let now =
            LaunchNow { build: BUILD, appearance: 0, displays: &[], support_dir: Some(support) };
        let marker = support.join("launch-times.jsonl");
        let with = |saved| shell_plan_with(saved, Path::new("/images"), &now, |p| p == marker);
        assert_eq!(with(SavedRecord::Missing), ShellPlan::empty(PlanReason::NoRecordPriorState));
        assert_eq!(with(SavedRecord::Unusable).reason, PlanReason::NoRecord);
        let without = shell_plan_with(SavedRecord::Missing, Path::new("/images"), &now, |_| false);
        assert_eq!(without, ShellPlan::empty(PlanReason::NoRecord));
        let skip = LaunchNow { support_dir: None, ..now };
        assert_eq!(
            shell_plan_with(SavedRecord::Missing, Path::new("/images"), &skip, |_| true).reason,
            PlanReason::NoRecord
        );
        // The real stat, through SavedRecord::from_read.
        let dir = TestDir::new();
        let saved = SavedRecord::from_read(&dir.record(), None);
        assert!(matches!(saved, SavedRecord::Missing));
        let now = LaunchNow { support_dir: Some(&dir.0), ..now };
        assert_eq!(shell_plan(saved, Path::new("/images"), &now).reason, PlanReason::NoRecord);
        fs::write(dir.0.join("launch-times.jsonl"), b"").unwrap();
        assert_eq!(
            shell_plan(saved, Path::new("/images"), &now).reason,
            PlanReason::NoRecordPriorState
        );
        fs::write(dir.record(), b"garbage").unwrap();
        assert!(matches!(SavedRecord::from_read(&dir.record(), None), SavedRecord::Unusable));
    }
    #[test]
    fn plan_stale_build() {
        for key in ["other/w/3", "1234-abcdef0x/w/3", "1234-abcdef0", "", "1234/w/3"] {
            let mut data = sample();
            data.windows[0].image_key = key.into();
            let plan = plan_for(&data, &displays(), 1);
            assert_eq!(plan.reason, PlanReason::BuildDiffers, "{key}");
            assert_eq!(
                (plan.frame, plan.bar_rgba, plan.image_path),
                (data.windows[0].frame, [5, 6, 7, 8], None)
            );
        }
        let record = LaunchRecord::from_bytes(encode(&sample()).unwrap()).unwrap();
        let now = LaunchNow { build: "", appearance: 1, displays: &displays(), support_dir: None };
        assert_eq!(
            shell_plan_with(SavedRecord::Read(&record), Path::new("/images"), &now, |_| true)
                .reason,
            PlanReason::BuildDiffers
        );
    }
    #[test]
    fn plan_layout_display_missing_or_moved() {
        let mut d = displays();
        d.retain(|d| d.display_id != 7);
        assert_eq!(plan_for(&sample(), &d, 1).reason, PlanReason::LayoutDiffers);
        assert_eq!(plan_for(&sample(), &[], 1).reason, PlanReason::LayoutDiffers);
        for moved in [Frame { x: 1., ..SCREEN }, Frame { height: 1117., ..SCREEN }] {
            let mut d = displays();
            d[1].frame = moved;
            let plan = plan_for(&sample(), &d, 1);
            assert_eq!(plan.reason, PlanReason::LayoutDiffers);
            assert_eq!(plan.frame, sample().windows[0].frame);
        }
    }
    #[test]
    fn plan_scale_changed() {
        let mut d = displays();
        d[1].backing_scale = 1.0;
        assert_eq!(plan_for(&sample(), &d, 1).reason, PlanReason::ScaleDiffers);
    }
    #[test]
    fn plan_appearance_only_when_following_system() {
        let mut data = sample();
        assert_eq!(plan_for(&data, &displays(), 0).reason, PlanReason::AppearanceDiffers);
        assert_eq!(plan_for(&data, &displays(), 1).reason, PlanReason::ImageOk);
        data.windows[0].appearance_follows_system = 0;
        assert_eq!(plan_for(&data, &displays(), 0).reason, PlanReason::ImageOk);
        data.windows[0].appearance = 0;
        assert_eq!(plan_for(&data, &displays(), 1).reason, PlanReason::ImageOk);
        data.windows[0].appearance_follows_system = 1;
        assert_eq!(plan_for(&data, &displays(), 1).reason, PlanReason::AppearanceDiffers);
        let plan = plan_for(&data, &displays(), 0);
        assert_eq!((plan.reason, plan.appearance), (PlanReason::ImageOk, 0));
    }
    #[test]
    fn plan_image_missing_unsafe_or_too_long() {
        let record = LaunchRecord::from_bytes(encode(&sample()).unwrap()).unwrap();
        let d = displays();
        let now = LaunchNow { build: BUILD, appearance: 1, displays: &d, support_dir: None };
        let plan =
            shell_plan_with(SavedRecord::Read(&record), Path::new("/images"), &now, |_| false);
        assert_eq!((plan.reason, plan.image_path), (PlanReason::ImageMissing, None));
        assert_eq!(
            shell_plan_with(SavedRecord::Read(&record), Path::new("images"), &now, |_| true).reason,
            PlanReason::ImageMissing
        );
        for key in [
            format!("{BUILD}/../../etc/passwd"),
            format!("{BUILD}/./w"),
            format!("{BUILD}/w//3"),
            format!("{BUILD}/w/3/"),
        ] {
            let mut data = sample();
            data.windows[0].image_key = key;
            assert_eq!(reason(&data), PlanReason::ImageMissing);
        }
        // "/images/" is 8 bytes; the path plus its NUL must fit 1024.
        for (len, expected) in [(1023, PlanReason::ImageOk), (1024, PlanReason::ImageMissing)] {
            let mut data = sample();
            let prefix = format!("{BUILD}/");
            data.windows[0].image_key = format!("{prefix}{}", "k".repeat(len - 8 - prefix.len()));
            assert_eq!(reason(&data), expected, "{len}");
        }
        // The real stat: a directory or a missing file is not an image.
        let dir = TestDir::new();
        let path = dir.0.join(BUILD).join("w");
        fs::create_dir_all(&path).unwrap();
        assert_eq!(
            shell_plan(SavedRecord::Read(&record), &dir.0, &now).reason,
            PlanReason::ImageMissing
        );
        fs::create_dir(path.join("3")).unwrap();
        assert_eq!(
            shell_plan(SavedRecord::Read(&record), &dir.0, &now).reason,
            PlanReason::ImageMissing
        );
        fs::remove_dir(path.join("3")).unwrap();
        fs::write(path.join("3"), b"png").unwrap();
        let plan = shell_plan(SavedRecord::Read(&record), &dir.0, &now);
        assert_eq!((plan.reason, plan.image_path), (PlanReason::ImageOk, Some(path.join("3"))));
    }
    #[test]
    fn plan_image_size_with_one_pixel_tolerance() {
        for (w, h, expected) in [
            (1601, 1199, PlanReason::ImageOk),
            (1599, 1201, PlanReason::ImageOk),
            (1602, 1200, PlanReason::ImageSizeDiffers),
            (1600, 1198, PlanReason::ImageSizeDiffers),
            (800, 600, PlanReason::ImageSizeDiffers),
        ] {
            let mut data = sample();
            data.windows[0].image_pixel_width = w;
            data.windows[0].image_pixel_height = h;
            assert_eq!(reason(&data), expected, "{w}x{h}");
        }
    }
    #[test]
    fn plan_fullscreen_and_first_failure_wins() {
        let mut data = sample();
        data.windows[0].fullscreen = 1;
        assert_eq!(reason(&data), PlanReason::FullScreen);
        data.windows[0].image_pixel_width = 1;
        assert_eq!(reason(&data), PlanReason::ImageSizeDiffers);
        let mut d = displays();
        d[1].backing_scale = 3.0;
        assert_eq!(plan_for(&data, &d, 0).reason, PlanReason::ScaleDiffers);
        data.windows[0].image_key = "old/w/1".into();
        assert_eq!(plan_for(&data, &d, 0).reason, PlanReason::BuildDiffers);
    }
    #[test]
    fn plan_uses_front_window_only() {
        let mut data = sample();
        let mut back = window("back");
        back.display_id = 99;
        data.windows.push(back);
        assert_eq!(reason(&data), PlanReason::ImageOk);
        let record = LaunchRecord::from_bytes(encode(&data).unwrap()).unwrap();
        assert!(!layout_matches(&record, &displays()));
    }
    #[test]
    fn layout_matches_every_window() {
        let mut data = sample();
        let mut second = window("second");
        second.display_id = 3;
        second.screen_frame = Frame { x: 1512., ..SCREEN };
        second.backing_scale = 1.0;
        data.windows.push(second);
        let record = LaunchRecord::from_bytes(encode(&data).unwrap()).unwrap();
        assert!(layout_matches(&record, &displays()));
        let mut d = displays();
        d[0].backing_scale = 2.0;
        assert!(!layout_matches(&record, &d));
        let mut d = displays();
        d[1].frame.width = 1000.;
        assert!(!layout_matches(&record, &d));
        assert!(!layout_matches(&record, &displays()[1..]));
        data.windows.clear();
        let empty = LaunchRecord::from_bytes(encode(&data).unwrap()).unwrap();
        assert!(layout_matches(&empty, &[]));
    }
    #[test]
    fn ffi_windows_front_first_and_bounded_by_cap() {
        let dir = TestDir::new();
        let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
        let mut data = sample();
        data.windows = ["front", "middle", "back"].map(window).to_vec();
        write_atomic(dir.record(), &data).unwrap();
        let mut out = [CmuxLaunchWindow::default(); 4];
        let ids = |out: &[CmuxLaunchWindow]| {
            out.iter()
                .map(|w| {
                    unsafe { CStr::from_ptr(w.window_id.as_ptr()) }.to_str().unwrap().to_owned()
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), out.as_mut_ptr(), 4) }, 3);
        assert_eq!(ids(&out), ["front", "middle", "back", ""]);
        let mut two = [CmuxLaunchWindow::default(); 2];
        assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), two.as_mut_ptr(), 2) }, 3);
        assert_eq!(ids(&two), ["front", "middle"]);
        assert_eq!(
            unsafe { cmux_launch_record_windows(path.as_ptr(), std::ptr::null_mut(), 0) },
            3
        );
        assert_eq!(
            unsafe { cmux_launch_record_windows(path.as_ptr(), std::ptr::null_mut(), 1) },
            0
        );
        assert_eq!(unsafe { cmux_launch_record_windows(std::ptr::null(), out.as_mut_ptr(), 4) }, 0);
        // One unusable window makes the whole call fail, zeroing what it wrote.
        data.windows[2].id = "x".repeat(65);
        write_atomic(dir.record(), &data).unwrap();
        assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), out.as_mut_ptr(), 4) }, 0);
        assert_eq!(ids(&out[..3]), ["", "", ""]);
    }
    #[test]
    fn ffi_layout_and_shell_plan() {
        let dir = TestDir::new();
        let record = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
        let images = std::ffi::CString::new(dir.0.join("images").to_str().unwrap()).unwrap();
        let build = std::ffi::CString::new(BUILD).unwrap();
        let d = displays()
            .iter()
            .map(|d| CmuxLaunchDisplay {
                display_id: d.display_id,
                frame_x: d.frame.x,
                frame_y: d.frame.y,
                frame_width: d.frame.width,
                frame_height: d.frame.height,
                backing_scale: d.backing_scale,
            })
            .collect::<Vec<_>>();
        let support = std::ffi::CString::new(dir.0.join("support").to_str().unwrap()).unwrap();
        let now = CmuxLaunchNow {
            build: build.as_ptr(),
            appearance: 1,
            displays: d.as_ptr(),
            n: d.len(),
            support_dir: support.as_ptr(),
        };
        let mut out = CmuxLaunchShellPlan { reason: 42, ..Default::default() };
        let plan = |out: &mut CmuxLaunchShellPlan| unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &now, out)
        };
        let image_path = |out: &CmuxLaunchShellPlan| {
            unsafe { CStr::from_ptr(out.image_path.as_ptr()) }.to_str().unwrap().to_owned()
        };
        assert!(plan(&mut out));
        assert_eq!((out.reason, out.frame_width, image_path(&out)), (1, 0.0, String::new()));
        // A missing record after an earlier launch left state is reason 10.
        fs::create_dir(dir.0.join("support")).unwrap();
        fs::write(dir.0.join("support").join(PRIOR_STATE_MARKERS[0]), b"{}\n").unwrap();
        assert!(plan(&mut out));
        assert_eq!((out.reason, out.frame_width), (10, 0.0));
        let skip = CmuxLaunchNow { support_dir: std::ptr::null(), ..now };
        assert!(unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &skip, &mut out)
        });
        assert_eq!(out.reason, 1);
        // An unreadable record is reason 1 even with prior state.
        fs::write(dir.record(), b"garbage").unwrap();
        assert!(plan(&mut out));
        assert_eq!(out.reason, 1);
        assert!(!unsafe {
            cmux_launch_record_layout_matches(record.as_ptr(), d.as_ptr(), d.len())
        });
        write_atomic(dir.record(), &sample()).unwrap();
        assert!(unsafe { cmux_launch_record_layout_matches(record.as_ptr(), d.as_ptr(), d.len()) });
        assert!(!unsafe { cmux_launch_record_layout_matches(record.as_ptr(), d.as_ptr(), 1) });
        assert!(!unsafe {
            cmux_launch_record_layout_matches(record.as_ptr(), std::ptr::null(), 2)
        });
        assert!(plan(&mut out));
        assert_eq!(out.reason, 7);
        assert_eq!((out.frame_x, out.frame_width, out.appearance), (100., 800., 1));
        assert_eq!((out.background_rgba, out.bar_rgba), ([1, 2, 3, 4], [5, 6, 7, 8]));
        assert_eq!(image_path(&out), "");
        let file = dir.0.join("images").join(BUILD).join("w").join("3");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, b"png").unwrap();
        assert!(plan(&mut out));
        assert_eq!((out.reason, image_path(&out)), (0, file.to_str().unwrap().to_owned()));
        // Invalid arguments: false with a zeroed plan.
        let bad = [0xffu8, 0];
        let none = CmuxLaunchNow { build: bad.as_ptr().cast(), ..now };
        assert!(!unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &none, &mut out)
        });
        assert_eq!((out.reason, out.frame_width, out.image_path[0]), (0, 0.0, 0));
        let none = CmuxLaunchNow { displays: std::ptr::null(), ..now };
        assert!(!unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &none, &mut out)
        });
        assert!(!unsafe {
            cmux_launch_shell_plan(std::ptr::null(), images.as_ptr(), &now, &mut out)
        });
        assert!(!unsafe {
            cmux_launch_shell_plan(record.as_ptr(), std::ptr::null(), &now, &mut out)
        });
        assert!(!unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), std::ptr::null(), &mut out)
        });
        assert!(!unsafe {
            cmux_launch_shell_plan(record.as_ptr(), images.as_ptr(), &now, std::ptr::null_mut())
        });
    }

    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "cmux-launch-record-test-{}-{}-{}",
                std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn record(&self) -> std::path::PathBuf {
            self.0.join("record")
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn exact_cap_and_one_byte_over() {
        // Zero windows/rows, then a socket string; both are structurally valid.
        for version in [1u8, 2] {
            for extra in [0, 1] {
                let mut bytes = Vec::from(&b"CMUXLR01\x00\x00\x00\x00\x00\x00"[..]);
                bytes[8] = version;
                bytes.extend_from_slice(&((MAX_BYTES - 16 + extra) as u16).to_le_bytes());
                bytes.resize(MAX_BYTES + extra, b'x');
                let dir = TestDir::new();
                fs::write(dir.record(), &bytes).unwrap();
                assert_eq!(LaunchRecord::from_bytes(bytes).is_some(), extra == 0);
                assert_eq!(LaunchRecord::read(dir.record()).is_some(), extra == 0);
            }
        }
        // The writer stops at the same bound.
        let mut data = sample();
        let length = encode(&data).unwrap().len();
        data.session_socket_path.push_str(&"x".repeat(MAX_BYTES - length));
        assert_eq!(encode(&data).unwrap().len(), MAX_BYTES);
        data.session_socket_path.push('x');
        assert!(encode(&data).is_err());
    }

    #[test]
    fn atomic_write_preserves_previous_on_invalid_input() {
        let dir = TestDir::new();
        let mut data = sample();
        write_atomic(dir.record(), &data).unwrap();
        data.windows[0].id = "replacement".into();
        write_atomic(dir.record(), &data).unwrap();
        assert_eq!(
            LaunchRecord::read(dir.record()).unwrap().front_window().unwrap().id,
            "replacement"
        );
        let previous = fs::read(dir.record()).unwrap();
        data.session_socket_path = "x".repeat(MAX_BYTES);
        assert!(write_atomic(dir.record(), &data).is_err());
        assert_eq!(fs::read(dir.record()).unwrap(), previous);
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
        assert!(LaunchRecord::read(dir.0.join("missing")).is_none());
    }

    #[test]
    fn ffi_strings_are_terminated_or_output_is_zero() {
        let dir = TestDir::new();
        let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
        for (id_len, key_len, expected) in [(64, 1024, true), (65, 1024, false), (64, 1025, false)]
        {
            let mut data = sample();
            data.windows[0].id = "w".repeat(id_len);
            data.windows[0].image_key = "p".repeat(key_len);
            write_atomic(dir.record(), &data).unwrap();
            let mut out = CmuxLaunchWindow { display_id: 999, ..Default::default() };
            assert_eq!(
                unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) },
                expected
            );
            if expected {
                assert_eq!(
                    unsafe { CStr::from_ptr(out.window_id.as_ptr()) }.to_bytes().len(),
                    id_len
                );
                assert_eq!(
                    unsafe { CStr::from_ptr(out.image_key.as_ptr()) }.to_bytes().len(),
                    key_len
                );
            } else {
                assert_eq!(out.display_id, 0);
                assert_eq!(out.frame_width, 0.0);
                assert!(out.window_id.iter().chain(out.image_key.iter()).all(|&v| v == 0));
            }
        }
        let mut out = CmuxLaunchWindow { display_id: 999, ..Default::default() };
        assert!(!unsafe { cmux_launch_record_front_window(std::ptr::null(), &mut out) });
        assert_eq!(out.display_id, 0);
        let mut data = sample();
        data.windows[0].image_key = "a\0b".into();
        write_atomic(dir.record(), &data).unwrap();
        assert!(!unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
        assert_eq!(out.display_id, 0);
        // A v1 record still reads, with an empty key and defaulted v2 fields.
        fs::write(dir.record(), encode_v1(&sample())).unwrap();
        assert!(unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
        assert_eq!((out.display_id, out.backing_scale, out.image_key[0]), (7, 0.0, 0));
    }

    #[test]
    fn ffi_rejects_impossible_counts_before_dereference() {
        assert!(
            unsafe {
                input_data(std::ptr::null(), usize::MAX, std::ptr::null(), 0, std::ptr::null())
            }
            .is_none()
        );
        assert!(
            unsafe {
                input_data(std::ptr::null(), 0, std::ptr::null(), usize::MAX, std::ptr::null())
            }
            .is_none()
        );
        assert!(unsafe { displays_from(std::ptr::null(), usize::MAX) }.is_none());
    }

    #[test]
    fn window_min_bytes_matches_encoding() {
        let mut data = sample();
        data.sidebar_rows.clear();
        data.session_socket_path.clear();
        let empty = encode(&LaunchRecordData { windows: vec![], ..data.clone() }).unwrap().len();
        let w = &mut data.windows[0];
        (w.id, w.image_key, w.visible_workspace_id, w.visible_tab_ids) =
            (String::new(), String::new(), String::new(), vec![]);
        assert_eq!(encode(&data).unwrap().len() - empty, WINDOW_MIN_BYTES);
    }

    #[test]
    fn unicode_round_trip_and_invalid_utf8_rejected() {
        let mut data = sample();
        data.sidebar_rows[0].title = "作業 🦀".into();
        data.windows[0].image_key = format!("{BUILD}/画面/1");
        let bytes = encode(&data).unwrap();
        let r = LaunchRecord::from_bytes(bytes).unwrap();
        assert_eq!(r.sidebar_rows().next().unwrap().title, data.sidebar_rows[0].title);
        assert_eq!(r.front_window().unwrap().image_key, data.windows[0].image_key);
        let mut invalid = encode(&sample()).unwrap();
        invalid[16] = 0xff; // First window id.
        assert!(LaunchRecord::from_bytes(invalid).is_none());
    }

    #[test]
    fn stage_zero_is_closed_over_allowlist() {
        assert!(stage_zero_task_is_allowed(LaunchTask {
            name: "read_launch_record",
            stage: LaunchStage::Shell
        }));
        assert!(stage_zero_task_is_allowed(LaunchTask {
            name: "restore_everything",
            stage: LaunchStage::Rest
        }));
        assert!(!stage_zero_task_is_allowed(LaunchTask {
            name: "restore_everything",
            stage: LaunchStage::Shell
        }));
    }

    proptest! {
        #[test]
        fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..(MAX_BYTES + 128))) {
            let _ = LaunchRecord::from_bytes(bytes);
        }
    }
}
