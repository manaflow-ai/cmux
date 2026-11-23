//! Commands whose flags or subcommands change their class: a reader with an
//! output file or a program to run, git and gh. A flag that can run a
//! program or write a file is checked before the command's usual class.

use crate::rules::{is_flag, is_sink};
use crate::{Classification, CommandClass, Verdict, net, programs};

use CommandClass::{FileRead, FileWrite, GitHooks, GitLocal, Machine, Network};

/// One option as getopt sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Opt<'a> {
    Short(char),
    Long(&'a str),
}

/// Walks `args` the way getopt does and returns the positional words. Short
/// options in `short_valued` take a value (`-ofile` or `-o file`), as do the
/// long ones in `long_valued` (`--output=file` or `--output file`); `visit`
/// sees every option with its value.
pub(crate) fn scan<'a>(
    args: &[&'a str],
    short_valued: &str,
    long_valued: &[&str],
    mut visit: impl FnMut(Opt<'a>, Option<&'a str>),
) -> Vec<&'a str> {
    let mut positionals = Vec::new();
    let mut j = 0;
    while let Some(&word) = args.get(j) {
        j = j.saturating_add(1);
        if word == "--" {
            positionals.extend_from_slice(args.get(j..).unwrap_or_default());
            break;
        }
        if !is_flag(word) {
            positionals.push(word);
        } else if let Some(long) = word.strip_prefix("--") {
            match long.split_once('=') {
                Some((name, value)) => visit(Opt::Long(name), Some(value)),
                None if long_valued.contains(&long) => {
                    visit(Opt::Long(long), args.get(j).copied());
                    j = j.saturating_add(1);
                }
                None => visit(Opt::Long(long), None),
            }
        } else {
            let cluster = word.get(1..).unwrap_or_default();
            for (at, c) in cluster.char_indices() {
                if short_valued.contains(c) {
                    let rest = cluster.get(at.saturating_add(c.len_utf8())..).unwrap_or_default();
                    let value = if rest.is_empty() {
                        let next = args.get(j).copied();
                        j = j.saturating_add(1);
                        next
                    } else {
                        Some(rest)
                    };
                    visit(Opt::Short(c), value);
                    break;
                }
                visit(Opt::Short(c), None);
            }
        }
    }
    positionals
}

/// The class of a command whose flags matter, or `None` for a plain command.
pub(crate) fn tool(name: &str, tail: &[&str]) -> Option<Classification> {
    Some(match name {
        "git" => git(tail),
        "gh" => gh(tail),
        "sed" => programs::sed(tail),
        "awk" | "gawk" | "mawk" | "nawk" => programs::awk(name, tail),
        "curl" => net::curl(tail),
        "wget" => net::wget(tail),
        "ssh" | "sftp" => net::ssh(name, tail),
        "scp" => net::scp(tail),
        "rsync" => net::rsync(tail),
        "tee" => tee(tail),
        "sort" => sort(tail),
        "uniq" => second_positional_writes(
            name,
            tail,
            "fsw",
            &["skip-fields", "skip-chars", "check-chars"],
        ),
        "xxd" => second_positional_writes(name, tail, "cglosn", &[]),
        "rg" => runs_with(name, tail, FileRead, &["--pre", "--hostname-bin"]),
        "ack" | "ag" | "bat" | "batcat" => runs_with(name, tail, FileRead, &["--pager"]),
        "tar" => tar(tail),
        "zip" => runs_with(name, tail, FileWrite, &["--unzip-command", "-TT"]),
        "install" => runs_with(name, tail, FileWrite, &["--strip-program"]),
        "tree" | "base64" => output_flag(name, tail),
        "yq" if tail.iter().any(|w| matches!(*w, "-i" | "--inplace")) => {
            Classification::new(FileWrite, "yq -i")
        }
        "yq" => Classification::new(FileRead, name),
        "file" if tail.iter().any(|w| *w == "-C" || *w == "--compile") => {
            Classification::new(FileWrite, "file -C")
        }
        "file" => Classification::new(FileRead, name),
        "date" if tail.iter().any(|w| w.starts_with("-s") || w.starts_with("--set")) => {
            Classification::new(Machine, "date -s")
        }
        "date" => Classification::new(FileRead, name),
        _ => return None,
    })
}

/// A command of class `base`, or [`Machine`] when one of `flags` (bare or
/// with `=value`) names a program for it to run.
fn runs_with(name: &str, tail: &[&str], base: CommandClass, flags: &[&str]) -> Classification {
    let runs = tail.iter().find_map(|w| {
        flags.iter().find(|flag| {
            *w == **flag || w.strip_prefix(**flag).is_some_and(|rest| rest.starts_with('='))
        })
    });
    match runs {
        Some(flag) => Classification::new(Machine, format!("{name} {flag}")),
        None => Classification::new(base, name),
    }
}

/// `uniq IN OUT` and `xxd IN OUT` write their second file.
fn second_positional_writes(
    name: &str,
    tail: &[&str],
    short_valued: &str,
    long_valued: &[&str],
) -> Classification {
    let positionals = scan(tail, short_valued, long_valued, |_, _| {});
    match positionals.get(1) {
        Some(out) if !is_sink(out) => Classification::new(FileWrite, format!("{name} OUTPUT")),
        _ => Classification::new(FileRead, name),
    }
}

/// `tree -o FILE` and `base64 -o FILE` write a file.
fn output_flag(name: &str, tail: &[&str]) -> Classification {
    let mut writes = false;
    for (at, word) in tail.iter().enumerate() {
        let target = match *word {
            "-o" | "--output" => tail.get(at.saturating_add(1)).copied(),
            _ => word.strip_prefix("--output="),
        };
        writes |= target.is_some_and(|path| path != "-" && !is_sink(path));
    }
    if writes {
        Classification::new(FileWrite, format!("{name} -o"))
    } else {
        Classification::new(FileRead, name)
    }
}

fn tee(tail: &[&str]) -> Classification {
    let positionals = scan(tail, "", &["output-error"], |_, _| {});
    if positionals.iter().any(|w| !is_sink(w)) {
        Classification::new(FileWrite, "tee")
    } else {
        Classification::new(FileRead, "tee")
    }
}

/// `sort` reads, unless it writes `-o FILE` (attached or not) or runs a
/// compression program.
fn sort(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    verdict.add(FileRead, "sort");
    let long_valued = [
        "key",
        "field-separator",
        "output",
        "buffer-size",
        "temporary-directory",
        "compress-program",
        "files0-from",
        "parallel",
        "batch-size",
        "sort",
        "random-source",
    ];
    scan(tail, "ktoST", &long_valued, |opt, value| match opt {
        Opt::Short('o') | Opt::Long("output") if !value.is_some_and(is_sink) => {
            verdict.add(FileWrite, "sort -o");
        }
        Opt::Long("compress-program") => verdict.add(Machine, "sort --compress-program"),
        _ => {}
    });
    verdict.finish()
}

/// `tar` writes (it creates or extracts), and runs a program for
/// `--to-command`, a checkpoint action, a compression program, a remote
/// shell or a volume script.
fn tar(tail: &[&str]) -> Classification {
    const RUNS: &[&str] = &[
        "--to-command",
        "--checkpoint-action",
        "--use-compress-program",
        "--rsh-command",
        "--info-script",
        "--new-volume-script",
    ];
    let runs = tail.iter().any(|w| {
        RUNS.iter().any(|flag| w.starts_with(flag))
            // `-I PROG` and `-F SCRIPT`, alone or in a cluster such as `-xIf`.
            || (is_flag(w) && !w.starts_with("--") && w.get(1..).is_some_and(|flags| flags.contains(['I', 'F'])))
    });
    if runs {
        Classification::new(Machine, "tar program")
    } else {
        Classification::new(FileWrite, "tar")
    }
}

/// Git subcommands that only read the repository.
#[rustfmt::skip]
const GIT_LOCAL: &[&str] = &[
    "status", "diff", "log", "show", "rev-parse", "grep", "blame", "ls-files", "cat-file",
    "describe", "shortlog", "rev-list", "ls-tree", "merge-base", "reflog", "show-ref",
    "for-each-ref", "name-rev", "whatchanged", "cherry", "range-diff", "count-objects",
    "check-ignore", "check-attr", "var", "help", "version", "diff-tree", "diff-files",
    "diff-index",
];

/// Git subcommands that rewrite the index or the tree, or run hooks.
#[rustfmt::skip]
const GIT_HOOKS: &[&str] = &[
    "commit", "checkout", "switch", "merge", "rebase", "am", "cherry-pick", "revert", "reset",
    "restore", "add", "rm", "mv", "clean", "apply", "init", "gc", "notes",
];

/// Settings that change nothing git runs; any other `-c` setting may name a
/// program (`core.fsmonitor`, `core.pager`, `diff.external`, a filter, a
/// credential helper, an alias) or move the hooks, so it fails closed.
fn is_inert_git_setting(setting: &str) -> bool {
    const PREFIXES: &[&str] = &["color.", "advice.", "user.", "column.", "i18n.", "init."];
    #[rustfmt::skip]
    const KEYS: &[&str] = &[
        "core.quotepath", "core.abbrev", "core.autocrlf", "core.safecrlf", "safe.directory",
        "log.date", "log.decorate", "log.follow", "diff.noprefix", "diff.renames",
        "diff.mnemonicprefix", "diff.relative", "status.short", "status.branch",
        "merge.conflictstyle", "gc.auto", "maintenance.auto", "fetch.prune", "pull.rebase",
        "pull.ff", "push.default", "push.autosetupremote", "rebase.autostash",
        "protocol.version",
    ];
    let (key, value) = setting.split_once('=').unwrap_or((setting, "true"));
    let key = key.to_ascii_lowercase();
    let off = matches!(value.to_ascii_lowercase().as_str(), "false" | "no" | "off" | "0");
    match key.as_str() {
        // Turning these off is inert; turning them on runs a program.
        "core.fsmonitor" | "commit.gpgsign" | "tag.gpgsign" | "log.showsignature" => off,
        "core.hookspath" => value == "/dev/null",
        _ => PREFIXES.iter().any(|p| key.starts_with(p)) || KEYS.contains(&key.as_str()),
    }
}

fn git(tail: &[&str]) -> Classification {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        match word {
            "-c" => match tail.get(j.saturating_add(1)) {
                Some(setting) if is_inert_git_setting(setting) => j = j.saturating_add(2),
                _ => return Classification::new(Machine, "git -c"),
            },
            "-C" | "--git-dir" | "--work-tree" | "--namespace" => j = j.saturating_add(2),
            _ if word.starts_with("--config-env") || word.starts_with("--exec-path=") => {
                return Classification::new(Machine, "git --config-env");
            }
            _ if word.starts_with('-') => j = j.saturating_add(1),
            _ => break,
        }
    }
    let Some(&sub) = tail.get(j) else {
        return Classification::new(GitLocal, "git");
    };
    Classification::new(
        git_subcommand(sub, tail.get(j.saturating_add(1)..).unwrap_or_default()),
        format!("git {sub}"),
    )
}

fn git_subcommand(sub: &str, rest: &[&str]) -> CommandClass {
    let first = rest.iter().copied().find(|w| !w.starts_with('-'));
    let has = |flags: &[&str]| has_flag(rest, flags);
    // A local pack program (`--upload-pack=./x`, `clone -u ./x`) runs on this side.
    if is_remote_op(sub)
        && (has(&["--upload-pack", "--receive-pack", "--exec"]) || (sub == "clone" && has(&["-u"])))
    {
        return Machine;
    }
    match sub {
        // Pushing into a repository on this disk runs that repository's hooks.
        "push" if first.is_some_and(is_local_remote) => GitHooks,
        "push" | "fetch" | "ls-remote" => Network,
        // A clone saves a new checkout into the workspace; a `-c` on it
        // configures that checkout.
        "clone" if has(&["-c", "--config", "--template"]) => Machine,
        "clone" => FileWrite,
        // A pull is a fetch and then a merge or rebase into the tree.
        "pull" => GitHooks,
        "remote" => match first {
            Some("update" | "prune" | "show") => Network,
            None | Some("get-url") => GitLocal,
            _ => FileWrite,
        },
        "stash" if matches!(first, Some("list" | "show")) => GitLocal,
        "worktree" if first == Some("list") => GitLocal,
        "submodule" => match first {
            None | Some("status" | "summary") => GitLocal,
            Some("foreach") => Machine,
            _ => GitHooks,
        },
        "bisect" if first == Some("run") => Machine,
        // `rebase --exec` runs a command after each commit, `-i` an editor.
        "rebase" if has(&["-x", "--exec", "-i", "--interactive"]) => Machine,
        "grep" if has(&["-O", "--open-files-in-pager"]) => Machine,
        "diff" | "log" | "show" if has(&["--ext-diff"]) => Machine,
        "diff" | "log" | "show" if has(&["--output"]) => FileWrite,
        "config" => git_config(rest),
        "branch" => git_refs(rest, BRANCH_WRITES, BRANCH_LISTS, &["--edit-description"]),
        "tag" => git_refs(rest, TAG_WRITES, TAG_LISTS, &[]),
        "reflog" if matches!(first, Some("expire" | "delete")) => FileWrite,
        "stash" | "worktree" | "bisect" => GitHooks,
        _ if GIT_LOCAL.contains(&sub) => GitLocal,
        _ if GIT_HOOKS.contains(&sub) => GitHooks,
        // Aliases, `git lfs` and other extensions run local programs.
        _ => Machine,
    }
}

/// Whether `args` has one of `flags`: exactly, with `=value`, or a short
/// one with its value attached (`-xcmd`).
fn has_flag(args: &[&str], flags: &[&str]) -> bool {
    args.iter().any(|w| {
        flags.iter().any(|f| {
            *w == *f
                || w.strip_prefix(f).is_some_and(|rest| rest.starts_with('='))
                || (f.len() == 2
                    && !f.starts_with("--")
                    && w.starts_with(f)
                    && !w.starts_with("--"))
        })
    })
}

fn is_remote_op(sub: &str) -> bool {
    matches!(sub, "fetch" | "pull" | "push" | "clone" | "ls-remote" | "archive")
}

fn is_local_remote(remote: &str) -> bool {
    remote.starts_with('/') || remote.starts_with('.') || remote.starts_with("file://")
}

/// `git config` reads with `--get`, `--list` or a lone key; it opens an
/// editor with `--edit`; anything else writes the configuration.
fn git_config(rest: &[&str]) -> CommandClass {
    let reads =
        ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "get", "list"];
    #[rustfmt::skip]
    let writes = [
        "--unset", "--unset-all", "--add", "--replace-all", "--rename-section",
        "--remove-section", "set", "unset", "rename-section", "remove-section",
    ];
    let positionals = scan(rest, "f", &["file", "blob", "type", "default", "comment"], |_, _| {});
    if rest.iter().any(|w| matches!(*w, "-e" | "--edit" | "edit")) {
        Machine
    } else if rest.iter().any(|w| writes.contains(w)) {
        FileWrite
    } else if rest.iter().any(|w| reads.contains(w)) || positionals.len() == 1 {
        GitLocal
    } else {
        FileWrite
    }
}

const BRANCH_WRITES: &[&str] = &[
    "-d",
    "-D",
    "-m",
    "-M",
    "-c",
    "-C",
    "-f",
    "-u",
    "--delete",
    "--move",
    "--copy",
    "--force",
    "--set-upstream-to",
    "--unset-upstream",
    "--track",
    "--no-track",
];
const BRANCH_LISTS: &[&str] = &[
    "-l",
    "--list",
    "-a",
    "--all",
    "-r",
    "--remotes",
    "--contains",
    "--no-contains",
    "--merged",
    "--no-merged",
    "--points-at",
    "--show-current",
    "-v",
    "-vv",
    "--format",
    "--sort",
];
const TAG_WRITES: &[&str] = &["-d", "--delete", "-a", "-s", "-u", "-f", "--force", "-m", "-F"];
const TAG_LISTS: &[&str] = &[
    "-l",
    "--list",
    "--contains",
    "--no-contains",
    "--merged",
    "--no-merged",
    "--points-at",
    "-n",
    "--format",
    "--sort",
];

/// `git branch` and `git tag` list refs, or create, move and delete them,
/// which writes the repository.
fn git_refs(rest: &[&str], writes: &[&str], lists: &[&str], edits: &[&str]) -> CommandClass {
    let flag = |w: &&str, set: &[&str]| set.iter().any(|f| w.split('=').next() == Some(*f));
    if rest.iter().any(|w| flag(w, edits)) {
        Machine
    } else if rest.iter().any(|w| flag(w, writes)) {
        FileWrite
    } else if rest.iter().any(|w| flag(w, lists)) || rest.iter().all(|w| w.starts_with('-')) {
        GitLocal
    } else {
        FileWrite
    }
}

/// gh's own top-level commands. Any other first word is an extension or an
/// alias, which runs local code.
#[rustfmt::skip]
const GH_COMMANDS: &[&str] = &[
    "api", "auth", "browse", "cache", "codespace", "cs", "gist", "issue", "label", "org", "pr",
    "project", "release", "repo", "ruleset", "run", "search", "secret", "variable", "ssh-key",
    "gpg-key", "status", "workflow", "attestation", "completion", "config", "help", "copilot",
];

fn gh(tail: &[&str]) -> Classification {
    // Only the options every command takes come before the action; skip
    // them with their values so `gh pr --repo o/r checkout 1` finds `checkout`.
    let mut words = tail.iter().copied();
    let mut positional = Vec::new();
    while let Some(word) = words.next() {
        match word {
            "-R" | "--repo" | "--hostname" => {
                words.next();
            }
            _ if is_flag(word) => {}
            _ => positional.push(word),
        }
        if positional.len() == 2 {
            break;
        }
    }
    let rest: Vec<&str> = words.collect();
    let has = |flags: &[&str]| has_flag(&rest, flags);
    // `gh repo sync` with no repository fast-forwards the local checkout.
    let syncs_local = || scan(&rest, "sb", &["source", "branch"], |_, _| {}).is_empty();
    let (group, action) = (positional.first().copied(), positional.get(1).copied());
    let class = match (group, action) {
        (None, _) => Network,
        (Some("pr"), Some("checkout")) | (Some("co"), _) => GitHooks,
        (Some("pr"), Some("merge")) if has(&["-d", "--delete-branch"]) => GitHooks,
        (Some("issue"), Some("develop")) if has(&["-c", "--checkout"]) => GitHooks,
        (Some("repo"), Some("sync")) if syncs_local() => GitHooks,
        (Some("run" | "release" | "attestation"), Some("download")) => FileWrite,
        (Some("repo" | "gist"), Some("clone")) => FileWrite,
        (Some("repo"), Some("create")) if has(&["-c", "--clone"]) => FileWrite,
        (Some("repo"), Some("fork")) if has(&["--clone", "--remote"]) => FileWrite,
        (Some("repo"), Some("set-default")) | (Some("auth"), Some("setup-git")) => FileWrite,
        (Some("codespace" | "cs"), Some("cp")) => FileWrite,
        (Some("codespace" | "cs"), Some("code" | "jupyter" | "ports")) => Machine,
        (Some(group), _) if GH_COMMANDS.contains(&group) => Network,
        (Some(_), _) => Machine,
    };
    let reason = match (class, group, action) {
        (Network, _, _) | (_, None, _) => "gh".to_owned(),
        (_, Some(group), Some(action)) => format!("gh {group} {action}"),
        (_, Some(group), None) => format!("gh {group}"),
    };
    Classification::new(class, reason)
}
