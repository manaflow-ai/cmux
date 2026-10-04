//! Process roles: the `roles` object of `server.json` (server.md 5.1).
//!
//! A process role is a named program that `cmux host run` supervises beside
//! the built-in roles. This module only parses and validates the config;
//! [`crate::role_proc`] decides restarts and the host crate runs processes.
//! An invalid entry is refused alone: the others still run.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{Map, Value};

/// Names of the built-in roles (server.md 5). A process role cannot use them.
pub const RESERVED_NAMES: &[&str] =
    &["session", "link", "apps", "postgres", "browser", "automations", "health", "updater", "team"];

/// Default and largest stop grace (SIGTERM, then SIGKILL).
pub const DEFAULT_STOP_GRACE: Duration = Duration::from_secs(10);
pub const MAX_STOP_GRACE: Duration = Duration::from_secs(60);

/// Where the program comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Program {
    /// A bare file name in `<current>/bin/` of the store profile.
    Store(String),
    /// An absolute path. The host checks ownership and modes at spawn.
    Path(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestartPolicy {
    /// Restart after every exit.
    Always,
    /// Restart after a failed exit; a clean exit (code 0) ends the role.
    OnFailure,
    /// Never restart.
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Readiness {
    /// Ready once spawned.
    Started,
    /// Ready when the role writes `READY=1` to `CMUX_ROLE_NOTIFY_FD`.
    Notify,
}

/// One valid process role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleSpec {
    pub name: String,
    pub program: Program,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub restart: RestartPolicy,
    pub ready: Readiness,
    pub stop_grace: Duration,
    /// Under a root supervisor, run as root instead of the work user
    /// (`runAsRoot`; server.md 5.1 "Root").
    pub run_as_root: bool,
}

/// An entry that was refused, with the reason (shown in status).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvalidRole {
    pub name: String,
    pub reason: String,
}

/// The result of reading `roles`: valid entries in name order (a JSON
/// object has no order; disabled entries are left out), and refused ones.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RoleSet {
    pub roles: Vec<RoleSpec>,
    pub invalid: Vec<InvalidRole>,
}

/// Whether `name` may name a process role.
pub fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && name.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !RESERVED_NAMES.contains(&name)
}

/// Whether `key` may be set in a role's environment.
pub fn valid_env_key(key: &str) -> bool {
    let mut chars = key.chars();
    chars.next().is_some_and(|c| c.is_ascii_uppercase() || c == '_')
        && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
        && !key.starts_with("CMUX_ROLE_")
        && !key.starts_with("LD_")
        && !key.starts_with("DYLD_")
}

fn valid_store_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name != "."
        && name != ".."
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// Reads the `roles` value of `server.json`. `None` (no key) is an empty set.
pub fn parse_roles(value: Option<&Value>) -> RoleSet {
    let mut set = RoleSet::default();
    let Some(value) = value else { return set };
    let Some(entries) = value.as_object() else {
        set.invalid.push(InvalidRole {
            name: "roles".to_owned(),
            reason: "`roles` must be an object keyed by role name".to_owned(),
        });
        return set;
    };
    let mut names: Vec<&String> = entries.keys().collect();
    names.sort();
    for name in names {
        let entry = &entries[name.as_str()];
        match parse_entry(name, entry) {
            Ok(Some(spec)) => set.roles.push(spec),
            Ok(None) => {}
            Err(reason) => set.invalid.push(InvalidRole { name: name.clone(), reason }),
        }
    }
    set
}

const KNOWN_KEYS: &[&str] =
    &["program", "args", "env", "restart", "ready", "stopGraceSeconds", "enabled", "runAsRoot"];

/// `Ok(None)`: a valid entry with `enabled: false`.
fn parse_entry(name: &str, entry: &Value) -> Result<Option<RoleSpec>, String> {
    if !valid_name(name) {
        return Err(format!(
            "invalid role name {name:?}: use [a-z][a-z0-9-]{{0,31}}, not a built-in role name"
        ));
    }
    let Some(entry) = entry.as_object() else {
        return Err("a role entry must be an object".to_owned());
    };
    if let Some(key) = entry.keys().find(|key| !KNOWN_KEYS.contains(&key.as_str())) {
        return Err(format!("unknown key {key:?}"));
    }
    let enabled = match entry.get("enabled") {
        None => true,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err("`enabled` must be true or false".to_owned()),
    };
    let spec = RoleSpec {
        name: name.to_owned(),
        program: program(entry)?,
        args: args(entry)?,
        env: env(entry)?,
        restart: match str_field(entry, "restart")?.unwrap_or("always") {
            "always" => RestartPolicy::Always,
            "on-failure" => RestartPolicy::OnFailure,
            "never" => RestartPolicy::Never,
            other => return Err(format!("`restart` {other:?}: use always, on-failure or never")),
        },
        ready: match str_field(entry, "ready")?.unwrap_or("started") {
            "started" => Readiness::Started,
            "notify" => Readiness::Notify,
            other => return Err(format!("`ready` {other:?}: use started or notify")),
        },
        stop_grace: stop_grace(entry)?,
        run_as_root: match entry.get("runAsRoot") {
            None => false,
            Some(Value::Bool(b)) => *b,
            Some(_) => return Err("`runAsRoot` must be true or false".to_owned()),
        },
    };
    Ok(enabled.then_some(spec))
}

fn str_field<'a>(entry: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, String> {
    match entry.get(key) {
        None => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(format!("`{key}` must be a string")),
    }
}

fn program(entry: &Map<String, Value>) -> Result<Program, String> {
    let program = str_field(entry, "program")?.ok_or("`program` is required")?;
    if program.starts_with('/') {
        let clean = !program.contains('\0')
            && program
                .split('/')
                .skip(1)
                .all(|part| !part.is_empty() && part != "." && part != "..");
        return if clean {
            Ok(Program::Path(program.to_owned()))
        } else {
            Err(format!("`program` {program:?} is not a clean absolute path"))
        };
    }
    if valid_store_name(program) {
        Ok(Program::Store(program.to_owned()))
    } else {
        Err(format!(
            "`program` {program:?}: use a file name in the store's bin or an absolute path"
        ))
    }
}

fn args(entry: &Map<String, Value>) -> Result<Vec<String>, String> {
    let Some(value) = entry.get("args") else { return Ok(Vec::new()) };
    let items = value.as_array().ok_or("`args` must be an array of strings")?;
    items
        .iter()
        .map(|item| match item.as_str() {
            Some(s) if !s.contains('\0') => Ok(s.to_owned()),
            _ => Err("`args` must be an array of strings".to_owned()),
        })
        .collect()
}

fn env(entry: &Map<String, Value>) -> Result<BTreeMap<String, String>, String> {
    let Some(value) = entry.get("env") else { return Ok(BTreeMap::new()) };
    let map = value.as_object().ok_or("`env` must be an object of strings")?;
    let mut env = BTreeMap::new();
    for (key, value) in map {
        if !valid_env_key(key) {
            return Err(format!("`env` key {key:?} is not allowed"));
        }
        match value.as_str() {
            Some(s) if !s.contains('\0') => env.insert(key.clone(), s.to_owned()),
            _ => return Err(format!("`env` value of {key} must be a string")),
        };
    }
    Ok(env)
}

fn stop_grace(entry: &Map<String, Value>) -> Result<Duration, String> {
    match entry.get("stopGraceSeconds") {
        None => Ok(DEFAULT_STOP_GRACE),
        Some(value) => match value.as_u64() {
            Some(secs) if (1..=MAX_STOP_GRACE.as_secs()).contains(&secs) => {
                Ok(Duration::from_secs(secs))
            }
            _ => Err(format!("`stopGraceSeconds` must be 1 to {}", MAX_STOP_GRACE.as_secs())),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(value: Value) -> RoleSet {
        parse_roles(Some(&value))
    }

    #[test]
    fn chief_entry_parses_with_defaults() {
        let set = parse(json!({"chief": {"program": "optchat-chief", "args": ["host"]}}));
        assert!(set.invalid.is_empty(), "{:?}", set.invalid);
        let spec = &set.roles[0];
        assert_eq!(spec.name, "chief");
        assert_eq!(spec.program, Program::Store("optchat-chief".to_owned()));
        assert_eq!(spec.args, ["host"]);
        assert_eq!(spec.restart, RestartPolicy::Always);
        assert_eq!(spec.ready, Readiness::Started);
        assert_eq!(spec.stop_grace, DEFAULT_STOP_GRACE);
    }

    /// v1 rule: roles never run as root. `runAsRoot` (any value) is refused
    /// at load with a clear reason; a role that needs root is a system
    /// service, not a role.
    #[test]
    fn run_as_root_is_refused_at_load() {
        for value in [json!(true), json!(false), json!(1)] {
            let set = parse(json!({"r": {"program": "x", "runAsRoot": value}}));
            assert!(set.roles.is_empty(), "{value}: {:?}", set.roles);
            assert_eq!(set.invalid.len(), 1);
            assert!(set.invalid[0].reason.contains("runAsRoot"), "{}", set.invalid[0].reason);
            assert!(set.invalid[0].reason.contains("never run as root"), "{}", set.invalid[0].reason);
        }
    }

    #[test]
    fn missing_roles_is_empty_and_roles_are_in_name_order() {
        assert_eq!(parse_roles(None), RoleSet::default());
        let set = parse(json!({
            "b-role": {"program": "b", "restart": "on-failure", "ready": "notify"},
            "a-role": {"program": "/opt/x/bin/a", "stopGraceSeconds": 30},
            "off": {"program": "c", "enabled": false}
        }));
        let names: Vec<_> = set.roles.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["a-role", "b-role"]);
        assert!(set.invalid.is_empty());
        let a = set.roles.iter().find(|r| r.name == "a-role").unwrap();
        assert_eq!(a.program, Program::Path("/opt/x/bin/a".to_owned()));
        assert_eq!(a.stop_grace, Duration::from_secs(30));
        let b = set.roles.iter().find(|r| r.name == "b-role").unwrap();
        assert_eq!((b.restart, b.ready), (RestartPolicy::OnFailure, Readiness::Notify));
    }

    #[test]
    fn bad_entries_are_refused_alone() {
        let set = parse(json!({
            "postgres": {"program": "x"},
            "Bad": {"program": "x"},
            "dots": {"program": "../evil"},
            "rel": {"program": "bin/x"},
            "abs": {"program": "/opt/../etc/x"},
            "noprog": {},
            "envbad": {"program": "x", "env": {"DYLD_INSERT_LIBRARIES": "/tmp/x"}},
            "envrole": {"program": "x", "env": {"CMUX_ROLE_NAME": "y"}},
            "envlow": {"program": "x", "env": {"path": "/"}},
            "grace": {"program": "x", "stopGraceSeconds": 0},
            "restart": {"program": "x", "restart": "sometimes"},
            "extra": {"program": "x", "shell": true},
            "args": {"program": "x", "args": "host"},
            "good": {"program": "x", "env": {"OPTCHAT_MODE": "host"}}
        }));
        assert_eq!(set.roles.len(), 1, "{:?}", set.roles);
        assert_eq!(set.roles[0].name, "good");
        assert_eq!(set.invalid.len(), 13, "{:?}", set.invalid);
    }

    #[test]
    fn roles_must_be_an_object() {
        let set = parse(json!(["chief"]));
        assert!(set.roles.is_empty());
        assert_eq!(set.invalid[0].name, "roles");
    }

    #[test]
    fn names_and_env_keys() {
        assert!(valid_name("chief"));
        assert!(valid_name("a-2"));
        assert!(!valid_name("2a"));
        assert!(!valid_name("health"));
        assert!(!valid_name(&"a".repeat(33)));
        assert!(valid_env_key("OPTCHAT_HOME"));
        assert!(valid_env_key("_X"));
        assert!(!valid_env_key("LD_PRELOAD"));
        assert!(!valid_env_key("A-B"));
    }
}
