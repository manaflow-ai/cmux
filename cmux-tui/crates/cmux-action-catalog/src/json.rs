//! The catalog as JSON in one language: what the macOS app decodes at launch. Field names are
//! the Swift descriptor's (`ActionDescriptor`, `ActionArgument`, `ContextMenuPlacement`), so
//! the app maps them one to one.

use crate::model::*;
use crate::{bindings, palette, strings, tables};
use serde_json::{Map, Value, json};

fn text(value: &Text, locale: usize) -> Value {
    Value::String(strings::resolve(value, locale))
}

fn opt<T>(value: Option<T>, f: impl FnOnce(T) -> Value) -> Value {
    value.map_or(Value::Null, f)
}

/// A shortcut in the export's wire form: the key, and its modifiers in the order ctrl, opt,
/// shift, cmd.
pub fn shortcut(value: &Shortcut) -> Value {
    let mut modifiers = Vec::new();
    for (bit, name) in [(CTRL, "ctrl"), (OPT, "opt"), (SHIFT, "shift"), (CMD, "cmd")] {
        if value.modifiers & bit != 0 {
            modifiers.push(name);
        }
    }
    json!({ "key": value.key, "modifiers": modifiers })
}

fn decision(value: Decision) -> Value {
    match value {
        Decision::Offered => json!("offered"),
        Decision::Exempt(reason) => json!({ "exempt": reason }),
    }
}

fn cases(values: &[EnumCase], locale: usize) -> Value {
    values
        .iter()
        .map(|case| json!({ "value": case.value, "title": text(&case.title, locale) }))
        .collect()
}

fn argument(value: &Argument, locale: usize) -> Value {
    let kind = match value.kind {
        ArgKind::String => json!("string"),
        ArgKind::Bool => json!("bool"),
        ArgKind::Int(range) => {
            json!({ "int": opt(range, |(min, max)| json!({ "min": min, "max": max })) })
        }
        ArgKind::Enumeration(values) => json!({ "enumeration": cases(values, locale) }),
        ArgKind::Target(kind) => json!({ "target": kind }),
    };
    let suggestions = opt(value.suggestions.as_ref(), |s| {
        json!({
            "source": s.source,
            "pinned": cases(s.pinned, locale),
            "otherTitle": opt(s.other_title.as_ref(), |t| text(t, locale)),
            "allowsMultiple": s.allows_multiple,
        })
    });
    json!({
        "name": value.name,
        "title": text(&value.title, locale),
        "kind": kind,
        "isRequired": value.required,
        "suggestions": suggestions,
        "isTargetName": value.is_target_name,
        "isTargetDescription": value.is_target_description,
        "isSuppliedByTarget": value.is_supplied_by_target,
    })
}

fn placement(value: &Placement, locale: usize) -> Value {
    json!({
        "context": value.context,
        "group": value.group,
        "rank": value.rank,
        "style": value.style,
        "parent": value.parent,
        "folder": value.folder,
        "label": opt(value.label.as_ref(), |t| text(t, locale)),
    })
}

/// One binding: its keys, command, arguments and `when` text.
pub fn binding(value: &Binding) -> Value {
    let mut arguments = Map::new();
    for (name, argument) in value.arguments {
        let argument = match argument {
            BindingValue::String(s) => json!({ "string": s }),
            BindingValue::Int(i) => json!({ "int": i }),
            BindingValue::Bool(b) => json!({ "bool": b }),
        };
        arguments.insert((*name).to_owned(), argument);
    }
    json!({
        "keys": value.keys.iter().map(shortcut).collect::<Vec<_>>(),
        "command": value.command,
        "argument": value.argument,
        "arguments": arguments,
        "when_text": value.when,
        "source": value.source,
    })
}

const SURFACES: [(u8, &str); 4] =
    [(PALETTE, "palette"), (KEYBOARD, "keyboard"), (MENU, "menu"), (CONTEXT_MENU, "contextMenu")];

/// One action in the language at `locale` (an index into [`crate::LOCALES`]).
pub fn action(value: &Action, locale: usize) -> Value {
    let plan = &value.surface_plan;
    let aliases: Vec<Value> = value
        .default_aliases()
        .into_iter()
        .map(|b| json!({ "keys": b.keys.iter().map(shortcut).collect::<Vec<_>>(), "when": b.when }))
        .collect();
    json!({
        "id": value.id,
        "group": value.group,
        "title": text(&value.title, locale),
        "hint": opt(value.hint.as_ref(), |t| text(t, locale)),
        "description": value.description,
        "keywords": value.keywords,
        "defaultShortcut": opt(value.default_shortcut.as_ref(), shortcut),
        "shortcutLabel": value.shortcut_label,
        "shortcutFamily": value.shortcut_family,
        "defaultChord": opt(value.default_chord.as_ref(), |c| json!({ "first": shortcut(&c.first), "second": shortcut(&c.second) })),
        "category": value.category,
        "symbol": value.symbol,
        "surfaces": SURFACES.iter().filter(|(bit, _)| value.surfaces & bit != 0).map(|(_, name)| *name).collect::<Vec<_>>(),
        "surfacePlan": {
            "palette": decision(plan.palette),
            "cli": opt(plan.cli, decision),
            "contextMenus": plan.context_menus.iter().map(|p| placement(p, locale)).collect::<Vec<_>>(),
            "contextMenuExemption": plan.context_menu_exemption,
            "mcpExemption": plan.mcp_exemption,
        },
        "requires": value.requires,
        "arguments": value.arguments.iter().map(|a| argument(a, locale)).collect::<Vec<_>>(),
        "targets": value.targets,
        "cliName": value.cli_name,
        "mainMenu": value.main_menu,
        "isDebugOnly": value.is_debug_only,
        "isDestructive": value.is_destructive,
        "startsTerminal": value.starts_terminal,
        "waitsForResult": value.waits_for_result,
        "focuses": value.focuses,
        "isPersonOnly": value.is_person_only,
        "isGlobalHotKey": value.is_global_hot_key,
        "waitsForPerson": value.waits_for_person,
        "waitsForKeyedCreate": value.waits_for_keyed_create,
        "opensWorkspaceContent": value.opens_workspace_content,
        "computed": {
            "cli": value.cli(),
            "is_palette_visible": value.is_palette_visible(),
            "palette_suggestion_rank": value.palette_suggestion_rank(),
            "palette_tier": value.palette_tier().name(),
            "palette_family": value.palette_family().map(|f| f.id),
            "canonical_action_id": value.canonical_action_id(),
            "default_aliases": aliases,
        },
    })
}

fn binding_list(values: &[Binding]) -> Value {
    values.iter().map(binding).collect()
}

/// The keys that type into a text field, by key and then modifiers (a set: the order is the
/// dump's, so both sides compare).
fn text_input_keys() -> Vec<Value> {
    let mut keys: Vec<Value> = bindings::TEXT_INPUT_KEYS.iter().map(shortcut).collect();
    keys.sort_by_key(|k| (k["key"].as_str().unwrap_or("").to_owned(), k["modifiers"].to_string()));
    keys
}

/// The whole catalog in the language at `locale`, as a JSON value: every field of every
/// action, with the derived palette facts (`computed`), as the parity test reads it.
pub fn catalog_value(locale: usize) -> Value {
    catalog_with(locale, |a| action(a, locale))
}

/// `value` without the members that hold their default (null, false, an empty list or
/// object), recursively inside objects except an argument's `kind` (`{"int": null}` is an int
/// with no range): what the app decodes.
fn compact(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| if k == "kind" { (k, v) } else { (k, compact(v)) })
                .filter(|(_, v)| match v {
                    Value::Null | Value::Bool(false) => false,
                    Value::Array(a) => !a.is_empty(),
                    Value::Object(o) => !o.is_empty(),
                    _ => true,
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.into_iter().map(compact).collect()),
        other => other,
    }
}

/// One action as the app decodes it: no `computed`, no default members.
fn app_action(value: &Action, locale: usize) -> Value {
    let mut row = action(value, locale);
    if let Some(map) = row.as_object_mut() {
        map.remove("computed");
    }
    compact(row)
}

fn catalog_with(locale: usize, row: impl Fn(&Action) -> Value) -> Value {
    let legacy: Map<String, Value> =
        tables::LEGACY_ALIASES.iter().map(|(old, new)| ((*old).to_owned(), json!(new))).collect();
    let categories: Vec<Value> = tables::CATEGORIES
        .iter()
        .map(|c| {
            json!({
                "id": c.id,
                "title": text(&c.title, locale),
                "title_key": c.title.key,
                "title_table": c.title.table,
                "palette_section_id": format!("category.{}", c.id),
                "palette_section_order": c.palette_section_order(),
                "sort_order": c.sort_order,
            })
        })
        .collect();
    let folders: Vec<Value> = tables::MENU_FOLDERS
        .iter()
        .map(|f| json!({ "id": f.id, "title": text(&f.title, locale), "symbol": f.symbol, "group": f.group }))
        .collect();
    let families: Vec<Value> = palette::FAMILIES
        .iter()
        .map(|f| {
            json!({ "id": f.id, "title": text(&f.title, locale), "symbol": f.symbol, "parent": f.parent, "members": f.members })
        })
        .collect();
    let aliases: Map<String, Value> =
        palette::ALIASES.iter().map(|(id, words)| ((*id).to_owned(), json!(words))).collect();
    let duplicates: Map<String, Value> = palette::DUPLICATES
        .iter()
        .map(|(dup, canonical)| ((*dup).to_owned(), json!(canonical)))
        .collect();
    json!({
        "version": 1,
        "locale": strings::LOCALES.get(locale).copied().unwrap_or("en"),
        "actions": crate::actions().map(row).collect::<Vec<_>>(),
        "legacy_aliases": legacy,
        "categories": categories,
        "menu_folders": folders,
        "key_binding_defaults": {
            "tab_cycle_aliases": binding_list(bindings::TAB_CYCLE_ALIASES),
            "workspaces_as_tabs": binding_list(bindings::WORKSPACES_AS_TABS),
            "home_chat_switching": binding_list(bindings::HOME_CHAT_SWITCHING),
            "scoped_defaults": binding_list(bindings::SCOPED_DEFAULTS),
            "pane_resize_aliases": binding_list(bindings::PANE_RESIZE_ALIASES),
            "pane_focus_aliases": binding_list(bindings::PANE_FOCUS_ALIASES),
            "focus_history_aliases": binding_list(bindings::FOCUS_HISTORY_ALIASES),
            "zoom_aliases": binding_list(bindings::ZOOM_ALIASES),
            "space_aliases": binding_list(bindings::SPACE_ALIASES),
            "palette_keys": binding_list(bindings::PALETTE_KEYS),
            "list_navigation": binding_list(bindings::LIST_NAVIGATION),
            "home_chat_scoped": bindings::HOME_CHAT_SCOPED,
            "home_scoped": bindings::HOME_SCOPED,
            "yields_to_code_editor": bindings::YIELDS_TO_CODE_EDITOR,
            "yields_to_terminal": bindings::YIELDS_TO_TERMINAL,
            "yields_to_web_content": bindings::YIELDS_TO_WEB_CONTENT,
            "text_input_keys": text_input_keys(),
        },
        "debug_build_only": {
            "actions": tables::DEBUG_BUILD_ONLY_ACTIONS,
            "cases": tables::DEBUG_BUILD_ONLY_CASES
                .iter()
                .map(|(action, argument, value)| json!({ "action": action, "argument": argument, "value": value }))
                .collect::<Vec<_>>(),
        },
        "palette": {
            "daily": palette::DAILY,
            "niche": palette::NICHE,
            "suggestions": palette::SUGGESTIONS,
            "aliases": aliases,
            "families": families,
            "duplicates": duplicates,
        },
    })
}

/// The whole catalog in the language at `locale`, as JSON text.
/// The app's form: an action's missing member is false, null or empty.
pub fn catalog(locale: usize) -> String {
    catalog_with(locale, |a| app_action(a, locale)).to_string()
}
