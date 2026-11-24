//! Settings recovery for every writer: the owner records each published
//! change in `<state_dir>/settings-history.jsonl`, and `settings.undo`,
//! `settings.restore` and `settings.reset_group` get a person or an agent
//! back, whoever made the change (the Settings page, the palette, the CLI,
//! MCP agents, a hand edit of the file).

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use cmux_config::history::{HISTORY_CAPACITY, history_file_name, last_text_file_name};
use cmux_config::managed::FixedManagedReader;
use cmux_config::{ConfigStore, ManagedPreferences, Op, Origin, Refusal, Target, WriteMeta};
use serde_json::{Value, json};

/// A folder of this test's own, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("cmux-history-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn config(&self) -> PathBuf {
        self.0.join("cmux-next.json")
    }

    fn state_dir(&self) -> PathBuf {
        self.0.join("state")
    }

    /// The history file of this scratch's settings file.
    fn history_file(&self) -> PathBuf {
        self.state_dir().join(history_file_name(&self.config()))
    }

    fn text(&self) -> String {
        fs::read_to_string(self.config()).unwrap_or_default()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn open(scratch: &Scratch) -> ConfigStore {
    open_with(scratch, ManagedPreferences::default())
}

fn open_with(scratch: &Scratch, managed: ManagedPreferences) -> ConfigStore {
    ConfigStore::open(
        scratch.config(),
        None,
        Some(scratch.state_dir()),
        Box::new(FixedManagedReader(managed)),
    )
}

fn meta(origin: Origin) -> WriteMeta {
    WriteMeta { origin, ..WriteMeta::default() }
}

fn set(store: &mut ConfigStore, key: &str, value: Value, origin: Origin) -> u64 {
    let op = Op::Set { target: Target::Key(key.to_string()), value, meta: meta(origin) };
    store.apply(op).result.expect("the set applies").revision
}

fn run(store: &mut ConfigStore, op: Op) -> Result<cmux_config::Outcome, Refusal> {
    store.apply(op).result
}

fn undo(store: &mut ConfigStore, origin: Origin) -> Result<cmux_config::Outcome, Refusal> {
    run(store, Op::Undo { meta: meta(origin) })
}

fn file(scratch: &Scratch) -> Value {
    serde_json::from_str(&scratch.text()).unwrap_or(Value::Null)
}

/// A CLI `settings set` then `settings undo`: the file is its text before the set,
/// byte for byte, and both changes are in the history.
#[test]
fn a_cli_set_then_undo_restores_the_file_text() {
    let scratch = Scratch::new("cli-undo");
    let original = "{\n  // my editor\n  \"editor\": {\"tabSize\": 2}\n}\n";
    fs::write(scratch.config(), original).unwrap();
    let mut store = open(&scratch);
    let set_revision = set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);
    assert_ne!(scratch.text(), original);

    let undone = undo(&mut store, Origin::Cli).expect("the undo applies");
    assert_eq!(scratch.text(), original, "undo restores the text before the set");
    assert_eq!(undone.revision, set_revision + 1, "an undo is a write of its own");
    assert!(undone.keys.iter().any(|key| key == "editor.wordWrap"), "{:?}", undone.keys);

    let history = store.history();
    assert_eq!(history.len(), 2, "{history:?}");
    let newest = &history[0];
    assert_eq!(newest.revision, undone.revision);
    assert_eq!(newest.undoes, Some(set_revision));
    assert_eq!(newest.origin, "cli");
    let set_entry = &history[1];
    assert_eq!(set_entry.revision, set_revision);
    assert_eq!(set_entry.before, original);
    assert_eq!(set_entry.keys, vec!["editor.wordWrap".to_string()]);
    assert!(set_entry.at > 0);
    assert!(scratch.history_file().exists());
}

/// Three changes, then undo twice: each undo walks back one change; a third
/// undo after a new change undoes the new change first.
#[test]
fn repeated_undo_walks_back_one_change_at_a_time() {
    let scratch = Scratch::new("walk");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_first = scratch.text();
    set(&mut store, "editor.wordWrap", json!("on"), Origin::User);
    let after_second = scratch.text();
    set(&mut store, "editor.lineNumbers", json!("off"), Origin::Mcp);

    undo(&mut store, Origin::Cli).expect("the first undo applies");
    assert_eq!(scratch.text(), after_second);
    undo(&mut store, Origin::Cli).expect("the second undo applies");
    assert_eq!(scratch.text(), after_first);

    set(&mut store, "editor.folding", json!(false), Origin::Cli);
    undo(&mut store, Origin::Cli).expect("the new change is undone first");
    assert_eq!(scratch.text(), after_first);
    undo(&mut store, Origin::Cli).expect("then the first change");
    assert_eq!(file(&scratch).pointer("/editor/tabSize"), None, "{}", scratch.text());

    let refused = undo(&mut store, Origin::Cli);
    assert!(matches!(refused, Err(Refusal::InvalidParams { .. })), "nothing to undo: {refused:?}");
}

/// `settings.restore REV`: the file becomes the text just before that change,
/// in one write that is itself recorded, so an undo takes the restore back.
#[test]
fn restore_returns_to_the_setup_before_a_revision_and_can_be_undone() {
    let scratch = Scratch::new("restore");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let before_second = scratch.text();
    let second = set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);
    set(&mut store, "editor.lineNumbers", json!("off"), Origin::Cli);
    let latest = scratch.text();

    let restored = run(&mut store, Op::Restore { revision: second, meta: meta(Origin::Cli) })
        .expect("restore");
    assert_eq!(scratch.text(), before_second);
    assert_eq!(store.history()[0].revision, restored.revision);
    assert_eq!(store.history()[0].undoes, None, "a restore is not an undo");

    undo(&mut store, Origin::Cli).expect("the restore is undone");
    assert_eq!(scratch.text(), latest);

    let unknown = run(&mut store, Op::Restore { revision: 9999, meta: meta(Origin::Cli) });
    assert!(matches!(unknown, Err(Refusal::InvalidParams { .. })), "{unknown:?}");
}

/// A hand edit of the file (found by `reload`, the watcher's path) is in the
/// history with origin `file`, and an undo puts the text back.
#[test]
fn a_hand_edit_is_recorded_and_can_be_undone() {
    let scratch = Scratch::new("hand");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let before_edit = scratch.text();
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 8}}\n").unwrap();
    let change = store.reload().expect("the hand edit is a change");

    let history = store.history();
    assert_eq!(history[0].revision, change.revision);
    assert_eq!(history[0].origin, "file");
    assert_eq!(history[0].before, before_edit);

    undo(&mut store, Origin::Cli).expect("the hand edit is undone");
    assert_eq!(scratch.text(), before_edit);
}

/// A hand edit the write-time refresh finds (the watcher has not reported
/// it yet) is recorded before the write that follows it.
#[test]
fn a_hand_edit_found_by_the_write_refresh_is_recorded() {
    let scratch = Scratch::new("refresh");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let before_edit = scratch.text();
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 8}}\n").unwrap();
    set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);

    let history = store.history();
    assert_eq!(history.len(), 3, "{history:?}");
    assert_eq!(history[1].origin, "file");
    assert_eq!(history[1].before, before_edit);
    assert_eq!(history[0].before, "{\"editor\": {\"tabSize\": 8}}\n");
}

/// `settings.reset_group`: every row of the group (or the whole section)
/// goes back to its default in one revision; rows of other groups stay.
#[test]
fn reset_group_resets_only_that_groups_rows() {
    let scratch = Scratch::new("group");
    fs::write(
        scratch.config(),
        r#"{"editor": {"tabSize": 2, "insertSpaces": false, "wordWrap": "on", "lineNumbers": "off"}, "custom": 1}"#,
    )
    .unwrap();
    let mut store = open(&scratch);
    let before = store.state().revision();

    let outcome = run(
        &mut store,
        Op::ResetGroup { group: "editor.editorText".to_string(), meta: meta(Origin::Cli) },
    )
    .expect("the group resets");
    assert_eq!(outcome.revision, before + 1, "one revision");
    let root = file(&scratch);
    assert_eq!(root.pointer("/editor/tabSize"), None, "{root}");
    assert_eq!(root.pointer("/editor/insertSpaces"), None, "{root}");
    assert_eq!(root.pointer("/editor/wordWrap"), None, "{root}");
    assert_eq!(root.pointer("/editor/lineNumbers"), Some(&json!("off")), "another group stays");
    assert_eq!(root.pointer("/custom"), Some(&json!(1)), "keys the schema does not know stay");
    assert_eq!(store.history().len(), 1, "one history entry");

    let section =
        run(&mut store, Op::ResetGroup { group: "editor".to_string(), meta: meta(Origin::Cli) })
            .expect("a section resets");
    assert_eq!(file(&scratch).pointer("/editor"), None, "{}", scratch.text());
    assert_eq!(section.revision, outcome.revision + 1);

    let unknown =
        run(&mut store, Op::ResetGroup { group: "nope".to_string(), meta: meta(Origin::Cli) });
    match unknown {
        Err(Refusal::InvalidParams { message }) => {
            assert!(message.contains("editor.editorText"), "lists the groups: {message}");
            assert!(message.contains("appearance"), "lists the sections: {message}");
        }
        other => panic!("unknown group: {other:?}"),
    }
}

/// A managed key stays managed: reset_group leaves its file value alone, and
/// a restore may change its file value while the managed value still wins.
#[test]
fn managed_keys_still_win_after_reset_group_and_restore() {
    let scratch = Scratch::new("managed");
    fs::write(scratch.config(), r#"{"editor": {"tabSize": 2, "wordWrap": "on"}}"#).unwrap();
    let mut forced = BTreeMap::new();
    forced.insert("editor.tabSize".to_string(), json!(6));
    let managed = ManagedPreferences { forced, recommended: BTreeMap::new() };
    let mut store = open_with(&scratch, managed);

    run(
        &mut store,
        Op::ResetGroup { group: "editor.editorText".to_string(), meta: meta(Origin::User) },
    )
    .expect("the group resets");
    let root = file(&scratch);
    assert_eq!(root.pointer("/editor/tabSize"), Some(&json!(2)), "a managed key is left: {root}");
    assert_eq!(root.pointer("/editor/wordWrap"), None, "{root}");

    undo(&mut store, Origin::User).expect("the reset is undone");
    assert_eq!(file(&scratch).pointer("/editor/wordWrap"), Some(&json!("on")));
    assert_eq!(store.state().effective().root.pointer("/editor/tabSize"), Some(&json!(6)));
}

/// Origin `mcp` may undo or restore only agent-settable rows: a restore whose
/// change touches a user-only row is refused and writes nothing; the person
/// may.
#[test]
fn an_agent_may_not_restore_a_user_only_row() {
    let scratch = Scratch::new("agent");
    let mut store = open(&scratch);
    set(&mut store, "history.terminalCommands", json!(true), Origin::User);
    let after_user = scratch.text();

    let refused = undo(&mut store, Origin::Mcp);
    assert!(
        matches!(refused, Err(Refusal::AgentRefused { ref key, .. }) if key == "history.terminalCommands"),
        "{refused:?}"
    );
    assert_eq!(scratch.text(), after_user, "nothing was written");

    let group = run(
        &mut store,
        Op::ResetGroup { group: "general.history".to_string(), meta: meta(Origin::Mcp) },
    );
    assert!(matches!(group, Err(Refusal::AgentRefused { .. })), "{group:?}");

    set(&mut store, "editor.tabSize", json!(2), Origin::Mcp);
    undo(&mut store, Origin::Mcp).expect("an agent undoes an agent-settable change");
    assert_eq!(scratch.text(), after_user);

    undo(&mut store, Origin::User).expect("the person undoes the user-only change");
    assert_eq!(file(&scratch).pointer("/history/terminalCommands"), None);
}

/// A file the user left broken is never rewritten, by an undo either.
#[test]
fn undo_refuses_an_unreadable_file() {
    let scratch = Scratch::new("broken");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    fs::write(scratch.config(), "{\"editor\": ").unwrap();
    store.reload();
    let refused = undo(&mut store, Origin::User);
    assert!(matches!(refused, Err(Refusal::FileUnreadable { .. })), "{refused:?}");
    assert_eq!(scratch.text(), "{\"editor\": ");
}

/// An idempotent retry of an undo replays its outcome: it does not undo twice.
#[test]
fn an_undo_retry_with_the_same_idempotency_key_replays() {
    let scratch = Scratch::new("replay");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_first = scratch.text();
    set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);
    let keyed = || WriteMeta {
        origin: Origin::Cli,
        idempotency_key: Some("undo-1".to_string()),
        if_revision: None,
    };
    let first = run(&mut store, Op::Undo { meta: keyed() }).expect("undo");
    let again = run(&mut store, Op::Undo { meta: keyed() }).expect("replay");
    assert!(again.replayed);
    assert_eq!(again.revision, first.revision);
    assert_eq!(scratch.text(), after_first);
}

/// The history keeps the newest `HISTORY_CAPACITY` entries, newest first.
#[test]
fn the_history_keeps_the_newest_entries() {
    let scratch = Scratch::new("bounded");
    let mut store = open(&scratch);
    let mut last = 0;
    // Past twice the capacity: the file is rewritten to the newest entries once.
    for index in 0..(HISTORY_CAPACITY * 2 + 30) {
        // 2..=8 in turn: each value differs from the one before, so each set is a change.
        last = set(&mut store, "editor.tabSize", json!(2 + (index % 7) as u64), Origin::Cli);
    }
    let history = store.history();
    assert_eq!(history.len(), HISTORY_CAPACITY);
    assert_eq!(history[0].revision, last);
    assert!(history.windows(2).all(|pair| pair[0].revision > pair[1].revision));
    let lines = fs::read_to_string(scratch.history_file()).unwrap().lines().count();
    assert!(lines < HISTORY_CAPACITY * 2, "the file was trimmed: {lines} lines");
    // A fresh owner reads the same history from the file.
    drop(store);
    let reopened = open(&scratch);
    assert_eq!(reopened.history().len(), HISTORY_CAPACITY);
    assert_eq!(reopened.history()[0].revision, last);
}

/// No state directory: no history, and undo has nothing to undo.
#[test]
fn without_a_state_dir_there_is_no_history() {
    let scratch = Scratch::new("stateless");
    let mut store =
        ConfigStore::open(scratch.config(), None, None, Box::new(FixedManagedReader::default()));
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    assert!(store.history().is_empty());
    assert!(matches!(undo(&mut store, Origin::Cli), Err(Refusal::InvalidParams { .. })));
}

/// A hand edit that passes through a file that does not parse (an editor
/// saving mid-typing): the undo takes back only that edit, not the CLI set
/// before it too.
#[test]
fn a_hand_edit_through_a_broken_file_undoes_alone() {
    let scratch = Scratch::new("broken-mid");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_set = scratch.text();
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 2, \"wordWrap\": ").unwrap();
    store.reload();
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 2, \"wordWrap\": \"on\"}}\n").unwrap();
    store.reload().expect("the edit out of the broken file is a change");

    undo(&mut store, Origin::Cli).expect("the hand edit is undone");
    assert_eq!(scratch.text(), after_set, "the CLI set stays");
}

/// An edit made while no owner ran is recorded when the next owner opens,
/// so undo takes back that edit alone; its revision is new.
#[test]
fn an_edit_while_no_owner_ran_is_caught_up_at_open() {
    let scratch = Scratch::new("offline");
    let mut store = open(&scratch);
    let set_revision = set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_set = scratch.text();
    drop(store);
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 2, \"wordWrap\": \"on\"}}\n").unwrap();

    let mut store = open(&scratch);
    let history = store.history();
    assert_eq!(history[0].origin, "file", "{history:?}");
    assert_eq!(history[0].before, after_set);
    assert!(history[0].revision > set_revision, "{history:?}");

    undo(&mut store, Origin::Cli).expect("the offline edit is undone");
    assert_eq!(scratch.text(), after_set, "the CLI set stays");
}

/// A lost cold-start cache does not restart revisions under the history's:
/// the next change gets a revision no entry names yet.
#[test]
fn revisions_continue_past_the_history_without_the_cache() {
    let scratch = Scratch::new("lost-cache");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let newest = set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);
    drop(store);
    let _ = fs::remove_file(cmux_config::location::cache_path(&scratch.state_dir()));

    let mut store = open(&scratch);
    let next = set(&mut store, "editor.lineNumbers", json!("off"), Origin::Cli);
    assert!(next > newest, "{next} after {newest}");
}

/// The history holds whole settings texts: only its owner reads it.
#[cfg(unix)]
#[test]
fn the_history_files_are_private() {
    use std::os::unix::fs::PermissionsExt as _;
    let scratch = Scratch::new("private");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    for name in [history_file_name(&scratch.config()), last_text_file_name(&scratch.config())] {
        let mode = fs::metadata(scratch.state_dir().join(&name)).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "{name}: {mode:o}");
    }
}

/// A hand edit that changes only the text (a comment) is a change of its
/// own: undo takes back the comment, not the set before it too.
#[test]
fn a_comment_only_hand_edit_undoes_alone() {
    let scratch = Scratch::new("comment-only");
    let mut store = open(&scratch);
    let set_revision = set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_set = scratch.text();
    fs::write(scratch.config(), format!("// mine\n{after_set}")).unwrap();
    let change = store.reload().expect("a text-only edit is a change");
    assert!(change.keys.is_empty(), "{change:?}");
    assert!(change.revision > set_revision, "{change:?}");

    undo(&mut store, Origin::Cli).expect("the comment is undone");
    assert_eq!(scratch.text(), after_set, "the CLI set stays");
}

/// The write-time refresh records a comment-only edit the watcher has not
/// reported yet, too.
#[test]
fn a_comment_only_edit_found_at_write_time_is_recorded() {
    let scratch = Scratch::new("comment-write");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_set = scratch.text();
    let commented = format!("// mine\n{after_set}");
    fs::write(scratch.config(), &commented).unwrap();
    set(&mut store, "editor.wordWrap", json!("on"), Origin::Cli);

    undo(&mut store, Origin::Cli).expect("the second set is undone");
    assert_eq!(scratch.text(), commented);
    undo(&mut store, Origin::Cli).expect("then the comment");
    assert_eq!(scratch.text(), after_set);
}

/// An owner that starts while the file does not parse records the change
/// out of it against the text saved last: undo takes back only that edit.
#[test]
fn a_restart_on_a_broken_file_keeps_undo_to_one_change() {
    let scratch = Scratch::new("broken-restart");
    let mut store = open(&scratch);
    set(&mut store, "editor.tabSize", json!(2), Origin::Cli);
    let after_set = scratch.text();
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 2, \"wordWrap\": ").unwrap();
    store.reload();
    drop(store);

    let mut store = open(&scratch);
    fs::write(scratch.config(), "{\"editor\": {\"tabSize\": 2, \"wordWrap\": \"on\"}}\n").unwrap();
    store.reload().expect("the edit out of the broken file is a change");
    undo(&mut store, Origin::Cli).expect("the hand edit is undone");
    assert_eq!(scratch.text(), after_set, "the CLI set stays");
}

/// One state directory, two settings files: an owner on the second sees
/// none of the first's history, so it never writes the first's texts over
/// its own file.
#[test]
fn another_settings_file_does_not_share_the_history() {
    let scratch = Scratch::new("two-files");
    let mut first = open(&scratch);
    set(&mut first, "editor.tabSize", json!(2), Origin::Cli);
    drop(first);

    let other = scratch.0.join("other.json");
    fs::write(&other, "{\"editor\": {\"wordWrap\": \"on\"}}\n").unwrap();
    let mut second = ConfigStore::open(
        other.clone(),
        None,
        Some(scratch.state_dir()),
        Box::new(FixedManagedReader::default()),
    );
    assert!(second.history().is_empty(), "{:?}", second.history());
    assert!(matches!(undo(&mut second, Origin::Cli), Err(Refusal::InvalidParams { .. })));
    assert_eq!(fs::read_to_string(&other).unwrap(), "{\"editor\": {\"wordWrap\": \"on\"}}\n");

    drop(second);
    let mut first = open(&scratch);
    assert_eq!(first.history().len(), 1, "the first file keeps its history");
    undo(&mut first, Origin::Cli).expect("the first file's set is undone");
}

/// Undo of a background switch writes the saved text back as it was: no
/// `appearance.backgroundRecents` entry is added on the way.
#[test]
fn undo_of_a_background_switch_restores_the_text_exactly() {
    let scratch = Scratch::new("background-undo");
    fs::write(scratch.config(), "{}\n").unwrap();
    let mut store = open(&scratch);
    set(&mut store, "appearance.background", json!("daily"), Origin::User);
    let after_switch = scratch.text();
    assert_ne!(after_switch, "{}\n");

    undo(&mut store, Origin::User).expect("the switch is undone");
    assert_eq!(scratch.text(), "{}\n");
    let history = store.history();
    run(&mut store, Op::Restore { revision: history[0].revision, meta: meta(Origin::User) })
        .expect("the restore applies");
    assert_eq!(scratch.text(), after_switch, "restore writes the saved text back as it was");
}
