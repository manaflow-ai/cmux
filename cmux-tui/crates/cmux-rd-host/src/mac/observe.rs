//! A protocol-independent observer of a viewer's on-screen counter. SCK's
//! display timestamp is the boundary, not decoder completion or physical light.

use super::capture::Capture;
use super::sys::{
    self, cf, cg, CFArrayRef, CFDictionaryRef, CFStringRef, CGEventRef, CGPoint, CGRect,
};
use crate::args::Opts;
use crate::clock::{now_ns, Rng};
use crate::fdwait::wait_readable;
use crate::observe::{self, Window};
use crate::Res;
use cmux_encode::framework;
use std::fs;
use std::ptr;
use std::time::Duration;

framework! {
    mod window_api = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
        static kCGWindowNumber: CFStringRef;
        static kCGWindowOwnerPID: CFStringRef;
        static kCGWindowBounds: CFStringRef;
        fn CGWindowListCopyWindowInfo(options: u32, relative_to: u32) -> CFArrayRef;
        fn CGEventPostToPid(pid: i32, event: CGEventRef);
        fn CGPreflightPostEventAccess() -> bool;
    }
}

fn pair(opts: &Opts, key: &str) -> Res<(usize, usize)> {
    let value = opts.get(key).ok_or_else(|| format!("--{key} X,Y is required (capture pixels)"))?;
    let (x, y) = value.split_once(',').ok_or("expected X,Y")?;
    Ok((x.parse()?, y.parse()?))
}

fn integer(dictionary: CFDictionaryRef, key: CFStringRef) -> Option<i64> {
    // SAFETY: the documented CGWindow dictionary keys contain CFNumbers.
    unsafe {
        let value = cf::CFDictionaryGetValue(dictionary, key);
        let mut out = 0i64;
        if value.is_null()
            || cf::CFNumberGetValue(value, sys::CF_NUMBER_SINT64, (&raw mut out).cast()) == 0
        {
            None
        } else {
            Some(out)
        }
    }
}

fn windows() -> Res<Vec<Window>> {
    // SAFETY: on-screen-only | exclude-desktop; the returned array is owned.
    let list = unsafe { window_api::CGWindowListCopyWindowInfo(1 | 16, 0) };
    if list.is_null() {
        return Err("window list unavailable (Screen Recording required)".into());
    }
    let retained = sys::Retained::retain(list);
    // SAFETY: balance the Copy reference; retained holds the array during reads.
    unsafe {
        cf::CFRelease(list);
    }
    let list = retained.as_ptr();
    // SAFETY: CGWindowListCopyWindowInfo returns an array of window dictionaries.
    unsafe {
        let count = cf::CFArrayGetCount(list);
        if !(0..=8192).contains(&count) {
            return Err("window list is unexpectedly large".into());
        }
        let mut out = Vec::new();
        for index in 0..count {
            let info = cf::CFArrayGetValueAtIndex(list, index);
            let Some(id) =
                integer(info, window_api::kCGWindowNumber()).and_then(|n| u32::try_from(n).ok())
            else {
                continue;
            };
            let Some(pid) =
                integer(info, window_api::kCGWindowOwnerPID()).and_then(|n| i32::try_from(n).ok())
            else {
                continue;
            };
            let bounds = cf::CFDictionaryGetValue(info, window_api::kCGWindowBounds());
            let mut rect = CGRect::default();
            if bounds.is_null()
                || cg::CGRectMakeWithDictionaryRepresentation(bounds, &raw mut rect) == 0
            {
                continue;
            }
            out.push(Window {
                id,
                pid,
                rect: [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height],
            });
        }
        Ok(out)
    }
}

fn guard_target(window: u32, pid: i32, points: &[(f64, f64)]) -> Res<()> {
    if !observe::unobscured(&windows()?, window, pid, points) {
        return Err("selected window/PID does not own every visible marker and input point; uncover the exact viewer connection".into());
    }
    Ok(())
}

fn target_geometry(window: u32, pid: i32, points: &[(f64, f64)]) -> Res<[f64; 4]> {
    let list = windows()?;
    if !observe::unobscured(&list, window, pid, points) {
        return Err("selected window/PID is not the unobscured visible viewer pane".into());
    }
    list.into_iter()
        .find(|candidate| candidate.id == window && candidate.pid == pid)
        .map(|candidate| candidate.rect)
        .ok_or_else(|| "selected viewer window disappeared".into())
}

struct Event(CGEventRef);
impl Drop for Event {
    fn drop(&mut self) {
        // SAFETY: each Event owns its Create reference.
        unsafe {
            cf::CFRelease(self.0.cast_const());
        }
    }
}

fn input(pid: i32, kind: &str, at: CGPoint) -> Res<u64> {
    let make = |down: bool| -> Res<Event> {
        // SAFETY: documented constructors; no global HID event is posted.
        let event = unsafe {
            if kind == "key" {
                cg::CGEventCreateKeyboardEvent(ptr::null_mut(), 49, down) // space
            } else {
                cg::CGEventCreateMouseEvent(ptr::null_mut(), if down { 1 } else { 2 }, at, 0)
            }
        };
        if event.is_null() {
            return Err("could not create input event".into());
        }
        let event = Event(event);
        // SAFETY: owned CGEvent, no modifiers and exactly one click.
        unsafe {
            cg::CGEventSetFlags(event.0, 0);
            if kind == "click" {
                cg::CGEventSetIntegerValueField(event.0, sys::FIELD_MOUSE_EVENT_CLICK_STATE, 1);
            }
        }
        Ok(event)
    };
    // Create both before posting either, so allocation failure cannot leave a key held.
    let down = make(true)?;
    let up = make(false)?;
    let sent = now_ns() / 1000;
    // SAFETY: events target only the explicitly validated viewer PID.
    unsafe {
        window_api::CGEventPostToPid(pid, down.0);
        window_api::CGEventPostToPid(pid, up.0);
    }
    Ok(sent)
}

fn counter(capture: &Capture, origin: (usize, usize), cell: usize) -> Option<(u16, u64)> {
    let (pixels, times) = capture.newest()?;
    let (shown, _) = times?;
    Some((pixels.marker(origin, cell)?, shown))
}

fn await_counter<T>(
    capture: &Capture,
    origin: (usize, usize),
    cell: usize,
    timeout_ms: u64,
    mut accept: impl FnMut(u16, u64) -> Res<Option<T>>,
) -> Res<T> {
    let deadline = now_ns() + timeout_ms * 1_000_000;
    loop {
        if let Some((value, shown)) = counter(capture, origin, cell) {
            if let Some(result) = accept(value, shown)? {
                return Ok(result);
            }
        }
        let left = deadline.saturating_sub(now_ns());
        if left == 0 {
            return Err("marker response timed out; no partial percentile is valid".into());
        }
        wait_readable(&[capture.fd()], Some(left))?;
        capture.drain(&mut Vec::new());
    }
}

fn await_presented_marker(
    capture: &Capture,
    timeout_ms: u64,
) -> Res<observe::PresentedMarkerSample> {
    let deadline = now_ns() + timeout_ms * 1_000_000;
    loop {
        let batch = capture.take_presented();
        if batch.queue_overflow {
            return Err("presented-marker callback queue overflowed; no FPS result is valid".into());
        }
        if let Some(sample) = batch
            .samples
            .into_iter()
            .rev()
            .find(|sample| sample.counter.is_some() && sample.display_us.is_some())
        {
            return Ok(sample);
        }
        let left = deadline.saturating_sub(now_ns());
        if left == 0 {
            return Err(
                "no valid source marker arrived; remote frame identity is unverified".into()
            );
        }
        wait_readable(&[capture.fd()], Some(left))?;
    }
}

fn wait_start_file(path: &str, timeout_ms: u64) -> Res<u64> {
    let deadline = now_ns() + timeout_ms * 1_000_000;
    loop {
        if fs::metadata(path).is_ok() {
            return Ok(now_ns() / 1000);
        }
        if now_ns() >= deadline {
            return Err(format!("start signal file did not appear: {path}").into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn run_passive(opts: &Opts) -> Res<()> {
    let pid = opts.num_or::<i32>("pid", 0)?;
    let window = opts.num_or::<u32>("window", 0)?;
    let cell = opts.num_or::<usize>("cell-size", 0)?;
    let origin = pair(opts, "marker-origin")?;
    let duration_s = opts.num_or::<u64>("duration-s", 10)?;
    let interval_ms = opts.num_or::<u64>("interval-ms", 1000)?;
    let start_timeout_ms = opts.num_or::<u64>("start-timeout-ms", 30_000)?;
    let start_file = opts.get("start-file").ok_or("passive mode requires --start-file PATH")?;
    if pid <= 0
        || window == 0
        || !(2..=1024).contains(&cell)
        || duration_s == 0
        || !(10..=60_000).contains(&interval_ms)
        || start_timeout_ms == 0
    {
        return Err("passive mode needs --pid >0, --window >0, --cell-size 2..1024, --duration-s >0, --interval-ms 10..60000".into());
    }
    sys::load()?;
    window_api::available()?;
    let display = opts.str_or("display", "main");
    let fps = super::capture::refresh_fps(&display);
    let capture = Capture::start_observing(
        &display,
        fps,
        None,
        super::capture::MarkerConfig { origin, cell },
    )?;
    let (width, height) = capture.size();
    let fits = origin.0.checked_add(cell * 20).is_some_and(|x| x <= width as usize)
        && origin.1.checked_add(cell).is_some_and(|y| y <= height as usize);
    if !fits {
        return Err("marker lies outside capture dimensions".into());
    }
    let bounds = capture.bounds();
    let point = |x: usize, y: usize| {
        (
            bounds.x + x as f64 * bounds.width / width as f64,
            bounds.y + y as f64 * bounds.height / height as f64,
        )
    };
    let points: Vec<_> =
        (0..20).map(|i| point(origin.0 + i * cell + cell / 2, origin.1 + cell / 2)).collect();
    let geometry = target_geometry(window, pid, &points)?;
    let baseline_sample = await_presented_marker(&capture, 3000)?;
    let baseline = baseline_sample.counter.ok_or("baseline marker is invalid")?;
    let before_start = capture.take_presented();
    if before_start.queue_overflow {
        return Err("presented-marker callback queue overflowed before start".into());
    }
    let callback_base = before_start.callback_count;
    let start_us = wait_start_file(start_file, start_timeout_ms)?;
    let mut series = observe::PresentedSeries::with_baseline(Some(baseline));
    let mut interval = observe::PresentedSeries::with_baseline(Some(baseline));
    let mut intervals = Vec::new();
    let duration_us = duration_s.saturating_mul(1_000_000);
    let interval_us = interval_ms.saturating_mul(1000);
    let mut next_boundary = start_us + interval_us;
    let end_us = start_us + duration_us;
    let mut callback_at_boundary = callback_base;
    while now_ns() / 1000 < end_us {
        let now_us = now_ns() / 1000;
        let wait_us = next_boundary.saturating_sub(now_us).min(end_us.saturating_sub(now_us));
        if wait_us > 0 {
            wait_readable(&[capture.fd()], Some(wait_us * 1000))?;
        }
        let batch = capture.take_presented();
        if batch.queue_overflow {
            return Err("presented-marker callback queue overflowed; no FPS result is valid".into());
        }
        for sample in batch.samples {
            if sample.arrived_us >= start_us {
                series.ingest(sample);
                interval.ingest(sample);
            }
        }
        let now_us = now_ns() / 1000;
        if now_us >= next_boundary || now_us >= end_us {
            let boundary = now_us.min(end_us);
            let interval_start = boundary.saturating_sub(interval_us);
            let elapsed_s = (boundary.saturating_sub(interval_start)) as f64 / 1_000_000.0;
            let presented_frames = interval.presented_frames;
            intervals.push(serde_json::json!({
                "start_us": interval_start,
                "end_us": boundary,
                "presented_frames": presented_frames,
                "presented_fps": if elapsed_s > 0.0 { presented_frames as f64 / elapsed_s } else { 0.0 },
                "first_counter": interval.first_counter,
                "last_counter": interval.last_counter,
                "first_display_us": interval.first_display_us,
                "last_display_us": interval.last_display_us,
                "first_arrived_us": interval.first_arrived_us,
                "last_arrived_us": interval.last_arrived_us,
                "gaps": interval.gaps,
                "repeated": interval.repeated,
                "invalid_samples": interval.invalid,
                "callback_count": batch.callback_count.saturating_sub(callback_at_boundary),
            }));
            callback_at_boundary = batch.callback_count;
            interval = observe::PresentedSeries::with_baseline(series.last_counter);
            next_boundary = boundary.saturating_add(interval_us);
        }
        if now_us >= end_us {
            break;
        }
    }
    let geometry_after = target_geometry(window, pid, &points)?;
    if geometry_after != geometry {
        return Err("selected viewer window geometry changed during passive observation".into());
    }
    let first_arrived = series.first_arrived_us.ok_or("no valid remote marker after start")?;
    println!(
        "{}",
        serde_json::json!({
            "schema": "cmux.presented-marker-series/2",
            "complete": true,
            "method": "callback-time source marker with ScreenCaptureKit display timestamp; excludes decoder completion, physical scanout, and pixel response",
            "marker_observed": true,
            "host_identity_verified": false,
            "requires_real_visible_window": true,
            "pid": pid,
            "window": window,
            "window_geometry_points": geometry,
            "display": display,
            "capture_pixels": [width, height],
            "capture_fps_requested": fps,
            "marker_origin_pixels": [origin.0, origin.1],
            "cell_size_pixels": cell,
            "start_signal_file": start_file,
            "start_us": start_us,
            "start_signal_observed_us": start_us,
            "first_changed_marker_ms": (first_arrived.saturating_sub(start_us) as f64) / 1000.0,
            "session_ttff_ms": serde_json::Value::Null,
            "first_marker_display_us": series.first_display_us,
            "duration_s": duration_s,
            "interval_ms": interval_ms,
            "presented_frames": series.presented_frames,
            "first_counter": series.first_counter,
            "last_counter": series.last_counter,
            "gaps": series.gaps,
            "repeated": series.repeated,
            "invalid_samples": series.invalid,
            "intervals": intervals,
        })
    );
    Ok(())
}

pub fn run(opts: &Opts) -> Res<()> {
    if opts.str_or("mode", "active") == "passive" {
        return run_passive(opts);
    }
    let pid = opts.num_or::<i32>("pid", 0)?;
    let window = opts.num_or::<u32>("window", 0)?;
    let samples = opts.num_or::<usize>("samples", 200)?;
    let timeout = opts.num_or::<u64>("timeout-ms", 1000)?;
    let cell = opts.num_or::<usize>("cell-size", 0)?;
    let origin = pair(opts, "marker-origin")?;
    let at = pair(opts, "at")?;
    let kind = opts.str_or("input", "key");
    let seed = opts.num_or::<u64>("seed", 1)?;
    if pid <= 0
        || window == 0
        || !(1..=10000).contains(&samples)
        || !(1..=10000).contains(&timeout)
        || !(2..=1024).contains(&cell)
        || !["key", "click"].contains(&kind.as_str())
    {
        return Err("need --pid >0, --window >0, --samples 1..10000, --timeout-ms 1..10000, --cell-size 2..1024, --input key|click".into());
    }
    sys::load()?;
    window_api::available()?;
    // SAFETY: preflight only; never prompt for or change permissions.
    if !unsafe { window_api::CGPreflightPostEventAccess() } {
        return Err("Accessibility input permission is missing".into());
    }
    let display = opts.str_or("display", "main");
    let fps = super::capture::refresh_fps(&display);
    let capture = Capture::start(&display, fps, None)?;
    let (width, height) = capture.size();
    let fits = origin.0.checked_add(cell * 20).is_some_and(|x| x <= width as usize)
        && origin.1.checked_add(cell).is_some_and(|y| y <= height as usize)
        && at.0 < width as usize
        && at.1 < height as usize;
    if !fits {
        return Err("marker or input point lies outside capture dimensions".into());
    }
    if at.0 >= origin.0 && at.0 < origin.0 + cell * 20 && at.1 >= origin.1 && at.1 < origin.1 + cell
    {
        return Err("input point must be outside the marker cells (use the gray pad)".into());
    }
    let bounds = capture.bounds();
    let point = |x: usize, y: usize| {
        (
            bounds.x + x as f64 * bounds.width / width as f64,
            bounds.y + y as f64 * bounds.height / height as f64,
        )
    };
    let mut points: Vec<_> =
        (0..20).map(|i| point(origin.0 + i * cell + cell / 2, origin.1 + cell / 2)).collect();
    let click = point(at.0, at.1);
    points.push(click);
    guard_target(window, pid, &points)?;
    let mut before = await_counter(&capture, origin, cell, 3000, |value, _| Ok(Some(value)))?;
    let mut rng = Rng::new(seed);
    let mut samples_us = Vec::with_capacity(samples);
    for _ in 0..samples {
        // Deliberate stimulus jitter breaks refresh-phase locking. This is the
        // standalone bench thread, not an app/main-thread synchronization wait.
        std::thread::sleep(Duration::from_millis(rng.range(25, 75)));
        guard_target(window, pid, &points)?;
        if counter(&capture, origin, cell).map(|x| x.0) != Some(before) {
            return Err("marker changed before input; the scene is not isolated".into());
        }
        let sent = input(pid, &kind, CGPoint::new(click.0, click.1))?;
        let latency = await_counter(&capture, origin, cell, timeout, |value, shown| {
            observe::response(before, sent, value, shown).map_err(Into::into)
        })?;
        guard_target(window, pid, &points)?;
        samples_us.push(latency);
        before = before.wrapping_add(1);
    }
    let (p50, p95) = observe::percentiles(&samples_us).ok_or("no samples")?;
    println!(
        "{}",
        serde_json::json!({
            "schema": "cmux.presented-marker/1", "complete": true,
            "method": "CGEventPostToPid to SCK viewer-display timestamp; excludes physical scanout",
            "pid": pid, "window": window, "input": kind, "n": samples,
            "p50_ms": p50, "p95_ms": p95, "samples_us": samples_us,
            "capture_pixels": [width, height], "capture_fps_requested": fps,
            "display_bounds_points": [bounds.x, bounds.y, bounds.width, bounds.height],
            "marker_origin_pixels": [origin.0, origin.1], "cell_size_pixels": cell,
            "input_point_pixels": [at.0, at.1], "stimulus_seed": seed,
            "timeout_ms": timeout
        })
    );
    Ok(())
}
