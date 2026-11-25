//! `cmux link memory plan`: the carried set, with no network (plans/cloud/
//! agent-memory-follows-user.md in cmuxterm-hq, step 1).
//!
//! It walks the allowlist in the home, never through a link, and prints the
//! manifest a push would send: each carried file with its hash, size and, for
//! Claude's project memory, the project id it is keyed by. Everything it
//! leaves out is listed with the reason: a never-carried name, a path that is
//! not in plain form, a link or a hard link, a file over the size cap, bytes
//! that are not text, a secret-shaped text, the person's caps, or project
//! memory whose project is unknown or ambiguous on this device.
//!
//! Project memory is keyed by project, not by path: Claude names the folder
//! by the session's working folder with every non-alphanumeric character made
//! `-` (a slug), so `a-b` and `a/b` share one, and a slug is never read back
//! into a folder. The folders come from `--folder` and from the `cwd` Claude
//! records in that slug's transcripts; a folder counts for a slug only when its
//! own slug is that slug. Each folder's project id is its normalised git remote,
//! else its start-chat folder id. One id: carried under it. None: unmapped.
//! Two or more: a conflict, and none of that slug's memory is carried.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use anyhow::{Context as _, bail};
use regex::Regex;
use serde::Serialize;
use serde_json::json;

use super::place::{self, Dir, Entry};
use super::{FILE_MAX, Home, refusal, sha256_hex};

/// The person's caps, the same the head enforces.
#[derive(Clone, Copy, Debug, Serialize)]
pub(super) struct Caps {
    pub file_bytes: u64,
    pub total_bytes: u64,
    pub entries: usize,
    pub path_bytes: usize,
}

impl Default for Caps {
    fn default() -> Self {
        Self {
            file_bytes: FILE_MAX,
            total_bytes: 16 * 1024 * 1024,
            entries: 2_000,
            path_bytes: super::PATH_MAX,
        }
    }
}

/// Harness files that sit beside the carried ones and never travel: listed
/// as refused when present, so the person sees they were left out.
pub(super) const NEVER_CARRIED: &[&str] = &[
    ".claude/.credentials.json",
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/history.jsonl",
    ".claude.json",
    ".codex/auth.json",
    ".codex/config.toml",
    ".gemini/oauth_creds.json",
    ".gemini/settings.json",
];

/// One carried file in the manifest.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct Carried {
    /// Its path under the home.
    pub path: String,
    /// Project memory: the project id it is keyed by.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    /// Project memory: its path under the project's `memory/` folder.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub sha256: String,
    pub mode: u32,
    pub bytes: u64,
}

/// A file left out, and why.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct Refused {
    pub path: String,
    pub reason: String,
}

/// How one slug of Claude's project memory maps to a project here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct Mapped {
    pub slug: String,
    /// The one project id, when exactly one.
    pub project: Option<String>,
    /// Each folder seen for the slug, with the id it gave.
    pub folders: BTreeMap<String, Option<String>>,
    /// `mapped`, `unmapped` or `conflict`.
    pub state: &'static str,
}

/// What a push would send, and what it would leave out.
#[derive(Debug, Default, Serialize)]
pub(super) struct Plan {
    pub manifest: Vec<Carried>,
    pub refused: Vec<Refused>,
    pub projects: Vec<Mapped>,
    pub total_bytes: u64,
}

/// Where the folders for project memory come from.
pub(super) struct Sources {
    /// Folders named on the command line.
    pub folders: Vec<PathBuf>,
    /// The start-chat ledger for folder ids (none: git remotes only).
    pub ledger: Option<PathBuf>,
}

/// Secret shapes, by the name each is refused under.
static SECRETS: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    [
        ("anthropic key", r"\bsk-ant-[A-Za-z0-9_\-]{16,}"),
        ("openai key", r"\bsk-(?:proj-)?[A-Za-z0-9_\-]{32,}"),
        ("github token", r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})"),
        ("gitlab token", r"\bglpat-[A-Za-z0-9_\-]{20,}"),
        ("slack token", r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"),
        ("aws key", r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
        ("aws credentials", r"(?im)^\s*aws_secret_access_key\s*="),
        ("private key", r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"),
        ("jwt", r"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),
        ("netrc", r"(?m)^\s*machine\s+\S+\s+(?:login\s+\S+\s+)?password\s+\S+"),
        ("credential json", r#""(?:private_key|refresh_token|client_secret)"\s*:\s*""#),
    ]
    .into_iter()
    .filter_map(|(name, pattern)| Regex::new(pattern).ok().map(|regex| (name, regex)))
    .collect()
});

/// The first secret shape `text` matches, by name.
pub(super) fn secret_in(text: &str) -> Option<&'static str> {
    SECRETS.iter().find(|(_, regex)| regex.is_match(text)).map(|(name, _)| *name)
}

/// Claude's folder name for a working folder: every character that is not
/// an ASCII letter or digit becomes `-`.
pub(super) fn claude_slug(folder: &str) -> String {
    folder.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// One file read for the plan, or why not.
fn read_one(root: &Dir, relative: &str, caps: Caps) -> Result<(Vec<u8>, u32), String> {
    let Ok(Some((dir, name))) = place::parent_of(root, relative) else {
        return Err("a folder on the way is a link or not a folder".into());
    };
    let mode = match dir.entry(&name) {
        Ok(Entry::File { mode }) => mode & 0o777,
        Ok(Entry::Link) => return Err("a link".into()),
        Ok(Entry::Missing) => return Err("gone while read".into()),
        Ok(_) => return Err("not a regular file".into()),
        Err(error) => return Err(format!("unreadable: {error}")),
    };
    let file = dir.open_file(&name).map_err(|error| format!("unreadable: {error}"))?;
    let meta = file.metadata().map_err(|error| format!("unreadable: {error}"))?;
    if !meta.is_file() {
        return Err("not a regular file".into());
    }
    // A hard link is how a credential elsewhere could sit under an allowed name.
    if meta.nlink() > 1 {
        return Err("a hard link".into());
    }
    if meta.len() > caps.file_bytes {
        return Err(format!("over the file cap ({} bytes)", caps.file_bytes));
    }
    let mut bytes = Vec::new();
    file.take(caps.file_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("unreadable: {error}"))?;
    if bytes.len() as u64 > caps.file_bytes {
        return Err(format!("over the file cap ({} bytes)", caps.file_bytes));
    }
    // The file read must still be the one at the name.
    if dir.inode(&name).ok().flatten() != Some((meta.dev(), meta.ino())) {
        return Err("replaced while read".into());
    }
    let Ok(text) = std::str::from_utf8(&bytes) else { return Err("not text".into()) };
    if text.contains('\0') {
        return Err("not text".into());
    }
    if let Some(kind) = secret_in(text) {
        return Err(format!("secret: {kind}"));
    }
    Ok((bytes, mode))
}

/// The working folders Claude recorded in a slug's transcripts (`cwd`), at
/// most 64 files and 64 KiB of each, never through a link.
fn transcript_folders(projects: &Path, slug: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let folder = projects.join(slug);
    let Ok(meta) = std::fs::symlink_metadata(&folder) else { return found };
    if !meta.is_dir() {
        return found;
    }
    let Ok(entries) = std::fs::read_dir(&folder) else { return found };
    for entry in entries.flatten().take(64) {
        let path = entry.path();
        let is_file = std::fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file());
        if !is_file || path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
            continue;
        }
        let mut head = Vec::new();
        if std::fs::File::open(&path)
            .and_then(|file| file.take(64 * 1024).read_to_end(&mut head))
            .is_err()
        {
            continue;
        }
        for line in String::from_utf8_lossy(&head).lines() {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(line)
                && let Some(cwd) = value.get("cwd").and_then(|cwd| cwd.as_str())
            {
                found.insert(cwd.to_string());
            }
        }
    }
    found
}

/// Maps each slug to its project, from the folders seen for it.
fn map_slugs(
    home: &Path,
    slugs: &BTreeSet<String>,
    sources: &Sources,
) -> anyhow::Result<BTreeMap<String, Mapped>> {
    let projects = home.join(".claude").join("projects");
    let named: Vec<String> =
        sources.folders.iter().filter_map(|folder| folder.to_str().map(str::to_string)).collect();
    let mut out = BTreeMap::new();
    for slug in slugs {
        let mut folders: BTreeMap<String, Option<String>> = BTreeMap::new();
        for folder in named.iter().cloned().chain(transcript_folders(&projects, slug)) {
            if claude_slug(&folder) != *slug || folders.contains_key(&folder) {
                continue;
            }
            let path = Path::new(&folder);
            let id = if path.is_absolute() && path.is_dir() {
                crate::link::start_chat_cli::memory_project_id(sources.ledger.as_deref(), path)?
            } else {
                None
            };
            folders.insert(folder, id);
        }
        let ids: BTreeSet<&String> = folders.values().flatten().collect();
        let (project, state) = match ids.len() {
            0 => (None, "unmapped"),
            1 => (ids.into_iter().next().cloned(), "mapped"),
            _ => (None, "conflict"),
        };
        out.insert(slug.clone(), Mapped { slug: slug.clone(), project, folders, state });
    }
    Ok(out)
}

/// The plan for the home at `home`.
pub(super) fn plan(home: &Path, sources: &Sources, caps: Caps) -> anyhow::Result<Plan> {
    let root = Dir::open(home).with_context(|| format!("{} is not a folder", home.display()))?;
    let found = Home { root }.scan_all()?;
    let root = Dir::open(home)?;
    let mut plan = Plan::default();
    for never in NEVER_CARRIED {
        if let Ok(Some((dir, name))) = place::parent_of(&root, never)
            && !matches!(dir.entry(&name), Ok(Entry::Missing) | Err(_))
        {
            plan.refused.push(Refused { path: (*never).into(), reason: "never carried".into() });
        }
    }
    let slugs: BTreeSet<String> = found
        .iter()
        .filter_map(|path| match path.split('/').collect::<Vec<_>>().as_slice() {
            [".claude", "projects", slug, "memory", ..] => Some((*slug).to_string()),
            _ => None,
        })
        .collect();
    let mapped = map_slugs(home, &slugs, sources)?;
    for path in found {
        let refuse = |plan: &mut Plan, reason: String| {
            plan.refused.push(Refused { path: path.clone(), reason })
        };
        if path.len() > caps.path_bytes {
            refuse(&mut plan, "path form".into());
            continue;
        }
        if let Some(reason) = refusal(&path) {
            refuse(&mut plan, reason.into());
            continue;
        }
        let (project, name) = match path.split('/').collect::<Vec<_>>().as_slice() {
            [".claude", "projects", slug, "memory", rest @ ..] => {
                let Some(mapped) = mapped.get(*slug) else { continue };
                match &mapped.project {
                    Some(id) => (Some(id.clone()), Some(rest.join("/"))),
                    None => {
                        refuse(&mut plan, format!("project {}", mapped.state));
                        continue;
                    }
                }
            }
            _ => (None, None),
        };
        match read_one(&root, &path, caps) {
            Ok((bytes, mode)) => {
                let size = bytes.len() as u64;
                if plan.manifest.len() >= caps.entries {
                    refuse(&mut plan, format!("over the entry cap ({})", caps.entries));
                } else if plan.total_bytes + size > caps.total_bytes {
                    refuse(
                        &mut plan,
                        format!("over the person's cap ({} bytes)", caps.total_bytes),
                    );
                } else {
                    plan.total_bytes += size;
                    plan.manifest.push(Carried {
                        path: path.clone(),
                        project,
                        name,
                        sha256: sha256_hex(&bytes),
                        mode,
                        bytes: size,
                    });
                }
            }
            Err(reason) => refuse(&mut plan, reason),
        }
    }
    plan.refused.sort_by(|a, b| a.path.cmp(&b.path));
    plan.projects = mapped.into_values().collect();
    Ok(plan)
}

/// `cmux link memory plan [--home DIR] [--folder DIR]... [--ledger FILE] [--json]`.
pub(super) fn run(args: &[String]) -> anyhow::Result<serde_json::Value> {
    let mut home = None;
    let mut folders = Vec::new();
    let mut ledger = None;
    let mut rest = args.iter();
    while let Some(flag) = rest.next() {
        match flag.as_str() {
            "--json" => {}
            "--home" | "--folder" | "--ledger" => {
                let value = rest.next().with_context(|| format!("usage: {flag} needs a value"))?;
                let value = PathBuf::from(value);
                match flag.as_str() {
                    "--home" => home = Some(value),
                    "--folder" => folders.push(value),
                    _ => ledger = Some(value),
                }
            }
            _ => bail!("{}", super::USAGE),
        }
    }
    let home = home
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .context("no home folder; pass --home DIR")?;
    let ledger = ledger.or_else(crate::link::start_chat_cli::default_ledger);
    let caps = Caps::default();
    let plan = plan(&home, &Sources { folders, ledger }, caps)?;
    let mut value = serde_json::to_value(&plan)?;
    if let Some(object) = value.as_object_mut() {
        object.insert("ok".into(), json!(true));
        object.insert("verb".into(), json!("plan"));
        object.insert("home".into(), json!(home.display().to_string()));
        object.insert("caps".into(), serde_json::to_value(caps)?);
    }
    Ok(value)
}

#[cfg(test)]
#[path = "memory_plan_tests.rs"]
mod tests;
