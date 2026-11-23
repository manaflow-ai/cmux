//! Recipes: ready-made customizations a person tries with one click (Leo,
//! 2026-11-14: "the ergonomics need to be real good like just ultra
//! braindead").
//!
//! A recipe is a cmux profile (`cmuxProfile: 1`, the format
//! `cmux customize save` writes and `cmux customize use` previews), plus the
//! words a guide shows for it. Nothing here previews, applies or rolls back:
//! the `cmux-customize` engine does that, so a recipe is a draft like any
//! other (live on screen, then Apply or Discard, every apply a generation).
//!
//! The profiles are files in `recipes/`; a recipe that ships a views app
//! takes its script from the customization skill's tested templates, so the
//! widget a recipe installs is the one the templates' tests run. [`problems`]
//! checks a recipe against the settings schema, and the tests hold every
//! shipped recipe to it.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use cmux_config::Schema;
use cmux_customize::Part;
use cmux_customize::profile::{Profile, valid_name};

/// Where a guide groups a recipe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Group {
    Look,
    Layout,
    Type,
    Widgets,
    Keys,
    /// Looks and behavior like another app's, whole: theme file, chat stylesheet and settings.
    Apps,
}

impl Group {
    pub const ALL: &'static [Group] =
        &[Group::Look, Group::Layout, Group::Type, Group::Widgets, Group::Keys, Group::Apps];

    pub fn title(self) -> &'static str {
        match self {
            Group::Look => "Look",
            Group::Layout => "Layout",
            Group::Type => "Type",
            Group::Widgets => "Widgets",
            Group::Keys => "Keys",
            Group::Apps => "App looks",
        }
    }
}

/// One recipe: its profile text and what a guide says about it.
#[derive(Debug)]
pub struct Recipe {
    /// The profile's name and its file name (`compact-sidebar`).
    pub name: &'static str,
    pub title: &'static str,
    pub group: Group,
    /// The same change said as a wish, for `cmux customize 'WISH'` when the
    /// person wants an agent to tailor it.
    pub ask: &'static str,
    /// The profile file (`recipes/NAME.json`).
    profile: &'static str,
    /// Files the profile takes from elsewhere in the repository, by logical
    /// path: a views app's manifest and script from a tested template.
    includes: &'static [(&'static str, &'static str)],
}

const MY_PRS: &[(&str, &str)] = &[
    (
        "customize/cmux-app.json",
        include_str!("../../../../skills/cmux-customization/templates/my-prs/cmux-app.json"),
    ),
    (
        "customize/main.js",
        include_str!("../../../../skills/cmux-customization/templates/my-prs/main.js"),
    ),
];

const CLOCK_WEATHER: &[(&str, &str)] = &[
    (
        "customize/cmux-app.json",
        include_str!("../../../../skills/cmux-customization/templates/clock-weather/cmux-app.json"),
    ),
    (
        "customize/main.js",
        include_str!("../../../../skills/cmux-customization/templates/clock-weather/main.js"),
    ),
];

/// A look-alike carries its theme file and its chat stylesheet, kept as real
/// files beside the recipe so they read and diff like any theme or stylesheet.
const CODEX_APP: &[(&str, &str)] = &[
    ("themes/codex-app.json", include_str!("../recipes/apps/codex-app/theme.json")),
    ("agent-pane/theme.css", include_str!("../recipes/apps/codex-app/agent-pane.css")),
];

const CLAUDE_CODE_APP: &[(&str, &str)] = &[
    ("themes/claude-code-app.json", include_str!("../recipes/apps/claude-code-app/theme.json")),
    ("agent-pane/theme.css", include_str!("../recipes/apps/claude-code-app/agent-pane.css")),
];

/// Layout and behaviour looks (c-07be086806, Leo: "im saying the big stuff"): each is a look
/// folder in `examples/looks`, and the recipe is that look's `cmux-setup.json` with its
/// `keybindings.json`, so the gallery's install test and these tests hold the same files.
const LEADER: &[(&str, &str)] =
    &[("keybindings.json", include_str!("../../../../examples/looks/leader/keybindings.json"))];

const REVIEW_DESK: &[(&str, &str)] = &[(
    "keybindings.json",
    include_str!("../../../../examples/looks/review-desk/keybindings.json"),
)];

/// Hairline carries the gallery look's own files, so the recipe and the
/// installable look stay one design.
const HAIRLINE: &[(&str, &str)] = &[
    (
        "themes/hairline.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline.json"),
    ),
    (
        "themes/hairline-light.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline-light.json"),
    ),
    (
        "themes/hairline-slate.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline-slate.json"),
    ),
    (
        "themes/hairline-slate-light.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline-slate-light.json"),
    ),
    (
        "themes/hairline-stone.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline-stone.json"),
    ),
    (
        "themes/hairline-stone-light.json",
        include_str!("../../../../examples/looks/hairline/themes/hairline-stone-light.json"),
    ),
    (
        "agent-pane/theme.css",
        include_str!("../../../../examples/looks/hairline/agent-pane/theme.css"),
    ),
    ("markdown/theme.css", include_str!("../../../../examples/looks/hairline/markdown/theme.css")),
];

/// A look's theme file, kept beside its recipe in `recipes/looks/NAME/theme.json`.
macro_rules! look {
    ($name:literal) => {
        &[(
            concat!("themes/", $name, ".json"),
            include_str!(concat!("../recipes/looks/", $name, "/theme.json")),
        )]
    };
}

const CODEX_APP_DARK: &[(&str, &str)] = &[
    ("themes/codex-app-dark.json", include_str!("../recipes/apps/codex-app-dark/theme.json")),
    ("agent-pane/theme.css", include_str!("../recipes/apps/codex-app-dark/agent-pane.css")),
];

const VIOLET_APP: &[(&str, &str)] = &[
    ("themes/violet-app.json", include_str!("../recipes/apps/violet-app/theme.json")),
    ("agent-pane/theme.css", include_str!("../recipes/apps/violet-app/agent-pane.css")),
];

/// Every recipe, in the order a guide lists them.
/// Plush (examples/looks/plush): six theme files (three tints, each light and
/// dark) and its chat and Markdown stylesheets, taken from the look itself.
const PLUSH: &[(&str, &str)] = &[
    ("themes/plush.json", include_str!("../../../../examples/looks/plush/themes/plush.json")),
    (
        "themes/plush-dark.json",
        include_str!("../../../../examples/looks/plush/themes/plush-dark.json"),
    ),
    (
        "themes/plush-dusk.json",
        include_str!("../../../../examples/looks/plush/themes/plush-dusk.json"),
    ),
    (
        "themes/plush-dusk-dark.json",
        include_str!("../../../../examples/looks/plush/themes/plush-dusk-dark.json"),
    ),
    (
        "themes/plush-clay.json",
        include_str!("../../../../examples/looks/plush/themes/plush-clay.json"),
    ),
    (
        "themes/plush-clay-dark.json",
        include_str!("../../../../examples/looks/plush/themes/plush-clay-dark.json"),
    ),
    ("agent-pane/theme.css", include_str!("../../../../examples/looks/plush/agent-pane/theme.css")),
    ("markdown/theme.css", include_str!("../../../../examples/looks/plush/markdown/theme.css")),
];

pub const RECIPES: &[Recipe] = &[
    Recipe {
        name: "compact-sidebar",
        title: "A compact sidebar",
        group: Group::Layout,
        ask: "make the sidebar compact",
        profile: include_str!("../recipes/compact-sidebar.json"),
        includes: &[],
    },
    Recipe {
        name: "different-font",
        title: "A different font",
        group: Group::Type,
        ask: "use Geist in the chats and Menlo for code",
        profile: include_str!("../recipes/different-font.json"),
        includes: &[],
    },
    Recipe {
        name: "pr-widget",
        title: "Your pull requests in the sidebar",
        group: Group::Widgets,
        ask: "add a PR widget to the sidebar",
        profile: include_str!("../recipes/pr-widget.json"),
        includes: MY_PRS,
    },
    Recipe {
        name: "tiling-look",
        title: "A tiling window manager look",
        group: Group::Look,
        ask: "make it look like a tiling window manager",
        profile: include_str!("../recipes/tiling-look.json"),
        includes: &[],
    },
    Recipe {
        name: "pane-keys",
        title: "Move between panes with H J K L",
        group: Group::Keys,
        ask: "let me move between panes with ctrl-cmd-h, j, k and l",
        profile: include_str!("../recipes/pane-keys.json"),
        includes: &[],
    },
    Recipe {
        name: "clock-weather",
        title: "The time and the weather",
        group: Group::Widgets,
        ask: "show the time and the weather in the sidebar",
        profile: include_str!("../recipes/clock-weather.json"),
        includes: CLOCK_WEATHER,
    },
    Recipe {
        name: "vertical-tabs",
        title: "Vertical tabs",
        group: Group::Layout,
        ask: "put my tabs in a vertical list",
        profile: include_str!("../recipes/vertical-tabs.json"),
        includes: &[],
    },
    Recipe {
        name: "calm",
        title: "Calm: no motion",
        group: Group::Look,
        ask: "turn off the animations and make it calm",
        profile: include_str!("../recipes/calm.json"),
        includes: &[],
    },
    Recipe {
        name: "larger-text",
        title: "Larger text",
        group: Group::Type,
        ask: "make the text bigger everywhere",
        profile: include_str!("../recipes/larger-text.json"),
        includes: &[],
    },
    Recipe {
        name: "glass",
        title: "Glass",
        group: Group::Look,
        ask: "make the window see-through glass",
        profile: include_str!("../recipes/glass.json"),
        includes: &[],
    },
    Recipe {
        name: "plush",
        title: "Plush: soft raised surfaces",
        group: Group::Look,
        ask: "make it soft and plush, raised surfaces with no borders or glass",
        profile: include_str!("../recipes/plush.json"),
        includes: PLUSH,
    },
    Recipe {
        name: "hairline",
        title: "Hairline: flat and neutral",
        group: Group::Look,
        ask: "make cmux flat and neutral: gray surfaces, one-pixel lines, one corner radius, a focus ring and no glass",
        profile: include_str!("../recipes/hairline.json"),
        includes: HAIRLINE,
    },
    Recipe {
        name: "codex-app",
        title: "Like the Codex app",
        group: Group::Apps,
        ask: "make cmux look and work like the Codex app",
        profile: include_str!("../recipes/codex-app.json"),
        includes: CODEX_APP,
    },
    Recipe {
        name: "claude-code-app",
        title: "Like the Claude desktop app",
        group: Group::Apps,
        ask: "make cmux look and work like the Claude desktop app's Code tab",
        profile: include_str!("../recipes/claude-code-app.json"),
        includes: CLAUDE_CODE_APP,
    },
    Recipe {
        name: "claude-code-notification-levels",
        title: "Claude Code notification levels",
        group: Group::Apps,
        ask: "show permission banners and question badges, with task-complete alerts off",
        profile: include_str!(
            "../../../../examples/looks/claude-code/notification-levels/cmux-setup.json"
        ),
        includes: &[],
    },
    Recipe {
        name: "review-desk",
        title: "A review desk",
        group: Group::Layout,
        ask: "set up a review layout with the chat, the diff and a terminal side by side",
        profile: include_str!("../../../../examples/looks/review-desk/cmux-setup.json"),
        includes: REVIEW_DESK,
    },
    Recipe {
        name: "bottom-deck",
        title: "Every bar at the bottom",
        group: Group::Layout,
        ask: "move the tab bar, the address bars and the docks to the bottom",
        profile: include_str!("../../../../examples/looks/bottom-deck/cmux-setup.json"),
        includes: &[],
    },
    Recipe {
        name: "workspace-tabs",
        title: "Workspaces like browser tabs",
        group: Group::Layout,
        ask: "make my workspaces work like browser tabs",
        profile: include_str!("../../../../examples/looks/workspace-tabs/cmux-setup.json"),
        includes: &[],
    },
    Recipe {
        name: "leader",
        title: "A keyboard mode on Command-J",
        group: Group::Keys,
        ask: "give me leader keys to split, zoom, resize and move panes",
        profile: include_str!("../../../../examples/looks/leader/cmux-setup.json"),
        includes: LEADER,
    },
    Recipe {
        name: "ukiyo-e",
        title: "Ukiyo-e: the Great Wave",
        group: Group::Look,
        ask: "make it look like a Japanese woodblock print",
        profile: include_str!("../recipes/ukiyo-e.json"),
        includes: look!("ukiyo-e"),
    },
    Recipe {
        name: "hiroshige-dusk",
        title: "Hiroshige at dusk",
        group: Group::Look,
        ask: "make it look like a Hiroshige print at dusk",
        profile: include_str!("../recipes/hiroshige-dusk.json"),
        includes: look!("hiroshige-dusk"),
    },
    Recipe {
        name: "fuji-mist",
        title: "Fuji in mist",
        group: Group::Look,
        ask: "make it pale and misty like a Hokusai Fuji view",
        profile: include_str!("../recipes/fuji-mist.json"),
        includes: look!("fuji-mist"),
    },
    Recipe {
        name: "nio-guardian",
        title: "Nio guardian",
        group: Group::Look,
        ask: "make it dark and warm like a Kano school painting",
        profile: include_str!("../recipes/nio-guardian.json"),
        includes: look!("nio-guardian"),
    },
    Recipe {
        name: "sumi-ink",
        title: "Sumi ink",
        group: Group::Look,
        ask: "make it black ink on rice paper",
        profile: include_str!("../recipes/sumi-ink.json"),
        includes: look!("sumi-ink"),
    },
    Recipe {
        name: "water-lilies",
        title: "Water lilies",
        group: Group::Look,
        ask: "make it look like Monet's water lilies",
        profile: include_str!("../recipes/water-lilies.json"),
        includes: look!("water-lilies"),
    },
    Recipe {
        name: "starry-night",
        title: "Starry night",
        group: Group::Look,
        ask: "make it look like The Starry Night",
        profile: include_str!("../recipes/starry-night.json"),
        includes: look!("starry-night"),
    },
    Recipe {
        name: "gilded",
        title: "Gilded",
        group: Group::Look,
        ask: "make it gold like a Klimt painting",
        profile: include_str!("../recipes/gilded.json"),
        includes: look!("gilded"),
    },
    Recipe {
        name: "moonrise",
        title: "Moonrise",
        group: Group::Look,
        ask: "make it quiet and moonlit like Friedrich",
        profile: include_str!("../recipes/moonrise.json"),
        includes: look!("moonrise"),
    },
    Recipe {
        name: "engraving",
        title: "Engraving",
        group: Group::Look,
        ask: "make it black and white like a Dore engraving",
        profile: include_str!("../recipes/engraving.json"),
        includes: look!("engraving"),
    },
    Recipe {
        name: "aurora-night",
        title: "Aurora",
        group: Group::Look,
        ask: "put a moving aurora behind the window",
        profile: include_str!("../recipes/aurora-night.json"),
        includes: look!("aurora-night"),
    },
    Recipe {
        name: "still-water",
        title: "Still water",
        group: Group::Look,
        ask: "put moving ripples behind the window",
        profile: include_str!("../recipes/still-water.json"),
        includes: look!("still-water"),
    },
    Recipe {
        name: "deep-currents",
        title: "Deep currents",
        group: Group::Look,
        ask: "put moving ocean currents behind the window",
        profile: include_str!("../recipes/deep-currents.json"),
        includes: look!("deep-currents"),
    },
    Recipe {
        name: "dot-grid",
        title: "Dot grid",
        group: Group::Look,
        ask: "put a moving dot grid behind a black and white window",
        profile: include_str!("../recipes/dot-grid.json"),
        includes: look!("dot-grid"),
    },
    Recipe {
        name: "aero-sky",
        title: "Aero sky",
        group: Group::Look,
        ask: "put a glossy moving sky behind a light window",
        profile: include_str!("../recipes/aero-sky.json"),
        includes: look!("aero-sky"),
    },
    Recipe {
        name: "editorial-type",
        title: "Editorial type",
        group: Group::Type,
        ask: "use a serif for the chats and the pages",
        profile: include_str!("../recipes/editorial-type.json"),
        includes: &[],
    },
    Recipe {
        name: "readable-type",
        title: "Readable type",
        group: Group::Type,
        ask: "use the most readable font everywhere",
        profile: include_str!("../recipes/readable-type.json"),
        includes: &[],
    },
    Recipe {
        name: "codex-app-dark",
        title: "Like the Codex app, dark",
        group: Group::Apps,
        ask: "make cmux look like the Codex app, in dark",
        profile: include_str!("../recipes/codex-app-dark.json"),
        includes: CODEX_APP_DARK,
    },
    Recipe {
        name: "violet-app",
        title: "A violet coding app",
        group: Group::Apps,
        ask: "make cmux look like a violet desktop coding app",
        profile: include_str!("../recipes/violet-app.json"),
        includes: VIOLET_APP,
    },
];

/// The recipe called `name`.
pub fn find(name: &str) -> Option<&'static Recipe> {
    RECIPES.iter().find(|recipe| recipe.name == name)
}

impl Recipe {
    /// The whole profile, the files it takes from templates included.
    pub fn profile(&self) -> Result<Profile, String> {
        let mut profile: Profile = serde_json::from_str(self.profile).map_err(|error| {
            format!(
                "recipes/{}.json is not a cmux profile (line {}, column {}): {error}",
                self.name,
                error.line(),
                error.column()
            )
        })?;
        for (path, text) in self.includes {
            profile.files.insert((*path).to_owned(), (*text).to_owned());
        }
        Ok(profile)
    }

    /// The profile's one line about itself.
    pub fn summary(&self) -> String {
        self.profile().map(|profile| profile.description).unwrap_or_default()
    }

    /// The parts it changes, by name (`settings`, `views`, `keybindings`).
    pub fn parts(&self) -> Vec<&'static str> {
        let Ok(profile) = self.profile() else { return Vec::new() };
        let mut parts: Vec<Part> = profile.files.keys().map(|path| Part::of(path)).collect();
        if !profile.settings.is_empty() {
            parts.push(Part::Settings);
        }
        parts.sort();
        parts.dedup();
        parts.into_iter().map(Part::name).collect()
    }

    /// Every problem with this recipe, one line each; empty when it is good.
    pub fn problems(&self) -> Vec<String> {
        match self.profile() {
            Ok(profile) => {
                let mut found = problems(&profile);
                if profile.name != self.name {
                    found.push(format!(
                        "recipes/{}.json names itself {:?}; a recipe's name is its file name",
                        self.name, profile.name
                    ));
                }
                found
            }
            Err(error) => vec![error],
        }
    }
}

/// What is wrong with a recipe's profile, before the engine sees it: the
/// format, its name, a description to show, and every setting a key the
/// schema has, that an agent may set, with a value its row accepts. The
/// engine checks the same things and the files' contents again when the
/// recipe is previewed; this says it at build time, for every recipe.
pub fn problems(profile: &Profile) -> Vec<String> {
    let mut found = Vec::new();
    if profile.version != 1 {
        found.push(format!("format {} (recipes are format 1)", profile.version));
    }
    if !valid_name(&profile.name) {
        found.push(format!("{:?} is not a profile name", profile.name));
    }
    if profile.description.trim().is_empty() {
        found.push("has no description for the guide to show".to_owned());
    }
    if profile.settings.is_empty() && profile.files.is_empty() {
        found.push("changes nothing".to_owned());
    }
    let schema = Schema::embedded();
    for (key, value) in &profile.settings {
        let Some(row) = schema.row(key) else {
            found.push(format!("names the setting {key}, which the settings schema does not have"));
            continue;
        };
        if !row.agent_settable {
            found.push(format!("sets {key}, which only the person may change"));
        } else if cmux_config::schema::accepts(row, value, &Default::default()).is_err() {
            found.push(format!("sets {key} to a value that setting does not accept"));
        }
    }
    for path in profile.files.keys() {
        if matches!(Part::of(path), Part::Settings | Part::Automations) {
            found.push(format!("writes {path}, which a profile may not write"));
        }
    }
    found
}

/// The guide page (docs/cmux-next/customize-recipes.md), the same text in
/// the docs and in the app.
pub const GUIDE: &str = include_str!("../../../../docs/cmux-next/customize-recipes.md");

/// The folder the guide's commands name; [`guide`] puts the real one there.
pub const GUIDE_DIR: &str = "~/.local/state/cmux/customize/recipes";

/// The guide with its commands pointing at `dir`, where [`write_all`] put
/// the recipe files. Each command's path is shell-quoted, since the Run
/// button hands the line to a shell: a folder with a space or `;` in its
/// name stays one argument and never runs as a command of its own.
pub fn guide(dir: &Path) -> String {
    let mut page = GUIDE.to_owned();
    for recipe in RECIPES {
        let file = format!("{}.json", recipe.name);
        let path = dir.join(&file).display().to_string();
        page = page.replace(&format!("{GUIDE_DIR}/{file}"), &shell_quote(&path));
    }
    page.replace(GUIDE_DIR, &dir.display().to_string())
}

/// `text` as one POSIX shell word: single-quoted, each `'` written `'\''`.
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// What [`write_all`] wrote.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Written {
    pub dir: PathBuf,
    /// The guide page, for the Markdown viewer.
    pub guide: PathBuf,
    /// Each recipe's profile file, by name.
    pub files: BTreeMap<String, PathBuf>,
}

/// Writes every recipe as a profile file (`NAME.json`) and the guide
/// (`README.md`) into `dir`, so `cmux customize use FILE` and the guide's
/// Try it buttons have a real path. A file that already holds the same
/// text is left alone, so running it again writes nothing.
pub fn write_all(dir: &Path) -> io::Result<Written> {
    std::fs::create_dir_all(dir)?;
    let mut files = BTreeMap::new();
    for recipe in RECIPES {
        let profile = recipe.profile().map_err(io::Error::other)?;
        let mut text = serde_json::to_string_pretty(&profile).map_err(io::Error::other)?;
        text.push('\n');
        let path = dir.join(format!("{}.json", recipe.name));
        write_if_changed(&path, &text)?;
        files.insert(recipe.name.to_owned(), path);
    }
    let guide_path = dir.join("README.md");
    write_if_changed(&guide_path, &guide(dir))?;
    Ok(Written { dir: dir.to_path_buf(), guide: guide_path, files })
}

fn write_if_changed(path: &Path, text: &str) -> io::Result<()> {
    if std::fs::read(path).is_ok_and(|bytes| bytes == text.as_bytes()) {
        return Ok(());
    }
    cmux_config::fsio::write_atomic(path, text.as_bytes())
}
