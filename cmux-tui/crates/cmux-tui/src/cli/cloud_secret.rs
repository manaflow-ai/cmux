//! `cmux cloud secret set|ls|rm NAME [--repo OWNER/NAME]`: the values a Cloud machine's
//! `.cmux/machine.toml` names under `[secrets]`, kept on this Mac.
//!
//! A value goes into the login Keychain (service `cmux-cloud-secret`, account `<scope>/<NAME>`,
//! scope `OWNER/NAME` or `*` for every repo) through `security -i` on stdin, as `cmux harness
//! secret set` does: it is read from a no-echo prompt or stdin, never from argv, and is never
//! printed or logged. `~/.config/cmux/cloud-secrets.json` (0600) lists the accounts and when each
//! was set, never a value: `ls` reads it, and the app's `cloud deliver-secrets` uses the times to
//! deliver a changed value again. Values reach a machine only over its daemon link.

use std::path::PathBuf;

use acpmux::cli::harness_secret::{read_value, run_store, store_item};
use serde_json::{Map, Value, json};

use super::{OutputMode, UsageError};

/// The Keychain service of every Cloud secret (`CloudMachineSecrets.service` in the app).
pub(super) const SERVICE: &str = "cmux-cloud-secret";

/// `Some(exit code)` when `args` is `cloud secret …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, secret, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || secret != "secret" {
        return None;
    }
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    // A failure while running (a locked Keychain, the index) is not a usage error: it may be retried.
    Some(match run(command, global.output) {
        Ok(code) => code,
        Err(message) => super::app::failure(
            "cloud_secret.failed",
            &format!("cmux: {message}"),
            global.output,
            1,
        ),
    })
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Command {
    Set { account: String },
    Ls,
    Rm { account: String },
}

/// A cloud secret's size: at least 8 characters (Unicode scalars), so the machine's applier, which
/// masks values of 4 characters and more, masks it wherever setup prints it (shorter strings would
/// garble ordinary output), and at most 16 KiB, so the most names a machine config declares (100)
/// still fit one delivery.
const MIN_VALUE_CHARS: usize = 8;
const MAX_VALUE_BYTES: usize = 16 * 1024;

fn value_size(value: &str) -> Result<(), String> {
    if value.chars().count() < MIN_VALUE_CHARS {
        return Err(format!(
            "the value is shorter than {MIN_VALUE_CHARS} characters: a secret that short is not one"
        ));
    }
    if value.len() > MAX_VALUE_BYTES {
        return Err(format!("the value is longer than {} KiB", MAX_VALUE_BYTES / 1024));
    }
    Ok(())
}

const USAGE: &str =
    "usage: cmux cloud secret set|rm NAME [--repo OWNER/NAME], or cmux cloud secret ls";

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let Some((verb, rest)) = args.split_first() else { return Err(UsageError::new(USAGE)) };
    if verb == "ls" || verb == "list" {
        return if rest.is_empty() { Ok(Command::Ls) } else { Err(UsageError::new(USAGE)) };
    }
    let (name, scope) = match rest {
        [name] => (name, "*".to_owned()),
        [name, flag, repo] if flag == "--repo" => (name, repo_scope(repo)?),
        _ => return Err(UsageError::new(USAGE)),
    };
    valid_name(name)?;
    let account = format!("{scope}/{name}");
    match verb.as_str() {
        "set" => Ok(Command::Set { account }),
        "rm" | "remove" => Ok(Command::Rm { account }),
        _ => Err(UsageError::new(USAGE)),
    }
}

/// The machine config's own name rules (`[A-Za-z_][A-Za-z0-9_]*`, at most 128, not a name the
/// machine's shell or cmux owns), so a stored secret can always be delivered.
fn valid_name(name: &str) -> Result<(), UsageError> {
    let plain = name.len() <= 128
        && name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    let upper = name.to_ascii_uppercase();
    // The machine config's own list (CloudMachineConfig.swift's applier, RESERVED), so a stored name can
    // always be declared: what bash owns or evaluates on read, the model plane's keys, cmux's.
    #[rustfmt::skip]
    const RESERVED: &[&str] = &[
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PWD", "OLDPWD", "TERM",
        "BASH", "BASHOPTS", "BASHPID", "CDPATH", "COLUMNS", "DIRSTACK", "EPOCHREALTIME", "EPOCHSECONDS", "EUID", "EXECIGNORE",
        "FCEDIT", "FIGNORE", "FUNCNAME", "FUNCNEST", "GLOBIGNORE", "GROUPS", "HOSTFILE", "HOSTNAME", "HOSTTYPE", "IGNOREEOF",
        "INPUTRC", "LINENO", "LINES", "MACHTYPE", "MAIL", "MAILCHECK", "MAILPATH", "OPTARG", "OPTERR", "OPTIND", "OSTYPE",
        "PIPESTATUS", "POSIXLY_CORRECT", "PPID", "RANDOM", "REPLY", "SECONDS", "SHELLOPTS", "SHLVL", "SRANDOM", "TIMEFORMAT",
        "TMOUT", "TMPDIR", "UID", "_", "PS0", "PS1", "PS2", "PS3", "PS4", "HISTCMD", "HISTCONTROL", "HISTFILE", "HISTFILESIZE",
        "HISTIGNORE", "HISTSIZE", "HISTTIMEFORMAT", "LANG", "LANGUAGE", "TZ", "TZDIR", "NLSPATH",
        "ZDOTDIR", "FPATH", "MODULE_PATH", "PROMPT", "PROMPT2", "PROMPT3", "PROMPT4", "RPROMPT", "RPROMPT2", "RPS1",
        "RPS2", "NULLCMD", "READNULLCMD", "HISTCHARS", "WATCHFMT", "PERIOD", "KEYTIMEOUT", "SAVEHIST", "STTY",
        "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "PYTHONSAFEPATH",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
    ];
    let reserved = RESERVED.contains(&upper.as_str())
        || [
            "LD_",
            "DYLD_",
            "CMUX_",
            "BASH_",
            "COMP_",
            "PROMPT_",
            "READLINE_",
            "COPROC",
            "LC_",
            "ZSH_",
        ]
        .iter()
        .any(|p| upper.starts_with(p));
    if !plain || reserved {
        return Err(UsageError::new(format!(
            "{name:?} is not a secret name: [A-Za-z_][A-Za-z0-9_]*, and not PATH, HOME, LD_*, CMUX_* or another the machine owns"
        )));
    }
    Ok(())
}

/// `OWNER/NAME` as GitHub spells them, lowercased (a repo's scope does not depend on its case).
fn repo_scope(repo: &str) -> Result<String, UsageError> {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p != "."
            && p != ".."
            && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    match repo.split_once('/') {
        Some((owner, name)) if part(owner) && part(name) => Ok(repo.to_ascii_lowercase()),
        _ => Err(UsageError::new(format!("--repo {repo:?} is not OWNER/NAME"))),
    }
}

fn index_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config/cmux/cloud-secrets.json"))
}

/// The index's `secrets` object: empty when there is no file (nothing set yet); an error for a file
/// that is there but cannot be read as one, so a later write never drops what it listed.
fn read_index(path: &std::path::Path) -> Result<Map<String, Value>, String> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    let bad = || format!("{} is not a cloud secrets index; fix or remove it", path.display());
    let secrets = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|value| value.get("secrets").and_then(Value::as_object).cloned())
        .ok_or_else(bad)?;
    // Every entry an account and a set time, nothing else: `ls` prints them, so a stray value never shows.
    // A mark the app reads as an Int64: never above i64::MAX, so the next mark (+1) always fits too.
    let mark = |at: &Value| at.as_u64().is_some_and(|ms| ms <= i64::MAX as u64);
    if secrets.iter().all(|(account, at)| valid_account(account) && mark(at)) {
        Ok(secrets)
    } else {
        Err(bad())
    }
}

/// `<scope>/<NAME>` as `parse` makes it: scope `*` or `owner/name` (lowercased), a usable name.
fn valid_account(account: &str) -> bool {
    let Some((scope, name)) = account.rsplit_once('/') else { return false };
    valid_name(name).is_ok() && (scope == "*" || repo_scope(scope).is_ok_and(|s| s == scope))
}

fn write_index(path: &std::path::Path, secrets: Map<String, Value>) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let folder = path.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
    std::fs::create_dir_all(folder)?;
    let temporary = folder.join(format!(".cloud-secrets.json.{}", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
    file.write_all(
        serde_json::to_string_pretty(&json!({"version": 1, "secrets": secrets}))?.as_bytes(),
    )?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)
}

/// Holds `<index>.lock` (flock) for one read-modify-write of the index; released on drop.
struct IndexLock(
    // Never read: holding the open file is what keeps the flock until drop.
    #[allow(dead_code)] std::fs::File,
);

impl IndexLock {
    fn take(index: &std::path::Path) -> std::io::Result<Self> {
        use std::os::fd::AsRawFd as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        std::fs::create_dir_all(index.parent().ok_or_else(|| std::io::Error::other("no folder"))?)?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(index.with_extension("json.lock"))?;
        // SAFETY: a valid fd we own; blocks until another `cloud secret` run releases it.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Self(file))
    }
}

fn run(command: Command, output: OutputMode) -> Result<i32, String> {
    let fail = |message: String| message;
    let path = index_path().ok_or_else(|| fail("HOME is not set".into()))?;
    let _lock = IndexLock::take(&path).map_err(|e| fail(format!("cannot lock the index: {e}")))?;
    let mut secrets = read_index(&path)?;
    let answer = match command {
        Command::Ls => {
            let rows: Vec<Value> = secrets
                .iter()
                .map(|(account, at)| {
                    let (scope, name) = account.rsplit_once('/').unwrap_or(("*", account));
                    json!({"name": name, "scope": scope, "set_at_ms": at})
                })
                .collect();
            json!({"secrets": rows})
        }
        Command::Set { account } => {
            if std::env::consts::OS != "macos" {
                return Err(fail("cloud secrets live in this Mac's Keychain: run it on the Mac with the cmux app".into()));
            }
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            // Strictly later than every mark the index holds: two sets in the same millisecond still differ,
            // so a machine that has the first one gets the second. Worked out before anything is stored.
            let newest = secrets.values().filter_map(Value::as_u64).max().unwrap_or(0);
            let mark = now.max(newest + 1);
            if mark > i64::MAX as u64 {
                return Err(fail("the index's newest mark is too large; remove the index and set the secrets again".into()));
            }
            let (_, name) = account.rsplit_once('/').unwrap_or(("*", &account));
            let value = read_value(name).map_err(|e| fail(e.to_string()))?;
            value_size(value.as_str())?;
            let store = store_item(
                "macos",
                SERVICE,
                &account,
                &format!("cmux cloud secret {account}"),
                value.as_str(),
            )
            .map_err(|e| fail(e.to_string()))?;
            drop(value);
            run_store(&store).map_err(|e| fail(e.to_string()))?;
            secrets.insert(account.clone(), json!(mark));
            write_index(&path, secrets)
                .map_err(|e| fail(format!("stored, but the index was not written: {e}")))?;
            json!({"stored": account, "next": "cmux cloud deliver-secrets --target machine:<id>"})
        }
        Command::Rm { account } => {
            if std::env::consts::OS != "macos" {
                return Err(fail("cloud secrets live in this Mac's Keychain: run it on the Mac with the cmux app".into()));
            }
            // The account is a checked name and scope, never a value: argv is fine here.
            let status = cmux_process::Command::new("/usr/bin/security")
                .args(["delete-generic-password", "-s", SERVICE, "-a", &account])
                .stdout(cmux_process::Stdio::null())
                .stderr(cmux_process::Stdio::null())
                .status()
                .map_err(|e| fail(format!("cannot run security: {e}")))?;
            // 44: no such item, already gone. Anything else keeps it listed.
            if !status.success() && status.code() != Some(44) {
                return Err(fail(format!(
                    "the Keychain kept {account} ({status}); it stays listed"
                )));
            }
            let removed = secrets.remove(&account).is_some();
            write_index(&path, secrets).map_err(|e| fail(e.to_string()))?;
            json!({"removed": account, "was_listed": removed})
        }
    };
    Ok(super::wire::print_local_success(&answer, output))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn a_value_is_long_enough_to_mask_and_small_enough_to_deliver() {
        assert!(value_size("1234567").is_err(), "under 8 characters");
        assert!(
            value_size("🔒🔑🔒🔑").is_err(),
            "16 bytes, but 4 characters: never under the mask's floor"
        );
        assert!(value_size("12345678").is_ok());
        assert!(value_size(&"x".repeat(16 * 1024)).is_ok());
        assert!(value_size(&"x".repeat(16 * 1024 + 1)).is_err(), "over 16 KiB");
    }

    #[test]
    fn a_secret_is_named_with_its_scope_and_never_takes_a_value_argument() {
        assert_eq!(
            parse(&words("set DATABASE_URL")),
            Ok(Command::Set { account: "*/DATABASE_URL".into() })
        );
        assert_eq!(
            parse(&words("set API_KEY --repo Manaflow-AI/cmux")),
            Ok(Command::Set { account: "manaflow-ai/cmux/API_KEY".into() })
        );
        assert_eq!(parse(&words("rm API_KEY")), Ok(Command::Rm { account: "*/API_KEY".into() }));
        assert_eq!(parse(&words("ls")), Ok(Command::Ls));
        // A value on the command line would be in argv for every process to read.
        assert!(parse(&words("set API_KEY sk-live-123")).is_err());
        for bad in [
            "set 1BAD",
            "set PATH",
            "set CMUX_TOKEN",
            "set ld_preload",
            "set OPTIND",
            "set PS1",
            "set BASH_FUNC_x",
            "set LC_ALL",
            "set TZ",
            "set A-B",
            "set API_KEY --repo ../x",
            "set API_KEY --repo owner",
            "ls extra",
            "get X",
        ] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn the_index_holds_accounts_and_times_only_and_is_owner_only() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cmux/cloud-secrets.json");
        assert!(read_index(&path).unwrap().is_empty(), "no file: nothing set yet");
        let mut secrets = Map::new();
        secrets.insert("*/API_KEY".into(), json!(1));
        write_index(&path, secrets).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(read_index(&path).unwrap().get("*/API_KEY"), Some(&json!(1)));
        std::fs::write(&path, b"{broken").unwrap();
        assert!(read_index(&path).is_err(), "a damaged index is an error, never empty");
        for bad in [
            r#"{"secrets":{"*/API_KEY":"sk-live-123"}}"#,
            r#"{"secrets":{"*/API_KEY":true}}"#,
            r#"{"secrets":{"*/API_KEY":1.5}}"#,
            r#"{"secrets":{"*/API_KEY":-1}}"#,
            r#"{"secrets":{"API_KEY":1}}"#,
            r#"{"secrets":{"Acme/App/API_KEY":1}}"#,
            r#"{"secrets":{"*/PATH":1}}"#,
            r#"{"secrets":{"*/API_KEY":9223372036854775808}}"#,
            r#"{"secrets":{"*/API_KEY":18446744073709551615}}"#,
        ] {
            std::fs::write(&path, bad).unwrap();
            assert!(read_index(&path).is_err(), "{bad}");
        }
        std::fs::write(&path, r#"{"secrets":{"*/API_KEY":9223372036854775807}}"#).unwrap();
        assert!(read_index(&path).is_ok(), "i64::MAX is the largest mark the app reads");
        std::fs::write(&path, r#"{"secrets":{"acme/app/API_KEY":2,"*/DATABASE_URL":3}}"#).unwrap();
        assert_eq!(read_index(&path).unwrap().len(), 2);
    }
}
