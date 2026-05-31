const messages = {
  en: {
    "browser.systemDefault": "System default browser",
    "browser.system": "System",
    "browser.defaultProfile": "Default",
    "browser.profileLabel": "{browser} / {profile}",
    "menu.file": "File",
    "menu.newWorkspace": "New Workspace",
    "menu.renameWorkspace": "Rename Workspace",
    "menu.workspaceBlueprints": "Workspace Blueprints",
    "menu.newTerminal": "New Terminal",
    "menu.runCommand": "Run Command in Active Terminal",
    "menu.reopenClosedPane": "Reopen Closed Pane",
    "menu.copyTerminalSelection": "Copy Terminal Selection",
    "menu.pasteClipboard": "Paste Clipboard to Terminal",
    "menu.restartTerminal": "Restart Active Terminal",
    "menu.closeActivePane": "Close Active Pane",
    "menu.openBrowser": "Open Browser",
    "menu.settings": "Settings",
    "menu.colorSettings": "Color Settings",
    "menu.backgroundSettings": "Background Settings",
    "menu.settingsProfiles": "Settings Profiles",
    "menu.commandSnippets": "Command Snippets",
    "menu.edit": "Edit",
    "menu.findTerminal": "Find in Active Terminal",
    "menu.findNext": "Find Next in Terminal",
    "menu.findPrevious": "Find Previous in Terminal",
    "menu.view": "View",
    "menu.commandPalette": "Command Palette",
    "menu.toggleSidebar": "Toggle Sidebar",
    "menu.nextPane": "Next Pane",
    "menu.previousPane": "Previous Pane",
    "menu.lastPane": "Last Active Pane",
    "menu.nextWorkspace": "Next Workspace",
    "menu.previousWorkspace": "Previous Workspace",
    "menu.lastWorkspace": "Last Workspace",
    "menu.tunePerformance": "Tune Performance Now",
    "menu.performanceSettings": "Performance Settings",
    "dialog.chooseBackground": "Choose background image",
    "dialog.chooseWorkspaceFolder": "Choose workspace folder",
    "dialog.images": "Images",
    "panel.browser": "Browser",
    "panel.terminal": "Terminal"
  }
};

function currentLocale() {
  return String(process.env.CMUX_WINDOWS_LOCALE || Intl.DateTimeFormat().resolvedOptions().locale || "en").split("-")[0] || "en";
}

function t(key) {
  const locale = currentLocale();
  return messages[locale]?.[key] || messages.en[key] || key;
}

function formatMessage(key, values = {}) {
  return t(key).replace(/\{([a-z0-9_]+)\}/gi, (_, name) => values[name] ?? "");
}

module.exports = { formatMessage, t };
