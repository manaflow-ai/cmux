import {
  accentOptions,
  backgroundPresets,
  defaultSettings,
  paneHeaderOptions,
  settingsCategories,
  settingsPresets,
  sidebarDetailOptions,
  sidebarFooterOptions,
  terminalAppearanceKeys,
  terminalColorDefaults,
  terminalColorPresets,
  terminalCursorStyles,
  terminalFontOptions,
  terminalProfiles,
  tabSizeOptions,
  themePreviewOptions,
  titleDetailOptions,
  toolbarModeOptions,
  themeOptions
} from "./config.js";
import {
  hostnameOf,
  normalizeBrowserPageUrl,
  normalizeUrl
} from "./browser-utils.js";
import { createAppearancePreview } from "./appearance-preview.js";
import {
  replaceChildrenIfChanged,
  setClassNameIfChanged,
  setDatasetIfChanged,
  setHiddenIfChanged,
  setStylePropertyIfChanged,
  setTextIfChanged,
  setTitleIfChanged,
  toggleClassIfChanged
} from "./dom-utils.js";

const backgroundPresetMap = new Map(backgroundPresets.map((preset) => [preset.value, preset]));
const terminalFontStacks = new Map(terminalFontOptions.map(([id, , stack]) => [id, stack]));
const tabSizeMetrics = new Map([
  ["compact", { min: 88, basis: 124, max: 174 }],
  ["balanced", { min: 104, basis: 160, max: 220 }],
  ["roomy", { min: 136, basis: 210, max: 292 }]
]);
const workspaceColorOptions = [...new Set([
  ...accentOptions,
  "oklch(62% 0.22 255)",
  "oklch(76% 0.15 82)"
])];
const TerminalConstructor = window.Terminal;
const FitAddonConstructor = window.FitAddon?.FitAddon;
const WebLinksAddonConstructor = window.WebLinksAddon?.WebLinksAddon;
const SearchAddonConstructor = window.SearchAddon?.SearchAddon;
const terminalOutputChunkSize = 32768;
const terminalOutputPerformanceChunkSize = 16384;
const terminalOutputBacklogThreshold = 262144;
const renderSlowFrameMs = 24;
const renderVerySlowFrameMs = 72;
const renderSlowFrameTriggerCount = 4;
const appearancePreviewKeys = new Set([
  "theme",
  "accent",
  "backgroundImage",
  "backgroundOpacity",
  "terminalFontFamily",
  "terminalBackground",
  "terminalForeground",
  "terminalCursorColor"
]);
const terminalSettingsPreviewKeys = new Set([
  "terminalFontFamily",
  "terminalFontSize",
  "terminalLineHeight",
  "terminalPadding",
  "terminalScrollback",
  "terminalCursorStyle",
  "terminalCursorBlink",
  "terminalBackground",
  "terminalForeground",
  "terminalCursorColor"
]);
const layoutSettingsPreviewKeys = new Set([
  "density",
  "paneHeaderMode",
  "sidebarDetailMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "titleDetailMode",
  "showTabs",
  "showStatusbar",
  "sidebarWidth",
  "inspectorWidth",
  "performanceMode"
]);
const terminalSearchDecorations = {
  matchBackground: "#5f4b1a",
  activeMatchBackground: "#9d6b20",
  matchOverviewRuler: "#8f7a35",
  activeMatchColorOverviewRuler: "#d59a3d",
  matchBorder: "#9b7a32",
  activeMatchBorder: "#ffd166"
};
const paneLayoutStorageKey = "cmux.paneLayout";
const recentFoldersStorageKey = "cmux.recentWorkspaceFolders";
const recentCommandsStorageKey = "cmux.recentTerminalCommands";
const recentBrowserPagesStorageKey = "cmux.recentBrowserPages";
const customCommandSnippetsStorageKey = "cmux.customTerminalCommandSnippets";
const savedSettingsProfilesStorageKey = "cmux.savedSettingsProfiles";
const workspaceBlueprintsStorageKey = "cmux.workspaceBlueprints";
const customColorPaletteStorageKey = "cmux.customColorPalette";
const savedBackgroundImagesStorageKey = "cmux.savedBackgroundImages";
const recentFoldersLimit = 8;
const recentCommandsLimit = 8;
const recentBrowserPagesLimit = 10;
const customCommandSnippetsLimit = 20;
const savedSettingsProfilesLimit = 12;
const workspaceBlueprintsLimit = 12;
const workspaceBlueprintPanelLimit = 8;
const customColorPaletteLimit = 18;
const savedBackgroundImagesLimit = 12;
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

const paneLayoutPresets = [
  {
    id: "equal",
    label: "Equal",
    body: "Even sizes in the current split direction.",
    mode: "equal",
    direction: ""
  },
  {
    id: "sideBySide",
    label: "Side by side",
    body: "Equal columns for comparing panes.",
    mode: "equal",
    direction: "right"
  },
  {
    id: "stacked",
    label: "Stacked",
    body: "Equal rows for logs and output.",
    mode: "equal",
    direction: "down"
  },
  {
    id: "activeWide",
    label: "Active wide",
    body: "Give the active pane more width.",
    mode: "active",
    direction: "right"
  },
  {
    id: "activeTall",
    label: "Active tall",
    body: "Give the active pane more height.",
    mode: "active",
    direction: "down"
  }
];

const builtInTerminalCommandSnippets = [
  { id: "listFiles", label: "List Workspace Files", command: "dir" },
  { id: "gitStatus", label: "Git Status", command: "git status" },
  { id: "gitPull", label: "Git Pull", command: "git pull --ff-only" },
  { id: "gitPush", label: "Git Push", command: "git push" },
  { id: "npmScripts", label: "Show NPM Scripts", command: "npm run" },
  { id: "ghPrStatus", label: "GH PR Status", command: "gh pr status" },
  { id: "ghPrChecks", label: "GH PR Checks", command: "gh pr checks" },
  { id: "ghPrViewWeb", label: "GH PR View in Browser", command: "gh pr view --web" },
  { id: "ghPrMergeHelp", label: "GH PR Merge Help", command: "gh pr merge --help" }
];

const initialSettings = loadSettings();

const state = {
  data: null,
  dataSignature: "",
  sidebarCollapsed: false,
  inspectorMode: null,
  terminals: new Map(),
  browserViews: new Map(),
  paneCache: new Map(),
  paneLayouts: loadPaneLayouts(),
  recentFolders: loadRecentFolders(),
  recentCommands: loadRecentCommands(),
  recentBrowserPages: loadRecentBrowserPages(),
  customCommandSnippets: loadCustomCommandSnippets(),
  savedSettingsProfiles: loadSavedSettingsProfiles(),
  workspaceBlueprints: loadWorkspaceBlueprints(),
  customColorPalette: loadCustomColorPalette(),
  savedBackgroundImages: loadSavedBackgroundImages(),
  closedPanels: [],
  workspaceRows: new Map(),
  surfaceTabButtons: new Map(),
  newTabButton: null,
  paletteOpen: false,
  paletteIndex: 0,
  paletteRenderFrame: 0,
  paletteRenderTimer: 0,
  paletteListSignature: "",
  dragPanelId: null,
  zoomedPanelId: null,
  contextMenu: null,
  activeDialog: null,
  uiOperations: new Map(),
  pendingFocusSync: null,
  focusSyncTimer: 0,
  focusSyncRevision: 0,
  pendingBrowserUrlSync: new Map(),
  browserUrlSyncTimer: 0,
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
  appearancePreviewFrame: 0,
  terminalSettingsPreviewFrame: 0,
  layoutSettingsPreviewFrame: 0,
  settingsFilterFrame: 0,
  renderStats: {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0,
    slowCount: 0,
    skippedRenders: 0,
    browserUrlRenderSkips: 0,
    guardActivations: 0
  },
  terminalOutputStats: {
    currentQueued: 0,
    maxQueued: 0,
    writtenBytes: 0,
    chunks: 0,
    lastChunk: 0
  },
  performanceGuardTriggered: false,
  performanceGuardReason: "",
  appliedSettingsSignature: "",
  settings: initialSettings,
  settingsCategory: "quick",
  settingsQuery: "",
  settingsInspectorSignature: "",
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
  if (isSafeCustomColor(color)) return color.toLowerCase();
  return palette.includes(color) ? color : fallback;
}

function colorInputValue(value, fallback = "#5d8cff") {
  const color = String(value || "").trim();
  return isSafeCustomColor(color) ? color : fallback;
}

function normalizeCustomPaletteColor(value) {
  const color = String(value || "").trim().toLowerCase();
  return isSafeCustomColor(color) ? color : "";
}

function uniqueColors(colors = []) {
  const seen = new Set();
  const result = [];
  for (const color of colors) {
    const value = String(color || "").trim();
    const key = value.toLowerCase();
    if (!value || seen.has(key)) continue;
    seen.add(key);
    result.push(value);
  }
  return result;
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
  if (!paneHeaderOptions.some(([id]) => id === next.paneHeaderMode)) next.paneHeaderMode = defaultSettings.paneHeaderMode;
  if (!sidebarDetailOptions.some(([id]) => id === next.sidebarDetailMode)) next.sidebarDetailMode = defaultSettings.sidebarDetailMode;
  if (!sidebarFooterOptions.some(([id]) => id === next.sidebarFooterMode)) next.sidebarFooterMode = defaultSettings.sidebarFooterMode;
  if (!toolbarModeOptions.some(([id]) => id === next.toolbarMode)) {
    next.toolbarMode = parsed.showAdvanced ? "expanded" : defaultSettings.toolbarMode;
  }
  if (!tabSizeOptions.some(([id]) => id === next.tabSize)) next.tabSize = defaultSettings.tabSize;
  if (!titleDetailOptions.some(([id]) => id === next.titleDetailMode)) next.titleDetailMode = defaultSettings.titleDetailMode;
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
  next.adaptivePerformance = next.adaptivePerformance !== false;
  next.reduceMotion = Boolean(next.reduceMotion);
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

function isCustomBackgroundImage(value) {
  const url = normalizedImageUrl(value);
  return Boolean(url && !url.startsWith("preset:"));
}

function backgroundImageUrl(value) {
  const url = normalizedImageUrl(value);
  if (/^file:/i.test(url)) return `/_cmux/local-image?url=${encodeURIComponent(url)}`;
  return url;
}

function backgroundCss(value) {
  const normalized = normalizeBackgroundValue(value);
  if (!normalized) return "none";
  const preset = backgroundPresetMap.get(normalized);
  if (preset) return preset.css;
  const url = backgroundImageUrl(normalized);
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

function fileNameFromUrl(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const url = new URL(raw);
    const pathname = decodeURIComponent(url.pathname || "");
    const parts = pathname.split(/[\\/]+/).filter(Boolean);
    return parts.at(-1) || url.hostname || "";
  } catch {
    const parts = raw.split(/[\\/]+/).filter(Boolean);
    return parts.at(-1) || raw;
  }
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

function normalizeTerminalCommand(command) {
  return String(command || "").replace(/\r?\n/g, " ").trim().slice(0, 1000);
}

function loadRecentCommands() {
  try {
    const parsed = JSON.parse(localStorage.getItem(recentCommandsStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const unique = [];
    const seen = new Set();
    for (const entry of parsed) {
      const command = normalizeTerminalCommand(entry);
      const key = command.toLowerCase();
      if (!command || seen.has(key)) continue;
      seen.add(key);
      unique.push(command);
      if (unique.length >= recentCommandsLimit) break;
    }
    return unique;
  } catch {
    return [];
  }
}

function saveRecentCommands() {
  localStorage.setItem(recentCommandsStorageKey, JSON.stringify(state.recentCommands));
}

function rememberRecentCommand(command) {
  const normalized = normalizeTerminalCommand(command);
  if (!normalized) return;
  const key = normalized.toLowerCase();
  state.recentCommands = [
    normalized,
    ...state.recentCommands.filter((candidate) => candidate.toLowerCase() !== key)
  ].slice(0, recentCommandsLimit);
  saveRecentCommands();
}

function clearRecentCommands() {
  state.recentCommands = [];
  saveRecentCommands();
  renderSettingsInspector();
  toast("Recent commands cleared.");
}

function loadRecentBrowserPages() {
  try {
    const parsed = JSON.parse(localStorage.getItem(recentBrowserPagesStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const unique = [];
    const seen = new Set();
    for (const entry of parsed) {
      const url = normalizeBrowserPageUrl(entry);
      const key = url.toLowerCase();
      if (!url || seen.has(key)) continue;
      seen.add(key);
      unique.push(url);
      if (unique.length >= recentBrowserPagesLimit) break;
    }
    return unique;
  } catch {
    return [];
  }
}

function saveRecentBrowserPages() {
  localStorage.setItem(recentBrowserPagesStorageKey, JSON.stringify(state.recentBrowserPages));
}

function rememberRecentBrowserPage(value) {
  const url = normalizeBrowserPageUrl(value);
  if (!url) return;
  const key = url.toLowerCase();
  const nextPages = [
    url,
    ...state.recentBrowserPages.filter((candidate) => candidate.toLowerCase() !== key)
  ].slice(0, recentBrowserPagesLimit);
  if (nextPages.length === state.recentBrowserPages.length && nextPages.every((page, index) => page === state.recentBrowserPages[index])) {
    return;
  }
  state.recentBrowserPages = nextPages;
  saveRecentBrowserPages();
  if (state.inspectorMode === "settings" && state.settingsCategory === "browser") {
    renderSettingsInspector();
  }
}

function clearRecentBrowserPages() {
  state.recentBrowserPages = [];
  saveRecentBrowserPages();
  renderSettingsInspector();
  toast("Recent browser pages cleared.");
}

function hasRecentActivity() {
  return Boolean(state.recentFolders.length || state.recentCommands.length || state.recentBrowserPages.length);
}

async function clearRecentActivity() {
  if (!hasRecentActivity()) {
    toast("Recent activity is already clear.");
    return false;
  }
  if (!await showConfirmDialog({
    title: "Clear recent activity",
    message: "Remove recent folders, terminal commands, and browser pages. Saved profiles, snippets, backgrounds, colors, and blueprints stay.",
    confirmLabel: "Clear",
    danger: true
  })) return false;
  state.recentFolders = [];
  state.recentCommands = [];
  state.recentBrowserPages = [];
  saveRecentFolders();
  saveRecentCommands();
  saveRecentBrowserPages();
  renderSettingsInspector();
  toast("Recent activity cleared.");
  return true;
}

function normalizeSnippetLabel(label, command = "") {
  const value = String(label || "").replace(/\s+/g, " ").trim();
  if (value) return value.slice(0, 56);
  const fallback = normalizeTerminalCommand(command);
  return (fallback || "Command").slice(0, 56);
}

function createCustomCommandSnippetId() {
  return `custom_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function normalizeCustomCommandSnippet(entry) {
  const command = normalizeTerminalCommand(entry?.command);
  if (!command) return null;
  const id = /^[a-z0-9_-]+$/i.test(entry?.id || "") ? entry.id : createCustomCommandSnippetId();
  return {
    id,
    label: normalizeSnippetLabel(entry?.label, command),
    command
  };
}

function loadCustomCommandSnippets() {
  try {
    const parsed = JSON.parse(localStorage.getItem(customCommandSnippetsStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const snippets = [];
    const seenCommands = new Set();
    const seenIds = new Set();
    for (const entry of parsed) {
      const snippet = normalizeCustomCommandSnippet(entry);
      if (!snippet) continue;
      const commandKey = snippet.command.toLowerCase();
      if (seenCommands.has(commandKey)) continue;
      if (seenIds.has(snippet.id)) snippet.id = createCustomCommandSnippetId();
      seenCommands.add(commandKey);
      seenIds.add(snippet.id);
      snippets.push(snippet);
      if (snippets.length >= customCommandSnippetsLimit) break;
    }
    return snippets;
  } catch {
    return [];
  }
}

function saveCustomCommandSnippets() {
  localStorage.setItem(customCommandSnippetsStorageKey, JSON.stringify(state.customCommandSnippets));
}

function allTerminalCommandSnippets() {
  return [
    ...builtInTerminalCommandSnippets.map((snippet) => ({ ...snippet, builtIn: true })),
    ...state.customCommandSnippets.map((snippet) => ({ ...snippet, builtIn: false }))
  ];
}

function findTerminalCommandSnippet(snippetId) {
  return allTerminalCommandSnippets().find((candidate) => candidate.id === snippetId);
}

function upsertCustomCommandSnippet(snippet) {
  const normalized = normalizeCustomCommandSnippet(snippet);
  if (!normalized) return null;
  const commandKey = normalized.command.toLowerCase();
  const id = normalized.id || createCustomCommandSnippetId();
  const replacing = state.customCommandSnippets.some((candidate) => (
    candidate.id === id || candidate.command.toLowerCase() === commandKey
  ));
  if (!replacing && state.customCommandSnippets.length >= customCommandSnippetsLimit) {
    toast(`Snippet limit is ${customCommandSnippetsLimit}. Delete one first.`);
    return null;
  }
  state.customCommandSnippets = [
    { ...normalized, id },
    ...state.customCommandSnippets.filter((candidate) => (
      candidate.id !== id && candidate.command.toLowerCase() !== commandKey
    ))
  ];
  saveCustomCommandSnippets();
  return state.customCommandSnippets[0];
}

function normalizeSettingsProfileLabel(label) {
  return String(label || "").replace(/\s+/g, " ").trim().slice(0, 48);
}

function createSettingsProfileId() {
  return `profile_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function normalizeSavedSettingsProfile(entry) {
  const settings = normalizeSettings(entry?.settings);
  const label = normalizeSettingsProfileLabel(entry?.label);
  if (!label) return null;
  const id = /^[a-z0-9_-]+$/i.test(entry?.id || "") ? entry.id : createSettingsProfileId();
  return {
    id,
    label,
    settings,
    createdAt: Number(entry?.createdAt) || Date.now()
  };
}

function loadSavedSettingsProfiles() {
  try {
    const parsed = JSON.parse(localStorage.getItem(savedSettingsProfilesStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const profiles = [];
    const seenIds = new Set();
    for (const entry of parsed) {
      const profile = normalizeSavedSettingsProfile(entry);
      if (!profile) continue;
      if (seenIds.has(profile.id)) profile.id = createSettingsProfileId();
      seenIds.add(profile.id);
      profiles.push(profile);
      if (profiles.length >= savedSettingsProfilesLimit) break;
    }
    return profiles;
  } catch {
    return [];
  }
}

function saveSavedSettingsProfiles() {
  localStorage.setItem(savedSettingsProfilesStorageKey, JSON.stringify(state.savedSettingsProfiles));
}

function upsertSavedSettingsProfile(profile) {
  const normalized = normalizeSavedSettingsProfile(profile);
  if (!normalized) return null;
  const replacing = state.savedSettingsProfiles.some((candidate) => candidate.id === normalized.id);
  if (!replacing && state.savedSettingsProfiles.length >= savedSettingsProfilesLimit) {
    toast(`Profile limit is ${savedSettingsProfilesLimit}. Delete one first.`);
    return null;
  }
  state.savedSettingsProfiles = [
    normalized,
    ...state.savedSettingsProfiles.filter((candidate) => candidate.id !== normalized.id)
  ];
  saveSavedSettingsProfiles();
  return state.savedSettingsProfiles[0];
}

function loadCustomColorPalette() {
  try {
    const parsed = JSON.parse(localStorage.getItem(customColorPaletteStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    return uniqueColors(parsed.map(normalizeCustomPaletteColor).filter(Boolean)).slice(0, customColorPaletteLimit);
  } catch {
    return [];
  }
}

function saveCustomColorPalette() {
  localStorage.setItem(customColorPaletteStorageKey, JSON.stringify(state.customColorPalette));
}

function upsertCustomColorPalette(color, options = {}) {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) {
    if (options.toast !== false) toast("Pick a custom hex color first.");
    return false;
  }
  const existed = state.customColorPalette.some((candidate) => candidate.toLowerCase() === normalized);
  state.customColorPalette = [
    normalized,
    ...state.customColorPalette.filter((candidate) => candidate.toLowerCase() !== normalized)
  ].slice(0, customColorPaletteLimit);
  saveCustomColorPalette();
  if (options.render !== false) renderSettingsInspector();
  if (options.toast !== false) toast(existed ? "Saved color moved to top." : "Saved color added.");
  return true;
}

function deleteCustomColorPalette(color) {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) return;
  state.customColorPalette = state.customColorPalette.filter((candidate) => candidate.toLowerCase() !== normalized);
  saveCustomColorPalette();
  renderSettingsInspector();
  toast("Saved color deleted.");
}

function accentColorPalette() {
  return uniqueColors([...accentOptions, ...state.customColorPalette]);
}

function workspaceColorPalette() {
  return uniqueColors([...(state.data?.palette || workspaceColorOptions), ...state.customColorPalette]);
}

function settingsProfileSummary(settings) {
  const normalized = normalizeSettings(settings);
  const theme = themeOptions.find(([id]) => id === normalized.theme)?.[1] || normalized.theme;
  const toolbar = toolbarModeOptions.find(([id]) => id === normalized.toolbarMode)?.[1] || normalized.toolbarMode;
  return [
    theme,
    normalized.density,
    toolbar,
    normalized.performanceMode ? "performance" : normalized.reduceMotion ? "reduced motion" : "balanced",
    `${normalized.terminalFontSize}px`
  ].join(" / ");
}

function normalizeBlueprintLabel(label) {
  return String(label || "").replace(/\s+/g, " ").trim().slice(0, 56);
}

function normalizeBlueprintColor(value) {
  const color = String(value || "").trim();
  return isAllowedUiColor(color, workspaceColorOptions) ? color : "";
}

function createWorkspaceBlueprintId() {
  return `blueprint_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function normalizeBlueprintPanel(panel = {}) {
  const type = panel.type === "browser" ? "browser" : "terminal";
  const title = String(panel.title || (type === "browser" ? "Browser" : "Terminal")).trim().slice(0, 80);
  const color = normalizeBlueprintColor(panel.color);
  const shellProfile = terminalProfiles.some(([id]) => id === panel.shellProfile) ? panel.shellProfile : defaultSettings.terminalProfile;
  return {
    type,
    title,
    color,
    cwd: String(panel.cwd || "").trim().slice(0, 512),
    shellProfile,
    shellPath: String(panel.shellPath || "").trim().slice(0, 512),
    url: type === "browser" ? normalizeUrl(panel.url || defaultSettings.browserHomeUrl, defaultSettings.browserHomeUrl) : "",
    weight: normalizePaneWeight(panel.weight) || paneLayoutScale
  };
}

function normalizeWorkspaceBlueprint(entry) {
  const label = normalizeBlueprintLabel(entry?.label);
  if (!label) return null;
  const panels = Array.isArray(entry?.panels)
    ? entry.panels.map(normalizeBlueprintPanel).filter(Boolean).slice(0, workspaceBlueprintPanelLimit)
    : [];
  if (panels.length === 0) return null;
  const id = /^[a-z0-9_-]+$/i.test(entry?.id || "") ? entry.id : createWorkspaceBlueprintId();
  return {
    id,
    label,
    splitDirection: entry?.splitDirection === "down" ? "down" : "right",
    color: normalizeBlueprintColor(entry?.color),
    cwd: String(entry?.cwd || "").trim().slice(0, 512),
    panels,
    createdAt: Number(entry?.createdAt) || Date.now()
  };
}

function loadWorkspaceBlueprints() {
  try {
    const parsed = JSON.parse(localStorage.getItem(workspaceBlueprintsStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const blueprints = [];
    const seenIds = new Set();
    for (const entry of parsed) {
      const blueprint = normalizeWorkspaceBlueprint(entry);
      if (!blueprint) continue;
      if (seenIds.has(blueprint.id)) blueprint.id = createWorkspaceBlueprintId();
      seenIds.add(blueprint.id);
      blueprints.push(blueprint);
      if (blueprints.length >= workspaceBlueprintsLimit) break;
    }
    return blueprints;
  } catch {
    return [];
  }
}

function saveWorkspaceBlueprints() {
  localStorage.setItem(workspaceBlueprintsStorageKey, JSON.stringify(state.workspaceBlueprints));
}

function upsertWorkspaceBlueprint(blueprint) {
  const normalized = normalizeWorkspaceBlueprint(blueprint);
  if (!normalized) return null;
  const replacing = state.workspaceBlueprints.some((candidate) => candidate.id === normalized.id);
  if (!replacing && state.workspaceBlueprints.length >= workspaceBlueprintsLimit) {
    toast(`Blueprint limit is ${workspaceBlueprintsLimit}. Delete one first.`);
    return null;
  }
  state.workspaceBlueprints = [
    normalized,
    ...state.workspaceBlueprints.filter((candidate) => candidate.id !== normalized.id)
  ];
  saveWorkspaceBlueprints();
  return state.workspaceBlueprints[0];
}

function normalizeBackgroundLabel(label) {
  return String(label || "").replace(/\s+/g, " ").trim().slice(0, 48);
}

function createSavedBackgroundImageId() {
  return `background_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function defaultBackgroundLabel(url) {
  if (/^data:image\//i.test(url)) return "Background image";
  const name = fileNameFromUrl(url).replace(/\.(?:avif|bmp|gif|jpe?g|png|webp)$/i, "");
  if (name && !name.startsWith("data:image")) return normalizeBackgroundLabel(name);
  try {
    const parsed = new URL(url);
    return normalizeBackgroundLabel(parsed.hostname || "Background image");
  } catch {
    return "Background image";
  }
}

function normalizeSavedBackgroundImage(entry) {
  const input = typeof entry === "string" ? { url: entry } : entry || {};
  const url = normalizedImageUrl(input.url || input.value || input.backgroundImage);
  if (!url) return null;
  const label = normalizeBackgroundLabel(input.label) || defaultBackgroundLabel(url);
  const id = /^[a-z0-9_-]+$/i.test(input.id || "") ? input.id : createSavedBackgroundImageId();
  return {
    id,
    label,
    url,
    createdAt: Number(input.createdAt) || Date.now()
  };
}

function loadSavedBackgroundImages() {
  try {
    const parsed = JSON.parse(localStorage.getItem(savedBackgroundImagesStorageKey) || "[]");
    if (!Array.isArray(parsed)) return [];
    const backgrounds = [];
    const seenIds = new Set();
    const seenUrls = new Set();
    for (const entry of parsed) {
      const background = normalizeSavedBackgroundImage(entry);
      if (!background) continue;
      const urlKey = background.url.toLowerCase();
      if (seenUrls.has(urlKey)) continue;
      if (seenIds.has(background.id)) background.id = createSavedBackgroundImageId();
      seenIds.add(background.id);
      seenUrls.add(urlKey);
      backgrounds.push(background);
      if (backgrounds.length >= savedBackgroundImagesLimit) break;
    }
    return backgrounds;
  } catch {
    return [];
  }
}

function saveSavedBackgroundImages() {
  localStorage.setItem(savedBackgroundImagesStorageKey, JSON.stringify(state.savedBackgroundImages));
}

function upsertSavedBackgroundImage(background, options = {}) {
  const normalized = normalizeSavedBackgroundImage(background);
  if (!normalized) {
    if (options.toast !== false) toast("Choose a custom background image first.");
    return null;
  }
  const urlKey = normalized.url.toLowerCase();
  const replacing = state.savedBackgroundImages.some((candidate) => (
    candidate.id === normalized.id || candidate.url.toLowerCase() === urlKey
  ));
  if (!replacing && state.savedBackgroundImages.length >= savedBackgroundImagesLimit) {
    toast(`Background limit is ${savedBackgroundImagesLimit}. Delete one first.`);
    return null;
  }
  state.savedBackgroundImages = [
    normalized,
    ...state.savedBackgroundImages.filter((candidate) => (
      candidate.id !== normalized.id && candidate.url.toLowerCase() !== urlKey
    ))
  ];
  saveSavedBackgroundImages();
  if (options.render !== false) renderSettingsInspector();
  if (options.toast !== false) toast(replacing ? "Saved background updated." : "Background saved.");
  return state.savedBackgroundImages[0];
}

function applySavedBackgroundImage(backgroundId) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return;
  const changed = updateSettings({ backgroundImage: background.url });
  if (!changed) {
    toast(`${background.label} background already active.`);
    return;
  }
  renderSettingsInspector();
  toast(`${background.label} background applied.`);
}

async function renameSavedBackgroundImage(backgroundId) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return;
  const label = await showTextDialog({
    title: "Rename background",
    value: background.label,
    placeholder: "Background name",
    confirmLabel: "Rename"
  });
  if (!label) return;
  upsertSavedBackgroundImage({ ...background, label, createdAt: background.createdAt });
}

async function deleteSavedBackgroundImage(backgroundId) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return;
  if (!await showConfirmDialog({
    title: "Delete background",
    message: `Delete "${background.label}"?`,
    confirmLabel: "Delete",
    danger: true
  })) return;
  state.savedBackgroundImages = state.savedBackgroundImages.filter((candidate) => candidate.id !== backgroundId);
  saveSavedBackgroundImages();
  renderSettingsInspector();
  toast("Saved background deleted.");
}

function workspaceBlueprintSummary(blueprint) {
  const terminals = blueprint.panels.filter((panel) => panel.type === "terminal").length;
  const browsers = blueprint.panels.filter((panel) => panel.type === "browser").length;
  const direction = blueprint.splitDirection === "down" ? "stacked" : "side-by-side";
  return `${terminals} terminal${terminals === 1 ? "" : "s"} / ${browsers} browser${browsers === 1 ? "" : "s"} / ${direction}`;
}

function settingsRenderSignature(settings = state.settings) {
  return [
    settings.theme,
    settings.accent,
    settings.backgroundImage,
    settings.backgroundOpacity,
    settings.density,
    settings.toolbarMode,
    settings.tabSize,
    settings.titleDetailMode,
    settings.showTabs,
    settings.showStatusbar,
    settings.showAdvanced,
    settings.performanceMode,
    settings.reduceMotion,
    settings.paneHeaderMode,
    settings.sidebarDetailMode,
    settings.sidebarFooterMode,
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
  const tabMetrics = tabSizeMetrics.get(state.settings.tabSize) || tabSizeMetrics.get(defaultSettings.tabSize);
  elements.shell.style.setProperty("--surface-tab-min", `${tabMetrics.min}px`);
  elements.shell.style.setProperty("--surface-tab-basis", `${tabMetrics.basis}px`);
  elements.shell.style.setProperty("--surface-tab-max", `${tabMetrics.max}px`);
  toggleClassIfChanged(elements.shell, "density-compact", state.settings.density === "compact");
  toggleClassIfChanged(elements.shell, "pane-header-compact", state.settings.paneHeaderMode === "compact");
  toggleClassIfChanged(elements.shell, "pane-header-full", state.settings.paneHeaderMode === "full");
  toggleClassIfChanged(elements.shell, "pane-header-hidden", state.settings.paneHeaderMode === "hidden");
  toggleClassIfChanged(elements.shell, "workspace-detail-compact", state.settings.sidebarDetailMode === "compact");
  toggleClassIfChanged(elements.shell, "workspace-detail-balanced", state.settings.sidebarDetailMode === "balanced");
  toggleClassIfChanged(elements.shell, "workspace-detail-detailed", state.settings.sidebarDetailMode === "detailed");
  toggleClassIfChanged(elements.shell, "sidebar-footer-workspace", state.settings.sidebarFooterMode === "workspace");
  toggleClassIfChanged(elements.shell, "sidebar-footer-compact", state.settings.sidebarFooterMode === "compact");
  toggleClassIfChanged(elements.shell, "sidebar-footer-full", state.settings.sidebarFooterMode === "full");
  toggleClassIfChanged(elements.shell, "toolbar-compact", state.settings.toolbarMode === "compact");
  toggleClassIfChanged(elements.shell, "toolbar-standard", state.settings.toolbarMode === "standard");
  toggleClassIfChanged(elements.shell, "toolbar-expanded", state.settings.toolbarMode === "expanded");
  toggleClassIfChanged(elements.shell, "hide-tabs", !state.settings.showTabs);
  toggleClassIfChanged(elements.shell, "hide-status", !state.settings.showStatusbar);
  toggleClassIfChanged(elements.shell, "show-advanced", state.settings.showAdvanced);
  toggleClassIfChanged(elements.shell, "performance-mode", state.settings.performanceMode);
  const reduceMotion = state.settings.reduceMotion || state.settings.performanceMode;
  toggleClassIfChanged(document.body, "reduce-motion", reduceMotion);
  toggleClassIfChanged(elements.shell, "reduce-motion", reduceMotion);
  const css = backgroundCss(state.settings.backgroundImage);
  toggleClassIfChanged(elements.shell, "has-background", css !== "none");
  elements.shell.style.setProperty("--background-image", css);
  elements.shell.style.setProperty("--background-opacity", String(state.settings.backgroundOpacity / 100));
  return true;
}

function updateSettings(updates, options = {}) {
  const previous = state.settings;
  const nextSettings = normalizeSettings({
    ...state.settings,
    ...updates
  });
  const changedKeys = Object.keys(updates).filter((key) => previous[key] !== nextSettings[key]);
  if (changedKeys.length === 0) return false;
  state.settings = nextSettings;
  state.terminalFontSize = state.settings.terminalFontSize;
  if (options.immediate) saveSettings();
  else scheduleSettingsSave();
  applySettings();
  const terminalAppearanceChanged = changedKeys.filter((key) => terminalAppearanceKeys.has(key));
  if (terminalAppearanceChanged.length === 1 && terminalAppearanceChanged[0] === "terminalScrollback") {
    applyTerminalScrollback();
  } else if (terminalAppearanceChanged.length > 0) {
    scheduleTerminalAppearanceRefresh();
  }
  if (changedKeys.some((key) => appearancePreviewKeys.has(key))) {
    scheduleAppearancePreviewRefresh();
  }
  if (changedKeys.some((key) => terminalSettingsPreviewKeys.has(key))) {
    scheduleTerminalSettingsPreviewRefresh();
  }
  if (changedKeys.some((key) => layoutSettingsPreviewKeys.has(key))) {
    scheduleLayoutSettingsPreviewRefresh();
  }
  if (previous.titleDetailMode !== state.settings.titleDetailMode) {
    render();
  }
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

function applyTerminalScrollback() {
  for (const session of state.terminals.values()) {
    session.term.options.scrollback = state.settings.terminalScrollback;
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
  { id: "workspace.next", label: "Next Workspace", shortcut: "Ctrl+PageDown", run: () => cycleWorkspace(1) },
  { id: "workspace.previous", label: "Previous Workspace", shortcut: "Ctrl+PageUp", run: () => cycleWorkspace(-1) },
  { id: "workspace.starterTerminalBrowser", label: "Add Terminal + Browser Starter", shortcut: "", run: () => applyWorkspaceStarter("terminalBrowser") },
  { id: "workspace.starterTwoTerminals", label: "Add Two-Terminal Starter", shortcut: "", run: () => applyWorkspaceStarter("twoTerminals") },
  { id: "workspace.starterDevTrio", label: "Add Dev Trio Starter", shortcut: "", run: () => applyWorkspaceStarter("devTrio") },
  { id: "workspace.saveBlueprint", label: "Save Workspace Blueprint", shortcut: "", run: () => saveCurrentWorkspaceBlueprint() },
  { id: "settings.blueprints", label: "Open Workspace Blueprints", shortcut: "", run: () => openSettingsCategory("blueprints") },
  { id: "workspace.close", label: "Close Workspace", shortcut: "", run: () => closeActiveWorkspace() },
  { id: "terminal.new", label: "New Terminal", shortcut: "Ctrl+T", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitRight", label: "Split Terminal Right", shortcut: "", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitDown", label: "Split Terminal Down", shortcut: "", run: () => createPanel("terminal", "down") },
  { id: "terminal.duplicate", label: "Duplicate Active Pane", shortcut: "", run: () => duplicateActivePanel() },
  { id: "terminal.nextPane", label: "Next Pane", shortcut: "Ctrl+Tab", run: () => cycleActivePane(1) },
  { id: "terminal.previousPane", label: "Previous Pane", shortcut: "Ctrl+Shift+Tab", run: () => cycleActivePane(-1) },
  { id: "terminal.runCommand", label: "Run Command in Active Terminal", shortcut: "Ctrl+Shift+Enter", run: () => promptRunTerminalCommand() },
  { id: "terminal.runListFiles", label: "Run List Workspace Files", shortcut: "", run: () => runTerminalCommandSnippet("listFiles") },
  { id: "terminal.runGitStatus", label: "Run Git Status", shortcut: "", run: () => runTerminalCommandSnippet("gitStatus") },
  { id: "terminal.runGitPull", label: "Run Git Pull", shortcut: "", run: () => runTerminalCommandSnippet("gitPull") },
  { id: "terminal.runGitPush", label: "Run Git Push", shortcut: "", run: () => runTerminalCommandSnippet("gitPush") },
  { id: "terminal.runNpmScripts", label: "Run NPM Scripts", shortcut: "", run: () => runTerminalCommandSnippet("npmScripts") },
  { id: "terminal.runGhPrStatus", label: "Run GH PR Status", shortcut: "", run: () => runTerminalCommandSnippet("ghPrStatus") },
  { id: "terminal.runGhPrChecks", label: "Run GH PR Checks", shortcut: "", run: () => runTerminalCommandSnippet("ghPrChecks") },
  { id: "terminal.runGhPrViewWeb", label: "Run GH PR View in Browser", shortcut: "", run: () => runTerminalCommandSnippet("ghPrViewWeb") },
  { id: "terminal.runGhPrMergeHelp", label: "Run GH PR Merge Help", shortcut: "", run: () => runTerminalCommandSnippet("ghPrMergeHelp") },
  { id: "terminal.find", label: "Find in Active Terminal", shortcut: "Ctrl+F", run: () => openTerminalSearch() },
  { id: "terminal.findNext", label: "Find Next in Terminal", shortcut: "F3", run: () => findNextInTerminal() },
  { id: "terminal.findPrevious", label: "Find Previous in Terminal", shortcut: "Shift+F3", run: () => findPreviousInTerminal() },
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
  { id: "layout.resetChrome", label: "Reset Workspace Chrome", shortcut: "", run: () => resetWorkspaceChrome() },
  { id: "layout.equalPanes", label: "Equalize Panes", shortcut: "", run: () => applyPaneLayoutPreset("equal") },
  { id: "layout.sideBySide", label: "Layout Panes Side by Side", shortcut: "", run: () => applyPaneLayoutPreset("sideBySide") },
  { id: "layout.stacked", label: "Stack Panes Vertically", shortcut: "", run: () => applyPaneLayoutPreset("stacked") },
  { id: "layout.activeWide", label: "Make Active Pane Wide", shortcut: "", run: () => applyPaneLayoutPreset("activeWide") },
  { id: "layout.activeTall", label: "Make Active Pane Tall", shortcut: "", run: () => applyPaneLayoutPreset("activeTall") },
  { id: "terminal.fontUp", label: "Terminal Font Larger", shortcut: "Ctrl+=", run: () => changeTerminalFontSize(1) },
  { id: "terminal.fontDown", label: "Terminal Font Smaller", shortcut: "Ctrl+-", run: () => changeTerminalFontSize(-1) },
  { id: "browser.new", label: "Open Browser", shortcut: "Ctrl+Shift+L", run: () => openBrowserPrompt() },
  { id: "notifications.open", label: "Show Notifications", shortcut: "Ctrl+I", run: () => openInspector("notifications") },
  { id: "session.tools", label: "Show Session Tools", shortcut: "", run: () => openInspector("session") },
  { id: "settings.open", label: "Open Settings", shortcut: "Ctrl+,", run: () => openInspector("settings") },
  { id: "settings.performance", label: "Open Performance Settings", shortcut: "", run: () => openSettingsCategory("performance") },
  { id: "settings.performancePreset", label: "Apply Performance Preset", shortcut: "", run: () => applySettingsPresetById("performance") },
  { id: "settings.tunePerformance", label: "Tune Performance Now", shortcut: "", run: () => tunePerformanceNow() },
  { id: "settings.copyDiagnostics", label: "Copy Performance Diagnostics", shortcut: "", run: () => copyPerformanceDiagnostics() },
  { id: "settings.actions", label: "Open Actions Settings", shortcut: "", run: () => openSettingsCategory("actions") },
  { id: "settings.commands", label: "Open Command Snippets", shortcut: "", run: () => openSettingsCategory("commands") },
  { id: "settings.profiles", label: "Open Settings Profiles", shortcut: "", run: () => openSettingsCategory("profiles") },
  { id: "settings.saveProfile", label: "Save Current Settings Profile", shortcut: "", run: () => saveCurrentSettingsProfile() },
  { id: "settings.clearRecentActivity", label: "Clear Recent Activity", shortcut: "", run: () => clearRecentActivity() },
  { id: "settings.terminal", label: "Open Terminal Settings", shortcut: "", run: () => openSettingsCategory("terminal") },
  { id: "settings.terminalColors", label: "Reset Terminal Colors", shortcut: "", run: () => applyTerminalColorPresetById("cmux") },
  { id: "settings.colors", label: "Open Color Settings", shortcut: "", run: () => openSettingsCategory("appearance") },
  { id: "settings.saveAccentColor", label: "Save Current Accent Color", shortcut: "", run: () => upsertCustomColorPalette(state.settings.accent) },
  { id: "settings.saveWorkspaceColor", label: "Save Current Workspace Color", shortcut: "", run: () => upsertCustomColorPalette(activeWorkspace()?.color) },
  { id: "settings.backgrounds", label: "Open Background Settings", shortcut: "", run: () => openSettingsCategory("appearance") },
  { id: "settings.saveBackground", label: "Save Current Background", shortcut: "", run: () => upsertSavedBackgroundImage({ url: state.settings.backgroundImage }) },
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
  setAppState(await api("/api/state"));
}

function connectEvents() {
  const socket = new WebSocket(`${location.origin.replace(/^http/, "ws")}/events`);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.type === "state") {
      setAppState(message.state, { previousState: state.data, schedule: true });
    }
  });
  socket.addEventListener("close", () => setTimeout(connectEvents, 800));
}

function appStateSignature(data) {
  try {
    return JSON.stringify(data || null);
  } catch {
    return "";
  }
}

function applyPendingFocusToState(nextData) {
  const pending = state.pendingFocusSync;
  if (!pending || !Array.isArray(nextData?.workspaces)) return nextData;
  if (pending.type === "workspace") {
    if (nextData.workspaces.some((workspace) => workspace.id === pending.workspaceId)) {
      nextData.activeWorkspaceId = pending.workspaceId;
    }
    return nextData;
  }
  if (pending.type === "panel") {
    const workspace = nextData.workspaces.find((candidate) =>
      candidate.panels.some((panel) => panel.id === pending.panelId)
    );
    if (workspace) {
      nextData.activeWorkspaceId = workspace.id;
      workspace.activePanelId = pending.panelId;
    }
  }
  return nextData;
}

function setAppState(nextData, { previousState = state.data, schedule = false } = {}) {
  const protectedData = applyPendingFocusToState(nextData);
  const nextSignature = appStateSignature(protectedData);
  if (nextSignature && nextSignature === state.dataSignature) {
    state.data = protectedData;
    state.renderStats.skippedRenders += 1;
    return false;
  }
  state.data = protectedData;
  state.dataSignature = nextSignature;
  if (schedule) scheduleRender(previousState);
  else render(previousState);
  return true;
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
  state.dataSignature = appStateSignature(state.data);
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
  const operationLabel = currentUiOperationLabel();

  setTextIfChanged(elements.workspaceHeading, workspace?.title || "Workspace");
  setTextIfChanged(elements.workspaceSubheading, workspace ? `${workspace.cwdShort || "no directory"}` : "Ready");
  setTextIfChanged(elements.statusSummary, operationLabel || defaultStatusSummary(workspace, {
    attentionCount,
    panelCount,
    zoomedPanel
  }));
  toggleClassIfChanged(elements.statusSummary, "is-busy", Boolean(operationLabel));
  updateRuntimeStatusLabels();

  toggleClassIfChanged(elements.shell, "sidebar-collapsed", state.sidebarCollapsed);
  toggleClassIfChanged(elements.shell, "inspector-open", Boolean(state.inspectorMode));
  toggleClassIfChanged(elements.shell, "pane-zoomed", Boolean(zoomedPanel));
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
  if (value >= renderSlowFrameMs) state.renderStats.slowCount += 1;
  if (value >= renderVerySlowFrameMs || state.renderStats.slowCount >= renderSlowFrameTriggerCount) {
    maybeTriggerPerformanceGuard("slow rendering");
  }
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

function currentUiOperationLabel() {
  return [...state.uiOperations.values()].at(-1)?.label || "";
}

function hasUiOperationKind(kind) {
  return [...state.uiOperations.values()].some((operation) => operation.kind === kind);
}

function isUiOperationActive(key) {
  return state.uiOperations.has(key);
}

function defaultStatusSummary(workspace = activeWorkspace(), options = {}) {
  if (!workspace) return "cmux Windows";
  const panelCount = options.panelCount ?? workspace.panels.length;
  const attentionCount = options.attentionCount ?? allAttentionPanels().length;
  const zoomedPanel = options.zoomedPanel ?? zoomedPanelForWorkspace(workspace);
  const parts = [
    workspace.title || "Workspace",
    zoomedPanel ? "focus" : panelCount ? `${panelCount} pane${panelCount === 1 ? "" : "s"}` : "home"
  ];
  if (attentionCount > 0) parts.push(`${attentionCount} attention`);
  return parts.join(" · ");
}

function updateRuntimeStatusLabels() {
  const pipeName = state.data?.pipeName || "";
  setTextIfChanged(elements.statusPipe, pipeName ? "pipe" : "pipe unavailable");
  setTitleIfChanged(elements.statusPipe, pipeName || "Control pipe unavailable");
  setTextIfChanged(elements.statusPty, state.data?.ptyAvailable ? "ConPTY" : "fallback");
  setTitleIfChanged(elements.statusPty, state.data?.ptyAvailable
    ? "ConPTY terminal backend ready"
    : "Process pipe fallback terminal backend");
}

function updateOperationChrome() {
  const label = currentUiOperationLabel();
  const creatingPane = hasUiOperationKind("create-panel");
  toggleClassIfChanged(elements.shell, "operation-pending", Boolean(label));
  toggleClassIfChanged(elements.statusSummary, "is-busy", Boolean(label));
  setTextIfChanged(elements.statusSummary, label || defaultStatusSummary());
  for (const id of ["newTerminalButton", "splitRightButton", "splitDownButton", "newBrowserButton"]) {
    const button = document.getElementById(id);
    if (button) button.disabled = creatingPane;
  }
  if (state.newTabButton) state.newTabButton.disabled = creatingPane;
}

async function withUiOperation(key, kind, label, task) {
  if (state.uiOperations.has(key)) return null;
  state.uiOperations.set(key, { kind, label });
  updateOperationChrome();
  try {
    return await task();
  } finally {
    state.uiOperations.delete(key);
    updateOperationChrome();
  }
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
  setDatasetIfChanged(button, "workspaceId", workspace.id);
  setClassNameIfChanged(button, `workspace-row${workspace.id === activeId ? " is-active" : ""}${hasAttention ? " has-attention" : ""}`);
  setStylePropertyIfChanged(button, "--workspace-color", workspace.color || state.data.palette?.[0] || "");
  setTextIfChanged(button.querySelector(".workspace-name"), workspace.title || `Workspace ${index + 1}`);
  setTextIfChanged(button.querySelector(".workspace-badge"), String(attentionTotal));
  setTextIfChanged(
    button.querySelector(".workspace-meta"),
    workspace.latestNotification || `${workspace.terminalCount || 0} terminals / ${workspace.browserCount || 0} browsers`
  );
  setTextIfChanged(button.querySelector(".workspace-path"), workspace.cwdShort || "~");
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
  const label = panelDisplayTitle(panel, true);
  const fullTitle = panelDisplayTitle(panel, false);
  setDatasetIfChanged(button, "panelId", panel.id);
  setClassNameIfChanged(button, `surface-tab${panel.id === workspace.activePanelId ? " is-active" : ""}${panel.id === state.zoomedPanelId ? " is-zoomed" : ""}${panel.needsAttention ? " has-attention" : ""}`);
  setTitleIfChanged(button, `${fullTitle} - right-click for pane options`);
  setStylePropertyIfChanged(button, "--tab-color", panel.color || workspace.color || "var(--color-accent)");
  setTextIfChanged(button.querySelector(".surface-label"), label);
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
  setDatasetIfChanged(state.newTabButton, "workspaceId", workspace.id);
  state.newTabButton.disabled = hasUiOperationKind("create-panel");
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
  toggleClassIfChanged(elements.paneGrid, "direction-down", workspace.splitDirection === "down");
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  const visiblePanels = zoomedPanel ? [zoomedPanel] : panels;
  const layoutDirection = paneLayoutDirection(workspace);
  const layoutWeights = storedPaneWeightsForPanels(visiblePanels, layoutDirection, zoomedPanel);
  if (visiblePanels.length <= 1) elements.paneLayoutStyle.textContent = "";
  else if (layoutWeights) renderPaneLayoutStylesForWeights(layoutWeights);
  toggleClassIfChanged(elements.paneGrid, "is-zoomed", Boolean(zoomedPanel));
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
    setDatasetIfChanged(pane, "panelId", panel.id);
    setStylePropertyIfChanged(pane, "--panel-color", panel.color || workspace.color || "var(--color-accent)");
    toggleClassIfChanged(pane, "is-active", panel.id === workspace.activePanelId);
    toggleClassIfChanged(pane, "is-zoomed", panel.id === state.zoomedPanelId);
    toggleClassIfChanged(pane, "has-attention", panel.needsAttention);
    toggleClassIfChanged(pane, "is-browser", panel.type === "browser");
    toggleClassIfChanged(pane, "is-terminal", panel.type === "terminal");
    if (visiblePanels.length <= 1) clearPaneFlex(pane);
    setTextIfChanged(pane.querySelector(".pane-type"), panel.type === "browser" ? "web" : "term");
    const title = panelDisplayTitle(panel, false);
    const titleNode = pane.querySelector(".pane-title");
    setTextIfChanged(titleNode, title);
    setTitleIfChanged(titleNode, title);
    const zoomButton = pane.querySelector(".zoom");
    setTextIfChanged(zoomButton, panel.id === state.zoomedPanelId ? "↙" : "□");
    setTitleIfChanged(zoomButton, panel.id === state.zoomedPanelId ? "Show all panes" : "Focus pane");
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

function terminalPanelTitle(panel) {
  const name = panel.title || "Terminal";
  const cwd = panel.cwdShort || "~";
  return name === cwd ? name : `${name} · ${cwd}`;
}

function terminalPanelFolder(panel) {
  return panel.cwdShort || "~";
}

function panelDisplayTitle(panel, surface = false) {
  if (panel.type === "browser") {
    if (state.settings.titleDetailMode === "detailed" && !surface) return panel.url || "Browser";
    return hostnameOf(panel.url);
  }
  if (state.settings.titleDetailMode === "compact") return panel.title || "Terminal";
  if (state.settings.titleDetailMode === "folder") return terminalPanelFolder(panel);
  if (state.settings.titleDetailMode === "detailed") return terminalPanelTitle(panel);
  return surface ? panel.title || "Terminal" : terminalPanelTitle(panel);
}

function browserUrlChangeNeedsRender(panel, nextUrl) {
  const nextPanel = { ...panel, url: nextUrl };
  return panelDisplayTitle(panel, true) !== panelDisplayTitle(nextPanel, true)
    || panelDisplayTitle(panel, false) !== panelDisplayTitle(nextPanel, false);
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
    terminal.searchResultDisposable?.dispose?.();
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
  const searchAddon = SearchAddonConstructor ? new SearchAddonConstructor({ highlightLimit: 2000 }) : null;
  term.loadAddon(fitAddon);
  term.loadAddon(webLinksAddon);
  if (searchAddon) term.loadAddon(searchAddon);
  term.open(host);

  const socket = new WebSocket(`${location.origin.replace(/^http/, "ws")}/terminal/${panel.id}`);
  const session = {
    term,
    fitAddon,
    searchAddon,
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
    forceFit: false,
    searchOverlay: null,
    searchTerm: "",
    searchCaseSensitive: false,
    searchResultDisposable: null
  };
  session.searchOverlay = createTerminalSearchOverlay(panel, session);
  if (session.searchOverlay) host.append(session.searchOverlay);
  session.searchResultDisposable = searchAddon?.onDidChangeResults?.((result) => {
    updateTerminalSearchStatus(session, result.resultIndex, result.resultCount);
  });

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

function createTerminalSearchOverlay(panel, session) {
  const overlay = document.createElement("div");
  overlay.className = "terminal-search";
  overlay.hidden = true;
  overlay.innerHTML = `
    <input class="terminal-search-input" type="search" autocomplete="off" spellcheck="false" placeholder="Find in terminal">
    <span class="terminal-search-status"></span>
    <button class="terminal-search-button terminal-search-prev" type="button" title="Previous match">↑</button>
    <button class="terminal-search-button terminal-search-next" type="button" title="Next match">↓</button>
    <button class="terminal-search-button terminal-search-case" type="button" title="Match case">Aa</button>
    <button class="terminal-search-button terminal-search-close" type="button" title="Close search">×</button>
  `;
  const input = overlay.querySelector(".terminal-search-input");
  const previous = overlay.querySelector(".terminal-search-prev");
  const next = overlay.querySelector(".terminal-search-next");
  const matchCase = overlay.querySelector(".terminal-search-case");
  const close = overlay.querySelector(".terminal-search-close");
  overlay.addEventListener("pointerdown", (event) => event.stopPropagation());
  overlay.addEventListener("click", (event) => event.stopPropagation());
  input.addEventListener("input", () => runTerminalSearch(session, "next", true));
  input.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      closeTerminalSearch(panel);
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      runTerminalSearch(session, event.shiftKey ? "previous" : "next");
    }
    if (event.key === "F3") {
      event.preventDefault();
      runTerminalSearch(session, event.shiftKey ? "previous" : "next");
    }
  });
  previous.onclick = () => runTerminalSearch(session, "previous");
  next.onclick = () => runTerminalSearch(session, "next");
  matchCase.onclick = () => {
    session.searchCaseSensitive = !session.searchCaseSensitive;
    matchCase.classList.toggle("is-active", session.searchCaseSensitive);
    runTerminalSearch(session, "next", true);
  };
  close.onclick = () => closeTerminalSearch(panel);
  return overlay;
}

function terminalSearchInput(session) {
  return session?.searchOverlay?.querySelector(".terminal-search-input") || null;
}

function terminalSearchOptions(session, incremental = false) {
  return {
    caseSensitive: Boolean(session.searchCaseSensitive),
    regex: false,
    wholeWord: false,
    incremental,
    decorations: terminalSearchDecorations
  };
}

function updateTerminalSearchStatus(session, resultIndex = -1, resultCount = 0) {
  const status = session?.searchOverlay?.querySelector(".terminal-search-status");
  if (!status) return;
  const hasTerm = Boolean(session.searchTerm);
  const count = Number(resultCount) || 0;
  status.classList.toggle("is-empty", hasTerm && count === 0);
  if (!hasTerm) {
    status.textContent = "";
  } else if (count === 0) {
    status.textContent = "No results";
  } else {
    status.textContent = `${Math.max(0, Number(resultIndex) || 0) + 1} / ${count}`;
  }
}

function runTerminalSearch(session, direction = "next", incremental = false) {
  if (!session?.searchAddon) return false;
  const input = terminalSearchInput(session);
  const term = input?.value || "";
  session.searchTerm = term;
  if (!term) {
    session.searchAddon.clearDecorations?.();
    updateTerminalSearchStatus(session, -1, 0);
    return false;
  }
  const options = terminalSearchOptions(session, incremental);
  const found = direction === "previous"
    ? session.searchAddon.findPrevious(term, options)
    : session.searchAddon.findNext(term, options);
  if (!found) updateTerminalSearchStatus(session, -1, 0);
  return found;
}

function terminalSearchTarget(panel = activePanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) return null;
  const session = state.terminals.get(terminalPanel.id);
  return session ? { panel: terminalPanel, session } : null;
}

function openTerminalSearch(panel = activePanel()) {
  const target = terminalSearchTarget(panel);
  if (!target) {
    toast("Focus a terminal pane first.");
    return false;
  }
  if (!target.session.searchAddon) {
    toast("Terminal search is unavailable.");
    return false;
  }
  target.session.searchOverlay.hidden = false;
  target.session.host.classList.add("has-terminal-search");
  focusPanel(target.panel.id);
  setTimeout(() => {
    const input = terminalSearchInput(target.session);
    input?.focus();
    input?.select();
  }, 35);
  if (target.session.searchTerm) runTerminalSearch(target.session, "next", true);
  return true;
}

function closeTerminalSearch(panel = activePanel()) {
  const target = terminalSearchTarget(panel);
  if (!target) return false;
  target.session.searchOverlay.hidden = true;
  target.session.host.classList.remove("has-terminal-search");
  target.session.searchAddon?.clearDecorations?.();
  focusTerminalSession(target.panel.id);
  return true;
}

function findNextInTerminal(panel = activePanel()) {
  const target = terminalSearchTarget(panel);
  if (!target || target.session.searchOverlay.hidden) return openTerminalSearch(panel);
  return runTerminalSearch(target.session, "next");
}

function findPreviousInTerminal(panel = activePanel()) {
  const target = terminalSearchTarget(panel);
  if (!target || target.session.searchOverlay.hidden) return openTerminalSearch(panel);
  return runTerminalSearch(target.session, "previous");
}

function enqueueTerminalOutput(session, data) {
  session.queue += data;
  updateTerminalOutputBacklog();
  if (state.terminalOutputStats.currentQueued >= terminalOutputBacklogThreshold) {
    maybeTriggerPerformanceGuard("terminal output backlog");
  }
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
  const chunkSize = terminalOutputChunkSizeFor(session);
  const chunk = session.queue.length > chunkSize ? session.queue.slice(0, chunkSize) : session.queue;
  session.queue = session.queue.slice(chunk.length);
  state.terminalOutputStats.chunks += 1;
  state.terminalOutputStats.lastChunk = chunk.length;
  state.terminalOutputStats.writtenBytes += chunk.length;
  session.term.write(chunk);
  updateTerminalOutputBacklog();
  if (session.queue) scheduleTerminalOutputFlush(session);
}

function terminalOutputChunkSizeFor(session) {
  if (
    state.settings.performanceMode
    || (state.settings.adaptivePerformance && session.queue.length >= terminalOutputBacklogThreshold)
  ) {
    return terminalOutputPerformanceChunkSize;
  }
  return terminalOutputChunkSize;
}

function totalTerminalOutputQueue() {
  let total = 0;
  for (const session of state.terminals.values()) {
    if (!session.disposed) total += session.queue.length;
  }
  return total;
}

function updateTerminalOutputBacklog() {
  const queued = totalTerminalOutputQueue();
  state.terminalOutputStats.currentQueued = queued;
  state.terminalOutputStats.maxQueued = Math.max(state.terminalOutputStats.maxQueued, queued);
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
    queueBrowserUrlSync(panel.id, next);
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
      queueBrowserUrlSync(panel.id, event.url);
    }
    updateNavState();
  });
  view.addEventListener("dom-ready", () => {
    webviewReady = true;
    updateNavState();
  });
  view.addEventListener("did-navigate-in-page", (event) => {
    if (event.url) {
      address.value = event.url;
      queueBrowserUrlSync(panel.id, event.url);
    }
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
    renderSettingsInspector({ ifChanged: true });
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

function renderSettingsInspector(options = {}) {
  elements.inspectorTitle.textContent = "Settings";
  elements.inspectorSubtitle.textContent = `${settingsCategoryLabel(state.settingsCategory)} page`;
  const signature = settingsInspectorSignature();
  if (
    options.ifChanged
    && signature === state.settingsInspectorSignature
    && elements.inspectorBody.querySelector(".settings-react-host")
  ) {
    return;
  }
  state.settingsInspectorSignature = signature;
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

  if (shouldBuildSection("profiles")) {
    const profilesSection = settingsSection("Profiles", "saved settings profile preset apply save rename delete appearance layout terminal performance");
    profilesSection.append(settingsProfilesPanel());
    nodes.push(profilesSection);
  }

  if (shouldBuildSection("blueprints")) {
    const blueprintsSection = settingsSection("Workspace blueprints", "saved workspace blueprint layout pane template terminal browser split apply new save rename delete");
    blueprintsSection.append(workspaceBlueprintsPanel());
    nodes.push(blueprintsSection);
  }

  if (shouldBuildSection("workspace")) {
    const workspaceSection = settingsSection("Workspace");
    workspaceSection.append(workspaceSettingsPreviewPanel(workspace));
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
    workspaceSection.append(settingRow("Color", swatchGrid(workspaceColorPalette(), workspace?.color, (color) => setWorkspaceColor(color))));
    workspaceSection.append(settingRow("Custom color", colorPicker(workspace?.color, (color) => setWorkspaceColor(color)), false, "custom workspace color hex picker"));
    nodes.push(workspaceSection);
  }

  if (shouldBuildSection("appearance")) {
    const appearanceSection = settingsSection("Appearance");
    appearanceSection.append(appearancePreviewPanel());
    const themeSelect = document.createElement("select");
    themeSelect.className = "setting-select";
    themeSelect.dataset.settingControl = "theme";
    for (const [value, label] of themeOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      themeSelect.append(option);
    }
    themeSelect.value = state.settings.theme;
    themeSelect.onchange = () => updateSettings({ theme: themeSelect.value });
    appearanceSection.append(settingRow("Theme", themeSelect));
    appearanceSection.append(settingRow("Theme gallery", themeChoiceGrid(), true, "theme visual gallery preview"));
    appearanceSection.append(settingRow("Accent", swatchGrid(accentColorPalette(), state.settings.accent, (accent) => updateSettings({ accent }))));
    appearanceSection.append(settingRow("Custom accent", colorPicker(state.settings.accent, (accent) => updateSettings({ accent })), false, "custom accent color hex picker"));
    appearanceSection.append(settingRow("Saved colors", savedColorPalettePanel(), true, "saved color palette custom accent workspace tab pane color"));
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
    appearanceSection.append(settingRow("Saved backgrounds", savedBackgroundImagesPanel(), true, "saved background image wallpaper library apply rename delete save"));

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
    browserSection.append(recentBrowserPagesSettings());
    nodes.push(browserSection);
  }

  if (shouldBuildSection("layout")) {
    const layoutSection = settingsSection("Layout");
    layoutSection.append(layoutSettingsPreviewPanel());
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
    const paneHeaderSelect = document.createElement("select");
    paneHeaderSelect.className = "setting-select";
    for (const [value, label] of paneHeaderOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      paneHeaderSelect.append(option);
    }
    paneHeaderSelect.value = state.settings.paneHeaderMode;
    paneHeaderSelect.onchange = () => updateSettings({ paneHeaderMode: paneHeaderSelect.value });
    layoutSection.append(settingRow("Pane headers", paneHeaderSelect, false, "terminal pane header chrome compact hidden content only toolbar"));
    const sidebarDetailSelect = document.createElement("select");
    sidebarDetailSelect.className = "setting-select";
    for (const [value, label] of sidebarDetailOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      sidebarDetailSelect.append(option);
    }
    sidebarDetailSelect.value = state.settings.sidebarDetailMode;
    sidebarDetailSelect.onchange = () => updateSettings({ sidebarDetailMode: sidebarDetailSelect.value });
    layoutSection.append(settingRow("Workspace rows", sidebarDetailSelect, false, "sidebar workspace row detail compact folder counts metadata"));
    const sidebarFooterSelect = document.createElement("select");
    sidebarFooterSelect.className = "setting-select";
    for (const [value, label] of sidebarFooterOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      sidebarFooterSelect.append(option);
    }
    sidebarFooterSelect.value = state.settings.sidebarFooterMode;
    sidebarFooterSelect.onchange = () => updateSettings({ sidebarFooterMode: sidebarFooterSelect.value });
    layoutSection.append(settingRow("Sidebar footer", sidebarFooterSelect, false, "sidebar footer new workspace reset session danger buttons compact clean"));
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
    const tabSizeSelect = document.createElement("select");
    tabSizeSelect.className = "setting-select";
    for (const [value, label] of tabSizeOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      tabSizeSelect.append(option);
    }
    tabSizeSelect.value = state.settings.tabSize;
    tabSizeSelect.onchange = () => updateSettings({ tabSize: tabSizeSelect.value });
    layoutSection.append(settingRow("Tab width", tabSizeSelect, false, "surface tab chrome tab width compact balanced roomy"));
    const titleDetailSelect = document.createElement("select");
    titleDetailSelect.className = "setting-select";
    for (const [value, label] of titleDetailOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      titleDetailSelect.append(option);
    }
    titleDetailSelect.value = state.settings.titleDetailMode;
    titleDetailSelect.onchange = () => updateSettings({ titleDetailMode: titleDetailSelect.value });
    layoutSection.append(settingRow("Title detail", titleDetailSelect, false, "pane tab title name folder directory detail label terminal browser"));
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
    layoutActions.dataset.settingsSearch = normalizeSettingsQuery("split layout pane splitter resize reset equal workspace chrome toolbar sidebar footer inspector tabs status header title");
    layoutActions.append(
      settingsActionButton("Reset split layout", resetActivePaneLayout, "", "split layout pane splitter resize reset equal"),
      settingsActionButton("Reset workspace chrome", resetWorkspaceChrome, "", "workspace chrome toolbar sidebar footer inspector tabs status header title reset")
    );
    layoutSection.append(layoutActions);
    layoutSection.append(settingRow("Pane presets", paneLayoutPresetGrid(), true, "split layout pane presets side by side stacked active wide tall equal"));
    layoutSection.append(settingRow("Surface tabs", toggleInput(state.settings.showTabs, (checked) => updateSettings({ showTabs: checked }))));
    layoutSection.append(settingRow("Status bar", toggleInput(state.settings.showStatusbar, (checked) => updateSettings({ showStatusbar: checked }))));
    layoutSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked }))));
    nodes.push(layoutSection);
  }

  if (shouldBuildSection("performance")) {
    const performanceSection = settingsSection("Performance", "speed smooth lag render diagnostics optimize preset");
    performanceSection.append(settingsMetricGrid(performanceMetrics()));
    performanceSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked })), false, "speed smooth lag effects reduce animation"));
    performanceSection.append(settingRow("Adaptive guard", toggleInput(state.settings.adaptivePerformance, (checked) => updateSettings({ adaptivePerformance: checked })), false, "adaptive automatic performance guard lag slow output tune"));
    performanceSection.append(settingRow("Reduce motion", toggleInput(state.settings.reduceMotion, (checked) => updateSettings({ reduceMotion: checked })), false, "motion animation transition smooth reduce accessibility"));
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
    performanceActions.dataset.settingsSearch = normalizeSettingsQuery("performance speed preset balanced reset render stats clear copy diagnostics report lag debug");
    performanceActions.append(
      settingsActionButton("Tune now", () => tunePerformanceNow(), "", "performance tune optimize lag speed"),
      settingsActionButton("Copy diagnostics", copyPerformanceDiagnostics, "", "performance diagnostics report copy lag debug stats"),
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

  if (shouldBuildSection("commands")) {
    const snippetsSection = settingsSection("Command snippets", "terminal command snippets saved custom git github gh cli run add edit delete palette");
    snippetsSection.append(commandSnippetsSettings());
    nodes.push(snippetsSection);
  }

  if (shouldBuildSection("terminal")) {
    const terminalSection = settingsSection("Terminal");
    terminalSection.append(terminalSettingsPreviewPanel());
    const fontSelect = document.createElement("select");
    fontSelect.className = "setting-select";
    fontSelect.dataset.settingControl = "terminalFontFamily";
    for (const [value, label] of terminalFontOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      fontSelect.append(option);
    }
    fontSelect.value = state.settings.terminalFontFamily;
    fontSelect.onchange = () => {
      updateSettings({ terminalFontFamily: fontSelect.value });
      refreshTerminalFontChoices();
    };
    terminalSection.append(settingRow("Font", fontSelect));
    terminalSection.append(settingRow("Font gallery", terminalFontChoiceGrid(), true, "terminal font gallery preview cascadia consolas jetbrains fira mono"));
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
    terminalSection.append(settingRow("Color preset", terminalColorPresetGrid(), true, "terminal color theme preset powershell high contrast light warm graphite default"));
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
      settingsActionButton("Reset terminal colors", () => applyTerminalColorPresetById("cmux"), "", "terminal color reset default background foreground cursor")
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
    actionsSection.append(settingsMetricGrid(settingsDataMetrics(), "data storage local settings metric"));
    const actions = document.createElement("div");
    actions.className = "settings-actions";
    const clearRecent = settingsActionButton("Clear recent activity", clearRecentActivity, "danger", "clear recent activity folders commands browser pages history");
    clearRecent.disabled = !hasRecentActivity();
    actions.append(
      settingsActionButton("Export", exportSettings),
      settingsActionButton("Import", importSettings),
      clearRecent,
      settingsActionButton("Reset", resetSettings, "danger")
    );
    actionsSection.append(actions);
    actionsSection.append(recentCommandsSettings());
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
  if (searching) scheduleSettingsFilter();
}

function settingsInspectorSignature() {
  const category = state.settingsCategory;
  const searching = Boolean(normalizeSettingsQuery(state.settingsQuery));
  const parts = [
    category,
    state.settingsQuery,
    stableJson(state.settings)
  ];
  if (searching || ["workspace", "layout", "blueprints", "appearance", "performance", "actions"].includes(category)) {
    parts.push(activeWorkspaceSettingsSignature());
  }
  if (searching || ["appearance", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.customColorPalette), stableJson(state.savedBackgroundImages));
  }
  if (searching || ["browser", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.recentBrowserPages));
  }
  if (searching || ["workspace", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.recentFolders));
  }
  if (searching || ["commands", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.customCommandSnippets), stableJson(state.recentCommands));
  }
  if (searching || ["profiles", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.savedSettingsProfiles));
  }
  if (searching || ["blueprints", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.workspaceBlueprints));
  }
  if (searching || category === "performance") {
    parts.push(stableJson(state.renderStats), stableJson(state.terminalOutputStats), String(state.performanceGuardTriggered));
  }
  return parts.join("\u001e");
}

function activeWorkspaceSettingsSignature() {
  const workspace = activeWorkspace();
  if (!workspace) return "";
  return stableJson({
    id: workspace.id,
    title: workspace.title,
    color: workspace.color,
    cwd: workspace.cwd,
    cwdShort: workspace.cwdShort,
    activePanelId: workspace.activePanelId,
    splitDirection: workspace.splitDirection,
    terminalCount: workspace.terminalCount,
    browserCount: workspace.browserCount,
    panels: workspace.panels.map((panel) => ({
      id: panel.id,
      type: panel.type,
      title: panel.title,
      color: panel.color,
      cwd: panel.cwd,
      cwdShort: panel.cwdShort,
      shellProfile: panel.shellProfile,
      shellPath: panel.shellPath,
      url: panel.url
    }))
  });
}

function stableJson(value) {
  try {
    return JSON.stringify(value ?? null);
  } catch {
    return "";
  }
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
        scheduleSettingsFilter();
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
    scheduleSettingsFilter();
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

function optionLabel(options, value, fallback = "") {
  return options.find(([id]) => id === value)?.[1] || fallback || String(value || "");
}

function appearanceBackgroundLabel(value) {
  const normalized = normalizeBackgroundValue(value);
  if (!normalized) return "None";
  const preset = backgroundPresetMap.get(normalized);
  if (preset) return preset.label;
  return defaultBackgroundLabel(normalized);
}

function appearancePreviewPanel() {
  const preview = createAppearancePreview({
    settings: state.settings,
    themeLabel: optionLabel(themeOptions, state.settings.theme, "cmux"),
    accentLabel: normalizeCustomPaletteColor(state.settings.accent) ? "Custom" : "Preset",
    backgroundLabel: appearanceBackgroundLabel(state.settings.backgroundImage),
    terminalFontLabel: optionLabel(terminalFontOptions, state.settings.terminalFontFamily, "Mono"),
    terminalFontStack: terminalFontStack(),
    terminalTheme: terminalTheme(),
    backgroundImage: backgroundCss(state.settings.backgroundImage)
  });
  preview.dataset.settingsSearch = normalizeSettingsQuery("appearance visual preview theme gallery accent background image strength terminal colors font");
  return preview;
}

function scheduleAppearancePreviewRefresh() {
  if (state.appearancePreviewFrame) return;
  state.appearancePreviewFrame = requestAnimationFrame(() => {
    state.appearancePreviewFrame = 0;
    refreshAppearancePreview();
  });
}

function refreshAppearancePreview() {
  const preview = elements.inspectorBody.querySelector(".appearance-preview");
  if (preview) preview.replaceWith(appearancePreviewPanel());
  const themeSelect = elements.inspectorBody.querySelector('[data-setting-control="theme"]');
  if (themeSelect && themeSelect.value !== state.settings.theme) themeSelect.value = state.settings.theme;
  for (const button of elements.inspectorBody.querySelectorAll("[data-theme-choice]")) {
    const active = button.dataset.themeChoice === state.settings.theme;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
  }
  if (normalizeSettingsQuery(state.settingsQuery)) scheduleSettingsFilter();
}

function themeChoiceGrid() {
  const grid = document.createElement("div");
  grid.className = "theme-choice-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("theme gallery visual preview color appearance look");
  for (const theme of themePreviewOptions) {
    const label = optionLabel(themeOptions, theme.id, theme.id);
    const button = document.createElement("button");
    const active = theme.id === state.settings.theme;
    button.className = `theme-choice${active ? " is-active" : ""}`;
    button.type = "button";
    button.title = label;
    button.dataset.themeChoice = theme.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`theme visual gallery preview ${label} ${theme.id}`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.style.setProperty("--theme-preview-canvas", theme.canvas);
    button.style.setProperty("--theme-preview-pane", theme.pane);
    button.style.setProperty("--theme-preview-rail", theme.rail);
    button.style.setProperty("--theme-preview-line", theme.line);
    button.style.setProperty("--theme-preview-accent", theme.accent);
    button.innerHTML = `
      <span class="theme-choice-preview">
        <span class="theme-choice-sidebar"></span>
        <span class="theme-choice-pane"></span>
        <span class="theme-choice-accent"></span>
      </span>
      <span class="theme-choice-label"></span>
    `;
    button.querySelector(".theme-choice-label").textContent = label;
    button.onclick = () => {
      const changed = updateSettings({ theme: theme.id });
      if (!changed) toast(`${label} theme already active.`);
    };
    grid.append(button);
  }
  return grid;
}

function layoutSettingsPreviewPanel() {
  const settings = state.settings;
  const panel = document.createElement("div");
  panel.className = [
    "layout-settings-preview",
    `density-${settings.density}`,
    `pane-header-${settings.paneHeaderMode}`,
    `toolbar-${settings.toolbarMode}`,
    `tab-size-${settings.tabSize}`,
    settings.showTabs ? "show-tabs" : "hide-tabs",
    settings.showStatusbar ? "show-statusbar" : "hide-statusbar",
    settings.performanceMode ? "performance-preview" : ""
  ].filter(Boolean).join(" ");
  panel.dataset.settingsSearch = normalizeSettingsQuery("layout preview workspace chrome sidebar toolbar tabs status pane header density settings panel");
  panel.style.setProperty("--layout-preview-sidebar", `${Math.max(24, Math.round((settings.sidebarWidth / 304) * 72))}px`);
  panel.style.setProperty("--layout-preview-inspector", `${Math.max(42, Math.round((settings.inspectorWidth / 480) * 76))}px`);
  panel.innerHTML = `
    <div class="layout-preview-frame" aria-hidden="true">
      <div class="layout-preview-sidebar">
        <span class="layout-preview-brand"></span>
        <span class="layout-preview-workspace active"></span>
        <span class="layout-preview-workspace"></span>
        <span class="layout-preview-footer"></span>
      </div>
      <div class="layout-preview-main">
        <div class="layout-preview-topbar">
          <span></span><span></span><span></span>
        </div>
        <div class="layout-preview-tabs">
          <span class="active"></span><span></span><span class="plus"></span>
        </div>
        <div class="layout-preview-pane">
          <span class="layout-preview-pane-header"></span>
          <span class="layout-preview-terminal-line"></span>
          <span class="layout-preview-terminal-line short"></span>
        </div>
        <div class="layout-preview-status"></div>
      </div>
      <div class="layout-preview-inspector">
        <span></span><span></span><span></span>
      </div>
    </div>
    <div class="layout-preview-meta">
      <span><b>Toolbar</b><em data-layout-preview-toolbar></em></span>
      <span><b>Tabs</b><em data-layout-preview-tabs></em></span>
      <span><b>Header</b><em data-layout-preview-header></em></span>
      <span><b>Sidebar</b><em data-layout-preview-sidebar></em></span>
      <span><b>Settings</b><em data-layout-preview-settings></em></span>
      <span><b>Status</b><em data-layout-preview-status></em></span>
    </div>
  `;
  panel.querySelector("[data-layout-preview-toolbar]").textContent = optionLabel(toolbarModeOptions, settings.toolbarMode, settings.toolbarMode);
  panel.querySelector("[data-layout-preview-tabs]").textContent = settings.showTabs ? optionLabel(tabSizeOptions, settings.tabSize, settings.tabSize) : "Hidden";
  panel.querySelector("[data-layout-preview-header]").textContent = optionLabel(paneHeaderOptions, settings.paneHeaderMode, settings.paneHeaderMode);
  panel.querySelector("[data-layout-preview-sidebar]").textContent = `${settings.sidebarWidth}px`;
  panel.querySelector("[data-layout-preview-settings]").textContent = `${settings.inspectorWidth}px`;
  panel.querySelector("[data-layout-preview-status]").textContent = settings.showStatusbar ? "On" : "Off";
  return panel;
}

function scheduleLayoutSettingsPreviewRefresh() {
  if (state.layoutSettingsPreviewFrame) return;
  state.layoutSettingsPreviewFrame = requestAnimationFrame(() => {
    state.layoutSettingsPreviewFrame = 0;
    refreshLayoutSettingsPreview();
  });
}

function refreshLayoutSettingsPreview() {
  const preview = elements.inspectorBody.querySelector(".layout-settings-preview");
  if (preview) preview.replaceWith(layoutSettingsPreviewPanel());
  if (normalizeSettingsQuery(state.settingsQuery)) scheduleSettingsFilter();
}

function workspacePanelSummary(workspace) {
  const terminalCount = workspace?.terminalCount || 0;
  const browserCount = workspace?.browserCount || 0;
  const parts = [];
  if (terminalCount) parts.push(`${terminalCount} terminal${terminalCount === 1 ? "" : "s"}`);
  if (browserCount) parts.push(`${browserCount} browser${browserCount === 1 ? "" : "s"}`);
  return parts.join(" / ") || "No panes";
}

function workspaceSettingsPreviewPanel(workspace) {
  const active = workspace?.panels.find((panel) => panel.id === workspace.activePanelId) || workspace?.panels[0];
  const color = workspace?.color || state.data?.palette?.[0] || state.settings.accent;
  const title = workspace?.title || "Workspace";
  const folder = workspace?.cwdShort || workspace?.cwd || "No folder";
  const panelSummary = workspacePanelSummary(workspace);
  const activeLabel = active ? panelDisplayTitle(active, true) : "No active pane";
  const panelType = active?.type === "browser" ? "Browser" : "Terminal";
  const panelPath = active?.type === "browser" ? hostnameOf(active.url) : active?.cwdShort || folder;
  const panelColor = active?.color || color;
  const preview = document.createElement("div");
  preview.className = "workspace-settings-preview";
  preview.dataset.settingsSearch = normalizeSettingsQuery("workspace preview name rename folder directory color tab pane active terminal browser");
  preview.style.setProperty("--workspace-preview-color", color);
  preview.style.setProperty("--workspace-preview-pane-color", panelColor);
  preview.innerHTML = `
    <div class="workspace-preview-frame" aria-hidden="true">
      <div class="workspace-preview-row">
        <span class="workspace-preview-color"></span>
        <span class="workspace-preview-title"></span>
        <span class="workspace-preview-count"></span>
        <span class="workspace-preview-folder"></span>
      </div>
      <div class="workspace-preview-topbar">
        <span class="workspace-preview-heading"></span>
        <span class="workspace-preview-subheading"></span>
      </div>
      <div class="workspace-preview-tabs">
        <span class="workspace-preview-tab active"></span>
        <span class="workspace-preview-tab muted"></span>
        <span class="workspace-preview-tab plus"></span>
      </div>
      <div class="workspace-preview-pane">
        <span class="workspace-preview-pane-title"></span>
        <span class="workspace-preview-line"></span>
        <span class="workspace-preview-line short"></span>
      </div>
    </div>
    <div class="workspace-preview-meta">
      <span><b>Name</b><em data-workspace-preview-name></em></span>
      <span><b>Folder</b><em data-workspace-preview-folder></em></span>
      <span><b>Panes</b><em data-workspace-preview-panes></em></span>
      <span><b>Active</b><em data-workspace-preview-active></em></span>
    </div>
  `;
  preview.querySelector(".workspace-preview-title").textContent = title;
  preview.querySelector(".workspace-preview-count").textContent = panelSummary;
  preview.querySelector(".workspace-preview-folder").textContent = folder;
  preview.querySelector(".workspace-preview-heading").textContent = title;
  preview.querySelector(".workspace-preview-subheading").textContent = folder;
  preview.querySelector(".workspace-preview-tab.active").textContent = activeLabel;
  preview.querySelector(".workspace-preview-tab.muted").textContent = panelType;
  preview.querySelector(".workspace-preview-pane-title").textContent = activeLabel;
  preview.querySelector("[data-workspace-preview-name]").textContent = title;
  preview.querySelector("[data-workspace-preview-folder]").textContent = folder;
  preview.querySelector("[data-workspace-preview-panes]").textContent = panelSummary;
  preview.querySelector("[data-workspace-preview-active]").textContent = active ? `${panelType} / ${panelPath}` : "None";
  return preview;
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

const searchTokenAliases = new Map([
  ["bg", ["background", "wallpaper"]],
  ["backgoudn", ["background", "wallpaper"]],
  ["colour", ["color"]],
  ["colur", ["color"]],
  ["folder", ["directory", "cwd"]],
  ["lag", ["performance", "speed", "smooth"]],
  ["slow", ["performance", "speed", "smooth"]],
  ["term", ["terminal"]],
  ["workshop", ["workspace"]],
  ["workshape", ["workspace"]],
  ["workhsop", ["workspace"]]
]);

const settingsCategorySearchAliases = new Map([
  ["appearance", "look appearance background image wallpaper file local color colour theme accent"],
  ["workspace", "workspace workshop folder directory cwd rename color colour"],
  ["browser", "browser web url page home"],
  ["layout", "layout split pane tab sidebar footer reset header resize"],
  ["performance", "performance lag slow smooth speed motion"],
  ["terminal", "terminal term shell font cursor color colour profile"],
  ["commands", "commands snippets shell gh github cli"],
  ["profiles", "profiles preset saved settings"],
  ["blueprints", "blueprints workspace layout template"],
  ["data", "data import export reset recent history clear activity"]
]);

function uniqueSearchTokens(tokens) {
  return [...new Set(tokens.filter(Boolean))];
}

function settingsSearchTokens(value) {
  return normalizeSettingsQuery(value).split(/\s+/).filter(Boolean).map((token) => {
    const aliases = searchTokenAliases.get(token) || [];
    return uniqueSearchTokens([token, ...aliases]);
  });
}

function scheduleSettingsFilter() {
  if (state.settingsFilterFrame) return;
  state.settingsFilterFrame = requestAnimationFrame(() => {
    state.settingsFilterFrame = 0;
    applySettingsFilter();
  });
}

function applySettingsFilter() {
  const query = normalizeSettingsQuery(state.settingsQuery);
  const tokens = settingsSearchTokens(query);
  let visibleSections = 0;
  for (const section of elements.inspectorBody.querySelectorAll(".settings-section")) {
    const items = [...section.querySelectorAll("[data-settings-search]")].filter((item) => item !== section);
    const sectionMatches = settingsSearchMatches(section.dataset.settingsSearch, tokens);
    let sectionVisible = sectionMatches;
    for (const item of items) {
      const visible = settingsSearchMatches(item.dataset.settingsSearch, tokens) || sectionMatches;
      setHiddenIfChanged(item, !visible);
      sectionVisible ||= visible;
    }
    for (const group of section.querySelectorAll(".settings-command-group")) {
      const cardVisible = [...group.querySelectorAll(".settings-command-card")].some((card) => !card.hidden);
      const groupVisible = cardVisible
        || settingsSearchMatches(group.dataset.settingsSearch, tokens)
        || sectionMatches;
      setHiddenIfChanged(group, !groupVisible);
      sectionVisible ||= groupVisible;
    }
    setHiddenIfChanged(section, !sectionVisible);
    if (sectionVisible) visibleSections += 1;
  }
  const empty = elements.inspectorBody.querySelector(".settings-empty");
  if (empty) setHiddenIfChanged(empty, !query || visibleSections > 0);
  const clear = elements.inspectorBody.querySelector(".settings-search-clear");
  if (clear) clear.disabled = !query;
}

function settingsSearchMatches(searchText, tokens) {
  if (!tokens.length) return true;
  const haystack = normalizeSettingsQuery(searchText);
  return tokens.every((group) => group.some((token) => haystack.includes(token)));
}

function formatMs(value) {
  return `${Math.max(0, Number(value) || 0).toFixed(1)} ms`;
}

function formatBytes(value) {
  const bytes = Math.max(0, Number(value) || 0);
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${Math.round(bytes)} B`;
}

function performanceMetrics() {
  const workspaces = state.data?.workspaces || [];
  const panels = allPanels();
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  updateTerminalOutputBacklog();
  return [
    ["Render avg", formatMs(state.renderStats.avgMs)],
    ["Last render", formatMs(state.renderStats.lastMs)],
    ["Max render", formatMs(state.renderStats.maxMs)],
    ["Slow renders", String(state.renderStats.slowCount)],
    ["Skipped renders", String(state.renderStats.skippedRenders)],
    ["Browser URL skips", String(state.renderStats.browserUrlRenderSkips)],
    ["Output backlog", formatBytes(state.terminalOutputStats.currentQueued)],
    ["Output max", formatBytes(state.terminalOutputStats.maxQueued)],
    ["Output chunks", String(state.terminalOutputStats.chunks)],
    ["Guard", state.settings.performanceMode ? "On" : state.settings.adaptivePerformance ? "Watching" : "Off"],
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

function localStorageString(key) {
  try {
    return localStorage.getItem(key) || "";
  } catch {
    return "";
  }
}

function storageStringBytes(value) {
  const text = String(value || "");
  if (typeof Blob === "function") return new Blob([text]).size;
  return text.length;
}

function storageEntryBytes(key) {
  return storageStringBytes(localStorageString(key));
}

function settingsDataMetrics() {
  const storageEntries = [
    ["settings", "Settings", "cmux.settings"],
    ["terminalFontSize", "Terminal font", "cmux.terminalFontSize"],
    ["paneLayout", "Pane layouts", paneLayoutStorageKey],
    ["recentFolders", "Recent folders", recentFoldersStorageKey],
    ["recentCommands", "Recent commands", recentCommandsStorageKey],
    ["recentBrowserPages", "Recent pages", recentBrowserPagesStorageKey],
    ["commandSnippets", "Command snippets", customCommandSnippetsStorageKey],
    ["settingsProfiles", "Profiles", savedSettingsProfilesStorageKey],
    ["workspaceBlueprints", "Blueprints", workspaceBlueprintsStorageKey],
    ["customColors", "Saved colors", customColorPaletteStorageKey],
    ["savedBackgrounds", "Backgrounds", savedBackgroundImagesStorageKey]
  ];
  const totalBytes = storageEntries.reduce((sum, [, , key]) => sum + storageEntryBytes(key), 0);
  const recentItems = state.recentFolders.length + state.recentCommands.length + state.recentBrowserPages.length;
  const savedItems = state.customCommandSnippets.length
    + state.savedSettingsProfiles.length
    + state.workspaceBlueprints.length
    + state.customColorPalette.length
    + state.savedBackgroundImages.length;
  return [
    ["Local data", formatBytes(totalBytes)],
    ["Recent items", String(recentItems)],
    ["Saved items", String(savedItems)],
    ["Recent folders", `${state.recentFolders.length}/${recentFoldersLimit}`],
    ["Recent commands", `${state.recentCommands.length}/${recentCommandsLimit}`],
    ["Recent pages", `${state.recentBrowserPages.length}/${recentBrowserPagesLimit}`],
    ["Command snippets", `${state.customCommandSnippets.length}/${customCommandSnippetsLimit}`],
    ["Profiles", `${state.savedSettingsProfiles.length}/${savedSettingsProfilesLimit}`],
    ["Blueprints", `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`],
    ["Saved colors", `${state.customColorPalette.length}/${customColorPaletteLimit}`],
    ["Backgrounds", `${state.savedBackgroundImages.length}/${savedBackgroundImagesLimit}`],
    ["Pane layouts", formatBytes(storageEntryBytes(paneLayoutStorageKey))]
  ];
}

function performanceDiagnosticsPayload() {
  const workspace = activeWorkspace();
  const panels = allPanels();
  const workspacePanels = workspace?.panels || [];
  updateTerminalOutputBacklog();
  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    app: {
      name: "cmux Windows",
      userAgent: navigator.userAgent,
      viewport: {
        width: window.innerWidth,
        height: window.innerHeight,
        devicePixelRatio: window.devicePixelRatio || 1
      }
    },
    metrics: Object.fromEntries(performanceMetrics()),
    renderStats: { ...state.renderStats },
    terminalOutputStats: { ...state.terminalOutputStats },
    performanceGuard: {
      enabled: state.settings.performanceMode,
      adaptive: state.settings.adaptivePerformance,
      triggered: state.performanceGuardTriggered,
      reason: state.performanceGuardReason
    },
    settings: {
      theme: state.settings.theme,
      density: state.settings.density,
      toolbarMode: state.settings.toolbarMode,
      paneHeaderMode: state.settings.paneHeaderMode,
      sidebarDetailMode: state.settings.sidebarDetailMode,
      sidebarFooterMode: state.settings.sidebarFooterMode,
      tabSize: state.settings.tabSize,
      titleDetailMode: state.settings.titleDetailMode,
      showTabs: state.settings.showTabs,
      showStatusbar: state.settings.showStatusbar,
      performanceMode: state.settings.performanceMode,
      adaptivePerformance: state.settings.adaptivePerformance,
      reduceMotion: state.settings.reduceMotion,
      background: state.settings.backgroundImage
        ? isBackgroundPreset(state.settings.backgroundImage) ? state.settings.backgroundImage : "custom-image"
        : "none",
      terminalFontFamily: state.settings.terminalFontFamily,
      terminalFontSize: state.settings.terminalFontSize,
      terminalLineHeight: state.settings.terminalLineHeight,
      terminalPadding: state.settings.terminalPadding,
      terminalScrollback: state.settings.terminalScrollback,
      terminalCursorStyle: state.settings.terminalCursorStyle,
      terminalCursorBlink: state.settings.terminalCursorBlink
    },
    workspace: workspace ? {
      id: workspace.id,
      title: workspace.title || "Workspace",
      cwdShort: workspace.cwdShort || "",
      splitDirection: paneLayoutDirection(workspace),
      activePanelId: workspace.activePanelId,
      panels: workspacePanels.map((panel) => ({
        id: panel.id,
        type: panel.type,
        title: panel.title || "",
        cwdShort: panel.cwdShort || "",
        urlHost: panel.type === "browser" ? hostnameOf(panel.url) : "",
        needsAttention: Boolean(panel.needsAttention)
      }))
    } : null,
    counts: {
      workspaces: state.data?.workspaces?.length || 0,
      panes: panels.length,
      terminals: panels.filter((panel) => panel.type === "terminal").length,
      browsers: panels.filter((panel) => panel.type === "browser").length,
      paneCache: state.paneCache.size,
      terminalCache: state.terminals.size,
      browserCache: state.browserViews.size
    }
  };
}

async function copyPerformanceDiagnostics() {
  const payload = JSON.stringify(performanceDiagnosticsPayload(), null, 2);
  if (await writeClipboardText(payload)) {
    toast("Performance diagnostics copied.");
    return;
  }
  await showTextDialog({
    title: "Performance diagnostics",
    message: "Clipboard access is unavailable. The diagnostics report is shown below.",
    value: payload,
    confirmLabel: "Close",
    multiline: true,
    readOnly: true
  });
}

function settingsMetricGrid(metrics, searchPrefix = "performance diagnostics metric") {
  const grid = document.createElement("div");
  grid.className = "settings-metric-grid";
  for (const [label, value] of metrics) {
    const card = document.createElement("div");
    card.className = "settings-metric";
    card.dataset.settingsSearch = normalizeSettingsQuery(`${searchPrefix} ${label} ${value}`);
    card.innerHTML = `<span class="settings-metric-value"></span><span class="settings-metric-label"></span>`;
    card.querySelector(".settings-metric-value").textContent = value;
    card.querySelector(".settings-metric-label").textContent = label;
    grid.append(card);
  }
  return grid;
}

function paneLayoutPresetGrid() {
  const workspace = activeWorkspace();
  const disabled = !workspace || workspace.panels.length <= 1;
  const grid = document.createElement("div");
  grid.className = "pane-layout-preset-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("split layout pane presets side by side stacked active wide tall equal");
  for (const preset of paneLayoutPresets) {
    const button = document.createElement("button");
    button.className = "pane-layout-preset";
    button.type = "button";
    button.disabled = disabled;
    button.dataset.settingsSearch = normalizeSettingsQuery(`split layout pane preset ${preset.label} ${preset.body}`);
    button.innerHTML = `<span class="pane-layout-preset-title"></span><span class="pane-layout-preset-body"></span>`;
    button.querySelector(".pane-layout-preset-title").textContent = preset.label;
    button.querySelector(".pane-layout-preset-body").textContent = preset.body;
    button.onclick = () => applyPaneLayoutPreset(preset.id);
    grid.append(button);
  }
  return grid;
}

function resetRenderStats() {
  state.renderStats = {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0,
    slowCount: 0,
    skippedRenders: 0,
    browserUrlRenderSkips: 0,
    guardActivations: 0
  };
  state.terminalOutputStats = {
    currentQueued: totalTerminalOutputQueue(),
    maxQueued: totalTerminalOutputQueue(),
    writtenBytes: 0,
    chunks: 0,
    lastChunk: 0
  };
  state.performanceGuardTriggered = false;
  state.performanceGuardReason = "";
  renderSettingsInspector();
  toast("Performance stats reset.");
}

function maybeTriggerPerformanceGuard(reason) {
  if (!state.settings.adaptivePerformance || state.settings.performanceMode || state.performanceGuardTriggered) return;
  state.performanceGuardTriggered = true;
  state.performanceGuardReason = reason;
  state.renderStats.guardActivations += 1;
  tunePerformanceNow({ automatic: true, reason });
}

function tunePerformanceNow({ automatic = false, reason = "manual tune" } = {}) {
  const changed = updateSettings({
    performanceMode: true,
    adaptivePerformance: true,
    reduceMotion: true,
    backgroundOpacity: Math.min(state.settings.backgroundOpacity, 8),
    density: "compact",
    toolbarMode: "compact",
    showStatusbar: false,
    terminalPadding: Math.min(state.settings.terminalPadding, 4),
    terminalScrollback: Math.min(state.settings.terminalScrollback, 6000)
  });
  if (!changed) {
    toast(automatic ? "Performance guard already tuned." : "Performance tune already active.");
    return;
  }
  if (state.inspectorMode === "settings" && state.settingsCategory === "performance") {
    renderSettingsInspector();
  }
  toast(automatic ? `Performance guard enabled: ${reason}.` : "Performance tune applied.");
}

function commandGroupLabel(command) {
  if (command.id.startsWith("workspace.")) return "Workspace";
  if (command.id.startsWith("terminal.")) return "Terminal";
  if (command.id.startsWith("browser.")) return "Browser";
  if (command.id.startsWith("settings.")) return "Settings";
  if (command.id.startsWith("notifications.")) return "Notifications";
  if (command.id.startsWith("session.")) return "Session";
  if (command.id.startsWith("layout.")) return "Layout";
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

function terminalFontChoiceGrid() {
  const grid = document.createElement("div");
  grid.className = "terminal-font-choice-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("terminal font gallery preview cascadia code consolas jetbrains fira mono");
  for (const [value, label, stack] of terminalFontOptions) {
    const active = value === state.settings.terminalFontFamily;
    const button = document.createElement("button");
    button.className = `terminal-font-choice${active ? " is-active" : ""}`;
    button.type = "button";
    button.title = label;
    button.dataset.terminalFontChoice = value;
    button.dataset.settingsSearch = normalizeSettingsQuery(`terminal font gallery preview ${label} ${value}`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.style.setProperty("--terminal-font-choice-stack", stack);
    button.innerHTML = `
      <span class="terminal-font-choice-sample">
        <span>PS&gt; git status</span>
        <span>abc123 {} []</span>
      </span>
      <span class="terminal-font-choice-label"></span>
    `;
    button.querySelector(".terminal-font-choice-label").textContent = label;
    button.onclick = () => {
      const changed = updateSettings({ terminalFontFamily: value });
      if (!changed) toast(`${label} font already active.`);
      refreshTerminalFontChoices();
    };
    grid.append(button);
  }
  return grid;
}

function refreshTerminalFontChoices() {
  const fontSelect = elements.inspectorBody.querySelector('[data-setting-control="terminalFontFamily"]');
  if (fontSelect && fontSelect.value !== state.settings.terminalFontFamily) {
    fontSelect.value = state.settings.terminalFontFamily;
  }
  for (const button of elements.inspectorBody.querySelectorAll("[data-terminal-font-choice]")) {
    const active = button.dataset.terminalFontChoice === state.settings.terminalFontFamily;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
  }
}

function terminalSettingsPreviewPanel() {
  const panel = document.createElement("div");
  const colors = terminalTheme();
  const cursorStyle = state.settings.terminalCursorStyle || defaultSettings.terminalCursorStyle;
  panel.className = `terminal-settings-preview cursor-${cursorStyle}${state.settings.terminalCursorBlink ? " cursor-blink" : ""}`;
  panel.dataset.settingsSearch = normalizeSettingsQuery("terminal preview font size line height padding cursor blink color scrollback shell");
  panel.style.setProperty("--terminal-preview-background", colors.background);
  panel.style.setProperty("--terminal-preview-foreground", colors.foreground);
  panel.style.setProperty("--terminal-preview-cursor", colors.cursor);
  panel.style.setProperty("--terminal-preview-font", terminalFontStack());
  panel.style.setProperty("--terminal-preview-font-size", `${state.settings.terminalFontSize}px`);
  panel.style.setProperty("--terminal-preview-line-height", String(state.settings.terminalLineHeight));
  panel.style.setProperty("--terminal-preview-padding", `${state.settings.terminalPadding}px`);
  panel.innerHTML = `
    <div class="terminal-preview-screen" aria-hidden="true">
      <span class="terminal-preview-line prompt">PS C:\\app&gt; cmux status</span>
      <span class="terminal-preview-line ok">workspace ready · panes warm</span>
      <span class="terminal-preview-line">git status --short</span>
      <span class="terminal-preview-cursor"></span>
    </div>
    <div class="terminal-preview-meta">
      <span><b>Font</b><em data-terminal-preview-font></em></span>
      <span><b>Size</b><em data-terminal-preview-size></em></span>
      <span><b>Line</b><em data-terminal-preview-line></em></span>
      <span><b>Padding</b><em data-terminal-preview-padding></em></span>
      <span><b>Cursor</b><em data-terminal-preview-cursor></em></span>
      <span><b>History</b><em data-terminal-preview-history></em></span>
    </div>
  `;
  panel.querySelector("[data-terminal-preview-font]").textContent = optionLabel(terminalFontOptions, state.settings.terminalFontFamily, "Mono");
  panel.querySelector("[data-terminal-preview-size]").textContent = `${state.settings.terminalFontSize}px`;
  panel.querySelector("[data-terminal-preview-line]").textContent = formatLineHeight(state.settings.terminalLineHeight);
  panel.querySelector("[data-terminal-preview-padding]").textContent = `${state.settings.terminalPadding}px`;
  panel.querySelector("[data-terminal-preview-cursor]").textContent = `${optionLabel(terminalCursorStyles, cursorStyle, "Block")}${state.settings.terminalCursorBlink ? " blink" : ""}`;
  panel.querySelector("[data-terminal-preview-history]").textContent = String(state.settings.terminalScrollback);
  return panel;
}

function scheduleTerminalSettingsPreviewRefresh() {
  if (state.terminalSettingsPreviewFrame) return;
  state.terminalSettingsPreviewFrame = requestAnimationFrame(() => {
    state.terminalSettingsPreviewFrame = 0;
    refreshTerminalSettingsPreview();
  });
}

function refreshTerminalSettingsPreview() {
  const preview = elements.inspectorBody.querySelector(".terminal-settings-preview");
  if (preview) preview.replaceWith(terminalSettingsPreviewPanel());
  if (normalizeSettingsQuery(state.settingsQuery)) scheduleSettingsFilter();
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

function savedColorPalettePanel() {
  const panel = document.createElement("div");
  panel.className = "saved-color-panel";
  panel.dataset.settingsSearch = normalizeSettingsQuery("saved color palette custom accent workspace tab pane color save delete");

  const addRow = document.createElement("div");
  addRow.className = "saved-color-add";
  const colorInput = document.createElement("input");
  colorInput.className = "saved-color-input";
  colorInput.type = "color";
  colorInput.value = colorInputValue(state.settings.accent);
  colorInput.dataset.settingsSearch = normalizeSettingsQuery("saved color custom color picker hex");
  const savePicked = settingsActionButton("Save color", () => upsertCustomColorPalette(colorInput.value), "", "saved color custom palette add");
  addRow.append(colorInput, savePicked);
  panel.append(addRow);

  const actions = document.createElement("div");
  actions.className = "settings-actions saved-color-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("saved color palette save current accent workspace");
  const saveAccent = settingsActionButton("Save accent", () => upsertCustomColorPalette(state.settings.accent), "", "saved color save current accent");
  saveAccent.disabled = !normalizeCustomPaletteColor(state.settings.accent);
  const workspace = activeWorkspace();
  const saveWorkspace = settingsActionButton("Save workspace", () => upsertCustomColorPalette(workspace?.color), "", "saved color save workspace");
  saveWorkspace.disabled = !normalizeCustomPaletteColor(workspace?.color);
  actions.append(saveAccent, saveWorkspace);
  panel.append(actions);

  if (state.customColorPalette.length === 0) {
    const empty = document.createElement("div");
    empty.className = "saved-color-empty";
    empty.textContent = "Saved custom colors appear in accent, workspace, and pane color pickers.";
    panel.append(empty);
    return panel;
  }

  const list = document.createElement("div");
  list.className = "saved-color-list";
  for (const color of state.customColorPalette) {
    const card = document.createElement("div");
    card.className = "saved-color-card";
    card.dataset.settingsSearch = normalizeSettingsQuery(`saved color palette custom accent workspace ${color}`);
    const swatch = document.createElement("button");
    swatch.className = "saved-color-swatch";
    swatch.type = "button";
    swatch.title = `Use ${color} as accent`;
    swatch.style.setProperty("--saved-color", color);
    swatch.onclick = () => updateSettings({ accent: color });
    const value = document.createElement("div");
    value.className = "saved-color-value";
    value.textContent = color;
    const cardActions = document.createElement("div");
    cardActions.className = "saved-color-card-actions";
    cardActions.append(
      settingsActionButton("Accent", () => updateSettings({ accent: color }), "", `saved color apply accent ${color}`),
      settingsActionButton("Workspace", () => setWorkspaceColor(color), "", `saved color apply workspace ${color}`),
      settingsActionButton("Delete", () => deleteCustomColorPalette(color), "danger", `saved color delete ${color}`)
    );
    card.append(swatch, value, cardActions);
    list.append(card);
  }
  panel.append(list);
  return panel;
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
      const changed = updateSettings({ backgroundImage: preset.value });
      if (!changed) {
        toast(`${preset.label} background already active.`);
        return;
      }
      renderSettingsInspector();
    };
    grid.append(button);
  }
  return grid;
}

function savedBackgroundImagesPanel() {
  const panel = document.createElement("div");
  panel.className = "saved-background-panel";
  panel.dataset.settingsSearch = normalizeSettingsQuery("saved background image wallpaper library url file apply rename delete save");

  const addRow = document.createElement("div");
  addRow.className = "saved-background-add";
  const input = document.createElement("input");
  input.className = "setting-control saved-background-input";
  input.placeholder = "https://image-url";
  input.dataset.settingsSearch = normalizeSettingsQuery("saved background image url add");
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      upsertSavedBackgroundImage({ url: input.value });
      input.value = "";
    }
  });
  const saveUrl = settingsActionButton("Save URL", () => {
    if (upsertSavedBackgroundImage({ url: input.value })) input.value = "";
  }, "", "saved background image url add");
  addRow.append(input, saveUrl);
  panel.append(addRow);

  const actions = document.createElement("div");
  actions.className = "settings-actions saved-background-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("saved background current choose local file wallpaper");
  const saveCurrent = settingsActionButton("Save current", () => upsertSavedBackgroundImage({
    url: state.settings.backgroundImage
  }), "", "saved background image current");
  saveCurrent.disabled = !isCustomBackgroundImage(state.settings.backgroundImage);
  actions.append(
    saveCurrent,
    settingsActionButton("Choose + save", () => chooseBackgroundImage({ save: true }), "", "saved background image choose local file wallpaper")
  );
  panel.append(actions);

  if (state.savedBackgroundImages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "saved-background-empty";
    empty.textContent = "Save custom background images here so they can be reapplied without pasting the URL again.";
    panel.append(empty);
    return panel;
  }

  const list = document.createElement("div");
  list.className = "saved-background-list";
  for (const background of state.savedBackgroundImages) {
    const card = document.createElement("div");
    card.className = `saved-background-card${state.settings.backgroundImage === background.url ? " is-active" : ""}`;
    card.dataset.settingsSearch = normalizeSettingsQuery(`saved background image wallpaper ${background.label} ${background.url}`);
    const preview = document.createElement("button");
    preview.className = "saved-background-preview";
    preview.type = "button";
    preview.title = `Apply ${background.label}`;
    preview.style.setProperty("--saved-background-image", backgroundCss(background.url));
    preview.onclick = () => applySavedBackgroundImage(background.id);
    const text = document.createElement("div");
    text.className = "saved-background-text";
    const label = document.createElement("div");
    label.className = "saved-background-label";
    label.textContent = background.label;
    label.title = background.label;
    const url = document.createElement("div");
    url.className = "saved-background-url";
    url.textContent = background.url;
    url.title = background.url;
    text.append(label, url);
    const cardActions = document.createElement("div");
    cardActions.className = "saved-background-card-actions";
    cardActions.append(
      settingsActionButton("Apply", () => applySavedBackgroundImage(background.id), "", `apply saved background ${background.label}`),
      settingsActionButton("Rename", () => renameSavedBackgroundImage(background.id), "", `rename saved background ${background.label}`),
      settingsActionButton("Delete", () => deleteSavedBackgroundImage(background.id), "danger", `delete saved background ${background.label}`)
    );
    card.append(preview, text, cardActions);
    list.append(card);
  }
  panel.append(list);
  return panel;
}

function isActiveTerminalColorPreset(preset) {
  return state.settings.terminalBackground === preset.background
    && state.settings.terminalForeground === preset.foreground
    && state.settings.terminalCursorColor === preset.cursor;
}

function applyTerminalColorPreset(preset) {
  if (!preset) return;
  const changed = updateSettings({
    terminalBackground: preset.background,
    terminalForeground: preset.foreground,
    terminalCursorColor: preset.cursor
  });
  if (!changed) {
    toast(`${preset.label} terminal colors already active.`);
    return;
  }
  renderSettingsInspector();
  toast(`${preset.label} terminal colors applied.`);
}

function applyTerminalColorPresetById(presetId) {
  applyTerminalColorPreset(terminalColorPresets.find((preset) => preset.id === presetId));
}

function terminalColorPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "terminal-color-preset-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("terminal color theme preset powershell high contrast light warm graphite default");
  for (const preset of terminalColorPresets) {
    const button = document.createElement("button");
    const active = isActiveTerminalColorPreset(preset);
    button.className = `terminal-color-preset${active ? " is-active" : ""}`;
    button.type = "button";
    button.title = preset.body;
    button.setAttribute("aria-pressed", String(active));
    button.dataset.settingsSearch = normalizeSettingsQuery(`terminal color preset theme ${preset.label} ${preset.body}`);
    button.style.setProperty("--terminal-preset-background", preset.background || terminalColorDefaults.background);
    button.style.setProperty("--terminal-preset-foreground", preset.foreground || terminalColorDefaults.foreground);
    button.style.setProperty("--terminal-preset-cursor", preset.cursor || state.settings.accent || terminalColorDefaults.cursor);
    button.innerHTML = `
      <span class="terminal-color-preset-preview">
        <span class="terminal-color-preset-line"></span>
        <span class="terminal-color-preset-prompt"></span>
      </span>
      <span class="terminal-color-preset-text">
        <span class="terminal-color-preset-title"></span>
        <span class="terminal-color-preset-body"></span>
      </span>
    `;
    button.querySelector(".terminal-color-preset-line").textContent = "> cmux";
    button.querySelector(".terminal-color-preset-prompt").textContent = "_";
    button.querySelector(".terminal-color-preset-title").textContent = preset.label;
    button.querySelector(".terminal-color-preset-body").textContent = preset.body;
    button.onclick = () => applyTerminalColorPreset(preset);
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

function recentCommandsSettings() {
  const section = document.createElement("div");
  section.className = "recent-folder-list";
  section.dataset.settingsSearch = normalizeSettingsQuery("recent terminal commands shell command history run clear snippets");

  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Recent terminal commands";
  const clear = settingsActionButton("Clear", clearRecentCommands, "danger", "recent terminal commands clear history");
  clear.disabled = state.recentCommands.length === 0;
  header.append(title, clear);
  section.append(header);

  if (state.recentCommands.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Commands run from cmux will appear here.";
    section.append(empty);
    return section;
  }

  for (const command of state.recentCommands) {
    const card = document.createElement("div");
    card.className = "recent-folder-card";
    card.dataset.settingsSearch = normalizeSettingsQuery(`recent terminal command shell run ${command}`);
    const text = document.createElement("div");
    text.className = "recent-folder-text";
    const name = document.createElement("div");
    name.className = "recent-folder-name";
    name.textContent = command;
    name.title = command;
    const path = document.createElement("div");
    path.className = "recent-folder-path";
    path.textContent = "Active terminal";
    text.append(name, path);

    const actions = document.createElement("div");
    actions.className = "recent-folder-actions recent-command-actions";
    const run = settingsActionButton("Run", () => runTerminalCommand(command), "", `recent terminal command run ${command}`);
    run.dataset.recentCommandAction = "run";
    actions.append(run);
    card.append(text, actions);
    section.append(card);
  }

  return section;
}

function recentBrowserPagesSettings() {
  const section = document.createElement("div");
  section.className = "recent-folder-list";
  section.dataset.settingsSearch = normalizeSettingsQuery("recent browser pages urls web history open home clear");

  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Recent browser pages";
  const clear = settingsActionButton("Clear", clearRecentBrowserPages, "danger", "recent browser pages clear history");
  clear.disabled = state.recentBrowserPages.length === 0;
  header.append(title, clear);
  section.append(header);

  if (state.recentBrowserPages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Pages opened inside cmux will appear here.";
    section.append(empty);
    return section;
  }

  for (const url of state.recentBrowserPages) {
    const card = document.createElement("div");
    card.className = "recent-folder-card";
    card.dataset.settingsSearch = normalizeSettingsQuery(`recent browser page url web open home ${hostnameOf(url)} ${url}`);
    const text = document.createElement("div");
    text.className = "recent-folder-text";
    const name = document.createElement("div");
    name.className = "recent-folder-name";
    name.textContent = hostnameOf(url);
    name.title = url;
    const path = document.createElement("div");
    path.className = "recent-folder-path";
    path.textContent = url;
    path.title = url;
    text.append(name, path);

    const actions = document.createElement("div");
    actions.className = "recent-folder-actions command-snippet-actions is-built-in";
    const open = settingsActionButton("Open", () => createPanel("browser", "right", { url }), "", `recent browser page open ${url}`);
    open.dataset.recentBrowserAction = "open";
    const home = settingsActionButton("Home", () => {
      updateSettings({ browserHomeUrl: url });
      renderSettingsInspector();
      toast("Browser home updated.");
    }, "", `recent browser page home ${url}`);
    home.dataset.recentBrowserAction = "home";
    actions.append(open, home);
    card.append(text, actions);
    section.append(card);
  }

  return section;
}

function commandSnippetsSettings() {
  const wrapper = document.createElement("div");
  wrapper.className = "command-snippet-list";
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("command snippets terminal launcher saved built in custom git github gh cli add edit delete run");

  const customHeader = document.createElement("div");
  customHeader.className = "recent-folder-header";
  const customTitle = document.createElement("span");
  customTitle.textContent = "Saved snippets";
  const add = settingsActionButton("Add", addCustomCommandSnippet, "", "custom terminal command snippet add create");
  add.disabled = state.customCommandSnippets.length >= customCommandSnippetsLimit;
  customHeader.append(customTitle, add);
  wrapper.append(customHeader);

  if (state.customCommandSnippets.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Save commands you run often. They stay searchable from Settings and the command palette.";
    wrapper.append(empty);
  } else {
    for (const snippet of state.customCommandSnippets) {
      wrapper.append(commandSnippetCard({ ...snippet, builtIn: false }));
    }
  }

  const builtInHeader = document.createElement("div");
  builtInHeader.className = "command-snippet-group-title";
  builtInHeader.textContent = "Built-in snippets";
  wrapper.append(builtInHeader);
  for (const snippet of builtInTerminalCommandSnippets) {
    wrapper.append(commandSnippetCard({ ...snippet, builtIn: true }));
  }

  return wrapper;
}

function commandSnippetCard(snippet) {
  const card = document.createElement("div");
  card.className = "recent-folder-card command-snippet-card";
  card.dataset.settingsSearch = normalizeSettingsQuery(`command snippet terminal shell run ${snippet.builtIn ? "built in" : "custom saved"} ${snippet.label} ${snippet.command}`);

  const text = document.createElement("div");
  text.className = "recent-folder-text";
  const name = document.createElement("div");
  name.className = "recent-folder-name";
  name.textContent = snippet.label;
  name.title = snippet.label;
  const command = document.createElement("div");
  command.className = "recent-folder-path command-snippet-command";
  command.textContent = snippet.command;
  command.title = snippet.command;
  text.append(name, command);

  const actions = document.createElement("div");
  actions.className = `recent-folder-actions command-snippet-actions${snippet.builtIn ? " is-built-in" : ""}`;
  actions.append(settingsActionButton("Run", () => runTerminalCommand(snippet.command), "", `run command snippet ${snippet.label} ${snippet.command}`));
  if (snippet.builtIn) {
    actions.append(settingsActionButton("Save", () => saveBuiltInCommandSnippet(snippet), "", `save built in command snippet ${snippet.label}`));
  } else {
    actions.append(
      settingsActionButton("Edit", () => editCustomCommandSnippet(snippet.id), "", `edit custom command snippet ${snippet.label}`),
      settingsActionButton("Delete", () => deleteCustomCommandSnippet(snippet.id), "danger", `delete custom command snippet ${snippet.label}`)
    );
  }

  card.append(text, actions);
  return card;
}

async function addCustomCommandSnippet() {
  const details = await showCommandSnippetDialog({
    title: "Add command snippet",
    confirmLabel: "Save"
  });
  if (!details) return;
  const saved = upsertCustomCommandSnippet({
    id: createCustomCommandSnippetId(),
    label: details.label,
    command: details.command
  });
  if (!saved) return;
  renderSettingsInspector();
  toast("Command snippet saved.");
}

async function editCustomCommandSnippet(snippetId) {
  const snippet = state.customCommandSnippets.find((candidate) => candidate.id === snippetId);
  if (!snippet) return;
  const details = await showCommandSnippetDialog({
    title: "Edit command snippet",
    label: snippet.label,
    command: snippet.command,
    confirmLabel: "Save"
  });
  if (!details) return;
  const saved = upsertCustomCommandSnippet({
    id: snippet.id,
    label: details.label,
    command: details.command
  });
  if (!saved) return;
  renderSettingsInspector();
  toast("Command snippet updated.");
}

async function deleteCustomCommandSnippet(snippetId) {
  const snippet = state.customCommandSnippets.find((candidate) => candidate.id === snippetId);
  if (!snippet) return;
  if (!await showConfirmDialog({
    title: "Delete snippet",
    message: `Delete "${snippet.label}"?`,
    confirmLabel: "Delete",
    danger: true
  })) return;
  state.customCommandSnippets = state.customCommandSnippets.filter((candidate) => candidate.id !== snippetId);
  saveCustomCommandSnippets();
  renderSettingsInspector();
  toast("Command snippet deleted.");
}

function saveBuiltInCommandSnippet(snippet) {
  const commandKey = snippet.command.toLowerCase();
  if (state.customCommandSnippets.some((candidate) => candidate.command.toLowerCase() === commandKey)) {
    toast("Snippet is already saved.");
    return;
  }
  const saved = upsertCustomCommandSnippet({
    id: createCustomCommandSnippetId(),
    label: snippet.label,
    command: snippet.command
  });
  if (!saved) return;
  renderSettingsInspector();
  toast("Command snippet saved.");
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

async function chooseBackgroundImage(options = {}) {
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return;
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return;
  updateSettings({ backgroundImage: url });
  if (options.save) {
    upsertSavedBackgroundImage({ url }, { render: false, toast: false });
  }
  renderSettingsInspector();
  toast(options.save ? "Background image saved." : "Background image updated.");
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
  const changed = updateSettings(preset.settings);
  if (!changed) {
    toast(`${preset.label} settings already active.`);
    return;
  }
  renderSettingsInspector();
  toast(`${preset.label} settings applied.`);
}

function applySettingsPresetById(presetId) {
  const preset = settingsPresets.find((candidate) => candidate.id === presetId);
  if (!preset) return;
  applySettingsPreset(preset);
}

function settingsProfilesPanel() {
  const wrapper = document.createElement("div");
  wrapper.className = "settings-profile-list";
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("saved settings profile preset appearance layout terminal performance apply save rename delete");

  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Saved profiles";
  const save = settingsActionButton("Save", saveCurrentSettingsProfile, "", "save current settings profile preset");
  save.disabled = state.savedSettingsProfiles.length >= savedSettingsProfilesLimit;
  header.append(title, save);
  wrapper.append(header);

  if (state.savedSettingsProfiles.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Save your current colors, layout, terminal, and performance settings as a reusable profile.";
    wrapper.append(empty);
  } else {
    for (const profile of state.savedSettingsProfiles) {
      wrapper.append(settingsProfileCard(profile));
    }
  }

  const builtInTitle = document.createElement("div");
  builtInTitle.className = "command-snippet-group-title";
  builtInTitle.textContent = "Built-in profiles";
  wrapper.append(builtInTitle, settingsPresetGrid());
  return wrapper;
}

function settingsProfileCard(profile) {
  const card = document.createElement("div");
  card.className = "recent-folder-card settings-profile-card";
  card.dataset.settingsSearch = normalizeSettingsQuery(`saved settings profile preset apply rename delete ${profile.label} ${settingsProfileSummary(profile.settings)}`);

  const text = document.createElement("div");
  text.className = "recent-folder-text";
  const name = document.createElement("div");
  name.className = "recent-folder-name";
  name.textContent = profile.label;
  name.title = profile.label;
  const summary = document.createElement("div");
  summary.className = "recent-folder-path settings-profile-summary";
  summary.textContent = settingsProfileSummary(profile.settings);
  summary.title = summary.textContent;
  text.append(name, summary);

  const actions = document.createElement("div");
  actions.className = "recent-folder-actions settings-profile-actions";
  actions.append(
    settingsActionButton("Apply", () => applySavedSettingsProfile(profile.id), "", `apply settings profile ${profile.label}`),
    settingsActionButton("Rename", () => renameSavedSettingsProfile(profile.id), "", `rename settings profile ${profile.label}`),
    settingsActionButton("Delete", () => deleteSavedSettingsProfile(profile.id), "danger", `delete settings profile ${profile.label}`)
  );
  card.append(text, actions);
  return card;
}

async function saveCurrentSettingsProfile() {
  const label = await showTextDialog({
    title: "Save settings profile",
    message: "Save the current look, layout, terminal, and performance settings.",
    value: defaultSettingsProfileName(),
    placeholder: "Work setup",
    confirmLabel: "Save"
  });
  if (!label) return;
  const saved = upsertSavedSettingsProfile({
    id: createSettingsProfileId(),
    label,
    settings: state.settings,
    createdAt: Date.now()
  });
  if (!saved) return;
  renderSettingsInspector();
  toast("Settings profile saved.");
}

function defaultSettingsProfileName() {
  const base = "My profile";
  if (!state.savedSettingsProfiles.some((profile) => profile.label.toLowerCase() === base.toLowerCase())) {
    return base;
  }
  for (let index = 2; index <= savedSettingsProfilesLimit + 1; index += 1) {
    const label = `${base} ${index}`;
    if (!state.savedSettingsProfiles.some((profile) => profile.label.toLowerCase() === label.toLowerCase())) {
      return label;
    }
  }
  return base;
}

function applySavedSettingsProfile(profileId) {
  const profile = state.savedSettingsProfiles.find((candidate) => candidate.id === profileId);
  if (!profile) return;
  const changed = updateSettings(profile.settings);
  if (!changed) {
    toast(`${profile.label} profile already active.`);
    return;
  }
  renderSettingsInspector();
  toast(`${profile.label} profile applied.`);
}

async function renameSavedSettingsProfile(profileId) {
  const profile = state.savedSettingsProfiles.find((candidate) => candidate.id === profileId);
  if (!profile) return;
  const label = await showTextDialog({
    title: "Rename settings profile",
    value: profile.label,
    placeholder: "Profile name",
    confirmLabel: "Rename"
  });
  if (!label) return;
  const renamed = upsertSavedSettingsProfile({
    ...profile,
    label,
    createdAt: profile.createdAt
  });
  if (!renamed) return;
  renderSettingsInspector();
  toast("Settings profile renamed.");
}

async function deleteSavedSettingsProfile(profileId) {
  const profile = state.savedSettingsProfiles.find((candidate) => candidate.id === profileId);
  if (!profile) return;
  if (!await showConfirmDialog({
    title: "Delete profile",
    message: `Delete "${profile.label}"?`,
    confirmLabel: "Delete",
    danger: true
  })) return;
  state.savedSettingsProfiles = state.savedSettingsProfiles.filter((candidate) => candidate.id !== profileId);
  saveSavedSettingsProfiles();
  renderSettingsInspector();
  toast("Settings profile deleted.");
}

function workspaceBlueprintsPanel() {
  const wrapper = document.createElement("div");
  wrapper.className = "workspace-blueprint-list";
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("workspace blueprints saved layout pane template terminal browser split apply new save rename delete");

  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Saved blueprints";
  const save = settingsActionButton("Save", saveCurrentWorkspaceBlueprint, "", "save current workspace blueprint layout");
  save.disabled = state.workspaceBlueprints.length >= workspaceBlueprintsLimit || (activeWorkspace()?.panels.length || 0) === 0;
  header.append(title, save);
  wrapper.append(header);

  if (state.workspaceBlueprints.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Save a workspace pane setup, then recreate it later as a new workspace or add it to the current one.";
    wrapper.append(empty);
  } else {
    for (const blueprint of state.workspaceBlueprints) {
      wrapper.append(workspaceBlueprintCard(blueprint));
    }
  }

  const starterTitle = document.createElement("div");
  starterTitle.className = "command-snippet-group-title";
  starterTitle.textContent = "Starter layouts";
  wrapper.append(starterTitle, workspaceStarterGrid());
  return wrapper;
}

function workspaceBlueprintCard(blueprint) {
  const card = document.createElement("div");
  card.className = "recent-folder-card workspace-blueprint-card";
  card.dataset.settingsSearch = normalizeSettingsQuery(`workspace blueprint saved layout pane template ${blueprint.label} ${workspaceBlueprintSummary(blueprint)}`);

  const text = document.createElement("div");
  text.className = "recent-folder-text";
  const name = document.createElement("div");
  name.className = "recent-folder-name";
  name.textContent = blueprint.label;
  name.title = blueprint.label;
  const summary = document.createElement("div");
  summary.className = "recent-folder-path workspace-blueprint-summary";
  summary.textContent = workspaceBlueprintSummary(blueprint);
  summary.title = summary.textContent;
  text.append(name, summary);

  const actions = document.createElement("div");
  actions.className = "recent-folder-actions workspace-blueprint-actions";
  actions.append(
    settingsActionButton("New", () => createWorkspaceFromBlueprint(blueprint.id), "", `new workspace from blueprint ${blueprint.label}`),
    settingsActionButton("Add", () => applyWorkspaceBlueprint(blueprint.id), "", `add apply workspace blueprint ${blueprint.label}`),
    settingsActionButton("Rename", () => renameWorkspaceBlueprint(blueprint.id), "", `rename workspace blueprint ${blueprint.label}`),
    settingsActionButton("Delete", () => deleteWorkspaceBlueprint(blueprint.id), "danger", `delete workspace blueprint ${blueprint.label}`)
  );
  card.append(text, actions);
  return card;
}

function currentWorkspaceBlueprintSnapshot(label) {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length === 0) return null;
  const direction = paneLayoutDirection(workspace);
  if (!state.zoomedPanelId && workspace.id === state.data?.activeWorkspaceId) {
    persistPaneLayoutFromGrid(direction);
  }
  const equalWeight = Math.round(paneLayoutScale / Math.max(1, workspace.panels.length));
  return normalizeWorkspaceBlueprint({
    id: createWorkspaceBlueprintId(),
    label,
    splitDirection: direction,
    color: workspace.color || "",
    cwd: workspace.cwd || "",
    panels: workspace.panels.slice(0, workspaceBlueprintPanelLimit).map((panel) => ({
      type: panel.type,
      title: panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal"),
      color: panel.color || "",
      cwd: panel.cwd || workspace.cwd || "",
      shellProfile: panel.shellProfile || state.settings.terminalProfile,
      shellPath: panel.shellPath || "",
      url: panel.url || state.settings.browserHomeUrl,
      weight: storedPaneWeight(panel.id, direction) || equalWeight
    }))
  });
}

async function saveCurrentWorkspaceBlueprint() {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length === 0) {
    toast("Open panes before saving a blueprint.");
    return;
  }
  const label = await showTextDialog({
    title: "Save workspace blueprint",
    message: "Save the current pane mix, order, colors, and split direction.",
    value: defaultWorkspaceBlueprintName(workspace),
    placeholder: "Dev workspace",
    confirmLabel: "Save"
  });
  if (!label) return;
  const saved = upsertWorkspaceBlueprint(currentWorkspaceBlueprintSnapshot(label));
  if (!saved) return;
  renderSettingsInspector();
  toast("Workspace blueprint saved.");
}

function defaultWorkspaceBlueprintName(workspace = activeWorkspace()) {
  const base = `${workspace?.title || "Workspace"} layout`;
  if (!state.workspaceBlueprints.some((blueprint) => blueprint.label.toLowerCase() === base.toLowerCase())) {
    return base;
  }
  for (let index = 2; index <= workspaceBlueprintsLimit + 1; index += 1) {
    const label = `${base} ${index}`;
    if (!state.workspaceBlueprints.some((blueprint) => blueprint.label.toLowerCase() === label.toLowerCase())) {
      return label;
    }
  }
  return base;
}

async function createWorkspaceFromBlueprint(blueprintId) {
  const blueprint = state.workspaceBlueprints.find((candidate) => candidate.id === blueprintId);
  if (!blueprint) return;
  const workspace = await createWorkspace({
    title: blueprint.label,
    cwd: blueprint.cwd || activeWorkspace()?.cwd
  });
  const createdWorkspace = state.data?.workspaces.find((candidate) => candidate.id === workspace.id);
  const defaultPanels = createdWorkspace?.panels.map((panel) => panel.id) || [];
  for (const panelId of defaultPanels) {
    await api(`/api/panels/${panelId}`, { method: "DELETE" });
  }
  await applyWorkspaceBlueprint(blueprintId, workspace.id, { newWorkspace: true });
}

async function applyWorkspaceBlueprint(blueprintId, workspaceId = activeWorkspace()?.id, options = {}) {
  const blueprint = state.workspaceBlueprints.find((candidate) => candidate.id === blueprintId);
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!blueprint || !workspace) {
    toast("No workspace available.");
    return;
  }
  clearPaneLayoutsForWorkspace(workspace);
  try {
    const createdPanels = [];
    for (const panel of blueprint.panels) {
      const created = await createPanel(panel.type, blueprint.splitDirection, {
        workspaceId: workspace.id,
        focus: false,
        reconcile: false,
        title: panel.title,
        color: panel.color,
        cwd: panel.cwd || blueprint.cwd || workspace.cwd,
        shellProfile: panel.shellProfile,
        shellPath: panel.shellPath,
        url: panel.url
      });
      if (created?.id) createdPanels.push({ id: created.id, weight: panel.weight });
    }
    for (const created of createdPanels) {
      setStoredPaneWeight(created.id, blueprint.splitDirection, created.weight);
    }
    savePaneLayouts();
    await api(`/api/workspaces/${workspace.id}`, {
      method: "PATCH",
      body: JSON.stringify({
        color: blueprint.color || workspace.color,
        cwd: blueprint.cwd || workspace.cwd
      })
    });
    await loadState();
    if (workspace.id !== state.data?.activeWorkspaceId) await focusWorkspace(workspace.id);
    toast(options.newWorkspace ? `${blueprint.label} workspace created.` : `${blueprint.label} added.`);
  } catch {
    await loadState();
    toast("Workspace blueprint could not be applied.");
  }
}

async function renameWorkspaceBlueprint(blueprintId) {
  const blueprint = state.workspaceBlueprints.find((candidate) => candidate.id === blueprintId);
  if (!blueprint) return;
  const label = await showTextDialog({
    title: "Rename workspace blueprint",
    value: blueprint.label,
    placeholder: "Blueprint name",
    confirmLabel: "Rename"
  });
  if (!label) return;
  const renamed = upsertWorkspaceBlueprint({
    ...blueprint,
    label,
    createdAt: blueprint.createdAt
  });
  if (!renamed) return;
  renderSettingsInspector();
  toast("Workspace blueprint renamed.");
}

async function deleteWorkspaceBlueprint(blueprintId) {
  const blueprint = state.workspaceBlueprints.find((candidate) => candidate.id === blueprintId);
  if (!blueprint) return;
  if (!await showConfirmDialog({
    title: "Delete blueprint",
    message: `Delete "${blueprint.label}"?`,
    confirmLabel: "Delete",
    danger: true
  })) return;
  state.workspaceBlueprints = state.workspaceBlueprints.filter((candidate) => candidate.id !== blueprintId);
  saveWorkspaceBlueprints();
  renderSettingsInspector();
  toast("Workspace blueprint deleted.");
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
  menu.className = "context-menu";
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
    contextMenuButton("Find", () => openTerminalSearch(panel), !isTerminal),
    contextMenuButton("Find next", () => findNextInTerminal(panel), !isTerminal),
    contextMenuButton("Copy selection", () => copyActiveTerminalSelection(panel), !isTerminal),
    contextMenuButton("Paste", () => pasteClipboardToTerminal(panel), !isTerminal),
    contextMenuButton("Clear terminal", () => clearTerminalPanel(panel), !isTerminal),
    contextMenuButton("Restart terminal", () => restartPanel(panel.id), !isTerminal),
    contextMenuButton("Terminal settings", () => openSettingsCategory("terminal"), !isTerminal),
    contextMenuButton(panel.id === state.zoomedPanelId ? "Show all panes" : "Focus pane", () => togglePaneZoom(panel.id)),
    contextMenuButton("Move left", () => movePanelLeft(found.workspace, index), index <= 0),
    contextMenuButton("Move right", () => movePanelRight(found.workspace, index), index >= found.workspace.panels.length - 1),
    contextMenuButton("Close other panes", () => closeOtherPanes(panel.id), found.workspace.panels.length <= 1, "danger"),
    contextMenuButton("Close panes to right", () => closePanelsById(panesToRight.map((candidate) => candidate.id)), panesToRight.length === 0, "danger"),
    contextMenuButton("Close", () => closePanel(panel.id), false, "danger")
  );
  const colorTitle = document.createElement("div");
  colorTitle.className = "context-section-title";
  colorTitle.textContent = "Pane color";
  const colors = document.createElement("div");
  colors.className = "context-colors";
  for (const color of workspaceColorPalette()) {
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
  menu.replaceChildren(title, actions, colorTitle, colors, customColor, clear);
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function showWorkspaceContextMenu(event, workspace) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  menu.className = "context-menu";
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
  for (const color of workspaceColorPalette()) {
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
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function showToolbarMenu(event) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  menu.className = "context-menu context-menu-tools";
  const panel = activePanel();
  const workspace = activeWorkspace();
  const multiPane = Boolean(panel && workspace?.panels.length > 1);
  const multiWorkspace = (state.data?.workspaces.length || 0) > 1;
  const terminalActive = panel?.type === "terminal";
  const latestBrowserPage = state.recentBrowserPages[0] || "";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = workspace?.title || "Workspace tools";
  menu.replaceChildren(
    title,
    contextMenuSectionTitle("Pane"),
    contextMenuActionGroup(
      contextMenuButton("Split right", () => createPanel("terminal", "right")),
      contextMenuButton("Split down", () => createPanel("terminal", "down")),
      contextMenuButton("Duplicate active pane", duplicateActivePanel, !panel),
      contextMenuButton("Reopen closed pane", reopenClosedPanel, state.closedPanels.length === 0),
      contextMenuButton(state.zoomedPanelId ? "Show all panes" : "Focus active pane", () => togglePaneZoom(), !panel),
      contextMenuButton("Next pane", () => cycleActivePane(1), !multiPane),
      contextMenuButton("Previous pane", () => cycleActivePane(-1), !multiPane)
    ),
    contextMenuSectionTitle("Layout"),
    contextMenuActionGroup(
      contextMenuButton("Reset split layout", resetActivePaneLayout, !multiPane),
      contextMenuButton("Reset workspace chrome", resetWorkspaceChrome),
      contextMenuButton("Equalize panes", () => applyPaneLayoutPreset("equal"), !multiPane),
      contextMenuButton("Active pane wide", () => applyPaneLayoutPreset("activeWide"), !multiPane),
      contextMenuButton("Active pane tall", () => applyPaneLayoutPreset("activeTall"), !multiPane),
      contextMenuButton("Close other panes", () => closeOtherPanes(), !multiPane, "danger")
    ),
    contextMenuSectionTitle("Terminal"),
    contextMenuActionGroup(
      contextMenuButton("Run command...", promptRunTerminalCommand, !terminalActive),
      contextMenuButton("Git status", () => runTerminalCommandSnippet("gitStatus"), !terminalActive),
      contextMenuButton("GH PR status", () => runTerminalCommandSnippet("ghPrStatus"), !terminalActive),
      contextMenuButton("Find in terminal", openTerminalSearch, !terminalActive),
      contextMenuButton("Find next", findNextInTerminal, !terminalActive),
      contextMenuButton("Copy terminal selection", copyActiveTerminalSelection, !terminalActive),
      contextMenuButton("Paste to terminal", pasteClipboardToTerminal, !terminalActive),
      contextMenuButton("Clear active terminal", clearActiveTerminal, !terminalActive),
      contextMenuButton("Restart terminal", restartActiveTerminal, !terminalActive),
      contextMenuButton("Terminal settings", () => openSettingsCategory("terminal")),
      contextMenuButton("Reset terminal colors", () => applyTerminalColorPresetById("cmux"))
    ),
    contextMenuSectionTitle("Browser"),
    contextMenuActionGroup(
      contextMenuButton("Open browser", () => openBrowserPrompt(workspace?.id)),
      contextMenuButton("Open home page", () => createPanel("browser", "right", { workspaceId: workspace?.id, url: state.settings.browserHomeUrl }), !workspace),
      contextMenuButton(latestBrowserPage ? `Open recent: ${hostnameOf(latestBrowserPage)}` : "Open recent page", () => createPanel("browser", "right", { workspaceId: workspace?.id, url: latestBrowserPage }), !latestBrowserPage || !workspace),
      contextMenuButton("Browser settings", () => openSettingsCategory("browser"))
    ),
    contextMenuSectionTitle("Workspace"),
    contextMenuActionGroup(
      contextMenuButton("Next workspace", () => cycleWorkspace(1), !multiWorkspace),
      contextMenuButton("Previous workspace", () => cycleWorkspace(-1), !multiWorkspace),
      contextMenuButton("Rename workspace", renameActiveWorkspace),
      contextMenuButton("Change workspace color", cycleWorkspaceColor),
      contextMenuButton("Change workspace folder", () => chooseWorkspaceFolder(), !workspace),
      contextMenuButton("Open workspace folder", () => openWorkspaceFolder(), !workspace?.cwd),
      contextMenuButton("New workspace from folder", () => createWorkspaceFromFolder()),
      contextMenuButton("Save workspace blueprint", saveCurrentWorkspaceBlueprint, !panel)
    ),
    contextMenuSectionTitle("Settings"),
    contextMenuActionGroup(
      contextMenuButton("Performance settings", () => openSettingsCategory("performance")),
      contextMenuButton("Tune performance now", () => tunePerformanceNow()),
      contextMenuButton("Copy performance diagnostics", copyPerformanceDiagnostics),
      contextMenuButton("Apply speed preset", () => applySettingsPresetById("performance")),
      contextMenuButton("Actions settings", () => openSettingsCategory("actions")),
      contextMenuButton("Command snippets", () => openSettingsCategory("commands")),
      contextMenuButton("Settings profiles", () => openSettingsCategory("profiles")),
      contextMenuButton("Clear recent activity", clearRecentActivity, !hasRecentActivity(), "danger"),
      contextMenuButton("Color settings", () => openSettingsCategory("appearance")),
      contextMenuButton("Save current accent", () => upsertCustomColorPalette(state.settings.accent), !normalizeCustomPaletteColor(state.settings.accent)),
      contextMenuButton("Background settings", () => openSettingsCategory("appearance")),
      contextMenuButton("Save current background", () => upsertSavedBackgroundImage({ url: state.settings.backgroundImage }), !isCustomBackgroundImage(state.settings.backgroundImage)),
      contextMenuButton("Workspace blueprints", () => openSettingsCategory("blueprints"))
    ),
    contextMenuSectionTitle("Session"),
    contextMenuActionGroup(
      contextMenuButton("Notifications", () => openInspector("notifications")),
      contextMenuButton("Session tools", () => openInspector("session")),
      contextMenuButton("Reset session", resetSession, false, "danger")
    )
  );
  const rect = event.currentTarget.getBoundingClientRect();
  showContextMenuAt(menu, rect.left, rect.bottom + 6);
}

function showContextMenuAt(menu, preferredX, preferredY) {
  menu.hidden = false;
  const margin = 8;
  const rect = menu.getBoundingClientRect();
  const x = Math.min(preferredX, window.innerWidth - rect.width - margin);
  const y = Math.min(preferredY, window.innerHeight - rect.height - margin);
  menu.style.left = `${Math.max(margin, x)}px`;
  menu.style.top = `${Math.max(margin, y)}px`;
}

function contextMenuSectionTitle(label) {
  const title = document.createElement("div");
  title.className = "context-section-title";
  title.textContent = label;
  return title;
}

function contextMenuActionGroup(...actions) {
  const group = document.createElement("div");
  group.className = "context-actions";
  group.append(...actions);
  return group;
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

function showCommandSnippetDialog({
  title = "Command snippet",
  label = "",
  command = "",
  confirmLabel = "Save",
  cancelLabel = "Cancel"
} = {}) {
  if (state.activeDialog) state.activeDialog.close(null);
  const previousFocus = document.activeElement;
  const overlay = document.createElement("div");
  overlay.className = "dialog-backdrop";
  overlay.innerHTML = `
    <div class="app-dialog" role="dialog" aria-modal="true">
      <div class="dialog-title"></div>
      <div class="dialog-message"></div>
      <div class="dialog-field dialog-field-grid"></div>
      <div class="dialog-actions">
        <button class="dialog-button dialog-cancel" type="button"></button>
        <button class="dialog-button primary dialog-confirm" type="button"></button>
      </div>
    </div>
  `;
  overlay.querySelector(".dialog-title").textContent = title;
  const message = overlay.querySelector(".dialog-message");
  message.textContent = "Name the command and keep the exact shell text you want to send.";
  const field = overlay.querySelector(".dialog-field");
  const cancel = overlay.querySelector(".dialog-cancel");
  const confirm = overlay.querySelector(".dialog-confirm");
  cancel.textContent = cancelLabel;
  confirm.textContent = confirmLabel;

  const nameInput = document.createElement("input");
  nameInput.className = "dialog-input";
  nameInput.type = "text";
  nameInput.placeholder = "Git push";
  nameInput.value = label;
  const commandInput = document.createElement("input");
  commandInput.className = "dialog-input";
  commandInput.type = "text";
  commandInput.placeholder = "git push";
  commandInput.value = command;
  field.append(
    dialogInputRow("Name", nameInput),
    dialogInputRow("Command", commandInput)
  );

  return new Promise((resolve) => {
    const cleanup = (result) => {
      overlay.remove();
      state.activeDialog = null;
      if (previousFocus?.focus) previousFocus.focus();
      resolve(result);
    };
    const submit = () => {
      const normalizedCommand = normalizeTerminalCommand(commandInput.value);
      if (!normalizedCommand) {
        commandInput.focus();
        toast("Enter a command first.");
        return;
      }
      cleanup({
        label: normalizeSnippetLabel(nameInput.value, normalizedCommand),
        command: normalizedCommand
      });
    };
    state.activeDialog = { close: cleanup };
    cancel.onclick = () => cleanup(null);
    confirm.onclick = submit;
    overlay.addEventListener("mousedown", (event) => {
      if (event.target === overlay) cleanup(null);
    });
    overlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        cleanup(null);
      }
      if (event.key === "Enter") {
        event.preventDefault();
        submit();
      }
    });
    document.body.append(overlay);
    requestAnimationFrame(() => {
      nameInput.focus();
      nameInput.select();
    });
  });
}

function dialogInputRow(label, input) {
  const row = document.createElement("label");
  row.className = "dialog-field-row";
  const text = document.createElement("span");
  text.className = "dialog-field-label";
  text.textContent = label;
  row.append(text, input);
  return row;
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

function schedulePaletteRender() {
  if (state.paletteRenderFrame || state.paletteRenderTimer) return;
  const run = () => {
    if (state.paletteRenderFrame) cancelAnimationFrame(state.paletteRenderFrame);
    if (state.paletteRenderTimer) clearTimeout(state.paletteRenderTimer);
    state.paletteRenderFrame = 0;
    state.paletteRenderTimer = 0;
    renderPalette();
  };
  state.paletteRenderFrame = requestAnimationFrame(run);
  state.paletteRenderTimer = setTimeout(run, 50);
}

function flushPaletteRender() {
  if (!state.paletteRenderFrame && !state.paletteRenderTimer) return;
  if (state.paletteRenderFrame) cancelAnimationFrame(state.paletteRenderFrame);
  if (state.paletteRenderTimer) clearTimeout(state.paletteRenderTimer);
  state.paletteRenderFrame = 0;
  state.paletteRenderTimer = 0;
  renderPalette();
}

function renderPalette() {
  elements.palette.classList.toggle("is-open", state.paletteOpen);
  elements.palette.setAttribute("aria-hidden", String(!state.paletteOpen));
  if (!state.paletteOpen) return;

  const query = normalizeSettingsQuery(elements.paletteInput.value);
  const tokens = settingsSearchTokens(query);
  const matches = paletteEntries()
    .filter((entry) => paletteEntryMatches(entry, tokens))
    .sort((left, right) => paletteEntryScore(right, query, tokens) - paletteEntryScore(left, query, tokens));
  state.paletteIndex = Math.min(state.paletteIndex, Math.max(0, matches.length - 1));
  const signature = paletteListSignature(query, matches);
  if (signature === state.paletteListSignature) {
    updatePaletteSelection();
    return;
  }
  state.paletteListSignature = signature;
  const nodes = matches.map((entry, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `palette-item${index === state.paletteIndex ? " is-selected" : ""}`;
    button.setAttribute("aria-selected", String(index === state.paletteIndex));
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

function paletteListSignature(query, entries) {
  return stableJson({
    query,
    entries: entries.map((entry) => [
      entry.id,
      entry.label,
      entry.meta,
      entry.shortcut
    ])
  });
}

function updatePaletteSelection() {
  const items = [...elements.paletteList.querySelectorAll(".palette-item")];
  for (const [index, item] of items.entries()) {
    const selected = index === state.paletteIndex;
    const classChanged = toggleClassIfChanged(item, "is-selected", selected);
    const ariaSelected = String(selected);
    const ariaChanged = item.getAttribute("aria-selected") !== ariaSelected;
    if (ariaChanged) item.setAttribute("aria-selected", ariaSelected);
    if (selected && (classChanged || ariaChanged)) item.scrollIntoView({ block: "nearest" });
  }
}

function movePaletteSelection(delta) {
  const count = elements.paletteList.querySelectorAll(".palette-item").length;
  if (!count) return;
  const nextIndex = Math.max(0, Math.min(count - 1, state.paletteIndex + delta));
  if (nextIndex === state.paletteIndex) return;
  state.paletteIndex = nextIndex;
  updatePaletteSelection();
}

function paletteEntryMatches(entry, tokens) {
  if (!tokens.length) return true;
  return tokens.every((group) => group.some((token) => entry.search.includes(token)));
}

function paletteEntryScore(entry, query, tokens) {
  if (!query) return 0;
  let score = 0;
  if (entry.search.includes(query)) score += 8;
  if (entry.search.startsWith(query)) score += 4;
  const label = normalizeSettingsQuery(entry.label);
  if (label.includes(query)) score += 2;
  if (tokens.every((group) => group.some((token) => label.includes(token)))) score += 2;
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
  for (const [commandIndex, command] of state.recentCommands.entries()) {
    entries.push({
      id: `recentCommand.${commandIndex}`,
      label: `Run recent: ${command}`,
      meta: "Terminal command",
      shortcut: "Recent",
      search: normalizeSettingsQuery(`recent terminal command shell run ${commandIndex + 1} ${command}`),
      run: () => runTerminalCommand(command)
    });
  }
  for (const [pageIndex, url] of state.recentBrowserPages.entries()) {
    entries.push({
      id: `recentBrowser.${pageIndex}`,
      label: `Open recent page: ${hostnameOf(url)}`,
      meta: url,
      shortcut: "Browser",
      search: normalizeSettingsQuery(`recent browser page web url open ${pageIndex + 1} ${hostnameOf(url)} ${url}`),
      run: () => createPanel("browser", "right", { url })
    });
  }
  for (const snippet of allTerminalCommandSnippets()) {
    entries.push({
      id: `commandSnippet.${snippet.id}`,
      label: `Snippet: ${snippet.label}`,
      meta: snippet.builtIn ? "Built-in terminal snippet" : "Saved terminal snippet",
      shortcut: "Snippet",
      search: normalizeSettingsQuery(`terminal command snippet shell run ${snippet.builtIn ? "built in" : "custom saved"} ${snippet.label} ${snippet.command}`),
      run: () => runTerminalCommandSnippet(snippet.id)
    });
  }
  for (const preset of terminalColorPresets) {
    entries.push({
      id: `terminalColor.${preset.id}`,
      label: `Terminal colors: ${preset.label}`,
      meta: preset.body,
      shortcut: "Theme",
      search: normalizeSettingsQuery(`terminal colors theme preset ${preset.label} ${preset.body}`),
      run: () => applyTerminalColorPreset(preset)
    });
  }
  for (const color of state.customColorPalette) {
    entries.push({
      id: `savedColor.accent.${color.slice(1)}`,
      label: `Accent color: ${color}`,
      meta: "Saved color",
      shortcut: "Color",
      search: normalizeSettingsQuery(`saved color palette custom accent ${color}`),
      run: () => updateSettings({ accent: color })
    });
    entries.push({
      id: `savedColor.workspace.${color.slice(1)}`,
      label: `Workspace color: ${color}`,
      meta: activeWorkspace()?.title || "Active workspace",
      shortcut: "Color",
      search: normalizeSettingsQuery(`saved color palette custom workspace pane tab ${color}`),
      run: () => setWorkspaceColor(color)
    });
  }
  for (const background of state.savedBackgroundImages) {
    entries.push({
      id: `savedBackground.${background.id}`,
      label: `Background: ${background.label}`,
      meta: background.url,
      shortcut: "Look",
      search: normalizeSettingsQuery(`saved background image wallpaper apply ${background.label} ${background.url}`),
      run: () => applySavedBackgroundImage(background.id)
    });
  }
  for (const profile of state.savedSettingsProfiles) {
    entries.push({
      id: `settingsProfile.${profile.id}`,
      label: `Profile: ${profile.label}`,
      meta: settingsProfileSummary(profile.settings),
      shortcut: "Profile",
      search: normalizeSettingsQuery(`settings profile preset saved apply ${profile.label} ${settingsProfileSummary(profile.settings)}`),
      run: () => applySavedSettingsProfile(profile.id)
    });
  }
  for (const blueprint of state.workspaceBlueprints) {
    entries.push({
      id: `workspaceBlueprint.${blueprint.id}`,
      label: `Blueprint: ${blueprint.label}`,
      meta: workspaceBlueprintSummary(blueprint),
      shortcut: "Blueprint",
      search: normalizeSettingsQuery(`workspace blueprint layout template new add apply ${blueprint.label} ${workspaceBlueprintSummary(blueprint)}`),
      run: () => createWorkspaceFromBlueprint(blueprint.id)
    });
  }
  for (const [id, label] of settingsCategories.filter(([id]) => id !== "all")) {
    entries.push({
      id: `settings.${id}`,
      label: `Settings: ${label}`,
      meta: "Settings category",
      shortcut: "Settings",
      search: normalizeSettingsQuery(`settings preferences customize ${label} ${id} ${settingsCategorySearchAliases.get(id) || ""}`),
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
  const palette = workspaceColorPalette();
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
  return withUiOperation("workspace-starter", "create-panel", `Adding ${starter.label}...`, async () => {
    clearPaneLayoutsForWorkspace(workspace);
    try {
      for (const type of starter.panels) {
        await createPanel(type, "right", {
          workspaceId: workspace.id,
          focus: false,
          reconcile: false,
          operation: false,
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
  });
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
  if (options.operation !== false && hasUiOperationKind("create-panel")) {
    toast("Pane is still being added.");
    return null;
  }
  const addPanel = async () => {
    const workspace = options.workspaceId
      ? state.data?.workspaces.find((candidate) => candidate.id === options.workspaceId)
      : activeWorkspace();
    if (!workspace) return null;
    const shellProfile = options.shellProfile || state.settings.terminalProfile;
    const shellPath = options.shellPath || state.settings.terminalCustomShell;
    const url = type === "browser"
      ? normalizeUrl(options.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl)
      : undefined;
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
        url
      })
    });
    if (type === "browser" && createdPanel?.url) rememberRecentBrowserPage(createdPanel.url);
    if (options.reconcile !== false) {
      await loadState();
      if (options.focus !== false && workspace.id !== state.data?.activeWorkspaceId) {
        await focusWorkspace(workspace.id);
      }
    }
    return createdPanel;
  };
  if (options.operation === false) return addPanel();
  const label = options.operationLabel
    || `Adding ${type === "browser" ? "browser" : "terminal"} pane...`;
  return withUiOperation("create-panel", "create-panel", label, addPanel);
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

function queueFocusSync(sync) {
  if (!sync?.workspaceId && !sync?.panelId) return;
  const revision = state.focusSyncRevision + 1;
  state.focusSyncRevision = revision;
  state.pendingFocusSync = { ...sync, revision };
  if (state.focusSyncTimer) clearTimeout(state.focusSyncTimer);
  state.focusSyncTimer = setTimeout(() => flushFocusSync(revision), 70);
}

async function flushFocusSync(revision = state.focusSyncRevision) {
  const sync = state.pendingFocusSync;
  if (!sync || sync.revision !== revision) return;
  state.focusSyncTimer = 0;
  try {
    if (sync.type === "workspace") {
      await api(`/api/workspaces/${sync.workspaceId}/focus`, { method: "POST" });
    } else if (sync.type === "panel") {
      await api(`/api/panels/${sync.panelId}/focus`, { method: "POST" });
    }
  } catch {
    // Reconcile below; the target may have disappeared while the user kept working.
  } finally {
    if (state.pendingFocusSync?.revision === revision) {
      state.pendingFocusSync = null;
      await loadState();
    }
  }
}

function queueBrowserUrlSync(panelId, value) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "browser") return false;
  const url = normalizeUrl(value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  rememberRecentBrowserPage(url);
  if (found.panel.url !== url) {
    const shouldRender = browserUrlChangeNeedsRender(found.panel, url);
    found.panel.url = url;
    if (shouldRender) scheduleRender();
    else state.renderStats.browserUrlRenderSkips += 1;
  }
  state.pendingBrowserUrlSync.set(panelId, url);
  if (state.browserUrlSyncTimer) clearTimeout(state.browserUrlSyncTimer);
  state.browserUrlSyncTimer = setTimeout(flushBrowserUrlSync, 180);
  return true;
}

async function flushBrowserUrlSync() {
  state.browserUrlSyncTimer = 0;
  const entries = [...state.pendingBrowserUrlSync.entries()];
  state.pendingBrowserUrlSync.clear();
  await Promise.all(entries.map(async ([panelId, url]) => {
    const found = findPanelState(panelId);
    if (!found || found.panel.type !== "browser" || found.panel.url !== url) return;
    try {
      await api(`/api/panels/${panelId}`, {
        method: "PATCH",
        body: JSON.stringify({ url })
      });
    } catch {
      // The pane may have been closed before the debounce fired.
    }
  }));
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
  if (!panelId || isUiOperationActive(`close-panel:${panelId}`)) return;
  return withUiOperation(`close-panel:${panelId}`, "close-panel", "Closing pane...", async () => {
    rememberClosedPanel(panelId);
    optimisticClosePanel(panelId);
    try {
      await api(`/api/panels/${panelId}`, { method: "DELETE" });
      await loadState();
    } catch {
      await loadState();
    }
  });
}

async function closePanelsById(panelIds) {
  const ids = [...new Set(panelIds.filter(Boolean))];
  if (ids.length === 0) return;
  const key = `close-panels:${ids.slice().sort().join(",")}`;
  if (isUiOperationActive(key)) return;
  const label = ids.length === 1 ? "Closing pane..." : `Closing ${ids.length} panes...`;
  return withUiOperation(key, "close-panel", label, async () => {
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
  });
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
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return;
  if (state.data?.activeWorkspaceId === workspaceId) {
    focusTerminalSession(workspace.activePanelId);
    return;
  }
  optimisticFocusWorkspace(workspaceId);
  queueFocusSync({ type: "workspace", workspaceId });
  focusTerminalSession(workspace.activePanelId);
}

async function focusPanel(panelId) {
  const found = findPanelState(panelId);
  if (found && state.data?.activeWorkspaceId === found.workspace.id && found.workspace.activePanelId === panelId) {
    focusTerminalSession(panelId);
    return;
  }
  if (!optimisticFocusPanel(panelId)) return;
  queueFocusSync({ type: "panel", panelId });
  focusTerminalSession(panelId);
}

function cycleActivePane(delta = 1) {
  const workspace = activeWorkspace();
  const panels = workspace?.panels || [];
  if (panels.length === 0) return false;
  const activeIndex = panels.findIndex((panel) => panel.id === workspace.activePanelId);
  const currentIndex = activeIndex >= 0 ? activeIndex : 0;
  const nextPanel = panels[(currentIndex + delta + panels.length) % panels.length];
  if (!nextPanel) return false;
  focusPanel(nextPanel.id);
  return true;
}

function cycleWorkspace(delta = 1) {
  const workspaces = state.data?.workspaces || [];
  if (workspaces.length === 0) return false;
  const activeIndex = workspaces.findIndex((workspace) => workspace.id === state.data.activeWorkspaceId);
  const currentIndex = activeIndex >= 0 ? activeIndex : 0;
  const nextWorkspace = workspaces[(currentIndex + delta + workspaces.length) % workspaces.length];
  if (!nextWorkspace) return false;
  focusWorkspace(nextWorkspace.id);
  return true;
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

const workspaceChromeSettings = [
  "density",
  "paneHeaderMode",
  "sidebarDetailMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "titleDetailMode",
  "showTabs",
  "showStatusbar",
  "sidebarWidth",
  "inspectorWidth"
];

function resetWorkspaceChrome() {
  const updates = {};
  for (const key of workspaceChromeSettings) updates[key] = defaultSettings[key];
  const changed = updateSettings(updates, { immediate: true });
  if (!changed) {
    toast("Workspace chrome already reset.");
    return;
  }
  if (state.inspectorMode === "settings" && state.settingsCategory === "layout") {
    renderSettingsInspector();
  }
  toast("Workspace chrome reset.");
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

function paneLayoutPresetWeights(panels, activePanelId, mode) {
  if (panels.length <= 1) return new Map();
  if (mode !== "active") {
    const equalWeight = Math.round(paneLayoutScale / panels.length);
    return new Map(panels.map((panel) => [panel.id, equalWeight]));
  }
  const activeWeight = panels.length === 2 ? 680 : 600;
  const remaining = Math.max(1, paneLayoutScale - activeWeight);
  const otherPanels = panels.filter((panel) => panel.id !== activePanelId);
  const otherWeight = Math.max(1, Math.floor(remaining / Math.max(1, otherPanels.length)));
  let assignedOther = 0;
  const weights = new Map();
  for (const panel of panels) {
    if (panel.id === activePanelId) {
      weights.set(panel.id, activeWeight);
    } else {
      const isLastOther = assignedOther === otherPanels.length - 1;
      weights.set(panel.id, isLastOther ? Math.max(1, remaining - otherWeight * assignedOther) : otherWeight);
      assignedOther += 1;
    }
  }
  return weights;
}

async function applyPaneLayoutPreset(presetId) {
  const preset = paneLayoutPresets.find((candidate) => candidate.id === presetId);
  const workspace = activeWorkspace();
  const active = activePanel();
  if (!preset || !workspace || workspace.panels.length <= 1 || !active) {
    toast("Open another pane to use layout presets.");
    return false;
  }
  const direction = preset.direction || paneLayoutDirection(workspace);
  state.zoomedPanelId = null;
  if (paneLayoutDirection(workspace) !== direction) {
    await updatePanel(active.id, { direction });
  }
  const nextWorkspace = activeWorkspace() || workspace;
  const weights = paneLayoutPresetWeights(nextWorkspace.panels, active.id, preset.mode);
  for (const [panelId, weight] of weights) setStoredPaneWeight(panelId, direction, weight);
  savePaneLayouts();
  render();
  requestAnimationFrame(() => {
    renderPaneLayoutStylesForWeights(weights);
    clearVisiblePaneInlineFlex();
    for (const panel of nextWorkspace.panels) {
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal, true);
    }
  });
  toast(`${preset.label} layout applied.`);
  return true;
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

async function runTerminalCommand(command, panel = activePanel(), options = {}) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Focus a terminal pane first.");
    return false;
  }
  const normalized = normalizeTerminalCommand(command);
  if (!normalized) return false;
  const ok = await sendTerminalInput(terminalPanel.id, `${normalized}\r`);
  if (!ok) {
    toast("Terminal is not ready.");
    return false;
  }
  rememberRecentCommand(normalized);
  if (options.renderSettings) renderSettingsInspector();
  focusPanel(terminalPanel.id);
  focusTerminalSession(terminalPanel.id);
  return true;
}

async function promptRunTerminalCommand(panel = activePanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Focus a terminal pane first.");
    return false;
  }
  const command = await showTextDialog({
    title: "Run command",
    message: "Send a command to the active terminal.",
    value: state.recentCommands[0] || "",
    placeholder: "npm run dev",
    confirmLabel: "Run"
  });
  if (command === null) return false;
  return runTerminalCommand(command, terminalPanel, { renderSettings: state.inspectorMode === "settings" });
}

function runTerminalCommandSnippet(snippetId) {
  const snippet = findTerminalCommandSnippet(snippetId);
  if (!snippet) return false;
  return runTerminalCommand(snippet.command);
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
  const payload = JSON.stringify({
    version: 7,
    settings: state.settings,
    commandSnippets: state.customCommandSnippets,
    settingsProfiles: state.savedSettingsProfiles,
    workspaceBlueprints: state.workspaceBlueprints,
    customColorPalette: state.customColorPalette,
    savedBackgroundImages: state.savedBackgroundImages,
    recentBrowserPages: state.recentBrowserPages
  }, null, 2);
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
    const parsed = JSON.parse(raw);
    state.settings = normalizeSettings(parsed?.settings && typeof parsed.settings === "object" ? parsed.settings : parsed);
    state.terminalFontSize = state.settings.terminalFontSize;
    if (Array.isArray(parsed?.commandSnippets)) {
      state.customCommandSnippets = [];
      for (const entry of parsed.commandSnippets) {
        if (state.customCommandSnippets.length >= customCommandSnippetsLimit) break;
        const snippet = normalizeCustomCommandSnippet(entry);
        if (!snippet) continue;
        if (state.customCommandSnippets.some((candidate) => (
          candidate.command.toLowerCase() === snippet.command.toLowerCase()
        ))) continue;
        state.customCommandSnippets.push(snippet);
      }
      saveCustomCommandSnippets();
    }
    if (Array.isArray(parsed?.settingsProfiles)) {
      state.savedSettingsProfiles = [];
      const seenProfileIds = new Set();
      for (const entry of parsed.settingsProfiles) {
        if (state.savedSettingsProfiles.length >= savedSettingsProfilesLimit) break;
        const profile = normalizeSavedSettingsProfile(entry);
        if (!profile) continue;
        if (seenProfileIds.has(profile.id)) profile.id = createSettingsProfileId();
        seenProfileIds.add(profile.id);
        state.savedSettingsProfiles.push(profile);
      }
      saveSavedSettingsProfiles();
    }
    if (Array.isArray(parsed?.workspaceBlueprints)) {
      state.workspaceBlueprints = [];
      const seenBlueprintIds = new Set();
      for (const entry of parsed.workspaceBlueprints) {
        if (state.workspaceBlueprints.length >= workspaceBlueprintsLimit) break;
        const blueprint = normalizeWorkspaceBlueprint(entry);
        if (!blueprint) continue;
        if (seenBlueprintIds.has(blueprint.id)) blueprint.id = createWorkspaceBlueprintId();
        seenBlueprintIds.add(blueprint.id);
        state.workspaceBlueprints.push(blueprint);
      }
      saveWorkspaceBlueprints();
    }
    const importedColorPalette = Array.isArray(parsed?.customColorPalette)
      ? parsed.customColorPalette
      : Array.isArray(parsed?.customPalette)
        ? parsed.customPalette
        : null;
    if (importedColorPalette) {
      state.customColorPalette = uniqueColors(
        importedColorPalette.map(normalizeCustomPaletteColor).filter(Boolean)
      ).slice(0, customColorPaletteLimit);
      saveCustomColorPalette();
    }
    const importedBackgroundImages = Array.isArray(parsed?.savedBackgroundImages)
      ? parsed.savedBackgroundImages
      : Array.isArray(parsed?.savedBackgrounds)
        ? parsed.savedBackgrounds
        : null;
    if (importedBackgroundImages) {
      state.savedBackgroundImages = [];
      const seenBackgroundIds = new Set();
      const seenBackgroundUrls = new Set();
      for (const entry of importedBackgroundImages) {
        if (state.savedBackgroundImages.length >= savedBackgroundImagesLimit) break;
        const background = normalizeSavedBackgroundImage(entry);
        if (!background) continue;
        const urlKey = background.url.toLowerCase();
        if (seenBackgroundUrls.has(urlKey)) continue;
        if (seenBackgroundIds.has(background.id)) background.id = createSavedBackgroundImageId();
        seenBackgroundIds.add(background.id);
        seenBackgroundUrls.add(urlKey);
        state.savedBackgroundImages.push(background);
      }
      saveSavedBackgroundImages();
    }
    if (Array.isArray(parsed?.recentBrowserPages)) {
      state.recentBrowserPages = [];
      const seenRecentPages = new Set();
      for (const entry of parsed.recentBrowserPages) {
        if (state.recentBrowserPages.length >= recentBrowserPagesLimit) break;
        const url = normalizeBrowserPageUrl(entry);
        const urlKey = url.toLowerCase();
        if (!url || seenRecentPages.has(urlKey)) continue;
        seenRecentPages.add(urlKey);
        state.recentBrowserPages.push(url);
      }
      saveRecentBrowserPages();
    }
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
  if (element?.closest(".terminal-search")) return true;
  if (!element || element.closest(".terminal-host")) return false;
  return Boolean(
    element.isContentEditable
    || element.closest("input, textarea, select, [contenteditable='true'], [contenteditable='plaintext-only']")
  );
}

function consumeGlobalShortcut(event) {
  event.preventDefault();
  event.stopPropagation();
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

elements.paletteInput.addEventListener("input", () => {
  state.paletteIndex = 0;
  schedulePaletteRender();
});
elements.paletteInput.addEventListener("keydown", (event) => {
  if (event.key === "ArrowDown") {
    event.preventDefault();
    flushPaletteRender();
    movePaletteSelection(1);
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    flushPaletteRender();
    movePaletteSelection(-1);
  }
  if (event.key === "Enter") {
    event.preventDefault();
    flushPaletteRender();
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
    consumeGlobalShortcut(event);
    hideContextMenu();
    return;
  }
  if (editingText) return;
  if (event.ctrlKey && key === "f") {
    consumeGlobalShortcut(event);
    openTerminalSearch();
  } else if (event.ctrlKey && event.shiftKey && event.key === "Enter") {
    consumeGlobalShortcut(event);
    promptRunTerminalCommand();
  } else if (event.ctrlKey && key === "tab") {
    consumeGlobalShortcut(event);
    cycleActivePane(event.shiftKey ? -1 : 1);
  } else if (event.ctrlKey && event.key === "PageDown") {
    consumeGlobalShortcut(event);
    cycleWorkspace(1);
  } else if (event.ctrlKey && event.key === "PageUp") {
    consumeGlobalShortcut(event);
    cycleWorkspace(-1);
  } else if (event.key === "F3") {
    consumeGlobalShortcut(event);
    if (event.shiftKey) findPreviousInTerminal();
    else findNextInTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "c") {
    consumeGlobalShortcut(event);
    copyActiveTerminalSelection();
  } else if (event.ctrlKey && event.shiftKey && key === "v") {
    consumeGlobalShortcut(event);
    pasteClipboardToTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "p") {
    consumeGlobalShortcut(event);
    state.paletteOpen = !state.paletteOpen;
    renderPalette();
    if (state.paletteOpen) setTimeout(() => elements.paletteInput.focus(), 0);
  } else if (event.ctrlKey && key === "n") {
    consumeGlobalShortcut(event);
    createWorkspace();
  } else if (event.ctrlKey && event.shiftKey && key === "t") {
    consumeGlobalShortcut(event);
    reopenClosedPanel();
  } else if (event.ctrlKey && key === "t") {
    consumeGlobalShortcut(event);
    createPanel("terminal", "right");
  } else if (event.ctrlKey && event.shiftKey && key === "l") {
    consumeGlobalShortcut(event);
    openBrowserPrompt();
  } else if (event.ctrlKey && key === "i") {
    consumeGlobalShortcut(event);
    openInspector("notifications");
  } else if (event.ctrlKey && key === "b") {
    consumeGlobalShortcut(event);
    toggleSidebar();
  } else if (event.ctrlKey && event.key === ",") {
    consumeGlobalShortcut(event);
    openInspector("settings");
  } else if (event.ctrlKey && key === "k") {
    consumeGlobalShortcut(event);
    clearActiveTerminal();
  } else if (event.ctrlKey && (event.key === "=" || event.key === "+")) {
    consumeGlobalShortcut(event);
    changeTerminalFontSize(1);
  } else if (event.ctrlKey && event.key === "-") {
    consumeGlobalShortcut(event);
    changeTerminalFontSize(-1);
  } else if (event.ctrlKey && event.shiftKey && key === "r") {
    consumeGlobalShortcut(event);
    restartActiveTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "m") {
    consumeGlobalShortcut(event);
    togglePaneZoom();
  } else if (event.ctrlKey && key === "w") {
    const workspace = activeWorkspace();
    if (workspace?.activePanelId) {
      consumeGlobalShortcut(event);
      closePanel(workspace.activePanelId);
    }
  }
}, true);

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
