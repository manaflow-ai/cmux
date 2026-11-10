//! The skill distiller: when agents in one project have done the same kind of task three times,
//! the third chat offers to save it as a skill, its steps already drafted from those chats. Leo,
//! 2026-11-08: "go think of things/look at things, esp valuable things that people would think
//! \"wow this is awesome\"".
//!
//! - A chat's task shape ([`Shape`]) is the intent of its first person prompt (its content words,
//!   [`intent`]) and the run of its tool calls, normalised ([`step_of`]: `cargo test`, `gh pr`,
//!   `edit`). The live updates are read as they pass ([`observe`]); nothing rescans history.
//! - At a completed turn's end the chat's shape is written to its folder's record once
//!   ([`Record`], one small file per project folder in acpmux's home), at most [`MAX_CHATS`] chats.
//! - The chat and two others that are [`similar`] and not yet part of an offer make a pattern. A
//!   pattern is offered once: one already offered, saved or dismissed in that folder is never
//!   offered again ([`Record::claim`]).
//! - The draft (`hub/skill_distill.rs`) comes from the chat's own harness, one headless completion
//!   ([`draft_prompt`], [`parse_draft`]); where no harness can answer, it is built from the shapes
//!   themselves ([`shapes_draft`]). It is kept with the pattern, so it is drafted once.
//! - Save writes `SKILL.md` into the person's skills folder (`agent_guidance::user_skills_dir`),
//!   the one every chat cmux starts reads ([`write_skill`]); an existing skill is never replaced.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

/// The similar chats a pattern needs, the chat itself included.
pub const PATTERN_SIZE: usize = 3;
/// The most chats a folder's record keeps, newest last.
pub const MAX_CHATS: usize = 24;
/// The most patterns a folder's record keeps; the oldest go first.
const MAX_PATTERNS: usize = 64;
/// The most steps one chat's shape keeps.
const MAX_STEPS: usize = 40;
/// The most commands one chat's shape keeps.
const MAX_COMMANDS: usize = 12;
/// A kept command is cut to this many characters.
const MAX_COMMAND_CHARS: usize = 120;
/// A kept prompt is cut to this many characters.
pub const MAX_PROMPT_CHARS: usize = 160;
/// The most intent words of one prompt.
const MAX_INTENT_WORDS: usize = 24;
/// A skill's description: one line, at most this many characters (`agent_guidance`'s cut).
pub const MAX_DESCRIPTION: usize = 300;
/// A skill's body, in bytes.
pub const MAX_BODY: usize = 16 * 1024;

/// One chat's task shape.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Shape {
    pub session: String,
    /// The first person prompt, cut to [`MAX_PROMPT_CHARS`].
    pub prompt: String,
    /// Its content words ([`intent`]).
    pub intent: Vec<String>,
    /// The normalised tool runs, in order, no step twice in a row.
    pub steps: Vec<String>,
    /// The distinct shell commands it ran, first lines, in order.
    pub commands: Vec<String>,
    /// Part of a pattern already: it never seeds another.
    #[serde(default)]
    pub claimed: bool,
}

/// A pattern offered in a folder, with its draft.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pattern {
    pub offer_id: String,
    /// The words every chat of it asked with, and the steps they share: what a later pattern
    /// compares by.
    pub intent: Vec<String>,
    pub steps: Vec<String>,
    /// `offered`, `saved` or `dismissed`.
    pub state: String,
    pub draft: Option<Draft>,
}

/// A drafted skill.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Draft {
    pub name: String,
    pub description: String,
    pub body: String,
    /// `harness` (the chat's model wrote it) or `shapes` (built from the recorded steps).
    pub drafted: String,
}

/// A folder's record: its newest chats' shapes and the patterns offered there.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Record {
    #[serde(default)]
    pub chats: Vec<Shape>,
    #[serde(default)]
    pub patterns: Vec<Pattern>,
}

/// Words that say nothing about a task.
const STOP: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "into", "onto", "you", "your", "our",
    "are", "was", "were", "can", "could", "would", "should", "will", "please", "pls", "thanks",
    "then", "than", "them", "they", "its", "it's", "all", "any", "some", "just", "also", "now",
    "out", "via", "but", "not", "have", "has", "had", "let", "lets", "let's", "make", "sure",
    "get", "got", "want", "need", "like", "what", "when", "where", "which", "who", "how", "why",
    "there", "here", "about", "after", "before", "again", "new", "one", "two", "use", "using",
    "can't", "don't", "i'm", "i'd", "we're", "it", "me", "my", "we", "us", "to", "of", "in", "on",
    "at", "by", "an", "is", "be", "do", "so", "if", "or", "up",
];

/// A prompt's content words: lower-cased, at least three letters, no stop words, numbers,
/// versions or paths, a plural's `s` dropped, each once, in order.
pub fn intent(prompt: &str) -> Vec<String> {
    let text: String = prompt.chars().take(600).collect::<String>().to_lowercase();
    let mut seen = HashSet::new();
    text.split(|c: char| !(c.is_alphanumeric() || c == '\'' || c == '-'))
        .map(|w| w.trim_matches(|c: char| c == '\'' || c == '-'))
        .filter(|w| w.chars().count() >= 3 && !STOP.contains(w))
        .filter(|w| w.chars().any(char::is_alphabetic))
        .filter(|w| !w.chars().any(|c| c.is_ascii_digit()))
        .map(stem)
        .filter(|w| seen.insert(w.clone()))
        .take(MAX_INTENT_WORDS)
        .collect()
}

/// A word without its plural or tense ending, so "tests" and "test", "fixed" and "fix" meet.
fn stem(word: &str) -> String {
    for (end, min) in [("ing", 6), ("ed", 5), ("es", 5), ("s", 4)] {
        if word.len() >= min && word.ends_with(end) && !word.ends_with("ss") {
            return word.strip_suffix(end).unwrap_or(word).to_owned();
        }
    }
    word.to_owned()
}

/// What one tool call is as a step: a shell call is its program and, for a program with
/// subcommands, the first one (`cargo test`, `gh pr`, `git commit`); any other call its kind
/// (`edit`, `read`, `search`, `fetch`). None for a call that is no step (thinking, a plan).
pub fn step_of(update: &Value) -> Option<String> {
    let kind = update.get("kind").and_then(Value::as_str).unwrap_or("other");
    match kind {
        "execute" => command_of(update).map(|c| command_step(&c)).filter(|s| !s.is_empty()),
        "edit" | "delete" | "move" => Some("edit".into()),
        "read" | "search" | "fetch" => Some(kind.into()),
        _ => None,
    }
}

/// A shell call's command: `rawInput.command`, a script or an argv (`["bash", "-lc", "x"]` is
/// its script).
pub fn command_of(update: &Value) -> Option<String> {
    let command = match update.pointer("/rawInput/command")? {
        Value::String(script) => script.clone(),
        Value::Array(argv) => {
            let words: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            match words.as_slice() {
                [shell, flag, script, ..]
                    if shell.ends_with("sh") && (flag.starts_with('-') && flag.contains('c')) =>
                {
                    (*script).to_owned()
                }
                _ => words.join(" "),
            }
        }
        _ => return None,
    };
    let line = command.lines().map(str::trim).find(|l| !l.is_empty())?.to_owned();
    Some(line)
}

/// Programs whose first word is a subcommand that says what ran.
const WITH_SUBCOMMAND: &[&str] = &[
    "cargo",
    "git",
    "gh",
    "npm",
    "pnpm",
    "yarn",
    "bun",
    "bunx",
    "npx",
    "go",
    "make",
    "docker",
    "kubectl",
    "swift",
    "xcodebuild",
    "uv",
    "pip",
    "poetry",
    "mix",
    "dotnet",
    "gradle",
    "mvn",
    "terraform",
    "helm",
    "brew",
    "cmux",
    "acpmux",
    "cmux-ci",
    "glaeda-gh",
    "wt",
    "lane-gh",
    "vp",
    "deno",
    "rails",
    "bundle",
    "rake",
    "python",
    "python3",
];

/// The step a command line is: its last `&&`/`;` part that is not a `cd`, without env settings,
/// `sudo` or a path; its program and, where it has one, its subcommand.
fn command_step(line: &str) -> String {
    let part = line
        .split("&&")
        .flat_map(|p| p.split(';'))
        .map(|p| p.split('|').next().unwrap_or("").trim())
        .find(|p| !p.is_empty() && !p.starts_with("cd ") && *p != "cd")
        .unwrap_or("");
    let mut words = part.split_whitespace().skip_while(|w| {
        w.contains('=') && !w.starts_with('-') || matches!(*w, "sudo" | "env" | "time" | "exec")
    });
    let Some(program) = words.next() else { return String::new() };
    let program = program.rsplit('/').next().unwrap_or(program).trim_matches(['"', '\'']);
    if !WITH_SUBCOMMAND.contains(&program) {
        return program.to_owned();
    }
    match words.find(|w| !w.starts_with(['-', '+'])) {
        Some(sub) if sub.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == ':') => {
            format!("{program} {sub}")
        }
        _ => program.to_owned(),
    }
}

/// Whether a command looks like it carries a secret: never kept.
fn secretish(command: &str) -> bool {
    let lower = command.to_lowercase();
    [
        "token",
        "password",
        "passwd",
        "secret",
        "bearer",
        "api_key",
        "api-key",
        "apikey",
        "authorization",
        "credential",
        "private_key",
    ]
    .iter()
    .any(|w| lower.contains(w))
        || command.split_whitespace().any(|w| keyish(w) || (w.contains(':') && w.contains('@')))
}

/// A word that looks like a key or token itself: a known prefix (`ghp_`, `sk-`, `xoxb-`) or a
/// long run of letters and digits with both in it.
fn keyish(word: &str) -> bool {
    let word = word.trim_matches(|c: char| !c.is_ascii_alphanumeric());
    const PREFIXES: &[&str] =
        &["ghp_", "gho_", "ghs_", "github_pat_", "sk-", "sk_", "xox", "akia", "glpat-", "aiza"];
    let lower = word.to_lowercase();
    if PREFIXES.iter().any(|p| lower.starts_with(p)) && word.len() >= 12 {
        return true;
    }
    word.len() >= 24
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '+' | '/' | '='))
        && word.chars().any(|c| c.is_ascii_digit())
        && word.chars().any(|c| c.is_ascii_alphabetic())
}

/// `text` with every key-like word ([`keyish`]) cut out.
fn redact(text: &str) -> String {
    text.split(' ').map(|w| if keyish(w) { "…" } else { w }).collect::<Vec<_>>().join(" ")
}

/// A chat's live turn: its person prompt and its tool runs since the last turn end.
#[derive(Debug, Default)]
pub struct Turn {
    pub prompt: Option<String>,
    pub steps: Vec<String>,
    pub commands: Vec<String>,
    /// Tool calls already counted, by id: an update of one is not a new step.
    seen: HashSet<String>,
    /// Shell calls whose command has not come yet, by id: a later update carries it.
    waiting: HashSet<String>,
}

impl Turn {
    /// The person's prompt; the first one of the turn is kept.
    pub fn prompt(&mut self, text: &str) {
        if self.prompt.is_none() && !text.trim().is_empty() {
            self.prompt = Some(text.trim().to_owned());
        }
    }

    /// A live `session/update` of the chat's own thread.
    pub fn observe(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if self.seen.contains(id) {
            return;
        }
        // The call's kind comes with its first update; a shell call's command with that one or a
        // later one.
        let kind = update.get("kind").and_then(Value::as_str);
        let step = match kind {
            Some("execute") => None,
            Some(_) => step_of(update),
            None if self.waiting.contains(id) => None,
            None => return,
        };
        let shell = kind == Some("execute") || (kind.is_none() && self.waiting.contains(id));
        let command = if shell { command_of(update) } else { None };
        let step = match (step, &command) {
            (Some(step), _) => step,
            (None, Some(command)) => command_step(command),
            (None, None) => {
                if shell {
                    self.waiting.insert(id.to_owned());
                }
                return;
            }
        };
        self.waiting.remove(id);
        self.seen.insert(id.to_owned());
        if step.is_empty() {
            return;
        }
        if self.steps.len() < MAX_STEPS && self.steps.last() != Some(&step) {
            self.steps.push(step);
        }
        if let Some(command) = command.filter(|c| !secretish(c)) {
            let command: String = command.chars().take(MAX_COMMAND_CHARS).collect();
            if self.commands.len() < MAX_COMMANDS && !self.commands.contains(&command) {
                self.commands.push(command);
            }
        }
    }
}

/// How much two word sets share, over the smaller one.
fn overlap(a: &[String], b: &[String]) -> (usize, f64) {
    if a.is_empty() || b.is_empty() {
        return (0, 0.0);
    }
    let b: HashSet<&String> = b.iter().collect();
    let shared = a.iter().filter(|w| b.contains(w)).count();
    #[allow(clippy::cast_precision_loss)]
    let ratio = shared as f64 / a.len().min(b.len()) as f64;
    (shared, ratio)
}

/// Shared over all distinct, of two step lists.
fn jaccard(a: &[String], b: &[String]) -> f64 {
    let a: HashSet<&String> = a.iter().collect();
    let b: HashSet<&String> = b.iter().collect();
    let all = a.union(&b).count();
    if all == 0 {
        return 0.0;
    }
    #[allow(clippy::cast_precision_loss)]
    let ratio = a.intersection(&b).count() as f64 / all as f64;
    ratio
}

/// Whether two tasks are the same kind: they asked with at least two of the same words, half
/// of the shorter ask's, and ran mostly the same steps (half of all the steps either ran, and
/// at least two each).
pub fn similar(
    a_intent: &[String],
    a_steps: &[String],
    b_intent: &[String],
    b_steps: &[String],
) -> bool {
    let (shared, ratio) = overlap(a_intent, b_intent);
    let distinct = |s: &[String]| s.iter().collect::<HashSet<_>>().len();
    shared >= 2
        && ratio >= 0.5
        && distinct(a_steps) >= 2
        && distinct(b_steps) >= 2
        && jaccard(a_steps, b_steps) >= 0.5
}

/// The words in every list, in the first one's order.
fn common(lists: &[&[String]]) -> Vec<String> {
    let Some((first, rest)) = lists.split_first() else { return Vec::new() };
    let rest: Vec<HashSet<&String>> = rest.iter().map(|l| l.iter().collect()).collect();
    first.iter().filter(|w| rest.iter().all(|r| r.contains(w))).cloned().collect()
}

/// A new pattern: the chats it is made of, and what it is offered as.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub offer_id: String,
    /// The chats, the one that ended last.
    pub chats: Vec<Shape>,
}

impl Record {
    /// `shape` as the chat's newest entry: its first prompt kept from before, its steps and
    /// commands added to the ones its earlier turns ran. A chat no person has asked anything
    /// (an agent's, a lane's) gets no entry.
    pub fn update(&mut self, mut shape: Shape) {
        let known = self.chats.iter().any(|c| c.session == shape.session);
        if !known && shape.prompt.is_empty() {
            return;
        }
        if let Some(at) = self.chats.iter().position(|c| c.session == shape.session) {
            let old = self.chats.remove(at);
            if !old.prompt.is_empty() {
                shape.prompt = old.prompt;
                shape.intent = old.intent;
            }
            let mut steps = old.steps;
            for step in shape.steps {
                if steps.len() < MAX_STEPS && steps.last() != Some(&step) {
                    steps.push(step);
                }
            }
            shape.steps = steps;
            let mut commands = old.commands;
            for command in shape.commands {
                if commands.len() < MAX_COMMANDS && !commands.contains(&command) {
                    commands.push(command);
                }
            }
            shape.commands = commands;
            shape.claimed |= old.claimed;
        }
        self.chats.push(shape);
        let over = self.chats.len().saturating_sub(MAX_CHATS);
        self.chats.drain(..over);
    }

    /// A pattern `session`'s chat makes now with [`PATTERN_SIZE`]` - 1` others that are not part
    /// of one yet, unless the folder has had it offered, saved or dismissed before; the chats
    /// it takes are claimed, and the pattern is kept as offered under `offer_id`.
    pub fn claim(&mut self, session: &str, offer_id: &str) -> Option<Found> {
        let me = self.chats.iter().find(|c| c.session == session && !c.claimed)?.clone();
        if me.intent.is_empty() {
            return None;
        }
        let mut chats: Vec<Shape> = self
            .chats
            .iter()
            .rev()
            .filter(|c| c.session != session && !c.claimed)
            .filter(|c| similar(&me.intent, &me.steps, &c.intent, &c.steps))
            .take(PATTERN_SIZE.saturating_sub(1))
            .cloned()
            .collect();
        if chats.len().saturating_add(1) < PATTERN_SIZE {
            return None;
        }
        chats.insert(0, me);
        let intents: Vec<&[String]> = chats.iter().map(|c| c.intent.as_slice()).collect();
        let steps: Vec<&[String]> = chats.iter().map(|c| c.steps.as_slice()).collect();
        let intent = common(&intents);
        let steps = common(&steps);
        // What the three share must say what the task is, or a later Not now could not hold it.
        if intent.len() < 2 || steps.iter().collect::<HashSet<_>>().len() < 2 {
            return None;
        }
        // Asked about before: offered once, saved or dismissed, it never comes back.
        // A pattern still with no draft is one whose drafting never finished (the daemon stopped
        // meanwhile): it holds nothing back.
        if self
            .patterns
            .iter()
            .filter(|p| p.state != "offered" || p.draft.is_some())
            .any(|p| similar(&p.intent, &p.steps, &intent, &steps))
        {
            return None;
        }
        let ids: HashSet<&str> = chats.iter().map(|c| c.session.as_str()).collect();
        for chat in &mut self.chats {
            if ids.contains(chat.session.as_str()) {
                chat.claimed = true;
            }
        }
        self.patterns.push(Pattern {
            offer_id: offer_id.to_owned(),
            intent,
            steps,
            state: "offered".into(),
            draft: None,
        });
        let over = self.patterns.len().saturating_sub(MAX_PATTERNS);
        self.patterns.drain(..over);
        Some(Found { offer_id: offer_id.to_owned(), chats })
    }

    pub fn pattern_mut(&mut self, offer_id: &str) -> Option<&mut Pattern> {
        self.patterns.iter_mut().find(|p| p.offer_id == offer_id)
    }
}

/// The folder records, one JSON file per project folder under `dir`.
#[derive(Debug, Clone)]
pub struct Records {
    dir: PathBuf,
}

/// One record read, changed and written at a time.
static WRITING: Mutex<()> = Mutex::new(());

impl Records {
    pub fn at(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn path(&self, cwd: &Path) -> PathBuf {
        use sha2::Digest as _;
        let hash = sha2::Sha256::digest(cwd.to_string_lossy().as_bytes());
        let name: String = hash.iter().take(12).map(|b| format!("{b:02x}")).collect();
        self.dir.join(format!("{name}.json"))
    }

    /// `cwd`'s record, empty when it has none or it cannot be read.
    pub fn load(&self, cwd: &Path) -> Record {
        std::fs::read(self.path(cwd))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    /// Runs `change` on `cwd`'s record and writes it back whole; its answer.
    pub fn change<T>(&self, cwd: &Path, change: impl FnOnce(&mut Record) -> T) -> T {
        let _one = WRITING.lock().unwrap_or_else(|e| e.into_inner());
        let mut record = self.load(cwd);
        let out = change(&mut record);
        let path = self.path(cwd);
        if let Ok(bytes) = serde_json::to_vec(&record) {
            let _ = std::fs::create_dir_all(&self.dir);
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
        out
    }
}

/// The headless prompt that asks the chat's harness for the skill, from the pattern's chats.
pub fn draft_prompt(chats: &[Shape]) -> String {
    let mut out = String::from(
        "Several chats in one project did the same kind of task. Write a reusable agent skill \
         for it: what to do, step by step, and the commands it runs. Answer in exactly this form \
         and nothing else:\n\
         name: <lowercase-words-with-dashes, at most 40 characters>\n\
         description: <one line: when an agent should use this skill>\n\
         steps:\n\
         1. <one step>\n\
         commands:\n\
         - <one shell command, as run>\n",
    );
    for (n, chat) in chats.iter().enumerate() {
        let mut part = format!(
            "\nChat {}, asked: \"{}\"\nIts tool runs: {}\n",
            n.saturating_add(1),
            chat.prompt.replace('"', "'"),
            chat.steps.join(", ")
        );
        if !chat.commands.is_empty() {
            part.push_str("Its commands:\n");
            for command in &chat.commands {
                part.push_str("- ");
                part.push_str(command);
                part.push('\n');
            }
        }
        if out.len().saturating_add(part.len()) > crate::complete::MAX_PROMPT_BYTES {
            break;
        }
        out.push_str(&part);
    }
    out
}

/// A skill name from any text: lower-case words joined with `-`, at most 40 characters.
pub fn skill_name(text: &str) -> String {
    let mut name = String::new();
    for c in text.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            name.push(c);
        } else if !name.is_empty() && !name.ends_with('-') {
            name.push('-');
        }
        if name.len() >= 40 {
            break;
        }
    }
    name.trim_matches('-').to_owned()
}

/// Whether `name` is one Claude Code takes as a skill's (`agent_guidance::valid_name`).
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('-')
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// One line, cut to `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    line.chars().take(max).collect()
}

/// The body of a skill from its steps and commands.
fn body(steps: &[String], commands: &[String]) -> String {
    let mut out = String::from("## Steps\n\n");
    for (n, step) in steps.iter().enumerate() {
        out.push_str(&format!("{}. {step}\n", n.saturating_add(1)));
    }
    if !commands.is_empty() {
        out.push_str("\n## Commands\n\n```sh\n");
        for command in commands {
            out.push_str(command);
            out.push('\n');
        }
        out.push_str("```\n");
    }
    out
}

/// The skill in a harness's answer to [`draft_prompt`]; None when it has no name or no steps.
pub fn parse_draft(answer: &str) -> Option<Draft> {
    let (mut name, mut description) = (String::new(), String::new());
    let (mut steps, mut commands) = (Vec::new(), Vec::new());
    let mut list = "";
    for line in answer.lines() {
        let line = line.trim().trim_matches('*').trim();
        let lower = line.to_lowercase();
        if let Some(v) = lower.strip_prefix("name:") {
            name = skill_name(v);
            list = "";
        } else if lower.starts_with("description:") {
            let value = line.get("description:".len()..).unwrap_or("").trim();
            description = redact(&one_line(value, MAX_DESCRIPTION));
            list = "";
        } else if lower.starts_with("steps:") {
            list = "steps";
        } else if lower.starts_with("commands:") {
            list = "commands";
        } else if !line.is_empty() && !line.starts_with("```") {
            let item = line
                .trim_start_matches(|c: char| c.is_ascii_digit())
                .trim_start_matches(['.', ')', '-', '*', '•'])
                .trim();
            if item.is_empty() {
                continue;
            }
            match list {
                "steps" if steps.len() < 12 => steps.push(redact(&one_line(item, 200))),
                "commands" if commands.len() < MAX_COMMANDS => {
                    let item = item.trim_matches('`');
                    if !item.is_empty() && !secretish(item) {
                        commands.push(one_line(item, MAX_COMMAND_CHARS));
                    }
                }
                _ => {}
            }
        }
    }
    if !valid_name(&name) || steps.is_empty() {
        return None;
    }
    if description.is_empty() {
        description = format!("Use for {}.", name.replace('-', " "));
    }
    Some(Draft { name, description, body: body(&steps, &commands), drafted: "harness".into() })
}

/// What a step reads as in a drafted skill.
fn step_text(step: &str) -> String {
    match step {
        "edit" => "Edit the files the task needs".into(),
        "read" => "Read the relevant files".into(),
        "search" => "Search the code for what the task touches".into(),
        "fetch" => "Fetch the pages or data the task needs".into(),
        command => format!("Run `{command}`"),
    }
}

/// A draft from the shapes alone, for a chat whose harness cannot answer: named by the words
/// every chat asked with, its steps the ones every chat ran in the newest chat's order, its
/// commands the ones two chats or more ran.
pub fn shapes_draft(chats: &[Shape]) -> Draft {
    let intents: Vec<&[String]> = chats.iter().map(|c| c.intent.as_slice()).collect();
    let words = common(&intents);
    let name = skill_name(&words.iter().take(3).cloned().collect::<Vec<_>>().join(" "));
    let name = if valid_name(&name) { name } else { "repeated-task".into() };
    let ask = chats
        .iter()
        .map(|c| c.prompt.as_str())
        .filter(|p| !p.is_empty())
        .min_by_key(|p| p.len())
        .unwrap_or("");
    let ask = one_line(ask, 200);
    let description = if ask.is_empty() {
        format!("Use for {}.", name.replace('-', " "))
    } else {
        one_line(&format!("Use when asked to do what this asked: \"{ask}\""), MAX_DESCRIPTION)
    };
    let all_steps: Vec<&[String]> = chats.iter().map(|c| c.steps.as_slice()).collect();
    let mut steps: Vec<String> = Vec::new();
    for step in common(&all_steps) {
        if !steps.contains(&step) {
            steps.push(step);
        }
    }
    let mut counts: HashMap<&String, usize> = HashMap::new();
    for chat in chats {
        for command in &chat.commands {
            let count = counts.entry(command).or_default();
            *count = count.saturating_add(1);
        }
    }
    let commands: Vec<String> = chats
        .first()
        .map(|c| {
            c.commands
                .iter()
                .filter(|cmd| counts.get(cmd).copied().unwrap_or(0) >= 2)
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let steps: Vec<String> = steps.iter().map(|s| step_text(s)).collect();
    Draft { name, description, body: body(&steps, &commands), drafted: "shapes".into() }
}

/// The whole `SKILL.md` of a skill.
pub fn skill_file(name: &str, description: &str, body: &str) -> String {
    let description = description.replace('\\', "/").replace('"', "'");
    format!("---\nname: {name}\ndescription: \"{description}\"\n---\n\n{}\n", body.trim_end())
}

/// Checks a skill the person saves: a valid name, a one-line description, a body that fits.
pub fn check_skill(name: &str, description: &str, body: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err("a skill's name is lowercase letters, digits and dashes, at most 64".into());
    }
    let description = description.trim();
    if description.is_empty()
        || description.contains(['\n', '\r'])
        || description.chars().count() > MAX_DESCRIPTION
    {
        return Err(format!(
            "a skill's description is one line of at most {MAX_DESCRIPTION} characters"
        ));
    }
    if body.trim().is_empty() || body.len() > MAX_BODY {
        return Err(format!("a skill's steps are 1 to {MAX_BODY} bytes"));
    }
    Ok(())
}

/// Writes skill `name` into `dir` (made when missing) as `name/SKILL.md`; the file's path. A
/// skill of that name already there is never replaced, and nothing is written through a link.
pub fn write_skill(
    dir: &Path,
    name: &str,
    description: &str,
    body: &str,
) -> Result<PathBuf, String> {
    check_skill(name, description, body)?;
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
    // The folder itself may be a link (into a dotfiles repository); the skill's own folder and
    // file are made new, so neither is ever one.
    let skill_dir = dir.join(name);
    match std::fs::create_dir(&skill_dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(format!("a skill named {name} already exists"));
        }
        Err(e) => return Err(format!("cannot make {}: {e}", skill_dir.display())),
    }
    let path = skill_dir.join("SKILL.md");
    let written = std::fs::OpenOptions::new().write(true).create_new(true).open(&path).and_then(
        |mut file| {
            use std::io::Write as _;
            file.write_all(skill_file(name, description.trim(), body).as_bytes())
        },
    );
    if let Err(e) = written {
        // The folder this made, and what part of the file got written, go: a retry starts clean.
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&skill_dir);
        return Err(format!("cannot write {}: {e}", path.display()));
    }
    Ok(path)
}

static TURNS: LazyLock<Mutex<HashMap<String, Turn>>> = LazyLock::new(Default::default);

/// [`Turn::prompt`] for `session`'s person prompt.
pub fn note_prompt(session: &str, text: &str) {
    TURNS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(session.to_owned())
        .or_default()
        .prompt(text);
}

/// [`Turn::observe`] for `session`.
pub fn observe(session: &str, update: &Value) {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return;
    }
    TURNS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(session.to_owned())
        .or_default()
        .observe(update);
}

/// `session`'s turn as a shape, and a clean slate for the next turn.
pub fn take(session: &str) -> Shape {
    let turn = TURNS.lock().unwrap_or_else(|e| e.into_inner()).remove(session).unwrap_or_default();
    let prompt = turn.prompt.unwrap_or_default();
    Shape {
        session: session.to_owned(),
        intent: intent(&prompt),
        prompt: redact(&one_line(&prompt, MAX_PROMPT_CHARS)),
        steps: turn.steps,
        commands: turn.commands,
        claimed: false,
    }
}

#[cfg(test)]
#[path = "skill_distill_tests.rs"]
mod tests;
