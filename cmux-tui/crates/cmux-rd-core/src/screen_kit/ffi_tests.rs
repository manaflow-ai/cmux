use super::*;

#[test]
fn the_header_declares_exactly_the_exported_functions() {
    let header = include_str!("../../include/cmux_screen_kit.h");
    let declared: std::collections::BTreeSet<&str> = header
        .lines()
        .filter(|l| !l.trim_start().starts_with('#') && !l.trim_start().starts_with('/'))
        .filter_map(|l| {
            let open = l.find('(')?;
            let name = l[..open].rsplit(|c: char| !(c.is_alphanumeric() || c == '_')).next()?;
            name.starts_with("cmux_screen_").then_some(name)
        })
        .collect();
    let source = include_str!("ffi.rs");
    let exported: std::collections::BTreeSet<&str> = source
        .split("extern \"C\" fn ")
        .skip(1)
        .filter_map(|rest| rest.split('(').next())
        .collect();
    assert_eq!(declared, exported);
    for (name, value) in [
        ("CMUX_SCREEN_OK", CMUX_SCREEN_OK),
        ("CMUX_SCREEN_ERR_NULL", CMUX_SCREEN_ERR_NULL),
        ("CMUX_SCREEN_ERR_INVALID", CMUX_SCREEN_ERR_INVALID),
        ("CMUX_SCREEN_ERR_PANIC", CMUX_SCREEN_ERR_PANIC),
        ("CMUX_SCREEN_ERR_BUFFER", CMUX_SCREEN_ERR_BUFFER),
    ] {
        assert!(header.contains(&format!("#define {name} ({value})")), "{name}");
    }
    assert!(header.contains(&format!(
        "#define CMUX_SCREEN_TRACKPAD_MAX_ACTIONS ({CMUX_SCREEN_TRACKPAD_MAX_ACTIONS})"
    )));
}

#[test]
fn a_double_tap_through_the_c_abi() {
    let pad = cmux_screen_trackpad_new();
    let mut out = [CmuxScreenTrackpadAction::default(); CMUX_SCREEN_TRACKPAD_MAX_ACTIONS];
    let mut count = 0;
    // SAFETY: a live handle and buffers of the documented sizes.
    unsafe {
        assert_eq!(
            cmux_screen_trackpad_touch_down(pad, 0.0, out.as_mut_ptr(), &mut count),
            CMUX_SCREEN_OK
        );
        assert_eq!(count, 0);
        cmux_screen_trackpad_touch_up(pad, 0.08, out.as_mut_ptr(), &mut count);
        assert_eq!((count, out[0].kind), (1, CMUX_SCREEN_TRACKPAD_PRESS));
        let (mut held, mut has, mut deadline) = (false, false, 0.0);
        cmux_screen_trackpad_state(pad, &mut held, &mut has, &mut deadline);
        assert!(held && has && (deadline - 0.33).abs() < 1e-9);
        cmux_screen_trackpad_touch_down(pad, 0.2, out.as_mut_ptr(), &mut count);
        cmux_screen_trackpad_touch_up(pad, 0.28, out.as_mut_ptr(), &mut count);
        let kinds: Vec<u32> = out[..count].iter().map(|a| a.kind).collect();
        assert_eq!(
            kinds,
            [
                CMUX_SCREEN_TRACKPAD_RELEASE,
                CMUX_SCREEN_TRACKPAD_PRESS,
                CMUX_SCREEN_TRACKPAD_RELEASE
            ]
        );
        assert_eq!(
            cmux_screen_trackpad_set_timings(pad, -1.0, 8.0, 0.45, 0.25),
            CMUX_SCREEN_ERR_INVALID
        );
        assert_eq!(
            cmux_screen_trackpad_touch_down(
                std::ptr::null_mut(),
                0.0,
                out.as_mut_ptr(),
                &mut count
            ),
            CMUX_SCREEN_ERR_NULL
        );
        cmux_screen_trackpad_free(pad);
    }
}

#[test]
fn the_cursor_cache_through_the_c_abi() {
    let cache = cmux_screen_cursor_cache_new();
    let geometry = CursorGeometry {
        size: Size::new(0.1, 0.1),
        hotspot: Point::new(0.5, 0.5),
        points: Size::new(10.0, 10.0),
    };
    let (mut current, mut changed, mut has) = (false, false, false);
    let mut id = [0u8; 16];
    let mut len = 0;
    let mut got = CursorGeometry::default();
    // SAFETY: a live handle and buffers of the sizes passed.
    unsafe {
        let code = cmux_screen_cursor_cache_add(
            cache,
            b"arrow".as_ptr(),
            5,
            geometry,
            &mut current,
            id.as_mut_ptr(),
            id.len(),
            &mut len,
        );
        assert_eq!((code, current, len), (CMUX_SCREEN_OK, false, 0));
        assert_eq!(
            cmux_screen_cursor_cache_select(cache, std::ptr::null(), 0, &mut changed),
            CMUX_SCREEN_OK
        );
        assert!(!changed);
        cmux_screen_cursor_cache_select(cache, b"arrow".as_ptr(), 5, &mut changed);
        assert!(changed);
        cmux_screen_cursor_cache_current(
            cache,
            &mut has,
            id.as_mut_ptr(),
            id.len(),
            &mut len,
            &mut got,
        );
        assert!(has && &id[..len] == b"arrow" && got == geometry);
        assert_eq!(
            cmux_screen_cursor_cache_current(
                cache,
                &mut has,
                id.as_mut_ptr(),
                2,
                &mut len,
                &mut got
            ),
            CMUX_SCREEN_ERR_BUFFER
        );
        assert_eq!(len, 5);
        let bad = [0xffu8];
        assert_eq!(
            cmux_screen_cursor_cache_select(cache, bad.as_ptr(), 1, &mut changed),
            CMUX_SCREEN_ERR_INVALID
        );
        cmux_screen_cursor_cache_reset(cache);
        cmux_screen_cursor_cache_current(
            cache,
            &mut has,
            id.as_mut_ptr(),
            id.len(),
            &mut len,
            &mut got,
        );
        assert!(!has);
        cmux_screen_cursor_cache_free(cache);
    }
}

#[test]
fn names_and_policy_through_the_c_abi() {
    let mut buf = [0u8; 8];
    let mut len = 0;
    // SAFETY: a buffer of the size passed.
    unsafe {
        assert_eq!(
            cmux_screen_encoding_name(16, buf.as_mut_ptr(), buf.len(), &mut len),
            CMUX_SCREEN_OK
        );
        assert_eq!(&buf[..len], b"ZRLE");
        assert_eq!(
            cmux_screen_encoding_name(1, buf.as_mut_ptr(), 2, &mut len),
            CMUX_SCREEN_ERR_BUFFER
        );
        assert_eq!(len, 8);
    }
    assert!(cmux_screen_connecting_notice_shown(1, true, true, false));
    assert!(!cmux_screen_connecting_notice_shown(9, true, true, true), "an unknown phase");
    assert!(cmux_screen_keeps_live_layout(2, false));
    let mut q = ScrollQuantizer::default();
    let (mut x, mut y) = (0, 0);
    // SAFETY: live locals.
    unsafe {
        cmux_screen_scroll_quantize(&mut q, Point::new(36.0, -18.0), false, 1.0, &mut x, &mut y)
    };
    assert_eq!((x, y), (2, -1));
    let screens = [Rect::new(-10.0, 0.0, 10.0, 10.0), Rect::new(0.0, 0.0, 10.0, 10.0)];
    // SAFETY: a slice's pointer and length.
    assert_eq!(unsafe { cmux_screen_initial_page(screens.as_ptr(), screens.len()) }, 1);
    assert_eq!(cmux_screen_hint_pose(false, 0.5), HintPose::default());
}
