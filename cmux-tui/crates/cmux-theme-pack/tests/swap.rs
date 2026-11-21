//! Swap, undo, redo and live edit across whole packs through the store, and
//! the load-and-swap time bound (p95 under 100 ms).

use std::path::Path;
use std::time::{Duration, Instant};

use cmux_config::domains::Domains;
use cmux_config::schema::Schema;
use cmux_config::theme_file;
use cmux_theme_pack::store::MAXIMUM_WRITTEN;
use cmux_theme_pack::{Context, History, Step, Store, StoreError};
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

/// A nested edit is flattened like the manifest's `look`: a bad nested value
/// is refused (no step, nothing applied), a good one is stored and applied
/// under its dotted key, and an edit that sets nothing is refused too.
#[test]
fn nested_edits_are_checked_like_the_manifest() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let a = root.path().join("a");
    write_pack(&a, "cmux/a", 0.25);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let store = Store::new(&config);
    store.apply(&a, None, false, &context).unwrap();

    let before = store.history();
    match store.edit("sidebar", json!({ "sectionLook": "not-a-look" }), &context) {
        Err(StoreError::Refused(diagnostics)) => {
            assert!(
                diagnostics.iter().any(|d| d.key.as_deref() == Some("sidebar.sectionLook")),
                "{diagnostics:?}"
            );
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    assert_eq!(store.history(), before, "a refused nested edit costs no step");
    assert!(matches!(store.edit("sidebar", json!({}), &context), Err(StoreError::Refused(_))));
    // A system picture is no pack asset, edited or not.
    assert!(matches!(
        store.edit("appearance.background", json!("system:/Users/me/secret.png"), &context),
        Err(StoreError::Refused(_))
    ));
    assert_eq!(store.history(), before);

    let (_, step) = store.edit("ui", json!({ "animationSpeed": "fast" }), &context).unwrap();
    assert_eq!(compiled(&config, theme_of(&step))["ui.animationSpeed"], "fast");
    let history = store.history();
    let edits = &history.current().unwrap().edits;
    assert!(edits.contains_key("ui.animationSpeed") && !edits.contains_key("ui"), "{edits:?}");
}

/// Pruning deletes only files this store wrote: a theme of the person's own
/// named `pack-*` stays, and so does the file the setting picks now. A file
/// the history dropped (the redo tail) stays too: the settings history may
/// still name it, and undoing `appearance.themeFile` must find its look.
#[test]
fn prune_keeps_files_the_store_did_not_write_and_the_one_in_use() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let (a, b, c) = (root.path().join("a"), root.path().join("b"), root.path().join("c"));
    write_pack(&a, "cmux/a", 0.25);
    write_pack(&b, "cmux/b", 0.75);
    write_pack(&c, "cmux/c", 0.5);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let mine = theme_file::path(&config, "pack-mine");
    std::fs::create_dir_all(mine.parent().unwrap()).unwrap();
    std::fs::write(&mine, "{\"name\": \"mine\"}\n").unwrap();

    let store = Store::new(&config);
    let (_, step) = store.apply(&a, None, false, &context).unwrap();
    let first_a = theme_of(&step).to_string();
    store.undo().unwrap();
    // The setting still picks A's file: a new pack drops A from the history
    // (the redo tail) but its file stays while it is in use.
    let store = Store::new(&config).keeping(Some(first_a.clone()));
    store.apply(&b, None, false, &context).unwrap();
    assert!(theme_file::path(&config, &first_a).exists(), "the file in use was pruned");
    assert!(mine.exists(), "a theme the store did not write was pruned");
    // Once the setting moved on, A's file still stays (the settings history
    // names it), listed as written so the bound still covers it.
    let store = Store::new(&config);
    store.apply(&c, None, false, &context).unwrap();
    assert!(theme_file::path(&config, &first_a).exists(), "a file undo may name was pruned");
    assert!(store.history().written.contains(&first_a));
    assert!(mine.exists(), "a theme the store did not write was pruned");
}

/// The written files are bounded: past `MAXIMUM_WRITTEN` the oldest go,
/// never the one the setting picks.
#[test]
fn written_files_are_bounded_but_the_one_in_use_stays() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let a = root.path().join("a");
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let mut names: Vec<String> = Vec::new();
    for index in 0..(MAXIMUM_WRITTEN + 3) {
        // A new id each run: a new file name each run.
        write_pack(&a, &format!("cmux/p{index}"), 0.25);
        // From the second run on, the setting still picks the first file.
        let store = match names.first() {
            Some(first) => Store::new(&config).keeping(Some(first.clone())),
            None => Store::new(&config),
        };
        let (_, step) = store.apply(&a, None, false, &context).unwrap();
        names.push(theme_of(&step).to_string());
    }
    let exists = |index: usize| {
        names.get(index).is_some_and(|name| theme_file::path(&config, name).exists())
    };
    assert!(exists(0), "the file in use was pruned");
    assert!(!exists(1) && !exists(2) && !exists(3), "the oldest past the bound stayed");
    assert!(exists(4) && exists(MAXIMUM_WRITTEN + 2));
    let files = std::fs::read_dir(config.join("themes")).unwrap().count();
    assert_eq!(files, MAXIMUM_WRITTEN);
    assert_eq!(Store::new(&config).history().written.len(), MAXIMUM_WRITTEN);
}

/// A theme the person picked themselves since (`cmux theme use`) is the new
/// baseline: undo, redo and off never put an older look back over it, and a
/// theme of their own named `pack-*` is taken as `before` like any other.
#[test]
fn a_theme_picked_since_is_the_new_baseline() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let (a, b) = (root.path().join("a"), root.path().join("b"));
    write_pack(&a, "cmux/a", 0.25);
    write_pack(&b, "cmux/b", 0.75);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let harbor = Some("harbor".to_string());
    let (_, step) =
        Store::new(&config).keeping(harbor.clone()).apply(&a, harbor, false, &context).unwrap();
    let first_a = theme_of(&step).to_string();
    let (_, step) = Store::new(&config)
        .keeping(Some(first_a.clone()))
        .apply(&b, Some(first_a.clone()), false, &context)
        .unwrap();
    let first_b = theme_of(&step).to_string();
    // While the setting follows the history, undo moves through it.
    let step = Store::new(&config).keeping(Some(first_b.clone())).undo().unwrap();
    assert_eq!(theme_of(&step), first_a);

    // The person picks a theme of their own, named like a pack's.
    let mine = Some("pack-mine".to_string());
    let store = Store::new(&config).keeping(mine.clone());
    assert!(matches!(store.undo(), Err(StoreError::NothingToUndo)));
    assert!(matches!(store.redo(), Err(StoreError::NothingToRedo)));
    assert!(matches!(store.off(), Err(StoreError::NothingApplied)));
    let (_, step) = store.apply(&b, mine.clone(), false, &context).unwrap();
    assert_eq!(theme_of(&step), first_b);
    let history = store.history();
    assert_eq!(history.before, mine);
    assert_eq!(history.generations.len(), 1);
    // Off goes back to the person's theme, not to harbor or to A.
    let store = Store::new(&config).keeping(Some(first_b.clone()));
    assert_eq!(store.off().unwrap(), Step::Restore(mine.clone()));
    // With the setting on it, undo brings B back.
    assert_eq!(theme_of(&Store::new(&config).keeping(mine).undo().unwrap()), first_b);
}

/// The CLI's settings write runs inside the store (`picking`), after the
/// theme file is written and before the history is saved: a failed write
/// leaves the history where it was.
#[test]
fn a_failed_pick_leaves_the_history_where_it_was() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let (a, b) = (root.path().join("a"), root.path().join("b"));
    write_pack(&a, "cmux/a", 0.25);
    write_pack(&b, "cmux/b", 0.75);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    let store = Store::new(&config);
    store.apply(&a, None, false, &context).unwrap();
    let before = store.history();

    let failing = Store::new(&config).picking(|_, _| Err(3));
    match failing.apply(&b, None, false, &context) {
        Err(StoreError::NotPicked(3)) => {}
        other => panic!("expected a failed pick, got {other:?}"),
    }
    let after = store.history();
    assert_eq!((after.cursor, &after.generations), (before.cursor, &before.generations));
    // The theme file was written first, and is listed so the bound covers it.
    let theme_b = after.written.last().cloned().unwrap();
    assert!(theme_b.starts_with("pack-cmux-b-"), "{theme_b}");
    assert!(theme_file::path(&config, &theme_b).exists());
    assert!(matches!(failing.undo(), Err(StoreError::NotPicked(3))));
    assert_eq!(store.history().cursor, before.cursor);

    // A pick that succeeds moves the history.
    let picking = Store::new(&config).picking(|_, _| Ok(()));
    picking.apply(&b, None, false, &context).unwrap();
    assert_eq!(store.history().cursor, before.cursor + 1);
}

/// The history's names become paths: on read, any that is not a plain theme
/// file name, or (for a pack's file) lacks the `pack-` prefix, is dropped.
#[test]
fn a_history_naming_paths_outside_the_themes_folder_is_dropped_on_read() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(".history.json");
    let generation =
        |theme: &str| json!({ "pack": "cmux/a", "dir": "/packs/a", "theme": theme, "text": "{}" });
    let text = json!({
        "before": "../../outside",
        "generations": [
            generation("../../../etc/evil"),
            generation("pack-cmux-a-1"),
            generation("harbor"),
            generation(""),
        ],
        "cursor": 3,
        "written": ["../../../home/me/.zshrc", "pack-ok", "notes", "pack-../x", "/abs"],
    });
    std::fs::write(&path, text.to_string()).unwrap();
    let history = History::read(&path);
    let themes: Vec<&str> = history.generations.iter().map(|g| g.theme.as_str()).collect();
    assert_eq!(themes, ["pack-cmux-a-1", ""]);
    // Two of the three applied generations were dropped; the cursor follows.
    assert_eq!(history.cursor, 1);
    assert_eq!(history.written, ["pack-ok"]);
    assert_eq!(history.before, None);
    // A theme of the person's own stays a valid `before`.
    std::fs::write(&path, json!({ "before": "harbor" }).to_string()).unwrap();
    assert_eq!(History::read(&path).before.as_deref(), Some("harbor"));
}

/// Every history change holds `packs/.history.lock` from read to write: one
/// started while another holder has it waits.
#[test]
fn a_history_change_waits_for_the_history_lock() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("config");
    let a = root.path().join("a");
    write_pack(&a, "cmux/a", 0.25);
    let base = json!({});
    let context = Context { schema: Schema::embedded(), domains: domains(), base: &base };
    Store::new(&config).apply(&a, None, false, &context).unwrap();

    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(config.join("packs").join(".history.lock"))
        .unwrap();
    lock.lock().unwrap();
    let off = {
        let config = config.clone();
        std::thread::spawn(move || Store::new(&config).off().map_err(|error| error.to_string()))
    };
    std::thread::sleep(Duration::from_millis(300));
    assert!(!off.is_finished(), "off ran without the history lock");
    assert_eq!(Store::new(&config).history().cursor, 1);
    lock.unlock().unwrap();
    assert_eq!(off.join().unwrap(), Ok(Step::Restore(None)));
    assert_eq!(Store::new(&config).history().cursor, 2);
}
