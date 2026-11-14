//! The detector for the `cmux` CLI's conventions (cmuxterm-hq
//! docs/cli-conventions.md): every scope the root help lists, probed with a
//! word it does not have and read back the way an agent reads it.
//!
//! - `cmux <scope> --help` exits 0 with the help on stdout.
//! - A word the scope does not have exits 2 (usage) or 3 (could not judge:
//!   no session, no app), never 0 or 1.
//! - Under `--json`, written after the scope or before it, the error is one
//!   JSON object on the last stderr line: `{"code", "message", "details",
//!   "retryable"}`, its message without the human `cmux: ` prefix.
//! - Without `--json`, the last stderr line names the fix: a help to run, a
//!   quoted command, or the usage.
//! - Every option in every help is lowercase kebab-case, no retired spelling
//!   comes back (`--args-json`, `--confirm`, `--timeout MS`), and a short
//!   option means the same long option in every scope.
//!
//! A scope added to the root help is in every check at once. A scope that
//! cannot keep one names why in `EXEMPT`, with the check it skips.
#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// The word no scope has.
const BOGUS: &str = "zzz-not-a-command";

/// Scopes another lane owns: `cmux vm` (and its old name `cloud`) is the
/// Cloud command group's, audited on its own scorecard.
const OTHER_LANE: &[&str] = &["vm", "cloud"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Check {
    /// The bogus-word probes: the scope reads any word as data.
    BogusWord,
    /// The `--json` error envelope.
    JsonEnvelope,
    /// The human last line that names the fix.
    HumanFix,
    /// A human error that is not JSON.
    HumanNotJson,
}

/// Each scope that cannot keep a check, the check, and why. Keep this short:
/// an entry is a known gap or a deliberate design, never a way to land a new
/// command that breaks the conventions.
const EXEMPT: &[(&str, Check, &str)] = &[
    ("chat", Check::BogusWord, "every word after `chat` is the prompt"),
    ("run", Check::BogusWord, "the word after `run` is the script file to run"),
    ("open", Check::BogusWord, "the word after `open` is the file or URL to open"),
    ("coderouter", Check::BogusWord, "every word goes to the bundled CodeRouter CLI"),
    ("notify", Check::BogusWord, "notify takes flags only; covered by the flag probe"),
    ("agents", Check::HumanNotJson, "agent-facing: prints JSON without --json by design"),
    ("setup", Check::HumanNotJson, "agent-facing: prints JSON without --json by design"),
    ("acp", Check::JsonEnvelope, "acpmux's envelope: {\"error\": {code, message, retryable}}"),
    ("harness", Check::JsonEnvelope, "acpmux's envelope: {\"error\": {code, message, retryable}}"),
    ("chats", Check::JsonEnvelope, "acpmux's envelope: {\"error\": {code, message, retryable}}"),
    ("github", Check::JsonEnvelope, "git's credential-helper protocol: plain text by design"),
    ("host", Check::JsonEnvelope, "cmux-host's own parser; gap tracked in docs/cli-conventions.md"),
];

fn exempt(scope: &str, check: Check) -> bool {
    EXEMPT.iter().any(|(name, skipped, _)| *name == scope && *skipped == check)
}

struct Cli {
    dir: PathBuf,
}

impl Cli {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        // Short: Unix socket paths are limited to about 100 bytes.
        let dir = PathBuf::from("/tmp").join(format!("cxc-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("run")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("cmux")).unwrap();
        Self { dir }
    }

    /// `cmux <args>` with no session, no app and no network setup: every
    /// probe here is a refusal, so nothing it runs changes anything.
    fn run(&self, args: &[&str]) -> Output {
        self.run_in(args, &self.dir, &[])
    }

    /// [`Cli::run`] from `cwd`, with `env` added.
    fn run_in(&self, args: &[&str], cwd: &std::path::Path, env: &[(&str, &str)]) -> Output {
        Command::new(self.dir.join("cmux"))
            .current_dir(cwd)
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &self.dir)
            .env("TMPDIR", self.dir.join("run"))
            .env("XDG_RUNTIME_DIR", self.dir.join("run"))
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .envs(env.iter().copied())
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }
}

impl Drop for Cli {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn last_line(stream: &[u8]) -> String {
    text(stream).lines().rev().find(|line| !line.trim().is_empty()).unwrap_or_default().to_owned()
}

/// The scopes the root help lists: its padded rows (`  <scope>  <what>`),
/// never its `  cmux …` examples or option rows.
fn listed_scopes(help: &str) -> Vec<String> {
    let mut scopes = Vec::new();
    for line in help.lines() {
        let Some(rest) = line.strip_prefix("  ").filter(|rest| !rest.starts_with(' ')) else {
            continue;
        };
        let word = rest.split_whitespace().next().unwrap_or_default();
        let padded = rest.strip_prefix(word).is_some_and(|tail| tail.starts_with("  "));
        let scope_word = !word.is_empty()
            && word.chars().all(|c| c.is_ascii_lowercase() || c == '-')
            && !word.starts_with('-');
        if padded && scope_word && word != "cmux" && !scopes.iter().any(|s| s == word) {
            scopes.push(word.to_owned());
        }
    }
    scopes
}

fn scopes(cli: &Cli) -> Vec<String> {
    let root = cli.run(&["--help"]);
    assert!(root.status.success(), "cmux --help: {}", text(&root.stderr));
    let scopes: Vec<String> = listed_scopes(&text(&root.stdout))
        .into_iter()
        .filter(|scope| !OTHER_LANE.contains(&scope.as_str()))
        .collect();
    // The root help lists dozens; a parse that finds a handful broke.
    assert!(scopes.len() >= 30, "root help scopes: {scopes:?}");
    scopes
}

/// What is wrong with one `--json` refusal, or `None`.
fn envelope_problem(output: &Output, cmux_envelope: bool) -> Option<String> {
    let code = output.status.code();
    if !matches!(code, Some(2 | 3)) {
        return Some(format!("exit {code:?}, not 2 (usage) or 3 (could not judge)"));
    }
    let line = last_line(&output.stderr);
    let Ok(value) = serde_json::from_str::<Value>(&line) else {
        return Some(format!("last stderr line is not JSON: {line:?}"));
    };
    if !value.is_object() {
        return Some(format!("not a JSON object: {line}"));
    }
    if !cmux_envelope {
        return None;
    }
    let message = value["message"].as_str();
    let problems = [
        (value["code"].as_str().is_none_or(str::is_empty), "no string `code`"),
        (message.is_none(), "no string `message`"),
        (!value["details"].is_object(), "no object `details`"),
        (!value["retryable"].is_boolean(), "no boolean `retryable`"),
        (message.is_some_and(|m| m.starts_with("cmux:")), "the message keeps `cmux: `"),
        (value["code"] == "usage.invalid" && code != Some(2), "usage.invalid without exit 2"),
    ];
    let found: Vec<&str> = problems.iter().filter(|(bad, _)| *bad).map(|(_, what)| *what).collect();
    (!found.is_empty()).then(|| format!("{}: {line}", found.join(", ")))
}

/// Whether a human refusal's last line tells an agent what to run.
fn names_fix(line: &str) -> bool {
    line.contains("--help")
        || line.contains('`')
        || line.contains("usage:")
        || line.contains("Usage:")
        || line.contains("--app-socket")
}

#[test]
fn every_scope_answers_help_on_stdout() {
    let cli = Cli::new();
    let mut failures = Vec::new();
    for scope in scopes(&cli) {
        let output = cli.run(&[&scope, "--help"]);
        if output.status.code() != Some(0) || output.stdout.is_empty() {
            failures.push(format!(
                "cmux {scope} --help: exit {:?}, {} bytes on stdout; stderr: {}",
                output.status.code(),
                output.stdout.len(),
                last_line(&output.stderr)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "scopes whose --help broke the convention:\n{}",
        failures.join("\n")
    );
}

#[test]
fn every_scope_refuses_an_unknown_word_in_the_one_shape() {
    let cli = Cli::new();
    let mut failures = Vec::new();
    for scope in scopes(&cli) {
        if exempt(&scope, Check::BogusWord) {
            continue;
        }
        let envelope = !exempt(&scope, Check::JsonEnvelope);
        let after = cli.run(&[&scope, BOGUS, "--json"]);
        let before = cli.run(&["--json", &scope, BOGUS]);
        for (form, output) in [("after", &after), ("before", &before)] {
            if exempt(&scope, Check::JsonEnvelope) && envelope_problem(output, false).is_some() {
                // acpmux, git's helper protocol: their own shapes, not checked.
                continue;
            }
            if let Some(problem) = envelope_problem(output, envelope) {
                failures.push(format!("cmux {scope} {BOGUS} (--json {form} the scope): {problem}"));
            }
        }
        let human = cli.run(&[&scope, BOGUS]);
        let line = last_line(&human.stderr);
        if !matches!(human.status.code(), Some(2 | 3)) {
            failures.push(format!(
                "cmux {scope} {BOGUS}: exit {:?}, not 2 or 3: {line}",
                human.status.code()
            ));
        }
        if !exempt(&scope, Check::HumanFix) && !names_fix(&line) {
            failures.push(format!("cmux {scope} {BOGUS}: the last line names no fix: {line:?}"));
        }
        if !exempt(&scope, Check::HumanNotJson) && serde_json::from_str::<Value>(&line).is_ok() {
            failures.push(format!("cmux {scope} {BOGUS}: JSON without --json: {line}"));
        }
    }
    assert!(
        failures.is_empty(),
        "scopes that broke the CLI conventions (cmuxterm-hq docs/cli-conventions.md):\n{}",
        failures.join("\n")
    );
}

/// Retired spellings and what replaced them; old spellings keep working,
/// but no help may show them again.
const RETIRED: &[(&str, &str)] = &[
    ("--args-json", "--args"),
    ("--confirm", "--yes"),
    ("--timeout MS", "--timeout 30s (a duration)"),
];

/// Every `--option` word in `help`, as written.
fn options(help: &str) -> Vec<String> {
    let mut found = Vec::new();
    let bytes = help.as_bytes();
    let mut index = 0;
    while let Some(offset) = help[index..].find("--") {
        let start = index + offset;
        let before = start.checked_sub(1).map(|i| bytes[i]);
        let mut end = start + 2;
        while end < bytes.len()
            && (bytes[end].is_ascii_alphanumeric() || b"-_".contains(&bytes[end]))
        {
            end += 1;
        }
        let word_start = before.is_none_or(|b| !(b.is_ascii_alphanumeric() || b == b'-'));
        if word_start && end > start + 2 && bytes[start + 2].is_ascii_alphabetic() {
            found.push(help[start..end].to_owned());
        }
        index = end.max(start + 2);
    }
    found
}

fn kebab(option: &str) -> bool {
    option.strip_prefix("--").is_some_and(|name| {
        name.split('-').all(|part| {
            !part.is_empty() && part.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
    })
}

/// `-x, --long` definitions: a short option and the long one it stands for.
fn short_options(help: &str) -> Vec<(String, String)> {
    help.lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let (short, rest) = line.split_once(", ")?;
            let long = rest.split_whitespace().next()?;
            (short.len() == 2
                && short.starts_with('-')
                && short.as_bytes()[1].is_ascii_alphabetic()
                && long.starts_with("--"))
            .then(|| (short.to_owned(), long.to_owned()))
        })
        .collect()
}

#[test]
fn option_names_follow_the_conventions_in_every_help() {
    let cli = Cli::new();
    let mut failures = Vec::new();
    let mut shorts: BTreeMap<String, (String, String)> = BTreeMap::new();
    let root = text(&cli.run(&["--help"]).stdout);
    let mut helps = vec![("(root)".to_owned(), root)];
    for scope in scopes(&cli) {
        let output = cli.run(&[&scope, "--help"]);
        helps.push((scope, text(&output.stdout)));
    }
    for (scope, help) in &helps {
        for option in options(help) {
            if !kebab(&option) {
                failures.push(format!("cmux {scope} --help: {option} is not lowercase kebab-case"));
            }
            if let Some((_, now)) = RETIRED.iter().find(|(old, _)| *old == option) {
                failures.push(format!("cmux {scope} --help shows the retired {option}; use {now}"));
            }
        }
        for (old, now) in RETIRED.iter().filter(|(old, _)| old.contains(' ')) {
            if help.contains(old) {
                failures.push(format!("cmux {scope} --help shows the retired `{old}`; use {now}"));
            }
        }
        for (short, long) in short_options(help) {
            match shorts.get(&short) {
                Some((other, seen)) if *other != long => failures
                    .push(format!("{short} is {long} in cmux {scope} but {other} in cmux {seen}")),
                Some(_) => {}
                None => {
                    shorts.insert(short, (long, scope.clone()));
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "option names that broke the CLI conventions (cmuxterm-hq docs/cli-conventions.md):\n{}",
        failures.join("\n")
    );
}

#[test]
fn the_detector_reads_the_shapes_it_judges() {
    // The parsers above, on fixed text, so a change to them cannot pass by
    // finding nothing.
    let help = "USAGE\n  cmux tab list\n\nSCOPES\n  tab      Tabs\n  cmux pane  example\n  --json   Print JSON\n";
    assert_eq!(listed_scopes(help), vec!["tab".to_owned()]);
    assert_eq!(
        options("a [--name NAME] --json, x--y --Bad_Flag"),
        ["--name", "--json", "--Bad_Flag"]
    );
    assert!(kebab("--end-terminals") && !kebab("--Bad_Flag") && !kebab("--a--b"));
    assert_eq!(short_options("  -p, --prompt TEXT  send"), [("-p".into(), "--prompt".into())]);
    assert!(names_fix("cmux: unknown tab action; run `cmux tab --help`"));
    assert!(!names_fix("cmux: something failed"));
}

/// Where a text names a VM by the app's old words: `machine:ID` (a target, not
/// `machine: reason`) or `list-machines`. `None` when it says `vm:ID` and
/// `cmux vm ls`.
fn machine_word(text: &str) -> Option<String> {
    for (at, _) in text.match_indices("machine:") {
        let before = text[..at].chars().next_back();
        let after = text[at + "machine:".len()..].chars().next();
        if before.is_none_or(|c| !c.is_ascii_alphanumeric())
            && after.is_some_and(|c| !c.is_whitespace())
        {
            let line = text[..at].rfind('\n').map_or(0, |start| start + 1);
            let end = text[at..].find('\n').map_or(text.len(), |end| at + end);
            return Some(text[line..end].trim().to_owned());
        }
    }
    text.lines().find(|line| line.contains("list-machines")).map(|line| line.trim().to_owned())
}

/// The verb rows of a help (`  <verb>  <what>`), as `listed_scopes` reads the
/// root help's.
fn verb_rows(help: &str) -> Vec<String> {
    listed_scopes(help)
}

/// Leo, 2026-11-10: "i thought we rewrote the cli commands to not use
/// machine?" A Cloud VM is `vm:ID` and `cmux vm ls` in every help, error and
/// `next` hint the CLI prints; `machine:ID` and `list-machines` keep working
/// as input and are never printed.
#[test]
fn no_help_or_error_names_a_vm_by_its_old_machine_words() {
    let cli = Cli::new();
    let root = cli.run(&["--help"]);
    let mut commands: Vec<Vec<String>> = vec![vec!["--help".to_owned()]];
    for scope in listed_scopes(&text(&root.stdout)) {
        commands.push(vec![scope, "--help".to_owned()]);
    }
    for scope in ["vm", "cloud"] {
        let help = cli.run(&[scope, "--help"]);
        for verb in verb_rows(&text(&help.stdout)) {
            commands.push(vec![scope.to_owned(), verb, "--help".to_owned()]);
        }
    }
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    for extra in [
        &["vm", "--help"][..],
        &["cloud", "--help"],
        &["machine", "--help"],
        &["device", "--help"],
        &["chat", "--help"],
        &["vnc", "--help"],
        &["vm", "new", "--help"],
        &["cloud", "start-chat", "--help"],
        &["vm", BOGUS],
        &["vm", BOGUS, "--json"],
        &["cloud", BOGUS],
        &["vm", "ls"],
        &["vm", "ls", "--json"],
        &["vm", "access", "new"],
        &["vm", "exec", "--target"],
        &["vm", "kill-machine", "--target", "vm:vm-1", "--confirm", "--json"],
        &["cloud", "start-chat", "--target", "", "--prompt", "hi"],
        &["chat", "--on", "vm:nope", "--prompt", "hi"],
        &["chat", "--on", "vm:nope", "--prompt", "hi", "--json"],
        &["vnc", "vm:"],
        &["vnc"],
    ] {
        commands.push(words(extra));
    }
    let mut leaks = Vec::new();
    for command in &commands {
        let args: Vec<&str> = command.iter().map(String::as_str).collect();
        let output = cli.run(&args);
        let printed = format!("{}{}", text(&output.stdout), text(&output.stderr));
        if let Some(line) = machine_word(&printed) {
            leaks.push(format!("cmux {}: {line}", command.join(" ")));
        }
    }
    assert!(
        leaks.is_empty(),
        "{} command(s) print a VM as `machine:` or `list-machines` (say `vm:ID`, `cmux vm ls`):\n{}",
        leaks.len(),
        leaks.join("\n")
    );
}

#[test]
fn the_machine_word_check_reads_targets_not_prose() {
    assert!(machine_word("run `cmux vm ls` with --target vm:vm-1").is_none());
    assert!(machine_word("new Cloud machine: no capacity\n--login pass|machine|none").is_none());
    assert!(machine_word("--target machine:MACHINE_ID").is_some());
    assert!(machine_word("run `cmux vm list-machines`").is_some());
    assert!(machine_word("on machine:vm-1.").is_some());
}

/// A missing or malformed option is a usage error in the one shape too, not
/// only an unknown word: `link init` without `--install`, a `--port` that is
/// no port (both refused before any link state is read).
#[test]
fn a_missing_or_bad_option_is_the_usage_error_object() {
    let cli = Cli::new();
    for args in [
        &["--json", "link", "init"][..],
        &["link", "init", "--json"],
        &["link", "init", "--install", "x", "--port", "nope", "--json"],
    ] {
        let output = cli.run(args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "cmux {}: {}",
            args.join(" "),
            text(&output.stderr)
        );
        if let Some(problem) = envelope_problem(&output, true) {
            panic!("cmux {}: {problem}", args.join(" "));
        }
    }
}

/// Shell completion for every scope, read from the help (Leo, 2026-11-10: "We need to keep
/// cleaning up the cli commands so they're nice to type and intuitive and ergonomic and go with
/// best practices"). Every scope the root help lists completes at the first word, the everyday
/// scopes complete their verbs, and each shell gets a script that asks `cmux __complete`.
#[test]
fn completion_lists_every_scope() {
    let cli = Cli::new();
    let first = cli.run(&["__complete", "--", ""]);
    assert!(first.status.success(), "cmux __complete -- '': {}", text(&first.stderr));
    let offered: Vec<String> = text(&first.stdout).lines().map(str::to_owned).collect();
    for scope in scopes(&cli) {
        assert!(offered.contains(&scope), "`cmux <Tab>` does not offer `{scope}`: {offered:?}");
    }
    assert!(offered.iter().any(|word| word == "completion"), "{offered:?}");
    for (scope, verb) in
        [("vm", "ls"), ("chat", "send"), ("workspace", "list"), ("completion", "zsh")]
    {
        let out = cli.run(&["__complete", "--", scope, ""]);
        let verbs = text(&out.stdout);
        assert!(
            verbs.lines().any(|line| line == verb),
            "`cmux {scope} <Tab>` lacks `{verb}`: {verbs}"
        );
    }
    for shell in ["zsh", "bash", "fish"] {
        let out = cli.run(&["completion", shell]);
        assert!(out.status.success(), "cmux completion {shell}: {}", text(&out.stderr));
        assert!(text(&out.stdout).contains("cmux __complete --"), "cmux completion {shell}");
    }
    let help = cli.run(&["completion", "--help"]);
    assert!(help.status.success() && text(&help.stdout).contains("cmux completion zsh"));
    let bare = cli.run(&["completion"]);
    assert_eq!(bare.status.code(), Some(2), "bare `cmux completion` is a usage error");
}

/// The VM verbs a person types every day (`cmux vm exec dev -- uname -a`).
const EVERYDAY_VM_VERBS: &[&str] =
    &["exec", "ssh", "move", "status", "pause", "resume", "rm", "resize", "fork", "rename"];

/// Leo, 2026-11-10: "We need to keep cleaning up the cli commands so they're
/// nice to type and intuitive and ergonomic and go with best practices". The
/// everyday VM verbs name the VM by position in every example the VM help
/// prints, never `--target vm:ID`, and no VM help shows a retired spelling (a
/// delete says yes with `--yes`, not `--confirm`).
#[test]
fn the_vm_help_names_a_vm_by_position_and_deletes_with_yes() {
    let cli = Cli::new();
    let mut problems = Vec::new();
    for scope in ["vm", "cloud"] {
        let help = text(&cli.run(&[scope, "--help"]).stdout);
        problems.extend(
            targeted_examples(&help).into_iter().map(|line| format!("cmux {scope} --help: {line}")),
        );
        let mut helps = vec![(format!("{scope} --help"), help.clone())];
        for verb in verb_rows(&help) {
            let output = cli.run(&[scope, &verb, "--help"]);
            helps.push((format!("{scope} {verb} --help"), text(&output.stdout)));
        }
        for (command, help) in helps {
            for option in options(&help) {
                if let Some((_, now)) = RETIRED.iter().find(|(old, _)| *old == option) {
                    problems.push(format!("cmux {command} shows the retired {option}; use {now}"));
                }
            }
        }
    }
    assert!(
        problems.is_empty(),
        "VM help that is harder to type than it needs to be:\n{}",
        problems.join("\n")
    );
}

/// The `cmux vm|cloud VERB …` example lines of `help` whose everyday verb
/// names its VM with `--target`.
fn targeted_examples(help: &str) -> Vec<String> {
    help.lines()
        .map(str::trim)
        .filter_map(|line| {
            let rest =
                line.strip_prefix("cmux vm ").or_else(|| line.strip_prefix("cmux cloud "))?;
            let verb = rest.split_whitespace().next()?;
            (EVERYDAY_VM_VERBS.contains(&verb) && rest.contains("--target"))
                .then(|| line.to_owned())
        })
        .collect()
}

#[test]
fn the_targeted_example_check_reads_example_lines() {
    assert_eq!(targeted_examples("  cmux vm exec --target vm:X --command 'uname -a'").len(), 1);
    assert!(
        targeted_examples("  cmux vm exec dev -- uname -a\n  cmux vm access new --target vm:X")
            .is_empty()
    );
}

/// Leo, 2026-11-10: "We need to keep cleaning up the cli commands so they're
/// nice to type and intuitive and ergonomic and go with best practices". The
/// next command to a chat names no session id: `cmux chat send TEXT` and
/// `cmux chat wait|read last` are the last chat this terminal started or sent
/// to. With none recorded, the refusal names how to find one; with one
/// recorded, the command goes to it (here: no session, so it cannot reach
/// it, but it never asks for the SESSION id).
#[test]
fn chat_follow_ups_need_no_session_id() {
    let cli = Cli::new();
    let none = cli.run(&["chat", "send", "next step", "--json"]);
    let line = last_line(&none.stderr);
    let error: Value = serde_json::from_str(&line).unwrap_or_else(|_| panic!("not JSON: {line}"));
    assert_eq!(error["code"], "chat.no_last_chat", "{line}");
    assert_eq!(none.status.code(), Some(1), "{line}");
    assert!(names_fix(&last_line(&cli.run(&["chat", "send", "next step"]).stderr)));

    let state = cli.dir.join(".local/state/cmux");
    fs::create_dir_all(&state).unwrap();
    let session = "0d4f9a52-8c1e-4b7a-9f3e-2a6b5c7d8e9f";
    let book = format!(r#"{{"-": {{"session": "{session}", "vm": null, "at": 1}}}}"#);
    fs::write(state.join("last-chat.json"), book).unwrap();
    for args in [
        &["chat", "send", "next step", "--json"][..],
        &["chat", "wait", "last", "--timeout", "1", "--json"],
        &["chat", "read", "last", "--json"],
    ] {
        let output = cli.run(args);
        let stderr = text(&output.stderr);
        assert_ne!(output.status.code(), Some(2), "cmux {}: {stderr}", args.join(" "));
        assert!(!stderr.contains("SESSION id"), "cmux {}: {stderr}", args.join(" "));
        assert!(!stderr.contains("chat.no_last_chat"), "cmux {}: {stderr}", args.join(" "));
    }
    // `-w` is `--wait` in the chat help, so the short-option check holds it to that.
    let help = text(&cli.run(&["chat", "--help"]).stdout);
    assert!(short_options(&help).contains(&("-w".to_owned(), "--wait".to_owned())), "{help}");
}

/// A Tab only reads helps: completing a launcher's words (`cmux preview open`, which runs the
/// checkout's own script) runs nothing, and a help reader refuses anything but a help.
#[test]
fn completion_runs_nothing_but_helps() {
    let cli = Cli::new();
    let checkout = cli.dir.join("checkout");
    let marker = cli.dir.join("ran");
    for script in ["Prototypes/ViewShell/launch.sh", "Prototypes/UiLayerHost/launch.sh"] {
        let path = checkout.join(script);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("#!/bin/sh\ntouch {}\n", marker.display())).unwrap();
        fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    }
    fs::create_dir_all(checkout.join(".git")).unwrap();
    for words in [&["preview", "open", ""][..], &["dev", "ui-host", ""], &["preview", ""]] {
        let mut args = vec!["__complete", "--"];
        args.extend(words);
        let out = cli.run_in(&args, &checkout, &[]);
        assert!(out.status.success(), "cmux {args:?}: {}", text(&out.stderr));
    }
    for args in [&["preview", "open", "--help"][..], &["dev", "ui-host", "--help"], &["vm", "ls"]] {
        let out = cli.run_in(args, &checkout, &[("CMUX_COMPLETE_HELP", "1")]);
        assert_eq!(out.status.code(), Some(2), "a help reader ran `cmux {args:?}`");
    }
    assert!(!marker.exists(), "a Tab ran a checkout's launcher");
}
