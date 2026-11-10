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

/// Programs that run the chat folder's own packages, project files or settings (`package.json`,
/// `pyproject.toml`, `bunfig.toml`, `deno.json`, `.env`) before any other: their launch is the
/// folder's.
const PACKAGE_RUNNERS: &[&str] =
    &["npx", "bunx", "pnpx", "npm", "pnpm", "yarn", "bun", "deno", "uv", "uvx", "pipx"];

/// Node's flags that run code given on the command line, which resolves packages from the
/// working folder.
const NODE_EVAL: &[&str] = &["-e", "--eval", "-p", "--print"];

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

/// Whether launch `spawned` runs code that folder `cwd` chose. It does when:
/// - its program is a package runner, a relative path with a folder in it (`./agent`), or an
///   absolute path inside the folder; under a wrapper (`env`, `nice`, `timeout`, [`WRAPPERS`]),
///   every later word is judged as the program it may run;
/// - Python runs a module or code of the command line (`-m`, `-c`, also in a cluster such as
///   `-um`, or stdin), which imports from the folder first (not with `-P` or `-I`, nor with
///   `PYTHONSAFEPATH` unless `-E` drops it); Node runs code of the command line or preloads a
///   module by a name that is no absolute path, also in `NODE_OPTIONS`;
/// - an argument (or an option's value: `--flag=value`, `-rvalue`) is a path inside the folder,
///   a relative path to something the folder holds (so a model name such as `zai/glm-5` is no
///   path), or a bare word that names something the folder holds when acpmux cannot tell that it
///   is no path: an option's value (the word after `-x`/`--xx` or after `=`), or any word of a
///   launch that names an interpreter or a wrapper. A bare word of another program that follows
///   no option (`opencode acp`, `agent .`) is a subcommand or the program's own argument;
/// - an env value, or a part of one (a list, `KEY=path`, `--flag path`), is a path inside the
///   folder, `.`/`..` or a `./`/`../` path, a relative path to a file the folder holds, or any
///   relative or empty entry of a `*PATH` list;
/// - a `PATH` entry is empty or relative (it names the folder), or a bare program resolves, on
///   `PATH`, to a file whose real path is inside the folder (a chat in the home folder counts
///   `~/.local/bin/agent` as the folder's: fail closed). A link in a `PATH` folder to a program
///   outside the chat folder is that program.
///
/// The root folder holds every program, so it chooses none.
fn reads_folder(spawned: &HarnessProfile, cwd: &Path, path: &[PathBuf]) -> bool {
    if cwd.parent().is_none() {
        return false;
    }
    let argv = &spawned.argv;
    let Some((program, args)) = argv.split_first() else { return false };
    let folder = Folder::of(cwd);
    // The program, and under a wrapper each later word that may be the program it runs.
    let wrapped = WRAPPERS.contains(&name_of(program));
    let mut programs = std::iter::once(0).chain((1..argv.len()).filter(|_| wrapped));
    if programs.any(|i| match argv.get(i..) {
        Some([program, rest @ ..]) => {
            runs_folder_program(program, rest, i == 0, spawned, &folder, path)
        }
        _ => false,
    }) {
        return true;
    }
    // A bare word is judged when acpmux cannot tell that it is no path (see above).
    let interpreted =
        argv.iter().any(|w| is_interpreter(name_of(w)) || WRAPPERS.contains(&name_of(w)));
    let mut after_option = false;
    for arg in args {
        for (word, option_value) in arg_paths(arg, after_option) {
            let at = Path::new(word);
            let inside = if at.is_absolute() {
                folder.holds(at)
            } else {
                (word.contains('/') || interpreted || option_value) && cwd.join(word).exists()
            };
            if inside {
                return true;
            }
        }
        after_option = arg.starts_with('-') && arg != "-" && arg != "--" && !arg.contains('=');
    }
    if spawned.env.iter().any(|(key, value)| env_in_folder(key, value, &folder)) {
        return true;
    }
    if spawned.env.get("NODE_OPTIONS").is_some_and(|v| bare_preload(v.split_whitespace())) {
        return true;
    }
    path.iter().any(|dir| dir.as_os_str().is_empty() || dir.is_relative())
}

/// Whether `program` run with `rest` runs code the folder chose: a package runner, a relative
/// path with a folder in it (for a word under a wrapper, `first` false: one the folder holds, so
/// a model name such as `zai/glm-5` is none), an absolute path inside the folder, an interpreter
/// that loads the folder's modules, or a bare program that `path` resolves inside the folder.
fn runs_folder_program(
    program: &str,
    rest: &[String],
    first: bool,
    spawned: &HarnessProfile,
    folder: &Folder,
    path: &[PathBuf],
) -> bool {
    let named = name_of(program);
    let at = Path::new(program);
    PACKAGE_RUNNERS.contains(&named)
        || (program.contains('/')
            && at.is_relative()
            && (first || folder.written.join(at).exists()))
        || (at.is_absolute() && folder.holds(at))
        || runs_folder_modules(named, rest, &spawned.env)
        || (!program.contains('/') && resolves_in_folder(program, path, folder))
}

/// The file name of program word `word` (`python3` of `/usr/bin/python3`).
fn name_of(word: &str) -> &str {
    Path::new(word).file_name().and_then(|n| n.to_str()).unwrap_or(word)
}

/// Programs that run a script or code named by their arguments.
const INTERPRETERS: &[&str] = &[
    "node", "nodejs", "ruby", "perl", "php", "lua", "bash", "sh", "zsh", "dash", "tsx", "ts-node",
    "pypy", "pypy3",
];

/// Whether `named` is an interpreter ([`INTERPRETERS`], or any `python*`).
fn is_interpreter(named: &str) -> bool {
    named.starts_with("python") || INTERPRETERS.contains(&named)
}

/// Programs that run another program named by a later word (`env python3 agent.py`,
/// `timeout 3600 node agent.js`).
const WRAPPERS: &[&str] = &[
    "env",
    "nice",
    "nohup",
    "timeout",
    "stdbuf",
    "time",
    "command",
    "exec",
    "ionice",
    "taskset",
    "chrt",
    "setsid",
    "caffeinate",
    "arch",
    "sudo",
    "doas",
    "xcrun",
    "unbuffer",
    "flock",
];

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

/// Whether interpreter `named` with arguments `args` and env `env` loads modules from the working
/// folder (the chat's): see [`reads_folder`].
fn runs_folder_modules(named: &str, args: &[String], env: &BTreeMap<String, String>) -> bool {
    if named.starts_with("python") {
        return python_reads_folder(args, env);
    }
    if named == "node" || named == "nodejs" {
        let mut words = args.iter().map(String::as_str);
        while let Some(arg) = words.next() {
            if NODE_EVAL.iter().any(|f| arg == *f || arg.starts_with(&format!("{f}="))) {
                return true;
            }
            if preload_value(arg, &mut words).is_some_and(|v| !Path::new(v).is_absolute()) {
                return true;
            }
            if !arg.starts_with('-') {
                return false;
            }
        }
        // No script: code from stdin.
        return true;
    }
    false
}

/// The module preload option `word` names, taking its value from `word` (`--import=hook`) or
/// from the next of `words` (`-r hook`), or None when `word` is no preload option.
fn preload_value<'a>(word: &'a str, words: &mut impl Iterator<Item = &'a str>) -> Option<&'a str> {
    if NODE_PRELOAD.contains(&word) {
        return Some(words.next().unwrap_or_default());
    }
    NODE_PRELOAD.iter().find_map(|f| word.strip_prefix(f).and_then(|v| v.strip_prefix('=')))
}

/// Whether Node options `words` (argv or `NODE_OPTIONS`) preload a module by a name that is no
/// absolute path, which Node resolves from the working folder. A quoted value is no absolute path
/// (fail closed).
fn bare_preload<'a>(mut words: impl Iterator<Item = &'a str>) -> bool {
    while let Some(word) = words.next() {
        if preload_value(word, &mut words).is_some_and(|v| !Path::new(v).is_absolute()) {
            return true;
        }
    }
    false
}

/// Whether Python run with `args` and env `env` imports from the working folder: it runs a module
/// or code of the command line (`-m`, `-c`, also inside a cluster such as `-um`) or reads code
/// from stdin, and does not keep the safe import path (`-P`, `-I`, or `PYTHONSAFEPATH` that no
/// `-E` drops). A script runs from its own folder, which the argument rules judge.
fn python_reads_folder(args: &[String], env: &BTreeMap<String, String>) -> bool {
    let (mut p, mut isolated, mut no_env) = (false, false, false);
    let safe = |p: bool, isolated: bool, no_env: bool| {
        p || isolated || (!no_env && env.get("PYTHONSAFEPATH").is_some_and(|v| !v.is_empty()))
    };
    let mut words = args.iter();
    while let Some(arg) = words.next() {
        if arg == "-" {
            break;
        }
        if arg == "--" {
            // The next word is the script; none is stdin.
            return words.next().is_none() && !safe(p, isolated, no_env);
        }
        if let Some(long) = arg.strip_prefix("--") {
            if long == "check-hash-based-pycs" {
                words.next();
            }
            continue;
        }
        let Some(cluster) = arg.strip_prefix('-') else {
            // A script.
            return false;
        };
        let mut letters = cluster.chars();
        while let Some(letter) = letters.next() {
            match letter {
                'c' | 'm' => return !safe(p, isolated, no_env),
                'P' => p = true,
                'I' => isolated = true,
                'E' => no_env = true,
                // Options whose value is the rest of the cluster or the next word.
                'W' | 'X' => {
                    if letters.as_str().is_empty() {
                        words.next();
                    }
                    break;
                }
                _ => {}
            }
        }
    }
    // No script: code from stdin.
    !safe(p, isolated, no_env)
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

    #[test]
    fn a_launch_of_programs_outside_the_folder_carries_a_claim() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        let plain = launch(&["/usr/bin/python3", "/opt/agent.py", "--mode=ask"], &[]);
        assert_eq!(judge(&plain, cwd, &system_path()), None);
        // A bare program found on PATH, also when the folder holds a file of its name.
        std::fs::write(cwd.join("python3"), "").unwrap();
        let bare = launch(&["python3", "-u", "/opt/agent.py"], &[]);
        assert_eq!(judge(&bare, cwd, &system_path()), None);
        // Python that guards its import path, Node that preloads an absolute module.
        let guarded = launch(&["python3", "-P", "-m", "agent"], &[]);
        assert_eq!(judge(&guarded, cwd, &system_path()), None);
        let safe = launch(&["python3", "-m", "agent"], &[("PYTHONSAFEPATH", "1")]);
        assert_eq!(judge(&safe, cwd, &system_path()), None);
        let node = launch(&["node", "--require", "/opt/hook.js", "/opt/agent.js"], &[]);
        assert_eq!(judge(&node, cwd, &system_path()), None);
        // A model name with a slash is no path, nor is a plain env value.
        let model =
            launch(&["/usr/bin/agent", "--model", "zai/glm-5"], &[("AGENT_MODEL", "zai/glm-5")]);
        assert_eq!(judge(&model, cwd, &system_path()), None);
        // A path that only starts with the folder's name is another folder.
        let sibling = format!("{}-other/bin", cwd.display());
        let beside = launch(&["/usr/bin/agent"], &[("TOOLS", sibling.as_str())]);
        assert_eq!(judge(&beside, cwd, &system_path()), None);
        let beside_path = paths(&format!("{sibling}:/usr/bin"));
        assert_eq!(judge(&plain, cwd, &beside_path), None);
        // A PATH folder inside the chat folder whose program links to one outside it, as the
        // test PATH's tool links are, runs that program.
        let tools = cwd.join("tools");
        std::fs::create_dir_all(&tools).unwrap();
        std::os::unix::fs::symlink("/bin/sh", tools.join("agent")).unwrap();
        let linked = paths(&format!("{}:/usr/bin", tools.display()));
        assert_eq!(judge(&launch(&["agent", "/opt/agent.sh"], &[]), cwd, &linked), None);
        // The root folder chooses nothing.
        let root = launch(&["/usr/bin/python3", "-m", "agent"], &[]);
        assert_eq!(judge(&root, Path::new("/"), &paths(".")), None);
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
        reads(&["/usr/bin/agent", format!("-r{inside}").as_str()], &[], sys);
        // Env values.
        reads(&["/usr/bin/agent"], &[("PYTHONPATH", folder)], sys);
        reads(&["/usr/bin/agent"], &[("PYTHONPATH", ".")], sys);
        reads(&["/usr/bin/agent"], &[("PYTHONPATH", "lib")], sys);
        reads(&["/usr/bin/agent"], &[("NODE_PATH", "node_modules")], sys);
        reads(&["/usr/bin/agent"], &[("PYTHONPATH", "/opt::/usr/lib")], sys);
        reads(&["/usr/bin/agent"], &[("NODE_OPTIONS", "--require ./hook.js")], sys);
        reads(
            &["/usr/bin/agent"],
            &[("NODE_OPTIONS", format!("--require={inside}").as_str())],
            sys,
        );
        // PATH entries: relative, empty, or inside the folder (the login shell's too).
        reads(&["agent"], &[], "bin:/usr/bin");
        reads(&["agent"], &[], ":/usr/bin");
        reads(&["agent"], &[], ".:/usr/bin");
        // A bare program that PATH finds in the folder.
        let bin = cwd.join("node_modules").join(".bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(bin.join("agent"), "#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(bin.join("agent"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        reads(&["agent"], &[], &format!("{}:/usr/bin", bin.display()));
    }

    /// The PATH judged is the one the agent gets: the launch's own entries, as written, then the
    /// login shell's.
    #[test]
    fn the_launchs_own_path_is_judged_as_written() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        for own in ["bin:/usr/bin", ":/usr/bin"] {
            let why = unbelieved_launch(&launch(&["agent"], &[("PATH", own)]), cwd);
            assert_eq!(why, Some("launch_reads_folder"), "{own}");
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
        for (cwd, script) in [(&real, &through_link), (&link, &direct)] {
            for argv in [vec!["python3", script.as_str()], vec![script.as_str()]] {
                let why = judge(&launch(&argv, &[]), cwd, &system_path());
                assert_eq!(why, Some("launch_reads_folder"), "{argv:?} in {}", cwd.display());
            }
            let env = launch(&["/usr/bin/agent"], &[("PYTHONPATH", script.as_str())]);
            let why = judge(&env, cwd, &system_path());
            assert_eq!(why, Some("launch_reads_folder"), "env {script} in {}", cwd.display());
        }
    }

    /// A bare word of a program that is no interpreter or wrapper, and that follows no option, is
    /// no path: a subcommand (`opencode acp`) or `.` is no file of the folder, even when the folder
    /// holds one of that name (review of #40158).
    #[test]
    fn a_bare_argument_word_is_no_path() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        std::fs::write(cwd.join("acp"), "").unwrap();
        for argv in [["/usr/bin/opencode", "acp"], ["/usr/bin/agent", "."]] {
            assert_eq!(judge(&launch(&argv, &[]), cwd, &system_path()), None, "{argv:?}");
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
            &["/usr/bin/agent", "--config", "agent.json"],
            &["/usr/bin/agent", "--config=agent.json"],
        ];
        for argv in argvs {
            let why = judge(&launch(argv, &[]), cwd, &system_path());
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
            (&["python3", "-um", "agent"], &safe),
        ];
        for (argv, env) in guarded {
            assert_eq!(judge(&launch(argv, env), cwd, &system_path()), None, "{argv:?} {env:?}");
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
        let absolute =
            launch(&["node", "/opt/agent.js"], &[("NODE_OPTIONS", "--require /opt/hook.js")]);
        assert_eq!(judge(&absolute, cwd, &system_path()), None);
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

    /// `PYTHONSAFEPATH` exists only from Python 3.11: a Python whose version acpmux cannot tell
    /// (`python3`, which a folder's `.python-version` may choose) gets no credit for it (lead).
    #[test]
    fn the_safe_path_counts_only_on_a_python_known_to_have_it() {
        let dir = review_folder();
        let safe = [("PYTHONSAFEPATH", "1")];
        assert_reads(dir.path(), &["python3", "-m", "agent"], &safe);
        assert_reads(dir.path(), &["python3.10", "-m", "agent"], &safe);
        for argv in [&["python3.12", "-m", "agent"][..], &["/usr/bin/python3.11", "-um", "agent"]] {
            assert_eq!(judge(&launch(argv, &safe), dir.path(), &system_path()), None, "{argv:?}");
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
