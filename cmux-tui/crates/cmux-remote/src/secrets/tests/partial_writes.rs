//! A write that fails partway leaves every live file as it was and keeps
//! the sealed request sendable again. Generated values only.

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
fn a_login_that_fails_on_any_write_changes_nothing_and_can_be_sent_again() {
    let fixture = fixture(&[]);
    std::fs::create_dir_all(fixture.home.join(".claude")).unwrap();
    std::fs::create_dir_all(fixture.home.join(".config/cmux/agent-auth")).unwrap();
    std::fs::write(fixture.home.join(".claude/settings.json"), r#"{"theme":"dark"}"#).unwrap();
    std::fs::write(
        fixture.home.join(".claude/.credentials.json"),
        format!(r#"{{"claudeAiOauth":{{"accessToken":"old-{}"}}}}"#, random_hex(8)),
    )
    .unwrap();
    std::fs::write(fixture.home.join(".config/cmux/agent-auth/claude"), "managed\n").unwrap();
    let before = snapshot(&fixture.home);
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let item = fixture.seal(Purpose::HarnessLogin, "claude", &token);
    // Three files: three staged writes, then three renames.
    for step in 0..6 {
        let _fail = FailAt::set(Some(step));
        let error = fixture.secrets.install_harness_login(&item).unwrap_err();
        assert!(error.message.starts_with("write"), "step {step}: {error}");
        assert_eq!(snapshot(&fixture.home), before, "step {step} changed a live file");
    }
    // The same sealed login, sent again, installs.
    assert_eq!(fixture.secrets.install_harness_login(&item).unwrap(), "claude");
    let after = snapshot(&fixture.home);
    assert_eq!(after.len(), before.len(), "a temporary or backup was left: {:?}", after.keys());
    let credentials: serde_json::Value =
        serde_json::from_slice(&after[".claude/.credentials.json"]).unwrap();
    assert_eq!(credentials["claudeAiOauth"]["accessToken"], token.as_str());
    assert_eq!(after[".config/cmux/agent-auth/claude"], b"own\n");
    // A second success is still a replay.
    let error = fixture.secrets.install_harness_login(&item).unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");
}

#[test]
fn a_first_login_that_fails_partway_leaves_no_new_file() {
    let fixture = fixture(&[]);
    let before = snapshot(&fixture.home);
    let auth = serde_json::json!({
        "OPENAI_API_KEY": null,
        "tokens": {
            "access_token": random_hex(16),
            "refresh_token": random_hex(16),
            "id_token": random_hex(16),
        },
    })
    .to_string();
    let item = fixture.seal(Purpose::HarnessLogin, "codex", &auth);
    // Two files: two staged writes, then two renames.
    for step in 0..4 {
        let _fail = FailAt::set(Some(step));
        let error = fixture.secrets.install_harness_login(&item).unwrap_err();
        assert!(error.message.starts_with("write"), "step {step}: {error}");
        assert_eq!(snapshot(&fixture.home), before, "step {step} left a file");
    }
    assert_eq!(fixture.secrets.install_harness_login(&item).unwrap(), "codex");
    assert!(fixture.home.join(".codex/auth.json").is_file());
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
