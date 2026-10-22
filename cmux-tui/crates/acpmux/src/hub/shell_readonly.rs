//! Read-only shell commands under approve-reads and approve-edits. Leo: "Read-only commands (rg,
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

use serde_json::Value;

/// Directories a command given by path may come from; a relative path or any other directory
/// could be a program the agent wrote.
const TRUSTED_DIRS: [&str; 6] =
    ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/sbin", "/usr/sbin"];

/// Commands that only read, whatever their arguments.
const PLAIN: &[&str] = &[
    "pwd", "ls", "cat", "head", "tail", "wc", "echo", "printf", "true", "false", "which", "type",
    "stat", "du", "df", "basename", "dirname", "realpath", "readlink", "cut", "tr", "nl", "cmp",
    "comm", "diff", "grep", "egrep", "fgrep", "column", "whoami", "id", "uname", "cd", "test", "[",
    "jq",
];

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

/// Whether the toolCall of `request` is a shell command (`execute`) that only reads.
pub(crate) fn request_is_read_only(request: &Value) -> bool {
    let Some(call) = request.get("toolCall") else { return false };
    if call.get("kind").and_then(Value::as_str) != Some("execute") {
        return false;
    }
    match call.pointer("/rawInput/command") {
        Some(Value::String(script)) => is_read_only(script),
        Some(Value::Array(argv)) => {
            match argv.iter().map(Value::as_str).collect::<Option<Vec<_>>>().as_deref() {
                Some([shell, "-c" | "-lc", script])
                    if matches!(command_name(shell), Some("sh" | "bash" | "zsh")) =>
                {
                    is_read_only(script)
                }
                _ => false,
            }
        }
        _ => false,
    }
}

/// Whether shell `script` only reads: every command in it passes the allowlist.
pub(crate) fn is_read_only(script: &str) -> bool {
    let Some(segments) = segments(script) else { return false };
    segments.iter().any(|s| !s.is_empty()) && segments.iter().all(|s| segment_ok(s))
}

/// The words of each command in `script`, split at `;`, `&&`, `||`, `|` and newlines. None
/// for anything this does not read plainly.
fn segments(script: &str) -> Option<Vec<Vec<String>>> {
    let mut segs = vec![Vec::new()];
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = script.chars().peekable();
    let end = |segs: &mut Vec<Vec<String>>, word: &mut String, in_word: &mut bool| {
        if *in_word {
            segs.last_mut().unwrap().push(std::mem::take(word));
        }
        *in_word = false;
    };
    while let Some(c) = chars.next() {
        match c {
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
                in_word = true;
                word.push(c);
            }
            '#' if !in_word => while chars.next_if(|n| *n != '\n').is_some() {},
            ';' | '\n' => {
                end(&mut segs, &mut word, &mut in_word);
                segs.push(Vec::new());
            }
            '&' => {
                // `&&` separates; a lone `&` runs a job in the background.
                chars.next_if_eq(&'&')?;
                end(&mut segs, &mut word, &mut in_word);
                segs.push(Vec::new());
            }
            '|' => {
                chars.next_if_eq(&'|');
                end(&mut segs, &mut word, &mut in_word);
                segs.push(Vec::new());
            }
            ' ' | '\t' | '\r' => end(&mut segs, &mut word, &mut in_word),
            ch => {
                in_word = true;
                word.push(ch);
            }
        }
    }
    end(&mut segs, &mut word, &mut in_word);
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
    arg.starts_with('-') && !arg.starts_with("--") && arg[1..].contains(flag)
}

fn segment_ok(words: &[String]) -> bool {
    let Some((first, args)) = words.split_first() else { return true };
    // `GIT_EXTERNAL_DIFF=x git diff` runs x.
    if let Some((name, _)) = first.split_once('=')
        && !name.is_empty()
        && name.chars().all(|c| c == '_' || c.is_ascii_alphanumeric())
    {
        return false;
    }
    let Some(name) = command_name(first) else { return false };
    let any = |f: &dyn Fn(&str) -> bool| args.iter().any(|a| f(a));
    match name {
        n if PLAIN.contains(&n) => true,
        "sort" => !any(&|a| {
            a == "-o"
                || a.starts_with("--output")
                || a.starts_with("--compress-program")
                || short_has(a, 'o')
        }),
        "uniq" => args.iter().filter(|a| a.as_str() == "-" || !a.starts_with('-')).count() <= 1,
        "date" => !any(&|a| a.starts_with("--set") || short_has(a, 's')),
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
        "file" => !any(&|a| a == "--compile" || short_has(a, 'C')),
        "tree" => !any(&|a| short_has(a, 'o') || short_has(a, 'R')),
        "rg" => !any(&|a| a == "--pre" || a.starts_with("--pre=") || a.starts_with("--pre-glob")),
        "find" => !any(&|a| {
            a.starts_with("-exec")
                || a.starts_with("-ok")
                || a.starts_with("-fprint")
                || matches!(a, "-delete" | "-fls")
        }),
        "git" => git_ok(args),
        _ => false,
    }
}

fn git_ok(args: &[String]) -> bool {
    let mut i = 0;
    while let Some(a) = args.get(i) {
        match a.as_str() {
            "--no-pager" => i += 1,
            "-C" if i + 1 < args.len() => i += 2,
            a if a.starts_with("-C") && a.len() > 2 => i += 1,
            a if a.starts_with('-') => return false,
            _ => break,
        }
    }
    let Some((sub, rest)) = args[i..].split_first() else { return false };
    let writes = |a: &String| {
        a == "--output"
            || a.starts_with("--output=")
            || a.starts_with("-O")
            || a.starts_with("--open-files-in-pager")
            || a == "--ext-diff"
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
                            || (a.starts_with("-n") && a[2..].chars().all(|c| c.is_ascii_digit()))
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
            "cd /tmp && ls -la",
            "git branch --show-current",
            "/usr/bin/rg foo",
            "git --no-pager -C/x log -1",
            "ls src/*.rs",
            "[ -f x ] && cat x",
            "git config --get user.name",
            "git remote -v",
            "git tag -l 'v1*'",
            "git status # ; rm -rf x",
            "sort -u x | uniq -c",
            "echo \"a b\" 'c'",
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
            "date -s 2020-01-01",
            "hostname evil",
            "xargs rm",
            "bash -c ls",
            "",
            "ls |& cat",
        ] {
            assert!(!is_read_only(script), "{script}");
        }
    }

    #[test]
    fn request_needs_an_execute_with_a_command() {
        let req = |kind: &str, command: Value| json!({"toolCall": {"kind": kind, "rawInput": {"command": command}}});
        assert!(request_is_read_only(&req("execute", json!("git status"))));
        assert!(request_is_read_only(&req("execute", json!(["/bin/bash", "-lc", "git status"]))));
        assert!(request_is_read_only(&req("execute", json!(["zsh", "-c", "pwd"]))));
        assert!(!request_is_read_only(&req("execute", json!(["git", "status"]))));
        assert!(!request_is_read_only(&req("execute", json!(["bash", "-lc", "git push"]))));
        assert!(!request_is_read_only(&req("execute", json!(["python", "-c", "ls"]))));
        assert!(!request_is_read_only(&req("edit", json!("git status"))));
        assert!(!request_is_read_only(&json!({"toolCall": {"kind": "execute"}})));
    }
}
