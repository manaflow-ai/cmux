//! The default keymap takes no key that something else already owns.
//!
//! A new default shortcut can collide with five owners, and before this file only the shipped
//! binding table on a Mac (the Swift suite) noticed some of them. This test reads every default
//! key the catalog declares (each action's shortcut, digit family and chord, and every default
//! binding in [`bindings`]) and checks it against:
//!
//! 1. the catalog itself: two actions on the same key with the same required context
//!    (`ActionRegistry.shortcutConflictGroups`, the Keyboard Shortcuts page's conflict rule), a
//!    chord leader that is also a plain key, two chords on the same keys, two unscoped bindings
//!    on the same key that run different commands;
//! 2. Ghostty's reserved split keys (`schemas/keybindings/ghostty-reserved-keys.json`);
//! 3. the shortcuts macOS takes before the app sees them (`MacOSSystemShortcutsTests.onByDefault`);
//! 4. the menu bar's own key equivalents (`MainMenu.swift`: Hide, Edit's Undo / Copy / Paste ...);
//! 5. Ghostty's macOS default keybinds, which reach a terminal when cmux has no default there, and
//!    the first-party apps' catalog keys (the binding table's app layer).
//!
//! cmux takes some of those keys on purpose (it runs the same action as Ghostty's default, or the
//! terminal's Copy on Edit's Cmd-C). Those keys are listed in [`TAKEN_ON_PURPOSE`]; any other key a
//! new default takes from an owner fails here, naming the owner.
//!
//! Found adding Screen Sharing's Cmd-Shift-S (`macScreen.open`); the scan for it is
//! [`screen_sharing_key_is_free_everywhere`].

use cmux_action_catalog::{Binding, CMD, CTRL, OPT, SHIFT, Shortcut, actions, bindings};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    // affected-reads: Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/MacOSSystemShortcutsTests.swift schemas/keybindings/ghostty-reserved-keys.json first-party-apps examples/looks
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read(path: &str) -> String {
    let path = repo().join(path);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// A key as the catalog stores it: the character and the modifier bits.
type Stroke = (String, u8);

fn of(shortcut: &Shortcut) -> Stroke {
    (shortcut.key.to_string(), shortcut.modifiers)
}

/// A keybindings.json stroke (`ctrl+cmd+left`, `shift+cmd+,`) as a [`Stroke`].
fn parse(text: &str) -> Stroke {
    let text = text.to_lowercase();
    let (mods_text, key) = match text.strip_suffix("++") {
        Some(rest) => (rest.to_string(), "+".to_string()),
        None => match text.rsplit_once('+') {
            Some((mods, key)) => (mods.to_string(), key.to_string()),
            None => (String::new(), text.clone()),
        },
    };
    let mut modifiers = 0;
    for token in mods_text.split('+').filter(|t| !t.is_empty()) {
        modifiers |= match token {
            "ctrl" => CTRL,
            "opt" | "alt" => OPT,
            "shift" => SHIFT,
            "cmd" | "super" => CMD,
            other => panic!("{text}: unknown modifier {other}"),
        };
    }
    let key = match key.as_str() {
        "left" => "\u{f702}",
        "right" => "\u{f703}",
        "up" => "\u{f700}",
        "down" => "\u{f701}",
        "home" => "\u{f729}",
        "end" => "\u{f72b}",
        "page_up" => "\u{f72c}",
        "page_down" => "\u{f72d}",
        "return" | "enter" => "\r",
        "tab" => "\t",
        "escape" => "\u{1b}",
        "space" => " ",
        "backspace" => "\u{8}",
        other => other,
    };
    (key.to_string(), modifiers)
}

fn show((key, modifiers): &Stroke) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for (bit, name) in [(CTRL, "ctrl"), (OPT, "opt"), (SHIFT, "shift"), (CMD, "cmd")] {
        if modifiers & bit != 0 {
            parts.push(name);
        }
    }
    let key = match key.as_str() {
        "\u{f702}" => "left",
        "\u{f703}" => "right",
        "\u{f700}" => "up",
        "\u{f701}" => "down",
        "\r" => "return",
        "\t" => "tab",
        "\u{1b}" => "escape",
        " " => "space",
        "\u{8}" => "backspace",
        "\u{f729}" => "home",
        "\u{f72b}" => "end",
        "\u{f72c}" => "page_up",
        "\u{f72d}" => "page_down",
        other => other,
    };
    parts.push(key);
    parts.join("+")
}

/// One default key: the stroke, the command it runs, and where it applies.
#[derive(Clone, Debug)]
struct Entry {
    stroke: Stroke,
    command: &'static str,
    /// The action's required context facts (catalog keys) or the binding's `when` text.
    scope: Scope,
    kind: Kind,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Scope {
    /// A catalog key: the action's `requires`, whether it is a digit family, whether it is one of
    /// Home's chat-scoped actions.
    Catalog { requires: Vec<&'static str>, digits: bool, home: bool },
    /// A default binding with no `when`.
    Everywhere,
    /// A default binding's `when`.
    When(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Shortcut,
    ChordLeader,
    Binding,
}

impl Entry {
    /// Whether the key runs wherever no more specific default takes it: a catalog key with no
    /// required context, or a binding without `when`.
    fn unscoped(&self) -> bool {
        match &self.scope {
            Scope::Catalog { requires, home, .. } => requires.is_empty() && !home,
            Scope::Everywhere => true,
            Scope::When(_) => false,
        }
    }
}

fn binding_tables() -> Vec<(&'static str, &'static [Binding])> {
    vec![
        ("tab_cycle_aliases", bindings::TAB_CYCLE_ALIASES),
        ("workspaces_as_tabs", bindings::WORKSPACES_AS_TABS),
        ("home_chat_switching", bindings::HOME_CHAT_SWITCHING),
        ("scoped_defaults", bindings::SCOPED_DEFAULTS),
        ("pane_resize_aliases", bindings::PANE_RESIZE_ALIASES),
        ("pane_focus_aliases", bindings::PANE_FOCUS_ALIASES),
        ("focus_history_aliases", bindings::FOCUS_HISTORY_ALIASES),
        ("zoom_aliases", bindings::ZOOM_ALIASES),
        ("space_aliases", bindings::SPACE_ALIASES),
        ("palette_keys", bindings::PALETTE_KEYS),
        ("list_navigation", bindings::LIST_NAVIGATION),
    ]
}

/// Every default key: each action's shortcut (a digit family as its nine keys), the first stroke
/// of its chord, and the first stroke of every default binding.
fn default_keymap() -> Vec<Entry> {
    let home: BTreeSet<&str> =
        bindings::HOME_CHAT_SCOPED.iter().chain(bindings::HOME_SCOPED).copied().collect();
    let mut entries = Vec::new();
    for action in actions() {
        let mut requires: Vec<&'static str> = action.requires.to_vec();
        requires.sort_unstable();
        let digits = action.shortcut_family == Some("digits");
        let scope = Scope::Catalog { requires, digits, home: home.contains(action.id) };
        if let Some(shortcut) = &action.default_shortcut {
            let strokes: Vec<Stroke> = if digits {
                (1..=9).map(|n| (n.to_string(), shortcut.modifiers)).collect()
            } else {
                vec![of(shortcut)]
            };
            for stroke in strokes {
                entries.push(Entry {
                    stroke,
                    command: action.id,
                    scope: scope.clone(),
                    kind: Kind::Shortcut,
                });
            }
        }
        if let Some(chord) = &action.default_chord {
            entries.push(Entry {
                stroke: of(&chord.first),
                command: action.id,
                scope: scope.clone(),
                kind: Kind::ChordLeader,
            });
        }
    }
    for (_, table) in binding_tables() {
        for binding in table {
            let Some(first) = binding.keys.first() else { continue };
            entries.push(Entry {
                stroke: of(first),
                command: binding.command,
                scope: binding.when.map_or(Scope::Everywhere, Scope::When),
                kind: Kind::Binding,
            });
        }
    }
    entries
}

/// Keys cmux's defaults take from another owner on purpose, as (keys, why). A new default on one
/// of these keys still has to pass the catalog checks; a key not listed here that an owner holds
/// fails [`no_default_takes_a_key_another_owner_holds`].
#[rustfmt::skip]
const TAKEN_ON_PURPOSE: &[(&[&str], &str)] = &[
    (
        &[
            "cmd+,", "shift+cmd+,", "cmd+-", "cmd+0", "cmd+=", "ctrl+cmd+=", "cmd+d", "shift+cmd+d",
            "cmd+f", "cmd+e", "cmd+g", "cmd+k", "cmd+n", "cmd+q", "cmd+t", "cmd+w", "shift+cmd+w",
            "ctrl+cmd+f", "shift+cmd+[", "shift+cmd+]", "shift+cmd+enter", "shift+cmd+p",
            "opt+cmd+left", "opt+cmd+right", "opt+cmd+up", "opt+cmd+down", "ctrl+cmd+left",
            "ctrl+cmd+right", "ctrl+cmd+up", "ctrl+cmd+down", "opt+cmd+i", "cmd+1", "cmd+2",
            "cmd+3", "cmd+4", "cmd+5", "cmd+6", "cmd+7", "cmd+8", "cmd+9",
        ],
        "cmux runs the action Ghostty's default names (settings, font size, splits, find, clear, \
         tabs, workspaces), as the shipping cmux; cmux defaults rank above Ghostty defaults",
    ),
    (
        &["cmd+[", "cmd+]"],
        "focus history Back / Forward (ghostty-reserved-keys.json approvedDeviations, cx-442)",
    ),
    (
        &["ctrl+cmd+[", "ctrl+cmd+]", "shift+cmd+f", "shift+cmd+g", "shift+cmd+t"],
        "cmux's own defaults on Ghostty keys, as the shipping cmux (sidebar tabs, Find in Directory, \
         Find Previous, Reopen Closed)",
    ),
    (
        &["cmd+j"],
        "Cmd-J is cmux's leader (Ghostty's scroll_to_selection is Cmd-J J, terminal-shortcuts.md)",
    ),
    (
        &["cmd+up", "cmd+down", "cmd+left", "cmd+right", "cmd+enter"],
        "scoped keys in the palette, file explorer, omnibar, checklist and simulator; a terminal \
         keeps Ghostty's (they yield or need a context a terminal never has)",
    ),
    (
        &["cmd+c", "cmd+v"],
        "the terminal's Copy / Paste run Edit's Copy / Paste and Ghostty's copy_to_clipboard / \
         paste_from_clipboard",
    ),
    (
        &["cmd+s"],
        "Save: the code editor app's Save (when paneFocused:editor) ranks above the catalog's \
         file and markdown Save",
    ),
];

/// Ghostty's macOS default keybinds that hold Cmd (`Keybinds.init` in `src/config/Config.zig` of
/// the pinned `ghostty` submodule, cb1ef7091cd), in keybindings.json syntax. A terminal gets these
/// when cmux's defaults leave the key alone.
#[rustfmt::skip]
const GHOSTTY_MACOS_DEFAULTS: &[(&str, &str)] = &[
    ("cmd+c", "copy_to_clipboard"), ("cmd+v", "paste_from_clipboard"),
    ("shift+cmd+,", "reload_config"), ("cmd+,", "open_config"),
    ("cmd+=", "increase_font_size"), ("cmd++", "increase_font_size"), ("cmd+-", "decrease_font_size"),
    ("cmd+0", "reset_font_size"),
    ("ctrl+shift+cmd+j", "write_screen_file:copy"), ("shift+cmd+j", "write_screen_file:paste"),
    ("opt+shift+cmd+j", "write_screen_file:open"),
    ("ctrl+cmd+[", "goto_split:previous"), ("ctrl+cmd+]", "goto_split:next"),
    ("ctrl+shift+cmd+up", "resize_split:up"), ("ctrl+shift+cmd+down", "resize_split:down"),
    ("ctrl+shift+cmd+left", "resize_split:left"), ("ctrl+shift+cmd+right", "resize_split:right"),
    ("cmd+enter", "toggle_fullscreen"), ("shift+cmd+enter", "toggle_split_zoom"),
    ("shift+cmd+p", "toggle_command_palette"), ("cmd+q", "quit"), ("cmd+k", "clear_screen"),
    ("cmd+a", "select_all"), ("shift+cmd+t", "undo"), ("cmd+z", "undo"), ("shift+cmd+z", "redo"),
    ("cmd+home", "scroll_to_top"), ("cmd+end", "scroll_to_bottom"), ("cmd+page_up", "scroll_page_up"),
    ("cmd+page_down", "scroll_page_down"), ("cmd+j", "scroll_to_selection"),
    ("shift+cmd+up", "jump_to_prompt:-1"), ("shift+cmd+down", "jump_to_prompt:1"),
    ("cmd+n", "new_window"), ("cmd+w", "close_surface"), ("opt+cmd+w", "close_tab"),
    ("shift+cmd+w", "close_window"), ("opt+shift+cmd+w", "close_all_windows"), ("cmd+t", "new_tab"),
    ("shift+cmd+[", "previous_tab"), ("shift+cmd+]", "next_tab"),
    ("cmd+1", "goto_tab:1"), ("cmd+2", "goto_tab:2"), ("cmd+3", "goto_tab:3"), ("cmd+4", "goto_tab:4"),
    ("cmd+5", "goto_tab:5"), ("cmd+6", "goto_tab:6"), ("cmd+7", "goto_tab:7"), ("cmd+8", "goto_tab:8"),
    ("cmd+9", "last_tab"),
    ("cmd+d", "new_split:right"), ("shift+cmd+d", "new_split:down"),
    ("cmd+[", "goto_split:previous"), ("cmd+]", "goto_split:next"),
    ("opt+cmd+up", "goto_split:up"), ("opt+cmd+down", "goto_split:down"),
    ("opt+cmd+left", "goto_split:left"), ("opt+cmd+right", "goto_split:right"),
    ("ctrl+cmd+up", "resize_split:up"), ("ctrl+cmd+down", "resize_split:down"),
    ("ctrl+cmd+left", "resize_split:left"), ("ctrl+cmd+right", "resize_split:right"),
    ("ctrl+cmd+=", "equalize_splits"), ("cmd+up", "jump_to_prompt:-1"), ("cmd+down", "jump_to_prompt:1"),
    ("cmd+f", "start_search"), ("cmd+e", "search_selection"), ("shift+cmd+f", "end_search"),
    ("cmd+g", "navigate_search:next"), ("shift+cmd+g", "navigate_search:previous"),
    ("opt+cmd+i", "inspector"), ("ctrl+cmd+f", "toggle_fullscreen"), ("shift+cmd+v", "paste_from_selection"),
    ("cmd+right", "text:\\x05"), ("cmd+left", "text:\\x01"), ("cmd+backspace", "text:\\x15"),
];

/// The text between the first pair of double quotes after `from` in `line`.
fn quoted_after<'a>(line: &'a str, from: &str) -> Option<&'a str> {
    let rest = &line[line.find(from)? + from.len()..];
    let start = rest.find('"')? + 1;
    let end = rest[start..].find('"')? + start;
    Some(&rest[start..end])
}

/// The key equivalents `MainMenu.swift` sets by hand (`item(title, action, "z", [.command])` and
/// Hide's `keyEquivalent: "h"`), not from the catalog.
fn main_menu_keys() -> Vec<(Stroke, String)> {
    let source = read("Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift");
    let mut keys = Vec::new();
    for line in source.lines() {
        if let Some(start) = line.find("item(Strings.") {
            let call = &line[start..];
            let title = call["item(Strings.".len()..].split(',').next().unwrap_or("").to_string();
            let Some(key) = call.split(", \"").nth(1).and_then(|k| k.split('"').next()) else {
                continue;
            };
            let Some(mods) = call.split('[').nth(1).and_then(|m| m.split(']').next()) else {
                continue;
            };
            let mut modifiers = 0;
            for (flag, bit) in
                [(".command", CMD), (".option", OPT), (".shift", SHIFT), (".control", CTRL)]
            {
                if mods.contains(flag) {
                    modifiers |= bit;
                }
            }
            keys.push(((key.to_string(), modifiers), format!("menu bar {title}")));
        } else if line.contains("NSMenuItem(")
            && let Some(key) = quoted_after(line, "keyEquivalent:").filter(|k| !k.is_empty())
        {
            let title =
                line.split("Strings.").nth(1).and_then(|t| t.split(',').next()).unwrap_or("?");
            keys.push(((key.to_string(), CMD), format!("menu bar {title}")));
        }
    }
    assert!(
        keys.len() >= 10,
        "MainMenu.swift: read only {} key equivalents; did its shape change?",
        keys.len()
    );
    keys
}

/// The macOS shortcuts that are on by default (`MacOSSystemShortcutsTests.onByDefault`).
fn macos_system_keys() -> Vec<(Stroke, String)> {
    let source =
        read("Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/MacOSSystemShortcutsTests.swift");
    let keys: Vec<(Stroke, String)> = source
        .lines()
        .filter_map(|line| {
            let key = quoted_after(line, "SystemShortcut(key:")?;
            let name = quoted_after(line, "name:").unwrap_or("?");
            Some((parse(key), format!("macOS {name}")))
        })
        .collect();
    assert!(
        keys.len() >= 30,
        "MacOSSystemShortcutsTests: read only {} shortcuts; did its shape change?",
        keys.len()
    );
    keys
}

/// The first-party apps' catalog keys (`first-party-apps/*/catalog/*.json`, `keyboard` entries):
/// the binding table's app layer.
fn first_party_app_keys() -> Vec<(Stroke, String)> {
    fn walk(value: &serde_json::Value, file: &str, out: &mut Vec<(Stroke, String)>) {
        match value {
            serde_json::Value::Object(map) => {
                if let Some(serde_json::Value::Array(keys)) = map.get("keyboard") {
                    for entry in keys {
                        if let Some(key) = entry.get("key").and_then(|k| k.as_str()) {
                            let when =
                                entry.get("when").and_then(|w| w.as_str()).unwrap_or("everywhere");
                            out.push((parse(key), format!("app {file} ({when})")));
                        }
                    }
                }
                map.values().for_each(|v| walk(v, file, out));
            }
            serde_json::Value::Array(items) => items.iter().for_each(|v| walk(v, file, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    let root = repo().join("first-party-apps");
    let mut apps: Vec<_> = std::fs::read_dir(&root)
        .unwrap_or_else(|e| panic!("{}: {e}", root.display()))
        .flatten()
        .map(|e| e.path().join("catalog"))
        .filter(|p| p.is_dir())
        .collect();
    apps.sort();
    for dir in apps {
        let mut files: Vec<_> =
            std::fs::read_dir(&dir).into_iter().flatten().flatten().map(|e| e.path()).collect();
        files.sort();
        for file in files.into_iter().filter(|f| f.extension().is_some_and(|e| e == "json")) {
            let text = std::fs::read_to_string(&file)
                .unwrap_or_else(|e| panic!("{}: {e}", file.display()));
            let value: serde_json::Value =
                serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
            let name =
                file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            walk(&value, &name, &mut out);
        }
    }
    // CodeMirror's Save (`cmd+s` in the editor) at least: none read means the layout moved.
    assert!(
        !out.is_empty(),
        "first-party-apps/*/catalog/*.json: no `keyboard` key read; did the layout change?"
    );
    out
}

/// Every default binding table must be in [`binding_tables`]: each entry of
/// [`bindings::alias_entries`] (every table but the off-by-default workspaces-as-tabs keys) is in it.
#[test]
fn binding_tables_cover_every_default_binding() {
    let listed: usize = binding_tables().iter().map(|(_, table)| table.len()).sum();
    let aliases = bindings::alias_entries().count();
    assert_eq!(
        listed,
        aliases + bindings::WORKSPACES_AS_TABS.len(),
        "bindings.rs has a table binding_tables() does not list"
    );
}

/// Whether `when` requires one of `keys` (a focus key that is not negated).
fn when_requires(when: &str, keys: &[String]) -> bool {
    keys.iter().any(|key| {
        when.match_indices(key.as_str()).any(|(at, _)| {
            let before = when[..at].trim_end();
            let after = when[at + key.len()..].chars().next();
            !before.ends_with('!')
                && !after.is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '.')
        })
    })
}

/// `schemas/keybindings/ghostty-reserved-keys.json`.
struct GhosttyReserved {
    /// (stroke, command, Ghostty action).
    reserved: Vec<(Stroke, String, String)>,
    deviations: Vec<Stroke>,
    scoped_owners: Vec<String>,
    scoped_actions: Vec<String>,
}

fn ghostty_reserved() -> GhosttyReserved {
    let json: serde_json::Value =
        serde_json::from_str(&read("schemas/keybindings/ghostty-reserved-keys.json"))
            .expect("reserved keys json");
    let reserved = json["reserved"]
        .as_array()
        .expect("reserved")
        .iter()
        .map(|r| {
            (
                parse(r["key"].as_str().expect("key")),
                r["command"].as_str().expect("command").to_string(),
                r["ghostty"].as_str().unwrap_or("").to_string(),
            )
        })
        .collect();
    let deviations = json["approvedDeviations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|d| d["key"].as_str().map(parse))
        .collect();
    let strings = |pointer: &str| -> Vec<String> {
        json.pointer(pointer)
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect()
    };
    GhosttyReserved {
        reserved,
        deviations,
        scoped_owners: strings("/scopedOwners/keys"),
        scoped_actions: strings("/scopedActions"),
    }
}

/// Every owner of a key outside cmux's default keymap.
fn other_owners() -> BTreeMap<Stroke, Vec<String>> {
    let mut owners: BTreeMap<Stroke, Vec<String>> = BTreeMap::new();
    let ghostty =
        GHOSTTY_MACOS_DEFAULTS.iter().map(|(k, a)| (parse(k), format!("Ghostty default {a}")));
    for (stroke, owner) in
        ghostty.chain(main_menu_keys()).chain(macos_system_keys()).chain(first_party_app_keys())
    {
        owners.entry(stroke).or_default().push(owner);
    }
    owners
}

fn taken_on_purpose() -> BTreeSet<Stroke> {
    TAKEN_ON_PURPOSE.iter().flat_map(|(keys, _)| keys.iter().map(|k| parse(k))).collect()
}

/// `ActionRegistry.shortcutConflictGroups`: two actions on one key with the same required
/// context, digit-family-ness and Home scope, so neither can win.
#[test]
fn no_two_actions_share_a_key_in_the_same_context() {
    let mut groups: BTreeMap<(Stroke, Scope), BTreeSet<&str>> = BTreeMap::new();
    for entry in default_keymap().into_iter().filter(|e| e.kind == Kind::Shortcut) {
        groups.entry((entry.stroke, entry.scope)).or_default().insert(entry.command);
    }
    let conflicts: Vec<String> = groups
        .iter()
        .filter(|(_, ids)| ids.len() > 1)
        .map(|((stroke, scope), ids)| format!("{} {scope:?}: {ids:?}", show(stroke)))
        .collect();
    assert!(conflicts.is_empty(), "default shortcuts that conflict:\n{}", conflicts.join("\n"));
}

/// A chord leader is never also a plain key (the plain key would never run, or the chord would
/// never start), and two chords never share both keys.
#[test]
fn chord_leaders_and_chords_are_their_own() {
    let keymap = default_keymap();
    let leaders: BTreeSet<&Stroke> =
        keymap.iter().filter(|e| e.kind == Kind::ChordLeader).map(|e| &e.stroke).collect();
    let clashes: Vec<String> = keymap
        .iter()
        .filter(|e| e.kind != Kind::ChordLeader && leaders.contains(&e.stroke))
        .map(|e| format!("{} = {} is a chord leader", show(&e.stroke), e.command))
        .collect();
    assert!(clashes.is_empty(), "{}", clashes.join("\n"));

    let mut chords: BTreeMap<(Stroke, Stroke), Vec<&str>> = BTreeMap::new();
    for action in actions() {
        if let Some(chord) = &action.default_chord {
            if action.shortcut_family == Some("digits") {
                continue;
            }
            chords.entry((of(&chord.first), of(&chord.second))).or_default().push(action.id);
        }
    }
    let shared: Vec<String> = chords
        .iter()
        .filter(|(_, ids)| ids.len() > 1)
        .map(|((a, b), ids)| format!("{} {}: {ids:?}", show(a), show(b)))
        .collect();
    assert!(shared.is_empty(), "chords on the same keys:\n{}", shared.join("\n"));
}

/// Two bindings without `when` on one key run one command, and a binding without `when` never
/// sits on another action's unscoped catalog key.
#[test]
fn unscoped_bindings_have_their_key_to_themselves() {
    let keymap = default_keymap();
    let mut owners: BTreeMap<&Stroke, BTreeSet<&str>> = BTreeMap::new();
    for entry in keymap.iter().filter(|e| e.unscoped() && e.kind != Kind::ChordLeader) {
        owners.entry(&entry.stroke).or_default().insert(entry.command);
    }
    let shared: Vec<String> = owners
        .iter()
        .filter(|(_, commands)| commands.len() > 1)
        .map(|(stroke, commands)| format!("{}: {commands:?}", show(stroke)))
        .collect();
    assert!(
        shared.is_empty(),
        "unscoped default keys with more than one command:\n{}",
        shared.join("\n")
    );
}

/// Each reserved Ghostty split key is its command's, and no other unscoped default takes it
/// (`check-ghostty-reserved-keys.py` checks the exported keymap the same way).
#[test]
fn ghostty_reserved_keys_stay_their_commands() {
    let GhosttyReserved { reserved, deviations, scoped_owners, scoped_actions } =
        ghostty_reserved();
    let keymap = default_keymap();
    let mut findings = Vec::new();
    for (stroke, command, ghostty) in &reserved {
        if !keymap.iter().any(|e| &e.stroke == stroke && e.command == command) {
            findings.push(format!("{} ({ghostty}) is not {command}'s default", show(stroke)));
        }
        for entry in keymap.iter().filter(|e| &e.stroke == stroke && e.command != command) {
            let scoped = match &entry.scope {
                Scope::When(when) => when_requires(when, &scoped_owners),
                Scope::Catalog { requires, .. } => {
                    requires.iter().any(|r| scoped_owners.iter().any(|k| k == r))
                }
                Scope::Everywhere => false,
            };
            if !scoped
                && !scoped_actions.iter().any(|a| a == entry.command)
                && !deviations.contains(stroke)
            {
                findings.push(format!(
                    "{} = {} takes Ghostty's reserved {ghostty}",
                    show(stroke),
                    entry.command
                ));
            }
        }
    }
    assert!(findings.is_empty(), "{}", findings.join("\n"));
}

/// No default key is one macOS takes first, the menu bar sets by hand, Ghostty passes to a
/// terminal or a first-party app binds, unless cmux takes it on purpose ([`TAKEN_ON_PURPOSE`]).
#[test]
fn no_default_takes_a_key_another_owner_holds() {
    let owners = other_owners();
    let on_purpose = taken_on_purpose();
    let mut findings: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for entry in default_keymap() {
        let Some(holders) = owners.get(&entry.stroke) else { continue };
        let system = holders.iter().any(|h| h.starts_with("macOS "));
        if system || !on_purpose.contains(&entry.stroke) {
            findings
                .entry(format!("{} ({})", show(&entry.stroke), holders.join(", ")))
                .or_default()
                .insert(entry.command.to_string());
        }
    }
    let lines: Vec<String> =
        findings.iter().map(|(key, commands)| format!("{key}: {commands:?}")).collect();
    assert!(
        lines.is_empty(),
        "default keys another owner holds (pick a free key, or add the key to TAKEN_ON_PURPOSE with \
         why; a macOS key is never allowed):\n{}",
        lines.join("\n")
    );
}

/// Every key on [`TAKEN_ON_PURPOSE`] is still taken by a default and still held by another owner,
/// so the list never keeps a key nobody shares.
#[test]
fn taken_on_purpose_lists_only_shared_keys() {
    let owners = other_owners();
    let keymap = default_keymap();
    let stale: Vec<String> = taken_on_purpose()
        .iter()
        .filter(|stroke| {
            !owners.contains_key(*stroke) || !keymap.iter().any(|e| &e.stroke == *stroke)
        })
        .map(show)
        .collect();
    assert!(stale.is_empty(), "TAKEN_ON_PURPOSE keys nobody shares any more: {stale:?}");
}

/// Screen Sharing (`macScreen.open`) is Cmd-Shift-S: the catalog, the bindings, the menu bar,
/// Ghostty, macOS and the first-party apps leave that key free.
#[test]
fn screen_sharing_key_is_free_everywhere() {
    let open = cmux_action_catalog::find("macScreen.open").expect("Screen Sharing");
    let stroke = parse("shift+cmd+s");
    assert_eq!(open.default_shortcut.as_ref().map(of), Some(stroke.clone()));
    let others: Vec<&str> = default_keymap()
        .into_iter()
        .filter(|e| e.stroke == stroke && e.command != "macScreen.open")
        .map(|e| e.command)
        .collect();
    assert!(others.is_empty(), "shift+cmd+s is also {others:?}");
    assert_eq!(other_owners().get(&stroke), None, "shift+cmd+s has another owner");
    assert!(!taken_on_purpose().contains(&stroke));
}

/// Every `cmd+j` chord in the shipped looks' key files (`examples/looks/**`, the leader look's
/// `cmd+j e` and the rest), as the stroke after the leader and the file it is in.
fn look_leader_keys() -> Vec<(Stroke, String)> {
    fn walk(dir: &Path, out: &mut Vec<(Stroke, String)>) {
        let mut entries: Vec<_> = std::fs::read_dir(dir)
            .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
            .flatten()
            .map(|entry| entry.path())
            .collect();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                walk(&path, out);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            for (at, _) in text.match_indices("\"cmd+j ") {
                let rest = &text[at + "\"cmd+j ".len()..];
                let keys = &rest[..rest.find(['"', '\\']).unwrap_or(rest.len())];
                if let Some(second) = keys.split(' ').next().filter(|k| !k.is_empty()) {
                    out.push((parse(second), path.display().to_string()));
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(&repo().join("examples/looks"), &mut out);
    out
}

/// A default Command-J chord takes no key a shipped look already puts after Command-J: a person
/// with that look would get the look's command and Settings would show the two in conflict. Found
/// adding Open Workspace in Editor's chord, whose obvious Command-J E is the leader look's
/// Equalize Splits; it is Command-J I.
#[test]
fn default_leader_chords_leave_the_looks_their_keys() {
    let leader = parse("cmd+j");
    let looks = look_leader_keys();
    assert!(
        looks.iter().any(|(stroke, _)| *stroke == parse("e")),
        "the leader look's cmd+j e was not read"
    );
    let clashes: Vec<String> = actions()
        .filter_map(|action| action.default_chord.as_ref().map(|chord| (action.id, chord)))
        .filter(|(_, chord)| of(&chord.first) == leader)
        .flat_map(|(id, chord)| {
            let second = of(&chord.second);
            looks.iter().filter(move |(stroke, _)| *stroke == second).map(move |(stroke, file)| {
                format!("cmd+j {} = {id} is also in {file}", show(stroke))
            })
        })
        .collect();
    assert!(clashes.is_empty(), "{}", clashes.join("\n"));
}

/// Open Workspace in Editor is Command-J I, with no other default on it.
#[test]
fn open_in_editor_chord_is_command_j_i() {
    let action =
        cmux_action_catalog::find("workspace.openInEditor").expect("Open Workspace in Editor");
    let chord = action.default_chord.as_ref().expect("Open Workspace in Editor has a chord");
    assert_eq!((of(&chord.first), of(&chord.second)), (parse("cmd+j"), parse("i")));
    assert!(
        action.surfaces & cmux_action_catalog::KEYBOARD != 0,
        "the chord is not on the keyboard surface"
    );
}
