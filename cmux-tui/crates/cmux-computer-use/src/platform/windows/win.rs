//! Top-level windows, their processes and app names.

use std::collections::HashMap;
use std::sync::Mutex;

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{
    DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute,
};
use windows::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
};
use windows::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, EnumWindows, GWL_EXSTYLE, GetClassNameW, GetForegroundWindow,
    GetWindowLongPtrW, GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow,
    IsWindowVisible, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};
use windows::core::{BOOL, HSTRING, PCWSTR, PWSTR};

use super::pure;
use crate::desktop::{App, DResult, DesktopError, Rect, Window};

/// An HWND that crosses threads as its number (HWND is a pointer, so not
/// Send). Window handles are global to the session, so the number is the
/// handle everywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Hwnd(pub usize);

impl Hwnd {
    pub fn parse(id: &str) -> DResult<Self> {
        let h = pure::parse_window_id(id).ok_or_else(|| {
            DesktopError::TargetNotFound(format!(
                "window {id:?} (ids are decimal HWNDs from list_windows)"
            ))
        })?;
        let hwnd = Hwnd(h);
        // SAFETY: IsWindow accepts any value.
        if !unsafe { IsWindow(Some(hwnd.get())) }.as_bool() {
            return Err(DesktopError::TargetNotFound(format!(
                "window {id} is gone; call list_windows"
            )));
        }
        Ok(hwnd)
    }
    pub fn get(self) -> HWND {
        HWND(self.0 as *mut _)
    }
    pub fn from(h: HWND) -> Self {
        Hwnd(h.0 as usize)
    }
}

pub fn rect(r: RECT) -> Rect {
    Rect {
        x: f64::from(r.left),
        y: f64::from(r.top),
        width: f64::from(r.right - r.left),
        height: f64::from(r.bottom - r.top),
    }
}

/// The window's visible frame: DWM's extended frame bounds (without the
/// invisible resize borders), else the window rectangle.
pub fn frame_of(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    // SAFETY: the out buffer is a RECT of the size passed.
    let dwm = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut r as *mut RECT).cast(),
            size_of::<RECT>() as u32,
        )
    };
    if dwm.is_err() || r.right <= r.left {
        // SAFETY: as above.
        let _ = unsafe { GetWindowRect(hwnd, &mut r) };
    }
    r
}

pub fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    // SAFETY: a u32 out buffer of the size passed.
    let ok =
        unsafe { DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), 4) };
    ok.is_ok() && cloaked != 0
}

pub fn pid_of(hwnd: HWND) -> (u32, u32) {
    let mut pid = 0u32;
    // SAFETY: an out pointer to a local.
    let tid = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    (pid, tid)
}

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 256];
    // SAFETY: the slice is the buffer.
    let n = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn title(hwnd: HWND) -> String {
    let mut buf = vec![0u16; 1024];
    // SAFETY: the slice is the buffer. GetWindowTextW sends WM_GETTEXT only
    // to our own windows; for other processes it reads the cached title, so
    // a hung app cannot block us.
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

pub fn exe_path(pid: u32) -> Option<String> {
    // SAFETY: the handle is closed before returning; the buffer and its size match.
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 32768];
        let mut size = buf.len() as u32;
        let got = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut size,
        );
        let _ = CloseHandle(process);
        got.ok()?;
        Some(String::from_utf16_lossy(&buf[..size as usize]))
    }
}

/// The file's version-resource description (`Notepad`), else its file name.
fn friendly_name(path: &str) -> String {
    let fallback = pure::exe_display_name(path);
    let wide = HSTRING::from(path);
    // SAFETY: the version block lives in `data` for every read of it; the
    // pointers VerQueryValueW returns point into it.
    unsafe {
        let size = GetFileVersionInfoSizeW(&wide, None);
        if size == 0 {
            return fallback;
        }
        let mut data = vec![0u8; size as usize];
        if GetFileVersionInfoW(&wide, None, size, data.as_mut_ptr().cast()).is_err() {
            return fallback;
        }
        let mut ptr = std::ptr::null_mut();
        let mut len = 0u32;
        let mut lang = 0x0409_04B0u32;
        if VerQueryValueW(
            data.as_ptr().cast(),
            &HSTRING::from("\\VarFileInfo\\Translation"),
            &mut ptr,
            &mut len,
        )
        .as_bool()
            && len >= 4
        {
            let pair = ptr as *const u16;
            lang = (u32::from(*pair) << 16) | u32::from(*pair.add(1));
        }
        let key = HSTRING::from(format!("\\StringFileInfo\\{lang:08x}\\FileDescription"));
        if VerQueryValueW(data.as_ptr().cast(), &key, &mut ptr, &mut len).as_bool() && len > 1 {
            let s = PCWSTR(ptr as *const u16).to_string().unwrap_or_default();
            let s = s.trim();
            if !s.is_empty() {
                return s.to_string();
            }
        }
        fallback
    }
}

/// Executable paths and names by pid, so a listing reads each file's
/// version resource once.
#[derive(Default)]
pub struct NameCache {
    names: Mutex<HashMap<String, String>>,
}

impl NameCache {
    pub fn name_for(&self, path: &str) -> String {
        let mut names = self.names.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = names.get(path) {
            return n.clone();
        }
        let n = friendly_name(path);
        if names.len() > 512 {
            names.clear();
        }
        names.insert(path.to_string(), n.clone());
        n
    }
}

pub struct Listed {
    pub window: Window,
    pub app_name: String,
}

struct Enum {
    windows: Vec<HWND>,
}

unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: lparam is the &mut Enum passed to EnumWindows for this call.
    let state = unsafe { &mut *(lparam.0 as *mut Enum) };
    state.windows.push(hwnd);
    BOOL(1)
}

/// The app process of a UWP frame: ApplicationFrameHost owns the frame, the
/// app's own process owns a child CoreWindow.
fn uwp_app_pid(frame: HWND, host_pid: u32) -> Option<u32> {
    let mut state = Enum { windows: Vec::new() };
    // SAFETY: the callback only pushes into `state`, which outlives the call.
    let _ = unsafe {
        EnumChildWindows(Some(frame), Some(collect), LPARAM(&mut state as *mut Enum as isize))
    };
    state.windows.into_iter().map(pid_of).map(|(p, _)| p).find(|&p| p != host_pid && p != 0)
}

fn is_app_window(hwnd: HWND) -> bool {
    // SAFETY: plain queries on a handle EnumWindows gave us.
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() || is_cloaked(hwnd) {
            return false;
        }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        let app_window = ex & WS_EX_APPWINDOW.0 != 0;
        if ex & WS_EX_TOOLWINDOW.0 != 0 && !app_window {
            return false;
        }
        // Owned windows (dialogs) stay: they are where many apps ask things.
        !matches!(
            class_name(hwnd).as_str(),
            "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd"
        )
    }
}

/// Visible top-level app windows, front to back.
pub fn top_level_windows(names: &NameCache) -> DResult<Vec<Listed>> {
    let mut state = Enum { windows: Vec::new() };
    // SAFETY: the callback only pushes into `state`, which outlives the call.
    unsafe { EnumWindows(Some(collect), LPARAM(&mut state as *mut Enum as isize)) }
        .map_err(|e| DesktopError::Failed(format!("EnumWindows failed: {e}")))?;
    // SAFETY: plain queries.
    let (own, foreground) = unsafe { (GetCurrentProcessId(), GetForegroundWindow()) };
    let screen = super::capture::virtual_screen();
    let mut paths: HashMap<u32, Option<String>> = HashMap::new();
    let mut out = Vec::new();
    for hwnd in state.windows {
        if !is_app_window(hwnd) {
            continue;
        }
        let (mut pid, _) = pid_of(hwnd);
        if pid == own || pid == 0 {
            continue;
        }
        let mut path = paths.entry(pid).or_insert_with(|| exe_path(pid)).clone();
        if path.as_deref().is_some_and(|p| pure::exe_id(p) == "applicationframehost.exe")
            && let Some(app_pid) = uwp_app_pid(hwnd, pid)
        {
            pid = app_pid;
            path = paths.entry(pid).or_insert_with(|| exe_path(pid)).clone();
        }
        // A process we may not query (elevated, protected) still lists, by
        // pid, so policy can refuse it by name; it never matches an allow.
        let (app_id, app_name) = match &path {
            Some(p) => (pure::exe_id(p), names.name_for(p)),
            None => (format!("pid:{pid}"), format!("Process {pid}")),
        };
        // SAFETY: plain query.
        let minimized = unsafe { IsIconic(hwnd) }.as_bool();
        let frame = rect(frame_of(hwnd));
        if !minimized && (frame.width <= 0.0 || frame.height <= 0.0) {
            continue;
        }
        out.push(Listed {
            window: Window {
                id: Hwnd::from(hwnd).0.to_string(),
                app_id,
                pid,
                title: title(hwnd),
                frame,
                on_screen: !minimized && frame.intersects(&screen),
                focused: hwnd == foreground,
                minimized,
            },
            app_name,
        });
    }
    Ok(out)
}

/// Apps with at least one listed window, front-most first.
pub fn apps(windows: &[Listed]) -> Vec<App> {
    let mut out: Vec<App> = Vec::new();
    for l in windows {
        let w = &l.window;
        match out.iter_mut().find(|a| a.pid == w.pid) {
            Some(app) => {
                app.frontmost |= w.focused;
                app.hidden &= w.minimized;
            }
            None => out.push(App {
                id: w.app_id.clone(),
                name: l.app_name.clone(),
                pid: w.pid,
                frontmost: w.focused,
                hidden: w.minimized,
            }),
        }
    }
    out
}
