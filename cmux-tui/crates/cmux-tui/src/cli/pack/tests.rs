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

/// `use --watch` after the history moved (another pack applied since): the
/// reload is a new step under a new name and reads the setting fresh, so
/// the caller's `settings` call picks the new file instead of leaving the
/// setting on the other pack.
#[test]
fn a_watch_reload_after_the_history_moved_picks_its_new_file() {
    let root = tempfile::tempdir().unwrap();
    let config_dir = root.path().join("config");
    std::fs::create_dir_all(&config_dir).unwrap();
    let paths =
        Paths { settings: config_dir.join("cmux-next.json"), config_dir: config_dir.clone() };
    let pack = |name: &str| {
        let dir = root.path().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = json!({
            "cmuxPack": 1, "id": format!("cmux/{name}"), "capabilities": ["motion"],
            "look": { "ui.animationSpeed": "fast" }
        });
        std::fs::write(dir.join("cmux-pack.json"), manifest.to_string()).unwrap();
        dir
    };
    let (a, b) = (pack("a"), pack("b"));
    let base = json!({});
    let domains = Domains::default();
    let context = Context { schema: Schema::embedded(), domains: &domains, base: &base };
    let store = Store::new(&config_dir);
    store.apply(&a, None, false, &context).unwrap();
    let (_, step) = store.apply(&b, None, false, &context).unwrap();
    let theme_b = step_theme(&step).unwrap().to_string();
    std::fs::write(&paths.settings, json!({ "appearance": { "themeFile": theme_b } }).to_string())
        .unwrap();

    let (_, step, in_use) = reload(&a, &paths, &context, |_, _| Ok(())).unwrap();
    assert_eq!(in_use.as_deref(), Some(theme_b.as_str()), "the setting is read fresh");
    let theme_a = step_theme(&step).unwrap();
    assert!(theme_a.starts_with("pack-cmux-a-"), "{theme_a}");
    assert_ne!(in_use.as_deref(), Some(theme_a), "the reload needs a settings write");
    assert_eq!(step_settings_args(&step), ["set", "appearance.themeFile", theme_a]);
}

/// A `--watch` reload whose settings write fails keeps the history where it
/// was: the store saves the moved history only after the pick succeeds.
#[test]
fn a_watch_reload_whose_pick_fails_keeps_the_history() {
    let root = tempfile::tempdir().unwrap();
    let config_dir = root.path().join("config");
    std::fs::create_dir_all(&config_dir).unwrap();
    let paths =
        Paths { settings: config_dir.join("cmux-next.json"), config_dir: config_dir.clone() };
    let pack = |name: &str| {
        let dir = root.path().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = json!({
            "cmuxPack": 1, "id": format!("cmux/{name}"), "capabilities": ["motion"],
            "look": { "ui.animationSpeed": "fast" }
        });
        std::fs::write(dir.join("cmux-pack.json"), manifest.to_string()).unwrap();
        dir
    };
    let (a, b) = (pack("a"), pack("b"));
    let base = json!({});
    let domains = Domains::default();
    let context = Context { schema: Schema::embedded(), domains: &domains, base: &base };
    let store = Store::new(&config_dir);
    let (_, step) = store.apply(&b, None, false, &context).unwrap();
    let theme_b = step_theme(&step).unwrap().to_string();
    std::fs::write(&paths.settings, json!({ "appearance": { "themeFile": theme_b } }).to_string())
        .unwrap();
    let before = store.history();

    assert!(matches!(reload(&a, &paths, &context, |_, _| Err(1)), Err(StoreError::NotPicked(1))));
    let after = store.history();
    assert_eq!((after.cursor, &after.generations), (before.cursor, &before.generations));
}

/// `bench` works in a fresh private folder: a new random name each run,
/// never the predictable `cmux-pack-bench-PID`, and removed as it drops.
#[test]
fn bench_scratch_folders_are_fresh_and_private() {
    let (one, two) = (scratch_dir().unwrap(), scratch_dir().unwrap());
    assert_ne!(one.path(), two.path());
    let predictable = std::env::temp_dir().join(format!("cmux-pack-bench-{}", std::process::id()));
    assert_ne!(one.path(), predictable.as_path());
    assert_eq!(std::fs::read_dir(one.path()).unwrap().count(), 0);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(one.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "the scratch folder is open to others: {mode:o}");
    }
    let path = one.path().to_path_buf();
    drop(one);
    assert!(!path.exists(), "the scratch folder stayed");
}
