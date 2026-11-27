//! `cmux computer-use install`: the signed helper on a Mac with no cmux app
//! (try_cmd/cu_install.rs), on the try fixtures.

use std::cell::RefCell;

use super::super::cu_install::{self, RECEIPT, Request};
use super::super::cu_upgrade::{Host, Source};
use super::*;

/// The machine stood in for: what each restage saw.
#[derive(Default)]
struct FakeHost {
    restaged: RefCell<Vec<PathBuf>>,
}

impl Host for FakeHost {
    fn restage(&self, helper: &Path) -> Result<PathBuf, String> {
        self.restaged.borrow_mut().push(helper.to_path_buf());
        Ok(PathBuf::from("/staged/cmux-screen-sharing"))
    }
    fn worker(&self) -> Result<Value, String> {
        panic!("an install restarts no worker")
    }
}

fn wanted(fixture: &Fixture) -> helper::WantedHelper {
    let (_, helper) = live_plan(fixture, &found_value(&payload_with_helper(helper_key())));
    helper.expect("the build carries the helper")
}

fn build() -> Value {
    json!({ "from": "nightly", "commit": COMMIT })
}

fn standalone(fixture: &Fixture) -> PathBuf {
    fixture.app.parent().unwrap().join("standalone")
}

fn standalone_bytes(standalone: &Path) -> Option<Vec<u8>> {
    fs::read(
        standalone
            .join(helper::LIBRARY)
            .join(HELPER_NAME)
            .join("Contents/MacOS")
            .join(helper::EXECUTABLE),
    )
    .ok()
}

#[test]
fn computer_use_install_parses_from_and_dry_run() {
    let plain = |source, dry_run| Request { source, dry_run };
    assert_eq!(cu_install::parse(&[]).unwrap(), plain(Source::Nightly, false));
    assert_eq!(
        cu_install::parse(&["--from", "#50850", "--dry-run"]).unwrap(),
        plain(Source::Build("#50850".into()), true)
    );
    assert!(cu_install::parse(&["--undo"]).unwrap_err().contains("no --undo"));
    assert_eq!(cu_install::parse(&["--machine", "studio"]).unwrap_err(), cu_install::NOT_REMOTE);
}

/// No cmux app: the checked helper lands in the standalone folder (laid out as an app's
/// Contents/Library, where the daemon's launcher looks), is staged, and a receipt is kept.
#[test]
fn computer_use_install_puts_the_signed_helper_where_the_daemon_finds_it() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = FakeHost::default();
    let root = standalone(&fixture);
    let receipt = cu_install::install_with(
        &root,
        None,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "installed", "{receipt}");
    assert_eq!(receipt["commit"], COMMIT, "{receipt}");
    assert_eq!(standalone_bytes(&root).as_deref(), Some(NEW_HELPER));
    assert_eq!(signing.verified.get(), 1, "codesign checked it against the Developer ID form");
    let dest = root.join(helper::LIBRARY).join(HELPER_NAME);
    assert_eq!(*host.restaged.borrow(), vec![dest.clone()]);
    // The daemon's search (cmux_signed_bundle::helpers_in) reads the folder as an app.
    assert_eq!(cmux_signed_bundle::helpers_in(&root, helper::EXECUTABLE), vec![dest]);
    let saved: Value = serde_json::from_slice(&fs::read(root.join(RECEIPT)).unwrap()).unwrap();
    assert_eq!(saved["did"], "installed");
    // No temporary folder is left beside it.
    let left: Vec<_> = fs::read_dir(root.join(helper::LIBRARY))
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left, [HELPER_NAME]);

    // Again: the same build is current, staged again, nothing swapped.
    let again = cu_install::install_with(
        &root,
        None,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(again["did"], "current", "{again}");
    assert_eq!(standalone_bytes(&root).as_deref(), Some(NEW_HELPER));
}

/// A bundle codesign refuses is never installed.
#[test]
fn computer_use_install_refuses_a_bundle_that_fails_the_signature() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, false);
    let host = FakeHost::default();
    let root = standalone(&fixture);
    let error = cu_install::install_with(
        &root,
        None,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap_err();
    assert!(error.contains("does not meet"), "{error}");
    assert_eq!(standalone_bytes(&root), None);
    assert!(host.restaged.borrow().is_empty());
}

/// Only cmux's own team: a build record naming another team installs nothing.
#[test]
fn computer_use_install_refuses_another_team() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = FakeHost::default();
    let root = standalone(&fixture);
    let mut other = wanted(&fixture);
    other.file.team = Some("ABCDE12345".into());
    let error = cu_install::install_with(
        &root,
        None,
        &other,
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap_err();
    assert!(error.contains("not cmux's"), "{error}");
    assert_eq!(standalone_bytes(&root), None);
}

/// --dry-run fetches and checks, and installs nothing.
#[test]
fn computer_use_install_dry_run_installs_nothing() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = FakeHost::default();
    let root = standalone(&fixture);
    let receipt = cu_install::install_with(
        &root,
        None,
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        true,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "checked", "{receipt}");
    assert_eq!(standalone_bytes(&root), None);
    assert!(host.restaged.borrow().is_empty());
    assert!(!root.join(RECEIPT).exists());
}

/// An installed cmux app's own helper is the one the daemon runs: nothing goes beside it.
#[test]
fn computer_use_install_keeps_an_installed_apps_helper() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let host = FakeHost::default();
    let root = standalone(&fixture);
    let existing = installed_helper(&fixture.app);
    let receipt = cu_install::install_with(
        &root,
        Some(&existing),
        &wanted(&fixture),
        &fixture.store,
        &signing,
        &host,
        false,
        build(),
    )
    .unwrap();
    assert_eq!(receipt["did"], "untouched", "{receipt}");
    assert!(receipt["why"].as_str().unwrap().contains("cmux computer-use upgrade"), "{receipt}");
    assert_eq!(standalone_bytes(&root), None);
    assert_eq!(signing.verified.get(), 0);
}
