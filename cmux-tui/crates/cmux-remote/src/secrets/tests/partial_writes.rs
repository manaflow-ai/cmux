//! A write that fails partway leaves the live file as it was (or, when only
//! the folder sync failed, holding the new bytes) and keeps the sealed
//! request sendable again. Generated values only.

use std::collections::BTreeMap;
use std::path::Path;

use super::super::commit::FAIL_AT;
use super::super::files;
use super::super::seal::Purpose;
use super::{fixture, random_hex};

/// Every file below `home` (temporaries and backups included) with its bytes.
fn snapshot(home: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    let mut folders = vec![home.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(&folder).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                folders.push(path);
            } else {
                let name = path.strip_prefix(home).unwrap().display().to_string();
                files.insert(name, std::fs::read(&path).unwrap());
            }
        }
    }
    files
}

struct FailAt;

impl FailAt {
    fn set(step: Option<usize>) -> Self {
        FAIL_AT.with(|cell| cell.set(step));
        Self
    }
}

impl Drop for FailAt {
    fn drop(&mut self) {
        FAIL_AT.with(|cell| cell.set(None));
    }
}

#[test]
fn machine_secrets_that_fail_to_write_keep_the_file_and_can_be_sent_again() {
    let fixture = fixture(&["DEMO_KEY"]);
    let old = random_hex(16);
    fixture
        .secrets
        .replace_machine_secrets(&[fixture.seal(Purpose::Secret, "DEMO_KEY", &old)])
        .unwrap();
    let before = snapshot(&fixture.home);
    let newer = random_hex(16);
    let items = [fixture.seal(Purpose::Secret, "DEMO_KEY", &newer)];
    for step in 0..2 {
        let _fail = FailAt::set(Some(step));
        let error = fixture.secrets.replace_machine_secrets(&items).unwrap_err();
        assert!(error.message.starts_with("write"), "step {step}: {error}");
        assert_eq!(snapshot(&fixture.home), before, "step {step} changed the file");
    }
    fixture.secrets.replace_machine_secrets(&items).unwrap();
    let path = fixture.home.join(files::MACHINE_SECRETS_FILE);
    assert_eq!(std::fs::read_to_string(path).unwrap(), format!("export DEMO_KEY='{newer}'\n"));
    let error = fixture.secrets.replace_machine_secrets(&items).unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");
}

#[test]
fn a_failed_folder_sync_answers_write_and_the_request_can_be_sent_again() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let items = [fixture.seal(Purpose::Secret, "DEMO_KEY", &value)];
    let error = {
        let _fail = FailAt::set(Some(2));
        fixture.secrets.replace_machine_secrets(&items).unwrap_err()
    };
    assert!(error.message.starts_with("write"), "{error}");
    let path = fixture.home.join(files::MACHINE_SECRETS_FILE);
    let expected = format!("export DEMO_KEY='{value}'\n");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), expected);
    fixture.secrets.replace_machine_secrets(&items).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), expected);
    let names: Vec<_> = snapshot(&fixture.home).into_keys().collect();
    assert!(names.iter().all(|name| !name.ends_with(".tmp")), "{names:?}");
}

#[test]
fn a_write_failing_on_its_rename_never_clobbers_a_concurrent_one() {
    let fixture = fixture(&["DEMO_KEY"]);
    let path = fixture.home.join(files::MACHINE_SECRETS_FILE);
    for _ in 0..4 {
        let good = random_hex(16);
        let bad = random_hex(16);
        let good_items = [fixture.seal(Purpose::Secret, "DEMO_KEY", &good)];
        let bad_items = [fixture.seal(Purpose::Secret, "DEMO_KEY", &bad)];
        let (good_result, bad_result) = std::thread::scope(|scope| {
            let secrets = &fixture.secrets;
            let bad = scope.spawn(|| {
                let _fail = FailAt::set(Some(1));
                secrets.replace_machine_secrets(&bad_items)
            });
            let good = scope.spawn(|| secrets.replace_machine_secrets(&good_items));
            (good.join().unwrap(), bad.join().unwrap())
        });
        assert_eq!(good_result.unwrap(), 1);
        let error = bad_result.unwrap_err();
        assert!(error.message.starts_with("write"), "{error}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("export DEMO_KEY='{good}'\n"));
        let names: Vec<_> = snapshot(&fixture.home).into_keys().collect();
        assert!(names.iter().all(|name| !name.ends_with(".tmp")), "{names:?}");
        // The failed one can be sent again, and then wins.
        fixture.secrets.replace_machine_secrets(&bad_items).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("export DEMO_KEY='{bad}'\n"));
    }
}
