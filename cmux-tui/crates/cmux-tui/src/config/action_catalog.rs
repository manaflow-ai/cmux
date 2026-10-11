//! The action catalog: one ActionDefinition (config key, English and Japanese label) per Action, and the Action helpers built on it.

use super::*;

/// One executable TUI action and the metadata shared by key configuration,
/// context menus, shortcut help, and future command surfaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionDefinition {
    pub action: Action,
    pub config_key: &'static str,
    pub label_en: &'static str,
    pub label_ja: &'static str,
}

macro_rules! action_definition {
    ($action:expr, $config_key:literal, $label_en:literal, $label_ja:literal) => {
        ActionDefinition {
            action: $action,
            config_key: $config_key,
            label_en: $label_en,
            label_ja: $label_ja,
        }
    };
}

macro_rules! define_named_action_definitions {
    ($( $name:ident => ($action:expr, $config_key:literal, $label_en:literal, $label_ja:literal); )+) => {
        $(
            static $name: ActionDefinition =
                action_definition!($action, $config_key, $label_en, $label_ja);
        )+
    };
}

define_named_action_definitions! {
    SEND_PREFIX_DEFINITION => (Action::SendPrefix, "send-prefix", "Send prefix", "プレフィックスを送信");
    NEW_TAB_DEFINITION => (Action::NewTab, "new-tab", "New tab", "新しいタブ");
    NEW_BROWSER_TAB_DEFINITION => (Action::NewBrowserTab, "new-browser-tab", "New browser tab", "新しいブラウザタブ");
    NEW_PANE_SMART_DEFINITION => (Action::NewPaneSmart, "new-pane-smart", "New pane", "新しいペイン");
    NEXT_TAB_DEFINITION => (Action::NextTab, "next-tab", "Next tab", "次のタブ");
    PREV_TAB_DEFINITION => (Action::PrevTab, "prev-tab", "Previous tab", "前のタブ");
    SPLIT_RIGHT_DEFINITION => (Action::SplitRight, "split-right", "Split right", "右に分割");
    SPLIT_DOWN_DEFINITION => (Action::SplitDown, "split-down", "Split down", "下に分割");
    CLOSE_TAB_DEFINITION => (Action::CloseTab, "close-tab", "Close tab", "タブを閉じる");
    CLOSE_PANE_DEFINITION => (Action::ClosePane, "close-pane", "Close pane", "ペインを閉じる");
    RENAME_TAB_DEFINITION => (Action::RenameTab, "rename-tab", "Rename tab", "タブ名を変更");
    RENAME_SCREEN_DEFINITION => (Action::RenameScreen, "rename-screen", "Rename screen", "スクリーン名を変更");
    RENAME_WORKSPACE_DEFINITION => (Action::RenameWorkspace, "rename-workspace", "Rename workspace", "ワークスペース名を変更");
    CLOSE_SCREEN_DEFINITION => (Action::CloseScreen, "close-screen", "Close screen", "スクリーンを閉じる");
    PREV_SCREEN_DEFINITION => (Action::PrevScreen, "prev-screen", "Previous screen", "前のスクリーン");
    NEXT_SCREEN_DEFINITION => (Action::NextScreen, "next-screen", "Next screen", "次のスクリーン");
    NEW_SCREEN_DEFINITION => (Action::NewScreen, "new-screen", "New screen", "新しいスクリーン");
    PREV_WORKSPACE_DEFINITION => (Action::PrevWorkspace, "prev-workspace", "Previous workspace", "前のワークスペース");
    NEXT_WORKSPACE_DEFINITION => (Action::NextWorkspace, "next-workspace", "Next workspace", "次のワークスペース");
    NEW_WORKSPACE_DEFINITION => (Action::NewWorkspace, "new-workspace", "New workspace", "新しいワークスペース");
    CLOSE_WORKSPACE_DEFINITION => (Action::CloseWorkspace, "close-workspace", "Close workspace", "ワークスペースを閉じる");
    TOGGLE_SIDEBAR_DEFINITION => (Action::ToggleSidebar, "toggle-sidebar", "Show or hide sidebar", "サイドバーの表示を切り替え");
    TOGGLE_SIDEBAR_COMPACT_DEFINITION => (Action::ToggleSidebarCompact, "toggle-sidebar-compact", "Compact or expand sidebar", "サイドバーの幅を切り替え");
    TOGGLE_SIDEBAR_VIEW_DEFINITION => (Action::ToggleSidebarView, "toggle-sidebar-view", "Switch sidebar view", "サイドバー表示を切り替え");
    FOCUS_SIDEBAR_DEFINITION => (Action::FocusSidebar, "focus-sidebar", "Focus sidebar", "サイドバーにフォーカス");
    PROVIDER_MENU_DEFINITION => (Action::ProviderMenu, "provider-menu", "Machine provider menu", "マシンプロバイダーメニュー");
    NEW_PANE_RIGHT_DEFINITION => (Action::NewPaneRight, "new-pane-right", "New column to the right", "右に新しい列");
    UNDO_LAYOUT_DEFINITION => (Action::UndoLayout, "undo-layout", "Undo layout", "レイアウトを元に戻す");
    FOCUS_LEFT_DEFINITION => (Action::FocusLeft, "focus-left", "Focus left", "左へフォーカス");
    FOCUS_RIGHT_DEFINITION => (Action::FocusRight, "focus-right", "Focus right", "右へフォーカス");
    FOCUS_UP_DEFINITION => (Action::FocusUp, "focus-up", "Focus up", "上へフォーカス");
    FOCUS_DOWN_DEFINITION => (Action::FocusDown, "focus-down", "Focus down", "下へフォーカス");
    FOCUS_NEXT_PANE_DEFINITION => (Action::FocusNextPane, "focus-next-pane", "Focus next pane", "次のペインにフォーカス");
    SWAP_PANE_PREV_DEFINITION => (Action::SwapPanePrev, "swap-pane-prev", "Move pane backward", "ペインを前へ移動");
    SWAP_PANE_NEXT_DEFINITION => (Action::SwapPaneNext, "swap-pane-next", "Move pane forward", "ペインを後ろへ移動");
    ZOOM_PANE_DEFINITION => (Action::ZoomPane, "zoom-pane", "Maximize or restore pane", "ペインを最大化または復元");
    RESIZE_GROW_DEFINITION => (Action::ResizeGrow, "resize-grow", "Grow pane", "ペインを拡大");
    RESIZE_SHRINK_DEFINITION => (Action::ResizeShrink, "resize-shrink", "Shrink pane", "ペインを縮小");
    SCROLL_UP_DEFINITION => (Action::ScrollUp, "scroll-up", "Scroll up", "上にスクロール");
    SCROLL_DOWN_DEFINITION => (Action::ScrollDown, "scroll-down", "Scroll down", "下にスクロール");
    CLEAR_HISTORY_DEFINITION => (Action::ClearHistory, "clear-history", "Clear terminal history", "ターミナル履歴を消去");
    BROWSER_BACK_DEFINITION => (Action::BrowserBack, "browser-back", "Browser back", "ブラウザで戻る");
    BROWSER_FORWARD_DEFINITION => (Action::BrowserForward, "browser-forward", "Browser forward", "ブラウザで進む");
    BROWSER_RELOAD_DEFINITION => (Action::BrowserReload, "browser-reload", "Reload browser", "ブラウザを再読み込み");
    BROWSER_EDIT_URL_DEFINITION => (Action::BrowserEditUrl, "browser-edit-url", "Edit browser URL", "ブラウザ URL を編集");
    SHOW_SHORTCUTS_DEFINITION => (Action::ShowShortcuts, "show-shortcuts", "Keyboard shortcuts", "キーボードショートカット");
    DETACH_DEFINITION => (Action::Detach, "detach", "Detach", "デタッチ");
}

pub(super) static SELECT_TAB_DEFINITIONS: [ActionDefinition; 10] = [
    action_definition!(
        Action::select_tab(0).unwrap(),
        "select-tab-0",
        "Select tab 0",
        "タブ 0 を選択"
    ),
    action_definition!(
        Action::select_tab(1).unwrap(),
        "select-tab-1",
        "Select tab 1",
        "タブ 1 を選択"
    ),
    action_definition!(
        Action::select_tab(2).unwrap(),
        "select-tab-2",
        "Select tab 2",
        "タブ 2 を選択"
    ),
    action_definition!(
        Action::select_tab(3).unwrap(),
        "select-tab-3",
        "Select tab 3",
        "タブ 3 を選択"
    ),
    action_definition!(
        Action::select_tab(4).unwrap(),
        "select-tab-4",
        "Select tab 4",
        "タブ 4 を選択"
    ),
    action_definition!(
        Action::select_tab(5).unwrap(),
        "select-tab-5",
        "Select tab 5",
        "タブ 5 を選択"
    ),
    action_definition!(
        Action::select_tab(6).unwrap(),
        "select-tab-6",
        "Select tab 6",
        "タブ 6 を選択"
    ),
    action_definition!(
        Action::select_tab(7).unwrap(),
        "select-tab-7",
        "Select tab 7",
        "タブ 7 を選択"
    ),
    action_definition!(
        Action::select_tab(8).unwrap(),
        "select-tab-8",
        "Select tab 8",
        "タブ 8 を選択"
    ),
    action_definition!(
        Action::select_tab(9).unwrap(),
        "select-tab-9",
        "Select tab 9",
        "タブ 9 を選択"
    ),
];

pub(super) static SELECT_SCREEN_DEFINITIONS: [ActionDefinition; 10] = [
    action_definition!(
        Action::select_screen(0).unwrap(),
        "select-screen-0",
        "Select screen 0",
        "スクリーン 0 を選択"
    ),
    action_definition!(
        Action::select_screen(1).unwrap(),
        "select-screen-1",
        "Select screen 1",
        "スクリーン 1 を選択"
    ),
    action_definition!(
        Action::select_screen(2).unwrap(),
        "select-screen-2",
        "Select screen 2",
        "スクリーン 2 を選択"
    ),
    action_definition!(
        Action::select_screen(3).unwrap(),
        "select-screen-3",
        "Select screen 3",
        "スクリーン 3 を選択"
    ),
    action_definition!(
        Action::select_screen(4).unwrap(),
        "select-screen-4",
        "Select screen 4",
        "スクリーン 4 を選択"
    ),
    action_definition!(
        Action::select_screen(5).unwrap(),
        "select-screen-5",
        "Select screen 5",
        "スクリーン 5 を選択"
    ),
    action_definition!(
        Action::select_screen(6).unwrap(),
        "select-screen-6",
        "Select screen 6",
        "スクリーン 6 を選択"
    ),
    action_definition!(
        Action::select_screen(7).unwrap(),
        "select-screen-7",
        "Select screen 7",
        "スクリーン 7 を選択"
    ),
    action_definition!(
        Action::select_screen(8).unwrap(),
        "select-screen-8",
        "Select screen 8",
        "スクリーン 8 を選択"
    ),
    action_definition!(
        Action::select_screen(9).unwrap(),
        "select-screen-9",
        "Select screen 9",
        "スクリーン 9 を選択"
    ),
];

/// The canonical action catalog. Presentation surfaces derive their labels
/// and ordering from these named definitions instead of positional offsets.
pub fn action_definitions() -> &'static [&'static ActionDefinition] {
    static DEFINITIONS: [&ActionDefinition; 67] = [
        &SEND_PREFIX_DEFINITION,
        &NEW_TAB_DEFINITION,
        &NEW_BROWSER_TAB_DEFINITION,
        &NEW_PANE_SMART_DEFINITION,
        &NEXT_TAB_DEFINITION,
        &PREV_TAB_DEFINITION,
        &SELECT_TAB_DEFINITIONS[0],
        &SELECT_TAB_DEFINITIONS[1],
        &SELECT_TAB_DEFINITIONS[2],
        &SELECT_TAB_DEFINITIONS[3],
        &SELECT_TAB_DEFINITIONS[4],
        &SELECT_TAB_DEFINITIONS[5],
        &SELECT_TAB_DEFINITIONS[6],
        &SELECT_TAB_DEFINITIONS[7],
        &SELECT_TAB_DEFINITIONS[8],
        &SELECT_TAB_DEFINITIONS[9],
        &SPLIT_RIGHT_DEFINITION,
        &SPLIT_DOWN_DEFINITION,
        &CLOSE_TAB_DEFINITION,
        &CLOSE_PANE_DEFINITION,
        &RENAME_TAB_DEFINITION,
        &RENAME_SCREEN_DEFINITION,
        &RENAME_WORKSPACE_DEFINITION,
        &CLOSE_SCREEN_DEFINITION,
        &PREV_SCREEN_DEFINITION,
        &NEXT_SCREEN_DEFINITION,
        &SELECT_SCREEN_DEFINITIONS[0],
        &SELECT_SCREEN_DEFINITIONS[1],
        &SELECT_SCREEN_DEFINITIONS[2],
        &SELECT_SCREEN_DEFINITIONS[3],
        &SELECT_SCREEN_DEFINITIONS[4],
        &SELECT_SCREEN_DEFINITIONS[5],
        &SELECT_SCREEN_DEFINITIONS[6],
        &SELECT_SCREEN_DEFINITIONS[7],
        &SELECT_SCREEN_DEFINITIONS[8],
        &SELECT_SCREEN_DEFINITIONS[9],
        &NEW_SCREEN_DEFINITION,
        &PREV_WORKSPACE_DEFINITION,
        &NEXT_WORKSPACE_DEFINITION,
        &NEW_WORKSPACE_DEFINITION,
        &CLOSE_WORKSPACE_DEFINITION,
        &TOGGLE_SIDEBAR_DEFINITION,
        &TOGGLE_SIDEBAR_COMPACT_DEFINITION,
        &TOGGLE_SIDEBAR_VIEW_DEFINITION,
        &FOCUS_SIDEBAR_DEFINITION,
        &PROVIDER_MENU_DEFINITION,
        &NEW_PANE_RIGHT_DEFINITION,
        &UNDO_LAYOUT_DEFINITION,
        &FOCUS_LEFT_DEFINITION,
        &FOCUS_RIGHT_DEFINITION,
        &FOCUS_UP_DEFINITION,
        &FOCUS_DOWN_DEFINITION,
        &FOCUS_NEXT_PANE_DEFINITION,
        &SWAP_PANE_PREV_DEFINITION,
        &SWAP_PANE_NEXT_DEFINITION,
        &ZOOM_PANE_DEFINITION,
        &RESIZE_GROW_DEFINITION,
        &RESIZE_SHRINK_DEFINITION,
        &SCROLL_UP_DEFINITION,
        &SCROLL_DOWN_DEFINITION,
        &CLEAR_HISTORY_DEFINITION,
        &BROWSER_BACK_DEFINITION,
        &BROWSER_FORWARD_DEFINITION,
        &BROWSER_RELOAD_DEFINITION,
        &BROWSER_EDIT_URL_DEFINITION,
        &SHOW_SHORTCUTS_DEFINITION,
        &DETACH_DEFINITION,
    ];
    &DEFINITIONS
}

/// Fallback definition for `Action::UserCommand`. It is intentionally not in
/// `action_definitions()`: user commands are named by the user's config, and
/// presentation surfaces look the display name up there. The `action` field
/// pins index 0 only because a definition must carry one concrete action.
pub(super) static USER_COMMAND_FALLBACK_DEFINITION: ActionDefinition = action_definition!(
    Action::UserCommand(UserCommandIndex(0)),
    "user-command",
    "User command",
    "ユーザーコマンド"
);

impl Action {
    pub fn definition(self) -> &'static ActionDefinition {
        match self {
            Action::SendPrefix => &SEND_PREFIX_DEFINITION,
            Action::NewTab => &NEW_TAB_DEFINITION,
            Action::NewBrowserTab => &NEW_BROWSER_TAB_DEFINITION,
            Action::NewPaneSmart => &NEW_PANE_SMART_DEFINITION,
            Action::NextTab => &NEXT_TAB_DEFINITION,
            Action::PrevTab => &PREV_TAB_DEFINITION,
            Action::SelectTab(index) => &SELECT_TAB_DEFINITIONS[index.get() as usize],
            Action::SplitRight => &SPLIT_RIGHT_DEFINITION,
            Action::SplitDown => &SPLIT_DOWN_DEFINITION,
            Action::CloseTab => &CLOSE_TAB_DEFINITION,
            Action::ClosePane => &CLOSE_PANE_DEFINITION,
            Action::RenameTab => &RENAME_TAB_DEFINITION,
            Action::RenameScreen => &RENAME_SCREEN_DEFINITION,
            Action::RenameWorkspace => &RENAME_WORKSPACE_DEFINITION,
            Action::CloseScreen => &CLOSE_SCREEN_DEFINITION,
            Action::PrevScreen => &PREV_SCREEN_DEFINITION,
            Action::NextScreen => &NEXT_SCREEN_DEFINITION,
            Action::SelectScreen(index) => &SELECT_SCREEN_DEFINITIONS[index.get() as usize],
            Action::NewScreen => &NEW_SCREEN_DEFINITION,
            Action::PrevWorkspace => &PREV_WORKSPACE_DEFINITION,
            Action::NextWorkspace => &NEXT_WORKSPACE_DEFINITION,
            Action::NewWorkspace => &NEW_WORKSPACE_DEFINITION,
            Action::CloseWorkspace => &CLOSE_WORKSPACE_DEFINITION,
            Action::ToggleSidebar => &TOGGLE_SIDEBAR_DEFINITION,
            Action::ToggleSidebarCompact => &TOGGLE_SIDEBAR_COMPACT_DEFINITION,
            Action::ToggleSidebarView => &TOGGLE_SIDEBAR_VIEW_DEFINITION,
            Action::FocusSidebar => &FOCUS_SIDEBAR_DEFINITION,
            Action::ProviderMenu => &PROVIDER_MENU_DEFINITION,
            Action::NewPaneRight => &NEW_PANE_RIGHT_DEFINITION,
            Action::UndoLayout => &UNDO_LAYOUT_DEFINITION,
            Action::FocusLeft => &FOCUS_LEFT_DEFINITION,
            Action::FocusRight => &FOCUS_RIGHT_DEFINITION,
            Action::FocusUp => &FOCUS_UP_DEFINITION,
            Action::FocusDown => &FOCUS_DOWN_DEFINITION,
            Action::FocusNextPane => &FOCUS_NEXT_PANE_DEFINITION,
            Action::SwapPanePrev => &SWAP_PANE_PREV_DEFINITION,
            Action::SwapPaneNext => &SWAP_PANE_NEXT_DEFINITION,
            Action::ZoomPane => &ZOOM_PANE_DEFINITION,
            Action::ResizeGrow => &RESIZE_GROW_DEFINITION,
            Action::ResizeShrink => &RESIZE_SHRINK_DEFINITION,
            Action::ScrollUp => &SCROLL_UP_DEFINITION,
            Action::ScrollDown => &SCROLL_DOWN_DEFINITION,
            Action::ClearHistory => &CLEAR_HISTORY_DEFINITION,
            Action::BrowserBack => &BROWSER_BACK_DEFINITION,
            Action::BrowserForward => &BROWSER_FORWARD_DEFINITION,
            Action::BrowserReload => &BROWSER_RELOAD_DEFINITION,
            Action::BrowserEditUrl => &BROWSER_EDIT_URL_DEFINITION,
            Action::ShowShortcuts => &SHOW_SHORTCUTS_DEFINITION,
            Action::Detach => &DETACH_DEFINITION,
            // One shared fallback: presentation surfaces resolve the
            // configured display name through the command list instead of
            // this static definition, which is deliberately outside the
            // action catalog.
            Action::UserCommand(_) => &USER_COMMAND_FALLBACK_DEFINITION,
        }
    }

    pub const fn select_screen(number: u8) -> Option<Self> {
        match ActionIndex::new(number) {
            Some(index) => Some(Self::SelectScreen(index)),
            None => None,
        }
    }

    pub const fn user_command(number: usize) -> Option<Self> {
        match UserCommandIndex::new(number) {
            Some(index) => Some(Self::UserCommand(index)),
            None => None,
        }
    }

    pub fn user_command_index(&self) -> Option<usize> {
        match self {
            Action::UserCommand(index) => Some(index.get()),
            _ => None,
        }
    }

    pub const fn select_tab(number: u8) -> Option<Self> {
        match ActionIndex::new(number) {
            Some(index) => Some(Self::SelectTab(index)),
            None => None,
        }
    }

    pub fn screen_index(&self) -> Option<usize> {
        match self {
            Action::SelectScreen(number) => Some(number.get() as usize),
            _ => None,
        }
    }

    pub fn tab_index(&self) -> Option<usize> {
        match self {
            Action::SelectTab(number) => Some(number.get() as usize),
            _ => None,
        }
    }
}
