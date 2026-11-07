//! One request at a time, a merge that notices an outside edit, and replay
//! protection that outlives the daemon. Generated values only.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use super::super::commit::BEFORE_COMMIT;
use super::super::seal::{self, Purpose};
use super::super::{MachineSecrets, WINDOW_SECS, files};
use super::{MACHINE, fixture, random_hex};

const NOW: u64 = 1_800_000_000;

/// The same machine's daemon after a restart: a new service on the same key,
/// home and state, with `clock` and a window of `max_live` nonces.
fn restarted(fixture: &super::Fixture, clock: &Arc<AtomicU64>, max_live: usize) -> MachineSecrets {
    let clock = Arc::clone(clock);
    MachineSecrets::new(
        &fixture.identity,
        MACHINE.to_owned(),
        fixture.home.clone(),
        fixture.etc.clone(),
        fixture.state.clone(),
    )
    .with_clock(Arc::new(move || clock.load(Ordering::SeqCst)), max_live)
}

fn seal_at(
    fixture: &super::Fixture,
    name: &str,
    value: &str,
    issued_at: u64,
) -> cmux_remote_protocol::SealedSecret {
    seal::seal_at(
        &fixture.identity.public_key(),
        MACHINE,
        Purpose::Secret,
        name,
        value.as_bytes(),
        issued_at,
    )
    .unwrap()
}

#[test]
fn concurrent_requests_never_interleave_and_one_nonce_is_taken_once() {
    let fixture = fixture(&["DEMO_KEY"]);
    let values: Vec<String> = (0..8).map(|_| random_hex(16)).collect();
    let items: Vec<_> =
        values.iter().map(|value| fixture.seal(Purpose::Secret, "DEMO_KEY", value)).collect();
    std::thread::scope(|scope| {
        for item in &items {
            let secrets = &fixture.secrets;
            scope.spawn(move || {
                secrets.replace_machine_secrets(std::slice::from_ref(item)).unwrap()
            });
        }
    });
    let written = std::fs::read_to_string(fixture.home.join(files::MACHINE_SECRETS_FILE)).unwrap();
    assert!(values.iter().any(|value| written == format!("export DEMO_KEY='{value}'\n")));
    let folder = fixture.home.join(".config/cmux");
    let names: Vec<_> = std::fs::read_dir(&folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["machine-secrets.env"], "a temporary or backup was left");

    // The same sealed login from four threads at once installs once.
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let login = fixture.seal(Purpose::HarnessLogin, "claude", &token);
    let results: Vec<_> = std::thread::scope(|scope| {
        let handles: Vec<_> =
            (0..4).map(|_| scope.spawn(|| fixture.secrets.install_harness_login(&login))).collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    for error in results.iter().filter_map(|result| result.as_ref().err()) {
        assert!(error.message.starts_with("replay"), "{error}");
    }
}

#[test]
fn an_edit_racing_a_claude_login_is_merged_once_then_refused() {
    let fixture = fixture(&[]);
    std::fs::create_dir_all(fixture.home.join(".claude")).unwrap();
    let settings = fixture.home.join(".claude/settings.json");
    std::fs::write(&settings, r#"{"theme":"dark"}"#).unwrap();

    // One edit while the login is staged: merged into, not lost.
    let path = settings.clone();
    let mut edits = 0;
    BEFORE_COMMIT.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            if edits == 0 {
                std::fs::write(&path, r#"{"theme":"light","model":"opus"}"#).unwrap();
            }
            edits += 1;
        }));
    });
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let item = fixture.seal(Purpose::HarnessLogin, "claude", &token);
    let installed = fixture.secrets.install_harness_login(&item);
    BEFORE_COMMIT.with(|hook| hook.borrow_mut().take());
    assert_eq!(installed.unwrap(), "claude");
    let written: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
    assert_eq!(written["theme"], "light");
    assert_eq!(written["model"], "opus");
    assert_eq!(written["env"]["CLAUDE_CODE_OAUTH_TOKEN"], token.as_str());

    // An edit on every try: refused, the person's edit kept, and the same
    // sealed login installs once the file is left alone.
    let path = settings.clone();
    let mut edits = 0;
    BEFORE_COMMIT.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            edits += 1;
            std::fs::write(&path, format!(r#"{{"theme":"edit-{edits}"}}"#)).unwrap();
        }));
    });
    let newer = format!("sk-ant-oat01-{}", random_hex(24));
    let item = fixture.seal(Purpose::HarnessLogin, "claude", &newer);
    let refused = fixture.secrets.install_harness_login(&item);
    BEFORE_COMMIT.with(|hook| hook.borrow_mut().take());
    let error = refused.unwrap_err();
    assert!(error.message.starts_with("conflict"), "{error}");
    assert_eq!(std::fs::read_to_string(&settings).unwrap(), r#"{"theme":"edit-2"}"#);
    let credentials =
        std::fs::read_to_string(fixture.home.join(".claude/.credentials.json")).unwrap();
    assert!(credentials.contains(&token) && !credentials.contains(&newer));
    assert_eq!(fixture.secrets.install_harness_login(&item).unwrap(), "claude");
}

#[test]
fn a_taken_item_stays_refused_after_a_restart_until_its_window_passes() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    let item = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW);
    restarted(&fixture, &clock, 16).replace_machine_secrets(std::slice::from_ref(&item)).unwrap();
    let saved = fixture.state.join("secrets-v1/taken-nonces.json");
    assert_eq!(super::mode(&saved), 0o600);
    assert_eq!(super::mode(saved.parent().unwrap()), 0o700);

    let error = restarted(&fixture, &clock, 16)
        .replace_machine_secrets(std::slice::from_ref(&item))
        .unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");

    // Past its window the item is stale (never taken again), and loading
    // drops its nonce from the saved set.
    clock.store(NOW + WINDOW_SECS + 1, Ordering::SeqCst);
    let later = restarted(&fixture, &clock, 16);
    let error = later.replace_machine_secrets(std::slice::from_ref(&item)).unwrap_err();
    assert!(error.message.starts_with("stale"), "{error}");
    later
        .replace_machine_secrets(&[seal_at(
            &fixture,
            "DEMO_KEY",
            &random_hex(16),
            NOW + WINDOW_SECS,
        )])
        .unwrap();
    let stored: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
    assert_eq!(stored["taken"].as_object().unwrap().len(), 1);
    assert!(stored["taken"].get(&item.nonce).is_none());
}

#[test]
fn an_item_sealed_outside_the_window_is_refused() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    let secrets = restarted(&fixture, &clock, 16);
    for issued_at in [NOW - WINDOW_SECS - 1, NOW + WINDOW_SECS + 1, 0] {
        let error = secrets
            .replace_machine_secrets(&[seal_at(&fixture, "DEMO_KEY", &random_hex(16), issued_at)])
            .unwrap_err();
        assert!(error.message.starts_with("stale") && !error.retryable, "{issued_at}: {error}");
    }
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
    for issued_at in [NOW - WINDOW_SECS, NOW + WINDOW_SECS] {
        secrets
            .replace_machine_secrets(&[seal_at(&fixture, "DEMO_KEY", &random_hex(16), issued_at)])
            .unwrap();
    }
}

#[test]
fn a_full_window_refuses_retryably_and_never_drops_a_live_nonce() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    let secrets = restarted(&fixture, &clock, 2);
    let first = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW);
    secrets.replace_machine_secrets(std::slice::from_ref(&first)).unwrap();
    secrets
        .replace_machine_secrets(&[seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW)])
        .unwrap();
    let error = secrets
        .replace_machine_secrets(&[seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW)])
        .unwrap_err();
    assert!(error.message.starts_with("busy") && error.retryable, "{error}");
    // The first nonce is still taken.
    let error = secrets.replace_machine_secrets(std::slice::from_ref(&first)).unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");
    // Once the window has passed, room again.
    clock.store(NOW + WINDOW_SECS + 1, Ordering::SeqCst);
    secrets
        .replace_machine_secrets(&[seal_at(
            &fixture,
            "DEMO_KEY",
            &random_hex(16),
            NOW + WINDOW_SECS,
        )])
        .unwrap();
}

#[test]
fn an_unreadable_taken_set_refuses_items_sealed_before_the_restart() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    let item = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW - 1);
    std::fs::create_dir_all(fixture.state.join("secrets-v1")).unwrap();
    std::fs::write(fixture.state.join("secrets-v1/taken-nonces.json"), "not json").unwrap();
    let secrets = restarted(&fixture, &clock, 16);
    let error = secrets.replace_machine_secrets(std::slice::from_ref(&item)).unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");
    secrets
        .replace_machine_secrets(&[seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW)])
        .unwrap();
}
