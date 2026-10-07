//! Curated grammar for the daemon's state resources
//! (plans/cmux-next/state-ownership.md, steps A and B): workspace metadata
//! and status, tab pins and zoom, tab groups and saved tab groups, personal
//! workspace groups, rooms, screen metadata and groups, closed history.
//!
//! Every verb is a `cmux.protocol/2` operation, so every change carries an
//! idempotency key. Rooms and groups take their id or their exact name; the
//! CLI turns a unique name into the id before it sends the request
//! (`Resolve::StateName`).

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Number, Value};

use super::{
    CommandPlan, Flags, Resolve, Selectors, UsageError, ZoomStep, group_collapse, group_number,
    insert_optional_clearable_string, insert_optional_string, insert_u32, parse_bool,
    parse_tab_group_private, request, usage, validate_one_of, validate_prefixed_id,
};

const GROUP_COLORS: &[&str] =
    &["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];
const LOG_LEVELS: &[&str] = &["info", "progress", "success", "warning", "error"];
const STATUS_AREAS: &[&str] = &["status", "progress", "log"];

/// Parameters plus the name lookups they need.
#[derive(Default)]
struct Params {
    fields: Map<String, Value>,
    resolve: Vec<Resolve>,
}

impl Params {
    fn insert(&mut self, field: &str, value: Value) {
        self.fields.insert(field.into(), value);
    }

    /// A room or group given by id or exact name.
    fn state(&mut self, field: &'static str, value: &str, list: Op) -> Result<(), UsageError> {
        if value.is_empty() || value.len() > 64 {
            return Err(UsageError::new(format!("{field} must contain 1 to 64 UTF-8 bytes")));
        }
        self.insert(field, Value::String(value.into()));
        self.resolve.push(Resolve::StateName { field, list });
        Ok(())
    }

    fn optional_state(
        &mut self,
        flags: &mut Flags,
        flag: &str,
        field: &'static str,
        list: Op,
    ) -> Result<(), UsageError> {
        match flags.take(flag) {
            Some(value) => self.state(field, &value, list),
            None => Ok(()),
        }
    }

    fn room(
        &mut self,
        flags: &mut Flags,
        flag: &str,
        field: &'static str,
    ) -> Result<(), UsageError> {
        self.optional_state(flags, flag, field, Op::RoomList)
    }

    fn send(
        mut self,
        operation: Op,
        selectors: &Selectors,
        flags: &mut Flags,
    ) -> Result<CommandPlan, UsageError> {
        let resolve = std::mem::take(&mut self.resolve);
        let mut plan = request(operation, selectors, flags, self.fields)?;
        if let CommandPlan::Protocol(plan) = &mut plan {
            plan.resolve = resolve;
        }
        Ok(plan)
    }
}

/// `--color` for a tab or screen group: one of the fixed group colors.
fn group_color(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(color) = flags.take("color") {
        validate_one_of("--color", &color, GROUP_COLORS)?;
        params.insert("color", Value::String(color));
    }
    Ok(())
}

/// A comma-separated list of typed public ids (`tab_…`, `screen_…`).
fn id_list(flags: &mut Flags, flag: &str, scope: &str, prefix: &str) -> Result<Value, UsageError> {
    let values = flags
        .required(flag)?
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            validate_prefixed_id(scope, prefix, value)?;
            Ok(Value::String(value.to_string()))
        })
        .collect::<Result<Vec<_>, UsageError>>()?;
    if values.is_empty() {
        return Err(UsageError::new(format!("--{flag} needs at least one id")));
    }
    Ok(Value::Array(values))
}

/// A comma-separated list of strings; an empty value is an empty list.
fn string_list(value: &str) -> Value {
    Value::Array(
        value
            .split(',')
            .filter(|item| !item.is_empty())
            .map(|item| Value::String(item.to_string()))
            .collect(),
    )
}

fn optional_pane(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(pane) = flags.take("pane") {
        validate_prefixed_id("pane", "pane", &pane)?;
        params.insert("pane_id", Value::String(pane));
    }
    Ok(())
}

fn optional_index(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(index) = flags.take("index") {
        insert_u32(&mut params.fields, "index", "--index", index)?;
    }
    Ok(())
}

fn required_index(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    insert_u32(&mut params.fields, "index", "--index", flags.required("index")?)
}

/// `--<flag> <value>` sets the field, `--clear-<flag>` sends null.
/// `--top-index <n>` (the personal workspace index the group shows right
/// before) or `--clear-top-index` (after every loose workspace).
fn top_index(params: &mut Params, flags: &mut Flags) -> Result<(), UsageError> {
    let clear = flags.boolean("clear-top-index");
    match (group_number(flags, "top-index")?, clear) {
        (Some(_), true) => {
            Err(UsageError::new("--top-index and --clear-top-index are mutually exclusive"))
        }
        (Some(index), false) => {
            params.insert("top_index", index);
            Ok(())
        }
        (None, true) => {
            params.insert("top_index", Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn nullable(
    params: &mut Params,
    flags: &mut Flags,
    flag: &str,
    field: &str,
) -> Result<(), UsageError> {
    let value = flags.take(flag);
    let clear = flags.boolean(&format!("clear-{flag}"));
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --clear-{flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(field, Value::String(value));
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn require_change(params: &Params, what: &str) -> Result<(), UsageError> {
    if params.fields.is_empty() {
        Err(UsageError::new(format!("{what} needs at least one change flag; use --help")))
    } else {
        Ok(())
    }
}

/// Text from the positional word, or from the words after `--` (for text
/// that starts with a dash).
fn text_argument(word: Option<&str>, argv: Option<&[String]>) -> Result<String, UsageError> {
    match (word, argv) {
        (Some(word), None) => Ok(word.to_string()),
        (None, Some(argv)) if !argv.is_empty() => Ok(argv.join(" ")),
        (Some(_), Some(_)) => Err(UsageError::new("give the text once, before or after --")),
        _ => Err(UsageError::new("missing text")),
    }
}

fn float(flag: &str, value: &str, minimum: f64, maximum: f64) -> Result<Value, UsageError> {
    value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite() && (minimum..=maximum).contains(number))
        .and_then(Number::from_f64)
        .map(Value::Number)
        .ok_or_else(|| {
            UsageError::new(format!("{flag} must be a number from {minimum} to {maximum}"))
        })
}

// workspace

/// `workspace <selector> update`.
pub(super) fn workspace_update(
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    for name in ["title", "color", "icon"] {
        insert_optional_clearable_string(&mut params, flags, name)?;
    }
    if params.is_empty() {
        return Err(UsageError::new(
            "workspace update needs --title, --color or --icon (or a --clear-… flag)",
        ));
    }
    request(Op::WorkspaceUpdate, selectors, flags, params)
}

/// The caller's own terminal, when this CLI runs inside one.
fn caller_terminal() -> Option<String> {
    std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| !id.is_empty())
}

/// `workspace [<selector>] status|progress|log …`. Without a selector the
/// target is the caller's workspace inside a cmux terminal, else `current`.
pub(super) fn parse_workspace_status(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<&[String]>,
) -> Result<Option<CommandPlan>, UsageError> {
    let (target, area, rest) = match words {
        [selector, area, rest @ ..] if STATUS_AREAS.contains(area) && !rest.is_empty() => {
            (Some(*selector), *area, rest)
        }
        [area, rest @ ..] if STATUS_AREAS.contains(area) => (None, *area, rest),
        _ => return Ok(None),
    };
    let all = area == "status" && rest == ["list"] && flags.boolean("all");
    let resolve = status_target(target, all, caller_terminal(), selectors)?;
    let mut params = Params::default();
    params.resolve.extend(resolve);
    let operation = match (area, rest) {
        ("status", ["list"]) => Op::WorkspaceStatusList,
        ("status", ["set", key, text @ ..]) => {
            params.insert("key", Value::String((*key).into()));
            params.insert("text", Value::String(text_argument(text.first().copied(), argv)?));
            if text.len() > 1 {
                return usage("workspace status action");
            }
            insert_optional_string(&mut params.fields, flags, "icon", "icon");
            insert_optional_string(&mut params.fields, flags, "color", "color");
            Op::WorkspaceStatusSet
        }
        ("status", ["clear"]) => Op::WorkspaceStatusClear,
        ("status", ["clear", key]) => {
            params.insert("key", Value::String((*key).into()));
            Op::WorkspaceStatusClear
        }
        ("progress", ["set", value @ ..]) => {
            let indeterminate = flags.boolean("indeterminate");
            let value = match (value, indeterminate) {
                ([value], false) => float("progress", value, 0.0, 1.0)?,
                ([], true) => Value::Null,
                _ => {
                    return Err(UsageError::new(
                        "progress set needs a value from 0 to 1 or --indeterminate",
                    ));
                }
            };
            params.insert("value", value);
            insert_optional_string(&mut params.fields, flags, "label", "label");
            Op::WorkspaceProgressSet
        }
        ("progress", ["clear"]) => Op::WorkspaceProgressClear,
        ("log", ["append", text @ ..]) if text.len() <= 1 => {
            params.insert("text", Value::String(text_argument(text.first().copied(), argv)?));
            if let Some(level) = flags.take("level") {
                validate_one_of("--level", &level, LOG_LEVELS)?;
                params.insert("level", Value::String(level));
            }
            insert_optional_string(&mut params.fields, flags, "source", "source");
            Op::WorkspaceLogAppend
        }
        ("log", ["list"]) => {
            if let Some(limit) = flags.take("limit") {
                super::insert_bounded_u32(&mut params.fields, "limit", "--limit", limit, 1, 200)?;
            }
            Op::WorkspaceLogList
        }
        ("log", ["clear"]) => Op::WorkspaceLogClear,
        _ => return usage(&format!("workspace {area} action")),
    };
    if argv.is_some() && !matches!(operation, Op::WorkspaceStatusSet | Op::WorkspaceLogAppend) {
        return Err(UsageError::new(format!("workspace {area} takes no -- arguments")));
    }
    params.send(operation, selectors, flags).map(Some)
}

/// Fills the workspace selector for a status command: the named one, none
/// for `status list --all`, the caller's workspace inside a cmux terminal,
/// else `current`.
fn status_target(
    target: Option<&str>,
    all: bool,
    caller: Option<String>,
    selectors: &mut Selectors,
) -> Result<Option<Resolve>, UsageError> {
    match (target, all) {
        (Some(_), true) => Err(UsageError::new("--all lists every workspace; drop the selector")),
        (Some(selector), false) => selectors.insert("workspace", "ws", selector).map(|()| None),
        (None, true) => Ok(None),
        (None, false) => match caller {
            Some(terminal) => {
                validate_prefixed_id("terminal", "term", &terminal)?;
                Ok(Some(Resolve::CallerWorkspace { terminal }))
            }
            None => selectors.insert("workspace", "ws", "current").map(|()| None),
        },
    }
}

/// `workspace group …`: personal workspace groups of the home session.
/// `add` and `remove` place a workspace with `workspace.place`.
/// `workspace list [--order session|personal]`.
pub(super) fn workspace_list(
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Params::default();
    insert_optional_string(&mut params.fields, flags, "order", "order");
    params.send(Op::WorkspaceList, selectors, flags)
}

pub(super) fn parse_workspace_group(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Params::default();
    let operation = match words {
        ["list"] => {
            params.room(flags, "room", "room")?;
            Op::WorkspaceGroupList
        }
        ["create"] => {
            params.insert("name", Value::String(flags.required("name")?));
            insert_optional_string(&mut params.fields, flags, "color", "color");
            params.room(flags, "room", "room")?;
            optional_index(&mut params, flags)?;
            if flags.boolean("collapse") {
                params.insert("collapsed", Value::Bool(true));
            }
            Op::WorkspaceGroupCreate
        }
        ["remove"] => {
            selectors.insert("workspace", "ws", &flags.required("workspace")?)?;
            params.insert("group", Value::Null);
            Op::WorkspacePlace
        }
        [group, action] => {
            let field = if *action == "add" { "group" } else { "workspace_group" };
            params.state(field, group, Op::WorkspaceGroupList)?;
            match *action {
                "update" => {
                    insert_optional_string(&mut params.fields, flags, "name", "name");
                    nullable(&mut params, flags, "color", "color")?;
                    params.room(flags, "room", "room")?;
                    group_collapse(flags, &mut params.fields)?;
                    top_index(&mut params, flags)?;
                    Op::WorkspaceGroupUpdate
                }
                "delete" => Op::WorkspaceGroupDelete,
                "move" => {
                    required_index(&mut params, flags)?;
                    Op::WorkspaceGroupMove
                }
                "add" => {
                    selectors.insert("workspace", "ws", &flags.required("workspace")?)?;
                    if let Some(index) = group_number(flags, "index")? {
                        params.insert("index", index);
                    }
                    Op::WorkspacePlace
                }
                _ => return usage("workspace group action"),
            }
        }
        _ => return usage("workspace group action"),
    };
    params.send(operation, selectors, flags)
}

// tab

/// `tab <selector> pin|unpin|zoom <n>|reset|in|out|update`.
///
/// Zoom is a terminal's font zoom, which the daemon owns (`tab.update`). A
/// browser tab's page zoom belongs to the app that hosts the page, so the CLI
/// never writes a browser tab's record: a read before the request finds the
/// tab's kind and sends a browser tab's zoom to the app's page-zoom action
/// (`Resolve::TabZoom`).
pub(super) fn tab_change(
    action: &str,
    rest: &[&str],
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Params::default();
    let operation = match (action, rest) {
        ("pin", []) => Op::TabPin,
        ("unpin", []) => Op::TabUnpin,
        ("zoom", [step @ ("in" | "out")]) => {
            params.resolve.push(Resolve::TabZoom {
                step: if *step == "in" { ZoomStep::In } else { ZoomStep::Out },
            });
            Op::TabUpdate
        }
        ("zoom", ["reset"]) => {
            params.insert("zoom", Value::Null);
            params.resolve.push(Resolve::TabZoom { step: ZoomStep::Reset });
            Op::TabUpdate
        }
        ("zoom", [value]) => {
            params.insert("zoom", float("zoom", value, 0.25, 5.0)?);
            params.resolve.push(Resolve::TabZoom { step: ZoomStep::Value });
            Op::TabUpdate
        }
        ("update", []) => {
            let step = match (flags.take("zoom"), flags.boolean("clear-zoom")) {
                (Some(_), true) => {
                    return Err(UsageError::new("--zoom and --clear-zoom are mutually exclusive"));
                }
                (Some(value), false) => {
                    params.insert("zoom", float("--zoom", &value, 0.25, 5.0)?);
                    ZoomStep::Value
                }
                (None, true) => {
                    params.insert("zoom", Value::Null);
                    ZoomStep::Reset
                }
                (None, false) => {
                    return Err(UsageError::new("tab update needs --zoom or --clear-zoom"));
                }
            };
            params.resolve.push(Resolve::TabZoom { step });
            Op::TabUpdate
        }
        _ => return usage("tab action"),
    };
    params.send(operation, selectors, flags)
}

/// `tab group …`. Group operations take no topology selectors: a group is
/// addressed by its id or name, its tabs and panes by public id.
pub(super) fn parse_tab_group(
    words: &[&str],
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    let mut params = Params::default();
    let operation = match words {
        ["list"] => {
            optional_pane(&mut params, flags)?;
            Op::TabGroupList
        }
        ["create"] => {
            params.insert("tabs", id_list(flags, "tabs", "tab", "tab")?);
            insert_optional_string(&mut params.fields, flags, "name", "name");
            group_color(&mut params, flags)?;
            Op::TabGroupCreate
        }
        ["remove"] => {
            params.insert("tabs", id_list(flags, "tabs", "tab", "tab")?);
            Op::TabGroupRemoveTabs
        }
        ["saved", rest @ ..] => return parse_saved_tab_group(rest, flags),
        [group, action @ ("split" | "column" | "new-workspace" | "unsave")] => {
            return parse_tab_group_private(group, action, flags);
        }
        [group, action] => {
            if *action == "save" {
                params.state("tab_group", group, Op::TabGroupList)?;
                params.room(flags, "room", "room")?;
                return params.send(Op::SavedTabGroupSave, &selectors, flags);
            }
            params.state("tab_group", group, Op::TabGroupList)?;
            match *action {
                "show" => Op::TabGroupGet,
                "update" => {
                    insert_optional_string(&mut params.fields, flags, "name", "name");
                    group_color(&mut params, flags)?;
                    group_collapse(flags, &mut params.fields)?;
                    if params.fields.len() == 1 {
                        return Err(UsageError::new(
                            "tab group update needs --name, --color, --collapse or --expand",
                        ));
                    }
                    Op::TabGroupUpdate
                }
                "add" => {
                    params.insert("tabs", id_list(flags, "tabs", "tab", "tab")?);
                    optional_index(&mut params, flags)?;
                    Op::TabGroupAddTabs
                }
                "move" => {
                    optional_pane(&mut params, flags)?;
                    optional_index(&mut params, flags)?;
                    Op::TabGroupMove
                }
                "ungroup" => Op::TabGroupUngroup,
                "close" => Op::TabGroupClose,
                _ => return usage("tab group action"),
            }
        }
        _ => return usage("tab group action"),
    };
    params.send(operation, &selectors, flags)
}

/// `tab group saved …`: saved tab groups are personal and room-scoped.
fn parse_saved_tab_group(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    let mut params = Params::default();
    let operation = match words {
        ["list"] => {
            params.room(flags, "room", "room")?;
            Op::SavedTabGroupList
        }
        [saved, action] => {
            params.state("saved_tab_group", saved, Op::SavedTabGroupList)?;
            match *action {
                "reopen" => {
                    optional_pane(&mut params, flags)?;
                    Op::SavedTabGroupReopen
                }
                "delete" => Op::SavedTabGroupDelete,
                _ => return usage("saved tab group action"),
            }
        }
        _ => return usage("saved tab group action"),
    };
    params.send(operation, &selectors, flags)
}

// room

/// `room …`: rooms are personal views of the home session.
pub(super) fn parse_room(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut selectors = Selectors::default();
    let mut params = Params::default();
    let operation = match words {
        ["list"] => Op::RoomList,
        ["create"] => {
            params.insert("name", Value::String(flags.required("name")?));
            for name in ["color", "icon", "theme"] {
                insert_optional_string(&mut params.fields, flags, name, name);
            }
            optional_index(&mut params, flags)?;
            Op::RoomCreate
        }
        ["unpin"] => {
            selectors.insert("workspace", "ws", &flags.required("workspace")?)?;
            Op::RoomUnpin
        }
        [room, action] => {
            params.state("room", room, Op::RoomList)?;
            match *action {
                "update" => {
                    insert_optional_string(&mut params.fields, flags, "name", "name");
                    for name in ["color", "icon", "theme"] {
                        nullable(&mut params, flags, name, name)?;
                    }
                    nullable(&mut params, flags, "browser-profile", "browser_profile_id")?;
                    nullable(&mut params, flags, "default-session", "default_session_id")?;
                    if params.fields.len() == 1 {
                        return Err(UsageError::new(
                            "room update needs at least one change flag; use --help",
                        ));
                    }
                    Op::RoomUpdate
                }
                "delete" => {
                    params.room(flags, "move-to", "move_to")?;
                    Op::RoomDelete
                }
                "move" => {
                    required_index(&mut params, flags)?;
                    Op::RoomMove
                }
                "follow" => {
                    params.insert("sessions", string_list(&flags.required("sessions")?));
                    Op::RoomFollow
                }
                "pin" => {
                    selectors.insert("workspace", "ws", &flags.required("workspace")?)?;
                    Op::RoomPin
                }
                _ => return usage("room action"),
            }
        }
        _ => return usage("room action"),
    };
    params.send(operation, &selectors, flags)
}

// screen

/// `screen <selector> update|pin|unpin|move`.
pub(super) fn screen_change(
    action: &str,
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Params::default();
    let operation = match action {
        "pin" | "unpin" => {
            params.insert("pinned", Value::Bool(action == "pin"));
            Op::ScreenUpdate
        }
        "update" => {
            if let Some(pinned) = flags.take("pinned") {
                params.insert("pinned", Value::Bool(parse_bool("--pinned", &pinned)?));
            }
            nullable(&mut params, flags, "color", "color")?;
            nullable(&mut params, flags, "icon", "icon")?;
            require_change(&params, "screen update")?;
            Op::ScreenUpdate
        }
        _ => {
            required_index(&mut params, flags)?;
            Op::ScreenMove
        }
    };
    params.send(operation, selectors, flags)
}

/// `screen group …`. Only `list` takes the workspace selector.
pub(super) fn parse_screen_group(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Params::default();
    if words == ["list"] {
        if let Some(workspace) = flags.take("workspace") {
            selectors.insert("workspace", "ws", &workspace)?;
        }
        return params.send(Op::ScreenGroupList, selectors, flags);
    }
    let selectors = Selectors::default();
    let operation = match words {
        ["create"] => {
            params.insert("screens", id_list(flags, "screens", "screen", "screen")?);
            insert_optional_string(&mut params.fields, flags, "name", "name");
            group_color(&mut params, flags)?;
            Op::ScreenGroupCreate
        }
        ["remove"] => {
            params.insert("screens", id_list(flags, "screens", "screen", "screen")?);
            Op::ScreenGroupRemoveScreens
        }
        [group, action] => {
            params.state("screen_group", group, Op::ScreenGroupList)?;
            match *action {
                "show" => Op::ScreenGroupGet,
                "update" => {
                    insert_optional_string(&mut params.fields, flags, "name", "name");
                    group_color(&mut params, flags)?;
                    group_collapse(flags, &mut params.fields)?;
                    if params.fields.len() == 1 {
                        return Err(UsageError::new(
                            "screen group update needs --name, --color, --collapse or --expand",
                        ));
                    }
                    Op::ScreenGroupUpdate
                }
                "add" => {
                    params.insert("screens", id_list(flags, "screens", "screen", "screen")?);
                    Op::ScreenGroupAddScreens
                }
                "ungroup" => Op::ScreenGroupUngroup,
                _ => return usage("screen group action"),
            }
        }
        _ => return usage("screen group action"),
    };
    params.send(operation, &selectors, flags)
}

// closed

/// `closed list [--window W] [--limit N]`, `closed reopen [--window W]`
/// (the newest group of that window: Cmd-Shift-T) and
/// `closed <id> reopen [--members 0,2]`: the closed groups of the session.
pub(super) fn parse_closed(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    let mut params = Params::default();
    let operation = match words {
        ["list"] => {
            insert_optional_string(&mut params.fields, flags, "window", "window");
            if let Some(limit) = flags.take("limit") {
                super::insert_bounded_u32(&mut params.fields, "limit", "--limit", limit, 1, 1000)?;
            }
            Op::ClosedList
        }
        ["reopen"] => {
            insert_optional_string(&mut params.fields, flags, "window", "window");
            Op::ClosedReopen
        }
        [closed, "reopen"] => {
            if closed.is_empty() || closed.len() > 64 {
                return Err(UsageError::new("closed id must contain 1 to 64 UTF-8 bytes"));
            }
            params.insert("closed", Value::String((*closed).into()));
            insert_optional_string(&mut params.fields, flags, "window", "window");
            if let Some(members) = flags.take("members") {
                params.insert("members", closed_members(&members)?);
            }
            Op::ClosedReopen
        }
        _ => return usage("closed action"),
    };
    params.send(operation, &selectors, flags)
}

/// `--members 0,2`: member indexes of a closed group.
fn closed_members(value: &str) -> Result<Value, UsageError> {
    let members = value
        .split(',')
        .map(|member| member.trim().parse::<u32>().map(Value::from))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| UsageError::new("--members must be member indexes like 0,2"))?;
    Ok(Value::Array(members))
}

#[cfg(test)]
mod tests;
