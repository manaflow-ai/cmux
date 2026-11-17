use super::*;
use crate::prior::Registry;
use proptest::prelude::*;
use std::fs;

/// The plan of a launch with a record: what an earlier run left is not read then.
fn plan(windows: Option<&[SavedWindow]>, image_dir: &Path, now: &Now<'_>) -> Plan {
    super::plan(windows, PriorState::UNKNOWN, image_dir, now)
}

/// A home with nothing of an earlier run: an empty state directory and no `launch-times.jsonl`.
struct Home {
    dir: tempdir::Dir,
}

const SESSION: &str = "cmux-app-a";

impl Home {
    fn new() -> Self {
        let home = Self { dir: tempdir::Dir::new() };
        fs::create_dir_all(home.state_dir()).unwrap();
        home
    }
    fn state_dir(&self) -> PathBuf {
        self.dir.path().join("sessions")
    }
    fn launch_times(&self) -> PathBuf {
        self.dir.path().join("launch-times.jsonl")
    }
    fn prior(&self, snapshot_path_recorded: bool) -> PriorState {
        PriorState::gather(
            SESSION,
            Some(&self.state_dir()),
            snapshot_path_recorded,
            &self.launch_times(),
        )
    }
    fn reason(&self, snapshot_path_recorded: bool) -> Reason {
        let now = now(Appearance::Light, &RETINA);
        super::plan(None, self.prior(snapshot_path_recorded), self.dir.path(), &now).reason
    }
}

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
    assert_eq!(p.image.unwrap(), dir.path().join("w1.7.png"));
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
fn no_record_is_bare_on_a_fresh_install_and_todays_launch_on_an_upgrade() {
    let home = Home::new();
    let p = super::plan(None, home.prior(false), home.dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!((p.reason, p.window, p.image), (Reason::FreshInstall, None, None));
    assert!(p.reason.shows_window() && p.reason.uses_default_frame());
    // An upgrade from a build without the writer left its launch times.
    fs::write(home.launch_times(), "{}\n").unwrap();
    assert_eq!(home.reason(false), Reason::Upgrade);
    assert!(!Reason::Upgrade.shows_window());
    let dir = tempdir::Dir::new();
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
fn a_fresh_install_needs_every_sign_of_an_earlier_run_absent() {
    // No state directory at all is as fresh as an empty one.
    let home = Home::new();
    fs::remove_dir(home.state_dir()).unwrap();
    assert_eq!(home.reason(false), Reason::FreshInstall);

    // A registry folder of the session: its daemon ran here.
    let home = Home::new();
    fs::create_dir(home.state_dir().join(format!("{SESSION}-1f2e"))).unwrap();
    assert_eq!(home.prior(false).registry, Registry::Present);
    assert_eq!(home.reason(false), Reason::Upgrade);

    // Another session's folder (`<session>-a-b` has two id parts) is not this one's.
    let home = Home::new();
    fs::create_dir(home.state_dir().join(format!("{SESSION}-b-1f2e"))).unwrap();
    fs::create_dir(home.state_dir().join("other-1f2e")).unwrap();
    assert_eq!(home.prior(false).registry, Registry::Absent);
    assert_eq!(home.reason(false), Reason::FreshInstall);

    // A state directory that cannot be listed may hold one (a file there lists as no directory).
    let home = Home::new();
    fs::remove_dir(home.state_dir()).unwrap();
    fs::write(home.state_dir(), "").unwrap();
    assert_eq!(home.prior(false).registry, Registry::Unknown);
    assert_eq!(home.reason(false), Reason::Upgrade);

    // The app's launch times.
    let home = Home::new();
    fs::write(home.launch_times(), "").unwrap();
    assert_eq!(home.reason(false), Reason::Upgrade);

    // A recorded snapshot path (the app's defaults).
    let home = Home::new();
    assert_eq!(home.reason(true), Reason::Upgrade);

    // Unknown is never fresh.
    let dir = tempdir::Dir::new();
    let p = super::plan(None, PriorState::UNKNOWN, dir.path(), &now(Appearance::Light, &RETINA));
    assert_eq!(p.reason, Reason::Upgrade);
}

#[test]
fn a_record_decides_whatever_the_home_says() {
    let home = Home::new();
    let fresh = home.prior(false);
    assert!(fresh.is_fresh());
    let now = now(Appearance::Light, &RETINA);
    assert_eq!(super::plan(Some(&[]), fresh, home.dir.path(), &now).reason, Reason::NoWindows);
    let w = [window("w1", "")];
    assert_eq!(super::plan(Some(&w), fresh, home.dir.path(), &now).reason, Reason::ImageUnreadable);
}

#[test]
fn full_screen_makes_no_window_and_a_v1_record_the_plain_shell() {
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
    assert_eq!((p.reason, p.image), (Reason::BuildDiffers, None));
    assert!(p.reason.shows_window() && !p.reason.uses_default_frame());
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
