//! `open`: a file, a diff or a web page in a cmux viewer tab, placed where the person
//! asked (right, left, below, above, here, a sticky column, a named pane or workspace),
//! in one call.
//!
//! Before it, "open notes.md on my left" took an agent a split, the app's `file.open`
//! with that split's pane as `target`, and often a docs search and a layout read; a
//! sticky column also needed a viewport column (only `pane_split` with `viewport_width`
//! makes one) and `column_update`. Agents found that path in 0 of 4 samples
//! (tests/tool-evals open-r16b), and every open cost 2 to 4 steps (about 20k tokens a
//! step). This tool runs the same calls inside the server.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{Backend, Server, envelope, tool_error, v2_tools};

pub(super) const NAME: &str = "open";

/// The width a new right column takes (`crate::cli::beside::NEW_COLUMN_WIDTH`).
const COLUMN_WIDTH: f64 = 0.5;

fn stage_key(open_id: &str, phase: &str) -> String {
    let mut hash = Sha256::new();
    for part in ["cmux.mcp.open.v1", open_id, phase] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    format!("mcp-open-{:x}", hash.finalize())
}

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Open a file, diff or page",
        "description": "Open a file, a diff or a web page in a cmux viewer tab, where the person asked, in one call. kind: file (path), diff (path: a file or folder; none for the working tree's changes) or page (url). where: right (the column right of this chat, made when there is none), left, below, above (a new pane on that side of this chat's pane, or of pane), here (this chat's own pane), sticky (a column docked to edge, default right; an existing docked column takes it), pane (a tab in pane), workspace (a tab in that workspace, which stays in the background). The person's view stays unless focus is true.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["kind"],
            "properties": {
                "kind": {"type": "string", "enum": ["file", "diff", "page"]},
                "path": {"type": "string", "minLength": 1, "description": "A file or folder: absolute, or relative to this chat's folder."},
                "url": {"type": "string", "minLength": 1, "description": "An http or https address."},
                "where": {"type": "string", "enum": ["right", "left", "below", "above", "here", "sticky", "pane", "workspace"], "description": "Default right."},
                "pane": {"type": "string", "description": "With pane: the pane that gets the tab. With left, below or above: the pane to split (default this chat's)."},
                "workspace": {"type": "string", "description": "With workspace: the workspace that gets the tab."},
                "edge": {"type": "string", "enum": ["right", "left", "top", "bottom"], "description": "With sticky: the edge the column docks to. Default right."},
                "focus": {"type": "boolean", "description": "true moves the person's view to the new tab. Default false."},
                "idempotency_key": {"type": "string", "minLength": 1, "maxLength": 128,
                                    "description": "Stable identity for the whole split/open call. Reuse on retry."}
            }
        },
        "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
    })
}

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

fn text<'a>(arguments: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    arguments.get(key).and_then(Value::as_str).filter(|value| !value.is_empty())
}

impl<B: Backend> Server<B> {
    /// Runs `open`: the target pane first (a split, a column or a named pane), then the
    /// app's open action into it.
    pub(super) fn call_open(&self, arguments: &Map<String, Value>) -> Value {
        let known = ["kind", "path", "url", "where", "pane", "workspace", "edge", "focus", "idempotency_key"];
        if let Some(name) = arguments.keys().find(|name| !known.contains(&name.as_str())) {
            return invalid(format!("open has no argument {name:?}"));
        }
        let kind = text(arguments, "kind").unwrap_or_default();
        let (action, value_key) = match kind {
            "file" => ("file open", "path"),
            "diff" => ("browser open-diff-viewer", "path"),
            "page" => ("tab new-browser", "url"),
            _ => return invalid("open needs kind: file, diff or page"),
        };
        let value = text(arguments, value_key);
        if kind != "diff" && value.is_none() {
            return invalid(format!("open needs {value_key} for a {kind}"));
        }
        // `where` is a word; an object names its pane or workspace (`where: {workspace: id}`,
        // which a model wrote and which opened on the right before). Anything else is refused,
        // never read as the default.
        let mut arguments = arguments.clone();
        let place = match arguments.get("where").cloned() {
            None => "right".to_owned(),
            Some(Value::String(place)) => place,
            Some(Value::Object(named)) => {
                let Some((key, value)) = ["pane", "workspace"]
                    .iter()
                    .find_map(|key| named.get(*key).map(|value| (*key, value.clone())))
                else {
                    return invalid("open where must be a word, or {pane} or {workspace}");
                };
                arguments.insert(key.into(), value);
                key.to_owned()
            }
            Some(_) => return invalid("open where must be a word, or {pane} or {workspace}"),
        };
        let arguments = &arguments;
        let place = place.as_str();
        let focus = arguments.get("focus").and_then(Value::as_bool).unwrap_or(false);
        let open_id = match arguments.get("idempotency_key") {
            Some(Value::String(key)) => {
                if let Err(error) = cmux_tui_core::resource::validate_idempotency_key(key) {
                    return invalid(error.message);
                }
                key.to_owned()
            }
            Some(_) => return invalid("open idempotency_key must be a nonempty string"),
            None => match super::super::wire::random_idempotency_key() {
                Ok(key) => key,
                Err(error) => return invalid(error.0),
            },
        };
        // The app first: with no app to show the viewer, no split is left behind.
        let Some(tool) = self.actions.iter().find(|tool| tool.cli_name == action) else {
            return invalid(
                "open needs the cmux app, and no cmux app answers in this session; say so to \
                 the person, or show the text in a terminal",
            );
        };
        // The app reads a path in its own process: a relative one is made absolute here,
        // against the chat's folder (`file open` and the diff viewer refuse anything else).
        let value = match value {
            Some(value) if kind != "page" => Some(self.chat_path(value)),
            value => value.map(str::to_owned),
        };
        let (target, made) = match self.open_target(place, arguments, &open_id) {
            Ok(target) => target,
            Err(answer) => return self.failed_open(None, answer, &open_id),
        };
        // A page opens as a tab beside a tab (`tab new-browser` takes a tab target, not a
        // pane): the pane's shown tab.
        let target = match (kind, target) {
            ("page", Some(pane)) => match self.shown_tab(&pane) {
                Ok(tab) => Some(tab),
                Err(answer) => return self.failed_open(made, answer, &open_id),
            },
            (_, target) => target,
        };
        let mut run = Map::new();
        if let Some(value) = value {
            run.insert(value_key.into(), json!(value));
        }
        if let Some(target) = &target {
            run.insert("target".into(), json!(target));
        }
        if focus {
            run.insert("focus".into(), json!(true));
        }
        run.insert("idempotency_key".into(), json!(stage_key(&open_id, "app")));
        let answer = self.call_action(tool, &run);
        if answer.get("isError").and_then(Value::as_bool) == Some(true) {
            return self.failed_open(made, answer, &open_id);
        }
        if let Some(mut receipt) = answer.get("structuredContent").cloned()
            && let Some(object) = receipt.as_object_mut()
        {
            object.insert("open_idempotency_key".into(), json!(open_id));
            return super::success(receipt, true);
        }
        answer
    }

    /// Only a confirmed refusal may undo an owned split. An app action can
    /// complete before its acknowledgement arrives; on in_progress the
    /// viewer may already be open, and closing its pane would discard it.
    fn failed_open(&self, made: Option<String>, answer: Value, open_id: &str) -> Value {
        if answer.pointer("/structuredContent/state").and_then(Value::as_str) == Some("in_progress") {
            let Some(mut receipt) = answer.get("structuredContent").cloned() else {
                return answer;
            };
            let Some(record) = receipt.as_object_mut() else { return answer };
            if let Some(pane) = made {
                record.insert("created_pane".into(), json!(pane));
            }
            record.insert("open_idempotency_key".into(), json!(open_id));
            record.insert(
                "recovery".into(),
                json!("The app may already have opened the viewer. Inspect created_pane and the app tabs; retry open with the same open_idempotency_key to reconcile the split and app action."),
            );
            return tool_error(receipt);
        }
        self.undo_split(made, answer)
    }

    /// After a failed open, closes the pane the call split for it, so a refused open leaves
    /// the layout as it was.
    fn undo_split(&self, made: Option<String>, answer: Value) -> Value {
        if let Some(pane) = made {
            let _ = self.read(
                v2_tools::find("pane_close"),
                &Map::from_iter([("pane".into(), json!(pane))]),
            );
        }
        answer
    }

    /// `path` as the app must read it: absolute, `~/` expanded, a relative path joined to
    /// the chat's folder (its terminal's working folder, else this server's).
    pub(super) fn chat_path(&self, path: &str) -> String {
        use std::path::{Component, Path, PathBuf};
        if let Some(rest) = path.strip_prefix("~/").or((path == "~").then_some(""))
            && let Some(home) = std::env::var_os("HOME")
        {
            return PathBuf::from(home).join(rest).to_string_lossy().into_owned();
        }
        if Path::new(path).is_absolute() {
            return path.to_owned();
        }
        let folder = self.chat_folder().or_else(|| std::env::current_dir().ok());
        let Some(folder) = folder else { return path.to_owned() };
        let joined: PathBuf = folder
            .join(path)
            .components()
            .filter(|part| !matches!(part, Component::CurDir))
            .collect();
        joined.to_string_lossy().into_owned()
    }

    /// The working folder of the chat's terminal (`terminal_process_get`), when the chat
    /// runs in one.
    fn chat_folder(&self) -> Option<std::path::PathBuf> {
        let terminal = self.backend.caller_terminal()?;
        let process = self
            .read(
                v2_tools::find("terminal_process_get"),
                &Map::from_iter([("terminal".into(), json!(terminal))]),
            )
            .ok()?;
        ["foreground_cwd", "cwd"]
            .iter()
            .find_map(|key| {
                process.get(*key).and_then(Value::as_str).filter(|cwd| cwd.starts_with('/'))
            })
            .map(std::path::PathBuf::from)
    }

    /// The tab a pane shows: its focused tab, else its first.
    fn shown_tab(&self, pane: &str) -> Result<String, Value> {
        let list = Map::from_iter([("pane".into(), json!(pane)), ("limit".into(), json!(500))]);
        let tabs = self.read(v2_tools::find("tab_list"), &list)?;
        let items = tabs.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
        items
            .iter()
            .find(|tab| tab.get("focused").and_then(Value::as_bool) == Some(true))
            .or_else(|| items.first())
            .and_then(|tab| tab.get("id").and_then(Value::as_str))
            .map(str::to_owned)
            .ok_or_else(|| invalid("open: that pane has no tab to open the page beside"))
    }

    /// The pane the viewer goes into, and the pane this call made for it (closed again
    /// when the open fails). A side splits, `right` reuses or makes the column right of the
    /// chat, `sticky` reuses or docks a column.
    fn open_target(
        &self,
        place: &str,
        arguments: &Map<String, Value>,
        open_id: &str,
    ) -> Result<(Option<String>, Option<String>), Value> {
        let pane = text(arguments, "pane");
        let made = |pane: String| (Some(pane.clone()), Some(pane));
        let found = |pane: String| (Some(pane), None);
        match place {
            "here" => self.pane_id(&Map::from_iter([("pane".into(), json!("current"))])).map(found),
            "pane" => {
                let pane = pane.ok_or_else(|| invalid("open where: pane needs pane"))?;
                self.pane_id(&Map::from_iter([("pane".into(), json!(pane))])).map(found)
            }
            "workspace" => {
                let workspace = text(arguments, "workspace")
                    .ok_or_else(|| invalid("open where: workspace needs workspace"))?;
                let mut list = Map::new();
                list.insert("workspace".into(), json!(workspace));
                list.insert("limit".into(), json!(500));
                let panes = self.read(v2_tools::find("pane_list"), &list)?;
                let items =
                    panes.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
                let pane = items
                    .iter()
                    .find(|pane| pane.get("focused").and_then(Value::as_bool) == Some(true))
                    .or_else(|| items.first())
                    .and_then(|pane| pane.get("id").and_then(Value::as_str))
                    .map(str::to_owned);
                pane.map(found).ok_or_else(|| {
                    invalid("that workspace has no pane to take the tab; pane_create {workspace} makes one")
                })
            }
            "left" | "below" | "above" => {
                let direction = match place {
                    "left" => "left",
                    "below" => "down",
                    _ => "up",
                };
                let mut split = Map::new();
                split.insert("pane".into(), json!(pane.unwrap_or("current")));
                split.insert("direction".into(), json!(direction));
                self.split_pane(&split, open_id).map(made)
            }
            "right" => {
                let mut neighbor = Map::new();
                neighbor.insert("pane".into(), json!(pane.unwrap_or("current")));
                neighbor.insert("direction".into(), json!("right"));
                let answer = self.read(v2_tools::find("pane_neighbor_get"), &neighbor)?;
                if let Some(id) =
                    answer.get("pane").and_then(|pane| pane.get("id")).and_then(Value::as_str)
                {
                    return Ok(found(id.to_owned()));
                }
                let mut split = Map::new();
                split.insert("pane".into(), json!(pane.unwrap_or("current")));
                split.insert("direction".into(), json!("right"));
                split.insert("viewport_width".into(), json!(COLUMN_WIDTH));
                self.split_pane(&split, open_id).map(made)
            }
            "sticky" => self.sticky_pane(arguments, open_id),
            other => Err(invalid(format!(
                "open where must be right, left, below, above, here, sticky, pane or workspace, not {other:?}"
            ))),
        }
    }

    /// A pane in a column docked to `edge`: an existing docked column on that edge (not a
    /// column with a role, such as the agent chat's, and not the chat's own), else a new
    /// column right of the chat, docked.
    fn sticky_pane(
        &self,
        arguments: &Map<String, Value>,
        open_id: &str,
    ) -> Result<(Option<String>, Option<String>), Value> {
        let edge = text(arguments, "edge").unwrap_or("right");
        let screen = self.read(
            v2_tools::find("screen_get"),
            &Map::from_iter([("screen".into(), json!("current"))]),
        )?;
        let screen_id = screen.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
        let chat = self.pane_id(&Map::from_iter([("pane".into(), json!("current"))])).ok();
        if let Some(pane) = docked_column(screen.get("layout"), edge, chat.as_deref()) {
            return Ok((Some(pane), None));
        }
        let mut split = Map::new();
        split.insert("pane".into(), json!("current"));
        split.insert("direction".into(), json!("right"));
        split.insert("viewport_width".into(), json!(COLUMN_WIDTH));
        let pane = self.split_pane(&split, open_id)?;
        let docked = (|| {
            let screen = self.read(
                v2_tools::find("screen_get"),
                &Map::from_iter([("screen".into(), json!(&screen_id))]),
            )?;
            let column = column_of(screen.get("layout"), &pane)
                .ok_or_else(|| invalid("open: the new column is not in the screen's layout"))?;
            let mut update = Map::new();
            update.insert("screen".into(), json!(screen_id));
            update.insert("column".into(), json!(column));
            update.insert("dock".into(), json!(true));
            update.insert("edge".into(), json!(edge));
            update.insert("idempotency_key".into(), json!(stage_key(open_id, "dock")));
            self.read(v2_tools::find("column_update"), &update)
        })();
        match docked {
            Ok(_) => Ok((Some(pane.clone()), Some(pane))),
            Err(answer) => Err(self.failed_open(Some(pane), answer, open_id)),
        }
    }

    /// A pane selector's own id.
    fn pane_id(&self, arguments: &Map<String, Value>) -> Result<String, Value> {
        let record = self.read(v2_tools::find("pane_get"), arguments)?;
        record
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| invalid("open: that pane has no id"))
    }

    /// A new pane from `pane_split`: its id.
    fn split_pane(&self, arguments: &Map<String, Value>, open_id: &str) -> Result<String, Value> {
        let mut keyed = arguments.clone();
        keyed.insert("idempotency_key".into(), json!(stage_key(open_id, "split")));
        let created = self.read(v2_tools::find("pane_split"), &keyed)?;
        created
            .get("pane_id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| invalid("open: the split made no pane"))
    }
}

/// The first pane of a column docked to `edge` in a screen layout (`viewport.columns`),
/// skipping a column with a role (`dock.role`, such as `agent_chat`) and the one that
/// holds `chat`.
fn docked_column(layout: Option<&Value>, edge: &str, chat: Option<&str>) -> Option<String> {
    let columns = viewport_columns(layout?)?;
    columns.iter().find_map(|column| {
        let dock = column.get("dock")?;
        let at = dock.get("edge").and_then(Value::as_str).unwrap_or("right");
        let root = column.get("root")?;
        let free = dock.get("role").is_none_or(Value::is_null)
            && chat.is_none_or(|chat| !holds(root, chat));
        (at == edge && free).then(|| first_pane(root)).flatten()
    })
}

/// The `column_id` of the column that holds `pane`.
fn column_of(layout: Option<&Value>, pane: &str) -> Option<String> {
    let columns = viewport_columns(layout?)?;
    columns.iter().find_map(|column| {
        let root = column.get("root")?;
        holds(root, pane).then(|| column.get("column_id")?.as_str().map(str::to_owned)).flatten()
    })
}

fn viewport_columns(node: &Value) -> Option<Vec<Value>> {
    if node.get("kind").and_then(Value::as_str) == Some("viewport") {
        return node.get("columns").and_then(Value::as_array).cloned();
    }
    let root = node.get("root").unwrap_or(node);
    if root.get("kind").and_then(Value::as_str) == Some("viewport") {
        return root.get("columns").and_then(Value::as_array).cloned();
    }
    ["first", "second"].iter().find_map(|key| viewport_columns(root.get(*key)?))
}

fn first_pane(node: &Value) -> Option<String> {
    if let Some(pane) = node.get("pane_id").and_then(Value::as_str) {
        return Some(pane.to_owned());
    }
    ["first", "second", "root"].iter().find_map(|key| first_pane(node.get(*key)?))
}

fn holds(node: &Value, pane: &str) -> bool {
    node.get("pane_id").and_then(Value::as_str) == Some(pane)
        || ["first", "second", "root"]
            .iter()
            .any(|key| node.get(*key).is_some_and(|child| holds(child, pane)))
}
