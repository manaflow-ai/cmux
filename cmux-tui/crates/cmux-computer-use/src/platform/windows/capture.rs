//! Screenshots: a window through PrintWindow (works when covered), a
//! display through BitBlt of the screen. The agent cursor overlay is
//! excluded from capture (WDA_EXCLUDEFROMCAPTURE), so it never shows in the
//! agent's own screenshots.

use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleDC, CreateDIBSection,
    DIB_RGB_COLORS, DeleteDC, DeleteObject, EnumDisplayMonitors, GdiFlush, GetDC, GetMonitorInfoW,
    HBITMAP, HDC, HMONITOR, MONITOR_DEFAULTTOPRIMARY, MONITORINFO, MONITORINFOEXW,
    MonitorFromPoint, ReleaseDC, SRCCOPY, SelectObject,
};
use windows::Win32::Storage::Xps::{PRINT_WINDOW_FLAGS, PrintWindow};
use windows::Win32::UI::WindowsAndMessaging::{
    GA_ROOT, GetAncestor, GetSystemMetrics, GetWindowRect, IsIconic, PW_RENDERFULLCONTENT,
    SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, WindowFromPoint,
};
use windows::core::BOOL;

use super::pure;
use super::win::{self, Hwnd};
use crate::desktop::{DResult, DesktopError, Point, RawFrame, Rect};

/// The whole virtual screen (every monitor), in desktop pixels.
pub fn virtual_screen() -> Rect {
    // SAFETY: plain queries.
    unsafe {
        Rect {
            x: f64::from(GetSystemMetrics(SM_XVIRTUALSCREEN)),
            y: f64::from(GetSystemMetrics(SM_YVIRTUALSCREEN)),
            width: f64::from(GetSystemMetrics(SM_CXVIRTUALSCREEN)),
            height: f64::from(GetSystemMetrics(SM_CYVIRTUALSCREEN)),
        }
    }
}

/// A 32-bit top-down DIB section selected into its own memory DC.
struct Dib {
    dc: HDC,
    bitmap: HBITMAP,
    old: windows::Win32::Graphics::Gdi::HGDIOBJ,
    bits: *mut u8,
    width: i32,
    height: i32,
}

impl Dib {
    fn new(width: i32, height: i32) -> DResult<Self> {
        if width <= 0 || height <= 0 || width > 32768 || height > 32768 {
            return Err(DesktopError::Failed(format!("cannot capture a {width}x{height} area")));
        }
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        // SAFETY: GDI objects created here are released in Drop; `bits`
        // points into the section, valid while `bitmap` lives.
        unsafe {
            let dc = CreateCompatibleDC(None);
            if dc.is_invalid() {
                return Err(DesktopError::Failed("CreateCompatibleDC failed".into()));
            }
            let mut bits = std::ptr::null_mut();
            let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0)
            {
                Ok(b) => b,
                Err(e) => {
                    let _ = DeleteDC(dc);
                    return Err(DesktopError::Failed(format!("CreateDIBSection failed: {e}")));
                }
            };
            let old = SelectObject(dc, bitmap.into());
            Ok(Self { dc, bitmap, old, bits: bits.cast(), width, height })
        }
    }

    fn rgba(&self) -> Vec<u8> {
        let (w, h) = (self.width as usize, self.height as usize);
        // SAFETY: GDI is flushed, then the section holds w*h*4 bytes.
        unsafe {
            let _ = GdiFlush();
            let bgra = std::slice::from_raw_parts(self.bits, w * h * 4);
            pure::bgra_to_rgba(bgra, w, h, w * 4)
        }
    }
}

impl Drop for Dib {
    fn drop(&mut self) {
        // SAFETY: undoes `new` in reverse order.
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

fn blit_screen(r: RECT) -> DResult<Vec<u8>> {
    let dib = Dib::new(r.right - r.left, r.bottom - r.top)?;
    // SAFETY: the screen DC is released after the copy.
    unsafe {
        let screen = GetDC(None);
        let ok = BitBlt(
            dib.dc,
            0,
            0,
            dib.width,
            dib.height,
            Some(screen),
            r.left,
            r.top,
            SRCCOPY | CAPTUREBLT,
        );
        ReleaseDC(None, screen);
        ok.map_err(|e| DesktopError::Failed(format!("BitBlt failed: {e}")))?;
    }
    Ok(dib.rgba())
}

/// True when the window is on top at its center and corners, so a screen
/// copy of its frame shows only it.
fn uncovered(hwnd: HWND, f: RECT) -> bool {
    let inset = 8;
    let points = [
        ((f.left + f.right) / 2, (f.top + f.bottom) / 2),
        (f.left + inset, f.top + inset),
        (f.right - inset, f.top + inset),
        (f.left + inset, f.bottom - inset),
        (f.right - inset, f.bottom - inset),
    ];
    points.iter().all(|&(x, y)| {
        // SAFETY: plain queries.
        unsafe { GetAncestor(WindowFromPoint(POINT { x, y }), GA_ROOT) == hwnd }
    })
}

pub fn window(h: Hwnd) -> DResult<RawFrame> {
    let hwnd = h.get();
    // SAFETY: plain query.
    if unsafe { IsIconic(hwnd) }.as_bool() {
        return Err(DesktopError::Unsupported(
            "the window is minimized and has no pixels; use get_ui_tree, or restore it first"
                .into(),
        ));
    }
    let frame = win::frame_of(hwnd);
    let mut outer = RECT::default();
    // SAFETY: an out pointer to a local.
    unsafe { GetWindowRect(hwnd, &mut outer) }
        .map_err(|e| DesktopError::TargetNotFound(format!("window {}: {e}", h.0)))?;
    let dib = Dib::new(outer.right - outer.left, outer.bottom - outer.top)?;
    // SAFETY: draws into our own DC.
    let printed =
        unsafe { PrintWindow(hwnd, dib.dc, PRINT_WINDOW_FLAGS(PW_RENDERFULLCONTENT)) }.as_bool();
    let full = dib.rgba();
    // PrintWindow renders the whole window rectangle; crop it to the visible
    // frame so the image's origin is the frame we list.
    let (rgba, width, height) = pure::crop_rgba(
        &full,
        dib.width as usize,
        dib.height as usize,
        (frame.left - outer.left).max(0) as usize,
        (frame.top - outer.top).max(0) as usize,
        (frame.right - frame.left).max(0) as usize,
        (frame.bottom - frame.top).max(0) as usize,
    );
    let rgba = if printed && !pure::all_black(&rgba) {
        rgba
    } else if uncovered(hwnd, frame) {
        // Some GPU-composed apps do not render for PrintWindow. When the
        // window is in front, the screen holds exactly its pixels.
        blit_screen(frame)?
    } else {
        return Err(DesktopError::Unsupported(
            "this window does not render off-screen (PrintWindow returned no pixels) and another window covers it; use get_ui_tree, or a display screenshot".into(),
        ));
    };
    Ok(RawFrame {
        width: width as u32,
        height: height as u32,
        rgba,
        scale: 1.0,
        origin: Point { x: f64::from(frame.left), y: f64::from(frame.top) },
    })
}

pub struct Monitor {
    pub device: String,
    pub rect: RECT,
    pub primary: bool,
}

unsafe extern "system" fn collect_monitor(
    m: HMONITOR,
    _dc: HDC,
    _r: *mut RECT,
    lparam: LPARAM,
) -> BOOL {
    // SAFETY: lparam is the &mut Vec passed to EnumDisplayMonitors.
    let list = unsafe { &mut *(lparam.0 as *mut Vec<HMONITOR>) };
    list.push(m);
    BOOL(1)
}

fn monitor_info(handle: HMONITOR) -> Option<Monitor> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    // SAFETY: cbSize says the buffer is a MONITORINFOEXW.
    let ok = unsafe {
        GetMonitorInfoW(handle, (&mut info as *mut MONITORINFOEXW).cast::<MONITORINFO>())
    };
    if !ok.as_bool() {
        return None;
    }
    let len = info.szDevice.iter().position(|&c| c == 0).unwrap_or(info.szDevice.len());
    Some(Monitor {
        device: String::from_utf16_lossy(&info.szDevice[..len]),
        rect: info.monitorInfo.rcMonitor,
        primary: info.monitorInfo.dwFlags & 1 != 0,
    })
}

pub fn monitors() -> Vec<Monitor> {
    let mut handles: Vec<HMONITOR> = Vec::new();
    // SAFETY: the callback only pushes into `handles`, which outlives the call.
    let _ = unsafe {
        EnumDisplayMonitors(
            None,
            None,
            Some(collect_monitor),
            LPARAM(&mut handles as *mut _ as isize),
        )
    };
    handles.into_iter().filter_map(monitor_info).collect()
}

/// `None` is the primary monitor; otherwise a monitor's index in
/// enumeration order (`"0"`, `"1"`), its device name (`\\.\DISPLAY2`) or
/// `"all"` for the whole virtual screen.
pub fn display(id: Option<&str>) -> DResult<RawFrame> {
    let r = match id {
        None | Some("main") | Some("primary") => {
            // SAFETY: plain query.
            let primary =
                unsafe { MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY) };
            monitor_info(primary)
                .map(|m| m.rect)
                .ok_or_else(|| DesktopError::Failed("no primary monitor".into()))?
        }
        Some("all") => {
            let v = virtual_screen();
            RECT {
                left: v.x as i32,
                top: v.y as i32,
                right: (v.x + v.width) as i32,
                bottom: (v.y + v.height) as i32,
            }
        }
        Some(want) => {
            let list = monitors();
            let found = match want.parse::<usize>() {
                Ok(i) => list.get(i),
                Err(_) => list.iter().find(|m| m.device.eq_ignore_ascii_case(want)),
            };
            let names: Vec<String> = list
                .iter()
                .enumerate()
                .map(|(i, m)| {
                    format!("{i} ({}{})", m.device, if m.primary { ", primary" } else { "" })
                })
                .collect();
            found.map(|m| m.rect).ok_or_else(|| {
                DesktopError::TargetNotFound(format!(
                    "display {want:?}; displays are {}",
                    names.join(", ")
                ))
            })?
        }
    };
    let rgba = blit_screen(r)?;
    Ok(RawFrame {
        width: (r.right - r.left) as u32,
        height: (r.bottom - r.top) as u32,
        rgba,
        scale: 1.0,
        origin: Point { x: f64::from(r.left), y: f64::from(r.top) },
    })
}
