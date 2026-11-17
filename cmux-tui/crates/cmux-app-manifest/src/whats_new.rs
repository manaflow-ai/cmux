//! What's New for an app shipped in this repository (`catalog/whats-new.json`
//! in its package): its version history and the merged pull requests that
//! changed it since its previous version bump, as lines a person reads.
//!
//! A first-party app has no per-app tags, so the history comes from git: a
//! version row per run of commits whose manifest carries the same `version`
//! (the oldest commit of the run is its bump), and the items from the
//! squash-merge subjects (`... (#N)`) of the commits that touched the app's
//! folder since the bump to the previous version. It reads only the local
//! history (no network, no token). The App Store owner (cmux-tui-core
//! `apps/store_sections.rs`) reads the file; `cmux-app-whats-new` writes it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Map, Value, json};

/// Where the file lives in a package.
pub const WHATS_NEW_FILE: &str = "catalog/whats-new.json";

/// The manifests whose `version` an app's history follows, preferred first.
const MANIFESTS: [&str; 2] = ["cmux-app.v2.json", "cmux-app.json"];

/// One line of What's New: a merged pull request, said for the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhatsNewItem {
    pub title: String,
    pub pr: u64,
}

/// One released version: its git tag (repository extensions) or the commit
/// that set it (first-party apps), and when.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VersionRow {
    pub version: String,
    pub tag: Option<String>,
    pub commit: Option<String>,
    pub date_ms: Option<i64>,
}

/// The file's contents: What's New of `version` and the history, newest
/// first.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WhatsNew {
    pub version: String,
    pub items: Vec<WhatsNewItem>,
    pub versions: Vec<VersionRow>,
}

impl VersionRow {
    pub fn to_json(&self) -> Value {
        let mut row = Map::new();
        row.insert("version".into(), json!(self.version));
        if let Some(tag) = &self.tag {
            row.insert("tag".into(), json!(tag));
        }
        if let Some(commit) = &self.commit {
            row.insert("commit".into(), json!(commit));
        }
        if let Some(date_ms) = self.date_ms {
            row.insert("date_ms".into(), json!(date_ms));
        }
        Value::Object(row)
    }

    fn from_json(value: &Value) -> Option<Self> {
        let text = |key: &str| value[key].as_str().map(str::to_string);
        Some(Self {
            version: text("version").filter(|v| !v.is_empty())?,
            tag: text("tag"),
            commit: text("commit"),
            date_ms: value["date_ms"].as_i64(),
        })
    }
}

impl WhatsNew {
    pub fn to_json(&self) -> Value {
        let items: Vec<Value> =
            self.items.iter().map(|item| json!({ "title": item.title, "pr": item.pr })).collect();
        let versions: Vec<Value> = self.versions.iter().map(VersionRow::to_json).collect();
        json!({ "version": self.version, "items": items, "versions": versions })
    }

    /// The file as JSON text (two-space indent, a final newline), so a
    /// regenerated file diffs only where it changed.
    pub fn to_file_text(&self) -> String {
        let mut text = serde_json::to_string_pretty(&self.to_json()).unwrap_or_default();
        text.push('\n');
        text
    }

    /// Parses the file; `None` when it is not the shape [`to_json`] writes.
    /// An item without a title or PR number is left out, not an error.
    ///
    /// [`to_json`]: Self::to_json
    pub fn from_json(value: &Value) -> Option<Self> {
        let version = value["version"].as_str().filter(|v| !v.is_empty())?.to_string();
        let items = value["items"]
            .as_array()?
            .iter()
            .filter_map(|item| {
                let title = item["title"].as_str().filter(|t| !t.is_empty())?;
                Some(WhatsNewItem { title: title.to_string(), pr: item["pr"].as_u64()? })
            })
            .collect();
        let versions = value["versions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(VersionRow::from_json)
            .collect();
        Some(Self { version, items, versions })
    }
}

/// Conventional-commit types that never reach a person.
const INTERNAL_TYPES: [&str; 8] =
    ["build", "chore", "ci", "docs", "refactor", "style", "test", "tests"];

/// First words of a subject prefix that names internal work (`Rust release
/// profiles:`, `license:`).
const INTERNAL_AREAS: [&str; 8] =
    ["ci", "cmux-tui", "deps", "license", "lint", "machines", "rust", "tests"];

/// Words that mark a subject as about how cmux is built, not what the
/// person gets (matched case-insensitively anywhere in the subject).
const INTERNAL_TERMS: [&str; 23] = [
    " 404",
    " 502",
    " 503",
    "app server",
    "backend",
    "base red",
    "bench",
    "cargo",
    "carrier",
    "clippy",
    "clouddo",
    "cmux-platform",
    "cmux.wire",
    "codegen",
    "contract",
    "harness",
    "jsonschema",
    "polling",
    "rd viewer",
    "refusal code",
    "runtime",
    "stderr",
    "swift ",
];

/// At most this many items, newest first: the store shows a short list.
pub const MAX_ITEMS: usize = 10;

/// The person-facing line of a squash-merge subject `... (#N)`, or `None`
/// for a subject with no PR number or one about internal work. It drops the
/// area prefix (`App Store:`, `Cloud page:`, `fix(cloud):`) and trailing
/// tracker tags (`(F11)`, `(cx-9ce.2.28)`), and keeps the sentence.
pub fn person_line(subject: &str) -> Option<WhatsNewItem> {
    let subject = subject.trim();
    let lower = subject.to_lowercase();
    if INTERNAL_TERMS.iter().any(|term| lower.contains(term)) {
        return None;
    }
    let open = subject.strip_suffix(')')?.rfind(" (#")?;
    let pr = subject[open + 3..subject.len() - 1].parse::<u64>().ok()?;
    let mut title = subject[..open].trim_end();
    while let Some(rest) = strip_tracker_tag(title) {
        title = rest;
    }
    for _ in 0..2 {
        match strip_prefix(title) {
            Prefix::Internal => return None,
            Prefix::Area(rest) => title = rest,
            Prefix::None => break,
        }
    }
    let title = title.trim();
    let mut chars = title.chars();
    let first = chars.next()?;
    Some(WhatsNewItem { title: first.to_uppercase().chain(chars).collect(), pr })
}

/// `title` without a trailing `(TAG)` whose every word carries a digit
/// (`(F11)`, `(C1)`, `(R73 S1)`, `(cx-034r)`); a parenthetical a person
/// reads (`(warning, pause, refusals)`) stays.
fn strip_tracker_tag(title: &str) -> Option<&str> {
    let open = title.strip_suffix(')')?.rfind(" (")?;
    let inner = &title[open + 2..title.len() - 1];
    let tag = !inner.is_empty()
        && inner.split_whitespace().all(|word| word.chars().any(|c| c.is_ascii_digit()));
    tag.then(|| title[..open].trim_end())
}

enum Prefix<'a> {
    None,
    Internal,
    Area(&'a str),
}

/// A leading `area: ` of at most four words, or a conventional-commit type.
fn strip_prefix(title: &str) -> Prefix<'_> {
    let Some((head, rest)) = title.split_once(':') else { return Prefix::None };
    // `area: sentence`, or a bare `area:` with nothing after it; never `a:b`.
    if rest.chars().next().is_some_and(|c| !c.is_whitespace()) {
        return Prefix::None;
    }
    let (head, rest) = (head.trim(), rest.trim_start());
    let (kind, scope) = match head.split_once('(') {
        Some((kind, scope)) if scope.ends_with(')') || scope.ends_with(")!") => (kind, true),
        _ => (head.trim_end_matches('!'), false),
    };
    if INTERNAL_TYPES.contains(&kind) {
        return Prefix::Internal;
    }
    if scope && matches!(kind, "feat" | "fix" | "perf") {
        return Prefix::Area(rest);
    }
    let words: Vec<&str> = head.split_whitespace().collect();
    let plain = !head.contains([',', ';', '(', ')', '.', '`']);
    let Some(first) = words.first().filter(|_| words.len() <= 4 && plain) else {
        return Prefix::None;
    };
    let first = first.to_ascii_lowercase();
    if INTERNAL_AREAS.contains(&first.as_str()) || INTERNAL_TYPES.contains(&first.as_str()) {
        return Prefix::Internal;
    }
    Prefix::Area(rest)
}

fn git(repo: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn manifest_version(text: &str) -> Option<String> {
    let manifest: Value = serde_json::from_str(text).ok()?;
    manifest["version"].as_str().filter(|v| !v.is_empty()).map(str::to_string)
}

/// The version of the app's manifest at `commit` (`None`: the working tree),
/// from the first manifest of [`MANIFESTS`] that exists there.
fn version_at(repo: &Path, app_dir: &str, commit: Option<&str>) -> Option<String> {
    MANIFESTS.iter().find_map(|file| {
        let text = match commit {
            Some(commit) => git(repo, &["show", &format!("{commit}:{app_dir}/{file}")]).ok()?,
            None => std::fs::read_to_string(repo.join(app_dir).join(file)).ok()?,
        };
        manifest_version(&text)
    })
}

/// The version rows of `app_dir` (repository-relative), newest first: each
/// run of manifest commits with one version is a row whose commit and date
/// are the run's oldest commit, the bump. A version the working tree has
/// and no commit does yet comes first, with no commit.
fn versions(repo: &Path, app_dir: &str) -> Result<Vec<VersionRow>, String> {
    let current = version_at(repo, app_dir, None)
        .ok_or_else(|| format!("{app_dir} has no manifest with a version"))?;
    let paths: Vec<String> = MANIFESTS.iter().map(|file| format!("{app_dir}/{file}")).collect();
    let mut args = vec!["log", "--format=%H%x1f%ct", "--"];
    args.extend(paths.iter().map(String::as_str));
    let log = git(repo, &args)?;
    let mut rows: Vec<VersionRow> = Vec::new();
    for line in log.lines() {
        let Some((commit, seconds)) = line.split_once('\u{1f}') else { continue };
        let Some(version) = version_at(repo, app_dir, Some(commit)) else { continue };
        let date_ms = seconds.trim().parse::<i64>().ok().map(|s| s.saturating_mul(1000));
        match rows.last_mut() {
            // An older commit of the same run: the bump is further back.
            Some(row) if row.version == version => {
                row.commit = Some(commit.to_string());
                row.date_ms = date_ms;
            }
            _ => rows.push(VersionRow {
                version,
                tag: None,
                commit: Some(commit.to_string()),
                date_ms,
            }),
        }
    }
    if rows.first().is_none_or(|row| row.version != current) {
        rows.insert(0, VersionRow { version: current, ..VersionRow::default() });
    }
    Ok(rows)
}

/// What's New of the app in `repo`'s `app_dir` (repository-relative, such
/// as `first-party-apps/cloud`): the merged PRs that touched the folder
/// after the bump to the previous version (its whole history when it has
/// had one version), newest first, once each. A commit that changed only
/// the What's New file itself is left out.
pub fn generate(repo: &Path, app_dir: &str) -> Result<WhatsNew, String> {
    let app_dir = app_dir.trim_end_matches('/');
    let versions = versions(repo, app_dir)?;
    let range = versions.get(1).and_then(|row| row.commit.as_deref()).map(|c| format!("{c}..HEAD"));
    let mut args = vec!["log", "--no-merges", "--name-only", "--format=%x1e%s"];
    if let Some(range) = &range {
        args.push(range);
    }
    args.extend(["--", app_dir]);
    let log = git(repo, &args)?;
    let own_file = format!("{app_dir}/{WHATS_NEW_FILE}");
    let mut seen = BTreeSet::new();
    let mut items = Vec::new();
    for record in log.split('\u{1e}').filter(|r| !r.trim().is_empty()) {
        let mut lines = record.lines();
        let subject = lines.next().unwrap_or_default();
        let mut files = lines.map(str::trim).filter(|l| !l.is_empty()).peekable();
        if files.peek().is_some() && files.all(|file| file == own_file) {
            continue;
        }
        if let Some(item) = person_line(subject)
            && seen.insert(item.pr)
        {
            items.push(item);
        }
        if items.len() == MAX_ITEMS {
            break;
        }
    }
    let version = versions.first().map(|row| row.version.clone()).unwrap_or_default();
    Ok(WhatsNew { version, items, versions })
}

/// Generates the app's What's New and writes it to its package; answers
/// the file's path and whether it changed.
pub fn write(repo: &Path, app_dir: &str) -> Result<(PathBuf, bool), String> {
    let text = generate(repo, app_dir)?.to_file_text();
    let path = repo.join(app_dir.trim_end_matches('/')).join(WHATS_NEW_FILE);
    if std::fs::read_to_string(&path).is_ok_and(|old| old == text) {
        return Ok((path, false));
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok((path, true))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(subject: &str) -> Option<(String, u64)> {
        person_line(subject).map(|item| (item.title, item.pr))
    }

    #[test]
    fn a_subject_becomes_the_sentence_a_person_reads() {
        let said = |title: &str, pr| Some((title.to_string(), pr));
        assert_eq!(
            line("App Store: hero buttons use the one corner token (#44805)"),
            said("Hero buttons use the one corner token", 44805)
        );
        assert_eq!(
            line("cloud: a paused machine says what its pause costs a month (F11) (#40336)"),
            said("A paused machine says what its pause costs a month", 40336)
        );
        assert_eq!(
            line("Cloud: show the team's spending cap (warning, pause, refusals) (#40036)"),
            said("Show the team's spending cap (warning, pause, refusals)", 40036)
        );
        assert_eq!(
            line("fix(cloud): Reconnect waits for the machine (cx-9ce.2.28) (#7)"),
            said("Reconnect waits for the machine", 7)
        );
        // A long clause before a colon is the sentence, not an area.
        assert_eq!(
            line("The Cloud server never idle-stops: machine links stay up (#38154)"),
            said("The Cloud server never idle-stops: machine links stay up", 38154)
        );
        // Internal work and subjects with no PR never reach the person.
        assert_eq!(line("cloud: resume survives a 503; a 404 names its step (#44513)"), None);
        assert_eq!(line("Cloud clients honour the platform's refusal codes (#40552)"), None);
        assert_eq!(line("Select Cloud backend at runtime (#35284)"), None);
        assert_eq!(line("Rust release profiles: fat LTO for cmux-cloud (#42338)"), None);
        assert_eq!(line("test(apps): an open page hears installs (#9)"), None);
        assert_eq!(line("chore: bump deps (#10)"), None);
        assert_eq!(line("apps: first-party apps are hide-only"), None);
        assert_eq!(line("App Store: (#11)"), None);
    }

    #[test]
    fn the_file_round_trips() {
        let file = WhatsNew {
            version: "1.1.0".into(),
            items: vec![WhatsNewItem { title: "Faster".into(), pr: 3 }],
            versions: vec![
                VersionRow {
                    version: "1.1.0".into(),
                    commit: Some("abc".into()),
                    date_ms: Some(1000),
                    ..VersionRow::default()
                },
                VersionRow {
                    version: "1.0.0".into(),
                    tag: Some("v1.0.0".into()),
                    ..Default::default()
                },
            ],
        };
        let value = file.to_json();
        assert_eq!(value["versions"][1], json!({ "version": "1.0.0", "tag": "v1.0.0" }));
        assert_eq!(WhatsNew::from_json(&value), Some(file.clone()));
        let text = file.to_file_text();
        assert!(text.ends_with("}\n"), "{text}");
        assert_eq!(WhatsNew::from_json(&json!({ "items": [] })), None);
    }
}
