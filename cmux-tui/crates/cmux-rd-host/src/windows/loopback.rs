//! Bounded Windows capture -> production stream host -> decoder -> visible viewer proof.
//! No overlay credentials or synthetic encoded frames: the source is the current desktop.

use super::*;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, Feedback, HEADER_LEN};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;
use serde_json::json;
use windows_sys::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsW, EnumDisplaySettingsW, GdiFlush, GetPixel, StretchDIBits,
    CDS_FULLSCREEN, CDS_TEST, DEVMODEW, DISP_CHANGE_BADMODE, DISP_CHANGE_SUCCESSFUL, DM_PELSHEIGHT,
    DM_PELSWIDTH, ENUM_CURRENT_SETTINGS,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, DispatchMessageW, PeekMessageW, TranslateMessage, MSG,
    PM_REMOVE, WS_EX_TOPMOST, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
};

struct DesktopMode(DEVMODEW);

impl DesktopMode {
    fn set(width: u32, height: u32) -> Res<Option<Self>> {
        // SAFETY: DEVMODEW is initialized with the required size and filled by Windows.
        let mut original: DEVMODEW = unsafe { zeroed() };
        original.dmSize = size_of::<DEVMODEW>() as u16;
        if unsafe { EnumDisplaySettingsW(std::ptr::null(), ENUM_CURRENT_SETTINGS, &mut original) }
            == 0
        {
            return Err(format!(
                "Windows display mode read failed: {}",
                io::Error::last_os_error()
            )
            .into());
        }
        let restore = Self(original);
        let mut requested = original;
        requested.dmPelsWidth = width;
        requested.dmPelsHeight = height;
        requested.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        // Test before changing the runner's temporary desktop; never persist a registry setting.
        let tested = unsafe { ChangeDisplaySettingsW(&requested, CDS_TEST) };
        if optional_4k_mode_unavailable(width, height, tested) {
            return Ok(None);
        }
        if tested != DISP_CHANGE_SUCCESSFUL {
            return Err(format!("Windows display cannot provide {width}x{height}: ChangeDisplaySettingsW(CDS_TEST)={tested}; current={}x{}", original.dmPelsWidth, original.dmPelsHeight).into());
        }
        let changed = unsafe { ChangeDisplaySettingsW(&requested, CDS_FULLSCREEN) };
        if changed != DISP_CHANGE_SUCCESSFUL {
            return Err(format!(
                "Windows display mode {width}x{height} failed: ChangeDisplaySettingsW={changed}"
            )
            .into());
        }
        let capture = GdiCapture::new(None)?;
        if capture.size() != (width, height) {
            return Err(format!(
                "Windows capture dimensions {:?} do not match requested {width}x{height}",
                capture.size()
            )
            .into());
        }
        Ok(Some(restore))
    }
}

impl Drop for DesktopMode {
    fn drop(&mut self) {
        // SAFETY: restore only the mode this benchmark changed on its own ephemeral runner.
        unsafe { ChangeDisplaySettingsW(&self.0, 0) };
    }
}

const PREVIEW_WIDTH: usize = 320;
const PREVIEW_HEIGHT: usize = 180;

// Sample the whole preview explicitly. GDI's default shrinking mode combines
// source pixels, so a scaled destination pixel is not an exact source oracle.
fn preview_bgr(rgb: &[u8], width: usize, height: usize, preview: &mut [u8]) -> Res<()> {
    if width == 0
        || height == 0
        || width.checked_mul(height).and_then(|n| n.checked_mul(3)) != Some(rgb.len())
        || preview.len() != PREVIEW_WIDTH * PREVIEW_HEIGHT * 3
    {
        return Err("invalid decoded frame or preview dimensions".into());
    }
    for y in 0..PREVIEW_HEIGHT {
        for x in 0..PREVIEW_WIDTH {
            let source = ((y * height / PREVIEW_HEIGHT) * width + x * width / PREVIEW_WIDTH) * 3;
            let dest = (y * PREVIEW_WIDTH + x) * 3;
            preview[dest..dest + 3].copy_from_slice(&[
                rgb[source + 2],
                rgb[source + 1],
                rgb[source],
            ]);
        }
    }
    Ok(())
}

struct ViewerWindow(HWND, Vec<u8>);

impl ViewerWindow {
    fn new(width: u32, height: u32) -> Res<Self> {
        let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
        let title: Vec<u16> = "cmux-rd loopback viewer\0".encode_utf16().collect();
        // SAFETY: built-in window class, owned HWND, valid nul-terminated strings.
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOPMOST,
                class.as_ptr(),
                title.as_ptr(),
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                width as i32 - 390,
                height as i32 - 280,
                360,
                230,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null(),
            )
        };
        if hwnd.is_null() {
            return Err(format!("Windows viewer window: {}", io::Error::last_os_error()).into());
        }
        Ok(Self(hwnd, vec![0; PREVIEW_WIDTH * PREVIEW_HEIGHT * 3]))
    }

    fn present(&mut self, rgb: &[u8], width: usize, height: usize) -> Res<u32> {
        preview_bgr(rgb, width, height, &mut self.1)?;
        let center = (height / 2 * width + width / 2) * 3;
        let pixel = rgb.get(center..center + 3).ok_or("decoded center pixel missing")?;
        let expected =
            u32::from(pixel[0]) | (u32::from(pixel[1]) << 8) | (u32::from(pixel[2]) << 16);
        let mut info: BITMAPINFO = unsafe { zeroed() };
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: PREVIEW_WIDTH as i32,
            biHeight: -(PREVIEW_HEIGHT as i32),
            biPlanes: 1,
            biBitCount: 24,
            biCompression: BI_RGB,
            ..unsafe { zeroed() }
        };
        // Pump the window's messages before drawing so a pending paint cannot erase the proof.
        let mut msg: MSG = unsafe { zeroed() };
        unsafe {
            while PeekMessageW(&mut msg, self.0, 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let dc = unsafe { GetDC(self.0) };
        if dc.is_null() {
            return Err("Windows viewer GetDC failed".into());
        }
        // SAFETY: initialized, row-aligned 24-bit preview, drawn 1:1 with no GDI resampling.
        let rows = unsafe {
            StretchDIBits(
                dc,
                0,
                0,
                320,
                180,
                0,
                0,
                PREVIEW_WIDTH as i32,
                PREVIEW_HEIGHT as i32,
                self.1.as_ptr().cast(),
                &info,
                DIB_RGB_COLORS,
                SRCCOPY,
            )
        };
        unsafe { GdiFlush() };
        let shown = unsafe { GetPixel(dc, 160, 90) };
        unsafe { ReleaseDC(self.0, dc) };
        if rows <= 0 || shown != expected {
            return Err(format!("Windows viewer readback failed: rows={rows}, expected={expected:#x}, shown={shown:#x}").into());
        }
        Ok(shown)
    }
}

impl Drop for ViewerWindow {
    fn drop(&mut self) {
        unsafe { DestroyWindow(self.0) };
    }
}

fn distribution(samples: &[f64]) -> serde_json::Value {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = |p: usize| sorted.get((sorted.len() * p).div_ceil(100).saturating_sub(1)).copied();
    json!({"samples": sorted.len(), "p50": rank(50), "p95": rank(95)})
}

pub(super) fn run(opts: &Opts) -> Res<()> {
    let width = opts.num_or("width", 1920u32)?;
    let height = opts.num_or("height", 1080u32)?;
    let duration = opts.num_or("duration-s", 10u64)?;
    if !matches!((width, height), (1920, 1080) | (3840, 2160)) || !(2..=30).contains(&duration) {
        return Err("loopback requires 1920x1080 or 3840x2160 and --duration-s 2..30".into());
    }
    let Some(_mode) = DesktopMode::set(width, height)? else {
        println!(
            "{}",
            json!({
                "platform": "windows", "size": "3840x2160", "status": "not_measured",
                "reason": "no_display_mode", "message": "4K: not measured, no display mode",
                "first_frame_ms": null, "fps": null, "encode_ms": null,
                "loopback_ok": false
            })
        );
        return Ok(());
    };
    let mut viewer = ViewerWindow::new(width, height)?;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
    let address = listener.local_addr()?;
    let args = vec![
        "--loopback".into(),
        "1".into(),
        "--duration-s".into(),
        duration.to_string(),
        "--max-fps".into(),
        "60".into(),
        "--codec".into(),
        opts.str_or("codec", "openh264"),
        "--capture".into(),
        opts.str_or("capture", "auto"),
    ];
    let host_opts = Opts::parse(&args)?;
    // Connect before spawning, so accept cannot wait forever if viewer setup fails.
    let connected = Instant::now();
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(3))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    stream.set_nodelay(true)?;
    // The lexical scope owns and joins the host, including viewer error paths.
    std::thread::scope(|scope| {
        let host = scope.spawn(move || -> Result<HostMetrics, String> {
            let (connection, _) = listener.accept().map_err(|e| e.to_string())?;
            connection.set_read_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
            connection
                .set_write_timeout(Some(Duration::from_secs(5)))
                .map_err(|e| e.to_string())?;
            serve_connection(connection, &host_opts).map_err(|e| e.to_string())
        });
        let result = measure(&mut stream, &mut viewer, connected, width, height, duration);
        // Closing our socket releases the host on every error; its own deadline is a second bound.
        drop(stream);
        let host_result = host.join().map_err(|_| "Windows loopback host thread panicked");
        // A reset caused by cleanup must not hide the original decoder/readback failure.
        let mut report = result?;
        let metrics = host_result??;
        report["capture"] = metrics.capture_details["backend"].clone();
        report["capture_details"] = metrics.capture_details;
        report["capture_ms"] = distribution(&metrics.capture_ms);
        report["convert_ms"] = distribution(&metrics.convert_ms);
        report["encode_ms"] = distribution(&metrics.encode_ms);
        report["capture_encode_ok"] = json!(!metrics.encode_ms.is_empty());
        println!("{}", serde_json::to_string(&report)?);
        Ok(())
    })
}

fn measure(
    stream: &mut TcpStream,
    viewer: &mut ViewerWindow,
    connected: Instant,
    width: u32,
    height: u32,
    duration: u64,
) -> Res<serde_json::Value> {
    write_control(
        stream,
        &Control::Hello {
            user: "loopback-bench".into(),
            install: "loopback-bench".into(),
            class: "user".into(),
            interactive: true,
            udp_port: None,
            max_datagram: MAX_DATAGRAM_DEFAULT,
            token: None,
            service: cmux_rd_proto::SERVICE_DESKTOP.into(),
            caps: Vec::new(),
        },
    )?;
    write_control(stream, &Control::Start { key: "windows-loopback".into(), mode: "view".into() })?;
    let mut decoder = Decoder::new()?;
    let mut reassembler = Reassembler::new(500_000);
    let mut first = None;
    let mut steady_start = None;
    let mut steady_frames = 0u64;
    let mut frames = 0u64;
    let mut bytes = 0usize;
    let mut arrivals = Vec::new();
    let mut decode_ms = Vec::new();
    let mut present_ms = Vec::new();
    let mut colors = BTreeSet::new();
    let mut rgb = vec![0; width as usize * height as usize * 3];
    let deadline = connected + Duration::from_secs(duration + 10);
    let mut welcomed = false;
    let mut stop_sent = false;
    let mut last_present = connected;
    while Instant::now() < deadline {
        let (kind, payload) = read_blocking_frame(stream).map_err(|error| {
            format!("Windows loopback receive: welcomed={welcomed}, presented_frames={frames}, encoded_bytes={bytes}, first_frame_ms={:?}: {error}",
                first.map(|at: Instant| at.duration_since(connected).as_secs_f64() * 1000.0))
        })?;
        if kind == FRAME_CONTROL {
            match serde_json::from_slice::<Control>(&payload)? {
                Control::Welcome { width: w, height: h, .. } => {
                    if (w, h) != (width, height) {
                        return Err(format!("host sent {w}x{h}, requested {width}x{height}").into());
                    }
                    welcomed = true;
                }
                Control::Ended { .. } if stop_sent => break,
                Control::Refused { reason } => return Err(reason.into()),
                _ => {}
            }
            continue;
        }
        if kind != FRAME_DATAGRAM {
            continue;
        }
        let (header, body) =
            DatagramHeader::decode(&payload).map_err(|e| format!("viewer datagram: {e:?}"))?;
        if !matches!(header.kind, DatagramKind::Video | DatagramKind::Fec) {
            continue;
        }
        bytes += payload.len();
        arrivals.push(Arrival {
            transport_seq: header.transport_seq,
            arrival_us: (now_ns() / 1000) as u32,
        });
        let complete = reassembler.push(&header, body, now_ns() / 1000);
        let released = !complete.is_empty();
        for frame in complete {
            let decode_started = Instant::now();
            if let Some(yuv) = decoder.decode(&frame.body.access_unit)? {
                sample(&mut decode_ms, decode_started);
                if yuv.dimensions() != (width as usize, height as usize) {
                    return Err("decoded dimensions differ from requested capture".into());
                }
                let present_started = Instant::now();
                yuv.write_rgb8(&mut rgb);
                colors.insert(viewer.present(&mut rgb, width as usize, height as usize)?);
                sample(&mut present_ms, present_started);
                last_present = Instant::now();
                let first_present = *first.get_or_insert(last_present);
                frames += 1;
                if last_present.duration_since(first_present) >= Duration::from_secs(1) {
                    if steady_start.is_some() {
                        steady_frames += 1;
                    }
                    steady_start.get_or_insert(last_present);
                }
                if last_present.duration_since(first_present) >= Duration::from_secs(duration + 1)
                    && !stop_sent
                {
                    write_control(stream, &Control::Stop)?;
                    stop_sent = true;
                }
            }
        }
        if !stop_sent && (released || arrivals.len() >= cmux_rd_proto::MAX_ARRIVALS) {
            let fb = Feedback {
                acked_frame: reassembler.last_released(),
                arrivals: std::mem::take(&mut arrivals),
                need_recovery: reassembler.need_recovery(),
                ..Feedback::default()
            };
            let mut packet = Vec::with_capacity(HEADER_LEN + 64);
            DatagramHeader {
                flags: 0,
                kind: DatagramKind::Feedback,
                stream: 0,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode_into(&mut packet);
            packet.extend_from_slice(&fb.encode());
            write_frame(stream, FRAME_DATAGRAM, &packet)?;
        }
    }
    let first = first.ok_or("loopback viewer never presented a decoded frame")?;
    let steady = steady_start.ok_or("loopback viewer produced no steady sample")?;
    if !welcomed || !stop_sent || steady_frames < 2 || colors.len() < 2 {
        return Err(format!("incomplete loopback proof: welcomed={welcomed}, stopped={stop_sent}, steady_frames={steady_frames}, distinct_presented_colors={}", colors.len()).into());
    }
    Ok(json!({"platform":"windows", "carrier":"cmux.rd/1 stream over TCP loopback",
        "capture":"gdi-readback", "viewer":"OpenH264 -> visible GDI window -> GetPixel readback",
        "size":format!("{width}x{height}"), "first_frame_ms":first.duration_since(connected).as_secs_f64()*1000.0,
        "fps":steady_frames as f64 / last_present.duration_since(steady).as_secs_f64(),
        "steady_frames":steady_frames, "frames":frames, "encoded_bytes":bytes,
        "distinct_presented_colors":colors.len(), "decode_ms":distribution(&decode_ms),
        "present_ms":distribution(&present_ms), "loopback_ok":true}))
}

// Only an unsupported optional resolution is unmeasured. A failure to change a
// supported mode, a failed capture, or any missing 1080p mode remains an error.
fn optional_4k_mode_unavailable(width: u32, height: u32, result: i32) -> bool {
    (width, height) == (3840, 2160) && result == DISP_CHANGE_BADMODE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewer_reads_exact_sample_surrounded_by_different_pixels() {
        let (width, height) = (640, 360);
        let mut rgb = vec![0; width * height * 3];
        let center = (height / 2 * width + width / 2) * 3;
        rgb[center..center + 3].copy_from_slice(&[0xc3, 0x51, 0x33]);
        let mut viewer = ViewerWindow::new(640, 480).unwrap();
        assert_eq!(viewer.present(&rgb, width, height).unwrap(), 0x3351c3);
    }

    #[test]
    fn preview_preserves_exact_samples_and_channel_order() {
        let (width, height) = (640, 360);
        let mut rgb = vec![0; width * height * 3];
        for y in 0..height {
            for x in 0..width {
                let i = (y * width + x) * 3;
                rgb[i..i + 3].copy_from_slice(&[x as u8, y as u8, (x ^ y) as u8]);
            }
        }
        let mut preview = vec![0; PREVIEW_WIDTH * PREVIEW_HEIGHT * 3];
        preview_bgr(&rgb, width, height, &mut preview).unwrap();
        for (x, y) in [(0, 0), (1, 1), (160, 90), (319, 179)] {
            let i = (y * PREVIEW_WIDTH + x) * 3;
            assert_eq!(&preview[i..i + 3], &[(2 * x ^ 2 * y) as u8, (2 * y) as u8, (2 * x) as u8]);
        }
        assert!(preview_bgr(&rgb[..3], width, height, &mut preview).is_err());
    }

    #[test]
    fn optional_4k_mode_does_not_hide_product_or_required_mode_failures() {
        assert!(optional_4k_mode_unavailable(3840, 2160, DISP_CHANGE_BADMODE));
        assert!(!optional_4k_mode_unavailable(1920, 1080, DISP_CHANGE_BADMODE));
        assert!(!optional_4k_mode_unavailable(3840, 2160, DISP_CHANGE_SUCCESSFUL));
        assert!(!optional_4k_mode_unavailable(3840, 2160, -1));
    }
}
