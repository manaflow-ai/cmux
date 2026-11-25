//! `plans/cmux-next/action-surfaces.json` and the generated block of `plans/cmux-next/actions.md`, as the Swift
//! `ActionSurfaceExport.json` and `ActionSurfaceReport.markdown` write them, from the catalog JSON the app
//! decodes (`json::catalog_value`, or a dump of it). The descriptors are decoded with the Swift decoder's
//! leniency (`RustActionCatalog.descriptor`): an unknown context, group, target or exemption is dropped.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value, json};

use crate::apple_json;
use crate::swift_tables as t;

#[derive(Clone, Copy, PartialEq)]
enum Decision {
    Offered,
    Exempt(usize),
}

impl Decision {
    fn wire(self) -> &'static str {
        match self {
            Decision::Offered => "offered",
            Decision::Exempt(reason) => t::EXEMPTIONS[reason],
        }
    }
    fn exemption(self) -> Option<usize> {
        match self {
            Decision::Offered => None,
            Decision::Exempt(reason) => Some(reason),
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Style {
    Item,
    Choices,
    Submenu,
}

struct Placement {
    context: usize,
    group: usize,
    rank: i64,
    style: Style,
    parent: Option<String>,
    folder: Option<usize>,
    label: Option<String>,
}

struct Case {
    value: String,
    title: String,
}

enum Kind {
    Str,
    Int(Option<(i64, i64)>),
    Bool,
    Enum(Vec<Case>),
    Target(&'static str),
}

struct Argument {
    name: String,
    required: bool,
    kind: Kind,
    /// `suggestions` (with a source): its pinned cases.
    suggestions: Option<Vec<Case>>,
}

struct Descriptor {
    id: String,
    title: String,
    category: usize,
    palette: Decision,
    cli: Option<Decision>,
    menus: Vec<Placement>,
    context_menu_exemption: Option<usize>,
    mcp_exemption: Option<usize>,
    cli_name: Option<String>,
    main_menu: Option<String>,
    shortcut: Option<Value>,
    digits: bool,
    chord: Option<(Value, Value)>,
    requires: Vec<&'static str>,
    arguments: Vec<Argument>,
    targets: Vec<&'static str>,
    debug_only: bool,
    group: Option<String>,
    default_aliases: Value,
}

impl Descriptor {
    fn context_menu(&self) -> Option<Decision> {
        if !self.menus.is_empty() {
            return Some(Decision::Offered);
        }
        self.context_menu_exemption.map(Decision::Exempt)
    }
    fn mcp(&self) -> Option<Decision> {
        match self.cli {
            Some(Decision::Offered) => {
                Some(self.mcp_exemption.map(Decision::Exempt).unwrap_or(Decision::Offered))
            }
            other => other,
        }
    }
    fn decision(&self, surface: &str) -> Option<Decision> {
        match surface {
            "palette" => Some(self.palette),
            "cli" => self.cli,
            "contextMenu" => self.context_menu(),
            _ => self.mcp(),
        }
    }
}

fn index(list: &[&str], name: Option<&str>) -> Option<usize> {
    let name = name?;
    list.iter().position(|item| *item == name)
}

fn known(list: &[&'static str], name: Option<&str>) -> Option<&'static str> {
    index(list, name).map(|at| list[at])
}

fn decision(value: Option<&Value>) -> Option<Decision> {
    let value = value?;
    if value.as_str() == Some("offered") {
        return Some(Decision::Offered);
    }
    index(t::EXEMPTIONS, value.get("exempt").and_then(Value::as_str)).map(Decision::Exempt)
}

/// `RustActionCatalog.shortcut` then `ActionSurfaceExport.wireShortcut`: the key and its modifiers in the order
/// ctrl, opt, shift, cmd.
fn shortcut(value: Option<&Value>) -> Option<Value> {
    let value = value?;
    let key = value.get("key")?.as_str()?;
    let names: Vec<&str> = value
        .get("modifiers")
        .and_then(Value::as_array)
        .map(|m| m.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let modifiers: Vec<&str> =
        ["ctrl", "opt", "shift", "cmd"].into_iter().filter(|m| names.contains(m)).collect();
    Some(json!({"key": key, "modifiers": modifiers}))
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn flag(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn cases(value: Option<&Value>) -> Vec<Case> {
    value
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|row| Case {
                    value: string(row, "value").unwrap_or_default(),
                    title: string(row, "title").unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn argument(value: &Value) -> Option<Argument> {
    let name = string(value, "name")?;
    let kind = match value.get("kind")? {
        Value::String(text) if text == "bool" => Kind::Bool,
        Value::String(text) if text == "string" => Kind::Str,
        Value::Object(object) => {
            if let Some(range) = object.get("int") {
                let bound = |key: &str| range.get(key).and_then(Value::as_i64);
                Kind::Int(bound("min").zip(bound("max")))
            } else if let Some(values) = object.get("enumeration") {
                Kind::Enum(cases(Some(values)))
            } else if let Some(target) =
                known(t::TARGET_KINDS, object.get("target").and_then(Value::as_str))
            {
                Kind::Target(target)
            } else {
                return None;
            }
        }
        _ => return None,
    };
    let suggestions = value
        .get("suggestions")
        .filter(|wire| wire.get("source").and_then(Value::as_str).is_some())
        .map(|wire| cases(wire.get("pinned")));
    Some(Argument { name, required: flag(value, "isRequired"), kind, suggestions })
}

fn placement(value: &Value) -> Option<Placement> {
    let context = index(t::MENU_CONTEXTS, value.get("context").and_then(Value::as_str))?;
    let group = index(t::MENU_GROUPS, value.get("group").and_then(Value::as_str))?;
    let rank = value.get("rank")?.as_i64()?;
    let style = match value.get("style").and_then(Value::as_str) {
        Some("choices") => Style::Choices,
        Some("submenu") => Style::Submenu,
        _ => Style::Item,
    };
    Some(Placement {
        context,
        group,
        rank,
        style,
        parent: string(value, "parent"),
        folder: index(t::MENU_FOLDERS, value.get("folder").and_then(Value::as_str)),
        label: string(value, "label"),
    })
}

fn descriptor(value: &Value) -> Option<Descriptor> {
    let id = string(value, "id")?;
    let category = index(t::CATEGORIES, value.get("category").and_then(Value::as_str))?;
    let plan = value.get("surfacePlan")?;
    let palette = decision(plan.get("palette"))?;
    let exemption = |key: &str| index(t::EXEMPTIONS, plan.get(key).and_then(Value::as_str));
    let names: Vec<&str> = value
        .get("requires")
        .and_then(Value::as_array)
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let chord = value
        .get("defaultChord")
        .and_then(|chord| shortcut(chord.get("first")).zip(shortcut(chord.get("second"))));
    Some(Descriptor {
        title: string(value, "title").unwrap_or_else(|| id.clone()),
        category,
        palette,
        cli: decision(plan.get("cli")),
        menus: plan
            .get("contextMenus")
            .and_then(Value::as_array)
            .map(|p| p.iter().filter_map(placement).collect())
            .unwrap_or_default(),
        context_menu_exemption: exemption("contextMenuExemption"),
        mcp_exemption: exemption("mcpExemption"),
        cli_name: string(value, "cliName"),
        main_menu: known(t::MAIN_MENUS, value.get("mainMenu").and_then(Value::as_str))
            .map(str::to_owned),
        shortcut: shortcut(value.get("defaultShortcut")),
        digits: value.get("shortcutFamily").and_then(Value::as_str) == Some("digits"),
        chord,
        requires: t::CONTEXT_KEYS.iter().copied().filter(|key| names.contains(key)).collect(),
        arguments: value
            .get("arguments")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(argument).collect())
            .unwrap_or_default(),
        targets: value
            .get("targets")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|k| known(t::TARGET_KINDS, k.as_str())).collect())
            .unwrap_or_default(),
        debug_only: flag(value, "isDebugOnly"),
        group: string(value, "group"),
        default_aliases: value
            .pointer("/computed/default_aliases")
            .cloned()
            .unwrap_or_else(|| json!([])),
        id,
    })
}

// MARK: - Titles

/// `ActionTitleCatalog`: the module's string catalogs, for each title's key and English text.
pub struct Titles {
    by_key: HashMap<String, Entry>,
    by_table_key: HashMap<(String, String), Entry>,
    by_english: HashMap<String, Vec<Entry>>,
}

#[derive(Clone, PartialEq)]
struct Entry {
    table: String,
    key: String,
    english: String,
}

impl Titles {
    /// `catalogs`: each `.xcstrings` file's table name (its file stem) and JSON, sorted by file name.
    pub fn new(catalogs: &[(String, Value)]) -> Result<Self, String> {
        let mut titles = Titles {
            by_key: HashMap::new(),
            by_table_key: HashMap::new(),
            by_english: HashMap::new(),
        };
        for (table, file) in catalogs {
            let source = file
                .get("sourceLanguage")
                .and_then(Value::as_str)
                .ok_or(format!("{table}.xcstrings: no sourceLanguage"))?;
            let strings = file
                .get("strings")
                .and_then(Value::as_object)
                .ok_or(format!("{table}.xcstrings: no strings"))?;
            for (key, string) in strings {
                let english = string
                    .get("localizations")
                    .and_then(|l| l.get(source))
                    .and_then(|l| l.get("stringUnit"))
                    .and_then(|u| u.get("value"))
                    .and_then(Value::as_str)
                    .unwrap_or(key)
                    .to_owned();
                let entry =
                    Entry { table: table.clone(), key: key.clone(), english: english.clone() };
                if !titles.by_key.contains_key(key) || table == "Localizable" {
                    titles.by_key.insert(key.clone(), entry.clone());
                }
                titles.by_table_key.insert((table.clone(), key.clone()), entry.clone());
                titles.by_english.entry(english).or_default().push(entry);
            }
        }
        Ok(titles)
    }

    fn entry(&self, key: &str, table: &str) -> Option<&Entry> {
        self.by_table_key.get(&(table.to_owned(), key.to_owned()))
    }

    fn entry_for(&self, descriptor: &Descriptor) -> Option<&Entry> {
        if let Some(entry) = self.by_key.get(&format!("action.{}", descriptor.id))
            && entry.english == descriptor.title
        {
            return Some(entry);
        }
        let matches: &[Entry] =
            self.by_english.get(&descriptor.title).map(Vec::as_slice).unwrap_or(&[]);
        let action_keys: Vec<&Entry> =
            matches.iter().filter(|e| e.key.starts_with("action.")).collect();
        if action_keys.len() == 1 {
            return Some(action_keys[0]);
        }
        if matches.len() == 1 { matches.first() } else { None }
    }
}

// MARK: - Menus (ContextMenuCatalog)

#[derive(Clone, PartialEq)]
enum MenuEntry {
    Action(String),
    Separator,
    Submenu(String, Vec<MenuEntry>),
    Choices(String),
    Folder(usize, Vec<MenuEntry>),
}

struct Row<'a> {
    id: &'a str,
    placement: &'a Placement,
    index: usize,
}

struct Menus {
    menus: HashMap<usize, Vec<MenuEntry>>,
    labels: HashMap<usize, HashMap<String, String>>,
}

fn referenced_ids(entries: &[MenuEntry]) -> Vec<String> {
    let mut ids = Vec::new();
    for entry in entries {
        match entry {
            MenuEntry::Action(id) => ids.push(id.clone()),
            MenuEntry::Separator => {}
            MenuEntry::Submenu(id, children) => {
                ids.push(id.clone());
                ids.extend(referenced_ids(children));
            }
            MenuEntry::Choices(id) => {
                ids.push(id.clone());
                if let Some(trailer) = t::choice_trailer(id) {
                    ids.push(trailer.to_owned());
                }
            }
            MenuEntry::Folder(_, children) => ids.extend(referenced_ids(children)),
        }
    }
    ids
}

fn removing(hidden: &HashSet<String>, entries: &[MenuEntry]) -> Vec<MenuEntry> {
    let mut result = Vec::new();
    for entry in entries {
        match entry {
            MenuEntry::Action(id) | MenuEntry::Choices(id) => {
                if !hidden.contains(id) {
                    result.push(entry.clone());
                }
            }
            MenuEntry::Separator => result.push(entry.clone()),
            MenuEntry::Submenu(id, children) => {
                if !hidden.contains(id) {
                    result.push(MenuEntry::Submenu(id.clone(), removing(hidden, children)));
                }
            }
            MenuEntry::Folder(folder, children) => {
                let kept = removing(hidden, children);
                if kept.iter().any(|e| *e != MenuEntry::Separator) {
                    result.push(MenuEntry::Folder(*folder, kept));
                }
            }
        }
    }
    result
}

impl Menus {
    fn new(descriptors: &[Descriptor], folder_groups: &[usize]) -> Self {
        let mut rows: HashMap<usize, Vec<Row>> = HashMap::new();
        let mut labels: HashMap<usize, HashMap<String, String>> = HashMap::new();
        for (index, descriptor) in descriptors.iter().enumerate() {
            for placement in &descriptor.menus {
                rows.entry(placement.context).or_default().push(Row {
                    id: &descriptor.id,
                    placement,
                    index,
                });
                if let Some(label) = &placement.label {
                    labels
                        .entry(placement.context)
                        .or_default()
                        .insert(descriptor.id.clone(), label.clone());
                }
            }
        }
        let menus = rows
            .iter()
            .map(|(context, rows)| {
                let entries = Self::top_level(rows, folder_groups);
                let entries = match t::essentials(t::MENU_CONTEXTS[*context]) {
                    Some(essentials) => apply(&essentials, &entries),
                    None => entries,
                };
                (*context, entries)
            })
            .collect();
        Menus { menus, labels }
    }

    fn entries(&self, context: usize) -> &[MenuEntry] {
        self.menus.get(&context).map(Vec::as_slice).unwrap_or(&[])
    }

    fn top_level(rows: &[Row], folder_groups: &[usize]) -> Vec<MenuEntry> {
        let roots: Vec<&Row> = rows.iter().filter(|row| row.placement.parent.is_none()).collect();
        // (group, folder, rank, index, band, entries)
        let mut items: Vec<(usize, u8, i64, usize, i64, Vec<MenuEntry>)> = Vec::new();
        let mut last_band: HashMap<usize, i64> = HashMap::new();
        let mut add_row = |row: &Row, items: &mut Vec<_>| {
            let band = row.placement.rank / 100;
            let group = row.placement.group;
            let last = *last_band.get(&group).unwrap_or(&band);
            last_band.insert(group, last.max(band));
            items.push((
                group,
                0,
                row.placement.rank,
                row.index,
                band,
                Self::sorted_entries(&[row], rows),
            ));
        };
        for row in roots.iter().filter(|row| row.placement.folder.is_none()) {
            add_row(row, &mut items);
        }
        let mut folders: Vec<(usize, Vec<&Row>)> = Vec::new();
        for folder in 0..t::MENU_FOLDERS.len() {
            let members: Vec<&Row> =
                roots.iter().copied().filter(|row| row.placement.folder == Some(folder)).collect();
            if members.len() == 1 {
                add_row(members[0], &mut items);
            } else if !members.is_empty() {
                folders.push((folder, members));
            }
        }
        for (folder, members) in folders {
            let group = folder_groups[folder];
            let band = *last_band.get(&group).unwrap_or(&0);
            items.push((
                group,
                1,
                folder as i64,
                folder,
                band,
                vec![MenuEntry::Folder(folder, Self::sorted_entries(&members, rows))],
            ));
        }
        items.sort_by(|a, b| (a.0, a.1, a.2, a.3).cmp(&(b.0, b.1, b.2, b.3)));
        let mut result = Vec::new();
        let mut last_section: Option<(usize, i64)> = None;
        for item in items {
            let section = (item.0, item.4);
            if last_section.is_some_and(|last| last != section) {
                result.push(MenuEntry::Separator);
            }
            last_section = Some(section);
            result.extend(item.5);
        }
        result
    }

    fn sorted_entries(rows: &[&Row], all: &[Row]) -> Vec<MenuEntry> {
        let mut sorted: Vec<&&Row> = rows.iter().collect();
        sorted.sort_by(|a, b| {
            (a.placement.group, a.placement.rank, a.index).cmp(&(
                b.placement.group,
                b.placement.rank,
                b.index,
            ))
        });
        let mut result = Vec::new();
        let mut last_section: Option<(usize, i64)> = None;
        for row in sorted {
            let section = (row.placement.group, row.placement.rank / 100);
            if last_section.is_some_and(|last| last != section) {
                result.push(MenuEntry::Separator);
            }
            last_section = Some(section);
            match row.placement.style {
                Style::Item => result.push(MenuEntry::Action(row.id.to_owned())),
                Style::Choices => result.push(MenuEntry::Choices(row.id.to_owned())),
                Style::Submenu => {
                    let children: Vec<&Row> = all
                        .iter()
                        .filter(|c| c.placement.parent.as_deref() == Some(row.id))
                        .collect();
                    result.push(MenuEntry::Submenu(
                        row.id.to_owned(),
                        Self::sorted_entries(&children, all),
                    ));
                }
            }
        }
        result
    }
}

fn folder_index(name: &str) -> usize {
    t::MENU_FOLDERS.iter().position(|f| *f == name).expect("a MenuFolder")
}

/// `ContextMenuEssentials.apply`.
fn apply(rows: &t::Essentials, entries: &[MenuEntry]) -> Vec<MenuEntry> {
    let placed: HashSet<String> = referenced_ids(entries).into_iter().collect();
    let keep = |entry: &MenuEntry| {
        referenced_ids(std::slice::from_ref(entry)).iter().all(|id| placed.contains(id))
    };
    let listed = |row: &t::EssentialRow| -> Option<MenuEntry> {
        match row {
            t::EssentialRow::Action(id) => Some(MenuEntry::Action((*id).to_owned())),
            t::EssentialRow::Choices(id) => Some(MenuEntry::Choices((*id).to_owned())),
            t::EssentialRow::Separator => Some(MenuEntry::Separator),
            // The menu's own generated folder of that kind, or nothing.
            t::EssentialRow::Folder(name) => {
                let folder = folder_index(name);
                entries.iter().find_map(|entry| match entry {
                    MenuEntry::Folder(f, children) if *f == folder => {
                        Some(MenuEntry::Folder(folder, children.clone()))
                    }
                    _ => None,
                })
            }
        }
    };
    let top: Vec<MenuEntry> = rows.top.iter().filter_map(listed).filter(|e| keep(e)).collect();
    let group: Vec<MenuEntry> = rows.group.iter().filter_map(listed).filter(|e| keep(e)).collect();
    let close: Vec<&str> = rows.close.iter().copied().filter(|id| placed.contains(*id)).collect();
    let tail: Vec<&str> = rows.tail.iter().copied().filter(|id| placed.contains(*id)).collect();
    let before_more: Vec<MenuEntry> =
        rows.before_more.iter().filter_map(listed).filter(|e| keep(e)).collect();
    let mut shown: HashSet<String> =
        referenced_ids(&[top.clone(), group.clone(), before_more.clone()].concat())
            .into_iter()
            .collect();
    shown.extend(close.iter().chain(tail.iter()).map(|id| (*id).to_owned()));
    let rest = collapsing_separators(inlining_short_folders(removing(&shown, entries)));
    let more: Vec<MenuEntry> =
        if rest.is_empty() { vec![] } else { vec![MenuEntry::Folder(folder_index("more"), rest)] };
    let group_section: Vec<MenuEntry> = if group.is_empty() {
        vec![]
    } else {
        [vec![MenuEntry::Separator], group, vec![MenuEntry::Separator]].concat()
    };
    let lower: Vec<MenuEntry> = [before_more, more].concat();
    let upper_ends_in_separator =
        group_section.last().or(top.last()) == Some(&MenuEntry::Separator);
    let more_section: Vec<MenuEntry> =
        if lower.is_empty() || !close.is_empty() || upper_ends_in_separator {
            lower
        } else {
            [vec![MenuEntry::Separator], lower].concat()
        };
    let section = |ids: &[&str]| -> Vec<MenuEntry> {
        if ids.is_empty() {
            return vec![];
        }
        std::iter::once(MenuEntry::Separator)
            .chain(ids.iter().map(|id| MenuEntry::Action((*id).to_owned())))
            .collect()
    };
    [top, group_section, more_section, section(&close), section(&tail)].concat()
}

fn inlining_short_folders(entries: Vec<MenuEntry>) -> Vec<MenuEntry> {
    let copy = folder_index("copy");
    entries
        .into_iter()
        .flat_map(|entry| match entry {
            MenuEntry::Folder(folder, children)
                if folder != copy && referenced_ids(&children).len() <= t::INLINE_FOLDER_LIMIT =>
            {
                [vec![MenuEntry::Separator], children, vec![MenuEntry::Separator]].concat()
            }
            other => vec![other],
        })
        .collect()
}

fn collapsing_separators(entries: Vec<MenuEntry>) -> Vec<MenuEntry> {
    let mut result: Vec<MenuEntry> = Vec::new();
    for entry in entries {
        match entry {
            MenuEntry::Separator => {
                if result.last().is_some_and(|last| *last != MenuEntry::Separator) {
                    result.push(MenuEntry::Separator);
                }
            }
            MenuEntry::Folder(folder, children) => {
                result.push(MenuEntry::Folder(folder, collapsing_separators(children)))
            }
            other => result.push(other),
        }
    }
    while result.last() == Some(&MenuEntry::Separator) {
        result.pop();
    }
    result
}

// MARK: - The export

/// The catalog's root tables the exports read beside the actions.
struct Catalog {
    descriptors: Vec<Descriptor>,
    /// `RustActionCatalog.categories`: title, title key, title table, by category index.
    categories: HashMap<usize, (String, String, String)>,
    /// `MenuFolder.title` and `.group`, by folder index.
    folder_titles: Vec<String>,
    folder_groups: Vec<usize>,
    suggestions: Vec<String>,
}

impl Catalog {
    fn new(root: &Value) -> Self {
        let empty = vec![];
        let actions = root.get("actions").and_then(Value::as_array).unwrap_or(&empty);
        let descriptors = actions.iter().filter_map(descriptor).collect();
        let mut categories = HashMap::new();
        for row in root.get("categories").and_then(Value::as_array).unwrap_or(&empty) {
            let Some(id) = row.get("id").and_then(Value::as_str) else { continue };
            let Some(category) = index(t::CATEGORIES, Some(id)) else { continue };
            categories.insert(
                category,
                (
                    string(row, "title").unwrap_or_else(|| id.to_owned()),
                    string(row, "title_key").unwrap_or_else(|| format!("category.{id}")),
                    string(row, "title_table").unwrap_or_else(|| "Localizable".to_owned()),
                ),
            );
        }
        let mut folder_titles: Vec<String> =
            t::MENU_FOLDERS.iter().map(|f| (*f).to_owned()).collect();
        let mut folder_groups: Vec<usize> =
            vec![index(t::MENU_GROUPS, Some("close")).unwrap(); t::MENU_FOLDERS.len()];
        for row in root.get("menu_folders").and_then(Value::as_array).unwrap_or(&empty) {
            let Some(folder) = index(t::MENU_FOLDERS, row.get("id").and_then(Value::as_str)) else {
                continue;
            };
            let Some(group) = index(t::MENU_GROUPS, row.get("group").and_then(Value::as_str))
            else {
                continue;
            };
            folder_titles[folder] =
                string(row, "title").unwrap_or_else(|| t::MENU_FOLDERS[folder].to_owned());
            folder_groups[folder] = group;
        }
        let suggestions = root
            .pointer("/palette/suggestions")
            .and_then(Value::as_array)
            .map(|s| s.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        Catalog { descriptors, categories, folder_titles, folder_groups, suggestions }
    }

    fn category_title(&self, category: usize) -> (String, String, String) {
        let id = t::CATEGORIES[category];
        self.categories
            .get(&category)
            .cloned()
            .unwrap_or_else(|| (id.to_owned(), format!("category.{id}"), "Localizable".to_owned()))
    }
}

fn entry_value(entry: Option<&Entry>) -> (Value, Value) {
    match entry {
        Some(entry) => (json!(entry.key), json!(entry.table)),
        None => (Value::Null, Value::Null),
    }
}

fn wire_argument(argument: &Argument) -> Value {
    let mut wire = Map::new();
    wire.insert("name".into(), json!(argument.name));
    wire.insert("required".into(), json!(argument.required));
    match &argument.kind {
        Kind::Str => {
            wire.insert("kind".into(), json!("string"));
        }
        Kind::Int(range) => {
            wire.insert("kind".into(), json!("int"));
            if let Some((min, max)) = range {
                wire.insert("min".into(), json!(min));
                wire.insert("max".into(), json!(max));
            }
        }
        Kind::Bool => {
            wire.insert("kind".into(), json!("bool"));
        }
        Kind::Enum(cases) => {
            wire.insert("kind".into(), json!("enum"));
            wire.insert(
                "values".into(),
                Value::Array(cases.iter().map(|c| json!(c.value)).collect()),
            );
        }
        Kind::Target(kind) => {
            wire.insert("kind".into(), json!("target"));
            wire.insert("target_kind".into(), json!(kind));
        }
    }
    Value::Object(wire)
}

fn catalog_object(descriptor: &Descriptor, catalog: &Catalog, titles: &Titles) -> Value {
    let mut menus: Vec<&str> = Vec::new();
    for placement in &descriptor.menus {
        let name = t::export_name(t::MENU_CONTEXTS[placement.context]);
        if !menus.contains(&name) {
            menus.push(name);
        }
    }
    let entry = titles.entry_for(descriptor);
    let (title_key, title_table) = entry_value(entry);
    let shortcut = descriptor.shortcut.clone().map_or(Value::Null, |mut wire| {
        if descriptor.digits {
            wire["family"] = json!("digits");
        }
        wire
    });
    let (category_title, category_key, category_table) =
        catalog.category_title(descriptor.category);
    let undeclared = |d: Option<Decision>| d.map_or("undeclared", Decision::wire);
    json!({
        "id": descriptor.id,
        "cli_name": descriptor.cli_name,
        "palette": descriptor.palette.wire(),
        "cli": undeclared(descriptor.cli),
        "context_menu": undeclared(descriptor.context_menu()),
        "context_menus": menus,
        "mcp": undeclared(descriptor.mcp()),
        "main_menu": descriptor.main_menu,
        "title": entry.map_or(descriptor.title.as_str(), |e| e.english.as_str()),
        "title_key": title_key,
        "title_table": title_table,
        "default_shortcut": shortcut,
        "palette_section": {
            "id": format!("category.{}", t::CATEGORIES[descriptor.category]),
            "title_key": category_key,
            "title_table": category_table,
            "title": titles.entry(&category_key, &category_table).map_or(category_title.clone(), |e| e.english.clone()),
            "order": 100 + descriptor.category,
        },
        "default_chord": descriptor.chord.as_ref().map_or(Value::Null, |(a, b)| json!([a, b])),
        "default_aliases": descriptor.default_aliases,
        "palette_suggested": catalog.suggestions.iter().position(|id| *id == descriptor.id),
        "args": descriptor.arguments.iter().map(wire_argument).collect::<Vec<_>>(),
    })
}

fn visible_when(descriptor: Option<&Descriptor>) -> Value {
    match descriptor {
        None => json!({"requires": [], "debug_only": false, "feature": null}),
        Some(d) => json!({
            "requires": d.requires,
            "debug_only": d.debug_only,
            "feature": t::feature(&d.id, t::CATEGORIES[d.category], d.group.as_deref()),
        }),
    }
}

struct Exporter<'a> {
    by_id: HashMap<&'a str, &'a Descriptor>,
    titles: &'a Titles,
    catalog: &'a Catalog,
}

impl Exporter<'_> {
    fn entries(&self, entries: &[MenuEntry], labels: &HashMap<String, String>) -> Value {
        Value::Array(
            entries
                .iter()
                .enumerate()
                .map(|(order, entry)| self.entry(order, entry, labels))
                .collect(),
        )
    }

    fn entry(&self, order: usize, entry: &MenuEntry, labels: &HashMap<String, String>) -> Value {
        let mut row = Map::new();
        row.insert("order".into(), json!(order));
        match entry {
            MenuEntry::Separator => {
                row.insert("kind".into(), json!("separator"));
            }
            MenuEntry::Action(id) | MenuEntry::Choices(id) => {
                let is_choices = matches!(entry, MenuEntry::Choices(_));
                let descriptor = self.by_id.get(id.as_str()).copied();
                row.insert("kind".into(), json!(if is_choices { "choices" } else { "action" }));
                row.insert("id".into(), json!(id));
                row.insert("visible_when".into(), visible_when(descriptor));
                row.insert("enabled_when".into(), json!("can_perform"));
                if let Some(label) = labels.get(id) {
                    row.insert("label".into(), json!(label));
                }
                if is_choices && let Some(descriptor) = descriptor {
                    if let Some(choices) = self.choices(descriptor) {
                        row.insert("choices".into(), choices);
                    }
                    if let Some(trailer) = t::choice_trailer(id)
                        && let Some(Value::Object(choices)) = row.get_mut("choices")
                    {
                        choices.insert(
                            "trailer".into(),
                            json!({"id": trailer, "title_from": "action"}),
                        );
                    }
                }
            }
            MenuEntry::Submenu(id, children) => {
                row.insert("kind".into(), json!("submenu"));
                row.insert("id".into(), json!(id));
                row.insert("title_from".into(), json!("action"));
                if let Some(label) = labels.get(id) {
                    row.insert("label".into(), json!(label));
                }
                row.insert(
                    "visible_when".into(),
                    visible_when(self.by_id.get(id.as_str()).copied()),
                );
                row.insert("children".into(), self.entries(children, labels));
            }
            MenuEntry::Folder(folder, children) => {
                let name = t::MENU_FOLDERS[*folder];
                let key = format!("menu.folder.{name}");
                row.insert("kind".into(), json!("folder"));
                row.insert("folder".into(), json!(name));
                let title = self
                    .titles
                    .entry(&key, "Localizable")
                    .map_or(self.catalog.folder_titles[*folder].clone(), |e| e.english.clone());
                row.insert("title".into(), json!(title));
                row.insert("title_key".into(), json!(key));
                row.insert("title_table".into(), json!("Localizable"));
                row.insert("children".into(), self.entries(children, labels));
            }
        }
        Value::Object(row)
    }

    /// `ActionRegistry.menuChoices` (an enumeration or pinned suggestions), else a listed target kind
    /// (`ActionTargetChoices.kind`).
    fn choices(&self, descriptor: &Descriptor) -> Option<Value> {
        let menu_choices = descriptor.arguments.iter().find_map(|argument| match &argument.kind {
            Kind::Enum(cases) => Some((argument, cases)),
            _ => argument
                .suggestions
                .as_ref()
                .filter(|pinned| !pinned.is_empty())
                .map(|pinned| (argument, pinned)),
        });
        if let Some((argument, cases)) = menu_choices {
            let values: Vec<Value> = cases
                .iter()
                .map(|choice| {
                    let entry = self
                        .titles
                        .entry(&format!("argument.value.{}", choice.value), "Localizable")
                        .filter(|e| e.english == choice.title);
                    let (key, table) = entry_value(entry);
                    json!({"value": choice.value, "title": choice.title, "title_key": key, "title_table": table})
                })
                .collect();
            return Some(json!({
                "argument": argument.name,
                "values": values,
                "more_opens_palette": argument.suggestions.is_some(),
            }));
        }
        descriptor.arguments.iter().find_map(|argument| match argument.kind {
            Kind::Target(kind) if !descriptor.targets.contains(&kind) => {
                Some(json!({"argument": argument.name, "target_kind": kind}))
            }
            _ => None,
        })
    }
}

/// The two generated texts: action-surfaces.json (with its trailing newline) and the actions.md block (from
/// its begin marker through its end marker).
pub fn export(root: &Value, titles: &Titles) -> (String, String) {
    let catalog = Catalog::new(root);
    let menus = Menus::new(&catalog.descriptors, &catalog.folder_groups);
    let mut by_id = HashMap::new();
    for descriptor in &catalog.descriptors {
        by_id.entry(descriptor.id.as_str()).or_insert(descriptor);
    }
    let exporter = Exporter { by_id, titles, catalog: &catalog };
    let mut context_menus = Map::new();
    let no_labels = HashMap::new();
    for (context, name) in t::MENU_CONTEXTS.iter().enumerate() {
        let entries = menus.entries(context);
        if entries.is_empty() {
            continue;
        }
        let labels = menus.labels.get(&context).unwrap_or(&no_labels);
        context_menus.insert(
            t::export_name(name).to_owned(),
            json!({"implied": t::implied_context(name), "entries": exporter.entries(entries, labels)}),
        );
    }
    let actions: Vec<Value> =
        catalog.descriptors.iter().map(|d| catalog_object(d, &catalog, titles)).collect();
    let hand_built: Vec<Value> = t::HAND_BUILT_MENUS
        .iter()
        .map(|(name, source)| json!({"name": name, "source": source}))
        .collect();
    let root = json!({
        "version": 1,
        "actions": actions,
        "context_menus": context_menus,
        "context_menu_rules": t::RENDER_RULES,
        "context_menus_not_exported": hand_built,
    });
    let text = apple_json::pretty(&root, true) + "\n";
    (text, report(&catalog, &menus))
}

pub const BEGIN: &str = "<!-- generated: action surfaces -->";
pub const END: &str = "<!-- /generated -->";

/// `ActionSurfaceReport.markdown`.
fn report(catalog: &Catalog, menus: &Menus) -> String {
    let descriptors = &catalog.descriptors;
    let mut lines: Vec<String> = vec![BEGIN.into(), String::new()];
    let offered = |surface: &str| {
        descriptors.iter().filter(|d| d.decision(surface) == Some(Decision::Offered)).count()
    };
    lines.push("## Catalog counts".into());
    lines.push(String::new());
    for (category, name) in t::CATEGORIES.iter().enumerate() {
        if *name == "other" {
            continue;
        }
        let count = descriptors.iter().filter(|d| d.category == category).count();
        lines.push(format!("- `{name}`: {count}"));
    }
    lines.push(String::new());
    lines.push(format!("## Counts ({} actions)", descriptors.len()));
    lines.push(String::new());
    lines.push(format!(
        "Palette {}, CLI verbs {}, right-click {}, MCP tools {}.",
        offered("palette"),
        offered("cli"),
        offered("contextMenu"),
        offered("mcp")
    ));
    lines.push(String::new());
    lines.push("## Menus".into());
    lines.push(String::new());
    for (context, name) in t::MENU_CONTEXTS.iter().enumerate() {
        lines.push(format!("- **{name}**: {}", render(menus.entries(context))));
    }
    lines.push(String::new());
    for surface in t::SURFACES {
        lines.push(format!("## Exemptions: {surface}"));
        lines.push(String::new());
        let mut by_reason: HashMap<usize, Vec<&str>> = HashMap::new();
        for descriptor in descriptors {
            let Some(reason) = descriptor.decision(surface).and_then(Decision::exemption) else {
                continue;
            };
            // MCP repeats the CLI's reason for every action without a verb.
            if *surface == "mcp" && descriptor.cli != Some(Decision::Offered) {
                continue;
            }
            by_reason.entry(reason).or_default().push(&descriptor.id);
        }
        for (reason, name) in t::EXEMPTIONS.iter().enumerate() {
            let Some(ids) = by_reason.get(&reason) else { continue };
            let list: Vec<String> = ids.iter().map(|id| format!("`{id}`")).collect();
            lines.push(format!("**{name}** ({}): {}", ids.len(), list.join(", ")));
            lines.push(String::new());
        }
        if *surface == "mcp" {
            lines.push(
                "Every action without a CLI verb is also no MCP tool, for the CLI's reason.\n"
                    .into(),
            );
        }
    }
    lines.push(END.into());
    lines.join("\n")
}

/// `ActionSurfaceReport.render`: one menu on one line.
fn render(entries: &[MenuEntry]) -> String {
    entries
        .iter()
        .map(|entry| match entry {
            MenuEntry::Separator => "|".to_owned(),
            MenuEntry::Action(id) => id.clone(),
            MenuEntry::Choices(id) => format!("{id}[choices]"),
            MenuEntry::Submenu(id, children) => format!("{id} > ({})", render(children)),
            MenuEntry::Folder(folder, children) => {
                format!("[{}] > ({})", t::MENU_FOLDERS[*folder], render(children))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// `text` (actions.md) with its generated block replaced by `block`; None when it has no block.
pub fn replace_block(text: &str, block: &str) -> Option<String> {
    let start = text.find(BEGIN)?;
    let end = text.find(END)? + END.len();
    if end < start {
        return None;
    }
    Some(format!("{}{}{}", &text[..start], block, &text[end..]))
}
