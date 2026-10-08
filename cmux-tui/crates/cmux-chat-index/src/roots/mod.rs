//! Root discovery (ALL-CHATS-ON-DEVICE C3): default dirs, env overrides from
//! the login environment, wrapper layouts (subrouter account homes), roots
//! recorded at launch, and user roots. Every root is a harness data dir that
//! exists; guarded folders are refused with a reason; roots that resolve to
//! the same real directory merge into one root with every alias and account.

mod recorded;

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::entry::AdapterKind;
use crate::scan::AdapterConfig;

pub use recorded::RecordedRoots;

/// Why a root is known, in priority order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RootSource {
    Default,
    Env,
    Layout,
    Recorded,
    User,
}

/// A root as a person, a launch record or a profile names it.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RootSpec {
    pub harness: AdapterKind,
    pub path: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

impl RootSpec {
    /// The store root that holds a transcript a harness reported (Claude
    /// hook `transcript_path`: `<projects>/<encoded cwd>/<id>.jsonl`; Codex
    /// rollout: `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`).
    pub fn from_transcript(harness: AdapterKind, transcript: &Path) -> Option<Self> {
        let up = match harness {
            AdapterKind::ClaudeCode => 2,
            AdapterKind::Codex => 5,
            _ => return None,
        };
        let path = transcript.ancestors().nth(up)?.to_path_buf();
        path.is_absolute().then_some(Self { harness, path, label: None })
    }
}

/// One discovered root, after the real-path merge.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRoot {
    pub harness: AdapterKind,
    /// The first spelling found; the adapter scans this path.
    pub path: PathBuf,
    pub real_path: PathBuf,
    pub source: RootSource,
    /// Every other spelling that reached the same directory.
    pub aliases: Vec<PathBuf>,
    /// Account labels (subrouter profile dir names, user labels).
    pub accounts: Vec<String>,
}

impl ChatRoot {
    pub fn config(&self) -> AdapterConfig {
        AdapterConfig::new(self.harness, &self.path)
    }

    /// Stable id: harness and real path.
    pub fn id(&self) -> String {
        format!("{}:{}", self.harness.id(), self.real_path.display())
    }
}

/// A root left out because it is inside a guarded location.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefusedRoot {
    pub harness: AdapterKind,
    pub path: PathBuf,
    pub source: RootSource,
    pub reason: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Discovery {
    pub roots: Vec<ChatRoot>,
    pub refused: Vec<RefusedRoot>,
}

/// What discovery reads. `env` is the login environment (the daemon's own
/// first, then the login shell import); `refuse` is the guarded-folder check.
pub struct DiscoveryInput<'a> {
    pub home: &'a Path,
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub refuse: &'a dyn Fn(&Path) -> Option<String>,
    pub recorded: &'a [RootSpec],
    pub user: &'a [RootSpec],
}

pub fn discover(input: &DiscoveryInput<'_>) -> Discovery {
    let mut candidates: Vec<(RootSpec, RootSource)> = Vec::new();
    for kind in AdapterKind::ALL {
        for (path, source) in builtin_roots(kind, input) {
            candidates.push((RootSpec { harness: kind, path, label: None }, source));
        }
    }
    candidates
        .extend(subrouter_claude_homes(input).into_iter().map(|spec| (spec, RootSource::Layout)));
    candidates.extend(input.recorded.iter().cloned().map(|spec| (spec, RootSource::Recorded)));
    candidates.extend(input.user.iter().cloned().map(|spec| (spec, RootSource::User)));

    let mut found = Discovery::default();
    for (spec, source) in candidates {
        // Refuse before any read: resolving a guarded path reads inside it.
        if let Some(reason) = (input.refuse)(&spec.path) {
            found.refused.push(RefusedRoot {
                harness: spec.harness,
                path: spec.path,
                source,
                reason,
            });
            continue;
        }
        let Ok(real_path) = fs::canonicalize(&spec.path) else { continue };
        if !real_path.is_dir() {
            continue;
        }
        if let Some(root) = found
            .roots
            .iter_mut()
            .find(|root| root.harness == spec.harness && root.real_path == real_path)
        {
            if root.path != spec.path && !root.aliases.contains(&spec.path) {
                root.aliases.push(spec.path);
            }
            push_unique(&mut root.accounts, spec.label);
            continue;
        }
        let mut accounts = Vec::new();
        push_unique(&mut accounts, spec.label);
        found.roots.push(ChatRoot {
            harness: spec.harness,
            path: spec.path,
            real_path,
            source,
            aliases: Vec::new(),
            accounts,
        });
    }
    found
}

fn push_unique(list: &mut Vec<String>, value: Option<String>) {
    if let Some(value) = value.filter(|value| !value.is_empty())
        && !list.contains(&value)
    {
        list.push(value);
    }
}

/// The env override (when set) and the default dir of a built-in harness.
fn builtin_roots(kind: AdapterKind, input: &DiscoveryInput<'_>) -> Vec<(PathBuf, RootSource)> {
    let home = input.home;
    let env = |key: &str| (input.env)(key).filter(|value| !value.is_empty()).map(PathBuf::from);
    let xdg_data = env("XDG_DATA_HOME");
    let mut roots = Vec::new();
    let mut add = |path: Option<PathBuf>, source| {
        if let Some(path) = path.filter(|path| path.is_absolute()) {
            roots.push((path, source));
        }
    };
    match kind {
        AdapterKind::ClaudeCode => {
            add(env("CLAUDE_CONFIG_DIR").map(|dir| dir.join("projects")), RootSource::Env);
            add(Some(home.join(".claude/projects")), RootSource::Default);
        }
        AdapterKind::Codex => {
            add(env("CODEX_HOME"), RootSource::Env);
            add(Some(home.join(".codex")), RootSource::Default);
        }
        AdapterKind::OpenCode => {
            add(xdg_data.as_ref().map(|dir| dir.join("opencode")), RootSource::Env);
            add(Some(home.join(".local/share/opencode")), RootSource::Default);
        }
        AdapterKind::Pi => {
            add(env("PI_CODING_AGENT_SESSION_DIR"), RootSource::Env);
            add(env("PI_CODING_AGENT_DIR").map(|dir| dir.join("sessions")), RootSource::Env);
            add(Some(home.join(".pi/agent/sessions")), RootSource::Default);
        }
        AdapterKind::Gemini => {
            add(env("GEMINI_CLI_HOME").map(|dir| dir.join(".gemini")), RootSource::Env);
            add(Some(home.join(".gemini")), RootSource::Default);
        }
        AdapterKind::CursorAgent => add(Some(home.join(".cursor/chats")), RootSource::Default),
        AdapterKind::Amp => {
            add(xdg_data.as_ref().map(|dir| dir.join("amp/threads")), RootSource::Env);
            add(Some(home.join(".local/share/amp/threads")), RootSource::Default);
            add(Some(home.join("Library/Application Support/amp/threads")), RootSource::Default);
        }
    }
    roots
}

/// Subrouter (`sr claude`) gives each account its own Claude home:
/// `<SUBROUTER_STATE_DIR|~/.subrouter>/codex/claude/<profile>/projects`.
/// Most share one physical store through symlinks; the real-path merge
/// turns them into one root that lists every profile as an account.
fn subrouter_claude_homes(input: &DiscoveryInput<'_>) -> Vec<RootSpec> {
    let state = (input.env)("SUBROUTER_STATE_DIR")
        .filter(|value| !value.is_empty())
        .map_or_else(|| input.home.join(".subrouter"), PathBuf::from);
    let Ok(profiles) = fs::read_dir(state.join("codex/claude")) else { return Vec::new() };
    let mut specs: Vec<RootSpec> = profiles
        .flatten()
        .filter_map(|profile| {
            let label = profile.file_name().to_str()?.to_owned();
            let path = profile.path().join("projects");
            Some(RootSpec { harness: AdapterKind::ClaudeCode, path, label: Some(label) })
        })
        .collect();
    specs.sort_by(|a, b| a.path.cmp(&b.path));
    specs
}
