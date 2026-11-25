//! Tests of the wallpaper C ABI (src/wallpaper.rs).

use super::*;
use std::ffi::CStr;

fn text(p: *const c_char) -> Option<String> {
    // SAFETY: test pointers come from `owned` and are still alive.
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn static_bytes(
    f: unsafe extern "C" fn(usize, *mut usize) -> *const u8,
    i: usize,
) -> Option<String> {
    let mut len = 99;
    // SAFETY: `len` is writable.
    let p = unsafe { f(i, &mut len) };
    if p.is_null() {
        assert_eq!(len, 0);
        return None;
    }
    // SAFETY: the library returned `len` bytes at `p`.
    Some(String::from_utf8(unsafe { std::slice::from_raw_parts(p, len) }.to_vec()).unwrap())
}

#[test]
fn abi_version_is_five() {
    assert_eq!(cmux_wallpaper_abi_version(), 5);
}

#[test]
fn manifest_round_trips() {
    let smoke = cmux_wallpaper::smoke().unwrap().manifest_json;
    // SAFETY: valid bytes; the result is freed once.
    unsafe {
        let r = cmux_wallpaper_validate_manifest(smoke.as_ptr(), smoke.len());
        assert!((*r).ok);
        let json: serde_json::Value = serde_json::from_str(&text((*r).json).unwrap()).unwrap();
        assert_eq!(json["id"], "smoke");
        assert_eq!(json["variants"][0]["themes"], serde_json::json!(["dark", "light"]));
        cmux_wallpaper_manifest_result_free(r);

        let bad = br#"{"id": "Bad"}"#;
        let r = cmux_wallpaper_validate_manifest(bad.as_ptr(), bad.len());
        assert!(!(*r).ok);
        assert_eq!(text((*r).pointer).as_deref(), Some("/id"));
        assert!((*r).json.is_null());
        cmux_wallpaper_manifest_result_free(r);
        cmux_wallpaper_manifest_result_free(std::ptr::null_mut());
    }
}

#[test]
fn first_party_lists_every_shipped_wallpaper() {
    let n = cmux_wallpaper_first_party_count();
    for i in 0..n {
        let json = static_bytes(cmux_wallpaper_first_party_manifest_json, i).unwrap();
        assert!(!json.contains("\"smoke\""));
        assert!(static_bytes(cmux_wallpaper_first_party_source, i).is_some());
        let msl = static_bytes(cmux_wallpaper_first_party_msl, i).unwrap();
        assert!(
            msl.contains("vs_main") && msl.contains("fs_main") && msl.contains("[[buffer(0)]]")
        );
    }
    assert_eq!(static_bytes(cmux_wallpaper_first_party_manifest_json, n), None);
    assert_eq!(static_bytes(cmux_wallpaper_first_party_msl, n), None);
}

#[test]
fn schedule_round_trips() {
    let mut input = CmuxWallpaperScheduleInput {
        seconds_since_activity: 0.0,
        seconds_since_pointer: f64::INFINITY,
        seconds_since_agent_event: f64::INFINITY,
        settings_fps_cap: 30,
        manifest_fps: 60,
        gpu_strikes: 0,
        scale: 0.5,
        visible: true,
        coverage_resting: false,
        minimized: false,
        app_hidden: false,
        screens_asleep: false,
        session_inactive: false,
        low_power: false,
        thermal_serious: false,
        reduce_motion: false,
        animations_off: false,
        interactive: true,
        agents: false,
        has_frame: true,
        idle_after_s: 0.0,
    };
    // SAFETY: `input` is valid.
    let d = unsafe { cmux_wallpaper_schedule(&input) };
    assert!(d.run);
    assert_eq!((d.fps, d.scale, d.hold_reason), (30, 0.5, 0));
    input.low_power = true;
    input.has_frame = false;
    // SAFETY: `input` is valid.
    let d = unsafe { cmux_wallpaper_schedule(&input) };
    assert_eq!((d.run, d.hold_reason, d.draw_one), (false, 7, true));
    input.low_power = false;
    input.gpu_strikes = cmux_wallpaper_gpu_strikes(
        cmux_wallpaper_gpu_strikes(cmux_wallpaper_gpu_strikes(0, 5.0), 5.0),
        5.0,
    );
    input.scale = 0.25;
    // SAFETY: `input` is valid.
    let d = unsafe { cmux_wallpaper_schedule(&input) };
    assert_eq!((d.run, d.hold_reason), (false, 11));
    // SAFETY: null is allowed.
    assert_eq!(unsafe { cmux_wallpaper_schedule(std::ptr::null()) }.hold_reason, 1);
}

#[test]
fn reset_initializes_uninitialized_storage() {
    // The C contract: `CmuxWallpaperPointer p; cmux_wallpaper_pointer_reset(&p);` with no zeroing first.
    let mut slot = std::mem::MaybeUninit::<CmuxWallpaperPointer>::uninit();
    // SAFETY: `slot` is writable storage for one CmuxWallpaperPointer; reset only writes it.
    let p = unsafe {
        cmux_wallpaper_pointer_reset(slot.as_mut_ptr());
        slot.assume_init()
    };
    assert_eq!(p, CmuxWallpaperPointer::from(PointerState::default()));
    // SAFETY: null is allowed.
    unsafe { cmux_wallpaper_pointer_reset(std::ptr::null_mut()) };
}

#[test]
fn frame_and_pointer_round_trip() {
    let mut p = CmuxWallpaperPointer::default();
    // SAFETY: `p` is valid and writable; `out` has the Frame's floats.
    unsafe {
        cmux_wallpaper_pointer_reset(&mut p);
        cmux_wallpaper_pointer_update(&mut p, 10.0, 20.0, 1.0);
        cmux_wallpaper_pointer_update(&mut p, 20.0, 20.0, 1.0 + 1.0 / 60.0);
        cmux_wallpaper_pointer_advance(&mut p, 1.0 + 1.0 / 60.0);
        assert!(p.vx > 0.0 && p.inside && p.presence > 0.0);
        assert!(!cmux_wallpaper_pointer_settled(&p));
        assert!((cmux_wallpaper_pointer_since_moved(&p, 2.0 + 1.0 / 60.0) - 1.0).abs() < 1e-4);
        cmux_wallpaper_pointer_leave(&mut p);
        assert!(!p.inside);

        let input = CmuxWallpaperFrameInput {
            time: 3.0,
            pointer_x: p.x,
            presence: p.presence,
            accent: [0.1, 0.2, 0.3],
            params: [1.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            dark: true,
            ..Default::default()
        };
        let mut out = [7.0f32; CMUX_WALLPAPER_FRAME_FLOATS];
        assert!(cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()));
        assert_eq!(out[0], 3.0);
        assert_eq!(out[8], 20.0);
        assert_eq!(out[15], 1.0);
        assert_eq!(&out[24..28], &[0.1, 0.2, 0.3, 1.0]);
        assert_eq!(&out[28..30], &[1.0, 2.0]);
        assert!(!cmux_wallpaper_frame_pack(std::ptr::null(), out.as_mut_ptr()));
        assert!(!cmux_wallpaper_frame_pack(&input, std::ptr::null_mut()));
    }
    assert!((cmux_wallpaper_srgb_to_linear(1.0) - 1.0).abs() < 1e-6);
}

#[test]
fn activity_round_trips_into_the_frame_and_the_schedule() {
    let mut a = CmuxWallpaperActivity::default();
    // SAFETY: `a` is valid and writable; `out` has the Frame's floats; null is allowed.
    unsafe {
        cmux_wallpaper_activity_reset(&mut a);
        assert!(cmux_wallpaper_activity_settled(&a, 0.0));
        cmux_wallpaper_activity_event(&mut a, 5.0);
        cmux_wallpaper_activity_event(&mut a, 5.1);
        cmux_wallpaper_activity_advance(&mut a, 5.5);
        assert_eq!(a.count, 1);
        assert!(a.level > 0.0);
        assert!(!cmux_wallpaper_activity_settled(&a, 6.0));
        let since = cmux_wallpaper_activity_since_event(&a, 6.0);
        assert!((since - 1.0).abs() < 1e-6);
        assert_eq!(cmux_wallpaper_activity_since_event(std::ptr::null(), 6.0), 1.0e4);

        let input = CmuxWallpaperFrameInput {
            activity: a.level,
            since_agent_event: since,
            agent_events: f32::from(a.count),
            ..Default::default()
        };
        let mut out = [7.0f32; CMUX_WALLPAPER_FRAME_FLOATS];
        assert!(cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()));
        assert_eq!(&out[36..40], &[a.level, 1.0, 1.0, 0.0]);
        // No grade asked: the row is zeros (off).
        assert_eq!(&out[40..44], &[0.0; 4]);

        let mut s = CmuxWallpaperScheduleInput {
            seconds_since_activity: 100.0,
            seconds_since_pointer: f64::INFINITY,
            seconds_since_agent_event: f64::from(since),
            settings_fps_cap: 30,
            manifest_fps: 30,
            gpu_strikes: 0,
            scale: 1.0,
            visible: true,
            coverage_resting: false,
            minimized: false,
            app_hidden: false,
            screens_asleep: false,
            session_inactive: false,
            low_power: false,
            thermal_serious: false,
            reduce_motion: false,
            animations_off: false,
            interactive: true,
            agents: true,
            has_frame: true,
            idle_after_s: 0.0,
        };
        assert!(cmux_wallpaper_schedule(&s).run);
        s.agents = false;
        assert_eq!(cmux_wallpaper_schedule(&s).hold_reason, 12);
    }
}

#[test]
fn trail_round_trips_into_the_frame() {
    let mut trail = CmuxWallpaperTrail::default();
    // SAFETY: `trail` is valid and writable; `input.trail` has CMUX_WALLPAPER_TRAIL_FLOATS
    // floats; `out` has the Frame's floats; null is allowed.
    unsafe {
        cmux_wallpaper_trail_reset(&mut trail);
        cmux_wallpaper_trail_update(&mut trail, 10.0, 20.0, 1.0);
        cmux_wallpaper_trail_update(&mut trail, 30.0, 20.0, 1.01);
        // Within 50 ms of the committed point: the head moves.
        cmux_wallpaper_trail_update(&mut trail, 40.0, 24.0, 1.04);
        cmux_wallpaper_trail_update(&mut trail, f32::NAN, 0.0, 1.05);
        assert_eq!(trail.len, 2);
        assert_eq!((trail.x[0], trail.y[0]), (40.0, 24.0));
        cmux_wallpaper_trail_update(&mut trail, 50.0, 30.0, 1.06);
        assert_eq!(trail.len, 3);

        let mut input = CmuxWallpaperFrameInput::default();
        assert!(cmux_wallpaper_trail_rows(&trail, 1.26, 0.5, input.trail.as_mut_ptr()));
        assert_eq!(&input.trail[0..2], &[25.0, 15.0]);
        assert!((input.trail[2] - 0.2).abs() < 1e-5);
        assert_eq!(input.trail[3], 1.0);
        assert_eq!(&input.trail[8..10], &[5.0, 10.0]);
        assert_eq!(&input.trail[12..16], &[0.0; 4]);
        assert!(!cmux_wallpaper_trail_rows(std::ptr::null(), 1.0, 1.0, input.trail.as_mut_ptr()));
        assert!(!cmux_wallpaper_trail_rows(&trail, 1.0, 1.0, std::ptr::null_mut()));
        cmux_wallpaper_trail_update(std::ptr::null_mut(), 1.0, 1.0, 1.0);
        cmux_wallpaper_trail_reset(std::ptr::null_mut());

        let mut out = [7.0f32; CMUX_WALLPAPER_FRAME_FLOATS];
        assert!(cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()));
        assert_eq!(&out[44..46], &[25.0, 15.0]);
        assert_eq!(out[47], 1.0);
        assert!(out[56..].iter().all(|v| *v == 0.0));

        // A C caller's len past the ring reads as a full ring, never past it.
        trail.len = 1000;
        cmux_wallpaper_trail_update(&mut trail, 1.0, 2.0, 5.0);
        assert_eq!(trail.len as usize, CMUX_WALLPAPER_TRAIL_POINTS);
        cmux_wallpaper_trail_reset(&mut trail);
        assert_eq!(trail, CmuxWallpaperTrail::default());
    }
    assert_eq!(CMUX_WALLPAPER_FRAME_FLOATS, cmux_wallpaper::FRAME_FLOATS);
}

#[test]
fn the_manifest_idle_after_reaches_the_schedule() {
    let s = CmuxWallpaperScheduleInput {
        seconds_since_activity: 60.0,
        seconds_since_pointer: 2.5,
        seconds_since_agent_event: f64::INFINITY,
        settings_fps_cap: 30,
        manifest_fps: 30,
        gpu_strikes: 0,
        scale: 0.5,
        visible: true,
        coverage_resting: false,
        minimized: false,
        app_hidden: false,
        screens_asleep: false,
        session_inactive: false,
        low_power: false,
        thermal_serious: false,
        reduce_motion: false,
        animations_off: false,
        interactive: true,
        agents: false,
        has_frame: true,
        idle_after_s: 0.0,
    };
    // SAFETY: `s` is valid.
    unsafe {
        assert!(cmux_wallpaper_schedule(&s).run);
        let short = CmuxWallpaperScheduleInput { idle_after_s: 2.0, ..s };
        assert_eq!(cmux_wallpaper_schedule(&short).hold_reason, 12);
    }
}

#[test]
fn the_grade_reaches_the_frame_clamped() {
    let mut out = [7.0f32; CMUX_WALLPAPER_FRAME_FLOATS];
    for (grade, packed) in [(0.4, 0.4), (3.0, 1.0), (-1.0, 0.0), (f32::NAN, 0.0)] {
        let input = CmuxWallpaperFrameInput { grade, ..Default::default() };
        // SAFETY: `input` is valid; `out` has the Frame's floats.
        assert!(unsafe { cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()) });
        assert_eq!(&out[40..44], &[packed, 0.0, 0.0, 0.0], "{grade}");
    }
}
