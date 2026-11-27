use super::*;
use crate::relaunch_cover::{
    CoverCause, CoverSurface, CoverWindow, MANIFEST_FILE, MANIFEST_VERSION, Rect,
};

fn cs(s: &str) -> CString {
    CString::new(s).unwrap()
}

unsafe fn owned(p: *mut c_char) -> String {
    assert!(!p.is_null());
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
    unsafe { cmux_relaunch_cover_string_free(p) };
    s
}

#[test]
fn write_take_reveal_round_trip_over_the_c_abi() {
    let dir = std::env::temp_dir().join(format!("relaunch-cover-ffi-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    png.extend(200u32.to_be_bytes());
    png.extend(100u32.to_be_bytes());
    std::fs::write(dir.join("w.png"), &png).unwrap();
    let screen = Rect { x: 0.0, y: 0.0, width: 1000.0, height: 800.0 };
    let manifest = CoverManifest {
        version: MANIFEST_VERSION,
        cause: CoverCause::KeepSessionsQuit,
        written_at_ms: 1_000,
        build: "b".into(),
        windows: vec![CoverWindow {
            id: "w".into(),
            frame: Rect { x: 10.0, y: 10.0, width: 100.0, height: 50.0 },
            screen_frame: screen,
            scale: 2.0,
            order: 0,
            key: true,
            fullscreen: false,
            image: "w.png".into(),
            surfaces: vec![CoverSurface {
                id: "t".into(),
                rect: Rect { x: 0.0, y: 0.0, width: 100.0, height: 50.0 },
            }],
        }],
    };
    let d = cs(dir.to_str().unwrap());
    assert!(unsafe { cmux_relaunch_cover_write(d.as_ptr(), cs(&manifest.to_json()).as_ptr()) });
    assert!(!unsafe { cmux_relaunch_cover_write(d.as_ptr(), cs("{}").as_ptr()) });
    let displays =
        [CmuxLaunchShellDisplay { x: 0.0, y: 0.0, width: 1000.0, height: 800.0, scale: 2.0 }];
    let plan = unsafe {
        owned(cmux_relaunch_cover_take_plan(
            d.as_ptr(),
            2_000,
            20_000,
            displays.as_ptr(),
            1,
            cs("[\"w\"]").as_ptr(),
        ))
    };
    assert!(plan.contains("\"reason\":\"show\""), "{plan}");
    assert!(!dir.join(MANIFEST_FILE).exists());
    let reveal = unsafe { cmux_relaunch_cover_reveal_new(cs(&plan).as_ptr(), 1, 0) };
    assert!(!reveal.is_null());
    assert_eq!(unsafe { owned(cmux_relaunch_cover_reveal_start(reveal)) }, "[]");
    let steps = unsafe {
        owned(cmux_relaunch_cover_reveal_surface_ready(
            reveal,
            cs("w").as_ptr(),
            cs("t").as_ptr(),
            50,
        ))
    };
    assert_eq!(steps, r#"[{"step":"window","window":"w","fade_ms":120}]"#);
    let mut next = 7;
    assert_eq!(unsafe { owned(cmux_relaunch_cover_reveal_tick(reveal, 60, &mut next)) }, "[]");
    assert_eq!(next, 0);
    unsafe { cmux_relaunch_cover_reveal_free(reveal) };
    unsafe { cmux_relaunch_cover_clear(d.as_ptr(), cs(&plan).as_ptr()) };
    assert!(!dir.join("w.png").exists());
    // A second launch finds nothing: the cover was taken.
    let again = unsafe {
        owned(cmux_relaunch_cover_take_plan(
            d.as_ptr(),
            2_100,
            20_000,
            displays.as_ptr(),
            1,
            cs("[\"w\"]").as_ptr(),
        ))
    };
    assert!(again.contains("\"reason\":\"no_manifest\""), "{again}");
    assert!(unsafe { cmux_relaunch_cover_reveal_new(cs(&again).as_ptr(), 1, 0) }.is_null());
    let _ = std::fs::remove_dir_all(&dir);
}
