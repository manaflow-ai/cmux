//! `cmux customize docs [SURFACE]` and `cmux customize prompts [NAME]`: the reference for each
//! customization surface, written for an agent, and the copy-paste prompts for common goals.
//!
//! Nothing here is written by hand twice. A settings surface is `cmux_customize::SURFACE_KEYS`
//! (what the customize brief names) with each key's title, summary, choices and default from
//! this build's settings schema. An extension surface is its recipe page from the
//! extension-author skill (`skills/cmux-extension-author/recipes`, which
//! `ext::recipes_tests` builds and loads as written) under its interface's contract, places
//! and methods from this build's interface files (`Schema::current`). The prompts are the pages
//! of `skills/cmux-extension-author/prompts`, which the scheduled
//! `customize-prompts-cold-model` workflow pastes into a fresh model and checks with
//! `cmux ext dev --once --headless --json`. The tests below fail when a page is added
//! without being listed here, or names a surface or a key this build does not have.

use cmux_action_catalog::{CMD, CONTEXT_MENU, CTRL, KEYBOARD, MENU, OPT, SHIFT, Shortcut};
use cmux_customize::SURFACE_KEYS;
use cmux_customize::schema::Schema;
use serde_json::{Value, json};

/// The extension recipe pages, by surface name (the page's file stem).
const RECIPES: &[(&str, &str)] = &[
    ("section", include_str!("../../../../../../skills/cmux-extension-author/recipes/section.md")),
    (
        "live-section",
        include_str!("../../../../../../skills/cmux-extension-author/recipes/live-section.md"),
    ),
    ("pane", include_str!("../../../../../../skills/cmux-extension-author/recipes/pane.md")),
    ("newtab", include_str!("../../../../../../skills/cmux-extension-author/recipes/newtab.md")),
    ("widget", include_str!("../../../../../../skills/cmux-extension-author/recipes/widget.md")),
    ("command", include_str!("../../../../../../skills/cmux-extension-author/recipes/command.md")),
    (
        "composer-command",
        include_str!("../../../../../../skills/cmux-extension-author/recipes/composer-command.md"),
    ),
    (
        "composer-mention",
        include_str!("../../../../../../skills/cmux-extension-author/recipes/composer-mention.md"),
    ),
    (
        "session-info",
        include_str!("../../../../../../skills/cmux-extension-author/recipes/session-info.md"),
    ),
];

/// The copy-paste prompts, by name (the page's file stem).
const PROMPTS: &[(&str, &str)] = &[
    (
        "sidebar-show",
        include_str!("../../../../../../skills/cmux-extension-author/prompts/sidebar-show.md"),
    ),
    (
        "clone-app-flow",
        include_str!("../../../../../../skills/cmux-extension-author/prompts/clone-app-flow.md"),
    ),
    (
        "add-animation",
        include_str!("../../../../../../skills/cmux-extension-author/prompts/add-animation.md"),
    ),
    (
        "new-tab-page",
        include_str!("../../../../../../skills/cmux-extension-author/prompts/new-tab-page.md"),
    ),
    (
        "palette-command",
        include_str!("../../../../../../skills/cmux-extension-author/prompts/palette-command.md"),
    ),
    (
        "composer-slash-command",
        include_str!(
            "../../../../../../skills/cmux-extension-author/prompts/composer-slash-command.md"
        ),
    ),
];

/// cmux's motion scale: the default length of every chrome animation (hover, fold, fade, ...),
/// the file `gen-motion-scale.py` writes the pages' `--cmux-motion-*` tokens from.
const MOTION_SCALE: &str = include_str!("../../../../../../schemas/motion-scale/motion-scale.json");

/// Generated reference surfaces that are neither one recipe nor one brief line: every public
/// action, every key binding action, and the motion settings beside the timings they scale.
const REFERENCES: &[(&str, &str)] = &[
    (
        "actions",
        "Actions: every public action id, its title and where cmux offers it (no cmux needed)",
    ),
    ("keybindings", "Key bindings: every action id a key can run, its title and default keys"),
    ("motion", "Animations: the ui.animations.* switches and cmux's default chrome timings"),
];

/// A reference surface's summary, by name.
fn reference_summary(name: &str) -> String {
    REFERENCES
        .iter()
        .find(|(id, _)| *id == name)
        .map(|(_, summary)| (*summary).to_owned())
        .unwrap_or_default()
}

/// Where to look next from a settings surface: the extension surfaces that add to it.
const SEE_ALSO: &[(&str, &[&str])] = &[
    ("sidebar", &["section", "live-section"]),
    ("composer", &["composer-command", "composer-mention"]),
];

/// What `cmux ext dev` proves, the last line of every extension reference.
const PROVE_EXTENSION: &str = "Prove it: `cmux ext dev --once --json` exits 0 and its `scene` shows what you drew. \
With no cmux running (exit 3), `cmux ext dev --once --headless --json` builds, loads and renders it here.";

/// One surface's reference.
pub(super) struct Surface {
    pub name: String,
    /// `settings` or `extension`.
    pub kind: &'static str,
    pub interface: Option<String>,
    pub summary: String,
    pub text: String,
}

/// The settings surface's short name: the first word of what the brief calls it.
fn settings_name(what: &str) -> &str {
    what.split_whitespace().next().unwrap_or(what)
}

/// Every surface name, settings surfaces first, as `docs` lists them.
pub(super) fn surface_names() -> Vec<&'static str> {
    SURFACE_KEYS
        .iter()
        .map(|(what, _)| settings_name(what))
        .chain(RECIPES.iter().map(|(name, _)| *name))
        .chain(REFERENCES.iter().map(|(name, _)| *name))
        .collect()
}

pub(super) fn prompt_names() -> Vec<&'static str> {
    PROMPTS.iter().map(|(name, _)| *name).collect()
}

/// The page's title line, without its `# Recipe: ` or `# Prompt: ` head.
fn title_of(page: &str) -> String {
    let line = page.lines().next().unwrap_or_default().trim_start_matches('#').trim();
    line.split_once(": ").map_or(line, |(_, rest)| rest).to_owned()
}

/// The interface a recipe page names on its `Interface: `X`` line.
fn interface_of(page: &str) -> Option<String> {
    let line = page.lines().find(|line| line.starts_with("Interface: `"))?;
    let rest = line.strip_prefix("Interface: `")?;
    Some(rest.split('`').next()?.to_owned())
}

/// One setting's line: key, title, kind, summary, choices or range, default, who sets it.
fn setting_line(setting: &cmux_customize::schema::Setting) -> String {
    let mut text = format!("- `{}` ({}, {})", setting.key, setting.title, setting.kind);
    if let Some(summary) = &setting.summary {
        text.push_str(&format!(": {summary}"));
    }
    if !setting.choices.is_empty() {
        text.push_str(&format!(". One of: {}", setting.choices.join(", ")));
    }
    if let Some(range) = &setting.range {
        text.push_str(&format!(". {} to {} by {}{}", range.min, range.max, range.step, range.unit));
    }
    if let Some(default) = &setting.default {
        text.push_str(&format!(". Default: {default}"));
    }
    if !setting.agent_settable {
        text.push_str(". Only the person sets it");
    }
    text.push('\n');
    text
}

/// A catalog shortcut in `keybindings.json` syntax (`cmd+shift+]`, `ctrl+alt+left`).
fn key_text(shortcut: &Shortcut) -> String {
    let mut parts: Vec<String> = Vec::new();
    for (bit, name) in [(CTRL, "ctrl"), (OPT, "alt"), (SHIFT, "shift"), (CMD, "cmd")] {
        if shortcut.modifiers & bit != 0 {
            parts.push(name.to_owned());
        }
    }
    let key = match shortcut.key {
        "\u{f702}" => "left",
        "\u{f703}" => "right",
        "\u{f700}" => "up",
        "\u{f701}" => "down",
        "\r" => "enter",
        "\t" => "tab",
        "\u{1b}" => "escape",
        " " => "space",
        "\u{8}" | "\u{7f}" => "backspace",
        "\u{f728}" => "delete",
        "\u{f729}" => "home",
        "\u{f72b}" => "end",
        "\u{f72c}" => "pageup",
        "\u{f72d}" => "pagedown",
        other => other,
    };
    parts.push(key.to_owned());
    parts.join("+")
}

/// `keybindings`: every action a key can run, from the action catalog (what `cmux keybinding
/// list` reads from a running app), so an agent can bind keys with no cmux open.
fn keybindings_surface() -> Surface {
    let mut text = String::from(
        "# keybindings (reference)\n\nKey bindings live in `keybindings.json` in cmux's config folder (beside `cmux-next.json`), in the common editor \
format; cmux reloads it on save. Each entry is `{ \"key\": KEYS, \"command\": ACTION_ID }`; a `-` before the id \
removes that default. With cmux open, `cmux keybinding list --command ID` shows what is bound now and \
`cmux keybinding resolve KEYS` what keys do.\n\n```json keybindings.json\n[\n  { \"key\": \"cmd+k cmd+p\", \"command\": \"palette.open\" },\n  { \"key\": \"cmd+shift+p\", \"command\": \"-palette.open\" },\n  { \"key\": \"cmd+enter\", \"command\": \"palette.open\", \"when\": \"!terminalFocused && !agentPaneFocused\" },\n  { \"key\": \"g g\", \"command\": \"palette.open\", \"when\": \"diffViewerFocused\" }\n]\n```\n\n\
## Keys and chords\n\nOne stroke is modifiers joined by `+`, then one key: `cmd`, `shift`, `alt` (or `opt`), `ctrl`, then a \
character, `f1` to `f20` or a named key (`left`, `enter`, `escape`, `space`, `pageup`, ...). A chord is two strokes \
separated by a space (`cmd+k cmd+p`): press the first, release, press the second. A first stroke needs `cmd` or \
`ctrl`, unless it is bare under a `when` that requires a page owning bare keys or a key mode (below).\n\n\
## `when` clauses\n\nAn entry's optional `when` limits it to a context. The grammar: context keys, `!`, `&&`, `||`, \
`==`, `!=`, `=~ /regex/`, `in`, `not in`, parentheses, `true`, `false`, and quoted or bare values. \
An entry without `when` holds everywhere.\n\n",
    );
    text.push_str(&format!(
        "- Focus keys (true while that field or pane has the keyboard): {}\n",
        code_list(cmux_config::keybindings::bare::TEXT_KEYS)
    ));
    text.push_str(&format!(
        "- Pages that own bare keys (a first stroke with no modifier binds only under one of these, as an `&&` term): {}\n",
        code_list(cmux_config::keybindings::bare::OWNER_KEYS)
    ));
    text.push_str(&format!(
        "- `{mode}`: the user key mode the person entered with `keyMode.enter` (`{mode} == 'resize'`, or `{mode}` for any mode); \
it owns bare keys in any focus but a text field\n",
        mode = cmux_config::keybindings::bare::MODE_KEY
    ));
    text.push_str(
        "- An action's own context facts (the `requires` of `cmux customize docs actions`) also read as keys\n\n\
## Actions\n\n`id`: title (default keys)\n\n",
    );
    for action in cmux_action_catalog::actions() {
        if action.is_debug_only || action.surfaces & KEYBOARD == 0 {
            continue;
        }
        let mut keys: Vec<String> = action.default_shortcut.iter().map(key_text).collect();
        if let Some(chord) = &action.default_chord {
            keys.push(format!("{} {}", key_text(&chord.first), key_text(&chord.second)));
        }
        text.push_str(&format!("- `{}`: {}", action.id, action.title.en));
        if !keys.is_empty() {
            text.push_str(&format!(" ({})", keys.join(", ")));
        }
        text.push('\n');
    }
    text.push_str(
        "\nProve it: `cmux customize check` exits 0 with no problems (each problem names a file and a line).\n",
    );
    Surface {
        name: "keybindings".to_owned(),
        kind: "reference",
        interface: None,
        summary: reference_summary("keybindings"),
        text,
    }
}

/// Names as a comma-separated list of `code` spans.
fn code_list(names: &[&str]) -> String {
    names.iter().map(|name| format!("`{name}`")).collect::<Vec<_>>().join(", ")
}

/// Where the catalog offers an action, in words.
fn offered_on(action: &cmux_action_catalog::Action) -> Vec<&'static str> {
    let mut places = Vec::new();
    if action.is_palette_visible() {
        places.push("palette");
    }
    if action.surfaces & KEYBOARD != 0 {
        places.push("keys");
    }
    if action.surfaces & MENU != 0 || action.main_menu.is_some() {
        places.push("menu");
    }
    if action.surfaces & CONTEXT_MENU != 0 {
        places.push("context menu");
    }
    if action.cli() {
        places.push("cli");
    }
    places
}

/// `actions`: every public action in the catalog this build carries, grouped as declared, so an
/// agent finds an id for a keybinding, a palette scope, a button or `action.run` without a
/// running app (`cmux keybinding list` and `action.list` need one) and without reading source.
fn actions_surface() -> Surface {
    let mut text = String::from(
        "# actions (reference)\n\nEvery public action id of this build, from its action catalog: the ids a \
`keybindings.json` entry, a `cmux-next.json` button or palette entry, and an extension's `action.run` name. \
Each line: `id`: title (where cmux offers it; the context facts it requires). With cmux open, \
`cmux action run ID` runs one and `cmux keybinding list --command ID` shows its keys now.\n",
    );
    let mut group = "";
    for action in cmux_action_catalog::actions() {
        if action.is_debug_only {
            continue;
        }
        if action.group != group {
            group = action.group;
            text.push_str(&format!("\n## {group}\n\n"));
        }
        text.push_str(&format!("- `{}`: {}", action.id, action.title.en));
        let places = offered_on(action);
        if !places.is_empty() || !action.requires.is_empty() {
            text.push_str(&format!(" ({}", places.join(", ")));
            if !action.requires.is_empty() {
                if !places.is_empty() {
                    text.push_str("; ");
                }
                text.push_str(&format!("requires {}", code_list(action.requires)));
            }
            text.push(')');
        }
        text.push('\n');
    }
    text.push_str(
        "\nProve it: `cmux customize check` exits 0, so every id your config names is one of these.\n",
    );
    Surface {
        name: "actions".to_owned(),
        kind: "reference",
        interface: None,
        summary: reference_summary("actions"),
        text,
    }
}

/// `motion`: the animation settings, then the default length of each chrome motion they turn
/// off or scale (`schemas/motion-scale/motion-scale.json`, which the pages' tokens come from).
fn motion_surface(schema: &Schema) -> Surface {
    let mut text = String::from(
        "# motion (settings)\n\nAnimations in cmux's own chrome: the switches below turn a kind off, \
`ui.animationSpeed` scales every length. Write one with `cmux settings set KEY VALUE`. An extension's own \
motion (`.animation`, `.contentTransition`, `.loop`) is in `cmux customize prompts add-animation`.\n\n",
    );
    for setting in schema.settings.iter().filter(|setting| setting.key.starts_with("ui.animation"))
    {
        text.push_str(&setting_line(setting));
    }
    text.push_str(
        "\n## Default chrome timings\n\nAt the normal speed. Web pages and themes name them as `--cmux-motion-NAME` \
(never a raw number).\n\n",
    );
    let scale: Value = serde_json::from_str(MOTION_SCALE).unwrap_or(Value::Null);
    let purpose = |row: &Value| {
        let text = row["for"].as_str().unwrap_or_default();
        text.split(" (").next().unwrap_or(text).trim_end_matches('.').to_owned()
    };
    for step in scale["steps"].as_array().into_iter().flatten() {
        text.push_str(&format!(
            "- `{}`: {} ms: {}\n",
            step["name"].as_str().unwrap_or_default(),
            step["ms"],
            purpose(step)
        ));
    }
    for (name, token) in [
        ("settle", "settle"),
        ("sendPop", "send-pop"),
        ("send", "send"),
        ("spinner", "spinner-period"),
    ] {
        let row = &scale[name];
        if let Some(ms) = row["ms"].as_u64() {
            text.push_str(&format!("- `{token}`: {ms} ms: {}\n", purpose(row)));
        }
    }
    text.push_str(
        "\nProve it: `cmux customize check` exits 0 with no problems (each problem names a file and a line).\n",
    );
    Surface {
        name: "motion".to_owned(),
        kind: "settings",
        interface: None,
        summary: reference_summary("motion"),
        text,
    }
}

fn settings_surface(schema: &Schema, what: &str, keys: &[&str]) -> Surface {
    let name = settings_name(what);
    let mut text = format!("# {name} (settings)\n\n");
    text.push_str(&format!(
        "{what}: the settings below. Write one with `cmux settings set KEY VALUE`; every save shows in \
cmux at once (`cmux settings list` shows every key, `cmux customize schema settings` their types).\n\n"
    ));
    let mut example = None;
    for key in keys {
        let Some(setting) = schema.setting(key) else {
            text.push_str(&format!("- `{key}`\n"));
            continue;
        };
        text.push_str(&setting_line(setting));
        if example.is_none() && setting.agent_settable {
            let value = setting
                .choices
                .iter()
                .find(|choice| Some(&json!(choice)) != setting.default.as_ref())
                .cloned();
            example = value.map(|value| format!("cmux settings set {key} {value}"));
        }
    }
    if let Some(example) = example {
        text.push_str(&format!("\nExample:\n\n```sh\n{example}\n```\n"));
    }
    if let Some((_, also)) = SEE_ALSO.iter().find(|(surface, _)| *surface == name) {
        let also: Vec<String> =
            also.iter().map(|other| format!("`cmux customize docs {other}`")).collect();
        text.push_str(&format!("\nTo add a view of your own here: {}.\n", also.join(", ")));
    }
    text.push_str(
        "\nProve it: `cmux customize check` exits 0 with no problems (each problem names a file and a line).\n",
    );
    Surface {
        name: name.to_owned(),
        kind: "settings",
        interface: None,
        summary: what.to_owned(),
        text,
    }
}

fn extension_surface(schema: &Schema, name: &str, page: &str) -> Surface {
    let interface = interface_of(page);
    let summary = title_of(page);
    let mut text = format!("# {name} (extension)\n\n{summary}.\n");
    if let Some(interface) = &interface {
        text.push_str(&format!("\nInterface `{interface}`"));
        if let Some(point) =
            schema.extension_points.iter().find(|point| &point.interface == interface)
        {
            text.push_str(&format!(": {}\n", point.docs.trim()));
            if !point.methods.is_empty() {
                let methods: Vec<String> =
                    point.methods.keys().map(|method| format!("`{method}`")).collect();
                text.push_str(&format!("Methods: {}.\n", methods.join(", ")));
            }
            if let Some(options) = point
                .options
                .as_ref()
                .and_then(|options| options.get("properties"))
                .and_then(Value::as_object)
                .filter(|options| !options.is_empty())
            {
                let options: Vec<String> = options.keys().map(|key| format!("`{key}`")).collect();
                text.push_str(&format!("Manifest options: {}.\n", options.join(", ")));
            }
        } else {
            text.push('\n');
        }
        if let Some(slot) = schema.views.iter().find(|slot| &slot.interface == interface)
            && !slot.places.is_empty()
        {
            let option = slot.place_option.as_deref().unwrap_or("place");
            text.push_str(&format!("Places (`{option}`): {}.\n", slot.places.join(", ")));
        }
        text.push_str(&format!("Every field: `cmux customize schema extensions` ({interface}).\n"));
    }
    text.push_str("\n## A working example\n\n");
    // The page without its title line: it is the example, as the recipe test runs it.
    let body = page.split_once('\n').map_or("", |(_, rest)| rest).trim_start();
    text.push_str(body.trim_end());
    text.push_str(&format!("\n\n{PROVE_EXTENSION}\n"));
    Surface { name: name.to_owned(), kind: "extension", interface, summary, text }
}

/// Every surface's reference, in `surface_names` order.
pub(super) fn surfaces(schema: &Schema) -> Vec<Surface> {
    SURFACE_KEYS
        .iter()
        .map(|(what, keys)| settings_surface(schema, what, keys))
        .chain(RECIPES.iter().map(|(name, page)| extension_surface(schema, name, page)))
        .chain([actions_surface(), keybindings_surface(), motion_surface(schema)])
        .collect()
}

/// A prompt page's parts: its title, the check line's words (`None` for `loads`) and the
/// prompt itself (the page's ```text block).
pub(super) struct Prompt {
    pub name: &'static str,
    pub title: String,
    pub shows: Option<String>,
    pub prompt: String,
    pub page: &'static str,
}

fn prompt_of(name: &'static str, page: &'static str) -> Prompt {
    let shows = page
        .lines()
        .find_map(|line| line.trim().strip_prefix("<!-- prompt-check: shows \""))
        .and_then(|rest| rest.split('"').next())
        .map(str::to_owned);
    let prompt = page
        .split_once("```text\n")
        .and_then(|(_, rest)| rest.split_once("\n```"))
        .map_or_else(String::new, |(prompt, _)| prompt.to_owned());
    Prompt { name, title: title_of(page), shows, prompt, page }
}

pub(super) fn prompts() -> Vec<Prompt> {
    PROMPTS.iter().map(|(name, page)| prompt_of(name, page)).collect()
}

/// `docs` with no surface: one line per surface.
pub(super) fn docs_index_human(all: &[Surface]) -> String {
    let mut text = String::from(
        "The customization surfaces. `cmux customize docs SURFACE` prints one: what it is, every key \
or field, and a working example.\n\n",
    );
    let width = all.iter().map(|surface| surface.name.len()).max().unwrap_or(0);
    for surface in all {
        text.push_str(&format!(
            "  {:width$}  {:10}  {}\n",
            surface.name, surface.kind, surface.summary
        ));
    }
    text.push_str(
        "\nCopy-paste prompts for common goals (a fresh agent pastes one and finishes): `cmux customize prompts`.\n",
    );
    text.push_str(COMBINING_LOOKS);
    text
}

/// How several looks go together, and the install path that works with a pinned config file.
/// Printed under the index and in `docs --json` (`notes`).
pub(super) const COMBINING_LOOKS: &str = "\n\
Combining looks: an app's manifest `implements` is keyed by interface, so one app implements each \
interface once (one sidebar section, one pane, one New Tab page). To combine feature looks (say a \
sidebar section from one and a New Tab page from another), make one app per look, each in its own \
folder with its own `id`, and load each with `cmux ext dev DIR`; settings looks (`sidebar.look`, \
`agentPane.display.transcriptLook`, `agentPane.composerLook`) combine freely, one key each. A second \
view of the same interface goes inside the first one's render.\n\n\
Pinned config: with `CMUX_NEXT_CONFIG_FILE` set, `cmux customize apply` does not write the generation \
(it reports nothing to apply). Install a customization as a setup instead: \
`cmux setup install ./DIR` (a folder with a `cmux-setup.json`) or `cmux setup install github.com/OWNER/REPO`.\n";

pub(super) fn surface_json(surface: &Surface) -> Value {
    json!({
        "name": surface.name,
        "kind": surface.kind,
        "interface": surface.interface,
        "summary": surface.summary,
        "text": surface.text,
    })
}

pub(super) fn prompts_index_human(all: &[Prompt]) -> String {
    let mut text = String::from(
        "Copy-paste prompts. `cmux customize prompts NAME` prints one; paste its prompt into an agent \
in an empty folder and it ends with `cmux ext dev --once --json` exit 0.\n\n",
    );
    let width = all.iter().map(|prompt| prompt.name.len()).max().unwrap_or(0);
    for prompt in all {
        text.push_str(&format!("  {:width$}  {}\n", prompt.name, prompt.title));
    }
    text
}

pub(super) fn prompt_json(prompt: &Prompt) -> Value {
    json!({
        "name": prompt.name,
        "title": prompt.title,
        "shows": prompt.shows,
        "prompt": prompt.prompt,
    })
}

/// The answer to `docs [SURFACE]` or `prompts [NAME]`, human text and JSON.
pub(super) fn answer(request: &super::Request) -> Option<(String, Value)> {
    match request {
        super::Request::Docs { surface: None } => {
            let all = surfaces(&Schema::current());
            let json = json!({ "surfaces": all.iter().map(surface_json).collect::<Vec<_>>(),
                               "prompts": prompt_names() });
            Some((docs_index_human(&all), json))
        }
        super::Request::Docs { surface: Some(name) } => {
            let surface = surfaces(&Schema::current()).into_iter().find(|s| &s.name == name)?;
            Some((surface.text.clone(), surface_json(&surface)))
        }
        super::Request::Prompts { name: None } => {
            let all = prompts();
            let json = json!({ "prompts": all.iter().map(prompt_json).collect::<Vec<_>>() });
            Some((prompts_index_human(&all), json))
        }
        super::Request::Prompts { name: Some(name) } => {
            let prompt = prompts().into_iter().find(|p| p.name == name)?;
            Some((prompt.page.to_owned(), prompt_json(&prompt)))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::*;

    fn skill_dir(part: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../skills/cmux-extension-author")
            .join(part)
    }

    fn stems(part: &str) -> Vec<String> {
        let mut stems: Vec<String> = std::fs::read_dir(skill_dir(part))
            .expect("skill folder")
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| path.extension().is_some_and(|x| x == "md"))
            .map(|path| path.file_stem().unwrap().to_string_lossy().into_owned())
            .filter(|stem| stem != "README")
            .collect();
        stems.sort();
        stems
    }

    #[test]
    fn every_recipe_page_is_a_surface() {
        let mut listed: Vec<String> = RECIPES.iter().map(|(name, _)| (*name).to_owned()).collect();
        listed.sort();
        assert_eq!(
            listed,
            stems("recipes"),
            "add the new recipe page to RECIPES in customize/docs.rs"
        );
    }

    #[test]
    fn every_prompt_page_is_listed() {
        let mut listed: Vec<String> = PROMPTS.iter().map(|(name, _)| (*name).to_owned()).collect();
        listed.sort();
        assert_eq!(
            listed,
            stems("prompts"),
            "add the new prompt page to PROMPTS in customize/docs.rs"
        );
    }

    #[test]
    fn every_surface_names_what_this_build_has() {
        let schema = Schema::current();
        for (what, keys) in SURFACE_KEYS {
            for key in *keys {
                assert!(schema.setting(key).is_some(), "{what}: {key} is not a setting");
            }
        }
        for (name, page) in RECIPES {
            if let Some(interface) = interface_of(page) {
                assert!(
                    schema.extension_points.iter().any(|point| point.interface == interface),
                    "{name}: {interface} is not an interface of this build"
                );
            }
        }
        let names = surface_names();
        let mut unique = names.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), names.len(), "{names:?}");
        assert_eq!(surfaces(&schema).len(), names.len(), "a surface with no reference");
        for surface in surfaces(&schema) {
            assert!(surface.text.contains("Prove it"), "{}: no proof line", surface.name);
            if surface.kind == "extension" {
                assert!(
                    surface.text.contains("```json cmux-app.json"),
                    "{}: no manifest",
                    surface.name
                );
            }
        }
    }

    #[test]
    fn every_prompt_points_at_a_surface_and_says_how_it_is_checked() {
        let names = surface_names();
        for prompt in prompts() {
            assert!(!prompt.prompt.is_empty(), "{}: no ```text prompt", prompt.name);
            assert!(
                prompt.page.contains("<!-- prompt-check: "),
                "{}: no prompt-check line",
                prompt.name
            );
            let docs: Vec<&str> = prompt
                .prompt
                .split("cmux customize docs ")
                .skip(1)
                .filter_map(|rest| rest.split(|c: char| c == '`' || c.is_whitespace()).next())
                .collect();
            assert!(
                !docs.is_empty(),
                "{}: the prompt names no `cmux customize docs SURFACE`",
                prompt.name
            );
            for surface in docs {
                assert!(names.contains(&surface), "{}: {surface} is not a surface", prompt.name);
            }
            assert!(prompt.prompt.contains("cmux ext dev --once --json"), "{}", prompt.name);
            assert!(
                prompt.prompt.contains("cmux ext dev --once --headless --json"),
                "{}",
                prompt.name
            );
        }
    }

    #[test]
    fn docs_and_prompts_answer_before_any_store() {
        let docs = super::super::parse(&["docs".to_owned(), "section".to_owned()]).unwrap();
        let (text, json) = answer(&docs).expect("section is a surface");
        assert!(text.contains("cmux.section/1"), "{text}");
        assert_eq!(json["kind"], "extension");
        let sidebar = super::super::parse(&["docs".to_owned(), "sidebar".to_owned()]).unwrap();
        let (text, _) = answer(&sidebar).unwrap();
        assert!(text.contains("sidebar.density") && text.contains("cmux settings set"), "{text}");
        assert!(super::super::parse(&["docs".to_owned(), "nope".to_owned()]).is_err());
        let keys = super::super::parse(&["docs".to_owned(), "keybindings".to_owned()]).unwrap();
        let (text, _) = answer(&keys).unwrap();
        assert!(text.contains("`palette.open`") && text.contains("cmd+"), "{text}");
        assert!(
            text.contains("## `when` clauses") && text.contains("`diffViewerFocused`"),
            "{text}"
        );
        let actions = super::super::parse(&["docs".to_owned(), "actions".to_owned()]).unwrap();
        let (text, _) = answer(&actions).unwrap();
        let public = cmux_action_catalog::actions().filter(|action| !action.is_debug_only);
        for action in public {
            assert!(text.contains(&format!("- `{}`: ", action.id)), "actions misses {}", action.id);
        }
        let motion = super::super::parse(&["docs".to_owned(), "motion".to_owned()]).unwrap();
        let (text, _) = answer(&motion).unwrap();
        assert!(
            text.contains("ui.animations.enabled") && text.contains("`quick`: 80 ms"),
            "{text}"
        );
        let prompts = super::super::parse(&["prompts".to_owned()]).unwrap();
        let (_, json) = answer(&prompts).unwrap();
        assert_eq!(json["prompts"].as_array().map(Vec::len), Some(PROMPTS.len()));
    }
}
