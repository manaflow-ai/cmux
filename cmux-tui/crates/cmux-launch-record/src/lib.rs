//! Bounded launch record consumed by the cmux shell before the app core.
//! The reader owns only the bounded file buffer; fields are views into it.
use std::ffi::{CStr, c_char};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const FORMAT_VERSION: u16 = 1;
pub const MAX_BYTES: usize = 64 * 1024;
const MAGIC: &[u8; 8] = b"CMUXLR01";

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

#[derive(Debug, Clone, Copy, PartialEq)]
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
    pub image_path: String,
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
    pub visible_workspace_id: String,
    pub visible_tab_ids: Vec<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SidebarRow {
    pub id: String,
    pub title: String,
    pub icon_key: String,
}
#[derive(Debug, Clone, PartialEq)]
pub struct LaunchRecordData {
    pub windows: Vec<WindowRecord>,
    pub sidebar_rows: Vec<SidebarRow>,
    pub session_socket_path: String,
}

pub struct LaunchRecord {
    bytes: Vec<u8>,
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
        let mut p = Parser::new(&bytes);
        if p.take(8)? != MAGIC || p.u16()? != FORMAT_VERSION {
            return None;
        };
        let windows = p.u16()? as usize;
        let sidebar_rows = p.u16()? as usize;
        let windows_start = p.position();
        for _ in 0..windows {
            parse_window(&mut p)?;
        }
        let sidebar_start = p.position();
        for _ in 0..sidebar_rows {
            parse_sidebar(&mut p)?;
        }
        let socket = p.string_span()?;
        if p.position() != bytes.len() {
            return None;
        }
        Some(Self { bytes, windows, sidebar_rows, windows_start, sidebar_start, socket })
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
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
pub struct WindowView<'a> {
    bytes: &'a [u8],
    pub id: &'a str,
    pub frame: Frame,
    pub display_id: u32,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub image_path: &'a str,
    pub image_pixel_width: u32,
    pub image_pixel_height: u32,
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
        let (v, end) = decode_window(&self.record.bytes, self.pos)?;
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
    let result: io::Result<()> = (|| {
        let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
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
        for n in [w.frame.x, w.frame.y, w.frame.width, w.frame.height] {
            o.extend_from_slice(&n.to_le_bytes())
        }
        o.extend_from_slice(&w.display_id.to_le_bytes());
        o.extend_from_slice(&w.background_rgba);
        o.extend_from_slice(&w.bar_rgba);
        put_string(&mut o, &w.image_path)?;
        o.extend_from_slice(&w.image_pixel_width.to_le_bytes());
        o.extend_from_slice(&w.image_pixel_height.to_le_bytes());
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
fn put_u16(o: &mut Vec<u8>, n: usize) {
    o.extend_from_slice(&(n as u16).to_le_bytes())
}
fn put_string(o: &mut Vec<u8>, s: &str) -> Result<(), &'static str> {
    if s.len() > u16::MAX as usize || !s.is_ascii() {
        return Err("string must be ASCII and <= 65535 bytes");
    };
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
        self.take(n)?;
        Some((s, n))
    }
}
fn parse_window(p: &mut Parser<'_>) -> Option<()> {
    p.string_span()?;
    p.take(32 + 4 + 4 + 4)?;
    p.string_span()?;
    p.take(8)?;
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
fn decode_window(b: &[u8], mut p: usize) -> Option<(WindowView<'_>, usize)> {
    let (idsp, e) = read_span(b, p)?;
    p = e;
    let mut n = [0.; 4];
    for x in &mut n {
        *x = f64::from_le_bytes(b.get(p..p + 8)?.try_into().ok()?);
        p += 8
    }
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
            frame: Frame { x: n[0], y: n[1], width: n[2], height: n[3] },
            display_id,
            background_rgba: bg,
            bar_rgba: bar,
            image_path: span_str(b, img)?,
            image_pixel_width: iw,
            image_pixel_height: ih,
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
    pub image_path: [c_char; 1025],
}
impl Default for CmuxLaunchWindow {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}
fn copy_c(dst: &mut [c_char], s: &str) {
    for (d, b) in dst.iter_mut().zip(s.bytes()) {
        *d = b as c_char
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_record_front_window(
    path: *const c_char,
    out: *mut CmuxLaunchWindow,
) -> bool {
    if path.is_null() || out.is_null() {
        return false;
    }
    let p = unsafe { CStr::from_ptr(path) };
    let Ok(p) = p.to_str() else { return false };
    let Some(record) = LaunchRecord::read(p) else { return false };
    let Some(w) = record.front_window() else { return false };
    let o = unsafe { &mut *out };
    *o = CmuxLaunchWindow::default();
    o.frame_x = w.frame.x;
    o.frame_y = w.frame.y;
    o.frame_width = w.frame.width;
    o.frame_height = w.frame.height;
    o.display_id = w.display_id;
    o.background_rgba = w.background_rgba;
    o.bar_rgba = w.bar_rgba;
    o.image_pixel_width = w.image_pixel_width;
    o.image_pixel_height = w.image_pixel_height;
    copy_c(&mut o.window_id, w.id);
    copy_c(&mut o.image_path, w.image_path);
    true
}
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    fn sample() -> LaunchRecordData {
        LaunchRecordData {
            windows: vec![WindowRecord {
                id: "w".into(),
                frame: Frame { x: 1., y: 2., width: 3., height: 4. },
                display_id: 7,
                background_rgba: [1, 2, 3, 4],
                bar_rgba: [5, 6, 7, 8],
                image_path: "/tmp/f.png".into(),
                image_pixel_width: 10,
                image_pixel_height: 11,
                visible_workspace_id: "ws".into(),
                visible_tab_ids: vec!["tab".into()],
            }],
            sidebar_rows: vec![SidebarRow {
                id: "s".into(),
                title: "Side".into(),
                icon_key: "folder".into(),
            }],
            session_socket_path: "/tmp/sock".into(),
        }
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
    fn rejects() {
        let mut b = encode(&sample()).unwrap();
        b.push(0);
        assert!(LaunchRecord::from_bytes(b).is_none());
        let mut b = encode(&sample()).unwrap();
        b[8] = 2;
        assert!(LaunchRecord::from_bytes(b).is_none())
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
