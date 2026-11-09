//! The rules: which words, subcommands and flags put a command in which class.

use crate::lex::{self, RedirectKind, Token, Word};
use crate::{Classification, Classifier, CommandClass, Verdict};

use CommandClass::{FileRead, FileWrite, GitHooks, GitLocal, Machine, Network};

/// How deep `bash -c`, `eval` and substitutions may nest before the
/// classifier gives up and says [`Machine`].
const MAX_DEPTH: usize = 16;

/// Commands that only read files or print.
const FILE_READ: &[&str] = &[
    "cat",
    "grep",
    "egrep",
    "fgrep",
    "rg",
    "ag",
    "ack",
    "head",
    "tail",
    "ls",
    "wc",
    "jq",
    "yq",
    "diff",
    "stat",
    "tree",
    "echo",
    "printf",
    "pwd",
    "cd",
    "pushd",
    "popd",
    "true",
    "false",
    "test",
    "[",
    "[[",
    ":",
    "which",
    "type",
    "whereis",
    "basename",
    "dirname",
    "realpath",
    "readlink",
    "file",
    "du",
    "sort",
    "uniq",
    "cut",
    "tr",
    "nl",
    "column",
    "comm",
    "cmp",
    "md5sum",
    "md5",
    "sha1sum",
    "sha256sum",
    "shasum",
    "cksum",
    "xxd",
    "od",
    "hexdump",
    "strings",
    "base64",
    "fold",
    "paste",
    "join",
    "rev",
    "tac",
    "fmt",
    "expand",
    "unexpand",
    "fd",
    "bat",
    "eza",
    "exa",
    "date",
    "seq",
    "zcat",
    "read",
    "export",
    "unset",
    "set",
    "shopt",
    "local",
    "declare",
    "typeset",
    "readonly",
    "shift",
    "exit",
    "return",
    "hash",
];

/// Commands that write files.
const FILE_WRITE: &[&str] = &[
    "mkdir", "rmdir", "cp", "mv", "rm", "touch", "chmod", "chown", "chgrp", "ln", "install",
    "truncate", "patch", "tar", "unzip", "zip", "gzip", "gunzip", "bzip2", "xz", "rsync", "mktemp",
    "split", "csplit",
];

/// Commands that only talk to remote services.
const NETWORK: &[&str] = &["ssh", "sftp"];

/// Git subcommands that only read the repository.
const GIT_LOCAL: &[&str] = &[
    "status",
    "diff",
    "log",
    "show",
    "branch",
    "rev-parse",
    "grep",
    "blame",
    "ls-files",
    "cat-file",
    "describe",
    "shortlog",
    "rev-list",
    "ls-tree",
    "merge-base",
    "reflog",
    "show-ref",
    "for-each-ref",
    "name-rev",
    "whatchanged",
    "cherry",
    "range-diff",
    "count-objects",
    "check-ignore",
    "check-attr",
    "config",
    "tag",
    "var",
    "help",
    "version",
    "diff-tree",
    "diff-files",
    "diff-index",
];

/// Git subcommands that rewrite the index or the tree, or run hooks.
const GIT_HOOKS: &[&str] = &[
    "commit",
    "checkout",
    "switch",
    "merge",
    "rebase",
    "am",
    "cherry-pick",
    "revert",
    "reset",
    "restore",
    "add",
    "rm",
    "mv",
    "clean",
    "apply",
    "init",
    "gc",
    "notes",
];

/// gh's own top-level commands. Any other first word is an extension or an
/// alias, which runs local code.
const GH_COMMANDS: &[&str] = &[
    "api",
    "auth",
    "browse",
    "cache",
    "codespace",
    "cs",
    "gist",
    "issue",
    "label",
    "org",
    "pr",
    "project",
    "release",
    "repo",
    "ruleset",
    "run",
    "search",
    "secret",
    "variable",
    "ssh-key",
    "gpg-key",
    "status",
    "workflow",
    "attestation",
    "completion",
    "config",
    "help",
    "copilot",
];

/// Where writes go nowhere.
fn is_sink(path: &str) -> bool {
    matches!(path, "/dev/null" | "/dev/stdout" | "/dev/stderr" | "/dev/tty" | "-")
        || path.starts_with("/dev/fd/")
}

/// `NAME=value`, `NAME+=value` or `NAME[i]=value`.
fn is_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let name = name.trim_end_matches('+');
    let name = match name.split_once('[') {
        Some((base, _)) if name.ends_with(']') => base,
        _ => name,
    };
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A command named by path is the system's own only from a system directory;
/// `./ls` or `node_modules/.bin/tsc` is a project file.
fn command_name(word: &str) -> Option<&str> {
    match word.rsplit_once('/') {
        None => Some(word),
        Some((dir, name)) => {
            let system = matches!(
                dir,
                "/bin"
                    | "/usr/bin"
                    | "/usr/local/bin"
                    | "/opt/homebrew/bin"
                    | "/usr/sbin"
                    | "/sbin"
            );
            system.then_some(name)
        }
    }
}

fn is_flag(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-')
}

impl Classifier {
    pub(crate) fn classify_script(&self, script: &str, depth: usize) -> Classification {
        if depth > MAX_DEPTH {
            return Classification::new(Machine, "nesting");
        }
        let Ok(tokens) = lex::lex(script) else {
            return Classification::new(Machine, "unparsed");
        };
        let mut verdict = Verdict::default();
        let mut words: Vec<Word> = Vec::new();
        let mut redirects = Vec::new();
        for token in tokens {
            match token {
                Token::Word(word) => words.push(word),
                Token::Redirect { kind, op, target } => redirects.push((kind, op, target)),
                Token::Separator => {
                    self.simple(&words, &redirects, depth, &mut verdict);
                    words.clear();
                    redirects.clear();
                }
                Token::Background => {
                    self.simple(&words, &redirects, depth, &mut verdict);
                    words.clear();
                    redirects.clear();
                    verdict.add(Machine, "&");
                }
            }
        }
        self.simple(&words, &redirects, depth, &mut verdict);
        verdict.finish()
    }

    /// One simple command: its words, its substitutions and its redirections.
    fn simple(
        &self,
        words: &[Word],
        redirects: &[(RedirectKind, &'static str, Word)],
        depth: usize,
        verdict: &mut Verdict,
    ) {
        if !words.is_empty() {
            let argv: Vec<&str> = words.iter().map(|word| word.text.as_str()).collect();
            verdict.merge(self.argv(&argv, depth));
        }
        let targets = redirects.iter().map(|(_, _, target)| target);
        for word in words.iter().chain(targets) {
            for sub in &word.subs {
                verdict.merge(self.classify_script(sub, depth + 1));
            }
        }
        for (kind, op, target) in redirects {
            let writes = match kind {
                RedirectKind::Write => true,
                RedirectKind::DupOrWrite => !target.text.bytes().all(|b| b.is_ascii_digit()),
                RedirectKind::Read => false,
            };
            if writes && !is_sink(&target.text) {
                verdict.add(FileWrite, *op);
            }
        }
    }

    /// A command's words: assignments and reserved words first, then the
    /// command itself.
    fn argv(&self, argv: &[&str], depth: usize) -> Classification {
        let mut i = 0;
        while let Some(&word) = argv.get(i) {
            match word {
                _ if is_assignment(word) => i += 1,
                "if" | "then" | "else" | "elif" | "do" | "while" | "until" | "!" | "{" => i += 1,
                // The loop header runs nothing; its substitutions are classified
                // with the words.
                "for" | "select" | "fi" | "done" | "esac" | "}" => {
                    return Classification::new(FileRead, word);
                }
                // Case patterns don't fit this lexer; fail closed.
                "case" => return Classification::new(Machine, word),
                _ => return self.command(argv.get(i..).unwrap_or_default(), depth),
            }
        }
        Classification::new(FileRead, "")
    }

    /// A command with its arguments; `args` is not empty.
    fn command(&self, args: &[&str], depth: usize) -> Classification {
        let Some((&first, tail)) = args.split_first() else {
            return Classification::new(Machine, "");
        };
        let Some(name) = command_name(first) else {
            return Classification::new(Machine, first);
        };
        match name {
            "timeout" => {
                self.wrapped(name, tail, &["-s", "-k", "--signal", "--kill-after"], 1, depth)
            }
            "nice" => self.wrapped(name, tail, &["-n"], 0, depth),
            "stdbuf" => self.wrapped(name, tail, &["-i", "-o", "-e"], 0, depth),
            "exec" => self.wrapped(name, tail, &["-a"], 0, depth),
            "nohup" | "time" | "builtin" => self.wrapped(name, tail, &[], 0, depth),
            "command" if tail.iter().take_while(|w| is_flag(w)).any(|w| w.contains(['v', 'V'])) => {
                Classification::new(FileRead, name)
            }
            "command" => self.wrapped(name, tail, &[], 0, depth),
            "xargs" => self.wrapped(
                name,
                tail,
                &["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"],
                0,
                depth,
            ),
            "env" => self.env(tail, depth),
            "eval" => self.classify_script(&tail.join(" "), depth + 1),
            "bash" | "sh" | "zsh" | "dash" | "ksh" => self.shell(name, tail, depth),
            "git" => git(tail),
            "gh" => gh(tail),
            "sed" => sed(tail),
            "find" => self.find(tail, depth),
            "awk" | "gawk" | "mawk" | "nawk" => awk(name, tail),
            "tee" => tee(tail),
            "sort" if tail.iter().any(|w| *w == "-o" || w.starts_with("--output")) => {
                Classification::new(FileWrite, "sort -o")
            }
            "curl" => curl(tail),
            "wget" => wget(tail),
            "scp" => scp(tail),
            _ if FILE_READ.contains(&name) => Classification::new(FileRead, name),
            _ if FILE_WRITE.contains(&name) => Classification::new(FileWrite, name),
            _ if NETWORK.contains(&name) => Classification::new(Network, name),
            _ if self.is_home_tool(name) => Classification::new(Network, name),
            _ => Classification::new(Machine, name),
        }
    }

    /// A wrapper that runs the rest of its words as a command: skips its
    /// flags (and the values of `valued` ones), then `positional` more words.
    fn wrapped(
        &self,
        name: &str,
        tail: &[&str],
        valued: &[&str],
        positional: usize,
        depth: usize,
    ) -> Classification {
        let mut j = 0;
        while let Some(&word) = tail.get(j) {
            if word == "--" {
                j += 1;
                break;
            }
            if !is_flag(word) {
                break;
            }
            j += if valued.contains(&word) { 2 } else { 1 };
        }
        j += positional;
        match tail.get(j..) {
            Some(rest) if !rest.is_empty() => self.argv(rest, depth),
            // `xargs` with no command runs `echo`; the rest run nothing.
            _ => Classification::new(FileRead, name),
        }
    }

    fn env(&self, tail: &[&str], depth: usize) -> Classification {
        let mut j = 0;
        while let Some(&word) = tail.get(j) {
            match word {
                "-u" | "-C" | "--unset" | "--chdir" => j += 2,
                "-S" | "--split-string" => {
                    let script = tail.get(j + 1..).unwrap_or_default().join(" ");
                    return self.classify_script(&script, depth + 1);
                }
                _ if word.starts_with("--split-string=") || word.starts_with("-S") => {
                    let first = word
                        .strip_prefix("--split-string=")
                        .or_else(|| word.strip_prefix("-S"))
                        .unwrap_or_default();
                    let mut script = first.to_owned();
                    for rest in tail.get(j + 1..).unwrap_or_default() {
                        script.push(' ');
                        script.push_str(rest);
                    }
                    return self.classify_script(&script, depth + 1);
                }
                "-" => j += 1,
                _ if is_flag(word) || is_assignment(word) => j += 1,
                _ => return self.argv(tail.get(j..).unwrap_or_default(), depth),
            }
        }
        Classification::new(FileRead, "env")
    }

    /// `bash -c 'script'` classifies the script; any other shell run reads a
    /// script file or stdin, which the classifier can't see.
    fn shell(&self, name: &str, tail: &[&str], depth: usize) -> Classification {
        let mut j = 0;
        let mut has_c = false;
        while let Some(&word) = tail.get(j) {
            match word {
                "--" => {
                    j += 1;
                    break;
                }
                "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file" => j += 2,
                _ if word.starts_with("--") => j += 1,
                _ if word.len() > 1 && (word.starts_with('-') || word.starts_with('+')) => {
                    let flags = word.get(1..).unwrap_or_default();
                    has_c |= word.starts_with('-') && flags.contains('c');
                    // `-euo pipefail`: a cluster with `o` takes the next word.
                    j += if flags.contains(['o', 'O']) { 2 } else { 1 };
                }
                _ => break,
            }
        }
        match (has_c, tail.get(j)) {
            (true, Some(script)) => self.classify_script(script, depth + 1),
            _ => Classification::new(Machine, name),
        }
    }

    /// `find` reads, unless it deletes, writes a list file, or runs a command
    /// per match (classified like any other command).
    fn find(&self, tail: &[&str], depth: usize) -> Classification {
        let mut verdict = Verdict::default();
        verdict.add(FileRead, "find");
        let mut j = 0;
        while let Some(&word) = tail.get(j) {
            j += 1;
            match word {
                "-delete" => verdict.add(FileWrite, "find -delete"),
                "-fprint" | "-fprint0" | "-fprintf" | "-fls" => {
                    verdict.add(FileWrite, "find -fprint");
                }
                "-exec" | "-execdir" | "-ok" | "-okdir" => {
                    let start = j;
                    while tail.get(j).is_some_and(|w| *w != ";" && *w != "+") {
                        j += 1;
                    }
                    match tail.get(start..j) {
                        Some(sub) if !sub.is_empty() => verdict.merge(self.argv(sub, depth)),
                        _ => verdict.add(Machine, "find -exec"),
                    }
                    j += 1;
                }
                _ => {}
            }
        }
        verdict.finish()
    }
}

fn git(tail: &[&str]) -> Classification {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        match word {
            "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" => j += 2,
            _ if word.starts_with('-') => j += 1,
            _ => break,
        }
    }
    let Some(&sub) = tail.get(j) else {
        return Classification::new(GitLocal, "git");
    };
    let rest = tail.get(j + 1..).unwrap_or_default();
    let first = rest.iter().copied().find(|w| !w.starts_with('-'));
    let class = match sub {
        "push" | "fetch" | "ls-remote" => Network,
        // A clone saves a new checkout into the workspace.
        "clone" => FileWrite,
        // A pull is a fetch and then a merge or rebase into the tree.
        "pull" => GitHooks,
        "remote" => match first {
            Some("update" | "prune" | "show") => Network,
            _ => GitLocal,
        },
        "stash" => match first {
            Some("list" | "show") => GitLocal,
            _ => GitHooks,
        },
        "worktree" => match first {
            Some("list") => GitLocal,
            _ => GitHooks,
        },
        "submodule" => match first {
            None | Some("status" | "summary") => GitLocal,
            Some("foreach") => Machine,
            _ => GitHooks,
        },
        "bisect" => match first {
            Some("run") => Machine,
            _ => GitHooks,
        },
        // `rebase --exec` runs a command after each commit.
        "rebase" if rest.iter().any(|w| *w == "-x" || w.starts_with("--exec")) => Machine,
        _ if GIT_LOCAL.contains(&sub) => GitLocal,
        _ if GIT_HOOKS.contains(&sub) => GitHooks,
        // Aliases, `git lfs` and other extensions run local programs.
        _ => Machine,
    };
    Classification::new(class, format!("git {sub}"))
}

fn gh(tail: &[&str]) -> Classification {
    let mut positional = tail.iter().copied().filter(|w| !w.starts_with('-'));
    let Some(group) = positional.next() else {
        return Classification::new(Network, "gh");
    };
    let action = positional.next();
    match (group, action) {
        ("pr", Some("checkout")) | ("co", _) => Classification::new(GitHooks, "gh pr checkout"),
        ("run" | "release", Some("download")) => {
            Classification::new(FileWrite, format!("gh {group} download"))
        }
        ("repo", Some("clone")) => Classification::new(FileWrite, "gh repo clone"),
        _ if GH_COMMANDS.contains(&group) => Classification::new(Network, "gh"),
        _ => Classification::new(Machine, format!("gh {group}")),
    }
}

/// `sed` prints unless it edits in place.
fn sed(tail: &[&str]) -> Classification {
    let in_place = tail.iter().any(|w| {
        w.starts_with("--in-place")
            || (is_flag(w)
                && !w.starts_with("--")
                && w.get(1..).is_some_and(|flags| flags.contains('i')))
    });
    if in_place {
        Classification::new(FileWrite, "sed -i")
    } else {
        Classification::new(FileRead, "sed")
    }
}

/// `awk` reads, unless its program runs commands or prints into a file. A
/// program file (`-f`) can't be seen, so it fails closed.
fn awk(name: &str, tail: &[&str]) -> Classification {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        match word {
            "-f" | "--file" => return Classification::new(Machine, format!("{name} -f")),
            "-F" | "-v" => j += 2,
            "--" => {
                j += 1;
                break;
            }
            _ if is_flag(word) => j += 1,
            _ => break,
        }
    }
    let program = tail.get(j).copied().unwrap_or_default();
    let compact: String = program.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.contains("system(") || compact.contains("|getline") || awk_redirect(&compact, "|\"")
    {
        Classification::new(Machine, format!("{name} system"))
    } else if awk_redirect(&compact, ">\"") {
        Classification::new(FileWrite, format!("{name} >"))
    } else {
        Classification::new(FileRead, name)
    }
}

/// Whether an awk program (blanks removed) redirects with `op` into a quoted
/// command or file. `"|"` or `">"`, a string holding the operator, doesn't count.
fn awk_redirect(program: &str, op: &str) -> bool {
    program
        .match_indices(op)
        .any(|(at, _)| program.get(..at).is_some_and(|before| !before.ends_with('"')))
}

fn tee(tail: &[&str]) -> Classification {
    if tail.iter().any(|w| !w.starts_with('-') && !is_sink(w)) {
        Classification::new(FileWrite, "tee")
    } else {
        Classification::new(FileRead, "tee")
    }
}

/// `curl` is network, unless it saves its download into the workspace.
fn curl(tail: &[&str]) -> Classification {
    let mut saves = false;
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        j += 1;
        if let Some(path) = word.strip_prefix("--output=") {
            saves |= !is_sink(path);
        } else if word == "--output" {
            saves |= tail.get(j).is_some_and(|path| !is_sink(path));
            j += 1;
        } else if matches!(word, "--remote-name" | "--remote-name-all" | "--output-dir") {
            saves = true;
        } else if is_flag(word) && !word.starts_with("--") {
            let flags = word.get(1..).unwrap_or_default();
            saves |= flags.contains('O');
            if let Some(at) = flags.find('o') {
                let attached = flags.get(at + 1..).unwrap_or_default();
                if attached.is_empty() {
                    saves |= tail.get(j).is_some_and(|path| !is_sink(path));
                    j += 1;
                } else {
                    saves |= !is_sink(attached);
                }
            }
        }
    }
    if saves {
        Classification::new(FileWrite, "curl -o")
    } else {
        Classification::new(Network, "curl")
    }
}

/// `wget` saves into the workspace unless it writes to stdout or only checks.
fn wget(tail: &[&str]) -> Classification {
    let mut output: Option<&str> = None;
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        j += 1;
        if word == "--spider" {
            return Classification::new(Network, "wget");
        } else if let Some(path) = word.strip_prefix("--output-document=") {
            output = Some(path);
        } else if word == "--output-document" {
            output = tail.get(j).copied();
            j += 1;
        } else if is_flag(word)
            && !word.starts_with("--")
            && let Some(at) = word.find('O')
        {
            let attached = word.get(at + 1..).unwrap_or_default();
            if attached.is_empty() {
                output = tail.get(j).copied();
                j += 1;
            } else {
                output = Some(attached);
            }
        }
    }
    if output.is_some_and(is_sink) {
        Classification::new(Network, "wget")
    } else {
        Classification::new(FileWrite, "wget")
    }
}

/// `scp` to a remote host is network; `scp` to a local path writes it.
fn scp(tail: &[&str]) -> Classification {
    let mut last = None;
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        j += 1;
        if matches!(word, "-P" | "-i" | "-o" | "-F" | "-l" | "-c" | "-J" | "-S") {
            j += 1;
        } else if !is_flag(word) {
            last = Some(word);
        }
    }
    match last {
        Some(dest) if !dest.contains(':') => Classification::new(FileWrite, "scp"),
        _ => Classification::new(Network, "scp"),
    }
}
