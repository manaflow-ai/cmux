//! Part of `Hub`; see `hub/mod.rs`. What an agent's `asksBeforeTools` claim is judged by
//! (`policy_mode.rs` `claim_distrust`; lead, 2026-11-09): the claim holds a narrow policy only
//! from a launch that nothing but the daemon's config chose.
//!
//! Each start records, in the session meta, either the claim basis (`SessionMeta::claim_basis`):
//! a digest of every config input of the launch ([`config_inputs`]: the harness entry's argv and
//! env, its `defaults` env and its preset), read under the same config read as the preset the
//! spawn applies ([`start_claim`]); or why the launch cannot carry a claim
//! (`SessionMeta::claim_unbelieved`):
//! - `not_a_config_entry`: the start ran a folder profile (`.cmux/harnesses`), which the
//!   repository supplies, also when a config entry later takes its name;
//! - `entry_changed`: the config changed while the start read it (the entry or its `defaults`
//!   env is not what the start resolved);
//! - `argv_skips_approvals`: the command skips approvals (`--yolo`, `--dangerously-skip-
//!   permissions`, `subsession_guard::argv_full_access`), so the agent never asks;
//! - `launch_reads_folder`: the command runs code the chat's folder chose ([`unbelieved_launch`]).
//!
//! The launch is judged as the config chose it, after `${cwd}`, `${home}` and `${model}`
//! expansion and before acpmux's own additions (the chat's env, routes, cmux's rules), at every
//! start, with the `PATH` the agent gets (the launch's own before the login shell's,
//! `login_env::with_agent_path`). The chat's own env (`session_env.rs`) never changes what runs,
//! so it is no input. A later check computes [`config_inputs`] again from the config as it is now;
//! any change since the start means the agent no longer runs what the config says.

use super::*;
use std::collections::BTreeMap;

/// Node's flags that preload a module: a bare name resolves from the working folder.
const NODE_PRELOAD: &[&str] = &["-r", "--require", "--import", "--loader", "--experimental-loader"];

/// The digest of the config inputs of a launch of harness entry `harness`, with preset `preset`:
/// the entry's argv and env (`HarnessProfile::launch_digest`), its `defaults` env with the
/// preset's env over it, and the preset's approval digest (its env, args, system prompt, mode).
/// None when `harness` is no entry of `cfg` (a folder profile, or an entry removed).
pub(super) fn config_inputs(cfg: &Config, harness: &str, preset: Option<&str>) -> Option<String> {
    let entry = cfg.profile(harness)?;
    let preset = preset.and_then(|name| cfg.presets.get(name));
    let mut env = cfg.defaults_for(harness).env;
    if let Some(p) = preset {
        env.extend(p.env.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    let inputs = json!({
        "entry": entry.launch_digest(),
        "defaultsEnv": env,
        "preset": preset.and_then(crate::config::Preset::approval_digest),
    });
    Some(crate::sha256::sha256_hex(inputs.to_string().as_bytes()))
}

/// The claim basis a start of `harness` with preset `preset` records, from `cfg` as the spawn
/// reads its preset: `launch_digest` and `defaults_env` are the entry's launch and the defaults
/// env the start resolved (with or without the preset's env over it). Any of them changed since
/// is `entry_changed`; no entry is `not_a_config_entry`.
pub(super) fn start_claim(
    cfg: &Config,
    harness: &str,
    preset: Option<&str>,
    launch_digest: &str,
    defaults_env: &BTreeMap<String, String>,
) -> Result<String, &'static str> {
    let entry = cfg.profile(harness).ok_or("not_a_config_entry")?;
    if entry.launch_digest() != launch_digest {
        return Err("entry_changed");
    }
    let defaults = cfg.defaults_for(harness).env;
    let mut with_preset = defaults.clone();
    if let Some(p) = preset.and_then(|name| cfg.presets.get(name)) {
        with_preset.extend(p.env.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    if *defaults_env != defaults && *defaults_env != with_preset {
        return Err("entry_changed");
    }
    config_inputs(cfg, harness, preset).ok_or("not_a_config_entry")
}

/// Why launch `spawned` (as the config chose it, expanded) of a chat in folder `cwd` cannot carry
/// a claim, or None (module docs). The `PATH` judged is the one the agent gets: the launch's own
/// entries, as written, before the login shell's (`login_env::with_agent_path`), else the login
/// shell's.
pub(super) fn unbelieved_launch(spawned: &HarnessProfile, cwd: &Path) -> Option<&'static str> {
    let own = spawned.env.get("PATH").filter(|p| !p.is_empty());
    let mut path: Vec<PathBuf> =
        own.map(|own| std::env::split_paths(own).collect()).unwrap_or_default();
    path.extend(crate::login_env::agent_path().iter().flat_map(std::env::split_paths));
    judge(spawned, cwd, &path)
}

/// [`unbelieved_launch`] with the agent's `PATH` entries given.
fn judge(spawned: &HarnessProfile, cwd: &Path, path: &[PathBuf]) -> Option<&'static str> {
    if super::subsession_guard::argv_full_access(&spawned.argv).is_some() {
        return Some("argv_skips_approvals");
    }
    reads_folder(spawned, cwd, path).then_some("launch_reads_folder")
}

/// Whether launch `spawned` may run code that folder `cwd` chose. Fail closed, by allowlists: it
/// reads nothing of the folder only when acpmux understands every word of it
/// ([`Launch::understood`]), every env name of it is a reviewed one whose value names nothing of
/// the folder ([`env_kept`]), and no `PATH` entry is empty or relative (it names the folder). A bare
/// program that `PATH` resolves to a file whose real path is inside the folder is the folder's (a
/// chat in the home folder counts `~/.local/bin/agent` as the folder's); a link in a `PATH` folder
/// to a program outside the chat folder is that program.
///
/// The root folder holds every program, so it chooses none.
fn reads_folder(spawned: &HarnessProfile, cwd: &Path, path: &[PathBuf]) -> bool {
    if cwd.parent().is_none() {
        return false;
    }
    let folder = Folder::of(cwd);
    if spawned.env.iter().any(|(key, value)| !env_kept(key, value, &folder))
        || path.iter().any(|dir| dir.as_os_str().is_empty() || dir.is_relative())
    {
        return true;
    }
    !Launch { folder: &folder, path }.understood(&spawned.argv, spawned.env.clone())
}

/// Env names a launch may set and keep its claim: names that no runtime reads as code, as a file
/// to load, or as a folder to search for code (reviewed for #40158). Every other name refuses the
/// claim (fail closed): `RUBYOPT`, `PERL5OPT`, `BASH_ENV`, `PYTHONHOME`, `PYTHONPATH`,
/// `NODE_OPTIONS`, `DYLD_INSERT_LIBRARIES`, `ZDOTDIR`, `HOME` and any name not reviewed.
const REVIEWED_ENV: &[&str] = &[
    "PATH",
    "LANG",
    "LANGUAGE",
    "TERM",
    "COLORTERM",
    "NO_COLOR",
    "FORCE_COLOR",
    "CLICOLOR",
    "TZ",
    "RUST_LOG",
    "RUST_BACKTRACE",
    "PYTHONUNBUFFERED",
    "PYTHONDONTWRITEBYTECODE",
    "PYTHONIOENCODING",
    "PYTHONSAFEPATH",
    "PYTHONNOUSERSITE",
    "NODE_ENV",
    "NODE_NO_WARNINGS",
    // acpmux's own switch for the cmux tools of the agents a profile starts.
    "ACPMUX_AGENT_TOOLS",
];

/// Suffixes of reviewed env names: a credential, an endpoint or a model name of the agent's own
/// provider (`OPENAI_API_KEY`, `ANTHROPIC_BASE_URL`, `GEMINI_MODEL`), which no runtime loads.
const REVIEWED_ENV_SUFFIXES: &[&str] = &["_API_KEY", "_AUTH_TOKEN", "_BASE_URL", "_MODEL"];

/// Whether env entry `key`=`value` keeps the claim: a reviewed name ([`REVIEWED_ENV`], `LC_*`, a
/// name with a suffix of [`REVIEWED_ENV_SUFFIXES`]) whose value names nothing of `folder`
/// ([`env_in_folder`]).
fn env_kept(key: &str, value: &str, folder: &Folder) -> bool {
    let reviewed = REVIEWED_ENV.contains(&key)
        || key.strip_prefix("LC_").is_some_and(|rest| !rest.is_empty())
        || REVIEWED_ENV_SUFFIXES.iter().any(|s| key.len() > s.len() && key.ends_with(s));
    reviewed && !env_in_folder(key, value, folder)
}

/// The file name of program word `word` (`python3` of `/usr/bin/python3`).
fn name_of(word: &str) -> &str {
    Path::new(word).file_name().and_then(|n| n.to_str()).unwrap_or(word)
}

/// The agent CLIs whose launch keeps the claim, with arguments that name no program and nothing of
/// the folder ([`Launch::args_understood`]), reviewed for #40158. Each reads its own project
/// config in the chat folder (`opencode.json`, `.codex/`): the one assumption the lead accepted.
const AGENT_CLIS: &[&str] = &["opencode", "codex"];

/// Names of programs that run other code (interpreters, shells, wrappers, package runners, build
/// tools), as an argument names them ([`Launch::names_program`]), case folded and with any version
/// (`Node22`, `perl5.34`): a name that is not here but that `PATH` resolves to a program is one
/// too.
const RUNNERS: &[&str] = &[
    "python",
    "pypy",
    "node",
    "nodejs",
    "deno",
    "bun",
    "bunx",
    "npx",
    "pnpx",
    "npm",
    "pnpm",
    "yarn",
    "uv",
    "uvx",
    "pipx",
    "ruby",
    "irb",
    "perl",
    "php",
    "lua",
    "luajit",
    "tclsh",
    "wish",
    "expect",
    "osascript",
    "swift",
    "java",
    "jshell",
    "kotlin",
    "scala",
    "groovy",
    "dotnet",
    "go",
    "cargo",
    "rustc",
    "make",
    "sh",
    "bash",
    "zsh",
    "dash",
    "ksh",
    "fish",
    "csh",
    "tcsh",
    "env",
    "sudo",
    "doas",
    "exec",
    "eval",
    "source",
    "command",
    "xargs",
    "nohup",
    "nice",
    "timeout",
    "stdbuf",
    "time",
    "caffeinate",
    "setsid",
    "sandbox-exec",
    "xcrun",
    "arch",
    "pyenv",
    "mise",
    "asdf",
    "direnv",
    "op",
    "dotenv",
    "nix",
    "nix-shell",
    "conda",
    "poetry",
    "pipenv",
    "flock",
    "ionice",
    "taskset",
    "chrt",
    "unbuffer",
    "script",
    "tsx",
    "ts-node",
    "docker",
    "podman",
];

/// Value literals of the words a launch's arguments hold (JSON and TOML booleans, a log level):
/// no program, though `PATH` holds programs of these names (`/usr/bin/true`, `/usr/bin/info`),
/// which run no code of their arguments.
const VALUE_LITERALS: &[&str] = &["true", "false", "yes", "info"];

/// Words of a key or an option that names a command to run (`--hook`, `mcp_servers.x.command`,
/// `notify`, `args`): a value literal under one is a program word, not a value.
const COMMAND_KEYS: &[&str] = &[
    "command", "commands", "cmd", "hook", "hooks", "exec", "execute", "notify", "run", "shell",
    "program", "script", "spawn", "launch", "args", "argv", "server", "servers", "mcp",
];

/// Whether word `word` (an option or a part of an argument) has a word of [`COMMAND_KEYS`], split
/// on `-`, `_` and `.`, case folded.
fn names_command(word: &str) -> bool {
    word.to_lowercase()
        .split(['-', '_', '.'])
        .any(|w| COMMAND_KEYS.contains(&w) || w.starts_with("mcp"))
}

/// What a launch's program is ([`Launch::program`]).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Program {
    /// An agent CLI of [`AGENT_CLIS`].
    Agent,
    /// CPython 3, with its minor version when a name tells it (`python3.12`).
    Python(Option<u32>),
    /// Node.
    Node,
    /// `env`.
    Env,
    /// A wrapper that [`wrapped`] reads.
    Wrapper,
}

/// The [`Program`] that file name `name` names, case folded (`PYTHON3` is `python3`; a script
/// extension such as `codex.js` is dropped), or `None`: acpmux has no form for it.
fn program_of(name: &str) -> Option<Program> {
    let lower = name.to_lowercase();
    let bare = [".js", ".mjs", ".cjs"].iter().find_map(|e| lower.strip_suffix(e)).unwrap_or(&lower);
    if AGENT_CLIS.contains(&bare) {
        return Some(Program::Agent);
    }
    if bare == "python3" {
        return Some(Program::Python(None));
    }
    if let Some(minor) = bare.strip_prefix("python3.") {
        return minor.parse().ok().map(|minor| Program::Python(Some(minor)));
    }
    match bare {
        "node" | "nodejs" => Some(Program::Node),
        "env" => Some(Program::Env),
        _ if wrapped(bare, &[]).is_some() => Some(Program::Wrapper),
        _ => None,
    }
}

/// Node's options that load or run nothing.
const NODE_SAFE_FLAGS: &[&str] = &[
    "--no-warnings",
    "--enable-source-maps",
    "--trace-warnings",
    "--no-deprecation",
    "--trace-uncaught",
];

/// Node's options whose `=value` loads or runs nothing.
const NODE_SAFE_VALUED: &[&str] =
    &["--max-old-space-size", "--stack-size", "--unhandled-rejections"];

/// Where wrapper `named` (a program of a closed list, its own options parsed fully) runs the
/// program it wraps: `Some(Some(i))` at `args[i]` (`args.len()` for none), `Some(None)` when an
/// option is one acpmux does not know, and `None` when `named` is no such wrapper. `env` is read
/// apart ([`Launch::env_wrapper`]).
fn wrapped(named: &str, args: &[String]) -> Option<Option<usize>> {
    let (takes_value, switches): (&[&str], &[&str]) = match named {
        "nohup" => (&[], &[]),
        "nice" => (&["-n", "--adjustment"], &[]),
        "timeout" => (
            &["-s", "--signal", "-k", "--kill-after"],
            &["--preserve-status", "--foreground", "-v", "--verbose"],
        ),
        "stdbuf" => (&["-i", "-o", "-e", "--input", "--output", "--error"], &[]),
        "time" => (&[], &["-p"]),
        "caffeinate" => (&["-w", "-t"], &["-d", "-i", "-m", "-s", "-u"]),
        "setsid" => (&[], &["-w", "-f", "-c", "--wait", "--fork", "--ctty"]),
        _ => return None,
    };
    let mut i = 0;
    while let Some(arg) = args.get(i).map(String::as_str) {
        if !arg.starts_with('-') {
            break;
        }
        i += 1;
        if arg == "--" {
            break;
        }
        if switches.contains(&arg) {
            continue;
        }
        if takes_value.contains(&arg) {
            if args.get(i).is_none() {
                return Some(None);
            }
            i += 1;
            continue;
        }
        // A value joined to its option (`--signal=KILL`, `-n10`, `-oL`), or nice's old `-10`.
        let joined = takes_value.iter().any(|f| {
            arg.strip_prefix(f).is_some_and(|v| {
                if f.starts_with("--") { v.starts_with('=') } else { !v.is_empty() }
            })
        });
        let old_nice = named == "nice"
            && arg
                .strip_prefix('-')
                .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
        if !(joined || old_nice) {
            return Some(None);
        }
    }
    if named == "timeout" {
        // The duration, then the program.
        if args.get(i).is_none() {
            return Some(None);
        }
        i += 1;
    }
    Some(Some(i))
}

/// The forms of a launch that acpmux understands to read nothing of the chat folder: allowlists
/// of programs ([`Program`]), of their options, and of env names. Every other form reads it (fail
/// closed).
struct Launch<'a> {
    folder: &'a Folder,
    path: &'a [PathBuf],
}

impl Launch<'_> {
    /// Whether `argv`, run with env `env`, is understood to read nothing of the folder. Its
    /// program is outside the folder and is a [`Program`] by its written name and by the real
    /// file it runs ([`Self::program`]):
    /// - an agent CLI, with arguments that [`Self::args_understood`];
    /// - a wrapper of [`wrapped`], or `env` (its `KEY=VALUE` words judged as env, `-u` and `-i`
    ///   applied), that runs an understood launch;
    /// - Python, with options of its safe list, and a script by an absolute path outside the
    ///   folder, or a module, code of the command line or stdin with the safe path (`-P`, `-I`, or
    ///   `PYTHONSAFEPATH` on a Python known to be 3.11 or later);
    /// - Node, with options of its safe list (a preload by an absolute path outside the folder),
    ///   and a script by an absolute path outside the folder.
    ///
    /// Any other program refuses: an interpreter acpmux has no form for (`ruby`, `sh -c`, PyPy),
    /// a versioned or unknown name (`perl5.34`, `node22`), a package runner, a program acpmux
    /// cannot find.
    fn understood(&self, argv: &[String], env: BTreeMap<String, String>) -> bool {
        let Some((program, args)) = argv.split_first() else { return true };
        if !self.program_outside(program) {
            return false;
        }
        match self.program(program) {
            None => false,
            Some(Program::Agent) => self.args_understood(args, false),
            Some(Program::Env) => self.env_wrapper(args, env),
            Some(Program::Wrapper) => match wrapped(&name_of(program).to_lowercase(), args) {
                Some(Some(at)) => self.understood(args.get(at..).unwrap_or_default(), env),
                _ => false,
            },
            Some(Program::Python(minor)) => self.python(minor, args, &env),
            Some(Program::Node) => self.node(args),
        }
    }

    /// The [`Program`] that program word `program` runs, or `None` (fail closed). Its written name
    /// and the name of the real file it runs (an absolute path, or the first program `PATH`
    /// finds, links resolved) must name the same kind, case folded: a link named `python3` to
    /// Perl is no Python. A program acpmux cannot find is none. A Python's minor version is the
    /// real file's when its name tells one.
    fn program(&self, program: &str) -> Option<Program> {
        let written = program_of(name_of(program))?;
        let found = if program.contains('/') {
            Some(PathBuf::from(program)).filter(|p| p.is_absolute() && is_program(p))?
        } else {
            self.path.iter().map(|dir| dir.join(program)).find(|p| is_program(p))?
        };
        let real = std::fs::canonicalize(&found).ok()?;
        let real = program_of(real.file_name()?.to_str()?)?;
        match (written, real) {
            (Program::Python(written), Program::Python(real)) => {
                Some(Program::Python(real.or(written)))
            }
            (written, real) if written == real => Some(written),
            _ => None,
        }
    }

    /// Whether program word `program` runs a file outside the folder: an absolute path outside
    /// it, or a bare name that `PATH` does not resolve into it.
    fn program_outside(&self, program: &str) -> bool {
        if program.contains('/') {
            return self.script_outside(program);
        }
        !resolves_in_folder(program, self.path, self.folder)
    }

    /// Whether `word` is an absolute path outside the folder.
    fn script_outside(&self, word: &str) -> bool {
        let at = Path::new(word);
        at.is_absolute() && !self.folder.holds(at)
    }

    /// Whether arguments `args` name nothing of the folder and no program ([`Self::parts_understood`]).
    /// A word (or an option's value: `--flag=value`, `-rvalue`) names something of the folder when
    /// it is a path inside it, a relative path to something it holds (so a model name such as
    /// `zai/glm-5` is none), or a bare word that names something it holds as an option's value
    /// (the word after `-x`/`--xx`) or, `interpreted`, as any argument of a script. A bare word of
    /// an agent CLI that follows no option (`opencode acp`) is a subcommand: the one form acpmux
    /// takes as no path without proof (lead).
    fn args_understood(&self, args: &[String], interpreted: bool) -> bool {
        // An escape (`\u006eode` in TOML or JSON, `\x` in a shell string) can spell any program
        // or path past the part checks: a word with a backslash refuses (lead, #40158).
        if args.iter().any(|arg| arg.contains('\\')) {
            return false;
        }
        let cwd = self.folder.written.as_path();
        let mut after_option = false;
        let mut option: Option<&str> = None;
        for arg in args {
            for (word, option_value) in arg_paths(arg, after_option) {
                let at = Path::new(word);
                let inside = if at.is_absolute() {
                    self.folder.holds(at)
                } else {
                    (word.contains('/') || interpreted || option_value) && cwd.join(word).exists()
                };
                if inside {
                    return false;
                }
            }
            if !self.parts_understood(arg, option) {
                return false;
            }
            after_option = arg.starts_with('-') && arg != "-" && arg != "--" && !arg.contains('=');
            option = after_option.then_some(arg.as_str());
        }
        true
    }

    /// Whether the parts of argument word `arg` name no program ([`Self::names_program`]) and
    /// nothing of the folder. Its parts are split on whitespace, quotes, brackets and `=`, `:`,
    /// `,`, `;`, so a `KEY=VALUE` (`mcp_servers.x.command=node`), a quoted value, inline JSON
    /// (`{"command":"node","args":["./srv.js"]}`) and a command string (`node hook.js`) are read
    /// part by part, case folded. A part names something of the folder when it is a path inside
    /// it, or (in a word of more than one part) a relative path to something it holds.
    ///
    /// A value literal ([`VALUE_LITERALS`]) is no program only as a value: a part after the
    /// first of a word, or the word after option `option`, and only when neither the word nor
    /// `option` has a key of a command ([`names_command`]: `--hook info`, `command=true`).
    fn parts_understood(&self, arg: &str, option: Option<&str>) -> bool {
        let cwd = self.folder.written.as_path();
        let parts: Vec<&str> = arg
            .split(|c: char| c.is_whitespace() || "\"'`[]{}()=:,;".contains(c))
            .filter(|p| !p.is_empty())
            .collect();
        let composite = parts.as_slice() != [arg];
        let commands = option.is_some_and(names_command) || parts.iter().any(|p| names_command(p));
        parts.iter().enumerate().all(|(i, part)| {
            let value = !commands && (i > 0 || option.is_some());
            let at = Path::new(part);
            !self.names_program(part, value)
                && if at.is_absolute() {
                    !self.folder.holds(at)
                } else {
                    !(composite && cwd.join(part).exists())
                }
        })
    }

    /// Whether word `part` names a program other than an agent CLI: a runner of [`RUNNERS`] (case
    /// folded, any version; any name that starts with `python` or `pypy`), an absolute path to a
    /// program, or a bare name that `PATH` resolves to a program and that is no value literal
    /// ([`VALUE_LITERALS`]) where `value` says the part is a value.
    fn names_program(&self, part: &str, value: bool) -> bool {
        let name = name_of(part);
        if program_of(name) == Some(Program::Agent) {
            return false;
        }
        let lower = name.to_lowercase();
        let plain = lower.trim_end_matches(|c: char| c.is_ascii_digit() || ".-_".contains(c));
        if RUNNERS.contains(&plain) || lower.starts_with("python") || lower.starts_with("pypy") {
            return true;
        }
        let at = Path::new(part);
        if at.is_absolute() {
            return is_program(at);
        }
        if value && VALUE_LITERALS.contains(&lower.as_str()) {
            return false;
        }
        !part.contains('/')
            && !part.starts_with('-')
            && part.chars().any(|c| c.is_ascii_alphabetic())
            && self.path.iter().any(|dir| is_program(&dir.join(part)))
    }

    /// `env` with arguments `args`, given env `env`: its options (`-i`, `-u NAME`, `--`) change
    /// the env; any other option is one acpmux does not know. Its `KEY=VALUE` words are env,
    /// judged as the entry's env is ([`env_kept`]); a `PATH` of its own is one acpmux does not
    /// follow.
    fn env_wrapper(&self, args: &[String], mut env: BTreeMap<String, String>) -> bool {
        let mut i = 0;
        while let Some(arg) = args.get(i).map(String::as_str) {
            if !arg.starts_with('-') {
                break;
            }
            i += 1;
            match arg {
                "--" => break,
                "-" | "-i" | "--ignore-environment" => env.clear(),
                "-u" | "--unset" => {
                    let Some(key) = args.get(i) else { return false };
                    i += 1;
                    env.remove(key.as_str());
                }
                _ => match arg.strip_prefix("--unset=").or_else(|| arg.strip_prefix("-u")) {
                    Some(key) if !key.is_empty() => {
                        env.remove(key);
                    }
                    _ => return false,
                },
            }
        }
        while let Some((key, value)) = args.get(i).and_then(|a| a.split_once('=')) {
            if key == "PATH" || !env_kept(key, value, self.folder) {
                return false;
            }
            env.insert(key.to_owned(), value.to_owned());
            i += 1;
        }
        self.understood(args.get(i..).unwrap_or_default(), env)
    }

    /// CPython 3 of minor version `minor` (when known) with arguments `args` and env `env`
    /// ([`Self::understood`]). Its short options are read as clusters (`-um` is a module run).
    fn python(&self, minor: Option<u32>, args: &[String], env: &BTreeMap<String, String>) -> bool {
        // `PYTHONSAFEPATH` exists from 3.11; a Python whose version no name tells (`python3`, a
        // shim that the folder's `.python-version` may point) is not known to have it.
        let knows_safe_path = minor.is_some_and(|minor| minor >= 11);
        let safe_env = knows_safe_path && env.get("PYTHONSAFEPATH").is_some_and(|v| !v.is_empty());
        let (mut safe_flag, mut no_env) = (false, false);
        let mut i = 0;
        while let Some(arg) = args.get(i) {
            i += 1;
            let safe = safe_flag || (safe_env && !no_env);
            if arg == "-" {
                return safe && self.args_understood(args.get(i..).unwrap_or_default(), true);
            }
            if arg == "--" {
                return match args.get(i) {
                    Some(script) => {
                        self.script_outside(script)
                            && self.args_understood(args.get(i + 1..).unwrap_or_default(), true)
                    }
                    None => safe,
                };
            }
            if arg == "--check-hash-based-pycs" {
                i += 1;
                continue;
            }
            if arg.starts_with("--") {
                return false;
            }
            let Some(cluster) = arg.strip_prefix('-') else {
                return self.script_outside(arg)
                    && self.args_understood(args.get(i..).unwrap_or_default(), true);
            };
            let mut letters = cluster.chars();
            while let Some(letter) = letters.next() {
                match letter {
                    // A module or code of the command line (the rest of the cluster or the next
                    // word), then its arguments.
                    'm' | 'c' => {
                        let safe = safe_flag || (safe_env && !no_env);
                        let rest = if letters.as_str().is_empty() { i + 1 } else { i };
                        return safe
                            && self.args_understood(args.get(rest..).unwrap_or_default(), true);
                    }
                    'P' | 'I' => safe_flag = true,
                    'E' => no_env = true,
                    'u' | 'B' | 's' | 'S' | 'O' | 'q' | 'b' | 'd' | 'v' | 'x' | 'R' => {}
                    // Options whose value is the rest of the cluster or the next word.
                    'W' | 'X' => {
                        if letters.as_str().is_empty() {
                            i += 1;
                        }
                        break;
                    }
                    _ => return false,
                }
            }
        }
        // No script: code from stdin.
        safe_flag || (safe_env && !no_env)
    }

    /// Node with arguments `args` ([`Self::understood`]): no script is stdin or the REPL, and
    /// `-e`, `-p`, `--run` and every option not of its safe list are not understood.
    fn node(&self, args: &[String]) -> bool {
        let mut i = 0;
        while let Some(arg) = args.get(i).map(String::as_str) {
            i += 1;
            if NODE_PRELOAD.contains(&arg) {
                let Some(value) = args.get(i) else { return false };
                i += 1;
                if !self.script_outside(value) {
                    return false;
                }
                continue;
            }
            if let Some(value) = NODE_PRELOAD
                .iter()
                .find_map(|f| arg.strip_prefix(f).and_then(|v| v.strip_prefix('=')))
            {
                if !self.script_outside(value) {
                    return false;
                }
                continue;
            }
            if NODE_SAFE_FLAGS.contains(&arg)
                || NODE_SAFE_VALUED
                    .iter()
                    .any(|f| arg.strip_prefix(f).is_some_and(|v| v.starts_with('=')))
            {
                continue;
            }
            if arg.starts_with('-') {
                return false;
            }
            return self.script_outside(arg)
                && self.args_understood(args.get(i..).unwrap_or_default(), true);
        }
        false
    }
}

/// The chat folder as a start judges it: as written and as its real path (links resolved), and
/// whether its volume ignores case (APFS by default), so a path that differs only in case is in
/// it too.
struct Folder {
    written: PathBuf,
    real: PathBuf,
    folds_case: bool,
}

impl Folder {
    fn of(cwd: &Path) -> Self {
        let real = real_path(cwd);
        let folds_case = folds_case(&real);
        Self { written: cwd.to_path_buf(), real, folds_case }
    }

    /// Whether absolute path `path` leads into the folder (as written, through links, or in
    /// another case on a volume that ignores case).
    fn holds(&self, path: &Path) -> bool {
        if path.starts_with(&self.written) {
            return true;
        }
        let real = real_path(path);
        if real.starts_with(&self.real) {
            return true;
        }
        let lower = |p: &Path| PathBuf::from(p.to_string_lossy().to_lowercase());
        self.folds_case && lower(&real).starts_with(lower(&self.real))
    }
}

/// `path` with links resolved: the real path of its longest part that exists, then the rest as
/// written.
fn real_path(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut head = path;
    loop {
        if let Ok(real) = std::fs::canonicalize(head) {
            return rest.iter().rev().fold(real, |p, part| p.join(part));
        }
        match (head.parent(), head.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                head = parent;
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// Whether the volume of existing folder `real` ignores case: the same folder answers to its name
/// in another case. A path with no letter to change cannot tell: it counts as ignoring case (fail
/// closed).
fn folds_case(real: &Path) -> bool {
    let text = real.to_string_lossy();
    let flipped: String = text
        .chars()
        .map(|c| if c.is_lowercase() { c.to_ascii_uppercase() } else { c.to_ascii_lowercase() })
        .collect();
    if flipped == text {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        match (std::fs::metadata(real), std::fs::metadata(&flipped)) {
            (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
            _ => false,
        }
    }
    #[cfg(not(unix))]
    {
        std::fs::metadata(&flipped).is_ok()
    }
}

/// Whether bare program `program` resolves on `path` to a file whose real path is in `folder`.
fn resolves_in_folder(program: &str, path: &[PathBuf], folder: &Folder) -> bool {
    let Some(found) = path.iter().map(|dir| dir.join(program)).find(|p| is_program(p)) else {
        return false;
    };
    // Where the lookup leads: a link in a `PATH` folder to a program elsewhere is that program.
    folder.holds(&std::fs::canonicalize(&found).unwrap_or(found))
}

/// Whether `path` is a file a `PATH` lookup runs.
fn is_program(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        meta.is_file() && meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        meta.is_file()
    }
}

/// The words of argument `arg` that may be paths, each with whether it is an option's value: the
/// argument itself (an option's value when it follows an option, `after_option`), or an option's
/// value (`--flag=value`; `-rvalue` for a short option).
fn arg_paths(arg: &str, after_option: bool) -> Vec<(&str, bool)> {
    let Some(rest) = arg.strip_prefix('-') else { return vec![(arg, after_option)] };
    let mut words = Vec::new();
    if let Some((_, value)) = arg.split_once('=') {
        words.push((value, true));
    }
    if !rest.starts_with('-') {
        // The short option's letter, then its value.
        let mut value = rest.chars();
        value.next();
        words.push((value.as_str(), true));
    }
    words.into_iter().filter(|(w, _)| !w.is_empty()).collect()
}

/// Whether env key `key` holds a list of folders a program searches (`PATH`, `PYTHONPATH`,
/// `NODE_PATH`, `*_PATH`), not a switch such as `PYTHONSAFEPATH`.
fn is_path_list(key: &str) -> bool {
    matches!(key, "PATH" | "PYTHONPATH" | "PERL5LIB" | "RUBYLIB" | "CLASSPATH")
        || key.ends_with("_PATH")
}

/// Whether env value `value` of key `key` names something in folder `cwd` ([`reads_folder`]).
fn env_in_folder(key: &str, value: &str, folder: &Folder) -> bool {
    let cwd = folder.written.as_path();
    let list = is_path_list(key);
    if list && value.contains(':') && value.split(':').any(str::is_empty) {
        return true;
    }
    value.split([':', ';', ',', '=', ' ']).filter(|p| !p.is_empty()).any(|part| {
        let path = Path::new(part);
        if path.is_absolute() {
            return folder.holds(path);
        }
        part == "."
            || part == ".."
            || part.starts_with("./")
            || part.starts_with("../")
            || (list && key != "PATH")
            || (part.contains('/') && cwd.join(part).exists())
    })
}

// The tests make links and modes, which are Unix's.
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn launch(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
        serde_json::from_value(json!({
            "argv": argv,
            "env": env.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect::<serde_json::Map<_, _>>(),
        }))
        .unwrap()
    }

    fn paths(list: &str) -> Vec<PathBuf> {
        std::env::split_paths(list).collect()
    }

    fn system_path() -> Vec<PathBuf> {
        paths("/usr/bin:/bin")
    }

    /// A folder of stand-in programs (empty scripts that are programs) of every name a believed
    /// launch runs, and of names that are value literals too (`true`, `info`), and a `PATH` that
    /// finds them first: no result depends on what the machine has.
    fn tools() -> (tempfile::TempDir, Vec<PathBuf>) {
        use std::os::unix::fs::PermissionsExt as _;
        let tools = tempfile::tempdir().unwrap();
        let programs = ["opencode", "codex", "python3", "python3.10", "python3.11", "python3.12"];
        for name in programs.into_iter().chain(["node", "true", "yes", "info", "ls"]) {
            let program = tools.path().join(name);
            std::fs::write(&program, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = paths(&format!("{}:/usr/bin:/bin", tools.path().display()));
        (tools, path)
    }

    #[test]
    fn a_launch_of_programs_outside_the_folder_carries_a_claim() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        let (tools, path) = tools();
        let python = tools.path().join("python3").to_string_lossy().into_owned();
        let plain = launch(&[python.as_str(), "/opt/agent.py", "--mode=ask"], &[]);
        assert_eq!(judge(&plain, cwd, &path), None);
        // A bare program found on PATH, also when the folder holds a file of its name.
        std::fs::write(cwd.join("python3"), "").unwrap();
        let bare = launch(&["python3", "-u", "/opt/agent.py"], &[]);
        assert_eq!(judge(&bare, cwd, &path), None);
        // Python that guards its import path, Node that preloads an absolute module.
        let guarded = launch(&["python3", "-P", "-m", "agent"], &[]);
        assert_eq!(judge(&guarded, cwd, &path), None);
        let safe = launch(&["python3.12", "-m", "agent"], &[("PYTHONSAFEPATH", "1")]);
        assert_eq!(judge(&safe, cwd, &path), None);
        let node = launch(&["node", "--require", "/opt/hook.js", "/opt/agent.js"], &[]);
        assert_eq!(judge(&node, cwd, &path), None);
        // An agent CLI. A model name with a slash is no path, nor is a reviewed env value.
        let model =
            launch(&["opencode", "--model", "zai/glm-5"], &[("OPENCODE_MODEL", "zai/glm-5")]);
        assert_eq!(judge(&model, cwd, &path), None);
        // A path that only starts with the folder's name is another folder.
        let sibling = format!("{}-other/bin", cwd.display());
        let beside = launch(&["opencode", "acp"], &[("OPENCODE_BASE_URL", sibling.as_str())]);
        assert_eq!(judge(&beside, cwd, &path), None);
        let beside_path = paths(&format!("{sibling}:{}", tools.path().display()));
        assert_eq!(judge(&launch(&["opencode", "acp"], &[]), cwd, &beside_path), None);
        // A PATH folder inside the chat folder whose program links to one outside it runs that
        // program.
        let links = cwd.join("tools");
        std::fs::create_dir_all(&links).unwrap();
        std::os::unix::fs::symlink(tools.path().join("opencode"), links.join("opencode")).unwrap();
        let linked = paths(&format!("{}:/usr/bin", links.display()));
        assert_eq!(judge(&launch(&["opencode", "acp"], &[]), cwd, &linked), None);
        // The root folder chooses nothing.
        let root = launch(&["/usr/bin/python3", "-m", "agent"], &[]);
        assert_eq!(judge(&root, Path::new("/"), &paths(".")), None);
    }

    /// A word with a backslash refuses: an escape in a TOML, JSON or shell string can spell a
    /// program that no part check sees (`-c mcp_servers.x.command="\u006eode"`) (lead, #40158).
    #[test]
    fn an_argument_word_with_a_backslash_reads_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let (_tools, path) = tools();
        let refused: &[&[&str]] = &[
            &["codex", "-c", r#"mcp_servers.x.command="\u006eode""#],
            &["codex", "-c", r#"mcp_servers.x.args=["sr\u0076.js"]"#],
            &["opencode", "--mcp-config", r#"{"s":{"command":"\u006eode"}}"#],
            &["opencode", "--hook", r"n\ode hook.js"],
            &["opencode", r"--log-level=\info"],
        ];
        for argv in refused {
            let why = judge(&launch(argv, &[]), dir.path(), &path);
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?}");
        }
        let plain = launch(&["codex", "-c", r#"model="gpt-5""#], &[]);
        assert_eq!(judge(&plain, dir.path(), &path), None);
    }

    /// A value literal of the words acpmux reads (`true`, `false`, `yes`, the log level `info`) is
    /// no program as a value, in any case, though `PATH` holds programs of those names; any other
    /// bare word that `PATH` resolves is one. As the program, a bare word that follows no option,
    /// or the value of a command key (`--hook info`, `command=true`) a literal is a program
    /// (lead, #40158).
    #[test]
    fn a_value_literal_is_no_program() {
        let dir = tempfile::tempdir().unwrap();
        let (_tools, path) = tools();
        for argv in [
            &["codex", "-c", "sandbox_workspace_write.network_access=true"][..],
            &["codex", "-c", "hide_agent_reasoning=FALSE"],
            &["opencode", "acp", "--log-level", "INFO"],
        ] {
            assert_eq!(judge(&launch(argv, &[]), dir.path(), &path), None, "{argv:?}");
        }
        for argv in [
            &["opencode", "--hook", "ls"][..],
            &["codex", "-c", r#"notify=["sh"]"#],
            // A literal is safe only as a value, never as a program word.
            &["opencode", "--hook", "info"],
            &["opencode", "--hook=true"],
            &["codex", "-c", "mcp_servers.x.command=true"],
            &["opencode", "--mcp-config", r#"{"s":{"command":"yes"}}"#],
            &["opencode", "run", "true"],
            &["true"],
        ] {
            let why = judge(&launch(argv, &[]), dir.path(), &path);
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?}");
        }
    }

    /// Only a program of the allowlist keeps the claim, by its written name and by the real file
    /// it runs: an unknown program, a link named for an allowed program that runs another, and a
    /// program acpmux cannot find keep none (lead, #40158).
    #[test]
    fn only_a_program_of_the_allowlist_carries_a_claim() {
        let dir = tempfile::tempdir().unwrap();
        let (tools, path) = tools();
        let other = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(tools.path().join("node"), other.path().join("opencode"))
            .unwrap();
        let disguised = other.path().join("opencode").to_string_lossy().into_owned();
        for argv in [
            &["/usr/bin/agent", "acp"][..],
            &["agent-cli", "acp"],
            &[disguised.as_str(), "acp"],
            &["/opt/missing/opencode", "acp"],
        ] {
            let why = judge(&launch(argv, &[]), dir.path(), &path);
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?}");
        }
    }

    #[test]
    fn a_launch_that_runs_the_folders_code_carries_none() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        std::fs::write(cwd.join("agent.py"), "").unwrap();
        let inside = cwd.join("agent.py").to_string_lossy().into_owned();
        let folder = cwd.to_str().unwrap();
        let reads = |argv: &[&str], env: &[(&str, &str)], path: &str| {
            let why = judge(&launch(argv, env), cwd, &paths(path));
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?} {env:?} {path:?}");
        };
        let sys = "/usr/bin:/bin";
        let (tools, _) = tools();
        let tp = format!("{}:/usr/bin:/bin", tools.path().display());
        // The program.
        reads(&["./agent"], &[], sys);
        reads(&["bin/agent"], &[], sys);
        reads(&[inside.as_str()], &[], sys);
        for runner in ["npx", "/usr/bin/bunx", "uvx", "uv", "bun", "deno", "pnpm", "pipx"] {
            reads(&[runner, "some-acp"], &[], sys);
        }
        // Interpreters that import from the folder.
        reads(&["python3", "-m", "agent"], &[], sys);
        reads(&["python3.12", "-X", "dev", "-magent"], &[], sys);
        reads(&["python3", "-c", "import agent"], &[], sys);
        reads(&["python3", "-u"], &[], sys);
        reads(&["node", "-e", "require('agent')"], &[], sys);
        reads(&["node", "--require", "hook", "/opt/agent.js"], &[], sys);
        reads(&["node", "--import=hook", "/opt/agent.js"], &[], sys);
        // Arguments.
        reads(&["python3", inside.as_str()], &[], sys);
        reads(&["python3", "agent.py"], &[], sys);
        reads(&["python3", format!("--script={inside}").as_str()], &[], sys);
        reads(&["opencode", format!("-r{inside}").as_str()], &[], &tp);
        // Env values.
        reads(&["opencode"], &[("PYTHONPATH", folder)], &tp);
        reads(&["opencode"], &[("PYTHONPATH", ".")], &tp);
        reads(&["opencode"], &[("PYTHONPATH", "lib")], &tp);
        reads(&["opencode"], &[("NODE_PATH", "node_modules")], &tp);
        reads(&["opencode"], &[("PYTHONPATH", "/opt::/usr/lib")], &tp);
        reads(&["opencode"], &[("NODE_OPTIONS", "--require ./hook.js")], &tp);
        reads(&["opencode"], &[("NODE_OPTIONS", format!("--require={inside}").as_str())], &tp);
        // A reviewed env name whose value names the folder.
        reads(&["opencode"], &[("OPENCODE_BASE_URL", folder)], &tp);
        reads(&["opencode"], &[("NO_COLOR", inside.as_str())], &tp);
        // PATH entries: relative, empty, or inside the folder (the login shell's too). The program
        // is `opencode`, of the program allowlist, and `PATH` finds a stand-in of it outside the
        // folder after the entry: only the `PATH` rule can refuse these.
        let tools_dir = tools.path().display();
        for entries in ["bin", "", "."] {
            reads(&["opencode", "acp"], &[], &format!("{entries}:{tools_dir}"));
        }
        // A bare program that PATH finds in the folder: an `opencode` of the folder's own, found
        // before the stand-in outside it. Only the folder rule refuses it (lead, #40158).
        let bin = cwd.join("node_modules").join(".bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("opencode"), "#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(bin.join("opencode"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        reads(&["opencode", "acp"], &[], &format!("{}:{tools_dir}", bin.display()));
        // The same launch with the stand-in first keeps the claim: the folder's copy decided.
        let first = paths(&format!("{tools_dir}:{}", bin.display()));
        assert_eq!(judge(&launch(&["opencode", "acp"], &[]), cwd, &first), None);
    }

    /// The PATH judged is the one the agent gets: the launch's own entries, as written, then the
    /// login shell's.
    #[test]
    fn the_launchs_own_path_is_judged_as_written() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        // `opencode`, of the program allowlist, found outside the folder after the entry: only
        // the relative or empty entry refuses.
        let (tools, _) = tools();
        for entry in ["bin", ""] {
            let own = format!("{entry}:{}", tools.path().display());
            let launch = launch(&["opencode", "acp"], &[("PATH", own.as_str())]);
            assert_eq!(unbelieved_launch(&launch, cwd), Some("launch_reads_folder"), "{own}");
        }
    }

    /// A path is judged by where it leads: a link to the chat folder (`/tmp` is `/private/tmp`
    /// on macOS), or the chat folder named by a link, is the folder (review of #40158).
    #[test]
    fn a_path_through_a_link_into_the_folder_is_the_folders() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("agent.py"), "").unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let through_link = link.join("agent.py").to_string_lossy().into_owned();
        let direct = real.join("agent.py").to_string_lossy().into_owned();
        let (_tools, tools_path) = tools();
        for (cwd, script) in [(&real, &through_link), (&link, &direct)] {
            for argv in [vec!["python3", script.as_str()], vec![script.as_str()]] {
                let why = judge(&launch(&argv, &[]), cwd, &system_path());
                assert_eq!(why, Some("launch_reads_folder"), "{argv:?} in {}", cwd.display());
            }
            let env = launch(&["opencode"], &[("OPENCODE_BASE_URL", script.as_str())]);
            let why = judge(&env, cwd, &tools_path);
            assert_eq!(why, Some("launch_reads_folder"), "env {script} in {}", cwd.display());
        }
    }

    /// A bare word of an agent CLI that follows no option is no path: a subcommand (`opencode acp`)
    /// or `.` is no file of the folder, even when the folder holds one of that name (review of
    /// #40158).
    #[test]
    fn a_bare_argument_word_is_no_path() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        std::fs::write(cwd.join("acp"), "").unwrap();
        let (_tools, path) = tools();
        for argv in [["opencode", "acp"], ["codex", "."]] {
            assert_eq!(judge(&launch(&argv, &[]), cwd, &path), None, "{argv:?}");
        }
        // The script an interpreter runs is still judged.
        std::fs::write(cwd.join("agent.py"), "").unwrap();
        let script = launch(&["python3", "-u", "agent.py"], &[]);
        assert_eq!(judge(&script, cwd, &system_path()), Some("launch_reads_folder"));
    }

    /// A folder file that a launch names by a bare word is still the folder's when an option takes
    /// it (`--config agent.json`), when the interpreter's own options hide it (`python3 -I`), or
    /// when a wrapper (`env`, `nice`, `timeout`) runs the interpreter (delta review of #40158).
    #[test]
    fn a_folder_file_behind_an_option_or_a_wrapper_is_the_folders() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        for file in ["agent.py", "agent.js", "agent.json"] {
            std::fs::write(cwd.join(file), "").unwrap();
        }
        let argvs: &[&[&str]] = &[
            &["python3", "-I", "agent.py"],
            &["env", "python3", "agent.py"],
            &["nice", "node", "agent.js"],
            &["timeout", "3600", "python3", "agent.py"],
            &["env", "python3", "-m", "agent"],
            &["opencode", "--config", "agent.json"],
            &["opencode", "--config=agent.json"],
        ];
        let (_tools, path) = tools();
        for argv in argvs {
            let why = judge(&launch(argv, &[]), cwd, &path);
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?}");
        }
    }

    /// Python options that drop the safe import path read the folder: `-E` ignores
    /// `PYTHONSAFEPATH`, and `-m` in a cluster (`-um`) is still a module run. `-I` and `-P` keep
    /// the safe path (codex review of #40158, F3).
    #[test]
    fn python_options_that_drop_the_safe_path_read_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        let safe = [("PYTHONSAFEPATH", "1")];
        let reads: &[(&[&str], &[(&str, &str)])] = &[
            (&["python3", "-E", "-m", "agent"], &safe),
            (&["python3", "-Em", "agent"], &safe),
            (&["python3", "-um", "agent"], &[]),
            (&["python3", "-u", "-c", "import agent"], &[]),
        ];
        for (argv, env) in reads {
            let why = judge(&launch(argv, env), cwd, &system_path());
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?} {env:?}");
        }
        let guarded: &[(&[&str], &[(&str, &str)])] = &[
            (&["python3", "-Im", "agent"], &[]),
            (&["python3", "-P", "-um", "agent"], &[]),
            (&["python3.12", "-um", "agent"], &safe),
        ];
        let (_tools, path) = tools();
        for (argv, env) in guarded {
            assert_eq!(judge(&launch(argv, env), cwd, &path), None, "{argv:?} {env:?}");
        }
    }

    /// A preload in `NODE_OPTIONS` by a bare name resolves from the folder's `node_modules`
    /// (codex review of #40158, F4); an absolute one does not.
    #[test]
    fn a_bare_preload_in_node_options_is_the_folders() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        for options in
            ["--require hook", "--import=hook", "-r hook", "--max-old-space-size=4096 -r hook"]
        {
            let node = launch(&["node", "/opt/agent.js"], &[("NODE_OPTIONS", options)]);
            assert_eq!(judge(&node, cwd, &system_path()), Some("launch_reads_folder"), "{options}");
        }
        // `NODE_OPTIONS` is no reviewed env name: an absolute preload there refuses too (lead,
        // #40158), and the same preload on Node's command line keeps the claim.
        let absolute =
            launch(&["node", "/opt/agent.js"], &[("NODE_OPTIONS", "--require /opt/hook.js")]);
        assert_eq!(judge(&absolute, cwd, &system_path()), Some("launch_reads_folder"));
        let (_tools, path) = tools();
        let argv = launch(&["node", "--require", "/opt/hook.js", "/opt/agent.js"], &[]);
        assert_eq!(judge(&argv, cwd, &path), None);
    }

    /// The folder a launch reads, for the review cases of #40158 (w5l-158-rev-2): `agent.py`,
    /// `agent.js` and a `package.json` script `agent`.
    fn review_folder() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for file in ["agent.py", "agent.js"] {
            std::fs::write(dir.path().join(file), "").unwrap();
        }
        std::fs::write(dir.path().join("package.json"), r#"{"scripts":{"agent":"node agent.js"}}"#)
            .unwrap();
        dir
    }

    fn assert_reads(cwd: &Path, argv: &[&str], env: &[(&str, &str)]) {
        let why = judge(&launch(argv, env), cwd, &system_path());
        assert_eq!(why, Some("launch_reads_folder"), "{argv:?} {env:?}");
    }

    /// A program acpmux does not know may be a wrapper that runs the next words: an unknown wrapper
    /// does not hide `python3 -m agent` (w5l-158-rev-2, item 1).
    #[test]
    fn an_unknown_wrapper_does_not_hide_a_module_run() {
        let dir = review_folder();
        for argv in [
            &["pyenv", "exec", "python3", "-m", "agent"][..],
            &["mise", "exec", "--", "python3", "-m", "agent"],
            &["sandbox-exec", "-f", "/etc/p.sb", "python3", "-m", "agent"],
            &["op", "run", "--", "python3", "-m", "agent"],
        ] {
            assert_reads(dir.path(), argv, &[]);
        }
    }

    /// `env`'s own `KEY=VALUE` words are env, judged as the entry's env is (item 2).
    #[test]
    fn env_words_are_judged_as_env() {
        let dir = review_folder();
        assert_reads(dir.path(), &["env", "PYTHONPATH=.", "python3", "/opt/agent.py"], &[]);
        assert_reads(
            dir.path(),
            &["env", "NODE_OPTIONS=--require hook", "node", "/opt/agent.js"],
            &[],
        );
    }

    /// A wrapper that drops the env (`env -u`, `env -i`, `sudo`) drops `PYTHONSAFEPATH` too (item 2).
    #[test]
    fn a_wrapper_that_drops_the_env_drops_the_safe_path() {
        let dir = review_folder();
        let safe = [("PYTHONSAFEPATH", "1")];
        assert_reads(
            dir.path(),
            &["env", "-u", "PYTHONSAFEPATH", "python3.12", "-m", "agent"],
            &safe,
        );
        assert_reads(dir.path(), &["env", "-i", "python3.12", "-m", "agent"], &safe);
        assert_reads(dir.path(), &["sudo", "python3.12", "-m", "agent"], &safe);
    }

    /// Node finds `agent.js` for a script named `agent`, and `--run` runs a `package.json` script
    /// (item 3).
    #[test]
    fn node_finds_a_folder_script_by_its_bare_name() {
        let dir = review_folder();
        assert_reads(dir.path(), &["node", "agent"], &[]);
        assert_reads(dir.path(), &["node", "--run", "agent"], &[]);
    }

    /// PyPy runs modules from the folder as CPython does (w5l-158-rev-2, non-blocking).
    #[test]
    fn pypy_reads_the_folder() {
        let dir = review_folder();
        assert_reads(dir.path(), &["pypy3", "-m", "agent"], &[]);
        assert_reads(dir.path(), &["pypy3", "-c", "import agent"], &[]);
    }

    /// A shell's command string is code of the command line, which acpmux does not read (lead).
    #[test]
    fn a_shell_command_string_reads_the_folder() {
        let dir = review_folder();
        assert_reads(dir.path(), &["sh", "-c", "python3 -m agent"], &[]);
        assert_reads(dir.path(), &["/bin/bash", "-lc", "agent acp"], &[]);
    }

    /// A folder outside the chat folder with the agent CLIs `codex` and `opencode` (empty scripts
    /// that are programs), so a launch names a real file of each.
    fn agent_bin() -> tempfile::TempDir {
        use std::os::unix::fs::PermissionsExt as _;
        let bin = tempfile::tempdir().unwrap();
        for name in ["codex", "opencode"] {
            let program = bin.path().join(name);
            std::fs::write(&program, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        bin
    }

    /// An interpreter that is not on the program allowlist runs a folder file: a versioned name
    /// (`perl5.34`, `tclsh8.5`, `node22`, `ruby3.3`, as stock macOS and version managers name
    /// them) or one acpmux has no form for (`osascript`, `swift`, `java`, `expect`)
    /// (w5l-delta-rev, item 1).
    #[test]
    fn an_interpreter_off_the_list_reads_the_folder() {
        let dir = review_folder();
        for file in
            ["agent.pl", "agent.tcl", "agent.scpt", "agent.swift", "Agent.java", "agent.exp"]
        {
            std::fs::write(dir.path().join(file), "").unwrap();
        }
        std::fs::write(dir.path().join("agent.rb"), "").unwrap();
        for argv in [
            &["/usr/bin/perl5.34", "agent.pl"][..],
            &["tclsh8.5", "agent.tcl"],
            &["osascript", "agent.scpt"],
            &["swift", "agent.swift"],
            &["java", "Agent.java"],
            &["expect", "agent.exp"],
            &["node22", "agent"],
            &["ruby3.3", "agent.rb"],
        ] {
            assert_reads(dir.path(), argv, &[]);
        }
    }

    /// A program name in another case is that program on a volume that ignores case (APFS by
    /// default): `PYTHON3 -m agent` is a module run, `NODE agent` runs `agent.js` (item 2).
    #[test]
    fn a_program_name_in_another_case_is_that_program() {
        let dir = review_folder();
        assert_reads(dir.path(), &["PYTHON3", "-m", "agent"], &[]);
        assert_reads(dir.path(), &["NODE", "agent"], &[]);
    }

    /// An interpreter or a folder file inside a composite word is seen: a `KEY=VALUE` option
    /// value (`-c mcp_servers.x.command=node`), a quoted value, inline JSON (`--mcp-config`) and a
    /// command string (`--hook "node hook.js"`), so a folder MCP server or hook does not run at
    /// launch (item 3). A plain subcommand or model value of an agent CLI is no program.
    #[test]
    fn a_runner_inside_a_composite_word_reads_the_folder() {
        let dir = review_folder();
        for file in ["srv.js", "hook.js"] {
            std::fs::write(dir.path().join(file), "").unwrap();
        }
        let bin = agent_bin();
        let codex = bin.path().join("codex").to_string_lossy().into_owned();
        let opencode = bin.path().join("opencode").to_string_lossy().into_owned();
        let mcp = r#"{"mcpServers":{"s":{"command":"node","args":["./srv.js"]}}}"#;
        for argv in [
            &[codex.as_str(), "-c", "mcp_servers.x.command=node"][..],
            &[codex.as_str(), "-c", r#"mcp_servers.x.args=["srv.js"]"#],
            &[codex.as_str(), r#"-cmcp_servers.x.command="python3""#],
            &[opencode.as_str(), "--mcp-config", mcp],
            &[opencode.as_str(), "--hook", "node hook.js"],
        ] {
            assert_reads(dir.path(), argv, &[]);
        }
        for argv in [
            &[opencode.as_str(), "acp"][..],
            &[codex.as_str(), "-c", r#"model="gpt-5""#],
            &[codex.as_str(), "--model", "zai/glm-5"],
        ] {
            assert_eq!(judge(&launch(argv, &[]), dir.path(), &system_path()), None, "{argv:?}");
        }
    }

    /// An env name that is not on the env allowlist may load code from the folder: Ruby's and
    /// Perl's options, Bash's startup file, Python's home and user base, the dynamic loader's
    /// preload, zsh's config folder (item 4). A reviewed name keeps the claim with any value.
    #[test]
    fn an_env_name_off_the_list_reads_the_folder() {
        let dir = review_folder();
        for folder in ["venv", "u", "conf"] {
            std::fs::create_dir_all(dir.path().join(folder)).unwrap();
        }
        for file in ["rc.sh", "hook.dylib"] {
            std::fs::write(dir.path().join(file), "").unwrap();
        }
        let script = ["python3", "/opt/agent.py"];
        for env in [
            ("RUBYOPT", "-I. -ragent"),
            ("PERL5OPT", "-I. -Magent"),
            ("BASH_ENV", "rc.sh"),
            ("PYTHONHOME", "venv"),
            ("PYTHONUSERBASE", "u"),
            ("DYLD_INSERT_LIBRARIES", "hook.dylib"),
            ("ZDOTDIR", "conf"),
        ] {
            assert_reads(dir.path(), &script, &[env]);
        }
        let reviewed = [("LANG", "C.UTF-8"), ("OPENAI_BASE_URL", "https://example.com/v1")];
        assert_eq!(judge(&launch(&script, &reviewed), dir.path(), &system_path()), None);
    }

    /// `PYTHONSAFEPATH` exists only from Python 3.11: a Python whose version acpmux cannot tell
    /// (`python3`, which a folder's `.python-version` may choose) gets no credit for it (lead).
    #[test]
    fn the_safe_path_counts_only_on_a_python_known_to_have_it() {
        let dir = review_folder();
        let safe = [("PYTHONSAFEPATH", "1")];
        let (tools, path) = tools();
        for argv in [&["python3", "-m", "agent"][..], &["python3.10", "-m", "agent"]] {
            let why = judge(&launch(argv, &safe), dir.path(), &path);
            assert_eq!(why, Some("launch_reads_folder"), "{argv:?}");
        }
        let absolute = tools.path().join("python3.11").to_string_lossy().into_owned();
        for argv in [&["python3.12", "-m", "agent"][..], &[absolute.as_str(), "-um", "agent"]] {
            assert_eq!(judge(&launch(argv, &safe), dir.path(), &path), None, "{argv:?}");
        }
    }

    #[test]
    fn a_command_that_skips_approvals_carries_no_claim() {
        let cwd = Path::new("/w");
        for flag in ["--yolo", "--dangerously-skip-permissions"] {
            let pinned = launch(&["/usr/bin/agent", flag], &[]);
            assert_eq!(judge(&pinned, cwd, &system_path()), Some("argv_skips_approvals"), "{flag}");
        }
    }

    fn config(entry_env: &str, defaults_env: &str, preset_env: &str) -> Config {
        serde_json::from_value(json!({
            "harnesses": {"lane": {"argv": ["/usr/bin/lane"], "env": {"E": entry_env}}},
            "defaults": {"lane": {"env": {"D": defaults_env}}},
            "presets": {"p": {"harness": "lane", "env": {"P": preset_env}}},
        }))
        .unwrap()
    }

    #[test]
    fn the_config_inputs_follow_the_entry_its_defaults_and_its_preset() {
        let base = config_inputs(&config("1", "1", "1"), "lane", Some("p")).unwrap();
        let again = config_inputs(&config("1", "1", "1"), "lane", Some("p"));
        assert_eq!(again.as_deref(), Some(base.as_str()));
        for changed in [config("2", "1", "1"), config("1", "2", "1"), config("1", "1", "2")] {
            assert_ne!(config_inputs(&changed, "lane", Some("p")).as_deref(), Some(base.as_str()));
        }
        let unpreset = config_inputs(&config("1", "1", "1"), "lane", None);
        assert_ne!(unpreset.as_deref(), Some(base.as_str()));
        assert_eq!(config_inputs(&config("1", "1", "1"), "acme", None), None);
    }

    /// A start records a basis only when the config it reads with the preset still has the entry
    /// and the defaults env the start resolved: a change in between is no basis.
    #[test]
    fn a_start_records_a_basis_only_from_the_config_it_resolved() {
        let cfg = config("1", "1", "1");
        let digest = cfg.harnesses["lane"].launch_digest();
        let defaults = cfg.defaults_for("lane").env;
        let mut with_preset = defaults.clone();
        with_preset.insert("P".to_owned(), "1".to_owned());
        let want = config_inputs(&cfg, "lane", Some("p")).unwrap();
        for env in [&defaults, &with_preset] {
            let got = start_claim(&cfg, "lane", Some("p"), &digest, env);
            assert_eq!(got.as_deref(), Ok(want.as_str()));
        }
        let entry_now = config("2", "1", "1");
        let got = start_claim(&entry_now, "lane", Some("p"), &digest, &defaults);
        assert_eq!(got, Err("entry_changed"));
        let defaults_now = config("1", "2", "1");
        let got = start_claim(&defaults_now, "lane", Some("p"), &digest, &defaults);
        assert_eq!(got, Err("entry_changed"));
        let gone = start_claim(&cfg, "acme", None, &digest, &defaults);
        assert_eq!(gone, Err("not_a_config_entry"));
    }
}
