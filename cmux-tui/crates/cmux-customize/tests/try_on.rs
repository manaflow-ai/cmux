//! Try on: a customization applied for a while reverts by itself unless
//! someone keeps it, and it does so even when nothing ran at its end time
//! (the app quit, the machine slept).

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Error, Kind, Roots, Settled};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        home.write("cmux-next.json", COZY);
        home
    }

    /// A fresh `Customize` on the same folders: what a relaunched app opens.
    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }

    fn write(&self, path: &str, text: &str) {
        let file = self.config(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }

    fn read(&self, path: &str) -> Option<String> {
        fs::read_to_string(self.config(path)).ok()
    }
}

const COZY: &str = "{\n  \"appearance\": { \"density\": \"cozy\" }\n}\n";
const MINUTE: u64 = 60_000;

/// A recipe as the recipes lane writes one: a profile with extra fields.
fn night() -> Profile {
    serde_json::from_str(
        r#"{"cmuxProfile":1,"name":"night","title":"Night","ask":"make it dark","category":"look",
            "settings":{"appearance.density":"compact","appearance.themeFile":"night"},
            "files":{"themes/night.json":"{ \"name\": \"night\" }\n"}}"#,
    )
    .unwrap()
}

fn tried_on(home: &Home) -> bool {
    home.read("themes/night.json").is_some()
        && home.read("cmux-next.json").unwrap().contains("compact")
}

#[test]
fn a_try_on_reverts_by_itself_at_its_time_even_after_a_restart() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    let tried = customize.try_on(Some(&night()), 10 * MINUTE, "cli", 100).unwrap();
    assert_eq!(tried.try_on.revert_to, Some(1));
    assert_eq!(tried.try_on.expires_ms, 100 + 10 * MINUTE);
    assert_eq!(tried.applied.generation.kind, Kind::Applied);
    assert!(tried_on(&home));
    assert_eq!(customize.status().unwrap().try_on.as_ref(), Some(&tried.try_on));
    // Before its time, a look changes nothing.
    assert_eq!(customize.settle(100 + 5 * MINUTE).unwrap(), None);
    assert!(tried_on(&home));
    drop(customize);

    // The app quit; the first look after the end time reverts it.
    let relaunched = home.customize();
    let settled = relaunched.settle(100 + 11 * MINUTE).unwrap();
    assert!(matches!(settled, Some(Settled::Reverted { .. })), "{settled:?}");
    assert!(!tried_on(&home));
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(relaunched.generations().unwrap().current, Some(1));
    assert_eq!(relaunched.status().unwrap().try_on, None);
    // Settled once: the next look finds nothing.
    assert_eq!(relaunched.settle(100 + 12 * MINUTE).unwrap(), None);
}

#[test]
fn keep_leaves_it_applied_for_good() {
    let home = Home::new();
    let customize = home.customize();
    let tried = customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    assert!(matches!(customize.keep().unwrap(), Some(Settled::Kept { .. })));
    assert_eq!(customize.settle(100 + 60 * MINUTE).unwrap(), None);
    assert!(tried_on(&home));
    assert_eq!(customize.generations().unwrap().current, Some(tried.applied.generation.n));
    assert_eq!(customize.keep().unwrap(), None);
}

#[test]
fn revert_now_puts_it_back_and_keeps_hand_edits_by_number() {
    let home = Home::new();
    let customize = home.customize();
    customize.try_on(Some(&night()), 10 * MINUTE, "cli", 100).unwrap();
    home.write("themes/night.json", "{ \"name\": \"night, tweaked\" }\n");
    let settled = customize.revert_try_on("user", 200).unwrap();
    let Some(Settled::Reverted { restored, .. }) = settled else { panic!("{settled:?}") };
    assert!(!tried_on(&home));
    // The tweak is kept as its own generation, so a rollback brings it back.
    let kept = restored.kept_as.expect("the hand edit is kept");
    customize.rollback(Some(kept), "user", 300).unwrap();
    assert!(home.read("themes/night.json").unwrap().contains("tweaked"));
}

#[test]
fn applying_past_a_try_on_ends_it_where_it_is() {
    let home = Home::new();
    let customize = home.customize();
    customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    home.write("themes/night.json", "{ \"name\": \"night 2\" }\n");
    customize.apply(None, "user", 200).unwrap();
    assert_eq!(customize.status().unwrap().try_on, None);
    assert!(matches!(customize.settle(100 + 2 * MINUTE).unwrap(), Some(Settled::Ended { .. })));
    assert!(home.read("themes/night.json").unwrap().contains("night 2"));
}

#[test]
fn trying_again_still_reverts_to_where_you_started() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    home.write("cmux-next.json", "{\n  \"appearance\": { \"density\": \"comfortable\" }\n}\n");
    let second = customize.try_on(None, MINUTE, "cli", 200).unwrap();
    assert!(second.replaced.is_some());
    assert_eq!(second.try_on.revert_to, Some(1));
    customize.settle(200 + 2 * MINUTE).unwrap();
    assert_eq!(home.read("cmux-next.json").unwrap(), COZY);
    assert_eq!(home.read("themes/night.json"), None);
}

#[test]
fn nothing_to_try_and_a_bad_time_are_refused_and_write_nothing() {
    let home = Home::new();
    let customize = home.customize();
    assert!(matches!(customize.try_on(None, MINUTE, "cli", 1), Err(Error::NothingToTry)));
    assert!(matches!(customize.try_on(Some(&night()), 10, "cli", 1), Err(Error::TryOnTime)));
    assert!(matches!(
        customize.try_on(Some(&night()), 25 * 60 * MINUTE, "cli", 1),
        Err(Error::TryOnTime)
    ));
    assert!(!tried_on(&home));
    assert_eq!(customize.try_on_state().unwrap(), None);
}

#[test]
fn the_timer_reverts_at_the_end_time_and_stops() {
    let home = Home::new();
    let customize = home.customize();
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    customize.try_on(Some(&night()), 1_000, "cli", now).unwrap();
    let started = Instant::now();
    let settled = home.customize().run_try_on_timer().unwrap();
    assert!(started.elapsed() < Duration::from_secs(30));
    assert!(matches!(settled.as_slice(), [Settled::Reverted { .. }]), "{settled:?}");
    assert!(!tried_on(&home));
    // With nothing to wait for, it returns at once.
    assert!(home.customize().run_try_on_timer().unwrap().is_empty());
}

/// The library's entries that are on, by name.
fn library_on(customize: &Customize) -> Vec<String> {
    let listing = customize.library().unwrap();
    listing.entries.into_iter().filter(|entry| entry.on).map(|entry| entry.name).collect()
}

fn library_names(customize: &Customize) -> Vec<String> {
    customize.library().unwrap().entries.into_iter().map(|entry| entry.name).collect()
}

#[test]
fn a_try_on_that_reverts_leaves_nothing_on_in_the_library() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.try_on(Some(&night()), 10 * MINUTE, "cli", 100).unwrap();
    // While it runs it is live, and the library says so.
    assert_eq!(library_on(&customize), ["night"]);

    let settled = customize.revert_try_on("user", 200).unwrap();
    assert!(matches!(settled, Some(Settled::Reverted { .. })), "{settled:?}");
    assert!(!tried_on(&home));
    // A try-on nobody kept is not in the library: nothing there is on.
    assert!(library_on(&customize).is_empty(), "{:?}", customize.library().unwrap());
    assert!(library_names(&customize).is_empty());
}

#[test]
fn a_try_on_that_runs_out_after_a_restart_leaves_nothing_on_in_the_library() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.try_on(Some(&night()), 10 * MINUTE, "cli", 100).unwrap();
    assert_eq!(library_on(&customize), ["night"]);
    drop(customize);

    // The app quit mid-try; the first look after the end time reverts it,
    // the library with it.
    let relaunched = home.customize();
    assert!(matches!(
        relaunched.settle(100 + 11 * MINUTE).unwrap(),
        Some(Settled::Reverted { .. })
    ));
    assert!(library_on(&relaunched).is_empty(), "{:?}", relaunched.library().unwrap());
    assert!(library_names(&relaunched).is_empty());
}

#[test]
fn trying_on_an_entry_that_was_off_and_reverting_leaves_it_off_where_it_was() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    // Used once, then turned off: an entry that is off.
    customize.preview_profile(&night(), "cli", 10).unwrap();
    assert_eq!(customize.apply(None, "cli", 11).unwrap().library.as_deref(), Some("night"));
    customize.begin("roomy", "cli", 20).unwrap();
    home.write("cmux-next.json", "{\n  \"appearance\": { \"density\": \"comfortable\" }\n}\n");
    let roomy = customize.apply(None, "cli", 21).unwrap().library.expect("saved");
    customize.library_set_on("night", false, "cli", 30).unwrap();
    assert_eq!(library_on(&customize), std::slice::from_ref(&roomy));
    assert_eq!(library_names(&customize), [roomy.clone(), "night".to_owned()]);

    // Trying it again turns that entry on, on top; reverting puts it back
    // off, and the one that was on stays on.
    customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    assert_eq!(library_on(&customize)[0], "night");
    customize.revert_try_on("user", 200).unwrap();
    assert_eq!(library_on(&customize), std::slice::from_ref(&roomy));
    assert_eq!(library_names(&customize), [roomy, "night".to_owned()]);
}

#[test]
fn keep_leaves_the_library_entry_on() {
    let home = Home::new();
    let customize = home.customize();
    customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    customize.keep().unwrap();
    assert_eq!(customize.settle(100 + 60 * MINUTE).unwrap(), None);
    assert_eq!(library_on(&customize), ["night"]);
}

#[test]
fn trying_two_things_and_keeping_neither_leaves_neither_in_the_library() {
    let home = Home::new();
    let customize = home.customize();
    customize.ensure_baseline(1).unwrap();
    customize.try_on(Some(&night()), MINUTE, "cli", 100).unwrap();
    home.write("cmux-next.json", "{\n  \"appearance\": { \"density\": \"comfortable\" }\n}\n");
    customize.try_on(None, MINUTE, "cli", 200).unwrap();
    assert_eq!(library_on(&customize).len(), 2);
    customize.settle(200 + 2 * MINUTE).unwrap();
    assert!(library_names(&customize).is_empty(), "{:?}", customize.library().unwrap());
}
