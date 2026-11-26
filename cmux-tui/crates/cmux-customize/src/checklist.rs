//! The customizations checklist (Leo 2026-11-22: "a customizations
//! checklist. actually, this needs to be SOMEWHERE as a default. not just for
//! me."): the steps that walk a person through making cmux theirs, and how far
//! they are, as data. `cmux customize checklist` answers it; the Settings page
//! draws it (webviews `CustomizeProgressCard.tsx`) and decides nothing.
//!
//! A step is done when the person really did it, read from what cmux already
//! keeps: a setting that differs from its default, a binding in
//! keybindings.json, a customization in the library that is on, or a
//! connection the caller reports (`--has github`: the app knows its accounts,
//! this crate does not). A step nothing can tell about is checked off by
//! hand, and the hand-checked ids are kept in the settings file
//! (`customize.checklist.done`). Any step can be checked off by hand, so a
//! connection the caller did not report never leaves a step stuck.
//!
//! The checklist is on for everyone (`customize.checklist.enabled`, default
//! true); Dismiss turns that off, and the Settings switch turns it back on.

use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::Value;

/// The setting that shows the checklist; absent means on.
pub const ENABLED_KEY: &str = "customize.checklist.enabled";
/// The setting that keeps the ids of the steps checked off by hand.
pub const DONE_KEY: &str = "customize.checklist.done";
/// The value an absent [`ENABLED_KEY`] means.
pub const ENABLED_DEFAULT: bool = true;

/// Words with their string catalog key (the Settings page's
/// CmuxNextSettingsWindow catalog); `text` is the English.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Words {
    pub key: &'static str,
    pub text: &'static str,
}

/// How a step's done state is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Watch {
    /// Done when any of these settings differs from its default. A key that
    /// ends in `.` stands for every row under it (`notifications.`).
    Settings(&'static [&'static str]),
    /// Done when keybindings.json has a binding.
    Keybindings,
    /// Done when a customization in the library is on (an ask, a profile, a
    /// look from the examples).
    Library,
    /// Done when the caller reports this connection (`--has NAME`).
    Connected(&'static str),
}

/// One step of the checklist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    /// Stable: the hand-checked list keeps it.
    pub id: &'static str,
    pub title: Words,
    /// One short line: what doing it changes.
    pub detail: Words,
    /// Where the step is done: a Settings route (`/settings/CATEGORY`, with
    /// `?focus=card.ID` for one card), the page's own link syntax.
    pub route: &'static str,
    pub watch: Watch,
}

const fn words(key: &'static str, text: &'static str) -> Words {
    Words { key, text }
}

/// The steps, in the order they show: how it looks first, then how it
/// behaves, then what it connects to.
pub const STEPS: &[Step] = &[
    Step {
        id: "theme",
        title: words("settingsPage.customizeProgress.step.theme", "Pick a theme"),
        detail: words(
            "settingsPage.customizeProgress.step.theme.detail",
            "Colors for the terminal and the window.",
        ),
        route: "/settings/appearance?focus=card.themeStudio",
        watch: Watch::Settings(&[
            "appearance.theme",
            "appearance.appTheme",
            "appearance.themeFile",
            "appearance.accent",
        ]),
    },
    Step {
        id: "look",
        title: words("settingsPage.customizeProgress.step.look", "Try a look"),
        detail: words(
            "settingsPage.customizeProgress.step.look.detail",
            "A whole look at once, kept in your Customization Library.",
        ),
        route: "/settings/appearance?focus=card.customizeLibrary",
        watch: Watch::Library,
    },
    Step {
        id: "background",
        title: words("settingsPage.customizeProgress.step.background", "Choose a background"),
        detail: words(
            "settingsPage.customizeProgress.step.background.detail",
            "A picture or color behind your work.",
        ),
        route: "/settings/appearance?focus=card.backdrops",
        watch: Watch::Settings(&[
            "appearance.background",
            "appearance.backgroundLight",
            "appearance.backgroundDark",
        ]),
    },
    Step {
        id: "textSize",
        title: words("settingsPage.customizeProgress.step.textSize", "Set text size and density"),
        detail: words(
            "settingsPage.customizeProgress.step.textSize.detail",
            "How big and how roomy the sidebar, tabs and chat are.",
        ),
        route: "/settings/general?focus=card.textSize",
        watch: Watch::Settings(&[
            "appearance.metrics.chromeFontSize",
            "appearance.density",
            "app.uiScale",
        ]),
    },
    Step {
        id: "sidebar",
        title: words("settingsPage.customizeProgress.step.sidebar", "Arrange the sidebar"),
        detail: words(
            "settingsPage.customizeProgress.step.sidebar.detail",
            "Its side, look and what each row shows.",
        ),
        route: "/settings/sidebar",
        watch: Watch::Settings(&["sidebar.", "appearance.metrics.sidebarWidth"]),
    },
    Step {
        id: "chat",
        title: words("settingsPage.customizeProgress.step.chat", "Tune the chat"),
        detail: words(
            "settingsPage.customizeProgress.step.chat.detail",
            "Chat text, font and width.",
        ),
        route: "/settings/chat",
        watch: Watch::Settings(&["agentPane.display.", "agentPane.composerRing"]),
    },
    Step {
        id: "newTab",
        title: words("settingsPage.customizeProgress.step.newTab", "Choose your New Tab page"),
        detail: words(
            "settingsPage.customizeProgress.step.newTab.detail",
            "What a new tab opens on.",
        ),
        route: "/settings/newTab",
        watch: Watch::Settings(&[
            "tabs.newTabTemplate",
            "tabs.nativeNewTabPage",
            "tabs.newTabApp",
            "tabs.newTabNowPlaying",
        ]),
    },
    Step {
        id: "terminalFont",
        title: words("settingsPage.customizeProgress.step.terminalFont", "Pick a terminal font"),
        detail: words(
            "settingsPage.customizeProgress.step.terminalFont.detail",
            "The font and size of your terminals.",
        ),
        route: "/settings/terminal",
        watch: Watch::Settings(&["terminal.fontFamily", "terminal.fontSize"]),
    },
    Step {
        id: "shortcut",
        title: words("settingsPage.customizeProgress.step.shortcut", "Set a keyboard shortcut"),
        detail: words(
            "settingsPage.customizeProgress.step.shortcut.detail",
            "Put any action on the keys you want.",
        ),
        route: "/settings/keyboard",
        watch: Watch::Keybindings,
    },
    Step {
        id: "notifications",
        title: words("settingsPage.customizeProgress.step.notifications", "Set up notifications"),
        detail: words(
            "settingsPage.customizeProgress.step.notifications.detail",
            "When cmux tells you an agent is done or needs you, and how.",
        ),
        route: "/settings/notifications",
        watch: Watch::Settings(&["notifications."]),
    },
    Step {
        id: "agents",
        title: words("settingsPage.customizeProgress.step.agents", "Choose your agents and models"),
        detail: words(
            "settingsPage.customizeProgress.step.agents.detail",
            "Sign in to the models your chats use.",
        ),
        route: "/settings/models",
        watch: Watch::Connected("models"),
    },
    Step {
        id: "agentDefaults",
        title: words("settingsPage.customizeProgress.step.agentDefaults", "Set agent defaults"),
        detail: words(
            "settingsPage.customizeProgress.step.agentDefaults.detail",
            "What a new chat may do without asking, and its guidance.",
        ),
        route: "/settings/agents",
        watch: Watch::Settings(&["agents.defaultPermissionMode", "agents.guidance."]),
    },
    Step {
        id: "mcp",
        title: words("settingsPage.customizeProgress.step.mcp", "Connect an MCP server"),
        detail: words(
            "settingsPage.customizeProgress.step.mcp.detail",
            "Give your agents a service's tools.",
        ),
        route: "/settings/mcpServers",
        watch: Watch::Connected("mcp"),
    },
    Step {
        id: "github",
        title: words("settingsPage.customizeProgress.step.github", "Connect GitHub"),
        detail: words(
            "settingsPage.customizeProgress.step.github.detail",
            "Pull requests and repositories in cmux.",
        ),
        route: "/settings/accounts",
        watch: Watch::Connected("github"),
    },
    Step {
        id: "phone",
        title: words("settingsPage.customizeProgress.step.phone", "Pair your phone"),
        detail: words(
            "settingsPage.customizeProgress.step.phone.detail",
            "Follow your chats away from the Mac.",
        ),
        route: "/settings/mobile",
        watch: Watch::Connected("phone"),
    },
];

/// The connections a caller may report: [`Watch::Connected`]'s names.
pub fn facts() -> impl Iterator<Item = &'static str> {
    STEPS.iter().filter_map(|step| match step.watch {
        Watch::Connected(name) => Some(name),
        _ => None,
    })
}

/// What the checklist reads, gathered by the caller.
#[derive(Clone, Copy)]
pub struct Inputs<'a> {
    /// The settings file's object (absent keys mean their defaults).
    pub settings: &'a Value,
    /// The defaults: the schema's value for a key, `None` when it has no
    /// row or its default is derived at run time.
    pub default_of: &'a dyn Fn(&str) -> Option<Value>,
    /// The schema's keys under a prefix (`notifications.`).
    pub keys_under: &'a dyn Fn(&str) -> Vec<String>,
    /// Bindings in keybindings.json.
    pub keybindings: usize,
    /// Library entries that are on.
    pub library_on: usize,
    /// The connections the caller reports (`--has`).
    pub connected: &'a BTreeSet<String>,
}

/// How a step came to be done.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DoneBy {
    /// A setting, binding or library entry says so.
    Setting,
    /// The caller reported the connection.
    Connected,
    /// Checked off by hand.
    Checked,
}

/// One step as the page draws it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StepState {
    pub id: &'static str,
    pub title: Words,
    pub detail: Words,
    pub route: &'static str,
    pub done: bool,
    /// Why it is done; `None` when it is not.
    pub done_by: Option<DoneBy>,
}

/// The checklist and the person's progress through it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Checklist {
    /// `customize.checklist.enabled`: false once dismissed.
    pub enabled: bool,
    pub done: usize,
    pub total: usize,
    /// The first step not done, the one to suggest next; `None` when all are.
    pub next: Option<&'static str>,
    pub steps: Vec<StepState>,
}

/// Reads the checklist from what cmux keeps.
pub fn checklist(inputs: &Inputs<'_>) -> Checklist {
    let checked = checked(inputs.settings);
    let steps: Vec<StepState> = STEPS
        .iter()
        .map(|step| {
            let done_by = derived(step, inputs)
                .or_else(|| checked.contains(step.id).then_some(DoneBy::Checked));
            StepState {
                id: step.id,
                title: step.title,
                detail: step.detail,
                route: step.route,
                done: done_by.is_some(),
                done_by,
            }
        })
        .collect();
    let enabled =
        setting(inputs.settings, ENABLED_KEY).and_then(Value::as_bool).unwrap_or(ENABLED_DEFAULT);
    Checklist {
        enabled,
        done: steps.iter().filter(|step| step.done).count(),
        total: steps.len(),
        next: steps.iter().find(|step| !step.done).map(|step| step.id),
        steps,
    }
}

/// The ids checked off by hand that name a step (an id of a step since
/// removed is ignored, never an error).
pub fn checked(settings: &Value) -> BTreeSet<&'static str> {
    let Some(Value::Array(ids)) = setting(settings, DONE_KEY) else { return BTreeSet::new() };
    let ids: BTreeSet<&str> = ids.iter().filter_map(Value::as_str).collect();
    STEPS.iter().map(|step| step.id).filter(|id| ids.contains(id)).collect()
}

/// The step's done state from what cmux keeps, else `None`.
fn derived(step: &Step, inputs: &Inputs<'_>) -> Option<DoneBy> {
    let done = match step.watch {
        Watch::Settings(keys) => keys.iter().any(|key| {
            if key.ends_with('.') {
                (inputs.keys_under)(key).iter().any(|key| changed(inputs, key))
            } else {
                changed(inputs, key)
            }
        }),
        Watch::Keybindings => inputs.keybindings > 0,
        Watch::Library => inputs.library_on > 0,
        Watch::Connected(name) => {
            return inputs.connected.contains(name).then_some(DoneBy::Connected);
        }
    };
    done.then_some(DoneBy::Setting)
}

/// The key is set to something other than its default.
fn changed(inputs: &Inputs<'_>, key: &str) -> bool {
    match setting(inputs.settings, key) {
        None | Some(Value::Null) => false,
        Some(value) => (inputs.default_of)(key).as_ref() != Some(value),
    }
}

/// A dotted key's value in a settings object, written nested
/// (`{"appearance": {"theme": …}}`), flat (`{"appearance.theme": …}`) or
/// anything between, as cmux.json allows.
pub fn setting<'a>(settings: &'a Value, key: &str) -> Option<&'a Value> {
    let object = settings.as_object()?;
    if let Some(value) = object.get(key) {
        return Some(value);
    }
    key.match_indices('.').find_map(|(at, _)| {
        let (head, rest) = key.split_at_checked(at)?;
        setting(object.get(head)?, rest.strip_prefix('.')?)
    })
}

/// The checklist of the person's own cmux: their settings file, their
/// keybindings.json and their library, with the connections the caller
/// reports. A settings or bindings file that is missing or unreadable counts
/// as empty (nothing done there yet); a library that cannot be read is an
/// error, as everywhere in `cmux customize`.
pub fn read(
    customize: &crate::Customize,
    connected: &BTreeSet<String>,
) -> Result<Checklist, crate::Error> {
    let settings_file = &customize.roots().settings_file;
    let settings = std::fs::read_to_string(settings_file)
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok())
        .unwrap_or(Value::Null);
    let keybindings = std::fs::read_to_string(cmux_config::keybindings_path(settings_file))
        .map(|text| cmux_config::keybindings::parse(&text).entries.len())
        .unwrap_or(0);
    let library_on = customize.library()?.entries.iter().filter(|entry| entry.on).count();
    Ok(checklist(&Inputs {
        settings: &settings,
        default_of: &schema_reads::default_of,
        keys_under: &schema_reads::keys_under,
        keybindings,
        library_on,
        connected,
    }))
}

/// The schema's defaults and prefixes, for [`Inputs`].
pub mod schema_reads {
    use serde_json::Value;

    /// The schema's default for `key`.
    pub fn default_of(key: &str) -> Option<Value> {
        cmux_config::Schema::embedded().row(key).and_then(|row| row.default.clone())
    }

    /// The schema's keys under `prefix`.
    pub fn keys_under(prefix: &str) -> Vec<String> {
        cmux_config::Schema::embedded()
            .rows_in(None)
            .filter(|row| row.key.starts_with(prefix))
            .map(|row| row.key.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn run(
        settings: Value,
        keybindings: usize,
        library_on: usize,
        connected: &[&str],
    ) -> Checklist {
        let connected: BTreeSet<String> = connected.iter().map(|name| (*name).to_owned()).collect();
        checklist(&Inputs {
            settings: &settings,
            default_of: &schema_reads::default_of,
            keys_under: &schema_reads::keys_under,
            keybindings,
            library_on,
            connected: &connected,
        })
    }

    fn done(list: &Checklist) -> Vec<&'static str> {
        list.steps.iter().filter(|step| step.done).map(|step| step.id).collect()
    }

    #[test]
    fn a_fresh_install_has_every_step_left_and_is_on() {
        let list = run(json!({}), 0, 0, &[]);
        assert!(list.enabled);
        assert_eq!(list.done, 0);
        assert_eq!(list.total, STEPS.len());
        assert_eq!(list.next, Some("theme"));
        assert!(list.total >= 10, "at least the ten steps of the ask");
    }

    #[test]
    fn a_setting_that_differs_from_its_default_marks_its_step() {
        let list =
            run(json!({"appearance": {"theme": "Nord"}, "terminal.fontSize": 15}), 0, 0, &[]);
        assert_eq!(done(&list), ["theme", "terminalFont"]);
        assert_eq!(list.steps[0].done_by, Some(DoneBy::Setting));
        assert_eq!(list.next, Some("look"));
    }

    #[test]
    fn a_setting_written_back_to_its_default_does_not_count() {
        // appearance.density defaults to "cozy"; sidebar.side to "left".
        let list =
            run(json!({"appearance.density": "cozy", "sidebar": {"side": "left"}}), 0, 0, &[]);
        assert_eq!(list.done, 0);
        let list = run(json!({"sidebar": {"side": "right"}}), 0, 0, &[]);
        assert_eq!(done(&list), ["sidebar"]);
    }

    #[test]
    fn a_prefix_step_counts_any_row_under_it() {
        let list = run(json!({"notifications": {"sounds": {"volume": 0.5}}}), 0, 0, &[]);
        assert_eq!(done(&list), ["notifications"]);
    }

    #[test]
    fn bindings_the_library_and_connections_mark_their_steps() {
        let list = run(json!({}), 2, 1, &["github", "mcp"]);
        assert_eq!(done(&list), ["look", "shortcut", "mcp", "github"]);
        let github = list.steps.iter().find(|step| step.id == "github").unwrap();
        assert_eq!(github.done_by, Some(DoneBy::Connected));
    }

    #[test]
    fn any_step_can_be_checked_off_by_hand_and_unknown_ids_are_ignored() {
        let list = run(
            json!({"customize": {"checklist": {"done": ["phone", "gone-step", 3]}}}),
            0,
            0,
            &[],
        );
        assert_eq!(done(&list), ["phone"]);
        assert_eq!(list.steps.last().unwrap().done_by, Some(DoneBy::Checked));
        // A derived step wins over the hand check: it says why it is done.
        let list = run(json!({"customize.checklist.done": ["github"]}), 0, 0, &["github"]);
        let github = list.steps.iter().find(|step| step.id == "github").unwrap();
        assert_eq!(github.done_by, Some(DoneBy::Connected));
    }

    #[test]
    fn dismissing_turns_it_off_and_everything_done_has_no_next() {
        let all: Vec<&str> = STEPS.iter().map(|step| step.id).collect();
        let list = run(json!({"customize.checklist": {"enabled": false, "done": all}}), 0, 0, &[]);
        assert!(!list.enabled);
        assert_eq!((list.done, list.total, list.next), (list.total, STEPS.len(), None));
    }

    #[test]
    fn setting_reads_nested_flat_and_mixed_paths() {
        let settings = json!({"a": {"b.c": 1, "d": {"e": 2}}, "f.g": 3});
        assert_eq!(setting(&settings, "a.b.c"), Some(&json!(1)));
        assert_eq!(setting(&settings, "a.d.e"), Some(&json!(2)));
        assert_eq!(setting(&settings, "f.g"), Some(&json!(3)));
        assert_eq!(setting(&settings, "a.x"), None);
    }

    #[test]
    fn ids_are_unique_and_every_watched_key_is_a_settings_row() {
        let ids: BTreeSet<&str> = STEPS.iter().map(|step| step.id).collect();
        assert_eq!(ids.len(), STEPS.len());
        let schema = cmux_config::Schema::embedded();
        for step in STEPS {
            assert!(step.title.key.starts_with("settingsPage.customizeProgress.step."));
            assert!(step.route.starts_with("/settings/"), "{}", step.id);
            if let Watch::Settings(keys) = step.watch {
                for key in keys {
                    let known = if key.ends_with('.') {
                        !schema_reads::keys_under(key).is_empty()
                    } else {
                        schema.row(key).is_some()
                    };
                    assert!(known, "step {} watches {key}, which no settings row has", step.id);
                }
            }
        }
        assert_eq!(facts().collect::<Vec<_>>(), ["models", "mcp", "github", "phone"]);
    }

    #[test]
    fn the_checklist_keys_match_the_schema() {
        let schema = cmux_config::Schema::embedded();
        let enabled = schema.row(ENABLED_KEY).expect("customize.checklist.enabled row");
        assert_eq!(enabled.default, Some(json!(ENABLED_DEFAULT)));
        let done = schema.row(DONE_KEY).expect("customize.checklist.done row");
        assert_eq!(done.default, Some(json!([])));
    }
}
