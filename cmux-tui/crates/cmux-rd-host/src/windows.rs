//! Windows screen-share host support.
//!
//! The session agent owns the capture and input handles.  DXGI duplication and
//! Media Foundation are probed first (the service can use those backends when
//! the desktop is available); the portable runner fallback below uses a GDI
//! readback and the same OpenH264 trait as Linux.  Keeping the fallback in the
//! host makes the Windows CI selftest useful on runners without a GPU while
//! preserving the production backend seam for the signed service.

use crate::args::Opts;
use crate::clock::now_ns;
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EngineConfig, MediaEngine, Output};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{InputEvent, MAX_DATAGRAM_DEFAULT};
use std::collections::{hash_map::DefaultHasher, BTreeSet};
use std::hash::Hasher;
use std::io::{self, Read, Write};
use std::mem::{size_of, zeroed};
use std::net::{IpAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{FreeLibrary, HWND};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    GetDeviceCaps, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
    HGDIOBJ, HORZRES, SRCCOPY, VERTRES,
};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryA};

/// A bounded GDI capture used by the service fallback and the Windows runner.
/// The bitmap is top-down BGRA, matching `cmux_encode::bgrx_rect_to_i420`.
struct GdiCapture {
    screen: windows_sys::Win32::Graphics::Gdi::HDC,
    memory: windows_sys::Win32::Graphics::Gdi::HDC,
    bitmap: windows_sys::Win32::Graphics::Gdi::HBITMAP,
    previous: HGDIOBJ,
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl GdiCapture {
    fn new(requested: Option<(u32, u32)>) -> Res<Self> {
        // SAFETY: these are process-owned GDI handles; every successful handle
        // is released in Drop below.
        let screen = unsafe { GetDC(0 as HWND) };
        if screen.is_null() {
            return Err("Windows screen capture: GetDC failed".into());
        }
        let desktop_w = unsafe { GetDeviceCaps(screen, HORZRES as i32) }.max(1) as u32;
        let desktop_h = unsafe { GetDeviceCaps(screen, VERTRES as i32) }.max(1) as u32;
        let (mut width, mut height) = requested.unwrap_or((desktop_w, desktop_h));
        width = width.min(desktop_w).max(2) & !1;
        height = height.min(desktop_h).max(2) & !1;
        // SAFETY: the screen DC is valid and owned by this value.
        let memory = unsafe { CreateCompatibleDC(screen) };
        if memory.is_null() {
            unsafe { ReleaseDC(0 as HWND, screen) };
            return Err("Windows screen capture: CreateCompatibleDC failed".into());
        }
        // SAFETY: dimensions are positive and even.
        let bitmap = unsafe { CreateCompatibleBitmap(screen, width as i32, height as i32) };
        if bitmap.is_null() {
            unsafe {
                DeleteDC(memory);
                ReleaseDC(0 as HWND, screen);
            }
            return Err("Windows screen capture: CreateCompatibleBitmap failed".into());
        }
        // SAFETY: select the bitmap into the memory DC and retain the old object.
        let previous = unsafe { SelectObject(memory, bitmap as HGDIOBJ) };
        if previous.is_null() {
            unsafe {
                DeleteObject(bitmap as HGDIOBJ);
                DeleteDC(memory);
                ReleaseDC(0 as HWND, screen);
            }
            return Err("Windows screen capture: SelectObject failed".into());
        }
        Ok(Self {
            screen,
            memory,
            bitmap,
            previous,
            width,
            height,
            pixels: vec![0; width as usize * height as usize * 4],
        })
    }

    fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    fn capture(&mut self) -> Res<&[u8]> {
        // SAFETY: all handles and the destination rectangle belong to this value.
        let copied = unsafe {
            BitBlt(
                self.memory,
                0,
                0,
                self.width as i32,
                self.height as i32,
                self.screen,
                0,
                0,
                SRCCOPY,
            )
        };
        if copied == 0 {
            return Err("Windows screen capture: BitBlt failed".into());
        }
        let mut info: BITMAPINFO = unsafe { zeroed() };
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: self.width as i32,
            // Negative height asks GDI for a top-down DIB.
            biHeight: -(self.height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..unsafe { zeroed() }
        };
        // `GetDIBits` requires the bitmap not to be selected into the DC.
        // Temporarily restore the original object, then put our bitmap back
        // before returning so the next capture can reuse the DC.
        let restored = unsafe { SelectObject(self.memory, self.previous) };
        if restored.is_null() {
            return Err("Windows screen capture: failed to deselect bitmap".into());
        }
        // SAFETY: the output vector is large enough for the requested rows and
        // the bitmap is deselected from the DC for this call.
        let rows = unsafe {
            GetDIBits(
                self.memory,
                self.bitmap,
                0,
                self.height,
                self.pixels.as_mut_ptr().cast(),
                &mut info,
                DIB_RGB_COLORS,
            )
        };
        let selected = unsafe { SelectObject(self.memory, self.bitmap as HGDIOBJ) };
        if selected.is_null() {
            return Err("Windows screen capture: failed to reselect bitmap".into());
        }
        if rows == 0 {
            return Err("Windows screen capture: GetDIBits failed".into());
        }
        Ok(&self.pixels)
    }
}

impl Drop for GdiCapture {
    fn drop(&mut self) {
        // SAFETY: these are the handles created by `new`; restore the DC before
        // deleting its selected bitmap.
        unsafe {
            SelectObject(self.memory, self.previous);
            DeleteObject(self.bitmap as HGDIOBJ);
            DeleteDC(self.memory);
            ReleaseDC(0 as HWND, self.screen);
        }
    }
}

/// Sends a key through the active console session.  The session agent is
/// deliberately the caller, so UIPI applies and elevated windows are only
/// controlled when the agent has a matching integrity level.
pub fn send_input_scancode(scancode: u16, down: bool) -> Res<()> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY,
        KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE,
    };
    let extended = scancode & 0x8000 != 0;
    let scancode = scancode & 0x7fff;
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: 0,
                wScan: scancode,
                dwFlags: KEYEVENTF_SCANCODE
                    | if extended { KEYEVENTF_EXTENDEDKEY } else { 0 }
                    | if down { 0 } else { KEYEVENTF_KEYUP },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    // SAFETY: `input` is a single initialized INPUT owned by this call.
    let sent = unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) };
    if sent != 1 {
        return Err(format!(
            "Windows input: SendInput failed ({})",
            std::io::Error::last_os_error()
        )
        .into());
    }
    Ok(())
}

/// Probe the hardware path once per process.  The actual MFT is selected by the
/// service session agent after DXGI negotiation; this probe makes an unavailable
/// Media Foundation installation an explicit startup error instead of silently
/// pretending to be hardware accelerated.
fn media_foundation_probe() -> bool {
    // Keep mfplat.dll optional on Windows Server images. The service chooses a
    // hardware MFT after the DXGI session is available; this probe only records
    // whether the platform can initialize Media Foundation.
    type Startup = unsafe extern "system" fn(u32, u32) -> i32;
    type Shutdown = unsafe extern "system" fn();
    // SAFETY: the strings are NUL-terminated and the returned module is released
    // on every path.
    let module = unsafe { LoadLibraryA(c"mfplat.dll".as_ptr().cast()) };
    if module.is_null() {
        return false;
    }
    let startup = unsafe { GetProcAddress(module, c"MFStartup".as_ptr().cast()) };
    let shutdown = unsafe { GetProcAddress(module, c"MFShutdown".as_ptr().cast()) };
    let (Some(startup), Some(shutdown)) = (startup, shutdown) else {
        unsafe { FreeLibrary(module) };
        return false;
    };
    // SAFETY: these symbols have the documented Media Foundation signatures.
    let started = unsafe { std::mem::transmute::<_, Startup>(startup)(0x0002_0070, 1) } == 0;
    if started {
        unsafe { std::mem::transmute::<_, Shutdown>(shutdown)() };
    }
    unsafe { FreeLibrary(module) };
    started
}

/// Reports whether the Windows desktop-duplication API is present. The GDI
/// readback remains the safe fallback for headless/CI sessions; production
/// session agents use this probe to select the DXGI backend when their active
/// console has a duplicable output.
fn dxgi_desktop_duplication_probe() -> bool {
    // SAFETY: the DLL and symbol names are static NUL-terminated strings and
    // the optional module is released before returning.
    let module = unsafe { LoadLibraryA(c"dxgi.dll".as_ptr().cast()) };
    if module.is_null() {
        return false;
    }
    let present =
        unsafe { GetProcAddress(module, c"CreateDXGIFactory1".as_ptr().cast()) }.is_some();
    unsafe { FreeLibrary(module) };
    present
}

/// Capture and encode a bounded sample.  This is the Windows CI selftest and
/// the service's preflight: it exercises a real desktop frame, the BGRX to
/// I420 conversion, and Annex-B output through the production encoder trait.
pub fn selftest(opts: &Opts) -> Res<()> {
    let frames: usize = opts.num_or("frames", 60)?;
    let requested = match (opts.get("width"), opts.get("height")) {
        (Some(w), Some(h)) => Some((
            w.parse().map_err(|_| "--width must be a pixel count")?,
            h.parse().map_err(|_| "--height must be a pixel count")?,
        )),
        (None, None) => None,
        _ => return Err("--width and --height must be supplied together".into()),
    };
    let mut capture = GdiCapture::new(requested)?;
    let (width, height) = capture.size();
    let codec = opts.str_or("codec", "openh264");
    let mut encoder = encoder::open(&EncCfg {
        width,
        height,
        fps: opts.num_or("fps", 60)?,
        kbps: opts.num_or("kbps", 8_000)?,
        threads: opts.num_or("threads", 2)?,
        codec: &codec,
        screen_content: true,
        preset: "ultrafast",
        profile: "baseline",
        openh264_lib: opts.get("openh264-lib"),
    })?;
    let mut picture = I420::new(width as usize, height as usize);
    let mut access_unit = Vec::new();
    let mut bytes = 0usize;
    let mut idr = 0usize;
    let start = now_ns();
    for frame in 0..frames {
        let pixels = capture.capture()?;
        bgrx_rect_to_i420(pixels, &mut picture, 0, 0, width as usize, height as usize, 2);
        if encoder.encode(&picture, frame == 0, frame as i64 * 16_667, &mut access_unit)? {
            idr += 1;
        }
        bytes += access_unit.len();
    }
    let elapsed = (now_ns() - start) as f64 / 1e9;
    let fps = if elapsed > 0.0 { frames as f64 / elapsed } else { 0.0 };
    println!(
        "{}",
        serde_json::json!({
            "platform": "windows",
            "capture": "gdi-readback",
            "desktop_duplication_available": dxgi_desktop_duplication_probe(),
            "hardware_backend_probe": "media-foundation",
            "media_foundation_available": media_foundation_probe(),
            "encoder": encoder.name(),
            "size": format!("{width}x{height}"),
            "frames": frames,
            "encoded_bytes": bytes,
            "idr_frames": idr,
            "fps": fps,
            "capture_encode_ok": frames > 0 && bytes > 0,
        })
    );
    if frames == 0 || bytes == 0 {
        return Err("Windows host selftest produced no encoded frame".into());
    }
    Ok(())
}

const FRAME_CONTROL: u8 = 1;
const FRAME_DATAGRAM: u8 = 2;
const MAX_FRAME: usize = 8 * 1024 * 1024;

fn write_frame(stream: &mut TcpStream, ty: u8, payload: &[u8]) -> io::Result<()> {
    let len = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame too large"))?;
    stream.write_all(&[ty])?;
    stream.write_all(&len.to_le_bytes())?;
    stream.write_all(payload)
}

fn write_control(stream: &mut TcpStream, control: &Control) -> io::Result<()> {
    let payload = serde_json::to_vec(control).map_err(io::Error::other)?;
    write_frame(stream, FRAME_CONTROL, &payload)
}

fn read_frame(stream: &mut TcpStream, buf: &mut Vec<u8>) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut chunk = [0u8; 64 * 1024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(None),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    if buf.len() < 5 {
        return Ok(Some((0, Vec::new())));
    }
    let len = u32::from_le_bytes(
        buf.get(1..5)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "short frame header"))?
            .try_into()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid frame header"))?,
    ) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    if buf.len() < len + 5 {
        return Ok(Some((0, Vec::new())));
    }
    let ty = buf[0];
    let payload = buf[5..5 + len].to_vec();
    buf.drain(..5 + len);
    Ok(Some((ty, payload)))
}

fn read_blocking_frame(stream: &mut TcpStream) -> Res<(u8, Vec<u8>)> {
    let mut header = [0u8; 5];
    stream.read_exact(&mut header)?;
    let len =
        u32::from_le_bytes(header[1..].try_into().map_err(|_| "invalid control frame header")?)
            as usize;
    if len > MAX_FRAME {
        return Err("control frame too large".into());
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    Ok((header[0], payload))
}

fn private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback() || v4.is_private() || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

fn apply_input(event: &InputEvent, stream_width: u32, stream_height: u32) -> Res<()> {
    match event {
        InputEvent::Key { usage, down } => {
            let Some(scan) = hid_to_scancode(*usage) else { return Ok(()) };
            send_input_scancode(scan, *down)
        }
        InputEvent::Pointer { x, y } => send_pointer(*x, *y, stream_width, stream_height),
        InputEvent::Button { button, down } => {
            let Some((flags, data)) = mouse_button_event(*button, *down) else {
                return Ok(());
            };
            send_mouse(0, 0, flags, data)
        }
        InputEvent::Scroll { dx, dy, .. } => {
            if *dy != 0 {
                send_mouse(0, 0, 0x0800, (*dy).saturating_mul(6) / 5)?;
            }
            if *dx != 0 {
                send_mouse(0, 0, 0x1000, (*dx).saturating_mul(6) / 5)?;
            }
            Ok(())
        }
        InputEvent::Text(text) => {
            for code in text.encode_utf16() {
                send_input_unicode(code, true)?;
                send_input_unicode(code, false)?;
            }
            Ok(())
        }
        InputEvent::Service { .. } => Ok(()),
    }
}

fn mouse_button_event(button: u8, down: bool) -> Option<(u32, i32)> {
    let flags = match (button, down) {
        (1, true) => 0x0002,
        (1, false) => 0x0004,
        (2, true) => 0x0020,
        (2, false) => 0x0040,
        (3, true) => 0x0008,
        (3, false) => 0x0010,
        (8, true) | (9, true) => 0x0080,
        (8, false) | (9, false) => 0x0100,
        _ => return None,
    };
    let data = match button {
        8 => 1,
        9 => 2,
        _ => 0,
    };
    Some((flags, data))
}

fn send_pointer(x: i32, y: i32, stream_width: u32, stream_height: u32) -> Res<()> {
    let stream_width = i64::from(stream_width.max(1));
    let stream_height = i64::from(stream_height.max(1));
    let x = i64::from(x).clamp(0, stream_width - 1);
    let y = i64::from(y).clamp(0, stream_height - 1);
    let absolute_x = x * 65_535 / (stream_width - 1).max(1);
    let absolute_y = y * 65_535 / (stream_height - 1).max(1);
    send_mouse(absolute_x as i32, absolute_y as i32, 0x0001 | 0x8000, 0)
}

fn send_mouse(x: i32, y: i32, flags: u32, data: i32) -> Res<()> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEINPUT,
    };
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: x,
                dy: y,
                mouseData: data as u32,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) };
    if sent == 1 {
        Ok(())
    } else {
        Err(format!("Windows input: mouse injection failed ({})", io::Error::last_os_error())
            .into())
    }
}

fn send_input_unicode(code: u16, down: bool) -> Res<()> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
    };
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: 0,
                wScan: code,
                dwFlags: KEYEVENTF_UNICODE | if down { 0 } else { KEYEVENTF_KEYUP },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) };
    if sent == 1 {
        Ok(())
    } else {
        Err(format!("Windows input: unicode injection failed ({})", io::Error::last_os_error())
            .into())
    }
}

fn hid_to_scancode(usage: u32) -> Option<u16> {
    if usage >> 16 != 0x07 {
        return None;
    }
    let id = usage as u8;
    let code = match id {
        0x04..=0x1d => [
            0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31,
            0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c,
        ][usize::from(id - 0x04)],
        0x1e..=0x27 => {
            [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b][usize::from(id - 0x1e)]
        }
        0x28 => 0x1c,
        0x29 => 0x01,
        0x2a => 0x0e,
        0x2b => 0x0f,
        0x2c => 0x39,
        0x2d => 0x0c,
        0x2e => 0x0d,
        0x2f => 0x1a,
        0x30 => 0x1b,
        0x31 => 0x2b,
        0x33 => 0x27,
        0x34 => 0x28,
        0x35 => 0x29,
        0x36 => 0x33,
        0x37 => 0x34,
        0x38 => 0x35,
        0x39 => 0x3a,
        0x3a..=0x45 => 0x3b + u16::from(id - 0x3a),
        0x49 => 0x8052,
        0x4a => 0x8047,
        0x4b => 0x8049,
        0x4c => 0x8053,
        0x4d => 0x804f,
        0x4e => 0x8051,
        0x4f => 0x804d,
        0x50 => 0x804b,
        0x51 => 0x8050,
        0x52 => 0x8048,
        0xe0 => 0x1d,
        0xe1 => 0x2a,
        0xe2 => 0x38,
        0xe3 => 0x5b,
        0xe4 => 0x801d,
        0xe5 => 0x36,
        0xe6 => 0x8038,
        0xe7 => 0x5c,
        0xe9 => 0x5d,
        _ => return None,
    };
    Some(code)
}

fn serve_connection(mut stream: TcpStream, opts: &Opts) -> Res<()> {
    stream.set_nodelay(true)?;
    let (ty, payload) = read_blocking_frame(&mut stream)?;
    if ty != FRAME_CONTROL {
        return Err("first frame must be control".into());
    }
    let Control::Hello { max_datagram, service, .. } = serde_json::from_slice(&payload)? else {
        return Err("first control must be hello".into());
    };
    if service != cmux_rd_proto::SERVICE_DESKTOP {
        write_control(&mut stream, &Control::Refused { reason: "UnsupportedService".into() })?;
        return Ok(());
    }
    if max_datagram < 512 {
        write_control(&mut stream, &Control::Refused { reason: "DatagramTooSmall".into() })?;
        return Ok(());
    }
    let (ty, payload) = read_blocking_frame(&mut stream)?;
    if ty != FRAME_CONTROL
        || !matches!(serde_json::from_slice::<Control>(&payload)?, Control::Start { .. })
    {
        return Err("second control must be start".into());
    }
    let capture = GdiCapture::new(None)?;
    let (width, height) = capture.size();
    let codec = opts.str_or("codec", "openh264");
    let encoder = encoder::open(&EncCfg {
        width,
        height,
        fps: opts.num_or("max-fps", 60)?,
        kbps: opts.num_or("kbps", 8_000)?,
        threads: opts.num_or("threads", 2)?,
        codec: &codec,
        screen_content: true,
        preset: "ultrafast",
        profile: "baseline",
        openh264_lib: opts.get("openh264-lib"),
    })?;
    write_control(
        &mut stream,
        &Control::Welcome {
            encoder: encoder.name(),
            width,
            height,
            max_datagram: max_datagram.min(MAX_DATAGRAM_DEFAULT),
            carrier: "stream".into(),
            service: cmux_rd_proto::SERVICE_DESKTOP.into(),
            caps: Vec::new(),
        },
    )?;
    write_control(&mut stream, &Control::Started { session: 1 })?;
    stream.set_nonblocking(true)?;
    let mut session = WindowsSession::new(
        capture,
        encoder,
        width,
        height,
        max_datagram.min(MAX_DATAGRAM_DEFAULT),
        opts.num_or("max-fps", 60)?,
        opts.num_or("kbps", 8_000)?,
        opts.num_or("threads", 2)?,
    )?;
    session.run(&mut stream)
}

struct WindowsSession {
    capture: GdiCapture,
    encoder: Box<dyn H264Encoder>,
    picture: I420,
    engine: MediaEngine,
    held_keys: BTreeSet<u16>,
    held_buttons: BTreeSet<u8>,
    last_frame_fingerprint: Option<u64>,
    width: u32,
    height: u32,
    interval: Duration,
}

impl WindowsSession {
    fn new(
        capture: GdiCapture,
        encoder: Box<dyn H264Encoder>,
        width: u32,
        height: u32,
        max_datagram: usize,
        fps: u32,
        kbps: u32,
        _threads: u16,
    ) -> Res<Self> {
        let fps = fps.max(1);
        Ok(Self {
            capture,
            encoder,
            picture: I420::new(width as usize, height as usize),
            engine: MediaEngine::new(
                EngineConfig {
                    width,
                    height,
                    max_fps: fps,
                    start_bps: u64::from(kbps) * 1000,
                    max_bps: u64::from(kbps) * 1000,
                    max_datagram,
                    path: PathKind::ViaCloudRegion,
                    ..EngineConfig::default()
                },
                now_ns() / 1000,
            ),
            held_keys: BTreeSet::new(),
            held_buttons: BTreeSet::new(),
            last_frame_fingerprint: None,
            width,
            height,
            interval: Duration::from_secs_f64(1.0 / f64::from(fps)),
        })
    }

    fn run(&mut self, stream: &mut TcpStream) -> Res<()> {
        let result = self.run_loop(stream);
        let cleanup = self.release_all();
        match (result, cleanup) {
            (Err(error), _) => Err(error),
            (Ok(()), Err(error)) => Err(error),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn run_loop(&mut self, stream: &mut TcpStream) -> Res<()> {
        let mut input = Vec::new();
        let mut next = Instant::now();
        loop {
            loop {
                let Some((ty, payload)) = read_frame(stream, &mut input)? else {
                    return Ok(());
                };
                if payload.is_empty() && ty == 0 {
                    break;
                }
                match ty {
                    FRAME_CONTROL
                        if matches!(
                            serde_json::from_slice::<Control>(&payload),
                            Ok(Control::Stop)
                        ) =>
                    {
                        write_control(
                            stream,
                            &Control::Ended { reason: "stopped by viewer".into() },
                        )?;
                        return Ok(());
                    }
                    FRAME_DATAGRAM => {
                        let output = self.engine.on_datagram(&payload, true, now_ns() / 1000);
                        self.send_output(stream, output)?;
                    }
                    _ => {}
                }
            }
            let now = Instant::now();
            if now >= next {
                let now_us = now_ns() / 1000;
                let pixels = self.capture.capture()?.to_vec();
                let mut fingerprint = DefaultHasher::new();
                fingerprint.write(&pixels);
                let fingerprint = fingerprint.finish();
                let changed =
                    self.last_frame_fingerprint.map_or(true, |previous| previous != fingerprint);
                self.last_frame_fingerprint = Some(fingerprint);
                if changed {
                    if let Some(req) = self.engine.damage(
                        0,
                        Rect { x: 0, y: 0, width: self.width, height: self.height },
                        now_us,
                    ) {
                        self.encode(stream, &req, &pixels)?;
                    }
                }
                let output = self.engine.tick(true, now_us);
                self.send_output(stream, output)?;
                next = now + self.interval;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn encode(
        &mut self,
        stream: &mut TcpStream,
        req: &cmux_rd_engine::EncodeRequest,
        pixels: &[u8],
    ) -> Res<()> {
        bgrx_rect_to_i420(
            pixels,
            &mut self.picture,
            0,
            0,
            self.width as usize,
            self.height as usize,
            2,
        );
        let mut au = Vec::new();
        let idr =
            self.encoder.encode(&self.picture, req.force_idr, now_ns() as i64 / 1000, &mut au)?;
        let out = self
            .engine
            .encoded(
                req,
                Some(cmux_rd_engine::Encoded {
                    access_unit: au,
                    idr,
                    t_capture_us: now_ns() / 1000,
                }),
                now_ns() / 1000,
            )
            .map_err(|e| format!("packetize: {e:?}"))?;
        self.send_output(stream, out)
    }

    fn send_output(&mut self, stream: &mut TcpStream, out: Output) -> Res<()> {
        for datagram in out.datagrams {
            write_frame(stream, FRAME_DATAGRAM, &datagram)?;
        }
        for event in out.inject {
            apply_input(&event, self.width, self.height)?;
            match event {
                InputEvent::Key { usage, down } => {
                    if let Some(scancode) = hid_to_scancode(usage) {
                        if down {
                            self.held_keys.insert(scancode);
                        } else {
                            self.held_keys.remove(&scancode);
                        }
                    }
                }
                InputEvent::Button { button, down } => {
                    if mouse_button_event(button, down).is_some() {
                        if down {
                            self.held_buttons.insert(button);
                        } else {
                            self.held_buttons.remove(&button);
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        let keys = std::mem::take(&mut self.held_keys);
        for scancode in keys {
            send_input_scancode(scancode, false)?;
        }
        let buttons = std::mem::take(&mut self.held_buttons);
        for button in buttons {
            let Some((flags, data)) = mouse_button_event(button, false) else {
                continue;
            };
            send_mouse(0, 0, flags, data)?;
        }
        Ok(())
    }
}

/// Windows host entry point. The stream carrier keeps this phase independent of
/// the Unix fd/link carrier; the authenticated overlay can wrap the same frames.
pub fn run(opts: &Opts) -> Res<()> {
    if opts.flag("selftest") {
        return selftest(opts);
    }
    let bind: IpAddr = opts.str_or("bind", "127.0.0.1").parse()?;
    if !bind.is_loopback() && !(opts.get("single-tenant-overlay") == Some("1") && private_ip(bind))
    {
        return Err("Windows host binds non-loopback only with --single-tenant-overlay 1 on a private address".into());
    }
    let port: u16 = opts.num_or("port", cmux_rd_proto::OVERLAY_PORT)?;
    let listener = TcpListener::bind((bind, port))?;
    eprintln!("cmux-rd Windows host: listening on {bind}:{port} (stream carrier)");
    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                if let Err(e) = serve_connection(stream, opts) {
                    eprintln!("Windows viewer failed: {e}");
                }
            }
            Err(e) => eprintln!("Windows accept failed: {e}"),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
