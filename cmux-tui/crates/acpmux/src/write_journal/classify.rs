//! Which shell commands only read files, so a replica may answer them while the machine sleeps.
//!
//! Conservative by construction: a command is a read only when every word is understood. Anything
//! else is an exec, which wakes the machine and flushes the journal first. Calling a read an exec
//! costs one wake; calling an exec a read would skip its effects, so every doubt goes to exec.

/// Unquoted characters that make a command anything but a plain pipeline of plain words:
/// redirects, substitutions, expansions, separators, globs we would have to expand, escapes.
const SHELL_META: &[char] =
    &['>', '<', '$', '`', ';', '\n', '\r', '(', ')', '{', '}', '\\', '*', '?', '[', ']', '!', '#'];

/// Characters that still expand inside double quotes.
const DOUBLE_QUOTED_META: &[char] = &['$', '`', '\\', '!'];

/// The kind of a tool call for the journal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallClass {
    /// Served from the replica plus the journal.
    Read,
    /// Runs on the machine: a barrier that flushes the journal first.
    Exec,
}

/// `command` (one shell command line) as a [`CallClass`].
pub fn classify_command(command: &str) -> CallClass {
    if is_pure_read(command) { CallClass::Read } else { CallClass::Exec }
}

/// True when `command` only reads files (module docs).
pub fn is_pure_read(command: &str) -> bool {
    if command.trim().is_empty() || command.contains(['\n', '\r']) {
        return false;
    }
    let mut any = false;
    for and_part in command.split("&&") {
        // A single `&` (background) or `||` left after splitting on `&&` is an exec.
        if and_part.contains('&') {
            return false;
        }
        for stage in and_part.split('|') {
            let Some(words) = split_words(stage) else { return false };
            if words.is_empty() || !stage_reads(&words) {
                return false;
            }
            any = true;
        }
    }
    any
}

/// Shell words with plain single and double quotes; `None` for anything else: an unclosed quote,
/// an unquoted [`SHELL_META`], an expansion inside double quotes, or a word starting with `~`.
fn split_words(stage: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    for c in stage.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), c) if DOUBLE_QUOTED_META.contains(&c) => return None,
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            (None, c) if SHELL_META.contains(&c) || (c == '~' && !in_word) => return None,
            (None, c) => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if quote.is_some() {
        return None;
    }
    if in_word {
        words.push(cur);
    }
    Some(words)
}

/// Commands that only read their arguments and write only to stdout.
const READERS: &[&str] = &[
    "ls", "cat", "head", "wc", "grep", "egrep", "fgrep", "rg", "stat", "pwd", "basename",
    "dirname", "realpath", "sort", "cut", "tr", "nl", "du", "diff", "cmp",
];

/// Git subcommands that only read the repository.
const GIT_READERS: &[&str] = &[
    "log",
    "show",
    "diff",
    "status",
    "blame",
    "ls-files",
    "ls-tree",
    "rev-parse",
    "cat-file",
    "grep",
    "branch",
];

/// Whether `arg` is the option `bad` in any spelling: exact, `--opt=value`, an abbreviated long
/// option (GNU tools and git take any unique prefix: `--outp=x` is `--output=x`), or a short
/// option inside a cluster or with its value attached (`-nf`, `-ofile`).
fn is_option(arg: &str, bad: &str) -> bool {
    if arg == bad || arg.starts_with(&format!("{bad}=")) {
        return true;
    }
    if let (Some(name), true) = (arg.strip_prefix("--"), bad.starts_with("--")) {
        let name = name.split('=').next().unwrap_or(name);
        return !name.is_empty() && bad.get(2..).is_some_and(|b| b.starts_with(name));
    }
    match (arg.strip_prefix('-'), bad.strip_prefix('-')) {
        (Some(cluster), Some(letter)) if !arg.starts_with("--") && letter.chars().count() == 1 => {
            cluster.contains(letter)
        }
        _ => false,
    }
}

fn any_option(args: &[String], bad: &[&str]) -> bool {
    args.iter().any(|a| bad.iter().any(|b| is_option(a, b)))
}

fn stage_reads(words: &[String]) -> bool {
    let Some((cmd, args)) = words.split_first() else { return false };
    // `VAR=x cmd` changes what runs.
    if cmd.contains('=') {
        return false;
    }
    match cmd.as_str() {
        // `-f`/`-F` never end; `sort -o` writes a file; `rg --pre` runs a program per file.
        "tail" => !any_option(args, &["-f", "-F", "--follow", "--retry"]),
        // `-T` spills temporary files into a folder it names.
        "sort" => !any_option(
            args,
            &["-o", "--output", "--compress-program", "-T", "--temporary-directory"],
        ),
        "rg" => !any_option(
            args,
            &["--pre", "--pre-glob", "--search-zip", "-z", "--hostname-bin", "--hyperlink-format"],
        ),
        // find takes no abbreviations and no clusters: its actions are whole words.
        "find" => !args.iter().any(|a| {
            [
                "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf",
                "-fls",
            ]
            .contains(&a.as_str())
        }),
        "git" => git_reads(args),
        c => READERS.contains(&c),
    }
}

fn git_reads(args: &[String]) -> bool {
    // A global option (`-c`, `-C`, `--exec-path`, `-p`) before the subcommand is an exec.
    let Some((sub, rest)) = args.split_first() else { return false };
    if !GIT_READERS.contains(&sub.as_str()) {
        return false;
    }
    const BAD: &[&str] = &[
        "--output",
        "--ext-diff",
        "--textconv",
        "--filters",
        "-O",
        "--open-files-in-pager",
        "--paginate",
        "-p",
    ];
    // `-p` is a patch flag for log/show/diff, a pager flag only before the subcommand.
    let patch = matches!(sub.as_str(), "log" | "show" | "diff");
    let bad: Vec<&str> = BAD.iter().copied().filter(|b| !(patch && *b == "-p")).collect();
    if any_option(rest, &bad) {
        return false;
    }
    // `git branch NAME` creates, `-d` deletes, `-m` moves: only the listing forms read.
    if sub == "branch" {
        const LIST: &[&str] = &[
            "-a",
            "-r",
            "-v",
            "-vv",
            "--all",
            "--remotes",
            "--list",
            "--show-current",
            "--verbose",
        ];
        return rest.iter().all(|a| LIST.contains(&a.as_str()));
    }
    true
}
