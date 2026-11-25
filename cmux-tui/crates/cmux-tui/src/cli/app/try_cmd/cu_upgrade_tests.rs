//! `cmux computer-use upgrade`: the engine's hot upgrade (try_cmd/cu_upgrade.rs) on the try
//! fixtures: staging, the swap, the worker's restage and restart, and the one undo.

use std::cell::RefCell;

use super::super::cu_upgrade::{self, Host, RECEIPT, Request, Source, UNDONE};
use super::*;

/// The machine stood in for: what each restage saw in the app's helper, and the worker pids
/// `status` answers with in turn.
struct FakeHost {
    restaged: RefCell<Vec<Option<Vec<u8>>>>,
    fail_first_restage: bool,
    pids: RefCell<Vec<u64>>,
}

fn host(pids: &[u64]) -> FakeHost {
    FakeHost {
        restaged: RefCell::default(),
        fail_first_restage: false,
        pids: RefCell::new(pids.to_vec()),
    }
}

impl Host for FakeHost {
    fn restage(&self, helper: &Path) -> Result<PathBuf, String> {
        let bytes = fs::read(helper.join("Contents/MacOS").join(helper::EXECUTABLE)).ok();
        let first = self.restaged.borrow().is_empty();
        self.restaged.borrow_mut().push(bytes);
        if first && self.fail_first_restage {
            return Err("codesign refused the copy".into());
        }
        Ok(PathBuf::from("/staged/cmux-screen-sharing"))
    }
    fn worker(&self) -> Result<Value, String> {
        let mut pids = self.pids.borrow_mut();
        if pids.is_empty() {
            return Err("the daemon did not answer".into());
        }
        let pid = pids.remove(0);
        Ok(json!({ "executable": "/staged/cmux-screen-sharing", "pid": pid }))
    }
}

fn wanted(fixture: &Fixture) -> helper::WantedHelper {
    let (_, helper) = live_plan(fixture, &found_value(&payload_with_helper(helper_key())));
    helper.expect("the build carries the helper")
}

fn build() -> Value {
    json!({ "from": "nightly", "commit": COMMIT })
}

#[test]
fn computer_use_upgrade_parses_from_undo_and_dry_run() {
    let parse = |words: &[&str]| cu_upgrade::parse(words);
    let plain = |source| Request { source, undo: false, dry_run: false };
    assert_eq!(parse(&[]).unwrap(), plain(Source::Nightly));
    assert_eq!(parse(&["--from", "nightly"]).unwrap(), plain(Source::Nightly));
    assert_eq!(parse(&["--from", "#50850"]).unwrap(), plain(Source::Build("#50850".into())));
    assert_eq!(parse(&["--from=0123abc"]).unwrap(), plain(Source::Build("0123abc".into())));
    assert_eq!(
        parse(&["--undo", "--dry-run"]).unwrap(),
        Request { source: Source::Nightly, undo: true, dry_run: true }
    );
    assert!(parse(&["--undo", "--from", "nightly"]).is_err(), "--undo takes no build");
    assert!(parse(&["--from"]).is_err());
    assert!(parse(&["--force"]).is_err());
    for words in [&["--machine", "studio"][..], &["--machine=studio"][..]] {
        assert_eq!(parse(words).unwrap_err(), cu_upgrade::NOT_REMOTE, "{words:?}");
    }
}

/// A receipt that can't be saved would leave an upgrade `--undo` can't find: the helper goes
/// back and is staged again instead.
#[test]
fn computer_use_upgrade_unsaved_receipt_puts_the_helper_back() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = host(&[100, 200, 300]);
    // A folder where the receipt goes: the save's rename fails.
    let blocker = fixture.store.root.join(RECEIPT);
    fs::create_dir_all(blocker.join("in-the-way")).unwrap();
    let error = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap_err();
    assert!(error.contains("receipt was not saved"), "{error}");
    assert!(error.contains("the helper is back as it was"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(
        *host.restaged.borrow(),
        vec![Some(NEW_HELPER.to_vec()), Some(OLD_HELPER.to_vec())],
        "the old helper is staged again"
    );
    assert!(blocker.is_dir(), "nothing claims an upgrade happened");
}

/// The swap is done and its receipt saved when the history line is written: a history that
/// can't be written is noted in the answer, and the upgrade still stands and can be undone.
#[test]
fn computer_use_upgrade_unwritable_history_still_reports_the_swap() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = host(&[100, 200, 300, 400]);
    // A folder where the history goes: the append fails.
    fs::create_dir_all(fixture.store.root.join("history.jsonl").join("in-the-way")).unwrap();
    let receipt = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "swapped", "{receipt}");
    assert!(receipt["history_not_saved"].is_string(), "{receipt}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(NEW_HELPER));
    let undone = cu_upgrade::undo_with(&fixture.store, &host, false).unwrap();
    assert_eq!(undone["did"], "restored", "{undone}");
    assert!(undone["history_not_saved"].is_string(), "{undone}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
}

/// The checked bundle replaces the app's helper, the worker's copy is restaged from it, the
/// receipt says the worker restarted, and the bundle from before is kept for undo.
#[test]
fn computer_use_upgrade_swaps_the_helper_restages_and_restarts_the_worker() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = host(&[100, 200]);
    let receipt = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "swapped");
    assert_eq!(receipt["commit"], COMMIT);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(NEW_HELPER));
    assert_eq!(
        *host.restaged.borrow(),
        vec![Some(NEW_HELPER.to_vec())],
        "restaged once, from the new bundle"
    );
    assert_eq!(receipt["worker"]["before"]["pid"], 100);
    assert_eq!(receipt["worker"]["after"]["pid"], 200);
    assert_eq!(receipt["worker"]["restarted"], true);
    assert_eq!(signing.verified.get(), 1, "the build's bundle was checked once");
    let kept = PathBuf::from(receipt["undo"][helper::KEY]["copy"].as_str().unwrap());
    assert_eq!(fs::read(kept.join("Contents/MacOS").join(helper::EXECUTABLE)).unwrap(), OLD_HELPER);
    let saved: Value =
        serde_json::from_slice(&fs::read(fixture.store.root.join(RECEIPT)).unwrap()).unwrap();
    assert_eq!(saved, receipt);
    let names: Vec<_> = fs::read_dir(fixture.app.join(helper::LIBRARY))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec![HELPER_NAME.to_owned()], "no staging folder is left in the app");
}

/// `--undo` puts the helper from before back and restages it, once.
#[test]
fn computer_use_upgrade_undo_restores_the_helper_once() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let upgrade = host(&[100, 200]);
    cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &upgrade,
        false,
        build(),
    )
    .unwrap();
    let dry = host(&[]);
    let checked = cu_upgrade::undo_with(&fixture.store, &dry, true).unwrap();
    assert_eq!(checked["did"], "checked");
    assert_eq!(
        helper_bytes(&fixture.app).as_deref(),
        Some(NEW_HELPER),
        "a dry undo changes nothing"
    );
    assert!(dry.restaged.borrow().is_empty());

    let undo = host(&[200, 300]);
    let receipt = cu_upgrade::undo_with(&fixture.store, &undo, false).unwrap();
    assert_eq!(receipt["did"], "restored");
    assert_eq!(receipt["undoes"], COMMIT);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(*undo.restaged.borrow(), vec![Some(OLD_HELPER.to_vec())]);
    assert_eq!(receipt["worker"]["after"]["pid"], 300);
    assert!(!fixture.store.root.join(RECEIPT).exists());
    assert!(fixture.store.root.join(UNDONE).is_file());

    let again = cu_upgrade::undo_with(&fixture.store, &host(&[]), false).unwrap_err();
    assert!(again.contains("already undone"), "{again}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
}

#[test]
fn computer_use_upgrade_undo_with_no_upgrade_refuses() {
    let (fixture, _) = helper_fixture();
    let error = cu_upgrade::undo_with(&fixture.store, &host(&[]), false).unwrap_err();
    assert!(error.contains("no Computer Use upgrade"), "{error}");
}

/// A worker copy that cannot be staged puts the app's helper back (and stages it again), so
/// the app and the worker never disagree, and leaves no receipt to undo.
#[test]
fn computer_use_upgrade_failed_restage_puts_the_helper_back() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = FakeHost { fail_first_restage: true, ..host(&[100]) };
    let error = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap_err();
    assert!(error.contains("the helper is back as it was"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(
        *host.restaged.borrow(),
        vec![Some(NEW_HELPER.to_vec()), Some(OLD_HELPER.to_vec())],
        "the old helper is staged again"
    );
    assert!(!fixture.store.root.join(RECEIPT).exists());
}

/// A bundle that does not meet the installed helper's requirement is never swapped in.
#[test]
fn computer_use_upgrade_refuses_a_bundle_off_the_installed_requirement() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, false);
    let host = host(&[100]);
    let error = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap_err();
    assert!(error.contains("does not meet the installed helper's requirement"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert!(host.restaged.borrow().is_empty());
    assert!(!fixture.store.root.join(RECEIPT).exists());
}

/// `--dry-run` checks the build's bundle and changes nothing.
#[test]
fn computer_use_upgrade_dry_run_checks_and_changes_nothing() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = host(&[]);
    let receipt = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        true,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "checked");
    assert_eq!(signing.verified.get(), 1);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert!(host.restaged.borrow().is_empty());
    assert!(!fixture.store.root.join(RECEIPT).exists());
}

/// The same build twice: the second finds nothing to change.
#[test]
fn computer_use_upgrade_to_the_running_build_is_untouched() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let wanted = wanted(&fixture);
    cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted,
        &fixture.store,
        &signing,
        &host(&[1, 2]),
        false,
        build(),
    )
    .unwrap();
    let host = host(&[]);
    let receipt = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted,
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "untouched");
    assert!(host.restaged.borrow().is_empty());
}

/// Builds since the rename bundle `<app> Helper.app`, while CI's zip still holds `<app> Screen
/// Sharing.app`: the upgrade takes it and keeps the installed name.
#[test]
fn computer_use_upgrade_takes_a_renamed_helper() {
    let (fixture, unpacked) = helper_fixture();
    let library = fixture.app.join(helper::LIBRARY);
    let renamed = library.join("cmux NIGHTLY Screen Sharing.app");
    fs::rename(library.join(HELPER_NAME), &renamed).unwrap();
    struct AnyName(FakeSigning);
    impl Signing for AnyName {
        fn unpack(&self, zip: &Path, into: &Path) -> Result<(), String> {
            self.0.unpack(zip, into)
        }
        fn requirement(&self, bundle: &Path) -> Result<String, String> {
            assert!(bundle.ends_with("cmux NIGHTLY Screen Sharing.app"), "{bundle:?}");
            Ok(REQUIREMENT.to_owned())
        }
        fn verify(&self, bundle: &Path, requirement: &str) -> Result<(), String> {
            self.0.verify(bundle, requirement)
        }
    }
    let upgrade = host(&[1, 2]);
    let receipt = cu_upgrade::upgrade_with(
        &fixture.app,
        &wanted(&fixture),
        &fixture.store,
        &AnyName(signing(unpacked, true)),
        &upgrade,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "swapped");
    assert_eq!(
        fs::read(renamed.join("Contents/MacOS").join(helper::EXECUTABLE)).unwrap(),
        NEW_HELPER
    );
    assert!(!library.join(HELPER_NAME).exists(), "the installed name stays");
    let undo = cu_upgrade::undo_with(&fixture.store, &host(&[2, 3]), false).unwrap();
    assert_eq!(undo["did"], "restored");
    assert_eq!(
        fs::read(renamed.join("Contents/MacOS").join(helper::EXECUTABLE)).unwrap(),
        OLD_HELPER
    );
}
