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
//! tokenizer cannot read plainly (a variable, a redirection, a subshell, a background job,
//! an unterminated quote) refuses, and a refusal only means the person is asked as before.
//! `permissions.rs` answers a pass with allow_once only, never a persistent grant.
//!
//! Git reads can still run a program the repository names: `core.fsmonitor`, a diff driver's
//! `textconv`, `diff.external`, a clean filter, `gpg.program` under `log.showSignature`, or a
//! `post-index-change` hook. So a script with git passes only when the repository it reads, and
//! every submodule checked out in it, names none (`repository_runs_nothing`). `cd` asks:
//! Claude Code's shell keeps the directory for its next command, whose git reads would then
//! look at a repository this never checked. A merge driver (`merge.<name>.driver`) passes: a
//! read never merges, and `--remerge-diff`, which does, asks. A partial clone's promisor remote
//! passes: a read may fetch an object the clone left out, as `git fetch` would (W5-L, review in
//! the cmux checkout).
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
//! A command substitution (`$(...)` or backticks, quoted or not) passes when its own script
//! does, judged the same way (nesting up to `SUBST_DEPTH`). Its output is text the script
//! does not show, so where it lands matters too: the argument of a `PLAIN` command takes any
//! output, and any other command takes only a `git rev-parse` or `git merge-base` with plain
//! revision arguments, which prints object names or echoes one of those arguments back
//! (`substituted`). An output that is an option (`git diff $(git log --format=--output=x)`)
//! never reaches a command that reads its options. `$((...))`, `<(...)` and `>(...)` ask.
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
    // A subagent's command carries acpmux's own mark line, which sets one variable and runs
    // nothing (`bg_hook.rs` `subagent_mark`): what it reads is the rest.
    let script = crate::bg_hook::without_subagent_mark(script);
    if !env_runs_nothing(env) || !path_is_absolute(env) || !shells_are_system(env) {
        return false;
    }
    let found = |name: &str| BUILTINS.contains(&name) || resolve(name, env).is_some();
    let Some(git_dirs) = git_dirs(script, &found, 0) else { return false };
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
    git_dirs(script, &|_| true, 0).is_some()
}

/// The `-C` directory of each git command in `script` (None: git's own directory), when every
/// command passes the allowlist and `found` passes each bare command name; None otherwise.
/// The scripts of its command substitutions count as its own commands; `depth` is how deep
/// `script` itself sits in them.
fn git_dirs(script: &str, found: &dyn Fn(&str) -> bool, depth: u8) -> Option<Vec<Option<String>>> {
    let (segments, substitutions) = segments(script, depth)?;
    if segments.iter().all(Vec::is_empty) {
        return None;
    }
    let mut git = Vec::new();
    for s in &segments {
        if let Some(first) = s.first()
            && (first.contains([SUBSTITUTED, OPAQUE]) || (!first.contains('/') && !found(first)))
        {
            return None;
        }
        // An output only a `PLAIN` command may take whole, and one that would be an option or
        // a glob's prefix nowhere.
        let plain = s.first().and_then(|f| command_name(f)).is_some_and(|n| PLAIN.contains(&n));
        if s.iter().any(|w| {
            (w.contains(OPAQUE) && !plain)
                || (w.contains([SUBSTITUTED, OPAQUE])
                    && (w.starts_with('-') || w.ends_with(GLOBBED)))
        }) {
            return None;
        }
        if let Reads::Git(dir) = segment_ok(s)? {
            git.push(dir);
        }
    }
    for inner in &substitutions {
        git.extend(git_dirs(inner, found, depth + 1)?);
    }
    Some(git)
}

/// How deep command substitutions may nest: `$(a $(b $(c)))` is 3.
const SUBST_DEPTH: u8 = 3;

/// Stands in a word for the output of a substitution `substituted` reads as object names,
/// followed by the arguments it may echo instead, so the checks that look inside a word (a
/// signature format) see them. The script refuses control characters, so none of its own
/// words holds one.
const SUBSTITUTED: char = '\u{1}';

/// Stands in a word for the output of any other substitution: text only a `PLAIN` command
/// takes as an argument.
const OPAQUE: char = '\u{2}';

/// What the output of substitution `body` (at `depth`) stands as in a word: `SUBSTITUTED` and
/// the arguments it may echo when it is a single `git rev-parse` or `git merge-base` whose
/// arguments are only revisions (no option, glob or blank), else `OPAQUE`. None when `body`
/// sits too deep or does not read plainly; whether its commands only read is `git_dirs`'s call.
fn substituted(body: &str, depth: u8) -> Option<String> {
    if depth > SUBST_DEPTH {
        return None;
    }
    let (segments, _) = segments(body, depth)?;
    let mut commands = segments.iter().filter(|s| !s.is_empty());
    let (Some(words), None) = (commands.next(), commands.next()) else {
        return Some(OPAQUE.to_string());
    };
    let names = match words.as_slice() {
        [git, sub, args @ ..] if command_name(git) == Some("git") => match sub.as_str() {
            // `git rev-parse` prints an argument it cannot resolve as it is.
            "rev-parse" => args.iter().all(|a| {
                matches!(a.as_str(), "--verify" | "-q" | "--quiet" | "--short")
                    || a.strip_prefix("--short=")
                        .is_some_and(|n| n.chars().all(|c| c.is_ascii_digit()))
                    || is_revision(a)
            }),
            "merge-base" => args.iter().all(|a| {
                matches!(a.as_str(), "--all" | "--octopus" | "--independent" | "--fork-point")
                    || is_revision(a)
            }),
            _ => false,
        },
        _ => false,
    };
    if !names {
        return Some(OPAQUE.to_string());
    }
    let echoed = words.iter().skip(2).filter(|a| is_revision(a));
    Some(std::iter::once(SUBSTITUTED.to_string()).chain(echoed.cloned()).collect())
}

/// A word `git rev-parse` may print back that is one plain word: no option, glob or blank.
/// A nested substitution in it is already one of these, or `OPAQUE`.
fn is_revision(word: &str) -> bool {
    !word.is_empty()
        && !word.starts_with('-')
        && !word.contains(OPAQUE)
        && !word.contains(|c: char| c.is_whitespace() || matches!(c, '*' | '?' | '[' | GLOBBED))
}

/// The script of a `$(...)` whose `$(` `chars` has just passed, up to its closing `)`. None
/// when it is unterminated, arithmetic (`$((`), or holds something whose end this cannot
/// find the way the shell does (a comment, a backtick).
fn substitution_body(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Option<String> {
    if chars.peek() == Some(&'(') {
        return None;
    }
    let mut body = String::new();
    let mut open = 0u32;
    loop {
        let c = chars.next()?;
        match c {
            ')' if open == 0 => return Some(body),
            '(' => open += 1,
            ')' => open -= 1,
            '#' | '`' => return None,
            '\\' => {
                body.push(c);
                body.push(chars.next()?);
                continue;
            }
            '\'' | '"' => {
                body.push(c);
                loop {
                    let q = chars.next()?;
                    body.push(q);
                    if q == c {
                        break;
                    }
                    if c == '"' && q == '\\' {
                        body.push(chars.next()?);
                    }
                }
                continue;
            }
            _ => {}
        }
        body.push(c);
    }
}

/// The script of a backtick substitution whose opening backtick `chars` has just passed, up
/// to the next one. None when it is unterminated or holds a backslash, which the shell reads
/// differently inside backticks.
fn backtick_body(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Option<String> {
    let mut body = String::new();
    loop {
        match chars.next()? {
            '`' => return Some(body),
            '\\' => return None,
            c => body.push(c),
        }
    }
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

/// The words of each command in `script`, split at `;`, `&&`, `||`, `|` and newlines, and the
/// scripts of its command substitutions (`depth` deep already), each standing in its word as
/// `substituted` says. None for anything this does not read plainly.
fn segments(script: &str, depth: u8) -> Option<(Vec<Vec<String>>, Vec<String>)> {
    let mut segs = vec![Vec::new()];
    let mut substitutions = Vec::new();
    // The body of the substitution `chars` is at (after `$` or a backtick), and what stands
    // for its output.
    let mut substitute = |chars: &mut std::iter::Peekable<std::str::Chars<'_>>, tick: bool| {
        let body = if tick {
            backtick_body(chars)?
        } else {
            chars.next_if_eq(&'(')?;
            substitution_body(chars)?
        };
        let stands = substituted(&body, depth + 1)?;
        substitutions.push(body);
        Some(stands)
    };
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
                        '$' => word.push_str(&substitute(&mut chars, false)?),
                        '`' => word.push_str(&substitute(&mut chars, true)?),
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
            '$' | '`' => {
                in_word = true;
                word.push_str(&substitute(&mut chars, c == '`')?);
            }
            '>' | '<' | '(' | ')' | '{' | '}' => return None,
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
    Some((segs, substitutions))
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
        "sed" => sed_prints_only(args),
        _ => false,
    };
    ok.then_some(Reads::Plain)
}

/// `sed -n` that only prints lines by number (`sed -n '1,40p' f`, `-e '$p'`): a reviewer's way
/// to read part of a file. Any other sed command can write (`w`, `s///w`) or run one (`e`), and
/// `-i` edits in place, so anything else asks; GNU sed reads an option after the files too.
pub(crate) fn sed_prints_only(args: &[String]) -> bool {
    let mut quiet = false;
    let mut scripts: Vec<&str> = Vec::new();
    let mut i = 0;
    while let Some(a) = args.get(i) {
        match a.as_str() {
            "-n" | "--quiet" | "--silent" => quiet = true,
            "-E" | "-r" | "--regexp-extended" => {}
            // A cluster of those (`-En`).
            a if a.len() > 2
                && !a.starts_with("--")
                && a.strip_prefix('-').is_some_and(|f| f.chars().all(|c| "nEr".contains(c))) =>
            {
                quiet |= a.contains('n');
            }
            "-e" => {
                i += 1;
                let Some(script) = args.get(i) else { return false };
                scripts.push(script);
            }
            a if a.starts_with('-') => return false,
            _ => break,
        }
        i += 1;
    }
    let mut rest = args.get(i..).unwrap_or_default().iter();
    if scripts.is_empty() {
        let Some(script) = rest.next() else { return false };
        scripts.push(script);
    }
    if rest.any(|a| a.starts_with('-')) {
        return false;
    }
    let address = |a: &str| a == "$" || (!a.is_empty() && a.bytes().all(|b| b.is_ascii_digit()));
    let prints = |command: &str| {
        let Some(range) = command.trim().strip_suffix('p') else { return false };
        let range = range.trim();
        range.is_empty()
            || match range.split_once(',') {
                Some((from, to)) => address(from.trim()) && address(to.trim()),
                None => address(range),
            }
    };
    quiet
        && scripts.iter().all(|s| s.split([';', '\n']).filter(|c| !c.trim().is_empty()).all(prints))
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
        // So would a substitution's output.
        if named.contains(['*', '?', '[', SUBSTITUTED, OPAQUE])
            || named.starts_with('~')
            || dir.replace(named).is_some()
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
            // Merges again to show a merge commit, which runs the repository's merge drivers.
            || long_is(a, "--remerge-diff")
            // `--diff-merges=remerge` (or `r`); any other value shows no remerge, but asks too.
            || a.starts_with("--diff-merges")
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
        // A partial clone's promisor (`promisor`, `partialclonefilter`): a read that needs an
        // object the clone left out fetches it from that remote's `url`, as `git fetch` does with
        // the person's credentials, and stores it with git's own objects. The transport runs no
        // program the repository names: `uploadpack`, `core.sshCommand`, `credential.helper` and
        // `protocol.*` here still ask. W5-L: the cmux checkout is a partial clone, and a review
        // chat could not run `git diff` in it.
        ("remote", Some(_)) => matches!(
            name,
            "url"
                | "promisor"
                | "partialclonefilter"
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
        // A merge driver runs only when git merges file contents (merge, rebase, cherry-pick, a
        // stash apply, a remerge diff, which asks: `git_read_ok`), never in an allowed read.
        ("merge", Some(_)) => matches!(name, "name" | "driver" | "recursive"),
        ("rebase", None) => matches!(name, "autosquash" | "autostash" | "updaterefs"),
        ("rerere", None) => matches!(name, "enabled" | "autoupdate"),
        _ => false,
    }
}

#[cfg(test)]
#[path = "shell_readonly_tests.rs"]
mod tests;
