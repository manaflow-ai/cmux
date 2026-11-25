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
fn abi_version_is_six() {
    assert_eq!(cmux_wallpaper_abi_version(), 6);
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
        at_rest: false,
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
            at_rest: false,
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
        at_rest: false,
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

const SCENE_MANIFEST: &str = r#"{"id": "scene-test", "name": "Scene test",
    "description": "A test scene.", "scene": "scene.json", "fps": 30, "scale": 1,
    "interactive": true, "params": [], "still": {"time": 0, "pointer": [0.5, 0.5]},
    "variants": [{"name": "Plain"}]}"#;

/// Makes a scene from `manifest` and `scene`, or the error text.
fn new_scene(manifest: &str, scene: &str) -> Result<*mut CmuxWallpaperScene, String> {
    let mut error: *mut c_char = std::ptr::dangling_mut();
    // SAFETY: valid bytes; `error` is writable.
    let s = unsafe {
        cmux_wallpaper_scene_new(
            manifest.as_ptr(),
            manifest.len(),
            scene.as_ptr(),
            scene.len(),
            &mut error,
        )
    };
    if s.is_null() {
        let why = text(error).expect("an error with a null scene");
        // SAFETY: `error` came from this library and is freed once.
        unsafe { cmux_wallpaper_string_free(error) };
        Err(why)
    } else {
        assert!(error.is_null());
        Ok(s)
    }
}

#[test]
fn a_scene_packs_its_block_and_rests() {
    assert_eq!(cmux_wallpaper_scene_floats(), 512);
    let still = r##"{"field": {"points": [
        {"at": [0, 0], "color": "#FF0000"}, {"at": [1, 0], "color": "paper"},
        {"at": [1, 1], "color": "accent"}, {"at": [0, 1], "color": "ink"}]},
        "shapes": [{"kind": "circle", "size": [0.4, 0.4]}],
        "image": {"slot": "badge"}}"##;
    let moving = r#"{"shapes": [{"kind": "ring",
        "at": {"keys": [[0, [0.2, 0.5]], [2, [0.8, 0.5]]]}, "size": [0.3, 0.3]}]}"#;
    let input = CmuxWallpaperFrameInput {
        time: 1.0,
        width: 800.0,
        height: 400.0,
        backing_scale: 2.0,
        presence: 1.0,
        ..Default::default()
    };
    let s = new_scene(SCENE_MANIFEST, still).unwrap();
    let m = new_scene(SCENE_MANIFEST, moving).unwrap();
    // SAFETY: live handles; `out` has 512 floats; null is allowed.
    unsafe {
        let mut out = [7.0_f32; 512];
        assert!(cmux_wallpaper_scene_evaluate(s, &input, 1.0, out.as_mut_ptr(), out.len()));
        // Header: one shape, no guides, no ropes.
        assert_eq!(&out[0..4], &[1.0, 0.0, 0.0, 0.0]);
        // Grain row: image shown.
        assert_eq!(out[7], 1.0);
        // Shape 0 (row 12): a circle at the center, in rendered pixels.
        assert_eq!(&out[48..51], &[1.0, 400.0, 200.0]);
        assert!(cmux_wallpaper_scene_at_rest(s));
        assert!(cmux_wallpaper_scene_has_image(s));

        assert!(cmux_wallpaper_scene_evaluate(m, &input, 1.0, out.as_mut_ptr(), out.len()));
        assert_eq!(out[48], 8.0);
        assert!(!cmux_wallpaper_scene_at_rest(m));
        assert!(!cmux_wallpaper_scene_has_image(m));

        // Too short a buffer or a null: false, nothing written.
        let mut short = [7.0_f32; 511];
        assert!(!cmux_wallpaper_scene_evaluate(s, &input, 1.0, short.as_mut_ptr(), short.len()));
        assert!(short.iter().all(|x| *x == 7.0));
        assert!(!cmux_wallpaper_scene_evaluate(
            std::ptr::null_mut(),
            &input,
            1.0,
            out.as_mut_ptr(),
            512
        ));
        assert!(!cmux_wallpaper_scene_evaluate(s, std::ptr::null(), 1.0, out.as_mut_ptr(), 512));
        assert!(!cmux_wallpaper_scene_evaluate(s, &input, 1.0, std::ptr::null_mut(), 512));
        assert!(cmux_wallpaper_scene_at_rest(std::ptr::null()));
        assert!(!cmux_wallpaper_scene_has_image(std::ptr::null()));

        cmux_wallpaper_scene_free(s);
        cmux_wallpaper_scene_free(m);
        cmux_wallpaper_scene_free(std::ptr::null_mut());
        cmux_wallpaper_string_free(std::ptr::null_mut());
    }
}

/// The hold end to end: a hanging card settles and the scene is at rest
/// (the scheduler holds it, reason 13); a pointer move alone keeps it at
/// rest; a press on the card wakes it, and the scheduler runs it.
#[test]
fn a_press_on_the_card_wakes_a_resting_scene() {
    let lanyard = r#"{
        "physics": {
            "bodies": [{"id": "card", "at": [0.5, 0.6], "size": [0.2, 0.28], "draggable": true, "damping": 0.6}],
            "ropes": [{"id": "strap", "anchor": [0.5, -0.02], "to": "card", "toAt": [0, -0.5],
                       "length": 0.45, "segments": 6, "width": 0.012, "color": "accent"}]
        },
        "shapes": [{"kind": "roundRect", "size": [0.2, 0.28], "body": "card"}],
        "image": {"slot": "badge", "body": "card", "inset": 0.02}
    }"#;
    let s = new_scene(SCENE_MANIFEST, lanyard).unwrap();
    let mut input = CmuxWallpaperFrameInput {
        width: 800.0,
        height: 400.0,
        backing_scale: 1.0,
        pointer_x: 10.0,
        pointer_y: 390.0,
        ..Default::default()
    };
    let mut out = [0.0_f32; 512];
    let mut schedule = CmuxWallpaperScheduleInput {
        seconds_since_activity: 0.0,
        seconds_since_pointer: 0.0,
        seconds_since_agent_event: f64::INFINITY,
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
        agents: false,
        has_frame: true,
        idle_after_s: 0.0,
        at_rest: false,
    };
    // SAFETY: a live handle; `out` has 512 floats; `schedule` is valid.
    unsafe {
        let mut now = 1000.0_f64;
        let mut frames = 0;
        while !cmux_wallpaper_scene_at_rest(s) {
            assert!(frames < 60 * 60, "the card never settled");
            now += 1.0 / 60.0;
            frames += 1;
            assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
        }
        schedule.at_rest = cmux_wallpaper_scene_at_rest(s);
        assert_eq!(cmux_wallpaper_schedule(&schedule).hold_reason, 13);
        // The card's center, from the image row (126).
        let (cx, cy) = (out[126 * 4], out[126 * 4 + 1]);
        assert!(cx > 0.0 && cy > 0.0, "no card pose: {cx} {cy}");

        // A move over the card, no button: still at rest.
        (input.pointer_x, input.pointer_y) = (cx, cy);
        now += 1.0 / 60.0;
        assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
        assert!(cmux_wallpaper_scene_at_rest(s));

        // A press away from the card: still at rest.
        (input.pointer_x, input.pointer_y, input.button_down) = (10.0, 390.0, true);
        assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
        assert!(cmux_wallpaper_scene_at_rest(s));
        input.button_down = false;
        assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));

        // A press on the card wakes it, and the scheduler runs.
        (input.pointer_x, input.pointer_y, input.button_down) = (cx, cy, true);
        assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
        assert!(!cmux_wallpaper_scene_at_rest(s));
        schedule.at_rest = cmux_wallpaper_scene_at_rest(s);
        assert!(cmux_wallpaper_schedule(&schedule).run);
        cmux_wallpaper_scene_free(s);
    }
}

#[test]
fn a_refused_scene_says_where() {
    // A program wallpaper is not a scene.
    let smoke = cmux_wallpaper::smoke().unwrap().manifest_json;
    assert!(new_scene(smoke, "{}").unwrap_err().contains("no scene"));
    // A bad manifest names its pointer.
    assert!(new_scene(r#"{"id": "Bad"}"#, "{}").unwrap_err().starts_with("/id: "));
    // A bad scene names its pointer.
    let why =
        new_scene(SCENE_MANIFEST, r#"{"shapes": [{"kind": "star", "size": [1, 1]}]}"#).unwrap_err();
    assert!(why.starts_with("/shapes/0/kind: scene: "), "{why}");
    assert!(new_scene(SCENE_MANIFEST, "not json").is_err());
    // A null error pointer is allowed.
    // SAFETY: valid bytes; a null `error` is allowed.
    let s = unsafe {
        cmux_wallpaper_scene_new(
            SCENE_MANIFEST.as_ptr(),
            SCENE_MANIFEST.len(),
            b"{".as_ptr(),
            1,
            std::ptr::null_mut(),
        )
    };
    assert!(s.is_null());
}

#[test]
fn first_party_scenes_load_and_programs_are_not_scenes() {
    let mut engine_len = 99;
    // SAFETY: `engine_len` is writable.
    let engine = unsafe { cmux_wallpaper_scene_engine_msl(&mut engine_len) };
    assert!(!engine.is_null() && engine_len > 0);
    // SAFETY: the library returned `engine_len` bytes at `engine`.
    let msl =
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(engine, engine_len) }).unwrap();
    // The engine's entry points and the Frame uniform at buffer 0, as every program's.
    assert!(msl.contains("vs_main") && msl.contains("fs_main") && msl.contains("[[buffer(0)]]"));
    // The host binds the Scene block at fragment buffer 1, the image at texture 0, its sampler at 0.
    assert!(msl.contains("[[buffer(1)]]"), "the Scene block is not at buffer 1");
    assert!(msl.contains("[[texture(0)]]"), "the image is not at texture 0");
    assert!(msl.contains("[[sampler(0)]]"), "the sampler is not at sampler 0");
    for (i, w) in cmux_wallpaper::first_party().iter().enumerate() {
        let m = Manifest::parse(w.manifest_json.as_bytes()).unwrap();
        let s = cmux_wallpaper_scene_new_first_party(i);
        if m.scene.is_some() || m.lottie.is_some() {
            assert!(!s.is_null(), "{} does not load", w.folder);
            // Its program is the engine's.
            assert_eq!(static_bytes(cmux_wallpaper_first_party_msl, i).as_deref(), Some(msl));
        } else {
            assert!(s.is_null(), "{} is a program, not a scene", w.folder);
        }
        // SAFETY: null or a live handle, freed once.
        unsafe { cmux_wallpaper_scene_free(s) };
    }
    assert!(cmux_wallpaper_scene_new_first_party(usize::MAX).is_null());
}
