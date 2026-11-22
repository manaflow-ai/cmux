//! A value the person's own settings file already holds that this build does
//! not take (one an older build wrote, or a typo) is theirs: the app loads it
//! as the row's default and says so on the row. It never stops a preview,
//! an apply, a try-on or a library change that leaves it alone, it stays in
//! the file as written, and status still reports it.
//!
//! Seen on a real nightly (ask-180d77061a): the person's file held
//! `"workspaceColors.indicatorStyle": "solidFill"`, and every
//! `cmux customize use` was refused until that value was changed by hand.
//! That legacy spelling is now accepted. These tests use an unsupported
//! sentinel to keep covering preservation of other stale values.

use std::fs;
use std::path::PathBuf;

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Error, Roots};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new(settings: &str) -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        home.write("cmux-next.json", settings);
        home
    }

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

    fn settings(&self) -> String {
        fs::read_to_string(self.config("cmux-next.json")).unwrap()
    }
}

/// One deliberately unsupported value beside accepted settings.
/// Nested, as the settings reader reads it.
const STALE: &str = "{\n  \"workspaceColors\": { \"indicatorStyle\": \"__unsupported_indicator__\" },\n  \"sidebar\": { \"density\": \"expanded\" }\n}\n";

fn profile(path: &str) -> Profile {
    let home = Home::new("{}\n");
    let file = home.dir.path().join(path);
    fs::write(
        &file,
        r#"{"cmuxProfile":1,"name":"night","description":"a dark one",
            "settings":{"appearance.density":"compact","appearance.themeFile":"night"},
            "files":{"themes/night.json":"{ \"name\": \"night\" }\n"}}"#,
    )
    .unwrap();
    home.customize().load_profile(file.to_str().unwrap()).unwrap()
}

fn stale_is_reported(customize: &Customize) {
    let problems = customize.status().unwrap().problems;
    let lines: Vec<String> = problems.iter().map(|problem| problem.line()).collect();
    assert!(
        lines.iter().any(|line| line.contains("workspaceColors.indicatorStyle")),
        "status no longer reports the person's stale value: {lines:?}"
    );
    assert!(
        !lines.join("\n").contains("__unsupported_indicator__"),
        "a problem quoted the value: {lines:?}"
    );
}

#[test]
fn a_stale_value_in_the_persons_settings_never_blocks_a_profile_preview_or_apply() {
    let home = Home::new(STALE);
    let customize = home.customize();
    let profile = profile("night.profile.json");
    customize.preview_profile(&profile, "cli", 1).expect("the preview was refused");
    let live = home.settings();
    assert!(live.contains("\"compact\""), "{live}");
    assert!(
        live.contains("\"indicatorStyle\": \"__unsupported_indicator__\""),
        "rewritten: {live}"
    );
    stale_is_reported(&customize);
    let applied = customize.apply(None, "cli", 2).expect("the apply was refused");
    assert!(applied.recorded);
    assert!(home.settings().contains("\"__unsupported_indicator__\""));
    stale_is_reported(&customize);
}

#[test]
fn a_stale_value_in_the_persons_settings_never_blocks_a_try_on() {
    let home = Home::new(STALE);
    let customize = home.customize();
    let profile = profile("night.profile.json");
    customize.try_on(Some(&profile), 60_000, "cli", 1).expect("the try-on was refused");
    assert!(home.settings().contains("\"compact\""));
    assert!(home.settings().contains("\"__unsupported_indicator__\""));
}

#[test]
fn a_stale_value_in_the_persons_settings_never_blocks_a_library_change() {
    let home = Home::new(STALE);
    let customize = home.customize();
    customize.begin("make it compact", "cli", 1).unwrap();
    home.write(
        "cmux-next.json",
        &STALE.replace("\n}\n", ",\n  \"appearance\": { \"density\": \"compact\" }\n}\n"),
    );
    let name = customize
        .apply(None, "cli", 2)
        .expect("the apply was refused")
        .library
        .expect("saved to the library");
    customize.library_set_on(&name, false, "cli", 3).expect("turning it off was refused");
    let live = home.settings();
    assert!(!live.contains("\"compact\""), "{live}");
    assert!(live.contains("\"__unsupported_indicator__\""), "{live}");
}

#[test]
fn a_profile_that_brings_a_value_the_setting_does_not_take_is_still_refused() {
    // Only what the person's file already held is theirs: a change that
    // writes a refused value, even over their stale one, stops as before.
    let home = Home::new(STALE);
    let customize = home.customize();
    customize.begin("break it", "cli", 1).unwrap();
    home.write("cmux-next.json", &STALE.replace("__unsupported_indicator__", "glow"));
    let Err(Error::Invalid(problems)) = customize.apply(None, "cli", 2) else {
        panic!("a new refused value applied")
    };
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert!(problems[0].line().contains("workspaceColors.indicatorStyle"), "{problems:?}");
}

#[test]
fn a_stale_value_in_the_persons_settings_never_blocks_a_save_and_stays_out_of_the_profile() {
    let home = Home::new(
        "{\n  \"workspaceColors\": { \"indicatorStyle\": \"__unsupported_indicator__\" },\n  \"appearance\": { \"density\": \"compact\" }\n}\n",
    );
    let customize = home.customize();
    let saved = customize.save_profile("mine", "my setup", 1).expect("the save was refused");
    assert!(
        saved.left_out.iter().any(|line| line.contains("workspaceColors.indicatorStyle")),
        "{:?}",
        saved.left_out
    );
    let text = fs::read_to_string(&saved.path).unwrap();
    assert!(!text.contains("__unsupported_indicator__"), "{text}");
    assert!(text.contains("compact"), "{text}");
    // The saved profile is one someone else can use.
    let theirs = Home::new("{}\n");
    let theirs_customize = theirs.customize();
    let profile = theirs_customize.load_profile(saved.path.to_str().unwrap()).unwrap();
    theirs_customize.preview_profile(&profile, "cli", 2).expect("the saved profile was refused");
}

#[test]
fn a_refused_value_written_during_an_open_preview_stops_a_try_on_before_it_writes() {
    // With a preview open its edits are not the person's yet: the apply
    // would refuse that value, so the preview refuses first and writes
    // nothing, never a preview its own apply then refuses.
    let home = Home::new("{}\n");
    let customize = home.customize();
    customize.begin("tweak", "cli", 1).unwrap();
    home.write("cmux-next.json", STALE);
    let profile = profile("night.profile.json");
    let Err(Error::Invalid(problems)) = customize.try_on(Some(&profile), 60_000, "cli", 2) else {
        panic!("tried on")
    };
    assert!(problems[0].line().contains("workspaceColors.indicatorStyle"), "{problems:?}");
    assert!(!home.config("themes/night.json").exists());
    assert!(!home.settings().contains("\"compact\""));
}
