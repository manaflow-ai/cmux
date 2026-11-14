//! One request at a time, and replay protection that outlives the daemon. Generated values only.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

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

    // The same sealed request from four threads at once is taken once.
    let value = random_hex(16);
    let item = fixture.seal(Purpose::Secret, "DEMO_KEY", &value);
    let results: Vec<_> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| fixture.secrets.replace_machine_secrets(std::slice::from_ref(&item)))
            })
            .collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    for error in results.iter().filter_map(|result| result.as_ref().err()) {
        assert!(error.message.starts_with("replay"), "{error}");
    }
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
fn an_unreadable_taken_set_refuses_every_item_that_may_have_been_taken() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    // Taken at NOW, sealed by a device clock a minute ahead.
    let ahead = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW + 60);
    restarted(&fixture, &clock, 16).replace_machine_secrets(std::slice::from_ref(&ahead)).unwrap();
    let saved = fixture.state.join("secrets-v1/taken-nonces.json");
    std::fs::write(&saved, "not json").unwrap();
    clock.store(NOW + 1, Ordering::SeqCst);
    let busy = |secrets: &MachineSecrets, item: &cmux_remote_protocol::SealedSecret| {
        let error = secrets.replace_machine_secrets(std::slice::from_ref(item)).unwrap_err();
        assert!(error.message.starts_with("busy") && error.retryable, "{error}");
    };
    let secrets = restarted(&fixture, &clock, 16);
    busy(&secrets, &ahead);
    // A fresh item sealed at the same second, or as far ahead as the window
    // allows, waits too: either could have been taken before.
    busy(&secrets, &seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW + 1));
    busy(&secrets, &seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW + 1 + WINDOW_SECS));
    // The floor is saved: another restart later doesn't move or drop it.
    clock.store(NOW + 200, Ordering::SeqCst);
    busy(&restarted(&fixture, &clock, 16), &ahead);
    // Once every item it covers is stale, items are taken again.
    let floor = NOW + 1 + WINDOW_SECS + 1;
    clock.store(floor + WINDOW_SECS, Ordering::SeqCst);
    let secrets = restarted(&fixture, &clock, 16);
    let error = secrets.replace_machine_secrets(std::slice::from_ref(&ahead)).unwrap_err();
    assert!(error.message.starts_with("stale"), "{error}");
    secrets
        .replace_machine_secrets(&[seal_at(
            &fixture,
            "DEMO_KEY",
            &random_hex(16),
            floor + WINDOW_SECS,
        )])
        .unwrap();
}

#[test]
fn two_daemons_on_one_machine_share_the_lock_and_the_window() {
    let fixture = fixture(&["DEMO_KEY"]);
    let clock = Arc::new(AtomicU64::new(NOW));
    // An old and a new daemon, both running (a handover).
    let daemons = [restarted(&fixture, &clock, 64), restarted(&fixture, &clock, 64)];
    let values: Vec<String> = (0..8).map(|_| random_hex(16)).collect();
    let item = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW);
    let results: Vec<_> = std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for (index, value) in values.iter().enumerate() {
            let daemon = &daemons[index % 2];
            let fixture = &fixture;
            handles.push(scope.spawn(move || {
                daemon
                    .replace_machine_secrets(&[seal_at(fixture, "DEMO_KEY", value, NOW)])
                    .map(|_| ())
            }));
        }
        for daemon in &daemons {
            let item = &item;
            handles.push(scope.spawn(move || {
                daemon.replace_machine_secrets(std::slice::from_ref(item)).map(|_| ())
            }));
        }
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    // Every distinct item went through; the one sent to both daemons once.
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), values.len() + 1);
    let refused = results.iter().filter_map(|result| result.as_ref().err()).collect::<Vec<_>>();
    assert_eq!(refused.len(), 1);
    assert!(refused[0].message.starts_with("replay"), "{}", refused[0]);
    let folder = fixture.home.join(".config/cmux");
    let names: Vec<_> = std::fs::read_dir(&folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["machine-secrets.env"], "a temporary or backup was left");
    let stored: serde_json::Value = serde_json::from_slice(
        &std::fs::read(fixture.state.join("secrets-v1/taken-nonces.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(stored["taken"].as_object().unwrap().len(), values.len() + 1);
}

/// Hold the machine config applier's lock, as a running apply does.
fn hold_applier_lock(fixture: &super::Fixture) -> std::fs::File {
    use std::os::fd::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(fixture.home.join(".cmux/machine-config/lock"))
        .unwrap();
    // SAFETY: `file` is an open descriptor.
    assert_eq!(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) }, 0);
    file
}

#[test]
fn a_write_waits_for_a_running_apply_and_honors_what_it_declared() {
    let fixture = fixture(&["DEMO_KEY"]);
    let held = hold_applier_lock(&fixture);
    let item = fixture.seal(Purpose::Secret, "DEMO_KEY", &random_hex(16));
    let status = fixture.home.join(files::MACHINE_CONFIG_STATUS_FILE);
    let result = std::thread::scope(|scope| {
        let write =
            scope.spawn(|| fixture.secrets.replace_machine_secrets(std::slice::from_ref(&item)));
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(!write.is_finished(), "the write didn't wait for the apply");
        // The apply removes the name, then lets go of its lock.
        std::fs::write(
            &status,
            serde_json::to_vec(&serde_json::json!({
                "state": "done",
                "secrets": { "declared": ["OTHER_KEY"] },
            }))
            .unwrap(),
        )
        .unwrap();
        drop(held);
        write.join().unwrap()
    });
    let error = result.unwrap_err();
    assert!(error.message.starts_with("bad-name"), "{error}");
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
}

#[test]
fn a_write_behind_a_long_apply_answers_busy_and_can_be_sent_again() {
    let fixture = fixture(&["DEMO_KEY"]);
    let secrets = restarted(&fixture, &Arc::new(AtomicU64::new(NOW)), 16)
        .with_config_wait(std::time::Duration::from_millis(100));
    let item = seal_at(&fixture, "DEMO_KEY", &random_hex(16), NOW);
    let held = hold_applier_lock(&fixture);
    let error = secrets.replace_machine_secrets(std::slice::from_ref(&item)).unwrap_err();
    assert!(error.message.starts_with("busy") && error.retryable, "{error}");
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
    drop(held);
    assert_eq!(secrets.replace_machine_secrets(std::slice::from_ref(&item)).unwrap(), 1);
}
