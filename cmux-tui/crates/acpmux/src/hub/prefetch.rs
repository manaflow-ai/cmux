//! Harness magic: predictive prefetch. The files a prompt names (an absolute path, a path under
//! the session's folder or its git root, `path:line`, `path:line-line`, `path#L1-L9`, a
//! backticked path) are read by acpmux as the turn starts and appended to this one message as a
//! hidden context block (`prompt_context::is_context`), each labelled with its path, line range
//! and git blob hash, so the agent need not spend a request on a Read of it. The block goes
//! after everything else in the message: the system prompt and the earlier transcript, the
//! cached prefix, are untouched. Zero model tokens of its own; fails open (any error, a
//! timeout, nothing found: the prompt goes as it was).
//!
//! What is fetched follows what history says gets read: a person's or agent's prompt names a
//! file that is then read in the same turn 17% of the time overall, 24% on a session's first
//! prompt and 49% when a first prompt says "read"/"see"/"look at"/"follow" before the path
//! (`/home/cmux/harness-magic/tools/prefetch_hist.py` over 118 Claude transcripts, 517 named
//! files). A later prompt therefore fetches only a cued path or a `path:line`; the first fetches
//! every named file, cued ones first, within the budget.
//!
//! Skipped: binaries, files over [`MAX_READ_BYTES`], a whole file over the per-file budget (a
//! `path:line` still gets its window), secret-looking files (`.env*`, credentials, keys) and key
//! folders (`.ssh`, `.aws`, ...), and anything outside the session's folder, its git root and
//! the home folder.
//!
//! Measured per turn on `turn_result` as `harnessMagic.prefetch.*`: `files`, `tokens`,
//! `rereadAnyway` (read calls of a prefetched file in that turn), `neverRead` and
//! `estRequestsSaved`.
//!
//! Off: `agents.harnessMagic.prefetch.enabled: false` in the settings file, or
//! `ACPMUX_HM_PREFETCH=0` in the daemon's environment.

use std::collections::{BTreeMap, HashSet};
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value, json};

pub const SETTING_ENABLED: &str = "agents.harnessMagic.prefetch.enabled";
pub const ENV_KILL: &str = "ACPMUX_HM_PREFETCH";
/// About four characters a token.
const CHARS_PER_TOKEN: usize = 4;
/// The whole block's budget, in tokens.
pub const TOTAL_TOKENS: usize = 24_000;
/// One file's budget, in tokens.
pub const FILE_TOKENS: usize = 8_000;
/// Lines either side of a `path:line`.
pub const WINDOW: usize = 80;
/// A file larger than this is not read at all.
pub const MAX_READ_BYTES: u64 = 2 * 1024 * 1024;
/// The most distinct paths one prompt is looked through for.
const MAX_PATHS: usize = 32;
/// The longest prompt looked through.
const MAX_PROMPT_BYTES: usize = 256 * 1024;
/// Requests a prompt-named file cost the turn, historically: distinct model requests that read
/// a named file, over named files (124 / 519, `prefetch_hist.py`). A prefetched file that is
/// still read gives its share back.
pub const HIST_REQUESTS_PER_FILE: f64 = 0.239;

/// Whether prefetch runs: on unless the settings say `false` or the kill switch says `0`.
pub fn enabled_by(doc: Option<&Value>, env: Option<&str>) -> bool {
    if env.is_some_and(|v| matches!(v.trim(), "0" | "false" | "off" | "no")) {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(true)
}

fn enabled() -> bool {
    let env = std::env::var(ENV_KILL).ok();
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => enabled_by(Some(&doc), env.as_deref()),
        _ => enabled_by(None, env.as_deref()),
    }
}

/// One file reference a prompt makes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ref {
    pub path: String,
    /// 1-based, inclusive.
    pub lines: Option<(usize, usize)>,
    /// A read verb comes right before it ("read X", "see X").
    pub cued: bool,
}

fn is_separator(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '`' | '"' | '\'' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | ',' | ';' | '|'
        )
}

/// Splits `path:12`, `path:12-40`, `path:12:5`, `path#L12-L40` into the path and its lines.
fn split_lines(token: &str) -> (&str, Option<(usize, usize)>) {
    if let Some((path, frag)) = token.split_once("#L") {
        let mut parts = frag.splitn(2, '-');
        let a = parts.next().and_then(|a| a.parse::<usize>().ok());
        let b = parts.next().map(|b| b.trim_start_matches('L').parse::<usize>().ok());
        return match (a, b) {
            (Some(a), None) => (path, Some((a, a))),
            (Some(a), Some(Some(b))) => (path, Some((a.min(b), a.max(b)))),
            _ => (path, None),
        };
    }
    let mut path = token;
    let mut nums: Vec<&str> = Vec::new();
    // At most two `:N` tails (`:line:col`), read from the end.
    for _ in 0..2 {
        match path.rsplit_once(':') {
            Some((head, tail))
                if !head.is_empty()
                    && !tail.is_empty()
                    && tail.chars().all(|c| c.is_ascii_digit() || c == '-') =>
            {
                nums.push(tail);
                path = head;
            }
            _ => break,
        }
    }
    // `path:line:col` read back to front: the line is the last one found.
    let Some(line) = nums.last() else { return (token, None) };
    let mut it = line.splitn(2, '-');
    let a = it.next().and_then(|a| a.parse::<usize>().ok());
    let b = it.next().and_then(|b| b.parse::<usize>().ok());
    match (a, b) {
        (Some(a), Some(b)) => (path, Some((a.min(b), a.max(b)))),
        (Some(a), None) => (path, Some((a, a))),
        _ => (path, None),
    }
}

fn looks_like_path(p: &str) -> bool {
    if p.is_empty() || p.len() > 1024 || p.contains("://") || p.starts_with('-') {
        return false;
    }
    if p.contains(['*', '$', '=', '?', '\\']) {
        return false;
    }
    if p.contains('/') {
        return p.chars().any(|c| c.is_alphanumeric());
    }
    // A bare file name: `name.ext`, the extension short and plain.
    match p.rsplit_once('.') {
        Some((stem, ext)) => {
            // "e.g" is no file; "main.c" and "x.py" are.
            !stem.is_empty()
                && (1..=8).contains(&ext.len())
                && (ext.len() >= 2 || stem.chars().count() >= 2)
                && ext.chars().all(|c| c.is_ascii_alphanumeric())
                && ext.chars().any(|c| c.is_ascii_alphabetic())
        }
        None => false,
    }
}

fn cued_before(text: &str, at: usize) -> bool {
    let mut from = at.saturating_sub(40);
    while !text.is_char_boundary(from) {
        from -= 1;
    }
    let before = text.get(from..at).unwrap_or_default().to_lowercase();
    // Only this sentence's words cue: "Read a.md first. Then b.rs" does not cue b.rs.
    let before = [". ", "! ", "? ", "\n", "; "]
        .iter()
        .filter_map(|end| before.rfind(end).map(|i| i + end.len()))
        .max()
        .and_then(|i| before.get(i..))
        .unwrap_or(&before);
    before
        .split(|c: char| !c.is_alphanumeric())
        .any(|w| matches!(w, "read" | "see" | "follow" | "reading"))
        || before.contains("look at")
}

/// The file references in `text`, in order of appearance, one per distinct path and lines.
pub fn extract(text: &str) -> Vec<Ref> {
    let text = if text.len() > MAX_PROMPT_BYTES {
        let mut end = MAX_PROMPT_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.get(..end).unwrap_or_default()
    } else {
        text
    };
    let mut out: Vec<Ref> = Vec::new();
    let mut start = None;
    let push = |s: usize, e: usize, out: &mut Vec<Ref>| {
        let raw = text
            .get(s..e)
            .unwrap_or_default()
            .trim_start_matches('@')
            .trim_end_matches(['.', ',', ':', ';', '!', '?']);
        let (path, lines) = split_lines(raw);
        if !looks_like_path(path) {
            return;
        }
        let r = Ref { path: path.to_owned(), lines, cued: cued_before(text, s) };
        if let Some(seen) = out.iter_mut().find(|o| o.path == r.path && o.lines == r.lines) {
            seen.cued |= r.cued;
        } else {
            out.push(r);
        }
    };
    for (i, c) in text.char_indices() {
        if is_separator(c) {
            if let Some(s) = start.take() {
                push(s, i, &mut out);
            }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start {
        push(s, text.len(), &mut out);
    }
    out
}

/// The folder holding `.git` at or above `dir`.
pub fn git_root(dir: &Path) -> Option<PathBuf> {
    dir.ancestors().find(|d| d.join(".git").exists()).map(Path::to_path_buf)
}

const KEY_DIRS: &[&str] =
    &[".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store", ".git", ".acpmux"];

/// Whether `path` looks like it holds a secret, by its name or a folder it is in.
pub fn secret_looking(path: &Path) -> bool {
    let text = path.to_string_lossy().to_lowercase();
    if text.contains("/.config/gh/") || text.contains("/.config/gcloud/") {
        return true;
    }
    if path
        .components()
        .any(|c| matches!(c, Component::Normal(n) if KEY_DIRS.iter().any(|k| n == *k)))
    {
        return true;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    name.starts_with(".env")
        || name.ends_with(".env")
        || ["credential", "secret", "password", "passwd", "token", "apikey", "api_key", "private"]
            .iter()
            .any(|w| name.contains(w))
        || [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".kdbx", ".gpg", ".asc"]
            .iter()
            .any(|ext| name.ends_with(ext))
        || name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
        || name.starts_with("id_ecdsa")
        || matches!(
            name.as_str(),
            ".netrc"
                | ".npmrc"
                | ".pypirc"
                | ".git-credentials"
                | "settings.local.json"
                | "auth.json"
        )
}

/// `raw` resolved to an existing regular file under one of `roots`.
fn resolve(
    raw: &str,
    cwd: &Path,
    git: Option<&Path>,
    home: Option<&Path>,
    roots: &[PathBuf],
) -> Option<PathBuf> {
    let candidates: Vec<PathBuf> = if let Some(rest) = raw.strip_prefix("~/") {
        vec![home?.join(rest)]
    } else if raw.starts_with('/') {
        vec![PathBuf::from(raw)]
    } else {
        [Some(cwd), git].into_iter().flatten().map(|b| b.join(raw)).collect()
    };
    candidates.into_iter().find_map(|c| {
        let canon = std::fs::canonicalize(&c).ok()?;
        let meta = std::fs::metadata(&canon).ok()?;
        (meta.is_file() && roots.iter().any(|r| canon.starts_with(r))).then_some(canon)
    })
}

/// Git's blob id of `bytes` (SHA-1 of `blob <len>\0<bytes>`), as `git hash-object` gives it.
pub fn blob_hash(bytes: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// One attached file (or windows of it).
#[derive(Debug, Clone, PartialEq)]
pub struct Fetched {
    pub path: PathBuf,
    /// The forms the prompt named it by.
    pub named: Vec<String>,
    /// 1-based inclusive line ranges given.
    pub ranges: Vec<(usize, usize)>,
    pub total_lines: usize,
    pub blob: String,
    pub chars: usize,
}

/// What a prompt's prefetch attaches.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub block: Value,
    pub files: Vec<Fetched>,
    pub tokens: usize,
}

fn numbered(lines: &[&str], from: usize, to: usize, cap: usize) -> (String, usize) {
    let mut out = String::new();
    let mut last = from.saturating_sub(1);
    for n in from..=to {
        let Some(text) = lines.get(n.wrapping_sub(1)) else { break };
        let line = format!("{n:>6}\t{}\n", text.trim_end_matches('\r'));
        if out.len() + line.len() > cap {
            break;
        }
        out.push_str(&line);
        last = n;
    }
    (out, last)
}

fn merge(mut ranges: Vec<(usize, usize)>) -> Vec<(usize, usize)> {
    ranges.sort();
    let mut out: Vec<(usize, usize)> = Vec::new();
    for (a, b) in ranges {
        match out.last_mut() {
            Some(last) if a <= last.1 + 1 => last.1 = last.1.max(b),
            _ => out.push((a, b)),
        }
    }
    out
}

/// One file's attachment, within `cap` characters, or None (binary, too big, nothing to show).
fn fetch_one(path: &Path, refs: &[&Ref], cap: usize) -> Option<(String, Fetched)> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > MAX_READ_BYTES {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.iter().take(8192).any(|b| *b == 0) {
        return None;
    }
    let text = std::str::from_utf8(&bytes).ok()?;
    let lines: Vec<&str> = text.lines().collect();
    let total = lines.len();
    if total == 0 {
        return None;
    }
    let whole = refs.iter().any(|r| r.lines.is_none());
    let wanted = if whole {
        vec![(1, total)]
    } else {
        merge(
            refs.iter()
                .filter_map(|r| r.lines)
                .filter(|(a, _)| *a <= total)
                .map(|(a, b)| (a.saturating_sub(WINDOW).max(1), (b + WINDOW).min(total)))
                .collect(),
        )
    };
    let mut body = String::new();
    let mut ranges = Vec::new();
    for (a, b) in wanted {
        let (chunk, last) = numbered(&lines, a, b, cap.saturating_sub(body.len()));
        // A whole file over its budget is left to the agent's own Read: half a file saves none.
        if whole && last < b {
            return None;
        }
        if last < a {
            break;
        }
        ranges.push((a, last));
        body.push_str(&chunk);
    }
    if ranges.is_empty() {
        return None;
    }
    let blob = blob_hash(&bytes);
    let shown: Vec<String> = ranges.iter().map(|(a, b)| format!("{a}-{b}")).collect();
    let entry = format!(
        "<file path=\"{}\" lines=\"{}\" totalLines=\"{total}\" blob=\"{blob}\">\n{body}</file>\n",
        path.display(),
        shown.join(","),
    );
    let fetched = Fetched {
        path: path.to_path_buf(),
        named: refs.iter().map(|r| r.path.clone()).collect(),
        ranges,
        total_lines: total,
        blob,
        chars: entry.len(),
    };
    Some((entry, fetched))
}

const HEAD: &str = "acpmux read the files this message names as it was sent and attached them here, \
numbered as a Read shows them, each with its git blob id. Use them instead of reading them again; \
read one again only to see lines not shown here or after it changes.\n";

/// The prefetch for `text`, a session in `cwd`: None when nothing is worth attaching.
/// `first`: the session's first prompt, which fetches every named file, not only cued ones.
pub fn plan(text: &str, cwd: &Path, home: Option<&Path>, first: bool) -> Option<Plan> {
    plan_within(
        text,
        cwd,
        home,
        first,
        TOTAL_TOKENS * CHARS_PER_TOKEN,
        FILE_TOKENS * CHARS_PER_TOKEN,
    )
}

pub fn plan_within(
    text: &str,
    cwd: &Path,
    home: Option<&Path>,
    first: bool,
    total_cap: usize,
    file_cap: usize,
) -> Option<Plan> {
    let refs = extract(text);
    if refs.is_empty() {
        return None;
    }
    let cwd = std::fs::canonicalize(cwd).ok()?;
    let git = git_root(&cwd);
    let home = home.and_then(|h| std::fs::canonicalize(h).ok());
    let roots: Vec<PathBuf> =
        [Some(cwd.clone()), git.clone(), home.clone()].into_iter().flatten().collect();
    // Each file once, its refs together, in the order the fetch should go: cued, then
    // `path:line`, then the rest; a later prompt only the first two.
    let mut by_file: BTreeMap<PathBuf, (usize, u8, Vec<&Ref>)> = BTreeMap::new();
    for (i, r) in refs.iter().enumerate() {
        if by_file.len() >= MAX_PATHS
            && !by_file.values().any(|(_, _, v)| v.iter().any(|o| o.path == r.path))
        {
            continue;
        }
        let Some(path) = resolve(&r.path, &cwd, git.as_deref(), home.as_deref(), &roots) else {
            continue;
        };
        if secret_looking(&path) {
            continue;
        }
        let rank = if r.cued {
            0
        } else if r.lines.is_some() {
            1
        } else {
            2
        };
        let e = by_file.entry(path).or_insert((i, rank, Vec::new()));
        e.1 = e.1.min(rank);
        e.2.push(r);
    }
    let mut order: Vec<(PathBuf, usize, u8, Vec<&Ref>)> = by_file
        .into_iter()
        .map(|(p, (i, rank, v))| (p, i, rank, v))
        .filter(|(_, _, rank, _)| first || *rank < 2)
        .collect();
    order.sort_by_key(|(_, i, rank, _)| (*rank, *i));
    let mut body = String::from(HEAD);
    let mut files = Vec::new();
    let mut used = 0usize;
    for (path, _, _, refs) in order {
        let cap = file_cap.min(total_cap.saturating_sub(used));
        if cap == 0 {
            break;
        }
        if let Some((entry, fetched)) = fetch_one(&path, &refs, cap) {
            used += entry.len();
            body.push_str(&entry);
            files.push(fetched);
        }
    }
    if files.is_empty() {
        return None;
    }
    let text = format!("<cmux-prefetch-context>\n{body}</cmux-prefetch-context>");
    let tokens = text.len().div_ceil(CHARS_PER_TOKEN);
    let block = json!({"type": "text", "text": text, "_meta": {"acpmux": {"context": true, "prefetch": true}}});
    Some(Plan { block, files, tokens })
}

/// The running turn's prefetch and the reads of its files seen since.
#[derive(Debug, Default, Clone)]
pub struct PrefetchTurn {
    pub turn_id: String,
    /// Canonical paths, and the forms the prompt named each by.
    files: Vec<(String, Vec<String>)>,
    tokens: usize,
    calls: HashSet<String>,
    reread: u64,
    read: HashSet<String>,
}

fn read_verb(command: &str) -> bool {
    command.split(|c: char| c.is_whitespace() || matches!(c, '|' | ';' | '&' | '(' | ')')).any(
        |w| {
            matches!(
                w.rsplit('/').next(),
                Some(
                    "cat" | "sed" | "head" | "tail" | "nl" | "less" | "bat" | "awk" | "grep" | "rg"
                )
            )
        },
    )
}

impl PrefetchTurn {
    pub fn new(turn_id: &str, plan: &Plan) -> Self {
        PrefetchTurn {
            turn_id: turn_id.to_owned(),
            files: plan
                .files
                .iter()
                .map(|f| (f.path.to_string_lossy().into_owned(), f.named.clone()))
                .collect(),
            tokens: plan.tokens,
            ..Default::default()
        }
    }

    fn matches(&self, path: &str) -> Option<usize> {
        let path = path.trim();
        if path.is_empty() {
            return None;
        }
        self.files.iter().position(|(canon, named)| {
            canon == path
                || (path.starts_with('/')
                    && std::fs::canonicalize(path)
                        .ok()
                        .is_some_and(|c| c.to_string_lossy() == canon.as_str()))
                || (!path.starts_with('/')
                    && (canon.ends_with(&format!("/{path}")) || named.iter().any(|n| n == path)))
        })
    }

    /// A `tool_call` or `tool_call_update` of the turn: a read of a prefetched file counts once
    /// per call.
    pub fn observe(&mut self, update: &Value) {
        if self.files.is_empty() {
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if self.calls.contains(id) {
            return;
        }
        let kind = update.get("kind").and_then(Value::as_str);
        let title = update.get("title").and_then(Value::as_str).unwrap_or("");
        let raw = update.get("rawInput");
        let mut hit: Option<usize> = None;
        let is_read = kind == Some("read") || title.starts_with("Read");
        if is_read {
            let mut paths: Vec<&str> = update
                .get("locations")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|l| l.get("path").and_then(Value::as_str))
                .collect();
            for key in ["file_path", "path", "filePath", "notebook_path"] {
                if let Some(p) = raw.and_then(|r| r.get(key)).and_then(Value::as_str) {
                    paths.push(p);
                }
            }
            hit = paths.iter().find_map(|p| self.matches(p));
        }
        if hit.is_none() {
            let command = match raw.and_then(|r| r.get("command")) {
                Some(Value::String(c)) => Some(c.clone()),
                Some(Value::Array(a)) => {
                    Some(a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
                }
                _ => None,
            };
            if let Some(command) = command.filter(|c| read_verb(c)) {
                let words: Vec<&str> =
                    command.split(|c: char| c.is_whitespace() || matches!(c, '\'' | '"')).collect();
                hit = self.files.iter().position(|(canon, named)| {
                    command.contains(canon.as_str())
                        || named.iter().any(|n| words.contains(&n.as_str()))
                });
            }
        }
        if let Some(canon) = hit.and_then(|i| self.files.get(i)).map(|f| f.0.clone()) {
            self.calls.insert(id.to_owned());
            self.reread += 1;
            self.read.insert(canon);
        }
    }

    /// The counters this turn's `turn_result` carries.
    pub fn counters(&self) -> Map<String, Value> {
        let files = self.files.len();
        let saved = (files as f64 * HIST_REQUESTS_PER_FILE - self.reread as f64).max(0.0);
        let mut m = Map::new();
        m.insert("harnessMagic.prefetch.files".into(), json!(files));
        m.insert("harnessMagic.prefetch.tokens".into(), json!(self.tokens));
        m.insert("harnessMagic.prefetch.rereadAnyway".into(), json!(self.reread));
        m.insert("harnessMagic.prefetch.neverRead".into(), json!(files - self.read.len()));
        m.insert(
            "harnessMagic.prefetch.estRequestsSaved".into(),
            json!((saved * 100.0).round() / 100.0),
        );
        m
    }
}

/// How long the turn waits for the files at most; past it the prompt goes without them.
const BUDGET: std::time::Duration = std::time::Duration::from_millis(750);

impl super::Hub {
    /// Appends the prefetch block for the prompt `text` of `turn_id` to `blocks`, and keeps what
    /// it attached for the turn's counters. Nothing on any error or when off.
    pub(super) async fn prefetch_into(
        &self,
        session: &super::Session,
        text: &str,
        turn_id: &str,
        blocks: &mut Vec<Value>,
    ) {
        *session.prefetch.lock().unwrap_or_else(|e| e.into_inner()) = None;
        // Most prompts name no file: no settings read, no thread.
        if extract(text).is_empty() {
            return;
        }
        let (cwd, first) = {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            (m.cwd.clone(), m.turn_count <= 1)
        };
        let text = text.to_owned();
        let job = tokio::task::spawn_blocking(move || {
            if !enabled() {
                return None;
            }
            plan(&text, &cwd, dirs::home_dir().as_deref(), first)
        });
        let Ok(Ok(Some(plan))) = tokio::time::timeout(BUDGET, job).await else { return };
        *session.prefetch.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(PrefetchTurn::new(turn_id, &plan));
        blocks.push(plan.block);
    }

    /// A tool call of the running turn (`stalled_turn.rs` `note_tool_update`).
    pub(super) fn note_prefetch_read(&self, session: &super::Session, update: &Value) {
        if let Some(p) = session.prefetch.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            p.observe(update);
        }
    }

    /// The counters of `turn_id`'s prefetch, once: empty when it attached nothing.
    pub(super) fn take_prefetch_counters(
        &self,
        session: &super::Session,
        turn_id: &str,
    ) -> Map<String, Value> {
        let mut slot = session.prefetch.lock().unwrap_or_else(|e| e.into_inner());
        match slot.as_ref() {
            Some(p) if p.turn_id == turn_id => {
                slot.take().map(|p| p.counters()).unwrap_or_default()
            }
            _ => Map::new(),
        }
    }
}

#[cfg(test)]
#[path = "prefetch_tests.rs"]
mod tests;
