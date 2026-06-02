import {
  accentOptions,
  backgroundEffectsOptions,
  backgroundFitOptions,
  backgroundPositionOptions,
  backgroundPresets,
  browserHomePresets,
  browserLaunchModeOptions,
  defaultSettings,
  paneActionOptions,
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
import {
  browserTabLimit,
  browserTabSnapshotForPanel,
  browserTabsStorageKey,
  browserTabTitle,
  loadBrowserTabSnapshots,
  normalizeBrowserTab,
  normalizeBrowserTabSnapshot,
  saveBrowserTabSnapshots
} from "./browser-tabs.js";
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
import {
  clampPaneLayoutPercent,
  paneLayoutPercentMax,
  paneLayoutPercentMin,
  paneLayoutPercentFromWeights,
  paneLayoutWeightsByActivePercent
} from "./layout-utils.js";
import {
  appendPaneTreeLeaf,
  buildActivePanePresetTree,
  buildPaneTreeFromPanelIds,
  equalizePaneTree,
  insertPanelAtLeaf,
  loadPaneTreeLayouts,
  normalizePaneTree,
  paneTreeDirection,
  paneTreeLeaf,
  paneTreeLeafIds,
  paneTreeLayoutsStorageKey,
  paneTreeRatio,
  paneTreeSplit,
  paneTreeSplitForPanel,
  replacePaneTreePanelId,
  removePanelFromPaneTree,
  savePaneTreeLayouts,
  swapPaneTreePanelIds,
  updatePaneTreeSplit
} from "./pane-tree.js";
import { canLoadImage } from "./image-utils.js";
import { formatMessage, t } from "./i18n.js";
import {
  safeReleasePointerCapture,
  safeSetPointerCapture
} from "./pointer-utils.js";
import {
  attachHorizontalWheelScroll,
  scrollChildIntoView
} from "./scroll-utils.js";
import {
  normalizeSettingsQuery,
  settingsCategorySearchAliases,
  settingsSearchMatches,
  settingsSearchTokens
} from "./settings-search.js";

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
const terminalHiddenOutputQueueLimit = terminalOutputBacklogThreshold * 4;
const terminalHiddenOutputPreserveBytes = terminalOutputBacklogThreshold * 2;
const renderSlowFrameMs = 24;
const renderVerySlowFrameMs = 72;
const renderSlowFrameTriggerCount = 4;
const performanceGuardStartupGraceMs = 2500;
const performanceGuardStartupRenderCount = 3;
const appearancePreviewKeys = new Set([
  "theme",
  "accent",
  "backgroundImage",
  "backgroundOpacity",
  "backgroundFit",
  "backgroundPosition",
  "backgroundEffects",
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
  "terminalPauseInactiveOutput",
  "terminalCursorStyle",
  "terminalCursorBlink",
  "terminalBackground",
  "terminalForeground",
  "terminalCursorColor"
]);
const layoutSettingsPreviewKeys = new Set([
  "density",
  "paneActionMode",
  "paneHeaderMode",
  "sidebarDetailMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "titleDetailMode",
  "focusMode",
  "showTabs",
  "showStatusbar",
  "sidebarWidth",
  "inspectorWidth",
  "performanceMode"
]);
const browserSettingsPreviewKeys = new Set([
  "browserHomeUrl",
  "browserLaunchMode",
  "externalBrowserProfileId",
  "browserSuspendInactive"
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
const paneResizeMinWidth = 8;
const paneResizeMinHeight = 8;
const settingsSaveDelay = 140;
const browserTabSnapshotSaveDelay = 180;
const terminalFontSizeMin = 10;
const terminalFontSizeMax = 22;
const terminalWheelZoomThreshold = 120;
const terminalWheelZoomIdleResetMs = 450;
const terminalWheelZoomMaxSteps = 3;
const deferredTerminalInitIdleTimeoutMs = 700;
const browserLoadTimeoutMs = 15000;
const browserPausedStatusText = "Paused while inactive";
const embeddedGoogleHomeUrl = "https://www.google.com/webhp?igu=1";
// Google can cover embedded Chromium with a Chrome install sheet; keep the home pane usable.
const embeddedGooglePromoDismissScript = `(() => {
  const observerKey = "__cmuxGooglePromoObserver";
  const textOf = (node) => (node?.innerText || node?.textContent || "").replace(/\\s+/g, " ").trim();
  const cleanup = () => {
    window[observerKey]?.disconnect?.();
    window[observerKey] = null;
  };
  const dismissPromo = () => {
    const elements = Array.from(document.querySelectorAll("*"));
    const dismiss = elements.find((node) => {
      const text = textOf(node);
      if (!/^do not .*chrome$/i.test(text) && !/^no thanks$/i.test(text) && !/^not now$/i.test(text)) return false;
      const rect = node.getBoundingClientRect();
      return rect.width >= 80 && rect.width <= 260 && rect.height >= 24 && rect.height <= 90;
    });
    if (dismiss) {
      dismiss.click();
      return "clicked";
    }
    let hidden = 0;
    for (const node of elements) {
      if (node.tagName === "HTML" || node.tagName === "BODY") continue;
      const text = textOf(node);
      if (!/built by Google/i.test(text) || !/Download Chrome/i.test(text)) continue;
      const rect = node.getBoundingClientRect();
      if (rect.width < 250 || rect.height < 100) continue;
      node.style.display = "none";
      node.setAttribute("aria-hidden", "true");
      hidden += 1;
    }
    return hidden ? "hidden" : "";
  };
  const immediateResult = dismissPromo();
  if (immediateResult) {
    cleanup();
    return immediateResult;
  }
  const root = document.documentElement || document.body;
  if (!root || typeof MutationObserver !== "function") return "";
  if (!window[observerKey]) {
    window[observerKey] = new MutationObserver(() => {
      if (!dismissPromo()) return;
      cleanup();
    });
    window[observerKey].observe(root, { childList: true, subtree: true });
  }
  return "watching";
})()`;
const paneResizeFitThrottleMs = 90;
const panePointerDragThreshold = 6;
const closedPanelLimit = 12;
const maxConcurrentPaneCreations = 4;
const visibleBackgroundOpacity = 24;
const terminalCursorMigrationStorageKey = "cmux.terminalCursorBarMigration";
const browserHomeMigrationStorageKey = "cmux.browserHomeGoogleMigration";
const launchToken = new URLSearchParams(location.search).get("token") || "";
const eventReconnectMinDelayMs = 250;
const eventReconnectMaxDelayMs = 5000;

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
    id: "grid",
    label: "Grid",
    body: "Balanced rows and columns for several panes.",
    mode: "grid",
    direction: ""
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
  paneTrees: loadPaneTreeLayouts(),
  recentFolders: loadRecentFolders(),
  recentCommands: loadRecentCommands(),
  recentBrowserPages: loadRecentBrowserPages(),
  browserTabSnapshots: loadBrowserTabSnapshots(),
  customCommandSnippets: loadCustomCommandSnippets(),
  savedSettingsProfiles: loadSavedSettingsProfiles(),
  workspaceBlueprints: loadWorkspaceBlueprints(),
  customColorPalette: loadCustomColorPalette(),
  savedBackgroundImages: loadSavedBackgroundImages(),
  closedPanels: [],
  workspaceRows: new Map(),
  surfaceTabButtons: new Map(),
  workspaceListSignature: "",
  surfaceTabsSignature: "",
  paneRenderSignature: "",
  paneFitSignature: "",
  newTabButton: null,
  paletteOpen: false,
  paletteIndex: 0,
  paletteRenderFrame: 0,
  paletteFocusFrame: 0,
  paletteListSignature: "",
  surfaceTabScrollFrame: 0,
  surfaceTabScrollTargetId: "",
  surfaceTabOverflowFrame: 0,
  surfaceTabEnsureActive: false,
  surfaceTabResizeObserver: null,
  commandStripOverflowFrame: 0,
  commandStripResizeObserver: null,
  dragPanelId: null,
  dragWorkspaceId: null,
  zoomedPanelId: null,
  zoomedPanelIds: new Map(),
  minimizedPanelIds: new Set(),
  hoveredPanelId: null,
  previousWorkspaceId: null,
  previousPanelIds: new Map(),
  pendingPanels: new Map(),
  canceledPendingPanelIds: new Set(),
  pendingClosedPanelIds: new Set(),
  focusedPanelId: null,
  contextMenu: null,
  activeDialog: null,
  uiOperations: new Map(),
  pendingFocusSync: null,
  focusSyncTimer: 0,
  focusSyncRevision: 0,
  pendingPaneTimer: 0,
  eventSocket: null,
  eventSocketGeneration: 0,
  eventSocketReconnectDelay: eventReconnectMinDelayMs,
  eventSocketReconnectTimer: 0,
  pendingBrowserUrlSync: new Map(),
  browserUrlSyncTimer: 0,
  browserTabSnapshotSaveTimer: 0,
  pendingTerminalFontSizeSync: new Map(),
  terminalFontSizeSyncTimer: 0,
  resizing: null,
  sidebarResizing: null,
  inspectorResizing: null,
  panePointerDrag: null,
  lastInteractedPanelId: null,
  suppressPaneHeaderClick: false,
  renderFrame: 0,
  paneLayoutFrame: 0,
  workspaceTerminalFitFrames: new Map(),
  visibleTerminalFitFrame: 0,
  visibleTerminalFitPanelIds: new Set(),
  terminalFocusFrame: 0,
  terminalFocusPanelId: "",
  scheduledRenderPrevious: null,
  pendingRender: false,
  pendingRenderPrevious: null,
  workspaceSwitchHudTimer: 0,
  paneSwitchHudTimer: 0,
  settingsSaveTimer: 0,
  settingsSavePending: false,
  terminalAppearanceFrame: 0,
  deferredTerminalInitQueue: new Set(),
  deferredTerminalInitTimer: 0,
  deferredTerminalInitFrame: 0,
  paintDeferredTerminalInitPanelIds: new Set(),
  deferredTerminalFitFrame: 0,
  appearancePreviewFrame: 0,
  terminalSettingsPreviewFrame: 0,
  layoutSettingsPreviewFrame: 0,
  browserSettingsPreviewFrame: 0,
  settingsFilterFrame: 0,
  settingsSearchIndex: [],
  settingsSearchFocusFrame: 0,
  renderStats: {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0,
    slowCount: 0,
    coalescedRenders: 0,
    skippedRenders: 0,
    browserUrlRenderSkips: 0,
    guardActivations: 0
  },
  terminalOutputStats: {
    currentQueued: 0,
    maxQueued: 0,
    writtenBytes: 0,
    chunks: 0,
    lastChunk: 0,
    pausedFlushes: 0,
    trimmedBytes: 0,
    trimmedEvents: 0
  },
  terminalFitStats: {
    deferred: 0,
    flushed: 0
  },
  paneCreateStats: {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0,
    failures: 0,
    lastType: ""
  },
  terminalConnectStats: {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0
  },
  performanceGuardTriggered: false,
  performanceGuardReason: "",
  performanceGuardStartedAt: performance.now(),
  performanceGuardSlowRenderCount: 0,
  terminalWheelZoomState: new Map(),
  appliedSettingsSignature: "",
  settings: initialSettings,
  settingsCategory: "quick",
  settingsQuery: "",
  inspectorSignature: "",
  settingsInspectorSignature: "",
  settingsScrollResetPending: false,
  settingsSearchAutoScrollQuery: "",
  browserProfiles: [{ id: "system", label: t("browser.systemDefault"), browser: t("browser.system"), profileName: t("browser.defaultProfile") }],
  browserProfilesLoaded: false,
  browserProfilesLoading: false,
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
  commandStrip: document.querySelector(".command-strip"),
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
  workspaceSwitchHud: document.getElementById("workspaceSwitchHud"),
  paneSwitchHud: document.getElementById("paneSwitchHud"),
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
  next.terminalFontSize = clamp(next.terminalFontSize, terminalFontSizeMin, terminalFontSizeMax);
  next.terminalLineHeight = clamp(next.terminalLineHeight, 1, 1.5);
  next.backgroundOpacity = clamp(next.backgroundOpacity, 0, 42);
  if (!backgroundFitOptions.some(([id]) => id === next.backgroundFit)) next.backgroundFit = defaultSettings.backgroundFit;
  if (!backgroundPositionOptions.some(([id]) => id === next.backgroundPosition)) next.backgroundPosition = defaultSettings.backgroundPosition;
  if (!backgroundEffectsOptions.some(([id]) => id === next.backgroundEffects)) next.backgroundEffects = defaultSettings.backgroundEffects;
  if (!themeOptions.some(([id]) => id === next.theme)) next.theme = defaultSettings.theme;
  next.accent = normalizeUiColor(next.accent, defaultSettings.accent);
  if (!["comfortable", "compact"].includes(next.density)) next.density = defaultSettings.density;
  if (!paneHeaderOptions.some(([id]) => id === next.paneHeaderMode)) next.paneHeaderMode = defaultSettings.paneHeaderMode;
  if (!paneActionOptions.some(([id]) => id === next.paneActionMode)) next.paneActionMode = defaultSettings.paneActionMode;
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
  if (!browserLaunchModeOptions.some(([id]) => id === next.browserLaunchMode)) next.browserLaunchMode = defaultSettings.browserLaunchMode;
  next.externalBrowserProfileId = String(next.externalBrowserProfileId || defaultSettings.externalBrowserProfileId).trim().slice(0, 120) || "system";
  next.browserSuspendInactive = next.browserSuspendInactive !== false;
  next.terminalCustomShell = String(next.terminalCustomShell || "").trim().slice(0, 512);
  next.showTabs = next.showTabs !== false;
  next.showStatusbar = next.showStatusbar !== false;
  next.focusMode = Boolean(next.focusMode);
  next.showAdvanced = next.toolbarMode === "expanded";
  next.performanceMode = Boolean(next.performanceMode);
  next.adaptivePerformance = next.adaptivePerformance !== false;
  next.reduceMotion = Boolean(next.reduceMotion);
  next.terminalPauseInactiveOutput = next.terminalPauseInactiveOutput !== false;
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

function normalizeTerminalFontSize(value, fallback = state?.settings?.terminalFontSize || defaultSettings.terminalFontSize) {
  const size = Number(value);
  const fallbackSize = Number(fallback);
  if ((!Number.isFinite(size) || size <= 0) && (!Number.isFinite(fallbackSize) || fallbackSize <= 0)) return 0;
  const next = Number.isFinite(size) && size > 0 ? size : fallbackSize;
  return clamp(next, terminalFontSizeMin, terminalFontSizeMax);
}

function panelHasTerminalFontSize(panel) {
  return panel?.type === "terminal" && Number(panel.terminalFontSize) > 0;
}

function terminalFontSizeForPanel(panel) {
  return normalizeTerminalFontSize(
    panelHasTerminalFontSize(panel) ? panel.terminalFontSize : state.settings.terminalFontSize,
    state.settings.terminalFontSize
  );
}

function loadSettings() {
  let parsed = {};
  try {
    parsed = JSON.parse(localStorage.getItem("cmux.settings") || "{}");
  } catch {
    parsed = {};
  }
  let migrated = false;
  if (
    localStorage.getItem(terminalCursorMigrationStorageKey) !== "1"
    && parsed
    && typeof parsed === "object"
    && !Array.isArray(parsed)
    && (!Object.hasOwn(parsed, "terminalCursorStyle") || parsed.terminalCursorStyle === "block")
  ) {
    parsed.terminalCursorStyle = defaultSettings.terminalCursorStyle;
    localStorage.setItem(terminalCursorMigrationStorageKey, "1");
    migrated = true;
  }
  if (
    localStorage.getItem(browserHomeMigrationStorageKey) !== "1"
    && parsed
    && typeof parsed === "object"
    && !Array.isArray(parsed)
    && (!Object.hasOwn(parsed, "browserHomeUrl") || /^https?:\/\/(?:www\.)?bing\.com/i.test(parsed.browserHomeUrl))
  ) {
    parsed.browserHomeUrl = defaultSettings.browserHomeUrl;
    localStorage.setItem(browserHomeMigrationStorageKey, "1");
    migrated = true;
  }
  const legacyFontSize = Number(localStorage.getItem("cmux.terminalFontSize") || 0);
  const settings = normalizeSettings(parsed, legacyFontSize);
  if (migrated) localStorage.setItem("cmux.settings", JSON.stringify(settings));
  return settings;
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

function stripWrappingQuotes(value) {
  const raw = String(value || "").trim();
  const quote = raw[0];
  return raw.length >= 2
    && (quote === "\"" || quote === "'")
    && raw.at(-1) === quote
    ? raw.slice(1, -1).trim()
    : raw;
}

function localPathToFileUrl(value) {
  const raw = stripWrappingQuotes(value);
  if (!raw) return "";
  if (/^\\\\/.test(raw)) {
    const parts = raw.replace(/^\\\\/, "").split(/[\\/]+/).filter(Boolean);
    return parts.length ? `file://${parts.map(encodeURIComponent).join("/")}` : "";
  }
  const match = raw.match(/^([a-z]):[\\/](.*)$/i);
  if (!match) return "";
  const drive = match[1].toUpperCase();
  const rest = match[2].split(/[\\/]+/).filter(Boolean).map(encodeURIComponent).join("/");
  return `file:///${drive}:/${rest}`;
}

function normalizeBackgroundValue(value) {
  let url = stripWrappingQuotes(value);
  if (!url) return "";
  const fileUrl = localPathToFileUrl(url);
  if (fileUrl) return fileUrl;
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
  if (/^file:/i.test(url)) {
    const proxyUrl = new URL("/_cmux/local-image", location.origin);
    proxyUrl.searchParams.set("url", url);
    if (launchToken) proxyUrl.searchParams.set("token", launchToken);
    return `${proxyUrl.pathname}${proxyUrl.search}`;
  }
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

function backgroundImageSettings(backgroundImage) {
  const normalized = normalizeBackgroundValue(backgroundImage);
  const updates = { backgroundImage: normalized };
  if (normalized && state.settings.backgroundOpacity < visibleBackgroundOpacity) {
    updates.backgroundOpacity = visibleBackgroundOpacity;
  }
  return updates;
}

function backgroundSizeCss(value) {
  if (value === "contain") return "contain";
  if (value === "stretch") return "100% 100%";
  if (value === "auto") return "auto";
  return "cover";
}

function backgroundRepeatCss(value) {
  const normalized = normalizeBackgroundValue(value);
  return normalized && !isBackgroundPreset(normalized) ? "no-repeat" : "repeat";
}

function backgroundPositionCss(value) {
  if (["top", "bottom", "left", "right", "center"].includes(value)) return value;
  return "center";
}

async function validateBackgroundImageValue(value) {
  const url = normalizedImageUrl(value);
  if (!url) return { ok: false, url: "" };
  const ok = await canLoadImage(backgroundImageUrl(url));
  return { ok, url };
}

async function applyCustomBackgroundImage(value, options = {}) {
  const raw = String(value || "").trim();
  if (!raw) {
    const changed = updateSettings({ backgroundImage: "" }, { immediate: true });
    if (changed && options.render !== false) renderSettingsInspector();
    if (options.toast) toast(changed ? "Background image cleared." : "Background image is already clear.");
    return changed;
  }
  const preset = isBackgroundPreset(raw) ? raw : "";
  if (preset) {
    const changed = updateSettings(backgroundImageSettings(preset), { immediate: true });
    if (changed && options.render !== false) renderSettingsInspector();
    if (options.toast) {
      const label = backgroundPresetMap.get(preset)?.label || "Selected";
      toast(changed ? `${label} background applied.` : `${label} background already active.`);
    }
    return changed;
  }
  const validated = await validateBackgroundImageValue(raw);
  if (!validated.ok) {
    if (options.toast) toast("Background image could not be loaded.");
    if (options.resetInput) options.resetInput.value = isBackgroundPreset(state.settings.backgroundImage) ? "" : state.settings.backgroundImage;
    return null;
  }
  const changed = updateSettings(backgroundImageSettings(validated.url), { immediate: true });
  if (changed && options.render !== false) renderSettingsInspector();
  if (options.toast) toast(changed ? "Background image updated." : "Background image already active.");
  return changed;
}

function isSupportedBackgroundFileName(name) {
  return /\.(avif|bmp|gif|jpe?g|png|webp)$/i.test(String(name || ""));
}

function firstDroppedBackgroundFile(dataTransfer) {
  for (const file of [...(dataTransfer?.files || [])]) {
    if (file.type?.startsWith("image/") || isSupportedBackgroundFileName(file.name)) return file;
  }
  return null;
}

function droppedBackgroundText(dataTransfer) {
  const uri = dataTransfer?.getData("text/uri-list")
    ?.split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("#"));
  if (uri) return uri;
  return dataTransfer?.getData("text/plain")?.trim() || "";
}

function droppedBackgroundValue(dataTransfer) {
  const file = firstDroppedBackgroundFile(dataTransfer);
  if (file) {
    const filePath = window.cmuxNative?.filePath?.(file) || file.path || "";
    const fileUrl = localPathToFileUrl(filePath);
    if (fileUrl) return fileUrl;
  }
  return droppedBackgroundText(dataTransfer);
}

function hasBackgroundDropData(dataTransfer, options = {}) {
  if (state.dragPanelId || state.dragWorkspaceId) return false;
  const items = [...(dataTransfer?.items || [])];
  if (items.some((item) => item.kind === "file" && (!item.type || item.type.startsWith("image/")))) return true;
  const types = [...(dataTransfer?.types || [])];
  return types.includes("text/uri-list") || (options.allowPlainText !== false && types.includes("text/plain"));
}

function installBackgroundDropTarget(target, options = {}) {
  if (!target) return;
  const setDropping = (dropping) => target.classList.toggle("is-drop-target", dropping);
  target.addEventListener("dragover", (event) => {
    if (!hasBackgroundDropData(event.dataTransfer, options)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    setDropping(true);
  });
  target.addEventListener("dragleave", () => setDropping(false));
  target.addEventListener("drop", async (event) => {
    if (!hasBackgroundDropData(event.dataTransfer, options)) return;
    event.preventDefault();
    setDropping(false);
    const value = droppedBackgroundValue(event.dataTransfer);
    if (!value) {
      toast("Drop a supported image file or image URL.");
      return;
    }
    if (options.input) options.input.value = value;
    if (options.save) {
      await applyAndSaveCustomBackgroundImage({ url: value });
      return;
    }
    await applyCustomBackgroundImage(value, { toast: true });
  });
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

function cleanupBrowserTabSnapshots() {
  if (!state.data || state.browserTabSnapshots.size === 0) return;
  const panelIds = allPanelIds();
  let changed = false;
  for (const panelId of [...state.browserTabSnapshots.keys()]) {
    if (panelIds.has(panelId)) continue;
    state.browserTabSnapshots.delete(panelId);
    changed = true;
  }
  if (changed) saveBrowserTabSnapshots(state.browserTabSnapshots);
}

function embeddedBrowserUserAgent() {
  return navigator.userAgent
    .replace(/\sElectron\/\S+/ig, "")
    .replace(/\scmux-windows\/\S+/ig, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function normalizeBrowserProfiles(profiles = []) {
  const result = [];
  const seen = new Set();
  const add = (profile) => {
    const id = String(profile?.id || "").trim() || "system";
    if (seen.has(id)) return;
    seen.add(id);
    result.push({
      id,
      label: String(profile?.label || t("browser.systemDefault")).trim() || t("browser.systemDefault"),
      browser: String(profile?.browser || "").trim(),
      profileName: String(profile?.profileName || "").trim()
    });
  };
  add({ id: "system", label: t("browser.systemDefault"), browser: t("browser.system"), profileName: t("browser.defaultProfile") });
  for (const profile of profiles) add(profile);
  return result;
}

async function loadBrowserProfiles(options = {}) {
  if (state.browserProfilesLoading || (state.browserProfilesLoaded && !options.force)) return state.browserProfiles;
  state.browserProfilesLoading = true;
  try {
    const profiles = window.cmuxNative?.listBrowserProfiles
      ? await window.cmuxNative.listBrowserProfiles()
      : [];
    state.browserProfiles = normalizeBrowserProfiles(profiles);
    state.browserProfilesLoaded = true;
    if (!state.browserProfiles.some((profile) => profile.id === state.settings.externalBrowserProfileId)) {
      updateSettings({ externalBrowserProfileId: "system" });
    }
  } catch {
    state.browserProfiles = normalizeBrowserProfiles();
    state.browserProfilesLoaded = true;
  } finally {
    state.browserProfilesLoading = false;
  }
  if (options.render && state.inspectorMode === "settings" && state.settingsCategory === "browser") {
    renderSettingsInspector();
  }
  return state.browserProfiles;
}

function browserProfileOptions() {
  if (!state.browserProfilesLoaded && !state.browserProfilesLoading) {
    loadBrowserProfiles({ render: true });
  }
  return normalizeBrowserProfiles(state.browserProfiles);
}

function browserProfileLabel(profileId = state.settings.externalBrowserProfileId) {
  return normalizeBrowserProfiles(state.browserProfiles).find((profile) => profile.id === profileId)?.label || t("browser.systemDefault");
}

async function refreshBrowserProfiles(options = {}) {
  const profiles = await loadBrowserProfiles({ force: true, render: options.render !== false });
  const profileCount = profiles.filter((profile) => profile.id !== "system").length;
  if (options.toast !== false) {
    toast(profileCount
      ? `${profileCount} browser profile${profileCount === 1 ? "" : "s"} found.`
      : "No browser profiles found; system browser will be used.");
  }
  return profiles;
}

async function openExternalBrowser(url, options = {}) {
  const target = normalizeUrl(url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  if (window.cmuxNative?.openExternal) {
    const requestedProfileId = options.profileId || state.settings.externalBrowserProfileId;
    let result = null;
    try {
      result = await window.cmuxNative.openExternal(target, requestedProfileId);
    } catch {
      result = { ok: false, profileId: "system", error: "open_external_failed" };
    }
    if (result?.ok === false) {
      toast(`${browserProfileLabel(requestedProfileId)} could not open this page.`);
    } else if (options.toast) {
      toast(result?.profileId && result.profileId !== "system"
        ? `Opened in ${browserProfileLabel(result.profileId)}.`
        : "Opened in system browser.");
    }
    return result;
  }
  try {
    window.open(target, "_blank", "noopener");
  } catch {
    return { ok: false, error: "open_external_failed" };
  }
  if (options.toast) toast("Opened in browser.");
  return { ok: true };
}

async function showExternalBrowserProfileMenuAt(preferredX, preferredY, url = state.settings.browserHomeUrl) {
  const target = normalizeUrl(url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = t("browser.openExternally");
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = target;
  menu.replaceChildren(title, meta, contextMenuButton(t("browser.loadingProfiles"), () => {}, true));
  showContextMenuAt(menu, preferredX, preferredY);

  const profiles = await loadBrowserProfiles({ force: !state.browserProfilesLoaded, render: false });
  if (state.contextMenu !== menu || menu.hidden) return;
  const profileActions = contextMenuActionGroup(...normalizeBrowserProfiles(profiles).map((profile) => (
    contextMenuButton(profile.label, () => openExternalBrowser(target, {
      profileId: profile.id,
      toast: true
    }), false)
  )));
  const settingsActions = contextMenuActionGroup(
    contextMenuButton(t("browser.useSelectedProfile"), () => openExternalBrowser(target, { toast: true })),
    contextMenuButton(t("browser.settings"), () => openSettingsCategory("browser"))
  );
  menu.replaceChildren(
    title,
    meta,
    contextMenuSectionTitle(t("browser.profile")),
    profileActions,
    contextMenuSectionTitle(t("browser.default")),
    settingsActions
  );
  showContextMenuAt(menu, preferredX, preferredY);
}

async function showExternalBrowserProfileMenu(event, url = state.settings.browserHomeUrl) {
  event.preventDefault();
  event.stopPropagation();
  return showExternalBrowserProfileMenuAt(event.clientX, event.clientY, url);
}

function hasRecentActivity() {
  return Boolean(
    state.recentFolders.length
    || state.recentCommands.length
    || state.recentBrowserPages.length
    || state.browserTabSnapshots.size
  );
}

async function clearRecentActivity() {
  if (!hasRecentActivity()) {
    toast("Recent activity is already clear.");
    return false;
  }
  if (!await showConfirmDialog({
    title: "Clear recent activity",
    message: "Remove recent folders, terminal commands, browser pages, and saved browser tabs. Saved profiles, snippets, backgrounds, colors, and blueprints stay.",
    confirmLabel: "Clear",
    danger: true
  })) return false;
  state.recentFolders = [];
  state.recentCommands = [];
  state.recentBrowserPages = [];
  state.browserTabSnapshots = new Map();
  saveRecentFolders();
  saveRecentCommands();
  saveRecentBrowserPages();
  saveBrowserTabSnapshots(state.browserTabSnapshots);
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
  const actions = paneActionOptions.find(([id]) => id === normalized.paneActionMode)?.[1] || normalized.paneActionMode;
  const backgroundEffects = optionLabel(backgroundEffectsOptions, normalized.backgroundEffects, "Flat");
  return [
    theme,
    normalized.density,
    toolbar,
    `${actions} pane controls`,
    `${backgroundEffects.toLowerCase()} background`,
    normalized.performanceMode ? "performance" : normalized.reduceMotion ? "reduced motion" : "balanced",
    normalized.terminalPauseInactiveOutput ? "paused output" : "live output",
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
    terminalFontSize: type === "terminal" ? normalizeTerminalFontSize(panel.terminalFontSize, 0) : 0,
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

function backgroundFilePath(value) {
  const url = normalizedImageUrl(value);
  if (!/^file:/i.test(url)) return "";
  try {
    const parsed = new URL(url);
    const pathName = decodeURIComponent(parsed.pathname || "").replace(/\//g, "\\");
    if (parsed.hostname) return `\\\\${parsed.hostname}${pathName}`;
    return pathName.replace(/^\\([A-Za-z]:\\)/, "$1");
  } catch {
    return "";
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

async function saveCustomBackgroundImage(background, options = {}) {
  const input = typeof background === "string" ? { url: background } : background || {};
  const source = input.url || input.value || input.backgroundImage;
  if (!normalizedImageUrl(source)) {
    if (options.toast !== false) toast("Choose a custom background image first.");
    return null;
  }
  const validated = await validateBackgroundImageValue(source);
  if (!validated.ok) {
    if (options.toast !== false) toast("Background image could not be loaded.");
    return null;
  }
  return upsertSavedBackgroundImage({ ...input, url: validated.url }, options);
}

async function applyAndSaveCustomBackgroundImage(background, options = {}) {
  const input = typeof background === "string" ? { url: background } : background || {};
  const source = input.url || input.value || input.backgroundImage;
  if (!normalizedImageUrl(source)) {
    if (options.toast !== false) toast("Choose a custom background image first.");
    return null;
  }
  const validated = await validateBackgroundImageValue(source);
  if (!validated.ok) {
    if (options.toast !== false) toast("Background image could not be loaded.");
    if (options.resetInput) options.resetInput.value = isBackgroundPreset(state.settings.backgroundImage) ? "" : state.settings.backgroundImage;
    return null;
  }
  const wasSaved = state.savedBackgroundImages.some((candidate) => candidate.url.toLowerCase() === validated.url.toLowerCase());
  const saved = upsertSavedBackgroundImage({ ...input, url: validated.url }, { render: false, toast: false });
  if (!saved) return null;
  const changed = updateSettings(backgroundImageSettings(validated.url), { immediate: true });
  if (options.render !== false) renderSettingsInspector();
  if (options.toast !== false) {
    if (changed && !wasSaved) toast("Background image applied and saved.");
    else if (changed) toast(`${saved.label} background applied.`);
    else if (!wasSaved) toast("Background image saved.");
    else toast(`${saved.label} background already active.`);
  }
  return saved;
}

async function applySavedBackgroundImage(backgroundId) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return;
  const validated = await validateBackgroundImageValue(background.url);
  if (!validated.ok) {
    toast(`${background.label} background could not be loaded.`);
    return;
  }
  const changed = updateSettings(backgroundImageSettings(validated.url), { immediate: true });
  if (!changed) {
    toast(`${background.label} background already active.`);
    return;
  }
  renderSettingsInspector();
  toast(`${background.label} background applied.`);
}

async function openBackgroundImageFile(value = state.settings.backgroundImage) {
  return openBackgroundImageSource(value);
}

function canOpenBackgroundImageSource(value) {
  const url = normalizedImageUrl(value);
  return Boolean(backgroundFilePath(url) || /^https?:\/\//i.test(url));
}

async function openBackgroundImageSource(value = state.settings.backgroundImage) {
  const url = normalizedImageUrl(value);
  if (!url) {
    toast("Choose a custom background image first.");
    return false;
  }
  const filePath = backgroundFilePath(value);
  if (filePath) {
    if (!window.cmuxNative?.openPath) {
      toast("Open file is available in the desktop app.");
      return false;
    }
    const result = await window.cmuxNative.openPath(filePath);
    const ok = result === true || result?.ok;
    toast(ok ? "Background file opened." : "Background file could not be opened.");
    return ok;
  }
  if (/^https?:\/\//i.test(url)) {
    const result = await openExternalBrowser(url, { toast: true });
    return Boolean(result?.ok);
  }
  toast("This background source cannot be opened directly.");
  return false;
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
    settings.backgroundFit,
    settings.backgroundPosition,
    settings.backgroundEffects,
    settings.density,
    settings.toolbarMode,
    settings.tabSize,
    settings.titleDetailMode,
    settings.focusMode,
    settings.showTabs,
    settings.showStatusbar,
    settings.showAdvanced,
    settings.performanceMode,
    settings.reduceMotion,
    settings.paneHeaderMode,
    settings.paneActionMode,
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
  toggleClassIfChanged(elements.shell, "pane-actions-essential", state.settings.paneActionMode === "essential");
  toggleClassIfChanged(elements.shell, "pane-actions-split", state.settings.paneActionMode === "split");
  toggleClassIfChanged(elements.shell, "pane-actions-full", state.settings.paneActionMode === "full");
  toggleClassIfChanged(elements.shell, "workspace-detail-compact", state.settings.sidebarDetailMode === "compact");
  toggleClassIfChanged(elements.shell, "workspace-detail-balanced", state.settings.sidebarDetailMode === "balanced");
  toggleClassIfChanged(elements.shell, "workspace-detail-detailed", state.settings.sidebarDetailMode === "detailed");
  toggleClassIfChanged(elements.shell, "sidebar-footer-workspace", state.settings.sidebarFooterMode === "workspace");
  toggleClassIfChanged(elements.shell, "sidebar-footer-compact", state.settings.sidebarFooterMode === "compact");
  toggleClassIfChanged(elements.shell, "sidebar-footer-full", state.settings.sidebarFooterMode === "full");
  toggleClassIfChanged(elements.shell, "toolbar-minimal", state.settings.toolbarMode === "minimal");
  toggleClassIfChanged(elements.shell, "toolbar-compact", state.settings.toolbarMode === "compact");
  toggleClassIfChanged(elements.shell, "toolbar-standard", state.settings.toolbarMode === "standard");
  toggleClassIfChanged(elements.shell, "toolbar-expanded", state.settings.toolbarMode === "expanded");
  toggleClassIfChanged(elements.shell, "focus-mode", state.settings.focusMode);
  toggleClassIfChanged(elements.shell, "hide-tabs", !state.settings.showTabs);
  toggleClassIfChanged(elements.shell, "hide-status", !state.settings.showStatusbar);
  toggleClassIfChanged(elements.shell, "show-advanced", state.settings.showAdvanced);
  toggleClassIfChanged(elements.shell, "performance-mode", state.settings.performanceMode);
  toggleClassIfChanged(elements.shell, "background-effects-flat", state.settings.backgroundEffects === "flat");
  toggleClassIfChanged(elements.shell, "background-effects-glass", state.settings.backgroundEffects === "glass");
  const reduceMotion = state.settings.reduceMotion || state.settings.performanceMode;
  toggleClassIfChanged(document.body, "reduce-motion", reduceMotion);
  toggleClassIfChanged(elements.shell, "reduce-motion", reduceMotion);
  const css = backgroundCss(state.settings.backgroundImage);
  toggleClassIfChanged(elements.shell, "has-background", css !== "none");
  elements.shell.style.setProperty("--background-image", css);
  elements.shell.style.setProperty("--background-opacity", String(state.settings.backgroundOpacity / 100));
  elements.shell.style.setProperty("--background-size", backgroundSizeCss(state.settings.backgroundFit));
  elements.shell.style.setProperty("--background-repeat", backgroundRepeatCss(state.settings.backgroundImage));
  elements.shell.style.setProperty("--background-position", backgroundPositionCss(state.settings.backgroundPosition));
  scheduleCommandStripOverflowRefresh();
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
  if (changedKeys.some((key) => browserSettingsPreviewKeys.has(key))) {
    scheduleBrowserSettingsPreviewRefresh();
  }
  if (changedKeys.includes("terminalPauseInactiveOutput") || changedKeys.includes("performanceMode")) {
    resumeTerminalOutputAfterActivityChange();
  }
  if (changedKeys.includes("browserSuspendInactive")) {
    render();
  } else if (previous.titleDetailMode !== state.settings.titleDetailMode) {
    render();
  }
  return true;
}

function bindDeferredSettingRange(input, row, options) {
  const label = row.querySelector(".setting-label");
  const settingKey = options.settingKey;
  const formatLabel = typeof options.formatLabel === "function"
    ? options.formatLabel
    : (value) => String(value);
  const parseValue = () => {
    const value = typeof options.parse === "function"
      ? options.parse(input.value)
      : Number(input.value);
    return typeof value === "number" && !Number.isFinite(value)
      ? state.settings[settingKey]
      : value;
  };
  const preview = (value) => {
    setTextIfChanged(label, formatLabel(value));
    options.preview?.(value);
  };
  const commit = () => {
    const value = parseValue();
    updateSettings({ [settingKey]: value });
    const committedValue = state.settings[settingKey];
    input.value = String(committedValue);
    preview(committedValue);
  };
  input.addEventListener("input", () => preview(parseValue()));
  input.addEventListener("change", commit);
  input.addEventListener("blur", commit);
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

function cleanupPaneTrees() {
  const liveWorkspaceIds = new Set((state.data?.workspaces || []).map((workspace) => workspace.id));
  let changed = false;
  for (const workspaceId of [...state.paneTrees.keys()]) {
    if (!liveWorkspaceIds.has(workspaceId)) {
      state.paneTrees.delete(workspaceId);
      changed = true;
    }
  }
  if (changed) savePaneTreeLayouts(state.paneTrees);
}

function paneTreeForWorkspace(workspace, panels = workspace?.panels || []) {
  if (!workspace || panels.length === 0) return null;
  const panelIds = panels.map((panel) => panel.id);
  const allowedPanelIds = new Set(panelIds);
  const existing = state.paneTrees.get(workspace.id);
  const before = JSON.stringify(existing || null);
  let tree = normalizePaneTree(existing, allowedPanelIds);
  const presentPanelIds = new Set(paneTreeLeafIds(tree));
  for (const panelId of panelIds) {
    if (!presentPanelIds.has(panelId)) {
      tree = appendPaneTreeLeaf(tree, panelId, paneLayoutDirection(workspace));
      presentPanelIds.add(panelId);
    }
  }
  if (!tree) tree = buildPaneTreeFromPanelIds(panelIds, paneLayoutDirection(workspace));
  if (JSON.stringify(tree || null) !== before) {
    state.paneTrees.set(workspace.id, tree);
    savePaneTreeLayouts(state.paneTrees);
  }
  return tree;
}

function insertPanelInPaneTree(workspaceId, anchorPanelId, panelId, direction, placement = "after") {
  if (!workspaceId || !panelId) return;
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  const sourceTree = workspace ? paneTreeForWorkspace(workspace) : state.paneTrees.get(workspaceId);
  let tree = removePanelFromPaneTree(sourceTree, panelId);
  const inserted = anchorPanelId
    ? insertPanelAtLeaf(tree, anchorPanelId, panelId, direction, placement)
    : { node: appendPaneTreeLeaf(tree, panelId, direction), inserted: true };
  tree = inserted.inserted ? inserted.node : appendPaneTreeLeaf(tree, panelId, direction);
  state.paneTrees.set(workspaceId, tree);
  savePaneTreeLayouts(state.paneTrees);
}

function removePanelFromAllPaneTrees(panelId) {
  if (!panelId) return;
  let changed = false;
  for (const [workspaceId, tree] of [...state.paneTrees.entries()]) {
    const next = removePanelFromPaneTree(tree, panelId);
    if (JSON.stringify(next || null) === JSON.stringify(tree || null)) continue;
    changed = true;
    if (next) state.paneTrees.set(workspaceId, next);
    else state.paneTrees.delete(workspaceId);
  }
  if (changed) savePaneTreeLayouts(state.paneTrees);
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
  if (state.paneTrees.delete(workspace.id)) savePaneTreeLayouts(state.paneTrees);
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

function visiblePaneWeights(direction) {
  const panes = [...elements.paneGrid.querySelectorAll(".pane")].filter((pane) => pane.dataset.panelId);
  if (panes.length <= 1) return null;
  const sizes = panes.map((pane) => {
    const rect = pane.getBoundingClientRect();
    return {
      panelId: pane.dataset.panelId,
      size: Math.max(1, direction === "down" ? rect.height : rect.width)
    };
  });
  const total = sizes.reduce((sum, item) => sum + item.size, 0);
  if (!total) return null;
  return new Map(sizes.map((item) => [item.panelId, Math.round((item.size / total) * paneLayoutScale)]));
}

function defaultActivePaneLayoutPercent(workspace = activeWorkspace()) {
  const paneCount = workspace?.panels?.length || 0;
  return paneCount > 1 ? Math.round(100 / paneCount) : 50;
}

function activePaneLayoutPercent(workspace = activeWorkspace()) {
  if (!workspace || workspace.panels.length <= 1 || !workspace.activePanelId) return 50;
  const tree = paneTreeForWorkspace(workspace);
  const found = paneTreeSplitForPanel(tree, workspace.activePanelId);
  if (found) {
    return Math.round((found.activeInFirst ? found.split.ratio : 1 - found.split.ratio) * 100);
  }
  const direction = paneLayoutDirection(workspace);
  const fallback = defaultActivePaneLayoutPercent(workspace);
  const storedWeights = storedPaneWeightsForPanels(workspace.panels, direction, null);
  if (storedWeights) return paneLayoutPercentFromWeights(storedWeights, workspace.activePanelId, fallback);
  const visibleWeights = visiblePaneWeights(direction);
  if (visibleWeights) return paneLayoutPercentFromWeights(visibleWeights, workspace.activePanelId, fallback);
  return fallback;
}

function applyActivePaneLayoutPercent(percent, options = {}) {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1 || !workspace.activePanelId) {
    if (options.toast) toast("Open another pane to resize the active pane.");
    return 50;
  }
  const direction = paneLayoutDirection(workspace);
  const nextPercent = clampPaneLayoutPercent(percent);
  const tree = paneTreeForWorkspace(workspace);
  const found = paneTreeSplitForPanel(tree, workspace.activePanelId);
  if (found?.split?.id) {
    const ratio = paneTreeRatio((found.activeInFirst ? nextPercent : 100 - nextPercent) / 100);
    state.paneTrees.set(workspace.id, updatePaneTreeSplit(tree, found.split.id, (split) => ({
      ...split,
      ratio
    })));
    if (options.save) savePaneTreeLayouts(state.paneTrees);
    clearZoomedPanelForWorkspace(workspace);
    scheduleRender();
    scheduleWorkspaceTerminalFits(workspace.id, true);
    if (options.toast) toast(`Active pane ${nextPercent}%.`);
    return nextPercent;
  }
  const weights = paneLayoutWeightsByActivePercent(workspace.panels, workspace.activePanelId, nextPercent, paneLayoutScale);
  if (zoomedPanelIdForWorkspace(workspace)) {
    clearZoomedPanelForWorkspace(workspace);
    render();
  }
  for (const [panelId, weight] of weights) setStoredPaneWeight(panelId, direction, weight);
  renderPaneLayoutStylesForWeights(weights);
  clearVisiblePaneInlineFlex();
  requestAnimationFrame(() => {
    renderPaneLayoutStylesForWeights(weights);
    clearVisiblePaneInlineFlex();
    for (const panel of workspace.panels) {
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal, true);
    }
  });
  if (options.save) savePaneLayouts();
  if (options.toast) toast(`Active pane ${nextPercent}%.`);
  return nextPercent;
}

function adjustActivePaneLayoutPercent(delta) {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1) {
    toast(t("paneShape.resizeNeedsPane"));
    return false;
  }
  const nextPercent = applyActivePaneLayoutPercent(
    activePaneLayoutPercent(workspace) + Number(delta || 0),
    { save: true, toast: true }
  );
  refreshLayoutSettings();
  return nextPercent;
}

function scheduleVisiblePaneLayoutApply() {
  if (state.resizing || state.paneLayoutFrame) return;
  state.paneLayoutFrame = requestAnimationFrame(() => {
    state.paneLayoutFrame = 0;
    if (elements.paneGrid.querySelector(".pane-split")) return;
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
    const panel = findPanelState(session.panelId)?.panel;
    session.fontSize = terminalFontSizeForPanel(panel);
    session.term.options.fontFamily = terminalFontStack();
    session.term.options.fontSize = session.fontSize;
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

const paneOrdinalCommands = Array.from({ length: 9 }, (_, index) => {
  const ordinal = index + 1;
  return {
    id: `terminal.focusPane${ordinal}`,
    label: ordinal === 9 ? "Focus Last Pane" : `Focus Pane ${ordinal}`,
    shortcut: `Ctrl+${ordinal}`,
    run: () => focusPaneByOrdinal(ordinal)
  };
});

const workspaceOrdinalCommands = Array.from({ length: 9 }, (_, index) => {
  const ordinal = index + 1;
  return {
    id: `workspace.focus${ordinal}`,
    label: ordinal === 9 ? "Focus Last Workspace" : `Focus Workspace ${ordinal}`,
    shortcut: `Ctrl+Alt+${ordinal}`,
    run: () => focusWorkspaceByOrdinal(ordinal)
  };
});

const commands = [
  { id: "workspace.new", label: "New Workspace", shortcut: "Ctrl+N", run: () => createWorkspace() },
  { id: "workspace.newFromFolder", label: "New Workspace From Folder", shortcut: "", run: () => createWorkspaceFromFolder() },
  { id: "workspace.rename", label: "Rename Workspace", shortcut: "", run: () => renameActiveWorkspace() },
  { id: "workspace.color", label: "Change Workspace Color", shortcut: "", run: () => cycleWorkspaceColor() },
  { id: "workspace.changeFolder", label: "Change Workspace Folder", shortcut: "", run: () => chooseWorkspaceFolder() },
  { id: "workspace.openFolder", label: "Open Workspace Folder", shortcut: "", run: () => openWorkspaceFolder() },
  { id: "workspace.next", label: "Next Workspace", shortcut: "Ctrl+PageDown", run: () => cycleWorkspace(1) },
  { id: "workspace.previous", label: "Previous Workspace", shortcut: "Ctrl+PageUp", run: () => cycleWorkspace(-1) },
  { id: "workspace.last", label: "Switch to Last Workspace", shortcut: "Ctrl+Alt+Backspace", run: () => focusLastWorkspace() },
  ...workspaceOrdinalCommands,
  { id: "workspace.starterTerminalBrowser", label: "Add Terminal + Browser Starter", shortcut: "", run: () => applyWorkspaceStarter("terminalBrowser") },
  { id: "workspace.starterTwoTerminals", label: "Add Two-Terminal Starter", shortcut: "", run: () => applyWorkspaceStarter("twoTerminals") },
  { id: "workspace.starterDevTrio", label: "Add Dev Trio Starter", shortcut: "", run: () => applyWorkspaceStarter("devTrio") },
  { id: "workspace.saveBlueprint", label: "Save Workspace Blueprint", shortcut: "", run: () => saveCurrentWorkspaceBlueprint() },
  { id: "settings.blueprints", label: "Open Workspace Blueprints", shortcut: "", run: () => openSettingsCategory("blueprints") },
  { id: "workspace.closeEmpty", label: "Close Empty Workspaces", shortcut: "", run: () => closeEmptyWorkspaces() },
  { id: "workspace.close", label: "Close Workspace", shortcut: "", run: () => closeActiveWorkspace() },
  { id: "terminal.new", label: "New Terminal", shortcut: "Ctrl+T", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitRight", label: "Split Terminal Right", shortcut: "", run: () => splitActivePanel("right") },
  { id: "terminal.splitDown", label: "Split Terminal Down", shortcut: "", run: () => splitActivePanel("down") },
  { id: "terminal.duplicate", label: "Duplicate Active Pane", shortcut: "", run: () => duplicateActivePanel() },
  { id: "terminal.nextPane", label: "Next Pane", shortcut: "Ctrl+Tab", run: () => cycleActivePane(1) },
  { id: "terminal.previousPane", label: "Previous Pane", shortcut: "Ctrl+Shift+Tab", run: () => cycleActivePane(-1) },
  { id: "terminal.lastPane", label: "Switch to Last Active Pane", shortcut: "Ctrl+Shift+Backspace", run: () => focusLastPane() },
  ...paneOrdinalCommands,
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
  { id: "terminal.focusPane", label: "Focus Active Pane", shortcut: "Ctrl+Shift+M", run: () => togglePaneZoom() },
  { id: "terminal.minimizePane", label: "Minimize Active Pane", shortcut: "", run: () => minimizeActivePane() },
  { id: "terminal.restoreMinimized", label: "Restore Minimized Panes", shortcut: "", run: () => restoreMinimizedPanes() },
  { id: "terminal.resetLayout", label: "Reset Split Layout", shortcut: "", run: () => resetActivePaneLayout() },
  { id: "layout.focusMode", label: "Toggle Focus Mode", shortcut: "Ctrl+Shift+F", run: () => toggleFocusMode() },
  { id: "layout.resetChrome", label: "Reset Workspace Chrome", shortcut: "", run: () => resetWorkspaceChrome() },
  { id: "layout.equalPanes", label: "Equalize Panes", shortcut: "", run: () => applyPaneLayoutPreset("equal") },
  { id: "layout.sideBySide", label: "Layout Panes Side by Side", shortcut: "", run: () => applyPaneLayoutPreset("sideBySide") },
  { id: "layout.stacked", label: "Stack Panes Vertically", shortcut: "", run: () => applyPaneLayoutPreset("stacked") },
  { id: "layout.activeWide", label: "Make Active Pane Wide", shortcut: "", run: () => applyPaneLayoutPreset("activeWide") },
  { id: "layout.activeTall", label: "Make Active Pane Tall", shortcut: "", run: () => applyPaneLayoutPreset("activeTall") },
  { id: "layout.activePercent", label: "Set Active Pane Size", shortcut: "", run: () => promptActivePaneLayoutPercent() },
  { id: "terminal.fontUp", label: "Active Pane Text Larger", shortcut: "Ctrl+=", run: () => changeTerminalFontSize(1) },
  { id: "terminal.fontDown", label: "Active Pane Text Smaller", shortcut: "Ctrl+-", run: () => changeTerminalFontSize(-1) },
  { id: "terminal.fontReset", label: "Reset Active Pane Text Size", shortcut: "Ctrl+0", run: () => resetTerminalFontSize() },
  { id: "browser.new", label: "Open Browser", shortcut: "Ctrl+Shift+L", run: () => openBrowserHome() },
  { id: "browser.newPane", label: "Open Browser Pane", shortcut: "", run: () => openBrowserHome(activeWorkspace()?.id, { mode: "pane" }) },
  { id: "browser.homeExternal", label: "Open Browser Home Externally", shortcut: "", run: () => openExternalBrowser(state.settings.browserHomeUrl) },
  { id: "browser.newTab", label: "New Browser Tab", shortcut: "", run: () => newBrowserTabFromPanel() },
  { id: "browser.focusAddress", label: "Focus Browser Address", shortcut: "Ctrl+L", run: () => focusBrowserAddress() },
  { id: "browser.reload", label: "Reload Active Browser", shortcut: "Ctrl+R", run: () => reloadBrowserPanel() },
  { id: "browser.openExternal", label: "Open Active Browser Externally", shortcut: "", run: () => openBrowserPanelExternally() },
  { id: "browser.copyUrl", label: "Copy Active Browser URL", shortcut: "", run: () => copyBrowserPanelUrl() },
  { id: "notifications.open", label: "Show Notifications", shortcut: "Ctrl+I", run: () => openInspector("notifications") },
  { id: "session.tools", label: "Show Session Tools", shortcut: "", run: () => openInspector("session") },
  { id: "settings.open", label: "Open Settings", shortcut: "Ctrl+,", run: () => openInspector("settings") },
  { id: "settings.resetAppearance", label: "Reset Look Settings", shortcut: "", run: () => resetAppearanceSettings() },
  { id: "settings.performance", label: "Open Performance Settings", shortcut: "", run: () => openSettingsCategory("performance") },
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
  { id: "settings.saveBackground", label: "Save Current Background", shortcut: "", run: () => saveCustomBackgroundImage({ url: state.settings.backgroundImage }) },
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
  const active = workspace?.panels.find((panel) => panel.id === workspace.activePanelId);
  if (active && !isPanelMinimized(active)) return active;
  return workspace?.panels.find((panel) => !isPanelMinimized(panel)) || active || workspace?.panels[0];
}

function workspaceHasPanelId(workspace, panelId) {
  return Boolean(workspace?.panels?.some((panel) => panel.id === panelId));
}

function isPanelMinimized(panel) {
  return Boolean(panel?.id && state.minimizedPanelIds.has(panel.id));
}

function isPendingPanel(panel) {
  return Boolean(panel?.pending || (panel?.id && state.pendingPanels.has(panel.id)));
}

function minimizedPanelCount(workspace = activeWorkspace()) {
  if (!workspace) return 0;
  return workspace.panels.filter((panel) => isPanelMinimized(panel)).length;
}

function firstUnminimizedPanel(workspace, ignoredPanelId = "") {
  return workspace?.panels.find((panel) => panel.id !== ignoredPanelId && !isPanelMinimized(panel)) || null;
}

function zoomedPanelIdForWorkspace(workspace = activeWorkspace()) {
  if (!workspace) return null;
  const scopedPanelId = state.zoomedPanelIds.get(workspace.id);
  if (workspaceHasPanelId(workspace, scopedPanelId) && !state.minimizedPanelIds.has(scopedPanelId)) {
    if (workspace.id === state.data?.activeWorkspaceId) state.zoomedPanelId = scopedPanelId;
    return scopedPanelId;
  }
  if (scopedPanelId) state.zoomedPanelIds.delete(workspace.id);
  if (workspace.id === state.data?.activeWorkspaceId) state.zoomedPanelId = null;
  return null;
}

function setZoomedPanelIdForWorkspace(workspace, panelId) {
  if (!workspace) return;
  const nextPanelId = workspaceHasPanelId(workspace, panelId) ? panelId : null;
  if (nextPanelId) state.zoomedPanelIds.set(workspace.id, nextPanelId);
  else state.zoomedPanelIds.delete(workspace.id);
  if (workspace.id === state.data?.activeWorkspaceId) state.zoomedPanelId = nextPanelId;
  if (nextPanelId && workspace.activePanelId !== nextPanelId) {
    workspace.activePanelId = nextPanelId;
  }
}

function clearZoomedPanelForWorkspace(workspace = activeWorkspace()) {
  setZoomedPanelIdForWorkspace(workspace, null);
}

function clearDifferentZoomedPanelOnFocus(workspace, panelId) {
  if (!workspace || !workspaceHasPanelId(workspace, panelId)) return false;
  const zoomedPanelId = zoomedPanelIdForWorkspace(workspace);
  if (!zoomedPanelId || zoomedPanelId === panelId) return false;
  setZoomedPanelIdForWorkspace(workspace, null);
  return true;
}

function isPanelZoomed(panel, workspace = activeWorkspace()) {
  return Boolean(panel?.id && panel.id === zoomedPanelIdForWorkspace(workspace));
}

function zoomedPanelForWorkspace(workspace = activeWorkspace()) {
  const panelId = zoomedPanelIdForWorkspace(workspace);
  if (!workspace || !panelId) return null;
  return workspace.panels.find((panel) => panel.id === panelId) || null;
}

function focusablePanelForWorkspace(workspace) {
  if (!workspace) return null;
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  if (zoomedPanel && !isPanelMinimized(zoomedPanel)) return zoomedPanel;
  return workspace.panels.find((panel) => panel.id === workspace.activePanelId && !isPanelMinimized(panel))
    || firstUnminimizedPanel(workspace)
    || workspace.panels.find((panel) => panel.id === workspace.activePanelId)
    || workspace.panels[0]
    || null;
}

function allPanels() {
  return (state.data?.workspaces || []).flatMap((workspace) => workspace.panels);
}

function isAppHomeWorkspace(workspace) {
  return Boolean(
    workspace
    && workspace.id === state.data?.activeWorkspaceId
    && workspace.panels.length === 0
    && allPanels().length === 0
  );
}

function workspaceDisplayTitle(workspace, fallback = "Workspace") {
  if (isAppHomeWorkspace(workspace)) return "cmux";
  return workspace?.title || fallback;
}

function allPanelIds() {
  return new Set(allPanels().map((panel) => panel.id));
}

function rememberPreviousWorkspace(workspaceId) {
  if (!workspaceId) return false;
  if (!state.data?.workspaces?.some((workspace) => workspace.id === workspaceId)) return false;
  state.previousWorkspaceId = workspaceId;
  return true;
}

function previousWorkspace() {
  const workspace = state.previousWorkspaceId
    ? state.data?.workspaces.find((candidate) => candidate.id === state.previousWorkspaceId)
    : null;
  if (workspace) return workspace;
  state.previousWorkspaceId = null;
  return null;
}

function rememberPreviousPanel(workspace, panelId) {
  if (!workspace?.id || !panelId) return false;
  if (!workspaceHasPanelId(workspace, panelId)) return false;
  state.previousPanelIds.set(workspace.id, panelId);
  return true;
}

function previousPanelForWorkspace(workspace = activeWorkspace()) {
  if (!workspace) return null;
  const panelId = state.previousPanelIds.get(workspace.id);
  const panel = workspace.panels.find((candidate) => candidate.id === panelId);
  if (panel) return panel;
  if (panelId) state.previousPanelIds.delete(workspace.id);
  return null;
}

function visiblePanePanelIds() {
  return new Set([...elements.paneGrid.querySelectorAll(".pane[data-panel-id]:not(.is-minimized)")].map((pane) => pane.dataset.panelId));
}

function findPanelState(panelId) {
  for (const workspace of state.data?.workspaces || []) {
    const panel = workspace.panels.find((candidate) => candidate.id === panelId);
    if (panel) return { workspace, panel };
  }
  return null;
}

function panelFromElement(target) {
  const element = target?.nodeType === Node.ELEMENT_NODE ? target : target?.parentElement;
  const panelId = element?.closest?.(".pane[data-panel-id]")?.dataset?.panelId || "";
  return panelId ? findPanelState(panelId)?.panel || null : null;
}

function panelFromEvent(event) {
  for (const target of event?.composedPath?.() || []) {
    const panel = panelFromElement(target);
    if (panel) return panel;
  }
  return panelFromElement(event?.target);
}

function panelFromActiveElement() {
  return panelFromElement(document.activeElement);
}

function hoveredPanel() {
  const found = state.hoveredPanelId ? findPanelState(state.hoveredPanelId) : null;
  if (
    found
    && found.workspace.id === state.data?.activeWorkspaceId
    && !isPanelMinimized(found.panel)
  ) {
    return found.panel;
  }
  state.hoveredPanelId = null;
  return null;
}

function markInteractedPanel(panelId) {
  const found = findPanelState(panelId);
  if (!found || found.workspace.id !== state.data?.activeWorkspaceId || isPanelMinimized(found.panel)) return null;
  const wasActive = found.workspace.activePanelId === panelId;
  if (!wasActive) rememberPreviousPanel(found.workspace, found.workspace.activePanelId);
  state.lastInteractedPanelId = panelId;
  state.focusedPanelId = panelId;
  const zoomChanged = clearDifferentZoomedPanelOnFocus(found.workspace, panelId);
  if (!wasActive) {
    found.workspace.activePanelId = panelId;
    queueFocusSync({ type: "panel", panelId });
    updateBrowserPaneActivity(visiblePanePanelIds());
  }
  if (zoomChanged) render();
  return found.panel;
}

function focusedPanel() {
  const activeElementPanel = panelFromActiveElement();
  const activeElementFound = activeElementPanel?.id ? findPanelState(activeElementPanel.id) : null;
  if (
    activeElementFound
    && activeElementFound.workspace.id === state.data?.activeWorkspaceId
    && !isPanelMinimized(activeElementFound.panel)
  ) {
    return activeElementFound.panel;
  }
  const found = state.focusedPanelId ? findPanelState(state.focusedPanelId) : null;
  if (found && found.workspace.id === state.data?.activeWorkspaceId && !isPanelMinimized(found.panel)) return found.panel;
  const interacted = state.lastInteractedPanelId ? findPanelState(state.lastInteractedPanelId) : null;
  if (interacted && interacted.workspace.id === state.data?.activeWorkspaceId && !isPanelMinimized(interacted.panel)) {
    return interacted.panel;
  }
  return activePanel();
}

function actionPanelFromEvent(event) {
  return panelFromEvent(event) || hoveredPanel() || panelFromActiveElement() || focusedPanel();
}

function activePaneActionTarget() {
  return panelFromActiveElement() || hoveredPanel() || focusedPanel();
}

function keyboardPanelFromEvent(event) {
  // If focus falls back to chrome/body, keep pane shortcuts scoped to the pane under the pointer.
  return panelFromEvent(event) || panelFromActiveElement() || hoveredPanel() || focusedPanel();
}

function api(path, options = {}) {
  const headers = {
    "content-type": "application/json",
    ...(launchToken ? { "x-local-token": launchToken } : {}),
    ...(options.headers || {})
  };
  return fetch(path, {
    ...options,
    headers
  }).then(async (response) => {
    if (!response.ok) throw new Error(await response.text());
    return response.json();
  });
}

async function loadState() {
  setAppState(await api("/api/state"));
}

function connectEvents() {
  if (state.eventSocketReconnectTimer) {
    clearTimeout(state.eventSocketReconnectTimer);
    state.eventSocketReconnectTimer = 0;
  }
  const socketGeneration = state.eventSocketGeneration + 1;
  state.eventSocketGeneration = socketGeneration;
  const url = new URL("/events", location.origin.replace(/^http/, "ws"));
  if (launchToken) url.searchParams.set("token", launchToken);
  const socket = new WebSocket(url.href);
  state.eventSocket = socket;
  socket.addEventListener("open", () => {
    if (socketGeneration !== state.eventSocketGeneration) return;
    state.eventSocketReconnectDelay = eventReconnectMinDelayMs;
  });
  socket.addEventListener("message", (event) => {
    if (socketGeneration !== state.eventSocketGeneration) return;
    const message = JSON.parse(event.data);
    if (message.type === "state") {
      setAppState(message.state, { previousState: state.data, schedule: true });
    }
  });
  socket.addEventListener("close", () => {
    if (socketGeneration !== state.eventSocketGeneration) return;
    if (state.eventSocket === socket) state.eventSocket = null;
    scheduleEventReconnect(socketGeneration);
  });
}

function scheduleEventReconnect(socketGeneration) {
  if (state.eventSocketReconnectTimer || socketGeneration !== state.eventSocketGeneration) return;
  const baseDelay = state.eventSocketReconnectDelay;
  const jitter = Math.round(baseDelay * 0.2 * Math.random());
  state.eventSocketReconnectDelay = Math.min(eventReconnectMaxDelayMs, Math.round(baseDelay * 1.7));
  state.eventSocketReconnectTimer = setTimeout(() => {
    state.eventSocketReconnectTimer = 0;
    if (socketGeneration !== state.eventSocketGeneration) return;
    connectEvents();
  }, baseDelay + jitter);
}

function appendSignatureValue(parts, value) {
  if (value === undefined) {
    parts.push("u;");
    return;
  }
  if (value === null) {
    parts.push("n;");
    return;
  }
  const text = String(value);
  parts.push(typeof value, ":", String(text.length), ":", text, ";");
}

function appendSignatureArray(parts, values, appendItem) {
  const items = Array.isArray(values) ? values : [];
  parts.push("[", String(items.length), "]");
  for (const item of items) appendItem(parts, item);
}

function appendPanelSignature(parts, panel = {}) {
  appendSignatureValue(parts, panel.id);
  appendSignatureValue(parts, panel.workspaceId);
  appendSignatureValue(parts, panel.type);
  appendSignatureValue(parts, panel.title);
  appendSignatureValue(parts, Boolean(panel.titleLocked));
  appendSignatureValue(parts, panel.color || "");
  appendSignatureValue(parts, panel.cwd);
  appendSignatureValue(parts, panel.cwdShort);
  appendSignatureValue(parts, panel.branch || "");
  appendSignatureValue(parts, panel.shellProfile || "");
  appendSignatureValue(parts, panel.shellPath || "");
  appendSignatureValue(parts, panel.terminalFontSize || 0);
  appendSignatureValue(parts, panel.url);
  appendSignatureValue(parts, Boolean(panel.needsAttention));
  appendSignatureValue(parts, panel.notificationText || "");
  appendSignatureValue(parts, Boolean(panel.pending));
  appendSignatureValue(parts, panel.pendingStartedAt || 0);
}

function appendWorkspaceSignature(parts, workspace = {}) {
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.title);
  appendSignatureValue(parts, workspace.color || "");
  appendSignatureValue(parts, workspace.activePanelId);
  appendSignatureValue(parts, workspace.splitDirection);
  appendSignatureValue(parts, workspace.terminalCount || 0);
  appendSignatureValue(parts, workspace.browserCount || 0);
  appendSignatureValue(parts, workspace.cwd);
  appendSignatureValue(parts, workspace.cwdShort);
  appendSignatureValue(parts, workspace.branch || "");
  appendSignatureValue(parts, workspace.latestNotification || "");
  appendSignatureArray(parts, workspace.panels, appendPanelSignature);
}

function appStateSignature(data) {
  try {
    if (!data || typeof data !== "object") return "";
    const parts = [];
    appendSignatureValue(parts, data.activeWorkspaceId);
    appendSignatureValue(parts, data.rendererPort || 0);
    appendSignatureValue(parts, Boolean(data.ptyAvailable));
    appendSignatureValue(parts, data.pipeName || "");
    appendSignatureArray(parts, data.palette, appendSignatureValue);
    appendSignatureArray(parts, data.workspaces, appendWorkspaceSignature);
    return parts.join("");
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

function resolvePendingPanelFromAuthoritativeState(workspace, pendingPanel) {
  if (!workspace || !pendingPanel?.id) return null;
  const currentWorkspace = state.data?.workspaces?.find((candidate) => candidate.id === pendingPanel.workspaceId);
  const currentRealPanelIds = new Set((currentWorkspace?.panels || [])
    .filter((panel) => panel.id !== pendingPanel.id && !isPendingPanel(panel))
    .map((panel) => panel.id));
  const resolvedPanels = (workspace.panels || []).filter((panel) =>
    panel.id !== pendingPanel.id
    && panel.type === pendingPanel.type
    && !currentRealPanelIds.has(panel.id)
  );
  if (resolvedPanels.length === 0) return null;
  return resolvedPanels.find((panel) => panel.id === workspace.activePanelId) || resolvedPanels.at(-1);
}

function applyPendingPanelsToState(nextData) {
  if (state.pendingPanels.size === 0 || !Array.isArray(nextData?.workspaces)) return nextData;
  let removedPending = false;
  const activePendingPanelId = state.data?.workspaces
    ?.find((workspace) => workspace.id === state.data?.activeWorkspaceId)
    ?.activePanelId || "";
  for (const pendingPanel of [...state.pendingPanels.values()]) {
    const workspace = nextData.workspaces.find((candidate) => candidate.id === pendingPanel.workspaceId);
    if (!workspace) continue;
    const resolvedPanel = resolvePendingPanelFromAuthoritativeState(workspace, pendingPanel);
    if (resolvedPanel) {
      state.pendingPanels.delete(pendingPanel.id);
      removedPending = true;
      state.canceledPendingPanelIds.delete(pendingPanel.id);
      remapPanelStateId(pendingPanel.id, resolvedPanel.id, workspace.id);
      cleanupPanel(pendingPanel.id);
      if (activePendingPanelId === pendingPanel.id || state.focusedPanelId === pendingPanel.id) {
        workspace.activePanelId = resolvedPanel.id;
        nextData.activeWorkspaceId = workspace.id;
        state.focusedPanelId = resolvedPanel.id;
        state.lastInteractedPanelId = resolvedPanel.id;
      }
      deferCreatedTerminalInitUntilPaint(resolvedPanel, workspace);
      continue;
    }
    if (workspace.panels.some((panel) => panel.id === pendingPanel.id)) continue;
    workspace.panels.push({ ...pendingPanel });
    workspace.terminalCount = workspace.panels.filter((panel) => panel.type === "terminal").length;
    workspace.browserCount = workspace.panels.filter((panel) => panel.type === "browser").length;
    if (activePendingPanelId === pendingPanel.id || state.focusedPanelId === pendingPanel.id) {
      workspace.activePanelId = pendingPanel.id;
      nextData.activeWorkspaceId = workspace.id;
    }
  }
  if (removedPending) stopPendingPaneTimerIfIdle();
  return nextData;
}

function applyPendingClosedPanelsToState(nextData) {
  if (state.pendingClosedPanelIds.size === 0 || !Array.isArray(nextData?.workspaces)) return nextData;
  for (const workspace of nextData.workspaces) {
    const panels = workspace.panels || [];
    const filtered = panels.filter((panel) => !state.pendingClosedPanelIds.has(panel.id));
    if (filtered.length === panels.length) continue;
    workspace.panels = filtered;
    if (state.pendingClosedPanelIds.has(workspace.activePanelId)) {
      workspace.activePanelId = filtered[0]?.id || null;
    }
    workspace.terminalCount = filtered.filter((panel) => panel.type === "terminal").length;
    workspace.browserCount = filtered.filter((panel) => panel.type === "browser").length;
  }
  return nextData;
}

function applyPendingTerminalFontSizesToState(nextData) {
  if (state.pendingTerminalFontSizeSync.size === 0 || !Array.isArray(nextData?.workspaces)) return nextData;
  for (const workspace of nextData.workspaces) {
    for (const panel of workspace.panels || []) {
      if (panel.type === "terminal" && state.pendingTerminalFontSizeSync.has(panel.id)) {
        panel.terminalFontSize = state.pendingTerminalFontSizeSync.get(panel.id);
      }
    }
  }
  return nextData;
}

function setAppState(nextData, { previousState = state.data, schedule = false } = {}) {
  const protectedData = applyPendingTerminalFontSizesToState(
    applyPendingClosedPanelsToState(
      applyPendingPanelsToState(applyPendingFocusToState(nextData))
    )
  );
  const nextSignature = appStateSignature(protectedData);
  if (nextSignature && nextSignature === state.dataSignature) {
    state.data = protectedData;
    state.renderStats.skippedRenders += 1;
    return false;
  }
  state.data = protectedData;
  state.dataSignature = nextSignature;
  cleanupBrowserTabSnapshots();
  if (schedule) scheduleRender(previousState);
  else render(previousState);
  return true;
}

function scheduleRender(previousState = null) {
  if (previousState && !state.scheduledRenderPrevious) state.scheduledRenderPrevious = previousState;
  if (state.renderFrame) {
    state.renderStats.coalescedRenders += 1;
    return;
  }
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
  const workspaceTitle = workspaceDisplayTitle(workspace);
  const workspaceSubheading = workspace
    ? (isAppHomeWorkspace(workspace) ? "home" : `${workspace.cwdShort || "no directory"}`)
    : "Ready";

  setTextIfChanged(elements.workspaceHeading, workspaceTitle);
  setTextIfChanged(elements.workspaceSubheading, workspaceSubheading);
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
  toggleClassIfChanged(elements.shell, "workspace-empty", panelCount === 0);
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
  if (state.inspectorMode === "settings" && (state.settingsCategory === "performance" || normalizeSettingsQuery(state.settingsQuery))) {
    refreshPerformanceMetricsGrid();
  }
  if (!performanceGuardCanUseRenderSignal()) return;
  if (value >= renderSlowFrameMs) state.performanceGuardSlowRenderCount += 1;
  if (value >= renderVerySlowFrameMs || state.performanceGuardSlowRenderCount >= renderSlowFrameTriggerCount) {
    maybeTriggerPerformanceGuard("slow rendering");
  }
}

function performanceGuardCanUseRenderSignal() {
  return state.renderStats.count > performanceGuardStartupRenderCount
    && performance.now() - state.performanceGuardStartedAt >= performanceGuardStartupGraceMs;
}

function cleanupStalePaneCache() {
  const livePanelIds = allPanelIds();
  for (const panelId of [...state.paneCache.keys()]) {
    if (!livePanelIds.has(panelId)) cleanupPanel(panelId);
  }
  cleanupPaneLayouts();
  cleanupPaneTrees();
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

function paneCreationButtonsDisabled() {
  return paneCreationOperationCount() >= maxConcurrentPaneCreations;
}

function paneCreationOperationCount() {
  let count = 0;
  for (const operation of state.uiOperations.values()) {
    if (operation.kind === "create-panel") count += 1;
  }
  return count;
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
    workspaceDisplayTitle(workspace),
    zoomedPanel ? "focus" : panelCount ? `${panelCount} pane${panelCount === 1 ? "" : "s"}` : "home"
  ];
  if (attentionCount > 0) parts.push(`${attentionCount} attention`);
  return parts.join(" · ");
}

function switchHudParts(hud) {
  hud._switchHudParts ||= {
    index: hud.querySelector(".workspace-switch-index"),
    title: hud.querySelector(".workspace-switch-title"),
    meta: hud.querySelector(".workspace-switch-meta")
  };
  return hud._switchHudParts;
}

function setSwitchHudVisible(hud, visible) {
  toggleClassIfChanged(hud, "is-visible", visible);
  const ariaHidden = visible ? "false" : "true";
  if (hud.getAttribute("aria-hidden") !== ariaHidden) {
    hud.setAttribute("aria-hidden", ariaHidden);
  }
}

function updateSwitchHud(hud, details) {
  const parts = switchHudParts(hud);
  setStylePropertyIfChanged(hud, "--workspace-hud-color", details.color);
  setTextIfChanged(parts.index, details.index);
  setTextIfChanged(parts.title, details.title);
  setTextIfChanged(parts.meta, details.meta);
  setSwitchHudVisible(hud, true);
}

function showWorkspaceSwitchHud(workspace) {
  if (!workspace || !elements.workspaceSwitchHud) return;
  const workspaces = state.data?.workspaces || [];
  const index = Math.max(0, workspaces.findIndex((candidate) => candidate.id === workspace.id));
  const panelCount = workspace.panels?.length || 0;
  const meta = [
    isAppHomeWorkspace(workspace) ? "home" : workspace.cwdShort || workspace.cwd || "no directory",
    panelCount ? `${panelCount} pane${panelCount === 1 ? "" : "s"}` : "home"
  ].filter(Boolean).join(" · ");
  updateSwitchHud(elements.workspaceSwitchHud, {
    color: workspace.color || state.data?.palette?.[0] || state.settings.accent,
    index: `${index + 1} / ${Math.max(1, workspaces.length)}`,
    title: workspaceDisplayTitle(workspace, `Workspace ${index + 1}`),
    meta
  });
  if (state.workspaceSwitchHudTimer) clearTimeout(state.workspaceSwitchHudTimer);
  state.workspaceSwitchHudTimer = setTimeout(() => {
    state.workspaceSwitchHudTimer = 0;
    setSwitchHudVisible(elements.workspaceSwitchHud, false);
  }, 900);
}

function showPaneSwitchHud(panel, workspace = activeWorkspace()) {
  if (!panel || !workspace || !elements.paneSwitchHud) return;
  const panels = workspace.panels || [];
  const index = Math.max(0, panels.findIndex((candidate) => candidate.id === panel.id));
  const panelType = panel.type === "browser" ? "browser" : "terminal";
  const location = panel.type === "browser"
    ? hostnameOf(panel.url || state.settings.browserHomeUrl)
    : panel.cwdShort || panel.cwd || workspace.cwdShort || "~";
  updateSwitchHud(elements.paneSwitchHud, {
    color: panel.color || workspace.color || state.data?.palette?.[0] || state.settings.accent,
    index: `${index + 1} / ${Math.max(1, panels.length)}`,
    title: panelDisplayTitle(panel, false),
    meta: `${panelType} · ${location}`
  });
  if (state.paneSwitchHudTimer) clearTimeout(state.paneSwitchHudTimer);
  state.paneSwitchHudTimer = setTimeout(() => {
    state.paneSwitchHudTimer = 0;
    setSwitchHudVisible(elements.paneSwitchHud, false);
  }, 720);
}

function updateRuntimeStatusLabels() {
  const pipeName = state.data?.pipeName || "";
  setTextIfChanged(elements.statusPipe, pipeName ? "pipe" : "pipe unavailable");
  setTitleIfChanged(elements.statusPipe, pipeName || "Control pipe unavailable");
  setTextIfChanged(elements.statusPty, state.data?.ptyAvailable ? "shell ready" : "compat mode");
  setTitleIfChanged(elements.statusPty, state.data?.ptyAvailable
    ? "Terminal shell ready"
    : "Compatibility shell mode active");
}

function updateOperationChrome() {
  const label = currentUiOperationLabel();
  const creatingPane = paneCreationButtonsDisabled();
  toggleClassIfChanged(elements.shell, "operation-pending", Boolean(label));
  toggleClassIfChanged(elements.statusSummary, "is-busy", Boolean(label));
  setTextIfChanged(elements.statusSummary, label || defaultStatusSummary());
  for (const id of ["newTerminalButton", "splitRightButton", "splitDownButton", "newBrowserButton"]) {
    const button = document.getElementById(id);
    if (button) button.disabled = creatingPane;
  }
  if (state.newTabButton) state.newTabButton.disabled = creatingPane;
  updateVisibleEmptyWorkspaceControls();
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
  const signature = workspaceListSignature();
  if (
    signature === state.workspaceListSignature
    && state.workspaceRows.size === state.data.workspaces.length
    && elements.workspaceList.childNodes.length === state.data.workspaces.length
  ) {
    return;
  }
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
  state.workspaceListSignature = signature;
}

function workspaceListSignature() {
  const activeId = state.data?.activeWorkspaceId || "";
  const paletteColor = state.data?.palette?.[0] || "";
  return stableJson([
    activeId,
    paletteColor,
    state.settings.sidebarDetailMode,
    ...(state.data?.workspaces || []).map((workspace, index) => {
      const attentionTotal = workspace.panels.filter((panel) => panel.needsAttention).length;
      const branch = workspaceRowBranch(workspace);
      return [
        workspace.id,
        workspace.title || `Workspace ${index + 1}`,
        workspace.cwdShort || "~",
        branch,
        workspace.color || paletteColor,
        workspace.terminalCount || 0,
        workspace.browserCount || 0,
        workspace.latestNotification || "",
        attentionTotal
      ];
    })
  ]);
}

function createWorkspaceRow() {
  const button = document.createElement("button");
  button.className = "workspace-row";
  button.draggable = true;
  button.innerHTML = `
    <span class="workspace-attention"></span>
    <span class="workspace-card">
      <span class="workspace-name-line">
        <span class="workspace-color"></span>
        <span class="workspace-name"></span>
        <span class="workspace-badge"></span>
      </span>
      <span class="workspace-meta"></span>
      <span class="workspace-detail-line">
        <span class="workspace-path"></span>
        <span class="workspace-branch"></span>
      </span>
    </span>
  `;
  button._workspaceParts = workspaceRowParts(button);
  button.addEventListener("click", () => focusWorkspace(button.dataset.workspaceId));
  button.addEventListener("dblclick", (event) => {
    event.preventDefault();
    event.stopPropagation();
    const workspace = state.data?.workspaces.find((candidate) => candidate.id === button.dataset.workspaceId);
    if (workspace) renameWorkspaceById(workspace.id, workspace.title);
  });
  button.addEventListener("dragstart", (event) => {
    state.dragWorkspaceId = button.dataset.workspaceId;
    state.dragPanelId = null;
    button.classList.add("is-workspace-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", state.dragWorkspaceId);
  });
  button.addEventListener("dragend", () => {
    button.classList.remove("is-workspace-dragging");
    state.dragWorkspaceId = null;
    clearAllDropTargets();
  });
  button.addEventListener("contextmenu", (event) => {
    const workspace = state.data?.workspaces.find((candidate) => candidate.id === button.dataset.workspaceId);
    if (workspace) showWorkspaceContextMenu(event, workspace);
  });
  button.addEventListener("dragover", (event) => {
    if (!state.dragPanelId && !state.dragWorkspaceId) return;
    event.preventDefault();
    clearWorkspaceListDropTarget();
    if (state.dragPanelId) {
      button.classList.add("is-drop-target");
      return;
    }
    if (state.dragWorkspaceId === button.dataset.workspaceId) return;
    const placement = workspaceDropPlacement(event, button);
    button.classList.toggle("is-workspace-drop-before", placement === "before");
    button.classList.toggle("is-workspace-drop-after", placement === "after");
  });
  button.addEventListener("dragleave", () => {
    button.classList.remove("is-drop-target", "is-workspace-drop-before", "is-workspace-drop-after");
  });
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const targetWorkspaceId = button.dataset.workspaceId;
    const workspacePlacement = workspaceDropPlacement(event, button);
    button.classList.remove("is-drop-target", "is-workspace-drop-before", "is-workspace-drop-after");
    if (state.dragPanelId) movePanelToWorkspace(state.dragPanelId, targetWorkspaceId);
    else if (state.dragWorkspaceId && state.dragWorkspaceId !== targetWorkspaceId) {
      moveWorkspaceRelative(state.dragWorkspaceId, targetWorkspaceId, workspacePlacement);
    }
  });
  return button;
}

function clearWorkspaceListDropTarget() {
  elements.workspaceList.classList.remove("is-workspace-drop-end");
}

function isWorkspaceRowEvent(event) {
  return Boolean(event.target?.closest?.(".workspace-row"));
}

function workspaceListCanDropToEnd() {
  const workspaces = state.data?.workspaces || [];
  return Boolean(
    state.dragWorkspaceId
    && workspaces.length > 1
    && workspaces.some((workspace) => workspace.id === state.dragWorkspaceId)
    && workspaces.at(-1)?.id !== state.dragWorkspaceId
  );
}

function handleWorkspaceListDragOver(event) {
  if (isWorkspaceRowEvent(event) || !workspaceListCanDropToEnd()) return;
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
  elements.workspaceList.classList.add("is-workspace-drop-end");
}

function handleWorkspaceListDragLeave(event) {
  if (event.currentTarget.contains(event.relatedTarget)) return;
  clearWorkspaceListDropTarget();
}

function handleWorkspaceListDrop(event) {
  if (isWorkspaceRowEvent(event) || !workspaceListCanDropToEnd()) return;
  event.preventDefault();
  const workspaceId = state.dragWorkspaceId;
  clearWorkspaceListDropTarget();
  updateWorkspaceOrder(workspaceId, { moveToEnd: true });
}

function workspaceRowParts(button) {
  button._workspaceParts ||= {
    name: button.querySelector(".workspace-name"),
    badge: button.querySelector(".workspace-badge"),
    meta: button.querySelector(".workspace-meta"),
    path: button.querySelector(".workspace-path"),
    branch: button.querySelector(".workspace-branch")
  };
  return button._workspaceParts;
}

function workspaceDropPlacement(event, row) {
  const rect = row.getBoundingClientRect();
  const y = rect.height ? (event.clientY - rect.top) / rect.height : 0.5;
  return y < 0.5 ? "before" : "after";
}

function workspaceRowBranch(workspace) {
  if (state.settings.sidebarDetailMode !== "detailed") return "";
  return String(workspace?.branch || "").trim();
}

function updateWorkspaceRow(button, workspace, index, activeId) {
  const hasAttention = workspace.panels.some((panel) => panel.needsAttention);
  const attentionTotal = workspace.panels.filter((panel) => panel.needsAttention).length;
  const title = workspaceDisplayTitle(workspace, `Workspace ${index + 1}`);
  const cwd = isAppHomeWorkspace(workspace) ? "home" : workspace.cwdShort || "~";
  const branch = workspaceRowBranch(workspace);
  const paneSummary = `${workspace.terminalCount || 0} terminal${workspace.terminalCount === 1 ? "" : "s"} / ${workspace.browserCount || 0} browser${workspace.browserCount === 1 ? "" : "s"}`;
  const parts = workspaceRowParts(button);
  setDatasetIfChanged(button, "workspaceId", workspace.id);
  setClassNameIfChanged(button, `workspace-row${workspace.id === activeId ? " is-active" : ""}${hasAttention ? " has-attention" : ""}${branch ? " has-branch" : ""}`);
  setStylePropertyIfChanged(button, "--workspace-color", workspace.color || state.data.palette?.[0] || "");
  setTitleIfChanged(button, `${title} - ${cwd}${branch ? ` - ${branch}` : ""} - ${paneSummary} - double-click to rename`);
  setTextIfChanged(parts.name, title);
  setTextIfChanged(parts.badge, hasAttention ? String(attentionTotal) : "");
  setTextIfChanged(parts.meta, workspace.latestNotification || "");
  setTextIfChanged(parts.path, cwd);
  setTitleIfChanged(parts.path, cwd);
  setTextIfChanged(parts.branch, branch ? `git ${branch}` : "");
  setTitleIfChanged(parts.branch, branch ? `git ${branch}` : "");
  setHiddenIfChanged(parts.branch, !branch);
}

function renderSurfaceTabs(workspace) {
  if (!workspace) {
    clearSurfaceTabs();
    return;
  }
  if (workspace.panels.length === 0) {
    clearSurfaceTabs();
    return;
  }
  const signature = surfaceTabsSignature(workspace);
  if (
    signature === state.surfaceTabsSignature
    && state.newTabButton
    && state.newTabButton.dataset.workspaceId === workspace.id
    && state.surfaceTabButtons.size === workspace.panels.length
    && elements.surfaceTabs.childNodes.length === workspace.panels.length + 1
  ) {
    scheduleSurfaceTabsOverflowRefresh();
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
  state.surfaceTabsSignature = signature;
  scheduleSurfaceTabsOverflowRefresh({ ensureActive: true });
}

function clearSurfaceTabs() {
  for (const tab of state.surfaceTabButtons.values()) tab.remove();
  state.surfaceTabButtons.clear();
  state.surfaceTabsSignature = "";
  state.surfaceTabEnsureActive = false;
  replaceChildrenIfChanged(elements.surfaceTabs, []);
  toggleClassIfChanged(elements.surfaceTabs, "has-overflow", false);
  toggleClassIfChanged(elements.surfaceTabs, "is-crowded", false);
  toggleClassIfChanged(elements.surfaceTabs, "can-scroll-left", false);
  toggleClassIfChanged(elements.surfaceTabs, "can-scroll-right", false);
}

function surfaceTabsSignature(workspace) {
  const zoomedPanelId = zoomedPanelIdForWorkspace(workspace) || "";
  return stableJson([
    workspace.id,
    workspace.activePanelId || "",
    workspace.color || "",
    state.settings.titleDetailMode,
    paneCreationButtonsDisabled(),
    workspace.panels.map((panel) => {
      const pending = isPendingPanel(panel);
      const minimized = isPanelMinimized(panel);
      return [
        panel.id,
        surfaceTabLabel(workspace, panel),
        panelDisplayTitle(panel, false),
        panel.color || workspace.color || "var(--color-accent)",
        panel.id === workspace.activePanelId,
        panel.id === zoomedPanelId,
        minimized,
        pending,
        Boolean(panel.needsAttention)
      ];
    })
  ]);
}

function scheduleActiveSurfaceTabIntoView(panelId) {
  if (!panelId) return;
  state.surfaceTabScrollTargetId = panelId;
  if (state.surfaceTabScrollFrame) return;
  state.surfaceTabScrollFrame = requestAnimationFrame(() => {
    state.surfaceTabScrollFrame = 0;
    const targetPanelId = state.surfaceTabScrollTargetId;
    state.surfaceTabScrollTargetId = "";
    const activeTab = state.surfaceTabButtons.get(targetPanelId);
    scrollChildIntoView(elements.surfaceTabs, activeTab, {
      inset: 42,
      smooth: !document.body.classList.contains("reduce-motion") && !state.settings.reduceMotion && !state.settings.performanceMode
    });
  });
}

function scheduleSurfaceTabsOverflowRefresh(options = {}) {
  if (options.ensureActive) state.surfaceTabEnsureActive = true;
  if (state.surfaceTabOverflowFrame) return;
  state.surfaceTabOverflowFrame = requestAnimationFrame(() => {
    state.surfaceTabOverflowFrame = 0;
    const ensureActive = state.surfaceTabEnsureActive;
    state.surfaceTabEnsureActive = false;
    updateSurfaceTabsOverflow();
    if (ensureActive) scheduleActiveSurfaceTabIntoView(activeWorkspace()?.activePanelId);
  });
}

function surfaceTabsOverflowing() {
  return elements.surfaceTabs.scrollWidth > elements.surfaceTabs.clientWidth + 1;
}

function updateSurfaceTabScrollState(strip, overflowing = surfaceTabsOverflowing()) {
  if (!strip) return;
  const maxScrollLeft = Math.max(0, strip.scrollWidth - strip.clientWidth);
  const scrollLeft = Math.max(0, strip.scrollLeft);
  toggleClassIfChanged(strip, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(strip, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
}

function updateSurfaceTabsOverflow() {
  if (!elements.surfaceTabs) return;
  const strip = elements.surfaceTabs;
  const tabCount = Math.max(0, elements.surfaceTabs.querySelectorAll(".surface-tab:not(.surface-new-tab)").length);
  if (tabCount < 6 && strip.classList.contains("is-crowded")) {
    strip.classList.remove("is-crowded");
  }
  const normalOverflow = surfaceTabsOverflowing();
  const crowded = normalOverflow || tabCount >= 6;
  toggleClassIfChanged(strip, "is-crowded", crowded);
  const finalOverflow = surfaceTabsOverflowing();
  toggleClassIfChanged(strip, "has-overflow", finalOverflow);
  updateSurfaceTabScrollState(strip, finalOverflow);
  if (!finalOverflow && strip.scrollLeft) strip.scrollLeft = 0;
}

function commandStripContentWidth() {
  if (!elements.commandStrip) return 0;
  const style = getComputedStyle(elements.commandStrip);
  const gap = parseFloat(style.columnGap || style.gap) || 0;
  const padding = (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0);
  const visibleChildren = Array.from(elements.commandStrip.children).filter((child) => {
    const childStyle = getComputedStyle(child);
    return childStyle.display !== "none" && childStyle.visibility !== "hidden";
  });
  const childWidth = visibleChildren.reduce((total, child) => total + child.getBoundingClientRect().width, 0);
  return childWidth + Math.max(0, visibleChildren.length - 1) * gap + padding;
}

function scheduleCommandStripOverflowRefresh() {
  if (state.commandStripOverflowFrame) return;
  state.commandStripOverflowFrame = requestAnimationFrame(() => {
    state.commandStripOverflowFrame = 0;
    updateCommandStripOverflow();
  });
}

function updateCommandStripOverflow() {
  if (!elements.commandStrip) return;
  const strip = elements.commandStrip;
  const overflowing = commandStripContentWidth() > elements.commandStrip.clientWidth + 1
    || elements.commandStrip.scrollWidth > elements.commandStrip.clientWidth + 1;
  const maxScrollLeft = Math.max(0, strip.scrollWidth - strip.clientWidth);
  const scrollLeft = Math.max(0, strip.scrollLeft);
  toggleClassIfChanged(strip, "has-overflow", overflowing);
  toggleClassIfChanged(strip, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(strip, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
  if (!overflowing && strip.scrollLeft) {
    strip.scrollLeft = 0;
  }
}

function observeCommandStripOverflow() {
  if (!elements.commandStrip) return;
  if (typeof ResizeObserver === "function") {
    state.commandStripResizeObserver = new ResizeObserver(scheduleCommandStripOverflowRefresh);
    state.commandStripResizeObserver.observe(elements.commandStrip);
  }
  window.addEventListener("resize", scheduleCommandStripOverflowRefresh, { passive: true });
  elements.commandStrip.addEventListener("scroll", () => updateCommandStripOverflow(), { passive: true });
  requestAnimationFrame(() => {
    updateCommandStripOverflow();
  });
}

function observeSurfaceTabOverflow() {
  if (!elements.surfaceTabs) return;
  if (typeof ResizeObserver === "function") {
    state.surfaceTabResizeObserver = new ResizeObserver(scheduleSurfaceTabsOverflowRefresh);
    for (const target of [
      elements.surfaceTabs,
      elements.surfaceTabs.parentElement,
      elements.shell,
      elements.inspector
    ]) {
      if (target) state.surfaceTabResizeObserver.observe(target);
    }
  }
  window.addEventListener("resize", scheduleSurfaceTabsOverflowRefresh, { passive: true });
  window.visualViewport?.addEventListener("resize", scheduleSurfaceTabsOverflowRefresh, { passive: true });
  elements.surfaceTabs.addEventListener("scroll", () => updateSurfaceTabScrollState(elements.surfaceTabs), { passive: true });
  requestAnimationFrame(() => {
    updateSurfaceTabsOverflow();
  });
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
  button._surfaceParts = surfaceTabParts(button);
  button.addEventListener("click", () => {
    const panelId = button.dataset.panelId;
    if (state.minimizedPanelIds.has(panelId)) restorePane(panelId);
    else focusPanel(panelId);
    scheduleActiveSurfaceTabIntoView(panelId);
  });
  button.addEventListener("mousedown", (event) => {
    if (event.button === 1) event.preventDefault();
  });
  button.addEventListener("auxclick", (event) => {
    if (event.button !== 1) return;
    event.preventDefault();
    event.stopPropagation();
    closePanel(button.dataset.panelId);
  });
  button.addEventListener("dblclick", (event) => {
    if (event.target.closest(".surface-close")) return;
    event.preventDefault();
    event.stopPropagation();
    const found = findPanelState(button.dataset.panelId);
    if (found && !isPendingPanel(found.panel)) renamePanel(found.panel);
  });
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
    clearSurfaceTabDropTargets();
    button.classList.add(surfaceTabDropPlacement(event, button) === "after" ? "is-drop-after" : "is-drop-before");
  });
  button.addEventListener("dragleave", () => button.classList.remove("is-drop-before", "is-drop-after"));
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const placement = surfaceTabDropPlacement(event, button);
    button.classList.remove("is-drop-before", "is-drop-after");
    if (state.dragPanelId && state.dragPanelId !== button.dataset.panelId) {
      if (placement === "after") movePanelAfter(state.dragPanelId, button.dataset.panelId);
      else movePanelBefore(state.dragPanelId, button.dataset.panelId);
    }
  });
  button.addEventListener("dragend", () => {
    button.classList.remove("is-dragging");
    state.dragPanelId = null;
    clearAllDropTargets();
  });
  button._surfaceParts.close.addEventListener("click", (event) => {
    event.stopPropagation();
    closePanel(button.dataset.panelId);
  });
  return button;
}

function surfaceTabParts(button) {
  button._surfaceParts ||= {
    dot: button.querySelector(".surface-dot"),
    label: button.querySelector(".surface-label"),
    close: button.querySelector(".surface-close")
  };
  return button._surfaceParts;
}

function updateSurfaceTab(button, workspace, panel) {
  const label = surfaceTabLabel(workspace, panel);
  const fullTitle = panelDisplayTitle(panel, false);
  const minimized = isPanelMinimized(panel);
  const pending = isPendingPanel(panel);
  const ordinal = Math.max(1, (workspace?.panels || []).findIndex((candidate) => candidate.id === panel.id) + 1);
  const parts = surfaceTabParts(button);
  setDatasetIfChanged(button, "panelId", panel.id);
  setClassNameIfChanged(button, `surface-tab${panel.id === workspace.activePanelId ? " is-active" : ""}${isPanelZoomed(panel, workspace) ? " is-zoomed" : ""}${minimized ? " is-minimized" : ""}${pending ? " is-pending" : ""}${panel.needsAttention ? " has-attention" : ""}`);
  setTitleIfChanged(button, `${label}${label !== fullTitle ? ` - ${fullTitle}` : ""}${pending ? " - starting" : ""}${minimized ? " - minimized, click to restore" : ""} - middle-click to ${pending ? "cancel" : "close"}, double-click to rename, right-click for pane options`);
  setStylePropertyIfChanged(button, "--tab-color", panel.color || workspace.color || "var(--color-accent)");
  setDatasetIfChanged(parts.dot, "tabIndex", String(ordinal));
  setTextIfChanged(parts.label, label);
}

function surfaceTabDropPlacement(event, button) {
  const rect = button.getBoundingClientRect();
  return event.clientX > rect.left + rect.width / 2 ? "after" : "before";
}

function clearSurfaceTabDropTargets() {
  for (const button of elements.surfaceTabs.querySelectorAll(".surface-tab.is-drop-before, .surface-tab.is-drop-after")) {
    button.classList.remove("is-drop-before", "is-drop-after");
  }
}

function getNewSurfaceTab(workspace) {
  if (!state.newTabButton) {
    state.newTabButton = document.createElement("button");
    state.newTabButton.className = "surface-tab surface-new-tab";
    state.newTabButton.type = "button";
    state.newTabButton.title = "Add pane";
    state.newTabButton.setAttribute("aria-label", "Add pane");
    state.newTabButton.textContent = "+";
    state.newTabButton.onclick = (event) => showNewSurfaceTabMenu(event, newSurfaceTabWorkspace());
    state.newTabButton.addEventListener("contextmenu", (event) => showNewSurfaceTabMenu(event, newSurfaceTabWorkspace()));
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
  state.newTabButton.disabled = paneCreationButtonsDisabled();
  setTitleIfChanged(state.newTabButton, state.newTabButton.disabled ? currentUiOperationLabel() || "Pane is being added" : "Add pane");
  return state.newTabButton;
}

function newSurfaceTabWorkspace() {
  const workspaceId = state.newTabButton?.dataset.workspaceId || activeWorkspace()?.id || "";
  return state.data?.workspaces.find((candidate) => candidate.id === workspaceId) || activeWorkspace();
}

function showNewSurfaceTabMenu(event, workspace = activeWorkspace()) {
  event.preventDefault();
  event.stopPropagation();
  if (!workspace) return;
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = "Add pane";
  const actions = contextMenuActionGroup(
    contextMenuButton("New terminal", () => createPanel("terminal", "right", { workspaceId: workspace.id }), paneCreationButtonsDisabled()),
    contextMenuButton("New browser pane", () => openBrowserHome(workspace.id, { mode: "pane" }), paneCreationButtonsDisabled()),
    contextMenuButton("Reopen closed pane", reopenClosedPanel, state.closedPanels.length === 0 || paneCreationButtonsDisabled())
  );
  menu.replaceChildren(title, actions);
  if (event.type === "contextmenu") {
    showContextMenuAt(menu, event.clientX, event.clientY);
  } else {
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenuAt(menu, rect.left, rect.bottom + 6);
  }
}

function renderPanes(workspace) {
  const panels = workspace?.panels || [];
  if (!workspace) {
    state.paneRenderSignature = "";
    state.paneFitSignature = "";
    renderEmptyWorkspace(null);
    updateBrowserPaneActivity(new Set());
    return;
  }
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  const visiblePanels = zoomedPanel ? [zoomedPanel] : panels;
  const tree = zoomedPanel ? paneTreeLeaf(zoomedPanel.id) : paneTreeForWorkspace(workspace, visiblePanels);
  const signature = paneRenderSignature(workspace, visiblePanels, tree);
  const fitSignature = paneFitSignature(workspace, visiblePanels, tree);
  const shouldFitVisibleTerminals = fitSignature !== state.paneFitSignature;
  const liveVisiblePanelIds = new Set(visiblePanels.filter((panel) => !isPanelMinimized(panel)).map((panel) => panel.id));
  if (signature === state.paneRenderSignature && paneGridContainsPanels(visiblePanels)) {
    updateBrowserPaneActivity(liveVisiblePanelIds);
    resumeTerminalOutputAfterActivityChange(liveVisiblePanelIds);
    if (shouldFitVisibleTerminals) {
      state.paneFitSignature = fitSignature;
      scheduleVisibleTerminalFits(visiblePanels);
    }
    return;
  }
  toggleClassIfChanged(elements.paneGrid, "direction-down", false);
  elements.paneLayoutStyle.textContent = "";
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
    state.paneRenderSignature = "";
    state.paneFitSignature = "";
    renderEmptyWorkspace(workspace);
    updateBrowserPaneActivity(new Set());
    return;
  }

  const panelById = new Map(visiblePanels.map((panel) => [panel.id, panel]));
  const node = renderPaneTreeNode(tree, workspace, panelById, visiblePanels.length);
  replaceChildrenIfChanged(elements.paneGrid, node ? [node] : []);
  state.paneRenderSignature = signature;
  state.paneFitSignature = fitSignature;
  updateBrowserPaneActivity(liveVisiblePanelIds);
  resumeTerminalOutputAfterActivityChange(liveVisiblePanelIds);
  if (shouldFitVisibleTerminals) scheduleVisibleTerminalFits(visiblePanels);
}

function paneGridContainsPanels(panels) {
  if (!panels.length) return false;
  const paneNodes = elements.paneGrid.querySelectorAll(".pane[data-panel-id]");
  if (paneNodes.length !== panels.length) return false;
  return panels.every((panel) => {
    const pane = state.paneCache.get(panel.id);
    return pane?.isConnected && elements.paneGrid.contains(pane);
  });
}

function scheduleVisibleTerminalFits(visiblePanels) {
  for (const panel of visiblePanels) {
    if (!panel?.id || isPanelMinimized(panel)) continue;
    state.visibleTerminalFitPanelIds.add(panel.id);
  }
  if (state.visibleTerminalFitFrame || state.visibleTerminalFitPanelIds.size === 0) return;
  state.visibleTerminalFitFrame = requestAnimationFrame(() => {
    state.visibleTerminalFitFrame = 0;
    const panelIds = [...state.visibleTerminalFitPanelIds];
    state.visibleTerminalFitPanelIds.clear();
    const activeWorkspaceId = state.data?.activeWorkspaceId || "";
    for (const panelId of panelIds) {
      const found = findPanelState(panelId);
      if (!found || found.workspace.id !== activeWorkspaceId || isPanelMinimized(found.panel)) continue;
      const terminal = state.terminals.get(panelId);
      if (terminal) scheduleFitTerminal(terminal);
    }
  });
}

function paneRenderSignature(workspace, visiblePanels, tree) {
  return stableJson([
    workspace.id,
    workspace.activePanelId || "",
    workspace.color || "",
    Boolean(zoomedPanelIdForWorkspace(workspace)),
    state.settings.titleDetailMode,
    state.settings.browserSuspendInactive,
    state.settings.browserHomeUrl,
    state.settings.terminalProfile,
    tree,
    visiblePanels.map((panel) => ([
      panel.id,
      panel.type,
      panelDisplayTitle(panel, false),
      panel.title || "",
      panel.titleLocked || false,
      panel.color || "",
      panel.cwd || "",
      panel.cwdShort || "",
      panel.url || "",
      panel.shellProfile || "",
      panel.shellPath || "",
      terminalFontSizeForPanel(panel),
      Boolean(panel.needsAttention),
      isPanelMinimized(panel),
      isPendingPanel(panel),
      state.terminals.has(panel.id),
      state.browserViews.has(panel.id)
    ]))
  ]);
}

function paneFitSignature(workspace, visiblePanels, tree) {
  return stableJson([
    workspace.id,
    zoomedPanelIdForWorkspace(workspace) || "",
    tree,
    visiblePanels.map((panel) => ([
      panel.id,
      panel.type,
      isPanelMinimized(panel),
      panel.type === "terminal" ? terminalFontSizeForPanel(panel) : 0
    ]))
  ]);
}

function renderPaneTreeNode(node, workspace, panelById, visibleCount) {
  if (!node) return null;
  if (node.type === "pane") {
    const panel = panelById.get(node.panelId);
    if (!panel) return null;
    return renderPaneNode(panel, workspace, visibleCount);
  }
  const first = renderPaneTreeNode(node.first, workspace, panelById, visibleCount);
  const second = renderPaneTreeNode(node.second, workspace, panelById, visibleCount);
  if (!first) return second;
  if (!second) return first;
  const split = getPaneSplitNode(node);
  const splitter = getPaneSplitter(workspace, node);
  const firstRatio = paneTreeRatio(node.ratio);
  first.style.flex = `${Math.round(firstRatio * paneLayoutScale)} 1 0px`;
  second.style.flex = `${Math.round((1 - firstRatio) * paneLayoutScale)} 1 0px`;
  replaceChildrenIfChanged(split, [first, splitter, second]);
  return split;
}

function renderPaneNode(panel, workspace, visibleCount) {
  let pane = state.paneCache.get(panel.id) || elements.paneGrid.querySelector(`[data-panel-id="${panel.id}"]`);
  if (!pane) pane = createPane(panel);
  const parts = paneParts(pane);
  setDatasetIfChanged(pane, "panelId", panel.id);
  setStylePropertyIfChanged(pane, "--panel-color", panel.color || workspace.color || "var(--color-accent)");
  toggleClassIfChanged(pane, "is-active", panel.id === workspace.activePanelId);
  const zoomed = isPanelZoomed(panel, workspace);
  toggleClassIfChanged(pane, "is-zoomed", zoomed);
  toggleClassIfChanged(pane, "has-attention", panel.needsAttention);
  toggleClassIfChanged(pane, "is-browser", panel.type === "browser");
  toggleClassIfChanged(pane, "is-terminal", panel.type === "terminal");
  toggleClassIfChanged(pane, "is-minimized", isPanelMinimized(panel));
  const pending = isPendingPanel(panel);
  toggleClassIfChanged(pane, "is-pending", pending);
  if (visibleCount <= 1) clearPaneFlex(pane);
  setTextIfChanged(parts.type, panel.type === "browser" ? "web" : "term");
  const title = panelDisplayTitle(panel, false);
  setTextIfChanged(parts.title, title);
  setTitleIfChanged(parts.title, title);
  setTitleIfChanged(parts.header, `${title} - double-click to rename`);
  setTextIfChanged(parts.zoom, zoomed ? "↙" : "□");
  setTitleIfChanged(parts.zoom, zoomed ? "Show all panes" : "Focus pane");
  setTextIfChanged(parts.minimize, isPanelMinimized(panel) ? "+" : "-");
  setTitleIfChanged(parts.minimize, isPanelMinimized(panel) ? "Restore pane" : "Minimize pane");
  const terminalOnlyButtons = [parts.fontDown, parts.fontUp, parts.restart];
  for (const button of parts.tools) {
    button.disabled = (pending && !button.classList.contains("close"))
      || (terminalOnlyButtons.includes(button) && panel.type !== "terminal");
  }
  setTitleIfChanged(parts.close, pending ? "Cancel pane" : "Close");
  if (pending) {
    renderPendingPane(panel, parts.body);
    return pane;
  }
  if (panel.type === "terminal") {
    const body = parts.body;
    const deferUntilPaint = shouldDeferTerminalInitUntilPaint(panel, workspace);
    if (shouldDeferInitialTerminalLoad(panel, workspace, visibleCount)) {
      renderDeferredTerminal(panel, body);
      if (deferUntilPaint) state.paintDeferredTerminalInitPanelIds.delete(panel.id);
      queueDeferredTerminalInit(panel.id, { afterPaint: deferUntilPaint });
    } else {
      ensureTerminal(panel, body);
    }
    const terminal = state.terminals.get(panel.id);
    if (terminal) scheduleFitTerminal(terminal);
  }
  if (panel.type === "browser") {
    const body = parts.body;
    if (shouldRenderDeferredBrowserShell(panel)) {
      renderDeferredBrowserShell(panel, body);
    } else {
      ensureBrowser(panel, body);
    }
  }
  return pane;
}

function renderPendingPane(panel, body) {
  let pending = body.querySelector(".pending-pane");
  if (!pending) {
    pending = document.createElement("div");
    pending.className = "pending-pane";
    pending.innerHTML = `
      <span class="pending-pane-pulse"></span>
      <span class="pending-pane-copy">
        <span class="pending-pane-text"></span>
        <span class="pending-pane-meta"></span>
      </span>
      <button class="pending-pane-cancel" type="button">Cancel</button>
    `;
  }
  const cancel = pending.querySelector(".pending-pane-cancel");
  cancel.onclick = (event) => {
    event.preventDefault();
    event.stopPropagation();
    cancelPendingPanel(panel.id);
  };
  const isBrowser = panel.type === "browser";
  const elapsedSeconds = pendingPanelElapsedSeconds(panel);
  const slow = elapsedSeconds >= 8;
  toggleClassIfChanged(pending, "is-slow", slow);
  const baseMeta = isBrowser
    ? hostnameOf(panel.url || state.settings.browserHomeUrl)
    : `${optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell")} / ${panel.cwdShort || "~"}`;
  const meta = `${baseMeta} / ${elapsedSeconds}s`;
  setTextIfChanged(
    pending.querySelector(".pending-pane-text"),
    slow
      ? (isBrowser ? "Browser is still opening..." : "Terminal is still starting...")
      : (isBrowser ? "Opening browser..." : "Starting terminal...")
  );
  setTextIfChanged(pending.querySelector(".pending-pane-meta"), meta);
  replaceChildrenIfChanged(body, [pending]);
  ensurePendingPaneTimer();
}

function pendingPanelElapsedSeconds(panel) {
  const startedAt = Number(panel?.pendingStartedAt || Date.now());
  return Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
}

function ensurePendingPaneTimer() {
  if (state.pendingPaneTimer || state.pendingPanels.size === 0) return;
  state.pendingPaneTimer = window.setInterval(updatePendingPaneTimers, 1000);
}

function stopPendingPaneTimerIfIdle() {
  if (!state.pendingPaneTimer || state.pendingPanels.size > 0) return;
  window.clearInterval(state.pendingPaneTimer);
  state.pendingPaneTimer = 0;
}

function updatePendingPaneTimers() {
  if (state.pendingPanels.size === 0) {
    stopPendingPaneTimerIfIdle();
    return;
  }
  for (const panel of state.pendingPanels.values()) {
    const pane = state.paneCache.get(panel.id)
      || [...elements.paneGrid.querySelectorAll(".pane[data-panel-id]")].find((candidate) => candidate.dataset.panelId === panel.id);
    const body = pane ? paneParts(pane).body : null;
    if (body?.isConnected) renderPendingPane(panel, body);
  }
}

function getPaneSplitNode(splitNode) {
  let split = elements.paneGrid.querySelector(`[data-pane-split-id="${splitNode.id}"]`);
  if (!split) {
    split = document.createElement("div");
    split.dataset.paneSplitId = splitNode.id;
  }
  setClassNameIfChanged(split, `pane-split direction-${paneTreeDirection(splitNode.direction)}`);
  return split;
}

function terminalPanelTitle(panel) {
  const name = panel.title || "Terminal";
  const cwd = panel.cwdShort || "~";
  return name === cwd ? name : `${name} · ${cwd}`;
}

function surfaceTabLabel(workspace, panel) {
  const label = panelDisplayTitle(panel, true);
  const duplicates = (workspace?.panels || [])
    .filter((candidate) => panelDisplayTitle(candidate, true) === label);
  if (duplicates.length <= 1) return label;
  const duplicateIndex = duplicates.findIndex((candidate) => candidate.id === panel.id);
  return duplicateIndex >= 0 ? `${label} ${duplicateIndex + 1}` : label;
}

function terminalPanelFolder(panel) {
  return panel.cwdShort || "~";
}

function panelDisplayTitle(panel, surface = false) {
  if (isPendingPanel(panel)) return panel.title || (panel.type === "browser" ? "Opening browser" : "Starting terminal");
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

function createEmptyWorkspaceLogo() {
  const logo = document.createElement("div");
  logo.className = "empty-workspace-logo";
  logo.setAttribute("role", "img");
  logo.setAttribute("aria-label", "cmux Windows");
  logo.innerHTML = `
    <svg viewBox="0 0 180 180" aria-hidden="true" focusable="false">
      <rect class="empty-logo-shell" width="180" height="180" rx="28"></rect>
      <rect class="empty-logo-window" x="34" y="38" width="112" height="88" rx="10"></rect>
      <rect class="empty-logo-accent" x="46" y="54" width="54" height="8" rx="4"></rect>
      <rect class="empty-logo-line strong" x="46" y="74" width="86" height="8" rx="4"></rect>
      <rect class="empty-logo-line" x="46" y="94" width="66" height="8" rx="4"></rect>
      <path class="empty-logo-stand" d="M64 142h52"></path>
      <path class="empty-logo-stand" d="M90 126v18"></path>
      <circle class="empty-logo-dot" cx="129" cy="54" r="5"></circle>
      <path class="empty-logo-check" d="M57 119 72 134l34-42"></path>
    </svg>
  `;
  return logo;
}

function ensureEmptyWorkspaceLogo(node) {
  const inner = node?.querySelector(".empty-workspace-inner");
  if (!inner || inner.querySelector(".empty-workspace-logo")) return;
  inner.prepend(createEmptyWorkspaceLogo());
}

function createEmptyWorkspace(workspace) {
  const node = document.createElement("div");
  node.className = "empty-workspace";
  node.innerHTML = `
    <div class="empty-workspace-inner">
      <div class="empty-workspace-title"></div>
      <div class="empty-workspace-body">Start with a shell, browser, or ready layout.</div>
      <div class="empty-workspace-launchers"></div>
    </div>
  `;
  ensureEmptyWorkspaceLogo(node);
  node.querySelector(".empty-workspace-title").textContent = "cmux";
  updateEmptyWorkspaceActions(node, workspace);
  return node;
}

function renderEmptyWorkspace(workspace) {
  let node = [...elements.paneGrid.children].find((child) => child.classList.contains("empty-workspace"));
  if (!node) {
    node = createEmptyWorkspace(workspace);
  } else {
    ensureEmptyWorkspaceLogo(node);
    node.querySelector(".empty-workspace-title").textContent = "cmux";
    updateEmptyWorkspaceActions(node, workspace);
  }
  replaceChildrenIfChanged(elements.paneGrid, [node]);
}

function updateVisibleEmptyWorkspaceControls() {
  const node = elements.paneGrid?.querySelector(".empty-workspace");
  if (!node) return;
  updateEmptyWorkspaceActions(node, activeWorkspace());
}

function updateEmptyWorkspaceActions(node, workspace) {
  const canReopen = state.closedPanels.length > 0;
  setTextIfChanged(
    node.querySelector(".empty-workspace-body"),
    canReopen ? "Reopen the last pane or start fresh." : "Start with a shell or browser. Layouts stay in Settings."
  );
  renderEmptyWorkspaceLaunchers(node, workspace);
}

async function workspaceForEmptyAction(workspace) {
  if (workspace?.id) return workspace;
  return await createWorkspace();
}

async function createEmptyWorkspacePanel(type, workspace) {
  const targetWorkspace = await workspaceForEmptyAction(workspace);
  if (!targetWorkspace?.id) return null;
  return createPanel(type, "right", {
    workspaceId: targetWorkspace.id,
    url: type === "browser" ? state.settings.browserHomeUrl : undefined
  });
}

function emptyWorkspaceLaunchers() {
  const launchers = [
    {
      id: "terminal",
      icon: ">_",
      label: "Terminal",
      meta: "shell",
      kind: "panel",
      type: "terminal",
      primary: state.closedPanels.length === 0
    },
    {
      id: "browser",
      icon: "○",
      label: "Browser",
      meta: "home",
      kind: "panel",
      type: "browser"
    }
  ];
  if (workspaceStarters.length > 0 || state.workspaceBlueprints.length > 0) {
    launchers.push({
      id: "layouts",
      icon: "▦",
      label: "Layouts",
      meta: "settings",
      kind: "layouts"
    });
  }
  if (state.closedPanels.length > 0) {
    launchers.unshift({
      id: "reopen",
      icon: "↺",
      label: "Reopen",
      meta: "last pane",
      kind: "reopen",
      primary: true
    });
  }
  return launchers;
}

async function runEmptyWorkspaceLauncher(launcher, workspace) {
  if (!launcher || paneCreationButtonsDisabled()) return;
  if (launcher.kind === "reopen") {
    await reopenClosedPanel();
    return;
  }
  if (launcher.kind === "panel") {
    await createEmptyWorkspacePanel(launcher.type, workspace);
    return;
  }
  if (launcher.kind === "layouts") {
    openSettingsCategory("blueprints");
    return;
  }
}

function renderEmptyWorkspaceLaunchers(node, workspace) {
  const host = node.querySelector(".empty-workspace-launchers");
  if (!host) return;
  const busy = paneCreationButtonsDisabled();
  const cards = emptyWorkspaceLaunchers().map((launcher) => {
    const button = document.createElement("button");
    button.className = `empty-workspace-launcher${launcher.primary ? " is-primary" : ""}`;
    button.type = "button";
    button.dataset.emptyLauncher = launcher.id;
    button.disabled = busy;
    const launcherLabel = `${launcher.label}: ${launcher.meta}`;
    const busyLabel = currentUiOperationLabel() || "Pane is being added";
    button.title = busy ? busyLabel : launcherLabel;
    button.setAttribute("aria-label", busy ? `${launcherLabel}. ${busyLabel}.` : launcherLabel);
    button.innerHTML = `
      <span class="empty-workspace-launcher-icon"></span>
      <span class="empty-workspace-launcher-text">
        <span class="empty-workspace-launcher-label"></span>
        <span class="empty-workspace-launcher-meta"></span>
      </span>
    `;
    button.querySelector(".empty-workspace-launcher-icon").textContent = launcher.icon;
    button.querySelector(".empty-workspace-launcher-label").textContent = launcher.label;
    button.querySelector(".empty-workspace-launcher-meta").textContent = launcher.meta;
    button.onclick = () => runEmptyWorkspaceLauncher(launcher, workspace);
    return button;
  });
  replaceChildrenIfChanged(host, cards);
}

function getPaneSplitter(workspace, splitNode) {
  const key = splitNode.id;
  let splitter = elements.paneGrid.querySelector(`[data-splitter-key="${key}"]`);
  if (!splitter) {
    splitter = document.createElement("div");
    splitter.className = "pane-splitter";
    splitter.dataset.splitterKey = key;
    splitter.dataset.splitId = splitNode.id;
    splitter.tabIndex = 0;
    splitter.setAttribute("role", "separator");
    splitter.addEventListener("pointerdown", (event) => startPaneResize(event, splitter));
    splitter.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
      equalizePaneSplitter(splitter);
    });
    splitter.addEventListener("contextmenu", (event) => showPaneSplitterContextMenu(event, splitter));
    splitter.addEventListener("keydown", handlePaneSplitterKeydown);
  }
  setDatasetIfChanged(splitter, "splitId", splitNode.id);
  const direction = paneTreeDirection(splitNode.direction);
  setDatasetIfChanged(splitter, "orientation", direction);
  setSplitterResizePercent(splitter, Math.round(paneTreeRatio(splitNode.ratio) * 100), direction);
  setTitleIfChanged(splitter, "Drag to resize. Right-click for sizes. Double-click to equalize. Arrow keys adjust 1%; Shift+Arrow adjusts 10%.");
  return splitter;
}

function setSplitterResizePercent(splitter, percent, direction = splitter?.dataset.orientation || "right") {
  if (!splitter) return 50;
  const nextPercent = clampPaneLayoutPercent(percent);
  const label = direction === "down"
    ? `Top ${nextPercent}% / bottom ${100 - nextPercent}%`
    : `Left ${nextPercent}% / right ${100 - nextPercent}%`;
  setDatasetIfChanged(splitter, "resizePercent", String(nextPercent));
  setDatasetIfChanged(splitter, "resizeLabel", label);
  splitter.setAttribute("aria-label", "Resize pane split");
  splitter.setAttribute("aria-valuemin", String(paneLayoutPercentMin));
  splitter.setAttribute("aria-valuemax", String(paneLayoutPercentMax));
  splitter.setAttribute("aria-valuenow", String(nextPercent));
  splitter.setAttribute("aria-valuetext", label);
  splitter.setAttribute("aria-orientation", direction === "down" ? "horizontal" : "vertical");
  return nextPercent;
}

function setPaneSplitterPercent(splitter, percent, options = {}) {
  const workspace = activeWorkspace();
  const splitId = splitter?.dataset.splitId || "";
  if (!workspace || !splitId) return false;
  const tree = paneTreeForWorkspace(workspace);
  if (!tree) return false;
  const nextPercent = clampPaneLayoutPercent(percent);
  let changed = false;
  const nextTree = updatePaneTreeSplit(tree, splitId, (split) => {
    const currentPercent = Math.round(paneTreeRatio(split.ratio) * 100);
    if (currentPercent === nextPercent) return split;
    changed = true;
    return {
      ...split,
      ratio: paneTreeRatio(nextPercent / 100)
    };
  });
  const direction = splitter?.dataset.orientation || "right";
  setSplitterResizePercent(splitter, nextPercent, direction);
  if (!changed) return false;
  state.paneTrees.set(workspace.id, nextTree);
  savePaneTreeLayouts(state.paneTrees);
  scheduleRender();
  scheduleWorkspaceTerminalFits(workspace.id, true);
  if (options.toast) {
    refreshLayoutSettings();
    toast(`${splitter.dataset.resizeLabel || `${nextPercent}% / ${100 - nextPercent}%`}.`);
  }
  return true;
}

function equalizePaneSplitter(splitter) {
  return setPaneSplitterPercent(splitter, 50, { toast: true });
}

async function promptPaneSplitterPercent(splitter) {
  const currentPercent = clampPaneLayoutPercent(Number(splitter?.dataset.resizePercent || 50));
  const value = await showTextDialog({
    title: "Set split size",
    message: `Enter the first pane percentage from ${paneLayoutPercentMin} to ${paneLayoutPercentMax}.`,
    value: String(currentPercent),
    placeholder: "65",
    confirmLabel: "Apply"
  });
  if (value === null) return false;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    toast(`Enter a number from ${paneLayoutPercentMin} to ${paneLayoutPercentMax}.`);
    return false;
  }
  return setPaneSplitterPercent(splitter, parsed, { toast: true });
}

function handlePaneSplitterKeydown(event) {
  const splitter = event.currentTarget;
  const direction = splitter?.dataset.orientation === "down" ? "down" : "right";
  const key = event.key;
  const growsFirst = direction === "down" ? key === "ArrowDown" : key === "ArrowRight";
  const shrinksFirst = direction === "down" ? key === "ArrowUp" : key === "ArrowLeft";
  if (key === "Enter" || key === " ") {
    event.preventDefault();
    event.stopPropagation();
    equalizePaneSplitter(splitter);
    return;
  }
  if (!growsFirst && !shrinksFirst) return;
  event.preventDefault();
  event.stopPropagation();
  const step = event.shiftKey ? 10 : 1;
  const currentPercent = clampPaneLayoutPercent(Number(splitter.dataset.resizePercent || 50));
  setPaneSplitterPercent(splitter, currentPercent + (growsFirst ? step : -step));
}

function scheduleWorkspaceTerminalFits(workspaceId, force = true) {
  if (!workspaceId || state.workspaceTerminalFitFrames.has(workspaceId)) return;
  const frame = requestAnimationFrame(() => {
    state.workspaceTerminalFitFrames.delete(workspaceId);
    fitWorkspaceTerminals(workspaceId, force);
  });
  state.workspaceTerminalFitFrames.set(workspaceId, frame);
}

function fitWorkspaceTerminals(workspaceId, force = true) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  for (const panel of workspace?.panels || []) {
    const terminal = state.terminals.get(panel.id);
    if (terminal) scheduleFitTerminal(terminal, force);
  }
}

function startPaneResize(event, splitter) {
  if (event.button !== 0 || state.resizing) return;
  event.preventDefault();
  const workspace = activeWorkspace();
  if (!workspace) return;
  const previousPane = splitter.previousElementSibling;
  const nextPane = splitter.nextElementSibling;
  if (!previousPane || !nextPane) return;
  const splitId = splitter.dataset.splitId || "";
  const vertical = splitter.parentElement?.classList.contains("direction-down")
    || (!splitId && workspace.splitDirection === "down");
  const previousRect = previousPane.getBoundingClientRect();
  const nextRect = nextPane.getBoundingClientRect();
  const start = vertical ? event.clientY : event.clientX;
  const previousSize = vertical ? previousRect.height : previousRect.width;
  const nextSize = vertical ? nextRect.height : nextRect.width;
  previousPane.style.flex = `0 0 ${Math.max(1, previousSize)}px`;
  nextPane.style.flex = `0 0 ${Math.max(1, nextSize)}px`;
  splitter.classList.add("is-dragging");
  elements.shell.classList.add("pane-resizing", vertical ? "pane-resizing-y" : "pane-resizing-x");
  safeSetPointerCapture(splitter, event.pointerId);
  state.resizing = {
    splitter,
    splitId,
    pointerId: event.pointerId,
    previousPane,
    nextPane,
    vertical,
    direction: vertical ? "down" : "right",
    workspaceId: workspace.id,
    start,
    current: start,
    previousSize,
    nextSize,
    frame: 0,
    lastFitAt: 0,
    panelIds: [
      ...new Set([
        ...paneElementPanelIds(previousPane),
        ...paneElementPanelIds(nextPane)
      ])
    ]
  };
  setSplitterResizePercent(splitter, Math.round((previousSize / Math.max(1, previousSize + nextSize)) * 100), vertical ? "down" : "right");
}

function continuePaneResize(event) {
  const resize = state.resizing;
  if (!resize || event.pointerId !== resize.pointerId) return;
  event.preventDefault();
  resize.current = resize.vertical ? event.clientY : event.clientX;
  schedulePaneResizeFrame(resize);
}

function schedulePaneResizeFrame(resize = state.resizing) {
  if (!resize || resize.frame) return;
  resize.frame = requestAnimationFrame(() => {
    resize.frame = 0;
    applyPaneResize(resize);
  });
}

function applyPaneResize(resize = state.resizing) {
  if (!resize) return;
  const { previousPane, nextPane, vertical, start, previousSize, nextSize, current, panelIds } = resize;
  const delta = current - start;
  const pairTotal = Math.max(2, previousSize + nextSize);
  const baseMinSize = vertical ? paneResizeMinHeight : paneResizeMinWidth;
  const minSize = Math.min(baseMinSize, Math.max(1, Math.floor(pairTotal / 2) - 1));
  const nextPrevious = Math.min(pairTotal - minSize, Math.max(minSize, previousSize + delta));
  const nextNext = pairTotal - nextPrevious;
  previousPane.style.flex = `0 0 ${nextPrevious}px`;
  nextPane.style.flex = `0 0 ${nextNext}px`;
  setSplitterResizePercent(resize.splitter, Math.round((nextPrevious / pairTotal) * 100), vertical ? "down" : "right");
  const now = performance.now();
  if (now - resize.lastFitAt < paneResizeFitThrottleMs) return;
  resize.lastFitAt = now;
  for (const panelId of panelIds) {
    const terminal = state.terminals.get(panelId);
    if (terminal) scheduleFitTerminal(terminal);
  }
}

function paneElementPanelIds(element) {
  if (!element) return [];
  if (element.dataset?.panelId) return [element.dataset.panelId];
  return [...element.querySelectorAll(".pane[data-panel-id]")].map((pane) => pane.dataset.panelId);
}

function finishPaneResize(event) {
  const resize = state.resizing;
  if (!resize || event.pointerId !== resize.pointerId) return;
  const { splitter, splitId, previousPane, nextPane, vertical, workspaceId, direction } = resize;
  if (resize.frame) {
    cancelAnimationFrame(resize.frame);
    resize.frame = 0;
  }
  applyPaneResize(resize);
  safeReleasePointerCapture(splitter, event.pointerId);
  splitter.classList.remove("is-dragging");
  elements.shell.classList.remove("pane-resizing", "pane-resizing-x", "pane-resizing-y");
  if (splitId) {
    const previousRect = previousPane.getBoundingClientRect();
    const nextRect = nextPane.getBoundingClientRect();
    const previousSize = Math.max(1, vertical ? previousRect.height : previousRect.width);
    const nextSize = Math.max(1, vertical ? nextRect.height : nextRect.width);
    const ratio = paneTreeRatio(previousSize / Math.max(1, previousSize + nextSize));
    const tree = state.paneTrees.get(workspaceId);
    if (tree) {
      state.paneTrees.set(workspaceId, updatePaneTreeSplit(tree, splitId, (split) => ({
        ...split,
        ratio
      })));
      savePaneTreeLayouts(state.paneTrees);
    }
  } else {
    persistPaneLayoutFromGrid(direction);
    renderPaneLayoutStylesForVisiblePanes(direction);
    clearVisiblePaneInlineFlex();
  }
  state.resizing = null;
  flushPendingRender();
  refreshLayoutSettings();
  requestAnimationFrame(() => {
    if (splitId) {
      previousPane.style.flex = "";
      nextPane.style.flex = "";
      render();
    } else {
      renderPaneLayoutStylesForVisiblePanes(direction);
      clearVisiblePaneInlineFlex();
    }
    fitWorkspaceTerminals(workspaceId);
  });
}

function startSidebarResize(event) {
  if (state.sidebarCollapsed || event.button !== 0) return;
  const rect = elements.sidebar.getBoundingClientRect();
  if (rect.right - event.clientX > 8) return;
  event.preventDefault();
  safeSetPointerCapture(elements.sidebar, event.pointerId);
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
    safeReleasePointerCapture(elements.sidebar, event.pointerId);
  }
  state.sidebarResizing = null;
  elements.shell.classList.remove("sidebar-resizing");
  saveSettings();
  applySettings();
  refreshLayoutSettings();
}

function startInspectorResize(event) {
  if (!state.inspectorMode || event.button !== 0) return;
  const rect = elements.inspector.getBoundingClientRect();
  if (event.clientX - rect.left > 8) return;
  event.preventDefault();
  safeSetPointerCapture(elements.inspector, event.pointerId);
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
    safeReleasePointerCapture(elements.inspector, event.pointerId);
  }
  state.inspectorResizing = null;
  elements.shell.classList.remove("inspector-resizing");
  saveSettings();
  applySettings();
  refreshLayoutSettings();
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
        <button class="pane-tool split-right" type="button" title="Split right" aria-label="Split right">◫</button>
        <button class="pane-tool split-down" type="button" title="Split down" aria-label="Split down">⇣</button>
        <button class="pane-tool minimize" type="button" title="Minimize pane" aria-label="Minimize pane">-</button>
        <button class="pane-tool zoom" type="button" title="Focus pane" aria-label="Focus pane">□</button>
        <button class="pane-tool font-down" type="button" title="Smaller terminal text" aria-label="Smaller terminal text">A-</button>
        <button class="pane-tool font-up" type="button" title="Larger terminal text" aria-label="Larger terminal text">A+</button>
        <button class="pane-tool restart" type="button" title="Restart terminal" aria-label="Restart terminal">↻</button>
        <button class="pane-tool close" type="button" title="Close" aria-label="Close pane">×</button>
      </div>
    </div>
    <div class="pane-body"></div>
  `;
  const parts = paneParts(pane);
  pane.addEventListener("pointerenter", () => {
    state.hoveredPanelId = pane.dataset.panelId;
  });
  pane.addEventListener("pointermove", () => {
    state.hoveredPanelId = pane.dataset.panelId;
  });
  pane.addEventListener("pointerleave", () => {
    if (state.hoveredPanelId === pane.dataset.panelId) state.hoveredPanelId = null;
  });
  pane.addEventListener("wheel", handlePaneWheelZoom, { passive: false, capture: true });
  pane.addEventListener("focusin", () => markInteractedPanel(pane.dataset.panelId));
  pane.addEventListener("pointerdown", () => markInteractedPanel(pane.dataset.panelId), { capture: true });
  const header = parts.header;
  header.draggable = false;
  header.addEventListener("click", () => {
    if (state.suppressPaneHeaderClick) {
      state.suppressPaneHeaderClick = false;
      return;
    }
    focusPanel(pane.dataset.panelId);
  });
  header.addEventListener("dblclick", (event) => {
    if (event.target.closest(".pane-toolbar, .pane-tool")) return;
    event.preventDefault();
    event.stopPropagation();
    const found = findPanelState(pane.dataset.panelId);
    if (found && !isPendingPanel(found.panel)) renamePanel(found.panel);
  });
  header.addEventListener("contextmenu", (event) => {
    const found = findPanelState(pane.dataset.panelId);
    if (found) showPanelContextMenu(event, found.panel);
  });
  header.addEventListener("pointerdown", (event) => startPanePointerDrag(event, pane));
  parts.splitRight.onclick = (event) => {
    event.stopPropagation();
    splitPanelFromPaneId(pane.dataset.panelId, "right");
  };
  parts.splitDown.onclick = (event) => {
    event.stopPropagation();
    splitPanelFromPaneId(pane.dataset.panelId, "down");
  };
  parts.zoom.onclick = (event) => {
    event.stopPropagation();
    togglePaneZoom(pane.dataset.panelId);
  };
  parts.minimize.onclick = (event) => {
    event.stopPropagation();
    togglePaneMinimized(pane.dataset.panelId);
  };
  parts.fontDown.onclick = (event) => {
    event.stopPropagation();
    changePaneTerminalFontSize(pane.dataset.panelId, -1);
  };
  parts.fontUp.onclick = (event) => {
    event.stopPropagation();
    changePaneTerminalFontSize(pane.dataset.panelId, 1);
  };
  parts.restart.onclick = (event) => {
    event.stopPropagation();
    restartPanel(pane.dataset.panelId);
  };
  parts.close.onclick = (event) => {
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

function paneParts(pane) {
  pane._paneParts ||= {
    header: pane.querySelector(".pane-header"),
    type: pane.querySelector(".pane-type"),
    title: pane.querySelector(".pane-title"),
    body: pane.querySelector(".pane-body"),
    splitRight: pane.querySelector(".split-right"),
    splitDown: pane.querySelector(".split-down"),
    minimize: pane.querySelector(".minimize"),
    zoom: pane.querySelector(".zoom"),
    fontDown: pane.querySelector(".font-down"),
    fontUp: pane.querySelector(".font-up"),
    restart: pane.querySelector(".restart"),
    close: pane.querySelector(".close"),
    tools: [...pane.querySelectorAll(".pane-tool")]
  };
  return pane._paneParts;
}

function paneDropPosition(event, pane) {
  const rect = pane.getBoundingClientRect();
  const x = rect.width ? (event.clientX - rect.left) / rect.width : 0.5;
  const y = rect.height ? (event.clientY - rect.top) / rect.height : 0.5;
  const horizontalEdge = Math.min(0.5, Math.max(80 / Math.max(1, rect.width), 0.25));
  const verticalEdge = Math.min(0.5, Math.max(80 / Math.max(1, rect.height), 0.25));
  if (x < horizontalEdge) return "left";
  if (x > 1 - horizontalEdge) return "right";
  if (y < verticalEdge) return "top";
  if (y > 1 - verticalEdge) return "bottom";
  return "center";
}

function startPanePointerDrag(event, pane) {
  if (event.button !== 0 || event.target.closest(".pane-tool")) return;
  state.panePointerDrag = {
    panelId: pane.dataset.panelId,
    pointerId: event.pointerId,
    captureElement: event.currentTarget,
    sourcePane: pane,
    targetPane: null,
    startX: event.clientX,
    startY: event.clientY,
    active: false
  };
  safeSetPointerCapture(event.currentTarget, event.pointerId);
}

function continuePanePointerDrag(event) {
  const drag = state.panePointerDrag;
  if (!drag || drag.pointerId !== event.pointerId) return;
  const moved = Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY);
  if (!drag.active && moved < panePointerDragThreshold) return;
  if (!drag.active) {
    drag.active = true;
    state.dragPanelId = drag.panelId;
    drag.sourcePane.classList.add("is-dragging");
    document.body.classList.add("pane-drag-active");
  }
  event.preventDefault();
  const target = panePointerDropTarget(event, drag.panelId);
  if (drag.targetPane && drag.targetPane !== target) clearPaneDropTarget(drag.targetPane);
  drag.targetPane = target;
  if (!target) return;
  target.dataset.dropPosition = paneDropPosition(event, target);
  target.classList.add("is-drop-target");
}

function finishPanePointerDrag(event) {
  const drag = state.panePointerDrag;
  if (!drag || drag.pointerId !== event.pointerId) return;
  if (drag.captureElement) safeReleasePointerCapture(drag.captureElement, event.pointerId);
  if (drag.active) {
    event.preventDefault();
    const target = drag.targetPane;
    const targetPanelId = target?.dataset.panelId || "";
    const placement = target?.dataset.dropPosition || (target ? paneDropPosition(event, target) : "");
    state.suppressPaneHeaderClick = true;
    if (targetPanelId && targetPanelId !== drag.panelId && placement) {
      movePanelRelative(drag.panelId, targetPanelId, placement);
    }
    setTimeout(() => {
      state.suppressPaneHeaderClick = false;
    }, 0);
  }
  drag.sourcePane.classList.remove("is-dragging");
  if (drag.targetPane) clearPaneDropTarget(drag.targetPane);
  document.body.classList.remove("pane-drag-active");
  state.dragPanelId = null;
  state.panePointerDrag = null;
}

function cancelPanePointerDrag(event) {
  const drag = state.panePointerDrag;
  if (!drag || drag.pointerId !== event.pointerId) return;
  if (drag.captureElement) safeReleasePointerCapture(drag.captureElement, event.pointerId);
  drag.sourcePane.classList.remove("is-dragging");
  if (drag.targetPane) clearPaneDropTarget(drag.targetPane);
  document.body.classList.remove("pane-drag-active");
  state.dragPanelId = null;
  state.panePointerDrag = null;
}

function panePointerDropTarget(event, sourcePanelId) {
  const element = document.elementFromPoint(event.clientX, event.clientY);
  const pane = element?.closest?.(".pane[data-panel-id]");
  if (!pane || pane.dataset.panelId === sourcePanelId) return null;
  return pane;
}

function clearPaneDropTarget(pane) {
  pane.classList.remove("is-drop-target");
  pane.removeAttribute("data-drop-position");
}

function clearAllDropTargets() {
  for (const pane of document.querySelectorAll(".pane.is-drop-target")) clearPaneDropTarget(pane);
  for (const node of document.querySelectorAll(".is-drop-before, .is-drop-after, .workspace-row.is-drop-target, .workspace-row.is-workspace-drop-before, .workspace-row.is-workspace-drop-after")) {
    node.classList.remove("is-drop-before", "is-drop-after", "is-drop-target", "is-workspace-drop-before", "is-workspace-drop-after");
  }
  clearWorkspaceListDropTarget();
  for (const pane of document.querySelectorAll(".pane.is-dragging")) pane.classList.remove("is-dragging");
  document.body.classList.remove("pane-drag-active");
  state.panePointerDrag = null;
  state.dragPanelId = null;
  state.dragWorkspaceId = null;
}

function cleanupPanel(panelId) {
  if (state.zoomedPanelId === panelId) state.zoomedPanelId = null;
  if (state.focusedPanelId === panelId) state.focusedPanelId = null;
  if (state.lastInteractedPanelId === panelId) state.lastInteractedPanelId = null;
  if (state.hoveredPanelId === panelId) state.hoveredPanelId = null;
  state.visibleTerminalFitPanelIds.delete(panelId);
  state.paintDeferredTerminalInitPanelIds.delete(panelId);
  if (state.terminalFocusPanelId === panelId) {
    state.terminalFocusPanelId = "";
    if (state.terminalFocusFrame) cancelAnimationFrame(state.terminalFocusFrame);
    state.terminalFocusFrame = 0;
  }
  for (const [workspaceId, previousPanelId] of [...state.previousPanelIds.entries()]) {
    if (previousPanelId === panelId) state.previousPanelIds.delete(workspaceId);
  }
  state.minimizedPanelIds.delete(panelId);
  state.pendingPanels.delete(panelId);
  if (state.browserTabSnapshots.delete(panelId)) saveBrowserTabSnapshots(state.browserTabSnapshots);
  for (const [workspaceId, zoomedPanelId] of [...state.zoomedPanelIds.entries()]) {
    if (zoomedPanelId === panelId) state.zoomedPanelIds.delete(workspaceId);
  }
  state.terminalWheelZoomState.delete(panelId);
  state.deferredTerminalInitQueue.delete(panelId);
  const terminal = state.terminals.get(panelId);
  if (terminal) {
    terminal.disposed = true;
    if (terminal.fitFrame) cancelAnimationFrame(terminal.fitFrame);
    if (terminal.connectionStatusTimer) clearTimeout(terminal.connectionStatusTimer);
    closeSocketQuietly(terminal.socket);
    terminal.resizeObserver?.disconnect();
    terminal.searchResultDisposable?.dispose?.();
    terminal.focusDisposable?.dispose?.();
    terminal.term?.dispose();
    state.terminals.delete(panelId);
  }
  const browserSession = state.browserViews.get(panelId);
  if (browserSession?.initialLoadFrame) cancelAnimationFrame(browserSession.initialLoadFrame);
  if (browserSession?.tabRenderFrame) cancelAnimationFrame(browserSession.tabRenderFrame);
  if (browserSession?.tabScrollFrame) cancelAnimationFrame(browserSession.tabScrollFrame);
  if (browserSession?.tabOverflowFrame) cancelAnimationFrame(browserSession.tabOverflowFrame);
  browserSession?.tabResizeObserver?.disconnect?.();
  browserSession?.detachTabWheelScroll?.();
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

function setTerminalConnectionStatus(session, status, label, clearAfter = 0) {
  if (!session?.host) return;
  if (session.connectionStatusTimer) {
    clearTimeout(session.connectionStatusTimer);
    session.connectionStatusTimer = 0;
  }
  session.host.classList.toggle("is-connecting", status === "connecting");
  session.host.classList.toggle("is-terminal-ready", status === "ready");
  session.host.classList.toggle("is-terminal-disconnected", status === "disconnected" || status === "error");
  session.host.dataset.connectionStatus = label || "";
  if (clearAfter > 0) {
    session.connectionStatusTimer = setTimeout(() => clearTerminalConnectionStatus(session), clearAfter);
  }
}

function clearTerminalConnectionStatus(session) {
  if (!session?.host) return;
  if (session.connectionStatusTimer) {
    clearTimeout(session.connectionStatusTimer);
    session.connectionStatusTimer = 0;
  }
  session.host.classList.remove("is-connecting", "is-terminal-ready", "is-terminal-disconnected");
  delete session.host.dataset.connectionStatus;
}

function markTerminalOutputReady(session) {
  if (!session || session.hasOutput) return;
  session.hasOutput = true;
}

function shouldDeferInitialTerminalLoad(panel, workspace, visibleCount = 1) {
  return shouldDeferTerminalInitUntilPaint(panel, workspace)
    || shouldKeepTerminalInitDeferred(panel)
    || (visibleCount > 1
    && panel?.type === "terminal"
    && !state.terminals.has(panel.id)
    && panel.id !== workspace?.activePanelId
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel));
}

function shouldDeferTerminalInitUntilPaint(panel, workspace) {
  return panel?.type === "terminal"
    && panel.id === workspace?.activePanelId
    && state.paintDeferredTerminalInitPanelIds.has(panel.id)
    && !state.terminals.has(panel.id)
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel);
}

function shouldKeepTerminalInitDeferred(panel) {
  return panel?.type === "terminal"
    && state.deferredTerminalInitQueue.has(panel.id)
    && !state.terminals.has(panel.id)
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel);
}

function renderDeferredTerminal(panel, body) {
  let deferred = body.querySelector(".terminal-deferred");
  if (!deferred) {
    deferred = document.createElement("div");
    deferred.className = "terminal-deferred";
    deferred.innerHTML = `
      <span class="terminal-deferred-title">Preparing terminal</span>
      <span class="terminal-deferred-meta"></span>
    `;
    body.replaceChildren(deferred);
  }
  setTextIfChanged(deferred.querySelector(".terminal-deferred-meta"), panel.cwdShort || panel.cwd || "~");
}

function queueDeferredTerminalInit(panelId, options = {}) {
  if (!panelId || state.terminals.has(panelId)) return;
  state.deferredTerminalInitQueue.add(panelId);
  if (options.afterPaint) scheduleDeferredTerminalInitAfterPaint();
  else scheduleDeferredTerminalInit();
}

function scheduleDeferredTerminalInitAfterPaint() {
  if (state.deferredTerminalInitFrame) return;
  state.deferredTerminalInitFrame = requestAnimationFrame(() => {
    state.deferredTerminalInitFrame = 0;
    flushDeferredTerminalInit();
  });
}

function scheduleDeferredTerminalInit() {
  if (state.deferredTerminalInitTimer) return;
  const run = () => {
    state.deferredTerminalInitTimer = 0;
    flushDeferredTerminalInit();
  };
  state.deferredTerminalInitTimer = typeof requestIdleCallback === "function"
    ? requestIdleCallback(run, { timeout: deferredTerminalInitIdleTimeoutMs })
    : setTimeout(run, Math.min(160, deferredTerminalInitIdleTimeoutMs));
}

function flushDeferredTerminalInit() {
  const activeWorkspaceId = state.data?.activeWorkspaceId || "";
  const visiblePanelIds = visiblePanePanelIds();
  for (const panelId of [...state.deferredTerminalInitQueue]) {
    state.deferredTerminalInitQueue.delete(panelId);
    if (state.terminals.has(panelId)) continue;
    const found = findPanelState(panelId);
    if (!found || found.workspace.id !== activeWorkspaceId || !visiblePanelIds.has(panelId)) continue;
    const pane = state.paneCache.get(panelId);
    const body = pane ? paneParts(pane).body : null;
    if (!body?.querySelector(".terminal-deferred")) continue;
    ensureTerminal(found.panel, body);
    const terminal = state.terminals.get(panelId);
    if (terminal) scheduleFitTerminal(terminal, true);
    break;
  }
  if (state.deferredTerminalInitQueue.size > 0) scheduleDeferredTerminalInit();
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
  host.className = "terminal-host is-connecting";
  host.dataset.connectionStatus = "Connecting shell";
  host.addEventListener("wheel", handleTerminalWheelZoom, { passive: false, capture: true });
  body.appendChild(host);

  const fontSize = terminalFontSizeForPanel(panel);
  const term = new TerminalConstructor({
    cursorBlink: state.settings.terminalCursorBlink,
    cursorStyle: state.settings.terminalCursorStyle,
    allowProposedApi: true,
    convertEol: true,
    fontFamily: terminalFontStack(),
    fontSize,
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

  const terminalUrl = new URL(`/terminal/${panel.id}`, location.origin.replace(/^http/, "ws"));
  if (launchToken) terminalUrl.searchParams.set("token", launchToken);
  const socket = new WebSocket(terminalUrl.href);
  const session = {
    panelId: panel.id,
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
    fitDeferred: false,
    fontSize,
    searchOverlay: null,
    searchTerm: "",
    searchCaseSensitive: false,
    searchResultDisposable: null,
    focusDisposable: null,
    connectionStatusTimer: 0,
    createdAt: performance.now(),
    hasOutput: false
  };
  session.searchOverlay = createTerminalSearchOverlay(panel, session);
  if (session.searchOverlay) host.append(session.searchOverlay);
  session.searchResultDisposable = searchAddon?.onDidChangeResults?.((result) => {
    updateTerminalSearchStatus(session, result.resultIndex, result.resultCount);
  });
  session.focusDisposable = term.onFocus?.(() => {
    const found = findPanelState(panel.id);
    if (!found || state.data?.activeWorkspaceId !== found.workspace.id) return;
    state.focusedPanelId = panel.id;
    state.lastInteractedPanelId = panel.id;
    if (found.workspace.activePanelId !== panel.id) {
      rememberPreviousPanel(found.workspace, found.workspace.activePanelId);
      found.workspace.activePanelId = panel.id;
      scheduleRender();
      queueFocusSync({ type: "panel", panelId: panel.id });
    }
  });

  socket.addEventListener("open", () => {
    recordTerminalConnectDuration(performance.now() - session.createdAt);
    if (!session.hasOutput) setTerminalConnectionStatus(session, "connecting", "Starting shell");
    scheduleFitTerminal(session, true);
  });
  socket.addEventListener("error", () => {
    if (!session.disposed) setTerminalConnectionStatus(session, "error", "Shell connection failed");
  });
  socket.addEventListener("close", () => {
    if (!session.disposed) setTerminalConnectionStatus(session, "disconnected", "Shell disconnected");
  });
  socket.addEventListener("message", (event) => {
    if (session.disposed) return;
    const message = JSON.parse(event.data);
    if (message.type === "output") {
      markTerminalOutputReady(session);
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
  requestInitialTerminalLayout(session, panel.id);
  state.terminals.set(panel.id, session);
}

function requestInitialTerminalLayout(session, panelId, frame = 0) {
  requestAnimationFrame(() => {
    if (session.disposed) return;
    if (!isTerminalHostVisible(session)) {
      scheduleFitTerminal(session, true);
      if (frame < 12) requestInitialTerminalLayout(session, panelId, frame + 1);
      return;
    }
    scheduleFitTerminal(session, true);
    if (panelId === activeWorkspace()?.activePanelId) session.term.focus();
  });
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
  requestAnimationFrame(() => {
    if (target.session.disposed || target.session.searchOverlay.hidden) return;
    const input = terminalSearchInput(target.session);
    input?.focus();
    input?.select();
  });
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

function trimPausedTerminalOutput(session) {
  if (!session?.queue || session.queue.length <= terminalHiddenOutputQueueLimit) return false;
  const preserveBytes = Math.min(terminalHiddenOutputPreserveBytes, session.queue.length);
  const trimmedBytes = session.queue.length - preserveBytes;
  if (trimmedBytes <= 0) return false;
  const marker = `\r\n[cmux] ${formatBytes(trimmedBytes)} of hidden output was trimmed to keep switching responsive.\r\n`;
  session.queue = marker + session.queue.slice(-preserveBytes);
  state.terminalOutputStats.trimmedBytes = (state.terminalOutputStats.trimmedBytes || 0) + trimmedBytes;
  state.terminalOutputStats.trimmedEvents = (state.terminalOutputStats.trimmedEvents || 0) + 1;
  return true;
}

function enqueueTerminalOutput(session, data) {
  session.queue += data;
  const paused = terminalOutputShouldPause(session);
  if (paused) trimPausedTerminalOutput(session);
  updateTerminalOutputBacklog();
  if (state.terminalOutputStats.currentQueued >= terminalOutputBacklogThreshold) {
    maybeTriggerPerformanceGuard("terminal output backlog");
  }
  if (!paused) scheduleTerminalOutputFlush(session);
}

function scheduleTerminalOutputFlush(session) {
  if (session.disposed || session.scheduled) return;
  session.scheduled = true;
  requestAnimationFrame(() => flushTerminalOutput(session));
}

function flushTerminalOutput(session) {
  session.scheduled = false;
  if (session.disposed || !session.queue) return;
  if (terminalOutputShouldPause(session)) {
    state.terminalOutputStats.pausedFlushes += 1;
    return;
  }
  const chunkSize = terminalOutputChunkSizeFor(session);
  const chunk = session.queue.length > chunkSize ? session.queue.slice(0, chunkSize) : session.queue;
  session.queue = session.queue.slice(chunk.length);
  state.terminalOutputStats.chunks += 1;
  state.terminalOutputStats.lastChunk = chunk.length;
  state.terminalOutputStats.writtenBytes += chunk.length;
  session.term.write(chunk, () => clearTerminalConnectionStatus(session));
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

function terminalOutputPausesInactive() {
  return state.settings.terminalPauseInactiveOutput !== false || state.settings.performanceMode;
}

function terminalOutputShouldPause(session) {
  return terminalOutputPausesInactive() && !isTerminalHostVisible(session);
}

function resumeTerminalOutputAfterActivityChange(visiblePanelIds = visiblePanePanelIds()) {
  const pauseInactive = terminalOutputPausesInactive();
  for (const session of state.terminals.values()) {
    if (session.disposed || !session.queue) continue;
    if (!pauseInactive || visiblePanelIds.has(session.panelId)) scheduleTerminalOutputFlush(session);
  }
  updateTerminalOutputBacklog();
}

function pausedTerminalOutputCount() {
  let count = 0;
  for (const session of state.terminals.values()) {
    if (!session.disposed && session.queue && terminalOutputShouldPause(session)) count += 1;
  }
  return count;
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
  if (!terminalFitCanRun(session)) {
    if (!session.fitDeferred) state.terminalFitStats.deferred += 1;
    session.fitDeferred = true;
    return;
  }
  session.fitDeferred = false;
  if (session.fitFrame) return;
  session.fitFrame = requestAnimationFrame(() => {
    session.fitFrame = 0;
    fitTerminal(session);
  });
}

function fitTerminal(session) {
  if (session.disposed) return;
  if (!terminalFitCanRun(session)) {
    if (!session.fitDeferred) state.terminalFitStats.deferred += 1;
    session.fitDeferred = true;
    return;
  }
  session.fitDeferred = false;
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

function terminalFitCanRun(session) {
  return !document.hidden && isTerminalHostVisible(session);
}

function scheduleDeferredTerminalFitFlush() {
  if (document.hidden || state.deferredTerminalFitFrame) return;
  state.deferredTerminalFitFrame = requestAnimationFrame(() => {
    state.deferredTerminalFitFrame = 0;
    flushDeferredTerminalFits();
  });
}

function flushDeferredTerminalFits() {
  if (document.hidden) return;
  for (const session of state.terminals.values()) {
    if (session.disposed || !session.fitDeferred || !terminalFitCanRun(session)) continue;
    session.fitDeferred = false;
    state.terminalFitStats.flushed += 1;
    scheduleFitTerminal(session, true);
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

function setBrowserAudioMuted(view, muted) {
  if (typeof view?.setAudioMuted !== "function") return;
  try {
    if (typeof view.isAudioMuted === "function" && view.isAudioMuted() === muted) return;
    view.setAudioMuted(muted);
  } catch {
    // Webview audio controls are best-effort and unavailable in iframe fallback.
  }
}

function stopBrowserLoading(view) {
  try {
    if (typeof view?.isLoading === "function" && !view.isLoading()) return;
    if (typeof view?.stop === "function") view.stop();
  } catch {
    // The pane may be detached while workspaces are switching.
  }
}

function lockBrowserViewZoom(view) {
  if (!view || typeof view.setZoomFactor !== "function") return;
  try {
    view.setZoomFactor(1);
    if (typeof view.setZoomLevel === "function") view.setZoomLevel(0);
    const limits = typeof view.setVisualZoomLevelLimits === "function"
      ? view.setVisualZoomLevelLimits(1, 1)
      : null;
    limits?.catch?.(() => {});
  } catch {
    // The iframe fallback and detached webviews do not expose every Electron method.
  }
}

function resolveBrowserPanel(panel = focusedPanel()) {
  const found = panel?.id ? findPanelState(panel.id) : null;
  const candidate = found?.panel || panel;
  return candidate?.type === "browser" && !isPendingPanel(candidate) ? candidate : null;
}

function browserPanelUrl(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) return "";
  const session = state.browserViews.get(browserPanel.id);
  return normalizeUrl(session?.address?.value || browserPanel.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
}

function focusBrowserAddress(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) {
    toast("Focus a browser pane first.");
    return false;
  }
  focusPanel(browserPanel.id);
  requestAnimationFrame(() => {
    const address = state.browserViews.get(browserPanel.id)?.address;
    if (!address) return;
    address.focus();
    address.select();
  });
  return true;
}

function reloadBrowserPanel(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) {
    toast("Focus a browser pane first.");
    return false;
  }
  focusPanel(browserPanel.id);
  const session = state.browserViews.get(browserPanel.id);
  if (!session) {
    toast("Browser pane is not ready.");
    return false;
  }
  const url = browserPanelUrl(browserPanel);
  session.setLoading?.(true);
  session.setStatus?.("Loading");
  if (typeof session.view?.reload === "function" && !session.reload?.disabled) {
    session.view.reload();
  } else {
    session.address.value = url;
    session.view.src = browserViewSourceUrl(url);
  }
  return true;
}

function navigateBrowserHistory(delta, panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  const session = browserPanel ? state.browserViews.get(browserPanel.id) : null;
  if (!browserPanel || !session) return false;
  focusPanel(browserPanel.id);
  try {
    if (delta < 0 && typeof session.view?.goBack === "function" && !session.back?.disabled) {
      session.view.goBack();
      return true;
    }
    if (delta > 0 && typeof session.view?.goForward === "function" && !session.forward?.disabled) {
      session.view.goForward();
      return true;
    }
  } catch {
    return false;
  }
  return false;
}

async function openBrowserPanelExternally(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) {
    toast("Focus a browser pane first.");
    return false;
  }
  focusPanel(browserPanel.id);
  await openExternalBrowser(browserPanelUrl(browserPanel));
  return true;
}

async function copyBrowserPanelUrl(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) {
    toast("Focus a browser pane first.");
    return false;
  }
  const url = browserPanelUrl(browserPanel);
  if (await writeClipboardText(url)) {
    toast("Browser URL copied.");
    return true;
  }
  toast("Clipboard is unavailable.");
  return false;
}

function newBrowserTabFromPanel(panel = focusedPanel()) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) return createPanel("browser", "right", { url: state.settings.browserHomeUrl });
  const session = state.browserViews.get(browserPanel.id);
  if (session) {
    focusPanel(browserPanel.id);
    return createBrowserTab(session, state.settings.browserHomeUrl);
  }
  const found = findPanelState(browserPanel.id);
  return createPanel("browser", "right", {
    workspaceId: found?.workspace.id,
    anchorPanelId: browserPanel.id,
    url: state.settings.browserHomeUrl
  });
}

function updateBrowserPaneActivity(visiblePanelIds = new Set()) {
  const activePanelId = activeWorkspace()?.activePanelId || "";
  for (const [panelId, session] of state.browserViews.entries()) {
    const visible = visiblePanelIds.has(panelId);
    const active = visible && panelId === activePanelId;
    const suspended = state.settings.browserSuspendInactive && !active;
    if (active || (visible && !state.settings.browserSuspendInactive)) {
      loadDeferredBrowserSession(session);
    }
    const hasStalePausedStatus = session.statusText === browserPausedStatusText && !suspended;
    const isMissingPausedStatus = session.statusText !== browserPausedStatusText && suspended;
    if (
      session.visible === visible
      && session.active === active
      && session.suspended === suspended
      && session.suspendInactive === state.settings.browserSuspendInactive
      && !hasStalePausedStatus
      && !isMissingPausedStatus
    ) continue;
    session.visible = visible;
    session.active = active;
    session.suspended = suspended;
    session.suspendInactive = state.settings.browserSuspendInactive;
    session.shell?.classList.toggle("is-browser-suspended", suspended);
    if (suspended) {
      session.setStatus?.(browserPausedStatusText);
    } else if (session.statusText === browserPausedStatusText) {
      session.setStatus?.("");
    }
    setBrowserAudioMuted(session.view, suspended);
    if (suspended) stopBrowserLoading(session.view);
  }
}

function activeBrowserTab(session) {
  return session?.tabs?.find((tab) => tab.id === session.activeTabId) || session?.tabs?.[0] || null;
}

function browserSessionTargetUrl(session) {
  return normalizeUrl(
    session?.address?.value || activeBrowserTab(session)?.url || state.settings.browserHomeUrl,
    state.settings.browserHomeUrl
  );
}

function isGoogleHomeUrl(value) {
  try {
    const parsed = new URL(normalizeUrl(value, state.settings.browserHomeUrl));
    const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
    if (host !== "google.com") return false;
    const path = parsed.pathname.replace(/\/+$/, "") || "/";
    if (path !== "/" && path !== "/webhp") return false;
    if (parsed.searchParams.has("q")) return false;
    for (const key of parsed.searchParams.keys()) {
      if (!["igu", "zx"].includes(key.toLowerCase())) return false;
    }
    return true;
  } catch {
    return false;
  }
}

function browserViewSourceUrl(value) {
  const targetUrl = normalizeUrl(value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  return isGoogleHomeUrl(targetUrl) ? embeddedGoogleHomeUrl : targetUrl;
}

function browserDisplayUrl(value) {
  const targetUrl = normalizeUrl(value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  return isGoogleHomeUrl(targetUrl) ? "https://www.google.com/" : targetUrl;
}

function scheduleEmbeddedGoogleHomePolish(view, value) {
  if (!isGoogleHomeUrl(value || view?.src)) return;
  if (!view?.isConnected) return;
  if (typeof view?.executeJavaScript !== "function") return;
  try {
    const result = view.executeJavaScript(embeddedGooglePromoDismissScript, true);
    result?.catch?.(() => {});
  } catch {
    // Webviews can detach while panes or workspaces are being rearranged.
  }
}

function loadDeferredBrowserSession(session) {
  if (!session?.loadDeferred) return false;
  const targetUrl = browserSessionTargetUrl(session);
  const sourceUrl = browserViewSourceUrl(targetUrl);
  clearDeferredBrowserSession(session);
  if (session.view.src !== sourceUrl) {
    session.setLoading?.(true);
    session.setStatus?.("Loading");
    session.view.src = sourceUrl;
  }
  session.updateNavState?.();
  return true;
}

function clearDeferredBrowserSession(session) {
  if (!session) return;
  session.loadDeferred = false;
  if (session.deferredPane) session.deferredPane.hidden = true;
  session.shell?.classList.remove("is-browser-deferred");
}

function shouldDeferInitialBrowserLoad(panel) {
  const workspace = activeWorkspace();
  if (!state.settings.browserSuspendInactive || !workspace || panel.id === workspace.activePanelId) return false;
  const browserPanels = workspace.panels.filter((candidate) => (
    candidate.type === "browser" && !isPanelMinimized(candidate) && !isPendingPanel(candidate)
  ));
  if (browserPanels.length <= 1) return false;
  const activeBrowserPanelId = workspace.panels.find((candidate) =>
    candidate.id === workspace.activePanelId && candidate.type === "browser"
  )?.id;
  const eagerBrowserPanelId = activeBrowserPanelId || browserPanels[0]?.id;
  return panel.id !== eagerBrowserPanelId;
}

function shouldRenderDeferredBrowserShell(panel) {
  return panel?.type === "browser"
    && !state.browserViews.has(panel.id)
    && shouldDeferInitialBrowserLoad(panel);
}

function renderDeferredBrowserShell(panel, body) {
  let deferred = body.querySelector(".browser-deferred-standalone");
  const targetUrl = normalizeUrl(panel.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  if (!deferred) {
    deferred = document.createElement("button");
    deferred.className = "browser-deferred browser-deferred-standalone";
    deferred.type = "button";
    deferred.setAttribute("aria-label", "Browser paused. Click pane to load.");
    deferred.innerHTML = `
      <span class="browser-deferred-title">Browser paused</span>
      <span class="browser-deferred-url"></span>
      <span class="browser-deferred-action">Click pane to load</span>
    `;
    deferred.onclick = () => focusPanel(panel.id);
    body.replaceChildren(deferred);
  }
  deferred.querySelector(".browser-deferred-url").textContent = targetUrl;
  deferred.querySelector(".browser-deferred-url").title = targetUrl;
}

function saveBrowserSessionTabs(session) {
  if (!session?.panelId) return;
  state.browserTabSnapshots.set(session.panelId, normalizeBrowserTabSnapshot({
    activeTabId: session.activeTabId,
    tabs: session.tabs
  }, state.settings.browserHomeUrl));
  scheduleBrowserTabSnapshotsSave();
}

function saveBrowserSessionTabsNow(session) {
  if (!session?.panelId) return;
  state.browserTabSnapshots.set(session.panelId, normalizeBrowserTabSnapshot({
    activeTabId: session.activeTabId,
    tabs: session.tabs
  }, state.settings.browserHomeUrl));
  flushBrowserTabSnapshotsSave();
}

function scheduleBrowserTabSnapshotsSave() {
  if (state.browserTabSnapshotSaveTimer) return;
  state.browserTabSnapshotSaveTimer = setTimeout(flushBrowserTabSnapshotsSave, browserTabSnapshotSaveDelay);
}

function flushBrowserTabSnapshotsSave() {
  if (state.browserTabSnapshotSaveTimer) {
    clearTimeout(state.browserTabSnapshotSaveTimer);
    state.browserTabSnapshotSaveTimer = 0;
  }
  saveBrowserTabSnapshots(state.browserTabSnapshots);
}

function browserTabSnapshotForPanelId(panelId, fallbackUrl = state.settings.browserHomeUrl) {
  const session = state.browserViews.get(panelId);
  if (session) {
    return normalizeBrowserTabSnapshot({
      activeTabId: session.activeTabId,
      tabs: session.tabs
    }, fallbackUrl);
  }
  return normalizeBrowserTabSnapshot(state.browserTabSnapshots.get(panelId), fallbackUrl);
}

function renderBrowserTabs(session) {
  if (!session?.tabList) return;
  if (session.tabRenderFrame) {
    cancelAnimationFrame(session.tabRenderFrame);
    session.tabRenderFrame = 0;
  }
  if (!session.tabButtons) session.tabButtons = new Map();
  const validTabIds = new Set(session.tabs.map((tab) => tab.id));
  for (const [tabId, button] of [...session.tabButtons.entries()]) {
    if (validTabIds.has(tabId)) continue;
    button.remove();
    session.tabButtons.delete(tabId);
  }
  const nodes = session.tabs.map((tab) => {
    let button = session.tabButtons.get(tab.id);
    if (!button) {
      button = createBrowserTabButton(session);
      session.tabButtons.set(tab.id, button);
    }
    updateBrowserTabButton(session, button, tab);
    return button;
  });
  replaceChildrenIfChanged(session.tabList, nodes);
  updateBrowserTabNewButton(session);
  scheduleActiveBrowserTabIntoView(session);
  scheduleBrowserTabOverflowRefresh(session);
}

function updateBrowserTabNewButton(session) {
  if (!session?.tabNew) return;
  const atLimit = (session.tabs?.length || 0) >= browserTabLimit;
  session.tabNew.classList.toggle("is-disabled", atLimit);
  session.tabNew.setAttribute("aria-disabled", String(atLimit));
  session.tabNew.title = atLimit
    ? `Browser tab limit reached (${browserTabLimit})`
    : t("browser.newTab");
}

function scheduleBrowserTabsRender(session) {
  if (!session?.tabList || session.tabRenderFrame) return;
  session.tabRenderFrame = requestAnimationFrame(() => {
    session.tabRenderFrame = 0;
    renderBrowserTabs(session);
  });
}

function scheduleBrowserTabOverflowRefresh(session) {
  if (!session?.tabList || session.tabOverflowFrame) return;
  session.tabOverflowFrame = requestAnimationFrame(() => {
    session.tabOverflowFrame = 0;
    updateBrowserTabOverflow(session);
  });
}

function updateBrowserTabOverflow(session) {
  const tabList = session?.tabList;
  if (!tabList) return;
  const tabCount = session.tabs?.length || tabList.children.length;
  if (tabCount < 5 && tabList.classList.contains("is-crowded")) {
    tabList.classList.remove("is-crowded");
  }
  const naturalOverflowing = tabList.scrollWidth > tabList.clientWidth + 1;
  toggleClassIfChanged(tabList, "is-crowded", naturalOverflowing || tabCount >= 5);
  const overflowing = tabList.scrollWidth > tabList.clientWidth + 1;
  const maxScrollLeft = Math.max(0, tabList.scrollWidth - tabList.clientWidth);
  const scrollLeft = Math.max(0, tabList.scrollLeft);
  toggleClassIfChanged(tabList, "has-overflow", overflowing);
  toggleClassIfChanged(tabList, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(tabList, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
  if (!overflowing && tabList.scrollLeft) tabList.scrollLeft = 0;
}

function scheduleActiveBrowserTabIntoView(session) {
  if (!session?.tabList || !session.activeTabId) return;
  if (session.tabScrollFrame) return;
  session.tabScrollFrame = requestAnimationFrame(() => {
    session.tabScrollFrame = 0;
    const activeButton = session.tabButtons?.get(session.activeTabId);
    if (!activeButton) return;
    const inset = 8;
    const minLeft = activeButton.offsetLeft - inset;
    const maxRight = activeButton.offsetLeft + activeButton.offsetWidth - session.tabList.clientWidth + inset;
    const maxScroll = Math.max(0, session.tabList.scrollWidth - session.tabList.clientWidth);
    let nextLeft = session.tabList.scrollLeft;
    if (activeButton.offsetLeft < session.tabList.scrollLeft + inset) {
      nextLeft = minLeft;
    } else if (activeButton.offsetLeft + activeButton.offsetWidth > session.tabList.scrollLeft + session.tabList.clientWidth - inset) {
      nextLeft = maxRight;
    }
    nextLeft = clamp(nextLeft, 0, maxScroll);
    if (Math.abs(nextLeft - session.tabList.scrollLeft) >= 1) {
      session.tabList.scrollTo({ left: nextLeft, behavior: "auto" });
    }
    scheduleBrowserTabOverflowRefresh(session);
  });
}

function createBrowserTabButton(session) {
  const button = document.createElement("button");
  button.type = "button";
  button.draggable = true;
  button.className = "browser-tab";
  const label = document.createElement("span");
  label.className = "browser-tab-label";
  const close = document.createElement("span");
  close.className = "browser-tab-close";
  close.textContent = "×";
  button._browserTabParts = { label, close };
  close.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    closeBrowserTab(session, button.dataset.browserTabId);
  });
  button.append(label, close);
  button.addEventListener("click", () => activateBrowserTab(session, button.dataset.browserTabId));
  button.addEventListener("mousedown", (event) => {
    if (event.button === 1) event.preventDefault();
  });
  button.addEventListener("auxclick", (event) => {
    if (event.button !== 1) return;
    event.preventDefault();
    event.stopPropagation();
    closeBrowserTab(session, button.dataset.browserTabId);
  });
  button.addEventListener("keydown", (event) => {
    if (event.key !== "Delete") return;
    event.preventDefault();
    event.stopPropagation();
    closeBrowserTab(session, button.dataset.browserTabId);
  });
  button.addEventListener("contextmenu", (event) => showBrowserTabContextMenu(event, session, button.dataset.browserTabId));
  button.addEventListener("dragstart", (event) => {
    const tabId = button.dataset.browserTabId;
    session.dragBrowserTabId = tabId;
    button.classList.add("is-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", tabId);
  });
  button.addEventListener("dragover", (event) => {
    const targetTabId = button.dataset.browserTabId;
    if (!session.dragBrowserTabId || session.dragBrowserTabId === targetTabId) return;
    event.preventDefault();
    clearBrowserTabDropTargets(session);
    button.classList.add(browserTabDropPlacement(event, button) === "after" ? "is-drop-after" : "is-drop-before");
  });
  button.addEventListener("dragleave", () => {
    button.classList.remove("is-drop-before", "is-drop-after");
  });
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const placement = browserTabDropPlacement(event, button);
    const draggedTabId = session.dragBrowserTabId;
    const targetTabId = button.dataset.browserTabId;
    clearBrowserTabDropTargets(session);
    if (draggedTabId && draggedTabId !== targetTabId) moveBrowserTab(session, draggedTabId, targetTabId, placement);
  });
  button.addEventListener("dragend", () => {
    session.dragBrowserTabId = "";
    button.classList.remove("is-dragging");
    clearBrowserTabDropTargets(session);
  });
  return button;
}

function updateBrowserTabButton(session, button, tab) {
  const label = browserTabLabel(session, tab);
  const fullTitle = tab.title || browserTabTitle(tab.url);
  const ordinal = Math.max(1, (session?.tabs || []).findIndex((candidate) => candidate.id === tab.id) + 1);
  const closeLabel = session.tabs.length <= 1 ? t("browser.resetTab") : t("browser.closeTab");
  button._browserTabParts ||= {
    label: button.querySelector(".browser-tab-label"),
    close: button.querySelector(".browser-tab-close")
  };
  const parts = button._browserTabParts;
  setClassNameIfChanged(button, `browser-tab${tab.id === session.activeTabId ? " is-active" : ""}`);
  setDatasetIfChanged(button, "browserTabId", tab.id);
  setDatasetIfChanged(button, "tabIndex", String(ordinal));
  setTitleIfChanged(button, `${label}${label !== fullTitle ? ` - ${fullTitle}` : ""} - ${tab.url}`);
  button.setAttribute("aria-label", `${label}. ${tab.url}. ${closeLabel} with Delete.`);
  setTextIfChanged(parts.label, label);
  setTitleIfChanged(parts.close, closeLabel);
}

function browserTabLabel(session, tab) {
  const label = tab.title || browserTabTitle(tab.url);
  const duplicates = (session?.tabs || [])
    .filter((candidate) => (candidate.title || browserTabTitle(candidate.url)) === label);
  if (duplicates.length <= 1) return label;
  const duplicateIndex = duplicates.findIndex((candidate) => candidate.id === tab.id);
  return duplicateIndex >= 0 ? `${label} ${duplicateIndex + 1}` : label;
}

function browserTabDropPlacement(event, button) {
  const rect = button.getBoundingClientRect();
  return event.clientX - rect.left > rect.width / 2 ? "after" : "before";
}

function clearBrowserTabDropTargets(session) {
  for (const button of session?.tabList?.querySelectorAll(".browser-tab.is-drop-before, .browser-tab.is-drop-after") || []) {
    button.classList.remove("is-drop-before", "is-drop-after");
  }
  session?.tabNew?.classList.remove("is-drop-before");
}

function moveBrowserTab(session, tabId, targetTabId, placement = "before") {
  if (!session || tabId === targetTabId) return false;
  const fromIndex = session.tabs.findIndex((tab) => tab.id === tabId);
  const targetIndex = session.tabs.findIndex((tab) => tab.id === targetTabId);
  if (fromIndex < 0 || targetIndex < 0) return false;
  const [tab] = session.tabs.splice(fromIndex, 1);
  let insertIndex = session.tabs.findIndex((candidate) => candidate.id === targetTabId);
  if (insertIndex < 0) insertIndex = session.tabs.length;
  if (placement === "after") insertIndex += 1;
  session.tabs.splice(insertIndex, 0, tab);
  saveBrowserSessionTabsNow(session);
  renderBrowserTabs(session);
  return true;
}

function moveBrowserTabToEnd(session, tabId) {
  if (!session) return false;
  const fromIndex = session.tabs.findIndex((tab) => tab.id === tabId);
  if (fromIndex < 0 || fromIndex === session.tabs.length - 1) return false;
  const [tab] = session.tabs.splice(fromIndex, 1);
  session.tabs.push(tab);
  saveBrowserSessionTabsNow(session);
  renderBrowserTabs(session);
  return true;
}

function duplicateBrowserTab(session, tabId) {
  if (!session) return false;
  if (session.tabs.length >= browserTabLimit) {
    toast(`Browser tab limit is ${browserTabLimit}. Close one first.`);
    return false;
  }
  const index = session.tabs.findIndex((tab) => tab.id === tabId);
  const source = session.tabs[index];
  if (!source) return false;
  const tab = normalizeBrowserTab({ url: source.url }, state.settings.browserHomeUrl);
  if (!tab) return false;
  tab.title = source.title || browserTabTitle(tab.url);
  session.tabs.splice(index + 1, 0, tab);
  activateBrowserTab(session, tab.id);
  return true;
}

function closeOtherBrowserTabs(session, tabId) {
  if (!session || session.tabs.length <= 1) return false;
  const tab = session.tabs.find((candidate) => candidate.id === tabId);
  if (!tab) return false;
  session.tabs = [tab];
  return activateBrowserTab(session, tab.id);
}

function closeBrowserTabsToRight(session, tabId) {
  if (!session) return false;
  const index = session.tabs.findIndex((tab) => tab.id === tabId);
  if (index < 0 || index >= session.tabs.length - 1) return false;
  const activeRemoved = session.tabs.slice(index + 1).some((tab) => tab.id === session.activeTabId);
  session.tabs = session.tabs.slice(0, index + 1);
  if (activeRemoved) return activateBrowserTab(session, tabId);
  saveBrowserSessionTabsNow(session);
  renderBrowserTabs(session);
  return true;
}

async function copyBrowserTabUrl(tab) {
  const url = normalizeUrl(tab?.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  if (await writeClipboardText(url)) {
    toast("Browser URL copied.");
    return true;
  }
  toast("Clipboard is unavailable.");
  return false;
}

function showBrowserTabContextMenu(event, session, tabId) {
  event.preventDefault();
  event.stopPropagation();
  const tab = session?.tabs?.find((candidate) => candidate.id === tabId);
  if (!tab) return;
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = browserTabLabel(session, tab);
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = tab.url;
  const actions = contextMenuActionGroup(
    contextMenuButton(tab.id === session.activeTabId ? "Focused" : "Focus tab", () => activateBrowserTab(session, tab.id), tab.id === session.activeTabId),
    contextMenuButton("New tab", () => createBrowserTab(session, state.settings.browserHomeUrl)),
    contextMenuButton("Duplicate tab", () => duplicateBrowserTab(session, tab.id)),
    contextMenuButton("Copy URL", () => copyBrowserTabUrl(tab)),
    contextMenuButton(t("browser.openExternally"), () => openExternalBrowser(tab.url, { toast: true })),
    contextMenuButton(t("browser.openWithProfile"), () => showExternalBrowserProfileMenuAt(event.clientX, event.clientY, tab.url), false, "", { keepOpen: true })
  );
  const closeActions = contextMenuActionGroup(
    contextMenuButton("Close other tabs", () => closeOtherBrowserTabs(session, tab.id), session.tabs.length <= 1),
    contextMenuButton("Close tabs to right", () => closeBrowserTabsToRight(session, tab.id), session.tabs.findIndex((candidate) => candidate.id === tab.id) >= session.tabs.length - 1),
    contextMenuButton(session.tabs.length <= 1 ? "Reset tab" : "Close tab", () => closeBrowserTab(session, tab.id), false, "danger")
  );
  menu.replaceChildren(title, meta, contextMenuSectionTitle("Tab"), actions, contextMenuSectionTitle("Close"), closeActions);
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function updateActiveBrowserTabUrl(session, value) {
  const tab = activeBrowserTab(session);
  if (!tab) return;
  const url = normalizeBrowserPageUrl(value || state.settings.browserHomeUrl);
  if (!url) return;
  tab.url = url;
  tab.title = browserTabTitle(url);
  saveBrowserSessionTabs(session);
  scheduleBrowserTabsRender(session);
}

function updateActiveBrowserTabTitle(session, value) {
  const tab = activeBrowserTab(session);
  if (!tab) return;
  const title = String(value || "").replace(/\s+/g, " ").trim().slice(0, 80);
  if (!title || title === tab.title) return;
  tab.title = title;
  saveBrowserSessionTabs(session);
  scheduleBrowserTabsRender(session);
}

function activateBrowserTab(session, tabId) {
  if (!session) return false;
  const tab = session.tabs.find((candidate) => candidate.id === tabId);
  if (!tab) return false;
  session.activeTabId = tab.id;
  session.address.value = tab.url;
  clearDeferredBrowserSession(session);
  const sourceUrl = browserViewSourceUrl(tab.url);
  if (session.view.src !== sourceUrl) {
    session.view.src = sourceUrl;
    session.setLoading?.(true);
    session.setStatus?.("Loading");
  }
  queueBrowserUrlSync(session.panelId, tab.url);
  saveBrowserSessionTabsNow(session);
  renderBrowserTabs(session);
  focusPanel(session.panelId);
  return true;
}

function createBrowserTab(session, value = state.settings.browserHomeUrl) {
  if (!session) return false;
  if (session.tabs.length >= browserTabLimit) {
    toast(`Browser tab limit is ${browserTabLimit}. Close one first.`);
    return false;
  }
  const tab = normalizeBrowserTab({ url: value }, state.settings.browserHomeUrl);
  if (!tab) return false;
  session.tabs.push(tab);
  activateBrowserTab(session, tab.id);
  return true;
}

function closeBrowserTab(session, tabId) {
  if (!session) return false;
  const index = session.tabs.findIndex((tab) => tab.id === tabId);
  if (index < 0) return false;
  if (session.tabs.length <= 1) {
    const tab = session.tabs[0];
    tab.url = normalizeBrowserPageUrl(state.settings.browserHomeUrl) || defaultSettings.browserHomeUrl;
    tab.title = browserTabTitle(tab.url);
    session.activeTabId = tab.id;
    activateBrowserTab(session, tab.id);
    return true;
  }
  const wasActive = session.activeTabId === tabId;
  session.tabs.splice(index, 1);
  if (wasActive) {
    const nextTab = session.tabs[Math.min(index, session.tabs.length - 1)];
    session.activeTabId = nextTab.id;
    activateBrowserTab(session, nextTab.id);
  } else {
    saveBrowserSessionTabsNow(session);
    renderBrowserTabs(session);
  }
  return true;
}

function terminalWheelZoomStateFor(panelId) {
  let zoomState = state.terminalWheelZoomState.get(panelId);
  if (!zoomState) {
    zoomState = { at: 0, remainder: 0 };
    state.terminalWheelZoomState.set(panelId, zoomState);
  }
  return zoomState;
}

function ensureBrowser(panel, body) {
  if (state.browserViews.has(panel.id)) return;
  body.replaceChildren();

  const shell = document.createElement("div");
  shell.className = "browser-shell";
  const tabStrip = document.createElement("div");
  tabStrip.className = "browser-tabs";
  const tabList = document.createElement("div");
  tabList.className = "browser-tab-list";
  const tabNew = document.createElement("button");
  tabNew.className = "browser-tab-new";
  tabNew.type = "button";
  tabNew.title = t("browser.newTab");
  tabNew.setAttribute("aria-label", t("browser.newTab"));
  tabNew.textContent = "+";
  tabStrip.append(tabList, tabNew);
  const bar = document.createElement("div");
  bar.className = "browser-bar";
  const back = document.createElement("button");
  back.className = "browser-nav browser-back";
  back.type = "button";
  back.title = "Back";
  back.textContent = "‹";
  const forward = document.createElement("button");
  forward.className = "browser-nav browser-forward";
  forward.type = "button";
  forward.title = "Forward";
  forward.textContent = "›";
  const reload = document.createElement("button");
  reload.className = "browser-nav browser-reload";
  reload.type = "button";
  reload.title = "Reload";
  reload.textContent = "↻";
  const home = document.createElement("button");
  home.className = "browser-nav browser-home";
  home.type = "button";
  home.title = "Home";
  home.textContent = "⌂";
  const address = document.createElement("input");
  address.className = "browser-address";
  const tabSnapshot = browserTabSnapshotForPanel(state.browserTabSnapshots, panel, state.settings.browserHomeUrl);
  const activeTab = tabSnapshot.tabs.find((tab) => tab.id === tabSnapshot.activeTabId) || tabSnapshot.tabs[0];
  address.value = activeTab?.url || panel.url || state.settings.browserHomeUrl;
  const go = document.createElement("button");
  go.className = "browser-go browser-go-submit";
  go.type = "button";
  go.textContent = "Go";
  const external = document.createElement("button");
  external.className = "browser-go browser-go-external";
  external.type = "button";
  external.title = "Open in system browser";
  external.textContent = "↗";
  const status = document.createElement("div");
  status.className = "browser-status";
  status.textContent = "Loading";
  bar.append(back, forward, reload, home, address, go, external);

  const content = document.createElement("div");
  content.className = "browser-content";
  const view = document.createElement(window.cmuxNative?.electron ? "webview" : "iframe");
  view.className = "browser-view";
  if (view.tagName.toLowerCase() === "webview") {
    view.setAttribute("partition", "persist:cmux-browser");
    view.setAttribute("webpreferences", "contextIsolation=yes,nodeIntegration=no");
    view.setAttribute("useragent", embeddedBrowserUserAgent());
  }
  const initialBrowserUrl = normalizeUrl(address.value, state.settings.browserHomeUrl);
  const errorPane = document.createElement("div");
  errorPane.className = "browser-error";
  errorPane.hidden = true;
  errorPane.innerHTML = `
    <div class="browser-error-card">
      <span class="browser-error-title"></span>
      <span class="browser-error-body"></span>
      <span class="browser-error-url"></span>
      <span class="browser-error-actions">
        <button class="browser-error-action browser-error-retry" type="button">Retry</button>
        <button class="browser-error-action browser-error-open" type="button">Open</button>
        <button class="browser-error-action browser-error-home" type="button">Home</button>
      </span>
    </div>
  `;
  const loadingPane = document.createElement("div");
  loadingPane.className = "browser-loading";
  loadingPane.innerHTML = `
    <span class="browser-loading-track"></span>
    <span class="browser-loading-title"></span>
    <span class="browser-loading-url"></span>
  `;
  const deferredPane = document.createElement("button");
  deferredPane.className = "browser-deferred";
  deferredPane.type = "button";
  deferredPane.setAttribute("aria-label", "Browser paused. Click pane to load.");
  deferredPane.hidden = true;
  deferredPane.innerHTML = `
    <span class="browser-deferred-title">Browser paused</span>
    <span class="browser-deferred-url"></span>
    <span class="browser-deferred-action">Click pane to load</span>
  `;
  content.append(view, errorPane, loadingPane, deferredPane);
  const isWebview = view.tagName.toLowerCase() === "webview";
  let webviewReady = !isWebview;
  let loadingStatusTimer = 0;
  let browserLoadTimer = 0;
  let browserLoadFailed = false;
  let session = null;

  const clearBrowserLoadTimer = () => {
    if (!browserLoadTimer) return;
    clearTimeout(browserLoadTimer);
    browserLoadTimer = 0;
  };

  const setLoading = (loading = false) => {
    const visible = Boolean(loading);
    const targetUrl = normalizeUrl(address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    clearBrowserLoadTimer();
    loadingPane.hidden = !visible;
    content.classList.toggle("is-loading", visible);
    if (!visible) return;
    loadingPane.querySelector(".browser-loading-title").textContent = `Loading ${hostnameOf(targetUrl)}`;
    loadingPane.querySelector(".browser-loading-url").textContent = targetUrl;
    loadingPane.querySelector(".browser-loading-url").title = targetUrl;
    browserLoadTimer = setTimeout(() => {
      browserLoadTimer = 0;
      if (!content.classList.contains("is-loading") || browserLoadFailed || deferredPane.hidden === false) return;
      browserLoadFailed = true;
      showBrowserError("The page is taking too long to respond. Try again, open it externally, or return home.", targetUrl);
      updateNavState();
    }, browserLoadTimeoutMs);
  };

  const setStatus = (message = "") => {
    if (!message && session?.suspended) message = browserPausedStatusText;
    if (loadingStatusTimer) {
      clearTimeout(loadingStatusTimer);
      loadingStatusTimer = 0;
    }
    if (session) session.statusText = message;
    status.textContent = message;
    status.classList.toggle("is-visible", Boolean(message));
    shell.classList.toggle("has-browser-status", Boolean(message));
    if (message === "Loading") {
      loadingStatusTimer = setTimeout(() => {
        loadingStatusTimer = 0;
        if (status.textContent === "Loading") setStatus("");
      }, 4500);
    }
  };
  const hideBrowserError = () => {
    errorPane.hidden = true;
  };
  const markBrowserContentLoaded = () => {
    content.classList.add("has-loaded");
  };
  const showBrowserError = (message = "This page could not be shown inside cmux.", detail = address.value) => {
    const targetUrl = normalizeUrl(detail || address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    clearBrowserLoadTimer();
    setLoading(false);
    errorPane.querySelector(".browser-error-title").textContent = "Page did not load";
    errorPane.querySelector(".browser-error-body").textContent = message;
    errorPane.querySelector(".browser-error-url").textContent = targetUrl;
    errorPane.querySelector(".browser-error-url").title = targetUrl;
    errorPane.hidden = false;
    setStatus("");
  };
  const showDeferredBrowser = () => {
    const targetUrl = normalizeUrl(address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    setLoading(false);
    hideBrowserError();
    deferredPane.querySelector(".browser-deferred-url").textContent = targetUrl;
    deferredPane.querySelector(".browser-deferred-url").title = targetUrl;
    deferredPane.hidden = false;
    shell.classList.add("is-browser-deferred");
    setStatus("");
  };
  const scheduleInitialBrowserLoad = () => {
    if (session?.initialLoadFrame) cancelAnimationFrame(session.initialLoadFrame);
    const load = () => {
      if (!session || state.browserViews.get(panel.id) !== session || session.loadDeferred) return;
      const targetUrl = normalizeUrl(address.value || initialBrowserUrl, state.settings.browserHomeUrl);
      browserLoadFailed = false;
      hideBrowserError();
      setLoading(true);
      setStatus("Loading");
      const sourceUrl = browserViewSourceUrl(targetUrl);
      if (view.src !== sourceUrl) view.src = sourceUrl;
      updateNavState();
    };
    session.initialLoadFrame = requestAnimationFrame(() => {
      session.initialLoadFrame = 0;
      load();
    });
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

  const openPopupExternally = (event) => {
    const popupUrl = event?.url || event?.detail?.url || "";
    if (!/^https?:\/\//i.test(popupUrl)) return;
    event.preventDefault?.();
    openExternalBrowser(popupUrl);
    setStatus("Opened externally");
  };

  const navigate = () => {
    if (!findPanelState(panel.id)) return;
    const next = normalizeUrl(address.value, state.settings.browserHomeUrl);
    address.value = next;
    clearDeferredBrowserSession(session);
    view.src = browserViewSourceUrl(next);
    browserLoadFailed = false;
    hideBrowserError();
    setLoading(true);
    setStatus("Loading");
    updateActiveBrowserTabUrl(session, next);
    queueBrowserUrlSync(panel.id, next);
  };
  const handleBrowserWheel = (event) => {
    if (!event.ctrlKey) return;
    markInteractedPanel(panel.id);
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
    lockBrowserViewZoom(view);
  };
  go.onclick = navigate;
  external.onclick = () => openBrowserPanelExternally(panel);
  external.oncontextmenu = (event) => showExternalBrowserProfileMenu(event, browserPanelUrl(panel));
  tabNew.onclick = () => createBrowserTab(session, state.settings.browserHomeUrl);
  deferredPane.onclick = () => {
    focusPanel(panel.id);
    loadDeferredBrowserSession(session);
  };
  tabNew.addEventListener("dragover", (event) => {
    if (!session?.dragBrowserTabId) return;
    event.preventDefault();
    tabNew.classList.add("is-drop-before");
  });
  tabNew.addEventListener("dragleave", () => tabNew.classList.remove("is-drop-before"));
  tabNew.addEventListener("drop", (event) => {
    event.preventDefault();
    tabNew.classList.remove("is-drop-before");
    if (session?.dragBrowserTabId) moveBrowserTabToEnd(session, session.dragBrowserTabId);
  });
  errorPane.querySelector(".browser-error-retry").onclick = () => {
    hideBrowserError();
    reloadBrowserPanel(panel);
  };
  errorPane.querySelector(".browser-error-open").onclick = () => openBrowserPanelExternally(panel);
  errorPane.querySelector(".browser-error-home").onclick = () => {
    address.value = state.settings.browserHomeUrl;
    navigate();
  };
  shell.addEventListener("wheel", handleBrowserWheel, { passive: false, capture: true });
  view.addEventListener("wheel", handleBrowserWheel, { passive: false, capture: true });
  address.addEventListener("focus", () => markInteractedPanel(panel.id));
  address.addEventListener("keydown", (event) => {
    if (event.ctrlKey && event.key === "Enter") {
      event.preventDefault();
      openBrowserPanelExternally(panel);
      return;
    }
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
    setLoading(true);
    setStatus("Loading");
    if (typeof view.reload === "function") {
      view.reload();
    } else {
      view.src = browserViewSourceUrl(address.value);
    }
  };
  home.onclick = () => {
    address.value = state.settings.browserHomeUrl;
    navigate();
  };
  view.addEventListener("did-navigate", (event) => {
    if (event.url) {
      const nextUrl = browserDisplayUrl(event.url);
      address.value = nextUrl;
      updateActiveBrowserTabUrl(session, nextUrl);
      queueBrowserUrlSync(panel.id, nextUrl);
      scheduleEmbeddedGoogleHomePolish(view, event.url);
    }
    updateNavState();
  });
  view.addEventListener("page-title-updated", (event) => {
    updateActiveBrowserTabTitle(session, event.title);
  });
  view.addEventListener("new-window", openPopupExternally);
  view.addEventListener("did-create-window", openPopupExternally);
  view.addEventListener("did-attach", () => lockBrowserViewZoom(view));
  view.addEventListener("zoom-changed", (event) => {
    event.preventDefault?.();
    lockBrowserViewZoom(view);
  });
  view.addEventListener("dom-ready", () => {
    webviewReady = true;
    markBrowserContentLoaded();
    lockBrowserViewZoom(view);
    scheduleEmbeddedGoogleHomePolish(view, address.value || view.src);
    updateNavState();
  });
  view.addEventListener("did-navigate-in-page", (event) => {
    if (event.url) {
      const nextUrl = browserDisplayUrl(event.url);
      address.value = nextUrl;
      updateActiveBrowserTabUrl(session, nextUrl);
      queueBrowserUrlSync(panel.id, nextUrl);
      scheduleEmbeddedGoogleHomePolish(view, event.url);
    }
    updateNavState();
  });
  view.addEventListener("did-start-loading", () => {
    browserLoadFailed = false;
    hideBrowserError();
    setLoading(true);
    setStatus("Loading");
    updateNavState();
  });
  view.addEventListener("did-stop-loading", () => {
    setLoading(false);
    setStatus("");
    updateNavState();
  });
  view.addEventListener("did-finish-load", () => {
    markBrowserContentLoaded();
    scheduleEmbeddedGoogleHomePolish(view, address.value || view.src);
    if (!browserLoadFailed) hideBrowserError();
    setLoading(false);
    setStatus("");
    updateNavState();
  });
  view.addEventListener("did-frame-finish-load", () => {
    markBrowserContentLoaded();
    scheduleEmbeddedGoogleHomePolish(view, address.value || view.src);
    if (webviewReady) setStatus("");
  });
  view.addEventListener("did-fail-load", (event) => {
    if (event.errorCode === -3) {
      setStatus("");
      return;
    }
    if (event.isMainFrame === false) return;
    browserLoadFailed = true;
    const failure = String(event.errorDescription || "").replace(/^ERR_/i, "").replace(/_/g, " ").toLowerCase();
    const message = failure
      ? `The page reported ${failure}. Try again, open it externally, or return home.`
      : "Try again, open it externally, or return home.";
    showBrowserError(message, event.validatedURL || address.value);
    updateNavState();
  });
  view.addEventListener("load", () => {
    markBrowserContentLoaded();
    if (!browserLoadFailed) hideBrowserError();
    setLoading(false);
    setStatus("");
  });
  view.addEventListener("error", () => {
    browserLoadFailed = true;
    showBrowserError("Try again, open it externally, or return home.");
  });

  shell.append(tabStrip, bar, status, content);
  body.append(shell);
  session = {
    panelId: panel.id,
    shell,
    tabStrip,
    tabList,
    tabNew,
    tabs: tabSnapshot.tabs,
    activeTabId: tabSnapshot.activeTabId,
    tabButtons: new Map(),
    setStatus,
    setLoading,
    updateNavState,
    view,
    deferredPane,
    address,
    back,
    forward,
    reload,
    home,
    external,
    visible: true,
    active: panel.id === activeWorkspace()?.activePanelId,
    suspended: false,
    suspendInactive: state.settings.browserSuspendInactive,
    loadDeferred: false,
    initialLoadFrame: 0
  };
  session.detachTabWheelScroll = attachHorizontalWheelScroll(tabList);
  tabList.addEventListener("scroll", () => updateBrowserTabOverflow(session), { passive: true });
  if (typeof ResizeObserver === "function") {
    session.tabResizeObserver = new ResizeObserver(() => {
      scheduleActiveBrowserTabIntoView(session);
      scheduleBrowserTabOverflowRefresh(session);
    });
    session.tabResizeObserver.observe(tabList);
    session.tabResizeObserver.observe(tabStrip);
    session.tabResizeObserver.observe(shell);
  }
  state.browserViews.set(panel.id, session);
  renderBrowserTabs(session);
  const activeUrl = activeBrowserTab(session)?.url;
  if (activeUrl && activeUrl !== panel.url) queueBrowserUrlSync(panel.id, activeUrl);
  if (shouldDeferInitialBrowserLoad(panel)) {
    session.loadDeferred = true;
    showDeferredBrowser();
  } else {
    scheduleInitialBrowserLoad();
  }
  updateNavState();
}

function renderInspector() {
  if (!state.inspectorMode) {
    state.inspectorSignature = "";
    return;
  }
  if (state.inspectorMode === "notifications") {
    const signature = inspectorContentSignature();
    if (signature === state.inspectorSignature) return;
    state.inspectorSignature = signature;
    setTextIfChanged(elements.inspectorTitle, "Notifications");
    setTextIfChanged(elements.inspectorSubtitle, "Unread panes and agent attention");
    const notifications = allAttentionPanels();
    if (notifications.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "No panes need attention.";
      replaceChildrenIfChanged(elements.inspectorBody, [empty]);
      return;
    }
    replaceChildrenIfChanged(elements.inspectorBody, notifications.map(({ workspace, panel }) => {
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
    state.inspectorSignature = "settings";
    renderSettingsInspector({ ifChanged: true });
  } else {
    const signature = inspectorContentSignature();
    if (signature === state.inspectorSignature) return;
    state.inspectorSignature = signature;
    setTextIfChanged(elements.inspectorTitle, "Session");
    setTextIfChanged(elements.inspectorSubtitle, "Local Windows runtime");
    const workspace = activeWorkspace();
    const cards = [
      ["Control pipe", state.data.pipeName || "Unavailable"],
      ["Terminal shell", state.data.ptyAvailable ? "Ready" : "Compatibility mode"],
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
    replaceChildrenIfChanged(elements.inspectorBody, [...nodes, reset]);
  }
}

function inspectorContentSignature() {
  if (state.inspectorMode === "notifications") {
    return stableJson({
      mode: "notifications",
      notifications: allAttentionPanels().map(({ workspace, panel }) => ({
        workspaceId: workspace.id,
        workspaceTitle: workspace.title,
        panelId: panel.id,
        panelTitle: panel.title,
        text: panel.notificationText
      }))
    });
  }
  const workspace = activeWorkspace();
  return stableJson({
    mode: state.inspectorMode || "",
    pipeName: state.data?.pipeName || "",
    ptyAvailable: Boolean(state.data?.ptyAvailable),
    workspaceId: workspace?.id || "",
    workspaceTitle: workspace?.title || "",
    workspaceCwd: workspace?.cwd || ""
  });
}

function renderSettingsInspector(options = {}) {
  if (state.inspectorMode !== "settings") {
    state.settingsInspectorSignature = "";
    return;
  }
  elements.inspectorTitle.textContent = "Settings";
  elements.inspectorSubtitle.textContent = `${settingsCategoryLabel(state.settingsCategory)} page`;
  const resetScroll = Boolean(options.resetScroll || state.settingsScrollResetPending);
  state.settingsScrollResetPending = false;
  const signature = settingsInspectorSignature();
  if (
    options.force !== true
    && signature === state.settingsInspectorSignature
    && elements.inspectorBody.querySelector(".settings-react-host")
  ) {
    refreshPerformanceMetricsGrid();
    if (resetScroll) resetSettingsScroll();
    if (normalizeSettingsQuery(state.settingsQuery)) scheduleSettingsFilter();
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
    quickSection.append(quickSetupOverviewPanel());
    quickSection.append(quickSetupActionGrid());
    quickSection.append(paneShapePanel(workspace));
    quickSection.append(...quickColorControlRows(workspace));
    quickSection.append(settingRow(
      "Background preset",
      backgroundPresetGrid(),
      true,
      "quick setup background preset wallpaper image look customize"
    ));
    quickSection.append(activeBackgroundPanel());
    quickSection.append(quickSettingsShortcutGrid());
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
    workspaceSection.append(settingRow("Active pane", activePaneSettingsPanel(workspace), true, "active pane tab terminal browser rename color text split duplicate"));
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
    workspaceSection.append(settingRow(
      "Color",
      colorControlPanel({
        colors: workspaceColorPalette(),
        activeColor: workspace?.color,
        fallbackColor: state.settings.accent,
        onPick: (color) => setWorkspaceColor(color),
        searchTerms: "workspace custom color hex picker"
      }),
      true,
      "workspace color custom hex picker palette swatch"
    ));
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
    const appearanceActions = document.createElement("div");
    appearanceActions.className = "settings-actions appearance-actions";
    appearanceActions.dataset.settingsSearch = normalizeSettingsQuery("appearance look reset theme accent background terminal colors default");
    appearanceActions.append(
      settingsActionButton("Reset look", resetAppearanceSettings, "", "appearance look reset theme accent background terminal colors default")
    );
    appearanceSection.append(appearanceActions);
    appearanceSection.append(activeBackgroundPanel({ tuning: true }));
    appearanceSection.append(settingRow("Background preset", backgroundPresetGrid(), true));

    const imageInput = document.createElement("input");
    imageInput.className = "setting-control";
    imageInput.value = isBackgroundPreset(state.settings.backgroundImage) ? "" : state.settings.backgroundImage;
    imageInput.placeholder = "URL or C:\\path\\image.png";
    const applyImageInput = (showToast = false) => withDisabledControl(imageInput, async () => {
      const next = imageInput.value.trim();
      if (next || !isBackgroundPreset(state.settings.backgroundImage)) {
        await applyCustomBackgroundImage(next, { resetInput: imageInput, toast: showToast });
      }
    });
    imageInput.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      applyImageInput(true);
    });
    imageInput.addEventListener("blur", async () => {
      await applyImageInput();
    });
    const customImageRow = settingRow("Custom image", imageInput, true, "background image url local path file drop wallpaper");
    installBackgroundDropTarget(customImageRow, { input: imageInput });
    appearanceSection.append(customImageRow);
    const imageActions = document.createElement("div");
    imageActions.className = "settings-actions background-actions";
    imageActions.append(
      settingsActionButton("Apply image", () => applyImageInput(true), "", "background image url local path apply wallpaper"),
      settingsActionButton("Apply + save", async () => {
        const saved = await applyAndSaveCustomBackgroundImage({ url: imageInput.value }, { resetInput: imageInput });
        if (saved) imageInput.value = saved.url;
      }, "", "background image url local path apply save wallpaper"),
      settingsActionButton("Choose file", chooseBackgroundImage, "", "background image local file wallpaper"),
      settingsActionButton("Clear image", () => {
        updateSettings({ backgroundImage: "" }, { immediate: true });
        renderSettingsInspector();
      }, "danger", "background image local file wallpaper reset remove")
    );
    imageActions.dataset.settingsSearch = normalizeSettingsQuery("background image local file wallpaper apply clear");
    appearanceSection.append(imageActions);
    appearanceSection.append(settingRow("Saved backgrounds", savedBackgroundImagesPanel(), true, "saved background image wallpaper library apply rename delete save"));

    nodes.push(appearanceSection);
  }

  if (shouldBuildSection("browser")) {
    const browserSection = settingsSection("Browser");
    browserSection.append(browserSettingsPreviewPanel());
    const homeInput = document.createElement("input");
    homeInput.className = "setting-control";
    homeInput.dataset.settingControl = "browserHomeUrl";
    homeInput.value = state.settings.browserHomeUrl;
    homeInput.placeholder = "https://www.google.com";
    homeInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") homeInput.blur();
    });
    homeInput.addEventListener("blur", () => {
      updateSettings({ browserHomeUrl: homeInput.value || defaultSettings.browserHomeUrl });
      homeInput.value = state.settings.browserHomeUrl;
    });
    browserSection.append(settingRow("Home page", homeInput, true));
    browserSection.append(settingRow("Home presets", browserHomePresetGrid(), true, "browser home preset quick start localhost github google vite"));
    const launchModeSelect = document.createElement("select");
    launchModeSelect.className = "setting-select";
    launchModeSelect.dataset.settingControl = "browserLaunchMode";
    for (const [value, label] of browserLaunchModeOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      launchModeSelect.append(option);
    }
    launchModeSelect.value = state.settings.browserLaunchMode;
    launchModeSelect.onchange = () => updateSettings({ browserLaunchMode: launchModeSelect.value });
    browserSection.append(settingRow("Open Browser action", launchModeSelect, false, "browser open button web pane external chrome edge brave profile launch mode"));
    const profileSelect = document.createElement("select");
    profileSelect.className = "setting-select";
    profileSelect.dataset.settingControl = "externalBrowserProfileId";
    const profiles = browserProfileOptions();
    for (const profile of profiles) {
      const option = document.createElement("option");
      option.value = profile.id;
      option.textContent = profile.label;
      profileSelect.append(option);
    }
    profileSelect.value = profiles.some((profile) => profile.id === state.settings.externalBrowserProfileId)
      ? state.settings.externalBrowserProfileId
      : "system";
    profileSelect.onchange = () => updateSettings({ externalBrowserProfileId: profileSelect.value });
    browserSection.append(settingRow("Open external in", profileSelect, false, "browser chrome edge brave profile system external open"));
    browserSection.append(settingRow(
      "Suspend inactive panes",
      toggleInput(state.settings.browserSuspendInactive, (checked) => updateSettings({ browserSuspendInactive: checked })),
      false,
      "browser performance suspend inactive background webview mute loading lag"
    ));
    const homeActions = document.createElement("div");
    homeActions.className = "settings-actions";
    homeActions.dataset.settingsSearch = normalizeSettingsQuery("browser home open reset default url page web system external profile chrome edge brave");
    homeActions.append(
      settingsActionButton("Open pane", () => createPanel("browser", "right", { url: state.settings.browserHomeUrl })),
      settingsActionButton("Open external", () => openExternalBrowser(state.settings.browserHomeUrl, { toast: true }), "", "browser system chrome edge brave profile external"),
      settingsActionButton("Refresh profiles", () => refreshBrowserProfiles({ render: true }), "", "browser chrome edge brave profile detect refresh reload"),
      settingsActionButton("Reset", () => {
        const changed = updateSettings({ browserHomeUrl: defaultSettings.browserHomeUrl });
        if (!changed) toast("Browser home already uses the default.");
      })
    );
    browserSection.append(homeActions);
    browserSection.append(recentBrowserPagesSettings());
    nodes.push(browserSection);
  }

  if (shouldBuildSection("layout")) {
    const layoutSection = settingsSection("Layout");
    layoutSection.append(layoutSettingsPreviewPanel());
    layoutSection.append(settingRow(
      "Focus mode",
      toggleInput(state.settings.focusMode, (checked) => toggleFocusMode(checked, { toast: false })),
      false,
      "focus mode simple workspace zen clean hide sidebar tabs status pane header reduce clutter"
    ));
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
    const paneActionSelect = document.createElement("select");
    paneActionSelect.className = "setting-select";
    for (const [value, label] of paneActionOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      paneActionSelect.append(option);
    }
    paneActionSelect.value = state.settings.paneActionMode;
    paneActionSelect.onchange = () => updateSettings({ paneActionMode: paneActionSelect.value });
    layoutSection.append(settingRow("Pane controls", paneActionSelect, false, "pane controls buttons actions clean split full toolbar clutter"));
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
    bindDeferredSettingRange(sidebarWidthRange, sidebarWidthRow, {
      settingKey: "sidebarWidth",
      formatLabel: (value) => `Sidebar ${value}px`,
      preview: (value) => elements.shell.style.setProperty("--sidebar-width", `${value}px`)
    });
    layoutSection.append(sidebarWidthRow);
    const inspectorWidthRange = document.createElement("input");
    inspectorWidthRange.className = "setting-control";
    inspectorWidthRange.type = "range";
    inspectorWidthRange.min = "300";
    inspectorWidthRange.max = "480";
    inspectorWidthRange.step = "4";
    inspectorWidthRange.value = String(state.settings.inspectorWidth);
    const inspectorWidthRow = settingRow(`Settings panel ${state.settings.inspectorWidth}px`, inspectorWidthRange, false, "settings inspector right panel width preferences customization");
    bindDeferredSettingRange(inspectorWidthRange, inspectorWidthRow, {
      settingKey: "inspectorWidth",
      formatLabel: (value) => `Settings panel ${value}px`,
      preview: (value) => elements.shell.style.setProperty("--inspector-width", `${value}px`)
    });
    layoutSection.append(inspectorWidthRow);
    layoutSection.append(paneShapePanel(workspace));
    const layoutActions = document.createElement("div");
    layoutActions.className = "settings-actions";
    layoutActions.dataset.settingsSearch = normalizeSettingsQuery("split layout pane splitter resize reset equal workspace chrome toolbar sidebar footer inspector tabs status header title focus mode simple clean");
    layoutActions.append(
      settingsActionButton(state.settings.focusMode ? "Leave focus" : "Focus mode", () => toggleFocusMode(), "", "focus mode simple clean hide chrome"),
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
    const performanceMetricGrid = settingsMetricGrid(performanceMetrics());
    performanceMetricGrid.dataset.performanceMetrics = "true";
    performanceSection.append(performanceMetricGrid);
    performanceSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked })), false, "speed smooth lag effects reduce animation"));
    performanceSection.append(settingRow("Adaptive guard", toggleInput(state.settings.adaptivePerformance, (checked) => updateSettings({ adaptivePerformance: checked })), false, "adaptive automatic performance guard lag slow output tune"));
    performanceSection.append(settingRow("Reduce motion", toggleInput(state.settings.reduceMotion, (checked) => updateSettings({ reduceMotion: checked })), false, "motion animation transition smooth reduce accessibility"));
    performanceSection.append(settingRow("Pause inactive output", toggleInput(state.settings.terminalPauseInactiveOutput, (checked) => updateSettings({ terminalPauseInactiveOutput: checked })), false, "terminal output pause inactive hidden background lag smooth performance"));
    const scrollbackRange = document.createElement("input");
    scrollbackRange.className = "setting-control";
    scrollbackRange.type = "range";
    scrollbackRange.min = "2000";
    scrollbackRange.max = "50000";
    scrollbackRange.step = "2000";
    scrollbackRange.value = String(state.settings.terminalScrollback);
    const scrollbackRow = settingRow(`History ${state.settings.terminalScrollback}`, scrollbackRange, false, "terminal history scrollback memory output performance");
    bindDeferredSettingRange(scrollbackRange, scrollbackRow, {
      settingKey: "terminalScrollback",
      formatLabel: (value) => `History ${value}`
    });
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
    actionsSection.append(settingsActionsOverviewPanel());
    actionsSection.append(settingsCommandGroupShortcutGrid());
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
    fontRange.min = String(terminalFontSizeMin);
    fontRange.max = String(terminalFontSizeMax);
    fontRange.value = String(state.settings.terminalFontSize);
    const fontRow = settingRow(`Default text size ${state.settings.terminalFontSize}px`, fontRange);
    bindDeferredSettingRange(fontRange, fontRow, {
      settingKey: "terminalFontSize",
      formatLabel: (value) => `Default text size ${value}px`
    });
    terminalSection.append(fontRow);
    const lineHeightRange = document.createElement("input");
    lineHeightRange.className = "setting-control";
    lineHeightRange.type = "range";
    lineHeightRange.min = "1";
    lineHeightRange.max = "1.5";
    lineHeightRange.step = "0.02";
    lineHeightRange.value = String(state.settings.terminalLineHeight);
    const lineHeightRow = settingRow(`Line height ${formatLineHeight(state.settings.terminalLineHeight)}`, lineHeightRange);
    bindDeferredSettingRange(lineHeightRange, lineHeightRow, {
      settingKey: "terminalLineHeight",
      formatLabel: (value) => `Line height ${formatLineHeight(value)}`
    });
    terminalSection.append(lineHeightRow);
    const paddingRange = document.createElement("input");
    paddingRange.className = "setting-control";
    paddingRange.type = "range";
    paddingRange.min = "0";
    paddingRange.max = "16";
    paddingRange.value = String(state.settings.terminalPadding);
    const paddingRow = settingRow(`Padding ${state.settings.terminalPadding}px`, paddingRange);
    bindDeferredSettingRange(paddingRange, paddingRow, {
      settingKey: "terminalPadding",
      formatLabel: (value) => `Padding ${value}px`,
      preview: (value) => elements.shell.style.setProperty("--terminal-padding", `${value}px`)
    });
    terminalSection.append(paddingRow);
    const scrollbackRange = document.createElement("input");
    scrollbackRange.className = "setting-control";
    scrollbackRange.type = "range";
    scrollbackRange.min = "2000";
    scrollbackRange.max = "50000";
    scrollbackRange.step = "2000";
    scrollbackRange.value = String(state.settings.terminalScrollback);
    const scrollbackRow = settingRow(`Scrollback ${state.settings.terminalScrollback}`, scrollbackRange);
    bindDeferredSettingRange(scrollbackRange, scrollbackRow, {
      settingKey: "terminalScrollback",
      formatLabel: (value) => `Scrollback ${value}`
    });
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
    actionsSection.append(dataSettingsOverviewPanel());
    actionsSection.append(settingsMetricGrid(settingsDataMetrics(), "data storage local settings metric"));
    actionsSection.append(dataStorageBreakdownPanel());
    const actions = document.createElement("div");
    actions.className = "settings-actions";
    const clearRecent = settingsActionButton("Clear recent activity", clearRecentActivity, "danger", "clear recent activity folders commands browser pages tabs history");
    clearRecent.disabled = !hasRecentActivity();
    const closeEmpty = settingsActionButton("Close empty workspaces", closeEmptyWorkspaces, "danger", "workspace cleanup empty duplicate close remove");
    closeEmpty.disabled = !hasEmptyWorkspaceCleanupTargets();
    actions.append(
      settingsActionButton("Export", exportSettings),
      settingsActionButton("Import", importSettings),
      closeEmpty,
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
  state.settingsSearchIndex = buildSettingsSearchIndex();
  if (resetScroll) resetSettingsScroll();
  renderSettingsChrome(settingsChrome);
  if (searching) scheduleSettingsFilter();
}

function resetSettingsScroll() {
  elements.inspectorBody.scrollTop = 0;
}

function queueSettingsSearchAutoScroll() {
  state.settingsSearchAutoScrollQuery = normalizeSettingsQuery(state.settingsQuery);
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
  if (searching || ["layout", "data", "actions"].includes(category)) {
    parts.push(stableJson(Object.fromEntries(state.paneLayouts)), stableJson(Object.fromEntries(state.paneTrees)));
  }
  if (searching || category === "quick") {
    parts.push(quickSettingsSignature());
  }
  if (searching || ["appearance", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.customColorPalette), stableJson(state.savedBackgroundImages));
  }
  if (searching || ["browser", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.recentBrowserPages), stableJson(Object.fromEntries(state.browserTabSnapshots)));
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
    paneTree: state.paneTrees.get(workspace.id) || null,
    paneLayouts: workspace.panels.map((panel) => [panel.id, state.paneLayouts.get(panel.id) || null]),
    panels: workspace.panels.map((panel) => ({
      id: panel.id,
      type: panel.type,
      title: panel.title,
      titleLocked: Boolean(panel.titleLocked),
      color: panel.color,
      cwd: panel.cwd,
      cwdShort: panel.cwdShort,
      shellProfile: panel.shellProfile,
      shellPath: panel.shellPath,
      terminalFontSize: panel.terminalFontSize || 0,
      url: panel.url
    }))
  });
}

function quickSettingsSignature() {
  const panels = allPanels();
  return stableJson({
    workspace: activeWorkspaceSettingsSignature(),
    workspaces: state.data?.workspaces?.length || 0,
    panes: panels.length,
    recentFolders: state.recentFolders.length,
    recentCommands: state.recentCommands.length,
    recentBrowserPages: state.recentBrowserPages.length,
    browserTabs: browserTabSnapshotCount(),
    commandSnippets: state.customCommandSnippets.length,
    profiles: state.savedSettingsProfiles.length,
    blueprints: state.workspaceBlueprints.length,
    colors: state.customColorPalette.length,
    backgrounds: state.savedBackgroundImages.length,
    performanceGuardTriggered: state.performanceGuardTriggered
  });
}

function stableJson(value) {
  try {
    return JSON.stringify(value ?? null);
  } catch {
    return "";
  }
}

function shouldRefreshLayoutSettings() {
  return state.inspectorMode === "settings"
    && (
      state.settingsCategory === "layout"
      || state.settingsCategory === "quick"
      || Boolean(normalizeSettingsQuery(state.settingsQuery))
    );
}

function refreshLayoutSettings(options = {}) {
  if (shouldRefreshLayoutSettings()) renderSettingsInspector(options);
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
    labels: {
      searchPlaceholder: t("settings.searchPlaceholder"),
      clearSearch: t("settings.clearSearch"),
      pageLabel: t("settings.pageLabel"),
      pageAriaLabel: t("settings.pageAriaLabel"),
      pagesAriaLabel: t("settings.pagesAriaLabel"),
      tabTitle: formatMessage("settings.tabTitle", { label: "{label}" })
    },
    onCategory: (category) => {
      state.settingsCategory = category;
      state.settingsQuery = "";
      renderSettingsInspector({ resetScroll: true });
    },
    onQuery: (query) => {
      const wasSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      state.settingsQuery = query;
      const isSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      if (isSearching) queueSettingsSearchAutoScroll();
      if (wasSearching !== isSearching) {
        renderSettingsInspector({ resetScroll: true });
        scheduleSettingsSearchFocus();
      } else {
        renderSettingsChrome(host);
        scheduleSettingsFilter();
      }
    },
    onClear: () => {
      state.settingsQuery = "";
      renderSettingsInspector({ resetScroll: true });
      scheduleSettingsSearchFocus();
    }
  });
}

function settingsSearch() {
  const wrapper = document.createElement("div");
  wrapper.className = `settings-search${state.settingsQuery ? " has-query" : ""}`;
  const input = document.createElement("input");
  input.className = "setting-control settings-search-input";
  input.type = "search";
  input.placeholder = t("settings.searchPlaceholder");
  input.setAttribute("aria-label", t("settings.searchPlaceholder"));
  input.value = state.settingsQuery;
  input.addEventListener("input", () => {
    const wasSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
    state.settingsQuery = input.value;
    wrapper.classList.toggle("has-query", Boolean(state.settingsQuery));
    clear.disabled = !state.settingsQuery;
    const isSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
    if (isSearching) queueSettingsSearchAutoScroll();
    if (wasSearching !== isSearching) {
      renderSettingsInspector({ resetScroll: true });
      restoreSettingsSearchFocus();
      return;
    }
    scheduleSettingsFilter();
  });
  const clear = document.createElement("button");
  clear.className = "settings-search-clear";
  clear.type = "button";
  clear.title = t("settings.clearSearch");
  clear.setAttribute("aria-label", t("settings.clearSearch"));
  clear.textContent = "×";
  clear.disabled = !state.settingsQuery;
  clear.onclick = () => {
    state.settingsQuery = "";
    renderSettingsInspector({ resetScroll: true });
    restoreSettingsSearchFocus();
  };
  wrapper.append(input, clear);
  return wrapper;
}

function restoreSettingsSearchFocus() {
  const input = elements.inspectorBody.querySelector(".settings-search-input");
  if (!input) return;
  input.focus({ preventScroll: true });
  input.setSelectionRange(input.value.length, input.value.length);
}

function cancelSettingsSearchFocus() {
  if (!state.settingsSearchFocusFrame) return;
  cancelAnimationFrame(state.settingsSearchFocusFrame);
  state.settingsSearchFocusFrame = 0;
}

function scheduleSettingsSearchFocus() {
  cancelSettingsSearchFocus();
  state.settingsSearchFocusFrame = requestAnimationFrame(() => {
    state.settingsSearchFocusFrame = 0;
    if (state.inspectorMode !== "settings") return;
    restoreSettingsSearchFocus();
  });
}

function settingsCategoryNav() {
  const nav = document.createElement("div");
  nav.className = "settings-page-switcher";
  const head = document.createElement("div");
  head.className = "settings-page-head";
  const labelText = document.createElement("span");
  labelText.className = "settings-page-label";
  labelText.textContent = t("settings.pageLabel");
  const select = document.createElement("select");
  select.className = "setting-select settings-page-select";
  select.setAttribute("aria-label", t("settings.pageAriaLabel"));
  for (const [id, label] of settingsCategories) {
    const option = document.createElement("option");
    option.value = id;
    option.textContent = label;
    select.append(option);
  }
  select.value = state.settingsCategory;
  select.onchange = () => {
    state.settingsCategory = select.value;
    state.settingsQuery = "";
    renderSettingsInspector({ resetScroll: true });
  };
  head.append(labelText, select);

  const tabs = document.createElement("div");
  tabs.className = "settings-page-tabs";
  tabs.setAttribute("role", "tablist");
  tabs.setAttribute("aria-label", t("settings.pagesAriaLabel"));
  for (const [id, label] of settingsCategories) {
    const button = document.createElement("button");
    const active = id === state.settingsCategory;
    button.className = `settings-page-tab${active ? " is-active" : ""}`;
    button.type = "button";
    button.textContent = label;
    button.title = formatMessage("settings.tabTitle", { label });
    button.dataset.settingsCategory = id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`settings page ${label} ${id} ${settingsCategorySearchAliases.get(id) || ""}`);
    button.setAttribute("role", "tab");
    button.setAttribute("aria-selected", active ? "true" : "false");
    button.onclick = () => {
      if (state.settingsCategory === id && !state.settingsQuery) return;
      state.settingsCategory = id;
      state.settingsQuery = "";
      renderSettingsInspector({ resetScroll: true });
    };
    tabs.append(button);
    if (active) {
      requestAnimationFrame(() => button.scrollIntoView({ block: "nearest", inline: "nearest" }));
    }
  }
  attachHorizontalWheelScroll(tabs);
  nav.append(head, tabs);
  return nav;
}

function settingsCategoryLabel(id) {
  return settingsCategories.find(([categoryId]) => categoryId === id)?.[1] || t("config.settingsCategory.quick");
}

function optionLabel(options, value, fallback = "") {
  return options.find(([id]) => id === value)?.[1] || fallback || String(value || "");
}

function appearanceBackgroundLabel(value) {
  const normalized = normalizeBackgroundValue(value);
  if (!normalized) return t("config.background.none");
  const preset = backgroundPresetMap.get(normalized);
  const label = preset ? preset.label : defaultBackgroundLabel(normalized);
  const fit = optionLabel(backgroundFitOptions, state.settings.backgroundFit, t("config.backgroundFit.cover"));
  const effects = optionLabel(backgroundEffectsOptions, state.settings.backgroundEffects, t("config.backgroundEffects.flat"));
  return `${label} / ${fit} / ${effects}`;
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
    backgroundImage: backgroundCss(state.settings.backgroundImage),
    backgroundSize: backgroundSizeCss(state.settings.backgroundFit),
    backgroundRepeat: backgroundRepeatCss(state.settings.backgroundImage),
    backgroundPosition: backgroundPositionCss(state.settings.backgroundPosition)
  });
  preview.dataset.settingsSearch = normalizeSettingsQuery("appearance visual preview theme gallery accent background image strength terminal colors font");
  return preview;
}

function backgroundTuningSelect(label, settingKey, options, onCommit) {
  const row = document.createElement("label");
  row.className = "background-tuning-row";
  const text = document.createElement("span");
  text.className = "setting-label";
  text.textContent = label;
  const select = document.createElement("select");
  select.className = "setting-select";
  select.dataset.settingControl = settingKey;
  for (const [value, optionLabelText] of options) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = optionLabelText;
    select.append(option);
  }
  select.value = state.settings[settingKey];
  select.onchange = () => {
    updateSettings({ [settingKey]: select.value });
    onCommit?.();
  };
  row.append(text, select);
  return row;
}

function backgroundTuningPanel(onCommit = null) {
  const panel = document.createElement("div");
  panel.className = "background-tuning-panel";
  panel.dataset.settingsSearch = normalizeSettingsQuery("background image fit position effects opacity strength wallpaper transparency tune");

  const controls = document.createElement("div");
  controls.className = "background-tuning-grid";
  controls.append(
    backgroundTuningSelect("Fit", "backgroundFit", backgroundFitOptions, onCommit),
    backgroundTuningSelect("Position", "backgroundPosition", backgroundPositionOptions, onCommit),
    backgroundTuningSelect("Effects", "backgroundEffects", backgroundEffectsOptions, onCommit)
  );

  const opacityInput = document.createElement("input");
  opacityInput.className = "setting-control";
  opacityInput.type = "range";
  opacityInput.min = "0";
  opacityInput.max = "42";
  opacityInput.value = String(state.settings.backgroundOpacity);
  const opacityRow = document.createElement("label");
  opacityRow.className = "background-tuning-row background-tuning-row-wide";
  const opacityLabel = document.createElement("span");
  opacityLabel.className = "setting-label";
  opacityLabel.textContent = `Strength ${state.settings.backgroundOpacity}%`;
  opacityRow.append(opacityLabel, opacityInput);
  bindDeferredSettingRange(opacityInput, opacityRow, {
    settingKey: "backgroundOpacity",
    formatLabel: (value) => `Strength ${value}%`,
    preview: (value) => elements.shell.style.setProperty("--background-opacity", String(value / 100))
  });

  panel.append(controls, opacityRow);
  return panel;
}

function activeBackgroundPanel(options = {}) {
  const panel = document.createElement("div");
  const background = state.settings.backgroundImage;
  const normalized = normalizeBackgroundValue(background);
  const hasBackground = Boolean(normalized);
  const preset = backgroundPresetMap.get(normalized);
  const filePath = backgroundFilePath(background);
  const label = hasBackground ? appearanceBackgroundLabel(background) : "None";
  const source = !hasBackground
    ? "No image is applied."
    : preset
      ? "Built-in preset"
      : filePath || normalized;
  panel.className = `active-background-panel${hasBackground ? " has-image" : ""}`;
  panel.dataset.activeBackgroundTuning = options.tuning ? "true" : "false";
  panel.dataset.settingsSearch = normalizeSettingsQuery("active background image wallpaper current preview source choose save open clear fit position effects opacity strength transparency tune");
  panel.style.setProperty("--active-background-image", backgroundCss(background));
  panel.style.setProperty("--active-background-repeat", backgroundRepeatCss(background));
  panel.style.setProperty("--active-background-size", backgroundSizeCss(state.settings.backgroundFit));
  panel.style.setProperty("--active-background-position", backgroundPositionCss(state.settings.backgroundPosition));
  panel.innerHTML = `
    <button class="active-background-preview" type="button" title="Choose background image"></button>
    <span class="active-background-copy">
      <span class="active-background-kicker">Active background</span>
      <span class="active-background-title"></span>
      <span class="active-background-source"></span>
    </span>
    <span class="active-background-actions"></span>
  `;
  installBackgroundDropTarget(panel);
  panel.querySelector(".active-background-preview").onclick = () => chooseBackgroundImage();
  panel.querySelector(".active-background-title").textContent = label;
  panel.querySelector(".active-background-title").title = label;
  panel.querySelector(".active-background-source").textContent = source;
  panel.querySelector(".active-background-source").title = source;
  const actions = panel.querySelector(".active-background-actions");
  const save = settingsActionButton("Save", () => saveCustomBackgroundImage({ url: state.settings.backgroundImage }), "", "active background save current");
  save.disabled = !isCustomBackgroundImage(state.settings.backgroundImage);
  const open = settingsActionButton("Open", () => openBackgroundImageSource(), "", "active background open local file url source reveal");
  open.disabled = !canOpenBackgroundImageSource(state.settings.backgroundImage);
  const clear = settingsActionButton("Clear", () => {
    const changed = updateSettings({ backgroundImage: "" }, { immediate: true });
    if (changed) renderSettingsInspector();
  }, "danger", "active background clear remove reset");
  clear.disabled = !hasBackground;
  actions.append(
    settingsActionButton("Choose", () => chooseBackgroundImage(), "", "active background choose local file"),
    save,
    open,
    clear
  );
  if (options.tuning) {
    const refreshBackgroundSummary = () => {
      const title = appearanceBackgroundLabel(state.settings.backgroundImage);
      panel.style.setProperty("--active-background-size", backgroundSizeCss(state.settings.backgroundFit));
      panel.style.setProperty("--active-background-position", backgroundPositionCss(state.settings.backgroundPosition));
      panel.querySelector(".active-background-title").textContent = title;
      panel.querySelector(".active-background-title").title = title;
    };
    panel.append(backgroundTuningPanel(refreshBackgroundSummary));
  }
  return panel;
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
  for (const activeBackground of elements.inspectorBody.querySelectorAll(".active-background-panel")) {
    activeBackground.replaceWith(activeBackgroundPanel({
      tuning: activeBackground.dataset.activeBackgroundTuning === "true"
    }));
  }
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
    `pane-actions-${settings.paneActionMode}`,
    `toolbar-${settings.toolbarMode}`,
    `tab-size-${settings.tabSize}`,
    settings.focusMode ? "focus-mode" : "",
    settings.showTabs ? "show-tabs" : "hide-tabs",
    settings.showStatusbar ? "show-statusbar" : "hide-statusbar",
    settings.performanceMode ? "performance-preview" : ""
  ].filter(Boolean).join(" ");
  panel.dataset.settingsSearch = normalizeSettingsQuery("layout preview workspace chrome sidebar toolbar tabs status pane header density settings panel active pane percent resize focus mode simple clean");
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
      <span><b>Mode</b><em data-layout-preview-mode></em></span>
      <span><b>Tabs</b><em data-layout-preview-tabs></em></span>
      <span><b>Header</b><em data-layout-preview-header></em></span>
      <span><b>Controls</b><em data-layout-preview-actions></em></span>
      <span><b>Sidebar</b><em data-layout-preview-sidebar></em></span>
      <span><b>Settings</b><em data-layout-preview-settings></em></span>
      <span><b>Status</b><em data-layout-preview-status></em></span>
      <span><b>Active pane</b><em data-layout-preview-active-pane></em></span>
    </div>
  `;
  panel.querySelector("[data-layout-preview-toolbar]").textContent = optionLabel(toolbarModeOptions, settings.toolbarMode, settings.toolbarMode);
  panel.querySelector("[data-layout-preview-mode]").textContent = settings.focusMode ? "Focus" : "Standard";
  panel.querySelector("[data-layout-preview-tabs]").textContent = settings.focusMode || !settings.showTabs ? "Hidden" : optionLabel(tabSizeOptions, settings.tabSize, settings.tabSize);
  panel.querySelector("[data-layout-preview-header]").textContent = settings.focusMode ? "Hidden" : optionLabel(paneHeaderOptions, settings.paneHeaderMode, settings.paneHeaderMode);
  panel.querySelector("[data-layout-preview-actions]").textContent = optionLabel(paneActionOptions, settings.paneActionMode, settings.paneActionMode);
  panel.querySelector("[data-layout-preview-sidebar]").textContent = settings.focusMode ? "Hidden" : `${settings.sidebarWidth}px`;
  panel.querySelector("[data-layout-preview-settings]").textContent = `${settings.inspectorWidth}px`;
  panel.querySelector("[data-layout-preview-status]").textContent = settings.focusMode || !settings.showStatusbar ? "Off" : "On";
  const workspace = activeWorkspace();
  panel.querySelector("[data-layout-preview-active-pane]").textContent = workspace?.panels?.length > 1 ? `${activePaneLayoutPercent(workspace)}%` : "Single";
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

function browserHomeKey(value) {
  return normalizeBrowserPageUrl(value).toLowerCase();
}

function browserHomeParts(value) {
  const url = normalizeUrl(value || defaultSettings.browserHomeUrl, defaultSettings.browserHomeUrl);
  try {
    const parsed = new URL(url);
    const path = `${parsed.pathname}${parsed.search}` || "/";
    return {
      url,
      host: parsed.hostname || "Browser",
      path: path === "/" ? "Home page" : path
    };
  } catch {
    return {
      url: defaultSettings.browserHomeUrl,
      host: hostnameOf(defaultSettings.browserHomeUrl),
      path: "Home page"
    };
  }
}

function browserSettingsPreviewPanel() {
  const home = browserHomeParts(state.settings.browserHomeUrl);
  const recent = state.recentBrowserPages[0] ? browserHomeParts(state.recentBrowserPages[0]) : null;
  const panel = document.createElement("div");
  panel.className = "browser-settings-preview";
  panel.dataset.settingsSearch = normalizeSettingsQuery("browser preview home url web page hostname recent history preset localhost github");
  panel.innerHTML = `
    <div class="browser-preview-frame" aria-hidden="true">
      <div class="browser-preview-address">
        <span data-browser-preview-host></span>
        <span data-browser-preview-url></span>
      </div>
      <div class="browser-preview-page">
        <span class="browser-preview-kicker">cmux browser</span>
        <span class="browser-preview-title"></span>
        <span class="browser-preview-line"></span>
        <span class="browser-preview-line short"></span>
      </div>
    </div>
    <div class="browser-preview-meta">
      <span><b>Home</b><em data-browser-preview-home></em></span>
      <span><b>Launch</b><em data-browser-preview-launch></em></span>
      <span><b>Host</b><em data-browser-preview-host-meta></em></span>
      <span><b>Recent</b><em data-browser-preview-recent></em></span>
    </div>
  `;
  panel.querySelector("[data-browser-preview-host]").textContent = home.host;
  panel.querySelector("[data-browser-preview-url]").textContent = home.url;
  panel.querySelector(".browser-preview-title").textContent = home.path;
  panel.querySelector("[data-browser-preview-home]").textContent = home.url;
  panel.querySelector("[data-browser-preview-launch]").textContent = optionLabel(browserLaunchModeOptions, state.settings.browserLaunchMode, "cmux pane");
  panel.querySelector("[data-browser-preview-host-meta]").textContent = home.host;
  panel.querySelector("[data-browser-preview-recent]").textContent = recent
    ? `${state.recentBrowserPages.length} / ${recent.host}`
    : "None";
  return panel;
}

function isActiveBrowserHomePreset(preset) {
  return browserHomeKey(preset.url) === browserHomeKey(state.settings.browserHomeUrl);
}

function browserHomePresetGrid() {
  const grid = document.createElement("div");
  grid.className = "browser-home-preset-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("browser home preset quick start google github localhost vite web url");
  for (const preset of browserHomePresets) {
    const active = isActiveBrowserHomePreset(preset);
    const button = document.createElement("button");
    button.className = `browser-home-preset${active ? " is-active" : ""}`;
    button.type = "button";
    button.title = preset.url;
    button.dataset.browserHomePreset = preset.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`browser home preset ${preset.label} ${preset.body} ${preset.url}`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.innerHTML = `
      <span class="browser-home-preset-title"></span>
      <span class="browser-home-preset-body"></span>
      <span class="browser-home-preset-url"></span>
    `;
    button.querySelector(".browser-home-preset-title").textContent = preset.label;
    button.querySelector(".browser-home-preset-body").textContent = preset.body;
    button.querySelector(".browser-home-preset-url").textContent = preset.url;
    button.onclick = () => applyBrowserHomePreset(preset);
    grid.append(button);
  }
  return grid;
}

function applyBrowserHomePreset(preset, options = {}) {
  const changed = updateSettings({ browserHomeUrl: preset.url });
  if (!changed) {
    if (options.toast !== false) toast(`${preset.label} is already the browser home.`);
    return;
  }
  if (state.inspectorMode === "settings" && state.settingsCategory === "browser") renderSettingsInspector();
  if (options.toast !== false) toast(`${preset.label} browser home applied.`);
}

function scheduleBrowserSettingsPreviewRefresh() {
  if (state.browserSettingsPreviewFrame) return;
  state.browserSettingsPreviewFrame = requestAnimationFrame(() => {
    state.browserSettingsPreviewFrame = 0;
    refreshBrowserSettingsPreview();
  });
}

function refreshBrowserSettingsPreview() {
  const preview = elements.inspectorBody.querySelector(".browser-settings-preview");
  if (preview) preview.replaceWith(browserSettingsPreviewPanel());
  const homeInput = elements.inspectorBody.querySelector('[data-setting-control="browserHomeUrl"]');
  if (homeInput && homeInput.value !== state.settings.browserHomeUrl) {
    homeInput.value = state.settings.browserHomeUrl;
  }
  const launchModeSelect = elements.inspectorBody.querySelector('[data-setting-control="browserLaunchMode"]');
  if (launchModeSelect && launchModeSelect.value !== state.settings.browserLaunchMode) {
    launchModeSelect.value = state.settings.browserLaunchMode;
  }
  for (const button of elements.inspectorBody.querySelectorAll("[data-browser-home-preset]")) {
    const preset = browserHomePresets.find((candidate) => candidate.id === button.dataset.browserHomePreset);
    const active = Boolean(preset && isActiveBrowserHomePreset(preset));
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
  }
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

function activePaneSettingsPanel(workspace = activeWorkspace()) {
  const panel = workspace?.panels.find((candidate) => candidate.id === workspace.activePanelId)
    || focusedPanel()
    || workspace?.panels[0]
    || null;
  const wrapper = document.createElement("div");
  wrapper.className = "active-pane-panel";
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("active pane tab terminal browser rename color text size split duplicate focus controls");
  if (!panel) {
    wrapper.innerHTML = `<div class="active-pane-empty">Open a terminal or browser pane to customize it here.</div>`;
    return wrapper;
  }

  const typeLabel = panel.type === "browser" ? "Browser" : "Terminal";
  const title = panelDisplayTitle(panel, false);
  const meta = panel.type === "browser"
    ? browserPanelUrl(panel) || panel.url || state.settings.browserHomeUrl
    : `${panel.cwdShort || workspace?.cwdShort || "~"} / ${optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell")}`;
  const summary = document.createElement("div");
  summary.className = "active-pane-summary";
  summary.innerHTML = `
    <span class="active-pane-color"></span>
    <span class="active-pane-copy">
      <span class="active-pane-kind"></span>
      <span class="active-pane-title"></span>
      <span class="active-pane-meta"></span>
    </span>
  `;
  summary.style.setProperty("--active-pane-color", panel.color || workspace?.color || state.settings.accent);
  summary.querySelector(".active-pane-kind").textContent = typeLabel;
  summary.querySelector(".active-pane-title").textContent = title;
  summary.querySelector(".active-pane-title").title = title;
  summary.querySelector(".active-pane-meta").textContent = meta;
  summary.querySelector(".active-pane-meta").title = meta;
  wrapper.append(summary);

  const titleInput = document.createElement("input");
  titleInput.className = "setting-control";
  titleInput.value = panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal");
  titleInput.placeholder = "Pane name";
  titleInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") titleInput.blur();
  });
  titleInput.addEventListener("blur", () => {
    const nextTitle = titleInput.value.trim();
    if (!nextTitle) {
      titleInput.value = panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal");
      return;
    }
    if (nextTitle !== panel.title) updatePanel(panel.id, { title: nextTitle });
  });
  wrapper.append(settingRow("Pane name", titleInput, false, "active pane rename tab title"));

  wrapper.append(settingRow(
    "Pane color",
    colorControlPanel({
      colors: workspaceColorPalette(),
      activeColor: panel.color || workspace?.color,
      fallbackColor: workspace?.color || state.settings.accent,
      onPick: (color) => updatePanel(panel.id, { color }),
      onClear: () => updatePanel(panel.id, { color: "" }),
      clearLabel: "Default",
      clearDisabled: !panel.color,
      searchTerms: "active pane custom color hex picker reset default clear"
    }),
    true,
    "active pane color tab custom hex picker palette swatch reset default clear"
  ));

  if (panel.type === "terminal") {
    const paneFontSize = terminalFontSizeForPanel(panel);
    const updatePaneTextLabel = (row, size) => {
      setTextIfChanged(row.querySelector(".setting-label"), `Pane text ${size || terminalFontSizeForPanel(panel)}px`);
    };
    const fontRange = document.createElement("input");
    fontRange.className = "setting-control";
    fontRange.type = "range";
    fontRange.min = String(terminalFontSizeMin);
    fontRange.max = String(terminalFontSizeMax);
    fontRange.value = String(paneFontSize);
    fontRange.dataset.activePaneTextRange = panel.id;
    const fontNumber = document.createElement("input");
    fontNumber.className = "setting-control active-pane-text-number";
    fontNumber.type = "number";
    fontNumber.inputMode = "numeric";
    fontNumber.min = String(terminalFontSizeMin);
    fontNumber.max = String(terminalFontSizeMax);
    fontNumber.step = "1";
    fontNumber.value = String(paneFontSize);
    fontNumber.dataset.activePaneTextNumber = panel.id;
    const resetText = settingsActionButton("Default", () => {
      if (!resetPaneTerminalFontSize(panel.id)) return;
      refreshActivePaneTextControls(panel.id);
    }, "", "active pane terminal text size reset default");
    resetText.dataset.activePaneResetText = panel.id;
    resetText.disabled = !panelHasTerminalFontSize(panel);
    const numberWrap = document.createElement("span");
    numberWrap.className = "active-pane-text-number-wrap";
    const numberUnit = document.createElement("span");
    numberUnit.className = "active-pane-text-number-unit";
    numberUnit.textContent = "px";
    numberWrap.append(fontNumber, numberUnit);
    const textControl = document.createElement("span");
    textControl.className = "active-pane-text-control";
    textControl.append(fontRange, numberWrap, resetText);
    const fontRow = settingRow(`Pane text ${paneFontSize}px`, textControl, false, "active pane terminal text size font zoom exact smaller larger default reset");
    fontRow.dataset.activePaneTextRow = panel.id;
    const syncTextSizeControl = (value, options = {}) => {
      const nextSize = setPaneTerminalFontSizeOverride(panel.id, Number(value), { toast: false });
      fontRange.value = String(nextSize);
      fontNumber.value = String(nextSize);
      updatePaneTextLabel(fontRow, nextSize);
      const resetButton = wrapper.querySelector("[data-active-pane-reset-text]");
      if (resetButton) resetButton.disabled = false;
      if (options.toast) toast(`Pane text ${nextSize}px.`);
      return nextSize;
    };
    fontRange.oninput = () => syncTextSizeControl(fontRange.value);
    fontRange.onchange = () => syncTextSizeControl(fontRange.value, { toast: true });
    fontNumber.oninput = () => {
      if (!fontNumber.value.trim()) return;
      const parsed = Number(fontNumber.value);
      if (!Number.isFinite(parsed)) return;
      syncTextSizeControl(parsed);
    };
    fontNumber.onchange = () => syncTextSizeControl(fontNumber.value.trim() || terminalFontSizeForPanel(panel), { toast: true });
    fontNumber.onkeydown = (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        fontNumber.blur();
      } else if (event.key === "Escape") {
        event.preventDefault();
        const current = terminalFontSizeForPanel(panel);
        fontRange.value = String(current);
        fontNumber.value = String(current);
        updatePaneTextLabel(fontRow, current);
        fontNumber.blur();
      }
    };
    wrapper.append(fontRow);
  } else {
    const urlInput = document.createElement("input");
    urlInput.className = "setting-control";
    urlInput.value = browserPanelUrl(panel) || panel.url || state.settings.browserHomeUrl;
    urlInput.placeholder = "https://www.google.com";
    urlInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") urlInput.blur();
    });
    urlInput.addEventListener("blur", () => {
      const nextUrl = normalizeUrl(urlInput.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
      urlInput.value = nextUrl;
      const session = state.browserViews.get(panel.id);
      if (session) {
        session.address.value = nextUrl;
        updateActiveBrowserTabUrl(session, nextUrl);
        const sourceUrl = browserViewSourceUrl(nextUrl);
        if (session.view.src !== sourceUrl) {
          session.view.src = sourceUrl;
          session.setStatus?.("Loading");
        }
      }
      updatePanel(panel.id, { url: nextUrl });
    });
    wrapper.append(settingRow("Browser URL", urlInput, true, "active pane browser url address page"));
  }

  const actions = document.createElement("div");
  actions.className = "settings-actions active-pane-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("active pane focus duplicate split reset color text browser terminal actions");
  actions.append(
    settingsActionButton("Focus pane", () => focusPanel(panel.id), "", "active pane focus"),
    settingsActionButton("Duplicate", () => duplicatePanel(panel), "", "active pane duplicate"),
    settingsActionButton("Split right", () => splitPanel(panel, "right"), "", "active pane split right"),
    settingsActionButton("Split down", () => splitPanel(panel, "down"), "", "active pane split down")
  );
  if (panel.type === "terminal") {
    actions.append(settingsActionButton("Restart", () => restartPanel(panel.id), "", "active pane terminal restart"));
  } else {
    actions.append(
      settingsActionButton("New tab", () => newBrowserTabFromPanel(panel), "", "active pane browser new tab"),
      settingsActionButton("Open external", () => openBrowserPanelExternally(panel), "", "active pane browser external")
    );
  }
  wrapper.append(actions);
  return wrapper;
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

function scheduleSettingsFilter() {
  if (state.settingsFilterFrame) return;
  state.settingsFilterFrame = requestAnimationFrame(() => {
    state.settingsFilterFrame = 0;
    applySettingsFilter();
  });
}

function buildSettingsSearchIndex() {
  return [...elements.inspectorBody.querySelectorAll(".settings-section")].map((section) => ({
    section,
    sectionSearch: section.dataset.settingsSearch || "",
    sectionTitle: settingsSectionTitle(section),
    items: [...section.querySelectorAll("[data-settings-search]")]
      .filter((item) => item !== section)
      .map((item) => ({ item, search: item.dataset.settingsSearch || "" })),
    groups: [...section.querySelectorAll(".settings-command-group")].map((group) => ({
      group,
      search: group.dataset.settingsSearch || "",
      cards: [...group.querySelectorAll(".settings-command-card")]
    }))
  }));
}

function updateSettingsSearchIndexItemSearch(target, search) {
  for (const section of state.settingsSearchIndex) {
    const record = section.items.find((item) => item.item === target);
    if (record) {
      record.search = search;
      return;
    }
  }
}

function settingsSectionTitle(section) {
  return normalizeSettingsQuery(section?.querySelector(".settings-section-title")?.textContent);
}

function settingsSearchTargetScore(item, sectionTitle = "") {
  if (!item) return -Infinity;
  let score = 10;
  if (item.classList.contains("setting-row")) score += 90;
  if (item.classList.contains("settings-command-card")) score += 85;
  if (item.classList.contains("settings-actions")) score += 74;
  if (item.classList.contains("settings-action")) score += 72;
  if (item.classList.contains("browser-home-preset")) score += 68;
  if (item.classList.contains("background-preset")) score += 68;
  if (item.classList.contains("terminal-color-preset")) score += 68;
  if (item.classList.contains("terminal-font-choice")) score += 68;
  if (item.classList.contains("pane-layout-preset")) score += 68;
  if (item.classList.contains("settings-preset")) score += 62;
  if (item.classList.contains("settings-metric")) score += 35;
  if (item.classList.contains("quick-settings-shortcut")) score -= 70;
  if (item.classList.contains("quick-settings-shortcut-grid")) score -= 55;
  if (item.classList.contains("quick-setup-overview")) score -= 60;
  if (sectionTitle === "quick setup") score -= 35;
  return score;
}

function maybeUpdateSettingsSearchTarget(current, item, sectionTitle) {
  const score = settingsSearchTargetScore(item, sectionTitle);
  if (!current || score > current.score) return { item, score };
  return current;
}

function scrollSettingsSearchTargetIntoView(target) {
  if (!target || !elements.inspectorBody.contains(target)) return;
  const bodyRect = elements.inspectorBody.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();
  const top = elements.inspectorBody.scrollTop + targetRect.top - bodyRect.top - 12;
  const behavior = state.settings.reduceMotion || state.settings.performanceMode ? "auto" : "smooth";
  elements.inspectorBody.scrollTo({ top: Math.max(0, Math.round(top)), behavior });
}

function applySettingsFilter() {
  const query = normalizeSettingsQuery(state.settingsQuery);
  const tokens = settingsSearchTokens(query);
  let visibleSections = 0;
  let bestTarget = null;
  const sections = state.settingsSearchIndex.length ? state.settingsSearchIndex : buildSettingsSearchIndex();
  for (const sectionRecord of sections) {
    const { section, sectionSearch, sectionTitle, items, groups } = sectionRecord;
    const sectionMatches = settingsSearchMatches(sectionSearch, tokens);
    let sectionVisible = sectionMatches;
    if (query && sectionMatches) bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, section, sectionTitle);
    for (const { item, search } of items) {
      const itemMatches = settingsSearchMatches(search, tokens);
      const visible = itemMatches || sectionMatches;
      setHiddenIfChanged(item, !visible);
      sectionVisible ||= visible;
      if (query && itemMatches) bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, item, sectionTitle);
    }
    for (const { group, search, cards } of groups) {
      const cardVisible = cards.some((card) => !card.hidden);
      const groupMatches = settingsSearchMatches(search, tokens);
      const groupVisible = cardVisible || groupMatches || sectionMatches;
      setHiddenIfChanged(group, !groupVisible);
      sectionVisible ||= groupVisible;
      if (query && groupMatches) bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, group, sectionTitle);
    }
    setHiddenIfChanged(section, !sectionVisible);
    if (sectionVisible) visibleSections += 1;
  }
  const empty = elements.inspectorBody.querySelector(".settings-empty");
  if (empty) setHiddenIfChanged(empty, !query || visibleSections > 0);
  const clear = elements.inspectorBody.querySelector(".settings-search-clear");
  if (clear) clear.disabled = !query;
  const shouldAutoScroll = query
    && (state.settingsSearchAutoScrollQuery === query || elements.inspectorBody.scrollTop === 0);
  if (state.settingsSearchAutoScrollQuery === query) state.settingsSearchAutoScrollQuery = "";
  if (shouldAutoScroll && visibleSections > 0) scrollSettingsSearchTargetIntoView(bestTarget?.item);
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

function recordDurationStats(stats, durationMs) {
  const value = Math.max(0, Number(durationMs) || 0);
  stats.count += 1;
  stats.lastMs = value;
  stats.avgMs = stats.avgMs ? (stats.avgMs * 0.82) + (value * 0.18) : value;
  stats.maxMs = Math.max(stats.maxMs, value);
}

function recordPaneCreateDuration(type, durationMs) {
  state.paneCreateStats.lastType = type === "browser" ? "browser" : "terminal";
  recordDurationStats(state.paneCreateStats, durationMs);
}

function recordTerminalConnectDuration(durationMs) {
  recordDurationStats(state.terminalConnectStats, durationMs);
}

function durationMetric(stats, key = "lastMs") {
  return stats.count ? formatMs(stats[key]) : "--";
}

function performanceMetrics() {
  const workspaces = state.data?.workspaces || [];
  const panels = allPanels();
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  updateTerminalOutputBacklog();
  const pausedTerminals = pausedTerminalOutputCount();
  return [
    ["Render avg", formatMs(state.renderStats.avgMs)],
    ["Last render", formatMs(state.renderStats.lastMs)],
    ["Max render", formatMs(state.renderStats.maxMs)],
    ["Slow renders", String(state.renderStats.slowCount)],
    ["Coalesced renders", String(state.renderStats.coalescedRenders || 0)],
    ["Skipped renders", String(state.renderStats.skippedRenders)],
    ["Browser URL skips", String(state.renderStats.browserUrlRenderSkips)],
    ["Output backlog", formatBytes(state.terminalOutputStats.currentQueued)],
    ["Output max", formatBytes(state.terminalOutputStats.maxQueued)],
    ["Output trimmed", formatBytes(state.terminalOutputStats.trimmedBytes)],
    ["Output chunks", String(state.terminalOutputStats.chunks)],
    ["Paused output", String(pausedTerminals)],
    ["Pause hits", String(state.terminalOutputStats.pausedFlushes)],
    ["Trim events", String(state.terminalOutputStats.trimmedEvents || 0)],
    ["Fit defers", String(state.terminalFitStats.deferred || 0)],
    ["Fit flushes", String(state.terminalFitStats.flushed || 0)],
    ["Last pane add", durationMetric(state.paneCreateStats)],
    ["Avg pane add", durationMetric(state.paneCreateStats, "avgMs")],
    ["Max pane add", durationMetric(state.paneCreateStats, "maxMs")],
    ["Pane add failures", String(state.paneCreateStats.failures || 0)],
    ["Last shell connect", durationMetric(state.terminalConnectStats)],
    ["Max shell connect", durationMetric(state.terminalConnectStats, "maxMs")],
    ["Pending panes", String(state.pendingPanels.size)],
    ["Suspended browsers", String([...state.browserViews.values()].filter((session) => session.suspended).length)],
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

function recentDataItemCount() {
  return state.recentFolders.length
    + state.recentCommands.length
    + state.recentBrowserPages.length
    + browserTabSnapshotCount();
}

function savedDataItemCount() {
  return state.customCommandSnippets.length
    + state.savedSettingsProfiles.length
    + state.workspaceBlueprints.length
    + state.customColorPalette.length
    + state.savedBackgroundImages.length;
}

function browserTabSnapshotCount() {
  let count = 0;
  for (const snapshot of state.browserTabSnapshots.values()) {
    count += Array.isArray(snapshot?.tabs) ? snapshot.tabs.length : 0;
  }
  return count;
}

function emptyWorkspaces() {
  return (state.data?.workspaces || []).filter((workspace) => (workspace.panels?.length || 0) === 0);
}

function emptyWorkspaceCleanupTargets() {
  const workspaces = state.data?.workspaces || [];
  const empty = emptyWorkspaces();
  if (empty.length === 0 || workspaces.length <= 1) return [];
  const nonEmptyCount = workspaces.length - empty.length;
  const keepWorkspaceId = nonEmptyCount > 0
    ? ""
    : state.data?.activeWorkspaceId || workspaces[0]?.id || "";
  return empty.filter((workspace) => workspace.id !== keepWorkspaceId);
}

function hasEmptyWorkspaceCleanupTargets() {
  return emptyWorkspaceCleanupTargets().length > 0;
}

function dataStorageEntries() {
  const entries = [
    {
      id: "settings",
      label: "Settings",
      key: "cmux.settings",
      count: "Current",
      category: "quick",
      terms: "preferences setup customize"
    },
    {
      id: "terminalFontSize",
      label: "Terminal font",
      key: "cmux.terminalFontSize",
      count: `${state.settings.terminalFontSize}px`,
      category: "terminal",
      terms: "terminal font size legacy"
    },
    {
      id: "paneLayout",
      label: "Pane layouts",
      key: paneLayoutStorageKey,
      count: String(state.paneLayouts.size),
      category: "layout",
      terms: "split layout pane size"
    },
    {
      id: "paneTreeLayouts",
      label: "Split shapes",
      key: paneTreeLayoutsStorageKey,
      count: String(state.paneTrees.size),
      category: "layout",
      terms: "split tree layout pane shape nested resize"
    },
    {
      id: "recentFolders",
      label: "Recent folders",
      key: recentFoldersStorageKey,
      count: `${state.recentFolders.length}/${recentFoldersLimit}`,
      category: "workspace",
      terms: "workspace folder history"
    },
    {
      id: "recentCommands",
      label: "Recent commands",
      key: recentCommandsStorageKey,
      count: `${state.recentCommands.length}/${recentCommandsLimit}`,
      category: "commands",
      terms: "terminal command history"
    },
    {
      id: "recentBrowserPages",
      label: "Recent pages",
      key: recentBrowserPagesStorageKey,
      count: `${state.recentBrowserPages.length}/${recentBrowserPagesLimit}`,
      category: "browser",
      terms: "browser web page history"
    },
    {
      id: "browserTabs",
      label: "Browser tabs",
      key: browserTabsStorageKey,
      count: `${state.browserTabSnapshots.size} panes / ${browserTabSnapshotCount()} tabs`,
      category: "browser",
      terms: "browser tab restore session saved tabs"
    },
    {
      id: "commandSnippets",
      label: "Command snippets",
      key: customCommandSnippetsStorageKey,
      count: `${state.customCommandSnippets.length}/${customCommandSnippetsLimit}`,
      category: "commands",
      terms: "saved terminal snippets git github gh cli"
    },
    {
      id: "settingsProfiles",
      label: "Profiles",
      key: savedSettingsProfilesStorageKey,
      count: `${state.savedSettingsProfiles.length}/${savedSettingsProfilesLimit}`,
      category: "profiles",
      terms: "saved settings profile"
    },
    {
      id: "workspaceBlueprints",
      label: "Blueprints",
      key: workspaceBlueprintsStorageKey,
      count: `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`,
      category: "blueprints",
      terms: "workspace layout template"
    },
    {
      id: "customColors",
      label: "Saved colors",
      key: customColorPaletteStorageKey,
      count: `${state.customColorPalette.length}/${customColorPaletteLimit}`,
      category: "appearance",
      terms: "color palette accent workspace pane"
    },
    {
      id: "savedBackgrounds",
      label: "Backgrounds",
      key: savedBackgroundImagesStorageKey,
      count: `${state.savedBackgroundImages.length}/${savedBackgroundImagesLimit}`,
      category: "appearance",
      terms: "background image wallpaper"
    }
  ];
  return entries.map((entry) => ({
    ...entry,
    bytes: storageEntryBytes(entry.key)
  }));
}

function totalDataStorageBytes() {
  return dataStorageEntries().reduce((sum, entry) => sum + entry.bytes, 0);
}

function settingsDataMetrics() {
  const recentItems = recentDataItemCount();
  const savedItems = savedDataItemCount();
  return [
    ["Local data", formatBytes(totalDataStorageBytes())],
    ["Recent items", String(recentItems)],
    ["Saved items", String(savedItems)],
    ["Recent folders", `${state.recentFolders.length}/${recentFoldersLimit}`],
    ["Recent commands", `${state.recentCommands.length}/${recentCommandsLimit}`],
    ["Recent pages", `${state.recentBrowserPages.length}/${recentBrowserPagesLimit}`],
    ["Browser tabs", `${state.browserTabSnapshots.size} panes / ${browserTabSnapshotCount()} tabs`],
    ["Command snippets", `${state.customCommandSnippets.length}/${customCommandSnippetsLimit}`],
    ["Profiles", `${state.savedSettingsProfiles.length}/${savedSettingsProfilesLimit}`],
    ["Blueprints", `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`],
    ["Empty workspaces", String(emptyWorkspaces().length)],
    ["Saved colors", `${state.customColorPalette.length}/${customColorPaletteLimit}`],
    ["Backgrounds", `${state.savedBackgroundImages.length}/${savedBackgroundImagesLimit}`],
    ["Pane layouts", formatBytes(storageEntryBytes(paneLayoutStorageKey))],
    ["Split shapes", formatBytes(storageEntryBytes(paneTreeLayoutsStorageKey))]
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
    terminalFitStats: { ...state.terminalFitStats },
    paneCreateStats: { ...state.paneCreateStats },
    terminalConnectStats: { ...state.terminalConnectStats },
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
      paneActionMode: state.settings.paneActionMode,
      sidebarDetailMode: state.settings.sidebarDetailMode,
      sidebarFooterMode: state.settings.sidebarFooterMode,
      tabSize: state.settings.tabSize,
      titleDetailMode: state.settings.titleDetailMode,
      showTabs: state.settings.showTabs,
      showStatusbar: state.settings.showStatusbar,
      performanceMode: state.settings.performanceMode,
      adaptivePerformance: state.settings.adaptivePerformance,
      reduceMotion: state.settings.reduceMotion,
      terminalPauseInactiveOutput: state.settings.terminalPauseInactiveOutput,
      background: state.settings.backgroundImage
        ? isBackgroundPreset(state.settings.backgroundImage) ? state.settings.backgroundImage : "custom-image"
        : "none",
      backgroundOpacity: state.settings.backgroundOpacity,
      backgroundEffects: state.settings.backgroundEffects,
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

function activeSettingsPresetLabel() {
  return settingsPresets.find((preset) => isActiveSettingsPreset(preset))?.label || "Custom";
}

function accentModeLabel() {
  return normalizeCustomPaletteColor(state.settings.accent) ? "Custom color" : "Preset color";
}

function performanceModeLabel() {
  if (state.settings.performanceMode) return "Tuned";
  if (state.settings.adaptivePerformance) return state.performanceGuardTriggered ? "Auto tuned" : "Watching";
  return "Manual";
}

function workspaceCountLabel() {
  const count = state.data?.workspaces?.length || 0;
  return `${count} workspace${count === 1 ? "" : "s"}`;
}

function quickSetupOverviewPanel() {
  const workspace = activeWorkspace();
  const panels = workspace?.panels || [];
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  const folder = workspace?.cwdShort || workspace?.cwd || "No folder";
  const panel = document.createElement("div");
  panel.className = "quick-setup-overview";
  panel.dataset.settingsSearch = normalizeSettingsQuery("quick setup overview current settings workspace panes theme layout terminal browser performance data");
  panel.innerHTML = `
    <div class="quick-overview-heading">
      <span class="quick-overview-title">Current setup</span>
      <span class="quick-overview-subtitle"></span>
    </div>
    <div class="quick-overview-grid">
      <span><b>Profile</b><em data-quick-profile></em></span>
      <span><b>Workspace</b><em data-quick-workspace></em></span>
      <span><b>Panes</b><em data-quick-panes></em></span>
      <span><b>Look</b><em data-quick-look></em></span>
      <span><b>Terminal</b><em data-quick-terminal></em></span>
      <span><b>Performance</b><em data-quick-performance></em></span>
    </div>
  `;
  panel.querySelector(".quick-overview-subtitle").textContent = folder;
  panel.querySelector("[data-quick-profile]").textContent = activeSettingsPresetLabel();
  panel.querySelector("[data-quick-workspace]").textContent = workspace?.title || "No workspace";
  panel.querySelector("[data-quick-panes]").textContent = `${terminalCount} term / ${browserCount} web`;
  panel.querySelector("[data-quick-look]").textContent = `${optionLabel(themeOptions, state.settings.theme, "cmux")} / ${accentModeLabel()}`;
  panel.querySelector("[data-quick-terminal]").textContent = `${optionLabel(terminalFontOptions, state.settings.terminalFontFamily, "Mono")} ${state.settings.terminalFontSize}px`;
  panel.querySelector("[data-quick-performance]").textContent = performanceModeLabel();
  return panel;
}

const quickSettingsShortcuts = [
  ["workspace", "Workspace", "Rename, folders, colors.", workspaceCountLabel],
  ["appearance", "Look", "Themes, colors, backgrounds.", () => appearanceBackgroundLabel(state.settings.backgroundImage)],
  ["layout", "Layout", "Tabs, panes, chrome.", () => optionLabel(toolbarModeOptions, state.settings.toolbarMode, "Minimal")],
  ["terminal", "Terminal", "Font, cursor, shell.", () => optionLabel(terminalProfiles, state.settings.terminalProfile, "Auto")],
  ["browser", "Browser", "Home page and history.", () => hostnameOf(state.settings.browserHomeUrl)],
  ["performance", "Performance", "Lag tuning and diagnostics.", performanceModeLabel],
  ["actions", "Actions", "Shortcuts and runnable actions.", () => `${commands.length} actions`],
  ["commands", "Commands", "Saved shell and GitHub CLI snippets.", () => `${state.customCommandSnippets.length}/${customCommandSnippetsLimit}`],
  ["profiles", "Profiles", "Save and reuse setups.", () => `${state.savedSettingsProfiles.length}/${savedSettingsProfilesLimit}`],
  ["data", "Data", "Import, export, cleanup.", () => `${state.recentFolders.length + state.recentCommands.length + state.recentBrowserPages.length} recent`]
];

function quickSetupActionGrid() {
  const actions = [
    {
      id: "rename",
      icon: "Aa",
      label: "Rename",
      body: "Name the active workspace without opening more chrome.",
      meta: () => activeWorkspace()?.title || "Workspace",
      cta: "Edit",
      search: "rename workspace name title quick setup",
      run: () => renameActiveWorkspace()
    },
    {
      id: "clean-ui",
      icon: "UI",
      label: "Clean UI",
      body: "Apply a minimal toolbar and quieter pane controls.",
      meta: activeSettingsPresetLabel,
      cta: "Apply",
      search: "simple clean minimal compact ui chrome pane controls preset",
      run: () => applySettingsPresetById("simple")
    },
    {
      id: "tune-speed",
      icon: "Hz",
      label: "Tune speed",
      body: "Reduce effects, pause hidden output, and lighten history.",
      meta: performanceModeLabel,
      cta: "Tune",
      search: "performance tune speed lag smooth reduce effects",
      run: () => {
        tunePerformanceNow();
        if (state.inspectorMode === "settings" && state.settingsCategory === "quick") renderSettingsInspector();
      }
    },
    {
      id: "focus-mode",
      icon: "Fx",
      label: state.settings.focusMode ? "Leave focus" : "Focus mode",
      body: "Hide extra chrome when you want only the workspace.",
      meta: () => state.settings.focusMode ? "On" : "Off",
      cta: "Toggle",
      search: "focus mode hide chrome simple clean workspace",
      run: () => {
        toggleFocusMode();
        if (state.inspectorMode === "settings" && state.settingsCategory === "quick") renderSettingsInspector();
      }
    },
    {
      id: "background",
      icon: "Bg",
      label: "Background",
      body: "Choose a local image for the workspace backdrop.",
      meta: () => appearanceBackgroundLabel(state.settings.backgroundImage),
      cta: "Choose",
      search: "background image wallpaper choose local file appearance",
      run: () => chooseBackgroundImage()
    },
    {
      id: "save-layout",
      icon: "Sv",
      label: "Save layout",
      body: "Store this pane shape as a reusable workspace blueprint.",
      meta: () => `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`,
      cta: "Save",
      search: "save layout workspace blueprint panes shape split",
      run: () => saveCurrentWorkspaceBlueprint()
    }
  ];
  const grid = document.createElement("div");
  grid.className = "quick-settings-shortcut-grid quick-action-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("quick actions clean ui speed tune focus mode background image wallpaper");
  for (const action of actions) {
    const button = document.createElement("button");
    button.className = "quick-settings-shortcut quick-action";
    button.type = "button";
    button.dataset.quickAction = action.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`quick action ${action.label} ${action.body} ${action.search}`);
    button.setAttribute("aria-label", `${action.label}. ${action.body} Current: ${action.meta()}.`);
    button.innerHTML = `
      <span class="quick-action-icon" aria-hidden="true"></span>
      <span class="quick-action-copy">
        <span class="quick-settings-shortcut-title"></span>
        <span class="quick-settings-shortcut-body"></span>
      </span>
      <span class="quick-action-footer">
        <span class="quick-settings-shortcut-meta"></span>
        <span class="quick-action-cta"></span>
      </span>
    `;
    button.querySelector(".quick-action-icon").textContent = action.icon;
    button.querySelector(".quick-settings-shortcut-title").textContent = action.label;
    button.querySelector(".quick-settings-shortcut-body").textContent = action.body;
    button.querySelector(".quick-settings-shortcut-meta").textContent = action.meta();
    button.querySelector(".quick-action-cta").textContent = action.cta;
    button.onclick = action.run;
    grid.append(button);
  }
  return grid;
}

function quickColorControlRows(workspace = activeWorkspace()) {
  const rows = [];
  if (!workspace) return rows;
  rows.push(settingRow(
    "Workspace color",
    colorControlPanel({
      colors: workspaceColorPalette(),
      activeColor: workspace.color,
      fallbackColor: state.settings.accent,
      onPick: (color) => setWorkspaceColor(color, workspace.id),
      searchTerms: "quick setup workspace custom color hex picker"
    }),
    true,
    "quick setup workspace color tab sidebar customize custom hex picker"
  ));
  const panel = workspace.panels.find((candidate) => candidate.id === workspace.activePanelId)
    || workspace.panels[0]
    || null;
  if (panel) {
    rows.push(settingRow(
      "Pane color",
      colorControlPanel({
        colors: workspaceColorPalette(),
        activeColor: panel.color || workspace.color,
        fallbackColor: workspace.color || state.settings.accent,
        onPick: (color) => updatePanel(panel.id, { color }),
        onClear: () => updatePanel(panel.id, { color: "" }),
        clearLabel: "Default",
        clearDisabled: !panel.color,
        searchTerms: "quick setup active pane custom color hex picker reset default clear"
      }),
      true,
      "quick setup active pane terminal browser tab color customize custom hex picker reset default clear"
    ));
  }
  return rows;
}

function quickSettingsShortcutGrid() {
  const grid = document.createElement("div");
  grid.className = "quick-settings-shortcut-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("quick setup shortcuts customize workspace appearance look layout terminal browser performance profiles data");
  for (const [category, label, body, meta] of quickSettingsShortcuts) {
    const button = document.createElement("button");
    button.className = "quick-settings-shortcut";
    button.type = "button";
    button.dataset.settingsSearch = normalizeSettingsQuery(`quick setup shortcut ${label} ${body} ${category}`);
    button.innerHTML = `
      <span class="quick-settings-shortcut-title"></span>
      <span class="quick-settings-shortcut-body"></span>
      <span class="quick-settings-shortcut-meta"></span>
    `;
    button.querySelector(".quick-settings-shortcut-title").textContent = label;
    button.querySelector(".quick-settings-shortcut-body").textContent = body;
    button.querySelector(".quick-settings-shortcut-meta").textContent = meta();
    button.onclick = () => openSettingsCategory(category);
    grid.append(button);
  }
  return grid;
}

function dataSettingsOverviewPanel() {
  const panel = document.createElement("div");
  panel.className = "data-settings-overview";
  panel.dataset.settingsSearch = normalizeSettingsQuery("data overview storage backup export import recent saved cleanup reset local settings empty workspaces browser tabs");
  panel.innerHTML = `
    <div class="data-overview-heading">
      <span class="data-overview-title">Local data</span>
      <span class="data-overview-subtitle">cmux Windows</span>
    </div>
    <div class="data-overview-grid">
      <span><b>Storage</b><em data-data-overview-storage></em></span>
      <span><b>Saved</b><em data-data-overview-saved></em></span>
      <span><b>Recent</b><em data-data-overview-recent></em></span>
      <span><b>Empty</b><em data-data-overview-empty></em></span>
    </div>
  `;
  panel.querySelector("[data-data-overview-storage]").textContent = formatBytes(totalDataStorageBytes());
  panel.querySelector("[data-data-overview-saved]").textContent = String(savedDataItemCount());
  panel.querySelector("[data-data-overview-recent]").textContent = String(recentDataItemCount());
  panel.querySelector("[data-data-overview-empty]").textContent = String(emptyWorkspaces().length);
  return panel;
}

function dataStorageBreakdownPanel() {
  const entries = dataStorageEntries();
  const maxBytes = Math.max(1, ...entries.map((entry) => entry.bytes));
  const panel = document.createElement("div");
  panel.className = "data-storage-breakdown";
  panel.dataset.settingsSearch = normalizeSettingsQuery("data storage breakdown local settings bytes saved recent export import cleanup");
  const header = document.createElement("div");
  header.className = "recent-folder-header";
  const title = document.createElement("span");
  title.textContent = "Storage breakdown";
  const total = document.createElement("span");
  total.className = "data-storage-total";
  total.textContent = formatBytes(entries.reduce((sum, entry) => sum + entry.bytes, 0));
  header.append(title, total);
  panel.append(header);

  const list = document.createElement("div");
  list.className = "data-storage-list";
  for (const entry of entries) {
    const row = document.createElement("button");
    row.className = "data-storage-row";
    row.type = "button";
    row.dataset.settingsSearch = normalizeSettingsQuery(`data storage ${entry.label} ${entry.key} ${entry.count} ${entry.terms}`);
    row.style.setProperty("--data-storage-fill", `${Math.max(3, Math.round((entry.bytes / maxBytes) * 100))}%`);
    row.innerHTML = `
      <span class="data-storage-row-text">
        <span class="data-storage-row-label"></span>
        <span class="data-storage-row-key"></span>
      </span>
      <span class="data-storage-row-count"></span>
      <span class="data-storage-row-bytes"></span>
      <span class="data-storage-row-bar" aria-hidden="true"></span>
    `;
    row.querySelector(".data-storage-row-label").textContent = entry.label;
    row.querySelector(".data-storage-row-key").textContent = entry.key;
    row.querySelector(".data-storage-row-count").textContent = entry.count;
    row.querySelector(".data-storage-row-bytes").textContent = formatBytes(entry.bytes);
    row.onclick = () => openSettingsCategory(entry.category);
    list.append(row);
  }
  panel.append(list);
  return panel;
}

function settingsMetricGrid(metrics, searchPrefix = "performance diagnostics metric") {
  const grid = document.createElement("div");
  grid.className = "settings-metric-grid";
  for (const [label, value] of metrics) {
    grid.append(settingsMetricCard(label, value, searchPrefix));
  }
  return grid;
}

function settingsMetricCard(label, value, searchPrefix = "performance diagnostics metric") {
  const card = document.createElement("div");
  card.className = "settings-metric";
  card.dataset.settingsSearch = normalizeSettingsQuery(`${searchPrefix} ${label} ${value}`);
  card.innerHTML = `<span class="settings-metric-value"></span><span class="settings-metric-label"></span>`;
  card.querySelector(".settings-metric-value").textContent = value;
  card.querySelector(".settings-metric-label").textContent = label;
  return card;
}

function refreshPerformanceMetricsGrid() {
  const grid = elements.inspectorBody.querySelector('[data-performance-metrics="true"]');
  if (!grid) return false;
  const metrics = performanceMetrics();
  const cards = [...grid.querySelectorAll(".settings-metric")];
  if (cards.length !== metrics.length) {
    replaceChildrenIfChanged(grid, metrics.map(([label, value]) => settingsMetricCard(label, value)));
    state.settingsSearchIndex = buildSettingsSearchIndex();
    return true;
  }
  let changed = false;
  for (const [index, [label, value]] of metrics.entries()) {
    const card = cards[index];
    const search = normalizeSettingsQuery(`performance diagnostics metric ${label} ${value}`);
    if (card.dataset.settingsSearch !== search) {
      card.dataset.settingsSearch = search;
      updateSettingsSearchIndexItemSearch(card, search);
      changed = true;
    }
    changed = setTextIfChanged(card.querySelector(".settings-metric-value"), value) || changed;
    changed = setTextIfChanged(card.querySelector(".settings-metric-label"), label) || changed;
  }
  return changed;
}

function paneShapePanel(workspace = activeWorkspace()) {
  const panel = activePanel();
  const hasPendingPane = Boolean(workspace?.panels?.some(isPendingPanel));
  const multiPane = Boolean(workspace && panel && workspace.panels.length > 1 && !hasPendingPane);
  const percent = multiPane ? activePaneLayoutPercent(workspace) : 50;
  const direction = paneLayoutDirection(workspace);
  const directionLabel = direction === "down" ? t("paneShape.stackedRows") : t("paneShape.sideBySideColumns");
  const panelTitle = panel ? panelDisplayTitle(panel, true) : t("paneShape.noPane");
  const wrapper = document.createElement("div");
  wrapper.className = `pane-shape-panel${direction === "down" ? " is-stacked" : ""}`;
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("pane shape split layout resize active pane percent range slider exact smaller bigger equal side by side stacked rows columns");
  wrapper.innerHTML = `
    <span class="pane-shape-meter" aria-hidden="true">
      <span class="pane-shape-meter-fill"></span>
    </span>
    <span class="pane-shape-copy">
      <span class="pane-shape-kicker"></span>
      <span class="pane-shape-title"></span>
      <span class="pane-shape-meta"></span>
    </span>
    <div class="pane-shape-slider">
      <span class="pane-shape-slider-label"></span>
      <input class="setting-control pane-shape-range" type="range">
      <span class="pane-shape-slider-value"></span>
      <span class="pane-shape-number-wrap">
        <input class="setting-control pane-shape-number" type="number" inputmode="numeric">
        <span class="pane-shape-number-unit">%</span>
      </span>
    </div>
    <span class="pane-shape-actions"></span>
  `;
  const titleNode = wrapper.querySelector(".pane-shape-title");
  const valueNode = wrapper.querySelector(".pane-shape-slider-value");
  const updatePercentView = (nextPercent) => {
    wrapper.style.setProperty("--pane-shape-fill", `${nextPercent}%`);
    titleNode.textContent = multiPane
      ? formatMessage("paneShape.titlePercent", { title: panelTitle, percent: nextPercent })
      : hasPendingPane
        ? t("paneShape.pendingTitle")
        : t("paneShape.emptyTitle");
    valueNode.textContent = multiPane ? `${nextPercent}%` : "--";
    setTextIfChanged(elements.inspectorBody?.querySelector("[data-layout-preview-active-pane]"), `${nextPercent}%`);
  };
  wrapper.querySelector(".pane-shape-kicker").textContent = t("paneShape.kicker");
  wrapper.querySelector(".pane-shape-meta").textContent = multiPane
    ? formatMessage("paneShape.metaReady", { direction: directionLabel })
    : hasPendingPane
      ? t("paneShape.metaPending")
      : t("paneShape.metaEmpty");
  wrapper.querySelector(".pane-shape-slider-label").textContent = t("paneShape.size");
  const range = wrapper.querySelector(".pane-shape-range");
  const number = wrapper.querySelector(".pane-shape-number");
  const syncPercentInputs = (nextPercent) => {
    range.value = String(nextPercent);
    number.value = String(nextPercent);
    updatePercentView(nextPercent);
  };
  range.min = String(paneLayoutPercentMin);
  range.max = String(paneLayoutPercentMax);
  range.step = "1";
  range.disabled = !multiPane;
  range.setAttribute("aria-label", t("paneShape.sizeAria"));
  number.min = String(paneLayoutPercentMin);
  number.max = String(paneLayoutPercentMax);
  number.step = "1";
  number.disabled = !multiPane;
  number.setAttribute("aria-label", t("paneShape.sizeAria"));
  range.oninput = () => {
    const nextPercent = applyActivePaneLayoutPercent(range.value);
    syncPercentInputs(nextPercent);
  };
  range.onchange = () => {
    const nextPercent = applyActivePaneLayoutPercent(range.value, { save: true, toast: true });
    syncPercentInputs(nextPercent);
  };
  number.oninput = () => {
    if (!number.value.trim()) return;
    const parsed = Number(number.value);
    if (!Number.isFinite(parsed)) return;
    const nextPercent = applyActivePaneLayoutPercent(parsed);
    syncPercentInputs(nextPercent);
  };
  number.onchange = () => {
    const value = number.value.trim() || String(activePaneLayoutPercent(workspace));
    const nextPercent = applyActivePaneLayoutPercent(value, { save: true, toast: true });
    syncPercentInputs(nextPercent);
  };
  number.onkeydown = (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      number.blur();
    } else if (event.key === "Escape") {
      event.preventDefault();
      syncPercentInputs(activePaneLayoutPercent(workspace));
      number.blur();
    }
  };
  syncPercentInputs(percent);
  const actions = wrapper.querySelector(".pane-shape-actions");
  const smaller = settingsActionButton(t("paneShape.smaller"), () => adjustActivePaneLayoutPercent(-5), "", "pane shape smaller reduce active pane size");
  smaller.disabled = !multiPane || percent <= paneLayoutPercentMin;
  const bigger = settingsActionButton(t("paneShape.bigger"), () => adjustActivePaneLayoutPercent(5), "", "pane shape bigger increase active pane size");
  bigger.disabled = !multiPane || percent >= paneLayoutPercentMax;
  const equal = settingsActionButton(t("paneShape.equal"), resetActivePaneLayout, "", "pane shape equalize reset split layout");
  equal.disabled = !multiPane;
  const side = settingsActionButton(t("paneShape.columns"), () => applyPaneLayoutPreset("sideBySide"), "", "pane shape side by side columns");
  side.disabled = !multiPane;
  const stack = settingsActionButton(t("paneShape.rows"), () => applyPaneLayoutPreset("stacked"), "", "pane shape stacked rows");
  stack.disabled = !multiPane;
  actions.append(smaller, bigger, equal, side, stack);
  return wrapper;
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
    coalescedRenders: 0,
    skippedRenders: 0,
    browserUrlRenderSkips: 0,
    guardActivations: 0
  };
  state.terminalOutputStats = {
    currentQueued: totalTerminalOutputQueue(),
    maxQueued: totalTerminalOutputQueue(),
    writtenBytes: 0,
    chunks: 0,
    lastChunk: 0,
    pausedFlushes: 0,
    trimmedBytes: 0,
    trimmedEvents: 0
  };
  state.terminalFitStats = {
    deferred: 0,
    flushed: 0
  };
  state.paneCreateStats = {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0,
    failures: 0,
    lastType: ""
  };
  state.terminalConnectStats = {
    count: 0,
    lastMs: 0,
    avgMs: 0,
    maxMs: 0
  };
  state.performanceGuardTriggered = false;
  state.performanceGuardReason = "";
  state.performanceGuardStartedAt = performance.now();
  state.performanceGuardSlowRenderCount = 0;
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
    backgroundEffects: "flat",
    density: "compact",
    toolbarMode: "minimal",
    paneActionMode: "essential",
    showStatusbar: false,
    terminalPadding: Math.min(state.settings.terminalPadding, 4),
    terminalScrollback: Math.min(state.settings.terminalScrollback, 6000),
    terminalPauseInactiveOutput: true,
    browserSuspendInactive: true
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
  if (command.id.startsWith("browser.")) return t("browser.fallbackTitle");
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
    "workspace.closeEmpty",
    "terminal.close",
    "terminal.closeOthers",
    "terminal.closeRight",
    "session.reset"
  ].includes(command.id);
}

function settingsCommandGroups() {
  const grouped = new Map();
  for (const command of commands) {
    const group = commandGroupLabel(command);
    if (!grouped.has(group)) grouped.set(group, []);
    grouped.get(group).push(command);
  }
  return grouped;
}

function commandShortcutCount(commandList = commands) {
  return commandList.filter((command) => Boolean(command.shortcut)).length;
}

function settingsActionsOverviewPanel() {
  const grouped = settingsCommandGroups();
  const panel = document.createElement("div");
  panel.className = "actions-settings-overview";
  panel.dataset.settingsSearch = normalizeSettingsQuery("actions overview commands shortcuts keyboard palette tools run groups dangerous confirm");
  panel.innerHTML = `
    <div class="actions-overview-heading">
      <span class="actions-overview-title">Action map</span>
      <span class="actions-overview-subtitle">Commands stay discoverable without adding toolbar clutter.</span>
    </div>
    <div class="actions-overview-grid">
      <span><b>Commands</b><em data-actions-overview-commands></em></span>
      <span><b>Shortcuts</b><em data-actions-overview-shortcuts></em></span>
      <span><b>Groups</b><em data-actions-overview-groups></em></span>
      <span><b>Confirm</b><em data-actions-overview-danger></em></span>
    </div>
  `;
  panel.querySelector("[data-actions-overview-commands]").textContent = String(commands.length);
  panel.querySelector("[data-actions-overview-shortcuts]").textContent = String(commandShortcutCount());
  panel.querySelector("[data-actions-overview-groups]").textContent = String(grouped.size);
  panel.querySelector("[data-actions-overview-danger]").textContent = String(commands.filter(isDangerCommand).length);
  return panel;
}

function firstShortcutLabel(commandList) {
  return commandList.find((command) => command.shortcut)?.shortcut || "Palette";
}

function settingsCommandGroupShortcutGrid() {
  const grid = document.createElement("div");
  grid.className = "actions-group-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("actions command groups jump shortcuts workspace terminal browser layout settings session tools");
  for (const [group, groupCommands] of settingsCommandGroups().entries()) {
    const button = document.createElement("button");
    button.className = "actions-group-card";
    button.type = "button";
    button.dataset.commandGroupJump = group;
    button.dataset.settingsSearch = normalizeSettingsQuery(`actions command group jump ${group} ${groupCommands.map((command) => `${command.label} ${command.id} ${command.shortcut}`).join(" ")}`);
    button.innerHTML = `
      <span class="actions-group-title"></span>
      <span class="actions-group-body"></span>
      <span class="actions-group-meta"></span>
    `;
    button.querySelector(".actions-group-title").textContent = group;
    button.querySelector(".actions-group-body").textContent = `${groupCommands.length} command${groupCommands.length === 1 ? "" : "s"} / ${commandShortcutCount(groupCommands)} shortcut${commandShortcutCount(groupCommands) === 1 ? "" : "s"}`;
    button.querySelector(".actions-group-meta").textContent = firstShortcutLabel(groupCommands);
    button.onclick = () => jumpToSettingsCommandGroup(group);
    grid.append(button);
  }
  return grid;
}

function jumpToSettingsCommandGroup(group) {
  const target = [...elements.inspectorBody.querySelectorAll(".settings-command-group")]
    .find((node) => node.dataset.commandGroup === group);
  if (!target) return;
  const reduceMotion = document.body.classList.contains("reduce-motion") || state.settings.reduceMotion || state.settings.performanceMode;
  target.scrollIntoView({ block: "start", behavior: reduceMotion ? "auto" : "smooth" });
  target.classList.add("is-highlighted");
  const firstRun = target.querySelector(".settings-command-run");
  if (firstRun) firstRun.focus({ preventScroll: true });
  setTimeout(() => target.classList.remove("is-highlighted"), 900);
}

function settingsCommandList() {
  const list = document.createElement("div");
  list.className = "settings-command-list";
  const grouped = settingsCommandGroups();
  for (const [group, groupCommands] of grouped.entries()) {
    const groupNode = document.createElement("div");
    groupNode.className = "settings-command-group";
    groupNode.dataset.commandGroup = group;
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

function colorControlPanel({
  colors,
  activeColor,
  fallbackColor = "#5d8cff",
  onPick,
  onClear,
  clearLabel = "Default",
  clearDisabled = false,
  searchTerms = ""
}) {
  const panel = document.createElement("div");
  panel.className = `settings-color-panel${onClear ? " has-clear" : ""}`;
  panel.dataset.settingsSearch = normalizeSettingsQuery(`color palette swatch custom hex picker ${searchTerms}`);
  panel.append(swatchGrid(colors, activeColor, onPick));

  const custom = document.createElement("div");
  custom.className = "settings-color-custom";
  custom.append(colorPicker(activeColor, onPick, fallbackColor));
  if (onClear) {
    const clear = settingsActionButton(clearLabel, onClear, "", `color reset default clear ${searchTerms}`);
    clear.classList.add("settings-color-clear");
    clear.disabled = clearDisabled;
    custom.append(clear);
  }
  panel.append(custom);
  return panel;
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
  const pane = focusedPanel();
  const savePane = settingsActionButton("Save pane", () => upsertCustomColorPalette(pane?.color), "", "saved color save active pane tab");
  savePane.disabled = !normalizeCustomPaletteColor(pane?.color);
  const clearPanes = settingsActionButton("Clear panes", () => clearWorkspacePaneColors(), "danger", "saved color clear pane tab colors workspace");
  clearPanes.disabled = !workspace?.panels?.some((panel) => panel.color);
  actions.append(saveAccent, saveWorkspace, savePane, clearPanes);
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
      settingsActionButton("Panes", () => setWorkspacePaneColors(color), "", `saved color apply panes tabs workspace ${color}`),
      settingsActionButton("Delete", () => deleteCustomColorPalette(color), "danger", `saved color delete ${color}`)
    );
    card.append(swatch, value, cardActions);
    list.append(card);
  }
  panel.append(list);
  return panel;
}

async function setWorkspacePaneColors(color, workspace = activeWorkspace()) {
  const targetColor = String(color || "").trim();
  if (!workspace || workspace.panels.length === 0) {
    toast("Open a pane before applying pane colors.");
    return false;
  }
  if (!isAllowedUiColor(targetColor, workspaceColorPalette())) {
    toast("Choose a saved color first.");
    return false;
  }
  const panels = workspace.panels.filter((panel) => panel.color !== targetColor);
  if (panels.length === 0) {
    toast("Pane colors already match.");
    return false;
  }
  await Promise.all(panels.map((panel) => updatePanel(panel.id, { color: targetColor })));
  if (state.inspectorMode === "settings" && state.settingsCategory === "appearance") renderSettingsInspector();
  toast(`${panels.length} pane${panels.length === 1 ? "" : "s"} updated.`);
  return true;
}

async function clearWorkspacePaneColors(workspace = activeWorkspace()) {
  if (!workspace || workspace.panels.length === 0) {
    toast("Open a pane before clearing pane colors.");
    return false;
  }
  const panels = workspace.panels.filter((panel) => panel.color);
  if (panels.length === 0) {
    toast("Pane colors already cleared.");
    return false;
  }
  await Promise.all(panels.map((panel) => updatePanel(panel.id, { color: "" })));
  if (state.inspectorMode === "settings" && state.settingsCategory === "appearance") renderSettingsInspector();
  toast(`${panels.length} pane${panels.length === 1 ? "" : "s"} cleared.`);
  return true;
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
    button.onclick = () => applyBackgroundPreset(preset);
    grid.append(button);
  }
  return grid;
}

function applyBackgroundPreset(preset, options = {}) {
  if (!preset) return false;
  const changed = updateSettings(backgroundImageSettings(preset.value), { immediate: true });
  if (!changed) {
    if (options.toast !== false) toast(`${preset.label} background already active.`);
    return false;
  }
  if (state.inspectorMode === "settings") renderSettingsInspector();
  if (options.toast) toast(`${preset.label} background applied.`);
  return true;
}

function savedBackgroundImagesPanel() {
  const panel = document.createElement("div");
  panel.className = "saved-background-panel";
  panel.dataset.settingsSearch = normalizeSettingsQuery("saved background image wallpaper library url file apply rename delete save");

  const addRow = document.createElement("div");
  addRow.className = "saved-background-add";
  const input = document.createElement("input");
  input.className = "setting-control saved-background-input";
  input.placeholder = "URL or C:\\path\\image.png";
  input.dataset.settingsSearch = normalizeSettingsQuery("saved background image url local path file add apply save");
  input.addEventListener("keydown", async (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      const saved = await withDisabledControl(input, () => applyAndSaveCustomBackgroundImage({ url: input.value }));
      if (saved) input.value = "";
    }
  });
  const saveUrl = settingsActionButton("Save image", async () => {
    const saved = await withDisabledControl(input, () => saveCustomBackgroundImage({ url: input.value }));
    if (saved) input.value = "";
  }, "", "saved background image url local path file add");
  addRow.append(input, saveUrl);
  panel.append(addRow);

  const actions = document.createElement("div");
  actions.className = "settings-actions saved-background-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("saved background current choose local file wallpaper apply save");
  const applyAndSave = settingsActionButton("Apply + save", async () => {
    const saved = await withDisabledControl(input, () => applyAndSaveCustomBackgroundImage({ url: input.value }));
    if (saved) input.value = "";
  }, "", "saved background image apply save url local path file wallpaper");
  const saveCurrent = settingsActionButton("Save current", () => saveCustomBackgroundImage({
    url: state.settings.backgroundImage
  }), "", "saved background image current");
  saveCurrent.disabled = !isCustomBackgroundImage(state.settings.backgroundImage);
  actions.append(
    applyAndSave,
    saveCurrent,
    settingsActionButton("Choose + save", () => chooseBackgroundImage({ save: true }), "", "saved background image choose local file wallpaper")
  );
  panel.append(actions);
  installBackgroundDropTarget(panel, { input, save: true });

  if (state.savedBackgroundImages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "saved-background-empty";
    empty.textContent = "Save URL or local image backgrounds here so they can be applied again without pasting the path.";
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
    preview.style.setProperty("--saved-background-repeat", backgroundRepeatCss(background.url));
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
    const open = settingsActionButton("Open", () => openBackgroundImageSource(background.url), "", `open saved background source ${background.label}`);
    open.disabled = !canOpenBackgroundImageSource(background.url);
    cardActions.append(
      settingsActionButton("Apply", () => applySavedBackgroundImage(background.id), "", `apply saved background ${background.label}`),
      open,
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
      const changed = updateSettings({ browserHomeUrl: url });
      toast(changed ? "Browser home updated." : "Browser home already uses this page.");
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
  button.onclick = (event) => {
    if (button.disabled || button.classList.contains("is-busy")) return;
    let result = null;
    try {
      result = onClick?.(event);
    } catch (error) {
      console.error(error);
      toast(`${label} failed.`);
      return;
    }
    if (!result || typeof result.then !== "function") return;
    runSettingsAction(button, label, result);
  };
  return button;
}

async function withDisabledControl(control, task) {
  if (control?.disabled) return null;
  const wasDisabled = Boolean(control?.disabled);
  if (control) control.disabled = true;
  try {
    return await task();
  } finally {
    if (control?.isConnected) control.disabled = wasDisabled;
  }
}

async function runSettingsAction(button, label, promise) {
  const previousText = button.textContent;
  button.disabled = true;
  button.classList.add("is-busy");
  button.setAttribute("aria-busy", "true");
  button.textContent = "Working";
  try {
    await promise;
  } catch (error) {
    console.error(error);
    toast(`${label} failed.`);
  } finally {
    if (!button.isConnected) return;
    button.disabled = false;
    button.classList.remove("is-busy");
    button.removeAttribute("aria-busy");
    button.textContent = previousText || label;
  }
}

async function chooseBackgroundImage(options = {}) {
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return;
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return;
  if (options.save) {
    const saved = await applyAndSaveCustomBackgroundImage({ url }, { render: false });
    if (!saved) return;
    renderSettingsInspector();
    return;
  }
  const changed = await applyCustomBackgroundImage(url, { render: false, toast: true });
  if (changed === null) return;
  renderSettingsInspector();
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
    settingsActionButton("Update", () => updateSavedSettingsProfile(profile.id), "", `update settings profile ${profile.label} overwrite current settings`),
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

async function updateSavedSettingsProfile(profileId) {
  const profile = state.savedSettingsProfiles.find((candidate) => candidate.id === profileId);
  if (!profile) return;
  if (!await showConfirmDialog({
    title: "Update profile",
    message: `Replace "${profile.label}" with the current settings?`,
    confirmLabel: "Update"
  })) return;
  const updated = upsertSavedSettingsProfile({
    ...profile,
    settings: state.settings,
    createdAt: profile.createdAt
  });
  if (!updated) return;
  renderSettingsInspector();
  toast(`${profile.label} profile updated.`);
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
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("workspace blueprints saved layout pane template terminal browser split apply new save update rename delete");

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
    settingsActionButton("Update", () => updateWorkspaceBlueprint(blueprint.id), "", `update workspace blueprint ${blueprint.label} current layout`),
    settingsActionButton("Rename", () => renameWorkspaceBlueprint(blueprint.id), "", `rename workspace blueprint ${blueprint.label}`),
    settingsActionButton("Delete", () => deleteWorkspaceBlueprint(blueprint.id), "danger", `delete workspace blueprint ${blueprint.label}`)
  );
  card.append(text, actions);
  return card;
}

function currentWorkspaceBlueprintSnapshot(label, overrides = {}) {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length === 0) return null;
  const direction = paneLayoutDirection(workspace);
  if (!zoomedPanelIdForWorkspace(workspace) && workspace.id === state.data?.activeWorkspaceId) {
    persistPaneLayoutFromGrid(direction);
  }
  const equalWeight = Math.round(paneLayoutScale / Math.max(1, workspace.panels.length));
  return normalizeWorkspaceBlueprint({
    id: overrides.id || createWorkspaceBlueprintId(),
    label,
    splitDirection: direction,
    color: workspace.color || "",
    cwd: workspace.cwd || "",
    createdAt: overrides.createdAt,
    panels: workspace.panels.slice(0, workspaceBlueprintPanelLimit).map((panel) => ({
      type: panel.type,
      title: panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal"),
      color: panel.color || "",
      cwd: panel.cwd || workspace.cwd || "",
      shellProfile: panel.shellProfile || state.settings.terminalProfile,
      shellPath: panel.shellPath || "",
      terminalFontSize: panel.terminalFontSize || 0,
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

async function updateWorkspaceBlueprint(blueprintId) {
  const blueprint = state.workspaceBlueprints.find((candidate) => candidate.id === blueprintId);
  if (!blueprint) return;
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length === 0) {
    toast("Open panes before updating a blueprint.");
    return;
  }
  if (!await showConfirmDialog({
    title: "Update blueprint",
    message: `Replace "${blueprint.label}" with the current workspace layout?`,
    confirmLabel: "Update"
  })) return;
  const updated = upsertWorkspaceBlueprint(currentWorkspaceBlueprintSnapshot(blueprint.label, {
    id: blueprint.id,
    createdAt: blueprint.createdAt
  }));
  if (!updated) return;
  renderSettingsInspector();
  toast(`${blueprint.label} blueprint updated.`);
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
        terminalFontSize: panel.terminalFontSize,
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
  state.contextMenu.scrollTop = 0;
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
  if (isPendingPanel(panel)) {
    menu.replaceChildren(
      title,
      contextMenuButton(panel.type === "browser" ? "Opening..." : "Starting...", () => {}, true)
    );
    showContextMenuAt(menu, event.clientX, event.clientY);
    return;
  }
  const isTerminal = panel.type === "terminal";
  const isBrowser = panel.type === "browser";
  const generalActions = contextMenuActionGroup(
    contextMenuButton("Rename", () => renamePanel(panel)),
    contextMenuButton("Duplicate", () => duplicatePanel(panel)),
    isTerminal
      ? contextMenuButton("New terminal tab", () => createPanel("terminal", "right", { anchorPanelId: panel.id }))
      : contextMenuButton("New browser tab", () => newBrowserTabFromPanel(panel)),
    contextMenuButton("Split right", () => splitPanel(panel, "right")),
    contextMenuButton("Split down", () => splitPanel(panel, "down")),
    contextMenuButton(isPanelMinimized(panel) ? "Restore pane" : "Minimize pane", () => togglePaneMinimized(panel.id))
  );
  const surfaceActions = [];
  if (isTerminal) {
    surfaceActions.push(
      contextMenuButton("Find", () => openTerminalSearch(panel)),
      contextMenuButton("Find next", () => findNextInTerminal(panel)),
      contextMenuButton("Copy selection", () => copyActiveTerminalSelection(panel)),
      contextMenuButton("Paste", () => pasteClipboardToTerminal(panel)),
      contextMenuButton("Clear terminal", () => clearTerminalPanel(panel)),
      contextMenuButton("Text larger", () => changePaneTerminalFontSize(panel.id, 1)),
      contextMenuButton("Text smaller", () => changePaneTerminalFontSize(panel.id, -1)),
      contextMenuButton("Reset text size", () => resetPaneTerminalFontSize(panel.id), !panelHasTerminalFontSize(panel)),
      contextMenuButton("Restart terminal", () => restartPanel(panel.id)),
      contextMenuButton("Terminal settings", () => openSettingsCategory("terminal"))
    );
  }
  if (isBrowser) {
    surfaceActions.push(
      contextMenuButton("Focus address", () => focusBrowserAddress(panel)),
      contextMenuButton("Reload page", () => reloadBrowserPanel(panel)),
      contextMenuButton("Open externally", () => openBrowserPanelExternally(panel)),
      contextMenuButton(t("browser.openWithProfile"), () => showExternalBrowserProfileMenuAt(event.clientX, event.clientY, browserPanelUrl(panel)), false, "", { keepOpen: true }),
      contextMenuButton("Copy URL", () => copyBrowserPanelUrl(panel)),
      contextMenuButton("Browser settings", () => openSettingsCategory("browser"))
    );
  }
  const layoutActions = contextMenuActionGroup(
    contextMenuButton("Set pane size", () => promptPanelLayoutPercent(panel), found.workspace.panels.length <= 1),
    contextMenuButton(isPanelZoomed(panel, found.workspace) ? "Show all panes" : "Focus pane", () => togglePaneZoom(panel.id)),
    contextMenuButton("Move left", () => movePanelLeft(found.workspace, index), index <= 0),
    contextMenuButton("Move right", () => movePanelRight(found.workspace, index), index >= found.workspace.panels.length - 1)
  );
  const closeActions = contextMenuActionGroup(
    contextMenuButton("Close other panes", () => closeOtherPanes(panel.id), found.workspace.panels.length <= 1, "danger"),
    contextMenuButton("Close panes to right", () => closePanelsById(panesToRight.map((candidate) => candidate.id)), panesToRight.length === 0, "danger"),
    contextMenuButton("Close", () => closePanel(panel.id), false, "danger")
  );
  const colorTitle = document.createElement("div");
  colorTitle.className = "context-section-title";
  colorTitle.textContent = "Tab color";
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
  const saveColor = contextMenuButton("Save color", () => upsertCustomColorPalette(panel.color), !normalizeCustomPaletteColor(panel.color));
  const customColor = contextColorPicker(panel.color, (color) => updatePanel(panel.id, { color }));
  const nodes = [
    title,
    contextMenuSectionTitle("Tab"),
    generalActions
  ];
  if (surfaceActions.length) {
    nodes.push(contextMenuSectionTitle(isTerminal ? "Terminal" : "Browser"), contextMenuActionGroup(...surfaceActions));
  }
  nodes.push(
    contextMenuSectionTitle("Layout"),
    layoutActions,
    contextMenuSectionTitle("Close"),
    closeActions,
    colorTitle,
    colors,
    customColor,
    contextMenuActionGroup(saveColor, clear)
  );
  menu.replaceChildren(...nodes);
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
  const saveColor = contextMenuButton("Save color", () => upsertCustomColorPalette(workspace.color), !normalizeCustomPaletteColor(workspace.color));
  menu.replaceChildren(
    title,
    meta,
    actions,
    contextMenuSectionTitle("Workspace color"),
    colors,
    customColor,
    contextMenuActionGroup(saveColor)
  );
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function showPaneSplitterContextMenu(event, splitter) {
  event.preventDefault();
  event.stopPropagation();
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1) return;
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const percent = clampPaneLayoutPercent(Number(splitter?.dataset.resizePercent || 50));
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = `Split ${percent}% / ${100 - percent}%`;
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = splitter?.dataset.orientation === "down" ? "Rows" : "Columns";
  const presets = contextMenuActionGroup(
    ...[10, 25, 33, 50, 67, 75, 90].map((nextPercent) => (
      contextMenuButton(`${nextPercent}% / ${100 - nextPercent}%`, () => setPaneSplitterPercent(splitter, nextPercent, { toast: true }), percent === nextPercent)
    ))
  );
  const actions = contextMenuActionGroup(
    contextMenuButton("Set exact size...", () => promptPaneSplitterPercent(splitter)),
    contextMenuButton("Equalize this split", () => equalizePaneSplitter(splitter), percent === 50),
    contextMenuButton("Reset all splits", resetActivePaneLayout)
  );
  menu.replaceChildren(title, meta, presets, actions);
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function showToolbarMenu(event) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  menu.className = "context-menu context-menu-tools";
  const panel = focusedPanel();
  const workspace = activeWorkspace();
  const multiPane = Boolean(panel && workspace?.panels.length > 1);
  const multiWorkspace = (state.data?.workspaces.length || 0) > 1;
  const hasPreviousPane = Boolean(previousPanelForWorkspace(workspace));
  const hasPreviousWorkspace = Boolean(previousWorkspace());
  const terminalActive = panel?.type === "terminal";
  const browserActive = panel?.type === "browser";
  const latestBrowserPage = state.recentBrowserPages[0] || "";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = workspace?.title || "Workspace tools";
  menu.replaceChildren(
    title,
    contextMenuSectionTitle("Pane"),
    contextMenuActionGroup(
      contextMenuButton("Split right", () => splitActivePanel("right")),
      contextMenuButton("Split down", () => splitActivePanel("down")),
      contextMenuButton("Duplicate active pane", duplicateActivePanel, !panel),
      contextMenuButton("Reopen closed pane", reopenClosedPanel, state.closedPanels.length === 0),
      contextMenuButton(zoomedPanelIdForWorkspace(workspace) ? "Show all panes" : "Focus active pane", () => togglePaneZoom(), !panel),
      contextMenuButton("Minimize active pane", minimizeActivePane, !panel),
      contextMenuButton("Restore minimized panes", () => restoreMinimizedPanes(workspace), minimizedPanelCount(workspace) === 0),
      contextMenuButton("Next pane", () => cycleActivePane(1), !multiPane),
      contextMenuButton("Previous pane", () => cycleActivePane(-1), !multiPane),
      contextMenuButton("Last active pane", focusLastPane, !hasPreviousPane)
    ),
    contextMenuSectionTitle("Layout"),
    contextMenuActionGroup(
      contextMenuButton("Reset split layout", resetActivePaneLayout, !multiPane),
      contextMenuButton("Reset workspace chrome", resetWorkspaceChrome),
      contextMenuButton("Equalize panes", () => applyPaneLayoutPreset("equal"), !multiPane),
      contextMenuButton("Grid layout", () => applyPaneLayoutPreset("grid"), !multiPane),
      contextMenuButton("Active pane wide", () => applyPaneLayoutPreset("activeWide"), !multiPane),
      contextMenuButton("Active pane tall", () => applyPaneLayoutPreset("activeTall"), !multiPane),
      contextMenuButton("Set active pane size", promptActivePaneLayoutPercent, !multiPane),
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
      contextMenuButton("New browser tab", () => newBrowserTabFromPanel(panel), !browserActive),
      contextMenuButton("Focus address", () => focusBrowserAddress(panel), !browserActive),
      contextMenuButton("Reload active page", () => reloadBrowserPanel(panel), !browserActive),
      contextMenuButton("Open active externally", () => openBrowserPanelExternally(panel), !browserActive),
      contextMenuButton("Copy active URL", () => copyBrowserPanelUrl(panel), !browserActive),
      contextMenuButton("Open home page", () => createPanel("browser", "right", { workspaceId: workspace?.id, url: state.settings.browserHomeUrl }), !workspace),
      contextMenuButton(latestBrowserPage ? `Open recent: ${hostnameOf(latestBrowserPage)}` : "Open recent page", () => createPanel("browser", "right", { workspaceId: workspace?.id, url: latestBrowserPage }), !latestBrowserPage || !workspace),
      contextMenuButton("Browser settings", () => openSettingsCategory("browser"))
    ),
    contextMenuSectionTitle("Workspace"),
    contextMenuActionGroup(
      contextMenuButton("Next workspace", () => cycleWorkspace(1), !multiWorkspace),
      contextMenuButton("Previous workspace", () => cycleWorkspace(-1), !multiWorkspace),
      contextMenuButton("Last workspace", focusLastWorkspace, !hasPreviousWorkspace),
      contextMenuButton("Rename workspace", renameActiveWorkspace),
      contextMenuButton("Change workspace color", cycleWorkspaceColor),
      contextMenuButton("Change workspace folder", () => chooseWorkspaceFolder(), !workspace),
      contextMenuButton("Open workspace folder", () => openWorkspaceFolder(), !workspace?.cwd),
      contextMenuButton("New workspace from folder", () => createWorkspaceFromFolder()),
      contextMenuButton("Save workspace blueprint", saveCurrentWorkspaceBlueprint, !panel),
      contextMenuButton("Close empty workspaces", closeEmptyWorkspaces, !hasEmptyWorkspaceCleanupTargets(), "danger")
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
      contextMenuButton("Save current background", () => saveCustomBackgroundImage({ url: state.settings.backgroundImage }), !isCustomBackgroundImage(state.settings.backgroundImage)),
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
  menu.scrollTop = 0;
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

function contextMenuButton(label, action, disabled = false, tone = "", options = {}) {
  const button = document.createElement("button");
  button.className = `context-action${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  button.textContent = label;
  button.disabled = disabled;
  button.onclick = (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (disabled) return;
    action();
    if (!options.keepOpen) hideContextMenu();
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

function splitPanel(panel, direction, type = "terminal", options = {}) {
  const found = findPanelState(panel?.id);
  if (!found) return null;
  return createPanel(type, direction, {
    ...options,
    workspaceId: found.workspace.id,
    anchorPanelId: panel.id
  });
}

function splitActivePanel(direction, type = "terminal", options = {}) {
  const panel = focusedPanel();
  if (panel) return splitPanel(panel, direction, type, options);
  return createPanel(type, direction, options);
}

function splitPanelFromPaneId(panelId, direction, type = "terminal", options = {}) {
  const found = findPanelState(panelId);
  if (!found) return null;
  return splitPanel(found.panel, direction, type, options);
}

function duplicatePanel(panel) {
  if (panel.type === "browser") {
    splitPanel(panel, "right", "browser", {
      url: panel.url || state.settings.browserHomeUrl,
      browserTabs: browserTabSnapshotForPanelId(panel.id, panel.url || state.settings.browserHomeUrl)
    });
    return;
  }
  splitPanel(panel, "right", "terminal", {
    shellProfile: panel.shellProfile || state.settings.terminalProfile,
    shellPath: panel.shellPath || state.settings.terminalCustomShell,
    terminalFontSize: panel.terminalFontSize || 0
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

function promptPanelLayoutPercent(panel) {
  const found = findPanelState(panel?.id);
  if (!found) return false;
  state.data.activeWorkspaceId = found.workspace.id;
  found.workspace.activePanelId = panel.id;
  render();
  return promptActivePaneLayoutPercent();
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
  if (state.paletteRenderFrame) return;
  const run = () => {
    state.paletteRenderFrame = 0;
    renderPalette();
  };
  state.paletteRenderFrame = requestAnimationFrame(run);
}

function flushPaletteRender() {
  if (!state.paletteRenderFrame) return;
  if (state.paletteRenderFrame) cancelAnimationFrame(state.paletteRenderFrame);
  state.paletteRenderFrame = 0;
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
  for (const preset of settingsPresets) {
    const summary = settingsProfileSummary(preset.settings);
    entries.push({
      id: `settingsPreset.${preset.id}`,
      label: `Preset: ${preset.label}`,
      meta: preset.body || summary,
      shortcut: "Preset",
      search: normalizeSettingsQuery(`settings preset profile setup apply ${preset.label} ${preset.body} ${summary}`),
      run: () => applySettingsPreset(preset)
    });
  }
  for (const preset of backgroundPresets) {
    entries.push({
      id: `backgroundPreset.${preset.value || "none"}`,
      label: `Background preset: ${preset.label}`,
      meta: preset.value ? "Built-in background" : "No background",
      shortcut: "Look",
      search: normalizeSettingsQuery(`background preset image wallpaper look apply ${preset.label} ${preset.value}`),
      run: () => applyBackgroundPreset(preset, { toast: true })
    });
  }
  for (const preset of browserHomePresets) {
    entries.push({
      id: `browserHomePreset.${preset.id}`,
      label: `Browser home: ${preset.label}`,
      meta: preset.url,
      shortcut: "Browser",
      search: normalizeSettingsQuery(`browser home preset start page homepage apply ${preset.label} ${preset.body} ${preset.url}`),
      run: () => applyBrowserHomePreset(preset)
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

function cancelPaletteFocus() {
  if (!state.paletteFocusFrame) return;
  cancelAnimationFrame(state.paletteFocusFrame);
  state.paletteFocusFrame = 0;
}

function schedulePaletteFocus() {
  cancelPaletteFocus();
  state.paletteFocusFrame = requestAnimationFrame(() => {
    state.paletteFocusFrame = 0;
    if (!state.paletteOpen) return;
    elements.paletteInput.focus({ preventScroll: true });
  });
}

function openPalette() {
  state.paletteOpen = true;
  state.paletteIndex = 0;
  renderPalette();
  elements.paletteList.scrollTop = 0;
  schedulePaletteFocus();
}

function closePalette() {
  state.paletteOpen = false;
  cancelPaletteFocus();
  elements.paletteList.scrollTop = 0;
  renderPalette();
}

function runPaletteCommand(entry) {
  closePalette();
  elements.paletteInput.value = "";
  entry.run();
}

async function createWorkspace(options = {}) {
  const previousWorkspaceId = state.data?.activeWorkspaceId || "";
  const workspace = await api("/api/workspaces", {
    method: "POST",
    body: JSON.stringify({
      title: options.title,
      cwd: options.cwd
    })
  });
  if (options.cwd) rememberRecentFolder(workspace.cwd || options.cwd);
  await loadState();
  if (workspace?.id && workspace.id !== previousWorkspaceId) rememberPreviousWorkspace(previousWorkspaceId);
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
  await updateWorkspace(workspace.id, { title: trimmed });
}

async function cycleWorkspaceColor(workspaceId = activeWorkspace()?.id) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  const palette = workspaceColorPalette();
  if (!workspace || palette.length === 0) return;
  const currentIndex = Math.max(0, palette.indexOf(workspace.color));
  const color = palette[(currentIndex + 1) % palette.length];
  await updateWorkspace(workspace.id, { color });
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
  const ok = await updateWorkspace(workspace.id, { cwd });
  if (!ok) return;
  rememberRecentFolder(cwd);
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
  await updateWorkspace(workspace.id, { color });
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

async function closeEmptyWorkspaces() {
  const targets = emptyWorkspaceCleanupTargets();
  if (targets.length === 0) {
    toast(emptyWorkspaces().length ? "One empty workspace stays available." : "No empty workspaces to close.");
    return false;
  }
  const label = `${targets.length} empty workspace${targets.length === 1 ? "" : "s"}`;
  if (!await showConfirmDialog({
    title: "Close empty workspaces",
    message: `Close ${label}? Workspaces with panes stay open.`,
    confirmLabel: "Close",
    danger: true
  })) return false;
  const targetIds = targets.map((workspace) => workspace.id);
  for (const workspaceId of targetIds) {
    state.paneTrees.delete(workspaceId);
  }
  savePaneTreeLayouts(state.paneTrees);
  await Promise.all(targetIds.map((workspaceId) => api(`/api/workspaces/${workspaceId}`, { method: "DELETE" })));
  await loadState();
  renderSettingsInspector();
  toast(`Closed ${label}.`);
  return true;
}

function createPendingPanelId() {
  return `pending_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function createPendingPanel(type, workspace, options = {}) {
  const isBrowser = type === "browser";
  return {
    id: createPendingPanelId(),
    workspaceId: workspace.id,
    type,
    title: options.title || (isBrowser ? "Opening browser" : "Starting terminal"),
    titleLocked: Boolean(options.title || options.titleLocked),
    color: options.color || "",
    cwd: options.cwd || workspace.cwd || "",
    cwdShort: workspace.cwdShort || "~",
    branch: "",
    shellProfile: type === "terminal" ? options.shellProfile || state.settings.terminalProfile : "",
    shellPath: type === "terminal" ? options.shellPath || "" : "",
    terminalFontSize: type === "terminal" ? normalizeTerminalFontSize(options.terminalFontSize, 0) : 0,
    url: isBrowser ? options.url || state.settings.browserHomeUrl : "",
    needsAttention: false,
    notificationText: "",
    pendingStartedAt: Date.now(),
    pending: true
  };
}

function addPendingPanel(workspace, panel, anchorPanelId, direction, options = {}) {
  if (!workspace || !panel?.id) return false;
  state.pendingPanels.set(panel.id, panel);
  insertPanelInPaneTree(workspace.id, anchorPanelId, panel.id, direction);
  const added = optimisticAddPanel(panel, workspace.id, { direction, focus: options.focus });
  ensurePendingPaneTimer();
  updateOperationChrome();
  return added;
}

function deferCreatedTerminalInitUntilPaint(panel, workspace) {
  if (
    panel?.type !== "terminal"
    || !workspace
    || workspace.activePanelId !== panel.id
    || state.terminals.has(panel.id)
    || isPanelMinimized(panel)
    || isPendingPanel(panel)
  ) {
    return false;
  }
  state.paintDeferredTerminalInitPanelIds.add(panel.id);
  return true;
}

function remapCachedPanelElement(previousPanelId, nextPanelId) {
  const pane = state.paneCache.get(previousPanelId);
  if (pane && !state.paneCache.has(nextPanelId)) {
    state.paneCache.delete(previousPanelId);
    state.paneCache.set(nextPanelId, pane);
    setDatasetIfChanged(pane, "panelId", nextPanelId);
  }
  const tab = state.surfaceTabButtons.get(previousPanelId);
  if (tab && !state.surfaceTabButtons.has(nextPanelId)) {
    state.surfaceTabButtons.delete(previousPanelId);
    state.surfaceTabButtons.set(nextPanelId, tab);
    setDatasetIfChanged(tab, "panelId", nextPanelId);
  }
}

function remapPanelStateId(previousPanelId, nextPanelId, workspaceId) {
  if (!previousPanelId || !nextPanelId || previousPanelId === nextPanelId) return;
  remapCachedPanelElement(previousPanelId, nextPanelId);
  const tree = state.paneTrees.get(workspaceId);
  if (tree) {
    state.paneTrees.set(workspaceId, replacePaneTreePanelId(tree, previousPanelId, nextPanelId));
    savePaneTreeLayouts(state.paneTrees);
  }
  const layout = state.paneLayouts.get(previousPanelId);
  if (layout && !state.paneLayouts.has(nextPanelId)) state.paneLayouts.set(nextPanelId, layout);
  state.paneLayouts.delete(previousPanelId);
  if (state.zoomedPanelId === previousPanelId) state.zoomedPanelId = nextPanelId;
  if (state.focusedPanelId === previousPanelId) state.focusedPanelId = nextPanelId;
  if (state.lastInteractedPanelId === previousPanelId) state.lastInteractedPanelId = nextPanelId;
  for (const [mappedWorkspaceId, panelId] of [...state.previousPanelIds.entries()]) {
    if (panelId === previousPanelId) state.previousPanelIds.set(mappedWorkspaceId, nextPanelId);
  }
  if (state.dragPanelId === previousPanelId) state.dragPanelId = nextPanelId;
  for (const [mappedWorkspaceId, panelId] of [...state.zoomedPanelIds.entries()]) {
    if (panelId === previousPanelId) state.zoomedPanelIds.set(mappedWorkspaceId, nextPanelId);
  }
  if (state.minimizedPanelIds.delete(previousPanelId)) state.minimizedPanelIds.add(nextPanelId);
}

function removePendingPanel(panelId, options = {}) {
  const found = findPanelState(panelId);
  state.pendingPanels.delete(panelId);
  stopPendingPaneTimerIfIdle();
  removePanelFromAllPaneTrees(panelId);
  cleanupPanel(panelId);
  if (!found) return false;
  found.workspace.panels = found.workspace.panels.filter((panel) => panel.id !== panelId);
  if (found.workspace.activePanelId === panelId) {
    found.workspace.activePanelId = firstUnminimizedPanel(found.workspace)?.id || found.workspace.panels[0]?.id || null;
  }
  if (state.focusedPanelId === panelId) state.focusedPanelId = found.workspace.activePanelId || null;
  if (state.lastInteractedPanelId === panelId) state.lastInteractedPanelId = found.workspace.activePanelId || null;
  refreshWorkspaceCounts(found.workspace);
  if (options.render !== false) render();
  return true;
}

function cancelPendingPanel(panelId) {
  if (!panelId || !state.pendingPanels.has(panelId)) return false;
  state.canceledPendingPanelIds.add(panelId);
  const removed = removePendingPanel(panelId);
  for (const operation of state.uiOperations.values()) {
    if (operation.kind === "create-panel") operation.label = "Canceling pane startup...";
  }
  updateOperationChrome();
  toast("Pane startup canceled.");
  return removed;
}

async function replacePendingPanel(pendingPanelId, createdPanel, workspaceId, options = {}) {
  if (state.canceledPendingPanelIds.delete(pendingPanelId)) {
    if (createdPanel?.id) {
      try {
        await api(`/api/panels/${createdPanel.id}`, { method: "DELETE" });
      } finally {
        await loadState();
      }
    }
    return false;
  }
  const wasPending = state.pendingPanels.has(pendingPanelId);
  state.pendingPanels.delete(pendingPanelId);
  stopPendingPaneTimerIfIdle();
  if (!createdPanel?.id) {
    removePendingPanel(pendingPanelId);
    return false;
  }
  if (!wasPending) {
    const existing = findPanelState(createdPanel.id);
    if (existing) {
      cleanupPanel(pendingPanelId);
      return true;
    }
  }
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === (createdPanel.workspaceId || workspaceId));
  if (!workspace) return false;
  const nextPanel = {
    ...createdPanel,
    workspaceId: workspace.id
  };
  const existingIndex = workspace.panels.findIndex((panel) => panel.id === createdPanel.id);
  const pendingIndex = workspace.panels.findIndex((panel) => panel.id === pendingPanelId);
  if (pendingIndex < 0 && existingIndex >= 0) {
    if (workspace.activePanelId === pendingPanelId || options.focus !== false) workspace.activePanelId = nextPanel.id;
    remapPanelStateId(pendingPanelId, nextPanel.id, workspace.id);
    cleanupPanel(pendingPanelId);
    workspace.cwd = nextPanel.cwd || workspace.cwd;
    refreshWorkspaceCounts(workspace);
    if (options.focus !== false) state.data.activeWorkspaceId = workspace.id;
    deferCreatedTerminalInitUntilPaint(nextPanel, workspace);
    render();
    return true;
  }
  if (existingIndex >= 0) workspace.panels.splice(existingIndex, 1);
  if (pendingIndex >= 0) workspace.panels.splice(pendingIndex, 1, nextPanel);
  else workspace.panels.push(nextPanel);
  if (workspace.activePanelId === pendingPanelId || options.focus !== false) workspace.activePanelId = nextPanel.id;
  remapPanelStateId(pendingPanelId, nextPanel.id, workspace.id);
  cleanupPanel(pendingPanelId);
  workspace.cwd = nextPanel.cwd || workspace.cwd;
  refreshWorkspaceCounts(workspace);
  if (options.focus !== false) state.data.activeWorkspaceId = workspace.id;
  deferCreatedTerminalInitUntilPaint(nextPanel, workspace);
  render();
  return true;
}

async function createPanel(type, direction = "right", options = {}) {
  if (options.operation !== false && paneCreationButtonsDisabled()) {
    toast("Pane is still being added.");
    return null;
  }
  const createStartedAt = performance.now();
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
    const anchorPanelId = options.anchorPanelId || "";
    const pendingPanel = options.pending === false
      ? null
      : createPendingPanel(type, workspace, {
        ...options,
        shellProfile,
        shellPath: shellProfile === "custom" ? shellPath : "",
        url
      });
    if (pendingPanel) addPendingPanel(workspace, pendingPanel, anchorPanelId, direction, options);
    let createdPanel = null;
    try {
      createdPanel = await api("/api/panels", {
        method: "POST",
        body: JSON.stringify({
          workspaceId: workspace.id,
          type,
          direction,
          title: options.title,
          color: options.color,
          shellProfile: type === "terminal" ? shellProfile : undefined,
          shellPath: type === "terminal" && shellProfile === "custom" ? shellPath : undefined,
          terminalFontSize: type === "terminal" ? options.terminalFontSize : undefined,
          cwd: options.cwd || workspace.cwd,
          url
        })
      });
    } catch (error) {
      state.paneCreateStats.failures += 1;
      if (pendingPanel) {
        removePendingPanel(pendingPanel.id);
        state.canceledPendingPanelIds.delete(pendingPanel.id);
      }
      throw error;
    }
    if (type === "browser" && createdPanel?.id && options.browserTabs) {
      state.browserTabSnapshots.set(createdPanel.id, normalizeBrowserTabSnapshot(options.browserTabs, createdPanel.url || url));
      saveBrowserTabSnapshots(state.browserTabSnapshots);
    }
    if (pendingPanel) await replacePendingPanel(pendingPanel.id, createdPanel, workspace.id, options);
    else {
      insertPanelInPaneTree(workspace.id, anchorPanelId, createdPanel?.id, direction);
      optimisticAddPanel(createdPanel, workspace.id, { direction, focus: options.focus });
    }
    if (type === "browser" && createdPanel?.url) rememberRecentBrowserPage(createdPanel.url);
    recordPaneCreateDuration(type, performance.now() - createStartedAt);
    return createdPanel;
  };
  if (options.operation === false) return addPanel();
  const label = options.operationLabel
    || `Adding ${type === "browser" ? "browser" : "terminal"} pane...`;
  const operationKey = options.pending === false
    ? "create-panel"
    : `create-panel:${Date.now().toString(36)}:${Math.random().toString(36).slice(2, 8)}`;
  return withUiOperation(operationKey, "create-panel", label, addPanel);
}

async function openBrowserPrompt(workspaceId = null) {
  const url = await showTextDialog({
    title: "Open browser",
    value: state.settings.browserHomeUrl,
    placeholder: "Search or URL",
    confirmLabel: "Open"
  });
  if (url === null) return;
  if (state.settings.browserLaunchMode === "external") {
    await openExternalBrowser(url);
    return true;
  }
  await createPanel("browser", "right", { url, workspaceId });
}

function openBrowserHome(workspaceId = activeWorkspace()?.id, options = {}) {
  const launchMode = options.mode || state.settings.browserLaunchMode;
  if (launchMode === "external") {
    return openExternalBrowser(state.settings.browserHomeUrl);
  }
  return createPanel("browser", "right", { url: state.settings.browserHomeUrl, workspaceId });
}

function refreshWorkspaceCounts(workspace) {
  if (!workspace) return;
  workspace.terminalCount = workspace.panels.filter((panel) => panel.type === "terminal").length;
  workspace.browserCount = workspace.panels.filter((panel) => panel.type === "browser").length;
}

function optimisticAddPanel(panel, workspaceId, options = {}) {
  if (!panel?.id || findPanelState(panel.id)) return false;
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === (panel.workspaceId || workspaceId));
  if (!workspace) return false;
  const activeWorkspaceId = state.data.activeWorkspaceId;
  const nextPanel = {
    ...panel,
    workspaceId: workspace.id
  };
  const previousPanelId = workspace.activePanelId;
  workspace.panels = workspace.panels.filter((candidate) => candidate.id !== nextPanel.id);
  workspace.panels.push(nextPanel);
  workspace.activePanelId = nextPanel.id;
  if (options.focus !== false) {
    rememberPreviousPanel(workspace, previousPanelId);
    if (activeWorkspaceId !== workspace.id) rememberPreviousWorkspace(activeWorkspaceId);
    state.lastInteractedPanelId = nextPanel.id;
    clearDifferentZoomedPanelOnFocus(workspace, nextPanel.id);
  }
  workspace.cwd = nextPanel.cwd || workspace.cwd;
  if (options.direction === "down" || options.direction === "right") {
    workspace.splitDirection = options.direction;
  }
  if (options.focus !== false) state.data.activeWorkspaceId = workspace.id;
  else state.data.activeWorkspaceId = activeWorkspaceId;
  refreshWorkspaceCounts(workspace);
  render();
  return true;
}

function optimisticFocusWorkspace(workspaceId, options = {}) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return false;
  const previousPanelId = workspace.activePanelId;
  const panel = focusablePanelForWorkspace(workspace);
  if (panel) workspace.activePanelId = panel.id;
  state.focusedPanelId = panel?.id || null;
  state.lastInteractedPanelId = panel?.id || null;
  const renderFocusChange = () => {
    if (options.schedule) scheduleRender();
    else render();
  };
  if (state.data.activeWorkspaceId !== workspaceId) {
    state.data.activeWorkspaceId = workspaceId;
    renderFocusChange();
  } else if (workspace.activePanelId !== previousPanelId) {
    renderFocusChange();
  }
  return true;
}

function optimisticFocusPanel(panelId, options = {}) {
  const found = findPanelState(panelId);
  if (!found) return false;
  const previousWorkspaceId = state.data.activeWorkspaceId;
  const previousPanelId = found.workspace.activePanelId;
  const previousFocusedPanelId = state.focusedPanelId;
  const previousLastInteractedPanelId = state.lastInteractedPanelId;
  state.focusedPanelId = panelId;
  state.lastInteractedPanelId = panelId;
  const zoomChanged = clearDifferentZoomedPanelOnFocus(found.workspace, panelId);
  found.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = found.workspace.id;
  const changed = previousWorkspaceId !== found.workspace.id
    || previousPanelId !== panelId
    || previousFocusedPanelId !== panelId
    || previousLastInteractedPanelId !== panelId
    || zoomChanged;
  if (changed) {
    if (options.schedule) scheduleRender();
    else render();
  }
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

function focusSyncMatchesLocalState(sync) {
  if (!sync || !state.data) return false;
  if (sync.type === "workspace") {
    return state.data.activeWorkspaceId === sync.workspaceId
      && state.data.workspaces.some((workspace) => workspace.id === sync.workspaceId);
  }
  if (sync.type === "panel") {
    const found = findPanelState(sync.panelId);
    return Boolean(found
      && state.data.activeWorkspaceId === found.workspace.id
      && found.workspace.activePanelId === sync.panelId);
  }
  return false;
}

async function flushFocusSync(revision = state.focusSyncRevision) {
  const sync = state.pendingFocusSync;
  if (!sync || sync.revision !== revision) return;
  state.focusSyncTimer = 0;
  let confirmed = false;
  try {
    if (sync.type === "workspace") {
      await api(`/api/workspaces/${sync.workspaceId}/focus`, { method: "POST" });
      confirmed = true;
    } else if (sync.type === "panel") {
      await api(`/api/panels/${sync.panelId}/focus`, { method: "POST" });
      confirmed = true;
    }
  } catch {
    // Reconcile below; the target may have disappeared while the user kept working.
  } finally {
    if (state.pendingFocusSync?.revision === revision) {
      state.pendingFocusSync = null;
      if (!confirmed || !focusSyncMatchesLocalState(sync)) await loadState();
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
  if (state.focusedPanelId === panelId) state.focusedPanelId = null;
  state.minimizedPanelIds.delete(panelId);
  state.pendingPanels.delete(panelId);
  for (const [workspaceId, zoomedPanelId] of [...state.zoomedPanelIds.entries()]) {
    if (zoomedPanelId === panelId) state.zoomedPanelIds.delete(workspaceId);
  }
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
    if (title) {
      found.panel.title = title.slice(0, 80);
      found.panel.titleLocked = true;
    }
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    found.panel.color = isAllowedUiColor(color, state.data?.palette || accentOptions) ? color : "";
  }
  if (Object.hasOwn(updates, "url") && found.panel.type === "browser") {
    found.panel.url = normalizeUrl(updates.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
  }
  if (Object.hasOwn(updates, "terminalFontSize") && found.panel.type === "terminal") {
    found.panel.terminalFontSize = normalizeTerminalFontSize(updates.terminalFontSize, 0);
  }
  if (updates.direction === "down" || updates.direction === "right") {
    panelWorkspace.splitDirection = updates.direction;
  }
  render();
  return true;
}

function panelUpdateReconcileNeeded(panelId, updates = {}) {
  const found = findPanelState(panelId);
  if (!found) return true;
  if (Object.hasOwn(updates, "workspaceId") && found.workspace.id !== updates.workspaceId) return true;
  if (Object.hasOwn(updates, "beforePanelId")) {
    const panelIndex = found.workspace.panels.findIndex((panel) => panel.id === panelId);
    const beforeIndex = found.workspace.panels.findIndex((panel) => panel.id === updates.beforePanelId);
    if (beforeIndex >= 0 && panelIndex !== beforeIndex - 1) return true;
  }
  if (updates.moveToEnd) {
    const panelIndex = found.workspace.panels.findIndex((panel) => panel.id === panelId);
    if (panelIndex !== found.workspace.panels.length - 1) return true;
  }
  if (Object.hasOwn(updates, "title")) {
    const title = String(updates.title || "").trim();
    if (title && found.panel.title !== title.slice(0, 80)) return true;
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    const expected = isAllowedUiColor(color, state.data?.palette || accentOptions) ? color : "";
    if ((found.panel.color || "") !== expected) return true;
  }
  if (Object.hasOwn(updates, "url") && found.panel.type === "browser") {
    const expected = normalizeUrl(updates.url || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    if (found.panel.url !== expected) return true;
  }
  if (Object.hasOwn(updates, "terminalFontSize") && found.panel.type === "terminal") {
    const expected = normalizeTerminalFontSize(updates.terminalFontSize, 0);
    if (normalizeTerminalFontSize(found.panel.terminalFontSize, 0) !== expected) return true;
  }
  if ((updates.direction === "down" || updates.direction === "right") && found.workspace.splitDirection !== updates.direction) {
    return true;
  }
  return false;
}

function closedPanelSnapshot(panelId) {
  const found = findPanelState(panelId);
  if (!found) return null;
  const isBrowser = found.panel.type === "browser";
  const url = found.panel.url || state.settings.browserHomeUrl;
  return {
    workspaceId: found.workspace.id,
    workspaceTitle: found.workspace.title || "Workspace",
    type: found.panel.type,
    title: found.panel.title || (isBrowser ? "Browser" : "Terminal"),
    titleLocked: Boolean(found.panel.titleLocked),
    color: found.panel.color || "",
    cwd: found.panel.cwd || found.workspace.cwd || "",
    shellProfile: found.panel.shellProfile || state.settings.terminalProfile,
    shellPath: found.panel.shellPath || "",
    terminalFontSize: found.panel.terminalFontSize || 0,
    url,
    browserTabs: isBrowser ? browserTabSnapshotForPanelId(found.panel.id, url) : null
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
      terminalFontSize: snapshot.terminalFontSize,
      url: snapshot.url,
      browserTabs: snapshot.browserTabs
    });
    toast(`Reopened ${created?.type === "browser" ? "browser" : "terminal"} pane.`);
  } catch {
    state.closedPanels.unshift(snapshot);
    toast("Could not reopen pane.");
  }
}

async function closePanel(panelId) {
  if (!panelId || isUiOperationActive(`close-panel:${panelId}`)) return;
  if (state.pendingPanels.has(panelId)) {
    cancelPendingPanel(panelId);
    return;
  }
  return withUiOperation(`close-panel:${panelId}`, "close-panel", "Closing pane...", async () => {
    state.pendingClosedPanelIds.add(panelId);
    rememberClosedPanel(panelId);
    removePanelFromAllPaneTrees(panelId);
    optimisticClosePanel(panelId);
    try {
      await api(`/api/panels/${panelId}`, { method: "DELETE" });
      await loadState();
    } catch {
      state.pendingClosedPanelIds.delete(panelId);
      await loadState();
      return;
    }
    state.pendingClosedPanelIds.delete(panelId);
  });
}

async function closePanelsById(panelIds) {
  const ids = [...new Set(panelIds.filter(Boolean))];
  if (ids.length === 0) return;
  const key = `close-panels:${ids.slice().sort().join(",")}`;
  if (isUiOperationActive(key)) return;
  const label = ids.length === 1 ? "Closing pane..." : `Closing ${ids.length} panes...`;
  return withUiOperation(key, "close-panel", label, async () => {
    for (const panelId of ids) state.pendingClosedPanelIds.add(panelId);
    let changed = false;
    for (const panelId of ids) {
      rememberClosedPanel(panelId);
      removePanelFromAllPaneTrees(panelId);
      changed = optimisticClosePanel(panelId, false) || changed;
    }
    if (changed) render();
    try {
      await Promise.all(ids.map((panelId) => api(`/api/panels/${panelId}`, { method: "DELETE" })));
      await loadState();
    } catch {
      for (const panelId of ids) state.pendingClosedPanelIds.delete(panelId);
      await loadState();
      return;
    }
    for (const panelId of ids) state.pendingClosedPanelIds.delete(panelId);
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
    const result = await api(`/api/panels/${panelId}`, {
      method: "PATCH",
      body: JSON.stringify(updates)
    });
    if (!result?.ok || panelUpdateReconcileNeeded(panelId, updates)) await loadState();
  } catch {
    await loadState();
  }
}

async function movePanelBefore(panelId, beforePanelId) {
  const workspace = activeWorkspace();
  if (!workspace || !panelId || !beforePanelId || panelId === beforePanelId) return;
  await updatePanel(panelId, { workspaceId: workspace.id, beforePanelId });
}

async function movePanelAfter(panelId, afterPanelId) {
  const workspace = activeWorkspace();
  if (!workspace || !panelId || !afterPanelId || panelId === afterPanelId) return;
  const targetIndex = workspace.panels.findIndex((panel) => panel.id === afterPanelId);
  if (targetIndex < 0) return;
  const nextPanel = workspace.panels.slice(targetIndex + 1).find((panel) => panel.id !== panelId);
  if (nextPanel) {
    await updatePanel(panelId, { workspaceId: workspace.id, beforePanelId: nextPanel.id });
    return;
  }
  await updatePanel(panelId, { workspaceId: workspace.id, moveToEnd: true });
}

async function movePanelRelative(panelId, targetPanelId, placement) {
  const found = findPanelState(targetPanelId);
  if (!found || !panelId || !targetPanelId || panelId === targetPanelId) return;
  if (placement === "center") {
    swapPanePositions(panelId, targetPanelId);
    return;
  }
  const direction = placement === "top" || placement === "bottom" ? "down" : "right";
  const targetIndex = found.workspace.panels.findIndex((candidate) => candidate.id === targetPanelId);
  const beforeTarget = placement === "left" || placement === "top";
  removePanelFromAllPaneTrees(panelId);
  insertPanelInPaneTree(found.workspace.id, targetPanelId, panelId, direction, beforeTarget ? "before" : "after");
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

function swapPanePositions(panelId, targetPanelId) {
  const source = findPanelState(panelId);
  const target = findPanelState(targetPanelId);
  if (!source || !target || source.workspace.id !== target.workspace.id || panelId === targetPanelId) return false;
  const tree = paneTreeForWorkspace(target.workspace);
  const swapped = swapPaneTreePanelIds(tree, panelId, targetPanelId);
  if (!swapped) return false;
  state.paneTrees.set(target.workspace.id, swapped);
  savePaneTreeLayouts(state.paneTrees);
  target.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = target.workspace.id;
  render();
  queueFocusSync({ type: "panel", panelId });
  focusTerminalSession(panelId);
  return true;
}

async function movePanelToWorkspace(panelId, workspaceId) {
  if (!panelId || !workspaceId) return;
  const targetWorkspace = state.data?.workspaces.find((workspace) => workspace.id === workspaceId);
  removePanelFromAllPaneTrees(panelId);
  insertPanelInPaneTree(workspaceId, targetWorkspace?.activePanelId, panelId, "right");
  await updatePanel(panelId, { workspaceId, moveToEnd: true });
}

function optimisticMoveWorkspace(workspaceId, beforeWorkspaceId = null) {
  const workspaces = state.data?.workspaces;
  if (!Array.isArray(workspaces) || !workspaceId || beforeWorkspaceId === workspaceId) return false;
  const currentIndex = workspaces.findIndex((workspace) => workspace.id === workspaceId);
  if (currentIndex < 0) return false;
  const [workspace] = workspaces.splice(currentIndex, 1);
  const insertIndex = beforeWorkspaceId
    ? workspaces.findIndex((candidate) => candidate.id === beforeWorkspaceId)
    : -1;
  workspaces.splice(insertIndex >= 0 ? insertIndex : workspaces.length, 0, workspace);
  state.data.activeWorkspaceId = workspace.id;
  render();
  return true;
}

function optimisticUpdateWorkspace(workspaceId, updates = {}) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return false;
  if (Object.hasOwn(updates, "beforeWorkspaceId") || Object.hasOwn(updates, "moveToEnd")) {
    return optimisticMoveWorkspace(workspaceId, updates.moveToEnd ? null : updates.beforeWorkspaceId);
  }
  let changed = false;
  if (Object.hasOwn(updates, "title")) {
    const title = String(updates.title || "").trim();
    if (title && workspace.title !== title.slice(0, 80)) {
      workspace.title = title.slice(0, 80);
      changed = true;
    }
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    if (isAllowedUiColor(color, state.data?.palette || workspaceColorOptions) && workspace.color !== color) {
      workspace.color = color;
      changed = true;
    }
  }
  if (Object.hasOwn(updates, "cwd")) {
    const cwd = String(updates.cwd || "").trim();
    if (cwd && workspace.cwd !== cwd) {
      workspace.cwd = cwd;
      workspace.cwdShort = shortFolderPath(cwd);
      changed = true;
    }
  }
  if (changed) render();
  return true;
}

function workspaceUpdateReconcileNeeded(workspaceId, updates = {}) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return true;
  if (Object.hasOwn(updates, "beforeWorkspaceId")) {
    const workspaces = state.data?.workspaces || [];
    const workspaceIndex = workspaces.findIndex((candidate) => candidate.id === workspaceId);
    const beforeIndex = workspaces.findIndex((candidate) => candidate.id === updates.beforeWorkspaceId);
    if (beforeIndex >= 0 && workspaceIndex !== beforeIndex - 1) return true;
  }
  if (updates.moveToEnd) {
    const workspaces = state.data?.workspaces || [];
    const workspaceIndex = workspaces.findIndex((candidate) => candidate.id === workspaceId);
    if (workspaceIndex !== workspaces.length - 1) return true;
  }
  if (Object.hasOwn(updates, "title")) {
    const title = String(updates.title || "").trim();
    if (title && workspace.title !== title.slice(0, 80)) return true;
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    if (isAllowedUiColor(color, state.data?.palette || workspaceColorOptions) && workspace.color !== color) return true;
  }
  if (Object.hasOwn(updates, "cwd")) {
    const cwd = String(updates.cwd || "").trim();
    if (cwd && workspace.cwd !== cwd) return true;
  }
  return false;
}

async function updateWorkspace(workspaceId, updates = {}) {
  if (!optimisticUpdateWorkspace(workspaceId, updates)) return false;
  try {
    const result = await api(`/api/workspaces/${workspaceId}`, {
      method: "PATCH",
      body: JSON.stringify(updates)
    });
    if (!result?.ok || workspaceUpdateReconcileNeeded(workspaceId, updates)) await loadState();
    return Boolean(result?.ok);
  } catch {
    await loadState();
    return false;
  }
}

async function updateWorkspaceOrder(workspaceId, updates) {
  await updateWorkspace(workspaceId, updates);
}

function moveWorkspaceRelative(workspaceId, targetWorkspaceId, placement) {
  if (!workspaceId || !targetWorkspaceId || workspaceId === targetWorkspaceId) return;
  const workspaces = state.data?.workspaces || [];
  const targetIndex = workspaces.findIndex((workspace) => workspace.id === targetWorkspaceId);
  if (targetIndex < 0) return;
  if (placement === "before") {
    updateWorkspaceOrder(workspaceId, { beforeWorkspaceId: targetWorkspaceId });
    return;
  }
  const nextWorkspace = workspaces[targetIndex + 1];
  if (nextWorkspace?.id === workspaceId) return;
  if (nextWorkspace) {
    updateWorkspaceOrder(workspaceId, { beforeWorkspaceId: nextWorkspace.id });
  } else {
    updateWorkspaceOrder(workspaceId, { moveToEnd: true });
  }
}

async function focusWorkspace(workspaceId) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace) return;
  const currentWorkspaceId = state.data?.activeWorkspaceId || "";
  const switchingWorkspace = currentWorkspaceId !== workspaceId;
  if (switchingWorkspace) rememberPreviousWorkspace(currentWorkspaceId);
  const previousPanelId = workspace.activePanelId;
  const focusablePanel = focusablePanelForWorkspace(workspace);
  if (focusablePanel) workspace.activePanelId = focusablePanel.id;
  state.focusedPanelId = focusablePanel?.id || null;
  state.lastInteractedPanelId = focusablePanel?.id || null;
  if (
    focusablePanel?.type === "terminal"
    && !state.terminals.has(focusablePanel.id)
    && (switchingWorkspace || workspace.activePanelId !== previousPanelId)
  ) {
    state.paintDeferredTerminalInitPanelIds.add(focusablePanel.id);
  }
  if (state.data?.activeWorkspaceId === workspaceId) {
    if (workspace.activePanelId !== previousPanelId) scheduleRender();
    focusTerminalSession(focusablePanel?.id);
    return;
  }
  optimisticFocusWorkspace(workspaceId, { schedule: true });
  if (switchingWorkspace) showWorkspaceSwitchHud(workspace);
  queueFocusSync({ type: "workspace", workspaceId });
  focusTerminalSession(focusablePanel?.id);
}

async function focusPanel(panelId) {
  const found = findPanelState(panelId);
  let wasMinimized = false;
  let zoomChanged = false;
  const currentWorkspace = activeWorkspace();
  const wasAlreadyFocused = found
    && state.data?.activeWorkspaceId === found.workspace.id
    && found.workspace.activePanelId === panelId;
  if (found) {
    if (!wasAlreadyFocused) {
      if (currentWorkspace?.id && currentWorkspace.id !== found.workspace.id) {
        rememberPreviousWorkspace(currentWorkspace.id);
        rememberPreviousPanel(currentWorkspace, currentWorkspace.activePanelId);
      }
      if (found.workspace.activePanelId !== panelId) rememberPreviousPanel(found.workspace, found.workspace.activePanelId);
    }
    wasMinimized = state.minimizedPanelIds.delete(panelId);
    state.focusedPanelId = panelId;
    state.lastInteractedPanelId = panelId;
    zoomChanged = clearDifferentZoomedPanelOnFocus(found.workspace, panelId);
  }
  const shouldShowPaneHud = Boolean(found && (!wasAlreadyFocused || wasMinimized || zoomChanged));
  if (wasAlreadyFocused) {
    if (wasMinimized || zoomChanged) render();
    if (shouldShowPaneHud) showPaneSwitchHud(found.panel, found.workspace);
    focusTerminalSession(panelId);
    return;
  }
  if (!optimisticFocusPanel(panelId, { schedule: true })) return;
  if (found.panel.type === "terminal" && !state.terminals.has(panelId)) {
    state.paintDeferredTerminalInitPanelIds.add(panelId);
  }
  if (shouldShowPaneHud) showPaneSwitchHud(found.panel, found.workspace);
  queueFocusSync({ type: "panel", panelId });
  focusTerminalSession(panelId);
}

function cycleActivePane(delta = 1) {
  const workspace = activeWorkspace();
  const allPanels = workspace?.panels || [];
  const panels = allPanels.filter((panel) => !isPanelMinimized(panel));
  if (panels.length === 0 && allPanels.length > 0) {
    restorePane(allPanels[0].id);
    return true;
  }
  if (panels.length === 0) return false;
  const activeIndex = panels.findIndex((panel) => panel.id === workspace.activePanelId);
  const currentIndex = activeIndex >= 0 ? activeIndex : 0;
  const nextPanel = panels[(currentIndex + delta + panels.length) % panels.length];
  if (!nextPanel) return false;
  focusPanel(nextPanel.id);
  return true;
}

function focusLastPane() {
  const panel = previousPanelForWorkspace();
  if (!panel) return false;
  focusPanel(panel.id);
  scheduleActiveSurfaceTabIntoView(panel.id);
  return true;
}

function focusPaneByOrdinal(ordinal) {
  const workspace = activeWorkspace();
  const panels = workspace?.panels || [];
  if (panels.length === 0) return false;
  const index = ordinal === 9 ? panels.length - 1 : ordinal - 1;
  const panel = panels[clamp(index, 0, panels.length - 1)];
  if (!panel) return false;
  focusPanel(panel.id);
  scheduleActiveSurfaceTabIntoView(panel.id);
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

function focusLastWorkspace() {
  const workspace = previousWorkspace();
  if (!workspace) return false;
  focusWorkspace(workspace.id);
  return true;
}

function focusWorkspaceByOrdinal(ordinal) {
  const workspaces = state.data?.workspaces || [];
  if (workspaces.length === 0) return false;
  const index = ordinal === 9 ? workspaces.length - 1 : ordinal - 1;
  const workspace = workspaces[clamp(index, 0, workspaces.length - 1)];
  if (!workspace) return false;
  focusWorkspace(workspace.id);
  return true;
}

function focusTerminalSession(panelId) {
  if (!state.terminals.has(panelId)) return;
  state.terminalFocusPanelId = panelId;
  if (state.terminalFocusFrame) cancelAnimationFrame(state.terminalFocusFrame);
  state.terminalFocusFrame = requestAnimationFrame(() => {
    const targetPanelId = state.terminalFocusPanelId;
    state.terminalFocusFrame = 0;
    state.terminalFocusPanelId = "";
    const terminal = state.terminals.get(targetPanelId);
    if (!terminal || terminal.disposed || !terminalFitCanRun(terminal)) return;
    const found = findPanelState(targetPanelId);
    if (
      !found
      || found.workspace.id !== state.data?.activeWorkspaceId
      || found.workspace.activePanelId !== targetPanelId
      || isPanelMinimized(found.panel)
    ) {
      return;
    }
    terminal.term.focus();
  });
}

function normalizedWheelZoomDelta(event) {
  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) return event.deltaY * 40;
  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) return event.deltaY * 360;
  return event.deltaY;
}

function applyTerminalWheelZoom(event, panel) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) return false;
  if (!event.ctrlKey) return false;
  event.preventDefault();
  event.stopPropagation();
  event.stopImmediatePropagation?.();
  const delta = normalizedWheelZoomDelta(event);
  if (!Number.isFinite(delta) || delta === 0) return true;
  const now = performance.now();
  const zoomState = terminalWheelZoomStateFor(terminalPanel.id);
  if (now - zoomState.at > terminalWheelZoomIdleResetMs) {
    zoomState.remainder = 0;
  }
  zoomState.at = now;
  if (zoomState.remainder && Math.sign(zoomState.remainder) !== Math.sign(delta)) {
    zoomState.remainder = 0;
  }
  zoomState.remainder += delta;
  const steps = Math.min(
    terminalWheelZoomMaxSteps,
    Math.trunc(Math.abs(zoomState.remainder) / terminalWheelZoomThreshold)
  );
  if (!steps) return true;
  const direction = zoomState.remainder < 0 ? 1 : -1;
  zoomState.remainder -= Math.sign(zoomState.remainder) * terminalWheelZoomThreshold * steps;
  changeTerminalFontSize(direction * steps, { panel: terminalPanel, toast: false, status: true });
  return true;
}

function handleTerminalWheelZoom(event) {
  if (!event.ctrlKey) return;
  const panel = panelFromEvent(event);
  if (panel?.type !== "terminal") return;
  applyTerminalWheelZoom(event, panel);
}

function handlePaneWheelZoom(event) {
  if (!event.ctrlKey) return;
  const panelId = event.currentTarget?.dataset?.panelId || "";
  const panel = panelId ? findPanelState(panelId)?.panel : null;
  if (panel?.type !== "terminal") return;
  applyTerminalWheelZoom(event, panel);
}

function handleWindowWheelZoom(event) {
  if (!event.ctrlKey) return;
  const panel = panelFromEvent(event);
  if (panel?.type === "terminal") {
    applyTerminalWheelZoom(event, panel);
    return;
  }
  if (event.target?.closest?.(".terminal-host")) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  } else if (event.target?.closest?.(".shell, .pane, .surface-tabs, .sidebar, .topbar, .command-strip")) {
    event.preventDefault();
    event.stopPropagation();
  }
}

function setPaneMinimized(panelId, minimized = true) {
  const found = findPanelState(panelId);
  if (!found) return false;
  if (!minimized) markInteractedPanel(panelId);
  const shouldMinimize = Boolean(minimized);
  if (state.minimizedPanelIds.has(panelId) === shouldMinimize) return false;
  const isActiveWorkspace = found.workspace.id === state.data?.activeWorkspaceId;
  if (shouldMinimize) {
    rememberPreviousPanel(found.workspace, panelId);
    state.minimizedPanelIds.add(panelId);
    if (isPanelZoomed(found.panel, found.workspace)) clearZoomedPanelForWorkspace(found.workspace);
    if (found.workspace.activePanelId === panelId) {
      const nextPanel = firstUnminimizedPanel(found.workspace, panelId);
      found.workspace.activePanelId = nextPanel?.id || panelId;
      if (isActiveWorkspace) {
        state.focusedPanelId = nextPanel?.id || null;
        state.lastInteractedPanelId = nextPanel?.id || null;
        if (nextPanel) focusTerminalSession(nextPanel.id);
      }
    } else if (isActiveWorkspace && state.focusedPanelId === panelId) {
      const nextPanel = firstUnminimizedPanel(found.workspace, panelId);
      state.focusedPanelId = nextPanel?.id || null;
      state.lastInteractedPanelId = nextPanel?.id || null;
      if (nextPanel) focusTerminalSession(nextPanel.id);
    } else if (isActiveWorkspace && state.lastInteractedPanelId === panelId) {
      state.lastInteractedPanelId = firstUnminimizedPanel(found.workspace, panelId)?.id || null;
    }
  } else {
    state.minimizedPanelIds.delete(panelId);
    found.workspace.activePanelId = panelId;
    state.data.activeWorkspaceId = found.workspace.id;
    state.focusedPanelId = panelId;
    state.lastInteractedPanelId = panelId;
    clearDifferentZoomedPanelOnFocus(found.workspace, panelId);
  }
  render();
  if (!shouldMinimize) {
    showPaneSwitchHud(found.panel, found.workspace);
    focusTerminalSession(panelId);
  }
  return true;
}

function togglePaneMinimized(panelId = activePaneActionTarget()?.id) {
  if (!panelId) return false;
  return setPaneMinimized(panelId, !state.minimizedPanelIds.has(panelId));
}

function restorePane(panelId) {
  return setPaneMinimized(panelId, false) || focusPanel(panelId);
}

function minimizeActivePane() {
  const panel = activePaneActionTarget();
  if (!panel) return false;
  return setPaneMinimized(panel.id, true);
}

function restoreMinimizedPanes(workspace = activeWorkspace()) {
  const targetWorkspace = typeof workspace === "string"
    ? state.data?.workspaces.find((candidate) => candidate.id === workspace)
    : workspace;
  if (!targetWorkspace) return false;
  let restored = false;
  for (const panel of targetWorkspace.panels) {
    if (!state.minimizedPanelIds.delete(panel.id)) continue;
    restored = true;
  }
  if (!restored) return false;
  const active = targetWorkspace.panels.find((panel) => panel.id === targetWorkspace.activePanelId) || targetWorkspace.panels[0];
  if (active) {
    targetWorkspace.activePanelId = active.id;
    state.focusedPanelId = active.id;
    state.lastInteractedPanelId = active.id;
    clearDifferentZoomedPanelOnFocus(targetWorkspace, active.id);
  }
  render();
  if (active) focusTerminalSession(active.id);
  return true;
}

function togglePaneZoom(panelId = activePaneActionTarget()?.id) {
  if (!panelId) return;
  const found = findPanelState(panelId);
  if (!found) return;
  markInteractedPanel(panelId);
  state.minimizedPanelIds.delete(panelId);
  const zoomingIn = zoomedPanelIdForWorkspace(found.workspace) !== panelId;
  setZoomedPanelIdForWorkspace(found.workspace, zoomingIn ? panelId : null);
  found.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = found.workspace.id;
  state.focusedPanelId = panelId;
  render();
  focusTerminalSession(panelId);
  const session = state.terminals.get(panelId);
  if (session) requestAnimationFrame(() => scheduleFitTerminal(session, true));
}

function toggleSidebar() {
  state.sidebarCollapsed = !state.sidebarCollapsed;
  render();
}

function openInspector(mode) {
  state.inspectorMode = state.inspectorMode === mode ? null : mode;
  if (state.inspectorMode !== "settings") cancelSettingsSearchFocus();
  updateRailButtons();
  render();
}

function openSettingsCategory(category = "quick") {
  state.inspectorMode = "settings";
  state.settingsCategory = settingsCategories.some(([id]) => id === category) ? category : "quick";
  state.settingsQuery = "";
  state.settingsScrollResetPending = true;
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

function resolveTerminalPanel(panel = focusedPanel()) {
  const found = panel?.id ? findPanelState(panel.id) : null;
  const candidate = found?.panel || panel;
  return candidate?.type === "terminal" && !isPendingPanel(candidate) ? candidate : null;
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
  "paneActionMode",
  "sidebarDetailMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "titleDetailMode",
  "focusMode",
  "showTabs",
  "showStatusbar",
  "sidebarWidth",
  "inspectorWidth"
];

const appearanceResetSettings = [
  "theme",
  "accent",
  "backgroundImage",
  "backgroundOpacity",
  "backgroundFit",
  "backgroundPosition",
  "backgroundEffects",
  "terminalBackground",
  "terminalForeground",
  "terminalCursorColor"
];

function toggleFocusMode(nextValue = !state.settings.focusMode, options = {}) {
  const enabled = Boolean(nextValue);
  const changed = updateSettings({ focusMode: enabled }, { immediate: true });
  if (!changed) {
    if (options.toast !== false) toast(`Focus mode already ${enabled ? "on" : "off"}.`);
    return false;
  }
  refreshLayoutSettings({ ifChanged: true });
  if (options.toast !== false) toast(`Focus mode ${enabled ? "on" : "off"}.`);
  return true;
}

function resetAppearanceSettings() {
  const updates = {};
  for (const key of appearanceResetSettings) updates[key] = defaultSettings[key];
  const changed = updateSettings(updates, { immediate: true });
  if (!changed) {
    toast("Look settings already reset.");
    return false;
  }
  renderSettingsInspector();
  toast("Look settings reset.");
  return true;
}

function resetWorkspaceChrome() {
  const updates = {};
  for (const key of workspaceChromeSettings) updates[key] = defaultSettings[key];
  const changed = updateSettings(updates, { immediate: true });
  if (!changed) {
    toast("Workspace chrome already reset.");
    return;
  }
  refreshLayoutSettings();
  toast("Workspace chrome reset.");
}

function resetActivePaneLayout() {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1) {
    toast("Open another pane to reset split layout.");
    return;
  }
  state.paneTrees.set(workspace.id, equalizePaneTree(paneTreeForWorkspace(workspace)));
  savePaneTreeLayouts(state.paneTrees);
  for (const panel of workspace.panels) state.paneLayouts.delete(panel.id);
  savePaneLayouts();
  render();
  refreshLayoutSettings();
  requestAnimationFrame(() => {
    for (const panel of workspace.panels) {
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal, true);
    }
  });
  toast("Split layout reset.");
}

function combinePaneTrees(nodes, direction) {
  let tree = null;
  let count = 0;
  for (const node of nodes) {
    if (!node) continue;
    if (!tree) {
      tree = node;
      count = 1;
      continue;
    }
    tree = paneTreeSplit(direction, tree, node, count / (count + 1));
    count += 1;
  }
  return tree;
}

function buildGridPanePresetTree(panelIds) {
  const ids = panelIds.filter(Boolean);
  if (ids.length <= 2) return buildPaneTreeFromPanelIds(ids, "right");
  const columnCount = Math.ceil(Math.sqrt(ids.length));
  const rows = [];
  for (let index = 0; index < ids.length; index += columnCount) {
    rows.push(ids.slice(index, index + columnCount));
  }
  const rowTrees = rows.map((rowIds) => buildPaneTreeFromPanelIds(rowIds, "right"));
  return combinePaneTrees(rowTrees, "down");
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
  clearZoomedPanelForWorkspace(workspace);
  if (paneLayoutDirection(workspace) !== direction) {
    await updatePanel(active.id, { direction });
  }
  const nextWorkspace = activeWorkspace() || workspace;
  let tree = paneTreeForWorkspace(nextWorkspace);
  if (preset.id === "equal") {
    tree = equalizePaneTree(tree);
  } else if (preset.mode === "grid") {
    tree = buildGridPanePresetTree(nextWorkspace.panels.map((panel) => panel.id));
  } else if (preset.mode === "active") {
    tree = buildActivePanePresetTree(nextWorkspace.panels, active.id, direction, nextWorkspace.panels.length === 2 ? 68 : 60);
  } else {
    tree = buildPaneTreeFromPanelIds(nextWorkspace.panels.map((panel) => panel.id), direction);
  }
  state.paneTrees.set(nextWorkspace.id, tree);
  savePaneTreeLayouts(state.paneTrees);
  render();
  refreshLayoutSettings();
  requestAnimationFrame(() => {
    for (const panel of nextWorkspace.panels) {
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal, true);
    }
  });
  toast(`${preset.label} layout applied.`);
  return true;
}

async function promptActivePaneLayoutPercent() {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length <= 1) {
    toast("Open another pane to resize the active pane.");
    return false;
  }
  const value = await showTextDialog({
    title: "Set active pane size",
    message: `Enter a percentage from ${paneLayoutPercentMin} to ${paneLayoutPercentMax}.`,
    value: String(activePaneLayoutPercent(workspace)),
    placeholder: "65",
    confirmLabel: "Apply"
  });
  if (value === null) return false;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    toast(`Enter a number from ${paneLayoutPercentMin} to ${paneLayoutPercentMax}.`);
    return false;
  }
  applyActivePaneLayoutPercent(parsed, { save: true, toast: true });
  refreshLayoutSettings();
  return true;
}

function queueTerminalFontSizeSync(panelId, fontSize) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  const size = Number(fontSize);
  state.pendingTerminalFontSizeSync.set(panelId, Number.isFinite(size) && size <= 0 ? 0 : normalizeTerminalFontSize(fontSize, state.settings.terminalFontSize));
  if (state.terminalFontSizeSyncTimer) clearTimeout(state.terminalFontSizeSyncTimer);
  state.terminalFontSizeSyncTimer = setTimeout(flushTerminalFontSizeSync, 220);
  return true;
}

async function flushTerminalFontSizeSync() {
  state.terminalFontSizeSyncTimer = 0;
  const entries = [...state.pendingTerminalFontSizeSync.entries()];
  state.pendingTerminalFontSizeSync.clear();
  await Promise.all(entries.map(async ([panelId, terminalFontSize]) => {
    const found = findPanelState(panelId);
    if (!found || found.panel.type !== "terminal" || normalizeTerminalFontSize(found.panel.terminalFontSize, 0) !== terminalFontSize) return;
    try {
      await api(`/api/panels/${panelId}`, {
        method: "PATCH",
        body: JSON.stringify({ terminalFontSize })
      });
    } catch {
      // The pane may have been closed before the debounce fired.
    }
  }));
}

function refreshActivePaneTextControls(panelId) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal" || !elements.inspectorBody) return;
  const nextSize = terminalFontSizeForPanel(found.panel);
  const hasOverride = panelHasTerminalFontSize(found.panel);
  for (const row of elements.inspectorBody.querySelectorAll("[data-active-pane-text-row]")) {
    if (row.dataset.activePaneTextRow !== panelId) continue;
    setTextIfChanged(row.querySelector(".setting-label"), `Pane text ${nextSize}px`);
  }
  for (const range of elements.inspectorBody.querySelectorAll("[data-active-pane-text-range]")) {
    if (range.dataset.activePaneTextRange === panelId) range.value = String(nextSize);
  }
  for (const number of elements.inspectorBody.querySelectorAll("[data-active-pane-text-number]")) {
    if (number.dataset.activePaneTextNumber === panelId) number.value = String(nextSize);
  }
  for (const button of elements.inspectorBody.querySelectorAll("[data-active-pane-reset-text]")) {
    if (button.dataset.activePaneResetText === panelId) button.disabled = !hasOverride;
  }
}

function setPaneTerminalFontSizeOverride(panelId, fontSize, options = {}) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return 0;
  const override = Number(fontSize) <= 0
    ? 0
    : normalizeTerminalFontSize(fontSize, terminalFontSizeForPanel(found.panel));
  const currentOverride = normalizeTerminalFontSize(found.panel.terminalFontSize, 0);
  if (currentOverride === override) {
    refreshActivePaneTextControls(panelId);
    return terminalFontSizeForPanel(found.panel);
  }
  found.panel.terminalFontSize = override;
  const nextSize = terminalFontSizeForPanel(found.panel);
  const session = state.terminals.get(panelId);
  if (session) {
    session.fontSize = nextSize;
    session.term.options.fontSize = nextSize;
    scheduleFitTerminal(session, true);
  }
  queueTerminalFontSizeSync(panelId, override);
  refreshActivePaneTextControls(panelId);
  if (options.toast !== false) {
    toast(override ? `Pane text ${nextSize}px.` : `Pane text reset to ${nextSize}px.`);
  }
  return nextSize;
}

function showTerminalTextSizeStatus(panelId, size) {
  const session = state.terminals.get(panelId);
  if (!session || session.disposed) return;
  if (!session.hasOutput && session.host.classList.contains("is-connecting")) return;
  setTerminalConnectionStatus(session, "ready", `Text ${size}px`, 650);
}

function changeTerminalFontSize(delta, options = {}) {
  const panel = resolveTerminalPanel(options.panel || (options.event ? keyboardPanelFromEvent(options.event) : null) || activePaneActionTarget());
  if (!panel) return false;
  markInteractedPanel(panel.id);
  const currentSize = terminalFontSizeForPanel(panel);
  const nextSize = normalizeTerminalFontSize(currentSize + delta, currentSize);
  if (nextSize === currentSize) return false;
  panel.terminalFontSize = nextSize;
  const session = state.terminals.get(panel.id);
  if (session) {
    session.fontSize = nextSize;
    session.term.options.fontSize = nextSize;
    scheduleFitTerminal(session, true);
  }
  queueTerminalFontSizeSync(panel.id, nextSize);
  refreshActivePaneTextControls(panel.id);
  if (options.status) showTerminalTextSizeStatus(panel.id, nextSize);
  if (options.toast !== false) toast(`Pane text ${nextSize}px`);
  return true;
}

function changePaneTerminalFontSize(panelId, delta) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  focusPanel(panelId);
  return changeTerminalFontSize(delta, { panel: found.panel });
}

function resetTerminalFontSize(options = {}) {
  const panel = resolveTerminalPanel(options.panel || (options.event ? keyboardPanelFromEvent(options.event) : null) || activePaneActionTarget());
  if (!panel) return false;
  markInteractedPanel(panel.id);
  if (!panelHasTerminalFontSize(panel)) {
    if (options.toast !== false) toast(`Pane text already uses ${state.settings.terminalFontSize}px default.`);
    return false;
  }
  panel.terminalFontSize = 0;
  const nextSize = terminalFontSizeForPanel(panel);
  const session = state.terminals.get(panel.id);
  if (session) {
    session.fontSize = nextSize;
    session.term.options.fontSize = nextSize;
    scheduleFitTerminal(session, true);
  }
  queueTerminalFontSizeSync(panel.id, 0);
  refreshActivePaneTextControls(panel.id);
  if (options.toast !== false) toast(`Pane text reset to ${nextSize}px.`);
  return true;
}

function resetPaneTerminalFontSize(panelId) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  focusPanel(panelId);
  return resetTerminalFontSize({ panel: found.panel });
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
    version: 8,
    settings: state.settings,
    paneLayouts: Object.fromEntries(state.paneLayouts),
    paneTreeLayouts: Object.fromEntries(state.paneTrees),
    browserTabs: Object.fromEntries(state.browserTabSnapshots),
    commandSnippets: state.customCommandSnippets,
    settingsProfiles: state.savedSettingsProfiles,
    workspaceBlueprints: state.workspaceBlueprints,
    customColorPalette: state.customColorPalette,
    savedBackgroundImages: state.savedBackgroundImages,
    recentFolders: state.recentFolders,
    recentCommands: state.recentCommands,
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

function importedObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
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
    const importedPaneLayouts = importedObject(parsed?.paneLayouts || parsed?.paneLayout);
    if (importedPaneLayouts) {
      localStorage.setItem(paneLayoutStorageKey, JSON.stringify(importedPaneLayouts));
      state.paneLayouts = loadPaneLayouts();
    }
    const importedPaneTreeLayouts = importedObject(parsed?.paneTreeLayouts || parsed?.splitLayouts);
    if (importedPaneTreeLayouts) {
      localStorage.setItem(paneTreeLayoutsStorageKey, JSON.stringify(importedPaneTreeLayouts));
      state.paneTrees = loadPaneTreeLayouts();
    }
    const importedBrowserTabs = importedObject(parsed?.browserTabs || parsed?.browserTabSnapshots);
    if (importedBrowserTabs) {
      localStorage.setItem(browserTabsStorageKey, JSON.stringify(importedBrowserTabs));
      state.browserTabSnapshots = loadBrowserTabSnapshots();
    }
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
    if (Array.isArray(parsed?.recentFolders)) {
      state.recentFolders = [];
      const seenRecentFolders = new Set();
      for (const entry of parsed.recentFolders) {
        if (state.recentFolders.length >= recentFoldersLimit) break;
        const folder = String(entry || "").trim();
        const key = folderKey(folder);
        if (!folder || seenRecentFolders.has(key)) continue;
        seenRecentFolders.add(key);
        state.recentFolders.push(folder);
      }
      saveRecentFolders();
    }
    if (Array.isArray(parsed?.recentCommands)) {
      state.recentCommands = [];
      const seenRecentCommands = new Set();
      for (const entry of parsed.recentCommands) {
        if (state.recentCommands.length >= recentCommandsLimit) break;
        const command = normalizeTerminalCommand(entry);
        const key = command.toLowerCase();
        if (!command || seenRecentCommands.has(key)) continue;
        seenRecentCommands.add(key);
        state.recentCommands.push(command);
      }
      saveRecentCommands();
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
    render();
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
  const panel = focusedPanel();
  if (panel?.type === "terminal") await restartPanel(panel.id);
}

async function restartPanel(panelId) {
  cleanupPanel(panelId);
  await api(`/api/panels/${panelId}/restart`, { method: "POST" });
  await loadState();
}

async function closeActivePanel() {
  const panel = focusedPanel();
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
document.getElementById("splitRightButton").onclick = () => splitActivePanel("right");
document.getElementById("splitDownButton").onclick = () => splitActivePanel("down");
const newBrowserButton = document.getElementById("newBrowserButton");
newBrowserButton.onclick = () => openBrowserHome();
newBrowserButton.oncontextmenu = (event) => showExternalBrowserProfileMenu(event, state.settings.browserHomeUrl);
document.getElementById("toolsMenuButton").onclick = showToolbarMenu;
document.getElementById("settingsButton").onclick = () => openInspector("settings");
document.getElementById("renameWorkspaceButton").onclick = () => renameActiveWorkspace();
document.getElementById("colorWorkspaceButton").onclick = () => cycleWorkspaceColor();
document.getElementById("notifyButton").onclick = () => simulateNotification();
document.getElementById("toggleSidebarButton").onclick = () => toggleSidebar();
attachHorizontalWheelScroll(elements.commandStrip);
observeCommandStripOverflow();
attachHorizontalWheelScroll(elements.surfaceTabs);
observeSurfaceTabOverflow();
document.getElementById("paletteButton").onclick = () => {
  openPalette();
};
document.getElementById("notificationsRailButton").onclick = () => openInspector("notifications");
document.getElementById("sessionsRailButton").onclick = () => openInspector("session");
document.getElementById("settingsRailButton").onclick = () => openInspector("settings");
document.getElementById("workspacesRailButton").onclick = () => {
  state.inspectorMode = null;
  cancelSettingsSearchFocus();
  updateRailButtons();
  render();
};
document.getElementById("closeInspectorButton").onclick = () => {
  state.inspectorMode = null;
  cancelSettingsSearchFocus();
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
    closePalette();
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
  if (event.ctrlKey && event.shiftKey && key === "f") {
    consumeGlobalShortcut(event);
    toggleFocusMode();
  } else if (event.ctrlKey && key === "f") {
    consumeGlobalShortcut(event);
    openTerminalSearch();
  } else if (event.ctrlKey && event.shiftKey && event.key === "Enter") {
    consumeGlobalShortcut(event);
    promptRunTerminalCommand();
  } else if (event.ctrlKey && key === "tab") {
    consumeGlobalShortcut(event);
    cycleActivePane(event.shiftKey ? -1 : 1);
  } else if (event.ctrlKey && event.shiftKey && !event.altKey && !event.metaKey && key === "backspace") {
    consumeGlobalShortcut(event);
    focusLastPane();
  } else if (event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey && /^[1-9]$/.test(event.key)) {
    consumeGlobalShortcut(event);
    focusPaneByOrdinal(Number(event.key));
  } else if (event.ctrlKey && event.altKey && !event.shiftKey && !event.metaKey && /^[1-9]$/.test(event.key)) {
    consumeGlobalShortcut(event);
    focusWorkspaceByOrdinal(Number(event.key));
  } else if (event.ctrlKey && event.altKey && !event.shiftKey && !event.metaKey && key === "backspace") {
    consumeGlobalShortcut(event);
    focusLastWorkspace();
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
    if (state.paletteOpen) closePalette();
    else openPalette();
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
    openBrowserHome();
  } else if (event.ctrlKey && key === "l") {
    const panel = keyboardPanelFromEvent(event);
    if (resolveBrowserPanel(panel)) {
      consumeGlobalShortcut(event);
      focusBrowserAddress(panel);
    }
  } else if (event.ctrlKey && key === "r") {
    const panel = keyboardPanelFromEvent(event);
    if (resolveBrowserPanel(panel)) {
      consumeGlobalShortcut(event);
      reloadBrowserPanel(panel);
    }
  } else if (event.altKey && event.key === "ArrowLeft") {
    if (navigateBrowserHistory(-1, keyboardPanelFromEvent(event))) consumeGlobalShortcut(event);
  } else if (event.altKey && event.key === "ArrowRight") {
    if (navigateBrowserHistory(1, keyboardPanelFromEvent(event))) consumeGlobalShortcut(event);
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
    changeTerminalFontSize(1, { event });
  } else if (event.ctrlKey && event.key === "-") {
    consumeGlobalShortcut(event);
    changeTerminalFontSize(-1, { event });
  } else if (event.ctrlKey && event.key === "0") {
    consumeGlobalShortcut(event);
    resetTerminalFontSize({ event });
  } else if (event.ctrlKey && event.shiftKey && key === "r") {
    consumeGlobalShortcut(event);
    restartActiveTerminal();
  } else if (event.ctrlKey && event.shiftKey && key === "m") {
    consumeGlobalShortcut(event);
    togglePaneZoom(keyboardPanelFromEvent(event)?.id);
  } else if (event.ctrlKey && key === "w") {
    const panel = keyboardPanelFromEvent(event);
    if (panel) {
      consumeGlobalShortcut(event);
      closePanel(panel.id);
    }
  }
}, true);

window.addEventListener("wheel", handleWindowWheelZoom, { passive: false, capture: true });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) scheduleDeferredTerminalFitFlush();
});
window.addEventListener("focus", scheduleDeferredTerminalFitFlush);

elements.sidebar.addEventListener("pointerdown", startSidebarResize);
elements.inspector.addEventListener("pointerdown", startInspectorResize);
elements.workspaceList.addEventListener("dragover", handleWorkspaceListDragOver);
elements.workspaceList.addEventListener("dragleave", handleWorkspaceListDragLeave);
elements.workspaceList.addEventListener("drop", handleWorkspaceListDrop);
new MutationObserver(scheduleVisiblePaneLayoutApply).observe(elements.paneGrid, {
  childList: true
});
window.addEventListener("pointermove", (event) => {
  continuePaneResize(event);
  continuePanePointerDrag(event);
  continueSidebarResize(event);
  continueInspectorResize(event);
});
window.addEventListener("pointerup", (event) => {
  finishPaneResize(event);
  finishPanePointerDrag(event);
  finishSidebarResize(event);
  finishInspectorResize(event);
});
window.addEventListener("pointercancel", (event) => {
  finishPaneResize(event);
  cancelPanePointerDrag(event);
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
window.addEventListener("beforeunload", () => {
  flushSettingsSave();
  flushBrowserTabSnapshotsSave();
});

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
      if (state.paletteOpen) closePalette();
      else openPalette();
      return;
    }
    const command = commands.find((candidate) => candidate.id === commandId);
    if (command) command.run();
  });
}

installBackgroundDropTarget(elements.paneGrid, { allowPlainText: false });
applySettings();
loadState();
loadBrowserProfiles();
connectEvents();
