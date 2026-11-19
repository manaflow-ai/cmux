//! Swap, undo, redo and live edit across whole packs through the store, and
//! the load-and-swap time bound (p95 under 100 ms).

use std::path::Path;
use std::time::{Duration, Instant};

use cmux_config::domains::Domains;
use cmux_config::schema::Schema;
use cmux_config::theme_file;
use cmux_theme_pack::{Context, Step, Store, StoreError};
use serde_json::{Value, json};

fn domains() -> &'static Domains {
    static DOMAINS: std::sync::OnceLock<Domains> = std::sync::OnceLock::new();
    DOMAINS.get_or_init(Domains::default)
}

fn write_pack(dir: &Path, id: &str, opacity: f64) {
    std::fs::create_dir_all(dir).unwrap();
    let manifest = json!({
        "cmuxPack": 1,
        "id": id,
        "name": id,
        "capabilities": ["tokens", "backgrounds", "motion", "components"],
        "look": {
            "appearance.accent": "theme",
            "appearance.backgroundOpacity": opacity,
            "sidebar.sectionLook": "card"
        },
        "slots": { "chat.thinkingIndicator": "pulse" }
    });
    std::fs::write(dir.join("cmux-pack.json"), manifest.to_string()).unwrap();
}

fn compiled(config: &Path, theme: &str) -> Value {
    let text = std::fs::read_to_string(theme_file::path(config, theme)).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn theme_of(step: &Step) -> &str {
    match step {
        Step::Apply { theme, .. } => theme,
        Step::Restore(_) => panic!("expected a pack, got {step:?}"),
    }
}

#[test]
fn swap_undo_redo_and_edit_move_whole_packs() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let (a, b) = (root.path().join("a"), root.path().join("b"));
    write_pack(&a, "cmux/a", 0.25);
    write_pack(&b, "cmux/b", 0.75);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let store = Store::new(&config);

    let (_, step) = store.apply(&a, Some("harbor".into()), false, &context).unwrap();
    let first_a = theme_of(&step).to_string();
    assert!(first_a.starts_with("pack-cmux-a-"), "{first_a}");
    assert_eq!(compiled(&config, &first_a)["appearance.backgroundOpacity"], 0.25);
    let (_, step) = store.apply(&b, Some(first_a.clone()), false, &context).unwrap();
    let first_b = theme_of(&step).to_string();
    assert!(first_b.starts_with("pack-cmux-b-"), "{first_b}");

    // An edit is one step, checked like the pack's own values.
    let (_, step) = store.edit("appearance.backgroundOpacity", json!(0.5), &context).unwrap();
    assert_eq!(compiled(&config, theme_of(&step))["appearance.backgroundOpacity"], 0.5);
    // Each generation has its own file: the one before the edit keeps its look,
    // so a settings-history undo of appearance.themeFile brings that look back.
    assert_ne!(theme_of(&step), first_b);
    assert_eq!(compiled(&config, &first_b)["appearance.backgroundOpacity"], 0.75);
    // A refused edit changes nothing and costs no undo step.
    let before = store.history();
    match store.edit("agent.defaultHarness", json!("codex"), &context) {
        Err(StoreError::Refused(diagnostics)) => {
            assert!(diagnostics.iter().all(|d| d.key.as_deref() == Some("agent.defaultHarness")));
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    assert_eq!(store.history(), before);

    let step = store.undo().unwrap();
    assert_eq!(compiled(&config, theme_of(&step))["appearance.backgroundOpacity"], 0.75);
    assert_eq!(theme_of(&store.undo().unwrap()), first_a);
    assert_eq!(compiled(&config, &first_a)["appearance.backgroundOpacity"], 0.25);
    assert_eq!(store.undo().unwrap(), Step::Restore(Some("harbor".into())));
    assert!(matches!(store.undo(), Err(StoreError::NothingToUndo)));
    assert_eq!(theme_of(&store.redo().unwrap()), first_a);
    assert_eq!(theme_of(&store.redo().unwrap()), first_b);
    let step = store.redo().unwrap();
    assert_eq!(compiled(&config, theme_of(&step))["appearance.backgroundOpacity"], 0.5);

    // Off is one undoable step back to the look before any pack.
    assert_eq!(store.off().unwrap(), Step::Restore(Some("harbor".into())));
    assert!(matches!(
        store.edit("appearance.accent", json!("theme"), &context),
        Err(StoreError::NothingApplied)
    ));
    let step = store.undo().unwrap();
    assert!(theme_of(&step).starts_with("pack-cmux-b-"));
    assert_eq!(compiled(&config, theme_of(&step))["appearance.backgroundOpacity"], 0.5);
}

#[test]
fn live_edits_of_the_pack_files_replace_one_step() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let a = root.path().join("a");
    write_pack(&a, "cmux/a", 0.25);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let store = Store::new(&config);
    let (_, step) = store.apply(&a, None, false, &context).unwrap();
    let name = theme_of(&step).to_string();
    for opacity in [0.3, 0.4, 0.6] {
        write_pack(&a, "cmux/a", opacity);
        store.apply(&a, None, true, &context).unwrap();
    }
    // Live edits rewrite the one file the app is reading: no new name, no settings write.
    assert_eq!(compiled(&config, &name)["appearance.backgroundOpacity"], 0.6);
    assert_eq!(store.history().generations.len(), 1);
    let packs = std::fs::read_dir(config.join("themes")).unwrap().count();
    assert_eq!(packs, 1, "superseded pack files are pruned");
    // A save that breaks the manifest keeps the last good look.
    std::fs::write(a.join("cmux-pack.json"), "{\"cmuxPack\": 1, \"look\": {").unwrap();
    assert!(store.apply(&a, None, true, &context).is_err());
    assert_eq!(compiled(&config, &name)["appearance.backgroundOpacity"], 0.6);
    assert_eq!(store.undo().unwrap(), Step::Restore(None));
}

fn percentile(sorted: &[Duration], fraction: f64) -> Duration {
    let index = ((sorted.len() as f64 - 1.0) * fraction).round() as usize;
    sorted[index]
}

/// Loading a pack and swapping to it (read, check every value, compile,
/// write the theme file, record the generation) stays under 100 ms at p95,
/// in this test's own debug build.
#[test]
fn load_and_swap_stay_under_100_ms() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let (a, b) = (root.path().join("a"), root.path().join("b"));
    write_pack(&a, "cmux/a", 0.25);
    write_pack(&b, "cmux/b", 0.75);
    let base = json!({});
    let first = Instant::now();
    let schema = Schema::embedded();
    let schema_time = first.elapsed();
    let context = Context { schema, domains: domains(), base: &base };
    let store = Store::new(&config);
    let mut times = Vec::new();
    let mut last = String::new();
    for run in 0..100 {
        let dir = if run % 2 == 0 { &a } else { &b };
        let started = Instant::now();
        let (_, step) = store.apply(dir, None, false, &context).unwrap();
        times.push(started.elapsed());
        last = theme_of(&step).to_string();
    }
    times.sort();
    let (p50, p95) = (percentile(&times, 0.5), percentile(&times, 0.95));
    // Before packs: the same look as a hand-written theme file, read and
    // checked the way `cmux theme use` and the daemon read one.
    let text = std::fs::read_to_string(theme_file::path(&config, &last)).unwrap();
    let mut before = Vec::new();
    for _ in 0..100 {
        let started = Instant::now();
        let file = theme_file::ThemeFile::read(
            "look",
            Some(Ok(text.as_str())),
            &base,
            None,
            schema,
            domains(),
        );
        assert!(file.is_loaded);
        before.push(started.elapsed());
    }
    before.sort();
    eprintln!(
        "theme file read (before packs): p50 {:.3} ms, p95 {:.3} ms",
        percentile(&before, 0.5).as_secs_f64() * 1e3,
        percentile(&before, 0.95).as_secs_f64() * 1e3,
    );
    eprintln!(
        "pack load+swap: p50 {:.3} ms, p95 {:.3} ms, max {:.3} ms over {} runs; schema first touch {:.2} ms",
        p50.as_secs_f64() * 1e3,
        p95.as_secs_f64() * 1e3,
        times.last().unwrap().as_secs_f64() * 1e3,
        times.len(),
        schema_time.as_secs_f64() * 1e3,
    );
    assert!(p95 < Duration::from_millis(100), "p95 {p95:?} is over 100 ms");
}
