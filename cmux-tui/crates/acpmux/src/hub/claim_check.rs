//! Part of `Hub`; see `hub/mod.rs`. Claim checks: a turn's last reply says "tests pass", "the
//! build succeeds", "lint is clean", "typecheck passes" or "I ran `X`", and the turn's own shell
//! runs back it or do not.
//!
//! A finished command call is noted as it ends (bounded, no output read); the reply is read once,
//! when the turn ends, from the text the stream already keeps (`stream.rs` `trailing_text`). The
//! result is one `claim_checks` record logged before `turn_end`, so a client that attaches later
//! reads it with the turn and nothing rescans history.
//!
//! It claims only what it can back: a sentence that hedges or negates, a claim of a kind no
//! pattern knows, and a run whose exit status does not speak for the command (piped, `;`, `||`,
//! backgrounded) give no check at all, never a guessed one.

use super::*;
use regex::Regex;
use std::collections::VecDeque;
use std::sync::LazyLock;

/// Finished command calls kept per turn: the newest win.
const RUNS: usize = 64;
/// Started calls whose command is known and whose end has not come.
const PENDING: usize = 32;
const MAX_ID: usize = 128;
const MAX_COMMAND: usize = 4096;
/// Checks one reply carries, at most.
const MAX_CLAIMS: usize = 16;
/// A claim's quoted text, at most: a phrase, never a paragraph.
const MAX_CLAIM_TEXT: usize = 120;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ClaimKind {
    Tests,
    Build,
    Lint,
    Typecheck,
    Ran,
}

impl ClaimKind {
    fn bit(self) -> u8 {
        match self {
            Self::Tests => 1,
            Self::Build => 2,
            Self::Lint => 4,
            Self::Typecheck => 8,
            Self::Ran => 0,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Tests => "tests",
            Self::Build => "build",
            Self::Lint => "lint",
            Self::Typecheck => "typecheck",
            Self::Ran => "ran",
        }
    }
}

#[derive(Clone, Debug)]
struct Run {
    id: String,
    command: String,
    /// The `ClaimKind` bits a command of this run whose exit status speaks for it is.
    kinds: u8,
    /// The bits of commands in it whose exit status the run's does not speak for.
    hidden: u8,
    ok: bool,
}

/// A turn's finished command calls (`Session::claim_runs`).
#[derive(Debug, Default)]
pub(super) struct ClaimRuns {
    pending: VecDeque<(String, String)>,
    runs: VecDeque<Run>,
}

impl ClaimRuns {
    pub(super) fn reset(&mut self) {
        self.pending.clear();
        self.runs.clear();
    }

    /// One `session/update` of the running turn. Only a call's start and end do work: output
    /// deltas carry no `rawInput` and no terminal status.
    pub(super) fn observe(&mut self, update: &Value) {
        if !matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) {
            return;
        }
        let Some(id) = update
            .get("toolCallId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= MAX_ID)
        else {
            return;
        };
        let terminal =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        // A command started in the background ends its call before the command ends: its
        // status is not the command's.
        if update.pointer("/rawInput/run_in_background").and_then(Value::as_bool) == Some(true) {
            self.pending.retain(|(pending, _)| pending != id);
            return;
        }
        let command = command(update);
        if !terminal {
            if let Some(command) = command {
                self.pending.retain(|(pending, _)| pending != id);
                if self.pending.len() == PENDING {
                    self.pending.pop_front();
                }
                self.pending.push_back((id.to_owned(), command));
            }
            return;
        }
        let started = self
            .pending
            .iter()
            .position(|(pending, _)| pending == id)
            .and_then(|at| self.pending.remove(at))
            .map(|(_, command)| command);
        let Some(command) = command.or(started) else {
            return;
        };
        let (kinds, hidden) = classify(&command);
        self.runs.retain(|run| run.id != id);
        if self.runs.len() == RUNS {
            self.runs.pop_front();
        }
        self.runs.push_back(Run { id: id.to_owned(), command, kinds, hidden, ok: !failed(update) });
    }

    /// The newest run a claim of `kind` (with `ran`, the command it names) is about.
    fn last_for(&self, kind: ClaimKind, ran: Option<&str>) -> Option<(&Run, bool)> {
        self.runs.iter().rev().find_map(|run| match (kind, ran) {
            (ClaimKind::Ran, Some(named)) => {
                let named = squash(named);
                let command = squash(&run.command);
                (!named.is_empty() && command.contains(&named))
                    .then(|| (run, trusted_contains(&run.command, &named)))
            }
            (ClaimKind::Ran, None) => None,
            _ if run.kinds & kind.bit() != 0 => Some((run, true)),
            _ if run.hidden & kind.bit() != 0 => Some((run, false)),
            _ => None,
        })
    }
}

/// A claim the reply makes and what the turn's runs say of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ClaimCheck {
    pub text: String,
    pub kind: ClaimKind,
    /// `backed`: the newest matching run exited 0. `failed`: it did not. `none`: no run matched.
    pub verdict: &'static str,
    pub tool_call_id: Option<String>,
    pub command: Option<String>,
}

impl ClaimCheck {
    fn to_json(&self) -> Value {
        let mut out =
            json!({"text": self.text, "kind": self.kind.as_str(), "verdict": self.verdict});
        if let Some(o) = out.as_object_mut() {
            if let Some(id) = &self.tool_call_id {
                o.insert("toolCallId".into(), json!(id));
            }
            if let Some(command) = &self.command {
                o.insert("command".into(), json!(super::session::masked_preview(command, 160)));
            }
        }
        out
    }
}

/// The checks `reply` gets from `runs`, in the reply's order.
pub(super) fn check(reply: &str, runs: &ClaimRuns) -> Vec<ClaimCheck> {
    let mut out: Vec<ClaimCheck> = Vec::new();
    for (text, kind, ran) in claims(reply) {
        if out.len() == MAX_CLAIMS {
            break;
        }
        if out.iter().any(|c| c.text == text && c.kind == kind) {
            continue;
        }
        let check = match runs.last_for(kind, ran.as_deref()) {
            None => ClaimCheck { text, kind, verdict: "none", tool_call_id: None, command: None },
            // The run's exit status does not speak for the command the claim is about.
            Some((_, false)) => continue,
            Some((run, true)) => ClaimCheck {
                text,
                kind,
                verdict: if run.ok { "backed" } else { "failed" },
                tool_call_id: Some(run.id.clone()),
                command: Some(run.command.clone()),
            },
        };
        out.push(check);
    }
    out
}

impl Hub {
    /// A finished or started command call of `session`'s running turn (`stalled_turn.rs`
    /// `note_tool_update`, after its this-turn gate).
    pub(super) fn note_claim_run(&self, session: &Session, update: &Value) {
        session.claim_runs.lock().unwrap_or_else(|e| e.into_inner()).observe(update);
    }

    /// A new turn: no run of the last one backs this one's claims.
    pub(super) fn reset_claim_runs(&self, session: &Session) {
        session.claim_runs.lock().unwrap_or_else(|e| e.into_inner()).reset();
    }

    /// `turn_id` ends: its last reply's claims, checked once, logged before its `turn_end`.
    /// Nothing is logged for a reply with no claim a pattern knows.
    pub(super) fn append_claim_checks(&self, session: &Session, turn_id: &str) {
        let reply = {
            let st = session.stream.lock().unwrap_or_else(|e| e.into_inner());
            if st.trailing_overflow || st.trailing_text.is_empty() {
                return;
            }
            st.trailing_text.clone()
        };
        let checks = {
            let runs = session.claim_runs.lock().unwrap_or_else(|e| e.into_inner());
            check(&reply, &runs)
        };
        if checks.is_empty() {
            return;
        }
        let claims: Vec<Value> = checks.iter().map(ClaimCheck::to_json).collect();
        self.append(session, "mux", "claim_checks", json!({"turnId": turn_id, "claims": claims}));
    }
}

fn command(update: &Value) -> Option<String> {
    let command = match update.pointer("/rawInput/command")? {
        Value::String(command) => command.clone(),
        // Codex sends argv; `bash -lc "<script>"` is its script.
        Value::Array(args) if args.len() <= 64 => {
            let args: Vec<&str> = args.iter().filter_map(Value::as_str).collect();
            match args.as_slice() {
                [shell, flag, script] if is_shell(shell) && flag.starts_with('-') => {
                    (*script).to_owned()
                }
                _ => args.join(" "),
            }
        }
        _ => return None,
    };
    (!command.trim().is_empty() && command.len() <= MAX_COMMAND).then_some(command)
}

fn is_shell(program: &str) -> bool {
    matches!(program.rsplit('/').next(), Some("bash" | "sh" | "zsh"))
}

fn failed(update: &Value) -> bool {
    update.get("status").and_then(Value::as_str) == Some("failed")
        || update
            .pointer("/rawOutput/exit_code")
            .or_else(|| update.get("exitCode"))
            .and_then(Value::as_i64)
            .is_some_and(|code| code != 0)
}

/// Whitespace folded, for comparing a named command with a run's.
fn squash(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The `&&` steps of `command`, each with whether the whole command's exit status speaks for
/// it: a step that pipes, chains with `;` or `||`, or runs in the background does not.
fn steps(command: &str) -> Vec<(&str, bool)> {
    let lines: Vec<&str> = command.lines().filter(|l| !l.trim().is_empty()).collect();
    let multi_line = lines.len() > 1;
    command
        .split("&&")
        .map(|step| {
            let bare = step.replace("2>&1", "").replace(">&2", "");
            let speaks = !multi_line
                && !bare.contains('|')
                && !bare.contains(';')
                && !bare.trim_end().ends_with('&');
            (step, speaks)
        })
        .collect()
}

fn trusted_contains(command: &str, named: &str) -> bool {
    steps(command).iter().any(|(step, speaks)| *speaks && squash(step).contains(named))
}

/// The claim kinds `command` runs, as bits: those its exit status speaks for, and the others.
fn classify(command: &str) -> (u8, u8) {
    let (mut kinds, mut hidden) = (0, 0);
    for (step, speaks) in steps(command) {
        // A multi-line or `;` step: each part is classified, none is trusted.
        for part in step.split(['\n', ';', '|']) {
            let bits = classify_simple(part);
            if speaks {
                kinds |= bits;
            } else {
                hidden |= bits;
            }
        }
    }
    (kinds, hidden & !kinds)
}

const TESTS: u8 = 1;
const BUILD: u8 = 2;
const LINT: u8 = 4;
const TYPECHECK: u8 = 8;

/// One simple command's kinds: its program and first words, past env assignments and wrappers.
fn classify_simple(part: &str) -> u8 {
    let words: Vec<&str> = part
        .split_whitespace()
        .map(|w| w.trim_matches(|c| c == '(' || c == ')' || c == '"' || c == '\''))
        .collect();
    let mut words = words.as_slice();
    loop {
        match words {
            [first, rest @ ..] if first.contains('=') && !first.starts_with('-') => words = rest,
            ["timeout", _, rest @ ..] => words = rest,
            ["time" | "env" | "nice" | "command" | "exec" | "npx" | "bunx" | "sudo", rest @ ..] => {
                words = rest
            }
            ["pnpm" | "uv" | "poetry" | "pipenv", "exec" | "run", rest @ ..]
                if rest.first().is_some_and(|w| !w.starts_with('-')) =>
            {
                words = rest
            }
            // The fleet runner: the command after `--` is the one it runs.
            ["cmux-ci", "test", rest @ ..] => {
                let after = rest
                    .iter()
                    .position(|w| *w == "--")
                    .map_or(rest, |at| rest.get(at + 1..).unwrap_or_default());
                return if after.is_empty() { TESTS } else { classify_simple(&after.join(" ")) };
            }
            _ => break,
        }
    }
    let Some((&program, args)) = words.split_first() else {
        return 0;
    };
    let program = program.rsplit('/').next().unwrap_or(program);
    let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
    match program {
        "cargo" => match sub {
            "test" | "nextest" | "t" => TESTS,
            "build" | "b" => BUILD,
            "check" | "c" => BUILD | TYPECHECK,
            "clippy" => LINT,
            "fmt" if args.contains(&"--check") => LINT,
            _ => 0,
        },
        "npm" | "pnpm" | "yarn" | "bun" => {
            let script = if sub == "run" {
                args.iter().filter(|a| !a.starts_with('-')).nth(1).copied().unwrap_or("")
            } else {
                sub
            };
            script_kinds(script)
        }
        "go" => match sub {
            "test" => TESTS,
            "build" => BUILD,
            "vet" => LINT,
            _ => 0,
        },
        "swift" => match sub {
            "test" => TESTS,
            "build" => BUILD,
            _ => 0,
        },
        "xcodebuild" => {
            if args.iter().any(|a| matches!(*a, "test" | "test-without-building")) {
                TESTS
            } else {
                BUILD
            }
        }
        "make" | "just" | "gradle" | "gradlew" | "mix" | "deno" | "turbo" | "nx" => {
            if sub.is_empty() && program == "make" { BUILD } else { script_kinds(sub) }
        }
        "python" | "python3" if args.first() == Some(&"-m") => match args.get(1).copied() {
            Some("pytest" | "unittest") => TESTS,
            Some("mypy" | "pyright") => TYPECHECK,
            Some("ruff" | "flake8" | "pylint") => LINT,
            _ => 0,
        },
        "pytest" | "vitest" | "jest" | "mocha" | "rspec" | "ctest" | "phpunit" | "tox" => TESTS,
        "playwright" if sub == "test" => TESTS,
        "tsc" | "vue-tsc" | "mypy" | "pyright" => TYPECHECK,
        "eslint" | "ruff" | "flake8" | "pylint" | "golangci-lint" | "swiftlint" | "shellcheck"
        | "stylelint" | "rubocop" | "ktlint" | "oxlint" => LINT,
        "biome" if matches!(sub, "lint" | "check" | "ci") => LINT,
        "prettier" if args.contains(&"--check") => LINT,
        "tsgo" if args.contains(&"--noEmit") => TYPECHECK,
        _ => {
            // A project script: `./scripts/test.sh`, `run-tests`, `lint.sh`.
            let stem = program.split('.').next().unwrap_or(program);
            if stem.contains("test") {
                TESTS
            } else if stem.contains("lint") {
                LINT
            } else if stem.contains("typecheck") {
                TYPECHECK
            } else {
                0
            }
        }
    }
}

/// A package script or make target's kinds, from its name.
fn script_kinds(name: &str) -> u8 {
    let name = name.to_ascii_lowercase();
    if name.contains("typecheck") || name.contains("type-check") || name == "tsc" {
        TYPECHECK
    } else if name.contains("test") || name == "t" {
        TESTS
    } else if name.contains("lint") {
        LINT
    } else if name.contains("build") || name == "compile" {
        BUILD
    } else if name == "check" {
        // `cargo check` style: types and a build.
        BUILD | TYPECHECK
    } else {
        0
    }
}

/// A sentence that hedges, negates, plans or reports a failure makes no checkable claim.
static HEDGE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:not|no longer|never|isn't|aren't|doesn't|don't|didn't|won't|wasn't|weren't|haven't|hasn't|can't|cannot|couldn't|unable|fail|fails|failed|failing|failure|should|would|could|might|may|will|expect|expected|hopefully|if|once|until|unless|need to|needs to|please|try|let me|let's|next|todo|before|yet|probably|likely|assume|assuming)\b|'ll\b",
    )
    .ok()
});

/// A pattern that does not compile is left out: its claims get no check.
static PATTERNS: LazyLock<Vec<(ClaimKind, Regex)>> = LazyLock::new(|| {
    let p = |kind, re: &str| Regex::new(re).ok().map(|re| (kind, re));
    [
        p(
            ClaimKind::Tests,
            r"(?i)\b(?:all\s+)?(?:\d+\s+)?(?:(?:the|unit|integration|e2e|new|existing|relevant|rust|swift|web|cargo)\s+)*(?:tests?|test\s+suite|specs?)\s+(?:now\s+|all\s+|still\s+|also\s+)*(?:pass(?:es|ed)?|are\s+passing|is\s+passing|are\s+green|is\s+green|succeed(?:s|ed)?)\b",
        ),
        p(ClaimKind::Tests, r"(?i)\b(?:all\s+)?\d+\s+(?:tests?\s+)?passed\b"),
        p(
            ClaimKind::Build,
            r"(?i)\b(?:the\s+)?build\s+(?:now\s+|still\s+)*(?:succeeds|succeeded|passes|passed|is\s+green|is\s+clean|is\s+successful|works)\b",
        ),
        p(
            ClaimKind::Build,
            r"(?i)\b(?:it|everything|the\s+(?:code|project|crate|app|package|workspace))\s+(?:now\s+|still\s+)*(?:compiles|builds)(?:\s+(?:cleanly|successfully|fine|without\s+(?:errors|warnings)))?\b",
        ),
        p(ClaimKind::Build, r"(?i)\b(?:compiles|builds)\s+(?:cleanly|successfully)\b"),
        p(
            ClaimKind::Lint,
            r"(?i)\b(?:the\s+)?(?:lint(?:er|ing|s)?|clippy|eslint|biome|ruff)\s+(?:is\s+|are\s+|now\s+|still\s+|also\s+)*(?:clean|passes|passed|passing|green|happy)\b",
        ),
        p(ClaimKind::Lint, r"(?i)\bno\s+(?:lint|clippy|eslint)\s+(?:errors|warnings|issues)\b"),
        p(ClaimKind::Lint, r"(?i)\blint[- ]clean\b"),
        p(
            ClaimKind::Typecheck,
            r"(?i)\b(?:the\s+)?(?:type[- ]?check(?:ing|s|er)?|tsc|mypy|pyright|types)\s+(?:is\s+|are\s+|now\s+|still\s+|also\s+)*(?:clean|passes|passed|passing|green)\b",
        ),
        p(ClaimKind::Typecheck, r"(?i)\bno\s+type\s+errors\b"),
        p(ClaimKind::Typecheck, r"(?i)\btype[- ]?checks\s+(?:cleanly|fine)\b"),
        p(ClaimKind::Ran, r"(?i)\b(?:ran|re-?ran|executed)\s+`([^`\n]{2,200})`"),
    ]
    .into_iter()
    .flatten()
    .collect()
});

/// The claims `reply` makes: each one's quoted text, kind, and for `Ran` the command named.
/// Fenced code is not prose and is skipped.
fn claims(reply: &str) -> Vec<(String, ClaimKind, Option<String>)> {
    let mut out = Vec::new();
    let mut fenced = false;
    for line in reply.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        for sentence in sentences(line) {
            // No hedge pattern, no claims: every sentence might hedge.
            if HEDGE.as_ref().is_none_or(|hedge| hedge.is_match(&mask_code(sentence))) {
                continue;
            }
            let mut found: Vec<(usize, String, ClaimKind, Option<String>)> = Vec::new();
            for (kind, re) in PATTERNS.iter() {
                for caps in re.captures_iter(sentence) {
                    let Some(whole) = caps.get(0) else { continue };
                    if whole.as_str().len() > MAX_CLAIM_TEXT {
                        continue;
                    }
                    // One phrase is one claim: a second pattern over the same words adds none.
                    if found.iter().any(|(at, text, _, _)| {
                        whole.start() < at + text.len() && *at < whole.end()
                    }) {
                        continue;
                    }
                    let ran = caps.get(1).map(|m| m.as_str().trim().to_owned());
                    found.push((whole.start(), whole.as_str().to_owned(), *kind, ran));
                }
            }
            found.sort_by_key(|(at, ..)| *at);
            out.extend(found.into_iter().map(|(_, text, kind, ran)| (text, kind, ran)));
        }
    }
    out
}

/// `line`'s sentences: split at `.`, `!`, `?` followed by a space or the end, outside backticks.
fn sentences(line: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut code = false;
    let bytes = line.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        match b {
            b'`' => code = !code,
            b'.' | b'!' | b'?' | b';'
                if !code && bytes.get(i + 1).is_none_or(|n| n.is_ascii_whitespace()) =>
            {
                out.extend(line.get(start..=i));
                start = i + 1;
            }
            _ => {}
        }
    }
    if start < line.len() {
        out.extend(line.get(start..));
    }
    out
}

/// `sentence` with backticked code blanked: a command named in it ("`cargo test --no-run`")
/// is not the sentence hedging.
fn mask_code(sentence: &str) -> String {
    let mut code = false;
    sentence
        .chars()
        .map(|c| {
            if c == '`' {
                code = !code;
                ' '
            } else if code {
                ' '
            } else {
                c
            }
        })
        .collect()
}

#[cfg(test)]
#[path = "claim_check_tests.rs"]
mod tests;
