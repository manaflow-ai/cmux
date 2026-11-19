use serde_json::json;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[test]
fn verbs_parse() {
    assert_eq!(parse(&words("check ./sakura")), Ok(Request::Check { dir: "./sakura".into() }));
    assert_eq!(
        parse(&words("use sakura")),
        Ok(Request::Use { spec: "sakura".into(), watch: false })
    );
    assert_eq!(
        parse(&words("use ./sakura --watch")),
        Ok(Request::Use { spec: "./sakura".into(), watch: true })
    );
    assert_eq!(
        parse(&words("edit appearance.accent pink")),
        Ok(Request::Edit { key: "appearance.accent".into(), value: json!("pink") })
    );
    assert_eq!(
        parse(&words("edit appearance.backgroundOpacity 0.8")),
        Ok(Request::Edit { key: "appearance.backgroundOpacity".into(), value: json!(0.8) })
    );
    assert_eq!(parse(&words("undo")), Ok(Request::Undo));
    assert_eq!(parse(&words("redo")), Ok(Request::Redo));
    assert_eq!(parse(&words("off")), Ok(Request::Off));
    assert_eq!(parse(&words("history")), Ok(Request::History));
    assert_eq!(
        parse(&words("bench a b")),
        Ok(Request::Bench { dirs: vec!["a".into(), "b".into()], runs: DEFAULT_RUNS })
    );
    assert_eq!(
        parse(&words("bench a --runs 20")),
        Ok(Request::Bench { dirs: vec!["a".into()], runs: 20 })
    );
}

#[test]
fn bad_verbs_and_options_are_refused() {
    assert!(parse(&[]).is_err());
    assert!(parse(&words("check")).is_err(), "check needs DIR");
    assert!(parse(&words("use a b")).is_err());
    assert!(parse(&words("check a --watch")).is_err(), "--watch is for use");
    assert!(parse(&words("edit appearance.accent")).is_err(), "edit needs a value");
    assert!(parse(&words("undo now")).is_err());
    assert!(parse(&words("bench")).is_err(), "bench needs a pack");
    assert!(parse(&words("bench a --runs 0")).is_err());
    assert!(parse(&words("bench a --runs many")).is_err());
    assert!(parse(&words("bench a --runs")).is_err());
    assert!(parse(&words("install a")).is_err());
}

#[test]
fn a_step_picks_its_theme_file_or_unsets_it() {
    let apply = Step::Apply { theme: "pack-leo-sakura".into(), text: "{}".into() };
    assert_eq!(step_settings_args(&apply), ["set", "appearance.themeFile", "pack-leo-sakura"]);
    let before = Step::Restore(Some("harbor".into()));
    assert_eq!(step_settings_args(&before), ["set", "appearance.themeFile", "harbor"]);
    // As `cmux theme reset` with no key: back to the stock look.
    assert_eq!(step_settings_args(&Step::Restore(None)), ["reset", "appearance.themeFile"]);
    assert_eq!(step_theme(&Step::Restore(None)), None);
    assert_eq!(step_theme(&apply), Some("pack-leo-sakura"));
}

#[test]
fn no_settings_write_when_the_setting_already_picks_the_step() {
    let apply = Step::Apply { theme: "pack-leo-sakura".into(), text: "{}".into() };
    // Returns before any daemon call, so this needs no daemon.
    assert_eq!(settings(&[], Some("pack-leo-sakura"), &apply), 0);
    assert_eq!(settings(&[], None, &Step::Restore(None)), 0);
}

#[test]
fn percentiles_are_nearest_rank() {
    let samples: Vec<f64> = (1..=100).map(f64::from).collect();
    assert_eq!(percentile(&samples, 50), 50.0);
    assert_eq!(percentile(&samples, 95), 95.0);
    assert_eq!(percentile(&samples, 100), 100.0);
    assert_eq!(percentile(&[7.0], 95), 7.0);
    assert_eq!(percentile(&[], 50), 0.0);
}
