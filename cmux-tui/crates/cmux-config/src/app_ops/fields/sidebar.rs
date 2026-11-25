//! Swift `SidebarSectionsSetting`, `WorkspaceRowSetting`, `SidebarBorderSetting`, `SidebarSurfaceSetting`
//! and `SidebarLookPreset.look(in:)`. Defaults, ranges and choice lists come from the settings schema.

use serde_json::{Map, Value, json};

use super::reader::{choices_of, default_of, invalid, quoted, range_of, value_at};

fn path_of(key: &str) -> Vec<&str> {
    key.split('.').collect()
}

struct Ctx<'a> {
    root: &'a Value,
    values: Map<String, Value>,
    diags: Vec<Value>,
}

impl<'a> Ctx<'a> {
    fn new(root: &'a Value) -> Self {
        Ctx { root, values: Map::new(), diags: vec![] }
    }

    /// The value at `path` (a dotted key), when set.
    fn at(&self, key: &str) -> Option<&'a Value> {
        value_at(self.root, &path_of(key))
    }

    fn default_flag(key: &str) -> Value {
        // A schema without the row (an older export) means off.
        match default_of(key) {
            Value::Null => json!(false),
            other => other,
        }
    }

    /// `result[key]`: the toggle, else its default plus a diagnostic.
    fn flag(&mut self, key: &str) -> Value {
        self.flag_at(key, key)
    }

    /// The toggle read from `from` (a legacy path) but stored under `key`.
    fn flag_at(&mut self, key: &str, from: &str) -> Value {
        let result = match self.at(from) {
            None => Self::default_flag(key),
            Some(value) if value.is_boolean() => value.clone(),
            Some(_) => {
                self.diags.push(invalid(from, "expected true or false"));
                Self::default_flag(key)
            }
        };
        self.values.insert(key.into(), result.clone());
        result
    }

    fn choice(&mut self, key: &str) -> Value {
        let allowed = choices_of(key);
        let default = default_of(key);
        let result = match self.at(key) {
            None => default,
            Some(value) => match value.as_str().filter(|text| allowed.iter().any(|a| a == text)) {
                Some(_) => value.clone(),
                None => {
                    self.diags.push(invalid(key, format!("expected one of {}", quoted(&allowed))));
                    default
                }
            },
        };
        self.values.insert(key.into(), result.clone());
        result
    }

    /// A share of the sidebar height: a number inside the row's range, else the default.
    fn share(&mut self, key: &str) -> f64 {
        let default = default_of(key).as_f64().unwrap_or_default();
        let (lo, hi) = range_of(key);
        let share = match self.at(key) {
            None => default,
            Some(value) => match value.as_f64().filter(|n| (lo..=hi).contains(n)) {
                Some(number) => number,
                None => {
                    self.diags.push(invalid(
                        key,
                        "expected a share of the sidebar height from 0.1 to 0.9, such as 0.33",
                    ));
                    default
                }
            },
        };
        self.values.insert(key.into(), json!(share));
        share
    }
}

/// The two band shares leave the list at least a fifth (Swift `SidebarSectionsPreferences.maxShareSum`).
const MAX_SHARE_SUM: f64 = 0.8;

const FLAGS_AFTER_NAV: [&str; 2] = ["sidebar.showProjects", "sidebar.showSpaces"];
const FLAGS_AFTER_SPACES: [&str; 15] = [
    "sidebar.showProfileControl",
    "sidebar.showSearchButton",
    "sidebar.showLiveToggle",
    "presence.live",
    "sidebar.showNewWorkspaceChooser",
    "sidebar.workspacesAsTabs",
    "sidebar.chromeGroups",
    "sidebar.sideBySide",
    "sidebar.noFade",
    "sidebar.controlsOnHover",
    "sidebar.floatOnHover",
    "sidebar.minimal",
    "sidebar.detailedStatusIcons",
    "sidebar.showTimestamps",
    "sidebar.settleFinished",
];

/// `fields.sidebar_sections`: every `sidebar.*` section key resolved (a missing key is its default, a bad
/// one the default plus a diagnostic), by dotted key; `rowDiagnosticsAt` is where the
/// `fields.workspace_row` diagnostics go in `diagnostics` (the place Swift parsed them), and the nav and
/// projection resolvers (already Rust, `cmux-layout-reducer`) append after.
pub(super) fn sidebar_sections(root: &Value) -> (Value, Vec<Value>) {
    let mut cx = Ctx::new(root);
    cx.choice("sidebar.sectionLook");
    let top = cx.share("sidebar.topBandMaxShare");
    let bottom = cx.share("sidebar.bottomBandMaxShare");
    let sum = top + bottom;
    if sum > MAX_SHARE_SUM {
        let scale = MAX_SHARE_SUM / sum;
        cx.values.insert("sidebar.topBandMaxShare".into(), json!(top * scale));
        cx.values.insert("sidebar.bottomBandMaxShare".into(), json!(bottom * scale));
    }
    // R87: the key nightly-next builds wrote before the rename, read while the new one is unset.
    let from = if cx.at("sidebar.pinnedBandsScroll").is_none()
        && cx.at("sidebar.stickyBandsScroll").is_some()
    {
        "sidebar.stickyBandsScroll"
    } else {
        "sidebar.pinnedBandsScroll"
    };
    cx.flag_at("sidebar.pinnedBandsScroll", from);
    cx.choice("sidebar.minimalMode");
    cx.flag("sidebar.sessionTree");
    cx.flag("sidebar.cards.tips");
    cx.choice("sidebar.numbering");
    cx.choice("sidebar.cmd9");
    cx.choice("sidebar.stepping");
    cx.flag("sidebar.steppingWraps");
    let row_at = cx.diags.len();
    for key in FLAGS_AFTER_NAV {
        cx.flag(key);
    }
    for key in FLAGS_AFTER_SPACES {
        cx.flag(key);
    }
    cx.flag("sidebar.showAutomaticSessions");
    cx.flag("sidebar.showAgentSessions");
    cx.flag("sidebar.showColors");
    indicator_style(&mut cx);
    for key in [
        "sidebar.showLocalMachine",
        "sidebar.groupHeader.memberCount",
        "sidebar.groupHeader.unreadCount",
    ] {
        cx.flag(key);
    }
    for key in ["sidebar.groupHeader.background", "sidebar.groupPalette", "sidebar.groupGradient"] {
        cx.choice(key);
    }
    cx.flag("sidebar.priorityView.enabled");
    cx.flag("sidebar.priorityView.shown");
    for key in ["sidebar.groupBy", "sidebar.density", "sidebar.textSize", "sidebar.style"] {
        cx.choice(key);
    }
    cx.flag("sidebar.showChats");
    let out = json!({"values": cx.values, "rowDiagnosticsAt": row_at});
    (out, cx.diags)
}

/// `workspaceColors.indicatorStyle`: the schema's styles, plus `solidFill` (`fill`) and classic's old
/// styles (`leftRail`) (Swift `WorkspaceColorIndicatorStyle(setting:)`).
fn indicator_style(cx: &mut Ctx) {
    let key = "workspaceColors.indicatorStyle";
    let allowed = choices_of(key);
    let default = default_of(key);
    let result = match cx.at(key) {
        None => default,
        Some(value) => match value.as_str() {
            Some("solidFill") => json!("fill"),
            Some(
                "rail" | "border" | "wash" | "lift" | "typography" | "washRail"
                | "blueWashColorRail",
            ) => {
                json!("leftRail")
            }
            Some(text) if allowed.iter().any(|a| a == text) => value.clone(),
            _ => {
                cx.diags.push(invalid(key, format!("expected one of {}", quoted(&allowed))));
                default
            }
        },
    };
    cx.values.insert(key.into(), result);
}

const ELEMENTS: [&str; 13] = [
    "icon",
    "directory",
    "branch",
    "process",
    "agentStatus",
    "tabCount",
    "ports",
    "lastActivity",
    "pullRequest",
    "progress",
    "working",
    "log",
    "notification",
];
const KINDS: [&str; 4] = ["terminal", "agent", "browser", "mixed"];
/// The S1 keys the first-generation toggles replace, read while the new key is unset.
const LEGACY: [(&str, &str); 2] =
    [("directory", "sidebar.showWorkspaceDirectory"), ("tabCount", "sidebar.showCounts")];

fn second_line() -> Vec<String> {
    choices_of("sidebar.workspaceRow.secondLineOrder")
}

/// A list of second-line element names; `None` when absent or invalid.
fn order(cx: &mut Ctx, key: &str) -> Option<Vec<Value>> {
    let value = cx.at(key)?;
    let allowed = second_line();
    if let Some(items) = value.as_array() {
        let all_ok =
            items.iter().all(|i| i.as_str().is_some_and(|t| allowed.iter().any(|a| a == t)));
        if all_ok {
            return Some(items.clone());
        }
    }
    cx.diags.push(invalid(key, format!("expected a list of {}", quoted(&allowed))));
    None
}

/// `fields.workspace_row`: `{values: {shown, secondLineOrder, overrides, statusPlacement}}`. `shown` lists
/// the elements on (in element order), `overrides` maps a kind to `{elements: {name: bool}, secondLineOrder?}`
/// (only kinds with a change). The `lines` layouts stay with `cmux-layout-reducer`.
pub(super) fn workspace_row(root: &Value) -> (Value, Vec<Value>) {
    let mut cx = Ctx::new(root);
    let base = "sidebar.workspaceRow";
    let mut shown: Vec<&str> = ELEMENTS
        .iter()
        .copied()
        .filter(|e| Ctx::default_flag(&format!("{base}.{e}")) == json!(true))
        .collect();
    for element in ELEMENTS {
        let key = format!("{base}.{element}");
        let legacy = LEGACY.iter().find(|(e, _)| *e == element).map(|(_, path)| *path);
        let from = match legacy {
            Some(old) if cx.at(&key).is_none() && cx.at(old).is_some() => old.to_string(),
            _ => key.clone(),
        };
        let Some(value) = cx.at(&from) else { continue };
        let Some(on) = value.as_bool() else {
            cx.diags.push(invalid(&from, "expected true or false"));
            continue;
        };
        shown.retain(|e| *e != element);
        if on {
            shown.push(element);
        }
    }
    shown.sort_by_key(|e| ELEMENTS.iter().position(|x| x == e));
    let second =
        order(&mut cx, &format!("{base}.secondLineOrder")).unwrap_or_else(default_second_line);
    let mut overrides = Map::new();
    for kind in KINDS {
        let mut elements = Map::new();
        for element in ELEMENTS {
            let key = format!("{base}.{kind}.{element}");
            let Some(value) = cx.at(&key) else { continue };
            match value.as_bool() {
                Some(on) => {
                    elements.insert(element.into(), json!(on));
                }
                None => cx.diags.push(invalid(&key, "expected true or false")),
            }
        }
        let list = order(&mut cx, &format!("{base}.{kind}.secondLineOrder"));
        if !elements.is_empty() || list.is_some() {
            let mut change = json!({"elements": elements});
            if let Some(list) = list {
                change["secondLineOrder"] = Value::Array(list);
            }
            overrides.insert(kind.into(), change);
        }
    }
    let placement = {
        let key = format!("{base}.statusPlacement");
        let allowed = choices_of(&key);
        match cx.at(&key) {
            None => default_of(&key),
            Some(value) if value.as_str().is_some_and(|t| allowed.iter().any(|a| a == t)) => {
                value.clone()
            }
            Some(_) => {
                cx.diags.push(invalid(&key, format!("expected one of {}", quoted(&allowed))));
                default_of(&key)
            }
        }
    };
    let values = json!({
        "shown": shown, "secondLineOrder": second, "overrides": overrides, "statusPlacement": placement,
    });
    (json!({"values": values}), cx.diags)
}

fn default_second_line() -> Vec<Value> {
    default_of("sidebar.workspaceRow.secondLineOrder").as_array().cloned().unwrap_or_default()
}

/// `fields.sidebar_border` `{root, defaultShows?}`: `{values: {shows, width}}`, `width` `null` for the divider hairline.
pub(super) fn sidebar_border(request: &Value) -> Result<Value, super::OpError> {
    let root =
        request.get("root").ok_or_else(|| super::OpError::Invalid("expected `root`".into()))?;
    let mut cx = Ctx::new(root);
    let default_shows = request
        .get("defaultShows")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| Ctx::default_flag("sidebar.border") == json!(true));
    let shows = match cx.at("sidebar.border") {
        None => default_shows,
        Some(value) => value.as_bool().unwrap_or_else(|| {
            cx.diags.push(invalid("sidebar.border", "expected true or false"));
            default_shows
        }),
    };
    let width = match cx.at("sidebar.borderWidth") {
        None => Value::Null,
        Some(value) => match value.as_f64().filter(|n| n.is_finite()) {
            Some(number) => {
                let (lo, hi) = range_of("sidebar.borderWidth");
                if number < lo || number > hi {
                    cx.diags.push(invalid(
                        "sidebar.borderWidth",
                        format!(
                            "clamped to {}...{} points",
                            super::reader::swift_double(lo),
                            super::reader::swift_double(hi)
                        ),
                    ));
                }
                json!(number.max(lo).min(hi))
            }
            None => {
                cx.diags.push(invalid("sidebar.borderWidth", "expected a number of points"));
                Value::Null
            }
        },
    };
    Ok(json!({"values": {"shows": shows, "width": width}, "diagnostics": cx.diags}))
}

/// `fields.sidebar_surface`: `{value}` the `appearance.sidebarSurface` choice, `null` when unset or bad
/// (the caller's `unset` surface applies).
pub(super) fn sidebar_surface(root: &Value) -> (Value, Vec<Value>) {
    let key = "appearance.sidebarSurface";
    let allowed = choices_of(key);
    let mut diags = vec![];
    let value = match value_at(root, &path_of(key)) {
        None => Value::Null,
        Some(v) if v.as_str().is_some_and(|t| allowed.iter().any(|a| a == t)) => v.clone(),
        Some(_) => {
            diags.push(invalid(key, format!("expected one of {}", quoted(&allowed))));
            Value::Null
        }
    };
    (json!({"value": value}), diags)
}

/// `fields.sidebar_look`: `{look}` the look `root` picks when it has a file (`null` for `cmux` or unknown).
pub(super) fn sidebar_look(root: &Value) -> (Value, Vec<Value>) {
    let look = crate::sidebar_look::look_in(root);
    (json!({"look": look}), vec![])
}
