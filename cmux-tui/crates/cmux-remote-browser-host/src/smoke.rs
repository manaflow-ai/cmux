//! `--smoke OUT_DIR`: the host's own proof on a GUI Mac (remote-tab-r2.md
//! section 2), before the rd source and the viewer exist. It opens a local
//! test page in a remote presentation tab, captures it, and writes:
//! - `frames.jsonl` (counter, size, update rect, phase) and the first frames
//!   as `frame-NNN.png` (straight from the IOSurface, damage not drawn);
//! - `result.json`: frames while idle (must be 0), the process tree's CPU
//!   seconds over the idle window, and key-to-capture latencies (a key sent
//!   with cmux_rp_send_key to the first frame whose update rect covers the
//!   box the key toggles; host side only: no encode, network or decode).
//! macOS only.

use std::ffi::{CString, c_char, c_int, c_void};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Instant;

use crate::ffi::{
    RbCallbacks, RbFrame, rb_shim_capture, rb_shim_frame_release, rb_shim_open_tab,
    rb_shim_post_delayed, rb_shim_quit, rb_shim_run, rb_shim_send_key, rb_shim_set_screen,
};

/// A static page; each keydown toggles a 16x16 CSS px box at (100, 100).
const PAGE: &str = "data:text/html,<html><body style='margin:0;background:%231f7a3a'>\
<div id=b style='position:absolute;left:100px;top:100px;width:16px;height:16px;\
background:red'></div><script>let n=0;addEventListener('keydown',()=>{n++;\
document.getElementById('b').style.background=n%252?'blue':'red';});\
document.title='ready';</script></body></html>";
const KEYS: usize = 20;
const KEY_SPACING_MS: i64 = 150;
const IDLE_WINDOW_MS: i64 = 3000;
const PNG_FRAMES: usize = 4;
const WATCHDOG_MS: i64 = 30_000;

#[derive(Default)]
struct Smoke {
    out: PathBuf,
    browser: Option<i32>,
    capture_started: bool,
    finished: bool,
    frames: usize,
    jsonl: Option<std::fs::File>,
    idle_start_frames: usize,
    idle_start_cpu: f64,
    idle_frames: Option<usize>,
    idle_cpu_s: Option<f64>,
    key_sent_at: Option<Instant>,
    keys_sent: usize,
    latencies_ms: Vec<f64>,
    error: Option<String>,
}

static SMOKE: Mutex<Option<Smoke>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut Smoke) -> R) -> Option<R> {
    let mut guard = SMOKE.lock().ok()?;
    guard.as_mut().map(f)
}

unsafe extern "C" {
    fn IOSurfaceLock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceUnlock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceGetBaseAddress(surface: *mut c_void) -> *mut c_void;
    fn IOSurfaceGetBytesPerRow(surface: *mut c_void) -> usize;
}
const LOCK_READ_ONLY: u32 = 1;

/// CPU seconds of this process and its helper processes (ps, read only).
fn tree_cpu_seconds() -> f64 {
    let me = std::process::id();
    let Ok(out) =
        std::process::Command::new("/bin/ps").args(["-A", "-o", "pid=,ppid=,time="]).output()
    else {
        return f64::NAN;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let rows: Vec<(u32, u32, f64)> = text
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid = it.next()?.parse().ok()?;
            let ppid = it.next()?.parse().ok()?;
            let time = it.next()?;
            // [[dd-]hh:]mm:ss.ss
            let secs = time
                .split(|c| c == ':' || c == '-')
                .filter_map(|p| p.parse::<f64>().ok())
                .rev()
                .zip([1.0, 60.0, 3600.0, 86400.0])
                .map(|(v, m)| v * m)
                .sum();
            Some((pid, ppid, secs))
        })
        .collect();
    let mut tree = vec![me];
    let mut grew = true;
    while grew {
        grew = false;
        for (pid, ppid, _) in &rows {
            if tree.contains(ppid) && !tree.contains(pid) {
                tree.push(*pid);
                grew = true;
            }
        }
    }
    rows.iter().filter(|(pid, _, _)| tree.contains(pid)).map(|(_, _, s)| s).sum()
}

fn write_png(
    path: &PathBuf,
    base: *const u8,
    stride: usize,
    w: usize,
    h: usize,
) -> Result<(), String> {
    let mut rgba = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        // SAFETY: the surface is locked and holds h rows of `stride` bytes.
        let row = unsafe { std::slice::from_raw_parts(base.add(y * stride), w * 4) };
        for px in row.chunks_exact(4) {
            rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
        }
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().and_then(|mut wr| wr.write_image_data(&rgba)).map_err(|e| e.to_string())
}

unsafe extern "C" fn on_ready(_: *mut c_void) {
    let url = CString::new(PAGE).unwrap_or_default();
    // SAFETY: plain values; on the UI thread.
    unsafe {
        rb_shim_set_screen(1200, 800, 2.0);
        rb_shim_open_tab(1, url.as_ptr(), 1200, 800);
        rb_shim_post_delayed(watchdog, std::ptr::null_mut(), WATCHDOG_MS);
    }
}

/// Ends a smoke that stalled (no title, no capture) with what it has.
unsafe extern "C" fn watchdog(_: *mut c_void) {
    if with(|s| s.finished).unwrap_or(true) {
        return;
    }
    with(|s| {
        s.error.get_or_insert_with(|| format!("watchdog: not finished after {WATCHDOG_MS} ms"));
    });
    // SAFETY: on the UI thread.
    unsafe { finish(std::ptr::null_mut()) }
}

unsafe extern "C" fn on_tab_created(_: *mut c_void, _request: c_int, browser: c_int) {
    with(|s| s.browser = Some(browser));
}

/// The page sets its title to `ready` when its script has run; the capture
/// starts then (as in the fork's embedder test), when the tab has its view.
unsafe extern "C" fn on_title(_: *mut c_void, browser: c_int, title: *const c_char) {
    // SAFETY: the shim passes a NUL-terminated string for the call.
    let title = unsafe { std::ffi::CStr::from_ptr(title) }.to_string_lossy();
    if title != "ready" || with(|s| s.capture_started).unwrap_or(true) {
        return;
    }
    // SAFETY: plain values; on the UI thread.
    let started = unsafe { rb_shim_capture(browser, 1, 0) } == 1;
    with(|s| {
        s.capture_started = true;
        if !started {
            s.error = Some("rb_shim_capture returned 0".to_string());
        }
    });
    // Let the first frames land and the page settle, then measure idle.
    // SAFETY: plain values.
    unsafe { rb_shim_post_delayed(start_idle, std::ptr::null_mut(), 2000) }
}

unsafe extern "C" fn on_frame(_: *mut c_void, _browser: c_int, f: *const RbFrame) {
    // SAFETY: the shim passes a valid frame for the call's duration.
    let f = unsafe { &*f };
    let now = Instant::now();
    with(|s| {
        let index = s.frames;
        s.frames += 1;
        let covers_box = f.has_update_rect != 0
            && f.update_x <= 200
            && f.update_y <= 200
            && f.update_x + f.update_width >= 232
            && f.update_y + f.update_height >= 232;
        if covers_box && let Some(sent) = s.key_sent_at.take() {
            s.latencies_ms.push(now.duration_since(sent).as_secs_f64() * 1000.0);
        }
        if let Some(file) = s.jsonl.as_mut() {
            let _ = writeln!(
                file,
                "{{\"index\":{index},\"counter\":{},\"coded\":[{},{}],\"update\":[{},{},{},{}],\"gpu\":{}}}",
                f.capture_counter,
                f.coded_width,
                f.coded_height,
                f.update_x,
                f.update_y,
                f.update_width,
                f.update_height,
                !f.io_surface.is_null()
            );
        }
        if index < PNG_FRAMES && !f.io_surface.is_null() {
            // SAFETY: the surface stays valid until the lease is released below.
            unsafe {
                IOSurfaceLock(f.io_surface, LOCK_READ_ONLY, std::ptr::null_mut());
                let base = IOSurfaceGetBaseAddress(f.io_surface) as *const u8;
                let stride = IOSurfaceGetBytesPerRow(f.io_surface);
                let path = s.out.join(format!("frame-{index:03}.png"));
                if let Err(e) = write_png(
                    &path,
                    base,
                    stride,
                    usize::try_from(f.coded_width).unwrap_or(0),
                    usize::try_from(f.coded_height).unwrap_or(0),
                ) {
                    s.error = Some(format!("png: {e}"));
                }
                IOSurfaceUnlock(f.io_surface, LOCK_READ_ONLY, std::ptr::null_mut());
            }
        }
    });
    // SAFETY: the lease came from this callback.
    unsafe { rb_shim_frame_release(f.lease) }
}

unsafe extern "C" fn start_idle(_: *mut c_void) {
    let cpu = tree_cpu_seconds();
    with(|s| {
        s.idle_start_frames = s.frames;
        s.idle_start_cpu = cpu;
    });
    // SAFETY: plain values.
    unsafe { rb_shim_post_delayed(end_idle, std::ptr::null_mut(), IDLE_WINDOW_MS) }
}

unsafe extern "C" fn end_idle(_: *mut c_void) {
    let cpu = tree_cpu_seconds();
    with(|s| {
        s.idle_frames = Some(s.frames - s.idle_start_frames);
        s.idle_cpu_s = Some(cpu - s.idle_start_cpu);
    });
    // SAFETY: plain values.
    unsafe { rb_shim_post_delayed(send_key, std::ptr::null_mut(), 0) }
}

unsafe extern "C" fn send_key(_: *mut c_void) {
    let Some((browser, sent)) = with(|s| (s.browser, s.keys_sent)) else { return };
    let Some(browser) = browser else { return };
    if sent >= KEYS {
        // SAFETY: plain values.
        unsafe { rb_shim_post_delayed(finish, std::ptr::null_mut(), 500) };
        return;
    }
    let code = CString::new("KeyA").unwrap_or_default();
    let key = CString::new("a").unwrap_or_default();
    let empty = CString::default();
    with(|s| {
        s.key_sent_at = Some(Instant::now());
        s.keys_sent += 1;
    });
    // SAFETY: the strings outlive the calls; no edit commands.
    unsafe {
        let none: *const *const c_char = std::ptr::null();
        rb_shim_send_key(
            browser,
            1,
            code.as_ptr(),
            key.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
            0,
            none,
            none,
            0,
        );
        rb_shim_send_key(
            browser,
            0,
            code.as_ptr(),
            key.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
            0,
            none,
            none,
            0,
        );
        rb_shim_post_delayed(send_key, std::ptr::null_mut(), KEY_SPACING_MS);
    }
}

/// A JSON number with one decimal, or `null` (JSON has no NaN).
fn num(v: Option<f64>) -> String {
    v.filter(|v| v.is_finite()).map_or("null".to_string(), |v| format!("{v:.1}"))
}

fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    let i = ((sorted.len().checked_sub(1)?) as f64 * p).round() as usize;
    sorted.get(i).copied()
}

unsafe extern "C" fn finish(_: *mut c_void) {
    if with(|s| std::mem::replace(&mut s.finished, true)).unwrap_or(true) {
        return;
    }
    with(|s| {
        let mut l = s.latencies_ms.clone();
        l.sort_by(f64::total_cmp);
        let result = format!(
            "{{\"frames\":{},\"idle_window_ms\":{IDLE_WINDOW_MS},\"idle_frames\":{},\"idle_cpu_seconds\":{},\
\"keys\":{},\"key_to_capture_ms\":{{\"count\":{},\"p50\":{},\"p95\":{},\"max\":{}}},\"error\":{}}}\n",
            s.frames,
            s.idle_frames.map_or("null".to_string(), |v| v.to_string()),
            s.idle_cpu_s
                .filter(|v| v.is_finite())
                .map_or("null".to_string(), |v| format!("{v:.3}")),
            s.keys_sent,
            l.len(),
            num(percentile(&l, 0.5)),
            num(percentile(&l, 0.95)),
            num(l.last().copied()),
            s.error.as_ref().map_or("null".to_string(), |e| format!("{e:?}")),
        );
        let _ = std::fs::write(s.out.join("result.json"), &result);
        print!("{result}");
    });
    // SAFETY: on the UI thread.
    unsafe { rb_shim_quit() }
}

/// Runs the smoke into `out` and returns the process exit code.
pub fn run(argv: &mut [*mut c_char], out: PathBuf) -> i32 {
    let _ = std::fs::create_dir_all(&out);
    let jsonl = std::fs::File::create(out.join("frames.jsonl")).ok();
    if let Ok(mut guard) = SMOKE.lock() {
        *guard = Some(Smoke { out: out.clone(), jsonl, ..Smoke::default() });
    }
    let cache = CString::new(out.join("cache").to_string_lossy().as_bytes()).unwrap_or_default();
    let callbacks = RbCallbacks {
        context: std::ptr::null_mut(),
        on_ready: Some(on_ready),
        on_tab_created: Some(on_tab_created),
        on_tab_closed: None,
        on_title: Some(on_title),
        on_url: None,
        on_frame: Some(on_frame),
        on_key_unhandled: None,
        on_context_menu: None,
        on_popup_menu: None,
        on_needs_begin_frames: None,
    };
    // SAFETY: argv, the strings and the callbacks outlive the call.
    unsafe {
        rb_shim_run(
            c_int::try_from(argv.len()).unwrap_or(0),
            argv.as_mut_ptr(),
            cache.as_ptr(),
            0,
            &callbacks,
        )
    }
}
