//! Reads classic's `session-<bundle>.json` into a [`Snapshot`]: topology,
//! names, folders, titles, pages, agent sessions, scrollback, where each
//! workspace ran, and each window's groups. Names are made unique across
//! every window. The file is checked against [`crate::limits`] before
//! anything is built from it.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::limits::{self, Budget, objects, strings};
use crate::model::{
    Agent, Group, Layout, Orientation, Pane, Rect, Remote, Snapshot, Tab, Window, Workspace,
};
use crate::names::{self, non_empty, text, trim_spaces};

/// Why a classic session could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    TooLarge {
        actual: usize,
        maximum: usize,
    },
    /// The file is JSON but not a session object (a damaged or foreign file).
    NotASnapshot,
    /// It holds too much saved state to import safely.
    TooComplex,
    /// It is not JSON.
    Json(String),
    Io(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::TooLarge { actual, maximum } => {
                write!(
                    formatter,
                    "the classic session is too large to read ({actual} bytes, at most {maximum})"
                )
            }
            Error::NotASnapshot => {
                formatter.write_str("the classic session file is not a session snapshot")
            }
            Error::TooComplex => {
                formatter.write_str("the classic session has too much saved state to import safely")
            }
            Error::Json(error) => write!(formatter, "the classic session is not JSON: {error}"),
            Error::Io(error) => write!(formatter, "the classic session could not be read: {error}"),
        }
    }
}

impl std::error::Error for Error {}

/// Classic's stable bundle id, whose session is read when no channel saved one.
pub const STABLE_BUNDLE_ID: &str = "com.cmuxterm.app";

/// Whether `bundle` is a classic channel's bundle id (debug builds included).
pub fn is_classic_bundle_id(bundle: &str) -> bool {
    const CHANNELS: [&str; 5] = [
        STABLE_BUNDLE_ID,
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.staging",
        "com.cmuxterm.app.debug",
    ];
    CHANNELS.contains(&bundle)
        || CHANNELS[1..]
            .iter()
            .any(|channel| bundle.strip_prefix(channel).is_some_and(|rest| rest.starts_with('.')))
}

/// The session classic saved last under `support` (its `cmux` folder), any
/// channel; stable's path when none is there.
pub fn newest_snapshot(support: &Path) -> PathBuf {
    let folder = support.join("cmux");
    let newest = std::fs::read_dir(&folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let bundle = name.strip_prefix("session-")?.strip_suffix(".json")?;
            if !is_classic_bundle_id(bundle) {
                return None;
            }
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((folder.join(&name), modified))
        })
        .fold(None::<(PathBuf, std::time::SystemTime)>, |best, next| match best {
            Some(best) if best.1 >= next.1 => Some(best),
            _ => Some(next),
        });
    newest.map_or_else(|| folder.join(format!("session-{STABLE_BUNDLE_ID}.json")), |(path, _)| path)
}

/// The folder of scrollback checkpoints classic keeps beside `session`
/// (`session-<bundle>-scrollback/`, one `<panel id>.json` per terminal);
/// none for a `session-history` archive, whose terminals are older.
pub fn checkpoint_folder(session: &Path) -> Option<PathBuf> {
    let name = session.file_name()?.to_str()?;
    let parent = session.parent()?;
    if parent.file_name().and_then(|name| name.to_str()) == Some("session-history") {
        return None;
    }
    let stem = name.strip_prefix("session-")?.strip_suffix(".json")?;
    let stem = stem.strip_suffix("-previous").unwrap_or(stem);
    Some(parent.join(format!("session-{stem}-scrollback")))
}

/// The session at `path`, with checkpoint scrollback beside it; none when
/// there is no file.
pub fn read_file(path: &Path, home: &str) -> Result<Option<Snapshot>, Error> {
    let Some(data) = limits::read_capped(path, limits::MAX_SNAPSHOT_BYTES)? else {
        return Ok(None);
    };
    decode(&data, checkpoint_folder(path).as_deref(), home).map(Some)
}

/// Decodes a session's bytes. Each terminal's scrollback comes from
/// classic's checkpoint in `checkpoints` when the snapshot itself carries no
/// scrollback at all: an 8 s autosave, the last save before classic crashed,
/// was force quit or the Mac lost power. A quit save's own scrollback always
/// wins, as in classic's restore. `home` is the folder a workspace without
/// one names.
pub fn decode(data: &[u8], checkpoints: Option<&Path>, home: &str) -> Result<Snapshot, Error> {
    limits::validate_encoded(data, limits::MAX_SNAPSHOT_BYTES)?;
    let root: Value =
        serde_json::from_slice(data).map_err(|error| Error::Json(error.to_string()))?;
    let Some(object) = root.as_object() else { return Err(Error::NotASnapshot) };
    let windows = objects(object.get("windows")).unwrap_or_default();
    if windows.len() > limits::MAX_WINDOWS {
        return Err(Error::TooComplex);
    }
    let managers: Vec<&Map<String, Value>> = windows
        .iter()
        .map(|window| {
            ["tabManager", "tab_manager"]
                .iter()
                .find_map(|name| window.get(*name).and_then(Value::as_object))
                .unwrap_or(&EMPTY)
        })
        .collect();
    let per_window: Vec<Vec<&Map<String, Value>>> = managers
        .iter()
        .map(|manager| objects(manager.get("workspaces")).unwrap_or_default())
        .collect();
    let all: Vec<&Map<String, Value>> = per_window.iter().flatten().copied().collect();
    if all.len() > limits::MAX_WORKSPACES {
        return Err(Error::TooComplex);
    }
    let mut budget = Budget::default();
    limits::validate_json(&root, &mut budget)?;
    for workspace in &all {
        limits::validate_workspace(workspace, &mut budget)?;
    }
    // Classic merges checkpoints only after an unclean exit, whose last save
    // is an autosave: one without any scrollback.
    let mut scrollback = Checkpoints {
        folder: checkpoints.filter(|_| !carries_scrollback(&all)).map(Path::to_path_buf),
        spent: 0,
    };
    let clues: Vec<names::Clues> =
        all.iter().map(|workspace| names::clues(workspace, home)).collect();
    let mut names = names::names(&clues).into_iter();
    let mut decoded = Vec::with_capacity(windows.len());
    for ((window, manager), workspaces) in windows.iter().zip(&managers).zip(&per_window) {
        let workspaces = workspaces
            .iter()
            .map(|value| {
                let name = names.next().unwrap_or_default();
                workspace(value, name, home, &mut scrollback)
            })
            .collect();
        let groups = ["workspaceGroups", "workspace_groups"]
            .iter()
            .find_map(|name| objects(manager.get(*name)))
            .unwrap_or_default();
        decoded.push(Window {
            id: text(window, &["windowId", "window_id"]).map(str::to_string),
            frame: rect(window.get("frame")),
            selected_workspace: ["selectedWorkspaceIndex", "selected_workspace_index"]
                .iter()
                .find_map(|name| integer(manager.get(*name))),
            workspaces,
            groups: groups.into_iter().filter_map(group).collect(),
        });
    }
    Ok(Snapshot {
        version: integer(object.get("version")).unwrap_or(1),
        created_at: object.get("createdAt").and_then(Value::as_f64),
        windows: decoded,
    })
}

static EMPTY: std::sync::LazyLock<Map<String, Value>> = std::sync::LazyLock::new(Map::new);

fn integer(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value.as_i64().or_else(|| value.as_f64().map(|number| number as i64))
}

fn rect(value: Option<&Value>) -> Option<Rect> {
    let value = value?.as_object()?;
    let number = |name: &str| value.get(name).and_then(Value::as_f64);
    let rect = Rect {
        x: number("x")?,
        y: number("y")?,
        width: number("width")?,
        height: number("height")?,
    };
    (rect.width > 0.0 && rect.height > 0.0).then_some(rect)
}

fn flag(value: &Map<String, Value>, names: &[&str]) -> bool {
    names.iter().find_map(|name| value.get(*name).and_then(Value::as_bool)).unwrap_or(false)
}

fn group(value: &Map<String, Value>) -> Option<Group> {
    let id = non_empty(value, &["id"])?.to_string();
    Some(Group {
        id,
        name: text(value, &["name"]).unwrap_or_default().to_string(),
        collapsed: flag(value, &["isCollapsed", "is_collapsed"]),
        pinned: flag(value, &["isPinned", "is_pinned"]),
        color: non_empty(value, &["customColor", "custom_color"]).map(str::to_string),
        icon: non_empty(value, &["iconSymbol", "icon_symbol"]).map(str::to_string),
    })
}

/// Whether any terminal carries its own scrollback (a quit save).
fn carries_scrollback(workspaces: &[&Map<String, Value>]) -> bool {
    workspaces.iter().any(|workspace| {
        objects(workspace.get("panels")).unwrap_or_default().iter().any(|panel| {
            panel
                .get("terminal")
                .and_then(|terminal| terminal.get("scrollback"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.is_empty())
        })
    })
}

/// Scrollback from classic's checkpoints, within the total scrollback budget.
struct Checkpoints {
    folder: Option<PathBuf>,
    spent: usize,
}

impl Checkpoints {
    /// The scrollback classic's checkpoint holds for `panel`
    /// (`<folder>/<PANEL UUID>.json`, `{panelId, scrollback, ...}`); none
    /// when there is none or it records another panel.
    fn take(&mut self, panel: &str) -> Option<String> {
        let folder = self.folder.as_ref()?;
        let remaining =
            limits::MAX_TOTAL_SCROLLBACK_BYTES.checked_sub(self.spent).filter(|left| *left > 0)?;
        let name = panel.to_uppercase();
        // Panel ids are UUIDs; anything else is not a file name to read.
        if !is_uuid(&name) {
            return None;
        }
        let maximum = limits::MAX_SCROLLBACK_BYTES.min(remaining);
        let data = limits::read_capped(&folder.join(format!("{name}.json")), maximum).ok()??;
        limits::validate_encoded(&data, maximum).ok()?;
        let record: Value = serde_json::from_slice(&data).ok()?;
        if record.get("panelId")?.as_str()?.to_uppercase() != name {
            return None;
        }
        let text = record.get("scrollback")?.as_str().filter(|text| !text.is_empty())?;
        if text.len() > remaining {
            return None;
        }
        self.spent += text.len();
        Some(text.to_string())
    }
}

/// `8-4-4-4-12` hexadecimal digits.
fn is_uuid(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(group, length)| {
            group.len() == length && group.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
}

fn workspace(
    value: &Map<String, Value>,
    name: String,
    home: &str,
    checkpoints: &mut Checkpoints,
) -> Workspace {
    let panels = objects(value.get("panels")).unwrap_or_default();
    let entries: Vec<(&str, Tab)> = panels
        .iter()
        .filter_map(|panel| {
            let id = panel.get("id")?.as_str()?;
            tab(panel, || checkpoints.take(id)).map(|tab| (id, tab))
        })
        .collect();
    // Panels nothing here can show (markdown, file preview) stay in classic.
    let left_out_panels = panels.iter().any(|panel| {
        !matches!(
            panel.get("type").and_then(Value::as_str).unwrap_or("terminal"),
            "terminal" | "browser"
        )
    });
    // A snapshot can name a panel twice; the first wins.
    let mut by_id: std::collections::HashMap<&str, &Tab> = std::collections::HashMap::new();
    for (id, tab) in &entries {
        by_id.entry(id).or_insert(tab);
    }
    let layout = match value.get("layout").and_then(Value::as_object) {
        Some(layout_value) => layout(layout_value, &by_id),
        None => {
            let mut seen = std::collections::HashSet::new();
            let tabs = entries
                .iter()
                .filter(|(id, _)| seen.insert(*id))
                .map(|(_, tab)| tab.clone())
                .collect();
            Layout::Pane(Pane { tabs, selected_tab: 0 })
        }
    };
    Workspace {
        key: names::key(value, &name, home),
        name,
        working_directory: names::directory(value, home),
        layout,
        remote: remote(value),
        cloud_vm: cloud_vm(value),
        left_out_panels,
        color: non_empty(value, &["customColor", "custom_color"]).map(str::to_string),
        pinned: value.get("isPinned").and_then(Value::as_bool).unwrap_or(false),
        group_id: non_empty(value, &["groupId", "group_id"]).map(str::to_string),
    }
}

/// A terminal or browser panel as a tab; none for a panel nothing here can
/// show. Old snapshots name no type.
fn tab(panel: &Map<String, Value>, checkpoint: impl FnOnce() -> Option<String>) -> Option<Tab> {
    match panel.get("type").and_then(Value::as_str).unwrap_or("terminal") {
        "terminal" => {
            let terminal = panel.get("terminal").and_then(Value::as_object);
            let directory = terminal
                .and_then(|terminal| text(terminal, &["workingDirectory", "working_directory"]))
                .or_else(|| text(panel, &["directory", "working_directory"]))
                .map(str::to_string);
            let agent = terminal.and_then(|terminal| {
                running_agent(terminal.get("agent"), directory.as_deref())
                    .or_else(|| ended_agent(terminal.get("resumeBinding"), directory.as_deref()))
            });
            let own = terminal
                .and_then(|terminal| terminal.get("scrollback"))
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty());
            Some(Tab {
                title: text(panel, &["customTitle", "title"]).map(str::to_string),
                working_directory: directory,
                url: None,
                agent,
                scrollback: own.map(str::to_string).or_else(checkpoint),
            })
        }
        "browser" => {
            let browser = panel.get("browser").and_then(Value::as_object)?;
            let url = text(browser, &["urlString", "url_string"]).filter(|url| !url.is_empty())?;
            // Only the person's own title: a page's title is the page's to set.
            Some(Tab {
                working_directory: None,
                title: text(panel, &["customTitle"]).map(str::to_string),
                url: Some(url.to_string()),
                agent: None,
                scrollback: None,
            })
        }
        _ => None,
    }
}

/// A Claude Code or Codex session classic recorded; other agents have no
/// acpmux harness to resume them.
fn running_agent(value: Option<&Value>, directory: Option<&str>) -> Option<Agent> {
    let value = value?.as_object()?;
    let kind = value.get("kind")?.as_str().filter(|kind| matches!(*kind, "claude" | "codex"))?;
    let session = non_empty(value, &["sessionId", "session_id"])?;
    Some(Agent {
        harness: kind.to_string(),
        session_id: session.to_string(),
        working_directory: text(value, &["workingDirectory", "working_directory"])
            .or(directory)
            .map(str::to_string),
    })
}

/// The session of an agent that exited: classic then keeps only its
/// `resumeBinding` (`checkpointId` is the session id). Only a binding the
/// agent's own hook recorded names a session; a persistent SSH launch's
/// session is on its host, not this Mac.
fn ended_agent(binding: Option<&Value>, directory: Option<&str>) -> Option<Agent> {
    let binding = binding?.as_object()?;
    if binding.get("source").and_then(Value::as_str) != Some("agent-hook") {
        return None;
    }
    let flavor =
        binding.get("launchFlavor").and_then(|flavor| flavor.get("kind")).and_then(Value::as_str);
    if flavor.unwrap_or("local") != "local" {
        return None;
    }
    let kind = binding.get("kind")?.as_str().filter(|kind| matches!(*kind, "claude" | "codex"))?;
    let session = binding.get("checkpointId")?.as_str().filter(|id| !id.is_empty())?;
    Some(Agent {
        harness: kind.to_string(),
        session_id: session.to_string(),
        working_directory: text(binding, &["cwd"]).or(directory).map(str::to_string),
    })
}

/// An SSH workspace's host. A websocket `remote` is an older Cloud VM, not SSH.
fn remote(value: &Map<String, Value>) -> Option<Remote> {
    let remote = value.get("remote")?.as_object()?;
    if legacy_cloud_vm(remote).is_some() || text(remote, &["transport"]).unwrap_or("ssh") != "ssh" {
        return None;
    }
    let destination = trim_spaces(remote.get("destination")?.as_str()?);
    if destination.is_empty() || destination.starts_with('-') {
        return None;
    }
    Some(Remote { destination: destination.to_string(), port: integer(remote.get("port")) })
}

/// The Cloud VM a workspace ran on: `cloudVM`, or an older one saved as a
/// websocket `remote` with `managedCloudVMID`.
fn cloud_vm(value: &Map<String, Value>) -> Option<String> {
    if let Some(vm) =
        ["cloudVM", "cloud_vm"].iter().find_map(|name| value.get(*name).and_then(Value::as_object))
    {
        return Some(text(vm, &["vmID", "vm_id"]).unwrap_or_default().to_string());
    }
    value.get("remote").and_then(Value::as_object).and_then(legacy_cloud_vm)
}

fn legacy_cloud_vm(remote: &Map<String, Value>) -> Option<String> {
    let id = text(remote, &["managedCloudVMID", "managed_cloud_vm_id"]).map(trim_spaces);
    if let Some(id) = id.filter(|id| !id.is_empty()) {
        return Some(id.to_string());
    }
    (remote.get("transport").and_then(Value::as_str) == Some("websocket")).then(String::new)
}

fn layout(value: &Map<String, Value>, panels: &std::collections::HashMap<&str, &Tab>) -> Layout {
    if value.get("type").and_then(Value::as_str) == Some("split") {
        let split = value.get("split").and_then(Value::as_object).unwrap_or(value);
        let orientation = match split.get("orientation").and_then(Value::as_str) {
            Some("vertical") => Orientation::Vertical,
            _ => Orientation::Horizontal,
        };
        let ratio = ["dividerPosition", "ratio"]
            .iter()
            .find_map(|name| split.get(*name).and_then(Value::as_f64))
            .unwrap_or(0.5);
        let side = |name: &str| {
            layout(split.get(name).and_then(Value::as_object).unwrap_or(&EMPTY), panels)
        };
        let (first, second) = (side("first"), side("second"));
        // A side with no tab left closes up; the other takes its space.
        let empty = |layout: &Layout| matches!(layout, Layout::Pane(pane) if pane.tabs.is_empty());
        if empty(&second) {
            return first;
        }
        if empty(&first) {
            return second;
        }
        return Layout::Split {
            orientation,
            ratio: ratio.clamp(0.05, 0.95),
            first: Box::new(first),
            second: Box::new(second),
        };
    }
    let pane = value.get("pane").and_then(Value::as_object).unwrap_or(value);
    let ids = strings(pane.get("panelIds"))
        .or_else(|| strings(pane.get("panel_ids")))
        .unwrap_or_default();
    // Only panels the snapshot still has become tabs; the selection counts those.
    let resolved: Vec<&str> = ids.into_iter().filter(|id| panels.contains_key(id)).collect();
    let tabs = resolved.iter().map(|id| (*panels[id]).clone()).collect();
    let selected = text(pane, &["selectedPanelId", "selected_panel_id"])
        .and_then(|chosen| resolved.iter().position(|id| *id == chosen))
        .unwrap_or(0);
    Layout::Pane(Pane { tabs, selected_tab: selected })
}
