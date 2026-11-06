//! The agent cursor: a cmux-blue arrow with a white outline in a layered,
//! click-through, always-on-top window that never activates, on a UI
//! thread of its own. It glides between the points the engine reports
//! (ease-out; a jump when the person turned off Windows animations), and
//! hides after [`crate::cursor::IDLE_HIDE`] without events. The window is
//! excluded from screen capture, so the agent's own screenshots never
//! show it. One cursor per machine: it follows the latest session.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION,
    CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, HBITMAP,
    HDC, MONITOR_DEFAULTTONEAREST, MonitorFromPoint, ReleaseDC, SelectObject,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, HWND_TOPMOST, KillTimer, MSG,
    PostMessageW, RegisterClassExW, SPI_GETCLIENTAREAANIMATION, SW_HIDE, SW_SHOWNOACTIVATE,
    SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetTimer,
    SetWindowDisplayAffinity, SetWindowPos, ShowWindow, SystemParametersInfoW, TranslateMessage,
    ULW_ALPHA, UpdateLayeredWindow, WDA_EXCLUDEFROMCAPTURE, WM_APP, WM_TIMER, WNDCLASSEXW,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};
use windows::core::{BOOL, w};

use super::pure;
use crate::cursor::{CMUX_BLUE, CursorEvent, CursorSink, IDLE_HIDE, OUTLINE};
use crate::desktop::Point;

const GLIDE: Duration = Duration::from_millis(220);
const FRAME_MS: u32 = 16;
const TIMER_ID: usize = 1;
const WAKE: u32 = WM_APP + 1;
/// Arrow units per 96-dpi pixel: about a 22 px tall arrow at 100%.
const BASE_SCALE: f64 = 1.15;

struct Shared {
    queue: Mutex<VecDeque<CursorEvent>>,
    hwnd: AtomicUsize,
    start: Once,
}

struct Overlay(Arc<Shared>);

impl CursorSink for Overlay {
    fn show(&self, event: CursorEvent) {
        {
            let mut q = self.0.queue.lock().unwrap_or_else(|e| e.into_inner());
            q.push_back(event);
            // A stalled UI thread must not grow the queue without bound.
            while q.len() > 256 {
                q.pop_front();
            }
        }
        let shared = self.0.clone();
        self.0.start.call_once(move || {
            let _ = std::thread::Builder::new()
                .name("cmux-cu-cursor".into())
                .spawn(move || run(shared));
        });
        let h = self.0.hwnd.load(Ordering::Acquire);
        if h != 0 {
            // SAFETY: posting a message with no pointers.
            let _ = unsafe { PostMessageW(Some(HWND(h as *mut _)), WAKE, WPARAM(0), LPARAM(0)) };
        }
    }
}

pub fn cursor_overlay() -> Arc<dyn CursorSink> {
    Arc::new(Overlay(Arc::new(Shared {
        queue: Mutex::new(VecDeque::new()),
        hwnd: AtomicUsize::new(0),
        start: Once::new(),
    })))
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    // SAFETY: forwards the window's own message.
    unsafe { DefWindowProcW(hwnd, msg, w, l) }
}

fn animations_on() -> bool {
    let mut on = BOOL(1);
    // SAFETY: a BOOL out buffer.
    let _ = unsafe {
        SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some((&mut on as *mut BOOL).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    on.as_bool()
}

/// The arrow's pixels in a DIB section, premultiplied, for one DPI.
struct Sprite {
    dc: HDC,
    bitmap: HBITMAP,
    width: i32,
    height: i32,
    tip: (i32, i32),
    dpi: u32,
}

impl Sprite {
    fn new(dpi: u32) -> Option<Self> {
        let art = pure::arrow_bitmap(BASE_SCALE * f64::from(dpi) / 96.0, CMUX_BLUE, OUTLINE);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: art.width as i32,
                biHeight: -(art.height as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        // SAFETY: the section holds width*height*4 bytes, written once here;
        // the GDI objects are released in Drop.
        unsafe {
            let dc = CreateCompatibleDC(None);
            let mut bits = std::ptr::null_mut();
            let bitmap =
                CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
            std::ptr::copy_nonoverlapping(art.bgra.as_ptr(), bits.cast::<u8>(), art.bgra.len());
            SelectObject(dc, bitmap.into());
            Some(Self {
                dc,
                bitmap,
                width: art.width as i32,
                height: art.height as i32,
                tip: (art.tip.0 as i32, art.tip.1 as i32),
                dpi,
            })
        }
    }
}

impl Drop for Sprite {
    fn drop(&mut self) {
        // SAFETY: releases what `new` created.
        unsafe {
            let _ = DeleteDC(self.dc);
            let _ = DeleteObject(self.bitmap.into());
        }
    }
}

fn dpi_at(p: (f64, f64)) -> u32 {
    let (mut x, mut y) = (96u32, 96u32);
    // SAFETY: plain queries with local out pointers.
    unsafe {
        let m = MonitorFromPoint(POINT { x: p.0 as i32, y: p.1 as i32 }, MONITOR_DEFAULTTONEAREST);
        let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut x, &mut y);
    }
    x.max(48)
}

struct Cursor {
    hwnd: HWND,
    sprite: Option<Sprite>,
    pos: Option<(f64, f64)>,
    from: (f64, f64),
    to: (f64, f64),
    started: Instant,
    last_event: Instant,
    visible: bool,
    session: String,
}

impl Cursor {
    fn draw(&mut self, p: (f64, f64)) {
        let dpi = dpi_at(p);
        if self.sprite.as_ref().is_none_or(|s| s.dpi != dpi) {
            self.sprite = Sprite::new(dpi);
        }
        let Some(s) = &self.sprite else { return };
        let dst = POINT { x: p.0.round() as i32 - s.tip.0, y: p.1.round() as i32 - s.tip.1 };
        let size = SIZE { cx: s.width, cy: s.height };
        let src = POINT { x: 0, y: 0 };
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        // SAFETY: all pointers are to locals; the screen DC is released.
        unsafe {
            let screen = GetDC(None);
            let _ = UpdateLayeredWindow(
                self.hwnd,
                Some(screen),
                Some(&dst),
                Some(&size),
                Some(s.dc),
                Some(&src),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            );
            ReleaseDC(None, screen);
        }
        self.pos = Some(p);
    }

    fn show(&mut self) {
        if !self.visible {
            // SAFETY: plain calls on our own window.
            unsafe {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
                SetTimer(Some(self.hwnd), TIMER_ID, FRAME_MS, None);
            }
            self.visible = true;
        }
        // Stay above windows that became topmost since.
        // SAFETY: as above.
        let _ = unsafe {
            SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
            )
        };
    }

    fn hide(&mut self) {
        if self.visible {
            // SAFETY: plain calls on our own window.
            unsafe {
                let _ = KillTimer(Some(self.hwnd), TIMER_ID);
                let _ = ShowWindow(self.hwnd, SW_HIDE);
            }
            self.visible = false;
        }
    }

    fn glide_to(&mut self, at: Point) {
        let target = (at.x, at.y);
        let now = Instant::now();
        let current = match self.pos {
            Some(p) if self.visible => {
                let t = now.duration_since(self.started).as_secs_f64() / GLIDE.as_secs_f64();
                if t < 1.0 { pure::glide(self.from, self.to, t) } else { p }
            }
            _ => target,
        };
        self.from = current;
        self.to = target;
        self.started = if animations_on() { now } else { now - GLIDE };
        self.draw(current);
    }

    fn handle(&mut self, event: CursorEvent) {
        if let CursorEvent::Hide { session } = &event {
            if *session == self.session || self.session.is_empty() {
                self.hide();
            }
            return;
        }
        self.session = event.session().to_string();
        self.last_event = Instant::now();
        let at = match &event {
            CursorEvent::Move { at, .. } | CursorEvent::Click { at, .. } => Some(*at),
            CursorEvent::Typing { at, .. } | CursorEvent::Look { at, .. } => *at,
            CursorEvent::Hide { .. } => None,
        };
        match at {
            Some(p) => {
                self.glide_to(p);
                self.show();
            }
            // Typing or looking with no point keeps a shown cursor up.
            None if self.pos.is_some() && self.visible => self.show(),
            None => {}
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();
        let t = now.duration_since(self.started).as_secs_f64() / GLIDE.as_secs_f64();
        if t < 1.0 {
            self.draw(pure::glide(self.from, self.to, t));
        } else if self.pos != Some(self.to) {
            self.draw(self.to);
        } else if now.duration_since(self.last_event) >= IDLE_HIDE {
            self.hide();
        }
    }
}

fn run(shared: Arc<Shared>) {
    super::ensure_dpi_awareness();
    // SAFETY: a window owned by this thread, driven by its own message loop.
    unsafe {
        let Ok(module) = GetModuleHandleW(None) else { return };
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: module.into(),
            lpszClassName: w!("cmuxComputerUseCursor"),
            ..Default::default()
        };
        RegisterClassExW(&class);
        let Ok(hwnd) = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            w!("cmuxComputerUseCursor"),
            w!("cmux agent cursor"),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            Some(module.into()),
            None,
        ) else {
            return;
        };
        // Windows 10 2004+: never in any capture, ours included.
        let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        shared.hwnd.store(hwnd.0 as usize, Ordering::Release);
        let now = Instant::now();
        let mut cursor = Cursor {
            hwnd,
            sprite: None,
            pos: None,
            from: (0.0, 0.0),
            to: (0.0, 0.0),
            started: now,
            last_event: now,
            visible: false,
            session: String::new(),
        };
        let drain = |cursor: &mut Cursor| {
            let events: Vec<CursorEvent> =
                shared.queue.lock().unwrap_or_else(|e| e.into_inner()).drain(..).collect();
            for e in events {
                cursor.handle(e);
            }
        };
        // Events that came before the window existed.
        drain(&mut cursor);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.hwnd == hwnd && msg.message == WAKE {
                drain(&mut cursor);
                continue;
            }
            if msg.hwnd == hwnd && msg.message == WM_TIMER {
                cursor.tick();
                continue;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
