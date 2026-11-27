//! `cmux env`: the person's Cloud environments (what a Cloud chat's machine is set up with) from
//! the command line: list, show, create, edit, variables, secrets, files, a project's default and
//! the last setup's output. Codex-style environments; the sheet in the app edits the same records.
//!
//! Leo: "being able to like have somebody configure their own environment ... them putting their
//! environment variables in, that's like selecting the project, the repository or whatever, and
//! adding more files and all that stuff."
//!
//! Every call goes through the session daemon's `cloud-environment` op (cmux-tui-cloud-conversations
//! `environments.rs`), which checks the origin and the routes and drops secret values from every
//! reply. The CLI brings its own install token: the app's `auth.token` (`cmux auth token`) mints it
//! for the signed-in person, and it goes only to the platform of the API that issued it. It lives in
//! memory for this one run, is wiped on drop, and is never printed.
//!
//! A secret's value is read by [`secret::set`] alone: from a no-echo prompt, or from stdin when
//! stdin is not a terminal, never from argv. It goes to the daemon in one `update` and is wiped
//! after; no output, error or log line carries it (tests.rs proves each).
//!
//! `cmux cloud env get|set` is a different command: it picks the Cloud backend deployment.

use std::path::PathBuf;

use serde_json::Value;

use super::{GlobalArgs, OutputMode, UsageError};

mod daemon;
mod ops;
mod render;
mod revision;
mod secret;

const USAGE: &str = super::cloud_help::ENVIRONMENTS_USAGE;

/// What `--network` sets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Network {
    Off,
    Limited,
    Full,
}

impl Network {
    pub(super) fn mode(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Limited => "limited",
            Self::Full => "full",
        }
    }
}

/// The flags of `create` and `edit`. `image` and `network` are `edit`'s alone.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct Fields {
    pub repo: Option<String>,
    pub git_ref: Option<String>,
    pub setup_file: Option<PathBuf>,
    pub maintenance_file: Option<PathBuf>,
    pub image: Option<String>,
    pub network: Option<Network>,
}

impl Fields {
    fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

/// One `cmux env` command. No variant has a field for a secret's value: it is never an argument.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Command {
    Help,
    List,
    Show { env: String },
    Create { name: String, fields: Fields },
    Edit { env: String, fields: Fields },
    SetVar { env: String, key: String, value: String },
    UnsetVar { env: String, key: String },
    SetSecret { env: String, key: String, hosts: Vec<String> },
    UnsetSecret { env: String, key: String },
    AddFile { env: String, path: String, from: PathBuf },
    RmFile { env: String, path: String },
    Default { repo: Option<String>, env: Option<String> },
    Logs { env: String, repo: Option<String>, git_ref: Option<String> },
}

/// `Some(exit code)` when `args` is `env …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (first, rest) = words.split_first()?;
    if first != "env" {
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
    if command == Command::Help {
        print!("{USAGE}");
        return Some(0);
    }
    Some(run(&global, &command))
}

fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let outcome = daemon::Live::connect(global)
        .and_then(|mut live| ops::execute(command, &mut live, &ops::System));
    match outcome {
        Ok(answer) => print(&answer, command, global.output),
        Err(failure) => super::app::failure(
            &failure.code,
            &format!("cmux: {}", failure.message),
            global.output,
            failure.exit,
        ),
    }
}

fn print(answer: &Value, command: &Command, output: OutputMode) -> i32 {
    match output {
        OutputMode::Quiet => 0,
        OutputMode::Json | OutputMode::JsonLines => {
            super::wire::print_local_success(answer, output)
        }
        OutputMode::Human => {
            print!("{}", render::human(command, answer));
            0
        }
    }
}

/// `env`'s words after `env`.
pub(super) fn parse(words: &[String]) -> Result<Command, UsageError> {
    let Some((verb, rest)) = words.split_first() else { return Ok(Command::Help) };
    if matches!(verb.as_str(), "help" | "--help" | "-h")
        || rest.iter().any(|word| matches!(word.as_str(), "--help" | "-h"))
    {
        return Ok(Command::Help);
    }
    let usage = || UsageError::new(USAGE);
    let (positional, flags) = split_flags(rest)?;
    let allow = |names: &[&str]| -> Result<(), UsageError> {
        match flags.iter().find(|(name, _)| !names.contains(&name.as_str())) {
            Some((name, _)) => Err(UsageError::new(format!("{verb} does not take --{name}"))),
            None => Ok(()),
        }
    };
    let one = |name: &str| -> Result<Option<String>, UsageError> {
        let mut values = flags.iter().filter(|(flag, _)| flag == name).map(|(_, v)| v.clone());
        let first = values.next();
        if values.next().is_some() {
            return Err(UsageError::new(format!("--{name} is given twice")));
        }
        Ok(first)
    };
    let fields = |names: &[&str]| -> Result<Fields, UsageError> {
        allow(names)?;
        let repo = one("repo")?.map(|repo| ops::check_repo(&repo)).transpose()?;
        let network = match one("network")?.as_deref() {
            None => None,
            Some("off") => Some(Network::Off),
            Some("limited") => Some(Network::Limited),
            Some("full") => Some(Network::Full),
            Some(other) => {
                return Err(UsageError::new(format!(
                    "--network {other:?} is not off, limited or full"
                )));
            }
        };
        Ok(Fields {
            repo,
            git_ref: one("ref")?,
            setup_file: one("setup-file")?.map(PathBuf::from),
            maintenance_file: one("maintenance-file")?.map(PathBuf::from),
            image: one("image")?,
            network,
        })
    };
    const CREATE: &[&str] = &["repo", "ref", "setup-file", "maintenance-file"];
    const EDIT: &[&str] = &["repo", "ref", "setup-file", "maintenance-file", "image", "network"];
    let env = |word: &String| ops::check_env(word).map(|()| word.clone());
    let command = match (verb.as_str(), positional.as_slice()) {
        ("list" | "ls", []) => {
            allow(&[])?;
            Command::List
        }
        ("show", [name]) => {
            allow(&[])?;
            Command::Show { env: env(name)? }
        }
        ("create", [name]) => {
            Command::Create { name: ops::check_name(name)?, fields: fields(CREATE)? }
        }
        ("edit", [name]) => {
            let fields = fields(EDIT)?;
            if fields.is_empty() {
                return Err(UsageError::new("edit needs at least one flag to change"));
            }
            Command::Edit { env: env(name)?, fields }
        }
        ("set-var", [name, key, value]) => {
            allow(&[])?;
            Command::SetVar { env: env(name)?, key: ops::check_key(key)?, value: value.clone() }
        }
        ("unset-var", [name, key]) => {
            allow(&[])?;
            Command::UnsetVar { env: env(name)?, key: ops::check_key(key)? }
        }
        // A third word would be a value on the command line, where every process can read it.
        ("set-secret", [_, _, _, ..]) => {
            return Err(UsageError::new(
                "set-secret never takes the value as an argument: it reads it from a hidden prompt or stdin",
            ));
        }
        ("set-secret", [name, key]) => {
            allow(&["host"])?;
            let hosts = flags
                .iter()
                .map(|(_, host)| ops::check_host(host))
                .collect::<Result<Vec<_>, _>>()?;
            if hosts.is_empty() {
                return Err(UsageError::new(
                    "set-secret needs --host HOST: a secret is sent only to the hosts named",
                ));
            }
            if hosts.len() > ops::MAX_HOSTS {
                return Err(UsageError::new(format!(
                    "a secret goes to at most {} hosts",
                    ops::MAX_HOSTS
                )));
            }
            Command::SetSecret { env: env(name)?, key: ops::check_key(key)?, hosts }
        }
        ("unset-secret", [name, key]) => {
            allow(&[])?;
            Command::UnsetSecret { env: env(name)?, key: ops::check_key(key)? }
        }
        ("add-file", [name, path]) => {
            allow(&["from"])?;
            let from =
                one("from")?.ok_or_else(|| UsageError::new("add-file needs --from LOCALFILE"))?;
            Command::AddFile { env: env(name)?, path: ops::check_path(path)?, from: from.into() }
        }
        ("rm-file", [name, path]) => {
            allow(&[])?;
            Command::RmFile { env: env(name)?, path: ops::check_path(path)? }
        }
        ("default", [] | [_]) => {
            allow(&["repo"])?;
            let repo = one("repo")?.map(|repo| ops::check_repo(&repo)).transpose()?;
            Command::Default { repo, env: positional.first().map(env).transpose()? }
        }
        ("logs", [name]) => {
            allow(&["repo", "ref"])?;
            let repo = one("repo")?.map(|repo| ops::check_repo(&repo)).transpose()?;
            Command::Logs { env: env(name)?, repo, git_ref: one("ref")? }
        }
        _ => return Err(usage()),
    };
    Ok(command)
}

/// The positional words, and each `--flag VALUE` as (flag, value).
type Split = (Vec<String>, Vec<(String, String)>);

/// The words, and the `--flag VALUE` (or `--flag=VALUE`) pairs among them. Every flag takes a value.
fn split_flags(words: &[String]) -> Result<Split, UsageError> {
    let (mut positional, mut flags) = (Vec::new(), Vec::new());
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let Some(flag) = word.strip_prefix("--") else {
            positional.push(word.clone());
            continue;
        };
        let (name, value) = match flag.split_once('=') {
            Some((name, value)) => (name.to_owned(), value.to_owned()),
            None => {
                let value = words
                    .next()
                    .ok_or_else(|| UsageError::new(format!("--{flag} needs a value")))?;
                (flag.to_owned(), value.clone())
            }
        };
        if name.is_empty() || value.is_empty() {
            return Err(UsageError::new(format!("--{name} needs a value")));
        }
        flags.push((name, value));
    }
    Ok((positional, flags))
}

#[cfg(test)]
mod revision_tests;
#[cfg(test)]
mod tests;
