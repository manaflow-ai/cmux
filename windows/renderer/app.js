import {
  accentOptions,
  backgroundPresets,
  defaultSettings,
  settingsCategories,
  settingsPresets,
  terminalAppearanceKeys,
  terminalColorDefaults,
  terminalCursorStyles,
  terminalFontOptions,
  terminalProfiles,
  toolbarModeOptions,
  themeOptions
} from "./config.js";

const backgroundPresetMap = new Map(backgroundPresets.map((preset) => [preset.value, preset]));
const terminalFontStacks = new Map(terminalFontOptions.map(([id, , stack]) => [id, stack]));
const TerminalConstructor = window.Terminal;
const FitAddonConstructor = window.FitAddon?.FitAddon;
const WebLinksAddonConstructor = window.WebLinksAddon?.WebLinksAddon;
const terminalOutputChunkSize = 32768;
const terminalOutputPerformanceChunkSize = 16384;
const paneLayoutStorageKey = "cmux.paneLayout";
const recentFoldersStorageKey = "cmux.recentWorkspaceFolders";
const recentFoldersLimit = 8;
const paneLayoutScale = 1000;
const paneLayoutMaxWeight = 10000;
const settingsSaveDelay = 140;
const closedPanelLimit = 12;

const workspaceStarters = [
  {
    id: "terminalBrowser",
    label: "Terminal + Browser",
    body: "One shell beside the configured browser home page.",
    panels: ["terminal", "browser"]
  },
  {
    id: "twoTerminals",
    label: "Two Terminals",
    body: "Side-by-side shells for server and commands.",
    panels: ["terminal", "terminal"]
  },
  {
    id: "devTrio",
    label: "Dev Trio",
    body: "Two shells plus a browser pane for local app work.",
    panels: ["terminal", "terminal", "browser"]
  }
];

const initialSettings = loadSettings();

const state = {
  data: null,
  sidebarCollapsed: false,
  inspectorMode: null,
  terminals: new Map(),
  browserViews: new Map(),
  paneCache: new Map(),
  paneLayouts: loadPaneLayouts(),
  recentFolders: loadRecentFolders(),
  closedPanels: [],
  workspaceRows: new Map(),
  surfaceTabButtons: new Map(),
  newTabButton: null,
  paletteOpen: false,
  paletteIndex: 0,
  dragPanelId: null,
  zoomedPanelId: null,
  contextMenu: null,
  activeDialog: null,
  resizing: null,
  sidebarResizing: null,
  inspectorResizing: null,
  renderFrame: 0,
  paneLayoutFrame: 0,
  scheduledRenderPrevious: null,
  pendingRender: false,
  pendingRenderPrevious: null,
  settingsSaveTimer: 0,
  settingsSavePending: false,
  terminalAppearanceFrame: 0,
  renderStats: {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0
  },
  appliedSettingsSignature: "",
  settings: initialSettings,
  settingsCategory: "quick",
  settingsQuery: "",
  terminalFontSize: initialSettings.terminalFontSize
};

window.addEventListener("error", (event) => {
  console.error(`renderer error: ${event.message} at ${event.filename}:${event.lineno}:${event.colno}`);
});

window.addEventListener("unhandledrejection", (event) => {
  console.error(`renderer rejection: ${event.reason?.stack || event.reason}`);
});

const elements = {
  shell: document.getElementById("shell"),
  sidebar: document.getElementById("sidebar"),
  workspaceList: document.getElementById("workspaceList"),
  workspaceHeading: document.getElementById("workspaceHeading"),
  workspaceSubheading: document.getElementById("workspaceSubheading"),
  surfaceTabs: document.getElementById("surfaceTabs"),
  paneGrid: document.getElementById("paneGrid"),
  inspector: document.getElementById("inspector"),
  inspectorTitle: document.getElementById("inspectorTitle"),
  inspectorSubtitle: document.getElementById("inspectorSubtitle"),
  inspectorBody: document.getElementById("inspectorBody"),
  statusSummary: document.getElementById("statusSummary"),
  statusPipe: document.getElementById("statusPipe"),
  statusPty: document.getElementById("statusPty"),
  palette: document.getElementById("palette"),
  paletteInput: document.getElementById("paletteInput"),
  paletteList: document.getElementById("paletteList"),
  toastRegion: document.getElementById("toastRegion"),
  maximizeWindowButton: document.getElementById("maximizeWindowButton")
};

elements.paneLayoutStyle = document.createElement("style");
elements.paneLayoutStyle.id = "paneLayoutStyle";
document.head.appendChild(elements.paneLayoutStyle);

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, Number(value) || min));
}

function isSafeCustomColor(value) {
  return /^#[0-9a-f]{6}$/i.test(String(value || "").trim());
}

function isAllowedUiColor(value, palette = accentOptions) {
  const color = String(value || "").trim();
  return palette.includes(color) || isSafeCustomColor(color);
}

function normalizeUiColor(value, fallback, palette = accentOptions) {
  const color = String(value || "").trim();
  return isAllowedUiColor(color, palette) ? color : fallback;
}

function colorInputValue(value, fallback = "#5d8cff") {
  const color = String(value || "").trim();
  return isSafeCustomColor(color) ? color : fallback;
}

function normalizeTerminalColor(value) {
  const color = String(value || "").trim();
  return isSafeCustomColor(color) ? color : "";
}

function normalizeSettings(input = {}, legacyFontSize = 0) {
  const parsed = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const next = {
    ...defaultSettings,
    ...parsed
  };
  if (legacyFontSize && !parsed.terminalFontSize) next.terminalFontSize = legacyFontSize;
  next.terminalFontSize = clamp(next.terminalFontSize, 10, 22);
  next.terminalLineHeight = clamp(next.terminalLineHeight, 1, 1.5);
  next.backgroundOpacity = clamp(next.backgroundOpacity, 0, 42);
  if (!themeOptions.some(([id]) => id === next.theme)) next.theme = defaultSettings.theme;
  next.accent = normalizeUiColor(next.accent, defaultSettings.accent);
  if (!["comfortable", "compact"].includes(next.density)) next.density = defaultSettings.density;
  if (!toolbarModeOptions.some(([id]) => id === next.toolbarMode)) {
    next.toolbarMode = parsed.showAdvanced ? "expanded" : defaultSettings.toolbarMode;
  }
  if (!terminalCursorStyles.some(([id]) => id === next.terminalCursorStyle)) next.terminalCursorStyle = defaultSettings.terminalCursorStyle;
  if (!terminalFontOptions.some(([id]) => id === next.terminalFontFamily)) next.terminalFontFamily = defaultSettings.terminalFontFamily;
  if (!terminalProfiles.some(([id]) => id === next.terminalProfile)) next.terminalProfile = defaultSettings.terminalProfile;
  next.backgroundImage = normalizeBackgroundValue(next.backgroundImage);
  next.browserHomeUrl = normalizeUrl(next.browserHomeUrl || defaultSettings.browserHomeUrl, defaultSettings.browserHomeUrl);
  next.terminalCustomShell = String(next.terminalCustomShell || "").trim().slice(0, 512);
  next.showTabs = next.showTabs !== false;
  next.showStatusbar = next.showStatusbar !== false;
  next.showAdvanced = next.toolbarMode === "expanded";
  next.performanceMode = Boolean(next.performanceMode);
  next.terminalCursorBlink = next.terminalCursorBlink !== false;
  next.terminalBackground = normalizeTerminalColor(next.terminalBackground);
  next.terminalForeground = normalizeTerminalColor(next.terminalForeground);
  next.terminalCursorColor = normalizeTerminalColor(next.terminalCursorColor);
  next.sidebarWidth = clamp(next.sidebarWidth, 188, 304);
  next.inspectorWidth = clamp(next.inspectorWidth, 300, 480);
  next.terminalScrollback = clamp(next.terminalScrollback, 2000, 50000);
  next.terminalPadding = clamp(next.terminalPadding, 0, 16);
  return next;
}

function loadSettings() {
  let parsed = {};
  try {
    parsed = JSON.parse(localStorage.getItem("cmux.settings") || "{}");
  } catch {
    parsed = {};
  }
  const legacyFontSize = Number(localStorage.getItem("cmux.terminalFontSize") || 0);
  return normalizeSettings(parsed, legacyFontSize);
}

function saveSettings() {
  localStorage.setItem("cmux.settings", JSON.stringify(state.settings));
  localStorage.setItem("cmux.terminalFontSize", String(state.settings.terminalFontSize));
}

function scheduleSettingsSave() {
  if (state.settingsSaveTimer) clearTimeout(state.settingsSaveTimer);
  state.settingsSavePending = true;
  state.settingsSaveTimer = setTimeout(() => {
    state.settingsSaveTimer = 0;
    state.settingsSavePending = false;
    saveSettings();
  }, settingsSaveDelay);
}

function flushSettingsSave() {
  if (state.settingsSaveTimer) {
    clearTimeout(state.settingsSaveTimer);
    state.settingsSaveTimer = 0;
  }
  if (!state.settingsSavePending) return;
  state.settingsSavePending = false;
  saveSettings();
}

function isBackgroundPreset(value) {
  return backgroundPresetMap.has(String(value || "").trim());
}

function normalizeBackgroundValue(value) {
  let url = String(value || "").trim();
  if (!url) return "";
  if (url.startsWith("preset:")) return backgroundPresetMap.has(url) ? url : "";
  if (!/^(https?:|data:image\/|file:|\/)/i.test(url)) url = `https://${url}`;
  return url;
}

function normalizedImageUrl(value) {
  const url = normalizeBackgroundValue(value);
  return url.startsWith("preset:") ? "" : url;
}

function backgroundCss(value) {
  const normalized = normalizeBackgroundValue(value);
  if (!normalized) return "none";
  const preset = backgroundPresetMap.get(normalized);
  if (preset) return preset.css;
  const url = normalizedImageUrl(normalized);
  return url ? `url("${url.replace(/["\\]/g, "\\$&")}")` : "none";
}

function terminalFontStack(value = state.settings.terminalFontFamily) {
  return terminalFontStacks.get(value) || terminalFontStacks.get(defaultSettings.terminalFontFamily);
}

function formatLineHeight(value) {
  return Number(value).toFixed(2);
}

function folderName(folderPath) {
  const parts = String(folderPath || "").split(/[\\/]+/).filter(Boolean);
  return parts.at(-1) || "Workspace";
}

function folderKey(folderPath) {
  return String(folderPath || "").trim().toLowerCase();
}

function shortFolderPath(folderPath) {
  const raw = String(folderPath || "").trim();
  if (!raw) return "";
  const parts = raw.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 3) return raw;
  return `${parts[0]}\\...\\${parts.slice(-2).join("\\")}`;
}

function loadRecentFolders() {
  try {
    const parsed = JSON.parse(localStorage.getItem(recentFoldersStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const unique = [];
    const seen = new Set();
    for (const entry of parsed) {
      const folder = String(entry || "").trim();
      const key = folderKey(folder);
      if (!folder || seen.has(key)) continue;
      seen.add(key);
      unique.push(folder);
      if (unique.length >= recentFoldersLimit) break;
    }
    return unique;
  } catch {
    return [];
  }
}

function saveRecentFolders() {
  localStorage.setItem(recentFoldersStorageKey, JSON.stringify(state.recentFolders));
}

function rememberRecentFolder(folderPath) {
  const folder = String(folderPath || "").trim();
  if (!folder) return;
  const key = folderKey(folder);
  state.recentFolders = [
    folder,
    ...state.recentFolders.filter((candidate) => folderKey(candidate) !== key)
  ].slice(0, recentFoldersLimit);
  saveRecentFolders();
}

function clearRecentFolders() {
  state.recentFolders = [];
  saveRecentFolders();
  renderSettingsInspector();
  toast("Recent folders cleared.");
}

function settingsRenderSignature(settings = state.settings) {
  return [
    settings.theme,
    settings.accent,
    settings.backgroundImage,
    settings.backgroundOpacity,
    settings.density,
    settings.toolbarMode,
    settings.showTabs,
    settings.showStatusbar,
    settings.showAdvanced,
    settings.performanceMode,
    settings.sidebarWidth,
    settings.inspectorWidth,
    settings.terminalFontFamily,
    settings.terminalPadding
  ].join("\u001f");
}

function applySettings() {
  const signature = settingsRenderSignature();
  if (state.appliedSettingsSignature === signature) return false;
  state.appliedSettingsSignature = signature;
  document.body.classList.remove(...themeOptions.filter(([id]) => id !== "cmux").map(([id]) => `theme-${id}`));
  if (state.settings.theme !== "cmux") document.body.classList.add(`theme-${state.settings.theme}`);
  document.documentElement.style.setProperty("--color-accent", state.settings.accent);
  document.documentElement.style.setProperty("--color-accent-hover", state.settings.accent);
  elements.shell.style.setProperty("--sidebar-width", `${state.settings.sidebarWidth}px`);
  elements.shell.style.setProperty("--inspector-width", `${state.settings.inspectorWidth}px`);
  elements.shell.style.setProperty("--terminal-font-family", terminalFontStack());
  elements.shell.style.setProperty("--terminal-padding", `${state.settings.terminalPadding}px`);
  elements.shell.classList.toggle("density-compact", state.settings.density === "compact");
  elements.shell.classList.toggle("toolbar-compact", state.settings.toolbarMode === "compact");
  elements.shell.classList.toggle("toolbar-standard", state.settings.toolbarMode === "standard");
  elements.shell.classList.toggle("toolbar-expanded", state.settings.toolbarMode === "expanded");
  elements.shell.classList.toggle("hide-tabs", !state.settings.showTabs);
  elements.shell.classList.toggle("hide-status", !state.settings.showStatusbar);
  elements.shell.classList.toggle("show-advanced", state.settings.showAdvanced);
  elements.shell.classList.toggle("performance-mode", state.settings.performanceMode);
  const css = backgroundCss(state.settings.backgroundImage);
  elements.shell.classList.toggle("has-background", css !== "none");
  elements.shell.style.setProperty("--background-image", css);
  elements.shell.style.setProperty("--background-opacity", String(state.settings.backgroundOpacity / 100));
  return true;
}

function updateSettings(updates, options = {}) {
  const previous = state.settings;
  state.settings = normalizeSettings({
    ...state.settings,
    ...updates
  });
  state.terminalFontSize = state.settings.terminalFontSize;
  if (options.immediate) saveSettings();
  else scheduleSettingsSave();
  applySettings();
  if (Object.keys(updates).some((key) => terminalAppearanceKeys.has(key) && previous[key] !== state.settings[key])) {
    scheduleTerminalAppearanceRefresh();
  }
}

function replaceChildrenIfChanged(parent, nodes) {
  if (parent.childNodes.length === nodes.length && nodes.every((node, index) => parent.childNodes[index] === node)) {
    return false;
  }
  parent.replaceChildren(...nodes);
  return true;
}

function normalizePaneWeight(value) {
  const weight = Number(value);
  if (!Number.isFinite(weight) || weight <= 0) return 0;
  return Math.min(paneLayoutMaxWeight, Math.max(1, Math.round(weight)));
}

function loadPaneLayouts() {
  try {
    const parsed = JSON.parse(localStorage.getItem(paneLayoutStorageKey) || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return new Map();
    const entries = [];
    for (const [panelId, layout] of Object.entries(parsed)) {
      if (!panelId || !layout || typeof layout !== "object" || Array.isArray(layout)) continue;
      const right = normalizePaneWeight(layout.right);
      const down = normalizePaneWeight(layout.down);
      const next = {};
      if (right) next.right = right;
      if (down) next.down = down;
      if (next.right || next.down) entries.push([panelId, next]);
    }
    return new Map(entries);
  } catch {
    return new Map();
  }
}

function savePaneLayouts() {
  if (state.paneLayouts.size === 0) {
    localStorage.removeItem(paneLayoutStorageKey);
    return;
  }
  const payload = {};
  for (const [panelId, layout] of state.paneLayouts.entries()) {
    const right = normalizePaneWeight(layout.right);
    const down = normalizePaneWeight(layout.down);
    const next = {};
    if (right) next.right = right;
    if (down) next.down = down;
    if (next.right || next.down) payload[panelId] = next;
  }
  localStorage.setItem(paneLayoutStorageKey, JSON.stringify(payload));
}

function paneLayoutDirection(workspace) {
  return workspace?.splitDirection === "down" ? "down" : "right";
}

function storedPaneWeight(panelId, direction) {
  return normalizePaneWeight(state.paneLayouts.get(panelId)?.[direction]);
}

function setStoredPaneWeight(panelId, direction, weight) {
  const nextWeight = normalizePaneWeight(weight);
  const layout = state.paneLayouts.get(panelId) || {};
  if (nextWeight) {
    layout[direction] = nextWeight;
    state.paneLayouts.set(panelId, layout);
    return;
  }
  delete layout[direction];
  if (layout.right || layout.down) state.paneLayouts.set(panelId, layout);
  else state.paneLayouts.delete(panelId);
}

function cleanupPaneLayouts() {
  const livePanelIds = allPanelIds();
  let changed = false;
  for (const panelId of [...state.paneLayouts.keys()]) {
    if (!livePanelIds.has(panelId)) {
      state.paneLayouts.delete(panelId);
      changed = true;
    }
  }
  if (changed) savePaneLayouts();
}

function storedPaneWeightsForPanels(panels, direction, zoomedPanel) {
  if (zoomedPanel || panels.length <= 1) return null;
  const persisted = loadPaneLayouts();
  const weights = new Map();
  for (const panel of panels) {
    const persistedLayout = persisted.get(panel.id);
    if (persistedLayout) {
      state.paneLayouts.set(panel.id, {
        ...(state.paneLayouts.get(panel.id) || {}),
        ...persistedLayout
      });
    }
    const weight = storedPaneWeight(panel.id, direction);
    if (!weight) return null;
    weights.set(panel.id, weight);
  }
  return weights;
}

function storedPaneWeightFromStorage(panelId, direction) {
  const persistedLayout = loadPaneLayouts().get(panelId);
  if (persistedLayout) {
    state.paneLayouts.set(panelId, {
      ...(state.paneLayouts.get(panelId) || {}),
      ...persistedLayout
    });
  }
  return storedPaneWeight(panelId, direction);
}

function paneIdSelector(panelId) {
  return String(panelId || "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
}

function renderPaneLayoutStylesForWeights(weights) {
  if (!weights || weights.size === 0) {
    elements.paneLayoutStyle.textContent = "";
    return;
  }
  elements.paneLayoutStyle.textContent = [...weights.entries()]
    .map(([panelId, weight]) => `#paneGrid > .pane[data-panel-id="${paneIdSelector(panelId)}"]{flex:${weight} 1 0px;}`)
    .join("\n");
}

function renderPaneLayoutStylesForVisiblePanes(direction) {
  const panes = [...elements.paneGrid.querySelectorAll(".pane")];
  if (panes.length <= 1) {
    elements.paneLayoutStyle.textContent = "";
    return false;
  }
  const weights = new Map();
  for (const pane of panes) {
    const weight = storedPaneWeightFromStorage(pane.dataset.panelId, direction);
    if (!weight) {
      elements.paneLayoutStyle.textContent = "";
      return false;
    }
    weights.set(pane.dataset.panelId, weight);
  }
  renderPaneLayoutStylesForWeights(weights);
  return true;
}

function clearPaneFlex(pane) {
  pane.style.flex = "";
}

function clearVisiblePaneFlex() {
  for (const pane of elements.paneGrid.querySelectorAll(".pane")) clearPaneFlex(pane);
  elements.paneLayoutStyle.textContent = "";
}

function clearVisiblePaneInlineFlex() {
  for (const pane of elements.paneGrid.querySelectorAll(".pane")) clearPaneFlex(pane);
}

function clearPaneLayoutsForWorkspace(workspace) {
  if (!workspace) return;
  let changed = false;
  for (const panel of workspace.panels) {
    if (state.paneLayouts.delete(panel.id)) changed = true;
  }
  if (changed) savePaneLayouts();
  clearVisiblePaneFlex();
}

function applyStoredPaneLayoutToVisiblePanes(direction) {
  const panes = [...elements.paneGrid.querySelectorAll(".pane")];
  if (panes.length <= 1) {
    elements.paneLayoutStyle.textContent = "";
    return false;
  }
  const weights = panes.map((pane) => storedPaneWeightFromStorage(pane.dataset.panelId, direction));
  if (weights.some((weight) => !weight)) {
    elements.paneLayoutStyle.textContent = "";
    return false;
  }
  const weightMap = new Map(panes.map((pane, index) => [pane.dataset.panelId, weights[index]]));
  renderPaneLayoutStylesForWeights(weightMap);
  return true;
}

function scheduleVisiblePaneLayoutApply() {
  if (state.resizing || state.paneLayoutFrame) return;
  state.paneLayoutFrame = requestAnimationFrame(() => {
    state.paneLayoutFrame = 0;
    const workspace = activeWorkspace();
    if (workspace) applyStoredPaneLayoutToVisiblePanes(paneLayoutDirection(workspace));
  });
}

function persistPaneLayoutFromGrid(direction) {
  const panes = [...elements.paneGrid.querySelectorAll(".pane")]
    .filter((pane) => pane.dataset.panelId);
  if (panes.length <= 1) return;
  const sizes = panes.map((pane) => {
    const rect = pane.getBoundingClientRect();
    return {
      panelId: pane.dataset.panelId,
      size: Math.max(1, direction === "down" ? rect.height : rect.width)
    };
  });
  const total = sizes.reduce((sum, item) => sum + item.size, 0);
  if (!total) return;
  for (const item of sizes) {
    setStoredPaneWeight(item.panelId, direction, Math.round((item.size / total) * paneLayoutScale));
  }
  cleanupPaneLayouts();
  savePaneLayouts();
}

function terminalTheme() {
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim() || "#72a4ff";
  const background = state.settings.terminalBackground || terminalColorDefaults.background;
  const foreground = state.settings.terminalForeground || terminalColorDefaults.foreground;
  const cursor = state.settings.terminalCursorColor || accent;
  return {
    background,
    foreground,
    cursor,
    cursorAccent: "#111316",
    selectionBackground: "#315a92",
    black: background,
    red: "#f07178",
    green: "#88c070",
    yellow: "#d9c77f",
    blue: "#72a4ff",
    magenta: "#c792ea",
    cyan: "#75c7c6",
    white: foreground,
    brightBlack: "#63675d",
    brightRed: "#ff8f8f",
    brightGreen: "#9bd980",
    brightYellow: "#ffe08a",
    brightBlue: "#9ec2ff",
    brightMagenta: "#d7a9ff",
    brightCyan: "#9ce0df",
    brightWhite: "#f3f1e7"
  };
}

function refreshTerminalAppearance() {
  for (const session of state.terminals.values()) {
    session.term.options.fontFamily = terminalFontStack();
    session.term.options.fontSize = state.terminalFontSize;
    session.term.options.lineHeight = state.settings.terminalLineHeight;
    session.term.options.scrollback = state.settings.terminalScrollback;
    session.term.options.cursorStyle = state.settings.terminalCursorStyle;
    session.term.options.cursorBlink = state.settings.terminalCursorBlink;
    session.term.options.theme = terminalTheme();
    scheduleFitTerminal(session, true);
  }
}

function scheduleTerminalAppearanceRefresh() {
  if (state.terminalAppearanceFrame) return;
  state.terminalAppearanceFrame = requestAnimationFrame(() => {
    state.terminalAppearanceFrame = 0;
    refreshTerminalAppearance();
  });
}

const commands = [
  { id: "workspace.new", label: "New Workspace", shortcut: "Ctrl+N", run: () => createWorkspace() },
  { id: "workspace.newFromFolder", label: "New Workspace From Folder", shortcut: "", run: () => createWorkspaceFromFolder() },
  { id: "workspace.rename", label: "Rename Workspace", shortcut: "", run: () => renameActiveWorkspace() },
  { id: "workspace.color", label: "Change Workspace Color", shortcut: "", run: () => cycleWorkspaceColor() },
  { id: "workspace.changeFolder", label: "Change Workspace Folder", shortcut: "", run: () => chooseWorkspaceFolder() },
  { id: "workspace.openFolder", label: "Open Workspace Folder", shortcut: "", run: () => openWorkspaceFolder() },
  { id: "workspace.starterTerminalBrowser", label: "Add Terminal + Browser Starter", shortcut: "", run: () => applyWorkspaceStarter("terminalBrowser") },
  { id: "workspace.starterTwoTerminals", label: "Add Two-Terminal Starter", shortcut: "", run: () => applyWorkspaceStarter("twoTerminals") },
  { id: "workspace.starterDevTrio", label: "Add Dev Trio Starter", shortcut: "", run: () => applyWorkspaceStarter("devTrio") },
  { id: "workspace.close", label: "Close Workspace", shortcut: "", run: () => closeActiveWorkspace() },
  { id: "terminal.new", label: "New Terminal", shortcut: "Ctrl+T", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitRight", label: "Split Terminal Right", shortcut: "", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitDown", label: "Split Terminal Down", shortcut: "", run: () => createPanel("terminal", "down") },
  { id: "terminal.duplicate", label: "Duplicate Active Pane", shortcut: "", run: () => duplicateActivePanel() },
  { id: "terminal.copySelection", label: "Copy Terminal Selection", shortcut: "Ctrl+Shift+C", run: () => copyActiveTerminalSelection() },
  { id: "terminal.pasteClipboard", label: "Paste Clipboard to Terminal", shortcut: "Ctrl+Shift+V", run: () => pasteClipboardToTerminal() },
  { id: "terminal.clear", label: "Clear Active Terminal", shortcut: "Ctrl+K", run: () => clearActiveTerminal() },
  { id: "terminal.restart", label: "Restart Active Terminal", shortcut: "Ctrl+Shift+R", run: () => restartActiveTerminal() },
  { id: "terminal.close", label: "Close Active Pane", shortcut: "Ctrl+W", run: () => closeActivePanel() },
  { id: "terminal.reopenClosed", label: "Reopen Closed Pane", shortcut: "Ctrl+Shift+T", run: () => reopenClosedPanel() },
  { id: "terminal.closeOthers", label: "Close Other Panes", shortcut: "", run: () => closeOtherPanes() },
  { id: "terminal.closeRight", label: "Close Panes to Right", shortcut: "", run: () => closePanesToRight() },
  { id: "terminal.focusPane", label: "Toggle Pane Focus", shortcut: "Ctrl+Shift+M", run: () => togglePaneZoom() },
  { id: "terminal.resetLayout", label: "Reset Split Layout", shortcut: "", run: () => resetActivePaneLayout() },
  { id: "terminal.fontUp", label: "Terminal Font Larger", shortcut: "Ctrl+=", run: () => changeTerminalFontSize(1) },
  { id: "terminal.fontDown", label: "Terminal Font Smaller", shortcut: "Ctrl+-", run: () => changeTerminalFontSize(-1) },
  { id: "browser.new", label: "Open Browser", shortcut: "Ctrl+Shift+L", run: () => openBrowserPrompt() },
  { id: "notifications.open", label: "Show Notifications", shortcut: "Ctrl+I", run: () => openInspector("notifications") },
  { id: "session.tools", label: "Show Session Tools", shortcut: "", run: () => openInspector("session") },
  { id: "settings.open", label: "Open Settings", shortcut: "Ctrl+,", run: () => openInspector("settings") },
  { id: "settings.performance", label: "Open Performance Settings", shortcut: "", run: () => openSettingsCategory("performance") },
  { id: "settings.performancePreset", label: "Apply Performance Preset", shortcut: "", run: () => applySettingsPresetById("performance") },
  { id: "settings.actions", label: "Open Actions Settings", shortcut: "", run: () => openSettingsCategory("actions") },
  { id: "session.reset", label: "Reset Session", shortcut: "", run: () => resetSession() },
  { id: "sidebar.toggle", label: "Toggle Sidebar", shortcut: "Ctrl+B", run: () => toggleSidebar() },
  { id: "attention.fake", label: "Simulate Notification", shortcut: "", run: () => simulateNotification() }
];

function activeWorkspace() {
  return state.data?.workspaces.find((workspace) => workspace.id === state.data.activeWorkspaceId)
    || state.data?.workspaces[0];
}

function activePanel() {
  const workspace = activeWorkspace();
  return workspace?.panels.find((panel) => panel.id === workspace.activePanelId) || workspace?.panels[0];
}

function zoomedPanelForWorkspace(workspace = activeWorkspace()) {
  if (!workspace || !state.zoomedPanelId) return null;
  return workspace.panels.find((panel) => panel.id === state.zoomedPanelId) || null;
}

function allPanels() {
  return (state.data?.workspaces || []).flatMap((workspace) => workspace.panels);
}

function allPanelIds() {
  return new Set(allPanels().map((panel) => panel.id));
}

function findPanelState(panelId) {
  for (const workspace of state.data?.workspaces || []) {
    const panel = workspace.panels.find((candidate) => candidate.id === panelId);
    if (panel) return { workspace, panel };
  }
  return null;
}

function api(path, options = {}) {
  return fetch(path, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(options.headers || {})
    }
  }).then(async (response) => {
    if (!response.ok) throw new Error(await response.text());
    return response.json();
  });
}

async function loadState() {
  state.data = await api("/api/state");
  render();
}

function connectEvents() {
  const socket = new WebSocket(`${location.origin.replace(/^http/, "ws")}/events`);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.type === "state") {
      const previous = state.data;
      state.data = message.state;
      scheduleRender(previous);
    }
  });
  socket.addEventListener("close", () => setTimeout(connectEvents, 800));
}

function scheduleRender(previousState = null) {
  if (previousState && !state.scheduledRenderPrevious) state.scheduledRenderPrevious = previousState;
  if (state.renderFrame) return;
  state.renderFrame = requestAnimationFrame(() => {
    state.renderFrame = 0;
    const previous = state.scheduledRenderPrevious;
    state.scheduledRenderPrevious = null;
    render(previous);
  });
}

function render(previousState) {
  if (!state.data) return;
  if (state.resizing) {
    state.pendingRender = true;
    state.pendingRenderPrevious ||= previousState || null;
    return;
  }
  const renderStartedAt = performance.now();
  cleanupStalePaneCache();
  const workspace = activeWorkspace();
  const panelCount = workspace?.panels.length || 0;
  const attentionCount = allAttentionPanels().length;
  const zoomedPanel = zoomedPanelForWorkspace(workspace);

  elements.workspaceHeading.textContent = workspace?.title || "Workspace";
  elements.workspaceSubheading.textContent = workspace
    ? `${workspace.cwdShort || "no directory"}`
    : "Ready";
  elements.statusSummary.textContent = workspace
    ? `${workspace.title} · ${zoomedPanel ? "focus" : panelCount ? `${panelCount} panel${panelCount === 1 ? "" : "s"}` : "home"} · ${attentionCount} attention`
    : "cmux Windows";
  elements.statusPipe.textContent = state.data.pipeName || "pipe unavailable";
  elements.statusPty.textContent = state.data.ptyAvailable ? "ConPTY ready" : "process pipe fallback";

  elements.shell.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  elements.shell.classList.toggle("inspector-open", Boolean(state.inspectorMode));
  elements.shell.classList.toggle("pane-zoomed", Boolean(zoomedPanel));
  applySettings();
  renderWorkspaces();
  renderSurfaceTabs(workspace);
  renderPanes(workspace);
  renderInspector();
  renderPalette();
  announceNewAttention(previousState, state.data);
  recordRenderDuration(performance.now() - renderStartedAt);
}

function recordRenderDuration(durationMs) {
  const value = Number(durationMs) || 0;
  state.renderStats.count += 1;
  state.renderStats.lastMs = value;
  state.renderStats.avgMs = state.renderStats.avgMs
    ? (state.renderStats.avgMs * 0.86) + (value * 0.14)
    : value;
  state.renderStats.maxMs = Math.max(state.renderStats.maxMs, value);
}

function cleanupStalePaneCache() {
  const livePanelIds = allPanelIds();
  for (const panelId of [...state.paneCache.keys()]) {
    if (!livePanelIds.has(panelId)) cleanupPanel(panelId);
  }
  cleanupPaneLayouts();
}

function flushPendingRender() {
  if (!state.pendingRender) return;
  const previous = state.pendingRenderPrevious;
  state.pendingRender = false;
  state.pendingRenderPrevious = null;
  render(previous);
}

function allAttentionPanels() {
  return (state.data?.workspaces || []).flatMap((workspace) =>
    workspace.panels
      .filter((panel) => panel.needsAttention)
      .map((panel) => ({ workspace, panel }))
  );
}

function renderWorkspaces() {
  const activeId = state.data.activeWorkspaceId;
  const validIds = new Set(state.data.workspaces.map((workspace) => workspace.id));
  for (const [workspaceId, row] of [...state.workspaceRows]) {
    if (!validIds.has(workspaceId)) {
      row.remove();
      state.workspaceRows.delete(workspaceId);
    }
  }
  const nodes = state.data.workspaces.map((workspace, index) => {
    let button = state.workspaceRows.get(workspace.id);
    if (!button) {
      button = createWorkspaceRow();
      state.workspaceRows.set(workspace.id, button);
    }
    updateWorkspaceRow(button, workspace, index, activeId);
    return button;
  });
  replaceChildrenIfChanged(elements.workspaceList, nodes);
}

function createWorkspaceRow() {
  const button = document.createElement("button");
  button.className = "workspace-row";
  button.innerHTML = `
    <span class="workspace-attention"></span>
    <span class="workspace-card">
      <span class="workspace-name-line">
        <span class="workspace-color"></span>
        <span class="workspace-name"></span>
        <span class="workspace-badge"></span>
      </span>
      <span class="workspace-meta"></span>
      <span class="workspace-path"></span>
      <span class="workspace-branch"></span>
    </span>
  `;
  button.addEventListener("click", () => focusWorkspace(button.dataset.workspaceId));
  button.addEventListener("contextmenu", (event) => {
    const workspace = state.data?.workspaces.find((candidate) => candidate.id === button.dataset.workspaceId);
    if (workspace) showWorkspaceContextMenu(event, workspace);
  });
  button.addEventListener("dragover", (event) => {
    if (!state.dragPanelId) return;
    event.preventDefault();
    button.classList.add("is-drop-target");
  });
  button.addEventListener("dragleave", () => button.classList.remove("is-drop-target"));
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    button.classList.remove("is-drop-target");
    if (state.dragPanelId) movePanelToWorkspace(state.dragPanelId, button.dataset.workspaceId);
  });
  return button;
}

function updateWorkspaceRow(button, workspace, index, activeId) {
  const hasAttention = workspace.panels.some((panel) => panel.needsAttention);
  const attentionTotal = workspace.panels.filter((panel) => panel.needsAttention).length;
  button.dataset.workspaceId = workspace.id;
  button.className = `workspace-row${workspace.id === activeId ? " is-active" : ""}${hasAttention ? " has-attention" : ""}`;
  button.style.setProperty("--workspace-color", workspace.color || state.data.palette?.[0] || "");
  button.querySelector(".workspace-name").textContent = workspace.title || `Workspace ${index + 1}`;
  button.querySelector(".workspace-badge").textContent = String(attentionTotal);
  button.querySelector(".workspace-meta").textContent = workspace.latestNotification
    || `${workspace.terminalCount || 0} terminals / ${workspace.browserCount || 0} browsers`;
  button.querySelector(".workspace-path").textContent = workspace.cwdShort || "~";
  button.querySelector(".workspace-branch").hidden = true;
}

function renderSurfaceTabs(workspace) {
  if (!workspace) {
    replaceChildrenIfChanged(elements.surfaceTabs, []);
    return;
  }
  const validIds = new Set(workspace.panels.map((panel) => panel.id));
  for (const [panelId, tab] of [...state.surfaceTabButtons]) {
    if (!validIds.has(panelId)) {
      tab.remove();
      state.surfaceTabButtons.delete(panelId);
    }
  }
  const nodes = workspace.panels.map((panel) => {
    let button = state.surfaceTabButtons.get(panel.id);
    if (!button) {
      button = createSurfaceTab();
      state.surfaceTabButtons.set(panel.id, button);
    }
    updateSurfaceTab(button, workspace, panel);
    return button;
  });
  nodes.push(getNewSurfaceTab(workspace));
  replaceChildrenIfChanged(elements.surfaceTabs, nodes);
}

function createSurfaceTab() {
  const button = document.createElement("button");
  button.className = "surface-tab";
  button.draggable = true;
  button.innerHTML = `
    <span class="surface-dot"></span>
    <span class="surface-label"></span>
    <span class="surface-close" title="Close">×</span>
  `;
  button.addEventListener("click", () => focusPanel(button.dataset.panelId));
  button.addEventListener("contextmenu", (event) => {
    const found = findPanelState(button.dataset.panelId);
    if (found) showPanelContextMenu(event, found.panel);
  });
  button.addEventListener("dragstart", (event) => {
    state.dragPanelId = button.dataset.panelId;
    button.classList.add("is-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", state.dragPanelId);
  });
  button.addEventListener("dragover", (event) => {
    if (!state.dragPanelId || state.dragPanelId === button.dataset.panelId) return;
    event.preventDefault();
    button.classList.add("is-drop-before");
  });
  button.addEventListener("dragleave", () => button.classList.remove("is-drop-before"));
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    button.classList.remove("is-drop-before");
    if (state.dragPanelId && state.dragPanelId !== button.dataset.panelId) {
      movePanelBefore(state.dragPanelId, button.dataset.panelId);
    }
  });
  button.addEventListener("dragend", () => {
    button.classList.remove("is-dragging");
    state.dragPanelId = null;
    clearAllDropTargets();
  });
  button.querySelector(".surface-close").addEventListener("click", (event) => {
    event.stopPropagation();
    closePanel(button.dataset.panelId);
  });
  return button;
}

function updateSurfaceTab(button, workspace, panel) {
  const label = panel.type === "browser" ? hostnameOf(panel.url) : panel.title || "Terminal";
  button.dataset.panelId = panel.id;
  button.className = `surface-tab${panel.id === workspace.activePanelId ? " is-active" : ""}${panel.id === state.zoomedPanelId ? " is-zoomed" : ""}${panel.needsAttention ? " has-attention" : ""}`;
  button.title = `${label} - right-click for pane options`;
  button.style.setProperty("--tab-color", panel.color || workspace.color || "var(--color-accent)");
  button.querySelector(".surface-label").textContent = label;
}

function getNewSurfaceTab(workspace) {
  if (!state.newTabButton) {
    state.newTabButton = document.createElement("button");
    state.newTabButton.className = "surface-tab surface-new-tab";
    state.newTabButton.type = "button";
    state.newTabButton.title = "New terminal";
    state.newTabButton.textContent = "+";
    state.newTabButton.onclick = () => createPanel("terminal", "right");
    state.newTabButton.addEventListener("dragover", (event) => {
      if (!state.dragPanelId) return;
      event.preventDefault();
      state.newTabButton.classList.add("is-drop-before");
    });
    state.newTabButton.addEventListener("dragleave", () => state.newTabButton.classList.remove("is-drop-before"));
    state.newTabButton.addEventListener("drop", (event) => {
      event.preventDefault();
      state.newTabButton.classList.remove("is-drop-before");
      if (state.dragPanelId) movePanelToWorkspace(state.dragPanelId, state.newTabButton.dataset.workspaceId);
    });
  }
  state.newTabButton.dataset.workspaceId = workspace.id;
  return state.newTabButton;
}

function renderPanes(workspace) {
  const panels = workspace?.panels || [];
  if (!workspace) {
    for (const child of [...elements.paneGrid.children]) {
      if (child.classList.contains("pane")) child.remove();
    }
    replaceChildrenIfChanged(elements.paneGrid, []);
    return;
  }
  elements.paneGrid.classList.toggle("direction-down", workspace.splitDirection === "down");
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  const visiblePanels = zoomedPanel ? [zoomedPanel] : panels;
  const layoutDirection = paneLayoutDirection(workspace);
  const layoutWeights = storedPaneWeightsForPanels(visiblePanels, layoutDirection, zoomedPanel);
  if (visiblePanels.length <= 1) elements.paneLayoutStyle.textContent = "";
  else if (layoutWeights) renderPaneLayoutStylesForWeights(layoutWeights);
  elements.paneGrid.classList.toggle("is-zoomed", Boolean(zoomedPanel));
  const panelIds = new Set(visiblePanels.map((panel) => panel.id));
  const livePanelIds = allPanelIds();
  for (const child of [...elements.paneGrid.children]) {
    if (child.classList.contains("pane") && !panelIds.has(child.dataset.panelId)) {
      if (!livePanelIds.has(child.dataset.panelId)) cleanupPanel(child.dataset.panelId);
      child.remove();
    }
  }
  if (panels.length === 0) {
    renderEmptyWorkspace(workspace);
    return;
  }

  const nodes = [];
  for (const [index, panel] of visiblePanels.entries()) {
    if (index > 0) nodes.push(getPaneSplitter(workspace, visiblePanels[index - 1], panel));
    let pane = elements.paneGrid.querySelector(`[data-panel-id="${panel.id}"]`) || state.paneCache.get(panel.id);
    if (!pane) {
      pane = createPane(panel);
    }
    nodes.push(pane);
    pane.dataset.panelId = panel.id;
    pane.style.setProperty("--panel-color", panel.color || workspace.color || "var(--color-accent)");
    pane.classList.toggle("is-active", panel.id === workspace.activePanelId);
    pane.classList.toggle("is-zoomed", panel.id === state.zoomedPanelId);
    pane.classList.toggle("has-attention", panel.needsAttention);
    pane.classList.toggle("is-browser", panel.type === "browser");
    pane.classList.toggle("is-terminal", panel.type === "terminal");
    if (visiblePanels.length <= 1) clearPaneFlex(pane);
    pane.querySelector(".pane-type").textContent = panel.type === "browser" ? "web" : "term";
    const title = panel.type === "browser" ? panel.url || "Browser" : panelTitle(panel);
    const titleNode = pane.querySelector(".pane-title");
    titleNode.textContent = title;
    titleNode.title = title;
    const zoomButton = pane.querySelector(".zoom");
    zoomButton.textContent = panel.id === state.zoomedPanelId ? "↙" : "□";
    zoomButton.title = panel.id === state.zoomedPanelId ? "Show all panes" : "Focus pane";
    if (panel.type === "terminal") {
      ensureTerminal(panel, pane.querySelector(".pane-body"));
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal);
    }
    if (panel.type === "browser") ensureBrowser(panel, pane.querySelector(".pane-body"));
  }
  replaceChildrenIfChanged(elements.paneGrid, nodes);
  if (!state.resizing && visiblePanels.length > 1) {
    requestAnimationFrame(() => applyStoredPaneLayoutToVisiblePanes(layoutDirection));
  }
}

function panelTitle(panel) {
  const name = panel.title || "Terminal";
  const cwd = panel.cwdShort || "~";
  return name === cwd ? name : `${name} · ${cwd}`;
}

function createEmptyWorkspace(workspace) {
  const node = document.createElement("div");
  node.className = "empty-workspace";
  node.innerHTML = `
    <div class="empty-workspace-inner">
      <img src="/assets/cmux-empty.svg" alt="cmux Windows">
      <div class="empty-workspace-title"></div>
      <div class="empty-workspace-body">Start with a pane or build a ready workspace layout.</div>
      <div class="empty-workspace-actions">
        <button class="tool-button primary new-terminal">+ Term</button>
        <button class="tool-button new-browser">Web</button>
      </div>
      <div class="empty-workspace-starters"></div>
    </div>
  `;
  node.querySelector(".empty-workspace-title").textContent = workspace?.title || "cmux Windows";
  node.querySelector(".new-terminal").onclick = () => createPanel("terminal", "right");
  node.querySelector(".new-browser").onclick = () => openBrowserPrompt();
  renderEmptyWorkspaceStarters(node, workspace);
  return node;
}

function renderEmptyWorkspace(workspace) {
  let node = [...elements.paneGrid.children].find((child) => child.classList.contains("empty-workspace"));
  if (!node) {
    node = createEmptyWorkspace(workspace);
  } else {
    node.querySelector(".empty-workspace-title").textContent = workspace?.title || "cmux Windows";
    renderEmptyWorkspaceStarters(node, workspace);
  }
  replaceChildrenIfChanged(elements.paneGrid, [node]);
}

function renderEmptyWorkspaceStarters(node, workspace) {
  const host = node.querySelector(".empty-workspace-starters");
  if (!host) return;
  const cards = workspaceStarters.map((starter) => {
    const button = document.createElement("button");
    button.className = "empty-workspace-starter";
    button.type = "button";
    button.dataset.workspaceStarter = starter.id;
    button.innerHTML = `
      <span class="empty-workspace-starter-label"></span>
      <span class="empty-workspace-starter-meta"></span>
    `;
    button.querySelector(".empty-workspace-starter-label").textContent = starter.label;
    button.querySelector(".empty-workspace-starter-meta").textContent = starter.panels
      .map((type) => type === "browser" ? "web" : "term")
      .join(" + ");
    button.onclick = () => applyWorkspaceStarter(starter.id, workspace?.id);
    return button;
  });
  replaceChildrenIfChanged(host, cards);
}

function getPaneSplitter(workspace, beforePanel, afterPanel) {
  const key = `${beforePanel.id}:${afterPanel.id}`;
  let splitter = elements.paneGrid.querySelector(`[data-splitter-key="${key}"]`);
  if (!splitter) {
    splitter = document.createElement("div");
    splitter.className = "pane-splitter";
    splitter.dataset.splitterKey = key;
    splitter.title = "Resize panes";
    splitter.addEventListener("pointerdown", (event) => startPaneResize(event, splitter));
  }
  return splitter;
}

function startPaneResize(event, splitter) {
  event.preventDefault();
  const workspace = activeWorkspace();
  if (!workspace) return;
  const previousPane = splitter.previousElementSibling;
  const nextPane = splitter.nextElementSibling;
  if (!previousPane || !nextPane) return;
  const vertical = workspace.splitDirection === "down";
  const previousRect = previousPane.getBoundingClientRect();
  const nextRect = nextPane.getBoundingClientRect();
  const start = vertical ? event.clientY : event.clientX;
  const previousSize = vertical ? previousRect.height : previousRect.width;
  const nextSize = vertical ? nextRect.height : nextRect.width;
  const panes = [...elements.paneGrid.querySelectorAll(".pane")];
  for (const pane of panes) {
    const rect = pane.getBoundingClientRect();
    const size = vertical ? rect.height : rect.width;
    pane.style.flex = `0 0 ${Math.max(120, size)}px`;
  }
  splitter.classList.add("is-dragging");
  splitter.setPointerCapture(event.pointerId);
  state.resizing = {
    splitter,
    previousPane,
    nextPane,
    vertical,
    direction: vertical ? "down" : "right",
    workspaceId: workspace.id,
    start,
    previousSize,
    nextSize
  };
}

function continuePaneResize(event) {
  if (!state.resizing) return;
  const { previousPane, nextPane, vertical, start, previousSize, nextSize } = state.resizing;
  const current = vertical ? event.clientY : event.clientX;
  const delta = current - start;
  const minSize = vertical ? 140 : 180;
  const nextPrevious = Math.max(minSize, previousSize + delta);
  const nextNext = Math.max(minSize, nextSize - delta);
  previousPane.style.flex = `0 0 ${nextPrevious}px`;
  nextPane.style.flex = `0 0 ${nextNext}px`;
  for (const panelId of [previousPane.dataset.panelId, nextPane.dataset.panelId]) {
    const terminal = state.terminals.get(panelId);
    if (terminal) scheduleFitTerminal(terminal);
  }
}

function finishPaneResize(event) {
  if (!state.resizing) return;
  const { splitter, workspaceId, direction } = state.resizing;
  splitter.releasePointerCapture?.(event.pointerId);
  splitter.classList.remove("is-dragging");
  persistPaneLayoutFromGrid(direction);
  renderPaneLayoutStylesForVisiblePanes(direction);
  clearVisiblePaneInlineFlex();
  state.resizing = null;
  flushPendingRender();
  requestAnimationFrame(() => {
    renderPaneLayoutStylesForVisiblePanes(direction);
    clearVisiblePaneInlineFlex();
  });
}

function startSidebarResize(event) {
  if (state.sidebarCollapsed || event.button !== 0) return;
  const rect = elements.sidebar.getBoundingClientRect();
  if (rect.right - event.clientX > 8) return;
  event.preventDefault();
  elements.sidebar.setPointerCapture?.(event.pointerId);
  elements.shell.classList.add("sidebar-resizing");
  state.sidebarResizing = {
    pointerId: event.pointerId,
    startX: event.clientX,
    startWidth: rect.width,
    width: rect.width
  };
}

function continueSidebarResize(event) {
  if (!state.sidebarResizing) return;
  const nextWidth = Math.round(clamp(
    state.sidebarResizing.startWidth + event.clientX - state.sidebarResizing.startX,
    188,
    304
  ));
  state.sidebarResizing.width = nextWidth;
  state.settings.sidebarWidth = nextWidth;
  elements.shell.style.setProperty("--sidebar-width", `${nextWidth}px`);
}

function finishSidebarResize(event) {
  if (!state.sidebarResizing) return;
  if (event.pointerId === state.sidebarResizing.pointerId) {
    elements.sidebar.releasePointerCapture?.(event.pointerId);
  }
  state.sidebarResizing = null;
  elements.shell.classList.remove("sidebar-resizing");
  saveSettings();
  applySettings();
  if (state.inspectorMode === "settings" && state.settingsCategory === "layout") {
    renderSettingsInspector();
  }
}

function startInspectorResize(event) {
  if (!state.inspectorMode || event.button !== 0) return;
  const rect = elements.inspector.getBoundingClientRect();
  if (event.clientX - rect.left > 8) return;
  event.preventDefault();
  elements.inspector.setPointerCapture?.(event.pointerId);
  elements.shell.classList.add("inspector-resizing");
  state.inspectorResizing = {
    pointerId: event.pointerId,
    startX: event.clientX,
    startWidth: rect.width,
    width: rect.width
  };
}

function continueInspectorResize(event) {
  if (!state.inspectorResizing) return;
  const nextWidth = Math.round(clamp(
    state.inspectorResizing.startWidth + state.inspectorResizing.startX - event.clientX,
    300,
    480
  ));
  state.inspectorResizing.width = nextWidth;
  state.settings.inspectorWidth = nextWidth;
  elements.shell.style.setProperty("--inspector-width", `${nextWidth}px`);
}

function finishInspectorResize(event) {
  if (!state.inspectorResizing) return;
  if (event.pointerId === state.inspectorResizing.pointerId) {
    elements.inspector.releasePointerCapture?.(event.pointerId);
  }
  state.inspectorResizing = null;
  elements.shell.classList.remove("inspector-resizing");
  saveSettings();
  applySettings();
  if (state.inspectorMode === "settings" && state.settingsCategory === "layout") {
    renderSettingsInspector();
  }
}

function createPane(panel) {
  const pane = document.createElement("article");
  pane.className = "pane";
  pane.dataset.panelId = panel.id;
  pane.innerHTML = `
    <div class="pane-header">
      <div class="pane-grip" title="Drag pane">::</div>
      <div class="pane-type"></div>
      <div class="pane-title"></div>
      <div class="pane-toolbar">
        <button class="pane-tool split-right" title="Split right">◫</button>
        <button class="pane-tool split-down" title="Split down">⇣</button>
        <button class="pane-tool zoom" title="Focus pane">□</button>
        <button class="pane-tool font-down" title="Smaller terminal text">A-</button>
        <button class="pane-tool font-up" title="Larger terminal text">A+</button>
        <button class="pane-tool restart" title="Restart terminal">↻</button>
        <button class="pane-tool close" title="Close">×</button>
      </div>
    </div>
    <div class="pane-body"></div>
  `;
  const header = pane.querySelector(".pane-header");
  header.draggable = true;
  header.addEventListener("click", () => focusPanel(pane.dataset.panelId));
  header.addEventListener("dragstart", (event) => {
    state.dragPanelId = pane.dataset.panelId;
    pane.classList.add("is-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", state.dragPanelId);
  });
  header.addEventListener("dragend", () => {
    pane.classList.remove("is-dragging");
    state.dragPanelId = null;
    clearAllDropTargets();
  });
  pane.querySelector(".split-right").onclick = (event) => {
    event.stopPropagation();
    createPanel("terminal", "right");
  };
  pane.querySelector(".split-down").onclick = (event) => {
    event.stopPropagation();
    createPanel("terminal", "down");
  };
  pane.querySelector(".zoom").onclick = (event) => {
    event.stopPropagation();
    togglePaneZoom(pane.dataset.panelId);
  };
  pane.querySelector(".font-down").onclick = (event) => {
    event.stopPropagation();
    changeTerminalFontSize(-1);
  };
  pane.querySelector(".font-up").onclick = (event) => {
    event.stopPropagation();
    changeTerminalFontSize(1);
  };
  pane.querySelector(".restart").onclick = (event) => {
    event.stopPropagation();
    restartPanel(pane.dataset.panelId);
  };
  pane.querySelector(".close").onclick = (event) => {
    event.stopPropagation();
    closePanel(pane.dataset.panelId);
  };
  pane.addEventListener("dragover", (event) => {
    if (!state.dragPanelId || state.dragPanelId === pane.dataset.panelId) return;
    event.preventDefault();
    pane.dataset.dropPosition = paneDropPosition(event, pane);
    pane.classList.add("is-drop-target");
  });
  pane.addEventListener("dragleave", () => clearPaneDropTarget(pane));
  pane.addEventListener("drop", (event) => {
    event.preventDefault();
    const placement = pane.dataset.dropPosition || paneDropPosition(event, pane);
    clearPaneDropTarget(pane);
    if (state.dragPanelId && state.dragPanelId !== pane.dataset.panelId) {
      movePanelRelative(state.dragPanelId, pane.dataset.panelId, placement);
    }
  });
  pane.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || event.target.closest(".pane-header")) return;
    focusPanel(pane.dataset.panelId);
  });
  state.paneCache.set(panel.id, pane);
  return pane;
}

function paneDropPosition(event, pane) {
  const rect = pane.getBoundingClientRect();
  const x = rect.width ? (event.clientX - rect.left) / rect.width : 0.5;
  const y = rect.height ? (event.clientY - rect.top) / rect.height : 0.5;
  if (y < 0.28) return "top";
  if (y > 0.72) return "bottom";
  return x < 0.5 ? "left" : "right";
}

function clearPaneDropTarget(pane) {
  pane.classList.remove("is-drop-target");
  pane.removeAttribute("data-drop-position");
}

function clearAllDropTargets() {
  for (const pane of document.querySelectorAll(".pane.is-drop-target")) clearPaneDropTarget(pane);
  for (const node of document.querySelectorAll(".is-drop-before, .workspace-row.is-drop-target")) {
    node.classList.remove("is-drop-before", "is-drop-target");
  }
}

function cleanupPanel(panelId) {
  if (state.zoomedPanelId === panelId) state.zoomedPanelId = null;
  const terminal = state.terminals.get(panelId);
  if (terminal) {
    terminal.disposed = true;
    if (terminal.fitFrame) cancelAnimationFrame(terminal.fitFrame);
    closeSocketQuietly(terminal.socket);
    terminal.resizeObserver?.disconnect();
    terminal.term?.dispose();
    state.terminals.delete(panelId);
  }
  const pane = state.paneCache.get(panelId);
  pane?.remove();
  state.paneCache.delete(panelId);
  state.browserViews.delete(panelId);
}

function closeSocketQuietly(socket) {
  if (!socket) return;
  if (socket.readyState === WebSocket.CONNECTING) {
    socket.addEventListener("open", () => socket.close(), { once: true });
    socket.addEventListener("error", () => {}, { once: true });
    return;
  }
  if (socket.readyState === WebSocket.OPEN) socket.close();
}

function ensureTerminal(panel, body) {
  if (state.terminals.has(panel.id)) return;
  body.replaceChildren();
  if (!TerminalConstructor || !FitAddonConstructor || !WebLinksAddonConstructor) {
    console.error("xterm renderer libraries failed to load.");
    const error = document.createElement("div");
    error.className = "empty-state";
    error.textContent = "Terminal renderer failed to load.";
    body.appendChild(error);
    return;
  }
  const host = document.createElement("div");
  host.className = "terminal-host";
  body.appendChild(host);

  const term = new TerminalConstructor({
    cursorBlink: state.settings.terminalCursorBlink,
    cursorStyle: state.settings.terminalCursorStyle,
    allowProposedApi: true,
    convertEol: true,
    fontFamily: terminalFontStack(),
    fontSize: state.terminalFontSize,
    lineHeight: state.settings.terminalLineHeight,
    scrollback: state.settings.terminalScrollback,
    theme: terminalTheme()
  });
  const fitAddon = new FitAddonConstructor();
  const webLinksAddon = new WebLinksAddonConstructor();
  term.loadAddon(fitAddon);
  term.loadAddon(webLinksAddon);
  term.open(host);

  const socket = new WebSocket(`${location.origin.replace(/^http/, "ws")}/terminal/${panel.id}`);
  const session = {
    term,
    fitAddon,
    socket,
    host,
    queue: "",
    scheduled: false,
    fitFrame: 0,
    resizeObserver: null,
    disposed: false,
    lastFitCols: 0,
    lastFitRows: 0,
    lastHostWidth: 0,
    lastHostHeight: 0,
    forceFit: false
  };

  socket.addEventListener("open", () => scheduleFitTerminal(session, true));
  socket.addEventListener("message", (event) => {
    if (session.disposed) return;
    const message = JSON.parse(event.data);
    if (message.type === "output") {
      enqueueTerminalOutput(session, message.data);
    }
  });

  term.onData((data) => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "input", data }));
    }
  });

  session.resizeObserver = new ResizeObserver(() => scheduleFitTerminal(session));
  session.resizeObserver.observe(host);
  setTimeout(() => {
    scheduleFitTerminal(session, true);
    if (panel.id === activeWorkspace()?.activePanelId) term.focus();
  }, 60);
  state.terminals.set(panel.id, session);
}

function enqueueTerminalOutput(session, data) {
  session.queue += data;
  scheduleTerminalOutputFlush(session);
}

function scheduleTerminalOutputFlush(session) {
  if (session.disposed || session.scheduled) return;
  session.scheduled = true;
  requestAnimationFrame(() => flushTerminalOutput(session));
}

function flushTerminalOutput(session) {
  session.scheduled = false;
  if (session.disposed || !session.queue) return;
  const chunkSize = state.settings.performanceMode ? terminalOutputPerformanceChunkSize : terminalOutputChunkSize;
  const chunk = session.queue.length > chunkSize ? session.queue.slice(0, chunkSize) : session.queue;
  session.queue = session.queue.slice(chunk.length);
  session.term.write(chunk);
  if (session.queue) scheduleTerminalOutputFlush(session);
}

function scheduleFitTerminal(session, force = false) {
  if (session.disposed) return;
  if (force) session.forceFit = true;
  if (session.fitFrame) return;
  session.fitFrame = requestAnimationFrame(() => {
    session.fitFrame = 0;
    fitTerminal(session);
  });
}

function fitTerminal(session) {
  if (session.disposed || !isTerminalHostVisible(session)) return;
  const width = session.host.clientWidth;
  const height = session.host.clientHeight;
  if (
    !session.forceFit
    && session.lastFitCols
    && session.lastFitRows
    && session.lastHostWidth === width
    && session.lastHostHeight === height
  ) {
    return;
  }
  try {
    session.fitAddon.fit();
    session.forceFit = false;
    session.lastHostWidth = width;
    session.lastHostHeight = height;
    if (
      session.socket.readyState === WebSocket.OPEN
      && (session.term.cols !== session.lastFitCols || session.term.rows !== session.lastFitRows)
    ) {
      session.lastFitCols = session.term.cols;
      session.lastFitRows = session.term.rows;
      session.socket.send(JSON.stringify({
        type: "resize",
        cols: session.term.cols,
        rows: session.term.rows
      }));
    }
  } catch {
    // xterm can reject fit during first layout; later resize observer calls repair it.
  }
}

function isTerminalHostVisible(session) {
  const host = session.host;
  return Boolean(
    host?.isConnected
    && host.clientWidth > 0
    && host.clientHeight > 0
    && host.getClientRects().length > 0
  );
}

function ensureBrowser(panel, body) {
  if (state.browserViews.has(panel.id)) return;
  body.replaceChildren();

  const shell = document.createElement("div");
  shell.className = "browser-shell";
  const bar = document.createElement("div");
  bar.className = "browser-bar";
  const back = document.createElement("button");
  back.className = "browser-nav";
  back.type = "button";
  back.title = "Back";
  back.textContent = "‹";
  const forward = document.createElement("button");
  forward.className = "browser-nav";
  forward.type = "button";
  forward.title = "Forward";
  forward.textContent = "›";
  const reload = document.createElement("button");
  reload.className = "browser-nav";
  reload.type = "button";
  reload.title = "Reload";
  reload.textContent = "↻";
  const home = document.createElement("button");
  home.className = "browser-nav";
  home.type = "button";
  home.title = "Home";
  home.textContent = "⌂";
  const address = document.createElement("input");
  address.className = "browser-address";
  address.value = panel.url || "https://example.com";
  const go = document.createElement("button");
  go.className = "browser-go";
  go.type = "button";
  go.textContent = "Go";
  const external = document.createElement("button");
  external.className = "browser-go";
  external.type = "button";
  external.textContent = "↗";
  const status = document.createElement("div");
  status.className = "browser-status";
  status.textContent = "Loading";
  bar.append(back, forward, reload, home, address, go, external);

  const view = document.createElement(window.cmuxNative?.electron ? "webview" : "iframe");
  view.className = "browser-view";
  view.src = normalizeUrl(address.value, state.settings.browserHomeUrl);
  view.setAttribute("allowpopups", "true");
  if (view.tagName.toLowerCase() === "webview") {
    view.setAttribute("partition", "persist:cmux-browser");
    view.setAttribute("webpreferences", "contextIsolation=yes,nodeIntegration=no");
  }
  const isWebview = view.tagName.toLowerCase() === "webview";
  let webviewReady = !isWebview;

  const setStatus = (message = "") => {
    status.textContent = message;
    status.classList.toggle("is-visible", Boolean(message));
  };

  const updateNavState = () => {
    try {
      back.disabled = !(isWebview && webviewReady && typeof view.canGoBack === "function" && view.canGoBack());
      forward.disabled = !(isWebview && webviewReady && typeof view.canGoForward === "function" && view.canGoForward());
      reload.disabled = isWebview && !webviewReady;
    } catch {
      back.disabled = true;
      forward.disabled = true;
      reload.disabled = true;
    }
  };

  const navigate = () => {
    if (!findPanelState(panel.id)) return;
    const next = normalizeUrl(address.value, state.settings.browserHomeUrl);
    address.value = next;
    view.src = next;
    setStatus("Loading");
    updatePanel(panel.id, { url: next });
  };
  go.onclick = navigate;
  external.onclick = () => {
    if (window.cmuxNative?.openExternal) {
      window.cmuxNative.openExternal(normalizeUrl(address.value, state.settings.browserHomeUrl));
    } else {
      window.open(normalizeUrl(address.value, state.settings.browserHomeUrl), "_blank", "noopener");
    }
  };
  address.addEventListener("keydown", (event) => {
    if (event.key === "Enter") navigate();
  });
  back.onclick = () => {
    if (isWebview && webviewReady && typeof view.goBack === "function" && !back.disabled) view.goBack();
  };
  forward.onclick = () => {
    if (isWebview && webviewReady && typeof view.goForward === "function" && !forward.disabled) view.goForward();
  };
  reload.onclick = () => {
    if (reload.disabled) return;
    if (typeof view.reload === "function") {
      view.reload();
    } else {
      view.src = address.value;
    }
  };
  home.onclick = () => {
    address.value = state.settings.browserHomeUrl;
    navigate();
  };
  view.addEventListener("did-navigate", (event) => {
    if (event.url) {
      address.value = event.url;
      if (findPanelState(panel.id)) updatePanel(panel.id, { url: event.url });
    }
    updateNavState();
  });
  view.addEventListener("dom-ready", () => {
    webviewReady = true;
    updateNavState();
  });
  view.addEventListener("did-navigate-in-page", (event) => {
    if (event.url) address.value = event.url;
    updateNavState();
  });
  view.addEventListener("did-start-loading", () => {
    setStatus("Loading");
    updateNavState();
  });
  view.addEventListener("did-stop-loading", () => {
    setStatus("");
    updateNavState();
  });
  view.addEventListener("did-fail-load", (event) => {
    if (event.errorCode === -3) return;
    setStatus("Could not load here. Use Open.");
    updateNavState();
  });
  view.addEventListener("load", () => {
    setStatus("");
  });
  view.addEventListener("error", () => {
    setStatus("Could not load here. Use Open.");
  });

  shell.append(bar, status, view);
  body.append(shell);
  state.browserViews.set(panel.id, { view, address, back, forward, reload, home });
  updateNavState();
}

function normalizeUrl(value, fallback = "https://example.com") {
  let next = String(value || "").trim();
  if (!next) next = fallback;
  if (/^https?:\/\//i.test(next)) return next;
  if (/^localhost(?::\d+)?(?:\/|$)/i.test(next) || /^(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?:\/|$)/.test(next)) {
    return `http://${next}`;
  }
  if (!/\s/.test(next) && next.includes(".")) return `https://${next}`;
  next = `https://www.bing.com/search?q=${encodeURIComponent(next)}`;
  return next;
}

function hostnameOf(value) {
  try {
    return new URL(normalizeUrl(value)).hostname;
  } catch {
    return "Browser";
  }
}

function renderInspector() {
  if (!state.inspectorMode) return;
  if (state.inspectorMode === "notifications") {
    elements.inspectorTitle.textContent = "Notifications";
    elements.inspectorSubtitle.textContent = "Unread panes and agent attention";
    const notifications = allAttentionPanels();
    if (notifications.length === 0) {
      elements.inspectorBody.innerHTML = `<div class="empty-state">No panes need attention.</div>`;
      return;
    }
    elements.inspectorBody.replaceChildren(...notifications.map(({ workspace, panel }) => {
      const card = document.createElement("div");
      card.className = "notification-card";
      card.innerHTML = `
        <div class="notification-title"></div>
        <div class="notification-body"></div>
        <button class="notification-action">Jump to pane</button>
      `;
      card.querySelector(".notification-title").textContent = workspace.title;
      card.querySelector(".notification-body").textContent = panel.notificationText || panel.title || "Terminal needs attention.";
      card.querySelector(".notification-action").onclick = async () => {
        await focusWorkspace(workspace.id);
        await focusPanel(panel.id);
      };
      return card;
    }));
  } else if (state.inspectorMode === "settings") {
    renderSettingsInspector();
  } else {
    elements.inspectorTitle.textContent = "Session";
    elements.inspectorSubtitle.textContent = "Local Windows runtime";
    const workspace = activeWorkspace();
    const cards = [
      ["Control pipe", state.data.pipeName || "Unavailable"],
      ["Terminal backend", state.data.ptyAvailable ? "node-pty / ConPTY" : "process pipe fallback"],
      ["Active workspace", workspace?.title || "None"],
      ["Working directory", workspace?.cwd || "None"]
    ];
    const nodes = cards.map(([title, body]) => {
      const card = document.createElement("div");
      card.className = "session-card";
      card.innerHTML = `<div class="session-title"></div><div class="session-body"></div>`;
      card.querySelector(".session-title").textContent = title;
      card.querySelector(".session-body").textContent = body;
      return card;
    });
    const reset = document.createElement("button");
    reset.className = "notification-action";
    reset.textContent = "Reset current session";
    reset.onclick = () => resetSession();
    elements.inspectorBody.replaceChildren(...nodes, reset);
  }
}

function renderSettingsInspector() {
  elements.inspectorTitle.textContent = "Settings";
  elements.inspectorSubtitle.textContent = `${settingsCategoryLabel(state.settingsCategory)} page`;
  const workspace = activeWorkspace();
  const settingsChrome = document.createElement("div");
  settingsChrome.className = "settings-react-host";
  const nodes = [settingsChrome];
  const searching = Boolean(normalizeSettingsQuery(state.settingsQuery));
  const shouldBuildSection = (id) => state.settingsCategory === id || searching;

  if (shouldBuildSection("quick")) {
    const quickSection = settingsSection("Quick setup");
    quickSection.append(settingsPresetGrid());
    nodes.push(quickSection);
  }

  if (shouldBuildSection("workspace")) {
    const workspaceSection = settingsSection("Workspace");
    const titleInput = document.createElement("input");
    titleInput.className = "setting-control";
    titleInput.value = workspace?.title || "";
    titleInput.placeholder = "Workspace name";
    titleInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") titleInput.blur();
    });
    titleInput.addEventListener("blur", () => renameWorkspaceTo(titleInput.value));
    workspaceSection.append(settingRow("Name", titleInput));
    const folderInput = document.createElement("input");
    folderInput.className = "setting-control";
    folderInput.readOnly = true;
    folderInput.value = workspace?.cwdShort || workspace?.cwd || "";
    folderInput.title = workspace?.cwd || "";
    workspaceSection.append(settingRow("Folder", folderInput, true, "workspace folder directory cwd path"));
    const folderActions = document.createElement("div");
    folderActions.className = "settings-actions";
    folderActions.dataset.settingsSearch = normalizeSettingsQuery("workspace folder directory cwd choose open new");
    folderActions.append(
      settingsActionButton("Choose", () => chooseWorkspaceFolder(), "", "workspace folder directory cwd picker choose folder"),
      settingsActionButton("Open", () => openWorkspaceFolder(), "", "workspace folder explorer directory open folder"),
      settingsActionButton("New", () => createWorkspaceFromFolder(), "", "workspace folder new directory new from folder")
    );
    workspaceSection.append(folderActions);
    workspaceSection.append(recentFoldersSettings());
    workspaceSection.append(workspaceStarterGrid());
    workspaceSection.append(settingRow("Color", swatchGrid(state.data?.palette || accentOptions, workspace?.color, (color) => setWorkspaceColor(color))));
    workspaceSection.append(settingRow("Custom color", colorPicker(workspace?.color, (color) => setWorkspaceColor(color)), false, "custom workspace color hex picker"));
    nodes.push(workspaceSection);
  }

  if (shouldBuildSection("appearance")) {
    const appearanceSection = settingsSection("Appearance");
    const themeSelect = document.createElement("select");
    themeSelect.className = "setting-select";
    for (const [value, label] of themeOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      themeSelect.append(option);
    }
    themeSelect.value = state.settings.theme;
    themeSelect.onchange = () => updateSettings({ theme: themeSelect.value });
    appearanceSection.append(settingRow("Theme", themeSelect));
    appearanceSection.append(settingRow("Accent", swatchGrid(accentOptions, state.settings.accent, (accent) => updateSettings({ accent }))));
    appearanceSection.append(settingRow("Custom accent", colorPicker(state.settings.accent, (accent) => updateSettings({ accent })), false, "custom accent color hex picker"));
    appearanceSection.append(settingRow("Background preset", backgroundPresetGrid(), true));

    const imageInput = document.createElement("input");
    imageInput.className = "setting-control";
    imageInput.value = isBackgroundPreset(state.settings.backgroundImage) ? "" : state.settings.backgroundImage;
    imageInput.placeholder = "https://image-url";
    imageInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") imageInput.blur();
    });
    imageInput.addEventListener("blur", () => {
      const next = imageInput.value.trim();
      if (next || !isBackgroundPreset(state.settings.backgroundImage)) {
        updateSettings({ backgroundImage: next });
        renderSettingsInspector();
      }
    });
    appearanceSection.append(settingRow("Custom image", imageInput, true));
    const imageActions = document.createElement("div");
    imageActions.className = "settings-actions background-actions";
    imageActions.append(
      settingsActionButton("Choose file", chooseBackgroundImage, "", "background image local file wallpaper"),
      settingsActionButton("Clear image", () => {
        updateSettings({ backgroundImage: "" });
        renderSettingsInspector();
      }, "danger", "background image local file wallpaper reset remove")
    );
    imageActions.dataset.settingsSearch = normalizeSettingsQuery("background image local file wallpaper clear");
    appearanceSection.append(imageActions);

    const opacityInput = document.createElement("input");
    opacityInput.className = "setting-control";
    opacityInput.type = "range";
    opacityInput.min = "0";
    opacityInput.max = "42";
    opacityInput.value = String(state.settings.backgroundOpacity);
    opacityInput.oninput = () => updateSettings({ backgroundOpacity: Number(opacityInput.value) });
    appearanceSection.append(settingRow("Image strength", opacityInput));
    nodes.push(appearanceSection);
  }

  if (shouldBuildSection("browser")) {
    const browserSection = settingsSection("Browser");
    const homeInput = document.createElement("input");
    homeInput.className = "setting-control";
    homeInput.value = state.settings.browserHomeUrl;
    homeInput.placeholder = "https://www.bing.com";
    homeInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") homeInput.blur();
    });
    homeInput.addEventListener("blur", () => {
      updateSettings({ browserHomeUrl: homeInput.value || defaultSettings.browserHomeUrl });
      homeInput.value = state.settings.browserHomeUrl;
    });
    browserSection.append(settingRow("Home page", homeInput, true));
    const homeActions = document.createElement("div");
    homeActions.className = "settings-actions";
    homeActions.append(
      settingsActionButton("Open", () => createPanel("browser", "right", { url: state.settings.browserHomeUrl })),
      settingsActionButton("Reset", () => {
        updateSettings({ browserHomeUrl: defaultSettings.browserHomeUrl });
        renderSettingsInspector();
      })
    );
    browserSection.append(homeActions);
    nodes.push(browserSection);
  }

  if (shouldBuildSection("layout")) {
    const layoutSection = settingsSection("Layout");
    const densitySelect = document.createElement("select");
    densitySelect.className = "setting-select";
    for (const value of ["comfortable", "compact"]) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value[0].toUpperCase() + value.slice(1);
      densitySelect.append(option);
    }
    densitySelect.value = state.settings.density;
    densitySelect.onchange = () => updateSettings({ density: densitySelect.value });
    layoutSection.append(settingRow("Density", densitySelect));
    const toolbarSelect = document.createElement("select");
    toolbarSelect.className = "setting-select";
    for (const [value, label] of toolbarModeOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      toolbarSelect.append(option);
    }
    toolbarSelect.value = state.settings.toolbarMode;
    toolbarSelect.onchange = () => updateSettings({ toolbarMode: toolbarSelect.value });
    layoutSection.append(settingRow("Toolbar", toolbarSelect, false, "top bar command strip compact standard expanded shortcuts actions"));
    const sidebarWidthRange = document.createElement("input");
    sidebarWidthRange.className = "setting-control";
    sidebarWidthRange.type = "range";
    sidebarWidthRange.min = "188";
    sidebarWidthRange.max = "304";
    sidebarWidthRange.step = "4";
    sidebarWidthRange.value = String(state.settings.sidebarWidth);
    const sidebarWidthRow = settingRow(`Sidebar ${state.settings.sidebarWidth}px`, sidebarWidthRange);
    sidebarWidthRange.oninput = () => {
      updateSettings({ sidebarWidth: Number(sidebarWidthRange.value) });
      sidebarWidthRow.querySelector(".setting-label").textContent = `Sidebar ${state.settings.sidebarWidth}px`;
    };
    layoutSection.append(sidebarWidthRow);
    const inspectorWidthRange = document.createElement("input");
    inspectorWidthRange.className = "setting-control";
    inspectorWidthRange.type = "range";
    inspectorWidthRange.min = "300";
    inspectorWidthRange.max = "480";
    inspectorWidthRange.step = "4";
    inspectorWidthRange.value = String(state.settings.inspectorWidth);
    const inspectorWidthRow = settingRow(`Settings panel ${state.settings.inspectorWidth}px`, inspectorWidthRange, false, "settings inspector right panel width preferences customization");
    inspectorWidthRange.oninput = () => {
      updateSettings({ inspectorWidth: Number(inspectorWidthRange.value) });
      inspectorWidthRow.querySelector(".setting-label").textContent = `Settings panel ${state.settings.inspectorWidth}px`;
    };
    layoutSection.append(inspectorWidthRow);
    const layoutActions = document.createElement("div");
    layoutActions.className = "settings-actions";
    layoutActions.dataset.settingsSearch = normalizeSettingsQuery("split layout pane splitter resize reset equal");
    layoutActions.append(settingsActionButton("Reset split layout", resetActivePaneLayout, "", "split layout pane splitter resize reset equal"));
    layoutSection.append(layoutActions);
    layoutSection.append(settingRow("Surface tabs", toggleInput(state.settings.showTabs, (checked) => updateSettings({ showTabs: checked }))));
    layoutSection.append(settingRow("Status bar", toggleInput(state.settings.showStatusbar, (checked) => updateSettings({ showStatusbar: checked }))));
    layoutSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked }))));
    nodes.push(layoutSection);
  }

  if (shouldBuildSection("performance")) {
    const performanceSection = settingsSection("Performance", "speed smooth lag render diagnostics optimize preset");
    performanceSection.append(settingsMetricGrid(performanceMetrics()));
    performanceSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked })), false, "speed smooth lag effects reduce animation"));
    const scrollbackRange = document.createElement("input");
    scrollbackRange.className = "setting-control";
    scrollbackRange.type = "range";
    scrollbackRange.min = "2000";
    scrollbackRange.max = "50000";
    scrollbackRange.step = "2000";
    scrollbackRange.value = String(state.settings.terminalScrollback);
    const scrollbackRow = settingRow(`History ${state.settings.terminalScrollback}`, scrollbackRange, false, "terminal history scrollback memory output performance");
    scrollbackRange.oninput = () => {
      updateSettings({ terminalScrollback: Number(scrollbackRange.value) });
      scrollbackRow.querySelector(".setting-label").textContent = `History ${state.settings.terminalScrollback}`;
    };
    performanceSection.append(scrollbackRow);
    const performanceActions = document.createElement("div");
    performanceActions.className = "settings-actions";
    performanceActions.dataset.settingsSearch = normalizeSettingsQuery("performance speed preset balanced reset render stats clear");
    performanceActions.append(
      settingsActionButton("Speed preset", () => applySettingsPresetById("performance"), "", "performance speed preset optimize"),
      settingsActionButton("Balanced preset", () => applySettingsPresetById("balanced"), "", "balanced preset restore"),
      settingsActionButton("Reset stats", resetRenderStats, "", "performance render stats reset")
    );
    performanceSection.append(performanceActions);
    nodes.push(performanceSection);
  }

  if (shouldBuildSection("actions")) {
    const actionsSection = settingsSection("Actions", "commands shortcuts keyboard palette run tools");
    actionsSection.append(settingsCommandList());
    nodes.push(actionsSection);
  }

  if (shouldBuildSection("terminal")) {
    const terminalSection = settingsSection("Terminal");
    const fontSelect = document.createElement("select");
    fontSelect.className = "setting-select";
    for (const [value, label] of terminalFontOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      fontSelect.append(option);
    }
    fontSelect.value = state.settings.terminalFontFamily;
    fontSelect.onchange = () => updateSettings({ terminalFontFamily: fontSelect.value });
    terminalSection.append(settingRow("Font", fontSelect));
    const fontRange = document.createElement("input");
    fontRange.className = "setting-control";
    fontRange.type = "range";
    fontRange.min = "10";
    fontRange.max = "22";
    fontRange.value = String(state.terminalFontSize);
    const fontRow = settingRow(`Text size ${state.terminalFontSize}px`, fontRange);
    fontRange.oninput = () => {
      updateSettings({ terminalFontSize: Number(fontRange.value) });
      fontRow.querySelector(".setting-label").textContent = `Text size ${state.terminalFontSize}px`;
    };
    terminalSection.append(fontRow);
    const lineHeightRange = document.createElement("input");
    lineHeightRange.className = "setting-control";
    lineHeightRange.type = "range";
    lineHeightRange.min = "1";
    lineHeightRange.max = "1.5";
    lineHeightRange.step = "0.02";
    lineHeightRange.value = String(state.settings.terminalLineHeight);
    const lineHeightRow = settingRow(`Line height ${formatLineHeight(state.settings.terminalLineHeight)}`, lineHeightRange);
    lineHeightRange.oninput = () => {
      updateSettings({ terminalLineHeight: Number(lineHeightRange.value) });
      lineHeightRow.querySelector(".setting-label").textContent = `Line height ${formatLineHeight(state.settings.terminalLineHeight)}`;
    };
    terminalSection.append(lineHeightRow);
    const paddingRange = document.createElement("input");
    paddingRange.className = "setting-control";
    paddingRange.type = "range";
    paddingRange.min = "0";
    paddingRange.max = "16";
    paddingRange.value = String(state.settings.terminalPadding);
    const paddingRow = settingRow(`Padding ${state.settings.terminalPadding}px`, paddingRange);
    paddingRange.oninput = () => {
      updateSettings({ terminalPadding: Number(paddingRange.value) });
      paddingRow.querySelector(".setting-label").textContent = `Padding ${state.settings.terminalPadding}px`;
    };
    terminalSection.append(paddingRow);
    const scrollbackRange = document.createElement("input");
    scrollbackRange.className = "setting-control";
    scrollbackRange.type = "range";
    scrollbackRange.min = "2000";
    scrollbackRange.max = "50000";
    scrollbackRange.step = "2000";
    scrollbackRange.value = String(state.settings.terminalScrollback);
    const scrollbackRow = settingRow(`Scrollback ${state.settings.terminalScrollback}`, scrollbackRange);
    scrollbackRange.oninput = () => {
      updateSettings({ terminalScrollback: Number(scrollbackRange.value) });
      scrollbackRow.querySelector(".setting-label").textContent = `Scrollback ${state.settings.terminalScrollback}`;
    };
    terminalSection.append(scrollbackRow);
    const cursorSelect = document.createElement("select");
    cursorSelect.className = "setting-select";
    for (const [value, label] of terminalCursorStyles) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      cursorSelect.append(option);
    }
    cursorSelect.value = state.settings.terminalCursorStyle;
    cursorSelect.onchange = () => updateSettings({ terminalCursorStyle: cursorSelect.value });
    terminalSection.append(settingRow("Cursor", cursorSelect));
    terminalSection.append(settingRow("Cursor blink", toggleInput(state.settings.terminalCursorBlink, (checked) => updateSettings({ terminalCursorBlink: checked }))));
    terminalSection.append(settingRow(
      "Background color",
      colorPicker(state.settings.terminalBackground, (terminalBackground) => updateSettings({ terminalBackground }), terminalColorDefaults.background),
      false,
      "terminal background color custom hex"
    ));
    terminalSection.append(settingRow(
      "Text color",
      colorPicker(state.settings.terminalForeground, (terminalForeground) => updateSettings({ terminalForeground }), terminalColorDefaults.foreground),
      false,
      "terminal foreground text color custom hex"
    ));
    terminalSection.append(settingRow(
      "Cursor color",
      colorPicker(state.settings.terminalCursorColor, (terminalCursorColor) => updateSettings({ terminalCursorColor }), terminalColorDefaults.cursor),
      false,
      "terminal cursor color custom hex"
    ));
    const colorActions = document.createElement("div");
    colorActions.className = "settings-actions";
    colorActions.dataset.settingsSearch = normalizeSettingsQuery("terminal color reset default background foreground cursor");
    colorActions.append(
      settingsActionButton("Reset terminal colors", () => {
        updateSettings({
          terminalBackground: "",
          terminalForeground: "",
          terminalCursorColor: ""
        });
        renderSettingsInspector();
      }, "", "terminal color reset default background foreground cursor")
    );
    terminalSection.append(colorActions);
    const profileSelect = document.createElement("select");
    profileSelect.className = "setting-select";
    for (const [value, label] of terminalProfiles) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      profileSelect.append(option);
    }
    profileSelect.value = state.settings.terminalProfile;
    profileSelect.onchange = () => {
      updateSettings({ terminalProfile: profileSelect.value });
      renderSettingsInspector();
    };
    terminalSection.append(settingRow("Default shell", profileSelect));
    if (state.settings.terminalProfile === "custom") {
      const shellInput = document.createElement("input");
      shellInput.className = "setting-control";
      shellInput.value = state.settings.terminalCustomShell;
      shellInput.placeholder = "C:\\\\Path\\\\to\\\\shell.exe";
      shellInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") shellInput.blur();
      });
      shellInput.addEventListener("blur", () => updateSettings({ terminalCustomShell: shellInput.value }));
      terminalSection.append(settingRow("Shell path", shellInput, true));
    }
    const restart = document.createElement("button");
    restart.className = "notification-action";
    restart.textContent = "Restart active terminal";
    restart.onclick = () => restartActiveTerminal();
    terminalSection.append(restart);
    nodes.push(terminalSection);
  }

  if (shouldBuildSection("data")) {
    const actionsSection = settingsSection("Settings data");
    const actions = document.createElement("div");
    actions.className = "settings-actions";
    actions.append(
      settingsActionButton("Export", exportSettings),
      settingsActionButton("Import", importSettings),
      settingsActionButton("Reset", resetSettings, "danger")
    );
    actionsSection.append(actions);
    nodes.push(actionsSection);
  }

  const empty = document.createElement("div");
  empty.className = "settings-empty";
  empty.textContent = "No matching settings.";
  empty.hidden = true;
  nodes.push(empty);

  unmountSettingsChrome();
  elements.inspectorBody.replaceChildren(...nodes);
  renderSettingsChrome(settingsChrome);
  if (searching) applySettingsFilter();
}

function unmountSettingsChrome() {
  const reactSettings = window.CmuxSettingsUi;
  if (!reactSettings?.unmountSettingsShell) return;
  for (const host of elements.inspectorBody.querySelectorAll(".settings-react-host")) {
    reactSettings.unmountSettingsShell(host);
  }
}

function renderSettingsChrome(host) {
  const reactSettings = window.CmuxSettingsUi;
  if (!reactSettings?.renderSettingsShell) {
    host.replaceChildren(settingsSearch(), settingsCategoryNav());
    return;
  }
  reactSettings.renderSettingsShell(host, {
    activeCategory: state.settingsCategory,
    categories: settingsCategories,
    query: state.settingsQuery,
    subtitle: elements.inspectorSubtitle.textContent,
    onCategory: (category) => {
      state.settingsCategory = category;
      state.settingsQuery = "";
      renderSettingsInspector();
    },
    onQuery: (query) => {
      const wasSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      state.settingsQuery = query;
      const isSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      if (wasSearching !== isSearching) {
        renderSettingsInspector();
        scheduleSettingsSearchFocus();
      } else {
        renderSettingsChrome(host);
        applySettingsFilter();
      }
    },
    onClear: () => {
      state.settingsQuery = "";
      renderSettingsInspector();
      scheduleSettingsSearchFocus();
    }
  });
}

function settingsSearch() {
  const wrapper = document.createElement("div");
  wrapper.className = "settings-search";
  const input = document.createElement("input");
  input.className = "setting-control settings-search-input";
  input.type = "search";
  input.placeholder = "Search settings";
  input.value = state.settingsQuery;
  input.addEventListener("input", () => {
    const wasSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
    state.settingsQuery = input.value;
    const isSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
    if (wasSearching !== isSearching) {
      renderSettingsInspector();
      restoreSettingsSearchFocus();
      return;
    }
    applySettingsFilter();
  });
  const clear = document.createElement("button");
  clear.className = "settings-search-clear";
  clear.type = "button";
  clear.title = "Clear search";
  clear.textContent = "x";
  clear.disabled = !state.settingsQuery;
  clear.onclick = () => {
    state.settingsQuery = "";
    renderSettingsInspector();
    restoreSettingsSearchFocus();
  };
  wrapper.append(input, clear);
  return wrapper;
}

function restoreSettingsSearchFocus() {
  const input = elements.inspectorBody.querySelector(".settings-search-input");
  if (!input) return;
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

function scheduleSettingsSearchFocus() {
  requestAnimationFrame(() => {
    restoreSettingsSearchFocus();
    if (!elements.inspectorBody.querySelector(".settings-search-input:focus")) {
      setTimeout(restoreSettingsSearchFocus, 0);
    }
  });
}

function settingsCategoryNav() {
  const nav = document.createElement("div");
  nav.className = "settings-nav";
  for (const [id, label] of settingsCategories) {
    const button = document.createElement("button");
    button.className = `settings-nav-button${state.settingsCategory === id ? " is-active" : ""}`;
    button.type = "button";
    button.textContent = label;
    button.onclick = () => {
      state.settingsCategory = id;
      renderSettingsInspector();
    };
    nav.append(button);
  }
  return nav;
}

function settingsCategoryLabel(id) {
  return settingsCategories.find(([categoryId]) => categoryId === id)?.[1] || "Quick";
}

function settingsSection(title, searchTerms = "") {
  const section = document.createElement("section");
  section.className = "settings-section";
  section.dataset.settingsSearch = normalizeSettingsQuery(`${title} ${searchTerms}`);
  const heading = document.createElement("div");
  heading.className = "settings-section-title";
  heading.textContent = title;
  section.append(heading);
  return section;
}

function settingRow(label, control, stacked = false, searchTerms = "") {
  const row = document.createElement("label");
  row.className = `setting-row${stacked ? " stacked" : ""}`;
  row.dataset.settingsSearch = normalizeSettingsQuery(`${label} ${searchTerms}`);
  const text = document.createElement("span");
  text.className = "setting-label";
  text.textContent = label;
  row.append(text, control);
  return row;
}

function normalizeSettingsQuery(value) {
  return String(value || "").trim().toLowerCase();
}

function applySettingsFilter() {
  const query = normalizeSettingsQuery(state.settingsQuery);
  let visibleSections = 0;
  for (const section of elements.inspectorBody.querySelectorAll(".settings-section")) {
    const items = [...section.querySelectorAll("[data-settings-search]")].filter((item) => item !== section);
    let sectionVisible = settingsSearchMatches(section.dataset.settingsSearch, query);
    for (const item of items) {
      const visible = settingsSearchMatches(item.dataset.settingsSearch, query) || settingsSearchMatches(section.dataset.settingsSearch, query);
      item.hidden = !visible;
      sectionVisible ||= visible;
    }
    for (const group of section.querySelectorAll(".settings-command-group")) {
      const cardVisible = [...group.querySelectorAll(".settings-command-card")].some((card) => !card.hidden);
      const groupVisible = cardVisible
        || settingsSearchMatches(group.dataset.settingsSearch, query)
        || settingsSearchMatches(section.dataset.settingsSearch, query);
      group.hidden = !groupVisible;
      sectionVisible ||= groupVisible;
    }
    section.hidden = !sectionVisible;
    if (sectionVisible) visibleSections += 1;
  }
  const empty = elements.inspectorBody.querySelector(".settings-empty");
  if (empty) empty.hidden = !query || visibleSections > 0;
  const clear = elements.inspectorBody.querySelector(".settings-search-clear");
  if (clear) clear.disabled = !query;
}

function settingsSearchMatches(searchText, query) {
  if (!query) return true;
  const haystack = normalizeSettingsQuery(searchText);
  return query.split(/\s+/).every((token) => haystack.includes(token));
}

function formatMs(value) {
  return `${Math.max(0, Number(value) || 0).toFixed(1)} ms`;
}

function performanceMetrics() {
  const workspaces = state.data?.workspaces || [];
  const panels = allPanels();
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  return [
    ["Render avg", formatMs(state.renderStats.avgMs)],
    ["Last render", formatMs(state.renderStats.lastMs)],
    ["Max render", formatMs(state.renderStats.maxMs)],
    ["Workspaces", String(workspaces.length)],
    ["Panes", String(panels.length)],
    ["Terminals", String(terminalCount)],
    ["Browsers", String(browserCount)],
    ["Cached panes", String(state.paneCache.size)],
    ["Terminal cache", String(state.terminals.size)],
    ["Browser cache", String(state.browserViews.size)],
    ["Settings save", state.settingsSavePending ? "Queued" : "Clean"],
    ["Renders", String(state.renderStats.count)]
  ];
}

function settingsMetricGrid(metrics) {
  const grid = document.createElement("div");
  grid.className = "settings-metric-grid";
  for (const [label, value] of metrics) {
    const card = document.createElement("div");
    card.className = "settings-metric";
    card.dataset.settingsSearch = normalizeSettingsQuery(`performance diagnostics metric ${label} ${value}`);
    card.innerHTML = `<span class="settings-metric-value"></span><span class="settings-metric-label"></span>`;
    card.querySelector(".settings-metric-value").textContent = value;
    card.querySelector(".settings-metric-label").textContent = label;
    grid.append(card);
  }
  return grid;
}

function resetRenderStats() {
  state.renderStats = {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0
  };
  renderSettingsInspector();
  toast("Performance stats reset.");
}

function commandGroupLabel(command) {
  if (command.id.startsWith("workspace.")) return "Workspace";
  if (command.id.startsWith("terminal.")) return "Terminal";
  if (command.id.startsWith("browser.")) return "Browser";
  if (command.id.startsWith("settings.")) return "Settings";
  if (command.id.startsWith("notifications.")) return "Notifications";
  if (command.id.startsWith("session.")) return "Session";
  if (command.id.startsWith("sidebar.")) return "Layout";
  return "Tools";
}

function isDangerCommand(command) {
  return [
    "workspace.close",
    "terminal.close",
    "terminal.closeOthers",
    "terminal.closeRight",
    "session.reset"
  ].includes(command.id);
}

function settingsCommandList() {
  const list = document.createElement("div");
  list.className = "settings-command-list";
  const grouped = new Map();
  for (const command of commands) {
    const group = commandGroupLabel(command);
    if (!grouped.has(group)) grouped.set(group, []);
    grouped.get(group).push(command);
  }
  for (const [group, groupCommands] of grouped.entries()) {
    const groupNode = document.createElement("div");
    groupNode.className = "settings-command-group";
    groupNode.dataset.settingsSearch = normalizeSettingsQuery(`actions commands shortcuts keyboard palette ${group}`);
    const title = document.createElement("div");
    title.className = "settings-command-group-title";
    title.textContent = group;
    groupNode.append(title);
    for (const command of groupCommands) {
      groupNode.append(settingsCommandCard(command, group));
    }
    list.append(groupNode);
  }
  return list;
}

function settingsCommandCard(command, group) {
  const card = document.createElement("div");
  card.className = "settings-command-card";
  card.dataset.settingsSearch = normalizeSettingsQuery(`actions commands shortcuts keyboard palette run ${group} ${command.id} ${command.label} ${command.shortcut}`);
  const text = document.createElement("div");
  text.className = "settings-command-text";
  const label = document.createElement("span");
  label.className = "settings-command-label";
  label.textContent = command.label;
  const id = document.createElement("span");
  id.className = "settings-command-id";
  id.textContent = command.id;
  text.append(label, id);
  const shortcut = document.createElement("span");
  shortcut.className = "settings-command-shortcut";
  shortcut.textContent = command.shortcut || "Palette";
  const run = document.createElement("button");
  run.className = `settings-command-run${isDangerCommand(command) ? " danger" : ""}`;
  run.type = "button";
  run.textContent = "Run";
  run.onclick = () => runSettingsCommand(command);
  card.append(text, shortcut, run);
  return card;
}

async function runSettingsCommand(command) {
  if (isDangerCommand(command) && !await showConfirmDialog({
    title: command.label,
    message: "This command changes or closes current workspace state.",
    confirmLabel: "Run",
    danger: true
  })) return;
  command.run();
}

function toggleInput(checked, onChange) {
  const label = document.createElement("label");
  label.className = "setting-toggle";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = Boolean(checked);
  input.onchange = () => onChange(input.checked);
  const text = document.createElement("span");
  text.textContent = checked ? "On" : "Off";
  input.addEventListener("change", () => {
    text.textContent = input.checked ? "On" : "Off";
  });
  label.append(input, text);
  return label;
}

function swatchGrid(colors, activeColor, onPick) {
  const grid = document.createElement("div");
  grid.className = "swatch-grid";
  for (const color of colors) {
    const button = document.createElement("button");
    button.className = `swatch-button${color === activeColor ? " is-active" : ""}`;
    button.type = "button";
    button.title = color;
    button.style.setProperty("--swatch-color", color);
    button.onclick = () => {
      onPick(color);
      for (const sibling of grid.querySelectorAll(".swatch-button")) sibling.classList.remove("is-active");
      button.classList.add("is-active");
    };
    grid.append(button);
  }
  return grid;
}

function colorPicker(activeColor, onPick, fallback = "#5d8cff") {
  const wrapper = document.createElement("div");
  wrapper.className = "color-picker";
  const input = document.createElement("input");
  input.className = "setting-control color-picker-input";
  input.type = "color";
  input.value = colorInputValue(activeColor, fallback);
  input.dataset.settingsSearch = normalizeSettingsQuery("custom color picker hex");
  let committedColor = input.value;
  const swatch = document.createElement("span");
  swatch.className = "color-picker-preview";
  swatch.style.setProperty("--picked-color", colorInputValue(activeColor, fallback));
  input.addEventListener("input", () => {
    swatch.style.setProperty("--picked-color", input.value);
  });
  input.addEventListener("change", () => {
    if (input.value === committedColor) return;
    committedColor = input.value;
    onPick(input.value);
  });
  wrapper.append(input, swatch);
  return wrapper;
}

function backgroundPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "background-preset-grid";
  for (const preset of backgroundPresets) {
    const button = document.createElement("button");
    button.className = `background-preset${preset.value === state.settings.backgroundImage ? " is-active" : ""}`;
    button.type = "button";
    button.title = preset.label;
    button.dataset.settingsSearch = normalizeSettingsQuery(`background image wallpaper ${preset.label}`);
    button.style.setProperty("--preset-background", preset.preview);
    button.innerHTML = `<span class="background-preset-preview"></span><span class="background-preset-label"></span>`;
    button.querySelector(".background-preset-label").textContent = preset.label;
    button.onclick = () => {
      updateSettings({ backgroundImage: preset.value });
      renderSettingsInspector();
    };
    grid.append(button);
  }
  return grid;
}

function recentFoldersSettings() {
  const section = document.createElement("div");
  section.className = "recent-folder-list";
  section.dataset.settingsSearch = normalizeSettingsQuery("recent folders recent workspace folder history directory cwd quick reopen");

  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Recent folders";
  const clear = settingsActionButton("Clear", clearRecentFolders, "danger", "recent folders clear history");
  clear.disabled = state.recentFolders.length === 0;
  header.append(title, clear);
  section.append(header);

  if (state.recentFolders.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Chosen workspace folders will appear here.";
    section.append(empty);
    return section;
  }

  for (const folder of state.recentFolders) {
    const card = document.createElement("div");
    card.className = "recent-folder-card";
    card.dataset.settingsSearch = normalizeSettingsQuery(`recent folder workspace directory cwd ${folderName(folder)} ${folder}`);
    const text = document.createElement("div");
    text.className = "recent-folder-text";
    const name = document.createElement("div");
    name.className = "recent-folder-name";
    name.textContent = folderName(folder);
    const path = document.createElement("div");
    path.className = "recent-folder-path";
    path.textContent = shortFolderPath(folder);
    path.title = folder;
    text.append(name, path);

    const actions = document.createElement("div");
    actions.className = "recent-folder-actions";
    const create = settingsActionButton("New", () => createWorkspaceFromFolderPath(folder), "", `recent folder new workspace ${folder}`);
    create.dataset.recentFolderAction = "new";
    const use = settingsActionButton("Use", () => setWorkspaceFolderFromRecent(folder), "", `recent folder use current workspace ${folder}`);
    use.dataset.recentFolderAction = "use";
    const open = settingsActionButton("Open", () => openFolderPath(folder), "", `recent folder open explorer ${folder}`);
    open.dataset.recentFolderAction = "open";
    actions.append(create, use, open);
    card.append(text, actions);
    section.append(card);
  }

  return section;
}

function workspaceStarterGrid() {
  const section = document.createElement("div");
  section.className = "workspace-starter-list";
  section.dataset.settingsSearch = normalizeSettingsQuery("workspace starter layout preset split terminal browser dev trio setup");

  const title = document.createElement("div");
  title.className = "workspace-starter-title";
  title.textContent = "Workspace starters";
  section.append(title);

  const grid = document.createElement("div");
  grid.className = "workspace-starter-grid";
  for (const starter of workspaceStarters) {
    const button = document.createElement("button");
    button.className = "workspace-starter";
    button.type = "button";
    button.dataset.workspaceStarter = starter.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`workspace starter layout preset ${starter.label} ${starter.body} ${starter.panels.join(" ")}`);
    button.innerHTML = `
      <span class="workspace-starter-title-text"></span>
      <span class="workspace-starter-body"></span>
      <span class="workspace-starter-panes"></span>
    `;
    button.querySelector(".workspace-starter-title-text").textContent = starter.label;
    button.querySelector(".workspace-starter-body").textContent = starter.body;
    button.querySelector(".workspace-starter-panes").textContent = starter.panels
      .map((type) => type === "browser" ? "web" : "term")
      .join(" + ");
    button.onclick = () => applyWorkspaceStarter(starter.id);
    grid.append(button);
  }
  section.append(grid);
  return section;
}

function settingsActionButton(label, onClick, tone = "", searchTerms = "") {
  const button = document.createElement("button");
  button.className = `settings-action${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  button.textContent = label;
  button.title = label;
  button.dataset.settingsSearch = normalizeSettingsQuery(`${label} ${searchTerms}`);
  button.onclick = onClick;
  return button;
}

async function chooseBackgroundImage() {
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return;
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return;
  updateSettings({ backgroundImage: url });
  renderSettingsInspector();
  toast("Background image updated.");
}

function settingsPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "settings-preset-grid";
  for (const preset of settingsPresets) {
    const button = document.createElement("button");
    button.className = `settings-preset${isActiveSettingsPreset(preset) ? " is-active" : ""}`;
    button.type = "button";
    button.dataset.settingsSearch = normalizeSettingsQuery(`preset ${preset.label} ${preset.body}`);
    button.innerHTML = `<span class="settings-preset-title"></span><span class="settings-preset-body"></span>`;
    button.querySelector(".settings-preset-title").textContent = preset.label;
    button.querySelector(".settings-preset-body").textContent = preset.body;
    button.onclick = () => applySettingsPreset(preset);
    grid.append(button);
  }
  return grid;
}

function isActiveSettingsPreset(preset) {
  return Object.entries(preset.settings).every(([key, value]) => state.settings[key] === value);
}

function applySettingsPreset(preset) {
  updateSettings(preset.settings);
  renderSettingsInspector();
  toast(`${preset.label} settings applied.`);
}

function applySettingsPresetById(presetId) {
  const preset = settingsPresets.find((candidate) => candidate.id === presetId);
  if (!preset) return;
  applySettingsPreset(preset);
}

function ensureContextMenu() {
  if (state.contextMenu) return state.contextMenu;
  const menu = document.createElement("div");
  menu.className = "context-menu";
  menu.hidden = true;
  document.body.append(menu);
  state.contextMenu = menu;
  return menu;
}

function hideContextMenu() {
  if (!state.contextMenu) return;
  state.contextMenu.hidden = true;
  state.contextMenu.replaceChildren();
}

function showPanelContextMenu(event, panel) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  const found = findPanelState(panel.id);
  if (!found) return;
  const index = found.workspace.panels.findIndex((candidate) => candidate.id === panel.id);
  const panesToRight = found.workspace.panels.slice(index + 1);
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = panel.type === "browser" ? hostnameOf(panel.url) : panel.title || "Terminal";
  const actions = document.createElement("div");
  actions.className = "context-actions";
  const isTerminal = panel.type === "terminal";
  actions.append(
    contextMenuButton("Rename", () => renamePanel(panel)),
    contextMenuButton("Duplicate", () => duplicatePanel(panel)),
    contextMenuButton("Copy selection", () => copyActiveTerminalSelection(panel), !isTerminal),
    contextMenuButton("Paste", () => pasteClipboardToTerminal(panel), !isTerminal),
    contextMenuButton("Clear terminal", () => clearTerminalPanel(panel), !isTerminal),
    contextMenuButton("Restart terminal", () => restartPanel(panel.id), !isTerminal),
    contextMenuButton(panel.id === state.zoomedPanelId ? "Show all panes" : "Focus pane", () => togglePaneZoom(panel.id)),
    contextMenuButton("Move left", () => movePanelLeft(found.workspace, index), index <= 0),
    contextMenuButton("Move right", () => movePanelRight(found.workspace, index), index >= found.workspace.panels.length - 1),
    contextMenuButton("Close other panes", () => closeOtherPanes(panel.id), found.workspace.panels.length <= 1, "danger"),
    contextMenuButton("Close panes to right", () => closePanelsById(panesToRight.map((candidate) => candidate.id)), panesToRight.length === 0, "danger"),
    contextMenuButton("Close", () => closePanel(panel.id), false, "danger")
  );
  const colors = document.createElement("div");
  colors.className = "context-colors";
  for (const color of state.data?.palette || accentOptions) {
    const button = document.createElement("button");
    button.className = `context-color${panel.color === color ? " is-active" : ""}`;
    button.type = "button";
    button.title = color;
    button.style.setProperty("--context-color", color);
    button.onclick = () => {
      updatePanel(panel.id, { color });
      hideContextMenu();
    };
    colors.append(button);
  }
  const clear = contextMenuButton("Clear color", () => updatePanel(panel.id, { color: "" }), !panel.color);
  const customColor = contextColorPicker(panel.color, (color) => updatePanel(panel.id, { color }));
  menu.replaceChildren(title, actions, colors, customColor, clear);
  menu.hidden = false;
  const x = Math.min(event.clientX, window.innerWidth - 238);
  const y = Math.min(event.clientY, window.innerHeight - 260);
  menu.style.left = `${Math.max(8, x)}px`;
  menu.style.top = `${Math.max(8, y)}px`;
}

function showWorkspaceContextMenu(event, workspace) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  const isActive = workspace.id === state.data?.activeWorkspaceId;
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = workspace.title || "Workspace";
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = `${workspace.terminalCount || 0} terminals / ${workspace.browserCount || 0} browsers`;
  const actions = document.createElement("div");
  actions.className = "context-actions";
  actions.append(
    contextMenuButton(isActive ? "Focused" : "Focus", () => focusWorkspace(workspace.id), isActive),
    contextMenuButton("Rename", () => renameWorkspaceById(workspace.id, workspace.title)),
    contextMenuButton("Change folder", () => chooseWorkspaceFolder(workspace), !workspace.id),
    contextMenuButton("Open folder", () => openWorkspaceFolder(workspace), !workspace.cwd),
    contextMenuButton("New terminal here", () => createPanel("terminal", "right", { workspaceId: workspace.id })),
    contextMenuButton("Open browser here", () => openBrowserPrompt(workspace.id)),
    contextMenuButton("New workspace", () => createWorkspace()),
    contextMenuButton("New workspace from folder", () => createWorkspaceFromFolder()),
    contextMenuButton("Close workspace", () => closeWorkspaceById(workspace.id), false, "danger")
  );
  const colors = document.createElement("div");
  colors.className = "context-colors";
  for (const color of state.data?.palette || accentOptions) {
    const button = document.createElement("button");
    button.className = `context-color${workspace.color === color ? " is-active" : ""}`;
    button.type = "button";
    button.title = color;
    button.style.setProperty("--context-color", color);
    button.onclick = () => {
      setWorkspaceColor(color, workspace.id);
      hideContextMenu();
    };
    colors.append(button);
  }
  const customColor = contextColorPicker(workspace.color, (color) => setWorkspaceColor(color, workspace.id));
  menu.replaceChildren(title, meta, actions, colors, customColor);
  menu.hidden = false;
  const x = Math.min(event.clientX, window.innerWidth - 238);
  const y = Math.min(event.clientY, window.innerHeight - 326);
  menu.style.left = `${Math.max(8, x)}px`;
  menu.style.top = `${Math.max(8, y)}px`;
}

function showToolbarMenu(event) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  const panel = activePanel();
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = activeWorkspace()?.title || "Workspace tools";
  const actions = document.createElement("div");
  actions.className = "context-actions";
  actions.append(
    contextMenuButton("Split down", () => createPanel("terminal", "down")),
    contextMenuButton("Duplicate active pane", duplicateActivePanel, !panel),
    contextMenuButton("Reopen closed pane", reopenClosedPanel, state.closedPanels.length === 0),
    contextMenuButton(state.zoomedPanelId ? "Show all panes" : "Focus active pane", () => togglePaneZoom(), !panel),
    contextMenuButton("Reset split layout", resetActivePaneLayout, !panel || activeWorkspace()?.panels.length <= 1),
    contextMenuButton("Close other panes", () => closeOtherPanes(), !panel || activeWorkspace()?.panels.length <= 1, "danger"),
    contextMenuButton("Rename workspace", renameActiveWorkspace),
    contextMenuButton("Change workspace color", cycleWorkspaceColor),
    contextMenuButton("Change workspace folder", () => chooseWorkspaceFolder(), !activeWorkspace()),
    contextMenuButton("Open workspace folder", () => openWorkspaceFolder(), !activeWorkspace()?.cwd),
    contextMenuButton("New workspace from folder", () => createWorkspaceFromFolder()),
    contextMenuButton("Copy terminal selection", copyActiveTerminalSelection, panel?.type !== "terminal"),
    contextMenuButton("Paste to terminal", pasteClipboardToTerminal, panel?.type !== "terminal"),
    contextMenuButton("Clear active terminal", clearActiveTerminal, panel?.type !== "terminal"),
    contextMenuButton("Restart terminal", restartActiveTerminal, panel?.type !== "terminal"),
    contextMenuButton("Performance settings", () => openSettingsCategory("performance")),
    contextMenuButton("Apply speed preset", () => applySettingsPresetById("performance")),
    contextMenuButton("Actions settings", () => openSettingsCategory("actions")),
    contextMenuButton("Notifications", () => openInspector("notifications")),
    contextMenuButton("Session tools", () => openInspector("session")),
    contextMenuButton("Reset session", resetSession, false, "danger")
  );
  menu.replaceChildren(title, actions);
  menu.hidden = false;
  const rect = event.currentTarget.getBoundingClientRect();
  const x = Math.min(rect.left, window.innerWidth - 238);
  const y = Math.min(rect.bottom + 6, window.innerHeight - 288);
  menu.style.left = `${Math.max(8, x)}px`;
  menu.style.top = `${Math.max(8, y)}px`;
}

function contextMenuButton(label, action, disabled = false, tone = "") {
  const button = document.createElement("button");
  button.className = `context-action${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  button.textContent = label;
  button.disabled = disabled;
  button.onclick = () => {
    if (disabled) return;
    action();
    hideContextMenu();
  };
  return button;
}

function contextColorPicker(activeColor, onPick) {
  const wrapper = document.createElement("label");
  wrapper.className = "context-color-picker";
  const label = document.createElement("span");
  label.textContent = "Custom color";
  const input = document.createElement("input");
  input.type = "color";
  input.value = colorInputValue(activeColor);
  input.onchange = () => {
    onPick(input.value);
    hideContextMenu();
  };
  wrapper.append(label, input);
  return wrapper;
}

function showTextDialog({
  title,
  message = "",
  value = "",
  placeholder = "",
  confirmLabel = "Save",
  cancelLabel = "Cancel",
  multiline = false,
  readOnly = false
} = {}) {
  if (state.activeDialog) state.activeDialog.close(null);
  const previousFocus = document.activeElement;
  const overlay = document.createElement("div");
  overlay.className = "dialog-backdrop";
  overlay.innerHTML = `
    <div class="app-dialog" role="dialog" aria-modal="true">
      <div class="dialog-title"></div>
      <div class="dialog-message"></div>
      <div class="dialog-field"></div>
      <div class="dialog-actions">
        <button class="dialog-button dialog-cancel" type="button"></button>
        <button class="dialog-button primary dialog-confirm" type="button"></button>
      </div>
    </div>
  `;
  const titleNode = overlay.querySelector(".dialog-title");
  const messageNode = overlay.querySelector(".dialog-message");
  const field = overlay.querySelector(".dialog-field");
  const cancel = overlay.querySelector(".dialog-cancel");
  const confirm = overlay.querySelector(".dialog-confirm");
  titleNode.textContent = title || "cmux";
  messageNode.textContent = message;
  messageNode.hidden = !message;
  cancel.textContent = cancelLabel;
  confirm.textContent = confirmLabel;
  const input = document.createElement(multiline ? "textarea" : "input");
  input.className = "dialog-input";
  if (!multiline) input.type = "text";
  input.value = value || "";
  input.placeholder = placeholder;
  input.readOnly = readOnly;
  field.append(input);

  return new Promise((resolve) => {
    const cleanup = (result) => {
      overlay.remove();
      state.activeDialog = null;
      if (previousFocus?.focus) previousFocus.focus();
      resolve(result);
    };
    state.activeDialog = { close: cleanup };
    cancel.onclick = () => cleanup(null);
    confirm.onclick = () => cleanup(readOnly ? input.value : input.value.trim());
    overlay.addEventListener("mousedown", (event) => {
      if (event.target === overlay) cleanup(null);
    });
    overlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        cleanup(null);
      }
      if (event.key === "Enter" && (!multiline || event.ctrlKey)) {
        event.preventDefault();
        cleanup(readOnly ? input.value : input.value.trim());
      }
    });
    document.body.append(overlay);
    requestAnimationFrame(() => {
      input.focus();
      input.select();
    });
  });
}

function showConfirmDialog({
  title,
  message = "",
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  danger = false
} = {}) {
  if (state.activeDialog) state.activeDialog.close(false);
  const previousFocus = document.activeElement;
  const overlay = document.createElement("div");
  overlay.className = "dialog-backdrop";
  overlay.innerHTML = `
    <div class="app-dialog" role="dialog" aria-modal="true">
      <div class="dialog-title"></div>
      <div class="dialog-message"></div>
      <div class="dialog-actions">
        <button class="dialog-button dialog-cancel" type="button"></button>
        <button class="dialog-button primary dialog-confirm" type="button"></button>
      </div>
    </div>
  `;
  const titleNode = overlay.querySelector(".dialog-title");
  const messageNode = overlay.querySelector(".dialog-message");
  const cancel = overlay.querySelector(".dialog-cancel");
  const confirm = overlay.querySelector(".dialog-confirm");
  titleNode.textContent = title || "Confirm";
  messageNode.textContent = message;
  messageNode.hidden = !message;
  cancel.textContent = cancelLabel;
  confirm.textContent = confirmLabel;
  confirm.classList.toggle("danger", danger);

  return new Promise((resolve) => {
    const cleanup = (result) => {
      overlay.remove();
      state.activeDialog = null;
      if (previousFocus?.focus) previousFocus.focus();
      resolve(result);
    };
    state.activeDialog = { close: cleanup };
    cancel.onclick = () => cleanup(false);
    confirm.onclick = () => cleanup(true);
    overlay.addEventListener("mousedown", (event) => {
      if (event.target === overlay) cleanup(false);
    });
    overlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        cleanup(false);
      }
      if (event.key === "Enter") {
        event.preventDefault();
        cleanup(true);
      }
    });
    document.body.append(overlay);
    requestAnimationFrame(() => confirm.focus());
  });
}

async function renamePanel(panel) {
  const title = await showTextDialog({
    title: "Rename tab",
    value: panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal"),
    placeholder: "Tab name",
    confirmLabel: "Rename"
  });
  if (!title) return;
  updatePanel(panel.id, { title });
}

function duplicatePanel(panel) {
  if (panel.type === "browser") {
    createPanel("browser", "right", { workspaceId: panel.workspaceId, url: panel.url || state.settings.browserHomeUrl });
    return;
  }
  createPanel("terminal", "right", {
    workspaceId: panel.workspaceId,
    shellProfile: panel.shellProfile || state.settings.terminalProfile,
    shellPath: panel.shellPath || state.settings.terminalCustomShell
  });
}

function duplicateActivePanel() {
  const panel = activePanel();
  if (!panel) {
    toast("Open a pane to duplicate it.");
    return;
  }
  duplicatePanel(panel);
}

function movePanelLeft(workspace, index) {
  if (index <= 0) return;
  movePanelBefore(workspace.panels[index].id, workspace.panels[index - 1].id);
}

function movePanelRight(workspace, index) {
  if (index < 0 || index >= workspace.panels.length - 1) return;
  const afterNext = workspace.panels[index + 2];
  if (afterNext) {
    movePanelBefore(workspace.panels[index].id, afterNext.id);
  } else {
    movePanelToWorkspace(workspace.panels[index].id, workspace.id);
  }
}

function renderPalette() {
  elements.palette.classList.toggle("is-open", state.paletteOpen);
  elements.palette.setAttribute("aria-hidden", String(!state.paletteOpen));
  if (!state.paletteOpen) return;

  const query = normalizeSettingsQuery(elements.paletteInput.value);
  const matches = paletteEntries()
    .filter((entry) => paletteEntryMatches(entry, query))
    .sort((left, right) => paletteEntryScore(right, query) - paletteEntryScore(left, query));
  state.paletteIndex = Math.min(state.paletteIndex, Math.max(0, matches.length - 1));
  const nodes = matches.map((entry, index) => {
    const button = document.createElement("button");
    button.className = `palette-item${index === state.paletteIndex ? " is-selected" : ""}`;
    button.innerHTML = `
      <span class="palette-main">
        <span class="palette-label"></span>
        <span class="palette-meta"></span>
      </span>
      <span class="palette-shortcut"></span>
    `;
    button.querySelector(".palette-label").textContent = entry.label;
    button.querySelector(".palette-meta").textContent = entry.meta;
    button.querySelector(".palette-shortcut").textContent = entry.shortcut;
    button.onclick = () => runPaletteCommand(entry);
    return button;
  });
  if (nodes.length === 0) {
    const empty = document.createElement("div");
    empty.className = "palette-empty";
    empty.textContent = "No matching commands, workspaces, panes, or settings.";
    nodes.push(empty);
  }
  elements.paletteList.replaceChildren(...nodes);
}

function paletteEntryMatches(entry, query) {
  if (!query) return true;
  return query.split(/\s+/).every((token) => entry.search.includes(token));
}

function paletteEntryScore(entry, query) {
  if (!query) return 0;
  let score = 0;
  if (entry.search.includes(query)) score += 8;
  if (entry.search.startsWith(query)) score += 4;
  if (normalizeSettingsQuery(entry.label).includes(query)) score += 2;
  return score;
}

function paletteEntries() {
  const entries = commands.map((command) => ({
    id: command.id,
    label: command.label,
    meta: "Command",
    shortcut: command.shortcut,
    search: normalizeSettingsQuery(`${command.label} ${command.shortcut} command`),
    run: command.run
  }));
  for (const [workspaceIndex, workspace] of (state.data?.workspaces || []).entries()) {
    entries.push({
      id: `workspace.${workspace.id}`,
      label: workspace.title || "Workspace",
      meta: workspace.cwdShort || workspace.cwd || "",
      shortcut: "Workspace",
      search: normalizeSettingsQuery(`workspace ${workspaceIndex + 1} ${workspace.title} ${workspace.cwdShort} ${workspace.cwd}`),
      run: () => focusWorkspace(workspace.id)
    });
    if (workspace.cwd) {
      entries.push({
        id: `workspace.folder.${workspace.id}`,
        label: `Open folder: ${workspace.title || "Workspace"}`,
        meta: workspace.cwdShort || workspace.cwd,
        shortcut: "Folder",
        search: normalizeSettingsQuery(`open folder explorer directory workspace ${workspaceIndex + 1} ${workspace.title} ${workspace.cwdShort} ${workspace.cwd}`),
        run: () => openWorkspaceFolder(workspace)
      });
    }
    entries.push({
      id: `workspace.changeFolder.${workspace.id}`,
      label: `Change folder: ${workspace.title || "Workspace"}`,
      meta: workspace.cwdShort || workspace.cwd || "",
      shortcut: "Folder",
      search: normalizeSettingsQuery(`change choose set folder directory cwd workspace ${workspaceIndex + 1} ${workspace.title} ${workspace.cwdShort} ${workspace.cwd}`),
      run: () => chooseWorkspaceFolder(workspace)
    });
    for (const [panelIndex, panel] of workspace.panels.entries()) {
      const label = panel.type === "browser" ? hostnameOf(panel.url) : panel.title || "Terminal";
      entries.push({
        id: `panel.${panel.id}`,
        label,
        meta: `${workspace.title || "Workspace"} / ${panel.type === "browser" ? hostnameOf(panel.url) : panel.cwdShort || "~"}`,
        shortcut: panel.type === "browser" ? "Browser" : "Pane",
        search: normalizeSettingsQuery(`pane ${panelIndex + 1} workspace ${workspaceIndex + 1} panel tab ${label} ${panel.type} ${workspace.title} ${panel.cwdShort} ${panel.cwd} ${panel.url}`),
        run: async () => {
          if (workspace.id !== state.data?.activeWorkspaceId) await focusWorkspace(workspace.id);
          await focusPanel(panel.id);
        }
      });
    }
  }
  for (const [folderIndex, folder] of state.recentFolders.entries()) {
    const name = folderName(folder);
    const shortPath = shortFolderPath(folder);
    entries.push({
      id: `recentFolder.new.${folderIndex}`,
      label: `New workspace: ${name}`,
      meta: shortPath,
      shortcut: "Recent",
      search: normalizeSettingsQuery(`recent folder workspace new reopen ${folderIndex + 1} ${name} ${shortPath} ${folder}`),
      run: () => createWorkspaceFromFolderPath(folder)
    });
    entries.push({
      id: `recentFolder.use.${folderIndex}`,
      label: `Use folder: ${name}`,
      meta: shortPath,
      shortcut: "Recent",
      search: normalizeSettingsQuery(`recent folder workspace use current change choose ${folderIndex + 1} ${name} ${shortPath} ${folder}`),
      run: () => setWorkspaceFolderFromRecent(folder)
    });
  }
  for (const [id, label] of settingsCategories.filter(([id]) => id !== "all")) {
    entries.push({
      id: `settings.${id}`,
      label: `Settings: ${label}`,
      meta: "Settings category",
      shortcut: "Settings",
      search: normalizeSettingsQuery(`settings preferences customize ${label} ${id}`),
      run: () => openSettingsCategory(id)
    });
  }
  return entries;
}

function runPaletteCommand(entry) {
  state.paletteOpen = false;
  elements.paletteInput.value = "";
  renderPalette();
  entry.run();
}

async function createWorkspace(options = {}) {
  const workspace = await api("/api/workspaces", {
    method: "POST",
    body: JSON.stringify({
      title: options.title || `Workspace ${state.data.workspaces.length + 1}`,
      cwd: options.cwd
    })
  });
  if (options.cwd) rememberRecentFolder(workspace.cwd || options.cwd);
  await loadState();
  return workspace;
}

async function createWorkspaceFromFolder() {
  const folder = await pickWorkspaceFolder();
  if (!folder) return;
  await createWorkspaceFromFolderPath(folder);
}

async function createWorkspaceFromFolderPath(folder) {
  try {
    await createWorkspace({
      title: folderName(folder),
      cwd: folder
    });
    toast("Workspace created from folder.");
  } catch {
    toast("Folder could not be opened as a workspace.");
  }
}

async function pickWorkspaceFolder() {
  if (!window.cmuxNative?.pickWorkspaceFolder) {
    toast("Folder picker is available in the desktop app.");
    return "";
  }
  return await window.cmuxNative.pickWorkspaceFolder();
}

async function renameActiveWorkspace() {
  const workspace = activeWorkspace();
  if (!workspace) return;
  await renameWorkspaceById(workspace.id, workspace.title);
}

async function renameWorkspaceById(workspaceId, currentTitle = "") {
  const title = await showTextDialog({
    title: "Rename workspace",
    value: currentTitle,
    placeholder: "Workspace name",
    confirmLabel: "Rename"
  });
  if (!title) return;
  await renameWorkspaceTo(title, workspaceId);
}

async function renameWorkspaceTo(title, workspaceId = activeWorkspace()?.id) {
  const trimmed = String(title || "").trim();
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace || !trimmed || trimmed === workspace.title) return;
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ title: trimmed })
  });
}

async function cycleWorkspaceColor(workspaceId = activeWorkspace()?.id) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  const palette = state.data?.palette || [];
  if (!workspace || palette.length === 0) return;
  const currentIndex = Math.max(0, palette.indexOf(workspace.color));
  const color = palette[(currentIndex + 1) % palette.length];
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ color })
  });
}

async function openWorkspaceFolder(workspace = activeWorkspace()) {
  if (!workspace?.cwd) {
    toast("No workspace folder to open.");
    return;
  }
  await openFolderPath(workspace.cwd, "Workspace folder opened.");
}

async function openFolderPath(folderPath, successMessage = "Folder opened.") {
  if (!folderPath) {
    toast("No folder to open.");
    return;
  }
  if (!window.cmuxNative?.openPath) {
    toast("Open folder is available in the desktop app.");
    return;
  }
  const result = await window.cmuxNative.openPath(folderPath);
  const ok = result === true || result?.ok;
  toast(ok ? successMessage : "Folder could not be opened.");
}

async function chooseWorkspaceFolder(workspace = activeWorkspace()) {
  if (!workspace) return;
  const folder = await pickWorkspaceFolder();
  if (!folder) return;
  await setWorkspaceFolder(folder, workspace.id);
}

async function setWorkspaceFolder(cwd, workspaceId = activeWorkspace()?.id) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace || !cwd) return;
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ cwd })
  });
  rememberRecentFolder(cwd);
  await loadState();
  toast("Workspace folder updated.");
}

async function setWorkspaceFolderFromRecent(folder) {
  try {
    await setWorkspaceFolder(folder);
  } catch {
    toast("Folder could not be used for this workspace.");
  }
}

async function applyWorkspaceStarter(starterId, workspaceId = activeWorkspace()?.id) {
  const starter = workspaceStarters.find((candidate) => candidate.id === starterId);
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!starter || !workspace) {
    toast("No workspace available.");
    return;
  }
  clearPaneLayoutsForWorkspace(workspace);
  try {
    for (const type of starter.panels) {
      await createPanel(type, "right", {
        workspaceId: workspace.id,
        focus: false,
        reconcile: false,
        url: type === "browser" ? state.settings.browserHomeUrl : undefined
      });
    }
    await loadState();
    if (workspace.id !== state.data?.activeWorkspaceId) await focusWorkspace(workspace.id);
    toast(`${starter.label} added.`);
  } catch {
    await loadState();
    toast("Workspace starter could not be added.");
  }
}

async function setWorkspaceColor(color, workspaceId = activeWorkspace()?.id) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return;
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ color })
  });
}

async function closeActiveWorkspace() {
  const workspace = activeWorkspace();
  if (!workspace) return;
  await closeWorkspaceById(workspace.id);
}

async function closeWorkspaceById(workspaceId) {
  if (!workspaceId) return;
  await api(`/api/workspaces/${workspaceId}`, { method: "DELETE" });
}

async function createPanel(type, direction = "right", options = {}) {
  const workspace = options.workspaceId
    ? state.data?.workspaces.find((candidate) => candidate.id === options.workspaceId)
    : activeWorkspace();
  if (!workspace) return;
  const shellProfile = options.shellProfile || state.settings.terminalProfile;
  const shellPath = options.shellPath || state.settings.terminalCustomShell;
  clearPaneLayoutsForWorkspace(workspace);
  const createdPanel = await api("/api/panels", {
    method: "POST",
    body: JSON.stringify({
      workspaceId: workspace.id,
      type,
      direction,
      title: options.title,
      color: options.color,
      shellProfile: type === "terminal" ? shellProfile : undefined,
      shellPath: type === "terminal" && shellProfile === "custom" ? shellPath : undefined,
      cwd: options.cwd || workspace.cwd,
      url: type === "browser" ? normalizeUrl(options.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl) : undefined
    })
  });
  if (options.reconcile !== false) {
    await loadState();
    if (options.focus !== false && workspace.id !== state.data?.activeWorkspaceId) {
      await focusWorkspace(workspace.id);
    }
  }
  return createdPanel;
}

async function openBrowserPrompt(workspaceId = null) {
  const url = await showTextDialog({
    title: "Open browser",
    value: state.settings.browserHomeUrl,
    placeholder: "Search or URL",
    confirmLabel: "Open"
  });
  if (url === null) return;
  await createPanel("browser", "right", { url, workspaceId });
}

function refreshWorkspaceCounts(workspace) {
  if (!workspace) return;
  workspace.terminalCount = workspace.panels.filter((panel) => panel.type === "terminal").length;
  workspace.browserCount = workspace.panels.filter((panel) => panel.type === "browser").length;
}

function optimisticFocusWorkspace(workspaceId) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return false;
  if (state.data.activeWorkspaceId !== workspaceId) {
    state.data.activeWorkspaceId = workspaceId;
    render();
  }
  return true;
}

function optimisticFocusPanel(panelId) {
  const found = findPanelState(panelId);
  if (!found) return false;
  found.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = found.workspace.id;
  render();
  return true;
}

function optimisticClosePanel(panelId, renderNow = true) {
  const found = findPanelState(panelId);
  if (!found) return false;
  if (state.zoomedPanelId === panelId) state.zoomedPanelId = null;
  found.workspace.panels = found.workspace.panels.filter((candidate) => candidate.id !== panelId);
  found.workspace.activePanelId = found.workspace.panels[0]?.id || null;
  refreshWorkspaceCounts(found.workspace);
  if (renderNow) render();
  return true;
}

function optimisticUpdatePanel(panelId, updates = {}) {
  const found = findPanelState(panelId);
  if (!found) return false;
  let panelWorkspace = found.workspace;
  if (
    Object.hasOwn(updates, "workspaceId")
    || Object.hasOwn(updates, "beforePanelId")
    || Object.hasOwn(updates, "moveToEnd")
  ) {
    if (updates.beforePanelId === panelId) return false;
    const targetWorkspace = state.data?.workspaces.find((workspace) => workspace.id === updates.workspaceId) || found.workspace;
    found.workspace.panels = found.workspace.panels.filter((candidate) => candidate.id !== panelId);
    if (found.workspace.activePanelId === panelId) {
      found.workspace.activePanelId = found.workspace.panels[0]?.id || null;
    }
    found.panel.workspaceId = targetWorkspace.id;
    const insertIndex = updates.moveToEnd || !updates.beforePanelId
      ? -1
      : targetWorkspace.panels.findIndex((candidate) => candidate.id === updates.beforePanelId);
    targetWorkspace.panels.splice(insertIndex >= 0 ? insertIndex : targetWorkspace.panels.length, 0, found.panel);
    targetWorkspace.activePanelId = panelId;
    state.data.activeWorkspaceId = targetWorkspace.id;
    panelWorkspace = targetWorkspace;
    refreshWorkspaceCounts(found.workspace);
    if (targetWorkspace !== found.workspace) refreshWorkspaceCounts(targetWorkspace);
  }
  if (Object.hasOwn(updates, "title")) {
    const title = String(updates.title || "").trim();
    if (title) found.panel.title = title.slice(0, 80);
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    found.panel.color = isAllowedUiColor(color, state.data?.palette || accentOptions) ? color : "";
  }
  if (Object.hasOwn(updates, "url") && found.panel.type === "browser") {
    found.panel.url = normalizeUrl(updates.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  }
  if (updates.direction === "down" || updates.direction === "right") {
    panelWorkspace.splitDirection = updates.direction;
  }
  render();
  return true;
}

function closedPanelSnapshot(panelId) {
  const found = findPanelState(panelId);
  if (!found) return null;
  return {
    workspaceId: found.workspace.id,
    workspaceTitle: found.workspace.title || "Workspace",
    type: found.panel.type,
    title: found.panel.title || (found.panel.type === "browser" ? "Browser" : "Terminal"),
    color: found.panel.color || "",
    cwd: found.panel.cwd || found.workspace.cwd || "",
    shellProfile: found.panel.shellProfile || state.settings.terminalProfile,
    shellPath: found.panel.shellPath || "",
    url: found.panel.url || state.settings.browserHomeUrl
  };
}

function rememberClosedPanel(panelId) {
  const snapshot = closedPanelSnapshot(panelId);
  if (!snapshot) return;
  state.closedPanels.unshift(snapshot);
  state.closedPanels = state.closedPanels.slice(0, closedPanelLimit);
}

async function reopenClosedPanel() {
  const snapshot = state.closedPanels.shift();
  if (!snapshot) {
    toast("No closed pane to reopen.");
    return;
  }
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === snapshot.workspaceId) || activeWorkspace();
  if (!workspace) {
    state.closedPanels.unshift(snapshot);
    toast("No workspace available.");
    return;
  }
  try {
    const created = await createPanel(snapshot.type, "right", {
      workspaceId: workspace.id,
      title: snapshot.title,
      color: snapshot.color,
      cwd: snapshot.cwd || workspace.cwd,
      shellProfile: snapshot.shellProfile,
      shellPath: snapshot.shellPath,
      url: snapshot.url
    });
    toast(`Reopened ${created?.type === "browser" ? "browser" : "terminal"} pane.`);
  } catch {
    state.closedPanels.unshift(snapshot);
    toast("Could not reopen pane.");
  }
}

async function closePanel(panelId) {
  rememberClosedPanel(panelId);
  optimisticClosePanel(panelId);
  try {
    await api(`/api/panels/${panelId}`, { method: "DELETE" });
    await loadState();
  } catch {
    await loadState();
  }
}

async function closePanelsById(panelIds) {
  const ids = [...new Set(panelIds.filter(Boolean))];
  if (ids.length === 0) return;
  let changed = false;
  for (const panelId of ids) {
    rememberClosedPanel(panelId);
    changed = optimisticClosePanel(panelId, false) || changed;
  }
  if (changed) render();
  try {
    await Promise.all(ids.map((panelId) => api(`/api/panels/${panelId}`, { method: "DELETE" })));
  } finally {
    await loadState();
  }
}

async function closeOtherPanes(panelId = activePanel()?.id) {
  const found = findPanelState(panelId);
  if (!found) return;
  await closePanelsById(found.workspace.panels
    .filter((candidate) => candidate.id !== panelId)
    .map((candidate) => candidate.id));
}

async function closePanesToRight(panelId = activePanel()?.id) {
  const found = findPanelState(panelId);
  if (!found) return;
  const index = found.workspace.panels.findIndex((candidate) => candidate.id === panelId);
  await closePanelsById(found.workspace.panels.slice(index + 1).map((candidate) => candidate.id));
}

async function updatePanel(panelId, updates) {
  optimisticUpdatePanel(panelId, updates);
  try {
    await api(`/api/panels/${panelId}`, {
      method: "PATCH",
      body: JSON.stringify(updates)
    });
    await loadState();
  } catch {
    await loadState();
  }
}

async function movePanelBefore(panelId, beforePanelId) {
  const workspace = activeWorkspace();
  if (!workspace || !panelId || !beforePanelId || panelId === beforePanelId) return;
  await updatePanel(panelId, { workspaceId: workspace.id, beforePanelId });
}

async function movePanelRelative(panelId, targetPanelId, placement) {
  const found = findPanelState(targetPanelId);
  if (!found || !panelId || !targetPanelId || panelId === targetPanelId) return;
  const direction = placement === "top" || placement === "bottom" ? "down" : "right";
  const targetIndex = found.workspace.panels.findIndex((candidate) => candidate.id === targetPanelId);
  const beforeTarget = placement === "left" || placement === "top";
  if (beforeTarget) {
    await updatePanel(panelId, { workspaceId: found.workspace.id, beforePanelId: targetPanelId, direction });
    return;
  }
  const nextPanel = found.workspace.panels[targetIndex + 1];
  if (nextPanel && nextPanel.id !== panelId) {
    await updatePanel(panelId, { workspaceId: found.workspace.id, beforePanelId: nextPanel.id, direction });
  } else {
    await updatePanel(panelId, { workspaceId: found.workspace.id, moveToEnd: true, direction });
  }
}

async function movePanelToWorkspace(panelId, workspaceId) {
  if (!panelId || !workspaceId) return;
  await updatePanel(panelId, { workspaceId, moveToEnd: true });
}

async function focusWorkspace(workspaceId) {
  if (!optimisticFocusWorkspace(workspaceId)) return;
  try {
    await api(`/api/workspaces/${workspaceId}/focus`, { method: "POST" });
    await loadState();
  } catch {
    await loadState();
  }
}

async function focusPanel(panelId) {
  const found = findPanelState(panelId);
  if (found && state.data?.activeWorkspaceId === found.workspace.id && found.workspace.activePanelId === panelId) {
    focusTerminalSession(panelId);
    return;
  }
  if (!optimisticFocusPanel(panelId)) return;
  try {
    await api(`/api/panels/${panelId}/focus`, { method: "POST" });
    await loadState();
  } catch {
    await loadState();
    return;
  }
  focusTerminalSession(panelId);
}

function focusTerminalSession(panelId) {
  const terminal = state.terminals.get(panelId);
  if (terminal) setTimeout(() => terminal.term.focus(), 20);
}

function togglePaneZoom(panelId = activePanel()?.id) {
  if (!panelId) return;
  const found = findPanelState(panelId);
  if (!found) return;
  const zoomingIn = state.zoomedPanelId !== panelId;
  state.zoomedPanelId = zoomingIn ? panelId : null;
  found.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = found.workspace.id;
  render();
  focusTerminalSession(panelId);
  const session = state.terminals.get(panelId);
  if (session) setTimeout(() => scheduleFitTerminal(session, true), 30);
}

function toggleSidebar() {
  state.sidebarCollapsed = !state.sidebarCollapsed;
  render();
}

function openInspector(mode) {
  state.inspectorMode = state.inspectorMode === mode ? null : mode;
  updateRailButtons();
  render();
}

function openSettingsCategory(category = "quick") {
  state.inspectorMode = "settings";
  state.settingsCategory = settingsCategories.some(([id]) => id === category) ? category : "quick";
  state.settingsQuery = "";
  updateRailButtons();
  render();
}

function updateRailButtons() {
  document.getElementById("workspacesRailButton").classList.toggle("is-active", !state.inspectorMode);
  document.getElementById("notificationsRailButton").classList.toggle("is-active", state.inspectorMode === "notifications");
  document.getElementById("sessionsRailButton").classList.toggle("is-active", state.inspectorMode === "session");
  document.getElementById("settingsRailButton").classList.toggle("is-active", state.inspectorMode === "settings");
}

async function resetSession() {
  await api("/api/session/reset", { method: "POST" });
  toast("Session reset.");
}

async function simulateNotification() {
  await api("/api/notify", {
    method: "POST",
    body: JSON.stringify({ message: "Agent turn complete. Review output when ready." })
  });
  openInspector("notifications");
}

function resolveTerminalPanel(panel = activePanel()) {
  const found = panel?.id ? findPanelState(panel.id) : null;
  const candidate = found?.panel || panel;
  return candidate?.type === "terminal" ? candidate : null;
}

function clearTerminalPanel(panel = activePanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  const terminal = terminalPanel ? state.terminals.get(terminalPanel.id) : null;
  if (!terminal) return false;
  terminal.term.clear();
  return true;
}

function clearActiveTerminal() {
  clearTerminalPanel();
}

function resetActivePaneLayout() {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1) {
    toast("Open another pane to reset split layout.");
    return;
  }
  clearPaneLayoutsForWorkspace(workspace);
  requestAnimationFrame(() => {
    for (const panel of workspace.panels) {
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal, true);
    }
  });
  toast("Split layout reset.");
}

function changeTerminalFontSize(delta) {
  updateSettings({ terminalFontSize: state.terminalFontSize + delta });
  toast(`Terminal text ${state.terminalFontSize}px`);
}

async function writeClipboardText(text) {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Fall back to the native bridge below.
  }
  if (window.cmuxNative?.writeClipboard) {
    await window.cmuxNative.writeClipboard(text);
    return true;
  }
  return false;
}

async function readClipboardText() {
  try {
    if (navigator.clipboard?.readText) return await navigator.clipboard.readText();
  } catch {
    // Fall back to the native bridge below.
  }
  if (window.cmuxNative?.readClipboard) return await window.cmuxNative.readClipboard();
  return "";
}

async function sendTerminalInput(panelId, text) {
  const payload = String(text ?? "");
  if (!payload) return false;
  const session = state.terminals.get(panelId);
  if (session?.socket?.readyState === WebSocket.OPEN) {
    session.socket.send(JSON.stringify({ type: "input", data: payload }));
    return true;
  }
  try {
    const result = await api("/api/input", {
      method: "POST",
      body: JSON.stringify({ panelId, text: payload })
    });
    return Boolean(result.ok);
  } catch {
    return false;
  }
}

async function copyActiveTerminalSelection(panel = activePanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Focus a terminal pane first.");
    return false;
  }
  const selection = state.terminals.get(terminalPanel.id)?.term?.getSelection?.() || "";
  if (!selection) {
    toast("Select terminal text first.");
    focusTerminalSession(terminalPanel.id);
    return false;
  }
  if (await writeClipboardText(selection)) {
    toast("Terminal selection copied.");
    return true;
  }
  toast("Clipboard is unavailable.");
  return false;
}

async function pasteClipboardToTerminal(panel = activePanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Focus a terminal pane first.");
    return false;
  }
  const clipboard = await readClipboardText();
  if (!clipboard) {
    toast("Clipboard is empty.");
    focusTerminalSession(terminalPanel.id);
    return false;
  }
  const ok = await sendTerminalInput(terminalPanel.id, clipboard);
  if (!ok) {
    toast("Terminal is not ready.");
    return false;
  }
  focusPanel(terminalPanel.id);
  focusTerminalSession(terminalPanel.id);
  return true;
}

async function exportSettings() {
  const payload = JSON.stringify(state.settings, null, 2);
  if (await writeClipboardText(payload)) {
    toast("Settings copied to clipboard.");
    return;
  }
  await showTextDialog({
    title: "Settings JSON",
    message: "Clipboard access is unavailable. The current settings are shown below.",
    value: payload,
    confirmLabel: "Close",
    multiline: true,
    readOnly: true
  });
}

async function importSettings() {
  const clipboard = await readClipboardText();
  const suggested = clipboard.trim().startsWith("{") ? clipboard : "";
  const raw = await showTextDialog({
    title: "Import settings",
    message: "Paste exported cmux Windows settings JSON.",
    value: suggested,
    placeholder: "{ ... }",
    confirmLabel: "Import",
    multiline: true
  });
  if (raw === null) return;
  try {
    state.settings = normalizeSettings(JSON.parse(raw));
    state.terminalFontSize = state.settings.terminalFontSize;
    saveSettings();
    applySettings();
    scheduleTerminalAppearanceRefresh();
    renderSettingsInspector();
    toast("Settings imported.");
  } catch {
    toast("Settings import failed.");
  }
}

async function resetSettings() {
  if (!await showConfirmDialog({
    title: "Reset settings",
    message: "Restore cmux Windows settings to defaults.",
    confirmLabel: "Reset",
    danger: true
  })) return;
  state.settings = normalizeSettings(defaultSettings);
  state.terminalFontSize = state.settings.terminalFontSize;
  saveSettings();
  applySettings();
  scheduleTerminalAppearanceRefresh();
  renderSettingsInspector();
  toast("Settings reset.");
}

async function restartActiveTerminal() {
  const panel = activePanel();
  if (panel?.type === "terminal") await restartPanel(panel.id);
}

async function restartPanel(panelId) {
  cleanupPanel(panelId);
  await api(`/api/panels/${panelId}/restart`, { method: "POST" });
  await loadState();
}

async function closeActivePanel() {
  const panel = activePanel();
  if (panel) await closePanel(panel.id);
}

function toast(message) {
  const node = document.createElement("div");
  node.className = "toast";
  node.textContent = message;
  elements.toastRegion.appendChild(node);
  setTimeout(() => node.remove(), 3200);
}

function isFormEditableTarget(target) {
  const element = target?.nodeType === Node.ELEMENT_NODE ? target : target?.parentElement;
  if (!element || element.closest(".terminal-host")) return false;
  return Boolean(
    element.isContentEditable
    || element.closest("input, textarea, select, [contenteditable='true'], [contenteditable='plaintext-only']")
  );
}

function announceNewAttention(previous, next) {
  if (!previous || !next) return;
  const oldAttention = new Set(previous.workspaces.flatMap((workspace) =>
    workspace.panels.filter((panel) => panel.needsAttention).map((panel) => panel.id)
  ));
  for (const workspace of next.workspaces) {
    for (const panel of workspace.panels) {
      if (panel.needsAttention && !oldAttention.has(panel.id)) {
        toast(panel.notificationText || `${panel.title} needs attention`);
      }
    }
  }
}

document.getElementById("newWorkspaceButton").onclick = () => createWorkspace();
document.getElementById("resetSessionButton").onclick = () => resetSession();
document.getElementById("newTerminalButton").onclick = () => createPanel("terminal", "right");
document.getElementById("splitRightButton").onclick = () => createPanel("terminal", "right");
document.getElementById("splitDownButton").onclick = () => createPanel("terminal", "down");
document.getElementById("newBrowserButton").onclick = () => openBrowserPrompt();
document.getElementById("toolsMenuButton").onclick = showToolbarMenu;
document.getElementById("settingsButton").onclick = () => openInspector("settings");
document.getElementById("renameWorkspaceButton").onclick = () => renameActiveWorkspace();
document.getElementById("colorWorkspaceButton").onclick = () => cycleWorkspaceColor();
document.getElementById("notifyButton").onclick = () => simulateNotification();
document.getElementById("toggleSidebarButton").onclick = () => toggleSidebar();
document.getElementById("paletteButton").onclick = () => {
  state.paletteOpen = true;
  renderPalette();
  setTimeout(() => elements.paletteInput.focus(), 0);
};
document.getElementById("notificationsRailButton").onclick = () => openInspector("notifications");
document.getElementById("sessionsRailButton").onclick = () => openInspector("session");
document.getElementById("settingsRailButton").onclick = () => openInspector("settings");
document.getElementById("workspacesRailButton").onclick = () => {
  state.inspectorMode = null;
  updateRailButtons();
  render();
};
document.getElementById("closeInspectorButton").onclick = () => {
  state.inspectorMode = null;
  updateRailButtons();
  render();
};
document.getElementById("minimizeWindowButton").onclick = () => window.cmuxNative?.minimizeWindow?.();
document.getElementById("maximizeWindowButton").onclick = async () => {
  const maximized = await window.cmuxNative?.toggleMaximizeWindow?.();
  updateMaximizeButton(Boolean(maximized));
};
document.getElementById("closeWindowButton").onclick = () => window.cmuxNative?.closeWindow?.();

elements.paletteInput.addEventListener("input", renderPalette);
elements.paletteInput.addEventListener("keydown", (event) => {
  const count = elements.paletteList.children.length;
  if (event.key === "ArrowDown") {
    event.preventDefault();
    state.paletteIndex = Math.min(count - 1, state.paletteIndex + 1);
    renderPalette();
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    state.paletteIndex = Math.max(0, state.paletteIndex - 1);
    renderPalette();
  }
  if (event.key === "Enter") {
    event.preventDefault();
    elements.paletteList.children[state.paletteIndex]?.click();
  }
  if (event.key === "Escape") {
    state.paletteOpen = false;
    renderPalette();
  }
});

window.addEventListener("keydown", (event) => {
  const key = event.key.toLowerCase();
  if (state.activeDialog) return;
  const editingText = isFormEditableTarget(event.target);
  if (event.key === "Escape" && state.contextMenu && !state.contextMenu.hidden) {
    hideContextMenu();
  } else if (!editingText && event.ctrlKey && event.shiftKey && key === "c") {
    event.preventDefault();
    copyActiveTerminalSelection();
  } else if (!editingText && event.ctrlKey && event.shiftKey && key === "v") {
    event.preventDefault();
    pasteClipboardToTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "p") {
    event.preventDefault();
    state.paletteOpen = !state.paletteOpen;
    renderPalette();
    if (state.paletteOpen) setTimeout(() => elements.paletteInput.focus(), 0);
  } else if (event.ctrlKey && key === "n") {
    event.preventDefault();
    createWorkspace();
  } else if (event.ctrlKey && event.shiftKey && key === "t") {
    event.preventDefault();
    reopenClosedPanel();
  } else if (event.ctrlKey && key === "t") {
    event.preventDefault();
    createPanel("terminal", "right");
  } else if (event.ctrlKey && event.shiftKey && key === "l") {
    event.preventDefault();
    openBrowserPrompt();
  } else if (event.ctrlKey && key === "i") {
    event.preventDefault();
    openInspector("notifications");
  } else if (event.ctrlKey && key === "b") {
    event.preventDefault();
    toggleSidebar();
  } else if (event.ctrlKey && event.key === ",") {
    event.preventDefault();
    openInspector("settings");
  } else if (event.ctrlKey && key === "k") {
    event.preventDefault();
    clearActiveTerminal();
  } else if (event.ctrlKey && (event.key === "=" || event.key === "+")) {
    event.preventDefault();
    changeTerminalFontSize(1);
  } else if (event.ctrlKey && event.key === "-") {
    event.preventDefault();
    changeTerminalFontSize(-1);
  } else if (event.ctrlKey && event.shiftKey && key === "r") {
    event.preventDefault();
    restartActiveTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "m") {
    event.preventDefault();
    togglePaneZoom();
  } else if (event.ctrlKey && key === "w") {
    const workspace = activeWorkspace();
    if (workspace?.activePanelId) {
      event.preventDefault();
      closePanel(workspace.activePanelId);
    }
  }
});

elements.sidebar.addEventListener("pointerdown", startSidebarResize);
elements.inspector.addEventListener("pointerdown", startInspectorResize);
new MutationObserver(scheduleVisiblePaneLayoutApply).observe(elements.paneGrid, {
  childList: true,
  subtree: true
});
window.addEventListener("pointermove", (event) => {
  continuePaneResize(event);
  continueSidebarResize(event);
  continueInspectorResize(event);
});
window.addEventListener("pointerup", (event) => {
  finishPaneResize(event);
  finishSidebarResize(event);
  finishInspectorResize(event);
});
window.addEventListener("pointercancel", (event) => {
  finishPaneResize(event);
  finishSidebarResize(event);
  finishInspectorResize(event);
});
document.addEventListener("click", (event) => {
  if (state.contextMenu && !state.contextMenu.hidden && !state.contextMenu.contains(event.target)) {
    hideContextMenu();
  }
});
document.addEventListener("dragend", clearAllDropTargets);
document.addEventListener("drop", clearAllDropTargets);
window.addEventListener("beforeunload", flushSettingsSave);

function updateMaximizeButton(maximized) {
  if (!elements.maximizeWindowButton) return;
  elements.maximizeWindowButton.textContent = maximized ? "❐" : "□";
  elements.maximizeWindowButton.title = maximized ? "Restore" : "Maximize";
}

if (window.cmuxNative?.isWindowMaximized) {
  window.cmuxNative.isWindowMaximized().then(updateMaximizeButton);
}
if (window.cmuxNative?.onWindowState) {
  window.cmuxNative.onWindowState((windowState) => updateMaximizeButton(Boolean(windowState.maximized)));
}

if (window.cmuxNative?.onCommand) {
  window.cmuxNative.onCommand((commandId) => {
    if (commandId === "palette.toggle") {
      state.paletteOpen = !state.paletteOpen;
      renderPalette();
      if (state.paletteOpen) setTimeout(() => elements.paletteInput.focus(), 0);
      return;
    }
    const command = commands.find((candidate) => candidate.id === commandId);
    if (command) command.run();
  });
}

applySettings();
loadState();
connectEvents();
