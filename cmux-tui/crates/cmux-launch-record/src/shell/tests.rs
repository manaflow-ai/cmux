//! Ported from cmux-launch-shell (cmux#45089) with the reason rules of this crate (1 and 2 show
//! a default-frame window, 10 shows none, a v1 record is 3), plus the record-level cases.
use super::*;
use crate::{LaunchRecordData, WindowRecord, write_atomic};
use proptest::prelude::*;
use std::ffi::{CStr, CString};
use std::fs;

const BUILD: &str = "4294.abc123";
const SCREEN: Frame = Frame { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 };

fn window(id: &str, key: &str) -> SavedWindow {
    SavedWindow {
        id: id.into(),
        frame: Frame { x: 100.0, y: 80.0, width: 1100.0, height: 720.0 },
        background_rgba: [20, 20, 24, 255],
        bar_rgba: [30, 30, 36, 255],
        backing_scale: 2.0,
        appearance: Appearance::Dark,
        appearance_follows_system: true,
        screen_frame: SCREEN,
        fullscreen: false,
        image_key: key.into(),
    }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend([8, 6, 0, 0, 0]);
    b
}

/// A store holding window `id`'s image at generation 7, `width` x `height` pixels.
fn store(id: &str, width: u32, height: u32) -> tempdir::Dir {
    let dir = tempdir::Dir::new();
    let path = ImageKey::parse(&format!("{BUILD}/{id}/7")).unwrap().path(dir.path());
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, png(width, height)).unwrap();
    dir
}

fn now(appearance: Appearance, displays: &[Display]) -> Now<'_> {
    Now { build: BUILD, appearance, displays, support_dir: None }
}

const RETINA: [Display; 1] = [Display { frame: SCREEN, scale: 2.0 }];

#[test]
fn a_current_image_is_drawn() {
    let dir = store("w1", 2200, 1440);
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!(p.reason, Reason::Image);
    assert_eq!(p.image.unwrap(), dir.path().join(BUILD).join("w1").join("7.png"));
    assert!(p.reason.shows_window() && !p.reason.uses_default_frame());
}

#[test]
fn an_image_of_another_build_falls_back_to_the_plain_shell() {
    let dir = store("w1", 2200, 1440);
    let w = window("w1", "4293.old/w1/7");
    let p = plan(Some(std::slice::from_ref(&w)), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!((p.reason, p.image), (Reason::BuildDiffers, None));
    // The plain shell keeps the saved frame and colors.
    assert_eq!(p.window, Some(w));
    assert!(p.reason.shows_window() && !p.reason.uses_default_frame());
}

#[test]
fn a_missing_or_pruned_image_falls_back() {
    let dir = tempdir::Dir::new();
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!((p.reason, p.image), (Reason::ImageUnreadable, None));
    assert!(p.reason.shows_window());
    // A file that is not a PNG is unreadable too.
    let path = dir.path().join(BUILD).join("w1").join("7.png");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"not a png at all, twenty-four+").unwrap();
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!(p.reason, Reason::ImageUnreadable);
}

#[test]
fn an_image_whose_size_is_not_the_frame_falls_back() {
    let key = format!("{BUILD}/w1/7");
    let reason = |w: u32, h: u32| {
        let dir = store("w1", w, h);
        plan(Some(&[window("w1", &key)]), dir.path(), &now(Appearance::Dark, &RETINA)).reason
    };
    assert_eq!(reason(2200, 1300), Reason::ImageSizeDiffers);
    // Within one pixel on each axis (rounding) the image stands; two pixels off it does not.
    for (w, h) in [(2201, 1439), (2199, 1441), (2200, 1440)] {
        assert_eq!(reason(w, h), Reason::Image, "{w}x{h}");
    }
    for (w, h) in [(2202, 1440), (2200, 1438), (1100, 720)] {
        assert_eq!(reason(w, h), Reason::ImageSizeDiffers, "{w}x{h}");
    }
    assert!(Reason::ImageSizeDiffers.shows_window());
}

#[test]
fn a_key_for_another_window_is_not_drawn() {
    let dir = store("w2", 2200, 1440);
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w2/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!(p.reason, Reason::ImageUnreadable);
}

#[test]
fn a_changed_display_layout_makes_no_window() {
    let dir = store("w1", 2200, 1440);
    let moved =
        [Display { frame: Frame { x: 0.0, y: 0.0, width: 1920.0, height: 1080.0 }, scale: 2.0 }];
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &moved),
    );
    assert_eq!(p.reason, Reason::LayoutDiffers);
    assert!(!p.reason.shows_window());
    let none: [Display; 0] = [];
    assert_eq!(
        plan(Some(&[window("w1", "")]), dir.path(), &now(Appearance::Dark, &none)).reason,
        Reason::LayoutDiffers
    );
}

#[test]
fn a_changed_scale_falls_back_but_keeps_the_window() {
    let dir = store("w1", 2200, 1440);
    let lowres = [Display { frame: SCREEN, scale: 1.0 }];
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &lowres),
    );
    assert_eq!(p.reason, Reason::ScaleDiffers);
    assert!(p.reason.shows_window());
}

#[test]
fn light_and_dark() {
    let dir = store("w1", 2200, 1440);
    let key = format!("{BUILD}/w1/7");
    // Saved dark, the system is light now, the theme follows it: stale.
    let p = plan(Some(&[window("w1", &key)]), dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!(p.reason, Reason::AppearanceDiffers);
    assert!(p.reason.shows_window());
    // A fixed theme does not follow the system: the image stands.
    let mut fixed = window("w1", &key);
    fixed.appearance_follows_system = false;
    assert_eq!(
        plan(Some(&[fixed]), dir.path(), &now(Appearance::Light, &RETINA)).reason,
        Reason::Image
    );
    // Saved light, light now.
    let mut light = window("w1", &key);
    light.appearance = Appearance::Light;
    assert_eq!(
        plan(Some(&[light]), dir.path(), &now(Appearance::Light, &RETINA)).reason,
        Reason::Image
    );
}

#[test]
fn no_record_and_no_windows_use_the_default_frame() {
    let dir = tempdir::Dir::new();
    let p = plan(None, dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!((p.reason, p.window, p.image), (Reason::NoRecord, None, None));
    assert!(p.reason.shows_window() && p.reason.uses_default_frame());
    let p = plan(Some(&[]), dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!(p.reason, Reason::NoWindows);
    assert!(p.reason.shows_window() && p.reason.uses_default_frame());
    let mut broken = window("w1", "");
    broken.frame.width = f64::NAN;
    assert_eq!(
        plan(Some(&[broken]), dir.path(), &now(Appearance::Light, &RETINA)).reason,
        Reason::NoWindows
    );
}

#[test]
fn no_record_with_prior_state_makes_no_window() {
    let support = tempdir::Dir::new();
    let images = tempdir::Dir::new();
    let with = Now { support_dir: Some(support.path()), ..now(Appearance::Light, &RETINA) };
    assert_eq!(plan(None, images.path(), &with).reason, Reason::NoRecord);
    fs::write(support.path().join("launch-times.jsonl"), b"{}\n").unwrap();
    let p = plan(None, images.path(), &with);
    assert_eq!((p.reason, p.window), (Reason::NoRecordPriorState, None));
    assert!(!p.reason.shows_window());
    // Without a support directory the marker is not looked for; a record overrides it.
    assert_eq!(
        plan(None, images.path(), &now(Appearance::Light, &RETINA)).reason,
        Reason::NoRecord
    );
    assert_eq!(plan(Some(&[]), images.path(), &with).reason, Reason::NoWindows);
    // Only a file counts.
    fs::remove_file(support.path().join("launch-times.jsonl")).unwrap();
    fs::create_dir(support.path().join("launch-times.jsonl")).unwrap();
    assert_eq!(plan(None, images.path(), &with).reason, Reason::NoRecord);
}

#[test]
fn full_screen_makes_no_window_and_old_records_are_stale() {
    let dir = store("w1", 2200, 1440);
    let mut full = window("w1", &format!("{BUILD}/w1/7"));
    full.fullscreen = true;
    let p = plan(Some(&[full.clone()]), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!(p.reason, Reason::FullScreen);
    assert!(!p.reason.shows_window());
    // A no-window reason wins over a plain-shell one.
    full.image_key = "4293.old/w1/7".into();
    assert_eq!(
        plan(Some(&[full]), dir.path(), &now(Appearance::Dark, &RETINA)).reason,
        Reason::FullScreen
    );
    let mut old = window("w1", "");
    old.backing_scale = 0.0;
    let p = plan(Some(&[old]), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!(p.reason, Reason::BuildDiffers);
    assert!(p.reason.shows_window() && !p.reason.uses_default_frame());
}

#[test]
fn only_the_front_window_is_planned() {
    let dir = store("front", 2200, 1440);
    let windows = [window("front", &format!("{BUILD}/front/7")), window("back", "x")];
    let p = plan(Some(&windows), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!(p.window.unwrap().id, "front");
    assert_eq!(p.reason, Reason::Image);
}

#[test]
fn keys_stay_inside_the_store() {
    for bad in [
        "",
        "a/b",
        "a/b/c/d",
        "../w/1",
        "b/../1",
        "b/w/-1",
        "b/w/1.png",
        "b/w/x",
        "b//1",
        "b/w\0/1",
    ] {
        assert_eq!(ImageKey::parse(bad), None, "{bad:?}");
    }
    assert_eq!(ImageKey::format("b", "..", 1), None);
    let key = ImageKey::format(BUILD, "3f2a-9c", 12).unwrap();
    assert_eq!(
        ImageKey::parse(&key),
        Some(ImageKey { build: BUILD, window_id: "3f2a-9c", generation: 12 })
    );
}

fn record_window(id: &str, key: &str) -> WindowRecord {
    WindowRecord {
        id: id.into(),
        frame: Frame { x: 100.0, y: 80.0, width: 1100.0, height: 720.0 },
        display_id: 1,
        background_rgba: [20, 20, 24, 255],
        bar_rgba: [30, 30, 36, 255],
        image_key: key.into(),
        image_pixel_width: 2200,
        image_pixel_height: 1440,
        backing_scale: 2.0,
        appearance: 1,
        appearance_follows_system: 1,
        fullscreen: 0,
        screen_frame: SCREEN,
        visible_workspace_id: "ws".into(),
        visible_tab_ids: vec![],
    }
}

/// The FFI inputs for `RETINA`, `BUILD` and dark, with `support` as the support directory.
struct CNow {
    build: CString,
    support: Option<CString>,
    displays: Vec<CmuxLaunchShellDisplay>,
}
impl CNow {
    fn new(support: Option<&Path>) -> Self {
        Self {
            build: CString::new(BUILD).unwrap(),
            support: support.map(|p| CString::new(p.to_str().unwrap()).unwrap()),
            displays: RETINA
                .iter()
                .map(|d| CmuxLaunchShellDisplay {
                    x: d.frame.x,
                    y: d.frame.y,
                    width: d.frame.width,
                    height: d.frame.height,
                    scale: d.scale,
                })
                .collect(),
        }
    }
    fn get(&self) -> CmuxLaunchShellNow {
        CmuxLaunchShellNow {
            build: self.build.as_ptr(),
            appearance: 1,
            displays: self.displays.as_ptr(),
            display_count: self.displays.len(),
            support_dir: self.support.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
        }
    }
}
fn c_path(p: &Path) -> CString {
    CString::new(p.to_str().unwrap()).unwrap()
}
fn text(buf: &[c_char]) -> String {
    unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap().to_owned()
}

#[test]
fn ffi_plan_from_a_record() {
    let images = store("w1", 2200, 1440);
    let support = tempdir::Dir::new();
    let record_path = support.path().join("launch-record");
    let (record, image_dir) = (c_path(&record_path), c_path(images.path()));
    let c = CNow::new(Some(support.path()));
    let now = c.get();
    let mut out = CmuxLaunchShellPlan { reason: 42, ..Default::default() };
    let call = |out: &mut CmuxLaunchShellPlan| unsafe {
        cmux_launch_shell_plan(record.as_ptr(), image_dir.as_ptr(), &now, out)
    };
    // No record, first launch: a default-frame window.
    assert!(call(&mut out));
    assert_eq!((out.reason, out.shows_window, out.uses_default_frame), (1, true, true));
    // No record after a launch that left state: no window.
    fs::write(support.path().join(PRIOR_STATE_MARKERS[0]), b"{}\n").unwrap();
    assert!(call(&mut out));
    assert_eq!((out.reason, out.shows_window, out.uses_default_frame), (10, false, false));
    // An unreadable record is no record.
    fs::write(&record_path, b"garbage").unwrap();
    assert!(call(&mut out));
    assert_eq!(out.reason, 10);
    let mut data = LaunchRecordData {
        windows: vec![record_window("w1", &format!("{BUILD}/w1/7"))],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
    };
    write_atomic(&record_path, &data).unwrap();
    assert!(call(&mut out));
    assert_eq!((out.reason, out.shows_window, out.uses_default_frame), (0, true, false));
    assert_eq!((out.frame_x, out.frame_width, out.appearance), (100.0, 1100.0, 1));
    assert_eq!((out.background_rgba, out.bar_rgba), ([20, 20, 24, 255], [30, 30, 36, 255]));
    assert_eq!(text(&out.window_id), "w1");
    let image = images.path().join(BUILD).join("w1").join("7.png");
    assert_eq!(text(&out.image_path), image.to_str().unwrap());
    // Another build: the saved frame, no image.
    data.windows[0].image_key = "4293.old/w1/7".into();
    write_atomic(&record_path, &data).unwrap();
    assert!(call(&mut out));
    assert_eq!((out.reason, out.shows_window, out.frame_width), (3, true, 1100.0));
    assert_eq!(text(&out.image_path), "");
    // An id that does not fit is no window to plan.
    data.windows[0].id = "x".repeat(65);
    write_atomic(&record_path, &data).unwrap();
    assert!(call(&mut out));
    assert_eq!((out.reason, out.frame_width, out.uses_default_frame), (2, 0.0, true));
    // A record with no windows.
    data.windows.clear();
    write_atomic(&record_path, &data).unwrap();
    assert!(call(&mut out));
    assert_eq!((out.reason, out.shows_window, out.uses_default_frame), (2, true, true));
}

#[test]
fn ffi_v1_record_is_stale_at_its_saved_frame() {
    let images = store("w1", 2200, 1440);
    let dir = tempdir::Dir::new();
    let record_path = dir.path().join("launch-record");
    // The v1 encoding: no scale, flags or screen frame; an image path, not a key.
    let mut b = b"CMUXLR01".to_vec();
    for n in [1u16, 1, 0] {
        b.extend(n.to_le_bytes());
    }
    let string = |b: &mut Vec<u8>, s: &str| {
        b.extend((s.len() as u16).to_le_bytes());
        b.extend(s.as_bytes());
    };
    string(&mut b, "w1");
    for n in [100.0f64, 80.0, 1100.0, 720.0] {
        b.extend(n.to_le_bytes());
    }
    b.extend(1u32.to_le_bytes());
    b.extend([20, 20, 24, 255, 30, 30, 36, 255]);
    string(&mut b, &format!("{BUILD}/w1/7"));
    b.extend(2200u32.to_le_bytes());
    b.extend(1440u32.to_le_bytes());
    string(&mut b, "ws");
    b.extend(0u16.to_le_bytes());
    string(&mut b, "");
    fs::write(&record_path, b).unwrap();
    assert_eq!(LaunchRecord::read(&record_path).unwrap().version(), 1);
    let (record, image_dir) = (c_path(&record_path), c_path(images.path()));
    let c = CNow::new(None);
    let mut out = CmuxLaunchShellPlan::default();
    assert!(unsafe {
        cmux_launch_shell_plan(record.as_ptr(), image_dir.as_ptr(), &c.get(), &mut out)
    });
    assert_eq!((out.reason, out.shows_window, out.uses_default_frame), (3, true, false));
    assert_eq!((out.frame_x, out.frame_y, out.frame_width), (100.0, 80.0, 1100.0));
    assert_eq!(text(&out.image_path), "");
}

#[test]
fn ffi_rejects_null_and_non_utf8_arguments() {
    let dir = tempdir::Dir::new();
    let (record, image_dir) = (c_path(&dir.path().join("r")), c_path(dir.path()));
    let c = CNow::new(Some(dir.path()));
    let now = c.get();
    let mut out = CmuxLaunchShellPlan { reason: 42, ..Default::default() };
    let null = std::ptr::null();
    unsafe {
        assert!(!cmux_launch_shell_plan(null, image_dir.as_ptr(), &now, &mut out));
        assert!(!cmux_launch_shell_plan(record.as_ptr(), null, &now, &mut out));
        assert!(!cmux_launch_shell_plan(
            record.as_ptr(),
            image_dir.as_ptr(),
            null.cast(),
            &mut out
        ));
        assert!(!cmux_launch_shell_plan(
            record.as_ptr(),
            image_dir.as_ptr(),
            &now,
            std::ptr::null_mut()
        ));
        let bad = [0xffu8, 0];
        let build = CmuxLaunchShellNow { build: bad.as_ptr().cast(), ..c.get() };
        assert!(!cmux_launch_shell_plan(record.as_ptr(), image_dir.as_ptr(), &build, &mut out));
        let support = CmuxLaunchShellNow { support_dir: bad.as_ptr().cast(), ..c.get() };
        assert!(!cmux_launch_shell_plan(record.as_ptr(), image_dir.as_ptr(), &support, &mut out));
    }
    assert_eq!((out.reason, out.shows_window, out.frame_width), (1, false, 0.0));
}

#[test]
fn ffi_windows_now_flags_each_drawable_image() {
    let images = store("front", 2200, 1440);
    let dir = tempdir::Dir::new();
    let record_path = dir.path().join("launch-record");
    let mut back = record_window("back", &format!("{BUILD}/back/7"));
    back.frame.x = 300.0;
    let data = LaunchRecordData {
        windows: vec![record_window("front", &format!("{BUILD}/front/7")), back],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
    };
    write_atomic(&record_path, &data).unwrap();
    let (record, image_dir) = (c_path(&record_path), c_path(images.path()));
    let c = CNow::new(None);
    let mut out = [crate::CmuxLaunchWindow::default(); 3];
    let n = unsafe {
        crate::cmux_launch_record_windows_now(
            record.as_ptr(),
            image_dir.as_ptr(),
            &c.get(),
            out.as_mut_ptr(),
            3,
        )
    };
    assert_eq!(n, 2);
    assert_eq!((text(&out[0].window_id), out[0].image_ok), ("front".into(), 1));
    // The back window's image is not in the store.
    assert_eq!(
        (text(&out[1].window_id), out[1].image_ok, out[1].frame_x),
        ("back".into(), 0, 300.0)
    );
    // The plain call never sets the flag.
    let n = unsafe { crate::cmux_launch_record_windows(record.as_ptr(), out.as_mut_ptr(), 3) };
    assert_eq!((n, out[0].image_ok), (2, 0));
    assert_eq!(
        unsafe {
            crate::cmux_launch_record_windows_now(
                record.as_ptr(),
                image_dir.as_ptr(),
                std::ptr::null(),
                out.as_mut_ptr(),
                3,
            )
        },
        0
    );
}

proptest! {
    /// Whatever the record says, a plan draws an image only when every staleness input matches,
    /// and never names a file outside the store.
    #[test]
    fn an_image_is_drawn_only_when_everything_matches(
        build in "[a-z0-9.]{1,8}", id in "[a-z0-9-]{1,8}", scale in prop::sample::select(vec![1.0, 2.0, 3.0]),
        now_scale in prop::sample::select(vec![1.0, 2.0, 3.0]), dark in any::<bool>(), now_dark in any::<bool>(),
        follows in any::<bool>(), full in any::<bool>(), key in ".{0,24}",
    ) {
        let dir = tempdir::Dir::new();
        let mut w = window(&id, &key);
        (w.backing_scale, w.appearance, w.appearance_follows_system, w.fullscreen) =
            (scale, Appearance::from_u8(dark as u8), follows, full);
        let displays = [Display { frame: SCREEN, scale: now_scale }];
        let now = Now {
            build: &build,
            appearance: Appearance::from_u8(now_dark as u8),
            displays: &displays,
            support_dir: None,
        };
        let p = plan(Some(&[w]), dir.path(), &now);
        if let Some(image) = &p.image {
            prop_assert!(image.starts_with(dir.path()));
            prop_assert_eq!(p.reason, Reason::Image);
            prop_assert!(!full && scale == now_scale && (!follows || dark == now_dark));
        }
    }
}

/// A temporary directory removed on drop (no extra dependency).
mod tempdir {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    pub struct Dir(PathBuf);
    impl Dir {
        pub fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "cmux-launch-record-shell-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
