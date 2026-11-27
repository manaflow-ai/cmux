//! Which registry action a Ghostty keybind runs (`new_split:right`,
//! `goto_split:left`, `equalize_splits`, ...), so a keybind in the person's
//! Ghostty config takes the same path as the shortcut, menu, palette and CLI.
//! `None`: the app has no action for it; Ghostty then treats the key as
//! unbound. Was `TerminalHostActionRoute.swift`.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// A split's side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitDirection {
    Right,
    Down,
    Left,
    Up,
}

/// Which split `goto_split` focuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitNavigation {
    Previous,
    Next,
    Up,
    Down,
    Left,
    Right,
}

/// Which tab `goto_tab` selects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum TabTarget {
    Previous,
    Next,
    Last,
    Index { number: i64 },
}

/// Which tabs `close_tab` closes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloseTabMode {
    This,
    Others,
    Right,
}

/// A Ghostty keybind action the terminal host hands the app
/// (`TerminalHostAction`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum Action {
    NewWindow,
    NewTab,
    CloseTab {
        mode: CloseTabMode,
    },
    CloseWindow,
    CloseAllWindows,
    Quit,
    NewSplit {
        direction: SplitDirection,
    },
    GotoSplit {
        target: SplitNavigation,
    },
    ResizeSplit {
        direction: SplitDirection,
        #[serde(default)]
        amount: i64,
    },
    EqualizeSplits,
    ToggleSplitZoom,
    GotoTab {
        target: TabTarget,
    },
    MoveTab {
        amount: i64,
    },
    ToggleFullscreen,
    ToggleMaximize,
    ToggleCommandPalette,
    ToggleInspector,
    PromptTitle,
    CheckForUpdates,
    Undo,
    Redo,
    Find,
    ToggleVisibility,
    ToggleTabOverview,
    PromptWindowTitle,
    SetWindowTitle {
        title: String,
    },
    PresentTerminal,
    GotoWindow {
        next: bool,
    },
    MoveTabToNewWindow,
}

/// The registry action a keybind runs.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Route {
    /// The registry action id.
    pub id: String,
    /// The action's arguments (`ActionValue`s: a string or an int here).
    pub arguments: Map<String, Value>,
    /// The run targets the terminal's tab (false: the active workspace).
    pub targets_terminal: bool,
}

impl Route {
    fn to(id: &str) -> Self {
        Self { id: id.to_owned(), arguments: Map::new(), targets_terminal: true }
    }

    fn with(mut self, key: &str, value: Value) -> Self {
        self.arguments.insert(key.to_owned(), value);
        self
    }

    fn on_workspace(mut self) -> Self {
        self.targets_terminal = false;
        self
    }
}

/// The route of `action`, or `None` when the app has no action for it.
pub fn route(action: &Action) -> Option<Route> {
    Some(match action {
        Action::NewSplit { direction } => Route::to(split(*direction)),
        Action::GotoSplit { target } => Route::to(focus(*target)),
        // The registry resizes by its own step; Ghostty's amount is in points
        // of its own split tree and has no daemon equivalent.
        Action::ResizeSplit { direction, .. } => Route::to(resize(*direction)),
        Action::EqualizeSplits => Route::to("equalizeSplits"),
        Action::ToggleSplitZoom => Route::to("toggleSplitZoom"),
        Action::NewTab => Route::to("newSurface"),
        Action::CloseTab { mode } => Route::to(close_tab(*mode)),
        Action::GotoTab { target } => goto_tab(*target),
        Action::MoveTab { amount } => match amount {
            0 => return None,
            amount if *amount < 0 => Route::to("moveSurfaceLeft"),
            _ => Route::to("moveSurfaceRight"),
        },
        Action::NewWindow => Route::to("newWindow"),
        Action::CloseWindow => Route::to("closeWindow"),
        Action::ToggleFullscreen => Route::to("toggleFullScreen"),
        Action::ToggleCommandPalette => Route::to("commandPalette"),
        Action::PromptTitle => Route::to("renameTab"),
        Action::Find => Route::to("find"),
        Action::Quit => Route::to("quit"),
        Action::CheckForUpdates => Route::to("palette.checkForUpdates"),
        // Ghostty's undo restores the last closed tab, split or window.
        Action::Undo => Route::to("history.reopen"),
        Action::ToggleVisibility => Route::to("showHideAllWindows"),
        Action::ToggleTabOverview => Route::to("tab.search"),
        // cmux's window title is the active workspace's name.
        Action::PromptWindowTitle => Route::to("renameWorkspace").on_workspace(),
        Action::SetWindowTitle { title } => {
            Route::to("renameWorkspace").with("name", Value::String(title.clone())).on_workspace()
        }
        Action::PresentTerminal => Route::to("tab.focus"),
        Action::CloseAllWindows => Route::to("closeAllWindows"),
        Action::ToggleMaximize => Route::to("zoomWindow"),
        Action::GotoWindow { next } => {
            Route::to(if *next { "selectNextWindow" } else { "selectPreviousWindow" })
        }
        Action::MoveTabToNewWindow => Route::to("tab.moveToNewWindow"),
        // No cmux equivalent: Ghostty's terminal inspector; redo of a reopen (decision C1).
        Action::ToggleInspector | Action::Redo => return None,
    })
}

fn split(direction: SplitDirection) -> &'static str {
    match direction {
        SplitDirection::Right => "splitRight",
        SplitDirection::Down => "splitDown",
        SplitDirection::Left => "splitLeft",
        SplitDirection::Up => "splitUp",
    }
}

fn focus(target: SplitNavigation) -> &'static str {
    match target {
        SplitNavigation::Left => "focusLeft",
        SplitNavigation::Right => "focusRight",
        SplitNavigation::Up => "focusUp",
        SplitNavigation::Down => "focusDown",
        SplitNavigation::Previous => "focusPreviousPane",
        SplitNavigation::Next => "focusNextPane",
    }
}

fn resize(direction: SplitDirection) -> &'static str {
    match direction {
        SplitDirection::Left => "resizePaneLeft",
        SplitDirection::Right => "resizePaneRight",
        SplitDirection::Up => "resizePaneUp",
        SplitDirection::Down => "resizePaneDown",
    }
}

fn close_tab(mode: CloseTabMode) -> &'static str {
    match mode {
        CloseTabMode::This => "closeTab",
        CloseTabMode::Others => "closeOtherTabsInPane",
        CloseTabMode::Right => "closeTabsToRight",
    }
}

fn goto_tab(target: TabTarget) -> Route {
    match target {
        TabTarget::Previous => Route::to("prevSurface"),
        TabTarget::Next => Route::to("nextSurface"),
        // selectSurfaceByNumber treats 9 as "last".
        TabTarget::Last => Route::to("selectSurfaceByNumber").with("index", Value::from(9)),
        TabTarget::Index { number } => {
            Route::to("selectSurfaceByNumber").with("index", Value::from(number.max(1)))
        }
    }
}

#[cfg(test)]
#[path = "keybind_route_tests.rs"]
mod tests;
