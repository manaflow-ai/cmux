//! The revocation fetch: no URL is a no-op, only a registry-signed list is
//! written, a lower or equal `sequence` never replaces the one on disk, and
//! a failing registry gets a bounded number of requests.

use std::cell::Cell;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{Value, json};

use super::super::community::RegistryFetch;
use super::super::registry_trust::tests::{envelope, keypair, temp_dir};
use super::super::registry_trust::{REVOCATIONS_FILE, REVOCATIONS_PURPOSE, open_revocations};
use super::{ATTEMPTS, Outcome, refresh};

const BUILD: &str = "a3c1b0f6b8f61b1e4d2b8c8f1f0e6a3d5c7b9e2f4a6c8e0b2d4f6a8c0e2b4d6f";
const URL: &str = "https://registry.example/v1/revocations.sig";

/// Answers each request from `answers` in turn (the last one repeats) and
/// counts them.
struct Scripted {
    answers: Vec<Result<Vec<u8>, String>>,
    calls: Mutex<usize>,
}

impl Scripted {
    fn new(answers: Vec<Result<Vec<u8>, String>>) -> Self {
        Self { answers, calls: Mutex::new(0) }
    }
    fn calls(&self) -> usize {
        *self.calls.lock().unwrap()
    }
}

impl RegistryFetch for Scripted {
    fn get(&self, url: &str) -> Result<Vec<u8>, String> {
        assert_eq!(url, URL);
        let mut calls = self.calls.lock().unwrap();
        let answer = self.answers[(*calls).min(self.answers.len() - 1)].clone();
        *calls += 1;
        answer
    }
}

fn list(sequence: u64) -> Value {
    json!({
        "schema": 1, "purpose": REVOCATIONS_PURPOSE, "sequence": sequence,
        "revoked": [{ "sha256": BUILD, "id": "acme/hello", "reason": "malware" }],
    })
}

fn no_pause(_: Duration) {}

#[test]
fn no_url_fetches_and_writes_nothing() {
    let dir = temp_dir();
    let (_, key) = keypair();
    let fetch = Scripted::new(vec![Err("never asked".into())]);
    assert_eq!(refresh(&dir.0, None, &[key], &fetch, &no_pause), Ok(Outcome::NoUrl));
    assert_eq!(fetch.calls(), 0);
    assert!(!dir.0.join(REVOCATIONS_FILE).exists());
}

#[test]
fn a_higher_sequence_is_written_and_a_lower_or_equal_one_is_refused() {
    let dir = temp_dir();
    let (pair, key) = keypair();
    let keys = [key.clone()];
    let five = envelope(&list(5), &pair, &key.0);
    let fetch = Scripted::new(vec![Ok(five.clone())]);
    assert_eq!(refresh(&dir.0, Some(URL), &keys, &fetch, &no_pause), Ok(Outcome::Updated(5)));
    assert_eq!(std::fs::read(dir.0.join(REVOCATIONS_FILE)).unwrap(), five);
    assert!(!dir.0.join(format!("{REVOCATIONS_FILE}.tmp")).exists(), "the temp file is renamed");

    for older in [4, 5] {
        let fetch = Scripted::new(vec![Ok(envelope(&list(older), &pair, &key.0))]);
        assert_eq!(
            refresh(&dir.0, Some(URL), &keys, &fetch, &no_pause),
            Ok(Outcome::Kept { have: 5, fetched: older }),
            "sequence {older} never rolls back 5"
        );
        assert_eq!(std::fs::read(dir.0.join(REVOCATIONS_FILE)).unwrap(), five);
    }

    let six = envelope(&list(6), &pair, &key.0);
    let fetch = Scripted::new(vec![Ok(six.clone())]);
    assert_eq!(refresh(&dir.0, Some(URL), &keys, &fetch, &no_pause), Ok(Outcome::Updated(6)));
    let on_disk = std::fs::read(dir.0.join(REVOCATIONS_FILE)).unwrap();
    assert_eq!(open_revocations(&on_disk, &keys).unwrap().sequence, 6);
}

#[test]
fn a_list_another_key_signed_is_refused_and_the_old_one_kept() {
    let dir = temp_dir();
    let (pair, key) = keypair();
    let keys = [key.clone()];
    let two = envelope(&list(2), &pair, &key.0);
    refresh(&dir.0, Some(URL), &keys, &Scripted::new(vec![Ok(two.clone())]), &no_pause).unwrap();

    let (stranger, stranger_key) = keypair();
    let forged = envelope(&list(99), &stranger, &stranger_key.0);
    let fetch = Scripted::new(vec![Ok(forged)]);
    assert!(refresh(&dir.0, Some(URL), &keys, &fetch, &no_pause).is_err());
    assert_eq!(fetch.calls(), 1, "a list that does not open is not retried");

    let mut garbled = envelope(&list(99), &pair, &key.0);
    let at = garbled.len() / 2;
    garbled[at] ^= 1;
    let fetch = Scripted::new(vec![Ok(garbled)]);
    assert!(refresh(&dir.0, Some(URL), &keys, &fetch, &no_pause).is_err());
    assert_eq!(std::fs::read(dir.0.join(REVOCATIONS_FILE)).unwrap(), two, "kept");
    assert!(
        refresh(&dir.0, Some(URL), &[], &Scripted::new(vec![Ok(two.clone())]), &no_pause)
            .unwrap_err()
            .contains("no registry key"),
        "a build with no registry key writes nothing"
    );
}

#[test]
fn a_failing_registry_gets_bounded_requests_with_backoff() {
    let dir = temp_dir();
    let (pair, key) = keypair();
    let keys = [key.clone()];
    let waited = Cell::new(Duration::ZERO);
    let pause = |d: Duration| waited.set(waited.get() + d);

    let fetch = Scripted::new(vec![Err("timed out".into())]);
    let error = refresh(&dir.0, Some(URL), &keys, &fetch, &pause).unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert_eq!(fetch.calls(), ATTEMPTS as usize);
    assert_eq!(waited.get(), Duration::from_secs(2 + 4));
    assert!(!dir.0.join(REVOCATIONS_FILE).exists());

    let fetch = Scripted::new(vec![Err("reset".into()), Ok(envelope(&list(1), &pair, &key.0))]);
    assert_eq!(refresh(&dir.0, Some(URL), &keys, &fetch, &pause), Ok(Outcome::Updated(1)));
    assert_eq!(fetch.calls(), 2);

    let plain = Scripted::new(vec![Err("never asked".into())]);
    assert!(refresh(&dir.0, Some("http://registry.example/x"), &keys, &plain, &pause).is_err());
    assert_eq!(plain.calls(), 0, "http is refused before any request");
}
