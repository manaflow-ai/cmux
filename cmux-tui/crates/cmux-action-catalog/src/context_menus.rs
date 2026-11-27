//! The right-click menus, built from the actions' placements (`SurfacePlan::context_menus`).
//!
//! No menu is a hand list: an action is in a menu exactly when it places itself there, so a menu
//! cannot drift from the catalog. A menu lists its groups in [`MENU_GROUPS`] order with a separator
//! between them and between rank hundreds inside a group; a folder ([`crate::tables::MENU_FOLDERS`])
//! collects its rows into one titled submenu after its group's rows, and a folder with one row
//! shows it inline. A few crowded menus keep only their essential rows at the top level and move
//! the rest into More ([`ESSENTIALS`]).
//!
//! The app reads the finished trees (`context_menu_trees` in the catalog JSON) and renders them
//! (`ActionRegistry.makeContextMenu`) with titles, shortcuts and enabled state.

use std::collections::{BTreeMap, HashSet};

use crate::model::Placement;
use crate::tables::MENU_FOLDERS;

/// The semantic groups of a menu row, in menu order (`MenuGroup`).
pub const MENU_GROUPS: &[&str] = &[
    "edit",
    "navigate",
    "create",
    "reopen",
    "identity",
    "organize",
    "move",
    "layout",
    "connection",
    "inspect",
    "view",
    "reset",
    "close",
];

/// One entry of a generated menu (`ContextMenuEntry`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    Action(&'static str),
    Separator,
    /// A submenu titled by the action, with the rows that name it as their parent.
    Submenu(&'static str, Vec<Entry>),
    /// A submenu with one item per value of the action's first enumeration argument.
    Choices(&'static str),
    /// A titled folder (`MenuFolder` id) of less used rows.
    Folder(&'static str, Vec<Entry>),
}

fn group_order(group: &str) -> usize {
    MENU_GROUPS.iter().position(|g| *g == group).unwrap_or(MENU_GROUPS.len())
}

fn folder_index(folder: &str) -> usize {
    MENU_FOLDERS.iter().position(|f| f.id == folder).unwrap_or(0)
}

fn folder_group(folder: &str) -> usize {
    group_order(MENU_FOLDERS.iter().find(|f| f.id == folder).map_or("close", |f| f.group))
}

#[derive(Clone, Copy)]
struct Row {
    id: &'static str,
    placement: &'static Placement,
    index: usize,
}

/// Every placement of every action, by menu, in catalog order.
fn rows() -> BTreeMap<&'static str, Vec<Row>> {
    let mut rows: BTreeMap<&'static str, Vec<Row>> = BTreeMap::new();
    for (index, action) in crate::actions().enumerate() {
        for placement in action.surface_plan.context_menus {
            rows.entry(placement.context).or_default().push(Row {
                id: action.id,
                placement,
                index,
            });
        }
    }
    rows
}

/// `rows` by group, rank and catalog order, with a separator between groups and between rank
/// hundreds inside a group.
fn entries(rows: &[Row], all: &[Row]) -> Vec<Entry> {
    let mut sorted = rows.to_vec();
    sorted.sort_by_key(|r| (group_order(r.placement.group), r.placement.rank, r.index));
    let mut result = Vec::new();
    let mut last: Option<(usize, i64)> = None;
    for row in sorted {
        let section = (group_order(row.placement.group), row.placement.rank / 100);
        if last.is_some_and(|l| l != section) {
            result.push(Entry::Separator);
        }
        last = Some(section);
        match row.placement.style {
            "choices" => result.push(Entry::Choices(row.id)),
            "submenu" => {
                let children: Vec<Row> =
                    all.iter().filter(|r| r.placement.parent == Some(row.id)).copied().collect();
                result.push(Entry::Submenu(row.id, entries(&children, all)));
            }
            _ => result.push(Entry::Action(row.id)),
        }
    }
    result
}

/// A top-level menu: the rows outside a folder, plus one row per folder after its group's rows,
/// in its group's last section. A folder with one row shows it inline.
fn top_level(rows: &[Row]) -> Vec<Entry> {
    let roots: Vec<Row> = rows.iter().filter(|r| r.placement.parent.is_none()).copied().collect();
    // (group, folder flag, rank, index, band, entries)
    let mut items: Vec<(usize, u8, i64, usize, i64, Vec<Entry>)> = Vec::new();
    let mut last_band: BTreeMap<usize, i64> = BTreeMap::new();
    let mut add_row = |row: Row, items: &mut Vec<_>| {
        let band = row.placement.rank / 100;
        let group = group_order(row.placement.group);
        let current = *last_band.get(&group).unwrap_or(&band);
        last_band.insert(group, current.max(band));
        items.push((group, 0, row.placement.rank, row.index, band, entries(&[row], rows)));
    };
    for row in roots.iter().filter(|r| r.placement.folder.is_none()) {
        add_row(*row, &mut items);
    }
    let mut folders: Vec<(&'static str, Vec<Row>)> = Vec::new();
    for folder in MENU_FOLDERS {
        let members: Vec<Row> =
            roots.iter().filter(|r| r.placement.folder == Some(folder.id)).copied().collect();
        match members.as_slice() {
            [] => {}
            [only] => add_row(*only, &mut items),
            _ => folders.push((folder.id, members)),
        }
    }
    for (folder, members) in folders {
        let index = folder_index(folder);
        let group = folder_group(folder);
        let band = *last_band.get(&group).unwrap_or(&0);
        items.push((
            group,
            1,
            index as i64,
            index,
            band,
            vec![Entry::Folder(folder, entries(&members, rows))],
        ));
    }
    items.sort_by_key(|item| (item.0, item.1, item.2, item.3));
    let mut result = Vec::new();
    let mut last: Option<(usize, i64)> = None;
    for item in items {
        let section = (item.0, item.4);
        if last.is_some_and(|l| l != section) {
            result.push(Entry::Separator);
        }
        last = Some(section);
        result.extend(item.5);
    }
    result
}

/// A choices row that always ends with this action, so its submenu shows with no choices too:
/// Move to Group lists the groups, then New Group.
pub const CHOICE_TRAILERS: &[(&str, &str)] =
    &[("moveWorkspaceToGroup", "workspace.moveToNewGroup")];

/// The trailer of the choices row `id`, if it has one.
pub fn choice_trailer(id: &str) -> Option<&'static str> {
    CHOICE_TRAILERS.iter().find(|(choices, _)| *choices == id).map(|(_, trailer)| *trailer)
}

/// Every action id `entries` reference, submenus, folders and choice trailers included.
pub fn referenced_ids(entries: &[Entry]) -> Vec<&'static str> {
    let mut ids = Vec::new();
    for entry in entries {
        match entry {
            Entry::Action(id) => ids.push(*id),
            Entry::Separator => {}
            Entry::Submenu(id, children) => {
                ids.push(*id);
                ids.extend(referenced_ids(children));
            }
            Entry::Choices(id) => {
                ids.push(*id);
                ids.extend(choice_trailer(id));
            }
            Entry::Folder(_, children) => ids.extend(referenced_ids(children)),
        }
    }
    ids
}

/// `entries` without the `hidden` rows, inside folders too; a folder left with no row goes.
pub fn removing(hidden: &HashSet<&str>, entries: &[Entry]) -> Vec<Entry> {
    let mut result = Vec::new();
    for entry in entries {
        match entry {
            Entry::Action(id) | Entry::Choices(id) => {
                if !hidden.contains(id) {
                    result.push(entry.clone());
                }
            }
            Entry::Separator => result.push(Entry::Separator),
            Entry::Submenu(id, children) => {
                if !hidden.contains(id) {
                    result.push(Entry::Submenu(id, removing(hidden, children)));
                }
            }
            Entry::Folder(folder, children) => {
                let kept = removing(hidden, children);
                if kept.iter().any(|e| *e != Entry::Separator) {
                    result.push(Entry::Folder(folder, kept));
                }
            }
        }
    }
    result
}

/// The few rows a crowded menu keeps at its top level (`ContextMenuEssentials.Rows`).
pub struct Essentials {
    /// The top-level rows, in order.
    pub top: &'static [Entry],
    /// The group rows: one top-level section after `top`, between separators.
    pub group: &'static [Entry],
    pub close: &'static [&'static str],
    /// The rows after the close rows, behind a separator (Chrome's Reopen Closed Tab).
    pub tail: &'static [&'static str],
    /// Top-level folders just above More: the menu's Copy ▸.
    pub before_more: &'static [Entry],
}

use Entry::{Action as A, Choices as C, Separator as S};

/// One Copy ▸ on the workspace, tab and pane menus, at their top level just above More, the
/// right-clicked object's link first, then its ID and the other identifiers (Leo 2026-10-29: "I
/// feel like there's a much better way of doing things than just all of these menus ... there's
/// no link to workspace, which is, I mean, that seems pretty important").
const COPY_FOLDER: &[Entry] = &[Entry::Folder("copy", Vec::new())];

/// The crowded menus (Leo 2026-10-11: the workspace menu's twelve rows were "overwhelming"):
/// every other row of such a menu moves into one More submenu, in its old order; its short
/// folders show there as sections, its long ones as submenus ([`INLINE_FOLDER_LIMIT`]). The
/// close rows end the menu after a separator. The group rows stay at the top level in their own
/// section (Lawrence 2026-10-14: "my groups UI is lost"); More never takes them.
#[rustfmt::skip]
pub const ESSENTIALS: &[(&str, Essentials)] = &[
    // Move ▸ stays at the top level (u2418: "I need an option to … move a workspace to the top of
    // a group"; under More it was not found). Send Message… (u5402) opens the Chief's chat about
    // this workspace. Rename and the color row open the menu as its name field and swatches
    // (Leo 2026-10-20: "like Chrome"). Archive sits in the closing section just above Close
    // (#48536).
    ("workspaceRow", Essentials {
        top: &[A("renameWorkspace"), A("palette.toggleWorkspacePin"), C("palette.workspaceColor"),
               A("workspace.newBelow"), A("home.messageAbout"), Entry::Folder("move", Vec::new())],
        group: &[C("moveWorkspaceToGroup"), A("groupSelectedWorkspaces"), A("removeWorkspaceFromGroup")],
        close: &["workspace.toggleArchive", "closeWorkspace"],
        tail: &[],
        before_more: COPY_FOLDER,
    }),
    // New Tab to the Right and the group rows stay at the top (Lawrence 2026-10-14), then the
    // frequent tab actions (Leo 2026-10-23: keep the obviously useful rows), then Copy ▸ and More.
    ("tab", Essentials {
        top: &[A("newTab.toRight"), A("tabGroup.create"), A("tabGroup.addTab"), A("tabGroup.removeTab"),
               S,
               A("reloadTab"), A("duplicateTab"),
               A("palette.toggleTabPin"), A("toggleTabAudioMute"),
               A("closeTab"), A("closeOtherTabsInPane"), A("closeTabsToRight")],
        group: &[],
        close: &[],
        tail: &[],
        before_more: COPY_FOLDER,
    }),
    // Split Left and Split Up sit in Split beside Split Right and Split Down (menu audit S1).
    ("pane", Essentials {
        top: &[A("splitRight"), A("splitDown"), Entry::Folder("split", Vec::new()), A("toggleSplitZoom"), A("renamePane")],
        group: &[],
        close: &["closePane"],
        tail: &[],
        before_more: COPY_FOLDER,
    }),
];

/// The menus opened on one of several selected rows, as Chrome's menu on several selected tabs
/// (Leo 2026-10-20). Their rows act on every selected row and say so.
#[rustfmt::skip]
pub const SELECTION_ESSENTIALS: &[(&str, Essentials)] = &[
    // The color row becomes the header's swatches, which color every selected row. Archive opens
    // the closing section here too, as on one row (#48595; Leo, 2026-11-21: "there's no right click
    // archive chat in the left bit.").
    ("workspaceRow", Essentials {
        top: &[C("palette.workspaceColor"), A("workspace.newBelow"), A("groupSelectedWorkspaces"), S,
               A("workspace.duplicate"), Entry::Folder("move", Vec::new()), A("palette.toggleWorkspacePin"),
               A("workspace.toggleAudioMute"), S],
        group: &[],
        close: &["workspace.toggleArchive", "closeWorkspace", "palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow"],
        tail: &["reopenClosedWorkspace"],
        before_more: &[],
    }),
];

/// The most rows a folder inside More may have and still show as a section of More rather than a
/// submenu of its own (Leo 2026-10-20: flatten "More ›"; a longer folder stays one submenu so More
/// fits a laptop screen).
pub const INLINE_FOLDER_LIMIT: usize = 8;

/// A listed folder as the menu's own folder of that kind, with its rows; other rows as listed.
fn generated(entry: &Entry, entries: &[Entry]) -> Option<Entry> {
    let Entry::Folder(folder, _) = entry else { return Some(entry.clone()) };
    entries.iter().find_map(|e| match e {
        Entry::Folder(f, children) if f == folder => Some(Entry::Folder(f, children.clone())),
        _ => None,
    })
}

/// More's top-level folders with at most [`INLINE_FOLDER_LIMIT`] rows as sections. Copy ▸ stays
/// one submenu wherever it is.
fn inlining_short_folders(entries: Vec<Entry>) -> Vec<Entry> {
    let mut result = Vec::new();
    for entry in entries {
        match entry {
            Entry::Folder(folder, children)
                if folder != "copy" && referenced_ids(&children).len() <= INLINE_FOLDER_LIMIT =>
            {
                result.push(Entry::Separator);
                result.extend(children);
                result.push(Entry::Separator);
            }
            other => result.push(other),
        }
    }
    result
}

/// `entries` with one separator between sections, none at the ends, inside folders too.
fn collapsing_separators(entries: Vec<Entry>) -> Vec<Entry> {
    let mut result: Vec<Entry> = Vec::new();
    for entry in entries {
        match entry {
            Entry::Separator => {
                if result.last().is_some_and(|last| *last != Entry::Separator) {
                    result.push(Entry::Separator);
                }
            }
            Entry::Folder(folder, children) => {
                result.push(Entry::Folder(folder, collapsing_separators(children)));
            }
            other => result.push(other),
        }
    }
    while result.last() == Some(&Entry::Separator) {
        result.pop();
    }
    result
}

/// `entries` (a whole generated menu) as its essential rows, its group section, More, and its
/// close rows. A listed row the menu does not place is left out; a listed folder is the menu's
/// generated folder of that kind (left out when the menu has none).
fn apply(rows: &Essentials, entries: Vec<Entry>) -> Vec<Entry> {
    let placed: HashSet<&str> = referenced_ids(&entries).into_iter().collect();
    let keep = |entry: &Entry| {
        referenced_ids(std::slice::from_ref(entry)).iter().all(|id| placed.contains(id))
    };
    let top: Vec<Entry> =
        rows.top.iter().filter_map(|e| generated(e, &entries)).filter(keep).collect();
    let group: Vec<Entry> = rows.group.iter().filter(|e| keep(e)).cloned().collect();
    let close: Vec<&str> = rows.close.iter().copied().filter(|id| placed.contains(id)).collect();
    let tail: Vec<&str> = rows.tail.iter().copied().filter(|id| placed.contains(id)).collect();
    let before_more: Vec<Entry> =
        rows.before_more.iter().filter_map(|e| generated(e, &entries)).filter(keep).collect();
    // referenced_ids counts a choices row's trailer, so More drops New Group with Move to Group.
    let mut shown: HashSet<&str> = HashSet::new();
    for list in [&top, &group, &before_more] {
        shown.extend(referenced_ids(list));
    }
    shown.extend(close.iter().copied());
    shown.extend(tail.iter().copied());
    let rest = collapsing_separators(inlining_short_folders(removing(&shown, &entries)));
    let more: Vec<Entry> =
        if rest.is_empty() { Vec::new() } else { vec![Entry::Folder("more", rest)] };
    let group_section: Vec<Entry> = if group.is_empty() {
        Vec::new()
    } else {
        std::iter::once(S).chain(group).chain(std::iter::once(S)).collect()
    };
    let mut lower = before_more;
    lower.extend(more);
    let top_ends_in_separator = group_section.last().or(top.last()) == Some(&S);
    let more_section: Vec<Entry> = if lower.is_empty() || !close.is_empty() || top_ends_in_separator
    {
        lower
    } else {
        std::iter::once(S).chain(lower).collect()
    };
    let mut result = top;
    result.extend(group_section);
    result.extend(more_section);
    for list in [close, tail] {
        if !list.is_empty() {
            result.push(S);
            result.extend(list.into_iter().map(A));
        }
    }
    result
}

fn essentials<'a>(table: &'a [(&str, Essentials)], context: &str) -> Option<&'a Essentials> {
    table.iter().find(|(c, _)| *c == context).map(|(_, e)| e)
}

/// One generated menu: its entries, and the menu opened on one of several selected rows when it
/// has its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Menu {
    pub context: &'static str,
    pub entries: Vec<Entry>,
    pub selection: Option<Vec<Entry>>,
}

/// Every generated menu, by context name (`ActionMenuContext` raw value), in name order.
pub fn menus() -> Vec<Menu> {
    let rows = rows();
    let mut contexts: Vec<&'static str> = rows.keys().copied().collect();
    for (context, _) in SELECTION_ESSENTIALS {
        if !contexts.contains(context) {
            contexts.push(context);
        }
    }
    contexts.sort_unstable();
    contexts
        .into_iter()
        .map(|context| {
            let menu_rows = rows.get(context).map_or(&[][..], Vec::as_slice);
            let generated = top_level(menu_rows);
            let entries = if menu_rows.is_empty() {
                Vec::new()
            } else if let Some(rows) = essentials(ESSENTIALS, context) {
                apply(rows, generated.clone())
            } else {
                generated.clone()
            };
            let selection =
                essentials(SELECTION_ESSENTIALS, context).map(|rows| apply(rows, generated));
            Menu { context, entries, selection }
        })
        .collect()
}

/// One entry as the catalog JSON writes it: `"-"` for a separator, else an object with one of
/// `action`, `choices`, `submenu` or `folder`, and `children` for the last two.
pub fn entry_json(entry: &Entry) -> serde_json::Value {
    use serde_json::json;
    match entry {
        Entry::Separator => json!("-"),
        Entry::Action(id) => json!({ "action": id }),
        Entry::Choices(id) => json!({ "choices": id }),
        Entry::Submenu(id, children) => {
            json!({ "submenu": id, "children": entries_json(children) })
        }
        Entry::Folder(folder, children) => {
            json!({ "folder": folder, "children": entries_json(children) })
        }
    }
}

pub fn entries_json(entries: &[Entry]) -> Vec<serde_json::Value> {
    entries.iter().map(entry_json).collect()
}

/// `context_menu_trees` in the catalog JSON: per menu (context raw value) its `entries` and, for a
/// menu with its own several-rows menu, `selection`.
pub fn trees_json() -> serde_json::Value {
    let mut trees = serde_json::Map::new();
    for menu in menus() {
        let mut row = serde_json::Map::new();
        row.insert("entries".into(), entries_json(&menu.entries).into());
        if let Some(selection) = &menu.selection {
            row.insert("selection".into(), entries_json(selection).into());
        }
        trees.insert(menu.context.into(), row.into());
    }
    trees.into()
}
