//! What each `cmux env` command asks the daemon's `cloud-environment` op, and the answer it prints.
//! Every answer passes through [`public`] or [`summary`], which name the fields they keep: a
//! secret keeps its name and hosts, nothing else.

use std::path::Path;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::daemon::Daemon;
use super::{Command, Fields, UsageError};

/// The most hosts a secret goes to (cmux-platform `SecretHosts`).
pub(in crate::cli) const MAX_HOSTS: usize = 8;
/// The largest file `--setup-file`, `--maintenance-file` or `add-file --from` reads; the platform
/// has the last word on sizes.
const MAX_FILE_BYTES: u64 = 1024 * 1024;

/// A failed command: a stable code, one line for a person, the exit code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Failure {
    pub code: String,
    pub message: String,
    pub exit: i32,
}

impl Failure {
    pub(super) fn new(code: &str, message: impl Into<String>, exit: i32) -> Self {
        Self { code: code.into(), message: message.into(), exit }
    }
}

/// What a command reads from this machine: files, this folder's repository, a secret's value.
pub(super) trait Local {
    fn read_file(&self, path: &Path) -> Result<String, Failure>;
    /// This folder's GitHub `OWNER/NAME`, from its git `origin`.
    fn current_repo(&self) -> Option<String>;
    /// A secret's value: a no-echo prompt on a terminal, else stdin. Never argv.
    fn secret_value(&self, key: &str) -> Result<Zeroizing<String>, Failure>;
}

/// The real machine.
pub(super) struct System;

impl Local for System {
    fn read_file(&self, path: &Path) -> Result<String, Failure> {
        use std::io::Read as _;
        let unreadable = |error: std::io::Error| {
            Failure::new(
                "env.file_unreadable",
                format!("cannot read {}: {error}", path.display()),
                1,
            )
        };
        let file = std::fs::File::open(path).map_err(unreadable)?;
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes).map_err(unreadable)?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(Failure::new(
                "env.file_too_large",
                format!("{} is larger than {} KiB", path.display(), MAX_FILE_BYTES / 1024),
                1,
            ));
        }
        String::from_utf8(bytes).map_err(|_| {
            Failure::new("env.file_not_text", format!("{} is not UTF-8 text", path.display()), 1)
        })
    }

    fn current_repo(&self) -> Option<String> {
        let output = cmux_process::Command::new("git")
            .args(["remote", "get-url", "origin"])
            .stderr(cmux_process::Stdio::null())
            .output()
            .ok()?;
        output.status.success().then_some(())?;
        github_repo(String::from_utf8_lossy(&output.stdout).trim())
    }

    fn secret_value(&self, key: &str) -> Result<Zeroizing<String>, Failure> {
        // The message never quotes input: it names the key and why.
        acpmux::cli::harness_secret::read_value(key)
            .map_err(|error| Failure::new("env.secret_unreadable", error.to_string(), 1))
    }
}

/// `OWNER/NAME` of a GitHub remote URL (`https://github.com/o/n.git`, `git@github.com:o/n`,
/// `ssh://git@github.com/o/n`).
pub(super) fn github_repo(url: &str) -> Option<String> {
    let path =
        ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"]
            .iter()
            .find_map(|prefix| url.strip_prefix(prefix))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    check_repo(path).ok()
}

/// `OWNER/NAME` as GitHub spells them.
pub(in crate::cli) fn check_repo(repo: &str) -> Result<String, UsageError> {
    let part = |p: &str| {
        (1..=100).contains(&p.len())
            && p != "."
            && p != ".."
            && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    match repo.split_once('/') {
        Some((owner, name)) if part(owner) && part(name) => Ok(repo.to_owned()),
        _ => Err(UsageError::new(format!("--repo {repo:?} is not OWNER/NAME"))),
    }
}

/// An environment's id or name: not empty, one line, at most 80 characters (a name's limit).
pub(in crate::cli) fn check_env(env: &str) -> Result<(), UsageError> {
    if env.trim().is_empty() || env.chars().count() > 80 || env.chars().any(char::is_control) {
        return Err(UsageError::new(format!("{env:?} is not an environment id or name")));
    }
    Ok(())
}

pub(in crate::cli) fn check_name(name: &str) -> Result<String, UsageError> {
    check_env(name)?;
    Ok(name.trim().to_owned())
}

/// A shell variable name (cmux-platform `VarName`).
pub(in crate::cli) fn check_key(key: &str) -> Result<String, UsageError> {
    let valid = (1..=128).contains(&key.len())
        && key.bytes().next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    if valid {
        Ok(key.to_owned())
    } else {
        Err(UsageError::new(format!("{key:?} is not a variable name")))
    }
}

/// An exact lowercase host name (cmux-platform `SecretHost`): no scheme, port, path or wildcard.
pub(in crate::cli) fn check_host(host: &str) -> Result<String, UsageError> {
    let label = |l: &str| {
        (1..=63).contains(&l.len())
            && !l.starts_with('-')
            && !l.ends_with('-')
            && l.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    };
    let valid = (1..=253).contains(&host.len()) && host.contains('.') && host.split('.').all(label);
    if valid {
        Ok(host.to_owned())
    } else {
        Err(UsageError::new(format!(
            "--host {host:?} is not a lowercase host name (no scheme, port, path or wildcard)"
        )))
    }
}

/// A file's path on the machine: one line, no `..` part, at most 1024 bytes.
pub(in crate::cli) fn check_path(path: &str) -> Result<String, UsageError> {
    let valid = (1..=1024).contains(&path.len())
        && !path.chars().any(char::is_control)
        && !path.split('/').any(|part| part == "..");
    if valid {
        Ok(path.to_owned())
    } else {
        Err(UsageError::new(format!("{path:?} is not a file path")))
    }
}

/// Runs `command` and answers what it prints.
pub(super) fn execute(
    command: &Command,
    daemon: &mut dyn Daemon,
    local: &dyn Local,
) -> Result<Value, Failure> {
    match command {
        Command::Help => Ok(Value::Null),
        Command::List => {
            let listed = daemon.call("list", &json!({}))?;
            let rows = listed.as_array().map(|all| all.iter().map(summary).collect::<Vec<_>>());
            Ok(json!({"environments": rows.unwrap_or_default()}))
        }
        Command::Show { env } => Ok(public(&resolve(daemon, env)?)),
        Command::Create { name, fields } => {
            let mut body = patch(fields, local, None)?;
            body.insert("name".into(), json!(name));
            let created = daemon.call("create", &json!({"environment": body}))?;
            Ok(public(&created))
        }
        Command::Edit { env, fields } => {
            let record = resolve(daemon, env)?;
            let changes = patch(fields, local, Some(&record))?;
            update(daemon, &record, Value::Object(changes))
        }
        Command::SetVar { env, key, value } => {
            let record = resolve(daemon, env)?;
            let mut vars = list(&record, "env_vars");
            vars.retain(|var| var.get("name").and_then(Value::as_str) != Some(key));
            vars.push(json!({"name": key, "value": value}));
            update(daemon, &record, json!({"env_vars": vars}))
        }
        Command::UnsetVar { env, key } => {
            let record = resolve(daemon, env)?;
            let mut vars = list(&record, "env_vars");
            let before = vars.len();
            vars.retain(|var| var.get("name").and_then(Value::as_str) != Some(key));
            if vars.len() == before {
                return Err(missing("variable", key, &record));
            }
            update(daemon, &record, json!({"env_vars": vars}))
        }
        Command::SetSecret { env, key, hosts } => {
            let record = resolve(daemon, env)?;
            // A secret's header stays what it was; `set-secret` changes its value and hosts.
            let header = list(&record, "secrets")
                .into_iter()
                .find(|secret| secret.get("name").and_then(Value::as_str) == Some(key))
                .and_then(|secret| secret.get("header").cloned());
            let saved = super::secret::set(daemon, local, id(&record)?, key, hosts, header)?;
            Ok(public(&saved))
        }
        Command::UnsetSecret { env, key } => {
            let record = resolve(daemon, env)?;
            if !list(&record, "secrets")
                .iter()
                .any(|s| s.get("name").and_then(Value::as_str) == Some(key))
            {
                return Err(missing("secret", key, &record));
            }
            update(daemon, &record, json!({"remove_secrets": [key]}))
        }
        Command::AddFile { env, path, from } => {
            let content = local.read_file(from)?;
            let record = resolve(daemon, env)?;
            let mut files = whole_files(&record)?;
            files.retain(|file| file.get("path").and_then(Value::as_str) != Some(path));
            files.push(json!({"path": path, "content": content}));
            update(daemon, &record, json!({"files": files}))
        }
        Command::RmFile { env, path } => {
            let record = resolve(daemon, env)?;
            let mut files = whole_files(&record)?;
            let before = files.len();
            files.retain(|file| file.get("path").and_then(Value::as_str) != Some(path));
            if files.len() == before {
                return Err(missing("file", path, &record));
            }
            update(daemon, &record, json!({"files": files}))
        }
        Command::Default { repo, env } => {
            let repo = repo.clone().or_else(|| local.current_repo()).ok_or_else(|| {
                Failure::new(
                    "usage.invalid",
                    "name the project with --repo OWNER/NAME: this folder has no GitHub origin",
                    2,
                )
            })?;
            match env {
                Some(env) => {
                    let record = resolve(daemon, env)?;
                    daemon
                        .call("default-set", &json!({"repo": repo, "environment": id(&record)?}))?;
                    Ok(json!({"repo": repo, "environment": summary(&record)}))
                }
                None => {
                    let answer = daemon.call("default-get", &json!({"repo": repo}))?;
                    let chosen = answer
                        .get("environment_id")
                        .or_else(|| answer.get("environment"))
                        .and_then(Value::as_str);
                    let environment = match chosen {
                        Some(chosen) => resolve(daemon, chosen)
                            .map(|record| summary(&record))
                            .unwrap_or_else(|_| json!({"id": chosen})),
                        None => Value::Null,
                    };
                    Ok(json!({"repo": repo, "environment": environment}))
                }
            }
        }
        Command::Logs { env, repo, git_ref } => {
            let record = resolve(daemon, env)?;
            let text = |key: &str| record.get(key).and_then(Value::as_str).map(str::to_owned);
            let repo =
                repo.clone().or_else(|| text("repo")).or_else(|| local.current_repo()).ok_or_else(
                    || {
                        Failure::new(
                            "usage.invalid",
                            "this environment names no repository: pass --repo OWNER/NAME",
                            2,
                        )
                    },
                )?;
            let mut params = json!({"repo": repo, "environment": id(&record)?});
            if let Some(git_ref) = git_ref.clone().or_else(|| text("ref")) {
                params["ref"] = json!(git_ref);
            }
            let derived = daemon.call("derive", &params)?;
            Ok(logs(&record, &repo, &derived))
        }
    }
}

/// One `update` of `record` with `changes`; answers the saved environment's public view.
fn update(daemon: &mut dyn Daemon, record: &Value, changes: Value) -> Result<Value, Failure> {
    let saved = daemon.call("update", &json!({"id": id(record)?, "patch": changes}))?;
    Ok(public(&saved))
}

fn id(record: &Value) -> Result<&str, Failure> {
    record.get("id").and_then(Value::as_str).ok_or_else(|| {
        Failure::new("env.invalid_reply", "the environment came back without an id", 1)
    })
}

fn missing(what: &str, name: &str, record: &Value) -> Failure {
    let env = record.get("name").and_then(Value::as_str).unwrap_or("this environment");
    Failure::new("env.not_found", format!("{env} has no {what} {name}"), 1)
}

fn list(record: &Value, key: &str) -> Vec<Value> {
    record.get(key).and_then(Value::as_array).cloned().unwrap_or_default()
}

/// The files as the platform keeps them, each with its content: a `files` update replaces them
/// all, so a reply without contents (an older deployment) would drop them.
fn whole_files(record: &Value) -> Result<Vec<Value>, Failure> {
    let files = list(record, "files");
    if files.iter().all(|file| {
        file.get("path").is_some_and(Value::is_string)
            && file.get("content").is_some_and(Value::is_string)
    }) {
        Ok(files
            .into_iter()
            .map(|file| json!({"path": file["path"], "content": file["content"]}))
            .collect())
    } else {
        Err(Failure::new(
            "env.files_unavailable",
            "this Cloud backend does not answer file contents, so files cannot be changed from here",
            1,
        ))
    }
}

/// The `create` body or `update` patch of `fields`. `record` is the environment `edit` changes
/// (its network keeps everything but the mode).
fn patch(
    fields: &Fields,
    local: &dyn Local,
    record: Option<&Value>,
) -> Result<Map<String, Value>, Failure> {
    let mut body = Map::new();
    if let Some(repo) = &fields.repo {
        body.insert("repo".into(), json!(repo));
    }
    if let Some(git_ref) = &fields.git_ref {
        body.insert("ref".into(), json!(git_ref));
    }
    if let Some(path) = &fields.setup_file {
        body.insert("setup_script".into(), json!(local.read_file(path)?));
    }
    if let Some(path) = &fields.maintenance_file {
        body.insert("maintenance_script".into(), json!(local.read_file(path)?));
    }
    if let Some(image) = &fields.image {
        body.insert("image".into(), json!(image));
    }
    if let Some(network) = fields.network {
        let current = record.and_then(|record| record.get("network"));
        let field = |key: &str, fallback: Value| {
            current.and_then(|n| n.get(key)).cloned().unwrap_or(fallback)
        };
        body.insert(
            "network".into(),
            json!({
                "mode": network.mode(),
                "package_managers": field("package_managers", json!(true)),
                "domains": field("domains", json!([])),
            }),
        );
    }
    Ok(body)
}

/// The environment `wanted` names: its id, else its name (any case). Two of the same name (yours
/// and your team's) need the id.
fn resolve(daemon: &mut dyn Daemon, wanted: &str) -> Result<Value, Failure> {
    let listed = daemon.call("list", &json!({}))?;
    let all = listed.as_array().cloned().unwrap_or_default();
    let field =
        |record: &Value, key: &str| record.get(key).and_then(Value::as_str).map(str::to_owned);
    if let Some(found) = all.iter().find(|record| field(record, "id").as_deref() == Some(wanted)) {
        return Ok(found.clone());
    }
    let named: Vec<&Value> = all
        .iter()
        .filter(|record| {
            field(record, "name").is_some_and(|name| name.eq_ignore_ascii_case(wanted.trim()))
        })
        .collect();
    match named.as_slice() {
        [one] => Ok((*one).clone()),
        [] => Err(Failure::new(
            "env.not_found",
            format!("no environment is named {wanted:?} (`cmux env list`)"),
            1,
        )),
        many => {
            let ids: Vec<String> = many
                .iter()
                .map(|record| {
                    format!(
                        "{} ({})",
                        field(record, "id").unwrap_or_default(),
                        field(record, "scope").unwrap_or_default()
                    )
                })
                .collect();
            Err(Failure::new(
                "env.ambiguous",
                format!(
                    "{} environments are named {wanted:?}: use the id, one of {}",
                    many.len(),
                    ids.join(", ")
                ),
                2,
            ))
        }
    }
}

/// A list row: who it is, not what is in it.
pub(super) fn summary(record: &Value) -> Value {
    let mut row = Map::new();
    for key in ["id", "name", "scope", "is_default", "repo", "ref"] {
        row.insert(key.into(), record.get(key).cloned().unwrap_or(Value::Null));
    }
    Value::Object(row)
}

/// What `show` and every change print: the named fields only. A secret is its name and hosts; a
/// file is its path and size.
pub(super) fn public(record: &Value) -> Value {
    let Value::Object(mut view) = summary(record) else { return Value::Null };
    for key in ["image", "network", "setup_script", "maintenance_script", "updated_at"] {
        view.insert(key.into(), record.get(key).cloned().unwrap_or(Value::Null));
    }
    let vars: Vec<Value> = list(record, "env_vars")
        .iter()
        .map(|var| json!({"name": var.get("name"), "value": var.get("value")}))
        .collect();
    let secrets: Vec<Value> = list(record, "secrets")
        .iter()
        .map(|secret| {
            let hosts: Vec<&str> = secret
                .get("hosts")
                .and_then(Value::as_array)
                .map(|hosts| hosts.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            json!({"name": secret.get("name").and_then(Value::as_str), "hosts": hosts})
        })
        .collect();
    let files: Vec<Value> = list(record, "files")
        .iter()
        .map(|file| {
            json!({
                "path": file.get("path").and_then(Value::as_str),
                "bytes": file.get("content").and_then(Value::as_str).map(str::len),
            })
        })
        .collect();
    view.insert("env_vars".into(), json!(vars));
    view.insert("secrets".into(), json!(secrets));
    view.insert("files".into(), json!(files));
    Value::Object(view)
}

/// `logs`: the last setup's state, steps and output.
fn logs(record: &Value, repo: &str, derived: &Value) -> Value {
    let error = derived.get("error").filter(|error| error.is_object());
    json!({
        "environment": summary(record),
        "repo": repo,
        "ref": derived.get("ref"),
        "status": derived.get("status"),
        "attempt": derived.get("attempt"),
        "started_at": derived.get("started_at"),
        "finished_at": derived.get("finished_at"),
        "steps": derived.get("steps").cloned().unwrap_or_else(|| json!([])),
        "error": error.map(|error| json!({"code": error.get("code"), "message": error.get("message")})),
        "log_tail": error.and_then(|error| error.get("log_tail")).cloned().unwrap_or(Value::Null),
    })
}
