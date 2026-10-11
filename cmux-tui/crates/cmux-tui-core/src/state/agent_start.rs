//! Where a new agent chat of a workspace starts (cx-nn3e, cx-9aps): the one
//! owner of that decision. `workspace.agent_start.get {cwd?}` answers
//! `{cwd, kind, agent_home, skipped?}`; the app's pane and its page only show
//! the answer and send it with `session/new`.
//!
//! The rules, first match wins:
//! 1. `seed`: the folder the caller names (the selected tab's folder for New
//!    Agent Chat, the New Tab page's folder, a folder the user picked).
//! 2. `chosen`: the workspace's agent folder (`workspace.agent_folder.set`).
//! 3. `workspace`: the first folder of the workspace's terminal tabs, in
//!    screen, pane and tab order.
//! 4. `agent_home`: the workspace's private agent-home folder,
//!    `<data dir>/cmux/agent-home/<workspace id>` (the app makes it).
//!
//! A candidate counts only when it names an existing folder (made canonical
//! here) that is not the user's home folder, not a folder above it, and not
//! inside agent-home. A seed that does not count is reported in `skipped`
//! with its reason (`home`, `above_home`, `agent_home`, `missing`), so the
//! pane can ask about a home folder the user picked instead of starting there.
//! The home folder is never a default: only the user's answer in the pane
//! starts one chat there.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::ResourceError;

/// Advertised by `identify` once `workspace.agent_start.get` exists.
pub(crate) const CAPABILITY: &str = "workspace-agent-start-v1";
/// The longest seed accepted (PATH_MAX on macOS and Linux).
const MAX_PATH_BYTES: usize = 4096;

/// Why a folder is no start folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Skip {
    Home,
    AboveHome,
    AgentHome,
    Missing,
}

impl Skip {
    fn as_str(self) -> &'static str {
        match self {
            Self::Home => "home",
            Self::AboveHome => "above_home",
            Self::AgentHome => "agent_home",
            Self::Missing => "missing",
        }
    }
}

/// What the rules read: plain values, so the rules run without a daemon.
pub(crate) struct Inputs<'a> {
    pub seed: Option<&'a str>,
    pub chosen: Option<&'a str>,
    pub tab_folders: &'a [String],
    pub home: Option<&'a Path>,
    pub agent_home_base: Option<&'a Path>,
    pub workspace_id: &'a str,
}

/// `<data dir>/cmux/agent-home`: `~/Library/Application Support` on macOS,
/// `%APPDATA%` on Windows, `$XDG_DATA_HOME` (else `~/.local/share`)
/// elsewhere, as `dirs::data_dir` (acpmux's `trust::agent_home_root`) and the
/// app's `AgentHome.standard` name it.
pub(crate) fn agent_home_base(home: Option<&Path>) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    let data = home.map(|home| home.join("Library").join("Application Support"));
    #[cfg(windows)]
    let data = std::env::var_os("APPDATA").map(PathBuf::from).filter(|path| path.is_absolute());
    #[cfg(all(not(target_os = "macos"), not(windows)))]
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| home.map(|home| home.join(".local").join("share")));
    data.map(|data| data.join("cmux").join("agent-home"))
}

/// A workspace id that names a folder: 1 to 128 of `[A-Za-z0-9_-]`.
fn safe_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// `path` canonical when it is a start folder, else why not.
pub(crate) fn check(
    path: &str,
    home: Option<&Path>,
    agent_home_base: Option<&Path>,
) -> Result<PathBuf, Skip> {
    if path.is_empty()
        || path.len() > MAX_PATH_BYTES
        || path.contains('\0')
        || !Path::new(path).is_absolute()
    {
        return Err(Skip::Missing);
    }
    let folder = std::fs::canonicalize(path).map_err(|_| Skip::Missing)?;
    if !folder.is_dir() {
        return Err(Skip::Missing);
    }
    if folder.parent().is_none() {
        return Err(Skip::AboveHome);
    }
    // No known home folder: fail closed, nothing counts as a start folder.
    let Some(home) = home.map(canonical) else { return Err(Skip::Home) };
    if folder == home {
        return Err(Skip::Home);
    }
    if home.starts_with(&folder) {
        return Err(Skip::AboveHome);
    }
    if let Some(base) = agent_home_base.map(canonical)
        && folder.starts_with(&base)
    {
        return Err(Skip::AgentHome);
    }
    Ok(folder)
}

/// The answer for `inputs` (the rules in the module comment).
pub(crate) fn resolve(inputs: &Inputs<'_>) -> Value {
    let agent_home = inputs
        .agent_home_base
        .filter(|_| safe_id(inputs.workspace_id))
        .map(|base| base.join(inputs.workspace_id).to_string_lossy().into_owned());
    let mut answer = serde_json::Map::new();
    answer.insert("agent_home".into(), json!(agent_home));
    let check = |path: &str| check(path, inputs.home, inputs.agent_home_base);
    let mut found: Option<(PathBuf, &str)> = None;
    if let Some(seed) = inputs.seed {
        match check(seed) {
            Ok(folder) => found = Some((folder, "seed")),
            Err(skip) => {
                answer.insert("skipped".into(), json!({"cwd": seed, "reason": skip.as_str()}));
            }
        }
    }
    if found.is_none() {
        found =
            inputs.chosen.and_then(|chosen| check(chosen).ok()).map(|folder| (folder, "chosen"));
    }
    if found.is_none() {
        found = inputs
            .tab_folders
            .iter()
            .find_map(|folder| check(folder).ok())
            .map(|folder| (folder, "workspace"));
    }
    match found {
        Some((folder, kind)) => {
            answer.insert("cwd".into(), json!(folder.to_string_lossy()));
            answer.insert("kind".into(), json!(kind));
        }
        None => {
            answer.insert("cwd".into(), json!(agent_home));
            answer.insert("kind".into(), json!("agent_home"));
        }
    }
    Value::Object(answer)
}

/// The folders of `workspace`'s terminal tabs, in screen, pane and tab order,
/// read from the public snapshot (`snapshot.terminals[].cwd`).
pub(crate) fn tab_folders(snapshot: &Value, workspace: &str) -> Vec<String> {
    let list = |key: &str| snapshot[key].as_array().cloned().unwrap_or_default();
    let ordered = |mut items: Vec<Value>| {
        items.sort_by_key(|item| item["index"].as_u64().unwrap_or(u64::MAX));
        items
    };
    let screens: Vec<String> = ordered(list("screens"))
        .into_iter()
        .filter(|screen| screen["workspace_id"] == workspace)
        .filter_map(|screen| screen["id"].as_str().map(str::to_owned))
        .collect();
    let panes: Vec<String> = screens
        .iter()
        .flat_map(|screen| {
            list("panes")
                .into_iter()
                .filter(move |pane| pane["screen_id"] == screen.as_str())
                .filter_map(|pane| pane["id"].as_str().map(str::to_owned))
        })
        .collect();
    let terminals = list("terminals");
    let mut folders = Vec::new();
    for pane in &panes {
        for tab in ordered(list("tabs")).into_iter().filter(|tab| tab["pane_id"] == pane.as_str()) {
            if tab["content_kind"] != "terminal" {
                continue;
            }
            let cwd = terminals
                .iter()
                .find(|terminal| terminal["id"] == tab["content_id"])
                .and_then(|terminal| terminal["cwd"].as_str());
            if let Some(cwd) = cwd
                && !folders.iter().any(|folder| folder == cwd)
            {
                folders.push(cwd.to_owned());
            }
        }
    }
    folders
}

impl Mux {
    /// `workspace.agent_start.get`.
    pub(crate) fn agent_start(
        &self,
        selectors: &crate::ResourceSelectors,
        seed: Option<&str>,
    ) -> Result<Value, ResourceError> {
        if let Some(seed) = seed
            && (seed.is_empty() || seed.len() > MAX_PATH_BYTES)
        {
            return Err(ResourceError::validation_invalid(
                Some("cwd"),
                "cwd must be 1 to 4096 bytes",
            ));
        }
        let workspace = self
            .resolve_resource_path(crate::ResourceTarget::Workspace, selectors)?
            .workspace
            .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>"))?;
        let id = workspace.as_str().to_owned();
        // The agent-home folder is named by the workspace's durable key, as the app names it
        // (`AgentHome.path(for: workspace.id)`) and moves it on a History reopen.
        let key = self
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .find(|candidate| candidate.public_id.as_str() == id)
                    .map(|candidate| candidate.key.clone())
            })
            .ok_or_else(|| ResourceError::not_found("workspace", &id))?;
        let chosen = self
            .read_registry_state(|connection| super::agent_folder::agent_folder(connection, &id))
            .map_err(crate::resource_api::operation_failed)?;
        let snapshot = crate::resource_api::public_session_snapshot(self)?;
        let folders = tab_folders(&snapshot, &id);
        let home = crate::platform::home_dir();
        let base = agent_home_base(home.as_deref());
        Ok(resolve(&Inputs {
            seed,
            chosen: chosen.as_deref(),
            tab_folders: &folders,
            home: home.as_deref(),
            agent_home_base: base.as_deref(),
            workspace_id: &key,
        }))
    }
}
