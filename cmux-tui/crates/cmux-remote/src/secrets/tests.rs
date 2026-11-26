//! Generated keys and values only: nothing here is a real secret.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{Arc, Mutex};

use cmux_remote_protocol::{ByteString, SealedSecret};

use super::seal::{self, Purpose};
use super::{MachineSecrets, files};
use crate::crypto::StaticIdentity;

mod partial_writes;
mod window;

const MACHINE: &str = "vm-secrets-test";

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    getrandom::fill(&mut buffer).unwrap();
    buffer.iter().map(|byte| format!("{byte:02x}")).collect()
}

struct Fixture {
    _dir: tempfile::TempDir,
    home: std::path::PathBuf,
    state: std::path::PathBuf,
    identity: StaticIdentity,
    logs: Arc<Mutex<Vec<String>>>,
    secrets: MachineSecrets,
}

fn fixture(declared: &[&str]) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let state = dir.path().join("state");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(home.join(".cmux/machine-config")).unwrap();
    std::fs::write(
        home.join(files::MACHINE_CONFIG_STATUS_FILE),
        serde_json::to_vec(&serde_json::json!({
            "state": "done",
            "secrets": { "declared": declared },
        }))
        .unwrap(),
    )
    .unwrap();
    let identity = StaticIdentity::generate().unwrap();
    let logs = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&logs);
    let secrets = MachineSecrets::new(&identity, MACHINE.to_owned(), home.clone(), state.clone())
        .with_log(Arc::new(move |line| sink.lock().unwrap().push(line.to_owned())));
    Fixture { _dir: dir, home, state, identity, logs, secrets }
}

impl Fixture {
    fn seal(&self, purpose: Purpose, name: &str, value: &str) -> SealedSecret {
        seal::seal(&self.identity.public_key(), MACHINE, purpose, name, value.as_bytes()).unwrap()
    }

    fn logs(&self) -> Vec<String> {
        self.logs.lock().unwrap().clone()
    }
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

fn assert_no_value(values: &[&str], texts: &[String]) {
    for value in values {
        for text in texts {
            assert!(!text.contains(value), "a value reached {text:?}");
        }
    }
}

#[test]
fn seal_and_open_round_trip() {
    let identity = StaticIdentity::generate().unwrap();
    let value = random_hex(24);
    let item =
        seal::seal(&identity.public_key(), MACHINE, Purpose::Secret, "DEMO", value.as_bytes())
            .unwrap();
    assert!(seal::is_nonce(&item.nonce));
    assert_eq!(item.enc.decode().unwrap().len(), 32);
    let opened = seal::open(identity.private_key(), MACHINE, Purpose::Secret, &item).unwrap();
    assert_eq!(opened.value.as_slice(), value.as_bytes());
    assert!(opened.issued_at.abs_diff(seal::unix_now()) <= 5);
    // The hpke crate derives the same public key as the Noise identity.
    assert_eq!(seal::public_key(identity.private_key()).unwrap(), identity.public_key());
}

#[test]
fn wrong_key_machine_name_or_bytes_never_open() {
    let identity = StaticIdentity::generate().unwrap();
    let other = StaticIdentity::generate().unwrap();
    let value = random_hex(24);
    let item =
        seal::seal(&identity.public_key(), MACHINE, Purpose::Secret, "DEMO", value.as_bytes())
            .unwrap();
    let open = |key: &StaticIdentity, machine: &str, purpose: Purpose, item: &SealedSecret| {
        seal::open(key.private_key(), machine, purpose, item).map(|_| ())
    };
    assert_eq!(open(&other, MACHINE, Purpose::Secret, &item), Err(seal::SealError::OpenFailed));
    assert_eq!(
        open(&identity, "vm-someone-else", Purpose::Secret, &item),
        Err(seal::SealError::OpenFailed)
    );
    let renamed = SealedSecret { name: "OTHER".into(), ..item.clone() };
    assert_eq!(
        open(&identity, MACHINE, Purpose::Secret, &renamed),
        Err(seal::SealError::OpenFailed)
    );
    let renonced = SealedSecret { nonce: seal::fresh_nonce().unwrap(), ..item.clone() };
    assert_eq!(
        open(&identity, MACHINE, Purpose::Secret, &renonced),
        Err(seal::SealError::OpenFailed)
    );
    let mut bytes = item.ciphertext.decode().unwrap();
    bytes[0] ^= 1;
    let tampered = SealedSecret { ciphertext: ByteString::from_bytes(&bytes), ..item.clone() };
    assert_eq!(
        open(&identity, MACHINE, Purpose::Secret, &tampered),
        Err(seal::SealError::OpenFailed)
    );
    let bad_nonce = SealedSecret { nonce: "not-hex".into(), ..item };
    assert_eq!(
        open(&identity, MACHINE, Purpose::Secret, &bad_nonce),
        Err(seal::SealError::BadNonce)
    );
}

#[test]
fn machine_secrets_are_written_0600_in_the_receivers_format() {
    let fixture = fixture(&["DEMO_KEY", "OTHER_KEY"]);
    let first = format!("{}'{}", random_hex(8), random_hex(8));
    let second = random_hex(16);
    let items = [
        fixture.seal(Purpose::Secret, "DEMO_KEY", &first),
        fixture.seal(Purpose::Secret, "OTHER_KEY", &second),
    ];
    assert_eq!(fixture.secrets.replace_machine_secrets(&items).unwrap(), 2);
    let path = fixture.home.join(files::MACHINE_SECRETS_FILE);
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(path.parent().unwrap()), 0o700);
    let quoted = first.replace('\'', "'\\''");
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        format!("export DEMO_KEY='{quoted}'\nexport OTHER_KEY='{second}'\n")
    );
    // An empty set clears the file, as the receiver did.
    assert_eq!(fixture.secrets.replace_machine_secrets(&[]).unwrap(), 0);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "");
    assert_eq!(mode(&path), 0o600);
    assert_no_value(&[&first, &second], &fixture.logs());
}

#[test]
fn a_replayed_item_is_refused_and_the_file_kept() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let item = fixture.seal(Purpose::Secret, "DEMO_KEY", &value);
    fixture.secrets.replace_machine_secrets(std::slice::from_ref(&item)).unwrap();
    let newer = random_hex(16);
    fixture
        .secrets
        .replace_machine_secrets(&[fixture.seal(Purpose::Secret, "DEMO_KEY", &newer)])
        .unwrap();
    let error = fixture.secrets.replace_machine_secrets(&[item]).unwrap_err();
    assert_eq!(error.code, "secret-refused");
    assert!(error.message.starts_with("replay"), "{error}");
    let path = fixture.home.join(files::MACHINE_SECRETS_FILE);
    assert_eq!(std::fs::read_to_string(path).unwrap(), format!("export DEMO_KEY='{newer}'\n"));
}

#[test]
fn a_disallowed_name_is_refused() {
    let fixture = fixture(&["DEMO_KEY", "PATH", "LD_PRELOAD"]);
    let value = random_hex(16);
    for name in ["PATH", "LD_PRELOAD", "NOT_DECLARED", "1BAD", "bad-name"] {
        let error = fixture
            .secrets
            .replace_machine_secrets(&[fixture.seal(Purpose::Secret, name, &value)])
            .unwrap_err();
        assert!(error.message.starts_with("bad-name"), "{name}: {error}");
    }
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
    // Before the machine's config has declared anything, no name is allowed.
    std::fs::remove_file(fixture.home.join(files::MACHINE_CONFIG_STATUS_FILE)).unwrap();
    let error = fixture
        .secrets
        .replace_machine_secrets(&[fixture.seal(Purpose::Secret, "DEMO_KEY", &value)])
        .unwrap_err();
    assert!(error.message.starts_with("bad-name"), "{error}");
}

#[test]
fn items_for_another_machine_or_key_are_refused() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let other_machine = seal::seal(
        &fixture.identity.public_key(),
        "vm-someone-else",
        Purpose::Secret,
        "DEMO_KEY",
        value.as_bytes(),
    )
    .unwrap();
    let other_key = seal::seal(
        &StaticIdentity::generate().unwrap().public_key(),
        MACHINE,
        Purpose::Secret,
        "DEMO_KEY",
        value.as_bytes(),
    )
    .unwrap();
    for item in [other_machine, other_key] {
        let error = fixture.secrets.replace_machine_secrets(&[item]).unwrap_err();
        assert!(error.message.starts_with("open-failed"), "{error}");
    }
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
}

#[test]
fn a_bad_value_or_duplicate_name_writes_nothing() {
    let fixture = fixture(&["DEMO_KEY", "OTHER_KEY"]);
    let short = fixture.seal(Purpose::Secret, "DEMO_KEY", "short");
    let multi =
        fixture.seal(Purpose::Secret, "DEMO_KEY", &format!("{}\n{}", random_hex(8), random_hex(8)));
    for item in [short, multi] {
        let error = fixture.secrets.replace_machine_secrets(&[item]).unwrap_err();
        assert!(error.message.starts_with("bad-value"), "{error}");
    }
    let value = random_hex(16);
    let error = fixture
        .secrets
        .replace_machine_secrets(&[
            fixture.seal(Purpose::Secret, "DEMO_KEY", &value),
            fixture.seal(Purpose::Secret, "DEMO_KEY", &value),
        ])
        .unwrap_err();
    assert!(error.message.starts_with("duplicate"), "{error}");
    assert!(!fixture.home.join(files::MACHINE_SECRETS_FILE).exists());
}

#[test]
fn a_path_outside_the_allowlist_is_refused() {
    let fixture = fixture(&[]);
    for path in [
        fixture.home.join(".bashrc"),
        fixture.home.join(".config/cmux/../../.profile"),
        fixture.home.join(".ssh/authorized_keys"),
    ] {
        let lock = super::replay::lock(&fixture.state).unwrap();
        let error = files::write_allowed(&lock, &fixture.home, &path, b"x").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(!path.exists());
    }
}

#[test]
fn no_value_reaches_a_log_line_or_an_error() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let mut texts = Vec::new();
    let ok = fixture.seal(Purpose::Secret, "DEMO_KEY", &value);
    texts.push(format!("{ok:?}"));
    fixture.secrets.replace_machine_secrets(std::slice::from_ref(&ok)).unwrap();
    for result in [
        fixture.secrets.replace_machine_secrets(&[ok]),
        fixture.secrets.replace_machine_secrets(&[fixture.seal(Purpose::Secret, "PATH", &value)]),
        fixture.secrets.replace_machine_secrets(&[seal::seal(
            &fixture.identity.public_key(),
            "vm-someone-else",
            Purpose::Secret,
            "DEMO_KEY",
            value.as_bytes(),
        )
        .unwrap()]),
    ] {
        texts.push(format!("{:?}", result.unwrap_err()));
    }
    texts.push(format!("{:?}", fixture.secrets));
    let logs = fixture.logs();
    assert!(logs.len() >= 4, "{logs:?}");
    texts.extend(logs);
    assert_no_value(&[&value], &texts);
}

#[test]
fn requests_built_on_the_device_open_on_the_machine() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let request = super::request::replace_machine_secrets(
        &fixture.identity.public_key(),
        MACHINE,
        &[("DEMO_KEY".to_owned(), zeroize::Zeroizing::new(value.clone()))],
    )
    .unwrap();
    let cmux_remote_protocol::WorkspaceRequest::ReplaceMachineSecrets { items } = request else {
        panic!("not a replace request");
    };
    let wire =
        serde_json::to_string(&cmux_remote_protocol::WorkspaceRequest::ReplaceMachineSecrets {
            items: items.clone(),
        })
        .unwrap();
    assert_eq!(fixture.secrets.replace_machine_secrets(&items).unwrap(), 1);
    // The serialized request carries no value.
    assert!(!wire.contains(&value));
}

#[test]
fn a_symlinked_folder_below_home_is_never_written_through() {
    let fixture = fixture(&["DEMO_KEY"]);
    let outside = fixture._dir.path().join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::create_dir_all(fixture.home.join(".config")).unwrap();
    std::os::unix::fs::symlink(&outside, fixture.home.join(".config/cmux")).unwrap();
    let error = fixture
        .secrets
        .replace_machine_secrets(&[fixture.seal(Purpose::Secret, "DEMO_KEY", &random_hex(16))])
        .unwrap_err();
    assert!(error.message.starts_with("write"), "{error}");
    assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
}

#[test]
fn every_refusal_code_is_listed() {
    use super::replay::Refusal;
    use super::seal::SealError;
    let codes = [Refusal::Stale, Refusal::Replay, Refusal::Busy, Refusal::Write]
        .map(Refusal::code)
        .into_iter()
        .chain(
            [
                SealError::BadNonce,
                SealError::BadEncapsulation,
                SealError::OpenFailed,
                SealError::Random,
                SealError::SealFailed,
            ]
            .map(SealError::code),
        );
    for code in codes {
        assert!(super::REFUSAL_CODES.contains(&code), "{code}");
    }
}
