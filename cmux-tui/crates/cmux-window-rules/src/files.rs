//! The file and viewer open rules: where Open Markdown File and Open Diff
//! Viewer open, when the cmux picker may show, which code editor actions this
//! handler binds, the folder VS Code (Inline) serves, and the file explorer's
//! Open With.

use serde::{Deserialize, Serialize};

/// Why an open did nothing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "refusal")]
pub enum Refusal {
    /// A file of another machine is named by an absolute path.
    PathNotAbsolute { path: String },
    /// The picker shows only for a run that may change the view.
    PickerNeedsFocus,
}

/// Where Open Markdown File opens a named file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FilePlace {
    /// A file of the pane's machine, which is not this Mac.
    Remote,
    /// Beside the chat the pane shows (the right-split router).
    BesideChat,
    /// A tab of the pane.
    Pane,
}

/// What Open Markdown File does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum MarkdownOpen {
    Open {
        place: FilePlace,
        path: String,
    },
    /// No path: the cmux picker in file mode.
    Picker,
    Refused(Refusal),
}

fn picker<T>(allows_view_change: bool, picker: T, refused: impl FnOnce(Refusal) -> T) -> T {
    if allows_view_change { picker } else { refused(Refusal::PickerNeedsFocus) }
}

/// Open Markdown File: a named file opens on the pane's machine (another
/// machine's by an absolute path), beside a chat the pane shows, else in the
/// pane; no path asks the picker.
pub fn open_markdown(
    path: Option<&str>,
    local: bool,
    shows_chat: bool,
    allows_view_change: bool,
) -> MarkdownOpen {
    let Some(path) = path.filter(|path| !path.is_empty()) else {
        return picker(allows_view_change, MarkdownOpen::Picker, MarkdownOpen::Refused);
    };
    let place = if !local {
        if !path.starts_with('/') || path.contains('\0') {
            return MarkdownOpen::Refused(Refusal::PathNotAbsolute { path: path.to_owned() });
        }
        FilePlace::Remote
    } else if shows_chat {
        FilePlace::BesideChat
    } else {
        FilePlace::Pane
    };
    MarkdownOpen::Open { place, path: path.to_owned() }
}

/// What Open Diff Viewer asks for.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DiffAsk {
    /// A chat's own patch (a turn's changes no git source holds).
    pub patch: bool,
    /// The `path` argument.
    pub path: Option<String>,
    /// The pane's folder.
    pub pane_folder: Option<String>,
    pub allows_view_change: bool,
    /// An open beside its caller (a chat): it does not take focus.
    pub beside_caller: bool,
}

/// What Open Diff Viewer does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum DiffOpen {
    /// The chat's patch in a tab; `folder` is the patch's repository folder.
    ChatPatch {
        folder: Option<String>,
        focus: bool,
    },
    /// The repository at `folder`.
    Folder {
        folder: String,
        focus: bool,
    },
    /// No folder: the cmux picker in folder mode.
    Picker,
    Refused(Refusal),
}

/// Open Diff Viewer: a chat's patch, else the named (or the pane's) folder's
/// repository, else the picker. An open beside its caller keeps focus there.
pub fn open_diff(ask: DiffAsk) -> DiffOpen {
    let given = ask.path.filter(|path| !path.is_empty());
    let folder = given.or(ask.pane_folder);
    let focus = ask.allows_view_change && !ask.beside_caller;
    if ask.patch {
        return DiffOpen::ChatPatch { folder, focus };
    }
    match folder {
        Some(folder) => DiffOpen::Folder { folder, focus },
        None => picker(ask.allows_view_change, DiffOpen::Picker, DiffOpen::Refused),
    }
}

/// What a folder's diff that did not open does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiffFailed {
    /// Says why (this Mac's picker cannot choose another machine's folder).
    Reason,
    /// The picker asks for a repository.
    Picker,
    PickerNeedsFocus,
}

/// A diff of the pane's folder did not open (no repository, an offline machine).
pub fn diff_failed(local: bool, allows_view_change: bool) -> DiffFailed {
    if !local {
        DiffFailed::Reason
    } else if allows_view_change {
        DiffFailed::Picker
    } else {
        DiffFailed::PickerNeedsFocus
    }
}

/// The shared find actions, bound by the terminal and browser handlers, which
/// reach a code editor page through them.
pub const SHARED_FIND_ACTIONS: [&str; 5] =
    ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"];

/// One code editor page action as the page declares it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorAction {
    pub action: String,
    /// It runs the editor's own command (`editor.action`), named by its `text` argument.
    pub runs_editor_command: bool,
}

/// An editor action the file page handler binds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorBinding {
    pub action: String,
    /// The run is refused without a `text` argument.
    pub needs_text: bool,
}

/// The editor actions this handler binds: every one but the shared find actions.
pub fn editor_bindings(actions: &[EditorAction]) -> Vec<EditorBinding> {
    actions
        .iter()
        .filter(|entry| !SHARED_FIND_ACTIONS.contains(&entry.action.as_str()))
        .map(|entry| EditorBinding {
            action: entry.action.clone(),
            needs_text: entry.runs_editor_command,
        })
        .collect()
}

/// What Open Folder in VS Code (Inline) reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct VSCodeFacts {
    /// The pane is on this Mac.
    pub local: bool,
    /// VS Code is installed.
    pub installed: bool,
    /// The person's own run (it asks in a folder panel).
    pub by_person: bool,
    /// The targeted (else selected) tab is a terminal.
    pub terminal: bool,
    /// That terminal's folder, as it reports it.
    pub cwd: Option<String>,
}

/// What Open Folder in VS Code (Inline) does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum VSCodeOpen {
    /// The folder panel, starting at `folder` (none: the home folder).
    Panel {
        folder: Option<String>,
    },
    /// Serves `folder` at once.
    Serve {
        folder: String,
    },
    ThisMacOnly,
    NotInstalled,
    NoFolder,
}

/// A person picks the folder in a panel that starts at the terminal's folder;
/// automation serves that folder directly.
pub fn vscode_open(facts: VSCodeFacts) -> VSCodeOpen {
    if !facts.local {
        return VSCodeOpen::ThisMacOnly;
    }
    if !facts.installed {
        return VSCodeOpen::NotInstalled;
    }
    let folder = facts
        .cwd
        .as_deref()
        .map(str::trim)
        .filter(|cwd| facts.terminal && cwd.starts_with('/'))
        .map(str::to_owned);
    match (facts.by_person, folder) {
        (true, folder) => VSCodeOpen::Panel { folder },
        (false, Some(folder)) => VSCodeOpen::Serve { folder },
        (false, None) => VSCodeOpen::NoFolder,
    }
}

/// What the file explorer's Open With does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum OpenWith {
    /// Opens the selection with the named app.
    App {
        app: String,
    },
    /// No app (the menu's Other…): the person picks one for the selected file.
    Choose,
    /// A script cannot answer the app panel.
    NoSuchApp,
    NoSelection,
}

/// The file explorer's Open With.
pub fn open_with(app: Option<&str>, by_person: bool, selection: bool) -> OpenWith {
    match app.filter(|app| !app.is_empty()) {
        Some(app) => OpenWith::App { app: app.to_owned() },
        None if !by_person => OpenWith::NoSuchApp,
        None if !selection => OpenWith::NoSelection,
        None => OpenWith::Choose,
    }
}

#[cfg(test)]
#[path = "files_tests.rs"]
mod tests;
