//! `cmux customize docs [SURFACE]`: what a customization can express, read
//! from the registries cmux itself runs on, so the page an agent reads never
//! drifts from the code.
//!
//! - settings: the embedded settings schema (`schemas/settings/source/*.json`)
//! - theme: the theme file's keys, colors and tokens ([`Schema::current`])
//! - slots: the swappable UI pieces a theme pack picks (`schemas/theme/slots.json`)
//! - motion: the `cmux.motion/1` tables (`cmux-app-host/src/motion.rs`), the chrome motion
//!   settings and the slot motion tokens
//! - extensions: every interface (`cmux-app-host/interfaces/`) and whether cmux draws it, only
//!   the daemon reads it, or it is a draft nothing consumes yet
//! - scene: the view functions and modifiers of the typed `cmux` global (`generated/cmux-app.d.ts`)
//! - kit: the components a customization is built from, with their gallery entry
//! - behavior: what an extension can do besides draw
//!
//! Each surface's items say `drawn`, `daemon-only`, `draft` or `missing` (a piece the docs in
//! `docs/cmux-next/extensions/behavior-motion-gaps.md` name as not built yet). [`card`] is the
//! compact form the customize brief carries, and [`PROMPTS`] the copy-paste prompts the recipes
//! guide prints; `cmux-customize-recipes`' `tests/prompts.rs` installs or validates each one's
//! artifact.

use serde::Serialize;
use serde_json::{Value, json};

use crate::schema::Schema;

/// The format of `cmux customize docs --json` and of the card.
pub const DOCS_SCHEMA: &str = "cmux.customize.docs/1";

/// The theme slot registry, the same file the web view and the theme pack reader use.
pub const SLOTS_JSON: &str = include_str!("../../../../schemas/theme/slots.json");

/// The surfaces, in the order the page lists them, each with the registry it is read from.
pub const SURFACES: &[(&str, &str, &str)] = &[
    ("settings", "Settings", "schemas/settings/source/*.json"),
    ("theme", "Theme file", "the theme file schema (cmux-theme-tokens)"),
    ("slots", "Theme slots", "schemas/theme/slots.json"),
    ("motion", "Motion", "cmux-app-host/src/motion.rs (cmux.motion/1)"),
    ("extensions", "Extension interfaces", "cmux-app-host/interfaces/"),
    ("scene", "Scene views and modifiers", "cmux-app-host/generated/cmux-app.d.ts"),
    ("kit", "Kit components", "webviews/src/kit/index.ts and the gallery"),
    ("behavior", "Behavior", "cmux-app-host/interfaces/ and the behavior and motion gaps"),
];

/// How far an item goes today.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reach {
    /// cmux draws it or acts on it.
    Drawn,
    /// The daemon reads it (lists it, routes to it), and no view draws it.
    DaemonOnly,
    /// A contract with no consumer yet: a package may implement it, and nothing calls it.
    Draft,
    /// Not expressible yet; the item names the missing piece.
    Missing,
}

impl Reach {
    pub fn name(self) -> &'static str {
        match self {
            Reach::Drawn => "drawn",
            Reach::DaemonOnly => "daemon-only",
            Reach::Draft => "draft",
            Reach::Missing => "missing",
        }
    }
}

/// One thing a surface can express.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Item {
    pub name: String,
    pub reach: Reach,
    pub docs: String,
}

/// One surface's page.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Surface {
    pub name: &'static str,
    pub title: &'static str,
    pub source: &'static str,
    pub items: Vec<Item>,
}

/// Every interface, by how far cmux takes it (docs/cmux-next/extensions/state-of-the-sdk.md).
/// `cmux-customize-recipes`' `tests/prompts.rs` holds this to the embedded interface files, so a new interface fails until
/// it is placed here.
pub const INTERFACE_REACH: &[(&str, Reach)] = &[
    ("cmux.chat.action", Reach::DaemonOnly),
    ("cmux.chat.widget", Reach::Drawn),
    ("cmux.composer.chip", Reach::Drawn),
    ("cmux.composer.command", Reach::Drawn),
    ("cmux.composer.mention", Reach::Drawn),
    ("cmux.composer.model.picker", Reach::DaemonOnly),
    ("cmux.composer.toolbar", Reach::DaemonOnly),
    ("cmux.contact.provider", Reach::Draft),
    ("cmux.credential.provider", Reach::Draft),
    ("cmux.diff.renderer", Reach::Draft),
    ("cmux.diff.source", Reach::Draft),
    ("cmux.editor", Reach::Drawn),
    ("cmux.feed.source", Reach::Draft),
    ("cmux.fs.provider", Reach::Draft),
    ("cmux.hovercard", Reach::Drawn),
    ("cmux.newtab", Reach::Drawn),
    ("cmux.opener", Reach::Drawn),
    ("cmux.palette.scope", Reach::Drawn),
    ("cmux.pane", Reach::Drawn),
    ("cmux.search.provider", Reach::Draft),
    ("cmux.section", Reach::Drawn),
    ("cmux.session.info.section", Reach::Drawn),
    ("cmux.sidebar.rows", Reach::Drawn),
    ("cmux.signal.source", Reach::DaemonOnly),
    ("cmux.status", Reach::Drawn),
    ("cmux.terminal.backend", Reach::DaemonOnly),
    ("cmux.terminal.connector", Reach::DaemonOnly),
    ("cmux.viewer", Reach::Drawn),
    ("cmux.widget", Reach::Drawn),
];

/// The gallery entry that shows every kit component in light and dark: the docs' picture.
pub const KIT_GALLERY: &str = "kit.primitives";

/// Where the kit's component manifest goes once the component-libraries work lands it (a JSON
/// list of every component, its props and its gallery entry). Until that file exists the kit
/// surface is the table below; when it does, [`kit_items`] should read it instead.
pub const KIT_COMPONENT_MANIFEST: &str = "webviews/src/kit/components.json";

/// The kit, as a customization builds with it: the scene function a views app or extension
/// calls, and the web export (`webviews/src/kit/index.ts`) the same piece is drawn with.
/// `cmux-customize-recipes`' `tests/prompts.rs` holds every web name to the kit's exports and every scene name to the
/// typed global.
pub const KIT: &[(&str, Option<&str>, Option<&str>, &str)] = &[
    (
        "Button",
        Some("Button"),
        Some("Button"),
        "A pressable label or icon; a Menu's items are Buttons.",
    ),
    (
        "Card",
        Some("Panel"),
        Some("Card"),
        "The app's card surface; a scene's Panel is drawn as one.",
    ),
    ("Panel", Some("Panel"), Some("Panel"), "A titled surface that groups rows."),
    (
        "Row",
        Some("Row"),
        Some("Row"),
        "One line with a symbol, a title, a detail and an accessory.",
    ),
    ("Pill", Some("Badge"), Some("Pill"), "A short count or state in a tone, never a color."),
    ("Menu", Some("Menu"), Some("Menu"), "Actions behind one button."),
    ("Tooltip", None, Some("Tooltip"), "A hover label; a scene node takes `.help(TEXT)`."),
    (
        "Glass",
        None,
        Some("Glass"),
        "The frosted surface; a theme's glass settings pick it for chrome.",
    ),
    ("Toggle", Some("Toggle"), None, "An on and off switch bound to a signal."),
    ("Slider", Some("Slider"), None, "A value in a range bound to a signal."),
    ("TextField", Some("TextField"), Some("Input"), "A text field with submit and cancel."),
    ("EmptyState", Some("EmptyState"), None, "What a view draws when it has nothing to show."),
    ("Icon", Some("Icon"), Some("Icon"), "A symbol by name."),
    (
        "Motion presets",
        None,
        Some("motionToken"),
        "The shared springs and fades; in a scene, `.animation(TOKEN)` with a cmux.motion/1 token.",
    ),
];

/// Behavior and motion that cannot be said yet, from
/// docs/cmux-next/extensions/behavior-motion-gaps.md, by the surface they belong to.
pub const GAPS: &[(&str, &str, &str)] = &[
    (
        "motion",
        "transition timing",
        "A transition takes no timing: it always uses the renderer's own spring.",
    ),
    (
        "motion",
        "negative spin on macOS",
        "The native renderer clamps a loop's amount to [0, 10], so a counterclockwise spin turns clockwise.",
    ),
    (
        "motion",
        "preset table",
        "No manifest- or theme-level motion preset table: a profile cannot retime its extensions in one place.",
    ),
    (
        "motion",
        "chrome timings",
        "Chrome motion is only ui.animationSpeed, ui.animation and ui.paneAnimations: a profile cannot set its own springs.",
    ),
    (
        "motion",
        "agentPane.display.streaming",
        "No setting for how agent text streams in (per token, per line or instant, and its fade).",
    ),
    (
        "motion",
        "scroll-linked props",
        "An extension cannot pin a header or fade content against its scroll position.",
    ),
    (
        "behavior",
        "contributes.keybindings",
        "A manifest cannot declare keybindings; a person sets keybindings.* in their own config.",
    ),
    (
        "behavior",
        "pane open arguments",
        "cmux.pane/1 has no open arguments, results or onOpen and onClose events.",
    ),
    (
        "behavior",
        "state across hot reload",
        "Scene state (scroll position, focused field, expanded rows) is lost on a hot reload.",
    ),
    (
        "behavior",
        "onKeybinding and onCommand activation",
        "Activation has onStartup, onInterface, onOp and onEvent only.",
    ),
];

/// What an agent builds for a prompt, so a test can install or validate it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "path", rename_all = "camelCase")]
pub enum Artifact {
    /// A recipe by name: `cmux customize use` previews it.
    Recipe(&'static str),
    /// A profile file in the repository, previewed the same way.
    Profile(&'static str),
    /// An extension folder in the repository: `cmux ext dev --once` validates it.
    Package(&'static str),
    /// A skill recipe page whose fenced `cmux-app.json` is the whole extension.
    SkillRecipe(&'static str),
    /// A theme pack folder: its `slots` pick variants from the slot registry.
    ThemePack(&'static str),
}

/// One copy-paste prompt for an agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Prompt {
    pub id: &'static str,
    pub surface: &'static str,
    pub title: &'static str,
    pub text: &'static str,
    pub artifact: Artifact,
}

/// The copy-paste prompts the recipes guide prints, word for word. Each tells the agent to
/// build only from kit components and where to look up what it may use.
pub const PROMPTS: &[Prompt] = &[
    Prompt {
        id: "motion-off",
        surface: "motion",
        title: "Turn motion off",
        text: "Turn off motion in my cmux: nothing slides, pulses or blinks. Run `cmux customize docs motion` and change only the chrome motion settings it lists. Preview it, check `cmux customize status --json` has no problems, and leave Apply to me.",
        artifact: Artifact::Recipe("calm"),
    },
    Prompt {
        id: "motion-cockpit",
        surface: "motion",
        title: "Counters that roll and cards that slide in",
        text: "Make my New Tab page a cockpit: a greeting, live counters that roll when they change, and cards that slide in. Build only from kit components (`cmux customize docs kit`; the kit.primitives gallery shows each one in light and dark). Animate only with cmux.motion/1 values from `cmux customize docs motion`: `.contentTransition(\"numericText\")` on counters, `.transition(\"slide\")` on cards, `.animation(\"smooth\")` on changes. Preview it and fix every problem `cmux customize status --json` lists.",
        artifact: Artifact::Profile("examples/customize-demo/last-demo/cockpit.json"),
    },
    Prompt {
        id: "motion-thinking-slot",
        surface: "motion",
        title: "A different thinking indicator",
        text: "Change how the chat shows that an agent is thinking: use the pulse variant of the chat.thinkingIndicator slot in a theme pack. Pick the slot and the variant from `cmux customize docs slots`; set nothing else, and draw no indicator of your own.",
        artifact: Artifact::ThemePack("examples/theme-packs/sakura"),
    },
    Prompt {
        id: "motion-background",
        surface: "motion",
        title: "A moving background",
        text: "Put a moving aurora behind the window, as a live wallpaper the theme names. It must stop under Reduce Motion. Use only settings `cmux customize docs settings` lists and preview it with `cmux customize use`.",
        artifact: Artifact::Recipe("aurora-night"),
    },
    Prompt {
        id: "behavior-pane-keys",
        surface: "behavior",
        title: "Keys that move between panes",
        text: "Let me move between panes with Control-Command-H, J, K and L, like Vim. Bind only actions cmux has (`cmux customize docs behavior` says where keybindings go) and keep every key I already bound.",
        artifact: Artifact::Recipe("pane-keys"),
    },
    Prompt {
        id: "behavior-leader",
        surface: "behavior",
        title: "A leader key for panes",
        text: "Give me a leader key: Command-J, then one key to split, zoom, even out, resize or move panes. Use cmux's own leader and actions cmux has, so no key a terminal or a chat types is taken.",
        artifact: Artifact::Recipe("leader"),
    },
    Prompt {
        id: "behavior-slash-command",
        surface: "behavior",
        title: "A slash command in the chat composer",
        text: "Add a /standup command to the agent chat composer that writes: \"Write my standup: what I did yesterday, what I do today, what blocks me.\" Implement cmux.composer.command/1 from the manifest alone, with no script (`cmux customize docs extensions` lists it), and check it with `cmux ext dev --once --json`.",
        artifact: Artifact::SkillRecipe("skills/cmux-extension-author/recipes/composer-command.md"),
    },
    Prompt {
        id: "kit-section",
        surface: "kit",
        title: "A sidebar section built from the kit",
        text: "Add a sidebar section with today's tasks: a lead line, one row per task with a symbol, and the actions in a menu. Build only from kit components (`cmux customize docs kit`: Panel, Row, Button, Menu, Toggle, Badge, EmptyState); use tones, never a literal color or size, and draw every state. Check it with `cmux customize status --json`.",
        artifact: Artifact::Package("skills/cmux-customization/templates/starter"),
    },
];

/// The prompt with this id.
pub fn prompt(id: &str) -> Option<&'static Prompt> {
    PROMPTS.iter().find(|prompt| prompt.id == id)
}

/// Every surface's page, or the one named.
pub fn docs(surface: Option<&str>) -> Result<Vec<Surface>, String> {
    let Some(name) = surface else { return Ok(SURFACES.iter().map(page).collect()) };
    match SURFACES.iter().find(|(surface, ..)| *surface == name) {
        Some(listed) => Ok(vec![page(listed)]),
        None => {
            let names: Vec<&str> = SURFACES.iter().map(|(name, ..)| *name).collect();
            Err(format!("no docs surface {name:?}; pick one of {}", names.join(", ")))
        }
    }
}

fn page(&(name, title, source): &(&'static str, &'static str, &'static str)) -> Surface {
    let items = match name {
        "settings" => settings_items(),
        "theme" => theme_items(),
        "slots" => slot_items(),
        "motion" => motion_items(),
        "extensions" => interface_items(|_| true),
        "scene" => scene_items(),
        "kit" => kit_items(),
        _ => behavior_items(),
    };
    Surface { name, title, source, items }
}

fn item(name: impl Into<String>, reach: Reach, docs: impl Into<String>) -> Item {
    Item { name: name.into(), reach, docs: docs.into() }
}

fn settings_items() -> Vec<Item> {
    let schema = Schema::current();
    let mut sections: Vec<(String, usize, usize)> = Vec::new();
    for setting in &schema.settings {
        let settable = usize::from(setting.agent_settable);
        if let Some((_, keys, editable)) =
            sections.iter_mut().find(|(name, ..)| *name == setting.section)
        {
            *keys += 1;
            *editable += settable;
        } else {
            sections.push((setting.section.clone(), 1, settable));
        }
    }
    sections
        .into_iter()
        .map(|(section, keys, settable)| {
            item(
                section,
                Reach::Drawn,
                format!(
                    "{keys} keys, {settable} an agent may set; `cmux customize schema settings` lists each with its values"
                ),
            )
        })
        .collect()
}

fn theme_items() -> Vec<Item> {
    let theme = Schema::current().theme;
    let mut items = vec![
        item(
            theme.file_setting,
            Reach::Drawn,
            format!(
                "names the theme file in {}/; keys: {}",
                theme.folder,
                theme.file_keys.join(", ")
            ),
        ),
        item("colors", Reach::Drawn, theme.colors.join(", ")),
    ];
    items.extend(
        theme
            .tokens
            .iter()
            .map(|token| item(token.name.clone(), Reach::Drawn, token.formula.clone())),
    );
    items
}

fn slots() -> Value {
    // The registry is embedded and tests/prompts.rs reads it, so null is never what ships.
    serde_json::from_str(SLOTS_JSON).unwrap_or_default()
}

/// Every slot id with its variant ids, as the registry lists them.
pub fn slot_variants() -> Vec<(String, Vec<String>)> {
    let slots = slots();
    slots
        .get("slots")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|slot| {
            let variants = slot
                .get("variants")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|variant| variant.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect();
            (slot.get("id").and_then(Value::as_str).unwrap_or_default().to_owned(), variants)
        })
        .collect()
}

fn slot_items() -> Vec<Item> {
    let registry = slots();
    let mut items: Vec<Item> = registry
        .get("slots")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|slot| {
            let variants: Vec<&str> = slot
                .get("variants")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|variant| variant.get("id").and_then(Value::as_str))
                .collect();
            item(
                slot.get("id").and_then(Value::as_str).unwrap_or_default(),
                Reach::Drawn,
                format!(
                    "{}: variants {} (default {}); a theme pack picks one with \"slots\": {{ID: VARIANT}}",
                    slot.get("title").and_then(Value::as_str).unwrap_or_default(),
                    variants.join(", "),
                    slot.get("defaultVariant").and_then(Value::as_str).unwrap_or("default"),
                ),
            )
        })
        .collect();
    items.extend(registry.get("next").and_then(Value::as_array).into_iter().flatten().map(
        |next| {
            item(
                next.get("id").and_then(Value::as_str).unwrap_or_default(),
                Reach::Missing,
                first_sentence(next.get("docs").and_then(Value::as_str).unwrap_or_default()),
            )
        },
    ));
    items
}

fn motion_items() -> Vec<Item> {
    use cmux_app_host::motion::*;
    let range = |(low, high): (f64, f64)| format!("{low} to {high}");
    let mut items = vec![
        item(
            ".animation(MOTION)",
            Reach::Drawn,
            format!(
                "{SCHEMA}: a token ({}), {{duration, curve}} with curve {} and a duration of {} s, or {{spring: {{response, dampingFraction}}}} with dampingFraction {}",
                MOTION_TOKENS.join(", "),
                CURVES.join(" | "),
                range(TIME_RANGE),
                range(DAMPING_RANGE),
            ),
        ),
        item(
            ".transition(KIND)",
            Reach::Drawn,
            format!("enter and exit: {}", TRANSITIONS.join(", ")),
        ),
        item(
            ".contentTransition(KIND)",
            Reach::Drawn,
            format!("a changing value: {}", CONTENT_TRANSITIONS.join(", ")),
        ),
        item(
            ".loop({effect, period, amount})",
            Reach::Drawn,
            format!(
                "effects {}; period {} s, amount {}; stops under Reduce Motion",
                LOOP_EFFECTS
                    .iter()
                    .map(|(effect, period)| format!("{effect} ({period} s)"))
                    .collect::<Vec<_>>()
                    .join(", "),
                range(LOOP_PERIOD_RANGE),
                range(LOOP_AMOUNT_RANGE),
            ),
        ),
        item(
            "Particles({preset})",
            Reach::Drawn,
            "cmux.particles/1: a particle field or a choreographed glyph",
        ),
    ];
    let schema = Schema::current();
    items.extend(schema.settings.iter().filter(|setting| is_motion_setting(&setting.key)).map(
        |setting| {
            let values = if setting.choices.is_empty() {
                setting.kind.to_owned()
            } else {
                setting.choices.join(", ")
            };
            item(setting.key.clone(), Reach::Drawn, format!("chrome motion setting: {values}"))
        },
    ));
    let registry = slots();
    if let Some(durations) =
        registry.get("tokens").and_then(|tokens| tokens.get("durations")).and_then(Value::as_object)
    {
        let names: Vec<&str> =
            durations.keys().filter(|key| !key.starts_with('$')).map(String::as_str).collect();
        items.push(item(
            "slot motion tokens",
            Reach::Drawn,
            format!("a slot variant times itself with {}", names.join(", ")),
        ));
    }
    items.extend(gap_items("motion"));
    items
}

fn is_motion_setting(key: &str) -> bool {
    key.starts_with("ui.animation") || key == "ui.paneAnimations" || key == "ui.calm"
}

fn gap_items(surface: &str) -> impl Iterator<Item = Item> + '_ {
    GAPS.iter()
        .filter(move |(on, ..)| *on == surface)
        .map(|(_, name, docs)| item(*name, Reach::Missing, *docs))
}

/// The reach of an interface (`cmux.section`, no version).
pub fn interface_reach(interface: &str) -> Option<Reach> {
    INTERFACE_REACH.iter().find(|(name, _)| *name == interface).map(|(_, reach)| *reach)
}

/// The embedded interface files, as (name, version, docs).
pub fn interfaces() -> Vec<(String, u64, String)> {
    let mut found: Vec<(String, u64, String)> = cmux_app_manifest::interface_files()
        .iter()
        .filter_map(|(_, text)| serde_json::from_str::<Value>(text).ok())
        .map(|file| {
            // The file's name carries its version (`cmux.section/1`).
            let full = file.get("name").and_then(Value::as_str).unwrap_or_default();
            let (name, version) = match full.rsplit_once('/') {
                Some((name, version)) => (name, version.parse().ok()),
                None => (full, None),
            };
            (
                name.to_owned(),
                version.or_else(|| file.get("version").and_then(Value::as_u64)).unwrap_or(1),
                file.get("docs").and_then(Value::as_str).unwrap_or_default().to_owned(),
            )
        })
        .collect();
    found.sort();
    found
}

fn interface_items(keep: impl Fn(&str) -> bool) -> Vec<Item> {
    interfaces()
        .into_iter()
        .filter(|(name, ..)| keep(name))
        .map(|(name, version, docs)| {
            let reach = interface_reach(&name).unwrap_or(Reach::Draft);
            item(format!("{name}/{version}"), reach, first_sentence(&docs))
        })
        .collect()
}

/// The view functions (`Panel`, `Row`, ...) and modifiers (`.animation`, ...) of the typed
/// global, with the doc line the d.ts has for each.
pub fn scene_api() -> (Vec<(String, String)>, Vec<String>) {
    let types = cmux_app_manifest::capabilities::APP_TYPES.get();
    let mut views = Vec::new();
    let mut doc = String::new();
    for line in types.lines() {
        let line = line.trim();
        if let Some(text) = line.strip_prefix("/**").and_then(|text| text.strip_suffix("*/")) {
            doc = text.trim().to_owned();
            continue;
        }
        if let Some(rest) = line.strip_prefix("declare function ")
            && rest.starts_with(|c: char| c.is_ascii_uppercase())
            && rest.contains("): CmuxView")
        {
            let name: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
            views.push((name, std::mem::take(&mut doc)));
            continue;
        }
        doc.clear();
    }
    let mut modifiers = Vec::new();
    if let Some((_, body)) = types.split_once("interface CmuxView {") {
        let block = body.split_once("\n}").map_or(body, |(block, _)| block);
        for line in block
            .lines()
            .map(str::trim)
            .filter(|line| !line.starts_with("/**") && !line.starts_with('*'))
        {
            for part in line.split("; ") {
                if let Some((name, _)) = part.trim().split_once('(')
                    && !name.is_empty()
                    && name.chars().all(|c| c.is_ascii_alphanumeric())
                    && !modifiers.iter().any(|existing| existing == name)
                {
                    modifiers.push(name.to_owned());
                }
            }
        }
    }
    (views, modifiers)
}

fn scene_items() -> Vec<Item> {
    let (views, modifiers) = scene_api();
    let mut items: Vec<Item> =
        views.into_iter().map(|(name, doc)| item(format!("{name}()"), Reach::Drawn, doc)).collect();
    items.push(item(
        "modifiers",
        Reach::Drawn,
        modifiers.iter().map(|name| format!(".{name}")).collect::<Vec<_>>().join(" "),
    ));
    items
}

fn kit_items() -> Vec<Item> {
    let mut items: Vec<Item> = KIT
        .iter()
        .map(|(name, scene, web, docs)| {
            let mut docs = (*docs).to_owned();
            if let Some(scene) = scene {
                docs.push_str(&format!(" Scene: {scene}()."));
            }
            if let Some(web) = web {
                docs.push_str(&format!(" Web kit: {web}."));
            }
            docs.push_str(&format!(" Gallery: {KIT_GALLERY}, light and dark."));
            item(*name, Reach::Drawn, docs)
        })
        .collect();
    items.push(item(
        "component manifest",
        Reach::Draft,
        format!("pending: {KIT_COMPONENT_MANIFEST} (every component, its props and its gallery entry); read it once it lands"),
    ));
    items
}

fn behavior_items() -> Vec<Item> {
    let mut items = vec![
        item(
            "keybindings.json",
            Reach::Drawn,
            "the person's own keys: `{\"key\": ACTION}` over the action catalog",
        ),
        item("contributes.menus", Reach::Drawn, "menu items an extension adds"),
        item("contributes.toolbarItems", Reach::Drawn, "toolbar items an extension adds"),
        item("activation", Reach::Drawn, "onStartup, onInterface, onOp, onEvent"),
        item("app.storage.*", Reach::Drawn, "state an extension keeps across reloads"),
    ];
    items.extend(interface_items(|name| {
        !matches!(
            name,
            "cmux.section"
                | "cmux.newtab"
                | "cmux.widget"
                | "cmux.chat.widget"
                | "cmux.sidebar.rows"
        )
    }));
    items.extend(gap_items("behavior"));
    items
}

fn first_sentence(text: &str) -> String {
    let text = text.trim();
    match text.split_once(". ") {
        Some((sentence, _)) => format!("{sentence}."),
        None => text.to_owned(),
    }
}

/// The pages as JSON.
pub fn json(surfaces: &[Surface]) -> Value {
    json!({ "schema": DOCS_SCHEMA, "surfaces": surfaces, "prompts": PROMPTS })
}

/// The pages as text, one line per item.
pub fn text(surfaces: &[Surface]) -> String {
    let mut out = String::new();
    for surface in surfaces {
        out.push_str(&format!("{} ({}; from {})\n", surface.title, surface.name, surface.source));
        for item in &surface.items {
            out.push_str(&format!("  [{}] {}: {}\n", item.reach.name(), item.name, item.docs));
        }
        let prompts: Vec<&Prompt> =
            PROMPTS.iter().filter(|prompt| prompt.surface == surface.name).collect();
        if !prompts.is_empty() {
            out.push_str("  Copy-paste prompts:\n");
            for prompt in prompts {
                out.push_str(&format!("  - {}: {}\n", prompt.title, prompt.text));
            }
        }
        out.push('\n');
    }
    out
}

/// The capability card: per surface, how many items each reach has, plus the motion values
/// and the kit rule, small enough for the customize brief.
pub fn card() -> Value {
    use cmux_app_host::motion::*;
    let surfaces: Vec<Value> = docs(None)
        .unwrap_or_default()
        .iter()
        .map(|surface| {
            let count =
                |reach: Reach| surface.items.iter().filter(|item| item.reach == reach).count();
            json!({
                "name": surface.name,
                "drawn": count(Reach::Drawn),
                "daemonOnly": count(Reach::DaemonOnly),
                "draft": count(Reach::Draft),
                "missing": count(Reach::Missing),
            })
        })
        .collect();
    json!({
        "schema": DOCS_SCHEMA,
        "surfaces": surfaces,
        "buildFrom": "kit",
        "kitGallery": KIT_GALLERY,
        "kit": KIT.iter().map(|(name, ..)| *name).collect::<Vec<_>>(),
        "motion": {
            "schema": SCHEMA,
            "tokens": MOTION_TOKENS,
            "transitions": TRANSITIONS,
            "contentTransitions": CONTENT_TRANSITIONS,
            "loops": LOOP_EFFECTS.iter().map(|(effect, _)| *effect).collect::<Vec<_>>(),
        },
        "slots": slot_variants().into_iter().map(|(id, _)| id).collect::<Vec<_>>(),
        "prompts": PROMPTS.iter().map(|prompt| prompt.id).collect::<Vec<_>>(),
        "more": "cmux customize docs SURFACE",
    })
}

/// The card as the brief's few lines.
pub fn card_text() -> String {
    use cmux_app_host::motion::*;
    let surfaces = docs(None).unwrap_or_default();
    let counts: Vec<String> = surfaces
        .iter()
        .map(|surface| {
            let drawn = surface.items.iter().filter(|item| item.reach == Reach::Drawn).count();
            let other = surface.items.len() - drawn;
            if other == 0 {
                format!("{} {drawn}", surface.name)
            } else {
                format!("{} {drawn} (+{other} not drawn)", surface.name)
            }
        })
        .collect();
    format!(
        "What a customization can express (`cmux customize docs SURFACE` says each item, and \
whether cmux draws it): {}.\n\
Build views only from kit components ({}; the {KIT_GALLERY} gallery shows each in light and dark). \
Motion is {SCHEMA}: `.animation({})`, `.transition({})`, `.contentTransition({})`, `.loop({{effect: {}}})`; \
a theme pack's `slots` swap {}.\n",
        counts.join(", "),
        KIT.iter().map(|(name, ..)| *name).collect::<Vec<_>>().join(", "),
        MOTION_TOKENS.join("|"),
        TRANSITIONS.join("|"),
        CONTENT_TRANSITIONS.join("|"),
        LOOP_EFFECTS.iter().map(|(effect, _)| *effect).collect::<Vec<_>>().join("|"),
        slot_variants().into_iter().map(|(id, _)| id).collect::<Vec<_>>().join(", "),
    )
}

/// Every motion value a script passes to `.animation`, `.transition`, `.contentTransition` or
/// `.loop` as a string literal that `cmux.motion/1` refuses, one line each.
pub fn motion_problems(script: &str) -> Vec<String> {
    let mut found = Vec::new();
    for (method, key) in [
        (".animation(\"", "animation"),
        (".transition(\"", "transition"),
        (".contentTransition(\"", "contentTransition"),
        (".loop(\"", "loop"),
    ] {
        let mut rest = script;
        while let Some((_, argument)) = rest.split_once(method) {
            rest = argument;
            let Some((literal, _)) = argument.split_once('"') else { break };
            let value = Value::String(literal.to_owned());
            if let Some(Err(error)) = cmux_app_host::motion::normalize_prop(key, &value) {
                found.push(format!("{key}({value}): {error}"));
            }
        }
    }
    found
}
