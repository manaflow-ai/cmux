//! Generated keys and values only: nothing here is a real secret.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{Arc, Mutex};

use cmux_remote_protocol::{ByteString, SealedSecret};

use super::seal::{self, Purpose};
use super::{MachineSecrets, files};
use crate::crypto::StaticIdentity;

const MACHINE: &str = "vm-secrets-test";

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    getrandom::fill(&mut buffer).unwrap();
    buffer.iter().map(|byte| format!("{byte:02x}")).collect()
}

struct Fixture {
    _dir: tempfile::TempDir,
    home: std::path::PathBuf,
    etc: std::path::PathBuf,
    identity: StaticIdentity,
    logs: Arc<Mutex<Vec<String>>>,
    secrets: MachineSecrets,
}

fn fixture(declared: &[&str]) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let etc = dir.path().join("etc");
    std::fs::create_dir_all(home.join(".cmux/machine-config")).unwrap();
    std::fs::create_dir_all(&etc).unwrap();
    std::fs::write(
        home.join(files::MACHINE_CONFIG_STATUS_FILE),
        serde_json::to_vec(&serde_json::json!({
            "state": "done",
            "secrets": { "declared": declared },
        }))
        .unwrap(),
    )
    .unwrap();
    std::fs::write(etc.join("vm-kind"), "owner\n").unwrap();
    // The image's launcher, reduced to its normalization: it drops the
    // model-plane names, so the test process's own environment can't leak in.
    std::fs::write(
        etc.join("agent-auth.sh"),
        "cmux_agent_drop_model_plane_env() { unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
         ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR OPENAI_BASE_URL CODEX_HOME CODEX_API_KEY \
         CMUX_CLAUDE_AUTH CMUX_CODEX_AUTH; }\n",
    )
    .unwrap();
    let identity = StaticIdentity::generate().unwrap();
    let logs = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&logs);
    let secrets = MachineSecrets::new(&identity, MACHINE.to_owned(), home.clone(), etc.clone())
        .with_log(Arc::new(move |line| sink.lock().unwrap().push(line.to_owned())));
    Fixture { _dir: dir, home, etc, identity, logs, secrets }
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
    assert_eq!(opened.as_slice(), value.as_bytes());
    // The hpke crate derives the same public key as the Noise identity.
    assert_eq!(seal::public_key(identity.private_key()).unwrap(), identity.public_key());
}

#[test]
fn wrong_key_machine_purpose_name_or_bytes_never_open() {
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
    assert_eq!(
        open(&identity, MACHINE, Purpose::HarnessLogin, &item),
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
    let error = fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "bash", &value), false)
        .unwrap_err();
    assert!(error.message.starts_with("bad-name"), "{error}");
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
    let login_as_secret = fixture.seal(Purpose::HarnessLogin, "DEMO_KEY", &value);
    for item in [other_machine, other_key, login_as_secret] {
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
        let error = files::write_allowed(&fixture.home, &path, b"x").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(!path.exists());
    }
}

#[test]
fn a_claude_login_is_installed_0600_where_claude_reads_it() {
    let fixture = fixture(&[]);
    std::fs::create_dir_all(fixture.home.join(".claude")).unwrap();
    std::fs::write(fixture.home.join(".claude/settings.json"), r#"{"theme":"dark"}"#).unwrap();
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let item = fixture.seal(Purpose::HarnessLogin, "claude", &token);
    assert_eq!(fixture.secrets.install_harness_login(&item, false).unwrap(), "claude");
    let settings: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture.home.join(".claude/settings.json")).unwrap())
            .unwrap();
    assert_eq!(settings["theme"], "dark");
    assert_eq!(settings["env"]["CLAUDE_CODE_OAUTH_TOKEN"], token.as_str());
    let credentials: serde_json::Value = serde_json::from_slice(
        &std::fs::read(fixture.home.join(".claude/.credentials.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(credentials["claudeAiOauth"]["accessToken"], token.as_str());
    for path in super::harness::HarnessLogin::Claude.paths(&fixture.home) {
        assert_eq!(mode(&path), 0o600, "{}", path.display());
        assert_eq!(mode(path.parent().unwrap()), 0o700, "{}", path.display());
    }
    assert_eq!(
        std::fs::read_to_string(fixture.home.join(".config/cmux/agent-auth/claude")).unwrap(),
        "own\n"
    );
    // The same sealed login again is a replay.
    let error = fixture.secrets.install_harness_login(&item, false).unwrap_err();
    assert!(error.message.starts_with("replay"), "{error}");
    assert_no_value(&[&token], &fixture.logs());
}

#[test]
fn a_codex_login_is_installed_0600() {
    let fixture = fixture(&[]);
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
    assert_eq!(fixture.secrets.install_harness_login(&item, false).unwrap(), "codex");
    let path = fixture.home.join(".codex/auth.json");
    assert_eq!(mode(&path), 0o600);
    let written: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(written, serde_json::from_str::<serde_json::Value>(&auth).unwrap());
}

#[test]
fn a_login_is_refused_off_an_owner_guest_or_next_to_a_custom_endpoint() {
    let fixture = fixture(&[]);
    let token = || format!("sk-ant-oat01-{}", random_hex(24));
    std::fs::write(fixture.etc.join("vm-kind"), "team\n").unwrap();
    let error = fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "claude", &token()), false)
        .unwrap_err();
    assert!(error.message.starts_with("not-owner-guest"), "{error}");
    assert!(!error.retryable);
    // A guest that hasn't bound yet has no kind record: retryable.
    std::fs::remove_file(fixture.etc.join("vm-kind")).unwrap();
    let error = fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "claude", &token()), false)
        .unwrap_err();
    assert!(error.message.starts_with("not-ready") && error.retryable, "{error}");
    std::fs::write(fixture.etc.join("vm-kind"), "team\n").unwrap();
    // The DEV creator allowance lets a team guest through (test builds are DEV builds).
    fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "claude", &token()), true)
        .unwrap();
    std::fs::write(fixture.etc.join("vm-kind"), "owner\n").unwrap();
    std::fs::write(
        fixture.home.join(".claude/settings.json"),
        r#"{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid"}}"#,
    )
    .unwrap();
    let error = fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "claude", &token()), false)
        .unwrap_err();
    assert!(error.message.starts_with("conflict"), "{error}");
    let error = fixture
        .secrets
        .install_harness_login(
            &fixture.seal(Purpose::HarnessLogin, "claude", "not-a-token-at-all"),
            false,
        )
        .unwrap_err();
    assert!(error.message.starts_with("invalid-credential"), "{error}");
}

#[test]
fn no_value_reaches_a_log_line_or_an_error() {
    let fixture = fixture(&["DEMO_KEY"]);
    let value = random_hex(16);
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let mut texts = Vec::new();
    let ok = fixture.seal(Purpose::Secret, "DEMO_KEY", &value);
    texts.push(format!("{ok:?}"));
    fixture.secrets.replace_machine_secrets(&[ok.clone()]).unwrap();
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
    std::fs::write(fixture.etc.join("vm-kind"), "team\n").unwrap();
    let error = fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "claude", &token), false)
        .unwrap_err();
    texts.push(format!("{error:?}"));
    texts.push(format!("{:?}", fixture.secrets));
    let logs = fixture.logs();
    assert!(logs.len() >= 5, "{logs:?}");
    texts.extend(logs);
    assert_no_value(&[&value, &token], &texts);
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
    assert_eq!(fixture.secrets.replace_machine_secrets(&items).unwrap(), 1);
    let token = format!("sk-ant-oat01-{}", random_hex(24));
    let request = super::request::install_harness_login(
        &fixture.identity.public_key(),
        MACHINE,
        "claude",
        token.as_bytes(),
        false,
    )
    .unwrap();
    let cmux_remote_protocol::WorkspaceRequest::InstallHarnessLogin { item, allow_team_guest } =
        request
    else {
        panic!("not a login request");
    };
    assert_eq!(fixture.secrets.install_harness_login(&item, allow_team_guest).unwrap(), "claude");
    // The serialized request carries no value.
    let wire =
        serde_json::to_string(&cmux_remote_protocol::WorkspaceRequest::InstallHarnessLogin {
            item,
            allow_team_guest,
        })
        .unwrap();
    assert!(!wire.contains(&token) && !wire.contains(&value));
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
    std::os::unix::fs::symlink(&outside, fixture.home.join(".claude")).unwrap();
    let error = fixture
        .secrets
        .install_harness_login(
            &fixture.seal(
                Purpose::HarnessLogin,
                "claude",
                &format!("sk-ant-oat01-{}", random_hex(24)),
            ),
            false,
        )
        .unwrap_err();
    assert!(error.message.starts_with("conflict") || error.message.starts_with("write"), "{error}");
    assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
}

#[test]
fn a_codex_config_that_can_reach_another_provider_refuses_the_login() {
    let fixture = fixture(&[]);
    std::fs::create_dir_all(fixture.home.join(".codex")).unwrap();
    let auth = serde_json::json!({
        "tokens": {
            "access_token": random_hex(16),
            "refresh_token": random_hex(16),
            "id_token": random_hex(16),
        },
    })
    .to_string();
    for config in [
        "model_provider = \"custom\"\n",
        "profile = \"work\"\n[profiles.work]\nmodel_provider = \"custom\"\n",
        "[profiles.other]\nmodel_provider = \"custom\"\n",
        "[model_providers.custom]\nbase_url = \"https://example.invalid\"\nrequires_openai_auth = true\n",
        "[model_providers.openai]\nbase_url = \"https://example.invalid\"\n",
        "openai_base_url = \"https://example.invalid\"\n",
        "profile = \"missing\"\n",
    ] {
        std::fs::write(fixture.home.join(".codex/config.toml"), config).unwrap();
        let error = fixture
            .secrets
            .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "codex", &auth), false)
            .unwrap_err();
        assert!(error.message.starts_with("conflict"), "{config}: {error}");
    }
    assert!(!fixture.home.join(".codex/auth.json").exists());
    std::fs::write(
        fixture.home.join(".codex/config.toml"),
        "model_provider = \"openai\"\n[profiles.fast]\nmodel = \"x\"\n",
    )
    .unwrap();
    fixture
        .secrets
        .install_harness_login(&fixture.seal(Purpose::HarnessLogin, "codex", &auth), false)
        .unwrap();
}
