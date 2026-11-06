//! `cmux-window-rules` over the JSON channel (ops `window_*`): the window
//! handlers' rules. The app reads its tab models, settings and the daemon's
//! answers, sends the facts and acts on the answer (the dialog, the toast,
//! the daemon command).

use cmux_window_rules::close::{self, ClosingTab, TerminalAnswer, Warnings};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"window_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Closing {
    #[serde(default)]
    tabs: Vec<ClosingTab>,
    #[serde(default, flatten)]
    warnings: Warnings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asked {
    #[serde(default)]
    agents: Vec<Option<String>>,
    #[serde(default)]
    answers: Vec<TerminalAnswer>,
    #[serde(default)]
    unanswered_asks: bool,
    #[serde(default, flatten)]
    warnings: Warnings,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    if operation.starts_with(b"window_tabs_") || operation.starts_with(b"window_panes_") {
        return respond_tabs(operation, request);
    }
    let answer = match operation {
        // Whether closing these tabs together earns the undo toast.
        b"window_close_toast" => {
            let request: Closing = read(request)?;
            serde_json::to_value(close::toast(&request.tabs)).map_err(|_| ERR_INVALID)?
        }
        // What a close reads before it knows its question; `reads` null: it never asks.
        b"window_close_reads" => {
            let request: Closing = read(request)?;
            json!({ "reads": close::reads(&request.tabs, request.warnings) })
        }
        // The close's question from the terminals' answers; `warning` null: close at once.
        b"window_close_warning" => {
            let request: Asked = read(request)?;
            json!({ "warning": close::warning(&request.agents, &request.answers, request.unanswered_asks, request.warnings) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

/// The tab and pane rules (`window_tabs_*`, `window_panes_*`; cmux-window-rules `tabs`).
fn respond_tabs(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    use cmux_window_rules::tabs::{self, panes};

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Number {
        number: i64,
        count: usize,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Agent {
        agent: Option<String>,
        session: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Tabs {
        tabs: Vec<tabs::DuplicateFacts>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Collapse {
        value: Option<bool>,
        current: bool,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Icon {
        user: bool,
        previous: Option<String>,
        icon: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Identifiers {
        workspaces: Vec<String>,
        refs: bool,
        workspace: Option<String>,
        pane: Option<String>,
        surface: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Text {
        text: String,
    }

    fn value<T: serde::Serialize>(answer: &T) -> Result<serde_json::Value, i32> {
        serde_json::to_value(answer).map_err(|_| ERR_INVALID)
    }
    let answer = match operation {
        // What a new tab opens next to the selected tab, and the kind New <Kind> Tab names.
        b"window_tabs_new_tab_kind" => {
            let facts: tabs::NewTabFacts = read(request)?;
            json!({ "kind": value(&tabs::new_tab_kind(&facts))?, "sameKind": value(&tabs::same_kind(&facts))? })
        }
        // What `openBrowser` does with its `url` and `engine` arguments.
        b"window_tabs_browser_open" => value(&tabs::browser_open(&read(request)?))?,
        // Whether a new browser tab opens behind, and whether it is an agent's.
        b"window_tabs_browser_placement" => value(&tabs::browser_placement(read(request)?))?,
        // Open in Chromium / Open in WebKit.
        b"window_tabs_reopen" => value(&tabs::reopen(&read(request)?))?,
        // Open Terminal as Chat's route; `harness` alone for a name.
        b"window_tabs_terminal_chat" => {
            let request: Agent = read(request)?;
            json!({
                "chat": value(&tabs::terminal_chat(request.agent.as_deref(), request.session.as_deref()))?,
                "harness": tabs::harness(request.agent.as_deref()),
            })
        }
        // Duplicate Tab per tab; `actions` null: refused (a page tab opens once).
        b"window_tabs_duplicate" => {
            let request: Tabs = read(request)?;
            json!({ "actions": value(&tabs::duplicate(&request.tabs))? })
        }
        b"window_tabs_by_number" => {
            let request: Number = read(request)?;
            json!({ "index": tabs::tab_by_number(request.number, request.count) })
        }
        b"window_tabs_move_to_split" => value(&tabs::move_to_split(&read(request)?))?,
        b"window_tabs_group_collapse" => {
            let request: Collapse = read(request)?;
            json!({ "collapsed": tabs::group_collapse(request.value, request.current) })
        }
        b"window_tabs_restart" => {
            json!({ "refusal": value(&tabs::restart_refusal(read(request)?))? })
        }
        b"window_tabs_icon_undo" => {
            let request: Icon = read(request)?;
            json!({ "undo": value(&tabs::icon_undo(request.user, request.previous.as_deref(), request.icon.as_deref()))? })
        }
        // Copy Workspace ID(s) (`workspaces`), or Copy IDs on a tab (`pane` and `surface`).
        b"window_tabs_identifiers" => {
            let request: Identifiers = read(request)?;
            let text = match (request.pane.as_deref(), request.surface.as_deref()) {
                (Some(pane), Some(surface)) => {
                    tabs::identifiers_text(request.workspace.as_deref(), pane, surface)
                }
                _ => tabs::workspace_id_text(&request.workspaces, request.refs),
            };
            json!({ "text": text })
        }
        b"window_panes_by_number" => {
            let request: Number = read(request)?;
            json!({ "index": tabs::pane_by_number(request.number, request.count) })
        }
        b"window_panes_split" => value(&panes::split(&read(request)?))?,
        b"window_panes_auto_direction" => value(&panes::auto_direction(read(request)?))?,
        b"window_panes_tab_bar" => value(&panes::tab_bar(read(request)?))?,
        b"window_panes_terminal_bindings" => json!({ "bindings": panes::TERMINAL_BINDINGS }),
        b"window_panes_clear_failure" => {
            let request: Text = read(request)?;
            json!({ "kind": panes::clear_failure_kind(&request.text) })
        }
        b"window_panes_shell_quote" => {
            let request: Text = read(request)?;
            json!({ "text": panes::shell_quoted(&request.text) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
