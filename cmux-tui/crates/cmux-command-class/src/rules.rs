//! The core rules: how a script splits into simple commands, how wrappers
//! hand their words on, and which plain command names fall in which class.
//! Commands whose flags or programs can change their class live in
//! [`crate::tools`], [`crate::net`] and [`crate::programs`].

use crate::lex::{self, RedirectKind, Token, Word};
use crate::{Classification, Classifier, CommandClass, Verdict, tools};

use CommandClass::{FileRead, FileWrite, Machine, Network};

/// How deep `bash -c`, `eval`, substitutions and wrappers (`nice nice ...`)
/// may nest before the classifier gives up and says [`Machine`].
const MAX_DEPTH: usize = 16;

/// Commands that only read files or print, with no flag that runs a program
/// or writes a file. A command with such a flag is in [`tools::tool`] first.
#[rustfmt::skip]
const FILE_READ: &[&str] = &[
    "cat", "grep", "egrep", "fgrep", "head", "tail", "ls", "wc", "jq", "diff", "stat", "echo",
    "printf", "pwd", "cd", "pushd", "popd", "true", "false", "test", "[", "[[", ":", "which",
    "type", "whereis", "basename", "dirname", "realpath", "readlink", "du", "cut", "tr", "nl",
    "column", "comm", "cmp", "md5sum", "md5", "sha1sum", "sha256sum", "shasum", "cksum", "od",
    "hexdump", "strings", "fold", "paste", "join", "rev", "tac", "fmt", "expand", "unexpand",
    "eza", "exa", "seq", "zcat", "read", "export", "unset", "set", "shopt", "local", "declare",
    "typeset", "readonly", "shift", "exit", "return", "hash",
];

/// Commands that write files.
#[rustfmt::skip]
const FILE_WRITE: &[&str] = &[
    "mkdir", "rmdir", "cp", "mv", "rm", "touch", "chmod", "chown", "chgrp", "ln", "truncate",
    "patch", "unzip", "gzip", "gunzip", "bzip2", "xz", "mktemp", "split", "csplit",
];

/// Where a redirect or a file argument writes nothing. `-` is not here: it
/// is stdout only to the commands that say so, and a file named `-` to the
/// rest (`> -`, `tee -`).
pub(crate) fn is_sink(path: &str) -> bool {
    matches!(path, "/dev/null" | "/dev/stdout" | "/dev/stderr" | "/dev/tty")
        || path.starts_with("/dev/fd/")
}

/// `NAME=value`, `NAME+=value` or `NAME[i]=value`.
pub(crate) fn is_assignment(word: &str) -> bool {
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

pub(crate) fn is_flag(word: &str) -> bool {
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
                Token::Separator | Token::Background => {
                    self.simple(&words, &redirects, depth, &mut verdict);
                    words.clear();
                    redirects.clear();
                    if matches!(token, Token::Background) {
                        verdict.add(Machine, "&");
                    }
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
                verdict.merge(self.classify_script(sub, depth.saturating_add(1)));
            }
        }
        for (kind, op, target) in redirects {
            let writes = match kind {
                RedirectKind::Write => true,
                // `2>&1` copies a descriptor and `>&-` closes one.
                RedirectKind::DupOrWrite => {
                    target.text != "-" && !target.text.bytes().all(|b| b.is_ascii_digit())
                }
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
                _ if is_assignment(word) => i = i.saturating_add(1),
                "if" | "then" | "else" | "elif" | "do" | "while" | "until" | "!" | "{" => {
                    i = i.saturating_add(1);
                }
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
        if depth > MAX_DEPTH {
            return Classification::new(Machine, "nesting");
        }
        let Some((&first, tail)) = args.split_first() else {
            return Classification::new(Machine, "");
        };
        let Some(name) = command_name(first) else {
            return Classification::new(Machine, first);
        };
        let next = depth.saturating_add(1);
        match name {
            "timeout" => {
                self.wrapped(name, tail, &["-s", "-k", "--signal", "--kill-after"], 1, next)
            }
            "nice" => self.wrapped(name, tail, &["-n"], 0, next),
            "stdbuf" => self.wrapped(name, tail, &["-i", "-o", "-e"], 0, next),
            "exec" => self.wrapped(name, tail, &["-a"], 0, next),
            "nohup" | "time" | "builtin" => self.wrapped(name, tail, &[], 0, next),
            "command" if tail.iter().take_while(|w| is_flag(w)).any(|w| w.contains(['v', 'V'])) => {
                Classification::new(FileRead, name)
            }
            "command" => self.wrapped(name, tail, &[], 0, next),
            "xargs" => {
                let valued = ["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"];
                self.wrapped(name, tail, &valued, 0, next)
            }
            "env" => self.env(tail, next),
            "eval" => self.classify_script(&tail.join(" "), next),
            "bash" | "sh" | "zsh" | "dash" | "ksh" => self.shell(name, tail, next),
            "find" => self.find(tail, next),
            "fd" | "fdfind" => self.fd(name, tail, next),
            _ => tools::tool(name, tail).unwrap_or_else(|| self.plain(name)),
        }
    }

    /// A command with no flag that changes its class.
    fn plain(&self, name: &str) -> Classification {
        let class = if FILE_READ.contains(&name) {
            FileRead
        } else if FILE_WRITE.contains(&name) {
            FileWrite
        } else if self.is_home_tool(name) {
            Network
        } else {
            Machine
        };
        Classification::new(class, name)
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
                j = j.saturating_add(1);
                break;
            }
            if !is_flag(word) {
                break;
            }
            j = j.saturating_add(if valued.contains(&word) { 2 } else { 1 });
        }
        j = j.saturating_add(positional);
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
                "-u" | "-C" | "--unset" | "--chdir" => j = j.saturating_add(2),
                "-S" | "--split-string" => {
                    let script = tail.get(j.saturating_add(1)..).unwrap_or_default().join(" ");
                    return self.classify_script(&script, depth);
                }
                _ if word.starts_with("--split-string=") || word.starts_with("-S") => {
                    let first = word
                        .strip_prefix("--split-string=")
                        .or_else(|| word.strip_prefix("-S"))
                        .unwrap_or_default();
                    let mut script = first.to_owned();
                    for rest in tail.get(j.saturating_add(1)..).unwrap_or_default() {
                        script.push(' ');
                        script.push_str(rest);
                    }
                    return self.classify_script(&script, depth);
                }
                "-" => j = j.saturating_add(1),
                _ if is_flag(word) || is_assignment(word) => j = j.saturating_add(1),
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
                    j = j.saturating_add(1);
                    break;
                }
                "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file" => j = j.saturating_add(2),
                _ if word.starts_with("--") => j = j.saturating_add(1),
                _ if word.len() > 1 && (word.starts_with('-') || word.starts_with('+')) => {
                    let flags = word.get(1..).unwrap_or_default();
                    has_c |= word.starts_with('-') && flags.contains('c');
                    // `-euo pipefail`: a cluster with `o` takes the next word.
                    j = j.saturating_add(if flags.contains(['o', 'O']) { 2 } else { 1 });
                }
                _ => break,
            }
        }
        match (has_c, tail.get(j)) {
            (true, Some(script)) => self.classify_script(script, depth),
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
            j = j.saturating_add(1);
            match word {
                "-delete" => verdict.add(FileWrite, "find -delete"),
                "-fprint" | "-fprint0" | "-fprintf" | "-fls" => {
                    verdict.add(FileWrite, "find -fprint");
                }
                "-exec" | "-execdir" | "-ok" | "-okdir" => {
                    let start = j;
                    while tail.get(j).is_some_and(|w| *w != ";" && *w != "+") {
                        j = j.saturating_add(1);
                    }
                    verdict.merge(self.per_match(
                        tail.get(start..j.min(tail.len())).unwrap_or_default(),
                        depth,
                        "find",
                    ));
                    j = j.saturating_add(1);
                }
                _ => {}
            }
        }
        verdict.finish()
    }

    /// `fd` reads, unless `-x`/`-X` runs a command per match.
    fn fd(&self, name: &str, tail: &[&str], depth: usize) -> Classification {
        let mut verdict = Verdict::default();
        verdict.add(FileRead, name);
        let exec = ["-x", "--exec", "-X", "--exec-batch"];
        if let Some(at) = tail.iter().position(|w| exec.contains(w)) {
            let rest = tail.get(at.saturating_add(1)..).unwrap_or_default();
            let end = rest.iter().position(|w| *w == ";").unwrap_or(rest.len());
            verdict.merge(self.per_match(rest.get(..end).unwrap_or_default(), depth, name));
        }
        verdict.finish()
    }

    fn per_match(&self, command: &[&str], depth: usize, name: &str) -> Classification {
        if command.is_empty() {
            Classification::new(Machine, format!("{name} -exec"))
        } else {
            self.argv(command, depth)
        }
    }
}
