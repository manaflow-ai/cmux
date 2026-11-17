use super::*;
use proptest::prelude::*;
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
    Now { build: BUILD, appearance, displays }
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
    assert!(p.reason.shows_window());
}

#[test]
fn an_image_of_another_build_falls_back_to_the_plain_shell() {
    let dir = store("w1", 2200, 1440);
    let w = window("w1", "4293.old/w1/7");
    let p = plan(Some(std::slice::from_ref(&w)), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!((p.reason, p.image), (Reason::BuildDiffers, None));
    // The plain shell keeps the saved frame and colors.
    assert_eq!(p.window, Some(w));
    assert!(p.reason.shows_window());
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
}

#[test]
fn an_image_whose_size_is_not_the_frame_falls_back() {
    let dir = store("w1", 2200, 1300);
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!(p.reason, Reason::ImageSizeDiffers);
    let dir = store("w1", 2201, 1439); // rounding
    let p = plan(
        Some(&[window("w1", &format!("{BUILD}/w1/7"))]),
        dir.path(),
        &now(Appearance::Dark, &RETINA),
    );
    assert_eq!(p.reason, Reason::Image);
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
fn no_record_is_todays_launch_and_no_windows_use_the_default_frame() {
    let dir = tempdir::Dir::new();
    let p = plan(None, dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!((p.reason, p.window, p.image), (Reason::NoRecord, None, None));
    assert!(!p.reason.shows_window());
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
fn full_screen_and_old_records_make_no_window() {
    let dir = store("w1", 2200, 1440);
    let mut full = window("w1", &format!("{BUILD}/w1/7"));
    full.fullscreen = true;
    assert_eq!(
        plan(Some(&[full]), dir.path(), &now(Appearance::Dark, &RETINA)).reason,
        Reason::FullScreen
    );
    let mut old = window("w1", "");
    old.backing_scale = 0.0;
    let p = plan(Some(&[old]), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!(p.reason, Reason::OldRecord);
    assert!(!p.reason.shows_window());
}

#[test]
fn only_the_front_window_is_planned() {
    let dir = store("front", 2200, 1440);
    let windows = [window("front", &format!("{BUILD}/front/7")), window("back", "x")];
    let p = plan(Some(&windows), dir.path(), &now(Appearance::Dark, &RETINA));
    assert_eq!(p.window.unwrap().id, "front");
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

#[test]
fn every_key_and_button_is_held_in_order_and_hover_passes() {
    use InputKind::*;
    for kind in [KeyDown, KeyUp, FlagsChanged, MouseDown, MouseUp, MouseDragged, Scroll] {
        assert_eq!(input_disposition(kind, 0), Disposition::Hold, "{kind:?}");
    }
    assert_eq!(input_disposition(MouseMoved, 0), Disposition::Pass);
    assert_eq!(input_disposition(Other, 0), Disposition::Pass);
    assert_eq!(input_disposition(KeyDown, INPUT_SWAP_AT - 2), Disposition::Hold);
    assert_eq!(input_disposition(KeyDown, INPUT_SWAP_AT - 1), Disposition::HoldAndSwap);
    // Past the swap point an event is still held, never dropped.
    assert_eq!(input_disposition(KeyDown, INPUT_SWAP_AT * 2), Disposition::HoldAndSwap);
    assert_eq!(InputKind::from_u8(200), Other);
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
        let now = Now { build: &build, appearance: Appearance::from_u8(now_dark as u8), displays: &displays };
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
                "cmux-launch-shell-{}-{}",
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
