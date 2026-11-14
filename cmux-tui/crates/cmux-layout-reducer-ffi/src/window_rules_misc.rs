//! The smaller window handlers' ops (`window_notifications_*`,
//! `window_history_*`, `window_remote_*`, `window_browser_*`,
//! `window_files_*`, `window_appearance_*`): their tables and refusals.

use cmux_window_rules::{appearance, browser, files, history, notifications, remote};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(answer: T) -> Result<Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Unread {
    verb: notifications::Verb,
    #[serde(default)]
    unread: Vec<notifications::UnreadTab>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Prompts {
    #[serde(default)]
    prompts: Vec<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mute {
    #[serde(default)]
    muted: Vec<String>,
    key: String,
    legacy: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Banners {
    desktop: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Undo {
    confirmation_required: bool,
    revision: Option<u64>,
    closes_panes: Option<usize>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Machines {
    target: Option<String>,
    machines: Vec<remote::Machine>,
    active: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct TerminalHere {
    direction: Option<String>,
    same_machine: bool,
    cwd: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Fit {
    fixed: Option<String>,
    asked: Option<String>,
    current: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct MenuFits {
    fit: bool,
    fit_width: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Device {
    device: Option<String>,
    orientation: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Markdown {
    path: Option<String>,
    local: bool,
    shows_chat: bool,
    allows_view_change: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct DiffFailed {
    local: bool,
    allows_view_change: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct EditorActions {
    actions: Vec<files::EditorAction>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct OpenWith {
    app: Option<String>,
    by_person: bool,
    selection: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct RingStyle {
    style: String,
    was_enabled: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Keymap {
    preset: String,
    changed: Vec<String>,
}

/// The domains whose ops this module answers.
const DOMAINS: [&[u8]; 6] = [
    b"window_notifications_",
    b"window_history_",
    b"window_remote_",
    b"window_browser_",
    b"window_files_",
    b"window_appearance_",
];

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    DOMAINS.iter().any(|domain| operation.starts_with(domain))
}

/// One op of the smaller window handlers.
pub(crate) fn respond_misc(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Which unread tabs a notification verb acknowledges and opens.
        b"window_notifications_plan" => {
            let request: Unread = read(request)?;
            value(notifications::plan(request.verb, &request.unread))?
        }
        // The prompted tab whose agent was prompted last.
        b"window_notifications_last_prompt" => {
            match notifications::last_prompt(&read::<Prompts>(request)?.prompts) {
                Ok(index) => json!({ "index": index }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        b"window_notifications_toggle_mute" => {
            let request: Mute = read(request)?;
            json!({ "muted": notifications::toggle_mute(&request.muted, &request.key, request.legacy.as_deref()) })
        }
        b"window_notifications_toggle_banners" => {
            json!({ "desktop": notifications::toggle_banners(&read::<Banners>(request)?.desktop) })
        }
        b"window_history_actions" => value(history::actions())?,
        b"window_history_undo_reply" => {
            let request: Undo = read(request)?;
            value(history::undo_reply(
                request.confirmation_required,
                request.revision,
                request.closes_panes,
            ))?
        }
        // The SSH machine a remote action acts on.
        b"window_remote_machine" => {
            let request: Machines = read(request)?;
            match remote::machine(
                request.target.as_deref(),
                &request.machines,
                request.active.as_deref(),
            ) {
                Ok(index) => json!({ "index": index }),
                Err(refusal) => value(refusal)?,
            }
        }
        b"window_remote_terminal_here" => {
            let request: TerminalHere = read(request)?;
            value(remote::terminal_here(
                request.direction.as_deref(),
                request.same_machine,
                request.cwd,
            ))?
        }
        b"window_remote_connect_step" => value(remote::connect_step(read(request)?))?,
        b"window_browser_fit_actions" => json!({ "actions": browser::fit_actions() }),
        b"window_browser_fit" => {
            let request: Fit = read(request)?;
            value(browser::fit(
                request.fixed.as_deref(),
                request.asked.as_deref(),
                request.current.as_deref(),
            ))?
        }
        b"window_browser_menu_fits" => {
            let request: MenuFits = read(request)?;
            json!({ "fits": browser::menu_fits(request.fit, request.fit_width) })
        }
        b"window_browser_device" => {
            let request: Device = read(request)?;
            value(browser::device(request.device.as_deref(), request.orientation.as_deref()))?
        }
        b"window_browser_pip_page" => value(browser::pip_page(read(request)?))?,
        b"window_browser_pip_row" => value(browser::pip_row(read(request)?))?,
        b"window_files_open_markdown" => {
            let request: Markdown = read(request)?;
            value(files::open_markdown(
                request.path.as_deref(),
                request.local,
                request.shows_chat,
                request.allows_view_change,
            ))?
        }
        b"window_files_open_diff" => value(files::open_diff(read(request)?))?,
        b"window_files_diff_failed" => {
            let request: DiffFailed = read(request)?;
            json!({ "failed": files::diff_failed(request.local, request.allows_view_change) })
        }
        b"window_files_editor_bindings" => {
            json!({ "bindings": files::editor_bindings(&read::<EditorActions>(request)?.actions) })
        }
        b"window_files_vscode" => value(files::vscode_open(read(request)?))?,
        b"window_files_open_with" => {
            let request: OpenWith = read(request)?;
            value(files::open_with(request.app.as_deref(), request.by_person, request.selection))?
        }
        b"window_appearance_verb" => value(appearance::appearance(read(request)?))?,
        b"window_appearance_focus_ring_style" => {
            let request: RingStyle = read(request)?;
            json!({ "edits": appearance::focus_ring_style(&request.style, request.was_enabled) })
        }
        b"window_appearance_keymap_toast" => {
            let request: Keymap = read(request)?;
            value(appearance::keymap_toast(&request.preset, &request.changed))?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
