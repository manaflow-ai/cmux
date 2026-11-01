//! Read-only shell commands under approve-reads. Leo: "Read-only commands (rg,
//! git status/diff/rev-parse, pwd) under approve-reads must auto-approve and never prompt."
//!
//! Claude Code's Bash and Codex's shell commands both ask as tool kind `execute`, which the
//! policies never approved, so a reviewer under approve-reads stopped on "allow this?" for
//! `rg foo` or `pwd; git status`. Both harnesses put the script in `toolCall.rawInput.command`:
//! Claude Code passes its Bash input `{"command": ...}`, and cmux-codex-acp unwraps `bash -lc`
//! (`items.rs` `shell_script`). An argv `[sh|bash|zsh, -c|-lc, script]` is read the same way.
//!
//! This is a strict allowlist that fails closed: a script passes only when every command in it
//! is a known reader with no option that writes or runs another program. Anything the
//! tokenizer cannot read plainly (an expansion, a redirection, a subshell, a background job,
//! an unterminated quote) refuses, and a refusal only means the person is asked as before.
//! `permissions.rs` answers a pass with allow_once only, never a persistent grant.
//!
//! Git reads can still run a program the repository names: `core.fsmonitor`, a diff driver's
//! `textconv`, `diff.external`, a clean filter, `gpg.program` under `log.showSignature`, or a
//! `post-index-change` hook. So a script with git passes only when the repository it reads, and
//! every submodule checked out in it, names none (`repository_runs_nothing`). `cd` asks:
//! Claude Code's shell keeps the directory for its next command, whose git reads would then
//! look at a repository this never checked.
//!
//! The commands run with the harness's environment, not the daemon's, so they are judged in it
//! (`permissions.rs` passes `login_env::effective_for` of the env its agent was started with:
//! profile, family defaults, preset, session env and route): a bare name passes only when that
//! PATH finds it in a system directory first, an environment that points these programs
//! elsewhere (`GIT_*`, `LD_PRELOAD`, `BASH_ENV`, ...) asks, and the repository probe runs that
//! git with that environment. Not under approve-edits: an agent that writes files unasked could
//! put its own `rg` in one of those directories.
//!
//! An allowed git read may still write git's own bookkeeping, as it does when the person runs
//! it: `git status` refreshes the index's stat data. Nothing the agent chooses reaches it.
//!
//! What is trusted: the launch environment and the person's own files it points at (`$HOME`'s
//! shell startup files, `~/.gitconfig`). The agent changes those only by writing, which asks.
//! Git config in every scope passes only keys that name no program a read runs
//! (`key_runs_nothing`, plus `person_key_runs_nothing` outside the repository).

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Directories a command given by path may come from; a relative path or any other directory
/// could be a program the agent wrote.
const TRUSTED_DIRS: [&str; 6] =
    ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/sbin", "/usr/sbin"];

/// Commands that only read, whatever their arguments.
const PLAIN: &[&str] = &[
    "pwd", "ls", "cat", "head", "tail", "wc", "echo", "true", "false", "which", "type", "stat",
    "du", "df", "basename", "dirname", "realpath", "readlink", "cut", "tr", "nl", "cmp", "comm",
    "grep", "egrep", "fgrep", "column", "whoami", "id", "uname", "jq",
];

/// Shell builtins: they run in the shell, whatever PATH holds.
const BUILTINS: &[&str] = &["pwd", "echo", "true", "false", "test", "[", "type"];

/// `GIT_*` variables that make no read run another program (identity, editors for commands that
/// edit, the prompt switch); every other one asks (`GIT_EXTERNAL_DIFF`, `GIT_CONFIG_COUNT`, ...).
const HARMLESS_GIT_ENV: &[&str] = &[
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL",
    "GIT_COMMITTER_DATE",
    "GIT_EDITOR",
    "GIT_SEQUENCE_EDITOR",
    "GIT_TERMINAL_PROMPT",
];

/// Variables that make the shell or these programs load or run something else.
const RUNS_ENV: &[&str] = &[
    "BASH_ENV",
    "ENV",
    "SHELLOPTS",
    "BASHOPTS",
    "PROMPT_COMMAND",
    "IFS",
    "PS4",
    "RIPGREP_CONFIG_PATH",
    "GREP_OPTIONS",
    "JQ_LIBRARY_PATH",
    "PAGER",
    "LESSOPEN",
    "LESSCLOSE",
    "LESSKEY",
    "LESSKEYIN",
    "MANPAGER",
    // zsh runs `$ZDOTDIR/.zshenv` before any `-c` script.
    "ZDOTDIR",
    // glibc writes a trace file.
    "MALLOC_TRACE",
];

/// How long the repository probe may take before the command asks instead.
pub(crate) const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// The environment the harness runs its shell commands with.
pub(crate) type Env = BTreeMap<String, String>;

/// Whether `env` points none of these programs at another program or file. The library search
/// path cargo sets for its tests passes on each OS: `LD_LIBRARY_PATH` on Linux and
/// `DYLD_FALLBACK_LIBRARY_PATH` on macOS. Each only finds libraries already on disk, and putting
/// one there takes an edit, which asks; the macOS one is searched only for a library its install
/// name does not find (and macOS drops every `DYLD_*` variable when it starts a protected system
/// program such as `/usr/bin/git`). Any other loader variable asks: one loads a library first
/// (`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, searched before the install name), another
/// writes a trace (`LD_DEBUG_OUTPUT`, `DYLD_PRINT_TO_FILE`).
fn env_runs_nothing(env: &Env) -> bool {
    env.keys().all(|k| {
        !(RUNS_ENV.contains(&k.as_str())
            || (k.starts_with("LD_") && k != "LD_LIBRARY_PATH")
            || (k.starts_with("DYLD_") && k != "DYLD_FALLBACK_LIBRARY_PATH")
            // An exported bash function (`BASH_FUNC_pwd%%`) runs in place of the command it names.
            || k.starts_with("BASH_FUNC_")
            || (k.starts_with("GIT_") && !HARMLESS_GIT_ENV.contains(&k.as_str())))
    })
}

/// Whether every PATH entry is absolute. An empty or relative one is searched from the command's
/// own directory, which this cannot see from the daemon's (`PATH=.:/usr/bin` finds `./ls`).
fn path_is_absolute(env: &Env) -> bool {
    env.get("PATH").is_none_or(|path| std::env::split_paths(path).all(|d| d.is_absolute()))
}

/// Whether the shell that runs the script is a system one. Claude Code runs `$SHELL`, and Codex
/// a bare `bash` (or `sh`, `zsh`) that its PATH finds, whose `-c` script cmux-codex-acp unwraps
/// before this sees it: `$SHELL` must name a system shell, and each of those names must be
/// found first in a system directory, or not at all.
fn shells_are_system(env: &Env) -> bool {
    let system = |p: &str| {
        Path::new(p).parent().and_then(Path::to_str).is_some_and(|d| TRUSTED_DIRS.contains(&d))
    };
    env.get("SHELL").is_none_or(|s| system(s))
        && ["bash", "sh", "zsh"].iter().all(|name| {
            let first = env.get("PATH").and_then(|path| {
                std::env::split_paths(path).map(|dir| dir.join(name)).find(|p| p.exists())
            });
            first.is_none_or(|p| p.to_str().is_some_and(system))
        })
}

/// Where the shell finds the bare command `name` with `env`'s PATH: the first executable
/// `DIR/name`, when DIR is a system directory. None when it is found elsewhere first, or not at all.
fn resolve(name: &str, env: &Env) -> Option<PathBuf> {
    #[cfg(unix)]
    let runs = |m: &std::fs::Metadata| {
        use std::os::unix::fs::PermissionsExt;
        m.permissions().mode() & 0o111 != 0
    };
    #[cfg(not(unix))]
    let runs = |_: &std::fs::Metadata| false;
    let path = env.get("PATH")?;
    let found = std::env::split_paths(path)
        .map(|dir| dir.join(name))
        .find(|p| p.metadata().is_ok_and(|m| m.is_file() && runs(&m)))?;
    found
        .parent()
        .and_then(Path::to_str)
        .is_some_and(|d| TRUSTED_DIRS.contains(&d))
        .then_some(found)
}

const GIT_READS: &[&str] = &[
    "status",
    "diff",
    "log",
    "show",
    "rev-parse",
    "merge-base",
    "ls-files",
    "ls-tree",
    "cat-file",
    "blame",
    "grep",
    "describe",
    "shortlog",
    "rev-list",
    "show-ref",
    "for-each-ref",
    "name-rev",
    "count-objects",
    "whatchanged",
    "version",
];

/// Whether the toolCall of `request` is a shell command (`execute`) that only reads, run with
/// `env` from the request's own `cwd` (or `workdir`) when it names one, else from
/// `session_cwd`. Its git reads look at the repositories on disk, so call this off the async
/// workers.
pub(crate) fn request_is_read_only(request: &Value, session_cwd: &Path, env: &Env) -> bool {
    let Some(call) = request.get("toolCall") else { return false };
    if call.get("kind").and_then(Value::as_str) != Some("execute") {
        return false;
    }
    let argv: Option<Vec<&str>> = match call.pointer("/rawInput/command") {
        Some(Value::Array(argv)) => argv.iter().map(Value::as_str).collect(),
        _ => None,
    };
    let script = match call.pointer("/rawInput/command") {
        Some(Value::String(script)) => script.as_str(),
        Some(Value::Array(_)) => match argv.as_deref() {
            Some([shell, "-c" | "-lc", script])
                if matches!(command_name(shell), Some("sh" | "bash" | "zsh")) =>
            {
                script
            }
            _ => return false,
        },
        _ => return false,
    };
    if !env_runs_nothing(env) || !path_is_absolute(env) || !shells_are_system(env) {
        return false;
    }
    let found = |name: &str| BUILTINS.contains(&name) || resolve(name, env).is_some();
    let Some(git_dirs) = git_dirs(script, &found) else { return false };
    if git_dirs.is_empty() {
        return true;
    }
    let Some(git) = resolve("git", env) else { return false };
    let raw = call.get("rawInput");
    let base = ["cwd", "workdir"]
        .iter()
        .find_map(|k| raw.and_then(|r| r.get(*k)).and_then(Value::as_str))
        .map_or_else(|| session_cwd.to_path_buf(), |d| session_cwd.join(d));
    git_dirs.iter().all(|dir| {
        let dir = dir.as_deref().map_or_else(|| base.clone(), |d| base.join(d));
        repository_runs_nothing(&git, env, &dir, 0)
    })
}

/// Whether shell `script` only reads, as far as its text shows: every command in it passes
/// the allowlist. Its bare names still need `resolve`, and its git reads `repository_runs_nothing`.
#[cfg(test)]
pub(crate) fn is_read_only(script: &str) -> bool {
    git_dirs(script, &|_| true).is_some()
}

/// The `-C` directory of each git command in `script` (None: git's own directory), when every
/// command passes the allowlist and `found` passes each bare command name; None otherwise.
fn git_dirs(script: &str, found: &dyn Fn(&str) -> bool) -> Option<Vec<Option<String>>> {
    let segments = segments(script)?;
    if segments.iter().all(Vec::is_empty) {
        return None;
    }
    let mut git = Vec::new();
    for s in &segments {
        if let Some(first) = s.first()
            && !first.contains('/')
            && !found(first)
        {
            return None;
        }
        if let Reads::Git(dir) = segment_ok(s)? {
            git.push(dir);
        }
    }
    Some(git)
}

/// Ends a word that holds an unquoted glob: the shell expands it after this has read it, so a
/// command whose arguments this checks by text (git) asks. The script refuses control
/// characters, so none of its own words holds one.
const GLOBBED: char = '\0';

/// Whether `text` names a signature check, which verifies with gpg: a `signature` atom or sort
/// key, or a `%G` placeholder with or without a modifier (`%+G?`, `%-GS`, `% GK`).
fn names_signature(text: &str) -> bool {
    text.contains("signature")
        || text.match_indices('%').any(|(i, _)| {
            let rest = text.get(i + 1..).unwrap_or("");
            rest.strip_prefix(['+', '-', ' ']).unwrap_or(rest).starts_with('G')
        })
}

/// What a command that passed the allowlist reads.
enum Reads {
    Plain,
    /// A git read, with its `-C` directory.
    Git(Option<String>),
}

/// The words of each command in `script`, split at `;`, `&&`, `||`, `|` and newlines. None
/// for anything this does not read plainly.
fn segments(script: &str) -> Option<Vec<Vec<String>>> {
    let mut segs = vec![Vec::new()];
    let mut word = String::new();
    let mut in_word = false;
    let mut globbed = false;
    let mut chars = script.chars().peekable();
    let end =
        |segs: &mut Vec<Vec<String>>, word: &mut String, in_word: &mut bool, globbed: &mut bool| {
            if std::mem::take(globbed) {
                word.push(GLOBBED);
            }
            if *in_word && let Some(last) = segs.last_mut() {
                last.push(std::mem::take(word));
            }
            *in_word = false;
        };
    while let Some(c) = chars.next() {
        match c {
            // Bash splits words only at space, tab and newline: a `\r` stays in the word.
            c if c.is_control() && c != '\t' && c != '\n' => return None,
            '\'' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        ch => word.push(ch),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '$' | '`' => return None,
                        '\\' => match chars.next()? {
                            // An escaped `$` is refused too: cmux-codex-acp's unwrap of a
                            // double-quoted `bash -lc "..."` leaves its escapes in place.
                            '$' | '`' => return None,
                            '\n' => {}
                            ch @ ('"' | '\\') => word.push(ch),
                            ch => {
                                word.push('\\');
                                word.push(ch);
                            }
                        },
                        ch => word.push(ch),
                    }
                }
            }
            '\\' => match chars.next()? {
                '$' | '`' => return None,
                '\n' => {}
                ch => {
                    in_word = true;
                    word.push(ch);
                }
            },
            '$' | '`' | '>' | '<' | '(' | ')' | '{' | '}' => return None,
            // A glob could expand to a file named like an option (`--pre=sh`): one passes only
            // after a literal prefix that is not an option.
            '*' | '?' | '[' => {
                let lone_bracket = c == '['
                    && !in_word
                    && chars.peek().is_none_or(|n| n.is_whitespace() || ";&|".contains(*n));
                if !lone_bracket && (!in_word || word.is_empty() || word.starts_with('-')) {
                    return None;
                }
                globbed |= !lone_bracket;
                in_word = true;
                word.push(c);
            }
            '#' if !in_word => while chars.next_if(|n| *n != '\n').is_some() {},
            ';' | '\n' => {
                end(&mut segs, &mut word, &mut in_word, &mut globbed);
                segs.push(Vec::new());
            }
            '&' => {
                // `&&` separates; a lone `&` runs a job in the background.
                chars.next_if_eq(&'&')?;
                end(&mut segs, &mut word, &mut in_word, &mut globbed);
                segs.push(Vec::new());
            }
            '|' => {
                chars.next_if_eq(&'|');
                end(&mut segs, &mut word, &mut in_word, &mut globbed);
                segs.push(Vec::new());
            }
            ' ' | '\t' => end(&mut segs, &mut word, &mut in_word, &mut globbed),
            ch => {
                in_word = true;
                word.push(ch);
            }
        }
    }
    end(&mut segs, &mut word, &mut in_word, &mut globbed);
    Some(segs)
}

/// The name a command word runs: itself, or the basename of a path in a trusted directory.
fn command_name(word: &str) -> Option<&str> {
    match word.rsplit_once('/') {
        None => Some(word),
        Some((dir, base)) => TRUSTED_DIRS.contains(&dir).then_some(base),
    }
}

/// A short option cluster (`-no`) holding `flag`.
fn short_has(arg: &str, flag: char) -> bool {
    arg.starts_with('-') && !arg.starts_with("--") && arg.get(1..).unwrap_or("").contains(flag)
}

/// A long option that GNU getopt and git read as `full`: any unambiguous prefix of it, with or
/// without `=VALUE` (`--out=f` is `--output=f`).
fn long_is(arg: &str, full: &str) -> bool {
    let name = arg.split_once('=').map_or(arg, |(n, _)| n);
    name.len() > 2 && name.starts_with("--") && full.starts_with(name)
}

fn segment_ok(words: &[String]) -> Option<Reads> {
    let Some((first, args)) = words.split_first() else { return Some(Reads::Plain) };
    // `GIT_EXTERNAL_DIFF=x git diff` runs x.
    if let Some((name, _)) = first.split_once('=')
        && !name.is_empty()
        && name.chars().all(|c| c == '_' || c.is_ascii_alphanumeric())
    {
        return None;
    }
    let name = command_name(first)?;
    if name == "git" {
        if args.iter().any(|a| a.ends_with(GLOBBED)) {
            return None;
        }
        return git_ok(args).map(Reads::Git);
    }
    let any = |f: &dyn Fn(&str) -> bool| args.iter().any(|a| f(a));
    let ok = match name {
        n if PLAIN.contains(&n) => true,
        // `-v NAME` and `-R NAME` evaluate an array subscript, which can hold `$(...)`.
        "test" | "[" => !any(&|a| matches!(a, "-v" | "-R")),
        // `--paginate` (`-l`) runs `pr`.
        "diff" => !any(&|a| short_has(a, 'l') || long_is(a, "--paginate")),
        // A filter on its input only: an operand is a file to read and the next one, however it
        // is spelled (BSD stops at the first operand, `-out` after it is the output), is written.
        "uniq" => args.iter().all(|a| {
            a.len() > 1
                && a.starts_with('-')
                && !a.starts_with("--")
                && a.get(1..).unwrap_or("").chars().all(|c| "cdiu".contains(c))
        }),
        // Only the time, as is or `+FORMAT`: an operand sets the clock, and BSD `-f` reads the
        // operand after it as the time to set.
        "date" => {
            args.iter().all(|a| matches!(a.as_str(), "-u" | "-R" | "--utc") || a.starts_with('+'))
        }
        "hostname" => args.iter().all(|a| {
            matches!(
                a.as_str(),
                "-s" | "-f"
                    | "-d"
                    | "-i"
                    | "-I"
                    | "-a"
                    | "-A"
                    | "--short"
                    | "--fqdn"
                    | "--long"
                    | "--domain"
                    | "--ip-address"
                    | "--all-ip-addresses"
                    | "--alias"
                    | "--all-fqdns"
            )
        }),
        // `--search-zip` (`-z`) runs gzip, xz and the like from PATH.
        "rg" => !any(&|a| {
            a == "--pre"
                || a.starts_with("--pre=")
                || a.starts_with("--pre-glob")
                || long_is(a, "--search-zip")
                || short_has(a, 'z')
                // Runs a program for the hostname of a hyperlink.
                || long_is(a, "--hostname-bin")
        }),
        "find" => !any(&|a| {
            a.starts_with("-exec")
                || a.starts_with("-ok")
                || a.starts_with("-fprint")
                || matches!(a, "-delete" | "-fls")
        }),
        _ => false,
    };
    ok.then_some(Reads::Plain)
}

/// A git read: its `-C` directory (at most one) when the rest passes.
fn git_ok(args: &[String]) -> Option<Option<String>> {
    let mut i = 0;
    let mut dir = None;
    while let Some(a) = args.get(i) {
        let named = match a.as_str() {
            "--no-pager" => {
                i += 1;
                continue;
            }
            "-C" => {
                i += 2;
                args.get(i - 1)?.clone()
            }
            a if a.starts_with("-C") => {
                i += 1;
                a.get(2..).unwrap_or("").to_owned()
            }
            a if a.starts_with('-') => return None,
            _ => break,
        };
        // The shell expands a glob or a leading `~` in the directory; the probe would read
        // another one.
        if named.contains(['*', '?', '[']) || named.starts_with('~') || dir.replace(named).is_some()
        {
            return None;
        }
    }
    git_read_ok(args.get(i..)?).then_some(dir)
}

fn git_read_ok(args: &[String]) -> bool {
    let Some((sub, rest)) = args.split_first() else { return false };
    // git takes any unambiguous prefix of a long option, and a short cluster (`-nOsh` is
    // `-n -O sh`). A signature check (`--show-signature`, a `%G` format) runs gpg.
    let grep = sub == "grep";
    let writes = |a: &String| {
        long_is(a, "--output")
            || short_has(a, 'O')
            // `git diff -o FILE` writes FILE; `git grep -o` only prints the matched part.
            || (short_has(a, 'o') && !grep)
            || long_is(a, "--open-files-in-pager")
            || long_is(a, "--ext-diff")
            || long_is(a, "--show-signature")
            // Any signature atom, sort key, dereference or `%G` placeholder verifies with gpg.
            || names_signature(a)
            // Opens the manual in a viewer.
            || long_is(a, "--help")
            // Runs smudge filters (git-lfs can fetch) and textconv drivers.
            || long_is(a, "--filters")
            || long_is(a, "--textconv")
    };
    if rest.iter().any(writes) {
        return false;
    }
    let first = rest.first().map(String::as_str);
    match sub.as_str() {
        s if GIT_READS.contains(&s) => true,
        "branch" => git_branch_ok(rest),
        "tag" => {
            rest.is_empty()
                || (rest.iter().any(|a| a == "-l" || a == "--list")
                    && rest.iter().all(|a| {
                        !a.starts_with('-')
                            || matches!(
                                a.as_str(),
                                "-l" | "--list"
                                    | "-i"
                                    | "--ignore-case"
                                    | "--column"
                                    | "--no-column"
                                    | "--contains"
                                    | "--no-contains"
                                    | "--merged"
                                    | "--no-merged"
                                    | "--points-at"
                            )
                            || a.starts_with("--sort=")
                            || a.starts_with("--format=")
                            || (a.starts_with("-n")
                                && a.get(2..).unwrap_or("").chars().all(|c| c.is_ascii_digit()))
                    }))
        }
        "remote" => match rest {
            [] => true,
            [v] => v == "-v" || v == "--verbose",
            [get, name] => get == "get-url" && !name.starts_with('-'),
            _ => false,
        },
        "config" => git_config_ok(rest),
        "worktree" => first == Some("list"),
        "stash" => matches!(first, Some("list" | "show")),
        "reflog" => matches!(first, None | Some("show")),
        _ => false,
    }
}

fn git_branch_ok(rest: &[String]) -> bool {
    let mut listing = false;
    for a in rest {
        match a.as_str() {
            "--list" | "-l" | "--contains" | "--merged" | "--no-merged" | "--points-at" => {
                listing = true
            }
            "-a" | "-r" | "-v" | "-vv" | "--all" | "--remotes" | "--show-current"
            | "--no-color" | "--color" => {}
            a if a.starts_with("--sort=") || a.starts_with("--format=") => {}
            a if a.starts_with('-') || !listing => return false,
            _ => {}
        }
    }
    true
}

/// `git config` that reads: a get or list mode, given first (`git config set ...` is a
/// subcommand on newer git).
fn git_config_ok(rest: &[String]) -> bool {
    if !rest.first().is_some_and(|a| a.starts_with('-')) {
        return false;
    }
    let (mut mode, mut listing) = (false, false);
    for a in rest {
        match a.as_str() {
            "--get" | "--get-all" | "--get-regexp" => mode = true,
            "--list" | "-l" => (mode, listing) = (true, true),
            "--global" | "--system" | "--local" | "--worktree" | "--show-origin"
            | "--show-scope" | "--null" | "-z" | "--name-only" | "--bool" | "--int"
            | "--bool-or-int" | "--path" | "--includes" | "--no-includes" => {}
            a if a.starts_with("--type=") => {}
            a if a.starts_with('-') || listing => return false,
            _ => {}
        }
    }
    mode
}

/// Whether git reads in `dir` run no program its repository names: the repository's local and
/// worktree config hold only keys that name none (`key_runs_nothing`; the global and system
/// config are the person's own), no `post-index-change` hook is installed (`git status` and
/// `git diff` run it when they refresh the index), and every submodule checked out in it passes
/// too (`git status` reads them). A directory git cannot read as a repository asks.
fn repository_runs_nothing(git_bin: &Path, env: &Env, dir: &Path, depth: u8) -> bool {
    let git = |dir: &Path, args: &[&str]| -> Option<Vec<u8>> {
        let out = Command::new(git_bin)
            .env_clear()
            .envs(env)
            .arg("-C")
            .arg(dir)
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        out.status.success().then_some(out.stdout)
    };
    let text = |out: Vec<u8>| String::from_utf8(out).ok().map(|s| s.trim_end().to_owned());
    // Nothing below runs a program the repository names: rev-parse and config never do, and
    // ls-files runs only once the config has passed.
    if depth > 4 || git(dir, &["rev-parse", "--git-dir"]).is_none() {
        return false;
    }
    let Some(config) = git(dir, &["config", "--list", "--show-scope", "-z"]) else { return false };
    // `-z`: scope NUL key LF value NUL; a key with no value has no LF.
    let fields: Vec<&[u8]> = config.split(|b| *b == 0).collect();
    for pair in fields.chunks_exact(2) {
        let [scope, entry] = pair else { return false };
        let (Ok(scope), Ok(entry)) = (std::str::from_utf8(scope), std::str::from_utf8(entry))
        else {
            return false;
        };
        let (key, value) = entry.split_once('\n').unwrap_or((entry, "true"));
        let person = !matches!(scope, "local" | "worktree");
        // A value that names a signature check (`branch.sort = signature:grade`, a `%G` format)
        // makes a read verify with gpg, whatever key holds it.
        let verifies = names_signature(value);
        let passes = key_runs_nothing(key, value)
            || (person && person_key_runs_nothing(key))
            // `git lfs install` (runner images, Homebrew): its clean filter runs only on files
            // whose attributes name it, and reads only; smudging, which can fetch, asks
            // (`--filters`, `--textconv`). Its `lfs.*` settings (transfer agents) ask.
            || (person && is_lfs_filter(key, value) && resolve("git-lfs", env).is_some());
        if verifies || !passes {
            return false;
        }
    }
    let Some(hook) =
        git(dir, &["rev-parse", "--path-format=absolute", "--git-path", "hooks/post-index-change"])
            .and_then(text)
    else {
        return false;
    };
    if Path::new(&hook).symlink_metadata().is_ok() {
        return false;
    }
    // A bare repository, or a directory inside `.git`, has no work tree and no submodules.
    let Some(top) = git(dir, &["rev-parse", "--show-toplevel"]).and_then(text) else {
        return true;
    };
    let top = PathBuf::from(top);
    let Some(index) = git(&top, &["ls-files", "--stage", "-z"]) else { return false };
    index.split(|b| *b == 0).filter_map(|e| e.strip_prefix(b"160000 ")).all(|e| {
        let Some(path) = e.splitn(2, |b| *b == b'\t').nth(1) else { return false };
        let Ok(path) = std::str::from_utf8(path) else { return false };
        let sub = top.join(path);
        sub.join(".git").symlink_metadata().is_err()
            || repository_runs_nothing(git_bin, env, &sub, depth + 1)
    })
}

/// Keys of the person's own config (global or system) that no allowed read uses to run a
/// program: aliases (none names an allowed subcommand), an editor, credential helpers (no
/// allowed read talks to a remote: a promisor remote asks), signing settings (every way a read
/// checks a signature asks), and includes (`git config --list` lists the included keys, which
/// are checked themselves). A repository's own config passes none of these.
fn person_key_runs_nothing(key: &str) -> bool {
    let Some((section, rest)) = key.split_once('.') else { return false };
    let name = rest.rsplit_once('.').map_or(rest, |(_, n)| n);
    match section {
        "alias" | "credential" | "gpg" | "url" | "http" | "safe" => true,
        "include" => name == "path",
        "includeif" => name == "path",
        "core" => matches!(name, "editor" | "attributesfile"),
        "sequence" => name == "editor",
        "commit" => matches!(name, "gpgsign" | "verbose" | "template" | "cleanup"),
        "tag" => matches!(name, "gpgsign" | "forcesignannotated" | "sort"),
        "diff" | "merge" => rest == "tool",
        _ => false,
    }
}

/// The filter lines `git lfs install` writes.
fn is_lfs_filter(key: &str, value: &str) -> bool {
    matches!(
        (key, value),
        ("filter.lfs.clean", "git-lfs clean -- %f")
            | ("filter.lfs.smudge", "git-lfs smudge -- %f")
            | ("filter.lfs.process", "git-lfs filter-process")
            | ("filter.lfs.required", "true")
    )
}

/// Whether repository config `key` = `value` names no program for a git read to run. An
/// allowlist: anything else (`core.fsmonitor` naming a hook, `diff.<driver>.textconv`,
/// `diff.external`, `filter.<driver>.clean`, `log.showSignature` with `gpg.program`,
/// `core.pager`, `credential.helper`, `include.path`, ...) makes git reads ask.
fn key_runs_nothing(key: &str, value: &str) -> bool {
    let Some((section, rest)) = key.split_once('.') else { return false };
    let (sub, name) = match rest.rsplit_once('.') {
        Some((sub, name)) => (Some(sub), name),
        None => (None, rest),
    };
    match (section, sub) {
        // Off only: `true` starts git's own fsmonitor daemon, and any other value is a hook.
        ("core", None) if name == "fsmonitor" => {
            matches!(value.to_ascii_lowercase().as_str(), "false" | "no" | "off" | "0" | "")
        }
        // core.hooksPath: the hook itself is checked where git looks for it.
        ("core", None) => matches!(
            name,
            "repositoryformatversion"
                | "filemode"
                | "bare"
                | "logallrefupdates"
                | "ignorecase"
                | "precomposeunicode"
                | "symlinks"
                | "autocrlf"
                | "safecrlf"
                | "eol"
                | "sparsecheckout"
                | "sparsecheckoutcone"
                | "untrackedcache"
                | "splitindex"
                | "commitgraph"
                | "multipackindex"
                | "quotepath"
                | "abbrev"
                | "checkstat"
                | "trustctime"
                | "preloadindex"
                | "longpaths"
                | "protecthfs"
                | "protectntfs"
                | "hookspath"
                | "excludesfile"
        ),
        ("extensions", None) => matches!(name, "worktreeconfig" | "objectformat" | "refstorage"),
        ("remote", Some(_)) => matches!(
            name,
            "url"
                | "pushurl"
                | "fetch"
                | "push"
                | "tagopt"
                | "prune"
                | "prunetags"
                | "mirror"
                | "skipdefaultupdate"
                | "skipfetchall"
        ),
        ("branch", Some(_)) => {
            matches!(name, "remote" | "merge" | "rebase" | "pushremote" | "description")
                || name == "vscode-merge-base"
        }
        ("branch", None) => matches!(name, "autosetupmerge" | "autosetuprebase" | "sort"),
        ("submodule", Some(_)) => matches!(name, "url" | "active" | "branch" | "ignore"),
        ("user", None) => matches!(name, "name" | "email" | "signingkey"),
        // Housekeeping and display: none of these names a program.
        ("gc" | "maintenance" | "fetch" | "color" | "status" | "advice", _) => true,
        ("pull", None) => matches!(name, "rebase" | "ff"),
        ("push", None) => matches!(name, "default" | "autosetupremote"),
        ("init", None) => name == "defaultbranch",
        ("index", None) => matches!(name, "version" | "threads" | "skiphash"),
        ("feature", None) => matches!(name, "manyfiles" | "experimental"),
        ("lfs", None) => name == "repositoryformatversion",
        ("diff", None) => matches!(
            name,
            "algorithm"
                | "renames"
                | "renamelimit"
                | "colormoved"
                | "indentheuristic"
                | "submodule"
                | "ignoresubmodules"
                | "mnemonicprefix"
                | "noprefix"
                | "context"
        ),
        ("log", None) => matches!(name, "decorate" | "date" | "follow" | "abbrevcommit"),
        ("merge", None) => matches!(name, "conflictstyle" | "ff"),
        ("rebase", None) => matches!(name, "autosquash" | "autostash" | "updaterefs"),
        ("rerere", None) => matches!(name, "enabled" | "autoupdate"),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_pass() {
        for script in [
            "rg -n foo src",
            "pwd; git rev-parse HEAD; git status --short",
            "git -C /x diff --stat",
            "git log --oneline -5 | head",
            "rg 'a$' x",
            "git branch --show-current",
            "/usr/bin/rg foo",
            "git --no-pager -C/x log -1",
            "ls src/*.rs",
            "[ -f x ] && cat x",
            "git config --get user.name",
            "git remote -v",
            "git tag -l 'v1*'",
            "git log --format='%h %s' -1",
            "ls src/*.rs | head",
            "git status # ; rm -rf x",
            "git log --oneline | uniq -c",
            "echo \"a b\" 'c'",
            "date +%s",
            "date -u",
            "diff -u a b",
            "test -f x",
            "rg -n foo",
            "git log --oneline --stat -1",
            "git grep -no needle",
        ] {
            assert!(is_read_only(script), "{script}");
        }
    }

    #[test]
    fn anything_else_refuses() {
        for script in [
            "rg foo > out",
            "git status; rm -rf x",
            "git -c core.pager=sh status",
            "find . -delete",
            "rg --pre sh foo",
            "echo $(id)",
            "echo `id`",
            "FOO=1 git diff",
            "git push",
            "git branch newbranch",
            "sed -i s/a/b/ f",
            "cat x &",
            "git config user.name x",
            "sort -o f x",
            "echo 'unterminated",
            "echo \"$HOME\"",
            "echo \\$HOME",
            "cat <<EOF",
            "(ls)",
            "{ ls; }",
            "rg foo *",
            "rg foo -- '--'*",
            "./rg foo",
            "/tmp/x/rg foo",
            "git",
            "git --git-dir=x status",
            "git diff --output=f",
            "git diff --ext-diff",
            "git grep -Ovi foo",
            "git stash",
            "git stash push",
            "git reflog expire --all",
            "git remote add x y",
            "git config --unset x",
            "git config set user.name x",
            "git tag v1",
            "find . -exec rm {} ;",
            "find . -fprint f",
            "sort -uo f x",
            "uniq a b",
            "uniq -- in -out",
            "date -s 2020-01-01",
            "hostname evil",
            "xargs rm",
            "bash -c ls",
            "",
            "ls |& cat",
            "printf -v PATH /tmp/evil; rg secret",
            "printf -vPATH . ; rg x",
            "cd /tmp && ls -la",
            "git -C a -C b status",
            // Codex review at 066066a8.
            "uniq -- in*",
            "uniq in*",
            "printf '%s\\n' a",
            "printf '%n' PATH; ls",
            "test -v 'BASH_VERSINFO[$(touch marker)0]'",
            "[ -v 'a[$(id)]' ]",
            "sort --out=result input",
            "sort --compress=x a",
            "file --comp -m magic",
            "git grep -nOsh needle -- payload.sh",
            "git diff --out=f",
            "git diff --ext",
            "rg -z needle file.gz",
            "rg -nz needle",
            "rg --search-z needle",
            "git log --show-signature -1",
            "git log --show-sig -1",
            "git log --format=%G? -1",
            // Codex review at 84851587.
            "git log --format='%+G?' -1",
            "git log --format=%-GS -1",
            "git log '--format=% GK' -1",
            "git for-each-ref --format %* refs/heads/main",
            "git for-each-ref --format=ab* refs/heads",
            "git log src/*.rs",
            "git show --pretty=format:%GS",
            "diff --paginate a b",
            "diff -ul a b",
            "pwd\rx",
            "pwd\u{0b}x",
            "date 102612002026",
            // Codex review at 630c4878.
            "git diff -o /tmp/out",
            "git log -po x",
            "sort -T /tmp x",
            "sort --temporary-directory=/tmp x",
            "sort --temp=/tmp x",
            // Codex review at 01e0b5a9.
            "git for-each-ref --sort=signature:grade refs/heads",
            "git for-each-ref --format='%(*signature:grade)' refs/tags",
            "git branch --sort=signature:grade --list",
            "sort -S 1K x",
            "sort -u x | uniq -c",
            // Codex review at a29dca90.
            "git -C repo[1] status",
            "git -C 'repo[1]' status",
            "git -C ~/x status",
            "git -C~ status",
            "git status --help",
            "git cat-file --filters HEAD:asset.bin",
            "git show --textconv HEAD:x",
            "git log --hel",
            "git for-each-ref --format='%(signature:grade)' refs/heads/main",
            "file -S -z payload.lrz",
            "file x",
            "tree -a",
            "/usr/bin/uniq /dev/null -out",
            "uniq -c -- -in",
            "uniq -f 1 x",
            "date -f '-%Y%m%d%H%M' -- -202610261200",
            "date -d now",
            "rg --hostname-bin=sh foo",
            "rg --hostname-b sh foo",
        ] {
            assert!(!is_read_only(script), "{script}");
        }
    }

    /// A new repository in a fresh directory, with `config` set in its local config.
    fn repo(config: &[(&str, &str)]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-readonly-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        git(&dir, &["init", "-q"]);
        for (key, value) in config {
            git(&dir, &["config", key, value]);
        }
        dir
    }

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git").arg("-C").arg(dir).args(args).status().unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// Only the system directories on PATH, and nothing else set.
    fn system_env() -> Env {
        Env::from([("PATH".to_owned(), TRUSTED_DIRS.join(":"))])
    }

    fn execute(command: Value) -> Value {
        json!({"toolCall": {"kind": "execute", "rawInput": {"command": command}}})
    }

    #[test]
    fn request_needs_an_execute_with_a_command() {
        let dir = repo(&[]);
        let req = |kind: &str, command: Value| json!({"toolCall": {"kind": kind, "rawInput": {"command": command}}});
        let reads = |r: &Value| request_is_read_only(r, &dir, &system_env());
        assert!(reads(&req("execute", json!("git status"))));
        assert!(reads(&req("execute", json!(["/bin/bash", "-lc", "git status"]))));
        assert!(reads(&req("execute", json!(["zsh", "-c", "pwd"]))));
        assert!(!reads(&req("execute", json!(["git", "status"]))));
        assert!(!reads(&req("execute", json!(["bash", "-lc", "git push"]))));
        assert!(!reads(&req("execute", json!(["python", "-c", "ls"]))));
        assert!(!reads(&req("edit", json!("git status"))));
        assert!(!reads(&json!({"toolCall": {"kind": "execute"}})));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Codex review of #24155: a repository's config or hooks can make `git status` or
    /// `git diff` run a program, so those asks stay with the person.
    #[test]
    fn a_repository_that_names_a_program_asks() {
        for config in [
            &[("core.fsmonitor", "/tmp/x")][..],
            &[("diff.x.textconv", "cat")],
            &[("diff.external", "cat")],
            &[("diff.x.command", "cat")],
            &[("filter.x.clean", "cat")],
            &[("filter.x.process", "cat")],
            &[("log.showsignature", "true"), ("gpg.program", "/tmp/x")],
            &[("core.pager", "/tmp/x")],
            &[("core.sshcommand", "/tmp/x")],
            &[("credential.helper", "!/tmp/x")],
            &[("include.path", "/tmp/x")],
            &[("remote.origin.uploadpack", "/tmp/x")],
            // A lazy fetch writes objects and runs the transport.
            &[("remote.origin.promisor", "true")],
            // A signature sort key verifies with gpg (`git branch`).
            &[("branch.sort", "signature:grade")],
        ] {
            let dir = repo(config);
            assert!(
                !request_is_read_only(&execute(json!("git status")), &dir, &system_env()),
                "{config:?}"
            );
            assert!(
                !request_is_read_only(&execute(json!("git diff")), &dir, &system_env()),
                "{config:?}"
            );
            assert!(
                request_is_read_only(&execute(json!("pwd")), &dir, &system_env()),
                "{config:?}"
            );
            std::fs::remove_dir_all(dir).unwrap();
        }
        let dir = repo(&[("core.fsmonitor", "true")]);
        assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::remove_dir_all(dir).unwrap();
        let dir = repo(&[
            ("core.fsmonitor", "false"),
            ("remote.origin.url", "/x"),
            ("branch.sort", "-committerdate"),
        ]);
        assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_index_hook_asks() {
        // The repository's own hooks directory, whatever the person's global core.hooksPath.
        let dir = repo(&[("core.hooksPath", ".git/hooks")]);
        let hook = dir.join(".git/hooks/post-index-change");
        std::fs::write(&hook, "#!/bin/sh\n").unwrap();
        assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::remove_file(&hook).unwrap();
        // Through core.hooksPath too, and only that hook counts.
        std::fs::create_dir(dir.join("hooks")).unwrap();
        std::fs::write(dir.join("hooks/pre-commit"), "#!/bin/sh\n").unwrap();
        git(&dir, &["config", "core.hooksPath", "hooks"]);
        assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::write(dir.join("hooks/post-index-change"), "#!/bin/sh\n").unwrap();
        assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// `git status` reads checked-out submodules with their own config.
    #[test]
    fn a_submodule_that_names_a_program_asks() {
        let dir = repo(&[]);
        let sub = dir.join("sub");
        std::fs::create_dir(&sub).unwrap();
        git(&sub, &["init", "-q"]);
        git(
            &sub,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "x",
            ],
        );
        let head =
            Command::new("git").arg("-C").arg(&sub).args(["rev-parse", "HEAD"]).output().unwrap();
        let head = String::from_utf8(head.stdout).unwrap();
        git(
            &dir,
            &["update-index", "--add", "--cacheinfo", &format!("160000,{},sub", head.trim())],
        );
        assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        git(&sub, &["config", "diff.x.textconv", "cat"]);
        assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The directory checked is the one git reads: `-C`, then the request's own cwd, then the
    /// session's.
    #[test]
    fn the_checked_repository_is_the_one_git_reads() {
        let clean = repo(&[]);
        let hostile = repo(&[("core.fsmonitor", "/tmp/x")]);
        let at = |command: &str, raw_cwd: Option<&Path>| {
            let mut r = execute(json!(command));
            if let Some(d) = raw_cwd {
                r["toolCall"]["rawInput"]["cwd"] = json!(d);
            }
            request_is_read_only(&r, &clean, &system_env())
        };
        assert!(at("git status", None));
        assert!(!at(&format!("git -C {} status", hostile.display()), None));
        assert!(!at(&format!("git status; git -C{} log", hostile.display()), None));
        assert!(!at("git status", Some(&hostile)));
        assert!(at("pwd", Some(&hostile)));
        // Outside any repository, git reads ask.
        let plain = std::env::temp_dir().join(format!("acpmux-readonly-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir(&plain).unwrap();
        assert!(!at("git status", Some(&plain)));
        for d in [clean, hostile, plain] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }

    /// The library search path cargo sets for its tests, on each OS (`LD_LIBRARY_PATH` on Linux,
    /// `DYLD_FALLBACK_LIBRARY_PATH` on macOS), only finds libraries already on disk: a git read
    /// under either still runs without asking. On macOS every git read under approve-reads asked
    /// (full-suite macOS job ac2ca38ed60bef1405523e24,
    /// `permission_groups::approve_reads_runs_read_only_shell_commands_without_asking`). Every
    /// other loader variable still asks.
    #[cfg(unix)]
    #[test]
    fn a_library_search_path_lets_a_git_read_run_on_each_os() {
        let dir = repo(&[]);
        let reads =
            |command: &str, env: &Env| request_is_read_only(&execute(json!(command)), &dir, env);
        for key in ["LD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"] {
            let mut env = system_env();
            env.insert(key.to_owned(), "/tmp/x".to_owned());
            assert!(reads("git status", &env), "{key}");
        }
        for key in ["DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH"] {
            let mut env = system_env();
            env.insert(key.to_owned(), "/tmp/x".to_owned());
            assert!(!reads("git status", &env), "{key}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Codex review of #24155 at 7e312f83: the command runs with the harness's PATH and env, so
    /// a bare `ls` found first in another directory, or an env that points git at a program,
    /// asks.
    #[cfg(unix)]
    #[test]
    fn the_harness_environment_decides() {
        let dir = repo(&[]);
        let tools = std::env::temp_dir().join(format!("acpmux-tools-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir(&tools).unwrap();
        let with_path = |first: &Path| {
            Env::from([(
                "PATH".to_owned(),
                format!("{}:{}", first.display(), TRUSTED_DIRS.join(":")),
            )])
        };
        let reads =
            |command: &str, env: &Env| request_is_read_only(&execute(json!(command)), &dir, env);
        assert!(reads("ls", &with_path(&tools)));
        assert!(reads("pwd", &Env::new()), "a builtin needs no PATH");
        assert!(!reads("ls", &Env::new()), "no PATH finds no ls");
        // A relative PATH entry is searched from the command's directory, not the daemon's.
        for path in [".:/usr/bin:/bin", ":/usr/bin:/bin", "/usr/bin:bin:/bin"] {
            let env = Env::from([("PATH".to_owned(), path.to_owned())]);
            assert!(!reads("ls", &env), "{path}");
            assert!(!reads("pwd", &env), "{path}");
        }
        // The shell itself: an agent bash found first on PATH, or a $SHELL outside the system
        // directories, asks even for a builtin.
        {
            use std::os::unix::fs::PermissionsExt;
            let fake = tools.join("bash");
            std::fs::write(&fake, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
            assert!(!reads("pwd", &with_path(&tools)));
            std::fs::remove_file(&fake).unwrap();
        }
        let mut shell = system_env();
        shell.insert("SHELL".to_owned(), tools.join("zsh").display().to_string());
        assert!(!reads("pwd", &shell));
        shell.insert("SHELL".to_owned(), "/bin/sh".to_owned());
        assert!(reads("pwd", &shell));
        {
            use std::os::unix::fs::PermissionsExt;
            let fake = tools.join("ls");
            std::fs::write(&fake, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(!reads("ls", &with_path(&tools)));
        assert!(!reads("git status; ls", &with_path(&tools)));
        assert!(reads("/bin/ls", &with_path(&tools)) || !Path::new("/bin/ls").exists());
        for key in [
            "GIT_EXTERNAL_DIFF",
            "GIT_CONFIG_COUNT",
            "GIT_DIR",
            "LD_PRELOAD",
            "BASH_ENV",
            "PAGER",
            "RIPGREP_CONFIG_PATH",
            "BASH_FUNC_pwd%%",
            "BASH_FUNC_git()",
            "ZDOTDIR",
            "LD_DEBUG_OUTPUT",
            "LD_PROFILE",
            "DYLD_PRINT_TO_FILE",
            "MALLOC_TRACE",
            "MANPAGER",
        ] {
            let mut env = system_env();
            env.insert(key.to_owned(), "/tmp/x".to_owned());
            assert!(!reads("git diff", &env), "{key}");
            assert!(!reads("pwd", &env), "{key}");
        }
        let mut env = system_env();
        env.insert("GIT_TERMINAL_PROMPT".to_owned(), "0".to_owned());
        assert!(reads("git diff", &env));
        for d in [dir, tools] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }

    /// The person's global config is read too: a key there that makes a read run a program asks.
    #[test]
    fn a_global_config_that_names_a_program_asks() {
        let dir = repo(&[]);
        let home = std::env::temp_dir().join(format!("acpmux-home-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir(&home).unwrap();
        let mut env = system_env();
        env.insert("HOME".to_owned(), home.display().to_string());
        env.insert("XDG_CONFIG_HOME".to_owned(), home.join(".config").display().to_string());
        let reads = |command: &str| request_is_read_only(&execute(json!(command)), &dir, &env);
        for config in [
            "[diff]\n\texternal = /tmp/hook\n",
            "[diff \"x\"]\n\ttextconv = /tmp/hook\n",
            "[filter \"x\"]\n\tclean = /tmp/hook\n",
            "[core]\n\tfsmonitor = /tmp/hook\n",
            "[log]\n\tshowSignature = true\n",
            "[help]\n\tformat = man\n[man]\n\tviewer = probe\n[man \"probe\"]\n\tcmd = touch /tmp/marker\n",
            "[core]\n\tpager = touch /tmp/marker\n",
            "[pager]\n\tlog = touch /tmp/marker\n",
            "[pretty]\n\tverify = format:%G?\n",
            "[pretty]\n\tverify = format:%+G?\n",
            "[format]\n\tpretty = format:%G?\n",
            "[lfs]\n\tstandalonetransferagent = probe\n",
            "[interactive]\n\tdiffFilter = /tmp/hook\n",
            "[tag]\n\tsort = signature:grade\n",
        ] {
            std::fs::write(home.join(".gitconfig"), config).unwrap();
            assert!(!reads("git diff"), "{config}");
            assert!(reads("pwd"), "{config}");
        }
        // The person's own settings that no read runs still pass: aliases, an editor, credential
        // and signing helpers (no read talks to a remote or checks a signature), includes (their
        // keys are listed and checked too).
        let identity = home.join("identity.gitconfig");
        std::fs::write(&identity, "[user]\n\tname = t\n").unwrap();
        std::fs::write(
            home.join(".gitconfig"),
            format!(
                "[alias]\n\tst = status\n[core]\n\teditor = vim\n[credential]\n\thelper = osxkeychain\n\
                 [gpg]\n\tformat = ssh\n[commit]\n\tgpgsign = true\n[safe]\n\tdirectory = *\n\
                 [include]\n\tpath = {}\n",
                identity.display()
            ),
        )
        .unwrap();
        assert!(reads("git diff"));
        // An included file is checked like the file that includes it.
        std::fs::write(&identity, "[diff]\n\texternal = /tmp/hook\n").unwrap();
        assert!(!reads("git diff"));
        // git-lfs's own filter lines pass when git-lfs is a system program; its settings ask.
        let lfs = "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n\tprocess = git-lfs filter-process\n\trequired = true\n";
        std::fs::write(home.join(".gitconfig"), lfs).unwrap();
        assert_eq!(reads("git diff"), resolve("git-lfs", &env).is_some());
        std::fs::write(
            home.join(".gitconfig"),
            format!("{lfs}[lfs]\n\tstandalonetransferagent = probe\n"),
        )
        .unwrap();
        assert!(!reads("git diff"));
        std::fs::write(home.join(".gitconfig"), "[filter \"lfs\"]\n\tclean = /tmp/hook %f\n")
            .unwrap();
        assert!(!reads("git diff"));
        for d in [dir, home] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }
}
