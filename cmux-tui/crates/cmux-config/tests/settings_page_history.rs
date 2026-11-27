//! The Settings page's Undo, Redo and Reset <card> on the durable settings
//! history. The page reaches the owner only through its host (the app's
//! SettingsController), which writes with origin `app`, the person: so the
//! page's undo takes back a user-only row, which a CLI or agent undo may not.
//! Redo is a `settings.restore` of the undo's own revision (its entry's
//! `before` is the file just before the undo), and a card's reset is one
//! history entry whichever way it is written (`settings.reset_group`, or one
//! `settings.edit` of resets).

use std::fs;
use std::path::PathBuf;

use cmux_config::managed::FixedManagedReader;
use cmux_config::{
    ConfigStore, Edit, EditKind, ManagedPreferences, Op, Origin, Outcome, Refusal, Target,
    WriteMeta,
};
use serde_json::{Value, json};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("cmux-page-history-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn config(&self) -> PathBuf {
        self.0.join("cmux-next.json")
    }

    fn text(&self) -> String {
        fs::read_to_string(self.config()).unwrap_or_default()
    }

    fn file(&self) -> Value {
        serde_json::from_str(&self.text()).unwrap_or(Value::Null)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn open(scratch: &Scratch) -> ConfigStore {
    ConfigStore::open(
        scratch.config(),
        None,
        Some(scratch.0.join("state")),
        Box::new(FixedManagedReader(ManagedPreferences::default())),
    )
}

fn meta(origin: Origin) -> WriteMeta {
    WriteMeta { origin, ..WriteMeta::default() }
}

fn set(store: &mut ConfigStore, key: &str, value: Value, origin: Origin) -> u64 {
    let op = Op::Set { target: Target::Key(key.to_string()), value, meta: meta(origin) };
    store.apply(op).result.expect("the set applies").revision
}

fn undo(store: &mut ConfigStore, origin: Origin) -> Result<Outcome, Refusal> {
    store.apply(Op::Undo { meta: meta(origin) }).result
}

fn restore(store: &mut ConfigStore, revision: u64) -> Result<Outcome, Refusal> {
    store.apply(Op::Restore { revision, meta: meta(Origin::App) }).result
}

/// The page's host writes as the app: its undo takes back the person's
/// change of a user-only row; the same undo from the CLI is refused.
#[test]
fn the_pages_undo_through_the_host_takes_back_a_user_only_row() {
    let scratch = Scratch::new("app-undo");
    let mut store = open(&scratch);
    set(&mut store, "history.terminalCommands", json!(true), Origin::App);
    assert_eq!(scratch.file().pointer("/history/terminalCommands"), Some(&json!(true)));

    let cli = undo(&mut store, Origin::Cli);
    assert!(matches!(cli, Err(Refusal::AgentRefused { .. })), "the CLI may not: {cli:?}");

    let undone = undo(&mut store, Origin::App).expect("the page's undo applies");
    assert_eq!(scratch.file().pointer("/history/terminalCommands"), None);
    let newest = &store.history()[0];
    assert_eq!(newest.revision, undone.revision);
    assert_eq!(newest.origin, "app");
    assert!(newest.undoes.is_some());
}

/// Redo after two undos: each redo is a restore of an undo's revision, back
/// to the file just before that undo; the redone change is undoable again.
#[test]
fn redo_restores_the_revision_of_an_undo() {
    let scratch = Scratch::new("redo");
    let mut store = open(&scratch);
    set(&mut store, "appearance.backgroundOpacity", json!(0.5), Origin::App);
    let after_first = scratch.text();
    set(&mut store, "appearance.background", json!("daily"), Origin::App);
    let after_second = scratch.text();

    let first_undo = undo(&mut store, Origin::App).expect("undo the background").revision;
    assert_eq!(scratch.text(), after_first);
    let second_undo = undo(&mut store, Origin::App).expect("undo the opacity").revision;
    assert_eq!(scratch.file().pointer("/appearance"), None, "{}", scratch.text());

    restore(&mut store, second_undo).expect("redo the opacity");
    assert_eq!(scratch.text(), after_first);
    let redone = restore(&mut store, first_undo).expect("redo the background").revision;
    assert_eq!(scratch.text(), after_second);
    assert_eq!(store.history()[0].revision, redone);

    // The redo is the newest change: the next undo takes it back.
    undo(&mut store, Origin::App).expect("undo the redo");
    assert_eq!(scratch.text(), after_first);
}

/// A card's reset written as one `settings.edit` of resets is one history
/// entry, so one undo brings the whole card back.
#[test]
fn a_cards_reset_in_one_edit_is_one_entry_and_one_undo() {
    let scratch = Scratch::new("card-edit");
    let mut store = open(&scratch);
    set(&mut store, "appearance.backgroundOpacity", json!(0.5), Origin::App);
    set(&mut store, "appearance.background", json!("daily"), Origin::App);
    let set_up = scratch.text();
    let entries = store.history().len();

    let edits = ["appearance.backgroundOpacity", "appearance.background"]
        .into_iter()
        .map(|key| Edit { target: Target::Key(key.to_string()), kind: EditKind::Reset })
        .collect();
    store.apply(Op::Edit { edits, meta: meta(Origin::App) }).result.expect("the reset applies");
    let file = scratch.file();
    assert_eq!(file.pointer("/appearance/backgroundOpacity"), None, "{}", scratch.text());
    assert_eq!(file.pointer("/appearance/background"), None, "{}", scratch.text());
    // The reset changed the background shown, so the one it replaced is a
    // recent one, one click back (`record_background`).
    assert_eq!(file.pointer("/appearance/backgroundRecents"), Some(&json!(["daily"])));
    assert_eq!(store.history().len(), entries + 1, "one entry for the card");

    undo(&mut store, Origin::App).expect("one undo");
    assert_eq!(scratch.text(), set_up);
}

/// `settings.reset_group` from the page's host is one entry too, and resets
/// a user-only row of the group (the person named the card).
#[test]
fn reset_group_from_the_host_is_one_entry_and_takes_user_only_rows() {
    let scratch = Scratch::new("card-group");
    let mut store = open(&scratch);
    set(&mut store, "history.terminalCommands", json!(true), Origin::App);
    let entries = store.history().len();

    store
        .apply(Op::ResetGroup { group: "general.history".to_string(), meta: meta(Origin::App) })
        .result
        .expect("the group resets");
    assert_eq!(scratch.file().pointer("/history/terminalCommands"), None);
    assert_eq!(store.history().len(), entries + 1);
}
