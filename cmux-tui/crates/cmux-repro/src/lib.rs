//! Repro capsules (cmuxterm-hq#23808).
//!
//! A capsule is one failing command written down so another machine can run it again: the
//! repository and the base commit it ran on, the local diff on top of that commit, the command and
//! its directory, the lockfile and tool fingerprint, and the failure's signature (the normalized
//! lines that say what broke). A fresh machine replays it ([`script::runner`]) and the output is
//! judged against the signature ([`judge`]): `reproduced` (red), `passed` (green), `failed
//! differently`, or `missing prerequisite` with the prerequisite named. The same probe then runs
//! with a candidate fix applied, and the pair of verdicts is the repair's receipt ([`Receipt`]).
//!
//! The capsule is a local JSON file. Nothing here uploads it. Before it is written, every string in
//! it goes through the caller's masker (the CLI passes acpmux's `secret_scan::mask`) and has every
//! secret value the caller names replaced ([`Capsule::scrub`]); [`Capsule::leaks`] then reads the
//! serialized bytes back and refuses the capsule if any of those values is still there (the secret
//! canary). Captured output is untrusted: it is data in the manifest and never runs.

pub mod create;
pub mod script;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// The manifest's version. A reader refuses a capsule with a newer schema.
pub const SCHEMA: u32 = 1;
/// The output kept in the manifest: its last this many bytes.
pub const OUTPUT_TAIL_BYTES: usize = 8 * 1024;
/// At most this many lines make a derived signature.
pub const SIGNATURE_LINES: usize = 4;
/// What a removed or masked value becomes.
pub const REDACTED: &str = "[REDACTED]";
/// The runner script's marker lines (stdout), read by [`judge`].
pub const EXIT_MARKER: &str = "CAPSULE-EXIT: ";
pub const PREREQ_MARKER: &str = "CAPSULE-PREREQ-MISSING: ";
/// The replay checkout's absolute path, so [`judge`] can write it `<ROOT>`.
pub const ROOT_MARKER: &str = "CAPSULE-ROOT: ";
pub const DRIFT_MARKER: &str = "CAPSULE-FINGERPRINT-DIFFERS: ";
/// The runner's exit status when a prerequisite is absent (the command never ran).
pub const PREREQ_EXIT: i32 = 97;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capsule {
    pub schema: u32,
    /// The first 16 hex digits of the SHA-256 of the manifest without this field.
    pub id: String,
    pub created_at: String,
    pub title: String,
    /// The cmux that made it (`cmux-tui 1.0.0`).
    pub made_by: String,
    pub repo: Repo,
    /// `git diff --binary BASE` plus the untracked files, as one patch; empty when the tree was clean.
    pub diff: String,
    /// The files the diff touches, for `cmux repro drop diff:PATH`.
    pub diff_files: Vec<String>,
    pub command: Command,
    /// Runs in the checkout before the command (installs, a build step); its failure is a missing
    /// prerequisite, not the bug.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub setup: String,
    #[serde(default)]
    pub prerequisites: Vec<Prerequisite>,
    pub expected: Expected,
    pub observed: Observed,
    #[serde(default)]
    pub fingerprint: Fingerprint,
    /// What the person took out before sharing (`diff:PATH`, `output`, `env:NAME`, ...).
    #[serde(default)]
    pub removed: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Repo {
    /// A fetchable URL with no credentials in it (an https GitHub URL for a GitHub remote).
    pub url: String,
    pub base_sha: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Command {
    /// One shell line, run with `bash -c`.
    pub shell: String,
    /// Relative to the repository root; empty for the root.
    #[serde(default)]
    pub cwd: String,
    pub timeout_s: u64,
    /// Only the variables the person named (`--env NAME`), after scrubbing.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prerequisite {
    pub name: String,
    /// A shell check that exits 0 when the prerequisite is there (`command -v cargo`).
    pub check: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Expected {
    /// The exit status that counts as the failure; `None` means any non-zero status.
    pub exit_code: Option<i32>,
    /// Normalized lines ([`normalize`]) that must all appear in the run's normalized output.
    pub signature: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Observed {
    pub exit_code: i32,
    pub duration_ms: u64,
    /// The last [`OUTPUT_TAIL_BYTES`] of stdout and stderr together, scrubbed.
    pub output_tail: String,
    pub os: String,
    pub arch: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fingerprint {
    /// Lockfiles and manifests, path relative to the repository root, to their SHA-256.
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    /// Tool name to the first line of its `--version`.
    #[serde(default)]
    pub tools: BTreeMap<String, String>,
}

/// A replay's verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "verdict", rename_all = "snake_case")]
pub enum Verdict {
    /// The expected exit status and every signature line: red.
    Reproduced,
    /// Exit 0 and none of the signature: green.
    Passed,
    /// It failed, but not the way the capsule says.
    FailedDifferently { exit_code: i32, missing: Vec<String> },
    /// The command never ran: these prerequisites were absent.
    MissingPrerequisite { missing: Vec<String> },
    /// The runner wrote no exit marker (killed, timed out at the transport).
    NoAnswer,
}

impl Verdict {
    pub fn word(&self) -> &'static str {
        match self {
            Verdict::Reproduced => "red (reproduced)",
            Verdict::Passed => "green (passed)",
            Verdict::FailedDifferently { .. } => "failed differently",
            Verdict::MissingPrerequisite { .. } => "missing prerequisite",
            Verdict::NoAnswer => "no answer",
        }
    }
}

/// One replay: where it ran, what ran, and the verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Run {
    /// `original` or `candidate`.
    pub phase: String,
    /// `local fresh checkout`, or the Cloud machine id and backend.
    pub place: String,
    /// The candidate patch's SHA-256 (empty for the original).
    #[serde(default)]
    pub candidate_sha256: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
    #[serde(flatten)]
    pub verdict: Verdict,
    /// Fingerprint entries that differ on the replaying machine.
    #[serde(default)]
    pub drift: Vec<String>,
    pub output_tail: String,
}

/// The repair's receipt: the same probe, red on the original and green with the candidate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    pub schema: u32,
    pub capsule_id: String,
    pub repo: Repo,
    pub command: String,
    pub runs: Vec<Run>,
    /// True only when the original reproduced and the candidate passed.
    pub repair_verified: bool,
}

impl Receipt {
    pub fn new(capsule: &Capsule, runs: Vec<Run>) -> Self {
        let original = runs.iter().find(|r| r.phase == "original");
        let candidate = runs.iter().find(|r| r.phase == "candidate");
        let repair_verified = matches!(original.map(|r| &r.verdict), Some(Verdict::Reproduced))
            && matches!(candidate.map(|r| &r.verdict), Some(Verdict::Passed));
        Receipt {
            schema: SCHEMA,
            capsule_id: capsule.id.clone(),
            repo: capsule.repo.clone(),
            command: capsule.command.shell.clone(),
            runs,
            repair_verified,
        }
    }
}

impl Capsule {
    /// Reads a capsule, refusing one from a newer cmux.
    pub fn from_json(text: &str) -> Result<Self, String> {
        let capsule: Capsule =
            serde_json::from_str(text).map_err(|e| format!("not a repro capsule: {e}"))?;
        if capsule.schema > SCHEMA {
            return Err(format!(
                "capsule schema {} is newer than this cmux reads ({SCHEMA}); read it with the `cmux repro` that wrote it",
                capsule.schema
            ));
        }
        Ok(capsule)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_default() + "\n"
    }

    /// Sets `id` from the rest of the manifest.
    pub fn seal(&mut self) {
        self.id.clear();
        let digest = Sha256::digest(serde_json::to_vec(self).unwrap_or_default());
        self.id = hex(&digest).chars().take(16).collect();
    }

    /// Masks every free-text field with `mask` and replaces each of `secrets` (exact values) with
    /// [`REDACTED`]. Values shorter than 6 bytes are skipped: they are not credentials and would
    /// shred ordinary text.
    pub fn scrub(&mut self, secrets: &[String], mask: &dyn Fn(&str) -> String) {
        let secrets: Vec<&str> =
            secrets.iter().map(String::as_str).filter(|s| s.len() >= 6).collect();
        let clean = |text: &str| -> String {
            let mut out = mask(text);
            for secret in &secrets {
                if out.contains(secret) {
                    out = out.replace(secret, REDACTED);
                }
            }
            out
        };
        self.title = clean(&self.title);
        self.diff = clean(&self.diff);
        self.command.shell = clean(&self.command.shell);
        self.setup = clean(&self.setup);
        for value in self.command.env.values_mut() {
            *value = clean(value);
        }
        for p in &mut self.prerequisites {
            p.check = clean(&p.check);
        }
        for line in &mut self.expected.signature {
            *line = clean(line);
        }
        self.observed.output_tail = clean(&self.observed.output_tail);
        self.repo.url = strip_url_credentials(&self.repo.url);
    }

    /// The secrets (by their position in `secrets`) still present anywhere in the serialized
    /// capsule, including JSON-escaped forms. Empty means the canary check passed.
    pub fn leaks(&self, secrets: &[String]) -> Vec<usize> {
        let bytes = serde_json::to_string(self).unwrap_or_default();
        secrets
            .iter()
            .enumerate()
            .filter(|(_, s)| s.len() >= 6)
            .filter(|(_, s)| {
                let escaped = serde_json::to_string(s).unwrap_or_default();
                let escaped = escaped.trim_matches('"');
                bytes.contains(s.as_str()) || bytes.contains(escaped)
            })
            .map(|(i, _)| i)
            .collect()
    }

    /// Takes one entry out before sharing: `diff` (all of it), `diff:PATH`, `output`, `env:NAME`,
    /// `fingerprint`, `setup`. Returns false when there was no such entry.
    pub fn drop_entry(&mut self, entry: &str) -> bool {
        let done = match entry.split_once(':') {
            Some(("diff", path)) => {
                let before = self.diff.len();
                self.diff = drop_patch_file(&self.diff, path);
                self.diff_files.retain(|f| f != path);
                self.diff.len() != before
            }
            Some(("env", name)) => self.command.env.remove(name).is_some(),
            None if entry == "diff" => {
                let had = !self.diff.is_empty();
                self.diff.clear();
                self.diff_files.clear();
                had
            }
            None if entry == "output" => {
                let had = !self.observed.output_tail.is_empty();
                self.observed.output_tail.clear();
                had
            }
            None if entry == "fingerprint" => {
                let had = !self.fingerprint.files.is_empty() || !self.fingerprint.tools.is_empty();
                self.fingerprint = Fingerprint::default();
                had
            }
            None if entry == "setup" => {
                let had = !self.setup.is_empty();
                self.setup.clear();
                had
            }
            _ => false,
        };
        if done {
            self.removed.push(entry.to_owned());
            self.seal();
        }
        done
    }
}

/// Judges a replay's output (the runner script's stdout and stderr together).
pub fn judge(capsule: &Capsule, output: &str) -> (Option<i32>, Verdict, Vec<String>) {
    let mut exit = None;
    let mut missing_prereqs = Vec::new();
    let mut drift = Vec::new();
    let mut root = None;
    for line in output.lines() {
        if let Some(path) = line.strip_prefix(ROOT_MARKER) {
            root = Some(path.trim().to_owned());
        } else if let Some(code) = line.strip_prefix(EXIT_MARKER) {
            exit = code.trim().parse::<i32>().ok();
        } else if let Some(name) = line.strip_prefix(PREREQ_MARKER) {
            missing_prereqs.push(name.trim().to_owned());
        } else if let Some(entry) = line.strip_prefix(DRIFT_MARKER) {
            drift.push(entry.trim().to_owned());
        }
    }
    if !missing_prereqs.is_empty() {
        return (exit, Verdict::MissingPrerequisite { missing: missing_prereqs }, drift);
    }
    let Some(code) = exit else { return (None, Verdict::NoAnswer, drift) };
    let normalized = normalize(output, root.as_deref());
    let missing: Vec<String> = capsule
        .expected
        .signature
        .iter()
        .filter(|line| !normalized.contains(line.as_str()))
        .cloned()
        .collect();
    let exit_matches = match capsule.expected.exit_code {
        Some(expected) => code == expected,
        None => code != 0,
    };
    let verdict = if exit_matches && missing.is_empty() {
        Verdict::Reproduced
    } else if code == 0 && missing.len() == capsule.expected.signature.len() {
        Verdict::Passed
    } else {
        // Includes exit 0 with part of the failure's text still printed: not a clean pass.
        Verdict::FailedDifferently { exit_code: code, missing }
    };
    (Some(code), verdict, drift)
}

/// Normalizes output so a replay on another machine compares equal: no ANSI escapes, no
/// durations, addresses or thread ids, the checkout's absolute path (`root`) written `<ROOT>`, and
/// whitespace collapsed.
pub fn normalize(text: &str, root: Option<&str>) -> String {
    let text = strip_ansi(text);
    let text = match root.map(|r| r.trim_end_matches('/')).filter(|r| r.len() > 1) {
        Some(root) => text.replace(root, "<ROOT>"),
        None => text,
    };
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        let line = normalize_line(line);
        if !line.is_empty() {
            out.push_str(&line);
            out.push('\n');
        }
    }
    out
}

fn normalize_line(line: &str) -> String {
    let words: Vec<String> = line.split_whitespace().map(normalize_word).collect();
    words.join(" ")
}

fn normalize_word(word: &str) -> String {
    let trimmed = word.trim_matches(|c: char| "()[],;".contains(c));
    let is_hex = trimmed.len() > 4
        && trimmed.strip_prefix("0x").is_some_and(|hex| hex.chars().all(|c| c.is_ascii_hexdigit()));
    if is_hex {
        return word.replace(trimmed, "<HEX>");
    }
    if is_duration(trimmed) {
        return word.replace(trimmed, "<T>");
    }
    if let Some(id) = trimmed.strip_prefix("ThreadId(")
        && id.trim_end_matches(')').chars().all(|c| c.is_ascii_digit())
    {
        return word.replace(trimmed, "ThreadId(<N>");
    }
    word.to_owned()
}

fn is_duration(word: &str) -> bool {
    for unit in ["ms", "µs", "us", "ns", "s", "m"] {
        if let Some(number) = word.strip_suffix(unit)
            && !number.is_empty()
            && number.chars().all(|c| c.is_ascii_digit() || c == '.')
            && number.chars().next().is_some_and(|c| c.is_ascii_digit())
            && (unit != "m" && unit != "s" || number.contains('.'))
        {
            return true;
        }
    }
    false
}

fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for d in chars.by_ref() {
                    if d.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        if c != '\r' {
            out.push(c);
        }
    }
    out
}

/// The failure lines of `output`, normalized: Rust panics and test failures, compiler errors,
/// assertion and exception lines. Falls back to the last non-empty line.
pub fn derive_signature(output: &str, root: Option<&str>) -> Vec<String> {
    const MARKS: &[&str] = &[
        "panicked at",
        "assertion",
        "error[E",
        "error:",
        "Error:",
        "FAILED",
        "FAIL ",
        "AssertionError",
        "Traceback",
        "Exception",
        "failures:",
        "---- ",
    ];
    let normalized = normalize(output, root);
    let mut lines: Vec<String> = Vec::new();
    for line in normalized.lines() {
        if line.starts_with("CAPSULE-") {
            continue;
        }
        if MARKS.iter().any(|m| line.contains(m)) && !lines.iter().any(|l| l == line) {
            // A panic line names the test thread; the message after it is the signature.
            let line = match line.find("panicked at ") {
                Some(at) => line.get(at..).unwrap_or(line).to_owned(),
                None => line.to_owned(),
            };
            lines.push(line.chars().take(240).collect());
            if lines.len() == SIGNATURE_LINES {
                break;
            }
        }
    }
    if lines.is_empty()
        && let Some(last) = normalized.lines().rev().find(|l| !l.starts_with("CAPSULE-"))
    {
        lines.push(last.chars().take(240).collect());
    }
    lines
}

/// Environment variable names that look like they hold a credential.
pub fn secret_shaped_name(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    [
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "API_KEY",
        "APIKEY",
        "PRIVATE",
        "CREDENTIAL",
        "COOKIE",
        "SESSION",
        "AUTH",
        "_KEY",
    ]
    .iter()
    .any(|m| upper.contains(m))
}

/// The secret values to scrub and check for: every secret-shaped environment variable plus the
/// ones the person named with `--deny-env`.
pub fn secret_values<I: IntoIterator<Item = (String, String)>>(
    env: I,
    deny: &[String],
) -> Vec<String> {
    let mut values: Vec<String> = env
        .into_iter()
        .filter(|(name, value)| {
            (secret_shaped_name(name) || deny.iter().any(|d| d == name)) && value.len() >= 6
        })
        .map(|(_, value)| value)
        .collect();
    values.sort();
    values.dedup();
    // Longest first, so a secret that contains another is replaced whole.
    values.sort_by_key(|v| std::cmp::Reverse(v.len()));
    values
}

/// `https://user:token@github.com/o/r.git` and `git@github.com:o/r.git` become
/// `https://github.com/o/r.git`.
pub fn strip_url_credentials(url: &str) -> String {
    let url = url.trim();
    if let Some(rest) = url.strip_prefix("git@github.com:") {
        return format!("https://github.com/{rest}");
    }
    if let Some(rest) = url.strip_prefix("ssh://git@github.com/") {
        return format!("https://github.com/{rest}");
    }
    for scheme in ["https://", "http://"] {
        if let Some(rest) = url.strip_prefix(scheme) {
            let (host_part, path) = rest.split_once('/').unwrap_or((rest, ""));
            let host = host_part.rsplit_once('@').map(|(_, h)| h).unwrap_or(host_part);
            return format!("{scheme}{host}/{path}");
        }
    }
    url.to_owned()
}

/// Removes one file's section from a `git diff` patch.
pub fn drop_patch_file(patch: &str, path: &str) -> String {
    let mut out = String::with_capacity(patch.len());
    let mut skipping = false;
    for line in patch.split_inclusive('\n') {
        if let Some(header) = line.strip_prefix("diff --git ") {
            let target = format!(" b/{path}");
            skipping = header.trim_end().ends_with(&target);
        }
        if !skipping {
            out.push_str(line);
        }
    }
    out
}

/// The files a patch touches (its `diff --git a/X b/X` headers).
pub fn patch_files(patch: &str) -> Vec<String> {
    patch
        .lines()
        .filter_map(|l| l.strip_prefix("diff --git "))
        .filter_map(|h| h.rsplit_once(" b/").map(|(_, b)| b.to_owned()))
        .collect()
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The last `max` bytes of `text`, cut at a character boundary.
pub fn tail_bytes(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text.get(start..).unwrap_or_default().to_owned()
}

#[cfg(test)]
mod tests;

/// Now, as `2026-11-25T04:30:00Z` (no date crate for one timestamp).
pub fn now_rfc3339() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    rfc3339(secs)
}

/// Unix seconds as RFC 3339 UTC (Howard Hinnant's civil-from-days).
pub fn rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}
