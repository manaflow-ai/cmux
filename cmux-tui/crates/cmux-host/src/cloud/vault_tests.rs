//! The vault pull with a fake route, a memory store and a memory secrets file; then the real file writer
//! and the login profile hook on a temp folder.

use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

use cmux_vault_e2e::b64;
use cmux_vault_e2e::crypto::{DeviceKey, seal_delivery};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::*;
use crate::cloud::client::MemoryStore;
use crate::cloud::vault_file::{PROFILE_TEXT, SecretsFile, ensure_profile_hook};

const VM: &str = "vm_aaaaaaaaaaaaaaaaaaaa";
const OTHER: &str = "vm_bbbbbbbbbbbbbbbbbbbb";

#[derive(Default)]
struct MemEnv {
    text: String,
    writes: usize,
    refuse: Option<&'static str>,
}

impl EnvFile for MemEnv {
    fn read(&mut self) -> Result<Zeroizing<String>, &'static str> {
        match self.refuse {
            Some(code) => Err(code),
            None => Ok(Zeroizing::new(self.text.clone())),
        }
    }
    fn write(&mut self, text: &str) -> Result<(), &'static str> {
        self.writes += 1;
        self.text = text.to_owned();
        Ok(())
    }
}

/// One item sealed to `daemon` for `machine`, as the route answers it.
fn item(
    daemon: &DeviceKey,
    machine: &str,
    vault: &str,
    name: &str,
    revision: u64,
    value: &str,
) -> Value {
    let sealed =
        seal_delivery(daemon.public_bytes(), machine, name, revision, value.as_bytes()).unwrap();
    json!({"vault": vault, "name": name, "revision": revision, "enc": b64::encode(&sealed.enc), "ct": b64::encode(&sealed.ct)})
}

fn answer(machine: &str, items: Vec<Value>) -> Answer {
    Answer::Http { status: 200, body: json!({"machine": machine, "items": items}) }
}

fn pull(daemon: &DeviceKey, got: Answer, store: &mut MemoryStore, env: &mut MemEnv) -> Outcome {
    pull_once(
        |path| {
            assert_eq!(path, MACHINE_PATH);
            got
        },
        VM,
        Some(daemon.private_bytes()),
        store,
        env,
    )
}

fn state(store: &MemoryStore) -> State {
    serde_json::from_str(&store.read(STATE_FILE).unwrap()).unwrap()
}

#[test]
fn a_delivery_is_written_beside_the_lines_the_vault_does_not_own() {
    let daemon = DeviceKey::generate().unwrap();
    let mut store = MemoryStore::default();
    let mut env = MemEnv { text: "export MAC_SENT='from-the-mac'\n".into(), ..MemEnv::default() };
    let got = answer(VM, vec![item(&daemon, VM, "personal", "API_KEY", 1, "s3cret 'quoted'")]);
    let outcome = pull(&daemon, got, &mut store, &mut env);
    let Outcome::Applied { applied, changed: true, .. } = &outcome else { panic!("{outcome:?}") };
    assert_eq!(applied.written, ["API_KEY"]);
    assert!(env.text.contains("export MAC_SENT='from-the-mac'\n"), "{}", env.text);
    assert!(env.text.contains("export API_KEY='s3cret '\\''quoted'\\'''\n"), "{}", env.text);
    assert_eq!(store.mode_of(STATE_FILE), Some(0o600));
    let held = state(&store);
    assert_eq!(held.revisions.get("API_KEY"), Some(&1));
    assert!(held.owned.contains("API_KEY"));
    // The journal line names names, never a value.
    let line = note(&outcome);
    assert!(line.contains("API_KEY") && !line.contains("s3cret"), "{line}");
}

#[test]
fn the_same_answer_again_rewrites_nothing_and_personal_wins_over_team() {
    let daemon = DeviceKey::generate().unwrap();
    let mut store = MemoryStore::default();
    let mut env = MemEnv::default();
    let items = || {
        vec![
            item(&daemon, VM, "team", "SHARED", 1, "team-value"),
            item(&daemon, VM, "personal", "SHARED", 1, "my-value"),
        ]
    };
    pull(&daemon, answer(VM, items()), &mut store, &mut env);
    assert!(env.text.contains("export SHARED='my-value'\n"), "{}", env.text);
    assert!(!env.text.contains("team-value"));
    assert_eq!(env.writes, 1);
    let again = pull(&daemon, answer(VM, items()), &mut store, &mut env);
    assert!(matches!(again, Outcome::Applied { changed: false, .. }), "{again:?}");
    assert!(quiet(&again));
    assert_eq!(
        env.writes, 1,
        "an unchanged answer never touches the file (acpmux rereads on a change)"
    );
}

#[test]
fn a_name_the_vault_stopped_sending_is_removed_and_other_lines_stay() {
    let daemon = DeviceKey::generate().unwrap();
    let mut store = MemoryStore::default();
    let mut env = MemEnv { text: "export KEEP='mac'\n".into(), ..MemEnv::default() };
    let both = vec![
        item(&daemon, VM, "personal", "GONE", 1, "old"),
        item(&daemon, VM, "personal", "STAYS", 1, "still"),
    ];
    pull(&daemon, answer(VM, both), &mut store, &mut env);
    let outcome = pull(
        &daemon,
        answer(VM, vec![item(&daemon, VM, "personal", "STAYS", 1, "still")]),
        &mut store,
        &mut env,
    );
    let Outcome::Applied { applied, .. } = &outcome else { panic!("{outcome:?}") };
    assert_eq!(applied.removed, ["GONE"]);
    assert!(!env.text.contains("GONE"), "{}", env.text);
    assert!(
        env.text.contains("export KEEP='mac'\n") && env.text.contains("export STAYS='still'\n")
    );
    assert!(!state(&store).owned.contains("GONE"));
    // The vault sends nothing at all: its names go, the header too, the rest stays.
    pull(&daemon, answer(VM, vec![]), &mut store, &mut env);
    assert_eq!(env.text, "export KEEP='mac'\n");
}

#[test]
fn a_rollback_is_refused_and_the_held_value_is_kept() {
    let daemon = DeviceKey::generate().unwrap();
    let mut store = MemoryStore::default();
    let mut env = MemEnv::default();
    pull(
        &daemon,
        answer(VM, vec![item(&daemon, VM, "personal", "TOKEN", 3, "new")]),
        &mut store,
        &mut env,
    );
    let outcome = pull(
        &daemon,
        answer(VM, vec![item(&daemon, VM, "personal", "TOKEN", 2, "old")]),
        &mut store,
        &mut env,
    );
    let Outcome::Applied { applied, kept, .. } = &outcome else { panic!("{outcome:?}") };
    assert_eq!(applied.refused, [("TOKEN".to_owned(), "vault.rollback")]);
    assert_eq!(kept, &["TOKEN"]);
    assert!(applied.removed.is_empty());
    assert!(
        env.text.contains("export TOKEN='new'\n") && !env.text.contains("'old'"),
        "{}",
        env.text
    );
    let held = state(&store);
    assert_eq!(held.revisions.get("TOKEN"), Some(&3));
    assert!(held.owned.contains("TOKEN"), "still the vault's: a later stop removes it");
}

#[test]
fn another_machines_answer_or_value_is_refused() {
    let daemon = DeviceKey::generate().unwrap();
    let mut store = MemoryStore::default();
    let mut env = MemEnv::default();
    pull(
        &daemon,
        answer(VM, vec![item(&daemon, VM, "personal", "MINE", 1, "v")]),
        &mut store,
        &mut env,
    );
    let before = (env.text.clone(), store.read(STATE_FILE));
    // An answer naming another machine changes nothing, not even a removal.
    let other = pull(&daemon, answer(OTHER, vec![]), &mut store, &mut env);
    assert_eq!(other, Outcome::Failed("vault.other_machine"));
    assert_eq!((env.text.clone(), store.read(STATE_FILE)), before);
    // A value sealed for another machine, moved into this machine's answer, does not open.
    let moved = pull(
        &daemon,
        answer(
            VM,
            vec![
                item(&daemon, VM, "personal", "MINE", 1, "v"),
                item(&daemon, OTHER, "personal", "THEIRS", 1, "stolen"),
            ],
        ),
        &mut store,
        &mut env,
    );
    let Outcome::Applied { applied, .. } = &moved else { panic!("{moved:?}") };
    assert_eq!(applied.refused.len(), 1);
    assert_eq!(applied.refused[0].0, "THEIRS");
    assert!(!env.text.contains("THEIRS") && !env.text.contains("stolen"));
}

#[test]
fn off_unreachable_and_refused_answers_change_nothing() {
    let daemon = DeviceKey::generate().unwrap();
    let not_found = json!({"error": {"code": "vault.not_found", "message": "m"}});
    for (got, expected) in [
        (Answer::Http { status: 404, body: not_found }, Outcome::Off),
        (Answer::Http { status: 404, body: json!("Not Found") }, Outcome::Failed("vault.no_route")),
        (
            Answer::Http { status: 404, body: json!({"error": {"code": "route.not_found"}}) },
            Outcome::Failed("vault.no_route"),
        ),
        (Answer::Http { status: 503, body: json!({}) }, Outcome::Failed("vault.unavailable")),
        (Answer::Http { status: 403, body: json!({}) }, Outcome::Failed("vault.forbidden")),
        (Answer::Transport, Outcome::Failed("vault.unreachable")),
        (
            Answer::Http { status: 200, body: json!({"items": []}) },
            Outcome::Failed("vault.malformed"),
        ),
    ] {
        let mut store = MemoryStore::default();
        let mut env = MemEnv { text: "export KEEP='x'\n".into(), ..MemEnv::default() };
        assert_eq!(pull(&daemon, got, &mut store, &mut env), expected);
        assert_eq!((env.writes, store.read(STATE_FILE)), (0, None));
    }
    assert_eq!(note(&Outcome::Off), "vault: off for this machine; looking again hourly");
    // No identity file yet, or a secrets file this writer may not replace: nothing written.
    let mut store = MemoryStore::default();
    let mut env = MemEnv::default();
    let got = answer(VM, vec![item(&daemon, VM, "personal", "A", 1, "v")]);
    assert_eq!(
        pull_once(|_| got, VM, None, &mut store, &mut env),
        Outcome::Failed("vault.no_daemon_key")
    );
    let mut env = MemEnv { refuse: Some("vault.secrets_symlink"), ..MemEnv::default() };
    let got = answer(VM, vec![item(&daemon, VM, "personal", "A", 1, "v")]);
    assert_eq!(pull(&daemon, got, &mut store, &mut env), Outcome::Failed("vault.secrets_symlink"));
    assert_eq!((env.writes, store.read(STATE_FILE)), (0, None));
}

fn me() -> (u32, u32) {
    // SAFETY: getuid and getgid have no preconditions.
    unsafe { (libc::getuid(), libc::getgid()) }
}

#[test]
fn the_secrets_file_is_private_atomic_and_never_written_through_a_symlink() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir(&home).unwrap();
    let (uid, gid) = me();
    let mut file = SecretsFile { home: home.clone(), uid, gid };
    assert_eq!(&*file.read().unwrap(), "", "no file yet reads as empty");
    file.write("export A='1'\n").unwrap();
    let path = home.join(SECRETS_FILE);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "export A='1'\n");
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let folder = std::fs::metadata(home.join(".config/cmux")).unwrap();
    assert_eq!(folder.permissions().mode() & 0o777, 0o700);
    assert_eq!(folder.uid(), uid);
    assert_eq!(&*file.read().unwrap(), "export A='1'\n");
    // No temporary is left beside it.
    let names: Vec<_> = std::fs::read_dir(home.join(".config/cmux"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(names, [std::ffi::OsString::from("machine-secrets.env")]);

    // A symlink in place of the file is never read or replaced.
    let elsewhere = dir.path().join("elsewhere");
    std::fs::write(&elsewhere, "export B='2'\n").unwrap();
    std::fs::remove_file(&path).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &path).unwrap();
    assert_eq!(file.read().unwrap_err(), "vault.secrets_symlink");
    assert!(std::fs::symlink_metadata(&path).unwrap().file_type().is_symlink());

    // Nor a symlinked folder on the way: the write goes nowhere.
    let home2 = dir.path().join("home2");
    std::fs::create_dir(&home2).unwrap();
    let target = dir.path().join("target");
    std::fs::create_dir(&target).unwrap();
    std::os::unix::fs::symlink(&target, home2.join(".config")).unwrap();
    let mut file2 = SecretsFile { home: home2, uid, gid };
    assert_eq!(file2.write("export C='3'\n").unwrap_err(), "vault.folder_not_owned");
    assert!(std::fs::read_dir(&target).unwrap().next().is_none());

    // A home of another user is not written into.
    let mut theirs = SecretsFile { home, uid: uid.wrapping_add(1), gid };
    assert_eq!(theirs.write("export D='4'\n").unwrap_err(), "vault.folder_not_owned");
}

#[test]
fn the_login_profile_hook_is_made_once_and_someones_own_file_is_left() {
    let dir = tempfile::tempdir().unwrap();
    let hook = dir.path().join("etc/profile.d/cmux-vault.sh");
    assert_eq!(ensure_profile_hook(&hook), Ok(true));
    assert_eq!(std::fs::read_to_string(&hook).unwrap(), PROFILE_TEXT);
    assert_eq!(std::fs::metadata(&hook).unwrap().permissions().mode() & 0o777, 0o644);
    assert_eq!(ensure_profile_hook(&hook), Ok(false));
    std::fs::write(&hook, "# my own\n").unwrap();
    assert_eq!(ensure_profile_hook(&hook), Err("vault.profile_not_managed"));
    assert_eq!(std::fs::read_to_string(&hook).unwrap(), "# my own\n");
}

/// The hook, run by a login shell's sh: the file's names arrive, a symlinked file is skipped, and a
/// machine setup run (CMUX_MACHINE_SETUP) never sees them.
#[test]
fn a_login_shell_reading_the_hook_sees_the_delivered_names() {
    let dir = tempfile::tempdir().unwrap();
    let hook = dir.path().join("cmux-vault.sh");
    std::fs::write(&hook, PROFILE_TEXT).unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join(".config/cmux")).unwrap();
    std::fs::write(home.join(SECRETS_FILE), "export VAULT_NAME='it '\\''arrived'\\'''\n").unwrap();
    let run = |setup: bool| {
        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.arg("-c").arg(format!(". '{}'; printf %s \"${{VAULT_NAME-unset}}\"", hook.display()));
        cmd.env_clear().env("HOME", &home);
        if setup {
            cmd.env("CMUX_MACHINE_SETUP", "1");
        }
        String::from_utf8(cmd.output().unwrap().stdout).unwrap()
    };
    assert_eq!(run(false), "it 'arrived'");
    assert_eq!(run(true), "unset");
}
