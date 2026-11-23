use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

const SCREEN: Rect = Rect { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 };
const T0: u64 = 1_800_000_000_000;

fn display() -> Display {
    Display { frame: SCREEN.into(), scale: 2.0 }
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend([8, 6, 0, 0, 0]);
    b
}

/// A fresh folder under the system's temporary directory, removed on drop.
struct Dir(PathBuf);

impl Dir {
    fn new() -> Self {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let unique = format!("relaunch-cover-{}-{nanos}-{:p}", std::process::id(), &nanos);
        let path = std::env::temp_dir().join(unique);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn window(id: &str, order: u32, surfaces: &[&str]) -> CoverWindow {
    CoverWindow {
        id: id.into(),
        frame: Rect { x: 100.0 + f64::from(order) * 30.0, y: 80.0, width: 1100.0, height: 720.0 },
        screen_frame: SCREEN,
        scale: 2.0,
        order,
        key: order == 0,
        fullscreen: false,
        image: format!("{id}.png"),
        surfaces: surfaces
            .iter()
            .enumerate()
            .map(|(i, s)| CoverSurface {
                id: (*s).into(),
                rect: Rect { x: 240.0 + 430.0 * i as f64, y: 40.0, width: 430.0, height: 680.0 },
            })
            .collect(),
    }
}

fn manifest(windows: Vec<CoverWindow>) -> CoverManifest {
    CoverManifest {
        version: MANIFEST_VERSION,
        cause: CoverCause::Update,
        written_at_ms: T0,
        build: "4300.abc".into(),
        windows,
    }
}

/// A folder holding each window's picture at its exact pixel size.
fn store(m: &CoverManifest) -> Dir {
    let dir = Dir::new();
    for w in &m.windows {
        let px = |p: f64| (p * w.scale).round() as u32;
        fs::write(dir.0.join(&w.image), png(px(w.frame.width), px(w.frame.height))).unwrap();
    }
    dir
}

fn now<'a>(displays: &'a [Display], restoring: &'a [&'a str], at: u64) -> CoverNow<'a> {
    CoverNow { now_ms: at, max_age_ms: DEFAULT_MAX_AGE_MS, displays, restoring }
}

#[test]
fn a_fresh_cover_of_the_same_windows_shows_every_window_front_first() {
    let m = manifest(vec![window("w-back", 1, &["t2"]), window("w-front", 0, &["t1", "a1"])]);
    let dir = store(&m);
    let displays = [display()];
    let plan = cover_plan(Some(&m), &dir.0, &now(&displays, &["w-front", "w-back"], T0 + 1_500));
    assert_eq!(plan.reason, CoverReason::Show);
    let ids: Vec<_> = plan.windows.iter().map(|w| w.id.as_str()).collect();
    assert_eq!(ids, ["w-front", "w-back"]);
    assert!(plan.windows[0].key && !plan.windows[1].key);
    assert_eq!(plan.windows[0].image_path, dir.0.join("w-front.png"));
    assert_eq!(plan.windows[0].surfaces.len(), 2);
}

#[test]
fn a_stale_cover_is_never_shown() {
    let m = manifest(vec![window("w", 0, &["t"])]);
    let dir = store(&m);
    let displays = [display()];
    let at_limit = cover_plan(Some(&m), &dir.0, &now(&displays, &["w"], T0 + DEFAULT_MAX_AGE_MS));
    assert_eq!(at_limit.reason, CoverReason::Show);
    let late = cover_plan(Some(&m), &dir.0, &now(&displays, &["w"], T0 + DEFAULT_MAX_AGE_MS + 1));
    assert_eq!(late.reason, CoverReason::Stale);
    assert!(late.windows.is_empty());
    // The clock went back: the age is unknown, so it is stale.
    let earlier = cover_plan(Some(&m), &dir.0, &now(&displays, &["w"], T0 - 1));
    assert_eq!(earlier.reason, CoverReason::Stale);
}

#[test]
fn a_changed_window_set_drops_the_whole_cover() {
    let m = manifest(vec![window("a", 0, &["t"]), window("b", 1, &["u"])]);
    let dir = store(&m);
    let displays = [display()];
    for restoring in [&["a"][..], &["a", "b", "c"], &["a", "c"], &[]] {
        let plan = cover_plan(Some(&m), &dir.0, &now(&displays, restoring, T0 + 10));
        assert_eq!(plan.reason, CoverReason::WindowSetChanged, "{restoring:?}");
        assert!(plan.windows.is_empty());
    }
}

#[test]
fn a_moved_display_or_scale_drops_it() {
    let m = manifest(vec![window("a", 0, &["t"])]);
    let dir = store(&m);
    let moved = [Display { frame: Frame { x: 1512.0, ..SCREEN.into() }, scale: 2.0 }];
    let plan = cover_plan(Some(&m), &dir.0, &now(&moved, &["a"], T0 + 10));
    assert_eq!(
        (plan.reason, plan.failed_window.as_deref()),
        (CoverReason::LayoutChanged, Some("a"))
    );
    let scaled = [Display { frame: SCREEN.into(), scale: 1.0 }];
    let plan = cover_plan(Some(&m), &dir.0, &now(&scaled, &["a"], T0 + 10));
    assert_eq!(plan.reason, CoverReason::LayoutChanged);
}

#[test]
fn a_missing_or_wrong_sized_picture_drops_it() {
    let m = manifest(vec![window("a", 0, &["t"]), window("b", 1, &["u"])]);
    let dir = store(&m);
    let displays = [display()];
    fs::write(dir.0.join("b.png"), png(2200, 1000)).unwrap();
    let plan = cover_plan(Some(&m), &dir.0, &now(&displays, &["a", "b"], T0 + 10));
    assert_eq!(
        (plan.reason, plan.failed_window.as_deref()),
        (CoverReason::ImageSizeDiffers, Some("b"))
    );
    fs::write(dir.0.join("b.png"), png(2201, 1440)).unwrap();
    assert_eq!(
        cover_plan(Some(&m), &dir.0, &now(&displays, &["a", "b"], T0 + 10)).reason,
        CoverReason::Show
    );
    fs::remove_file(dir.0.join("b.png")).unwrap();
    let plan = cover_plan(Some(&m), &dir.0, &now(&displays, &["a", "b"], T0 + 10));
    assert_eq!(plan.reason, CoverReason::ImageUnreadable);
}

#[test]
fn full_screen_none_and_empty_are_not_shown() {
    let displays = [display()];
    let dir = Dir::new();
    assert_eq!(cover_plan(None, &dir.0, &now(&displays, &[], T0)).reason, CoverReason::NoManifest);
    let empty = manifest(vec![]);
    assert_eq!(
        cover_plan(Some(&empty), &dir.0, &now(&displays, &[], T0)).reason,
        CoverReason::NoWindows
    );
    let mut w = window("a", 0, &["t"]);
    w.fullscreen = true;
    let m = manifest(vec![w]);
    let dir = store(&m);
    assert_eq!(
        cover_plan(Some(&m), &dir.0, &now(&displays, &["a"], T0)).reason,
        CoverReason::FullScreen
    );
}

#[test]
fn a_manifest_naming_a_file_outside_its_folder_is_refused() {
    let mut w = window("a", 0, &["t"]);
    w.image = "../launch-record.bin".into();
    let m = manifest(vec![w]);
    assert!(!m.is_well_formed());
    assert!(CoverManifest::from_json(&m.to_json()).is_none());
    let dir = Dir::new();
    assert!(write(&dir.0, &m).is_err());
    assert!(!dir.0.join(MANIFEST_FILE).exists());
    // Two key windows, or two windows with one id, are not a manifest either.
    let mut two_keys = manifest(vec![window("a", 0, &[]), window("b", 1, &[])]);
    two_keys.windows[1].key = true;
    assert!(!two_keys.is_well_formed());
    assert!(!manifest(vec![window("a", 0, &[]), window("a", 1, &[])]).is_well_formed());
    let mut old = manifest(vec![window("a", 0, &[])]);
    old.version = 0;
    assert!(!old.is_well_formed());
}

#[test]
fn a_cover_is_taken_once() {
    let m = manifest(vec![window("a", 0, &["t", "u"]), window("b", 1, &[])]);
    let dir = store(&m);
    let path = write(&dir.0, &m).unwrap();
    assert_eq!(path, dir.0.join(MANIFEST_FILE));
    assert_eq!(take(&dir.0), Some(m.clone()));
    assert!(!path.exists());
    assert_eq!(take(&dir.0), None);
    clear_images(&dir.0, &m);
    assert!(!dir.0.join("a.png").exists() && !dir.0.join("b.png").exists());
    // An unreadable manifest is removed too, and is no cover.
    fs::write(dir.0.join(MANIFEST_FILE), "{not json").unwrap();
    assert_eq!(take(&dir.0), None);
    assert!(!dir.0.join(MANIFEST_FILE).exists());
}

fn reveal(style: SwapStyle) -> Reveal {
    let m =
        manifest(vec![window("a", 0, &["t1", "t2"]), window("b", 1, &["u"]), window("c", 2, &[])]);
    let dir = store(&m);
    let displays = [display()];
    let plan = cover_plan(Some(&m), &dir.0, &now(&displays, &["a", "b", "c"], T0 + 10));
    assert_eq!(plan.reason, CoverReason::Show);
    Reveal::new(style, &plan, 0)
}

fn window_step(window: &str, fade_ms: u32) -> RevealStep {
    RevealStep::Window { window: window.into(), fade_ms }
}

#[test]
fn instant_swaps_each_window_once_all_its_surfaces_are_ready() {
    let mut r = reveal(SwapStyle::Instant);
    assert_eq!(r.start(), [window_step("c", 0)]);
    assert_eq!(r.surface_ready("a", "t1", 100), []);
    assert_eq!(r.surface_ready("a", "t1", 110), [], "a repeat does nothing");
    assert_eq!(r.surface_ready("a", "nope", 110), []);
    assert_eq!(r.surface_ready("b", "u", 150), [window_step("b", 0)]);
    assert_eq!(r.surface_ready("a", "t2", 200), [window_step("a", 0)]);
    assert!(r.is_done());
    assert_eq!(r.next_deadline_ms(), None);
    assert_eq!(r.surface_ready("a", "t2", 300), []);
}

#[test]
fn crossfade_swaps_at_the_same_moment_with_its_fade() {
    let mut r = reveal(SwapStyle::Crossfade);
    assert_eq!(r.start(), [window_step("c", CROSSFADE_MS)]);
    assert_eq!(r.surface_ready("a", "t2", 100), []);
    assert_eq!(r.surface_ready("a", "t1", 120), [window_step("a", CROSSFADE_MS)]);
}

#[test]
fn progressive_reveals_each_surface_then_the_rest_of_the_window() {
    let mut r = reveal(SwapStyle::Progressive);
    r.start();
    let surface = |s: &str| RevealStep::Surface {
        window: "a".into(),
        surface: s.into(),
        fade_ms: PROGRESSIVE_FADE_MS,
    };
    assert_eq!(r.surface_ready("a", "t1", 100), [surface("t1")]);
    assert_eq!(r.surface_ready("a", "t2", 140), [surface("t2"), window_step("a", 0)]);
}

#[test]
fn a_mismatch_takes_that_window_now_with_a_crossfade() {
    for style in [SwapStyle::Instant, SwapStyle::Crossfade, SwapStyle::Progressive] {
        let mut r = reveal(style);
        r.start();
        assert_eq!(r.mismatch("a"), [window_step("a", CROSSFADE_MS)], "{style:?}");
        assert_eq!(r.mismatch("a"), []);
        assert_eq!(r.surface_ready("a", "t1", 10), []);
        assert!(!r.is_done(), "b still waits");
    }
}

#[test]
fn the_deadline_takes_every_cover_still_up() {
    for style in [SwapStyle::Instant, SwapStyle::Crossfade, SwapStyle::Progressive] {
        let mut r = reveal(style);
        r.start();
        r.surface_ready("b", "u", 10);
        assert_eq!(r.next_deadline_ms(), Some(REVEAL_DEADLINE_MS));
        assert_eq!(r.tick(REVEAL_DEADLINE_MS - 1), []);
        assert_eq!(r.tick(REVEAL_DEADLINE_MS), [window_step("a", CROSSFADE_MS)], "{style:?}");
        assert!(r.is_done());
        assert_eq!(r.tick(REVEAL_DEADLINE_MS + 10), []);
    }
    // A ready report that arrives after the deadline also takes what is left.
    let mut r = reveal(SwapStyle::Instant);
    r.start();
    let late = r.surface_ready("a", "t1", REVEAL_DEADLINE_MS + 5);
    assert_eq!(late, [window_step("a", CROSSFADE_MS), window_step("b", CROSSFADE_MS)]);
}

#[test]
fn the_style_byte_defaults_to_crossfade() {
    assert_eq!(SwapStyle::from_u8(0), SwapStyle::Instant);
    assert_eq!(SwapStyle::from_u8(1), SwapStyle::Crossfade);
    assert_eq!(SwapStyle::from_u8(2), SwapStyle::Progressive);
    assert_eq!(SwapStyle::from_u8(9), SwapStyle::Crossfade);
}
