import {
  addTabStyleOptions,
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
  sidebarBranchOptions,
  sidebarDetailOptions,
  sidebarFooterOptions,
  terminalAppearanceKeys,
  terminalColorDefaults,
  terminalColorPresets,
  terminalCursorStyles,
  terminalFontOptions,
  terminalProfiles,
  terminalStartupOptions,
  tabSizeOptions,
  themePreviewOptions,
  titleDetailOptions,
  toolbarModeOptions,
  themeOptions
} from "./config.js";
import {
  browserDisplayUrl,
  browserViewSourceUrl,
  embeddedGooglePromoDismissScript,
  hostnameOf,
  isGoogleHomeUrl,
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
  setAttributeIfChanged,
  setClassNameIfChanged,
  setDatasetIfChanged,
  setDisabledIfChanged,
  setHiddenIfChanged,
  setStylePropertyIfChanged,
  setTextIfChanged,
  setTitleIfChanged,
  toggleClassIfChanged
} from "./dom-utils.js";
import {
  createEmptyWorkspaceView,
  updateEmptyWorkspaceView
} from "./empty-workspace-view.js";
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
  paneTreeEqual,
  paneTreeLeaf,
  paneTreeLeafIds,
  paneTreeLayoutsStorageKey,
  paneTreeRatio,
  paneTreeSplit,
  paneTreeSplitForPanel,
  paneTreeSignature,
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
  createPerformanceOverviewPanel,
  refreshPerformanceOverviewPanel as refreshPerformanceOverviewPanelView
} from "./performance-overview.js";
import {
  normalizeSettingsQuery,
  settingsCategorySearchAliases,
  settingsSearchMatchesNormalized,
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
const controlIconSvg = {
  arrowRight: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 12h14"></path><path d="m13 6 6 6-6 6"></path></svg>`,
  back: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m15 18-6-6 6-6"></path></svg>`,
  caseMatch: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 17 9 7l5 10"></path><path d="M6 13h6"></path><path d="M17 13h2a2 2 0 0 1 0 4h-3V9a2 2 0 0 1 4 0"></path></svg>`,
  clipboard: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9 5h6"></path><path d="M9 4h6a1 1 0 0 1 1 1v2H8V5a1 1 0 0 1 1-1Z"></path><rect x="5" y="6" width="14" height="16" rx="2"></rect></svg>`,
  close: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m7 7 10 10M17 7 7 17"></path></svg>`,
  copy: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="8" y="8" width="12" height="12" rx="2"></rect><path d="M4 16V6a2 2 0 0 1 2-2h10"></path></svg>`,
  down: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m6 9 6 6 6-6"></path></svg>`,
  external: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M14 4h6v6"></path><path d="M10 14 20 4"></path><path d="M20 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h5"></path></svg>`,
  forward: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m9 6 6 6-6 6"></path></svg>`,
  history: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 12a8 8 0 1 0 2.34-5.66"></path><path d="M4 5v6h6"></path><path d="M12 8v5l3 2"></path></svg>`,
  home: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m4 11 8-7 8 7"></path><path d="M6 10v10h12V10"></path></svg>`,
  image: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><circle cx="9" cy="10" r="1.5"></circle><path d="m4 16 4-4 3 3 2-2 7 7"></path></svg>`,
  layout: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14M4 12h16"></path></svg>`,
  maximize: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 4H4v4"></path><path d="M16 4h4v4"></path><path d="M8 20H4v-4"></path><path d="M16 20h4v-4"></path></svg>`,
  minimize: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 12h10"></path></svg>`,
  palette: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 4c4 0 8 3 8 7 0 3-2 5-5 5h-1.5a1.5 1.5 0 0 0 0 3H12a8 8 0 1 1 0-16Z"></path><circle cx="8.5" cy="10" r="1"></circle><circle cx="12" cy="8" r="1"></circle><circle cx="15.5" cy="10" r="1"></circle></svg>`,
  plus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 5v14M5 12h14"></path></svg>`,
  reload: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M20 12a8 8 0 1 1-2.34-5.66"></path><path d="M20 4v6h-6"></path></svg>`,
  rename: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 5h12M12 5v14M9 19h6"></path></svg>`,
  save: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 4h10l2 2v14H6z"></path><path d="M8 4v6h8M9 17h6"></path></svg>`,
  search: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="11" cy="11" r="6"></circle><path d="m16 16 4 4"></path></svg>`,
  browser: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="8"></circle><path d="M4 12h16M12 4c2.2 2.3 2.2 13.7 0 16M12 4c-2.2 2.3-2.2 13.7 0 16"></path></svg>`,
  terminal: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="m8 10 3 3-3 3"></path><path d="M13 16h4"></path></svg>`,
  browserPlus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="10.5" cy="12" r="6.5"></circle><path d="M4 12h13M10.5 5.5c1.8 1.9 1.8 11.1 0 13M10.5 5.5c-1.8 1.9-1.8 11.1 0 13"></path><path d="M18 13v6M15 16h6"></path></svg>`,
  terminalPlus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="3.5" y="5" width="13" height="14" rx="2"></rect><path d="m7 10 2.5 2.5L7 15"></path><path d="M11 15h3"></path><path d="M18 13v6M15 16h6"></path></svg>`,
  splitDown: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M4 12h16"></path></svg>`,
  splitRight: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14"></path></svg>`,
  speed: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 16a7 7 0 0 1 14 0"></path><path d="m12 16 4-5"></path><path d="M8 20h8"></path></svg>`,
  settings: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="3"></circle><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1"></path></svg>`,
  textSize: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 7V4h14v3"></path><path d="M12 4v16"></path><path d="M9 20h6"></path></svg>`,
  up: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m6 15 6-6 6 6"></path></svg>`
};

function controlIconMarkup(icon) {
  return controlIconSvg[icon] || controlIconSvg.arrowRight;
}
const TerminalConstructor = window.Terminal;
const FitAddonConstructor = window.FitAddon?.FitAddon;
const WebLinksAddonConstructor = window.WebLinksAddon?.WebLinksAddon;
const SearchAddonConstructor = window.SearchAddon?.SearchAddon;
const terminalOutputChunkSize = 32768;
const terminalOutputPerformanceChunkSize = 16384;
const terminalOutputBacklogThreshold = 262144;
const terminalHiddenOutputQueueLimit = terminalOutputBacklogThreshold * 2;
const terminalHiddenOutputPreserveBytes = terminalOutputBacklogThreshold;
const terminalResumeOutputChunkSize = 8192;
const terminalResumeThrottleThreshold = terminalOutputBacklogThreshold / 2;
const terminalResumeThrottleFrames = 4;
const embeddedBackgroundDataUrlLimitBytes = 2 * 1024 * 1024;
const renderSlowFrameMs = 24;
const renderVerySlowFrameMs = 72;
const renderSlowFrameTriggerCount = 4;
const performanceMetricsRefreshMinMs = 250;
const performanceGuardStartupGraceMs = 2500;
const performanceGuardStartupRenderCount = 3;
const performanceGuardSlowPaneCreateMs = 2000;
const performanceGuardSlowTerminalConnectMs = 1500;
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
const backgroundPreviewKeys = new Set([
  "backgroundImage",
  "backgroundOpacity",
  "backgroundFit",
  "backgroundPosition",
  "backgroundEffects"
]);
const terminalSettingsPreviewKeys = new Set([
  "terminalFontFamily",
  "terminalFontSize",
  "terminalLineHeight",
  "terminalPadding",
  "terminalScrollback",
  "terminalStartupMode",
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
  "sidebarBranchMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "addTabStyle",
  "titleDetailMode",
  "paneColorMarkers",
  "focusMode",
  "showTabs",
  "showStatusbar",
  "sidebarWidth",
  "inspectorWidth",
  "performanceMode"
]);
const surfaceTabLayoutKeys = new Set([
  "tabSize",
  "addTabStyle",
  "paneColorMarkers",
  "focusMode",
  "showTabs"
]);
const browserSettingsPreviewKeys = new Set([
  "browserHomeUrl",
  "browserLaunchMode",
  "externalBrowserProfileId",
  "browserSuspendInactive"
]);
const settingsInspectorSettingKeys = {
  appearance: [
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
  ],
  browser: [
    "browserHomeUrl",
    "browserLaunchMode",
    "externalBrowserProfileId",
    "browserSuspendInactive"
  ],
  layout: [
    "density",
    "paneActionMode",
    "paneHeaderMode",
    "sidebarDetailMode",
    "sidebarBranchMode",
    "sidebarFooterMode",
    "toolbarMode",
    "tabSize",
    "addTabStyle",
    "titleDetailMode",
    "paneColorMarkers",
    "focusMode",
    "showTabs",
    "showStatusbar",
    "sidebarWidth",
    "inspectorWidth",
    "performanceMode"
  ],
  performance: [
    "performanceMode",
    "adaptivePerformance",
    "reduceMotion",
    "terminalPauseInactiveOutput",
    "terminalSmoothResumedOutput",
    "terminalScrollback",
    "terminalStartupMode",
    "backgroundOpacity",
    "backgroundEffects",
    "density",
    "toolbarMode",
    "paneActionMode",
    "showStatusbar",
    "terminalPadding",
    "browserSuspendInactive"
  ],
  terminal: [
    "accent",
    "terminalFontFamily",
    "terminalFontSize",
    "terminalLineHeight",
    "terminalPadding",
    "terminalScrollback",
    "terminalStartupMode",
    "terminalCursorStyle",
    "terminalCursorBlink",
    "terminalBackground",
    "terminalForeground",
    "terminalCursorColor",
    "terminalProfile",
    "terminalCustomShell"
  ],
  workspace: [
    "accent",
    "titleDetailMode",
    "terminalFontSize",
    "browserHomeUrl"
  ]
};
const settingsPresetSettingKeys = new Set(settingsPresets.flatMap((preset) => Object.keys(preset.settings || {})));
const profileSettingsSettingKeys = [...settingsPresetSettingKeys];
const quickSettingsSettingKeys = [
  ...new Set([
    ...settingsPresetSettingKeys,
    "browserHomeUrl",
    "terminalProfile",
    "terminalCustomShell",
    "browserLaunchMode",
    "externalBrowserProfileId",
    "browserSuspendInactive"
  ])
];
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
const paneResizeMinWidth = 1;
const paneResizeMinHeight = 1;
const settingsSaveDelay = 140;
const browserTabSnapshotSaveDelay = 180;
const terminalFontSizeMin = 10;
const terminalFontSizeMax = 22;
const terminalWheelZoomThreshold = 80;
const terminalWheelZoomIdleResetMs = 450;
const terminalWheelZoomMaxSteps = 3;
const paletteVisibleResultLimit = 80;
const deferredTerminalInitIdleTimeoutMs = 70;
const browserLoadTimeoutMs = 15000;
const browserSuspendStopDelayMs = 1200;
const embeddedGooglePolishMinIntervalMs = 750;
const paneCreationBusyAnimationDelayMs = 2000;
const operationChromeRefreshMs = 1000;
const browserLoadingStatusText = t("browser.loadingStatus");
const browserPausedStatusText = t("browser.pausedStatus");
const paneResizeFitThrottleMs = 90;
const panePointerDragThreshold = 6;
const settingsWorkspaceSwitchRenderDelayMs = 90;
const closedPanelLimit = 12;
const maxConcurrentPaneCreations = 8;
const visibleBackgroundOpacity = 24;
const terminalCursorMigrationStorageKey = "cmux.terminalCursorBarMigration";
const browserHomeMigrationStorageKey = "cmux.browserHomeGoogleMigration";
const sidebarBranchMigrationStorageKey = "cmux.sidebarBranchQuietMigration";
const launchToken = new URLSearchParams(location.search).get("token") || "";
const eventReconnectMinDelayMs = 250;
const eventReconnectMaxDelayMs = 5000;
const embeddedGooglePolishState = new WeakMap();

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
  colorApplyTarget: "accent",
  backgroundApplyTarget: "app",
  closedPanels: [],
  workspaceRows: new Map(),
  surfaceTabButtons: new Map(),
  workspaceListSignature: "",
  workspaceListContentSignature: "",
  workspaceListActiveId: "",
  paneCleanupSignature: null,
  surfaceTabsSignature: "",
  surfaceTabsLayoutSignature: "",
  surfaceTabOverflowSignature: "",
  paneRenderSignature: "",
  paneStructureSignature: "",
  paneFitSignature: "",
  visiblePanePanelIds: new Set(),
  newSurfaceAddButtons: {
    terminal: null,
    browser: null
  },
  paletteOpen: false,
  paletteIndex: 0,
  paletteRenderFrame: 0,
  paletteFocusFrame: 0,
  paletteListSignature: "",
  paletteEntriesCache: null,
  paletteEntriesCacheSignature: "",
  surfaceTabScrollFrame: 0,
  surfaceTabScrollTargetId: "",
  surfaceTabScrollStateFrame: 0,
  surfaceTabOverflowFrame: 0,
  surfaceTabEnsureActive: false,
  surfaceTabResizeObserver: null,
  surfaceTabDropTargetId: "",
  surfaceTabDropTargetMode: "",
  commandStripOverflowFrame: 0,
  commandStripScrollFrame: 0,
  commandStripResizeObserver: null,
  dragPanelId: null,
  dragWorkspaceId: null,
  workspaceDropTargetId: "",
  workspaceDropTargetMode: "",
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
  operationChromeTimer: 0,
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
  terminalFontSizeSyncTimers: new Map(),
  windowResizing: null,
  windowMaximized: false,
  resizing: null,
  sidebarResizing: null,
  inspectorResizing: null,
  panePointerDrag: null,
  lastInteractedPanelId: null,
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
  immediateTerminalInitPanelIds: new Set(),
  deferredTerminalFitFrame: 0,
  appearancePreviewFrame: 0,
  terminalSettingsPreviewFrame: 0,
  layoutSettingsPreviewFrame: 0,
  browserSettingsPreviewFrame: 0,
  settingsFilterFrame: 0,
  performanceMetricsRefreshFrame: 0,
  performanceMetricsRefreshTimer: 0,
  performanceMetricsRefreshAt: 0,
  settingsSearchIndex: [],
  settingsSearchIndexVersion: 0,
  settingsSearchEmpty: null,
  settingsSearchClear: null,
  settingsSearchFeedback: null,
  settingsSearchResultText: "",
  settingsSearchFocusPending: false,
  settingsSearchLastFilterSignature: "",
  settingsSearchDisclosuresOpenVersion: 0,
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
  settingsInspectorRenderFrame: 0,
  settingsInspectorRenderTimer: 0,
  settingsInspectorRenderOptions: null,
  deferSettingsInspectorForWorkspaceSwitch: false,
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
  topbar: document.querySelector(".topbar"),
  sidebar: document.getElementById("sidebar"),
  workspaceList: document.getElementById("workspaceList"),
  workspaceHeading: document.getElementById("workspaceHeading"),
  workspaceSubheading: document.getElementById("workspaceSubheading"),
  commandStrip: document.querySelector(".command-strip"),
  surfaceTabs: document.getElementById("surfaceTabs"),
  paneGrid: document.getElementById("paneGrid"),
  paneCreationButtons: [
    document.getElementById("newTerminalButton"),
    document.getElementById("splitRightButton"),
    document.getElementById("splitDownButton"),
    document.getElementById("newBrowserButton")
  ].filter(Boolean),
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
  windowResizeEdges: Array.from(document.querySelectorAll("[data-window-resize-edge]")),
  maximizeWindowButton: document.getElementById("maximizeWindowButton")
};

elements.paneLayoutStyle = document.createElement("style");
elements.paneLayoutStyle.id = "paneLayoutStyle";
document.head.appendChild(elements.paneLayoutStyle);
elements.paletteInput.placeholder = t("palette.placeholder");
elements.paletteInput.setAttribute("aria-label", t("palette.searchLabel"));

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
  const fallbackColor = String(fallback || "").trim();
  if (isSafeCustomColor(color)) return color;
  return isSafeCustomColor(fallbackColor) ? fallbackColor : "#5d8cff";
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
  if (!sidebarBranchOptions.some(([id]) => id === next.sidebarBranchMode)) next.sidebarBranchMode = defaultSettings.sidebarBranchMode;
  if (!sidebarFooterOptions.some(([id]) => id === next.sidebarFooterMode)) next.sidebarFooterMode = defaultSettings.sidebarFooterMode;
  if (!toolbarModeOptions.some(([id]) => id === next.toolbarMode)) {
    next.toolbarMode = parsed.showAdvanced ? "expanded" : defaultSettings.toolbarMode;
  }
  if (!tabSizeOptions.some(([id]) => id === next.tabSize)) next.tabSize = defaultSettings.tabSize;
  if (!addTabStyleOptions.some(([id]) => id === next.addTabStyle)) next.addTabStyle = defaultSettings.addTabStyle;
  if (!titleDetailOptions.some(([id]) => id === next.titleDetailMode)) next.titleDetailMode = defaultSettings.titleDetailMode;
  if (!terminalCursorStyles.some(([id]) => id === next.terminalCursorStyle)) next.terminalCursorStyle = defaultSettings.terminalCursorStyle;
  if (!terminalFontOptions.some(([id]) => id === next.terminalFontFamily)) next.terminalFontFamily = defaultSettings.terminalFontFamily;
  if (!terminalProfiles.some(([id]) => id === next.terminalProfile)) next.terminalProfile = defaultSettings.terminalProfile;
  if (!terminalStartupOptions.some(([id]) => id === next.terminalStartupMode)) next.terminalStartupMode = defaultSettings.terminalStartupMode;
  next.backgroundImage = normalizeBackgroundValue(next.backgroundImage);
  next.browserHomeUrl = normalizeUrl(next.browserHomeUrl || defaultSettings.browserHomeUrl, defaultSettings.browserHomeUrl);
  if (!browserLaunchModeOptions.some(([id]) => id === next.browserLaunchMode)) next.browserLaunchMode = defaultSettings.browserLaunchMode;
  next.externalBrowserProfileId = String(next.externalBrowserProfileId || defaultSettings.externalBrowserProfileId).trim().slice(0, 120) || "system";
  next.browserSuspendInactive = next.browserSuspendInactive !== false;
  next.terminalCustomShell = String(next.terminalCustomShell || "").trim().slice(0, 512);
  next.showTabs = next.showTabs !== false;
  next.showStatusbar = next.showStatusbar !== false;
  next.paneColorMarkers = Boolean(next.paneColorMarkers);
  next.focusMode = Boolean(next.focusMode);
  next.showAdvanced = next.toolbarMode === "expanded";
  next.performanceMode = Boolean(next.performanceMode);
  next.adaptivePerformance = next.adaptivePerformance !== false;
  next.reduceMotion = Boolean(next.reduceMotion);
  next.terminalPauseInactiveOutput = next.terminalPauseInactiveOutput !== false;
  next.terminalSmoothResumedOutput = next.terminalSmoothResumedOutput !== false;
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
  if (
    localStorage.getItem(sidebarBranchMigrationStorageKey) !== "1"
    && parsed
    && typeof parsed === "object"
    && !Array.isArray(parsed)
    && (!Object.hasOwn(parsed, "sidebarBranchMode") || parsed.sidebarBranchMode === "active")
  ) {
    parsed.sidebarBranchMode = defaultSettings.sidebarBranchMode;
    localStorage.setItem(sidebarBranchMigrationStorageKey, "1");
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
  return /\.(avif|bmp|gif|jpe?g|png|svg|webp)$/i.test(String(name || ""));
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

function readDroppedBackgroundFileAsDataUrl(file) {
  return new Promise((resolve) => {
    if (!file || file.size > embeddedBackgroundDataUrlLimitBytes) {
      resolve({ ok: false, error: "too_large" });
      return;
    }
    const reader = new FileReader();
    reader.onload = () => resolve({ ok: true, url: String(reader.result || "") });
    reader.onerror = () => resolve({ ok: false, error: "unreadable" });
    reader.readAsDataURL(file);
  });
}

async function droppedBackgroundPayload(dataTransfer) {
  const file = firstDroppedBackgroundFile(dataTransfer);
  if (file) {
    const filePath = window.cmuxNative?.filePath?.(file) || file.path || "";
    const fileUrl = localPathToFileUrl(filePath);
    if (fileUrl) return { url: fileUrl, inputValue: fileUrl };
    const embedded = await readDroppedBackgroundFileAsDataUrl(file);
    if (embedded.ok && embedded.url) {
      return {
        url: embedded.url,
        inputValue: "",
        label: defaultBackgroundLabel(file.name) || "Dropped image"
      };
    }
    return { url: "", error: embedded.error || "unreadable" };
  }
  const text = droppedBackgroundText(dataTransfer);
  return text ? { url: text, inputValue: text } : null;
}

function hasBackgroundDropData(dataTransfer, options = {}) {
  if (state.dragPanelId || state.dragWorkspaceId) return false;
  const items = [...(dataTransfer?.items || [])];
  if (items.some((item) => item.kind === "file" && (!item.type || item.type.startsWith("image/")))) return true;
  const types = [...(dataTransfer?.types || [])];
  return types.includes("text/uri-list") || (options.allowPlainText !== false && types.includes("text/plain"));
}

function backgroundDropPanelForEvent(event, options = {}) {
  const candidate = typeof options.panelFromEvent === "function"
    ? options.panelFromEvent(event)
    : options.panel;
  return candidate ? resolveTerminalPanel(candidate) : null;
}

function backgroundDropPaneElement(panel) {
  if (!panel?.id) return null;
  return state.paneCache.get(panel.id) || elements.paneGrid.querySelector(`.pane[data-panel-id="${panel.id}"]`);
}

function clearBackgroundDropTarget(target) {
  target.classList.remove("is-background-drop-target", "is-drop-target");
  target._backgroundDropPane?.classList?.remove("is-background-drop-target");
  target._backgroundDropPane = null;
}

function updateBackgroundDropTarget(target, panel) {
  const pane = backgroundDropPaneElement(panel);
  if (target._backgroundDropPane && target._backgroundDropPane !== pane) {
    target._backgroundDropPane.classList.remove("is-background-drop-target");
  }
  target._backgroundDropPane = pane || null;
  target.classList.toggle("is-background-drop-target", !pane);
  target.classList.toggle("is-drop-target", !pane);
  pane?.classList.add("is-background-drop-target");
}

function installBackgroundDropTarget(target, options = {}) {
  if (!target) return;
  target.addEventListener("dragover", (event) => {
    if (!hasBackgroundDropData(event.dataTransfer, options)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    updateBackgroundDropTarget(target, backgroundDropPanelForEvent(event, options));
  });
  target.addEventListener("dragleave", (event) => {
    if (event.currentTarget.contains(event.relatedTarget)) return;
    clearBackgroundDropTarget(target);
  });
  target.addEventListener("drop", async (event) => {
    if (!hasBackgroundDropData(event.dataTransfer, options)) return;
    event.preventDefault();
    const panel = backgroundDropPanelForEvent(event, options);
    clearBackgroundDropTarget(target);
    const payload = await droppedBackgroundPayload(event.dataTransfer);
    if (!payload?.url) {
      toast(payload?.error === "too_large"
        ? "Dropped image is too large for a saved background."
        : "Drop a supported image file or image URL.");
      return;
    }
    const background = payload.label ? { url: payload.url, label: payload.label } : { url: payload.url };
    if (options.input && payload.inputValue) options.input.value = payload.inputValue;
    if (panel || Object.hasOwn(options, "panel")) {
      const changed = await applyPanelBackgroundImage(payload.url, panel || options.panel || null, { toast: true });
      if (changed !== null && options.input && !payload.inputValue) options.input.value = "";
      return;
    }
    if (options.saveTarget) {
      const target = typeof options.saveTarget === "function" ? options.saveTarget() : state.backgroundApplyTarget;
      const saved = await applyAndSaveBackgroundImageToTarget(background, target);
      if (saved && options.input && !payload.inputValue) options.input.value = "";
      return;
    }
    if (options.save) {
      const saved = await applyAndSaveCustomBackgroundImage(background);
      if (saved && options.input && !payload.inputValue) options.input.value = "";
      return;
    }
    if (options.applyTarget) {
      const target = typeof options.applyTarget === "function" ? options.applyTarget() : options.applyTarget;
      const changed = await applyBackgroundValueToTarget(payload.url, target, { toast: true });
      if (changed !== null && options.input && !payload.inputValue) options.input.value = "";
      return;
    }
    const changed = await applyCustomBackgroundImage(payload.url, { toast: true });
    if (changed !== null && options.input && !payload.inputValue) options.input.value = "";
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
  if (state.recentFolders.length === 0) {
    toast("Recent folders are already clear.");
    return false;
  }
  state.recentFolders = [];
  saveRecentFolders();
  renderSettingsInspector();
  toast("Recent folders cleared.");
  return true;
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
  if (state.recentCommands.length === 0) {
    toast("Recent commands are already clear.");
    return false;
  }
  state.recentCommands = [];
  saveRecentCommands();
  renderSettingsInspector();
  toast("Recent commands cleared.");
  return true;
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
  if (state.recentBrowserPages.length === 0) {
    toast("Recent browser pages are already clear.");
    return false;
  }
  state.recentBrowserPages = [];
  saveRecentBrowserPages();
  renderSettingsInspector();
  toast("Recent browser pages cleared.");
  return true;
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
  refreshBrowserExternalProfileButtons();
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

function browserExternalProfileTitle(profileId = state.settings.externalBrowserProfileId) {
  const label = browserProfileLabel(profileId);
  return profileId === "system" ? "Open in system browser" : `Open in ${label}`;
}

function refreshBrowserExternalProfileButtons() {
  for (const session of state.browserViews.values()) {
    if (!session?.external) continue;
    const title = browserExternalProfileTitle();
    setTitleIfChanged(session.external, title);
    if (session.external.getAttribute("aria-label") !== title) {
      session.external.setAttribute("aria-label", title);
    }
  }
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

function showNewTerminalMenu(event) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const workspace = activeWorkspace();
  const disabled = !workspace || paneCreationButtonsDisabled();
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = "New terminal";
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = workspace
    ? `${workspaceDisplayTitle(workspace)} / ${optionLabel(terminalProfiles, state.settings.terminalProfile, "Auto")}`
    : "Open a workspace first";
  const createProfile = (direction, shellProfile = state.settings.terminalProfile) => createTerminalPanel(direction, {
    workspaceId: workspace?.id,
    shellProfile
  });
  const placementActions = contextMenuActionGroup(
    contextMenuButton("Terminal right", () => createProfile("right"), disabled),
    contextMenuButton("Terminal below", () => createProfile("down"), disabled)
  );
  const profileActions = contextMenuActionGroup(...terminalProfiles.map(([id, label]) => {
    const isCustomMissing = id === "custom" && !state.settings.terminalCustomShell;
    const suffix = id === state.settings.terminalProfile ? " (default)" : "";
    return contextMenuButton(`${label}${suffix}`, () => createProfile("right", id), disabled || isCustomMissing);
  }));
  const settingsActions = contextMenuActionGroup(
    contextMenuButton("Terminal settings", () => openSettingsCategory("terminal")),
    contextMenuButton("Shell path", () => openSettingsCategory("terminal", { query: "shell path", focusSearch: true }))
  );
  menu.replaceChildren(
    title,
    meta,
    contextMenuSectionTitle("Placement"),
    placementActions,
    contextMenuSectionTitle("Shell profile"),
    profileActions,
    contextMenuSectionTitle("Settings"),
    settingsActions
  );
  showContextMenuAt(menu, event.clientX, event.clientY);
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

function commandSnippetCommandKey(command) {
  return normalizeTerminalCommand(command).toLowerCase();
}

function isBuiltInCommandSnippetSaved(snippet) {
  const commandKey = commandSnippetCommandKey(snippet?.command);
  if (!commandKey) return false;
  return state.customCommandSnippets.some((candidate) => commandSnippetCommandKey(candidate.command) === commandKey);
}

function customCommandSnippetsFull() {
  return state.customCommandSnippets.length >= customCommandSnippetsLimit;
}

function commandSnippetLimitTitle() {
  return `Snippet limit is ${customCommandSnippetsLimit}. Delete one first.`;
}

function upsertCustomCommandSnippet(snippet) {
  const normalized = normalizeCustomCommandSnippet(snippet);
  if (!normalized) return null;
  const commandKey = normalized.command.toLowerCase();
  const id = normalized.id || createCustomCommandSnippetId();
  const replacing = state.customCommandSnippets.some((candidate) => (
    candidate.id === id || candidate.command.toLowerCase() === commandKey
  ));
  if (!replacing && customCommandSnippetsFull()) {
    toast(commandSnippetLimitTitle());
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

function customColorPaletteFull() {
  return state.customColorPalette.length >= customColorPaletteLimit;
}

function customColorPaletteLimitTitle() {
  return `Saved color limit is ${customColorPaletteLimit}. Delete one first.`;
}

function customColorPaletteHasColor(color) {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) return false;
  return state.customColorPalette.some((candidate) => candidate.toLowerCase() === normalized);
}

function canSaveCustomColor(color) {
  const normalized = normalizeCustomPaletteColor(color);
  return Boolean(normalized && (customColorPaletteHasColor(normalized) || !customColorPaletteFull()));
}

function customColorSaveTitle(color, availableTitle = "Save this color to the reusable palette.") {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) return "Pick a custom hex color first.";
  if (customColorPaletteFull() && !customColorPaletteHasColor(normalized)) return customColorPaletteLimitTitle();
  return availableTitle;
}

function applyCustomColorSaveLimit(button, color, availableTitle = "Save this color to the reusable palette.") {
  if (!button) return button;
  const normalized = normalizeCustomPaletteColor(color);
  const disabled = !normalized || (!customColorPaletteHasColor(normalized) && customColorPaletteFull());
  button.disabled = disabled;
  button.title = customColorSaveTitle(normalized, availableTitle);
  return button;
}

function upsertCustomColorPalette(color, options = {}) {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) {
    if (options.toast !== false) toast("Pick a custom hex color first.");
    return false;
  }
  const existed = state.customColorPalette.some((candidate) => candidate.toLowerCase() === normalized);
  if (!existed && customColorPaletteFull()) {
    if (options.toast !== false) toast(customColorPaletteLimitTitle());
    return false;
  }
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
  const addTabs = optionLabel(addTabStyleOptions, normalized.addTabStyle, normalized.addTabStyle);
  const actions = paneActionOptions.find(([id]) => id === normalized.paneActionMode)?.[1] || normalized.paneActionMode;
  const backgroundEffects = optionLabel(backgroundEffectsOptions, normalized.backgroundEffects, "Flat");
  const startup = optionLabel(terminalStartupOptions, normalized.terminalStartupMode, "Fast");
  return [
    theme,
    normalized.density,
    toolbar,
    `${addTabs} add tabs`,
    `${actions} pane controls`,
    normalized.paneColorMarkers ? "colored pane markers" : "quiet pane markers",
    `${backgroundEffects.toLowerCase()} background`,
    normalized.performanceMode ? "performance" : normalized.reduceMotion ? "reduced motion" : "balanced",
    `${startup.toLowerCase()} startup`,
    normalized.terminalPauseInactiveOutput ? "paused output" : "live output",
    normalized.terminalSmoothResumedOutput ? "smooth resume" : "fast resume",
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
  const backgroundImage = type === "terminal" ? normalizeBackgroundValue(panel.backgroundImage) : "";
  return {
    type,
    title,
    color,
    backgroundImage,
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

function workspaceBlueprintsFull() {
  return state.workspaceBlueprints.length >= workspaceBlueprintsLimit;
}

function workspaceBlueprintLimitTitle() {
  return `Blueprint limit is ${workspaceBlueprintsLimit}. Delete one first.`;
}

function canSaveCurrentWorkspaceBlueprint(workspace = activeWorkspace()) {
  return Boolean(workspace?.panels?.length && !workspaceBlueprintsFull());
}

function currentWorkspaceBlueprintSaveTitle(workspace = activeWorkspace(), availableTitle = "Save the current workspace pane layout as a reusable blueprint.") {
  if (!workspace?.panels?.length) return "Open panes before saving a blueprint.";
  if (workspaceBlueprintsFull()) return workspaceBlueprintLimitTitle();
  return availableTitle;
}

function applyWorkspaceBlueprintSaveLimit(button, workspace = activeWorkspace(), availableTitle = "Save the current workspace pane layout as a reusable blueprint.") {
  if (!button) return button;
  button.disabled = !canSaveCurrentWorkspaceBlueprint(workspace);
  button.title = currentWorkspaceBlueprintSaveTitle(workspace, availableTitle);
  return button;
}

function upsertWorkspaceBlueprint(blueprint, options = {}) {
  const normalized = normalizeWorkspaceBlueprint(blueprint);
  if (!normalized) return null;
  const replacing = state.workspaceBlueprints.some((candidate) => candidate.id === normalized.id);
  if (!replacing && workspaceBlueprintsFull()) {
    if (options.toast !== false) toast(workspaceBlueprintLimitTitle());
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
  const name = fileNameFromUrl(url).replace(/\.(?:avif|bmp|gif|jpe?g|png|svg|webp)$/i, "");
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

function savedBackgroundImagesFull() {
  return state.savedBackgroundImages.length >= savedBackgroundImagesLimit;
}

function savedBackgroundImageLimitTitle() {
  return `Background limit is ${savedBackgroundImagesLimit}. Delete one first.`;
}

function savedBackgroundImageKey(value) {
  const url = normalizedImageUrl(value);
  return url ? url.toLowerCase() : "";
}

function savedBackgroundImageExists(value) {
  const key = savedBackgroundImageKey(value);
  if (!key) return false;
  return state.savedBackgroundImages.some((candidate) => savedBackgroundImageKey(candidate.url) === key);
}

function canSaveBackgroundImage(value) {
  const key = savedBackgroundImageKey(value);
  return Boolean(key && (savedBackgroundImageExists(key) || !savedBackgroundImagesFull()));
}

function savedBackgroundImageSaveTitle(value, availableTitle = "Save this image to the reusable background library.") {
  const key = savedBackgroundImageKey(value);
  if (!key) return "Choose a custom background image first.";
  if (savedBackgroundImagesFull() && !savedBackgroundImageExists(key)) return savedBackgroundImageLimitTitle();
  return availableTitle;
}

function applySavedBackgroundImageSaveLimit(button, value, availableTitle = "Save this image to the reusable background library.") {
  if (!button) return button;
  button.disabled = !canSaveBackgroundImage(value);
  button.title = savedBackgroundImageSaveTitle(value, availableTitle);
  return button;
}

function applySavedBackgroundImageCapacityLimit(button, availableTitle = "Save an image to the reusable background library.") {
  if (!button) return button;
  const full = savedBackgroundImagesFull();
  button.disabled = full;
  button.title = full ? savedBackgroundImageLimitTitle() : availableTitle;
  return button;
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
  if (!replacing && savedBackgroundImagesFull()) {
    if (options.toast !== false) toast(savedBackgroundImageLimitTitle());
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
  if (!saved) {
    if (options.toast !== false) toast(savedBackgroundImageLimitTitle());
    return null;
  }
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

async function applyAndSaveBackgroundImageToTarget(background, target = state.backgroundApplyTarget, options = {}) {
  const input = typeof background === "string" ? { url: background } : background || {};
  const source = input.url || input.value || input.backgroundImage;
  const scope = normalizeBackgroundApplyTarget(target);
  const targetOption = backgroundApplyTargetOption(scope);
  if (!activeBackgroundTargetStatus(scope).canTarget) {
    if (options.toast !== false) toast(`${targetOption.label} cannot use a background right now.`);
    return null;
  }
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
  const urlKey = validated.url.toLowerCase();
  const wasSaved = state.savedBackgroundImages.some((candidate) => candidate.url.toLowerCase() === urlKey);
  const saved = upsertSavedBackgroundImage({ ...input, url: validated.url }, { render: false, toast: false });
  if (!saved) {
    if (options.toast !== false) toast(savedBackgroundImageLimitTitle());
    return null;
  }
  const changed = await applyBackgroundValueToTarget(validated.url, scope, { render: false, toast: false });
  if (changed !== null && options.render !== false) renderSettingsInspector();
  if (options.toast !== false) {
    const targetLabel = targetOption.label.toLowerCase();
    if (changed === true && !wasSaved) toast(`Background saved and applied to ${targetLabel}.`);
    else if (changed === true) toast(`${saved.label} applied to ${targetLabel}.`);
    else if (!wasSaved) toast(`Background saved. ${targetOption.label} already uses it.`);
    else toast(`${targetOption.label} already uses ${saved.label}.`);
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

async function applyPanelBackgroundImage(value, panel = focusedPanel(), options = {}) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Select a terminal pane first.");
    return null;
  }
  const raw = String(value || "").trim();
  const current = normalizeBackgroundValue(terminalPanel.backgroundImage);
  if (!raw) {
    const changed = Boolean(current);
    if (!changed) {
      if (options.toast !== false) toast("Pane background is already clear.");
      return false;
    }
    await updatePanel(terminalPanel.id, { backgroundImage: "" });
    if (options.render !== false && state.inspectorMode === "settings") renderSettingsInspector();
    if (options.toast !== false) toast("Pane background cleared.");
    return true;
  }
  const preset = isBackgroundPreset(raw) ? raw : "";
  if (preset) {
    if (current === preset) {
      if (options.toast !== false) toast("Pane background is already active.");
      return false;
    }
    await updatePanel(terminalPanel.id, { backgroundImage: preset });
    if (options.render !== false && state.inspectorMode === "settings") renderSettingsInspector();
    if (options.toast !== false) toast("Pane background updated.");
    return true;
  }
  const validated = await validateBackgroundImageValue(raw);
  if (!validated.ok) {
    if (options.toast !== false) toast("Pane background image could not be loaded.");
    return null;
  }
  if (current === validated.url) {
    if (options.toast !== false) toast("Pane background is already active.");
    return false;
  }
  await updatePanel(terminalPanel.id, { backgroundImage: validated.url });
  if (options.render !== false && state.inspectorMode === "settings") renderSettingsInspector();
  if (options.toast !== false) toast("Pane background updated.");
  return true;
}

async function applyWorkspaceBackgroundImageToTerminals(value, workspace = activeWorkspace(), options = {}) {
  const terminals = (workspace?.panels || []).filter((panel) => panel.type === "terminal");
  if (terminals.length === 0) {
    if (options.toast !== false) toast("Open a terminal pane first.");
    return false;
  }
  const raw = String(value || "").trim();
  let backgroundImage = "";
  if (raw) {
    const preset = isBackgroundPreset(raw) ? raw : "";
    if (preset) {
      backgroundImage = preset;
    } else {
      const validated = await validateBackgroundImageValue(raw);
      if (!validated.ok) {
        if (options.toast !== false) toast("Pane background image could not be loaded.");
        return null;
      }
      backgroundImage = validated.url;
    }
  }
  const normalized = normalizeBackgroundValue(backgroundImage);
  const changedPanels = terminals.filter((panel) => normalizeBackgroundValue(panel.backgroundImage) !== normalized);
  if (changedPanels.length === 0) {
    if (options.toast !== false) {
      toast(normalized ? "Terminal pane backgrounds already match." : "Terminal pane backgrounds are already clear.");
    }
    return false;
  }
  await updatePanels(changedPanels.map((panel) => ({
    panelId: panel.id,
    updates: { backgroundImage: normalized }
  })));
  if (options.render !== false && state.inspectorMode === "settings") renderSettingsInspector();
  if (options.toast !== false) {
    const action = normalized ? "updated" : "cleared";
    toast(`${changedPanels.length} terminal pane${changedPanels.length === 1 ? "" : "s"} ${action}.`);
  }
  return true;
}

function normalizeBackgroundApplyTarget(target) {
  return ["app", "pane", "all"].includes(target) ? target : "app";
}

function backgroundApplyTargetOptions(workspace = activeWorkspace()) {
  const activeTerminal = activeTerminalPanelForSettings();
  const paneCount = workspaceTerminalPanels(workspace).length;
  return [
    {
      id: "app",
      label: "Whole app",
      meta: "window image",
      disabled: false
    },
    {
      id: "pane",
      label: "This terminal",
      meta: activeTerminal ? panelDisplayTitle(activeTerminal, true) : "select a terminal",
      disabled: !activeTerminal
    },
    {
      id: "all",
      label: "All terminals",
      meta: paneCount ? `${paneCount} pane${paneCount === 1 ? "" : "s"}` : "open a terminal",
      disabled: paneCount === 0
    }
  ];
}

function backgroundApplyTargetActionLabel(target = state.backgroundApplyTarget) {
  const option = backgroundApplyTargetOptions().find((candidate) => candidate.id === normalizeBackgroundApplyTarget(target));
  return option ? `${option.label} - ${option.meta}` : "Whole app - window image";
}

function backgroundApplyTargetOption(target = state.backgroundApplyTarget, workspace = activeWorkspace()) {
  return backgroundApplyTargetOptions(workspace).find((candidate) => candidate.id === normalizeBackgroundApplyTarget(target))
    || backgroundApplyTargetOptions(workspace)[0];
}

function backgroundApplyTargetPrimaryLabel(target = state.backgroundApplyTarget) {
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "pane") return "Apply to pane";
  if (scope === "all") return "Apply to all";
  return "Apply to app";
}

function backgroundApplyTargetSaveLabel(target = state.backgroundApplyTarget) {
  return `${backgroundApplyTargetPrimaryLabel(target)} + save`;
}

function backgroundApplyTargetClearLabel(target = state.backgroundApplyTarget) {
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "pane") return "Clear pane";
  if (scope === "all") return "Clear all";
  return "Clear app";
}

function backgroundTargetIconMarkup(target = state.backgroundApplyTarget) {
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "pane") return quickActionIconMarkup("paneBackground");
  if (scope === "all") return quickActionIconMarkup("terminalGroup");
  return quickActionIconMarkup("background");
}

function selectBackgroundApplyTarget(target = state.backgroundApplyTarget) {
  const nextTarget = normalizeBackgroundApplyTarget(target);
  const option = backgroundApplyTargetOption(nextTarget);
  if (!activeBackgroundTargetStatus(nextTarget).canTarget) {
    toast(formatMessage("quickGuide.backgroundTargetUnavailable", { label: option.label }));
    return false;
  }
  if (state.backgroundApplyTarget === nextTarget) return false;
  state.backgroundApplyTarget = nextTarget;
  refreshBackgroundPreviewNodes();
  refreshBackgroundLibraryPanels();
  return true;
}

function updateBackgroundCustomActionLabels(root = elements.inspectorBody, workspace = activeWorkspace()) {
  if (!root) return;
  const groups = root.matches?.("[data-background-custom-actions]")
    ? [root]
    : [...(root.querySelectorAll?.("[data-background-custom-actions]") || [])];
  if (groups.length === 0) return;
  const status = activeBackgroundTargetStatus(state.backgroundApplyTarget, workspace);
  const targetLabel = backgroundApplyTargetActionLabel(status.scope);
  const applyLabel = backgroundApplyTargetPrimaryLabel(status.scope);
  const clearLabel = backgroundApplyTargetClearLabel(status.scope);
  for (const group of groups) {
    const action = (id) => group.querySelector(`[data-background-custom-action="${id}"]`);
    const apply = action("apply");
    const applySave = action("apply-save");
    const paste = action("paste");
    const pasteSave = action("paste-save");
    const choose = action("choose");
    const chooseSave = action("choose-save");
    const clear = action("clear");
    if (apply) {
      setSettingsActionLabel(apply, applyLabel);
      setTitleIfChanged(apply, `Apply the typed image to ${targetLabel}`);
    }
    if (applySave) setTitleIfChanged(applySave, `Apply and save the typed image for ${targetLabel}`);
    if (paste) setTitleIfChanged(paste, `Paste an image for ${targetLabel}`);
    if (pasteSave) setTitleIfChanged(pasteSave, `Paste, apply, and save an image for ${targetLabel}`);
    if (choose) setTitleIfChanged(choose, `Choose an image for ${targetLabel}`);
    if (chooseSave) setTitleIfChanged(chooseSave, `Choose, apply, and save an image for ${targetLabel}`);
    if (clear) {
      setSettingsActionLabel(clear, clearLabel);
      setTitleIfChanged(clear, `Clear ${targetLabel}`);
    }
    for (const button of [apply, applySave, paste, pasteSave, choose, chooseSave].filter(Boolean)) {
      setDisabledIfChanged(button, !status.canTarget);
    }
    if (clear) setDisabledIfChanged(clear, !status.canTarget || !status.hasValue);
  }
}

function normalizeColorApplyTarget(target) {
  return ["accent", "workspace", "pane", "all"].includes(target) ? target : "accent";
}

function colorKey(value) {
  return String(value || "").trim().toLowerCase();
}

function colorApplyTargetOptions(workspace = activeWorkspace()) {
  const panel = focusedPanel() || activePanel();
  const paneCount = workspace?.panels?.length || 0;
  const workspaceColor = workspace?.color || state.settings.accent;
  const paneColor = panel?.color || workspaceColor;
  const paneColors = (workspace?.panels || []).map((candidate) => colorKey(candidate.color)).filter(Boolean);
  const uniquePaneColors = [...new Set(paneColors)];
  const allPaneStatus = paneCount
    ? uniquePaneColors.length > 1
      ? `${uniquePaneColors.length} colors`
      : colorSummaryLabel(uniquePaneColors[0] || "", workspaceColor)
    : "no panes";
  return [
    {
      id: "accent",
      label: "Accent",
      meta: "app chrome",
      color: state.settings.accent,
      status: colorSummaryLabel(state.settings.accent, defaultSettings.accent),
      disabled: false
    },
    {
      id: "workspace",
      label: "Workspace",
      meta: workspace ? workspaceDisplayTitle(workspace) : "no workspace",
      color: workspaceColor,
      status: workspace ? colorSummaryLabel(workspace?.color, state.settings.accent) : "no workspace",
      disabled: !workspace
    },
    {
      id: "pane",
      label: "This pane",
      meta: panel ? panelDisplayTitle(panel, true) : "no pane",
      color: paneColor,
      status: panel ? colorSummaryLabel(panel?.color, workspaceColor) : "no pane",
      disabled: !panel
    },
    {
      id: "all",
      label: "All panes",
      meta: paneCount ? `${paneCount} pane${paneCount === 1 ? "" : "s"}` : "no panes",
      color: uniquePaneColors.length === 1 ? uniquePaneColors[0] : workspaceColor,
      status: allPaneStatus,
      disabled: paneCount === 0
    }
  ];
}

function colorApplyTargetOption(target = state.colorApplyTarget, workspace = activeWorkspace()) {
  const options = colorApplyTargetOptions(workspace);
  return options.find((candidate) => candidate.id === normalizeColorApplyTarget(target)) || options[0];
}

function colorApplyTargetPrimaryLabel(target = state.colorApplyTarget) {
  const scope = normalizeColorApplyTarget(target);
  if (scope === "workspace") return "Apply to workspace";
  if (scope === "pane") return "Apply to pane";
  if (scope === "all") return "Apply to all";
  return "Apply to accent";
}

function colorApplyTargetActionLabel(target = state.colorApplyTarget, workspace = activeWorkspace()) {
  const option = colorApplyTargetOption(target, workspace);
  return option ? `${option.label} - ${option.meta}` : "Accent - app chrome";
}

function colorTargetIconMarkup(target = state.colorApplyTarget) {
  const scope = normalizeColorApplyTarget(target);
  if (scope === "workspace") return quickActionIconMarkup("workspace");
  if (scope === "pane") return quickActionIconMarkup("paneSettings");
  if (scope === "all") return quickActionIconMarkup("paneGroup");
  return quickActionIconMarkup("appearance");
}

function activePaneForColorTarget() {
  return focusedPanel() || activePanel();
}

async function applySavedColorToTarget(color, target = state.colorApplyTarget) {
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) {
    toast("Choose a saved color first.");
    return false;
  }
  const scope = normalizeColorApplyTarget(target);
  if (scope === "accent") {
    if (colorKey(state.settings.accent) === colorKey(normalized)) {
      toast("Accent already uses this color.");
      return false;
    }
    updateSettings({ accent: normalized });
    toast("Accent color updated.");
    return true;
  }
  if (scope === "workspace") {
    const workspace = activeWorkspace();
    if (!workspace) {
      toast("Open a workspace before applying workspace color.");
      return false;
    }
    if (String(workspace.color || "").toLowerCase() === normalized.toLowerCase()) {
      toast("Workspace already uses this color.");
      return false;
    }
    await setWorkspaceColor(normalized, workspace.id);
    toast("Workspace color updated.");
    return true;
  }
  if (scope === "pane") {
    const panel = activePaneForColorTarget();
    if (!panel) {
      toast("Open a pane before applying pane color.");
      return false;
    }
    if (String(panel.color || "").toLowerCase() === normalized.toLowerCase()) {
      toast("Pane already uses this color.");
      return false;
    }
    await updatePanel(panel.id, { color: normalized });
    toast("Pane color updated.");
    return true;
  }
  return setWorkspacePaneColors(normalized);
}

async function applyBackgroundValueToTarget(value, target = state.backgroundApplyTarget, options = {}) {
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "pane") return applyPanelBackgroundImage(value, activeTerminalPanelForSettings(), options);
  if (scope === "all") return applyWorkspaceBackgroundImageToTerminals(value, activeWorkspace(), options);
  return applyCustomBackgroundImage(value, options);
}

async function applyBackgroundPresetToTarget(preset, target = state.backgroundApplyTarget) {
  if (!preset) return false;
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "app") return applyBackgroundPreset(preset, { toast: true });
  return applyBackgroundValueToTarget(preset.value, scope, { toast: true });
}

async function applySavedBackgroundImageToTarget(backgroundId, target = state.backgroundApplyTarget) {
  const scope = normalizeBackgroundApplyTarget(target);
  if (scope === "app") return applySavedBackgroundImage(backgroundId);
  if (scope === "pane") return applySavedBackgroundImageToPanel(backgroundId);
  return applySavedBackgroundImageToWorkspaceTerminals(backgroundId);
}

async function applyCurrentBackgroundToTarget() {
  const target = normalizeBackgroundApplyTarget(state.backgroundApplyTarget);
  if (target === "app") {
    toast("The app already uses the current background.");
    return false;
  }
  if (!state.settings.backgroundImage) {
    toast("Choose an app background first.");
    return false;
  }
  return applyBackgroundValueToTarget(state.settings.backgroundImage, target, { toast: true });
}

async function clearBackgroundApplyTarget() {
  return applyBackgroundValueToTarget("", state.backgroundApplyTarget, { toast: true });
}

async function applySavedBackgroundImageToPanel(backgroundId, panel = focusedPanel()) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return null;
  return applyPanelBackgroundImage(background.url, panel, { toast: false }).then((changed) => {
    if (changed !== null) toast(`${background.label} applied to pane.`);
    return changed;
  });
}

async function applySavedBackgroundImageToWorkspaceTerminals(backgroundId, workspace = activeWorkspace()) {
  const background = state.savedBackgroundImages.find((candidate) => candidate.id === backgroundId);
  if (!background) return null;
  return applyWorkspaceBackgroundImageToTerminals(background.url, workspace, { toast: false }).then((changed) => {
    if (changed === true) {
      toast(`${background.label} applied to terminal panes.`);
    } else if (changed === false) {
      const terminals = (workspace?.panels || []).filter((panel) => panel.type === "terminal");
      toast(terminals.length ? "Terminal pane backgrounds already match." : "Open a terminal pane first.");
    }
    return changed;
  });
}

async function choosePanelBackgroundImage(panel = focusedPanel()) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Select a terminal pane first.");
    return null;
  }
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return null;
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return null;
  return applyPanelBackgroundImage(url, terminalPanel);
}

async function pastePanelBackgroundImageFromClipboard(panel = focusedPanel(), input = null) {
  if (!window.cmuxNative?.readClipboard) {
    toast("Clipboard is unavailable.");
    return null;
  }
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) {
    toast("Select a terminal pane first.");
    return null;
  }
  const textValue = String(await window.cmuxNative.readClipboard() || "").trim();
  let value = textValue;
  let pastedImage = false;
  let imageError = "";
  if (!value && window.cmuxNative?.readClipboardImage) {
    const image = await window.cmuxNative.readClipboardImage();
    if (image?.ok && image.dataUrl) {
      value = image.dataUrl;
      pastedImage = true;
    } else {
      imageError = image?.error || "";
    }
  }
  if (!value) {
    toast(imageError === "too_large"
      ? "Clipboard image is too large for a pane background."
      : "Clipboard does not contain an image URL, path, or copied image.");
    return null;
  }
  if (input) input.value = pastedImage ? "Copied image" : value;
  const changed = await applyPanelBackgroundImage(value, terminalPanel);
  if (changed !== null && pastedImage && input?.isConnected) input.value = "";
  return changed;
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
    settings.addTabStyle,
    settings.titleDetailMode,
    settings.paneColorMarkers,
    settings.focusMode,
    settings.showTabs,
    settings.showStatusbar,
    settings.showAdvanced,
    settings.performanceMode,
    settings.reduceMotion,
    settings.paneHeaderMode,
    settings.paneActionMode,
    settings.sidebarDetailMode,
    settings.sidebarBranchMode,
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
  setStylePropertyIfChanged(document.documentElement, "--color-accent", state.settings.accent);
  setStylePropertyIfChanged(document.documentElement, "--color-accent-hover", state.settings.accent);
  setStylePropertyIfChanged(elements.shell, "--sidebar-width", `${state.settings.sidebarWidth}px`);
  setStylePropertyIfChanged(elements.shell, "--inspector-width", `${state.settings.inspectorWidth}px`);
  setStylePropertyIfChanged(elements.shell, "--terminal-font-family", terminalFontStack());
  setStylePropertyIfChanged(elements.shell, "--terminal-padding", `${state.settings.terminalPadding}px`);
  const tabMetrics = tabSizeMetrics.get(state.settings.tabSize) || tabSizeMetrics.get(defaultSettings.tabSize);
  setStylePropertyIfChanged(elements.shell, "--surface-tab-min", `${tabMetrics.min}px`);
  setStylePropertyIfChanged(elements.shell, "--surface-tab-basis", `${tabMetrics.basis}px`);
  setStylePropertyIfChanged(elements.shell, "--surface-tab-max", `${tabMetrics.max}px`);
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
  toggleClassIfChanged(elements.shell, "workspace-branch-hidden", state.settings.sidebarBranchMode === "hidden");
  toggleClassIfChanged(elements.shell, "workspace-branch-active", state.settings.sidebarBranchMode === "active");
  toggleClassIfChanged(elements.shell, "workspace-branch-all", state.settings.sidebarBranchMode === "all");
  toggleClassIfChanged(elements.shell, "sidebar-footer-workspace", state.settings.sidebarFooterMode === "workspace");
  toggleClassIfChanged(elements.shell, "sidebar-footer-compact", state.settings.sidebarFooterMode === "compact");
  toggleClassIfChanged(elements.shell, "sidebar-footer-full", state.settings.sidebarFooterMode === "full");
  toggleClassIfChanged(elements.shell, "toolbar-minimal", state.settings.toolbarMode === "minimal");
  toggleClassIfChanged(elements.shell, "toolbar-compact", state.settings.toolbarMode === "compact");
  toggleClassIfChanged(elements.shell, "toolbar-standard", state.settings.toolbarMode === "standard");
  toggleClassIfChanged(elements.shell, "toolbar-expanded", state.settings.toolbarMode === "expanded");
  toggleClassIfChanged(elements.shell, "add-tabs-labeled", state.settings.addTabStyle === "labeled");
  toggleClassIfChanged(elements.shell, "add-tabs-compact", state.settings.addTabStyle === "compact");
  toggleClassIfChanged(elements.shell, "add-tabs-hidden", state.settings.addTabStyle === "hidden");
  toggleClassIfChanged(elements.shell, "pane-color-markers", state.settings.paneColorMarkers);
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
  setStylePropertyIfChanged(elements.shell, "--background-image", css);
  setStylePropertyIfChanged(elements.shell, "--background-opacity", String(state.settings.backgroundOpacity / 100));
  setStylePropertyIfChanged(elements.shell, "--background-size", backgroundSizeCss(state.settings.backgroundFit));
  setStylePropertyIfChanged(elements.shell, "--background-repeat", backgroundRepeatCss(state.settings.backgroundImage));
  setStylePropertyIfChanged(elements.shell, "--background-position", backgroundPositionCss(state.settings.backgroundPosition));
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
    if (changedKeys.every((key) => backgroundPreviewKeys.has(key))) {
      scheduleBackgroundPreviewRefresh();
    } else {
      scheduleAppearancePreviewRefresh();
    }
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
  if (changedKeys.includes("externalBrowserProfileId")) {
    refreshBrowserExternalProfileButtons();
  }
  if (changedKeys.some((key) => surfaceTabLayoutKeys.has(key))) {
    scheduleSurfaceTabsOverflowRefresh({ ensureActive: true });
  }
  if (changedKeys.includes("terminalPauseInactiveOutput") || changedKeys.includes("performanceMode")) {
    resumeTerminalOutputAfterActivityChange();
  }
  if (changedKeys.includes("terminalSmoothResumedOutput") && !state.settings.terminalSmoothResumedOutput) {
    for (const session of state.terminals.values()) session.resumeThrottleFrames = 0;
  }
  if (changedKeys.includes("terminalStartupMode") && shouldStartColdTerminalsFast()) {
    startVisibleColdTerminalsImmediately();
  }
  if (changedKeys.includes("browserSuspendInactive")) {
    scheduleRender();
  } else if (previous.titleDetailMode !== state.settings.titleDetailMode) {
    scheduleRender();
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
  let tree = normalizePaneTree(existing, allowedPanelIds);
  const presentPanelIds = new Set(paneTreeLeafIds(tree));
  for (const panelId of panelIds) {
    if (!presentPanelIds.has(panelId)) {
      tree = appendPaneTreeLeaf(tree, panelId, paneLayoutDirection(workspace));
      presentPanelIds.add(panelId);
    }
  }
  if (!tree) tree = buildPaneTreeFromPanelIds(panelIds, paneLayoutDirection(workspace));
  if (!paneTreeEqual(tree, existing)) {
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
    if (paneTreeEqual(next, tree)) continue;
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

function cleanupPaneLayouts(livePanelIds = allPanelIds()) {
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
  const weights = new Map();
  for (const panel of panels) {
    const weight = storedPaneWeight(panel.id, direction);
    if (!weight) return null;
    weights.set(panel.id, weight);
  }
  return weights;
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

function applyVisiblePaneSplitRatio(splitId, ratio) {
  if (!splitId) return false;
  const splitter = elements.paneGrid.querySelector(`[data-splitter-key="${splitId}"]`);
  const previousPane = splitter?.previousElementSibling;
  const nextPane = splitter?.nextElementSibling;
  if (!splitter || !previousPane || !nextPane) return false;
  const nextRatio = paneTreeRatio(ratio);
  previousPane.style.flex = `${Math.round(nextRatio * paneLayoutScale)} 1 0px`;
  nextPane.style.flex = `${Math.round((1 - nextRatio) * paneLayoutScale)} 1 0px`;
  setSplitterResizePercent(splitter, Math.round(nextRatio * 100), splitter.dataset.orientation || "right");
  return true;
}

function renderPaneLayoutStylesForVisiblePanes(direction) {
  const panes = [...elements.paneGrid.querySelectorAll(".pane")];
  if (panes.length <= 1) {
    elements.paneLayoutStyle.textContent = "";
    return false;
  }
  const weights = new Map();
  for (const pane of panes) {
    const weight = storedPaneWeight(pane.dataset.panelId, direction);
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
  setStylePropertyIfChanged(pane, "flex", "");
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
  const weights = panes.map((pane) => storedPaneWeight(pane.dataset.panelId, direction));
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
    if (options.render === false) {
      if (!applyVisiblePaneSplitRatio(found.split.id, ratio)) scheduleRender();
    } else {
      scheduleRender();
      scheduleWorkspaceTerminalFits(workspace.id, true);
    }
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
  scheduleLayoutSettingsRefresh({ ifChanged: true });
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

function terminalTheme(panel = null) {
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim() || "#72a4ff";
  const hasPaneBackground = Boolean(panel?.type === "terminal" && normalizeBackgroundValue(panel.backgroundImage));
  const background = hasPaneBackground ? "transparent" : state.settings.terminalBackground || terminalColorDefaults.background;
  const paletteBackground = state.settings.terminalBackground || terminalColorDefaults.background;
  const foreground = state.settings.terminalForeground || terminalColorDefaults.foreground;
  const cursor = state.settings.terminalCursorColor || accent;
  return {
    background,
    foreground,
    cursor,
    cursorAccent: "#111316",
    selectionBackground: "#315a92",
    black: paletteBackground,
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

function terminalThemeSignature(panel = null) {
  const paneBackground = panel?.type === "terminal" ? normalizeBackgroundValue(panel.backgroundImage) : "";
  return [
    state.settings.theme,
    state.settings.accent,
    state.settings.terminalBackground || terminalColorDefaults.background,
    state.settings.terminalForeground || terminalColorDefaults.foreground,
    state.settings.terminalCursorColor || "",
    paneBackground ? "pane-bg" : ""
  ].join("|");
}

function applyTerminalThemeIfChanged(session, panel = null, options = {}) {
  if (!session?.term) return false;
  const signature = terminalThemeSignature(panel);
  if (!options.force && session.terminalThemeSignature === signature) return false;
  session.term.options.theme = terminalTheme(panel);
  session.terminalThemeSignature = signature;
  return true;
}

function syncTerminalSessionPanelState(panel) {
  if (panel?.type !== "terminal") return false;
  const session = state.terminals.get(panel.id);
  if (!session?.term) return false;
  let changed = applyTerminalThemeIfChanged(session, panel);
  const nextFontSize = terminalFontSizeForPanel(panel);
  if (session.fontSize !== nextFontSize || session.term.options.fontSize !== nextFontSize) {
    session.fontSize = nextFontSize;
    session.term.options.fontSize = nextFontSize;
    scheduleFitTerminal(session, true);
    changed = true;
  }
  return changed;
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
    applyTerminalThemeIfChanged(session, panel);
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
  { id: "workspace.newStarterTerminalBrowser", label: "New Workspace With Terminal + Browser", shortcut: "", run: () => createWorkspaceFromStarter("terminalBrowser") },
  { id: "workspace.newStarterTwoTerminals", label: "New Workspace With Two Terminals", shortcut: "", run: () => createWorkspaceFromStarter("twoTerminals") },
  { id: "workspace.newStarterDevTrio", label: "New Workspace With Dev Trio", shortcut: "", run: () => createWorkspaceFromStarter("devTrio") },
  { id: "workspace.saveBlueprint", label: "Save Workspace Blueprint", shortcut: "", run: () => saveCurrentWorkspaceBlueprint() },
  { id: "settings.blueprints", label: "Open Workspace Blueprints", shortcut: "", run: () => openSettingsCategory("blueprints") },
  { id: "workspace.closeEmpty", label: "Close Empty Workspaces", shortcut: "", run: () => closeEmptyWorkspaces() },
  { id: "workspace.close", label: "Close Workspace", shortcut: "", run: () => closeActiveWorkspace() },
  { id: "terminal.new", label: "New Terminal", shortcut: "Ctrl+T", run: () => createTerminalPanel("right") },
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
  { id: "terminal.closeAll", label: "Close All Panes", shortcut: "", run: () => closeAllPanes() },
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
  { id: "settings.pane", label: "Open Active Pane Settings", shortcut: "", run: () => openPaneSettings() },
  { id: "settings.resetAppearance", label: "Reset Look Settings", shortcut: "", run: () => resetAppearanceSettings() },
  { id: "settings.performance", label: "Open Performance Settings", shortcut: "", run: () => openSettingsCategory("performance") },
  { id: "settings.tunePerformance", label: "Tune Performance Now", shortcut: "", run: () => tunePerformanceNow() },
  { id: "settings.cleanFast", label: "Apply Clean + Fast Setup", shortcut: "", run: () => applySettingsPresetById("simpleFast") },
  { id: "settings.saveCleanFastProfile", label: "Save Clean + Fast Profile", shortcut: "", run: () => applyAndSaveCleanFastProfile() },
  { id: "settings.savePerformanceProfile", label: "Save Performance Profile", shortcut: "", run: () => saveCurrentPerformanceProfile() },
  { id: "settings.copyDiagnostics", label: "Copy Performance Diagnostics", shortcut: "", run: () => copyPerformanceDiagnostics() },
  { id: "settings.actions", label: "Open Actions Settings", shortcut: "", run: () => openSettingsCategory("actions") },
  { id: "settings.commands", label: "Open Command Snippets", shortcut: "", run: () => openSettingsCategory("commands") },
  { id: "settings.profiles", label: "Open Settings Profiles", shortcut: "", run: () => openSettingsCategory("profiles") },
  { id: "settings.saveProfile", label: "Save Current Settings Profile", shortcut: "", run: () => saveCurrentSettingsProfile() },
  { id: "settings.clearRecentActivity", label: "Clear Recent Activity", shortcut: "", run: () => clearRecentActivity() },
  { id: "settings.terminal", label: "Open Terminal Settings", shortcut: "", run: () => openSettingsCategory("terminal") },
  { id: "settings.terminalColors", label: "Reset Terminal Colors", shortcut: "", run: () => applyTerminalColorPresetById("cmux") },
  { id: "settings.saveTerminalProfile", label: "Save Terminal Profile", shortcut: "", run: () => saveCurrentTerminalProfile() },
  { id: "settings.colors", label: "Open Color Settings", shortcut: "", run: () => openSettingsCategory("appearance", { query: "color", focusSearch: true }) },
  { id: "settings.saveAccentColor", label: "Save Current Accent Color", shortcut: "", run: () => upsertCustomColorPalette(state.settings.accent) },
  { id: "settings.saveWorkspaceColor", label: "Save Current Workspace Color", shortcut: "", run: () => upsertCustomColorPalette(activeWorkspace()?.color) },
  { id: "settings.backgrounds", label: "Open Background Settings", shortcut: "", run: () => openSettingsCategory("appearance", { query: "background", focusSearch: true }) },
  { id: "settings.saveBackground", label: "Save Current Background", shortcut: "", run: () => saveCustomBackgroundImage({ url: state.settings.backgroundImage }) },
  { id: "settings.saveBrowserProfile", label: "Save Browser Profile", shortcut: "", run: () => saveCurrentBrowserProfile() },
  { id: "session.reset", label: "Reset Session", shortcut: "", run: () => resetSession() },
  { id: "sidebar.toggle", label: "Toggle Sidebar", shortcut: "Ctrl+B", run: () => toggleSidebar() }
];

const paneLayoutCommandPresetIds = new Map([
  ["layout.equalPanes", "equal"],
  ["layout.sideBySide", "sideBySide"],
  ["layout.stacked", "stacked"],
  ["layout.activeWide", "activeWide"],
  ["layout.activeTall", "activeTall"]
]);

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

function workspaceSuggestedTitle(workspace = activeWorkspace()) {
  return folderName(workspace?.cwd) || workspace?.title || "Workspace";
}

function allPanelIds() {
  return new Set(allPanels().map((panel) => panel.id));
}

function livePaneStructureSignature() {
  const parts = [];
  for (const workspace of state.data?.workspaces || []) {
    parts.push(String(workspace.id || "").length, ":", workspace.id || "", "[");
    for (const panel of workspace.panels || []) {
      parts.push(String(panel.id || "").length, ":", panel.id || "", ";");
    }
    parts.push("]");
  }
  return parts.join("");
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
  return state.visiblePanePanelIds;
}

function findPanelState(panelId) {
  for (const workspace of state.data?.workspaces || []) {
    const panel = workspace.panels.find((candidate) => candidate.id === panelId);
    if (panel) return { workspace, panel };
  }
  return null;
}

function closingPanelShowsWorkspaceHome(workspace, panelId) {
  return Boolean(
    workspace
    && Array.isArray(workspace.panels)
    && workspace.panels.length === 1
    && workspace.panels[0]?.id === panelId
  );
}

function closePaneActionLabel(workspace, panelId) {
  return closingPanelShowsWorkspaceHome(workspace, panelId) ? "Close pane and show cmux home" : "Close pane";
}

function panelFromElement(target) {
  const element = target?.nodeType === Node.ELEMENT_NODE ? target : target?.parentElement;
  const panelId = element?.closest?.(".pane[data-panel-id]")?.dataset?.panelId || "";
  return panelId ? findPanelState(panelId)?.panel || null : null;
}

function panelFromPoint(clientX, clientY) {
  if (!Number.isFinite(clientX) || !Number.isFinite(clientY) || typeof document.elementsFromPoint !== "function") {
    return null;
  }
  for (const element of document.elementsFromPoint(clientX, clientY)) {
    const panel = panelFromElement(element);
    if (panel) return panel;
  }
  return null;
}

function panelFromEvent(event) {
  for (const target of event?.composedPath?.() || []) {
    const panel = panelFromElement(target);
    if (panel) return panel;
  }
  return panelFromElement(event?.target) || panelFromPoint(event?.clientX, event?.clientY);
}

function terminalPanelFromBackgroundDropEvent(event) {
  const panel = panelFromEvent(event);
  return panel?.type === "terminal" && !isPendingPanel(panel) && !isPanelMinimized(panel) ? panel : null;
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
    refreshAppStateSignature();
    queueFocusSync({ type: "panel", panelId });
    updateBrowserPaneActivity(visiblePanePanelIds());
    scheduleRender();
  }
  if (zoomChanged && wasActive) scheduleRender();
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
  items.forEach((item, index) => appendItem(parts, item, index));
}

function appendSignatureData(parts, value) {
  if (value instanceof Map) {
    parts.push("m", String(value.size), "{");
    for (const [key, item] of value.entries()) {
      appendSignatureValue(parts, key);
      appendSignatureData(parts, item);
    }
    parts.push("}");
    return;
  }
  if (Array.isArray(value)) {
    appendSignatureArray(parts, value, (nextParts, item) => appendSignatureData(nextParts, item));
    return;
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value);
    parts.push("o", String(keys.length), "{");
    for (const key of keys) {
      appendSignatureValue(parts, key);
      appendSignatureData(parts, value[key]);
    }
    parts.push("}");
    return;
  }
  appendSignatureValue(parts, value);
}

function appendPanelSignature(parts, panel = {}) {
  appendSignatureValue(parts, panel.id);
  appendSignatureValue(parts, panel.workspaceId);
  appendSignatureValue(parts, panel.type);
  appendSignatureValue(parts, panel.title);
  appendSignatureValue(parts, Boolean(panel.titleLocked));
  appendSignatureValue(parts, panel.color || "");
  appendSignatureValue(parts, panel.backgroundImage || "");
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
      deferCreatedTerminalInitUntilPaint(resolvedPanel, workspace, {
        activeWorkspaceId: nextData.activeWorkspaceId,
        focus: pendingPanel.focus,
        immediateTerminalInit: pendingPanel.immediateTerminalInit
      });
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

function refreshAppStateSignature() {
  state.dataSignature = appStateSignature(state.data);
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
  const deferSettingsInspector = Boolean(
    state.deferSettingsInspectorForWorkspaceSwitch
    && state.inspectorMode === "settings"
  );
  state.deferSettingsInspectorForWorkspaceSwitch = false;
  renderInspector({ deferSettings: deferSettingsInspector });
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
  schedulePerformanceMetricsRefresh();
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

function performanceGuardCanUseActivitySignal() {
  return performance.now() - state.performanceGuardStartedAt >= performanceGuardStartupGraceMs;
}

function cleanupStalePaneCache() {
  const signature = livePaneStructureSignature();
  if (signature === state.paneCleanupSignature) return;
  state.paneCleanupSignature = signature;
  const livePanelIds = allPanelIds();
  for (const panelId of [...state.paneCache.keys()]) {
    if (!livePanelIds.has(panelId)) cleanupPanel(panelId);
  }
  cleanupPaneLayouts(livePanelIds);
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
  const operations = [...state.uiOperations.values()];
  const latest = operations.at(-1);
  const createCount = operations.filter((operation) => operation.kind === "create-panel").length;
  const elapsed = paneCreationElapsedSeconds();
  const elapsedSuffix = elapsed >= 2 ? ` (${elapsed}s)` : "";
  if (latest?.kind === "create-panel" && createCount > 1) return `Starting ${createCount} panes${elapsedSuffix}...`;
  if (latest?.kind === "create-panel" && elapsedSuffix) {
    return String(latest.label || "Starting pane...").replace(/\.\.\.$/, `${elapsedSuffix}...`);
  }
  return latest?.label || "";
}

function paneCreationButtonsDisabled() {
  return paneCreationOperationCount() >= maxConcurrentPaneCreations;
}

function paneCreationLimitLabel() {
  return `Pane startup queue is full (${maxConcurrentPaneCreations}). Wait for one to finish.`;
}

function paneCreationQueueStatusLabel() {
  const count = paneCreationOperationCount();
  if (count <= 0) return "";
  const elapsed = paneCreationElapsedSeconds();
  const elapsedLabel = elapsed >= 2 ? ` Oldest ${elapsed}s.` : "";
  return `${count}/${maxConcurrentPaneCreations} pane startup${count === 1 ? "" : "s"} running.${elapsedLabel}`;
}

function paneCreationActionTitle(baseTitle, readyHint = "") {
  if (paneCreationButtonsDisabled()) return paneCreationLimitLabel();
  const queueLabel = paneCreationQueueStatusLabel();
  const title = String(baseTitle || "Add pane").trim();
  const titleSentence = /[.!?]$/.test(title) ? title : `${title}.`;
  return [titleSentence, queueLabel, readyHint].filter(Boolean).join(" ");
}

function paneCreationBusyLabel(type = "") {
  return type === "browser" ? "Opening" : "Starting";
}

function paneCreationButtonBaseLabel(button) {
  const label = button?.querySelector?.(".tool-label");
  if (!label) return "";
  if (!button.dataset.paneCreationBaseLabel) {
    button.dataset.paneCreationBaseLabel = label.textContent || "";
  }
  return button.dataset.paneCreationBaseLabel;
}

function updatePaneCreationButtonLabel(button, type, creating) {
  const label = button?.querySelector?.(".tool-label");
  if (!label) return;
  const next = creating ? paneCreationBusyLabel(type) : paneCreationButtonBaseLabel(button);
  setTextIfChanged(label, next);
}

function paneCreationButtonBaseTitle(button) {
  if (!button) return "Add pane";
  if (!button.dataset.paneCreationBaseTitle) {
    button.dataset.paneCreationBaseTitle = button.getAttribute("title")
      || button.getAttribute("aria-label")
      || "Add pane";
  }
  return button.dataset.paneCreationBaseTitle;
}

function updatePaneCreationButtonState(button) {
  if (!button) return;
  const disabled = paneCreationButtonsDisabled();
  const buttonType = paneCreationButtonType(button);
  const creating = paneCreationOperationCount(buttonType) > 0;
  const waiting = creating && paneCreationOperationWaiting(buttonType);
  const title = paneCreationActionTitle(paneCreationButtonBaseTitle(button));
  setDisabledIfChanged(button, disabled);
  toggleClassIfChanged(button, "is-creating", creating && !disabled);
  toggleClassIfChanged(button, "is-waiting", waiting && !disabled);
  updatePaneCreationButtonLabel(button, buttonType, creating && !disabled);
  setTitleIfChanged(button, title);
  setAttributeIfChanged(button, "aria-label", title);
}

function paneCreationButtonType(button) {
  if (!button?.id) return "";
  if (button.id === "newBrowserButton") return "browser";
  if (button.id === "newTerminalButton" || button.id === "splitRightButton" || button.id === "splitDownButton") return "terminal";
  return "";
}

function paneCreationOperationCount(type = "") {
  const requestedType = String(type || "");
  let count = 0;
  for (const operation of state.uiOperations.values()) {
    if (operation.kind !== "create-panel") continue;
    if (requestedType && operation.paneType && operation.paneType !== requestedType) continue;
    count += 1;
  }
  return count;
}

function paneCreationOperationWaiting(type = "") {
  const requestedType = String(type || "");
  const now = performance.now();
  for (const operation of state.uiOperations.values()) {
    if (operation.kind !== "create-panel") continue;
    if (requestedType && operation.paneType && operation.paneType !== requestedType) continue;
    if (now - Number(operation.startedAt || 0) >= paneCreationBusyAnimationDelayMs) return true;
  }
  const wallNow = Date.now();
  for (const panel of state.pendingPanels.values()) {
    if (requestedType && panel.type !== requestedType) continue;
    if (wallNow - Number(panel.pendingStartedAt || wallNow) >= paneCreationBusyAnimationDelayMs) return true;
  }
  return false;
}

function paneCreationElapsedSeconds() {
  let oldestStartedAtMs = 0;
  for (const panel of state.pendingPanels.values()) {
    const startedAt = Number(panel.pendingStartedAt || 0);
    if (startedAt && (!oldestStartedAtMs || startedAt < oldestStartedAtMs)) oldestStartedAtMs = startedAt;
  }
  const nowMs = Date.now();
  for (const operation of state.uiOperations.values()) {
    if (operation.kind !== "create-panel") continue;
    const startedAt = Number(operation.startedAt || 0);
    if (!startedAt) continue;
    const wallStartedAt = nowMs - Math.max(0, performance.now() - startedAt);
    if (!oldestStartedAtMs || wallStartedAt < oldestStartedAtMs) oldestStartedAtMs = wallStartedAt;
  }
  return oldestStartedAtMs ? Math.max(0, Math.floor((nowMs - oldestStartedAtMs) / 1000)) : 0;
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
  toggleClassIfChanged(elements.shell, "operation-pending", Boolean(label));
  toggleClassIfChanged(elements.statusSummary, "is-busy", Boolean(label));
  setTextIfChanged(elements.statusSummary, label || defaultStatusSummary());
  for (const button of elements.paneCreationButtons) updatePaneCreationButtonState(button);
  for (const button of Object.values(state.newSurfaceAddButtons)) {
    if (button) {
      const config = surfaceAddTabConfigs[button.dataset.addKind];
      if (config) {
        updateSurfaceAddButtonState(button, config);
      } else {
        setDisabledIfChanged(button, paneCreationButtonsDisabled());
        const title = paneCreationActionTitle(paneCreationButtonBaseTitle(button));
        setTitleIfChanged(button, title);
        setAttributeIfChanged(button, "aria-label", title);
      }
    }
  }
  updateVisibleEmptyWorkspaceControls();
}

function updateOperationChromeTimer() {
  if (state.uiOperations.size === 0) {
    stopOperationChromeTimerIfIdle();
    return;
  }
  updateOperationChrome();
}

function ensureOperationChromeTimer() {
  if (state.operationChromeTimer || state.uiOperations.size === 0) return;
  state.operationChromeTimer = window.setInterval(updateOperationChromeTimer, operationChromeRefreshMs);
}

function stopOperationChromeTimerIfIdle() {
  if (!state.operationChromeTimer || state.uiOperations.size > 0) return;
  window.clearInterval(state.operationChromeTimer);
  state.operationChromeTimer = 0;
}

async function withUiOperation(key, kind, label, task, metadata = {}) {
  if (state.uiOperations.has(key)) return null;
  state.uiOperations.set(key, { ...metadata, kind, label, startedAt: performance.now() });
  updateOperationChrome();
  ensureOperationChromeTimer();
  try {
    return await task();
  } finally {
    state.uiOperations.delete(key);
    updateOperationChrome();
    stopOperationChromeTimerIfIdle();
  }
}

function renderWorkspaces() {
  const activeId = state.data.activeWorkspaceId;
  const contentSignature = workspaceListContentSignature();
  if (
    contentSignature === state.workspaceListContentSignature
    && state.workspaceRows.size === state.data.workspaces.length
    && elements.workspaceList.childNodes.length === state.data.workspaces.length
  ) {
    if (activeId !== state.workspaceListActiveId) {
      updateWorkspaceRowById(state.workspaceListActiveId, activeId);
      updateWorkspaceRowById(activeId, activeId);
      state.workspaceListActiveId = activeId;
      state.workspaceListSignature = workspaceListSignature(contentSignature, activeId);
    }
    return;
  }
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
  state.workspaceListSignature = workspaceListSignature(contentSignature, activeId);
  state.workspaceListContentSignature = contentSignature;
  state.workspaceListActiveId = activeId;
}

function workspaceListSignature(contentSignature = workspaceListContentSignature(), activeId = state.data?.activeWorkspaceId || "") {
  const parts = [];
  appendSignatureValue(parts, activeId);
  appendSignatureValue(parts, contentSignature);
  return parts.join("");
}

function workspaceListContentSignature() {
  const paletteColor = state.data?.palette?.[0] || "";
  const parts = [];
  appendSignatureValue(parts, paletteColor);
  appendSignatureValue(parts, state.settings.sidebarDetailMode);
  appendSignatureValue(parts, state.settings.sidebarBranchMode);
  appendSignatureArray(parts, state.data?.workspaces || [], (nextParts, workspace, index) => {
    const attentionTotal = workspace.panels.filter((panel) => panel.needsAttention).length;
    appendSignatureValue(nextParts, workspace.id);
    appendSignatureValue(nextParts, workspace.title || `Workspace ${index + 1}`);
    appendSignatureValue(nextParts, workspace.cwd || "");
    appendSignatureValue(nextParts, workspace.cwdShort || "~");
    appendSignatureValue(nextParts, workspace.branch || "");
    appendSignatureValue(nextParts, workspace.color || paletteColor);
    appendSignatureValue(nextParts, workspace.terminalCount || 0);
    appendSignatureValue(nextParts, workspace.browserCount || 0);
    appendSignatureValue(nextParts, attentionTotal);
  });
  return parts.join("");
}

function updateWorkspaceRowById(workspaceId, activeId) {
  if (!workspaceId) return;
  const index = state.data?.workspaces.findIndex((workspace) => workspace.id === workspaceId) ?? -1;
  if (index < 0) return;
  const row = state.workspaceRows.get(workspaceId);
  if (!row) return;
  updateWorkspaceRow(row, state.data.workspaces[index], index, activeId);
}

function createWorkspaceRow() {
  const button = document.createElement("button");
  button.className = "workspace-row";
  button.draggable = true;
  button.innerHTML = `
    <span class="workspace-attention"></span>
    <span class="workspace-grip" aria-hidden="true"></span>
    <span class="workspace-card">
      <span class="workspace-name-line">
        <span class="workspace-color"></span>
        <span class="workspace-name"></span>
        <span class="workspace-badge"></span>
      </span>
      <span class="workspace-detail-line">
        <span class="workspace-meta">
          <span class="workspace-path"></span>
          <span class="workspace-branch"></span>
        </span>
        <span class="workspace-counts"></span>
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
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    clearWorkspaceListDropTarget();
    if (state.dragPanelId) {
      setWorkspaceRowDropTarget(button, "panel");
      return;
    }
    if (state.dragWorkspaceId === button.dataset.workspaceId) {
      clearWorkspaceRowDropTarget(button);
      return;
    }
    const placement = workspaceDropPlacement(event, button);
    setWorkspaceRowDropTarget(button, placement);
  });
  button.addEventListener("dragleave", () => {
    clearWorkspaceRowDropTarget(button);
  });
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const targetWorkspaceId = button.dataset.workspaceId;
    const workspacePlacement = workspaceDropPlacement(event, button);
    clearWorkspaceRowDropTarget(button);
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

function clearWorkspaceRowDropTarget(row = null) {
  const target = row || state.workspaceRows.get(state.workspaceDropTargetId);
  target?.classList?.remove("is-drop-target", "is-workspace-drop-before", "is-workspace-drop-after");
  if (!row || row.dataset.workspaceId === state.workspaceDropTargetId) {
    state.workspaceDropTargetId = "";
    state.workspaceDropTargetMode = "";
  }
}

function setWorkspaceRowDropTarget(row, mode) {
  const workspaceId = row?.dataset?.workspaceId || "";
  if (!workspaceId || !mode) {
    clearWorkspaceRowDropTarget();
    return;
  }
  if (state.workspaceDropTargetId === workspaceId && state.workspaceDropTargetMode === mode) return;
  clearWorkspaceRowDropTarget();
  row.classList.toggle("is-drop-target", mode === "panel");
  row.classList.toggle("is-workspace-drop-before", mode === "before");
  row.classList.toggle("is-workspace-drop-after", mode === "after");
  state.workspaceDropTargetId = workspaceId;
  state.workspaceDropTargetMode = mode;
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
  clearWorkspaceRowDropTarget();
  elements.workspaceList.classList.add("is-workspace-drop-end");
}

function handleWorkspaceListDragLeave(event) {
  if (event.currentTarget.contains(event.relatedTarget)) return;
  clearWorkspaceListDropTarget();
  clearWorkspaceRowDropTarget();
}

function handleWorkspaceListDrop(event) {
  if (isWorkspaceRowEvent(event) || !workspaceListCanDropToEnd()) return;
  event.preventDefault();
  const workspaceId = state.dragWorkspaceId;
  clearWorkspaceListDropTarget();
  clearWorkspaceRowDropTarget();
  updateWorkspaceOrder(workspaceId, { moveToEnd: true });
}

function workspaceRowParts(button) {
  button._workspaceParts ||= {
    name: button.querySelector(".workspace-name"),
    badge: button.querySelector(".workspace-badge"),
    path: button.querySelector(".workspace-path"),
    branch: button.querySelector(".workspace-branch"),
    counts: button.querySelector(".workspace-counts")
  };
  return button._workspaceParts;
}

function workspaceDropPlacement(event, row) {
  const rect = row.getBoundingClientRect();
  const y = rect.height ? (event.clientY - rect.top) / rect.height : 0.5;
  return y < 0.5 ? "before" : "after";
}

function updateWorkspaceRow(button, workspace, index, activeId) {
  const hasAttention = workspace.panels.some((panel) => panel.needsAttention);
  const attentionTotal = workspace.panels.filter((panel) => panel.needsAttention).length;
  const title = workspaceDisplayTitle(workspace, `Workspace ${index + 1}`);
  const isHome = isAppHomeWorkspace(workspace);
  const cwd = isHome ? "home" : workspace.cwdShort || "~";
  const fullCwd = isHome ? "cmux home" : workspace.cwd || cwd;
  const branch = String(workspace.branch || "").trim();
  const branchVisible = sidebarBranchVisible(workspace, activeId);
  const paneSummary = `${workspace.terminalCount || 0} terminal${workspace.terminalCount === 1 ? "" : "s"} / ${workspace.browserCount || 0} browser${workspace.browserCount === 1 ? "" : "s"}`;
  const compactPaneSummary = `${workspace.terminalCount || 0}T ${workspace.browserCount || 0}B`;
  const parts = workspaceRowParts(button);
  setDatasetIfChanged(button, "workspaceId", workspace.id);
  setClassNameIfChanged(button, `workspace-row${workspace.id === activeId ? " is-active" : ""}${hasAttention ? " has-attention" : ""}${branchVisible ? " has-branch" : ""}${state.dragWorkspaceId === workspace.id ? " is-workspace-dragging" : ""}`);
  setStylePropertyIfChanged(button, "--workspace-color", workspace.color || state.data.palette?.[0] || "");
  const rowHelp = `${title} - ${fullCwd}${branchVisible ? ` - ${branch}` : ""} - ${paneSummary} - drag to reorder, double-click to rename, right-click for workspace options`;
  setTitleIfChanged(button, rowHelp);
  if (button.getAttribute("aria-label") !== rowHelp) button.setAttribute("aria-label", rowHelp);
  setTextIfChanged(parts.name, title);
  setTextIfChanged(parts.badge, hasAttention ? String(attentionTotal) : "");
  setTextIfChanged(parts.path, cwd);
  setTitleIfChanged(parts.path, fullCwd);
  setTextIfChanged(parts.branch, branch);
  setTitleIfChanged(parts.branch, branch ? `Git branch: ${branch}` : "");
  setTextIfChanged(parts.counts, compactPaneSummary);
  setTitleIfChanged(parts.counts, paneSummary);
}

function sidebarBranchVisible(workspace, activeId = state.data?.activeWorkspaceId || "") {
  if (!String(workspace?.branch || "").trim()) return false;
  if (state.settings.sidebarDetailMode !== "detailed") return false;
  if (state.settings.sidebarBranchMode === "all") return true;
  return state.settings.sidebarBranchMode === "active" && workspace?.id === activeId;
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
  const tabLabels = surfaceTabLabels(workspace);
  const signature = surfaceTabsSignature(workspace, tabLabels);
  const layoutSignature = surfaceTabsLayoutSignature(workspace, tabLabels);
  const layoutChanged = layoutSignature !== state.surfaceTabsLayoutSignature;
  const structureReady = surfaceTabStructureReady(workspace);
  if (
    signature === state.surfaceTabsSignature
    && structureReady
  ) {
    return;
  }
  if (!layoutChanged && structureReady) {
    updateSurfaceTabStatesOnly(workspace, tabLabels);
    setDatasetIfChanged(elements.surfaceTabs, "tabCount", String(workspace.panels.length));
    state.surfaceTabsSignature = signature;
    state.surfaceTabsLayoutSignature = layoutSignature;
    scheduleActiveSurfaceTabIntoView(workspace.activePanelId);
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
    updateSurfaceTab(button, workspace, panel, tabLabels.get(panel.id));
    return button;
  });
  nodes.push(...getNewSurfaceTabs(workspace));
  replaceChildrenIfChanged(elements.surfaceTabs, nodes);
  setDatasetIfChanged(elements.surfaceTabs, "tabCount", String(workspace.panels.length));
  state.surfaceTabsSignature = signature;
  state.surfaceTabsLayoutSignature = layoutSignature;
  if (layoutChanged) scheduleSurfaceTabsOverflowRefresh({ ensureActive: true });
  else scheduleActiveSurfaceTabIntoView(workspace.activePanelId);
}

function surfaceTabStructureReady(workspace) {
  return Boolean(
    workspace?.id
    && state.newSurfaceAddButtons.terminal
    && state.newSurfaceAddButtons.browser
    && state.newSurfaceAddButtons.terminal.dataset.workspaceId === workspace.id
    && state.newSurfaceAddButtons.browser.dataset.workspaceId === workspace.id
    && state.surfaceTabButtons.size === workspace.panels.length
    && elements.surfaceTabs.childNodes.length === workspace.panels.length + 2
  );
}

function clearSurfaceTabs() {
  for (const tab of state.surfaceTabButtons.values()) tab.remove();
  state.surfaceTabButtons.clear();
  state.surfaceTabsSignature = "";
  state.surfaceTabsLayoutSignature = "";
  state.surfaceTabEnsureActive = false;
  setDatasetIfChanged(elements.surfaceTabs, "tabCount", "0");
  replaceChildrenIfChanged(elements.surfaceTabs, []);
  resetSurfaceTabsOverflow();
}

function surfaceTabsSignature(workspace, tabLabels = surfaceTabLabels(workspace)) {
  const zoomedPanelId = zoomedPanelIdForWorkspace(workspace) || "";
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.activePanelId || "");
  appendSignatureValue(parts, workspace.color || "");
  appendSignatureValue(parts, state.settings.titleDetailMode);
  appendSignatureValue(parts, paneCreationButtonsDisabled());
  appendSignatureArray(parts, workspace.panels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, tabLabels.get(panel.id) || surfaceTabLabel(workspace, panel));
    appendSignatureValue(nextParts, panelDisplayTitle(panel, false));
    appendSignatureValue(nextParts, panel.color || workspace.color || "var(--color-accent)");
    appendSignatureValue(nextParts, panel.id === workspace.activePanelId);
    appendSignatureValue(nextParts, panel.id === zoomedPanelId);
    appendSignatureValue(nextParts, isPanelMinimized(panel));
    appendSignatureValue(nextParts, isPendingPanel(panel));
    appendSignatureValue(nextParts, Boolean(panel.needsAttention));
  });
  return parts.join("");
}

function surfaceTabsLayoutSignature(workspace, tabLabels = surfaceTabLabels(workspace)) {
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, state.settings.titleDetailMode);
  appendSignatureValue(parts, state.settings.addTabStyle);
  appendSignatureValue(parts, paneCreationButtonsDisabled());
  appendSignatureArray(parts, workspace.panels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, tabLabels.get(panel.id) || surfaceTabLabel(workspace, panel));
    appendSignatureValue(nextParts, panelDisplayTitle(panel, false));
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
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
  if (!surfaceTabsCanOverflow()) {
    state.surfaceTabEnsureActive = false;
    resetSurfaceTabsOverflow();
    return;
  }
  if (state.surfaceTabOverflowFrame) return;
  state.surfaceTabOverflowFrame = requestAnimationFrame(() => {
    state.surfaceTabOverflowFrame = 0;
    const ensureActive = state.surfaceTabEnsureActive;
    state.surfaceTabEnsureActive = false;
    updateSurfaceTabsOverflow();
    if (ensureActive) scheduleActiveSurfaceTabIntoView(activeWorkspace()?.activePanelId);
  });
}

function surfaceTabsCanOverflow(strip = elements.surfaceTabs) {
  return Boolean(
    strip
    && state.settings.showTabs
    && !state.settings.focusMode
    && strip.childElementCount > 0
  );
}

function resetSurfaceTabsOverflow(strip = elements.surfaceTabs) {
  state.surfaceTabOverflowSignature = "";
  if (!strip) return;
  toggleClassIfChanged(strip, "has-overflow", false);
  toggleClassIfChanged(strip, "is-crowded", false);
  toggleClassIfChanged(strip, "can-scroll-left", false);
  toggleClassIfChanged(strip, "can-scroll-right", false);
  if (strip.scrollLeft) strip.scrollLeft = 0;
}

function surfaceTabsOverflowing(strip = elements.surfaceTabs) {
  if (!strip) return false;
  return strip.scrollWidth > strip.clientWidth + 1;
}

function tabOverflowStateSignature(strip, tabCount) {
  if (!strip) return "";
  return [
    tabCount,
    strip.clientWidth,
    strip.scrollWidth,
    Math.round(strip.scrollLeft || 0),
    strip.classList.contains("is-crowded") ? 1 : 0,
    strip.classList.contains("has-overflow") ? 1 : 0,
    strip.classList.contains("can-scroll-left") ? 1 : 0,
    strip.classList.contains("can-scroll-right") ? 1 : 0
  ].join("|");
}

function updateSurfaceTabScrollState(strip, overflowing = surfaceTabsOverflowing()) {
  if (!strip) return;
  const maxScrollLeft = Math.max(0, strip.scrollWidth - strip.clientWidth);
  const scrollLeft = Math.max(0, strip.scrollLeft);
  toggleClassIfChanged(strip, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(strip, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
}

function scheduleSurfaceTabScrollStateRefresh() {
  if (!elements.surfaceTabs || state.surfaceTabScrollStateFrame) return;
  state.surfaceTabScrollStateFrame = requestAnimationFrame(() => {
    state.surfaceTabScrollStateFrame = 0;
    updateSurfaceTabScrollState(elements.surfaceTabs, elements.surfaceTabs.classList.contains("has-overflow"));
  });
}

function updateSurfaceTabsOverflow() {
  const strip = elements.surfaceTabs;
  if (!surfaceTabsCanOverflow(strip)) {
    resetSurfaceTabsOverflow(strip);
    return;
  }
  const tabCount = Math.max(0, Number(strip.dataset.tabCount) || 0);
  if (tabCount === 0 || strip.clientWidth <= 0) {
    resetSurfaceTabsOverflow(strip);
    return;
  }
  const currentSignature = tabOverflowStateSignature(strip, tabCount);
  if (currentSignature === state.surfaceTabOverflowSignature) return;
  const normalOverflow = surfaceTabsOverflowing();
  toggleClassIfChanged(strip, "is-crowded", normalOverflow);
  const finalOverflow = surfaceTabsOverflowing();
  toggleClassIfChanged(strip, "has-overflow", finalOverflow);
  updateSurfaceTabScrollState(strip, finalOverflow);
  if (!finalOverflow && strip.scrollLeft) strip.scrollLeft = 0;
  state.surfaceTabOverflowSignature = tabOverflowStateSignature(strip, tabCount);
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

function updateCommandStripScrollState(strip, overflowing = strip?.classList.contains("has-overflow")) {
  if (!strip) return;
  const maxScrollLeft = Math.max(0, strip.scrollWidth - strip.clientWidth);
  const scrollLeft = Math.max(0, strip.scrollLeft);
  toggleClassIfChanged(strip, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(strip, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
}

function scheduleCommandStripScrollStateRefresh() {
  if (!elements.commandStrip || state.commandStripScrollFrame) return;
  state.commandStripScrollFrame = requestAnimationFrame(() => {
    state.commandStripScrollFrame = 0;
    updateCommandStripScrollState(elements.commandStrip);
  });
}

function updateCommandStripOverflow() {
  if (!elements.commandStrip) return;
  const strip = elements.commandStrip;
  const overflowing = commandStripContentWidth() > elements.commandStrip.clientWidth + 1
    || elements.commandStrip.scrollWidth > elements.commandStrip.clientWidth + 1;
  toggleClassIfChanged(strip, "has-overflow", overflowing);
  updateCommandStripScrollState(strip, overflowing);
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
  elements.commandStrip.addEventListener("scroll", scheduleCommandStripScrollStateRefresh, { passive: true });
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
  elements.surfaceTabs.addEventListener("scroll", scheduleSurfaceTabScrollStateRefresh, { passive: true });
  requestAnimationFrame(() => {
    updateSurfaceTabsOverflow();
  });
}

function activateSurfaceTabPanel(panelId) {
  if (!panelId) return false;
  if (state.minimizedPanelIds.has(panelId)) restorePane(panelId);
  else focusPanel(panelId);
  scheduleActiveSurfaceTabIntoView(panelId);
  return true;
}

function focusSurfaceTabButton(panelId) {
  if (!panelId) return;
  requestAnimationFrame(() => {
    const button = state.surfaceTabButtons.get(panelId);
    button?.focus?.({ preventScroll: true });
  });
}

function surfaceTabKeyboardTargetId(workspace, currentPanelId, key) {
  const panels = workspace?.panels || [];
  if (panels.length === 0) return "";
  const currentIndex = Math.max(0, panels.findIndex((panel) => panel.id === currentPanelId));
  if (key === "Home") return panels[0]?.id || "";
  if (key === "End") return panels.at(-1)?.id || "";
  if (key === "ArrowLeft") return panels[Math.max(0, currentIndex - 1)]?.id || "";
  if (key === "ArrowRight") return panels[Math.min(panels.length - 1, currentIndex + 1)]?.id || "";
  return "";
}

function handleSurfaceTabKeydown(event, panelId) {
  if (!panelId) return;
  if (event.key === "Delete") {
    event.preventDefault();
    event.stopPropagation();
    closePanel(panelId);
    return;
  }
  if (event.altKey || event.ctrlKey || event.metaKey) return;
  const nextPanelId = surfaceTabKeyboardTargetId(activeWorkspace(), panelId, event.key);
  if (!nextPanelId) return;
  event.preventDefault();
  event.stopPropagation();
  activateSurfaceTabPanel(nextPanelId);
  focusSurfaceTabButton(nextPanelId);
}

function createSurfaceTab() {
  const button = document.createElement("button");
  button.className = "surface-tab";
  button.draggable = true;
  button.innerHTML = `
    <span class="surface-dot"><span class="surface-kind" aria-hidden="true"></span></span>
    <span class="surface-label"></span>
    <span class="surface-close" title="Close"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m7 7 10 10M17 7 7 17"></path></svg></span>
  `;
  button._surfaceParts = surfaceTabParts(button);
  button.addEventListener("click", () => {
    activateSurfaceTabPanel(button.dataset.panelId);
  });
  button.addEventListener("keydown", (event) => handleSurfaceTabKeydown(event, button.dataset.panelId));
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
    setSurfaceTabDropTarget(button, surfaceTabDropPlacement(event, button));
  });
  button.addEventListener("dragleave", () => clearSurfaceTabDropTarget(button));
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const placement = surfaceTabDropPlacement(event, button);
    clearSurfaceTabDropTarget(button);
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
    kind: button.querySelector(".surface-kind"),
    label: button.querySelector(".surface-label"),
    close: button.querySelector(".surface-close")
  };
  return button._surfaceParts;
}

function updateSurfaceTabState(button, workspace, panel, label = surfaceTabLabel(workspace, panel)) {
  const fullTitle = panelDisplayTitle(panel, false);
  const minimized = isPanelMinimized(panel);
  const pending = isPendingPanel(panel);
  const ordinal = Math.max(1, (workspace?.panels || []).findIndex((candidate) => candidate.id === panel.id) + 1);
  const parts = surfaceTabParts(button);
  const active = panel.id === workspace.activePanelId;
  const tabbable = active || (!workspace.activePanelId && ordinal === 1);
  setDatasetIfChanged(button, "panelId", panel.id);
  setClassNameIfChanged(button, `surface-tab${active ? " is-active" : ""}${isPanelZoomed(panel, workspace) ? " is-zoomed" : ""}${minimized ? " is-minimized" : ""}${pending ? " is-pending" : ""}${panel.needsAttention ? " has-attention" : ""}`);
  const closeActionLabel = pending ? "cancel" : closePaneActionLabel(workspace, panel.id).toLowerCase();
  setTitleIfChanged(button, `${label}${label !== fullTitle ? ` - ${fullTitle}` : ""}${pending ? " - starting" : ""}${minimized ? " - minimized, click to restore" : ""} - middle-click to ${closeActionLabel}, double-click to rename, right-click for pane options`);
  if (active) setAttributeIfChanged(button, "aria-current", "page");
  else if (button.hasAttribute("aria-current")) button.removeAttribute("aria-current");
  setAttributeIfChanged(button, "aria-label", `${label}${active ? ", active" : ""}${pending ? ", starting" : ""}${minimized ? ", minimized" : ""}. Press Delete to ${closeActionLabel}.`);
  if (button.tabIndex !== (tabbable ? 0 : -1)) button.tabIndex = tabbable ? 0 : -1;
  setStylePropertyIfChanged(button, "--tab-color", panel.color || workspace.color || "var(--color-accent)");
  setDatasetIfChanged(button, "paneKind", panel.type === "browser" ? "browser" : "terminal");
  setDatasetIfChanged(parts.dot, "tabIndex", String(ordinal));
  setTitleIfChanged(parts.close, pending ? "Cancel pane" : closePaneActionLabel(workspace, panel.id));
  return parts;
}

function updateSurfaceTabStatesOnly(workspace, tabLabels = surfaceTabLabels(workspace)) {
  for (const panel of workspace?.panels || []) {
    const button = state.surfaceTabButtons.get(panel.id);
    if (!button) continue;
    updateSurfaceTabState(button, workspace, panel, tabLabels.get(panel.id));
  }
}

function updateSurfaceTab(button, workspace, panel, label = surfaceTabLabel(workspace, panel)) {
  const parts = updateSurfaceTabState(button, workspace, panel, label);
  const iconName = panel.type === "browser" ? "browser" : "terminal";
  if (parts.kind && parts.kind.dataset.icon !== iconName) {
    parts.kind.dataset.icon = iconName;
    parts.kind.innerHTML = controlIconMarkup(iconName);
  }
  setTextIfChanged(parts.label, label);
}

function surfaceTabDropPlacement(event, button) {
  const rect = button.getBoundingClientRect();
  return event.clientX > rect.left + rect.width / 2 ? "after" : "before";
}

function clearSurfaceTabDropTargets() {
  const target = state.surfaceTabButtons.get(state.surfaceTabDropTargetId);
  target?.classList?.remove("is-drop-before", "is-drop-after");
  state.surfaceTabDropTargetId = "";
  state.surfaceTabDropTargetMode = "";
}

function clearSurfaceTabDropTarget(button = null) {
  if (!button) {
    clearSurfaceTabDropTargets();
    return;
  }
  button.classList.remove("is-drop-before", "is-drop-after");
  if (button.dataset.panelId === state.surfaceTabDropTargetId) {
    state.surfaceTabDropTargetId = "";
    state.surfaceTabDropTargetMode = "";
  }
}

function setSurfaceTabDropTarget(button, mode) {
  const panelId = button?.dataset?.panelId || "";
  if (!panelId || !mode) {
    clearSurfaceTabDropTargets();
    return;
  }
  if (state.surfaceTabDropTargetId === panelId && state.surfaceTabDropTargetMode === mode) return;
  clearSurfaceTabDropTargets();
  button.classList.toggle("is-drop-before", mode === "before");
  button.classList.toggle("is-drop-after", mode === "after");
  state.surfaceTabDropTargetId = panelId;
  state.surfaceTabDropTargetMode = mode;
}

const surfaceAddTabConfigs = {
  terminal: {
    className: "surface-new-terminal",
    kindIcon: "terminal",
    title: "New terminal pane",
    label: "Terminal"
  },
  browser: {
    className: "surface-new-browser",
    kindIcon: "browser",
    title: "New browser pane",
    label: "Browser"
  }
};

function getNewSurfaceTabs(workspace) {
  return [
    getNewSurfaceTab("terminal", workspace),
    getNewSurfaceTab("browser", workspace)
  ];
}

function getNewSurfaceTab(kind, workspace) {
  const config = surfaceAddTabConfigs[kind];
  let button = state.newSurfaceAddButtons[kind];
  if (!button) {
    button = document.createElement("button");
    button.className = `surface-tab surface-new-tab ${config.className}`;
    button.type = "button";
    button.innerHTML = `
      <span class="surface-new-icon" aria-hidden="true">
        <span class="surface-new-kind">${controlIconMarkup(config.kindIcon)}</span>
        <span class="surface-new-add">${controlIconMarkup("plus")}</span>
      </span>
      <span class="surface-new-label"></span>
    `;
    button.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      createSurfaceAddPane(kind, surfaceAddButtonWorkspace(button));
    };
    button.addEventListener("contextmenu", (event) => showNewSurfaceTabMenu(event, surfaceAddButtonWorkspace(button), kind));
    button.addEventListener("dragover", (event) => {
      if (!state.dragPanelId) return;
      event.preventDefault();
      clearSurfaceTabDropTargets();
      button.classList.add("is-drop-before");
    });
    button.addEventListener("dragleave", () => button.classList.remove("is-drop-before"));
    button.addEventListener("drop", (event) => {
      event.preventDefault();
      button.classList.remove("is-drop-before");
      if (state.dragPanelId) movePanelToWorkspace(state.dragPanelId, button.dataset.workspaceId);
    });
    state.newSurfaceAddButtons[kind] = button;
  }
  setDatasetIfChanged(button, "workspaceId", workspace.id);
  setDatasetIfChanged(button, "addKind", kind);
  updateSurfaceAddButtonState(button, config);
  return button;
}

function updateSurfaceAddButtonState(button, config) {
  if (!button || !config) return;
  const parts = surfaceAddTabParts(button);
  const disabled = paneCreationButtonsDisabled();
  const addKind = button.dataset.addKind || "";
  const creating = paneCreationOperationCount(addKind) > 0;
  const waiting = creating && paneCreationOperationWaiting(addKind);
  setTextIfChanged(parts.label, creating && !disabled ? paneCreationBusyLabel(addKind) : config.label);
  setDisabledIfChanged(button, disabled);
  toggleClassIfChanged(button, "is-creating", creating && !disabled);
  toggleClassIfChanged(button, "is-waiting", waiting && !disabled);
  const title = paneCreationActionTitle(config.title, "Right-click to choose right or below.");
  setTitleIfChanged(button, title);
  setAttributeIfChanged(button, "aria-label", title);
}

function surfaceAddTabParts(button) {
  button._surfaceAddParts ||= {
    label: button.querySelector(".surface-new-label")
  };
  return button._surfaceAddParts;
}

function surfaceAddButtonWorkspace(button) {
  const workspaceId = button?.dataset.workspaceId || activeWorkspace()?.id || "";
  return state.data?.workspaces.find((candidate) => candidate.id === workspaceId) || activeWorkspace();
}

function createTerminalPanel(direction = "right", options = {}) {
  return createPanel("terminal", direction, { immediateTerminalInit: true, ...options });
}

function createSurfaceAddPane(kind, workspace, direction = "right") {
  if (!workspace || paneCreationButtonsDisabled()) return;
  if (kind === "browser") {
    openBrowserHome(workspace.id, { mode: "pane", direction });
    return;
  }
  createTerminalPanel(direction, { workspaceId: workspace.id });
}

function surfaceAddContextActions(kind, workspace) {
  const disabled = paneCreationButtonsDisabled();
  const label = kind === "browser" ? "Browser" : "Terminal";
  const create = (direction) => createSurfaceAddPane(kind, workspace, direction);
  return contextMenuActionGroup(
    contextMenuButton(`${label} right`, () => create("right"), disabled),
    contextMenuButton(`${label} below`, () => create("down"), disabled)
  );
}

function showNewSurfaceTabMenu(event, workspace = activeWorkspace(), preferredKind = "terminal") {
  event.preventDefault();
  event.stopPropagation();
  if (!workspace) return;
  const primaryKind = preferredKind === "browser" ? "browser" : "terminal";
  const secondaryKind = primaryKind === "browser" ? "terminal" : "browser";
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = "Add pane";
  const utilityActions = contextMenuActionGroup(
    contextMenuButton("Reopen closed pane", reopenClosedPanel, state.closedPanels.length === 0 || paneCreationButtonsDisabled())
  );
  menu.replaceChildren(
    title,
    contextMenuSectionTitle(primaryKind === "browser" ? "Browser" : "Terminal"),
    surfaceAddContextActions(primaryKind, workspace),
    contextMenuSectionTitle(secondaryKind === "browser" ? "Browser" : "Terminal"),
    surfaceAddContextActions(secondaryKind, workspace),
    contextMenuSectionTitle("Recent"),
    utilityActions
  );
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
    state.paneStructureSignature = "";
    state.paneFitSignature = "";
    state.visiblePanePanelIds = new Set();
    renderEmptyWorkspace(null);
    updateBrowserPaneActivity(state.visiblePanePanelIds);
    return;
  }
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  const visiblePanels = zoomedPanel ? [zoomedPanel] : panels;
  const tree = zoomedPanel ? paneTreeLeaf(zoomedPanel.id) : paneTreeForWorkspace(workspace, visiblePanels);
  const signature = paneRenderSignature(workspace, visiblePanels, tree);
  const structureSignature = paneStructureSignature(workspace, visiblePanels, tree);
  const fitSignature = paneFitSignature(workspace, visiblePanels, tree);
  const shouldFitVisibleTerminals = fitSignature !== state.paneFitSignature;
  const liveVisiblePanelIds = new Set(visiblePanels.filter((panel) => !isPanelMinimized(panel)).map((panel) => panel.id));
  state.visiblePanePanelIds = liveVisiblePanelIds;
  const gridHasVisiblePanes = paneGridContainsPanels(visiblePanels);
  if (signature === state.paneRenderSignature && gridHasVisiblePanes) {
    updateBrowserPaneActivity(liveVisiblePanelIds);
    resumeTerminalOutputAfterActivityChange(liveVisiblePanelIds);
    if (shouldFitVisibleTerminals) {
      state.paneFitSignature = fitSignature;
      scheduleVisibleTerminalFits(visiblePanels);
    }
    return;
  }
  if (
    structureSignature === state.paneStructureSignature
    && gridHasVisiblePanes
    && canUpdatePaneActiveStateInPlace(workspace, visiblePanels)
  ) {
    updateVisiblePaneActiveState(workspace, visiblePanels);
    updateBrowserPaneActivity(liveVisiblePanelIds);
    resumeTerminalOutputAfterActivityChange(liveVisiblePanelIds);
    if (shouldFitVisibleTerminals) {
      state.paneFitSignature = fitSignature;
      scheduleVisibleTerminalFits(visiblePanels);
    }
    state.paneRenderSignature = signature;
    state.paneStructureSignature = structureSignature;
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
    state.paneStructureSignature = "";
    state.paneFitSignature = "";
    state.visiblePanePanelIds = new Set();
    renderEmptyWorkspace(workspace);
    updateBrowserPaneActivity(state.visiblePanePanelIds);
    return;
  }

  const panelById = new Map(visiblePanels.map((panel) => [panel.id, panel]));
  const node = renderPaneTreeNode(tree, workspace, panelById, visiblePanels.length);
  replaceChildrenIfChanged(elements.paneGrid, node ? [node] : []);
  state.paneRenderSignature = signature;
  state.paneStructureSignature = structureSignature;
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
    if (!panel?.id || panel.type !== "terminal" || isPanelMinimized(panel)) continue;
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

function canUpdatePaneActiveStateInPlace(workspace, visiblePanels) {
  for (const panel of visiblePanels) {
    if (isPendingPanel(panel)) return false;
    if (panel.type === "terminal") {
      if (
        state.immediateTerminalInitPanelIds.has(panel.id)
        || state.paintDeferredTerminalInitPanelIds.has(panel.id)
      ) {
        return false;
      }
      if (!state.terminals.has(panel.id) && panel.id === workspace.activePanelId) return false;
    }
    if (
      panel.type === "browser"
      && !state.browserViews.has(panel.id)
      && !shouldRenderDeferredBrowserShell(panel)
    ) {
      return false;
    }
  }
  return true;
}

function updateVisiblePaneActiveState(workspace, visiblePanels) {
  const visibleCount = visiblePanels.length;
  for (const panel of visiblePanels) {
    const pane = state.paneCache.get(panel.id);
    if (!pane?.isConnected) continue;
    updatePaneActiveState(pane, panel, workspace, visibleCount);
  }
}

function updatePaneActiveState(pane, panel, workspace, visibleCount = workspace?.panels?.length || 0) {
  const parts = paneParts(pane);
  updatePaneChromeState(pane, panel, workspace);
  const zoomed = isPanelZoomed(panel, workspace);
  const minimized = isPanelMinimized(panel);
  const pending = isPendingPanel(panel);
  toggleClassIfChanged(pane, "is-active", panel.id === workspace.activePanelId);
  toggleClassIfChanged(pane, "is-zoomed", zoomed);
  toggleClassIfChanged(pane, "has-attention", Boolean(panel.needsAttention));
  toggleClassIfChanged(pane, "is-minimized", minimized);
  toggleClassIfChanged(pane, "is-pending", pending);
  if (visibleCount <= 1) clearPaneFlex(pane);
  updatePaneToolState(parts.zoom, zoomed ? "showAll" : "focus", zoomed ? "Show all panes" : "Focus pane");
  updatePaneToolState(parts.minimize, minimized ? "restore" : "minimize", minimized ? "Restore pane" : "Minimize pane");
  for (const button of parts.tools) {
    const terminalOnly = button === parts.fontDown || button === parts.fontUp || button === parts.restart;
    setDisabledIfChanged(button, (pending && !button.classList.contains("close"))
      || (terminalOnly && panel.type !== "terminal"));
  }
  const closeActionLabel = pending ? "Cancel pane" : closePaneActionLabel(workspace, panel.id);
  setTitleIfChanged(parts.close, closeActionLabel);
  setAttributeIfChanged(parts.close, "aria-label", closeActionLabel);
  if (panel.type === "terminal" && !pending) {
    const deferred = parts.body.querySelector(".terminal-deferred");
    if (deferred) renderDeferredTerminal(panel, parts.body);
  }
}

function paneRenderSignature(workspace, visiblePanels, tree) {
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.activePanelId || "");
  appendSignatureValue(parts, workspace.color || "");
  appendSignatureValue(parts, Boolean(zoomedPanelIdForWorkspace(workspace)));
  appendSignatureValue(parts, state.settings.titleDetailMode);
  appendSignatureValue(parts, state.settings.browserSuspendInactive);
  appendSignatureValue(parts, state.settings.browserHomeUrl);
  appendSignatureValue(parts, state.settings.terminalProfile);
  appendSignatureValue(parts, paneTreeSignature(tree));
  appendSignatureArray(parts, visiblePanels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, panelDisplayTitle(panel, false));
    appendSignatureValue(nextParts, panel.title || "");
    appendSignatureValue(nextParts, panel.titleLocked || false);
    appendSignatureValue(nextParts, panel.color || "");
    appendSignatureValue(nextParts, panel.backgroundImage || "");
    appendSignatureValue(nextParts, panel.cwd || "");
    appendSignatureValue(nextParts, panel.cwdShort || "");
    appendSignatureValue(nextParts, panel.url || "");
    appendSignatureValue(nextParts, panel.shellProfile || "");
    appendSignatureValue(nextParts, panel.shellPath || "");
    appendSignatureValue(nextParts, terminalFontSizeForPanel(panel));
    appendSignatureValue(nextParts, Boolean(panel.needsAttention));
    appendSignatureValue(nextParts, isPanelMinimized(panel));
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
}

function paneStructureSignature(workspace, visiblePanels, tree) {
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.color || "");
  appendSignatureValue(parts, Boolean(zoomedPanelIdForWorkspace(workspace)));
  appendSignatureValue(parts, state.settings.titleDetailMode);
  appendSignatureValue(parts, state.settings.browserSuspendInactive);
  appendSignatureValue(parts, state.settings.browserHomeUrl);
  appendSignatureValue(parts, state.settings.terminalProfile);
  appendSignatureValue(parts, paneTreeSignature(tree));
  appendSignatureArray(parts, visiblePanels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
}

function paneFitSignature(workspace, visiblePanels, tree) {
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, zoomedPanelIdForWorkspace(workspace) || "");
  appendSignatureValue(parts, paneTreeSignature(tree));
  appendSignatureArray(parts, visiblePanels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, isPanelMinimized(panel));
    appendSignatureValue(nextParts, panel.type === "terminal" ? terminalFontSizeForPanel(panel) : 0);
  });
  return parts.join("");
}

function refreshVisiblePaneSignatures(workspaceId = activeWorkspace()?.id) {
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!workspace || workspace.id !== state.data?.activeWorkspaceId) return false;
  const zoomedPanel = zoomedPanelForWorkspace(workspace);
  const visiblePanels = zoomedPanel ? [zoomedPanel] : (workspace.panels || []);
  const tree = zoomedPanel ? paneTreeLeaf(zoomedPanel.id) : paneTreeForWorkspace(workspace, visiblePanels);
  state.paneRenderSignature = paneRenderSignature(workspace, visiblePanels, tree);
  state.paneStructureSignature = paneStructureSignature(workspace, visiblePanels, tree);
  state.paneFitSignature = paneFitSignature(workspace, visiblePanels, tree);
  return true;
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
  setStylePropertyIfChanged(first, "flex", `${Math.round(firstRatio * paneLayoutScale)} 1 0px`);
  setStylePropertyIfChanged(second, "flex", `${Math.round((1 - firstRatio) * paneLayoutScale)} 1 0px`);
  replaceChildrenIfChanged(split, [first, splitter, second]);
  return split;
}

const paneToolIcons = {
  focus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 4H5a1 1 0 0 0-1 1v3M16 4h3a1 1 0 0 1 1 1v3M8 20H5a1 1 0 0 1-1-1v-3M16 20h3a1 1 0 0 0 1-1v-3"></path></svg>`,
  showAll: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9 9H5V5M15 9h4V5M9 15H5v4M15 15h4v4"></path><path d="m5 5 5 5M19 5l-5 5M5 19l5-5M19 19l-5-5"></path></svg>`,
  minimize: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 12h10"></path></svg>`,
  restore: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 7v10M7 12h10"></path></svg>`
};

function setPaneToolIcon(button, icon) {
  if (!button || button.dataset.paneIcon === icon) return;
  button.innerHTML = paneToolIcons[icon] || paneToolIcons.focus;
  button.dataset.paneIcon = icon;
}

function updatePaneToolState(button, icon, label) {
  setPaneToolIcon(button, icon);
  setTitleIfChanged(button, label);
  setAttributeIfChanged(button, "aria-label", label);
}

function updatePaneChromeState(pane, panel, workspace) {
  if (!pane || !panel) return;
  const parts = paneParts(pane);
  setStylePropertyIfChanged(pane, "--panel-color", panel.color || workspace?.color || "var(--color-accent)");
  const paneBackgroundImage = panel.type === "terminal" ? normalizeBackgroundValue(panel.backgroundImage) : "";
  toggleClassIfChanged(pane, "has-pane-background", Boolean(paneBackgroundImage));
  setStylePropertyIfChanged(pane, "--pane-background-image", backgroundCss(paneBackgroundImage));
  setStylePropertyIfChanged(pane, "--pane-background-repeat", backgroundRepeatCss(paneBackgroundImage));
  setStylePropertyIfChanged(pane, "--pane-background-size", backgroundSizeCss(state.settings.backgroundFit));
  setStylePropertyIfChanged(pane, "--pane-background-position", backgroundPositionCss(state.settings.backgroundPosition));
  setStylePropertyIfChanged(pane, "--pane-background-opacity", String(Math.max(0.12, Math.min(0.42, state.settings.backgroundOpacity / 100 || 0.18))));
  toggleClassIfChanged(pane, "is-browser", panel.type === "browser");
  toggleClassIfChanged(pane, "is-terminal", panel.type === "terminal");
  updatePaneTypeBadge(parts.type, panel.type);
  const title = panelDisplayTitle(panel, false);
  setTextIfChanged(parts.title, title);
  setTitleIfChanged(parts.title, title);
  setTitleIfChanged(parts.header, `${title} - drag header to move, double-click to rename`);
  syncTerminalSessionPanelState(panel);
}

function updatePaneTypeBadge(badge, type) {
  if (!badge) return;
  const kind = type === "browser" ? "browser" : "terminal";
  if (badge.dataset.paneTypeKind !== kind) {
    badge.innerHTML = controlIconMarkup(kind);
    badge.dataset.paneTypeKind = kind;
  }
  const label = kind === "browser" ? "Browser pane" : "Terminal pane";
  setTitleIfChanged(badge, label);
  setAttributeIfChanged(badge, "aria-label", label);
}

function renderPaneNode(panel, workspace, visibleCount) {
  let pane = state.paneCache.get(panel.id) || elements.paneGrid.querySelector(`[data-panel-id="${panel.id}"]`);
  if (!pane) pane = createPane(panel);
  const parts = paneParts(pane);
  setDatasetIfChanged(pane, "panelId", panel.id);
  updatePaneChromeState(pane, panel, workspace);
  toggleClassIfChanged(pane, "is-active", panel.id === workspace.activePanelId);
  const zoomed = isPanelZoomed(panel, workspace);
  const minimized = isPanelMinimized(panel);
  toggleClassIfChanged(pane, "is-zoomed", zoomed);
  toggleClassIfChanged(pane, "has-attention", panel.needsAttention);
  toggleClassIfChanged(pane, "is-minimized", minimized);
  const pending = isPendingPanel(panel);
  toggleClassIfChanged(pane, "is-pending", pending);
  if (visibleCount <= 1) clearPaneFlex(pane);
  updatePaneToolState(parts.zoom, zoomed ? "showAll" : "focus", zoomed ? "Show all panes" : "Focus pane");
  updatePaneToolState(parts.minimize, minimized ? "restore" : "minimize", minimized ? "Restore pane" : "Minimize pane");
  for (const button of parts.tools) {
    const terminalOnly = button === parts.fontDown || button === parts.fontUp || button === parts.restart;
    setDisabledIfChanged(button, (pending && !button.classList.contains("close"))
      || (terminalOnly && panel.type !== "terminal"));
  }
  const closeActionLabel = pending ? "Cancel pane" : closePaneActionLabel(workspace, panel.id);
  setTitleIfChanged(parts.close, closeActionLabel);
  setAttributeIfChanged(parts.close, "aria-label", closeActionLabel);
  if (pending) {
    renderPendingPane(panel, parts.body);
    return pane;
  }
  if (panel.type === "terminal") {
    const body = parts.body;
    const immediateInit = state.immediateTerminalInitPanelIds.has(panel.id);
    if (immediateInit) state.immediateTerminalInitPanelIds.delete(panel.id);
    const deferUntilPaint = !immediateInit && shouldDeferTerminalInitUntilPaint(panel, workspace);
    if (!immediateInit && shouldDeferInitialTerminalLoad(panel, workspace, visibleCount)) {
      renderDeferredTerminal(panel, body);
      if (deferUntilPaint) state.paintDeferredTerminalInitPanelIds.delete(panel.id);
      if (deferUntilPaint || panel.id === workspace?.activePanelId) {
        queueDeferredTerminalInit(panel.id, { afterPaint: deferUntilPaint });
      } else {
        state.deferredTerminalInitQueue.delete(panel.id);
      }
    } else {
      ensureTerminal(panel, body);
    }
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
      <span class="pending-pane-icon" aria-hidden="true"></span>
      <span class="pending-pane-copy">
        <span class="pending-pane-text"></span>
        <span class="pending-pane-meta"></span>
        <span class="pending-pane-progress" aria-hidden="true"><span></span></span>
      </span>
      <button class="pending-pane-cancel" type="button">Cancel</button>
    `;
    pending._pendingPaneParts = pendingPaneParts(pending);
    pending._pendingPaneParts.cancel.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      cancelPendingPanel(pending.dataset.panelId);
    };
    body.replaceChildren(pending);
  }
  if (pending.parentElement !== body) body.replaceChildren(pending);
  const parts = pending._pendingPaneParts || pendingPaneParts(pending);
  pending._pendingPaneParts = parts;
  setDatasetIfChanged(pending, "panelId", panel.id);
  const isBrowser = panel.type === "browser";
  const elapsedSeconds = pendingPanelElapsedSeconds(panel);
  const waiting = elapsedSeconds >= 2;
  const slow = elapsedSeconds >= 8;
  toggleClassIfChanged(pending, "is-browser", isBrowser);
  toggleClassIfChanged(pending, "is-terminal", !isBrowser);
  toggleClassIfChanged(pending, "is-waiting", waiting);
  toggleClassIfChanged(pending, "is-slow", slow);
  pending.setAttribute("role", "status");
  pending.setAttribute("aria-live", "polite");
  const baseMeta = isBrowser
    ? hostnameOf(panel.url || state.settings.browserHomeUrl)
    : `${optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell")} / ${panel.cwdShort || "~"}`;
  const title = pendingPaneTitle(isBrowser, elapsedSeconds);
  const elapsedLabel = elapsedSeconds > 0 ? `${elapsedSeconds}s elapsed` : "starting now";
  const meta = `${baseMeta} / ${elapsedLabel}`;
  const iconName = isBrowser ? "browserPlus" : "terminalPlus";
  if (parts.icon.dataset.pendingIcon !== iconName) {
    parts.icon.dataset.pendingIcon = iconName;
    parts.icon.innerHTML = controlIconMarkup(iconName);
  }
  pending.setAttribute("aria-label", `${title}. ${baseMeta}. ${elapsedSeconds} seconds elapsed.`);
  setTextIfChanged(
    parts.text,
    title
  );
  setTextIfChanged(parts.meta, meta);
  ensurePendingPaneTimer();
}

function pendingPaneTitle(isBrowser, elapsedSeconds) {
  if (elapsedSeconds >= 8) {
    return isBrowser ? "Browser is still opening" : "Terminal is still starting";
  }
  if (elapsedSeconds >= 2) {
    return isBrowser ? "Loading browser" : "Connecting terminal";
  }
  return isBrowser ? "Opening browser" : "Starting terminal";
}

function pendingPaneParts(pending) {
  return {
    icon: pending.querySelector(".pending-pane-icon"),
    text: pending.querySelector(".pending-pane-text"),
    meta: pending.querySelector(".pending-pane-meta"),
    cancel: pending.querySelector(".pending-pane-cancel")
  };
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
      || elements.paneGrid.querySelector(`.pane[data-panel-id="${paneIdSelector(panel.id)}"]`);
    const body = pane ? paneParts(pane).body : null;
    if (body?.isConnected) renderPendingPane(panel, body);
  }
  updateOperationChrome();
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

function compactSurfaceTabLabel(label) {
  const normalized = String(label || "").replace(/\s+/g, " ").trim();
  if (normalized.length <= 42) return normalized;
  return `${normalized.slice(0, 24).trim()}...${normalized.slice(-14).trim()}`;
}

function surfaceTabLabels(workspace) {
  const panels = workspace?.panels || [];
  const baseLabels = new Map();
  const counts = new Map();
  for (const panel of panels) {
    const label = panelDisplayTitle(panel, true);
    baseLabels.set(panel.id, label);
    counts.set(label, (counts.get(label) || 0) + 1);
  }
  const seen = new Map();
  const labels = new Map();
  for (const panel of panels) {
    const base = baseLabels.get(panel.id) || "";
    const index = (seen.get(base) || 0) + 1;
    seen.set(base, index);
    labels.set(panel.id, compactSurfaceTabLabel((counts.get(base) || 0) > 1 ? `${base} ${index}` : base));
  }
  return labels;
}

function surfaceTabLabel(workspace, panel) {
  const label = panelDisplayTitle(panel, true);
  const duplicates = (workspace?.panels || [])
    .filter((candidate) => panelDisplayTitle(candidate, true) === label);
  if (duplicates.length <= 1) return compactSurfaceTabLabel(label);
  const duplicateIndex = duplicates.findIndex((candidate) => candidate.id === panel.id);
  return compactSurfaceTabLabel(duplicateIndex >= 0 ? `${label} ${duplicateIndex + 1}` : label);
}

function terminalPanelFolder(panel) {
  return panel.cwdShort || "~";
}

function terminalPanelSmartSurfaceTitle(panel) {
  const title = String(panel?.title || "").trim();
  if (title && (panel.titleLocked || title.toLowerCase() !== "terminal")) return title;
  return terminalPanelFolder(panel);
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
  return surface ? terminalPanelSmartSurfaceTitle(panel) : terminalPanelTitle(panel);
}

function browserUrlChangeNeedsRender(panel, nextUrl) {
  const nextPanel = { ...panel, url: nextUrl };
  return panelDisplayTitle(panel, true) !== panelDisplayTitle(nextPanel, true)
    || panelDisplayTitle(panel, false) !== panelDisplayTitle(nextPanel, false);
}

function createEmptyWorkspace(workspace) {
  return createEmptyWorkspaceView(emptyWorkspaceViewModel(workspace));
}

function renderEmptyWorkspace(workspace) {
  let node = [...elements.paneGrid.children].find((child) => child.classList.contains("empty-workspace"));
  if (!node) {
    node = createEmptyWorkspace(workspace);
  } else {
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
  updateEmptyWorkspaceView(node, emptyWorkspaceViewModel(workspace, canReopen));
}

function emptyWorkspaceViewModel(workspace, canReopen = state.closedPanels.length > 0) {
  return {
    title: "cmux",
    bodyText: canReopen
      ? t("emptyWorkspace.noPanesReopen")
      : t("emptyWorkspace.noPanesStart"),
    launchers: emptyWorkspaceLaunchers(),
    iconMarkup: controlIconMarkup,
    onRun: (launcher) => runEmptyWorkspaceLauncher(launcher, workspace)
  };
}

async function workspaceForEmptyAction(workspace) {
  if (workspace?.id) return workspace;
  return await createWorkspace();
}

async function createEmptyWorkspacePanel(type, workspace) {
  const targetWorkspace = await workspaceForEmptyAction(workspace);
  if (!targetWorkspace?.id) return null;
  const options = {
    workspaceId: targetWorkspace.id,
    url: type === "browser" ? state.settings.browserHomeUrl : undefined
  };
  if (type === "terminal") return createTerminalPanel("right", options);
  return createPanel(type, "right", options);
}

function emptyWorkspaceCreationLauncherState(defaultMeta) {
  const queueLabel = paneCreationQueueStatusLabel();
  if (!queueLabel) return { meta: defaultMeta };
  const queueFull = paneCreationButtonsDisabled();
  return {
    meta: queueFull ? "Queue full" : queueLabel.replace(/\.$/, ""),
    busy: queueFull,
    busyMeta: "Queue full",
    busyLabel: queueFull ? paneCreationLimitLabel() : queueLabel
  };
}

function emptyWorkspaceLaunchers() {
  const launchers = [
    {
      id: "terminal",
      icon: "terminalPlus",
      label: t("emptyWorkspace.addTerminal"),
      ...emptyWorkspaceCreationLauncherState(optionLabel(terminalProfiles, state.settings.terminalProfile, "Auto shell")),
      kind: "panel",
      type: "terminal",
      addAction: true,
      primary: state.closedPanels.length === 0
    },
    {
      id: "browser",
      icon: "browserPlus",
      label: t("emptyWorkspace.addBrowser"),
      ...emptyWorkspaceCreationLauncherState(hostnameOf(state.settings.browserHomeUrl)),
      kind: "panel",
      type: "browser",
      addAction: true
    }
  ];
  if (workspaceStarters.length > 0 || state.workspaceBlueprints.length > 0) {
    launchers.push({
      id: "layouts",
      icon: "layout",
      label: t("config.settingsCategory.blueprints"),
      meta: t("emptyWorkspace.savedLayouts"),
      kind: "layouts"
    });
  }
  if (!isSettingsPresetIdActive("simpleFast")) {
    launchers.push({
      id: "fast",
      icon: "speed",
      label: t("emptyWorkspace.fastSetup", "Fast setup"),
      meta: t("emptyWorkspace.fastSetupMeta", "Clean UI, lower lag"),
      kind: "fast"
    });
  }
  launchers.push({
    id: "customize",
    icon: "settings",
    label: t("emptyWorkspace.customize", "Customize"),
    meta: t("emptyWorkspace.customizeMeta", "Themes, images, layout"),
    kind: "settings"
  });
  if (state.closedPanels.length > 0) {
    launchers.unshift({
      id: "reopen",
      icon: "history",
      label: t("emptyWorkspace.reopen"),
      ...emptyWorkspaceCreationLauncherState(t("emptyWorkspace.lastClosedPane")),
      kind: "reopen",
      primary: true
    });
  }
  return launchers;
}

async function runEmptyWorkspaceLauncher(launcher, workspace) {
  if (!launcher) return;
  if ((launcher.kind === "panel" || launcher.kind === "reopen") && paneCreationButtonsDisabled()) {
    toast(paneCreationLimitLabel());
    return;
  }
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
  if (launcher.kind === "fast") {
    applySettingsPresetById("simpleFast");
    return;
  }
  if (launcher.kind === "settings") {
    openSettingsCategory("quick");
    return;
  }
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
    splitter.setAttribute("aria-label", "Resize pane split");
    splitter.setAttribute("aria-valuemin", String(paneLayoutPercentMin));
    splitter.setAttribute("aria-valuemax", String(paneLayoutPercentMax));
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
  setTitleIfChanged(splitter, "Drag this grip to resize from 1% to 99%. Right-click for exact sizes. Double-click to equalize. Arrow keys adjust 1%; Shift+Arrow adjusts 10%.");
  return splitter;
}

function setSplitterResizePercent(splitter, percent, direction = splitter?.dataset.orientation || "right") {
  if (!splitter) return 50;
  const nextPercent = clampPaneLayoutPercent(percent);
  const label = direction === "down"
    ? `Top ${nextPercent}% / bottom ${100 - nextPercent}%`
    : `Left ${nextPercent}% / right ${100 - nextPercent}%`;
  setDatasetIfChanged(splitter, "resizePercent", String(nextPercent));
  setDatasetIfChanged(splitter, "resizeShort", `${nextPercent}%`);
  setDatasetIfChanged(splitter, "resizeLabel", label);
  setAttributeIfChanged(splitter, "aria-valuenow", String(nextPercent));
  setAttributeIfChanged(splitter, "aria-valuetext", label);
  setAttributeIfChanged(splitter, "aria-orientation", direction === "down" ? "horizontal" : "vertical");
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
  applyVisiblePaneSplitRatio(splitId, nextPercent / 100);
  scheduleRender();
  scheduleWorkspaceTerminalFits(workspace.id, true);
  scheduleLayoutSettingsRefresh({ ifChanged: true });
  if (options.toast) {
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

function windowResizePointFromEvent(event) {
  return { x: event.screenX, y: event.screenY };
}

function windowResizeCursorClass(edge) {
  if (edge === "left" || edge === "right") return "window-resizing-x";
  if (edge === "top" || edge === "bottom") return "window-resizing-y";
  return edge === "top-left" || edge === "bottom-right"
    ? "window-resizing-nwse"
    : "window-resizing-nesw";
}

function startWindowResize(event) {
  if (event.button !== 0 || event.isPrimary === false || state.windowResizing) return;
  if (state.windowMaximized || !window.cmuxNative?.beginWindowResize) return;
  const edge = event.currentTarget?.dataset?.windowResizeEdge || "";
  if (!edge) return;
  event.preventDefault();
  event.stopPropagation();
  const cursorClass = windowResizeCursorClass(edge);
  const point = windowResizePointFromEvent(event);
  state.windowResizing = {
    edge,
    pointerId: event.pointerId,
    element: event.currentTarget,
    point,
    frame: 0,
    cursorClass
  };
  elements.shell.classList.add("window-resizing", cursorClass);
  safeSetPointerCapture(event.currentTarget, event.pointerId);
  window.cmuxNative.beginWindowResize(edge, point);
}

function continueWindowResize(event) {
  const resize = state.windowResizing;
  if (!resize || event.pointerId !== resize.pointerId) return;
  event.preventDefault();
  resize.point = windowResizePointFromEvent(event);
  scheduleWindowResizeFrame(resize);
}

function scheduleWindowResizeFrame(resize = state.windowResizing) {
  if (!resize || resize.frame) return;
  resize.frame = requestAnimationFrame(() => {
    resize.frame = 0;
    window.cmuxNative?.resizeWindow?.(resize.point);
  });
}

function finishWindowResize(event) {
  const resize = state.windowResizing;
  if (!resize || event.pointerId !== resize.pointerId) return;
  event.preventDefault();
  if (resize.frame) {
    cancelAnimationFrame(resize.frame);
    resize.frame = 0;
  }
  window.cmuxNative?.resizeWindow?.(resize.point);
  window.cmuxNative?.endWindowResize?.();
  safeReleasePointerCapture(resize.element, event.pointerId);
  elements.shell.classList.remove("window-resizing", resize.cursorClass);
  state.windowResizing = null;
  scheduleDeferredTerminalFitFlush();
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
    appliedPreviousSize: Math.round(previousSize),
    appliedNextSize: Math.round(nextSize),
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
  const percentMinSize = Math.floor(pairTotal * (paneLayoutPercentMin / 100));
  const minSize = Math.min(
    Math.max(1, Math.max(baseMinSize, percentMinSize)),
    Math.max(1, Math.floor(pairTotal / 2) - 1)
  );
  const nextPrevious = Math.min(pairTotal - minSize, Math.max(minSize, previousSize + delta));
  const nextNext = pairTotal - nextPrevious;
  const nextPreviousSize = Math.round(nextPrevious);
  const nextNextSize = Math.round(nextNext);
  if (resize.appliedPreviousSize !== nextPreviousSize) {
    previousPane.style.flex = `0 0 ${nextPreviousSize}px`;
    resize.appliedPreviousSize = nextPreviousSize;
  }
  if (resize.appliedNextSize !== nextNextSize) {
    nextPane.style.flex = `0 0 ${nextNextSize}px`;
    resize.appliedNextSize = nextNextSize;
  }
  setSplitterResizePercent(resize.splitter, Math.round((nextPrevious / pairTotal) * 100), vertical ? "down" : "right");
  // Terminal hosts fit through ResizeObserver during live drag; keep this as a fallback only.
  if (typeof ResizeObserver === "function") return;
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
  let persistedSplitRatio = null;
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
    persistedSplitRatio = ratio;
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
  scheduleLayoutSettingsRefresh({ ifChanged: true });
  requestAnimationFrame(() => {
    if (splitId) {
      applyVisiblePaneSplitRatio(splitId, persistedSplitRatio);
      refreshVisiblePaneSignatures(workspaceId);
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
      <div class="pane-grip" title="Drag pane from the header" aria-hidden="true"></div>
      <div class="pane-type" role="img"></div>
      <div class="pane-title"></div>
      <div class="pane-toolbar">
        <button class="pane-tool split-right" type="button" title="Split right" aria-label="Split right"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14"></path></svg></button>
        <button class="pane-tool split-down" type="button" title="Split down" aria-label="Split down"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M4 12h16"></path></svg></button>
        <button class="pane-tool minimize" type="button" title="Minimize pane" aria-label="Minimize pane"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 12h10"></path></svg></button>
        <button class="pane-tool zoom" type="button" title="Focus pane" aria-label="Focus pane"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 4H5a1 1 0 0 0-1 1v3M16 4h3a1 1 0 0 1 1 1v3M8 20H5a1 1 0 0 1-1-1v-3M16 20h3a1 1 0 0 0 1-1v-3"></path></svg></button>
        <button class="pane-tool font-down" type="button" title="Smaller terminal text" aria-label="Smaller terminal text"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 7h10M10 7v12M7 19h6M17 16h4"></path></svg></button>
        <button class="pane-tool font-up" type="button" title="Larger terminal text" aria-label="Larger terminal text"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 7h10M10 7v12M7 19h6M18 15v6M15 18h6"></path></svg></button>
        <button class="pane-tool restart" type="button" title="Restart terminal" aria-label="Restart terminal"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 8a7 7 0 1 1-1 8"></path><path d="M7 4v4h4"></path></svg></button>
        <button class="pane-tool close" type="button" title="Close" aria-label="Close pane"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m7 7 10 10M17 7 7 17"></path></svg></button>
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
    changePaneTerminalFontSize(pane.dataset.panelId, -1, { toast: false, status: true });
  };
  parts.fontUp.onclick = (event) => {
    event.stopPropagation();
    changePaneTerminalFontSize(pane.dataset.panelId, 1, { toast: false, status: true });
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
    clearPaneGridDropTarget();
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
  const horizontalEdge = Math.min(0.34, Math.max(56 / Math.max(1, rect.width), 0.18));
  const verticalEdge = Math.min(0.34, Math.max(56 / Math.max(1, rect.height), 0.18));
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
    const targetWorkspaceId = target === elements.paneGrid ? activeWorkspace()?.id || "" : "";
    suppressNextPaneHeaderClick(drag.sourcePane);
    if (targetPanelId && targetPanelId !== drag.panelId && placement) {
      movePanelRelative(drag.panelId, targetPanelId, placement);
    } else if (targetWorkspaceId) {
      movePanelToWorkspace(drag.panelId, targetWorkspaceId);
    }
  }
  drag.sourcePane.classList.remove("is-dragging");
  if (drag.targetPane) clearPaneDropTarget(drag.targetPane);
  document.body.classList.remove("pane-drag-active");
  state.dragPanelId = null;
  state.panePointerDrag = null;
}

function suppressNextPaneHeaderClick(sourcePane) {
  const sourceHeader = sourcePane?.querySelector?.(".pane-header") || null;
  const controller = new AbortController();
  const cleanup = () => controller.abort();
  document.addEventListener("click", (event) => {
    const header = event.target?.closest?.(".pane-header");
    if (header && (!sourceHeader || header === sourceHeader)) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation?.();
    }
    cleanup();
  }, { capture: true, once: true, signal: controller.signal });
  document.addEventListener("pointerdown", cleanup, { capture: true, once: true, signal: controller.signal });
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
  if (!pane) return paneGridPointerDropTarget(event, sourcePanelId);
  if (pane.dataset.panelId === sourcePanelId) return null;
  return pane;
}

function paneGridCanAcceptPanelDrop(event = null) {
  if (!state.dragPanelId) return false;
  const workspace = activeWorkspace();
  if (!workspace?.id) return false;
  if (!findPanelState(state.dragPanelId)) return false;
  const target = event?.target?.nodeType === Node.ELEMENT_NODE ? event.target : event?.target?.parentElement;
  if (target?.closest?.(".pane[data-panel-id]")) return false;
  return true;
}

function paneGridPointerDropTarget(event, sourcePanelId) {
  const workspace = activeWorkspace();
  if (!workspace?.id || !sourcePanelId || !findPanelState(sourcePanelId)) return null;
  const element = document.elementFromPoint(event.clientX, event.clientY);
  if (!element || !elements.paneGrid.contains(element)) return null;
  if (element.closest?.(".pane[data-panel-id]")) return null;
  return elements.paneGrid;
}

function clearPaneGridDropTarget() {
  elements.paneGrid.classList.remove("is-drop-target", "is-background-drop-target");
  elements.paneGrid.removeAttribute("data-drop-position");
  elements.paneGrid._backgroundDropPane?.classList?.remove("is-background-drop-target");
  elements.paneGrid._backgroundDropPane = null;
}

function handlePaneGridDragOver(event) {
  if (!paneGridCanAcceptPanelDrop(event)) {
    clearPaneGridDropTarget();
    return;
  }
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
  elements.paneGrid.classList.add("is-drop-target");
}

function handlePaneGridDragLeave(event) {
  if (event.currentTarget.contains(event.relatedTarget)) return;
  clearPaneGridDropTarget();
}

function handlePaneGridDrop(event) {
  if (!paneGridCanAcceptPanelDrop(event)) return;
  event.preventDefault();
  const panelId = state.dragPanelId;
  const workspaceId = activeWorkspace()?.id || "";
  clearPaneGridDropTarget();
  if (panelId && workspaceId) movePanelToWorkspace(panelId, workspaceId);
}

function clearPaneDropTarget(pane) {
  pane.classList.remove("is-drop-target", "is-background-drop-target");
  pane.removeAttribute("data-drop-position");
}

function clearAllDropTargets() {
  clearPaneGridDropTarget();
  clearSurfaceTabDropTargets();
  for (const session of state.browserViews.values()) clearBrowserTabDropTargets(session);
  for (const pane of document.querySelectorAll(".pane.is-drop-target, .pane.is-background-drop-target")) clearPaneDropTarget(pane);
  for (const node of document.querySelectorAll(".is-drop-before, .is-drop-after, .workspace-row.is-drop-target, .workspace-row.is-workspace-drop-before, .workspace-row.is-workspace-drop-after")) {
    node.classList.remove("is-drop-before", "is-drop-after", "is-drop-target", "is-workspace-drop-before", "is-workspace-drop-after");
  }
  clearWorkspaceListDropTarget();
  clearWorkspaceRowDropTarget();
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
  state.immediateTerminalInitPanelIds.delete(panelId);
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
    if (terminal.queue) recordTerminalOutputQueueChange(-terminal.queue.length);
    closeSocketQuietly(terminal.socket);
    terminal.resizeObserver?.disconnect();
    terminal.searchResultDisposable?.dispose?.();
    terminal.focusDisposable?.dispose?.();
    terminal.term?.dispose();
    state.terminals.delete(panelId);
  }
  const browserSession = state.browserViews.get(panelId);
  if (browserSession?.initialLoadFrame) cancelAnimationFrame(browserSession.initialLoadFrame);
  clearBrowserSuspendStop(browserSession);
  if (browserSession?.tabRenderFrame) cancelAnimationFrame(browserSession.tabRenderFrame);
  if (browserSession?.tabScrollFrame) cancelAnimationFrame(browserSession.tabScrollFrame);
  if (browserSession?.tabScrollStateFrame) cancelAnimationFrame(browserSession.tabScrollStateFrame);
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
  if (shouldDeferTerminalInitUntilPaint(panel, workspace)) return true;
  if (shouldStartColdTerminalsFast()) return false;
  return shouldKeepTerminalInitDeferred(panel)
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
    && !shouldStartColdTerminalsFast()
    && state.deferredTerminalInitQueue.has(panel.id)
    && !state.terminals.has(panel.id)
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel);
}

function shouldStartColdTerminalsFast() {
  return state.settings.terminalStartupMode === "fast";
}

function startVisibleColdTerminalsImmediately() {
  const workspace = activeWorkspace();
  if (!workspace?.panels?.length) return false;
  const visiblePanelIds = visiblePanePanelIds();
  let requested = false;
  for (const panel of workspace.panels) {
    if (panel.type !== "terminal" || !visiblePanelIds.has(panel.id)) continue;
    requested = requestImmediateTerminalInit(panel.id) || requested;
  }
  if (!requested) return false;
  state.paneRenderSignature = "";
  scheduleRender();
  return true;
}

function requestImmediateTerminalInit(panelId) {
  const found = findPanelState(panelId);
  if (
    !found
    || found.panel.type !== "terminal"
    || state.terminals.has(panelId)
    || isPanelMinimized(found.panel)
    || isPendingPanel(found.panel)
  ) {
    return false;
  }
  state.paintDeferredTerminalInitPanelIds.delete(panelId);
  state.deferredTerminalInitQueue.delete(panelId);
  state.immediateTerminalInitPanelIds.add(panelId);
  return true;
}

function requestTerminalInitAfterPaint(panelId) {
  const found = findPanelState(panelId);
  if (
    !found
    || found.panel.type !== "terminal"
    || state.terminals.has(panelId)
    || isPanelMinimized(found.panel)
    || isPendingPanel(found.panel)
  ) {
    return false;
  }
  state.immediateTerminalInitPanelIds.delete(panelId);
  state.paintDeferredTerminalInitPanelIds.add(panelId);
  return true;
}

function startDeferredTerminal(panelId) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  focusPanel(panelId);
  const requested = requestImmediateTerminalInit(panelId);
  if (requested) scheduleRender();
  return requested;
}

function renderDeferredTerminal(panel, body) {
  let deferred = body.querySelector(".terminal-deferred");
  if (!deferred) {
    deferred = document.createElement("div");
    deferred.className = "terminal-deferred";
    deferred.innerHTML = `
      <span class="terminal-deferred-icon" aria-hidden="true">${controlIconMarkup("terminalPlus")}</span>
      <span class="terminal-deferred-copy">
        <span class="terminal-deferred-title">Preparing terminal</span>
        <span class="terminal-deferred-meta"></span>
        <span class="terminal-deferred-action"></span>
      </span>
    `;
    deferred.addEventListener("click", () => startDeferredTerminal(deferred.dataset.panelId));
    deferred.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      startDeferredTerminal(deferred.dataset.panelId);
    });
    body.replaceChildren(deferred);
  }
  const isActive = panel.id === activeWorkspace()?.activePanelId;
  setDatasetIfChanged(deferred, "panelId", panel.id);
  toggleClassIfChanged(deferred, "is-startable", !isActive);
  deferred.setAttribute("role", isActive ? "status" : "button");
  deferred.tabIndex = isActive ? -1 : 0;
  const profile = optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell");
  const folder = panel.cwdShort || panel.cwd || "~";
  const title = isActive ? "Preparing terminal" : "Start terminal";
  const action = isActive ? "Starting after layout is ready" : "Click or press Enter";
  setTitleIfChanged(deferred, `${title} - ${profile} / ${folder}`);
  deferred.setAttribute("aria-label", `${title}. ${profile}. ${folder}. ${action}.`);
  setTextIfChanged(deferred.querySelector(".terminal-deferred-title"), title);
  setTextIfChanged(deferred.querySelector(".terminal-deferred-meta"), `${profile} / ${folder}`);
  setTextIfChanged(deferred.querySelector(".terminal-deferred-action"), action);
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
    : setTimeout(run, Math.min(64, deferredTerminalInitIdleTimeoutMs));
}

function deferredTerminalInitQueueOrder(activeWorkspaceId) {
  const queued = [...state.deferredTerminalInitQueue];
  const activePanelId = state.data?.workspaces
    ?.find((workspace) => workspace.id === activeWorkspaceId)
    ?.activePanelId || "";
  if (!activePanelId || !state.deferredTerminalInitQueue.has(activePanelId)) return queued;
  return [activePanelId, ...queued.filter((panelId) => panelId !== activePanelId)];
}

function flushDeferredTerminalInit() {
  const activeWorkspaceId = state.data?.activeWorkspaceId || "";
  const activePanelId = state.data?.workspaces
    ?.find((workspace) => workspace.id === activeWorkspaceId)
    ?.activePanelId || "";
  const visiblePanelIds = visiblePanePanelIds();
  for (const panelId of deferredTerminalInitQueueOrder(activeWorkspaceId)) {
    if (!state.deferredTerminalInitQueue.delete(panelId)) continue;
    if (panelId !== activePanelId) continue;
    if (state.terminals.has(panelId)) continue;
    const found = findPanelState(panelId);
    if (!found || found.workspace.id !== activeWorkspaceId || !visiblePanelIds.has(panelId)) continue;
    const pane = state.paneCache.get(panelId);
    const body = pane ? paneParts(pane).body : null;
    if (!body?.querySelector(".terminal-deferred")) continue;
    ensureTerminal(found.panel, body);
    const terminal = state.terminals.get(panelId);
    if (terminal) scheduleFitTerminal(terminal, true);
    if (found.workspace.activePanelId === panelId) focusTerminalSession(panelId);
    break;
  }
  if (activePanelId && state.deferredTerminalInitQueue.has(activePanelId)) scheduleDeferredTerminalInit();
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
  host.dataset.connectionStatus = t("terminal.connectingShell");
  host.addEventListener("wheel", handleTerminalWheelZoom, { passive: false, capture: true });
  body.appendChild(host);

  const fontSize = terminalFontSizeForPanel(panel);
  const theme = terminalTheme(panel);
  const themeSignature = terminalThemeSignature(panel);
  const term = new TerminalConstructor({
    cursorBlink: state.settings.terminalCursorBlink,
    cursorStyle: state.settings.terminalCursorStyle,
    allowProposedApi: true,
    convertEol: true,
    fontFamily: terminalFontStack(),
    fontSize,
    lineHeight: state.settings.terminalLineHeight,
    scrollback: state.settings.terminalScrollback,
    theme
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
    writing: false,
    fitFrame: 0,
    resizeObserver: null,
    disposed: false,
    lastFitCols: 0,
    lastFitRows: 0,
    lastHostWidth: 0,
    lastHostHeight: 0,
    forceFit: false,
    fitDeferred: false,
    resumeThrottleFrames: 0,
    fontSize,
    searchOverlay: null,
    searchTerm: "",
    searchCaseSensitive: false,
    searchResultDisposable: null,
    focusDisposable: null,
    connectionStatusTimer: 0,
    createdAt: performance.now(),
    hasOutput: false,
    terminalThemeSignature: themeSignature
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
    if (!session.hasOutput) setTerminalConnectionStatus(session, "ready", t("terminal.shellConnected"), 1200);
    scheduleFitTerminal(session, true);
  });
  socket.addEventListener("error", () => {
    if (!session.disposed) setTerminalConnectionStatus(session, "error", t("terminal.shellConnectionFailed"));
  });
  socket.addEventListener("close", () => {
    if (!session.disposed) setTerminalConnectionStatus(session, "disconnected", t("terminal.shellDisconnected"));
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
  overlay.setAttribute("role", "search");
  overlay.setAttribute("aria-label", t("terminal.searchLabel"));
  overlay.hidden = true;
  overlay.innerHTML = `
    <input class="terminal-search-input" type="search" autocomplete="off" spellcheck="false">
    <span class="terminal-search-status" aria-live="polite"></span>
    <button class="terminal-search-button terminal-search-prev" type="button">${controlIconMarkup("up")}</button>
    <button class="terminal-search-button terminal-search-next" type="button">${controlIconMarkup("down")}</button>
    <button class="terminal-search-button terminal-search-case" type="button">${controlIconMarkup("caseMatch")}</button>
    <button class="terminal-search-button terminal-search-close" type="button">${controlIconMarkup("close")}</button>
  `;
  const input = overlay.querySelector(".terminal-search-input");
  const previous = overlay.querySelector(".terminal-search-prev");
  const next = overlay.querySelector(".terminal-search-next");
  const matchCase = overlay.querySelector(".terminal-search-case");
  const close = overlay.querySelector(".terminal-search-close");
  input.placeholder = t("terminal.searchPlaceholder");
  input.setAttribute("aria-label", t("terminal.searchPlaceholder"));
  for (const [button, label] of [
    [previous, t("terminal.searchPrevious")],
    [next, t("terminal.searchNext")],
    [matchCase, t("terminal.searchMatchCase")],
    [close, t("terminal.searchClose")]
  ]) {
    button.title = label;
    button.setAttribute("aria-label", label);
  }
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
    status.textContent = t("terminal.searchNoResults");
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
    toast(t("terminal.searchNeedsPane"));
    return false;
  }
  if (!target.session.searchAddon) {
    toast(t("terminal.searchUnavailable"));
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
  if (!session?.queue || session.queue.length <= terminalHiddenOutputQueueLimit) return 0;
  const preserveBytes = Math.min(terminalHiddenOutputPreserveBytes, session.queue.length);
  const trimmedBytes = session.queue.length - preserveBytes;
  if (trimmedBytes <= 0) return 0;
  const previousLength = session.queue.length;
  const marker = `\r\n[cmux] ${formatBytes(trimmedBytes)} of hidden output was trimmed to keep switching responsive.\r\n`;
  session.queue = marker + session.queue.slice(-preserveBytes);
  recordTerminalOutputQueueChange(session.queue.length - previousLength);
  state.terminalOutputStats.trimmedBytes = (state.terminalOutputStats.trimmedBytes || 0) + trimmedBytes;
  state.terminalOutputStats.trimmedEvents = (state.terminalOutputStats.trimmedEvents || 0) + 1;
  return trimmedBytes;
}

function enqueueTerminalOutput(session, data) {
  session.queue += data;
  recordTerminalOutputQueueChange(data.length);
  const paused = terminalOutputShouldPause(session);
  if (paused) trimPausedTerminalOutput(session);
  if (state.terminalOutputStats.currentQueued >= terminalOutputBacklogThreshold) {
    maybeTriggerPerformanceGuard("terminal output backlog");
  }
  if (!paused) scheduleTerminalOutputFlush(session);
}

function scheduleTerminalOutputFlush(session) {
  if (session.disposed || session.scheduled || session.writing) return;
  session.scheduled = true;
  requestAnimationFrame(() => flushTerminalOutput(session));
}

function flushTerminalOutput(session) {
  session.scheduled = false;
  if (session.disposed || session.writing || !session.queue) return;
  if (terminalOutputShouldPause(session)) {
    state.terminalOutputStats.pausedFlushes += 1;
    return;
  }
  const chunkSize = terminalOutputChunkSizeFor(session);
  const chunk = session.queue.length > chunkSize ? session.queue.slice(0, chunkSize) : session.queue;
  session.queue = session.queue.slice(chunk.length);
  recordTerminalOutputQueueChange(-chunk.length);
  state.terminalOutputStats.chunks += 1;
  state.terminalOutputStats.lastChunk = chunk.length;
  state.terminalOutputStats.writtenBytes += chunk.length;
  session.writing = true;
  session.term.write(chunk, () => {
    session.writing = false;
    if (session.resumeThrottleFrames > 0) session.resumeThrottleFrames -= 1;
    if (session.disposed) return;
    clearTerminalConnectionStatus(session);
    if (session.queue) scheduleTerminalOutputFlush(session);
  });
}

function terminalOutputChunkSizeFor(session) {
  if (session.resumeThrottleFrames > 0) {
    return Math.min(terminalResumeOutputChunkSize, terminalOutputPerformanceChunkSize);
  }
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
    const visible = visiblePanelIds.has(session.panelId);
    if (
      state.settings.terminalSmoothResumedOutput
      && pauseInactive
      && visible
      && session.queue.length >= terminalResumeThrottleThreshold
    ) {
      session.resumeThrottleFrames = Math.max(session.resumeThrottleFrames || 0, terminalResumeThrottleFrames);
    }
    if (!pauseInactive || visible) scheduleTerminalOutputFlush(session);
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

function recordTerminalOutputQueueChange(delta) {
  const currentQueued = Math.max(0, (state.terminalOutputStats.currentQueued || 0) + delta);
  state.terminalOutputStats.currentQueued = currentQueued;
  state.terminalOutputStats.maxQueued = Math.max(state.terminalOutputStats.maxQueued || 0, currentQueued);
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

function clearBrowserSuspendStop(session) {
  if (!session?.suspendStopTimer) return;
  clearTimeout(session.suspendStopTimer);
  session.suspendStopTimer = 0;
}

function scheduleBrowserSuspendStop(session) {
  if (!session || session.suspendStopTimer) return;
  session.suspendStopTimer = setTimeout(() => {
    session.suspendStopTimer = 0;
    if (!session.suspended) return;
    stopBrowserLoading(session.view);
  }, browserSuspendStopDelayMs);
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

function applyBrowserWheelZoomGuard(event, panel) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel || !event.ctrlKey) return false;
  event.preventDefault();
  event.stopPropagation();
  event.stopImmediatePropagation?.();
  markInteractedPanel(browserPanel.id);
  const session = state.browserViews.get(browserPanel.id);
  if (session?.view) lockBrowserViewZoom(session.view);
  return true;
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
  const session = state.browserViews.get(browserPanel.id);
  if (!session?.address) {
    toast("Browser pane is not ready.");
    return false;
  }
  return focusBrowserAddressSession(session);
}

function focusBrowserAddressSession(session) {
  if (!session?.address) return false;
  focusPanel(session.panelId);
  requestAnimationFrame(() => {
    if (state.browserViews.get(session.panelId) !== session) return;
    session.address.focus();
    session.address.select();
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
  session.setStatus?.(browserLoadingStatusText);
  if (typeof session.view?.reload === "function" && !session.reload?.disabled) {
    session.view.reload();
  } else {
    if (session.address.value !== url) session.address.value = url;
    session.view.src = browserViewSourceUrl(url, state.settings.browserHomeUrl);
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
  const result = await openExternalBrowser(browserPanelUrl(browserPanel), { toast: true });
  return Boolean(result?.ok);
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
    return createBrowserTab(session, state.settings.browserHomeUrl, { focusAddress: true });
  }
  return createBrowserTabSnapshotForPanel(browserPanel, state.settings.browserHomeUrl);
}

function createBrowserTabSnapshotForPanel(browserPanel, value = state.settings.browserHomeUrl) {
  if (!browserPanel?.id) return false;
  const snapshot = browserTabSnapshotForPanelId(browserPanel.id, browserPanel.url || state.settings.browserHomeUrl);
  if (snapshot.tabs.length >= browserTabLimit) {
    toast(browserTabLimitMessage());
    return false;
  }
  const tab = normalizeBrowserTab({ url: value }, state.settings.browserHomeUrl);
  if (!tab) return false;
  snapshot.tabs.push(tab);
  snapshot.activeTabId = tab.id;
  state.browserTabSnapshots.set(browserPanel.id, normalizeBrowserTabSnapshot(snapshot, tab.url));
  saveBrowserTabSnapshots(state.browserTabSnapshots);
  queueBrowserUrlSync(browserPanel.id, tab.url);
  focusPanel(browserPanel.id);
  scheduleRender();
  return true;
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
      scheduleBrowserSuspendStop(session);
    } else if (session.statusText === browserPausedStatusText) {
      session.setStatus?.("");
      clearBrowserSuspendStop(session);
    } else {
      clearBrowserSuspendStop(session);
    }
    setBrowserAudioMuted(session.view, suspended);
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

function runEmbeddedGoogleHomePolish(view, polishState) {
  polishState.frame = 0;
  const value = polishState.value || view?.src || "";
  if (!isGoogleHomeUrl(value, state.settings.browserHomeUrl)) return;
  if (!view?.isConnected) return;
  if (typeof view?.executeJavaScript !== "function") return;
  polishState.lastAt = performance.now();
  try {
    const result = view.executeJavaScript(embeddedGooglePromoDismissScript, true);
    result?.catch?.(() => {});
  } catch {
    // Webviews can detach while panes or workspaces are being rearranged.
  }
}

function scheduleEmbeddedGoogleHomePolish(view, value) {
  if (!isGoogleHomeUrl(value || view?.src, state.settings.browserHomeUrl)) return;
  if (!view?.isConnected) return;
  if (typeof view?.executeJavaScript !== "function") return;
  let polishState = embeddedGooglePolishState.get(view);
  if (!polishState) {
    polishState = { frame: 0, lastAt: 0, value: "" };
    embeddedGooglePolishState.set(view, polishState);
  }
  const targetValue = value || view.src || "";
  const now = performance.now();
  if (polishState.frame) return;
  if (polishState.value === targetValue && now - polishState.lastAt < embeddedGooglePolishMinIntervalMs) return;
  polishState.value = targetValue;
  polishState.frame = requestAnimationFrame(() => runEmbeddedGoogleHomePolish(view, polishState));
}

function loadDeferredBrowserSession(session) {
  if (!session?.loadDeferred) return false;
  const targetUrl = browserSessionTargetUrl(session);
  const sourceUrl = browserViewSourceUrl(targetUrl, state.settings.browserHomeUrl);
  clearDeferredBrowserSession(session);
  if (session.view.src !== sourceUrl) {
    session.content?.classList?.remove("has-loaded");
    session.setLoading?.(true);
    session.setStatus?.(browserLoadingStatusText);
    session.view.src = sourceUrl;
  }
  session.updateNavState?.();
  return true;
}

function clearDeferredBrowserSession(session) {
  if (!session) return;
  session.loadDeferred = false;
  if (session.deferredPane) setHiddenIfChanged(session.deferredPane, true);
  toggleClassIfChanged(session.shell, "is-browser-deferred", false);
}

function shouldDeferInitialBrowserLoad(panel) {
  const workspace = activeWorkspace();
  return Boolean(
    state.settings.browserSuspendInactive
    && workspace
    && workspaceHasPanelId(workspace, panel?.id)
    && panel?.id !== workspace.activePanelId
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel)
  );
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
    deferred.setAttribute("aria-label", t("browser.pausedAria"));
    deferred.innerHTML = `
      <span class="browser-deferred-title"></span>
      <span class="browser-deferred-url"></span>
      <span class="browser-deferred-action"></span>
    `;
    deferred.onclick = () => focusPanel(panel.id);
    body.replaceChildren(deferred);
  }
  setTextIfChanged(deferred.querySelector(".browser-deferred-title"), t("browser.pausedTitle"));
  setTextIfChanged(deferred.querySelector(".browser-deferred-action"), t("browser.pausedAction"));
  const url = deferred.querySelector(".browser-deferred-url");
  setTextIfChanged(url, targetUrl);
  setTitleIfChanged(url, targetUrl);
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
  const tabLabels = browserTabLabels(session);
  const signature = browserTabsSignature(session, tabLabels);
  const layoutSignature = browserTabsLayoutSignature(session, tabLabels);
  const layoutChanged = layoutSignature !== session.tabLayoutSignature;
  const structureReady = browserTabStructureReady(session);
  if (
    signature === session.tabSignature
    && structureReady
  ) {
    updateBrowserTabNewButton(session);
    session.tabLayoutSignature = layoutSignature;
    scheduleActiveBrowserTabIntoView(session, { refreshOverflow: layoutChanged || !session.tabOverflowSignature });
    return;
  }
  if (!layoutChanged && structureReady) {
    updateBrowserTabNewButton(session);
    updateBrowserTabSelectionOnly(session);
    session.tabSignature = signature;
    session.tabLayoutSignature = layoutSignature;
    scheduleActiveBrowserTabIntoView(session, { refreshOverflow: !session.tabOverflowSignature });
    return;
  }
  if (browserTabOrderReady(session)) {
    updateBrowserTabButtonsInPlace(session, tabLabels);
    updateBrowserTabNewButton(session);
    session.tabSignature = signature;
    session.tabLayoutSignature = layoutSignature;
    scheduleActiveBrowserTabIntoView(session, { refreshOverflow: layoutChanged || !session.tabOverflowSignature });
    return;
  }
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
    updateBrowserTabButton(session, button, tab, tabLabels.get(tab.id));
    return button;
  });
  replaceChildrenIfChanged(session.tabList, nodes);
  updateBrowserTabNewButton(session);
  session.tabSignature = signature;
  session.tabLayoutSignature = layoutSignature;
  scheduleActiveBrowserTabIntoView(session, { refreshOverflow: layoutChanged || !session.tabOverflowSignature });
}

function browserTabStructureReady(session) {
  const tabCount = Array.isArray(session?.tabs) ? session.tabs.length : 0;
  return Boolean(
    session?.tabNew
    && session.tabButtons?.size === tabCount
    && session.tabList?.children.length === tabCount
  );
}

function browserTabOrderReady(session) {
  if (!browserTabStructureReady(session)) return false;
  return (session.tabs || []).every((tab, index) => session.tabList.children[index] === session.tabButtons.get(tab.id));
}

function updateBrowserTabButtonsInPlace(session, tabLabels = browserTabLabels(session)) {
  if (!session?.tabList || !session.tabButtons) return false;
  let changed = false;
  for (const tab of session.tabs || []) {
    const button = session.tabButtons.get(tab.id);
    if (!button) continue;
    changed = updateBrowserTabButton(session, button, tab, tabLabels.get(tab.id)) || changed;
  }
  return changed;
}

function browserTabsSignature(session, tabLabels = browserTabLabels(session)) {
  const parts = [];
  appendSignatureValue(parts, session?.activeTabId || "");
  appendSignatureValue(parts, browserTabAtLimit(session));
  appendSignatureArray(parts, session?.tabs || [], (nextParts, tab) => {
    appendSignatureValue(nextParts, tab.id);
    appendSignatureValue(nextParts, tab.url || "");
    appendSignatureValue(nextParts, tab.title || "");
    appendSignatureValue(nextParts, tabLabels.get(tab.id) || browserTabBaseLabel(tab));
  });
  return parts.join("");
}

function browserTabsLayoutSignature(session, tabLabels = browserTabLabels(session)) {
  const parts = [];
  appendSignatureValue(parts, browserTabAtLimit(session));
  appendSignatureArray(parts, session?.tabs || [], (nextParts, tab) => {
    appendSignatureValue(nextParts, tab.id);
    appendSignatureValue(nextParts, tab.url || "");
    appendSignatureValue(nextParts, tab.title || "");
    appendSignatureValue(nextParts, tabLabels.get(tab.id) || browserTabBaseLabel(tab));
  });
  return parts.join("");
}

function updateBrowserTabNewButton(session) {
  if (!session?.tabNew) return;
  const tabCount = Array.isArray(session.tabs) ? session.tabs.length : 0;
  const atLimit = browserTabAtLimit(session);
  const label = atLimit
    ? browserTabLimitMessage()
    : `${t("browser.newTab")} (${tabCount}/${browserTabLimit})`;
  setDisabledIfChanged(session.tabNew, atLimit);
  toggleClassIfChanged(session.tabNew, "is-disabled", atLimit);
  setAttributeIfChanged(session.tabNew, "aria-disabled", String(atLimit));
  setAttributeIfChanged(session.tabNew, "aria-label", label);
  setTitleIfChanged(session.tabNew, label);
  setTextIfChanged(session.tabNew.querySelector(".browser-tab-new-label"), t("browser.newTab"));
}

function browserTabAtLimit(session) {
  return (session?.tabs?.length || 0) >= browserTabLimit;
}

function browserTabLimitMessage() {
  return `Browser tab limit reached (${browserTabLimit}). Close one first.`;
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

function updateBrowserTabScrollState(session, overflowing = session?.tabList?.classList.contains("has-overflow")) {
  const tabList = session?.tabList;
  if (!tabList) return;
  const maxScrollLeft = Math.max(0, tabList.scrollWidth - tabList.clientWidth);
  const scrollLeft = Math.max(0, tabList.scrollLeft);
  toggleClassIfChanged(tabList, "can-scroll-left", overflowing && scrollLeft > 1);
  toggleClassIfChanged(tabList, "can-scroll-right", overflowing && scrollLeft < maxScrollLeft - 1);
}

function scheduleBrowserTabScrollStateRefresh(session) {
  if (!session?.tabList || session.tabScrollStateFrame) return;
  session.tabScrollStateFrame = requestAnimationFrame(() => {
    session.tabScrollStateFrame = 0;
    updateBrowserTabScrollState(session);
  });
}

function updateBrowserTabOverflow(session) {
  const tabList = session?.tabList;
  if (!tabList) return;
  const tabCount = session.tabs?.length || tabList.children.length;
  const currentSignature = tabOverflowStateSignature(tabList, tabCount);
  if (currentSignature === session.tabOverflowSignature) return;
  if (tabCount < 5 && tabList.classList.contains("is-crowded")) {
    tabList.classList.remove("is-crowded");
  }
  const naturalOverflowing = tabList.scrollWidth > tabList.clientWidth + 1;
  toggleClassIfChanged(tabList, "is-crowded", naturalOverflowing || tabCount >= 5);
  const overflowing = tabList.scrollWidth > tabList.clientWidth + 1;
  toggleClassIfChanged(tabList, "has-overflow", overflowing);
  updateBrowserTabScrollState(session, overflowing);
  if (!overflowing && tabList.scrollLeft) tabList.scrollLeft = 0;
  session.tabOverflowSignature = tabOverflowStateSignature(tabList, tabCount);
}

function scheduleActiveBrowserTabIntoView(session, options = {}) {
  if (!session?.tabList || !session.activeTabId) return;
  if (session.tabScrollFrame) return;
  const refreshOverflow = options.refreshOverflow !== false;
  session.tabScrollFrame = requestAnimationFrame(() => {
    session.tabScrollFrame = 0;
    const activeButton = session.tabButtons?.get(session.activeTabId);
    if (!activeButton) {
      if (refreshOverflow) scheduleBrowserTabOverflowRefresh(session);
      return;
    }
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
    if (refreshOverflow) scheduleBrowserTabOverflowRefresh(session);
    else scheduleBrowserTabScrollStateRefresh(session);
  });
}

function createBrowserTabButton(session) {
  const button = document.createElement("button");
  button.type = "button";
  button.draggable = true;
  button.className = "browser-tab";
  const icon = document.createElement("span");
  icon.className = "browser-tab-icon";
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML = controlIconMarkup("browser");
  const label = document.createElement("span");
  label.className = "browser-tab-label";
  const close = document.createElement("span");
  close.className = "browser-tab-close";
  close.innerHTML = controlIconMarkup("close");
  button._browserTabParts = { icon, label, close };
  close.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    closeBrowserTab(session, button.dataset.browserTabId);
  });
  button.append(icon, label, close);
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
    handleBrowserTabKeydown(session, event, button.dataset.browserTabId);
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
    setBrowserTabDropTarget(session, button, browserTabDropPlacement(event, button));
  });
  button.addEventListener("dragleave", () => {
    clearBrowserTabDropTarget(session, button);
  });
  button.addEventListener("drop", (event) => {
    event.preventDefault();
    const placement = browserTabDropPlacement(event, button);
    const draggedTabId = session.dragBrowserTabId;
    const targetTabId = button.dataset.browserTabId;
    clearBrowserTabDropTarget(session, button);
    if (draggedTabId && draggedTabId !== targetTabId) moveBrowserTab(session, draggedTabId, targetTabId, placement);
  });
  button.addEventListener("dragend", () => {
    session.dragBrowserTabId = "";
    button.classList.remove("is-dragging");
    clearBrowserTabDropTargets(session);
  });
  return button;
}

function focusBrowserTabButton(session, tabId) {
  if (!session || !tabId) return;
  requestAnimationFrame(() => {
    const button = session.tabButtons?.get(tabId);
    button?.focus?.({ preventScroll: true });
  });
}

function browserTabKeyboardTargetId(session, currentTabId, key) {
  const tabs = session?.tabs || [];
  if (tabs.length === 0) return "";
  const currentIndex = Math.max(0, tabs.findIndex((tab) => tab.id === currentTabId));
  if (key === "Home") return tabs[0]?.id || "";
  if (key === "End") return tabs.at(-1)?.id || "";
  if (key === "ArrowLeft") return tabs[Math.max(0, currentIndex - 1)]?.id || "";
  if (key === "ArrowRight") return tabs[Math.min(tabs.length - 1, currentIndex + 1)]?.id || "";
  return "";
}

function handleBrowserTabKeydown(session, event, tabId) {
  if (!session || !tabId) return;
  if (event.ctrlKey && event.key.toLowerCase() === "t") {
    event.preventDefault();
    event.stopPropagation();
    createBrowserTab(session, state.settings.browserHomeUrl, { focusTab: true });
    return;
  }
  if (event.key === "Delete") {
    event.preventDefault();
    event.stopPropagation();
    closeBrowserTab(session, tabId);
    return;
  }
  const nextTabId = browserTabKeyboardTargetId(session, tabId, event.key);
  if (!nextTabId) return;
  event.preventDefault();
  event.stopPropagation();
  activateBrowserTab(session, nextTabId);
  focusBrowserTabButton(session, nextTabId);
}

function updateBrowserTabSelectionState(button, active) {
  if (!button) return false;
  let changed = false;
  changed = toggleClassIfChanged(button, "is-active", active) || changed;
  changed = setAttributeIfChanged(button, "aria-selected", active ? "true" : "false") || changed;
  const nextTabIndex = active ? 0 : -1;
  if (button.tabIndex !== nextTabIndex) {
    button.tabIndex = nextTabIndex;
    changed = true;
  }
  return changed;
}

function updateBrowserTabSelectionOnly(session) {
  if (!session?.tabList || !session.tabButtons) return false;
  let changed = false;
  for (const button of session.tabList.querySelectorAll(".browser-tab.is-active")) {
    if (button.dataset.browserTabId !== session.activeTabId) {
      changed = updateBrowserTabSelectionState(button, false) || changed;
    }
  }
  changed = updateBrowserTabSelectionState(session.tabButtons.get(session.activeTabId), true) || changed;
  return changed;
}

function updateBrowserTabButton(session, button, tab, label = browserTabLabel(session, tab)) {
  const fullTitle = browserTabBaseLabel(tab);
  const ordinal = Math.max(1, (session?.tabs || []).findIndex((candidate) => candidate.id === tab.id) + 1);
  const closeLabel = session.tabs.length <= 1 ? t("browser.resetTab") : t("browser.closeTab");
  button._browserTabParts ||= {
    icon: button.querySelector(".browser-tab-icon"),
    label: button.querySelector(".browser-tab-label"),
    close: button.querySelector(".browser-tab-close")
  };
  const parts = button._browserTabParts;
  const active = tab.id === session.activeTabId;
  let changed = false;
  if (!button.classList.contains("browser-tab")) {
    button.classList.add("browser-tab");
    changed = true;
  }
  changed = toggleClassIfChanged(button, "is-active", active) || changed;
  changed = setDatasetIfChanged(button, "browserTabId", tab.id) || changed;
  changed = setDatasetIfChanged(button, "tabIndex", String(ordinal)) || changed;
  changed = setAttributeIfChanged(button, "role", "tab") || changed;
  changed = updateBrowserTabSelectionState(button, active) || changed;
  changed = setTitleIfChanged(button, `${label}${label !== fullTitle ? ` - ${fullTitle}` : ""} - ${tab.url}`) || changed;
  const ariaLabel = `${label}. ${tab.url}. ${closeLabel} with Delete.`;
  changed = setAttributeIfChanged(button, "aria-label", ariaLabel) || changed;
  changed = setTextIfChanged(parts.label, label) || changed;
  changed = setTitleIfChanged(parts.close, closeLabel) || changed;
  return changed;
}

function browserTabBaseLabel(tab) {
  return tab?.title || browserTabTitle(tab?.url);
}

function browserTabLabels(session) {
  const tabs = session?.tabs || [];
  const baseLabels = new Map();
  const counts = new Map();
  for (const tab of tabs) {
    const label = browserTabBaseLabel(tab);
    baseLabels.set(tab.id, label);
    counts.set(label, (counts.get(label) || 0) + 1);
  }
  const seen = new Map();
  const labels = new Map();
  for (const tab of tabs) {
    const base = baseLabels.get(tab.id) || "";
    const index = (seen.get(base) || 0) + 1;
    seen.set(base, index);
    labels.set(tab.id, (counts.get(base) || 0) > 1 ? `${base} ${index}` : base);
  }
  return labels;
}

function browserTabLabel(session, tab) {
  const label = browserTabBaseLabel(tab);
  const duplicates = (session?.tabs || [])
    .filter((candidate) => browserTabBaseLabel(candidate) === label);
  if (duplicates.length <= 1) return label;
  const duplicateIndex = duplicates.findIndex((candidate) => candidate.id === tab.id);
  return duplicateIndex >= 0 ? `${label} ${duplicateIndex + 1}` : label;
}

function browserTabDropPlacement(event, button) {
  const rect = button.getBoundingClientRect();
  return event.clientX - rect.left > rect.width / 2 ? "after" : "before";
}

function clearBrowserTabDropTargets(session) {
  const target = session?.tabButtons?.get(session?.tabDropTargetId || "");
  target?.classList?.remove("is-drop-before", "is-drop-after");
  session?.tabNew?.classList.remove("is-drop-before");
  if (session) {
    session.tabDropTargetId = "";
    session.tabDropTargetMode = "";
  }
}

function clearBrowserTabDropTarget(session, button = null) {
  if (!session || !button) {
    clearBrowserTabDropTargets(session);
    return;
  }
  button.classList.remove("is-drop-before", "is-drop-after");
  if (button.dataset.browserTabId === session.tabDropTargetId) {
    session.tabDropTargetId = "";
    session.tabDropTargetMode = "";
  }
}

function setBrowserTabDropTarget(session, button, mode) {
  const tabId = button?.dataset?.browserTabId || "";
  if (!session || !tabId || !mode) {
    clearBrowserTabDropTargets(session);
    return;
  }
  if (session.tabDropTargetId === tabId && session.tabDropTargetMode === mode) return;
  clearBrowserTabDropTargets(session);
  button.classList.toggle("is-drop-before", mode === "before");
  button.classList.toggle("is-drop-after", mode === "after");
  session.tabDropTargetId = tabId;
  session.tabDropTargetMode = mode;
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
  saveBrowserSessionTabs(session);
  renderBrowserTabs(session);
  return true;
}

function moveBrowserTabToEnd(session, tabId) {
  if (!session) return false;
  const fromIndex = session.tabs.findIndex((tab) => tab.id === tabId);
  if (fromIndex < 0 || fromIndex === session.tabs.length - 1) return false;
  const [tab] = session.tabs.splice(fromIndex, 1);
  session.tabs.push(tab);
  saveBrowserSessionTabs(session);
  renderBrowserTabs(session);
  return true;
}

function duplicateBrowserTab(session, tabId) {
  if (!session) return false;
  if (browserTabAtLimit(session)) {
    toast(browserTabLimitMessage());
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
    contextMenuButton("New tab", () => createBrowserTab(session, state.settings.browserHomeUrl, { focusAddress: true })),
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

function showBrowserNewTabMenu(event, session) {
  event.preventDefault();
  event.stopPropagation();
  if (!session) return;
  const activeTab = activeBrowserTab(session);
  const atLimit = browserTabAtLimit(session);
  const homeUrl = normalizeUrl(state.settings.browserHomeUrl, defaultSettings.browserHomeUrl);
  const currentUrl = normalizeUrl(activeTab?.url || session.address?.value || homeUrl, homeUrl);
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = t("browser.newTab");
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = atLimit ? browserTabLimitMessage() : hostnameOf(homeUrl) || homeUrl;
  const actions = contextMenuActionGroup(
    contextMenuButton(t("browser.newTab"), () => createBrowserTab(session, homeUrl, { focusAddress: true }), atLimit),
    contextMenuButton("Duplicate current tab", () => activeTab && duplicateBrowserTab(session, activeTab.id), atLimit || !activeTab),
    contextMenuButton("Open home externally", () => openExternalBrowser(homeUrl, { toast: true })),
    contextMenuButton(t("browser.openWithProfile"), () => showExternalBrowserProfileMenuAt(event.clientX, event.clientY, currentUrl), false, "", { keepOpen: true })
  );
  const settingsActions = contextMenuActionGroup(
    contextMenuButton(t("browser.settings"), () => openSettingsCategory("browser"))
  );
  menu.replaceChildren(title, meta, contextMenuSectionTitle("Browser"), actions, contextMenuSectionTitle("Settings"), settingsActions);
  showContextMenuAt(menu, event.clientX, event.clientY);
}

function updateActiveBrowserTabUrl(session, value) {
  const tab = activeBrowserTab(session);
  if (!tab) return;
  const url = normalizeBrowserPageUrl(value || state.settings.browserHomeUrl);
  if (!url) return;
  if (tab.url === url) return;
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
  if (session.address.value !== tab.url) session.address.value = tab.url;
  clearDeferredBrowserSession(session);
  const sourceUrl = browserViewSourceUrl(tab.url, state.settings.browserHomeUrl);
  if (session.view.src !== sourceUrl) {
    session.content?.classList?.remove("has-loaded");
    session.view.src = sourceUrl;
    session.setLoading?.(true);
    session.setStatus?.(browserLoadingStatusText);
  }
  queueBrowserUrlSync(session.panelId, tab.url);
  saveBrowserSessionTabs(session);
  renderBrowserTabs(session);
  focusPanel(session.panelId);
  return true;
}

function createBrowserTab(session, value = state.settings.browserHomeUrl, options = {}) {
  if (!session) return false;
  if (browserTabAtLimit(session)) {
    toast(browserTabLimitMessage());
    return false;
  }
  const tab = normalizeBrowserTab({ url: value }, state.settings.browserHomeUrl);
  if (!tab) return false;
  session.tabs.push(tab);
  activateBrowserTab(session, tab.id);
  if (options.focusTab) focusBrowserTabButton(session, tab.id);
  if (options.focusAddress) focusBrowserAddressSession(session);
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
  tabList.setAttribute("role", "tablist");
  tabList.setAttribute("aria-label", t("browser.tabs"));
  tabList.setAttribute("aria-orientation", "horizontal");
  const tabNew = document.createElement("button");
  tabNew.className = "browser-tab-new";
  tabNew.type = "button";
  tabNew.title = t("browser.newTab");
  tabNew.setAttribute("aria-label", t("browser.newTab"));
  tabNew.innerHTML = `
    <span class="browser-tab-new-icon" aria-hidden="true">${controlIconMarkup("plus")}</span>
    <span class="browser-tab-new-label"></span>
  `;
  tabStrip.append(tabList, tabNew);
  const bar = document.createElement("div");
  bar.className = "browser-bar";
  const back = document.createElement("button");
  back.className = "browser-nav browser-back";
  back.type = "button";
  back.title = t("browser.back");
  back.setAttribute("aria-label", t("browser.back"));
  back.innerHTML = controlIconMarkup("back");
  const forward = document.createElement("button");
  forward.className = "browser-nav browser-forward";
  forward.type = "button";
  forward.title = t("browser.forward");
  forward.setAttribute("aria-label", t("browser.forward"));
  forward.innerHTML = controlIconMarkup("forward");
  const reload = document.createElement("button");
  reload.className = "browser-nav browser-reload";
  reload.type = "button";
  reload.title = t("browser.reload");
  reload.setAttribute("aria-label", t("browser.reload"));
  reload.innerHTML = controlIconMarkup("reload");
  const home = document.createElement("button");
  home.className = "browser-nav browser-home";
  home.type = "button";
  home.title = t("browser.home");
  home.setAttribute("aria-label", t("browser.home"));
  home.innerHTML = controlIconMarkup("home");
  const address = document.createElement("input");
  address.className = "browser-address";
  const tabSnapshot = browserTabSnapshotForPanel(state.browserTabSnapshots, panel, state.settings.browserHomeUrl);
  const activeTab = tabSnapshot.tabs.find((tab) => tab.id === tabSnapshot.activeTabId) || tabSnapshot.tabs[0];
  address.value = activeTab?.url || panel.url || state.settings.browserHomeUrl;
  const go = document.createElement("button");
  go.className = "browser-go browser-go-submit";
  go.type = "button";
  go.title = t("browser.go");
  go.setAttribute("aria-label", t("browser.go"));
  go.innerHTML = controlIconMarkup("arrowRight");
  const external = document.createElement("button");
  external.className = "browser-go browser-go-external";
  external.type = "button";
  const externalTitle = browserExternalProfileTitle();
  external.title = externalTitle;
  external.setAttribute("aria-label", externalTitle);
  external.innerHTML = controlIconMarkup("external");
  const status = document.createElement("div");
  status.className = "browser-status";
  status.textContent = browserLoadingStatusText;
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
      <span class="browser-error-icon" aria-hidden="true">${controlIconMarkup("browser")}</span>
      <span class="browser-error-title"></span>
      <span class="browser-error-body"></span>
      <span class="browser-error-url"></span>
      <span class="browser-error-actions">
        <button class="browser-error-action browser-error-retry" type="button"></button>
        <button class="browser-error-action browser-error-open" type="button"></button>
        <button class="browser-error-action browser-error-home" type="button"></button>
        <button class="browser-error-action browser-error-settings" type="button"></button>
      </span>
    </div>
  `;
  const loadingPane = document.createElement("div");
  loadingPane.className = "browser-loading";
  loadingPane.innerHTML = `
    <span class="browser-loading-icon" aria-hidden="true">${controlIconMarkup("browser")}</span>
    <span class="browser-loading-track"></span>
    <span class="browser-loading-title"></span>
    <span class="browser-loading-url"></span>
  `;
  const deferredPane = document.createElement("button");
  deferredPane.className = "browser-deferred";
  deferredPane.type = "button";
  deferredPane.setAttribute("aria-label", t("browser.pausedAria"));
  deferredPane.hidden = true;
  deferredPane.innerHTML = `
    <span class="browser-deferred-title"></span>
    <span class="browser-deferred-url"></span>
    <span class="browser-deferred-action"></span>
  `;
  const errorTitle = errorPane.querySelector(".browser-error-title");
  const errorBody = errorPane.querySelector(".browser-error-body");
  const errorUrl = errorPane.querySelector(".browser-error-url");
  const errorRetry = errorPane.querySelector(".browser-error-retry");
  const errorOpen = errorPane.querySelector(".browser-error-open");
  const errorHome = errorPane.querySelector(".browser-error-home");
  const errorSettings = errorPane.querySelector(".browser-error-settings");
  const loadingTitle = loadingPane.querySelector(".browser-loading-title");
  const loadingUrl = loadingPane.querySelector(".browser-loading-url");
  const deferredTitle = deferredPane.querySelector(".browser-deferred-title");
  const deferredUrl = deferredPane.querySelector(".browser-deferred-url");
  const deferredAction = deferredPane.querySelector(".browser-deferred-action");
  setTextIfChanged(errorRetry, t("browser.retry"));
  setTextIfChanged(errorOpen, t("browser.open"));
  setTextIfChanged(errorHome, t("browser.home"));
  setTextIfChanged(errorSettings, t("browser.settingsShort"));
  setTextIfChanged(deferredTitle, t("browser.pausedTitle"));
  setTextIfChanged(deferredAction, t("browser.pausedAction"));
  content.append(view, errorPane, loadingPane, deferredPane);
  const isWebview = view.tagName.toLowerCase() === "webview";
  let webviewReady = !isWebview;
  let loadingStatusTimer = 0;
  let browserLoadTimer = 0;
  let browserLoadFailed = false;
  let session = null;
  const setAddressValue = (value) => {
    const next = String(value ?? "");
    if (address.value !== next) address.value = next;
  };

  const clearBrowserLoadTimer = () => {
    if (!browserLoadTimer) return;
    clearTimeout(browserLoadTimer);
    browserLoadTimer = 0;
  };

  const setLoading = (loading = false) => {
    const visible = Boolean(loading);
    const targetUrl = normalizeUrl(address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    clearBrowserLoadTimer();
    setHiddenIfChanged(loadingPane, !visible);
    toggleClassIfChanged(content, "is-loading", visible);
    if (!visible) return;
    setTextIfChanged(loadingTitle, formatMessage("browser.loadingPage", {
      title: hostnameOf(targetUrl) || t("browser.pageFallback")
    }));
    setTextIfChanged(loadingUrl, targetUrl);
    setTitleIfChanged(loadingUrl, targetUrl);
    browserLoadTimer = setTimeout(() => {
      browserLoadTimer = 0;
      if (!content.classList.contains("is-loading") || browserLoadFailed || deferredPane.hidden === false) return;
      if (content.classList.contains("has-loaded")) {
        setLoading(false);
        setStatus("");
        return;
      }
      browserLoadFailed = true;
      showBrowserError(t("browser.errorTimeout"), targetUrl);
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
    setTextIfChanged(status, message);
    toggleClassIfChanged(status, "is-visible", Boolean(message));
    toggleClassIfChanged(shell, "has-browser-status", Boolean(message));
    if (message === browserLoadingStatusText) {
      loadingStatusTimer = setTimeout(() => {
        loadingStatusTimer = 0;
        if (status.textContent === browserLoadingStatusText) setStatus("");
      }, 4500);
    }
  };
  const hideBrowserError = () => {
    setHiddenIfChanged(errorPane, true);
  };
  const markBrowserContentLoaded = () => {
    content.classList.add("has-loaded");
  };
  const showBrowserError = (message = t("browser.errorDefault"), detail = address.value) => {
    const targetUrl = normalizeUrl(detail || address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    clearBrowserLoadTimer();
    setLoading(false);
    setTextIfChanged(errorTitle, t("browser.errorTitle"));
    setTextIfChanged(errorBody, message);
    setTextIfChanged(errorUrl, targetUrl);
    setTitleIfChanged(errorUrl, targetUrl);
    setHiddenIfChanged(errorPane, false);
    setStatus("");
  };
  const showDeferredBrowser = () => {
    const targetUrl = normalizeUrl(address.value || state.settings.browserHomeUrl, state.settings.browserHomeUrl);
    setLoading(false);
    hideBrowserError();
    setTextIfChanged(deferredUrl, targetUrl);
    setTitleIfChanged(deferredUrl, targetUrl);
    setHiddenIfChanged(deferredPane, false);
    toggleClassIfChanged(shell, "is-browser-deferred", true);
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
      setStatus(browserLoadingStatusText);
      const sourceUrl = browserViewSourceUrl(targetUrl, state.settings.browserHomeUrl);
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
      setDisabledIfChanged(back, !(isWebview && webviewReady && typeof view.canGoBack === "function" && view.canGoBack()));
      setDisabledIfChanged(forward, !(isWebview && webviewReady && typeof view.canGoForward === "function" && view.canGoForward()));
      setDisabledIfChanged(reload, isWebview && !webviewReady);
    } catch {
      setDisabledIfChanged(back, true);
      setDisabledIfChanged(forward, true);
      setDisabledIfChanged(reload, true);
    }
  };

  const openPopupExternally = (event) => {
    const popupUrl = event?.url || event?.detail?.url || "";
    if (!/^https?:\/\//i.test(popupUrl)) return;
    event.preventDefault?.();
    openExternalBrowser(popupUrl);
    setStatus(t("browser.openedExternallyStatus"));
  };

  const navigate = () => {
    if (!findPanelState(panel.id)) return;
    const next = normalizeUrl(address.value, state.settings.browserHomeUrl);
    setAddressValue(next);
    clearDeferredBrowserSession(session);
    const sourceUrl = browserViewSourceUrl(next, state.settings.browserHomeUrl);
    if (view.src !== sourceUrl) content.classList.remove("has-loaded");
    view.src = sourceUrl;
    browserLoadFailed = false;
    hideBrowserError();
    setLoading(true);
    setStatus(browserLoadingStatusText);
    updateActiveBrowserTabUrl(session, next);
    queueBrowserUrlSync(panel.id, next);
  };
  const handleBrowserWheel = (event) => {
    applyBrowserWheelZoomGuard(event, panel);
  };
  go.onclick = navigate;
  external.onclick = () => openBrowserPanelExternally(panel);
  external.oncontextmenu = (event) => showExternalBrowserProfileMenu(event, browserPanelUrl(panel));
  tabNew.oncontextmenu = (event) => showBrowserNewTabMenu(event, session);
  tabNew.onclick = (event) => {
    if (browserTabAtLimit(session)) {
      event.preventDefault();
      toast(browserTabLimitMessage());
      return;
    }
    createBrowserTab(session, state.settings.browserHomeUrl, { focusAddress: true });
  };
  tabStrip.addEventListener("dblclick", (event) => {
    if (event.target.closest?.(".browser-tab, .browser-tab-new, button, input")) return;
    createBrowserTab(session, state.settings.browserHomeUrl, { focusAddress: true });
  });
  deferredPane.onclick = () => {
    focusPanel(panel.id);
    loadDeferredBrowserSession(session);
  };
  tabNew.addEventListener("dragover", (event) => {
    if (!session?.dragBrowserTabId) return;
    event.preventDefault();
    clearBrowserTabDropTargets(session);
    tabNew.classList.add("is-drop-before");
  });
  tabNew.addEventListener("dragleave", () => tabNew.classList.remove("is-drop-before"));
  tabNew.addEventListener("drop", (event) => {
    event.preventDefault();
    tabNew.classList.remove("is-drop-before");
    if (session?.dragBrowserTabId) moveBrowserTabToEnd(session, session.dragBrowserTabId);
  });
  errorRetry.onclick = () => {
    hideBrowserError();
    reloadBrowserPanel(panel);
  };
  errorOpen.onclick = () => openBrowserPanelExternally(panel);
  errorHome.onclick = () => {
    setAddressValue(state.settings.browserHomeUrl);
    navigate();
  };
  errorSettings.onclick = () => openSettingsCategory("browser");
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
    setStatus(browserLoadingStatusText);
    if (typeof view.reload === "function") {
      view.reload();
    } else {
      view.src = browserViewSourceUrl(address.value, state.settings.browserHomeUrl);
    }
  };
  home.onclick = () => {
    setAddressValue(state.settings.browserHomeUrl);
    navigate();
  };
  view.addEventListener("did-navigate", (event) => {
    if (event.url) {
      const nextUrl = browserDisplayUrl(event.url, state.settings.browserHomeUrl);
      setAddressValue(nextUrl);
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
    if (!browserLoadFailed) {
      markBrowserContentLoaded();
      hideBrowserError();
    }
    lockBrowserViewZoom(view);
    scheduleEmbeddedGoogleHomePolish(view, address.value || view.src);
    updateNavState();
  });
  view.addEventListener("did-navigate-in-page", (event) => {
    if (event.url) {
      const nextUrl = browserDisplayUrl(event.url, state.settings.browserHomeUrl);
      setAddressValue(nextUrl);
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
    setStatus(browserLoadingStatusText);
    updateNavState();
  });
  view.addEventListener("did-stop-loading", () => {
    if (!browserLoadFailed) markBrowserContentLoaded();
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
  view.addEventListener("did-frame-finish-load", (event) => {
    if (event?.isMainFrame !== false && !browserLoadFailed) markBrowserContentLoaded();
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
      ? formatMessage("browser.errorReported", { failure })
      : t("browser.errorFallback");
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
    showBrowserError(t("browser.errorFallback"));
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
    tabSignature: "",
    tabLayoutSignature: "",
    tabOverflowSignature: "",
    tabScrollStateFrame: 0,
    tabDropTargetId: "",
    tabDropTargetMode: "",
    setStatus,
    setLoading,
    updateNavState,
    content,
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
    initialLoadFrame: 0,
    suspendStopTimer: 0
  };
  session.detachTabWheelScroll = attachHorizontalWheelScroll(tabList);
  tabList.addEventListener("scroll", () => scheduleBrowserTabScrollStateRefresh(session), { passive: true });
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
    setLoading(true);
    setStatus(browserLoadingStatusText);
    scheduleInitialBrowserLoad();
  }
  updateNavState();
}

function scheduleSettingsInspectorRender(options = {}) {
  state.settingsInspectorRenderOptions = mergeSettingsInspectorRenderOptions(
    state.settingsInspectorRenderOptions,
    options
  );
  const delayMs = Math.max(0, Number(options.delayMs) || 0);
  if (delayMs > 0 && !state.settingsInspectorRenderFrame) {
    if (state.settingsInspectorRenderTimer) return;
    state.settingsInspectorRenderTimer = window.setTimeout(() => {
      state.settingsInspectorRenderTimer = 0;
      queueSettingsInspectorRenderFrame();
    }, delayMs);
    return;
  }
  if (state.settingsInspectorRenderTimer) {
    window.clearTimeout(state.settingsInspectorRenderTimer);
    state.settingsInspectorRenderTimer = 0;
  }
  queueSettingsInspectorRenderFrame();
}

function queueSettingsInspectorRenderFrame() {
  if (state.settingsInspectorRenderFrame) return;
  state.settingsInspectorRenderFrame = requestAnimationFrame(() => {
    state.settingsInspectorRenderFrame = 0;
    const pendingOptions = state.settingsInspectorRenderOptions || {};
    state.settingsInspectorRenderOptions = null;
    renderSettingsInspector(pendingOptions);
  });
}

function mergeSettingsInspectorRenderOptions(current = {}, next = {}) {
  return {
    ...current,
    ...next,
    force: Boolean(current?.force || next?.force),
    resetScroll: Boolean(current?.resetScroll || next?.resetScroll),
    ifChanged: Boolean(current?.ifChanged || next?.ifChanged)
  };
}

function renderInspector(options = {}) {
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
        <button class="notification-action" type="button">Jump to pane</button>
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
    if (options.deferSettings && elements.inspectorBody.querySelector(".settings-react-host")) {
      scheduleSettingsInspectorRender({
        ifChanged: true,
        delayMs: settingsWorkspaceSwitchRenderDelayMs
      });
      return;
    }
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
    quickSection.append(quickSetupPresetRailPanel());
    quickSection.append(quickSetupGuidePanel());
    quickSection.append(quickActionDisclosurePanel());
    quickSection.append(paneShapePanel(workspace));
    quickSection.append(...quickColorControlRows(workspace));
    quickSection.append(quickCategoryDisclosurePanel());
    quickSection.append(quickPresetDisclosurePanel());
    nodes.push(quickSection);
  }

  if (shouldBuildSection("profiles")) {
    const profilesSection = settingsSection("Profiles", "saved settings profile preset apply save rename delete appearance layout terminal performance");
    profilesSection.append(settingsProfilesDisclosurePanel());
    nodes.push(profilesSection);
  }

  if (shouldBuildSection("blueprints")) {
    const blueprintsSection = settingsSection("Workspace blueprints", "saved workspace blueprint layout pane template terminal browser split apply new save rename delete");
    blueprintsSection.append(workspaceBlueprintsDisclosurePanel());
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
    titleInput.dataset.settingsSearch = normalizeSettingsQuery("workspace name rename title input");
    titleInput.disabled = !workspace;
    let titleSave = null;
    let titleUseFolder = null;
    const currentWorkspaceName = () => activeWorkspace()?.title || workspace?.title || "";
    const suggestedWorkspaceName = () => workspaceSuggestedTitle(activeWorkspace() || workspace);
    const updateWorkspaceNameActions = () => {
      const nextTitle = titleInput.value.trim();
      const currentTitle = currentWorkspaceName();
      const suggestedTitle = suggestedWorkspaceName();
      if (titleSave) {
        titleSave.disabled = !workspace || !nextTitle || nextTitle === currentTitle;
        titleSave.title = !workspace
          ? "Open a workspace before renaming it."
          : !nextTitle
            ? "Enter a workspace name first."
            : nextTitle === currentTitle
              ? "Workspace name is already current."
              : "Save the active workspace name.";
      }
      if (titleUseFolder) {
        titleUseFolder.disabled = !workspace || !suggestedTitle || suggestedTitle === currentTitle;
        titleUseFolder.title = !workspace
          ? "Open a workspace before using its folder name."
          : !suggestedTitle
            ? "Set a workspace folder before using its name."
            : suggestedTitle === currentTitle
              ? "Workspace already uses the folder name."
              : "Rename the workspace from its folder.";
      }
    };
    const revertWorkspaceNameInput = () => {
      titleInput.value = currentWorkspaceName();
      updateWorkspaceNameActions();
    };
    const saveWorkspaceNameInput = async (options = {}) => {
      const nextTitle = titleInput.value.trim();
      if (!workspace) {
        if (options.toast) toast("Open a workspace before renaming it.");
        return false;
      }
      if (!nextTitle) {
        revertWorkspaceNameInput();
        if (options.toast) toast("Enter a workspace name first.");
        return false;
      }
      if (nextTitle === currentWorkspaceName()) {
        revertWorkspaceNameInput();
        if (options.toast) toast("Workspace name already current.");
        return false;
      }
      const changed = await renameWorkspaceTo(titleInput.value);
      revertWorkspaceNameInput();
      if (options.toast) toast(changed ? "Workspace renamed." : "Workspace name already current.");
      return changed;
    };
    titleInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        saveWorkspaceNameInput({ toast: true });
      } else if (event.key === "Escape") {
        event.preventDefault();
        revertWorkspaceNameInput();
        titleInput.blur();
      }
    });
    titleInput.addEventListener("input", updateWorkspaceNameActions);
    titleSave = settingsActionButton("Save", () => saveWorkspaceNameInput({ toast: true }), "primary", "workspace name rename save title");
    titleUseFolder = settingsActionButton("Use folder", async () => {
      const suggestedTitle = suggestedWorkspaceName();
      titleInput.value = suggestedTitle;
      const changed = await renameWorkspaceTo(suggestedTitle);
      revertWorkspaceNameInput();
      toast(changed ? "Workspace name set from folder." : "Workspace already uses the folder name.");
    }, "", "workspace name rename use folder directory title");
    const titleControl = document.createElement("span");
    titleControl.className = "workspace-name-control";
    titleControl.append(titleInput, titleSave, titleUseFolder);
    updateWorkspaceNameActions();
    workspaceSection.append(settingRow("Name", titleControl, false, "workspace name rename title save use folder"));
    const folderInput = document.createElement("input");
    folderInput.className = "setting-control";
    folderInput.readOnly = true;
    folderInput.value = workspace?.cwdShort || workspace?.cwd || "";
    folderInput.title = workspace?.cwd || "";
    workspaceSection.append(settingRow("Folder", folderInput, true, "workspace folder directory cwd path"));
    const folderActions = document.createElement("div");
    folderActions.className = "settings-actions";
    folderActions.dataset.settingsSearch = normalizeSettingsQuery("workspace folder directory cwd choose open new recent history");
    const chooseFolder = settingsActionButton("Choose", () => chooseWorkspaceFolder(), "", "workspace folder directory cwd picker choose folder");
    chooseFolder.disabled = !workspace;
    chooseFolder.title = workspace ? "Choose a folder for the active workspace." : "Open a workspace before choosing a folder.";
    const openFolder = settingsActionButton("Open", () => openWorkspaceFolder(), "", "workspace folder explorer directory open folder");
    openFolder.disabled = !workspace?.cwd;
    openFolder.title = workspace?.cwd ? "Open this workspace folder." : "This workspace does not have a folder yet.";
    folderActions.append(
      chooseFolder,
      openFolder,
      settingsActionButton("New", () => createWorkspaceFromFolder(), "", "workspace folder new directory new from folder")
    );
    workspaceSection.append(folderActions);
    workspaceSection.append(recentFoldersDisclosurePanel());
    workspaceSection.append(workspaceStartersDisclosurePanel());
    workspaceSection.append(settingRow(
      "Color",
      colorControlPanel({
        colors: workspaceColorPalette(),
        activeColor: workspace?.color,
        fallbackColor: state.settings.accent,
        onPick: (color) => setWorkspaceColor(color),
        saveLabel: "Save",
        targetLabel: "Workspace",
        targetMeta: workspace ? workspaceDisplayTitle(workspace) : "No workspace selected",
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
    appearanceSection.append(appearanceThemeGalleryDisclosurePanel());
    appearanceSection.append(settingRow("Accent", swatchGrid(accentColorPalette(), state.settings.accent, (accent) => updateSettings({ accent }))));
    appearanceSection.append(settingRow("Custom accent", colorPicker(state.settings.accent, (accent) => updateSettings({ accent })), false, "custom accent color hex picker"));
    appearanceSection.append(savedColorsDisclosurePanel());
    const appearanceActions = document.createElement("div");
    appearanceActions.className = "settings-actions appearance-actions";
    appearanceActions.dataset.settingsSearch = normalizeSettingsQuery("appearance look save profile reset theme accent background terminal colors default profiles");
    const lookSettingsDefault = appearanceSettingsAreDefault();
    const lookReset = settingsActionButton("Reset look", resetAppearanceSettings, "", `appearance look reset theme accent background terminal colors default ${lookSettingsDefault ? "active current " : ""}`);
    lookReset.disabled = lookSettingsDefault;
    lookReset.title = lookReset.disabled
      ? "Look settings already match the default setup."
      : "Reset theme, accent, app background, and terminal colors.";
    appearanceActions.append(
      applySettingsProfileSaveLimit(
        settingsActionButton("Save profile", saveCurrentLookProfile, "primary", "appearance look save current settings profile theme accent background terminal layout performance"),
        "Save this look as a reusable Settings profile."
      ),
      settingsActionButton("Profiles", () => openSettingsCategory("profiles"), "", "appearance look settings profiles saved apply update"),
      lookReset
    );
    appearanceSection.append(appearanceActions);
    appearanceSection.append(activeBackgroundPanel({ tuning: true }));
    appearanceSection.append(appearanceBackgroundTemplateDisclosurePanel());
    appearanceSection.append(savedBackgroundDisclosurePanel());

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
    browserSection.append(browserHomePresetsDisclosurePanel());
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
    homeActions.dataset.settingsSearch = normalizeSettingsQuery("browser home open reset default url page web system external profile chrome edge brave save browser profile reusable");
    const browserHomeDefault = browserHomeKey(state.settings.browserHomeUrl) === browserHomeKey(defaultSettings.browserHomeUrl);
    const resetBrowserHomeAction = settingsActionButton("Reset", resetBrowserHome, "", `browser home reset default url page web ${browserHomeDefault ? "active current " : ""}`);
    resetBrowserHomeAction.disabled = browserHomeDefault;
    resetBrowserHomeAction.title = browserHomeDefault
      ? "Browser home already uses the default page."
      : "Reset the browser home page to the default.";
    homeActions.append(
      applySettingsProfileSaveLimit(
        settingsActionButton("Save browser profile", saveCurrentBrowserProfile, "primary", "browser save profile home page launch external chrome edge brave reusable"),
        "Save this browser setup as a reusable Settings profile."
      ),
      settingsActionButton("Open pane", () => createPanel("browser", "right", { url: state.settings.browserHomeUrl })),
      settingsActionButton("Open external", () => openExternalBrowser(state.settings.browserHomeUrl, { toast: true }), "", "browser system chrome edge brave profile external"),
      settingsActionButton("Refresh profiles", () => refreshBrowserProfiles({ render: true }), "", "browser chrome edge brave profile detect refresh reload"),
      resetBrowserHomeAction
    );
    browserSection.append(homeActions);
    browserSection.append(recentBrowserPagesDisclosurePanel());
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
    layoutSection.append(settingRow(
      "Pane headers",
      settingSegmentedControl("paneHeaderMode", paneHeaderOptions.map(([value, label]) => [
        value,
        label,
        value === "compact" ? "Small title bar" : value === "full" ? "Title with tools" : "Hide pane chrome"
      ]), "terminal pane header chrome compact hidden content only toolbar"),
      true,
      "terminal pane header chrome compact hidden content only toolbar"
    ));
    layoutSection.append(settingRow(
      "Pane controls",
      settingSegmentedControl("paneActionMode", paneActionOptions.map(([value, label]) => [
        value,
        label,
        value === "essential" ? "Close and focus" : value === "split" ? "Split tools visible" : "All pane actions"
      ]), "pane controls buttons actions clean split full toolbar clutter"),
      true,
      "pane controls buttons actions clean split full toolbar clutter"
    ));
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
    const sidebarBranchSelect = document.createElement("select");
    sidebarBranchSelect.className = "setting-select";
    for (const [value, label] of sidebarBranchOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      sidebarBranchSelect.append(option);
    }
    sidebarBranchSelect.value = state.settings.sidebarBranchMode;
    sidebarBranchSelect.onchange = () => updateSettings({ sidebarBranchMode: sidebarBranchSelect.value });
    layoutSection.append(settingRow("Git branches", sidebarBranchSelect, false, "sidebar workspace git branch branch name hide active all detailed rows"));
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
    layoutSection.append(settingRow(
      "Toolbar",
      settingSegmentedControl("toolbarMode", toolbarModeOptions, "top bar command strip compact standard expanded shortcuts actions"),
      true,
      "top bar command strip compact standard expanded shortcuts actions"
    ));
    layoutSection.append(settingRow(
      "Tab width",
      settingSegmentedControl("tabSize", tabSizeOptions.map(([value, label]) => [
        value,
        label,
        value === "compact" ? "More tabs fit" : value === "balanced" ? "Default width" : "Longer names"
      ]), "surface tab chrome tab width compact balanced roomy", { compact: true }),
      true,
      "surface tab chrome tab width compact balanced roomy"
    ));
    layoutSection.append(settingRow(
      "Add tabs",
      settingSegmentedControl("addTabStyle", addTabStyleOptions.map(([value, label]) => [
        value,
        label,
        value === "labeled" ? "Text buttons" : value === "compact" ? "Small + buttons" : "Hide from tabs"
      ]), "surface tab add terminal browser plus button labeled compact hidden simple chrome", { compact: true }),
      true,
      "surface tab add terminal browser plus button labeled compact hidden simple chrome"
    ));
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
    layoutSection.append(settingRow(
      "Pane color markers",
      toggleInput(state.settings.paneColorMarkers, (checked) => updateSettings({ paneColorMarkers: checked })),
      false,
      "pane tab color markers colored dots border accent strip quiet simple terminal chrome"
    ));
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
    layoutActions.dataset.settingsSearch = normalizeSettingsQuery("split layout pane splitter resize reset equal save layout blueprint workspace chrome toolbar sidebar footer inspector tabs status header title focus mode simple clean");
    const saveLayoutAction = settingsActionButton("Save layout", saveCurrentWorkspaceBlueprint, "", "save current split pane layout workspace blueprint reusable");
    applyWorkspaceBlueprintSaveLimit(saveLayoutAction, workspace, "Save the current workspace pane layout as a reusable blueprint.");
    const workspaceChromeDefault = workspaceChromeSettingsAreDefault();
    const resetChromeAction = settingsActionButton("Reset workspace chrome", resetWorkspaceChrome, "", `workspace chrome toolbar sidebar footer inspector tabs status header title reset ${workspaceChromeDefault ? "active current " : ""}`);
    resetChromeAction.disabled = workspaceChromeDefault;
    resetChromeAction.title = workspaceChromeDefault
      ? "Workspace chrome already matches the default setup."
      : "Reset toolbar, sidebar, tabs, status bar, and panel widths.";
    const canResetSplitLayout = Boolean(workspace?.panels?.length > 1);
    const resetSplitAction = settingsActionButton("Reset split layout", resetActivePaneLayout, "", `split layout pane splitter resize reset equal ${canResetSplitLayout ? "" : "disabled no panes "}`);
    resetSplitAction.disabled = !canResetSplitLayout;
    resetSplitAction.title = canResetSplitLayout
      ? "Reset split sizes for the active workspace."
      : "Open another pane before resetting the split layout.";
    layoutActions.append(
      settingsActionButton(state.settings.focusMode ? "Leave focus" : "Focus mode", () => toggleFocusMode(), "", "focus mode simple clean hide chrome"),
      saveLayoutAction,
      settingsActionButton("Blueprints", () => openSettingsCategory("blueprints"), "", "open saved workspace blueprints layout templates"),
      resetSplitAction,
      resetChromeAction
    );
    layoutSection.append(layoutActions);
    layoutSection.append(paneLayoutPresetsDisclosurePanel());
    layoutSection.append(settingRow("Surface tabs", toggleInput(state.settings.showTabs, (checked) => updateSettings({ showTabs: checked }))));
    layoutSection.append(settingRow("Status bar", toggleInput(state.settings.showStatusbar, (checked) => updateSettings({ showStatusbar: checked }))));
    layoutSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked }))));
    nodes.push(layoutSection);
  }

  if (shouldBuildSection("performance")) {
    const performanceSection = settingsSection("Performance", "speed smooth lag render diagnostics optimize preset");
    performanceSection.append(performanceOverviewPanel());
    const performanceMetricGrid = settingsMetricGrid(performanceMetrics());
    performanceMetricGrid.dataset.performanceMetrics = "true";
    performanceSection.append(performanceMetricGrid);
    performanceSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked })), false, "speed smooth lag effects reduce animation"));
    performanceSection.append(settingRow("Adaptive guard", toggleInput(state.settings.adaptivePerformance, (checked) => updateSettings({ adaptivePerformance: checked })), false, "adaptive automatic performance guard lag slow output tune"));
    performanceSection.append(settingRow("Reduce motion", toggleInput(state.settings.reduceMotion, (checked) => updateSettings({ reduceMotion: checked })), false, "motion animation transition smooth reduce accessibility"));
    const startupSelect = document.createElement("select");
    startupSelect.className = "setting-select";
    startupSelect.dataset.settingControl = "terminalStartupMode";
    for (const [value, label] of terminalStartupOptions) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      startupSelect.append(option);
    }
    startupSelect.value = state.settings.terminalStartupMode;
    startupSelect.onchange = () => updateSettings({ terminalStartupMode: startupSelect.value });
    performanceSection.append(settingRow("Terminal startup", startupSelect, false, "terminal startup new pane load fast balanced workspace switching lag"));
    performanceSection.append(settingRow("Pause inactive output", toggleInput(state.settings.terminalPauseInactiveOutput, (checked) => updateSettings({ terminalPauseInactiveOutput: checked })), false, "terminal output pause inactive hidden background lag smooth performance"));
    performanceSection.append(settingRow("Smooth resumed output", toggleInput(state.settings.terminalSmoothResumedOutput, (checked) => updateSettings({ terminalSmoothResumedOutput: checked })), false, "terminal output resume hidden backlog smooth workspace switching lag performance"));
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
    performanceActions.dataset.settingsSearch = normalizeSettingsQuery("performance speed preset clean fast profile save current balanced reset render stats clear copy diagnostics report lag debug");
    const speedPresetActive = isSettingsPresetIdActive("performance");
    const speedPreset = settingsActionButton(
      speedPresetActive ? "Speed active" : "Speed preset",
      () => applySettingsPresetById("performance"),
      speedPresetActive ? "primary" : "",
      `performance speed preset optimize ${speedPresetActive ? "active current " : ""}`
    );
    speedPreset.disabled = speedPresetActive;
    speedPreset.title = speedPresetActive ? "Fast performance settings are already active." : "Apply the fast performance preset.";
    performanceActions.append(
      applySettingsProfileSaveLimit(
        settingsActionButton("Save clean + fast", applyAndSaveCleanFastProfile, "primary", "performance clean fast simple speed preset save settings profile reusable"),
        "Apply Clean + Fast and save it as a reusable profile."
      ),
      applySettingsProfileSaveLimit(
        settingsActionButton("Save current speed", saveCurrentPerformanceProfile, "", "performance save current speed lag settings profile reusable"),
        "Save current performance settings as a reusable profile."
      ),
      settingsActionButton("Copy diagnostics", copyPerformanceDiagnostics, "", "performance diagnostics report copy lag debug stats"),
      speedPreset,
      resetPerformanceStatsAction()
    );
    performanceSection.append(performanceActions);
    nodes.push(performanceSection);
  }

  if (shouldBuildSection("actions")) {
    const actionsSection = settingsSection("Actions", "commands shortcuts keyboard palette run tools");
    actionsSection.append(settingsActionsOverviewPanel());
    actionsSection.append(settingsCommandGroupShortcutGrid());
    actionsSection.append(settingsCommandListDisclosurePanel());
    nodes.push(actionsSection);
  }

  if (shouldBuildSection("commands")) {
    const snippetsSection = settingsSection("Command snippets", "terminal command snippets saved custom git github gh cli run add edit delete palette");
    snippetsSection.append(commandSnippetsDisclosurePanel());
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
    terminalSection.append(terminalFontDisclosurePanel());
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
    cursorSelect.dataset.settingControl = "terminalCursorStyle";
    for (const [value, label] of terminalCursorStyles) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      cursorSelect.append(option);
    }
    cursorSelect.value = state.settings.terminalCursorStyle;
    cursorSelect.onchange = () => updateSettings({ terminalCursorStyle: cursorSelect.value });
    terminalSection.append(settingRow("Cursor", cursorSelect, false, "terminal cursor line bar block underline powershell caret shape"));
    terminalSection.append(settingRow("Cursor blink", toggleInput(state.settings.terminalCursorBlink, (checked) => updateSettings({ terminalCursorBlink: checked }))));
    terminalSection.append(terminalColorDisclosurePanel());
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
    colorActions.dataset.settingsSearch = normalizeSettingsQuery("terminal color reset default background foreground cursor save terminal profile setup reusable");
    const terminalColorsReset = isTerminalColorPresetIdActive("cmux");
    const resetTerminalColors = settingsActionButton("Reset terminal colors", () => applyTerminalColorPresetById("cmux"), "", `terminal color reset default background foreground cursor ${terminalColorsReset ? "active current " : ""}`);
    resetTerminalColors.disabled = terminalColorsReset;
    resetTerminalColors.title = terminalColorsReset
      ? "Terminal colors already match the cmux default."
      : "Reset background, text, and cursor colors to the cmux default.";
    colorActions.append(
      applySettingsProfileSaveLimit(
        settingsActionButton("Save terminal profile", saveCurrentTerminalProfile, "primary", "terminal save profile setup font color cursor shell reusable"),
        "Save this terminal setup as a reusable Settings profile."
      ),
      resetTerminalColors
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
    const restartActions = document.createElement("div");
    restartActions.className = "settings-actions";
    restartActions.dataset.settingsSearch = normalizeSettingsQuery("terminal restart active shell reload");
    const restartTarget = activeTerminalPanelForSettings();
    const restart = settingsActionButton("Restart active terminal", restartSettingsTerminal, "", "terminal restart active shell reload");
    restart.disabled = !restartTarget;
    restart.title = restartTarget ? "Restart the active terminal pane." : "Focus or create a terminal pane before restarting.";
    restartActions.append(restart);
    terminalSection.append(restartActions);
    nodes.push(terminalSection);
  }

  if (shouldBuildSection("data")) {
    const actionsSection = settingsSection("Settings data");
    actionsSection.append(dataSettingsOverviewPanel());
    actionsSection.append(settingsMetricGrid(settingsDataMetrics(), "data storage local settings metric"));
    actionsSection.append(dataStorageBreakdownDisclosurePanel());
    const actions = document.createElement("div");
    actions.className = "settings-actions";
    const clearRecent = settingsActionButton("Clear recent activity", clearRecentActivity, "danger", "clear recent activity folders commands browser pages tabs history");
    const recentActivity = hasRecentActivity();
    clearRecent.disabled = !recentActivity;
    clearRecent.title = recentActivity ? "Clear recent folders, commands, browser pages, and saved browser tabs." : "Recent activity is already clear.";
    const closeEmpty = settingsActionButton("Close extra empty workspaces", closeEmptyWorkspaces, "danger", "workspace cleanup empty duplicate close remove");
    const emptyWorkspaceCleanupTargets = hasEmptyWorkspaceCleanupTargets();
    closeEmpty.disabled = !emptyWorkspaceCleanupTargets;
    closeEmpty.title = emptyWorkspaceCleanupTargets ? "Close empty workspaces except the active one." : "There are no extra empty workspaces to close.";
    actions.append(
      settingsActionButton("Export", exportSettings),
      settingsActionButton("Import", importSettings),
      closeEmpty,
      clearRecent,
      settingsActionButton("Reset", resetSettings, "danger")
    );
    actionsSection.append(actions);
    actionsSection.append(recentCommandsDisclosurePanel());
    nodes.push(actionsSection);
  }

  const empty = document.createElement("div");
  empty.className = "settings-empty";
  empty.textContent = t("settings.searchNoResults");
  empty.hidden = true;
  nodes.push(empty);

  unmountSettingsChrome();
  elements.inspectorBody.replaceChildren(...nodes);
  rebuildSettingsSearchIndex();
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

function settingsSearchFeedbackText() {
  if (!normalizeSettingsQuery(state.settingsQuery)) return t("settings.searchHint");
  return state.settingsSearchResultText || t("settings.searching");
}

function setSettingsSearchResultText(text) {
  state.settingsSearchResultText = String(text || "");
  const feedback = state.settingsSearchFeedback?.isConnected
    ? state.settingsSearchFeedback
    : elements.inspectorBody.querySelector("[data-settings-search-feedback]");
  state.settingsSearchFeedback = feedback || null;
  if (feedback) setTextIfChanged(feedback, settingsSearchFeedbackText());
}

function settingsSearchResultMessage(matchCount, sectionCount) {
  if (sectionCount <= 0) return t("settings.searchNoResults");
  const count = Math.max(0, Number(matchCount) || 0);
  const sections = Math.max(1, Number(sectionCount) || 0);
  return formatMessage("settings.searchResults", {
    count,
    matchLabel: t(count === 1 ? "settings.searchMatch" : "settings.searchMatches"),
    sectionCount: sections,
    sectionLabel: t(sections === 1 ? "settings.searchPage" : "settings.searchPages")
  });
}

function settingsInspectorSignature() {
  const category = state.settingsCategory;
  const searching = Boolean(normalizeSettingsQuery(state.settingsQuery));
  const parts = [
    category,
    state.settingsQuery,
    settingsInspectorSettingsSignature(category, searching)
  ];
  if (!searching && category === "data") {
    parts.push(dataSettingsSignature());
    return parts.join("\u001e");
  }
  if (searching || ["workspace", "layout", "blueprints", "performance", "actions"].includes(category)) {
    parts.push(activeWorkspaceSettingsSignature());
  } else if (category === "appearance") {
    parts.push(appearanceWorkspaceSettingsSignature());
  }
  if (searching || ["layout", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.paneLayouts), stableJson(state.paneTrees));
  }
  if (searching || category === "quick") {
    parts.push(quickSettingsSignature());
  }
  if (searching || ["appearance", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.customColorPalette), stableJson(state.savedBackgroundImages));
  }
  if (searching || ["browser", "data", "actions"].includes(category)) {
    parts.push(stableJson(state.recentBrowserPages), stableJson(state.browserTabSnapshots));
  }
  if (searching || category === "browser") {
    parts.push(stableJson(state.browserProfiles), String(state.browserProfilesLoaded), String(state.browserProfilesLoading));
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

function settingsInspectorSettingsSignature(category, searching) {
  if (searching || category === "actions") {
    return stableJson(state.settings);
  }
  if (category === "data") return "";
  if (category === "profiles") return settingsKeysSignature(profileSettingsSettingKeys);
  if (category === "quick") return settingsKeysSignature(quickSettingsSettingKeys);
  const keys = settingsInspectorSettingKeys[category];
  if (!keys) return "";
  return settingsKeysSignature(keys);
}

function settingsKeysSignature(keys) {
  const parts = [];
  appendSignatureArray(parts, keys, (nextParts, key) => {
    appendSignatureValue(nextParts, key);
    appendSignatureData(nextParts, state.settings[key]);
  });
  return parts.join("");
}

function activeWorkspaceSettingsSignature() {
  const workspace = activeWorkspace();
  if (!workspace) return "";
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.title);
  appendSignatureValue(parts, workspace.color);
  appendSignatureValue(parts, workspace.cwd);
  appendSignatureValue(parts, workspace.cwdShort);
  appendSignatureValue(parts, workspace.activePanelId);
  appendSignatureValue(parts, workspace.splitDirection);
  appendSignatureValue(parts, workspace.terminalCount);
  appendSignatureValue(parts, workspace.browserCount);
  appendSignatureValue(parts, zoomedPanelIdForWorkspace(workspace) || "");
  appendSignatureData(parts, state.paneTrees.get(workspace.id) || null);
  appendSignatureArray(parts, workspace.panels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureData(nextParts, state.paneLayouts.get(panel.id) || null);
  });
  appendSignatureArray(parts, workspace.panels, (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, panel.title);
    appendSignatureValue(nextParts, Boolean(panel.titleLocked));
    appendSignatureValue(nextParts, panel.color);
    appendSignatureValue(nextParts, panel.cwd);
    appendSignatureValue(nextParts, panel.cwdShort);
    appendSignatureValue(nextParts, panel.shellProfile);
    appendSignatureValue(nextParts, panel.shellPath);
    appendSignatureValue(nextParts, panel.terminalFontSize || 0);
    appendSignatureValue(nextParts, panel.backgroundImage || "");
    appendSignatureValue(nextParts, panel.url);
    appendSignatureValue(nextParts, isPanelMinimized(panel));
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
}

function appearanceWorkspaceSettingsSignature(workspace = activeWorkspace()) {
  if (!workspace) return "";
  const activeTerminal = activeTerminalPanelForSettings();
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.color);
  appendSignatureValue(parts, workspace.activePanelId);
  appendSignatureValue(parts, state.focusedPanelId || "");
  appendSignatureValue(parts, state.colorApplyTarget);
  appendSignatureValue(parts, state.backgroundApplyTarget);
  appendSignatureValue(parts, activeTerminal?.id || "");
  appendSignatureArray(parts, workspace.panels || [], (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, panel.title || "");
    appendSignatureValue(nextParts, panel.color || "");
    appendSignatureValue(nextParts, panel.type === "terminal" ? panel.backgroundImage || "" : "");
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
}

function quickSettingsSignature() {
  const panels = allPanels();
  const parts = [];
  appendSignatureValue(parts, quickWorkspaceSettingsSignature());
  appendSignatureValue(parts, state.data?.workspaces?.length || 0);
  appendSignatureValue(parts, panels.length);
  appendSignatureValue(parts, state.recentFolders.length);
  appendSignatureValue(parts, state.recentCommands.length);
  appendSignatureValue(parts, state.recentBrowserPages.length);
  appendSignatureValue(parts, browserTabSnapshotCount());
  appendSignatureValue(parts, state.customCommandSnippets.length);
  appendSignatureValue(parts, state.savedSettingsProfiles.length);
  appendSignatureValue(parts, state.workspaceBlueprints.length);
  appendSignatureValue(parts, state.customColorPalette.length);
  appendSignatureValue(parts, state.savedBackgroundImages.length);
  appendSignatureValue(parts, state.performanceGuardTriggered);
  return parts.join("");
}

function dataSettingsSignature() {
  const parts = [];
  appendSignatureValue(parts, recentDataItemCount());
  appendSignatureValue(parts, savedDataItemCount());
  appendSignatureValue(parts, state.data?.activeWorkspaceId || "");
  appendSignatureArray(parts, state.data?.workspaces || [], (nextParts, workspace) => {
    appendSignatureValue(nextParts, workspace.id);
    appendSignatureValue(nextParts, workspace.panels?.length || 0);
  });
  appendSignatureArray(parts, dataStorageEntries(), (nextParts, entry) => {
    appendSignatureValue(nextParts, entry.id);
    appendSignatureValue(nextParts, entry.count);
    appendSignatureValue(nextParts, entry.bytes);
  });
  appendSignatureArray(parts, state.recentCommands, appendSignatureValue);
  return parts.join("");
}

function quickWorkspaceSettingsSignature(workspace = activeWorkspace()) {
  if (!workspace) return "";
  const activeTerminal = activeTerminalPanelForSettings();
  const parts = [];
  appendSignatureValue(parts, workspace.id);
  appendSignatureValue(parts, workspace.title);
  appendSignatureValue(parts, workspace.color);
  appendSignatureValue(parts, workspace.cwdShort || workspace.cwd || "");
  appendSignatureValue(parts, workspace.activePanelId);
  appendSignatureValue(parts, paneLayoutDirection(workspace));
  appendSignatureValue(parts, workspace.terminalCount);
  appendSignatureValue(parts, workspace.browserCount);
  appendSignatureValue(parts, activePaneLayoutPercent(workspace));
  appendSignatureValue(parts, state.focusedPanelId || "");
  appendSignatureValue(parts, activeTerminal?.id || "");
  appendSignatureValue(parts, activeTerminal?.backgroundImage || "");
  appendSignatureArray(parts, workspace.panels || [], (nextParts, panel) => {
    appendSignatureValue(nextParts, panel.id);
    appendSignatureValue(nextParts, panel.type);
    appendSignatureValue(nextParts, panel.title || "");
    appendSignatureValue(nextParts, Boolean(panel.titleLocked));
    appendSignatureValue(nextParts, panel.color || "");
    appendSignatureValue(nextParts, panel.cwdShort || "");
    appendSignatureValue(nextParts, panel.type === "browser" ? panel.url || "" : "");
    appendSignatureValue(nextParts, panel.type === "terminal" ? panel.backgroundImage || "" : "");
    appendSignatureValue(nextParts, panel.type === "terminal" ? panel.terminalFontSize || 0 : 0);
    appendSignatureValue(nextParts, isPendingPanel(panel));
  });
  return parts.join("");
}

function stableJson(value) {
  try {
    const parts = [];
    appendSignatureData(parts, value ?? null);
    return parts.join("");
  } catch {
    return "";
  }
}

function shouldRefreshLayoutSettings() {
  return state.inspectorMode === "settings"
    && (
      state.settingsCategory === "layout"
      || state.settingsCategory === "workspace"
      || state.settingsCategory === "quick"
      || Boolean(normalizeSettingsQuery(state.settingsQuery))
    );
}

function refreshLayoutSettings(options = {}) {
  if (shouldRefreshLayoutSettings()) renderSettingsInspector(options);
}

function scheduleLayoutSettingsRefresh(options = {}) {
  if (shouldRefreshLayoutSettings()) scheduleSettingsInspectorRender(options);
}

function unmountSettingsChrome() {
  const reactSettings = window.CmuxSettingsUi;
  if (!reactSettings?.unmountSettingsShell) return;
  for (const host of elements.inspectorBody.querySelectorAll(".settings-react-host")) {
    reactSettings.unmountSettingsShell(host);
  }
}

function refreshSettingsChromeRefs(root = elements.inspectorBody) {
  state.settingsSearchClear = root.querySelector(".settings-search-clear");
  state.settingsSearchFeedback = root.querySelector("[data-settings-search-feedback]");
}

function renderSettingsChrome(host) {
  const reactSettings = window.CmuxSettingsUi;
  const focusSearchOnMount = state.settingsSearchFocusPending;
  state.settingsSearchFocusPending = false;
  if (!reactSettings?.renderSettingsShell) {
    host.replaceChildren(settingsSearch(), settingsCategoryNav());
    refreshSettingsChromeRefs(host);
    if (focusSearchOnMount) restoreSettingsSearchFocus();
    return;
  }
  reactSettings.renderSettingsShell(host, {
    activeCategory: state.settingsCategory,
    categories: settingsCategories,
    focusSearchOnMount,
    query: state.settingsQuery,
    searchFeedback: settingsSearchFeedbackText(),
    subtitle: elements.inspectorSubtitle.textContent,
    labels: {
      searchPlaceholder: t("settings.searchPlaceholder"),
      clearSearch: t("settings.clearSearch"),
      searchHint: t("settings.searchHint"),
      pageLabel: t("settings.pageLabel"),
      pageAriaLabel: t("settings.pageAriaLabel"),
      pagesAriaLabel: t("settings.pagesAriaLabel"),
      tabTitle: formatMessage("settings.tabTitle", { label: "{label}" })
    },
    onCategory: (category) => {
      state.settingsCategory = category;
      state.settingsQuery = "";
      state.settingsSearchResultText = "";
      renderSettingsInspector({ resetScroll: true });
    },
    onQuery: (query) => {
      const wasSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      state.settingsQuery = query;
      const isSearching = Boolean(normalizeSettingsQuery(state.settingsQuery));
      state.settingsSearchResultText = isSearching ? t("settings.searching") : "";
      if (isSearching) queueSettingsSearchAutoScroll();
      if (wasSearching !== isSearching) {
        state.settingsSearchFocusPending = true;
        scheduleSettingsInspectorRender({ resetScroll: true });
      } else {
        renderSettingsChrome(host);
        scheduleSettingsFilter();
      }
    },
    onClear: () => {
      state.settingsQuery = "";
      state.settingsSearchResultText = "";
      state.settingsSearchFocusPending = true;
      scheduleSettingsInspectorRender({ resetScroll: true });
    }
  });
  refreshSettingsChromeRefs(host);
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
    state.settingsSearchResultText = isSearching ? t("settings.searching") : "";
    setSettingsSearchResultText(state.settingsSearchResultText);
    if (isSearching) queueSettingsSearchAutoScroll();
    if (wasSearching !== isSearching) {
      state.settingsSearchFocusPending = true;
      scheduleSettingsInspectorRender({ resetScroll: true });
      return;
    }
    scheduleSettingsFilter();
  });
  const clear = document.createElement("button");
  clear.className = "settings-search-clear";
  clear.type = "button";
  clear.title = t("settings.clearSearch");
  clear.setAttribute("aria-label", t("settings.clearSearch"));
  clear.innerHTML = controlIconMarkup("close");
  clear.disabled = !state.settingsQuery;
  clear.onclick = () => {
    state.settingsQuery = "";
    state.settingsSearchResultText = "";
    state.settingsSearchFocusPending = true;
    scheduleSettingsInspectorRender({ resetScroll: true });
  };
  const feedback = document.createElement("div");
  feedback.className = "settings-search-feedback";
  feedback.dataset.settingsSearchFeedback = "true";
  feedback.setAttribute("aria-live", "polite");
  feedback.textContent = settingsSearchFeedbackText();
  wrapper.append(input, clear, feedback);
  return wrapper;
}

function restoreSettingsSearchFocus() {
  const input = elements.inspectorBody.querySelector(".settings-search-input");
  if (!input) return;
  input.focus({ preventScroll: true });
  input.setSelectionRange(input.value.length, input.value.length);
}

function settingsCategoryIconName(id) {
  return {
    actions: "actions",
    appearance: "appearance",
    blueprints: "blueprints",
    browser: "browser",
    commands: "commands",
    data: "data",
    layout: "layout",
    performance: "performance",
    profiles: "profiles",
    quick: "quick",
    terminal: "terminal",
    workspace: "workspace"
  }[id] || "quick";
}

function settingsCategoryIconMarkup(id) {
  return quickActionIconMarkup(settingsCategoryIconName(id));
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
    button.title = formatMessage("settings.tabTitle", { label });
    button.dataset.settingsCategory = id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`settings page ${label} ${id} ${settingsCategorySearchAliases.get(id) || ""}`);
    button.setAttribute("role", "tab");
    button.setAttribute("aria-selected", active ? "true" : "false");
    const icon = document.createElement("span");
    icon.className = "settings-page-tab-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.innerHTML = settingsCategoryIconMarkup(id);
    const text = document.createElement("span");
    text.className = "settings-page-tab-label";
    text.textContent = label;
    button.append(icon, text);
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
  opacityInput.dataset.settingControl = "backgroundOpacity";
  const opacityRow = document.createElement("label");
  opacityRow.className = "background-tuning-row background-tuning-row-wide";
  const opacityLabel = document.createElement("span");
  opacityLabel.className = "setting-label";
  opacityLabel.textContent = `Strength ${state.settings.backgroundOpacity}%`;
  opacityRow.append(opacityLabel, opacityInput);
  bindDeferredSettingRange(opacityInput, opacityRow, {
    settingKey: "backgroundOpacity",
    formatLabel: (value) => `Strength ${value}%`,
    preview: (value) => {
      elements.shell.style.setProperty("--background-opacity", String(value / 100));
      refreshAppearancePreviewOpacity(value);
    }
  });

  panel.append(controls, opacityRow);
  return panel;
}

function activeBackgroundTargetControl() {
  const control = document.createElement("div");
  control.className = "background-target-control background-image-target-control";
  control.dataset.settingsSearch = normalizeSettingsQuery("background image target apply app active terminal all terminals scope destination current status mixed none");

  const header = document.createElement("span");
  header.className = "background-target-header";
  const label = document.createElement("span");
  label.className = "background-target-label";
  label.textContent = "Image target";
  const current = document.createElement("span");
  current.className = "background-target-current";
  header.append(label, current);

  const options = document.createElement("div");
  options.className = "background-target-options";
  for (const target of backgroundApplyTargetOptions()) {
    const button = document.createElement("button");
    button.className = "background-target-option";
    button.type = "button";
    button.dataset.backgroundTarget = target.id;
    const icon = backgroundTargetIconMarkup(target.id);
    button.innerHTML = `
      <span class="background-target-icon" aria-hidden="true">${icon}</span>
      <span class="background-target-copy">
        <span class="background-target-name"></span>
        <span class="background-target-meta"></span>
        <span class="background-target-status"></span>
      </span>
    `;
    button.onclick = () => {
      selectBackgroundApplyTarget(button.dataset.backgroundTarget);
    };
    options.append(button);
  }
  control.append(header, options);
  updateActiveBackgroundTargetControl(control);
  return control;
}

function updateActiveBackgroundTargetControl(root) {
  const options = backgroundApplyTargetOptions();
  const selected = backgroundApplyTargetOption(state.backgroundApplyTarget);
  setTextIfChanged(root.querySelector(".background-target-current"), `${selected.label} / ${selected.meta}`);
  for (const button of root.querySelectorAll("[data-background-target]")) {
    const target = options.find((candidate) => candidate.id === button.dataset.backgroundTarget);
    if (!target) continue;
    const model = activeBackgroundPanelViewModel(target.id);
    const active = target.id === normalizeBackgroundApplyTarget(state.backgroundApplyTarget);
    setClassNameIfChanged(button, [
      "background-target-option",
      active ? "is-active" : "",
      target.disabled ? "is-disabled" : "",
      model.hasBackground ? "has-background" : "",
      model.mixed ? "is-mixed" : ""
    ].filter(Boolean).join(" "));
    setDisabledIfChanged(button, target.disabled);
    setAttributeIfChanged(button, "aria-pressed", active ? "true" : "false");
    setAttributeIfChanged(button, "aria-label", `${target.label}: ${target.meta}. ${model.label}.`);
    setTitleIfChanged(button, `${target.label}: ${model.source}`);
    setStylePropertyIfChanged(button, "--target-background-image", model.image);
    setStylePropertyIfChanged(button, "--target-background-repeat", model.repeat);
    setStylePropertyIfChanged(button, "--target-background-size", model.size);
    setStylePropertyIfChanged(button, "--target-background-position", model.position);
    setTextIfChanged(button.querySelector(".background-target-name"), target.label);
    setTextIfChanged(button.querySelector(".background-target-meta"), target.meta);
    setTextIfChanged(button.querySelector(".background-target-status"), model.label);
  }
}

function activeBackgroundTargetStatus(target = state.backgroundApplyTarget, workspace = activeWorkspace()) {
  const scope = normalizeBackgroundApplyTarget(target);
  const activeTerminal = activeTerminalPanelForSettings();
  const terminalPanels = workspaceTerminalPanels(workspace);
  const paneBackgrounds = terminalPanels.filter((panel) => normalizeBackgroundValue(panel.backgroundImage));
  return {
    scope,
    canTarget: scope === "app" || (scope === "pane" ? Boolean(activeTerminal) : terminalPanels.length > 0),
    hasValue: scope === "app"
      ? Boolean(state.settings.backgroundImage)
      : scope === "pane"
        ? Boolean(activeTerminal && normalizeBackgroundValue(activeTerminal.backgroundImage))
        : paneBackgrounds.length > 0
  };
}

function backgroundSourceText(background, emptyText = "Drop an image here, paste one, or choose a local file.") {
  const normalized = normalizeBackgroundValue(background);
  if (!normalized) return emptyText;
  const preset = backgroundPresetMap.get(normalized);
  return preset ? "Built-in preset" : backgroundFilePath(background) || normalized;
}

function activeBackgroundPanelViewModel(target = state.backgroundApplyTarget, workspace = activeWorkspace()) {
  const scope = normalizeBackgroundApplyTarget(target);
  const activeTerminal = activeTerminalPanelForSettings();
  const terminalPanels = workspaceTerminalPanels(workspace);
  let background = "";
  let kicker = "App background";
  let emptySource = "Drop an image here, paste one, or choose a local file.";
  let mixed = false;

  if (scope === "pane") {
    kicker = "Active terminal background";
    background = activeTerminal?.backgroundImage || "";
    emptySource = activeTerminal ? "No background on the active terminal." : "Select a terminal pane first.";
  } else if (scope === "all") {
    kicker = "All terminal backgrounds";
    emptySource = terminalPanels.length ? "No terminal backgrounds in this workspace." : "Open a terminal pane first.";
    const backgrounds = terminalPanels
      .map((panel) => normalizeBackgroundValue(panel.backgroundImage))
      .filter(Boolean);
    const uniqueBackgrounds = [...new Set(backgrounds)];
    if (uniqueBackgrounds.length === 1 && backgrounds.length === terminalPanels.length) {
      background = uniqueBackgrounds[0];
    } else if (uniqueBackgrounds.length > 0) {
      mixed = true;
    }
  } else {
    background = state.settings.backgroundImage;
  }

  const normalized = normalizeBackgroundValue(background);
  const hasBackground = Boolean(normalized);
  return {
    background,
    hasBackground,
    mixed,
    kicker,
    label: mixed ? "Mixed terminal backgrounds" : hasBackground ? appearanceBackgroundLabel(background) : "None",
    source: mixed ? "Terminal panes have different backgrounds." : backgroundSourceText(background, emptySource),
    image: mixed ? "none" : backgroundCss(background),
    repeat: mixed ? "no-repeat" : backgroundRepeatCss(background),
    size: backgroundSizeCss(state.settings.backgroundFit),
    position: backgroundPositionCss(state.settings.backgroundPosition)
  };
}

function activeBackgroundScopeSnapshot() {
  const snapshot = document.createElement("span");
  snapshot.className = "active-background-snapshot";
  snapshot.setAttribute("aria-label", "Background target status");
  for (const target of ["app", "pane", "all"]) {
    const item = document.createElement("button");
    item.className = "active-background-snapshot-item";
    item.type = "button";
    item.dataset.backgroundSnapshotTarget = target;
    item.innerHTML = `
      <span class="active-background-snapshot-preview" aria-hidden="true"></span>
      <span class="active-background-snapshot-copy">
        <span class="active-background-snapshot-label"></span>
        <span class="active-background-snapshot-value"></span>
      </span>
    `;
    item.onclick = () => selectBackgroundApplyTarget(item.dataset.backgroundSnapshotTarget);
    snapshot.append(item);
  }
  updateActiveBackgroundScopeSnapshot(snapshot);
  return snapshot;
}

function updateActiveBackgroundScopeSnapshot(snapshot, workspace = activeWorkspace()) {
  if (!snapshot) return;
  const selectedTarget = normalizeBackgroundApplyTarget(state.backgroundApplyTarget);
  for (const button of snapshot.querySelectorAll("[data-background-snapshot-target]")) {
    const target = normalizeBackgroundApplyTarget(button.dataset.backgroundSnapshotTarget);
    const option = backgroundApplyTargetOption(target, workspace);
    const model = activeBackgroundPanelViewModel(target, workspace);
    const selected = target === selectedTarget;
    setClassNameIfChanged(button, [
      "active-background-snapshot-item",
      selected ? "is-selected" : "",
      model.hasBackground ? "has-image" : "",
      model.mixed ? "is-mixed" : "",
      option.disabled ? "is-disabled" : ""
    ].filter(Boolean).join(" "));
    setDisabledIfChanged(button, option.disabled);
    setAttributeIfChanged(button, "aria-pressed", selected ? "true" : "false");
    setAttributeIfChanged(button, "aria-label", `${option.label}: ${model.label}. ${model.source}`);
    setTitleIfChanged(button, `${option.label}: ${model.source}`);
    setStylePropertyIfChanged(button, "--snapshot-background-image", model.image);
    setStylePropertyIfChanged(button, "--snapshot-background-repeat", model.repeat);
    setStylePropertyIfChanged(button, "--snapshot-background-size", model.size);
    setStylePropertyIfChanged(button, "--snapshot-background-position", model.position);
    setTextIfChanged(button.querySelector(".active-background-snapshot-label"), option.label);
    setTextIfChanged(button.querySelector(".active-background-snapshot-value"), model.label);
  }
}

function activeBackgroundPanel(options = {}) {
  const panel = document.createElement("div");
  const model = activeBackgroundPanelViewModel();
  panel.className = `active-background-panel${model.hasBackground ? " has-image" : ""}`;
  panel.dataset.activeBackgroundTuning = options.tuning ? "true" : "false";
  panel.dataset.settingsSearch = normalizeSettingsQuery("active background image wallpaper current preview source choose save open clear fit position effects opacity strength transparency tune");
  panel.style.setProperty("--active-background-image", model.image);
  panel.style.setProperty("--active-background-repeat", model.repeat);
  panel.style.setProperty("--active-background-size", model.size);
  panel.style.setProperty("--active-background-position", model.position);
  panel.innerHTML = `
    <button class="active-background-preview" type="button" title="Choose background image"></button>
    <span class="active-background-copy">
      <span class="active-background-kicker">Active background</span>
      <span class="active-background-title"></span>
      <span class="active-background-source"></span>
    </span>
    <span class="active-background-actions"></span>
  `;
  panel.querySelector(".active-background-kicker").textContent = model.kicker;
  panel.querySelector(".active-background-title").textContent = model.label;
  panel.querySelector(".active-background-title").title = model.label;
  panel.querySelector(".active-background-source").textContent = model.source;
  panel.querySelector(".active-background-source").title = model.source;
  panel.querySelector(".active-background-copy").append(activeBackgroundScopeSnapshot());
  const actions = panel.querySelector(".active-background-actions");
  panel.insertBefore(activeBackgroundTargetControl(), actions);
  const targetStatus = activeBackgroundTargetStatus();
  const targetLabel = backgroundApplyTargetActionLabel(targetStatus.scope);
  const preview = panel.querySelector(".active-background-preview");
  preview.onclick = () => chooseBackgroundImageForTarget();
  preview.title = `Choose image for ${targetLabel}`;
  preview.setAttribute("aria-label", `Choose image for ${targetLabel}.`);

  const imageInput = document.createElement("input");
  imageInput.className = "setting-control active-background-input";
  imageInput.value = isBackgroundPreset(model.background) ? "" : model.background || "";
  imageInput.placeholder = "Image URL or C:\\path\\image.png";
  imageInput.dataset.settingsSearch = normalizeSettingsQuery("active background image url local path file apply selected target wallpaper");
  const applyTypedImage = (showToast = true) => withDisabledControl(imageInput, async () => {
    const next = imageInput.value.trim();
    if (!next) {
      if (showToast) toast("Enter an image URL or local path first.");
      return null;
    }
    const changed = await applyBackgroundValueToTarget(next, state.backgroundApplyTarget, {
      resetInput: imageInput,
      render: false,
      toast: showToast
    });
    if (changed !== null) renderSettingsInspector();
    return changed;
  });
  imageInput.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    applyTypedImage(true);
  });
  const applyTyped = settingsActionButton(backgroundApplyTargetPrimaryLabel(targetStatus.scope), () => applyTypedImage(true), "primary", "active background image url local path apply selected target wallpaper");
  applyTyped.dataset.backgroundAction = "apply-typed";
  applyTyped.title = `Apply entered image to ${targetLabel}`;
  applyTyped.disabled = !targetStatus.canTarget;
  const inputRow = document.createElement("span");
  inputRow.className = "active-background-input-row";
  inputRow.append(imageInput, applyTyped);
  panel.insertBefore(inputRow, actions);
  installBackgroundDropTarget(panel, { input: imageInput, applyTarget: () => state.backgroundApplyTarget });

  const choose = settingsActionButton("Choose file", () => chooseBackgroundImageForTarget(), "", "active background choose local file apply wallpaper");
  choose.dataset.backgroundAction = "choose";
  choose.title = `Choose an image for ${targetLabel}`;
  choose.disabled = !targetStatus.canTarget;
  const paste = settingsActionButton("Paste", () => pasteBackgroundImageFromClipboard({ target: () => state.backgroundApplyTarget }), "", "active background paste clipboard image url local path apply");
  paste.dataset.backgroundAction = "paste";
  paste.title = `Paste an image for ${targetLabel}`;
  paste.disabled = !targetStatus.canTarget;
  const save = settingsActionButton("Save image", () => saveCustomBackgroundImage({ url: activeBackgroundPanelViewModel().background }), "", "active background save current");
  save.dataset.backgroundAction = "save";
  applySavedBackgroundImageSaveLimit(save, model.background, "Save the selected background image.");
  const open = settingsActionButton("Open", () => openBackgroundImageSource(activeBackgroundPanelViewModel().background), "", "active background open local file url source reveal");
  open.dataset.backgroundAction = "open";
  open.title = "Open the selected background source";
  open.disabled = !canOpenBackgroundImageSource(model.background);
  const imageGroup = backgroundActionGroup("Image", "active background image choose paste save open", [choose, paste, save, open]);
  imageGroup.classList.add("background-action-group-image");

  const applyCurrent = settingsActionButton("Use app image", applyCurrentBackgroundToTarget, "", "active background apply current app image to selected target pane all terminals");
  applyCurrent.dataset.backgroundAction = "apply-current";
  applyCurrent.title = `Use the whole-app background on ${targetLabel}`;
  applyCurrent.disabled = !state.settings.backgroundImage || !targetStatus.canTarget || targetStatus.scope === "app";
  const clear = settingsActionButton(backgroundApplyTargetClearLabel(targetStatus.scope), clearBackgroundApplyTarget, "danger", "active background clear selected target app pane all terminals");
  clear.dataset.backgroundAction = "clear";
  clear.title = `Clear ${targetLabel}`;
  clear.disabled = !targetStatus.canTarget || !targetStatus.hasValue;
  const scopeGroup = backgroundActionGroup("Target", "active background selected target app pane all terminals use app clear", [applyCurrent, clear]);
  scopeGroup.classList.add("background-action-group-scope");
  actions.append(imageGroup, scopeGroup);
  if (options.tuning) {
    const refreshBackgroundSummary = () => {
      const nextModel = activeBackgroundPanelViewModel();
      panel.style.setProperty("--active-background-size", backgroundSizeCss(state.settings.backgroundFit));
      panel.style.setProperty("--active-background-position", backgroundPositionCss(state.settings.backgroundPosition));
      panel.querySelector(".active-background-title").textContent = nextModel.label;
      panel.querySelector(".active-background-title").title = nextModel.label;
    };
    panel.append(backgroundTuningPanel(refreshBackgroundSummary));
  }
  return panel;
}

function backgroundActionGroup(title, searchTerms, buttons = []) {
  const group = document.createElement("span");
  group.className = "background-action-group";
  group.dataset.settingsSearch = normalizeSettingsQuery(`${title} ${searchTerms}`);
  const label = document.createElement("span");
  label.className = "background-action-title";
  label.textContent = title;
  group.append(label, ...buttons.filter(Boolean));
  return group;
}

function activeBackgroundViewModel(settings = state.settings) {
  const background = settings.backgroundImage;
  const normalized = normalizeBackgroundValue(background);
  const hasBackground = Boolean(normalized);
  const preset = backgroundPresetMap.get(normalized);
  const filePath = backgroundFilePath(background);
  return {
    background,
    hasBackground,
    label: hasBackground ? appearanceBackgroundLabel(background) : "None",
    source: !hasBackground
      ? "Drop an image here, paste one, or choose a local file."
      : preset
        ? "Built-in preset"
        : filePath || normalized,
    image: backgroundCss(background),
    repeat: backgroundRepeatCss(background),
    size: backgroundSizeCss(settings.backgroundFit),
    position: backgroundPositionCss(settings.backgroundPosition)
  };
}

function activeBackgroundScopeModel(background = state.settings.backgroundImage, workspace = activeWorkspace()) {
  const normalized = normalizeBackgroundValue(background);
  const terminalPanels = workspaceTerminalPanels(workspace);
  const activeTerminal = activeTerminalPanelForSettings();
  const hasBackground = Boolean(normalized);
  const activePaneMatches = hasBackground && Boolean(activeTerminal && panelBackgroundMatches(activeTerminal, normalized));
  const allPanesMatch = hasBackground
    && terminalPanels.length > 0
    && terminalPanels.every((panel) => panelBackgroundMatches(panel, normalized));
  const paneCount = terminalPanels.length;
  return {
    app: hasBackground ? "Active" : "None",
    pane: activeTerminal
      ? activePaneMatches
        ? "Matches"
        : hasBackground
          ? "Different"
          : "No app image"
      : "No terminal",
    all: paneCount
      ? allPanesMatch
        ? `All ${paneCount}`
        : `${paneCount} available`
      : "No terminals",
    hasBackground,
    activePaneMatches,
    allPanesMatch,
    hasTerminal: Boolean(activeTerminal),
    paneCount
  };
}

function refreshAppearancePreviewOpacity(value = state.settings.backgroundOpacity) {
  const opacity = String(clamp(value, 0, 42) / 100);
  for (const preview of elements.inspectorBody.querySelectorAll(".appearance-preview")) {
    preview.style.setProperty("--preview-background-opacity", opacity);
  }
}

function refreshBackgroundPreviewNodes() {
  const appModel = activeBackgroundViewModel();
  for (const preview of elements.inspectorBody.querySelectorAll(".appearance-preview")) {
    preview.style.setProperty("--preview-background-image", appModel.image);
    preview.style.setProperty("--preview-background-opacity", String(state.settings.backgroundOpacity / 100));
    preview.style.setProperty("--preview-background-size", appModel.size);
    preview.style.setProperty("--preview-background-repeat", appModel.repeat);
    preview.style.setProperty("--preview-background-position", appModel.position);
    setTextIfChanged(preview.querySelector("[data-preview-background]"), appearanceBackgroundLabel(state.settings.backgroundImage));
  }
  for (const panel of elements.inspectorBody.querySelectorAll(".active-background-panel")) {
    const workspace = activeWorkspace();
    const model = activeBackgroundPanelViewModel(state.backgroundApplyTarget, workspace);
    toggleClassIfChanged(panel, "has-image", model.hasBackground);
    panel.style.setProperty("--active-background-image", model.image);
    panel.style.setProperty("--active-background-repeat", model.repeat);
    panel.style.setProperty("--active-background-size", model.size);
    panel.style.setProperty("--active-background-position", model.position);
    const kicker = panel.querySelector(".active-background-kicker");
    const title = panel.querySelector(".active-background-title");
    const source = panel.querySelector(".active-background-source");
    setTextIfChanged(kicker, model.kicker);
    setTextIfChanged(title, model.label);
    setTextIfChanged(source, model.source);
    if (title) title.title = model.label;
    if (source) source.title = model.source;
    updateActiveBackgroundScopeSnapshot(panel.querySelector(".active-background-snapshot"), workspace);
    updateActiveBackgroundTargetControl(panel);
    const targetStatus = activeBackgroundTargetStatus(state.backgroundApplyTarget, workspace);
    const targetLabel = backgroundApplyTargetActionLabel(targetStatus.scope);
    const choose = panel.querySelector('[data-background-action="choose"]');
    const paste = panel.querySelector('[data-background-action="paste"]');
    const save = panel.querySelector('[data-background-action="save"]');
    const applyTyped = panel.querySelector('[data-background-action="apply-typed"]');
    const applyCurrent = panel.querySelector('[data-background-action="apply-current"]');
    const open = panel.querySelector('[data-background-action="open"]');
    const clear = panel.querySelector('[data-background-action="clear"]');
    const input = panel.querySelector(".active-background-input");
    if (input && document.activeElement !== input) {
      const nextValue = isBackgroundPreset(model.background) ? "" : model.background || "";
      if (input.value !== nextValue) input.value = nextValue;
    }
    if (applyTyped) {
      setDisabledIfChanged(applyTyped, !targetStatus.canTarget);
      setTitleIfChanged(applyTyped, `Apply entered image to ${targetLabel}`);
      setSettingsActionLabel(applyTyped, backgroundApplyTargetPrimaryLabel(targetStatus.scope));
    }
    if (choose) {
      setDisabledIfChanged(choose, !targetStatus.canTarget);
      setTitleIfChanged(choose, `Choose an image for ${targetLabel}`);
    }
    if (paste) {
      setDisabledIfChanged(paste, !targetStatus.canTarget);
      setTitleIfChanged(paste, `Paste an image for ${targetLabel}`);
    }
    if (save) {
      applySavedBackgroundImageSaveLimit(save, model.background, "Save the selected background image.");
    }
    if (applyCurrent) {
      setDisabledIfChanged(applyCurrent, !state.settings.backgroundImage || !targetStatus.canTarget || targetStatus.scope === "app");
      setTitleIfChanged(applyCurrent, `Use the whole-app background on ${targetLabel}`);
    }
    if (open) {
      setDisabledIfChanged(open, !canOpenBackgroundImageSource(model.background));
      setTitleIfChanged(open, "Open the selected background source");
    }
    if (clear) {
      setDisabledIfChanged(clear, !targetStatus.canTarget || !targetStatus.hasValue);
      setTitleIfChanged(clear, `Clear ${targetLabel}`);
      setSettingsActionLabel(clear, backgroundApplyTargetClearLabel(targetStatus.scope));
    }
    for (const control of panel.querySelectorAll("[data-setting-control]")) {
      const key = control.dataset.settingControl;
      if (!Object.hasOwn(state.settings, key)) continue;
      const value = String(state.settings[key]);
      if (control.value !== value) control.value = value;
      if (key === "backgroundOpacity") {
        setTextIfChanged(control.closest(".background-tuning-row")?.querySelector(".setting-label"), `Strength ${value}%`);
      }
    }
  }
  updateBackgroundCustomActionLabels(elements.inspectorBody, activeWorkspace());
  if (normalizeSettingsQuery(state.settingsQuery)) scheduleSettingsFilter();
}

function refreshBackgroundLibraryPanels() {
  for (const grid of elements.inspectorBody.querySelectorAll(".background-preset-grid")) {
    grid.replaceWith(backgroundPresetGrid());
  }
  for (const panel of elements.inspectorBody.querySelectorAll(".saved-background-panel")) {
    const draft = panel.querySelector(".saved-background-input")?.value || "";
    const replacement = savedBackgroundImagesPanel();
    const input = replacement.querySelector(".saved-background-input");
    if (input && draft) input.value = draft;
    panel.replaceWith(replacement);
  }
}

function scheduleBackgroundPreviewRefresh() {
  if (state.backgroundPreviewFrame) return;
  state.backgroundPreviewFrame = requestAnimationFrame(() => {
    state.backgroundPreviewFrame = 0;
    refreshBackgroundPreviewNodes();
  });
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
    const status = button.querySelector(".theme-choice-status");
    if (status) setTextIfChanged(status, active ? "Active" : "");
    const theme = themePreviewOptions.find((candidate) => candidate.id === button.dataset.themeChoice);
    if (theme) {
      const label = optionLabel(themeOptions, theme.id, theme.id);
      const search = normalizeSettingsQuery(`theme visual gallery preview ${active ? "active current " : ""}${label} ${theme.id}`);
      if (button.dataset.settingsSearch !== search) {
        button.dataset.settingsSearch = search;
        updateSettingsSearchIndexItemSearch(button, search);
      }
    }
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
    button.dataset.settingsSearch = normalizeSettingsQuery(`theme visual gallery preview ${active ? "active current " : ""}${label} ${theme.id}`);
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
      <span class="theme-choice-label-row">
        <span class="theme-choice-label"></span>
        <span class="theme-choice-status"></span>
      </span>
    `;
    button.querySelector(".theme-choice-label").textContent = label;
    button.querySelector(".theme-choice-status").textContent = active ? "Active" : "";
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
    `add-tabs-${settings.addTabStyle}`,
    settings.focusMode ? "focus-mode" : "",
    settings.showTabs ? "show-tabs" : "hide-tabs",
    settings.showStatusbar ? "show-statusbar" : "hide-statusbar",
    settings.performanceMode ? "performance-preview" : ""
  ].filter(Boolean).join(" ");
  panel.dataset.settingsSearch = normalizeSettingsQuery("layout preview workspace chrome sidebar toolbar tabs status pane header density settings panel active pane percent resize focus mode simple clean panes split shape preset current");
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
      <span><b>Add tabs</b><em data-layout-preview-add-tabs></em></span>
      <span><b>Header</b><em data-layout-preview-header></em></span>
      <span><b>Controls</b><em data-layout-preview-actions></em></span>
      <span><b>Sidebar</b><em data-layout-preview-sidebar></em></span>
      <span><b>Settings</b><em data-layout-preview-settings></em></span>
      <span><b>Status</b><em data-layout-preview-status></em></span>
      <span><b>Active pane</b><em data-layout-preview-active-pane></em></span>
      <span><b>Panes</b><em data-layout-preview-panes></em></span>
      <span><b>Split</b><em data-layout-preview-split></em></span>
      <span><b>Shape</b><em data-layout-preview-shape></em></span>
    </div>
  `;
  panel.querySelector("[data-layout-preview-toolbar]").textContent = optionLabel(toolbarModeOptions, settings.toolbarMode, settings.toolbarMode);
  panel.querySelector("[data-layout-preview-mode]").textContent = settings.focusMode ? "Focus" : "Standard";
  panel.querySelector("[data-layout-preview-tabs]").textContent = settings.focusMode || !settings.showTabs ? "Hidden" : optionLabel(tabSizeOptions, settings.tabSize, settings.tabSize);
  panel.querySelector("[data-layout-preview-add-tabs]").textContent = settings.focusMode || !settings.showTabs ? "Hidden" : optionLabel(addTabStyleOptions, settings.addTabStyle, settings.addTabStyle);
  panel.querySelector("[data-layout-preview-header]").textContent = settings.focusMode ? "Hidden" : optionLabel(paneHeaderOptions, settings.paneHeaderMode, settings.paneHeaderMode);
  panel.querySelector("[data-layout-preview-actions]").textContent = optionLabel(paneActionOptions, settings.paneActionMode, settings.paneActionMode);
  panel.querySelector("[data-layout-preview-sidebar]").textContent = settings.focusMode ? "Hidden" : `${settings.sidebarWidth}px`;
  panel.querySelector("[data-layout-preview-settings]").textContent = `${settings.inspectorWidth}px`;
  panel.querySelector("[data-layout-preview-status]").textContent = settings.focusMode || !settings.showStatusbar ? "Off" : "On";
  const workspace = activeWorkspace();
  panel.querySelector("[data-layout-preview-active-pane]").textContent = workspace?.panels?.length > 1 ? `${activePaneLayoutPercent(workspace)}%` : "Single";
  panel.querySelector("[data-layout-preview-panes]").textContent = workspace?.panels?.length ? String(workspace.panels.length) : "None";
  panel.querySelector("[data-layout-preview-split]").textContent = workspace?.panels?.length > 1 ? paneLayoutDirectionLabel(workspace) : "Single";
  panel.querySelector("[data-layout-preview-shape]").textContent = activePaneLayoutPresetLabel(workspace);
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
      <span><b>Profile</b><em data-browser-preview-profile></em></span>
      <span><b>Host</b><em data-browser-preview-host-meta></em></span>
      <span><b>Recent</b><em data-browser-preview-recent></em></span>
    </div>
  `;
  panel.querySelector("[data-browser-preview-host]").textContent = home.host;
  panel.querySelector("[data-browser-preview-url]").textContent = home.url;
  panel.querySelector(".browser-preview-title").textContent = home.path;
  panel.querySelector("[data-browser-preview-home]").textContent = home.url;
  panel.querySelector("[data-browser-preview-launch]").textContent = optionLabel(browserLaunchModeOptions, state.settings.browserLaunchMode, "cmux pane");
  panel.querySelector("[data-browser-preview-profile]").textContent = browserProfileLabel();
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
    button.dataset.settingsSearch = normalizeSettingsQuery(`browser home preset ${active ? "active current " : ""}${preset.label} ${preset.body} ${preset.url}`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.innerHTML = `
      <span class="browser-home-preset-title-row">
        <span class="browser-home-preset-title"></span>
        <span class="browser-home-preset-status"></span>
      </span>
      <span class="browser-home-preset-body"></span>
      <span class="browser-home-preset-url"></span>
    `;
    button.querySelector(".browser-home-preset-title").textContent = preset.label;
    button.querySelector(".browser-home-preset-status").textContent = active ? "Active" : "";
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

function resetBrowserHome() {
  const changed = updateSettings({ browserHomeUrl: defaultSettings.browserHomeUrl });
  if (!changed) {
    toast("Browser home already uses the default.");
    return false;
  }
  if (state.inspectorMode === "settings" && state.settingsCategory === "browser") renderSettingsInspector();
  toast("Browser home reset.");
  return true;
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
  const profileSelect = elements.inspectorBody.querySelector('[data-setting-control="externalBrowserProfileId"]');
  if (profileSelect) {
    const profiles = browserProfileOptions();
    const nextProfileId = profiles.some((profile) => profile.id === state.settings.externalBrowserProfileId)
      ? state.settings.externalBrowserProfileId
      : "system";
    if (profileSelect.value !== nextProfileId) profileSelect.value = nextProfileId;
  }
  for (const button of elements.inspectorBody.querySelectorAll("[data-browser-home-preset]")) {
    const preset = browserHomePresets.find((candidate) => candidate.id === button.dataset.browserHomePreset);
    const active = Boolean(preset && isActiveBrowserHomePreset(preset));
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    const status = button.querySelector(".browser-home-preset-status");
    if (status) setTextIfChanged(status, active ? "Active" : "");
    if (preset) {
      const search = normalizeSettingsQuery(`browser home preset ${active ? "active current " : ""}${preset.label} ${preset.body} ${preset.url}`);
      if (button.dataset.settingsSearch !== search) {
        button.dataset.settingsSearch = search;
        updateSettingsSearchIndexItemSearch(button, search);
      }
    }
  }
  refreshRecentBrowserHomeActions();
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

function paneBackgroundControlPanel(panel) {
  const background = normalizeBackgroundValue(panel?.backgroundImage);
  const hasBackground = Boolean(background);
  const source = !hasBackground
    ? "Uses terminal color"
    : backgroundPresetMap.has(background)
      ? "Built-in preset"
      : backgroundFilePath(background) || background;
  const control = document.createElement("div");
  control.className = `active-pane-background${hasBackground ? " has-image" : ""}`;
  control.dataset.settingsSearch = normalizeSettingsQuery("active pane terminal background image wallpaper choose use app save library clear open source");
  control.style.setProperty("--active-pane-background-image", backgroundCss(background));
  control.style.setProperty("--active-pane-background-repeat", backgroundRepeatCss(background));
  control.style.setProperty("--active-pane-background-size", backgroundSizeCss(state.settings.backgroundFit));
  control.style.setProperty("--active-pane-background-position", backgroundPositionCss(state.settings.backgroundPosition));

  const preview = document.createElement("button");
  preview.className = "active-pane-background-preview";
  preview.type = "button";
  preview.title = "Choose pane background";
  preview.setAttribute("aria-label", "Choose pane background");
  preview.onclick = () => choosePanelBackgroundImage(panel);

  const copy = document.createElement("span");
  copy.className = "active-pane-background-copy";
  const title = document.createElement("span");
  title.className = "active-pane-background-title";
  title.textContent = hasBackground ? appearanceBackgroundLabel(background) : "No pane background";
  title.title = title.textContent;
  const meta = document.createElement("span");
  meta.className = "active-pane-background-source";
  meta.textContent = source;
  meta.title = source;
  copy.append(title, meta);

  const input = document.createElement("input");
  input.className = "setting-control active-pane-background-input";
  input.value = isBackgroundPreset(background) ? "" : background;
  input.placeholder = "URL or C:\\path\\image.png";
  input.dataset.settingsSearch = normalizeSettingsQuery("active pane terminal background url local path file image wallpaper input");
  const applyInput = (showToast = false) => withDisabledControl(input, async () => {
    const next = input.value.trim();
    if (!next && isBackgroundPreset(background)) return null;
    const changed = await applyPanelBackgroundImage(next, panel, { toast: showToast });
    if (changed === null) input.value = isBackgroundPreset(background) ? "" : background;
    return changed;
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      applyInput(true);
    } else if (event.key === "Escape") {
      event.preventDefault();
      input.value = isBackgroundPreset(background) ? "" : background;
      input.blur();
    }
  });

  const actions = document.createElement("span");
  actions.className = "background-action-groups active-pane-background-actions";
  const apply = settingsActionButton("Apply", () => applyInput(true), "primary", "active pane terminal background apply url path image");
  const paste = settingsActionButton("Paste", () => pastePanelBackgroundImageFromClipboard(panel, input), "", "active pane terminal background paste clipboard image url local path");
  const choose = settingsActionButton("Choose", () => choosePanelBackgroundImage(panel), "", "active pane terminal background choose local image");
  const useApp = settingsActionButton("Use app", () => applyPanelBackgroundImage(state.settings.backgroundImage, panel), "", "active pane terminal background use app global image");
  useApp.disabled = !state.settings.backgroundImage;
  const save = settingsActionButton("Save", () => saveCustomBackgroundImage({ url: background }), "", "active pane terminal background save image wallpaper library");
  applySavedBackgroundImageSaveLimit(save, background, "Save this pane background image.");
  const open = settingsActionButton("Open", () => openBackgroundImageSource(background), "", "active pane terminal background open source file url");
  open.disabled = !canOpenBackgroundImageSource(background);
  const clear = settingsActionButton("Clear", () => applyPanelBackgroundImage("", panel), "danger", "active pane terminal background clear remove");
  clear.disabled = !hasBackground;
  actions.append(
    backgroundActionGroup("Image source", "active pane terminal background image choose paste apply", [apply, paste, choose]),
    backgroundActionGroup("Pane image", "active pane terminal background use app save open clear", [useApp, save, open, clear])
  );

  control.append(preview, copy, input, actions);
  installBackgroundDropTarget(control, { input, panel });
  return control;
}

function editablePaneTitle(panel) {
  return panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal");
}

function activePaneSettingsPanel(workspace = activeWorkspace()) {
  const panel = workspace?.panels.find((candidate) => candidate.id === workspace.activePanelId)
    || focusedPanel()
    || workspace?.panels[0]
    || null;
  const wrapper = document.createElement("div");
  wrapper.className = "active-pane-panel";
  wrapper.dataset.settingsSearch = normalizeSettingsQuery("active pane tab terminal browser rename color text size split duplicate focus controls background image wallpaper");
  if (!panel) {
    wrapper.innerHTML = `<div class="active-pane-empty">Open a terminal or browser pane to customize it here.</div>`;
    return wrapper;
  }

  const paneBackground = panel.type === "terminal" ? normalizeBackgroundValue(panel.backgroundImage) : "";
  const typeLabel = panel.type === "browser" ? "Browser" : "Terminal";
  const title = panelDisplayTitle(panel, false);
  const meta = panel.type === "browser"
    ? browserPanelUrl(panel) || panel.url || state.settings.browserHomeUrl
    : `${panel.cwdShort || workspace?.cwdShort || "~"} / ${optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell")}`;
  const summary = document.createElement("div");
  summary.className = `active-pane-summary${paneBackground ? " has-background" : ""}`;
  summary.innerHTML = `
    <span class="active-pane-color"></span>
    <span class="active-pane-copy">
      <span class="active-pane-kind"></span>
      <span class="active-pane-title"></span>
      <span class="active-pane-meta"></span>
    </span>
    <button class="active-pane-background-chip" type="button">
      <span class="active-pane-background-chip-preview" aria-hidden="true"></span>
      <span class="active-pane-background-chip-label"></span>
    </button>
  `;
  summary.style.setProperty("--active-pane-color", panel.color || workspace?.color || state.settings.accent);
  summary.querySelector(".active-pane-kind").textContent = typeLabel;
  summary.querySelector(".active-pane-title").textContent = title;
  summary.querySelector(".active-pane-title").title = title;
  summary.querySelector(".active-pane-meta").textContent = meta;
  summary.querySelector(".active-pane-meta").title = meta;
  const backgroundChip = summary.querySelector(".active-pane-background-chip");
  if (panel.type === "terminal") {
    const backgroundLabel = paneBackground ? "Pane image" : "Default look";
    const backgroundTitle = paneBackground
      ? `Pane background: ${appearanceBackgroundLabel(paneBackground)}`
      : "Pane background uses terminal colors";
    backgroundChip.style.setProperty("--active-pane-background-image", backgroundCss(paneBackground));
    backgroundChip.style.setProperty("--active-pane-background-repeat", backgroundRepeatCss(paneBackground));
    backgroundChip.style.setProperty("--active-pane-background-size", backgroundSizeCss(state.settings.backgroundFit));
    backgroundChip.style.setProperty("--active-pane-background-position", backgroundPositionCss(state.settings.backgroundPosition));
    backgroundChip.querySelector(".active-pane-background-chip-label").textContent = backgroundLabel;
    backgroundChip.title = `${backgroundTitle}. Click to choose.`;
    backgroundChip.setAttribute("aria-label", `${backgroundTitle}. Choose pane background.`);
    backgroundChip.onclick = () => choosePanelBackgroundImage(panel);
  } else {
    backgroundChip.hidden = true;
  }
  wrapper.append(summary);

  const titleInput = document.createElement("input");
  titleInput.className = "setting-control";
  titleInput.value = editablePaneTitle(panel);
  titleInput.placeholder = "Pane name";
  const defaultPaneTitle = () => editablePaneTitle({ ...panel, title: "", titleLocked: false });
  const currentPaneTitle = () => panel.titleLocked ? panel.title : defaultPaneTitle();
  const savePaneTitleInput = async (options = {}) => {
    const nextTitle = titleInput.value.trim();
    if (!nextTitle) {
      const changed = Boolean(panel.titleLocked);
      if (changed) await updatePanel(panel.id, { title: "" });
      titleInput.value = defaultPaneTitle();
      if (options.toast) toast(changed ? "Pane name reset." : "Pane already uses the default name.");
      updatePaneTitleActions();
      return changed;
    }
    if (nextTitle === currentPaneTitle()) {
      if (options.toast) toast("Pane name already current.");
      updatePaneTitleActions();
      return false;
    }
    await updatePanel(panel.id, { title: nextTitle });
    if (options.toast) toast("Pane name saved.");
    updatePaneTitleActions();
    return true;
  };
  let titleSave = null;
  let titleReset = null;
  const updatePaneTitleActions = () => {
    const nextTitle = titleInput.value.trim();
    if (titleSave) {
      titleSave.disabled = !nextTitle || nextTitle === currentPaneTitle();
      titleSave.title = !nextTitle
        ? "Enter a pane name first, or use Default to clear a custom name."
        : nextTitle === currentPaneTitle()
          ? "Pane name is already current."
          : "Save the active pane name.";
    }
    if (titleReset) {
      titleReset.disabled = !panel.titleLocked;
      titleReset.title = panel.titleLocked ? "Restore the automatic pane name." : "Pane already uses the automatic name.";
    }
  };
  const refreshPaneTitleActionsAfterButton = () => {
    requestAnimationFrame(() => {
      if (titleControl.isConnected) updatePaneTitleActions();
    });
  };
  titleInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      titleInput.blur();
    } else if (event.key === "Escape") {
      titleInput.value = editablePaneTitle(panel);
      titleInput.blur();
    }
  });
  titleInput.addEventListener("input", updatePaneTitleActions);
  titleInput.addEventListener("blur", (event) => {
    if (event.relatedTarget && titleControl.contains(event.relatedTarget)) return;
    savePaneTitleInput();
  });
  titleSave = settingsActionButton("Save", async () => {
    const changed = await savePaneTitleInput({ toast: true });
    refreshPaneTitleActionsAfterButton();
    return changed;
  }, "primary", "active pane rename save tab title");
  titleReset = settingsActionButton("Default", async () => {
    const changed = Boolean(panel.titleLocked);
    titleInput.value = defaultPaneTitle();
    if (changed) await updatePanel(panel.id, { title: "" });
    else toast("Pane already uses the default name.");
    updatePaneTitleActions();
    refreshPaneTitleActionsAfterButton();
  }, "", "active pane rename default automatic title clear");
  const titleControl = document.createElement("span");
  titleControl.className = "active-pane-title-control";
  titleControl.append(titleInput, titleSave, titleReset);
  updatePaneTitleActions();
  wrapper.append(settingRow("Pane name", titleControl, false, "active pane rename save tab title default automatic clear"));

  const paneSizeControl = paneShapePanel(workspace);
  paneSizeControl.classList.add("is-embedded");
  wrapper.append(settingRow(
    "Pane size",
    paneSizeControl,
    true,
    "active pane size shape split resize percent exact slider 1 99 layout rows columns"
  ));

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
      saveLabel: "Save",
      targetLabel: panel.type === "browser" ? "Browser pane" : "Terminal pane",
      targetMeta: panelDisplayTitle(panel, true),
      searchTerms: "active pane custom color hex picker reset default clear"
    }),
    true,
    "active pane color tab custom hex picker palette swatch reset default clear"
  ));

  if (panel.type === "terminal") {
    wrapper.append(settingRow(
      "Pane background",
      paneBackgroundControlPanel(panel),
      true,
      "active pane terminal background image wallpaper choose use app save library clear open source"
    ));

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
        if (session.address.value !== nextUrl) session.address.value = nextUrl;
        updateActiveBrowserTabUrl(session, nextUrl);
        const sourceUrl = browserViewSourceUrl(nextUrl, state.settings.browserHomeUrl);
        if (session.view.src !== sourceUrl) {
          session.content?.classList?.remove("has-loaded");
          session.setLoading?.(true);
          session.view.src = sourceUrl;
          session.setStatus?.(browserLoadingStatusText);
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
  const row = document.createElement(control?.classList?.contains("setting-segmented") ? "div" : "label");
  row.className = `setting-row${stacked ? " stacked" : ""}`;
  row.dataset.settingsSearch = normalizeSettingsQuery(`${label} ${searchTerms}`);
  const text = document.createElement("span");
  text.className = "setting-label";
  text.textContent = label;
  row.append(text, control);
  return row;
}

function settingSegmentedControl(settingKey, choices, searchTerms = "", options = {}) {
  const control = document.createElement("div");
  control.className = `setting-segmented${options.compact ? " is-compact" : ""}`;
  control.setAttribute("role", "radiogroup");
  control.dataset.settingControl = settingKey;
  control.dataset.settingsSearch = normalizeSettingsQuery(`${settingKey} ${searchTerms}`);
  const value = state.settings[settingKey];
  for (const choice of choices) {
    const [choiceValue, label, body = ""] = choice;
    const active = choiceValue === value;
    const button = document.createElement("button");
    button.className = `setting-segmented-option${active ? " is-active" : ""}`;
    button.type = "button";
    button.dataset.settingValue = choiceValue;
    button.setAttribute("role", "radio");
    button.setAttribute("aria-checked", active ? "true" : "false");
    button.title = body ? `${label}: ${body}` : label;
    button.dataset.settingsSearch = normalizeSettingsQuery(`${settingKey} ${label} ${body} ${choiceValue}`);
    button.innerHTML = `
      <span class="setting-segmented-label"></span>
      <span class="setting-segmented-body"></span>
    `;
    button.querySelector(".setting-segmented-label").textContent = label;
    setTextIfChanged(button.querySelector(".setting-segmented-body"), body);
    button.onclick = () => {
      if (state.settings[settingKey] === choiceValue) return;
      updateSettings({ [settingKey]: choiceValue });
    };
    control.append(button);
  }
  return control;
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
    sectionSearch: normalizeSettingsQuery(section.dataset.settingsSearch || ""),
    sectionTitle: settingsSectionTitle(section),
    items: [...section.querySelectorAll("[data-settings-search]")]
      .filter((item) => item !== section)
      .map((item) => ({ item, search: normalizeSettingsQuery(item.dataset.settingsSearch || "") })),
    groups: [...section.querySelectorAll(".settings-command-group")].map((group) => ({
      group,
      search: normalizeSettingsQuery(group.dataset.settingsSearch || ""),
      cards: [...group.querySelectorAll(".settings-command-card")]
    }))
  }));
}

function rebuildSettingsSearchIndex() {
  state.settingsSearchIndex = buildSettingsSearchIndex();
  state.settingsSearchIndexVersion += 1;
  state.settingsSearchLastFilterSignature = "";
  state.settingsSearchDisclosuresOpenVersion = 0;
  state.settingsSearchEmpty = elements.inspectorBody.querySelector(".settings-empty");
  return state.settingsSearchIndex;
}

function updateSettingsSearchIndexItemSearch(target, search) {
  for (const section of state.settingsSearchIndex) {
    const record = section.items.find((item) => item.item === target);
    if (record) {
      record.search = normalizeSettingsQuery(search);
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

function syncSettingsDisclosuresForSearch(query) {
  if (!query) {
    state.settingsSearchDisclosuresOpenVersion = 0;
    return false;
  }
  if (state.settingsSearchDisclosuresOpenVersion === state.settingsSearchIndexVersion) return false;
  let mountedContent = false;
  for (const disclosure of elements.inspectorBody.querySelectorAll(".settings-disclosure")) {
    if (!disclosure.open) disclosure.open = true;
    mountedContent = ensureSettingsDisclosureContent(disclosure) || mountedContent;
  }
  return mountedContent;
}

function applySettingsFilter() {
  const query = normalizeSettingsQuery(state.settingsQuery);
  const tokens = settingsSearchTokens(query);
  const mountedDisclosureContent = syncSettingsDisclosuresForSearch(query);
  const sections = state.settingsSearchIndex.length && !mountedDisclosureContent
    ? state.settingsSearchIndex
    : rebuildSettingsSearchIndex();
  if (query) state.settingsSearchDisclosuresOpenVersion = state.settingsSearchIndexVersion;
  const pendingAutoScroll = query && state.settingsSearchAutoScrollQuery === query;
  const filterSignature = `${query}\u001e${state.settingsSearchIndexVersion}\u001e${pendingAutoScroll ? "scroll" : ""}`;
  if (filterSignature === state.settingsSearchLastFilterSignature) return;
  state.settingsSearchLastFilterSignature = filterSignature;
  let visibleSections = 0;
  let matchingItems = 0;
  let bestTarget = null;
  for (const sectionRecord of sections) {
    const { section, sectionSearch, sectionTitle, items, groups } = sectionRecord;
    const sectionMatches = settingsSearchMatchesNormalized(sectionSearch, tokens);
    let sectionVisible = sectionMatches;
    if (query && sectionMatches) {
      matchingItems += 1;
      bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, section, sectionTitle);
    }
    for (const { item, search } of items) {
      const itemMatches = settingsSearchMatchesNormalized(search, tokens);
      const visible = itemMatches || sectionMatches;
      setHiddenIfChanged(item, !visible);
      sectionVisible ||= visible;
      if (query && itemMatches) {
        matchingItems += 1;
        bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, item, sectionTitle);
      }
    }
    for (const { group, search, cards } of groups) {
      const cardVisible = cards.some((card) => !card.hidden);
      const groupMatches = settingsSearchMatchesNormalized(search, tokens);
      const groupVisible = cardVisible || groupMatches || sectionMatches;
      setHiddenIfChanged(group, !groupVisible);
      sectionVisible ||= groupVisible;
      if (query && groupMatches) {
        matchingItems += 1;
        bestTarget = maybeUpdateSettingsSearchTarget(bestTarget, group, sectionTitle);
      }
    }
    setHiddenIfChanged(section, !sectionVisible);
    if (sectionVisible) visibleSections += 1;
  }
  const empty = state.settingsSearchEmpty?.isConnected
    ? state.settingsSearchEmpty
    : elements.inspectorBody.querySelector(".settings-empty");
  state.settingsSearchEmpty = empty || null;
  if (empty) setHiddenIfChanged(empty, !query || visibleSections > 0);
  const clear = state.settingsSearchClear?.isConnected
    ? state.settingsSearchClear
    : elements.inspectorBody.querySelector(".settings-search-clear");
  state.settingsSearchClear = clear || null;
  if (clear) clear.disabled = !query;
  setSettingsSearchResultText(query ? settingsSearchResultMessage(matchingItems, visibleSections) : "");
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
  schedulePerformanceMetricsRefresh();
  if (performanceGuardCanUseActivitySignal() && state.paneCreateStats.lastMs >= performanceGuardSlowPaneCreateMs) {
    maybeTriggerPerformanceGuard("slow pane creation");
  }
}

function recordTerminalConnectDuration(durationMs) {
  recordDurationStats(state.terminalConnectStats, durationMs);
  schedulePerformanceMetricsRefresh();
  if (performanceGuardCanUseActivitySignal() && state.terminalConnectStats.lastMs >= performanceGuardSlowTerminalConnectMs) {
    maybeTriggerPerformanceGuard("slow terminal connection");
  }
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
    ["Startup", optionLabel(terminalStartupOptions, state.settings.terminalStartupMode, "Fast")],
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

function hasPerformanceStats() {
  const currentQueue = totalTerminalOutputQueue();
  return Boolean(
    state.renderStats.count
    || state.renderStats.slowCount
    || state.renderStats.coalescedRenders
    || state.renderStats.skippedRenders
    || state.renderStats.browserUrlRenderSkips
    || state.renderStats.guardActivations
    || state.terminalOutputStats.maxQueued > currentQueue
    || state.terminalOutputStats.writtenBytes
    || state.terminalOutputStats.chunks
    || state.terminalOutputStats.lastChunk
    || state.terminalOutputStats.pausedFlushes
    || state.terminalOutputStats.trimmedBytes
    || state.terminalOutputStats.trimmedEvents
    || state.terminalFitStats.deferred
    || state.terminalFitStats.flushed
    || state.paneCreateStats.count
    || state.paneCreateStats.failures
    || state.terminalConnectStats.count
    || state.performanceGuardTriggered
    || state.performanceGuardReason
    || state.performanceGuardSlowRenderCount
  );
}

function resetPerformanceStatsAction() {
  const hasStats = hasPerformanceStats();
  const action = settingsActionButton("Reset stats", resetRenderStats, "", `performance render stats reset ${hasStats ? "" : "empty clear "}`);
  action.disabled = !hasStats;
  action.title = hasStats ? "Clear collected performance counters." : "Performance counters are already clear.";
  return action;
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
      sidebarBranchMode: state.settings.sidebarBranchMode,
      sidebarFooterMode: state.settings.sidebarFooterMode,
      tabSize: state.settings.tabSize,
      titleDetailMode: state.settings.titleDetailMode,
      showTabs: state.settings.showTabs,
      showStatusbar: state.settings.showStatusbar,
      performanceMode: state.settings.performanceMode,
      adaptivePerformance: state.settings.adaptivePerformance,
      reduceMotion: state.settings.reduceMotion,
      terminalPauseInactiveOutput: state.settings.terminalPauseInactiveOutput,
      terminalStartupMode: state.settings.terminalStartupMode,
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

function activeSavedSettingsProfile() {
  return state.savedSettingsProfiles.find((profile) => isActiveSettingsProfile(profile)) || null;
}

function savedSettingsProfilesFull() {
  return state.savedSettingsProfiles.length >= savedSettingsProfilesLimit;
}

function settingsProfileLimitTitle() {
  return `Profile limit is ${savedSettingsProfilesLimit}. Delete one first.`;
}

function applySettingsProfileSaveLimit(button, availableTitle = "Save the current setup as a reusable profile.") {
  if (!button) return button;
  const full = savedSettingsProfilesFull();
  button.disabled = full;
  button.title = full ? settingsProfileLimitTitle() : availableTitle;
  return button;
}

function activeSettingsSetupModel() {
  const saved = activeSavedSettingsProfile();
  if (saved) {
    return {
      label: saved.label,
      kind: "Saved profile",
      baseName: `${saved.label} copy`
    };
  }
  const presetLabel = activeSettingsPresetLabel();
  if (presetLabel !== "Custom") {
    return {
      label: presetLabel,
      kind: "Built-in profile",
      baseName: `${presetLabel} setup`
    };
  }
  return {
    label: "Custom",
    kind: "Unsaved setup",
    baseName: "Custom setup"
  };
}

function activeSettingsSetupLabel() {
  return activeSettingsSetupModel().label;
}

function savedSettingsProfileCountLabel() {
  return `${state.savedSettingsProfiles.length}/${savedSettingsProfilesLimit}`;
}

function saveQuickSetupProfile() {
  const setup = activeSettingsSetupModel();
  return saveCurrentSettingsProfile({
    title: "Save current setup",
    message: "Save the current colors, layout, terminal, browser, and performance settings as a reusable profile.",
    baseName: setup.baseName
  });
}

async function applyAndSaveCleanFastProfile() {
  const preset = settingsPresetById("simpleFast");
  const changed = preset ? updateSettings(preset.settings) : false;
  const label = await showTextDialog({
    title: "Save clean + fast setup",
    message: "Apply the clean speed preset now, then save it as a reusable Settings profile.",
    value: defaultSettingsProfileName("Clean + fast setup"),
    placeholder: "Clean + fast setup",
    confirmLabel: "Save"
  });
  if (!label) {
    if (changed) {
      renderSettingsInspector();
      toast("Clean + fast settings applied.");
    }
    return;
  }
  const saved = upsertSavedSettingsProfile({
    id: createSettingsProfileId(),
    label,
    settings: state.settings,
    createdAt: Date.now()
  });
  renderSettingsInspector();
  if (!saved) return;
  toast(changed ? "Clean + fast profile saved and applied." : "Clean + fast profile saved.");
}

function settingsPresetById(presetId) {
  return settingsPresets.find((preset) => preset.id === presetId) || null;
}

function isSettingsPresetIdActive(presetId) {
  const preset = settingsPresetById(presetId);
  return Boolean(preset && isActiveSettingsPreset(preset));
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

function setQuickScopeItemState(panel, scopeId, options = {}) {
  const item = panel.querySelector(`[data-quick-scope-item="${scopeId}"]`);
  if (!item) return;
  const model = activeBackgroundPanelViewModel(scopeId);
  toggleClassIfChanged(item, "is-active", Boolean(options.active));
  toggleClassIfChanged(item, "is-muted", Boolean(options.muted));
  toggleClassIfChanged(item, "has-image", model.hasBackground);
  toggleClassIfChanged(item, "is-mixed", model.mixed);
  setStylePropertyIfChanged(item, "--quick-scope-background-image", model.image);
  setStylePropertyIfChanged(item, "--quick-scope-background-repeat", model.repeat);
  setStylePropertyIfChanged(item, "--quick-scope-background-size", model.size);
  setStylePropertyIfChanged(item, "--quick-scope-background-position", model.position);
  setDisabledIfChanged(item, Boolean(options.disabled));
  const option = backgroundApplyTargetOption(scopeId);
  const title = formatMessage("quickGuide.backgroundTargetTitle", { label: option.label });
  setTitleIfChanged(item, title);
  setAttributeIfChanged(item, "aria-label", `${title}. ${option.meta}.`);
  item.onclick = () => openBackgroundTargetSettings(scopeId);
}

function openBackgroundTargetSettings(target = "app") {
  const scope = normalizeBackgroundApplyTarget(target);
  const option = backgroundApplyTargetOption(scope);
  const status = activeBackgroundTargetStatus(scope);
  if (!status.canTarget) {
    toast(formatMessage("quickGuide.backgroundTargetUnavailable", { label: option.label }));
    return false;
  }
  state.backgroundApplyTarget = scope;
  openSettingsCategory("appearance", { query: "background image", focusSearch: false });
  return true;
}

function quickSetupOverviewPanel() {
  const workspace = activeWorkspace();
  const panels = workspace?.panels || [];
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  const folder = workspace?.cwdShort || workspace?.cwd || "No folder";
  const scope = activeBackgroundScopeModel(state.settings.backgroundImage, workspace);
  const activeTerminal = activeTerminalPanelForSettings();
  const activeTerminalBackground = activeTerminal ? normalizeBackgroundValue(activeTerminal.backgroundImage) : "";
  const performance = performanceOverviewModel();
  const panel = document.createElement("div");
  panel.className = "quick-setup-overview";
  panel.dataset.settingsSearch = normalizeSettingsQuery(`quick setup overview current settings workspace panes theme layout terminal browser performance speed lag ${performance.status} ${performance.title} ${performance.reason} background image app pane all terminal scope data`);
  panel.innerHTML = `
    <div class="quick-overview-heading">
      <span class="quick-overview-copy">
        <span class="quick-overview-title">Current setup</span>
        <span class="quick-overview-subtitle"></span>
      </span>
      <button class="quick-overview-save" type="button">
        <span class="quick-overview-save-icon" aria-hidden="true"></span>
        <span class="quick-overview-save-copy">
          <b>Save setup</b>
          <em data-quick-profile-count></em>
        </span>
      </button>
    </div>
    <div class="quick-overview-grid">
      <span><b>Profile</b><em data-quick-profile></em></span>
      <span><b>Workspace</b><em data-quick-workspace></em></span>
      <span><b>Panes</b><em data-quick-panes></em></span>
      <span><b>Look</b><em data-quick-look></em></span>
      <span><b>Terminal</b><em data-quick-terminal></em></span>
      <span><b>Performance</b><em data-quick-performance></em></span>
    </div>
    <button class="quick-overview-speed" type="button" data-performance-status>
      <span class="quick-overview-speed-icon" aria-hidden="true"></span>
      <span class="quick-overview-speed-copy">
        <b data-quick-speed-title></b>
        <em data-quick-speed-reason></em>
      </span>
      <span class="quick-overview-speed-meta">
        <span data-quick-speed-render></span>
        <span data-quick-speed-action></span>
      </span>
    </button>
    <div class="quick-overview-scope" aria-label="Background scope">
      <button class="quick-overview-scope-item" type="button" data-quick-scope-item="app">
        <span class="quick-overview-scope-preview" aria-hidden="true"></span>
        <span class="quick-overview-scope-copy"><b>App image</b><em data-quick-scope-app></em></span>
      </button>
      <button class="quick-overview-scope-item" type="button" data-quick-scope-item="pane">
        <span class="quick-overview-scope-preview" aria-hidden="true"></span>
        <span class="quick-overview-scope-copy"><b>Active terminal</b><em data-quick-scope-pane></em></span>
      </button>
      <button class="quick-overview-scope-item" type="button" data-quick-scope-item="all">
        <span class="quick-overview-scope-preview" aria-hidden="true"></span>
        <span class="quick-overview-scope-copy"><b>All terminals</b><em data-quick-scope-all></em></span>
      </button>
    </div>
  `;
  panel.querySelector(".quick-overview-subtitle").textContent = folder;
  const saveSetup = panel.querySelector(".quick-overview-save");
  saveSetup.querySelector(".quick-overview-save-icon").innerHTML = quickActionIconMarkup("profiles");
  const setup = activeSettingsSetupModel();
  saveSetup.querySelector("[data-quick-profile-count]").textContent = `${setup.kind} / ${savedSettingsProfileCountLabel()} profiles`;
  applySettingsProfileSaveLimit(saveSetup);
  saveSetup.dataset.settingsSearch = normalizeSettingsQuery("quick setup save current settings profile look layout terminal browser performance");
  saveSetup.setAttribute("aria-label", saveSetup.title);
  saveSetup.onclick = () => {
    if (!saveSetup.disabled) saveQuickSetupProfile();
  };
  const profileValue = panel.querySelector("[data-quick-profile]");
  profileValue.textContent = setup.label;
  profileValue.title = `${setup.kind}: ${setup.label}`;
  panel.querySelector("[data-quick-workspace]").textContent = workspace?.title || "No workspace";
  panel.querySelector("[data-quick-panes]").textContent = `${terminalCount} term / ${browserCount} web`;
  panel.querySelector("[data-quick-look]").textContent = `${optionLabel(themeOptions, state.settings.theme, "cmux")} / ${accentModeLabel()}`;
  panel.querySelector("[data-quick-terminal]").textContent = `${optionLabel(terminalFontOptions, state.settings.terminalFontFamily, "Mono")} ${state.settings.terminalFontSize}px`;
  panel.querySelector("[data-quick-performance]").textContent = performanceModeLabel();
  const speed = panel.querySelector(".quick-overview-speed");
  speed.className = `quick-overview-speed is-${performance.status}`;
  speed.querySelector(".quick-overview-speed-icon").innerHTML = quickActionIconMarkup("speed");
  speed.querySelector("[data-quick-speed-title]").textContent = performance.title;
  speed.querySelector("[data-quick-speed-reason]").textContent = performance.reason;
  speed.querySelector("[data-quick-speed-render]").textContent = performance.output === "Clean"
    ? performance.render
    : `${performance.output} / ${performance.render}`;
  speed.querySelector("[data-quick-speed-action]").textContent = performance.status === "tuned" ? "Details" : "Tune";
  speed.title = `${performance.title}: ${performance.reason}`;
  speed.setAttribute("aria-label", `${performance.title}. ${performance.reason}. ${performance.render}.`);
  speed.onclick = () => {
    if (performance.status === "tuned") {
      openSettingsCategory("performance");
      return;
    }
    tunePerformanceNow();
    if (state.inspectorMode === "settings" && state.settingsCategory === "quick") renderSettingsInspector();
  };
  panel.querySelector("[data-quick-scope-app]").textContent = scope.hasBackground
    ? appearanceBackgroundLabel(state.settings.backgroundImage)
    : "None";
  panel.querySelector("[data-quick-scope-pane]").textContent = activeTerminal
    ? activeTerminalPaneBackgroundLabel()
    : "No terminal";
  panel.querySelector("[data-quick-scope-all]").textContent = scope.all;
  setQuickScopeItemState(panel, "app", { active: scope.hasBackground });
  setQuickScopeItemState(panel, "pane", {
    active: Boolean(activeTerminalBackground),
    muted: !activeTerminal,
    disabled: !activeTerminal
  });
  setQuickScopeItemState(panel, "all", {
    active: scope.allPanesMatch,
    muted: scope.paneCount === 0,
    disabled: scope.paneCount === 0
  });
  return panel;
}

const quickSetupPresetRailItems = [
  { id: "simpleFast", label: "Clean + Fast", body: "Simple speed", icon: "speed", search: "clean fast simple minimal ui speed performance lag startup" },
  { id: "simple", label: "Clean", body: "Quiet chrome", icon: "clean", search: "clean simple minimal ui quiet chrome" },
  { id: "performance", label: "Fast", body: "Reduce lag", icon: "speed", search: "fast performance speed lag smooth" },
  { id: "focus", label: "Focus", body: "Hide extras", icon: "focus", search: "focus mode hide chrome workspace" },
  { id: "balanced", label: "Balanced", body: "Restore default", icon: "quick", search: "balanced restore default settings" }
];

function quickSetupPresetRailPanel() {
  const panel = document.createElement("div");
  panel.className = "quick-preset-rail";
  panel.dataset.settingsSearch = normalizeSettingsQuery("quick setup clean fast focus balanced preset simple performance restore default");
  for (const item of quickSetupPresetRailItems) {
    const preset = settingsPresetById(item.id);
    if (!preset) continue;
    const active = isActiveSettingsPreset(preset);
    const button = document.createElement("button");
    button.className = `quick-preset-rail-item${active ? " is-active" : ""}`;
    button.type = "button";
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.title = `${item.label}: ${preset.body}`;
    button.dataset.settingsSearch = normalizeSettingsQuery(`quick setup preset ${item.label} ${item.body} ${preset.body} ${item.search}`);
    button.innerHTML = `
      <span class="quick-preset-rail-icon" aria-hidden="true"></span>
      <span class="quick-preset-rail-copy">
        <span class="quick-preset-rail-label"></span>
        <span class="quick-preset-rail-body"></span>
      </span>
    `;
    button.querySelector(".quick-preset-rail-icon").innerHTML = quickActionIconMarkup(item.icon);
    button.querySelector(".quick-preset-rail-label").textContent = item.label;
    button.querySelector(".quick-preset-rail-body").textContent = item.body;
    button.onclick = () => applySettingsPreset(preset);
    panel.append(button);
  }
  return panel;
}

const quickSettingsShortcuts = [
  ["workspace", "Workspace", "Rename, folders, colors.", workspaceCountLabel, "workspace"],
  ["appearance", "Look", "Themes, colors, backgrounds.", () => appearanceBackgroundLabel(state.settings.backgroundImage), "appearance"],
  ["layout", "Layout", "Tabs, panes, chrome.", () => optionLabel(toolbarModeOptions, state.settings.toolbarMode, "Minimal"), "layout"],
  ["terminal", "Terminal", "Font, cursor, shell.", () => optionLabel(terminalProfiles, state.settings.terminalProfile, "Auto"), "terminal"],
  ["browser", "Browser", "Home page and history.", () => hostnameOf(state.settings.browserHomeUrl), "browser"],
  ["performance", "Performance", "Lag tuning and diagnostics.", performanceModeLabel, "performance"],
  ["blueprints", "Blueprints", "Saved pane layouts.", () => `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`, "blueprints"],
  ["actions", "Actions", "Shortcuts and runnable actions.", () => `${commands.length} actions`, "actions"],
  ["commands", "Commands", "Saved shell and GitHub CLI snippets.", () => `${state.customCommandSnippets.length}/${customCommandSnippetsLimit}`, "commands"],
  ["profiles", "Profiles", "Save and reuse setups.", savedSettingsProfileCountLabel, "profiles"],
  ["data", "Data", "Import, export, cleanup.", () => `${state.recentFolders.length + state.recentCommands.length + state.recentBrowserPages.length} recent`, "data"]
];

const quickActionIconSvg = {
  actions: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 7h8M8 12h5M8 17h8"></path><path d="M4 7h.01M4 12h.01M4 17h.01"></path></svg>`,
  appearance: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 4c4 0 8 3 8 7 0 3-2 5-5 5h-1.5a1.5 1.5 0 0 0 0 3H12a8 8 0 1 1 0-16Z"></path><circle cx="8.5" cy="10" r="1"></circle><circle cx="12" cy="8" r="1"></circle><circle cx="15.5" cy="10" r="1"></circle></svg>`,
  blueprints: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="5" y="4" width="14" height="16" rx="2"></rect><path d="M8 8h8M8 12h5M8 16h6"></path></svg>`,
  browser: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="8"></circle><path d="M4 12h16M12 4c2.2 2.3 2.2 13.7 0 16M12 4c-2.2 2.3-2.2 13.7 0 16"></path></svg>`,
  commands: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="m8 10 3 3-3 3"></path><path d="M13 16h3"></path></svg>`,
  data: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><ellipse cx="12" cy="6" rx="7" ry="3"></ellipse><path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6"></path><path d="M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"></path></svg>`,
  layout: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14M4 12h16"></path></svg>`,
  profiles: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="8" r="3"></circle><path d="M5 20c1.2-4 12.8-4 14 0"></path></svg>`,
  terminal: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="m8 10 3 3-3 3"></path><path d="M13 16h3"></path></svg>`,
  terminalGroup: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="5" y="4.5" width="11" height="8" rx="1.5"></rect><rect x="8" y="7.5" width="11" height="8" rx="1.5"></rect><rect x="4" y="10.5" width="11" height="9" rx="1.5"></rect><path d="m7.5 14 2 2-2 2"></path><path d="M11.5 18h2"></path></svg>`,
  workspace: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="6" height="6" rx="1"></rect><rect x="14" y="5" width="6" height="6" rx="1"></rect><rect x="4" y="15" width="16" height="4" rx="1"></rect></svg>`,
  rename: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 5h12M12 5v14M9 19h6"></path></svg>`,
  clean: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M8 9h8M8 13h5"></path></svg>`,
  performance: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 16a7 7 0 0 1 14 0"></path><path d="m12 16 4-5"></path><path d="M8 20h8"></path></svg>`,
  quick: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 12h14"></path><path d="m13 6 6 6-6 6"></path><path d="M5 6h4M5 18h4"></path></svg>`,
  speed: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 16a7 7 0 0 1 14 0"></path><path d="m12 16 4-5"></path><path d="M8 20h8"></path></svg>`,
  focus: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 4H5a1 1 0 0 0-1 1v3M16 4h3a1 1 0 0 1 1 1v3M8 20H5a1 1 0 0 1-1-1v-3M16 20h3a1 1 0 0 0 1-1v-3"></path><circle cx="12" cy="12" r="2.5"></circle></svg>`,
  background: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><circle cx="9" cy="10" r="1.5"></circle><path d="m7 17 4-4 3 3 2-2 2 3"></path></svg>`,
  browserPlus: controlIconSvg.browserPlus,
  paneBackground: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14M7 15l2-2 2 2"></path><circle cx="8" cy="9" r="1.2"></circle></svg>`,
  paneGroup: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="7" height="6" rx="1.3"></rect><rect x="13" y="5" width="7" height="6" rx="1.3"></rect><rect x="4" y="14" width="16" height="5" rx="1.3"></rect></svg>`,
  paneShape: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M12 5v14M4 12h16"></path></svg>`,
  paneSettings: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="4" y="5" width="16" height="14" rx="2"></rect><path d="M8 9h5M8 15h8"></path><circle cx="16" cy="9" r="1.5"></circle><circle cx="11" cy="15" r="1.5"></circle></svg>`,
  saveLayout: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 4h10l2 2v14H6z"></path><path d="M8 4v6h8M9 17h6"></path></svg>`,
  terminalPlus: controlIconSvg.terminalPlus
};

function quickActionIconMarkup(icon) {
  return quickActionIconSvg[icon] || quickActionIconSvg.clean;
}

function activeTerminalPaneBackgroundLabel() {
  const panel = resolveTerminalPanel(focusedPanel());
  if (!panel) return "Select terminal";
  const background = normalizeBackgroundValue(panel.backgroundImage);
  return background ? appearanceBackgroundLabel(background) : "Default";
}

function activePaneSettingsQuickLabel() {
  const panel = activePaneActionTarget() || activePanel();
  return panel ? panelDisplayTitle(panel, true) : "No pane";
}

function quickSetupActionDefinitions() {
  return [
    {
      id: "new-terminal",
      icon: "terminalPlus",
      label: "New terminal",
      body: "Start a terminal pane in the active workspace.",
      meta: () => paneCreationQueueStatusLabel() || optionLabel(terminalProfiles, state.settings.terminalProfile, "Auto"),
      cta: "+ Terminal",
      search: "new terminal add pane shell powershell command prompt quick setup",
      disabled: () => !activeWorkspace() || paneCreationButtonsDisabled(),
      run: () => createTerminalPanel("right", { workspaceId: activeWorkspace()?.id })
    },
    {
      id: "new-browser",
      icon: "browserPlus",
      label: "New browser",
      body: "Open the home page in a browser pane.",
      meta: () => paneCreationQueueStatusLabel() || hostnameOf(state.settings.browserHomeUrl),
      cta: "+ Browser",
      search: "new browser add pane web google home quick setup",
      disabled: () => !activeWorkspace() || paneCreationButtonsDisabled(),
      run: () => openBrowserHome(activeWorkspace()?.id, { mode: "pane" })
    },
    {
      id: "rename",
      icon: "rename",
      label: "Rename",
      body: "Name the active workspace without opening more chrome.",
      meta: () => activeWorkspace()?.title || "Workspace",
      cta: "Edit",
      search: "rename workspace name title quick setup",
      run: () => renameActiveWorkspace()
    },
    {
      id: "clean-fast",
      icon: "speed",
      label: "Clean + Fast",
      body: "Apply compact chrome, reduced effects, and fast terminal startup.",
      meta: activeSettingsSetupLabel,
      cta: "Apply",
      search: "clean fast simple speed compact ui chrome terminal startup lag preset",
      active: () => isSettingsPresetIdActive("simpleFast"),
      run: () => applySettingsPresetById("simpleFast")
    },
    {
      id: "save-clean-fast-profile",
      icon: "profiles",
      label: "Save fast setup",
      body: "Apply Clean + Fast and keep it as a reusable profile.",
      meta: savedSettingsProfileCountLabel,
      cta: "Save",
      search: "save clean fast simple speed settings profile reusable setup performance lag preset",
      disabled: savedSettingsProfilesFull,
      run: () => applyAndSaveCleanFastProfile()
    },
    {
      id: "clean-ui",
      icon: "clean",
      label: "Clean UI",
      body: "Apply a minimal toolbar and quieter pane controls.",
      meta: activeSettingsSetupLabel,
      cta: "Apply",
      search: "simple clean minimal compact ui chrome pane controls preset",
      active: () => isSettingsPresetIdActive("simple"),
      run: () => applySettingsPresetById("simple")
    },
    {
      id: "save-profile",
      icon: "profiles",
      label: "Save setup",
      body: "Keep this look, layout, terminal, browser, and speed setup.",
      meta: savedSettingsProfileCountLabel,
      cta: "Save",
      search: "save current settings profile setup look layout terminal browser performance",
      disabled: savedSettingsProfilesFull,
      run: () => saveQuickSetupProfile()
    },
    {
      id: "tune-speed",
      icon: "speed",
      label: "Tune speed",
      body: "Reduce effects, pause hidden output, and lighten history.",
      meta: performanceModeLabel,
      cta: "Tune",
      active: () => state.settings.performanceMode,
      activeCta: "Details",
      activeDisabled: false,
      search: "performance tune speed lag smooth reduce effects",
      run: () => {
        if (state.settings.performanceMode) {
          openSettingsCategory("performance");
          return;
        }
        tunePerformanceNow();
        if (state.inspectorMode === "settings" && state.settingsCategory === "quick") renderSettingsInspector();
      }
    },
    {
      id: "focus-mode",
      icon: "focus",
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
      icon: "background",
      label: "App image",
      body: "Set a backdrop for the whole window.",
      meta: () => appearanceBackgroundLabel(state.settings.backgroundImage),
      cta: "Choose",
      search: "background image wallpaper choose local file appearance",
      run: () => chooseBackgroundImage()
    },
    {
      id: "pane-background",
      icon: "paneBackground",
      label: "Terminal image",
      body: "Set an image on only the active terminal.",
      meta: activeTerminalPaneBackgroundLabel,
      cta: "Choose",
      search: "active pane terminal background image specific terminal wallpaper",
      disabled: () => !resolveTerminalPanel(focusedPanel()),
      run: () => choosePanelBackgroundImage()
    },
    {
      id: "pane-settings",
      icon: "paneSettings",
      label: "Pane settings",
      body: "Rename, color, text, image, and URL for the active pane.",
      meta: activePaneSettingsQuickLabel,
      cta: "Open",
      search: "active pane settings customize rename color tab text size background browser url terminal",
      disabled: () => !activePanel(),
      run: () => openPaneSettings(activePaneActionTarget() || activePanel())
    },
    {
      id: "all-terminal-backgrounds",
      icon: "terminalGroup",
      label: "All terminal image",
      body: "Choose one image for every terminal in this workspace.",
      meta: () => {
        const workspace = activeWorkspace();
        const count = workspaceTerminalPanels(workspace).length;
        return count ? `${count} terminal${count === 1 ? "" : "s"}` : "No terminals";
      },
      cta: "Choose",
      search: "all terminal pane background image choose local file wallpaper workspace",
      disabled: () => workspaceTerminalPanels().length === 0,
      run: () => chooseBackgroundImageForTarget({ target: "all" })
    },
    {
      id: "pane-shape",
      icon: "paneShape",
      label: "Pane shape",
      body: "Resize the active pane or switch rows and columns.",
      meta: () => {
        const workspace = activeWorkspace();
        return workspace?.panels?.length > 1 ? `${activePaneLayoutPercent(workspace)}%` : "Single";
      },
      cta: "Edit",
      search: "pane shape split layout resize terminal percent rows columns",
      run: () => openSettingsCategory("layout")
    },
    {
      id: "save-layout",
      icon: "saveLayout",
      label: "Save layout",
      body: "Store this pane shape as a reusable workspace blueprint.",
      meta: () => `${state.workspaceBlueprints.length}/${workspaceBlueprintsLimit}`,
      cta: "Save",
      search: "save layout workspace blueprint panes shape split",
      disabled: () => !canSaveCurrentWorkspaceBlueprint(),
      title: () => currentWorkspaceBlueprintSaveTitle(),
      run: () => saveCurrentWorkspaceBlueprint()
    }
  ];
}

function workspaceNeedsQuickRename(workspace = activeWorkspace()) {
  const title = String(workspace?.title || "").trim();
  if (!workspace || !title) return false;
  if (/^workspace(?:\s+\d+)?$/i.test(title)) return true;
  const folderTitle = workspaceSuggestedTitle(workspace);
  return Boolean(folderTitle && title === workspace.id && folderTitle !== title);
}

function quickSetupRecommendedActionIds(workspace = activeWorkspace()) {
  const panels = (workspace?.panels || []).filter((panel) => !isPendingPanel(panel));
  const terminalCount = panels.filter((panel) => panel.type === "terminal").length;
  const browserCount = panels.filter((panel) => panel.type === "browser").length;
  const activeTerminal = activeTerminalPanelForSettings();
  const ids = [];

  if (!workspace || terminalCount === 0) ids.push("new-terminal");
  if (workspace && browserCount === 0) ids.push("new-browser");
  if (!isSettingsPresetIdActive("simpleFast")) {
    ids.push(state.savedSettingsProfiles.length === 0 ? "save-clean-fast-profile" : "clean-fast");
  }
  if (!state.settings.backgroundImage) ids.push("background");
  else if (activeTerminal && !normalizeBackgroundValue(activeTerminal.backgroundImage)) ids.push("pane-background");
  if (state.savedSettingsProfiles.length === 0 && !ids.includes("save-clean-fast-profile") && ids.length < 4) ids.push("save-profile");
  if (workspaceNeedsQuickRename(workspace)) ids.push("rename");
  if (workspace && panels.length > 1 && !workspaceBlueprintsFull()) ids.push("save-layout");
  if (workspace && panels.length > 0 && ids.length < 4) ids.push("pane-settings");

  return [...new Set(ids)].slice(0, 4);
}

function quickSetupGuidePanel() {
  const actions = quickSetupActionDefinitions();
  const actionById = new Map(actions.map((action) => [action.id, action]));
  const recommended = quickSetupRecommendedActionIds()
    .map((id) => actionById.get(id))
    .filter(Boolean);
  const panel = document.createElement("div");
  panel.className = "quick-setup-guide";
  panel.dataset.settingsSearch = normalizeSettingsQuery("quick setup recommended simple speed background terminal browser rename layout profile save");
  panel.innerHTML = `
    <div class="quick-guide-heading">
      <span class="quick-guide-title"></span>
      <span class="quick-guide-subtitle"></span>
    </div>
    <div class="quick-guide-list"></div>
  `;
  setTextIfChanged(panel.querySelector(".quick-guide-title"), t("quickGuide.title"));
  const subtitle = panel.querySelector(".quick-guide-subtitle");
  const list = panel.querySelector(".quick-guide-list");
  subtitle.textContent = recommended.length
    ? t("quickGuide.subtitleActions")
    : t("quickGuide.subtitleReady");

  if (recommended.length === 0) {
    const done = document.createElement("button");
    done.className = "quick-guide-item is-complete";
    done.type = "button";
    done.dataset.settingsSearch = normalizeSettingsQuery("quick setup ready saved profile settings");
    done.innerHTML = `
      <span class="quick-guide-icon" aria-hidden="true">${quickActionIconMarkup("profiles")}</span>
      <span class="quick-guide-copy">
        <span class="quick-guide-item-title"></span>
        <span class="quick-guide-item-body"></span>
      </span>
      <span class="quick-guide-cta"></span>
    `;
    setTextIfChanged(done.querySelector(".quick-guide-item-title"), t("quickGuide.saveProfile"));
    setTextIfChanged(done.querySelector(".quick-guide-item-body"), t("quickGuide.saveProfile.body"));
    setTextIfChanged(done.querySelector(".quick-guide-cta"), t("quickGuide.profiles"));
    done.title = `${t("quickGuide.saveProfile")}: ${t("quickGuide.saveProfile.body")}`;
    done.setAttribute("aria-label", done.title);
    done.onclick = () => openSettingsCategory("profiles");
    list.append(done);
    return panel;
  }

  for (const action of recommended) {
    const item = document.createElement("button");
    item.className = "quick-guide-item";
    item.type = "button";
    item.disabled = Boolean(action.disabled?.());
    const title = action.title?.() || `${action.label}: ${action.body}`;
    item.dataset.quickGuideAction = action.id;
    item.dataset.settingsSearch = normalizeSettingsQuery(`quick recommended ${action.label} ${action.body} ${action.search}`);
    item.title = title;
    item.setAttribute("aria-label", `${action.label}. ${action.body} Current: ${action.meta()}.`);
    item.innerHTML = `
      <span class="quick-guide-icon" aria-hidden="true"></span>
      <span class="quick-guide-copy">
        <span class="quick-guide-item-title"></span>
        <span class="quick-guide-item-body"></span>
      </span>
      <span class="quick-guide-side">
        <span class="quick-guide-meta"></span>
        <span class="quick-guide-cta"></span>
      </span>
    `;
    item.querySelector(".quick-guide-icon").innerHTML = quickActionIconMarkup(action.icon);
    item.querySelector(".quick-guide-item-title").textContent = action.label;
    item.querySelector(".quick-guide-item-body").textContent = action.body;
    item.querySelector(".quick-guide-meta").textContent = action.meta();
    item.querySelector(".quick-guide-cta").textContent = action.cta;
    item.onclick = () => {
      if (item.disabled) return;
      action.run();
    };
    list.append(item);
  }
  return panel;
}

function quickSetupActionGrid() {
  const actions = quickSetupActionDefinitions();
  const grid = document.createElement("div");
  grid.className = "quick-settings-shortcut-grid quick-action-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("quick actions new terminal browser add pane clean ui speed tune focus mode background image wallpaper pane shape resize split rows columns");
  for (const action of actions) {
    const active = Boolean(action.active?.());
    const disabled = Boolean(action.disabled?.()) || (active && action.activeDisabled !== false);
    const button = document.createElement("button");
    button.className = `quick-settings-shortcut quick-action${active ? " is-active" : ""}`;
    button.type = "button";
    button.disabled = disabled;
    button.title = action.title?.() || `${action.label}: ${action.body}`;
    button.dataset.quickAction = action.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`quick action ${action.label} ${action.body} ${action.search} ${active ? "active details" : ""}`);
    button.setAttribute("aria-label", `${action.label}. ${action.body} Current: ${action.meta()}.${active ? " Active." : ""}`);
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
    button.querySelector(".quick-action-icon").innerHTML = quickActionIconMarkup(action.icon);
    button.querySelector(".quick-settings-shortcut-title").textContent = action.label;
    button.querySelector(".quick-settings-shortcut-body").textContent = action.body;
    button.querySelector(".quick-settings-shortcut-meta").textContent = action.meta();
    button.querySelector(".quick-action-cta").textContent = active ? action.activeCta || "Active" : action.cta;
    button.onclick = () => {
      if (button.disabled) return;
      action.run();
    };
    grid.append(button);
  }
  return grid;
}

function ensureSettingsDisclosureContent(disclosure) {
  if (!disclosure || disclosure.dataset.disclosureMounted === "true") return false;
  const contentBuilder = {
    "appearance-saved-colors": savedColorPalettePanel,
    "appearance-theme-gallery": themeChoiceGrid,
    "background-presets": backgroundPresetGrid,
    "browser-home-presets": browserHomePresetGrid,
    "browser-recent-pages": recentBrowserPagesSettings,
    "command-snippets": commandSnippetsSettings,
    "data-recent-commands": recentCommandsSettings,
    "data-storage-breakdown": dataStorageBreakdownPanel,
    "layout-pane-presets": paneLayoutPresetGrid,
    "quick-actions": quickSetupActionGrid,
    "quick-categories": quickSettingsShortcutGrid,
    "quick-presets": settingsPresetGrid,
    "recent-folders": recentFoldersSettings,
    "saved-backgrounds": savedBackgroundImagesPanel,
    "settings-profiles": settingsProfilesPanel,
    "settings-command-list": settingsCommandList,
    "terminal-colors": terminalColorPresetGrid,
    "terminal-fonts": terminalFontChoiceGrid,
    "workspace-starters": workspaceStarterGrid,
    "workspace-blueprints": workspaceBlueprintsPanel
  }[disclosure.dataset.disclosureContent];
  if (!contentBuilder) return false;
  disclosure.append(contentBuilder());
  disclosure.dataset.disclosureMounted = "true";
  return true;
}

function settingsDisclosurePanel({ className, content, searchTerms, title, body, meta }) {
  const shouldMount = Boolean(normalizeSettingsQuery(state.settingsQuery));
  const details = document.createElement("details");
  details.className = `settings-disclosure ${className}`.trim();
  details.open = shouldMount;
  details.dataset.disclosureContent = content;
  details.dataset.disclosureMounted = "false";
  details.dataset.settingsSearch = normalizeSettingsQuery(searchTerms);
  const summary = document.createElement("summary");
  summary.className = "settings-disclosure-summary";
  summary.innerHTML = `
    <span class="settings-disclosure-copy">
      <span class="settings-disclosure-title"></span>
      <span class="settings-disclosure-body"></span>
    </span>
    <span class="settings-disclosure-meta"></span>
  `;
  setTextIfChanged(summary.querySelector(".settings-disclosure-title"), title);
  setTextIfChanged(summary.querySelector(".settings-disclosure-body"), body);
  setTextIfChanged(summary.querySelector(".settings-disclosure-meta"), meta);
  details.append(summary);
  if (shouldMount) ensureSettingsDisclosureContent(details);
  details.addEventListener("toggle", () => {
    if (details.open) ensureSettingsDisclosureContent(details);
    else if (normalizeSettingsQuery(state.settingsQuery)) state.settingsSearchDisclosuresOpenVersion = 0;
  });
  return details;
}

function quickActionDisclosurePanel() {
  const actions = quickSetupActionDefinitions();
  return settingsDisclosurePanel({
    className: "quick-action-disclosure",
    content: "quick-actions",
    searchTerms: "quick setup all actions terminal browser clean speed focus background layout active pane settings rename color",
    title: t("quickGuide.allActions"),
    body: t("quickGuide.allActions.body"),
    meta: formatMessage("quickGuide.actionCount", { count: actions.length })
  });
}

function quickCategoryDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "quick-category-disclosure",
    content: "quick-categories",
    searchTerms: "quick setup settings pages shortcuts customize workspace appearance layout terminal browser performance profiles data",
    title: t("quickGuide.settingsPages"),
    body: t("quickGuide.settingsPages.body"),
    meta: formatMessage("quickGuide.pageCount", { count: quickSettingsShortcuts.length })
  });
}

function quickPresetDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "quick-preset-disclosure",
    content: "quick-presets",
    searchTerms: "quick setup presets theme appearance color layout terminal browser performance focus clean style",
    title: t("quickGuide.presets"),
    body: t("quickGuide.presets.body"),
    meta: formatMessage("quickGuide.presetCount", { count: settingsPresets.length })
  });
}

function appearanceBackgroundTemplateDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "appearance-background-disclosure",
    content: "background-presets",
    searchTerms: "appearance background templates preset wallpaper image app active pane terminal all terminals",
    title: t("appearance.backgroundTemplates"),
    body: t("appearance.backgroundTemplates.body"),
    meta: formatMessage("appearance.backgroundTemplateCount", { count: backgroundPresets.length })
  });
}

function savedBackgroundDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "appearance-saved-background-disclosure",
    content: "saved-backgrounds",
    searchTerms: "appearance saved backgrounds image wallpaper library apply rename delete save paste choose",
    title: t("appearance.savedBackgrounds"),
    body: t("appearance.savedBackgrounds.body"),
    meta: formatMessage("appearance.savedBackgroundCount", { count: state.savedBackgroundImages.length })
  });
}

function terminalFontDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "terminal-font-disclosure",
    content: "terminal-fonts",
    searchTerms: "terminal font gallery preview cascadia consolas jetbrains fira mono typeface",
    title: t("terminal.fontGallery"),
    body: t("terminal.fontGallery.body"),
    meta: formatMessage("terminal.fontCount", { count: terminalFontOptions.length })
  });
}

function terminalColorDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "terminal-color-disclosure",
    content: "terminal-colors",
    searchTerms: "terminal color theme preset powershell high contrast light warm graphite default foreground background cursor",
    title: t("terminal.colorPresets"),
    body: t("terminal.colorPresets.body"),
    meta: formatMessage("terminal.colorPresetCount", { count: terminalColorPresets.length })
  });
}

function settingsCommandListDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "settings-command-list-disclosure",
    content: "settings-command-list",
    searchTerms: "actions commands shortcuts keyboard palette run tools all command list groups",
    title: t("actions.commandList"),
    body: t("actions.commandList.body"),
    meta: formatMessage("actions.commandCount", { count: commands.length })
  });
}

function settingsProfilesDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "settings-profiles-disclosure",
    content: "settings-profiles",
    searchTerms: "profiles saved settings profile preset apply save rename delete built in appearance layout terminal performance",
    title: t("profiles.savedProfiles"),
    body: t("profiles.savedProfiles.body"),
    meta: formatMessage("profiles.savedProfileCount", {
      count: state.savedSettingsProfiles.length,
      limit: savedSettingsProfilesLimit
    })
  });
}

function workspaceBlueprintsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "workspace-blueprints-disclosure",
    content: "workspace-blueprints",
    searchTerms: "blueprints saved workspace layout pane template terminal browser split apply new save update rename delete starter layouts",
    title: t("blueprints.savedBlueprints"),
    body: t("blueprints.savedBlueprints.body"),
    meta: formatMessage("blueprints.savedBlueprintCount", {
      count: state.workspaceBlueprints.length,
      limit: workspaceBlueprintsLimit
    })
  });
}

function commandSnippetsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "command-snippets-disclosure",
    content: "command-snippets",
    searchTerms: "commands snippets terminal launcher saved built in custom git github gh cli add edit delete run",
    title: t("commands.snippets"),
    body: t("commands.snippets.body"),
    meta: formatMessage("commands.snippetCount", {
      count: state.customCommandSnippets.length,
      limit: customCommandSnippetsLimit
    })
  });
}

function recentFoldersDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "recent-folders-disclosure",
    content: "recent-folders",
    searchTerms: "workspace recent folders recent workspace folder history directory cwd quick reopen",
    title: t("workspace.recentFolders"),
    body: t("workspace.recentFolders.body"),
    meta: formatMessage("workspace.recentFolderCount", {
      count: state.recentFolders.length,
      limit: recentFoldersLimit
    })
  });
}

function workspaceStartersDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "workspace-starters-disclosure",
    content: "workspace-starters",
    searchTerms: "workspace starter layout preset split terminal browser dev trio setup",
    title: t("workspace.starters"),
    body: t("workspace.starters.body"),
    meta: formatMessage("workspace.starterCount", { count: workspaceStarters.length })
  });
}

function appearanceThemeGalleryDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "appearance-theme-gallery-disclosure",
    content: "appearance-theme-gallery",
    searchTerms: "appearance theme visual gallery preview color palette",
    title: t("appearance.themeGallery"),
    body: t("appearance.themeGallery.body"),
    meta: formatMessage("appearance.themeCount", { count: themeOptions.length })
  });
}

function savedColorsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "appearance-saved-colors-disclosure",
    content: "appearance-saved-colors",
    searchTerms: "appearance saved color palette custom accent workspace tab pane color",
    title: t("appearance.savedColors"),
    body: t("appearance.savedColors.body"),
    meta: formatMessage("appearance.savedColorCount", {
      count: state.customColorPalette.length,
      limit: customColorPaletteLimit
    })
  });
}

function browserHomePresetsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "browser-home-presets-disclosure",
    content: "browser-home-presets",
    searchTerms: "browser home preset quick start localhost github google vite",
    title: t("browser.homePresets"),
    body: t("browser.homePresets.body"),
    meta: formatMessage("browser.homePresetCount", { count: browserHomePresets.length })
  });
}

function recentBrowserPagesDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "browser-recent-pages-disclosure",
    content: "browser-recent-pages",
    searchTerms: "browser recent pages urls web history open home clear",
    title: t("browser.recentPages"),
    body: t("browser.recentPages.body"),
    meta: formatMessage("browser.recentPageCount", {
      count: state.recentBrowserPages.length,
      limit: recentBrowserPagesLimit
    })
  });
}

function paneLayoutPresetsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "pane-layout-presets-disclosure",
    content: "layout-pane-presets",
    searchTerms: "layout split layout pane presets side by side stacked active wide tall equal",
    title: t("layout.panePresets"),
    body: t("layout.panePresets.body"),
    meta: formatMessage("layout.panePresetCount", { count: paneLayoutPresets.length })
  });
}

function dataStorageBreakdownDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "data-storage-breakdown-disclosure",
    content: "data-storage-breakdown",
    searchTerms: "data storage breakdown local settings metric saved recent cleanup",
    title: t("data.storageBreakdown"),
    body: t("data.storageBreakdown.body"),
    meta: formatMessage("data.storageEntryCount", { count: dataStorageEntries().length })
  });
}

function recentCommandsDisclosurePanel() {
  return settingsDisclosurePanel({
    className: "data-recent-commands-disclosure",
    content: "data-recent-commands",
    searchTerms: "data recent terminal commands shell command history run clear snippets",
    title: t("data.recentCommands"),
    body: t("data.recentCommands.body"),
    meta: formatMessage("data.recentCommandCount", {
      count: state.recentCommands.length,
      limit: recentCommandsLimit
    })
  });
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
      saveLabel: "Save",
      targetLabel: "Workspace",
      targetMeta: workspaceDisplayTitle(workspace),
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
        saveLabel: "Save",
        targetLabel: panel.type === "browser" ? "Browser pane" : "Terminal pane",
        targetMeta: panelDisplayTitle(panel, true),
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
  for (const [category, label, body, meta, icon] of quickSettingsShortcuts) {
    const button = document.createElement("button");
    button.className = "quick-settings-shortcut quick-category";
    button.type = "button";
    button.dataset.settingsSearch = normalizeSettingsQuery(`quick setup shortcut ${label} ${body} ${category}`);
    button.innerHTML = `
      <span class="quick-category-icon" aria-hidden="true"></span>
      <span class="quick-category-copy">
        <span class="quick-settings-shortcut-title"></span>
        <span class="quick-settings-shortcut-body"></span>
      </span>
      <span class="quick-settings-shortcut-meta"></span>
    `;
    button.querySelector(".quick-category-icon").innerHTML = quickActionIconMarkup(icon);
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

function performanceOverviewModel() {
  updateTerminalOutputBacklog();
  const queuedBytes = state.terminalOutputStats.currentQueued || 0;
  const lastRenderMs = state.renderStats.lastMs || 0;
  const avgRenderMs = state.renderStats.avgMs || 0;
  const pendingPanes = state.pendingPanels.size;
  const pausedOutput = pausedTerminalOutputCount();
  const guard = state.settings.performanceMode
    ? "Tuned"
    : state.settings.adaptivePerformance
      ? (state.performanceGuardTriggered ? "Auto tuned" : "Watching")
      : "Off";
  const hasBacklog = queuedBytes >= terminalOutputBacklogThreshold;
  const slowRender = lastRenderMs >= renderSlowFrameMs || avgRenderMs >= renderSlowFrameMs;
  const verySlowRender = lastRenderMs >= renderVerySlowFrameMs || avgRenderMs >= renderVerySlowFrameMs;
  const slowPaneAdd = state.paneCreateStats.lastMs >= performanceGuardSlowPaneCreateMs
    || state.paneCreateStats.avgMs >= performanceGuardSlowPaneCreateMs;
  const slowShellConnect = state.terminalConnectStats.lastMs >= performanceGuardSlowTerminalConnectMs
    || state.terminalConnectStats.avgMs >= performanceGuardSlowTerminalConnectMs;
  const status = state.settings.performanceMode
    ? "tuned"
    : hasBacklog || verySlowRender || slowPaneAdd || slowShellConnect
      ? "warning"
      : slowRender || pendingPanes > 0
        ? "watching"
        : "steady";
  const title = status === "tuned"
    ? "Speed tune active"
    : status === "warning"
      ? "Needs attention"
      : status === "watching"
        ? "Watching load"
        : "Running steady";
  const reason = performanceOverviewReason({
    hasBacklog,
    pendingPanes,
    slowPaneAdd,
    slowRender,
    slowShellConnect,
    verySlowRender
  });
  return {
    status,
    title,
    reason,
    guard,
    render: `${formatMs(lastRenderMs)} last / ${formatMs(avgRenderMs)} avg`,
    output: queuedBytes ? `${formatBytes(queuedBytes)} queued` : "Clean",
    shell: durationMetric(state.terminalConnectStats),
    paneAdd: durationMetric(state.paneCreateStats),
    startup: optionLabel(terminalStartupOptions, state.settings.terminalStartupMode, "Fast"),
    paused: pausedOutput ? `${pausedOutput} paused` : "None",
    pending: pendingPanes ? `${pendingPanes} pending` : "None"
  };
}

function performanceOverviewReason({
  hasBacklog = false,
  pendingPanes = 0,
  slowPaneAdd = false,
  slowRender = false,
  slowShellConnect = false,
  verySlowRender = false
} = {}) {
  if (state.performanceGuardTriggered && state.performanceGuardReason) return state.performanceGuardReason;
  if (state.settings.performanceMode) return "Effects and hidden output are reduced.";
  if (hasBacklog) return "Terminal output backlog is building.";
  if (verySlowRender) return "Rendering is taking longer than expected.";
  if (slowPaneAdd) return "New panes are taking longer than expected.";
  if (slowShellConnect) return "Terminal shell connection is taking longer than expected.";
  if (slowRender) return "Rendering is being watched for repeated slow frames.";
  if (pendingPanes > 0) return "Pane creation is still in progress.";
  if (state.settings.adaptivePerformance) return "Adaptive guard will tune if rendering, output, or pane startup stalls.";
  return "Adaptive guard is disabled.";
}

function performanceOverviewPanel() {
  return createPerformanceOverviewPanel({
    createActionButton: settingsActionButton,
    model: performanceOverviewModel(),
    onBalanced: () => applySettingsPresetById("balanced"),
    onSearchChange: updateSettingsSearchIndexItemSearch,
    onTune: () => tunePerformanceNow()
  });
}

function refreshPerformanceOverviewPanel(panel = elements.inspectorBody.querySelector("[data-performance-overview]")) {
  return refreshPerformanceOverviewPanelView(panel, performanceOverviewModel(), {
    onSearchChange: updateSettingsSearchIndexItemSearch
  });
}

function performanceMetricsShouldRefresh() {
  return state.inspectorMode === "settings"
    && (state.settingsCategory === "performance" || normalizeSettingsQuery(state.settingsQuery));
}

function schedulePerformanceMetricsRefresh() {
  if (!performanceMetricsShouldRefresh()) return;
  if (state.performanceMetricsRefreshFrame || state.performanceMetricsRefreshTimer) return;
  const delay = Math.max(0, performanceMetricsRefreshMinMs - (performance.now() - state.performanceMetricsRefreshAt));
  const enqueueFrame = () => {
    state.performanceMetricsRefreshTimer = 0;
    state.performanceMetricsRefreshFrame = requestAnimationFrame(() => {
      state.performanceMetricsRefreshFrame = 0;
      state.performanceMetricsRefreshAt = performance.now();
      if (performanceMetricsShouldRefresh()) refreshPerformanceMetricsGrid();
    });
  };
  if (delay > 0) {
    state.performanceMetricsRefreshTimer = window.setTimeout(enqueueFrame, delay);
    return;
  }
  enqueueFrame();
}

function refreshPerformanceMetricsGrid() {
  const overviewChanged = refreshPerformanceOverviewPanel();
  const grid = elements.inspectorBody.querySelector('[data-performance-metrics="true"]');
  if (!grid) return overviewChanged;
  const metrics = performanceMetrics();
  const cards = [...grid.querySelectorAll(".settings-metric")];
  if (cards.length !== metrics.length) {
    replaceChildrenIfChanged(grid, metrics.map(([label, value]) => settingsMetricCard(label, value)));
    rebuildSettingsSearchIndex();
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
  return overviewChanged || changed;
}

function paneShapePanel(workspace = activeWorkspace()) {
  const panel = activePanel();
  const hasPendingPane = Boolean(workspace?.panels?.some(isPendingPanel));
  const multiPane = Boolean(workspace && panel && workspace.panels.length > 1 && !hasPendingPane);
  const percent = multiPane ? activePaneLayoutPercent(workspace) : 50;
  const direction = paneLayoutDirection(workspace);
  const directionLabel = paneLayoutDirectionLabel(workspace);
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
    <span class="pane-shape-stats" aria-label="Pane shape details">
      <span class="pane-shape-stat" data-pane-shape-stat="target"></span>
      <span class="pane-shape-stat" data-pane-shape-stat="direction"></span>
      <span class="pane-shape-stat" data-pane-shape-stat="range"></span>
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
    <span class="pane-shape-quick" role="group" aria-label="Quick pane sizes"></span>
    <span class="pane-shape-actions">
      <span class="pane-shape-action-group pane-shape-action-group-size" role="group" aria-label="Pane size actions"></span>
      <span class="pane-shape-action-group pane-shape-action-group-layout" role="group" aria-label="Pane layout actions"></span>
    </span>
  `;
  const titleNode = wrapper.querySelector(".pane-shape-title");
  const valueNode = wrapper.querySelector(".pane-shape-slider-value");
  let rangePreviewFrame = 0;
  let rangePreviewPercent = percent;
  let quickButtons = [];
  let smaller = null;
  let bigger = null;
  let exact = null;
  let equal = null;
  let side = null;
  let stack = null;
  const updateControlStates = (nextPercent) => {
    if (smaller) smaller.disabled = !multiPane || nextPercent <= paneLayoutPercentMin;
    if (bigger) bigger.disabled = !multiPane || nextPercent >= paneLayoutPercentMax;
    if (exact) exact.disabled = !multiPane;
    if (equal) equal.disabled = !multiPane;
    if (side) side.disabled = !multiPane;
    if (stack) stack.disabled = !multiPane;
    for (const button of quickButtons) {
      const isActive = Number(button.dataset.percent || 0) === nextPercent;
      button.disabled = !multiPane;
      button.classList.toggle("is-active", isActive);
      button.setAttribute("aria-pressed", String(isActive));
    }
  };
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
  wrapper.querySelector('[data-pane-shape-stat="target"]').textContent = multiPane
    ? formatMessage("paneShape.activeTarget", { title: panelTitle })
    : t("paneShape.noPane");
  wrapper.querySelector('[data-pane-shape-stat="direction"]').textContent = directionLabel;
  wrapper.querySelector('[data-pane-shape-stat="range"]').textContent = formatMessage("paneShape.range", {
    min: paneLayoutPercentMin,
    max: paneLayoutPercentMax
  });
  wrapper.querySelector(".pane-shape-slider-label").textContent = t("paneShape.size");
  const range = wrapper.querySelector(".pane-shape-range");
  const number = wrapper.querySelector(".pane-shape-number");
  const syncPercentInputs = (nextPercent) => {
    range.value = String(nextPercent);
    number.value = String(nextPercent);
    updatePercentView(nextPercent);
    updateControlStates(nextPercent);
  };
  const cancelRangePreview = () => {
    if (!rangePreviewFrame) return;
    cancelAnimationFrame(rangePreviewFrame);
    rangePreviewFrame = 0;
  };
  const scheduleRangePreview = (nextPercent) => {
    rangePreviewPercent = nextPercent;
    if (rangePreviewFrame) return;
    rangePreviewFrame = requestAnimationFrame(() => {
      rangePreviewFrame = 0;
      const appliedPercent = applyActivePaneLayoutPercent(rangePreviewPercent, { render: false });
      syncPercentInputs(appliedPercent);
    });
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
    const nextPercent = clampPaneLayoutPercent(range.value);
    syncPercentInputs(nextPercent);
    scheduleRangePreview(nextPercent);
  };
  range.onchange = () => {
    cancelRangePreview();
    const nextPercent = applyActivePaneLayoutPercent(range.value, { save: true, toast: true });
    syncPercentInputs(nextPercent);
  };
  number.onchange = () => {
    cancelRangePreview();
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
  const quick = wrapper.querySelector(".pane-shape-quick");
  quickButtons = [10, 25, 33, 50, 67, 75, 90].map((quickPercent) => {
    const button = document.createElement("button");
    button.className = "pane-shape-quick-button";
    button.type = "button";
    button.dataset.percent = String(quickPercent);
    button.dataset.settingsSearch = normalizeSettingsQuery(`pane shape quick size ${quickPercent} percent split layout`);
    button.textContent = `${quickPercent}%`;
    button.title = `Set active pane to ${quickPercent}%`;
    button.setAttribute("aria-pressed", "false");
    button.onclick = () => {
      const nextPercent = applyActivePaneLayoutPercent(quickPercent, { save: true, toast: true });
      syncPercentInputs(nextPercent);
    };
    return button;
  });
  quick.append(...quickButtons);
  const actions = wrapper.querySelector(".pane-shape-actions");
  const sizeActions = actions.querySelector(".pane-shape-action-group-size");
  const layoutActions = actions.querySelector(".pane-shape-action-group-layout");
  smaller = settingsActionButton(t("paneShape.smaller"), () => adjustActivePaneLayoutPercent(-1), "", "pane shape smaller reduce active pane size one percent");
  exact = settingsActionButton(t("paneShape.exact"), promptActivePaneLayoutPercent, "", "pane shape exact active pane size percent dialog");
  bigger = settingsActionButton(t("paneShape.bigger"), () => adjustActivePaneLayoutPercent(1), "", "pane shape bigger increase active pane size one percent");
  smaller.title = "Nudge active pane smaller by 1%.";
  exact.title = "Enter an exact active pane size.";
  bigger.title = "Nudge active pane larger by 1%.";
  equal = settingsActionButton(t("paneShape.equal"), resetActivePaneLayout, "", "pane shape equalize reset split layout");
  side = settingsActionButton(t("paneShape.columns"), () => applyPaneLayoutPreset("sideBySide"), "", "pane shape side by side columns");
  stack = settingsActionButton(t("paneShape.rows"), () => applyPaneLayoutPreset("stacked"), "", "pane shape stacked rows");
  sizeActions.append(smaller, exact, bigger);
  layoutActions.append(equal, side, stack);
  syncPercentInputs(percent);
  return wrapper;
}

function paneLayoutPresetGrid() {
  const workspace = activeWorkspace();
  const disabled = !workspace || workspace.panels.length <= 1;
  const activePresetIds = disabled ? new Set() : activePaneLayoutPresetIds(workspace);
  const grid = document.createElement("div");
  grid.className = "pane-layout-preset-grid";
  grid.dataset.settingsSearch = normalizeSettingsQuery("split layout pane presets side by side stacked active wide tall equal");
  for (const preset of paneLayoutPresets) {
    const active = activePresetIds.has(preset.id);
    const button = document.createElement("button");
    button.className = `pane-layout-preset${active ? " is-active" : ""}`;
    button.type = "button";
    button.disabled = disabled;
    button.dataset.presetId = preset.id;
    button.dataset.settingsSearch = normalizeSettingsQuery(`split layout pane preset ${active ? "active current " : ""}${preset.label} ${preset.body}`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.innerHTML = `
      <span class="pane-layout-preset-icon" aria-hidden="true">
        <span></span><span></span><span></span><span></span>
      </span>
      <span class="pane-layout-preset-copy">
        <span class="pane-layout-preset-title-row">
          <span class="pane-layout-preset-title"></span>
        </span>
        <span class="pane-layout-preset-body"></span>
      </span>
    `;
    button.querySelector(".pane-layout-preset-title").textContent = preset.label;
    if (active) {
      const status = document.createElement("span");
      status.className = "pane-layout-preset-status";
      status.textContent = "Active";
      button.querySelector(".pane-layout-preset-title-row").append(status);
    }
    button.querySelector(".pane-layout-preset-body").textContent = preset.body;
    button.onclick = () => applyPaneLayoutPreset(preset.id);
    grid.append(button);
  }
  return grid;
}

function paneLayoutPresetTreeForWorkspace(preset, workspace, activePanelId, currentTree = null) {
  if (!preset || !workspace || workspace.panels.length <= 1) return null;
  if (preset.id === "equal") return equalizePaneTree(currentTree || paneTreeForWorkspace(workspace));
  if (preset.mode === "grid") return buildGridPanePresetTree(workspace.panels.map((panel) => panel.id));
  const direction = preset.direction || paneLayoutDirection(workspace);
  if (preset.mode === "active") {
    return buildActivePanePresetTree(workspace.panels, activePanelId, direction, workspace.panels.length === 2 ? 68 : 60);
  }
  return buildPaneTreeFromPanelIds(workspace.panels.map((panel) => panel.id), direction);
}

function activePaneLayoutPresetIds(workspace = activeWorkspace()) {
  const ids = new Set();
  if (!workspace || workspace.panels.length <= 1) return ids;
  const currentTree = paneTreeForWorkspace(workspace);
  const activePanelId = workspace.panels.some((panel) => panel.id === workspace.activePanelId)
    ? workspace.activePanelId
    : workspace.panels[0]?.id;
  for (const preset of paneLayoutPresets) {
    if (preset.id === "equal") continue;
    if (preset.id === "grid" && workspace.panels.length <= 2) continue;
    const expected = paneLayoutPresetTreeForWorkspace(preset, workspace, activePanelId, currentTree);
    if (expected && paneTreeEqual(currentTree, expected)) ids.add(preset.id);
  }
  if (ids.size === 0) {
    const equal = paneLayoutPresetTreeForWorkspace(paneLayoutPresets.find((preset) => preset.id === "equal"), workspace, activePanelId, currentTree);
    if (equal && paneTreeEqual(currentTree, equal)) ids.add("equal");
  }
  return ids;
}

function paneLayoutDirectionLabel(workspace = activeWorkspace()) {
  return paneLayoutDirection(workspace) === "down" ? t("paneShape.stackedRows") : t("paneShape.sideBySideColumns");
}

function activePaneLayoutPresetLabel(workspace = activeWorkspace()) {
  if (!workspace?.panels?.length) return "None";
  if (workspace.panels.length <= 1) return "Single";
  const activeIds = activePaneLayoutPresetIds(workspace);
  const activePreset = paneLayoutPresets.find((preset) => activeIds.has(preset.id));
  return activePreset?.label || "Custom";
}

function activePaneLayoutCommandIds(workspace = activeWorkspace()) {
  const ids = new Set();
  if (!workspace || workspace.panels.length <= 1) return ids;
  const activePresetIds = activePaneLayoutPresetIds(workspace);
  for (const [commandId, presetId] of paneLayoutCommandPresetIds.entries()) {
    if (activePresetIds.has(presetId)) ids.add(commandId);
  }
  return ids;
}

function resetRenderStats() {
  if (!hasPerformanceStats()) {
    toast("Performance stats already clear.");
    return false;
  }
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
  if (state.performanceMetricsRefreshTimer) window.clearTimeout(state.performanceMetricsRefreshTimer);
  if (state.performanceMetricsRefreshFrame) cancelAnimationFrame(state.performanceMetricsRefreshFrame);
  state.performanceMetricsRefreshTimer = 0;
  state.performanceMetricsRefreshFrame = 0;
  state.performanceMetricsRefreshAt = 0;
  renderSettingsInspector();
  toast("Performance stats reset.");
  return true;
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
    paneColorMarkers: false,
    showStatusbar: false,
    terminalPadding: Math.min(state.settings.terminalPadding, 4),
    terminalScrollback: Math.min(state.settings.terminalScrollback, 6000),
    terminalStartupMode: "fast",
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
  let target = [...elements.inspectorBody.querySelectorAll(".settings-command-group")]
    .find((node) => node.dataset.commandGroup === group);
  if (!target) {
    const disclosure = elements.inspectorBody.querySelector('[data-disclosure-content="settings-command-list"]');
    if (disclosure) {
      disclosure.open = true;
      ensureSettingsDisclosureContent(disclosure);
      target = [...elements.inspectorBody.querySelectorAll(".settings-command-group")]
        .find((node) => node.dataset.commandGroup === group);
    }
  }
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
  const activeLayoutCommandIds = activePaneLayoutCommandIds();
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
      groupNode.append(settingsCommandCard(command, group, activeLayoutCommandIds.has(command.id)));
    }
    list.append(groupNode);
  }
  return list;
}

function settingsCommandCard(command, group, active = false) {
  const card = document.createElement("div");
  card.className = `settings-command-card${active ? " is-active" : ""}`;
  card.dataset.settingsSearch = normalizeSettingsQuery(`actions commands shortcuts keyboard palette run ${active ? "active current " : ""}${group} ${command.id} ${command.label} ${command.shortcut}`);
  const text = document.createElement("div");
  text.className = "settings-command-text";
  const labelRow = document.createElement("span");
  labelRow.className = "settings-command-label-row";
  const label = document.createElement("span");
  label.className = "settings-command-label";
  label.textContent = command.label;
  labelRow.append(label);
  if (active) {
    const status = document.createElement("span");
    status.className = "settings-command-status";
    status.textContent = "Active";
    labelRow.append(status);
  }
  const id = document.createElement("span");
  id.className = "settings-command-id";
  id.textContent = command.id;
  text.append(labelRow, id);
  const shortcut = document.createElement("span");
  shortcut.className = "settings-command-shortcut";
  shortcut.textContent = active ? "Active" : command.shortcut || "Palette";
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
  const cursorSelect = elements.inspectorBody.querySelector('[data-setting-control="terminalCursorStyle"]');
  if (cursorSelect && cursorSelect.value !== state.settings.terminalCursorStyle) {
    cursorSelect.value = state.settings.terminalCursorStyle;
  }
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

function colorSummaryLabel(activeColor, fallbackColor = "#5d8cff") {
  const color = String(activeColor || "").trim();
  const fallback = String(fallbackColor || "").trim();
  if (!color) return `Default ${colorSummaryValue(fallback)}`;
  return colorSummaryValue(color);
}

function colorSummaryValue(color) {
  const value = String(color || "").trim();
  if (!value) return "None";
  if (isSafeCustomColor(value)) return value.toUpperCase();
  return "Palette color";
}

function colorControlPanel({
  colors,
  activeColor,
  fallbackColor = "#5d8cff",
  onPick,
  onClear,
  clearLabel = "Default",
  clearDisabled = false,
  saveLabel = "",
  targetLabel = "",
  targetMeta = "",
  searchTerms = ""
}) {
  const panel = document.createElement("div");
  panel.className = `settings-color-panel${onClear ? " has-clear" : ""}${saveLabel ? " has-save" : ""}`;
  panel.dataset.settingsSearch = normalizeSettingsQuery(`color palette swatch custom hex picker save ${targetLabel} ${targetMeta} ${searchTerms}`);
  const summary = document.createElement("div");
  summary.className = `settings-color-summary${targetLabel ? " has-target" : ""}`;
  summary.style.setProperty("--settings-color-current", activeColor || fallbackColor);
  summary.innerHTML = `
    <span class="settings-color-summary-swatch" aria-hidden="true"></span>
    <span class="settings-color-summary-copy">
      <span class="settings-color-summary-label">Current</span>
      <span class="settings-color-summary-value"></span>
    </span>
  `;
  summary.querySelector(".settings-color-summary-value").textContent = colorSummaryLabel(activeColor, fallbackColor);
  if (targetLabel) {
    const target = document.createElement("span");
    target.className = "settings-color-target";
    target.innerHTML = `
      <span class="settings-color-target-label"></span>
      <span class="settings-color-target-meta"></span>
    `;
    target.querySelector(".settings-color-target-label").textContent = targetLabel;
    target.querySelector(".settings-color-target-meta").textContent = targetMeta || "selected target";
    target.title = targetMeta ? `${targetLabel}: ${targetMeta}` : targetLabel;
    summary.append(target);
  }
  panel.append(summary);
  panel.append(swatchGrid(colors, activeColor, onPick));

  const custom = document.createElement("div");
  custom.className = "settings-color-custom";
  const picker = colorPicker(activeColor, onPick, fallbackColor);
  custom.append(picker);
  if (saveLabel) {
    const save = settingsActionButton(saveLabel, () => {
      const input = picker.querySelector(".color-picker-input");
      upsertCustomColorPalette(input?.value || activeColor || fallbackColor);
    }, "", `color save custom palette ${searchTerms}`);
    save.classList.add("settings-color-save");
    custom.append(save);
  }
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
  const workspace = activeWorkspace();
  const colorTarget = normalizeColorApplyTarget(state.colorApplyTarget);
  const targetOption = colorApplyTargetOption(colorTarget, workspace);
  const targetLabel = colorApplyTargetActionLabel(colorTarget, workspace);

  const addRow = document.createElement("div");
  addRow.className = "saved-color-add";
  const colorInput = document.createElement("input");
  colorInput.className = "saved-color-input";
  colorInput.type = "color";
  colorInput.value = colorInputValue(targetOption.color || state.settings.accent);
  colorInput.dataset.settingsSearch = normalizeSettingsQuery("saved color custom color picker hex");
  const applyPicked = settingsActionButton(colorApplyTargetPrimaryLabel(colorTarget), () => applySavedColorToTarget(colorInput.value, state.colorApplyTarget), "primary", "saved color custom picker apply selected target accent workspace pane all");
  applyPicked.disabled = Boolean(targetOption.disabled);
  applyPicked.title = `Apply picked color to ${targetLabel}`;
  const savePicked = settingsActionButton("Save color", () => upsertCustomColorPalette(colorInput.value), "", "saved color custom palette add");
  const refreshSavePickedState = () => applyCustomColorSaveLimit(savePicked, colorInput.value, "Save the picked color to the reusable palette.");
  refreshSavePickedState();
  colorInput.addEventListener("input", refreshSavePickedState);
  colorInput.addEventListener("change", refreshSavePickedState);
  addRow.append(colorInput, applyPicked, savePicked);
  panel.append(addRow);
  panel.append(activeColorTargetControl());

  const actions = document.createElement("div");
  actions.className = "settings-actions saved-color-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("saved color palette save current accent workspace");
  const saveAccent = settingsActionButton("Save accent", () => upsertCustomColorPalette(state.settings.accent), "", "saved color save current accent");
  applyCustomColorSaveLimit(saveAccent, state.settings.accent, "Save the current accent color.");
  const saveWorkspace = settingsActionButton("Save workspace", () => upsertCustomColorPalette(workspace?.color), "", "saved color save workspace");
  applyCustomColorSaveLimit(saveWorkspace, workspace?.color, "Save the active workspace color.");
  const pane = focusedPanel();
  const savePane = settingsActionButton("Save pane", () => upsertCustomColorPalette(pane?.color), "", "saved color save active pane tab");
  applyCustomColorSaveLimit(savePane, pane?.color, "Save the active pane color.");
  const clearPanes = settingsActionButton("Clear panes", () => clearWorkspacePaneColors(), "danger", "saved color clear pane tab colors workspace");
  clearPanes.disabled = !workspace?.panels?.some((panel) => panel.color);
  actions.append(saveAccent, saveWorkspace, savePane, clearPanes);
  panel.append(actions);

  if (state.customColorPalette.length === 0) {
    const empty = document.createElement("div");
    empty.className = "saved-color-empty";
    empty.textContent = "Pick a color above to apply it now, or save it so it appears in accent, workspace, and pane color pickers.";
    panel.append(empty);
    return panel;
  }

  const list = document.createElement("div");
  list.className = "saved-color-list";
  const activePane = activePaneForColorTarget();
  for (const color of state.customColorPalette) {
    const colorValue = colorKey(color);
    const activeAccent = colorKey(state.settings.accent) === colorValue;
    const activeWorkspace = colorKey(workspace?.color) === colorValue;
    const activePaneColor = colorKey(activePane?.color) === colorValue;
    const activeAllPanes = Boolean(workspace?.panels?.length) && workspace.panels.every((panel) => colorKey(panel.color) === colorValue);
    const activeTarget = colorTarget === "workspace"
      ? activeWorkspace
      : colorTarget === "pane"
        ? activePaneColor
        : colorTarget === "all"
          ? activeAllPanes
          : activeAccent;
    const card = document.createElement("div");
    card.className = [
      "saved-color-card",
      activeTarget ? "is-active-target" : "",
      activeAccent ? "is-active-accent" : "",
      activeWorkspace ? "is-active-workspace" : "",
      activePaneColor ? "is-active-pane" : "",
      activeAllPanes ? "is-active-all" : ""
    ].filter(Boolean).join(" ");
    card.dataset.settingsSearch = normalizeSettingsQuery(`saved color palette custom accent workspace pane all ${color}`);
    const swatch = document.createElement("button");
    swatch.className = "saved-color-swatch";
    swatch.type = "button";
    swatch.title = `Apply ${color} to ${targetOption.label.toLowerCase()}`;
    swatch.setAttribute("aria-label", `Apply ${color} to ${targetOption.label}.`);
    swatch.setAttribute("aria-pressed", activeTarget ? "true" : "false");
    swatch.disabled = Boolean(targetOption.disabled);
    swatch.style.setProperty("--saved-color", color);
    swatch.onclick = () => applySavedColorToTarget(color, colorTarget);
    const value = document.createElement("div");
    value.className = "saved-color-value";
    value.textContent = color;
    const scope = document.createElement("div");
    scope.className = "background-preset-scope saved-color-scope";
    scope.dataset.settingsSearch = normalizeSettingsQuery(`saved color scope accent workspace pane all ${color}`);
    const addScopeChip = (labelText, active, muted = false) => {
      const chip = document.createElement("span");
      chip.className = [
        "background-preset-scope-chip",
        active ? "is-active" : "",
        muted ? "is-muted" : ""
      ].filter(Boolean).join(" ");
      chip.textContent = active ? `${labelText} active` : labelText;
      scope.append(chip);
    };
    addScopeChip("Accent", activeAccent);
    addScopeChip("Workspace", activeWorkspace, !workspace);
    addScopeChip("Pane", activePaneColor, !activePane);
    addScopeChip(workspace?.panels?.length ? `All ${workspace.panels.length}` : "All", activeAllPanes, !workspace?.panels?.length);
    const cardActions = document.createElement("div");
    cardActions.className = "saved-color-card-actions";
    const apply = settingsActionButton(colorApplyTargetPrimaryLabel(colorTarget), () => applySavedColorToTarget(color, colorTarget), "primary", `saved color apply selected target ${targetOption.label} ${color}`);
    apply.disabled = Boolean(targetOption.disabled);
    const more = settingsActionButton("More", (event) => showSavedColorMenu(event, color), "", `saved color more actions accent workspace pane all delete ${color}`);
    cardActions.append(apply, more);
    card.append(swatch, value, scope, cardActions);
    list.append(card);
  }
  panel.append(list);
  return panel;
}

function activeColorTargetControl() {
  const control = document.createElement("div");
  control.className = "background-target-control color-target-control";
  control.dataset.settingsSearch = normalizeSettingsQuery("saved color target apply accent workspace active pane all panes scope destination current status");

  const header = document.createElement("span");
  header.className = "background-target-header";
  const label = document.createElement("span");
  label.className = "background-target-label";
  label.textContent = "Color target";
  const current = document.createElement("span");
  current.className = "background-target-current";
  header.append(label, current);

  const options = document.createElement("div");
  options.className = "background-target-options";
  for (const target of colorApplyTargetOptions()) {
    const button = document.createElement("button");
    button.className = "background-target-option";
    button.type = "button";
    button.dataset.colorTarget = target.id;
    const icon = colorTargetIconMarkup(target.id);
    button.innerHTML = `
      <span class="background-target-icon color-target-icon" aria-hidden="true">${icon}</span>
      <span class="background-target-copy">
        <span class="background-target-name"></span>
        <span class="background-target-meta"></span>
        <span class="background-target-status"></span>
      </span>
    `;
    button.onclick = () => {
      const nextTarget = normalizeColorApplyTarget(button.dataset.colorTarget);
      if (state.colorApplyTarget === nextTarget) return;
      state.colorApplyTarget = nextTarget;
      renderSettingsInspector();
    };
    options.append(button);
  }
  control.append(header, options);
  updateActiveColorTargetControl(control);
  return control;
}

function updateActiveColorTargetControl(root) {
  const options = colorApplyTargetOptions();
  const selected = colorApplyTargetOption(state.colorApplyTarget);
  setTextIfChanged(root.querySelector(".background-target-current"), `${selected.label} / ${selected.status}`);
  for (const button of root.querySelectorAll("[data-color-target]")) {
    const target = options.find((candidate) => candidate.id === button.dataset.colorTarget);
    if (!target) continue;
    const active = target.id === normalizeColorApplyTarget(state.colorApplyTarget);
    setClassNameIfChanged(button, `background-target-option${active ? " is-active" : ""}${target.disabled ? " is-disabled" : ""}`);
    setDisabledIfChanged(button, target.disabled);
    setAttributeIfChanged(button, "aria-pressed", active ? "true" : "false");
    setAttributeIfChanged(button, "aria-label", `${target.label}: ${target.meta}. ${target.status}.`);
    setTitleIfChanged(button, `${target.label}: ${target.meta}. ${target.status}.`);
    setStylePropertyIfChanged(button, "--target-color", target.color || state.settings.accent);
    setTextIfChanged(button.querySelector(".background-target-name"), target.label);
    setTextIfChanged(button.querySelector(".background-target-meta"), target.meta);
    setTextIfChanged(button.querySelector(".background-target-status"), target.status);
  }
}

function showSavedColorMenu(event, color) {
  event?.preventDefault?.();
  event?.stopPropagation?.();
  const normalized = normalizeCustomPaletteColor(color);
  if (!normalized) return;
  const workspace = activeWorkspace();
  const panel = activePaneForColorTarget();
  const hasPanes = Boolean(workspace?.panels?.length);
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = normalized.toUpperCase();
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = "Choose where to apply this saved color.";
  const applyActions = contextMenuActionGroup(
    contextMenuButton("Apply to accent", () => applySavedColorToTarget(normalized, "accent")),
    contextMenuButton("Apply to workspace", () => applySavedColorToTarget(normalized, "workspace"), !workspace),
    contextMenuButton("Apply to active pane", () => applySavedColorToTarget(normalized, "pane"), !panel),
    contextMenuButton("Apply to all panes", () => applySavedColorToTarget(normalized, "all"), !hasPanes)
  );
  const manageActions = contextMenuActionGroup(
    contextMenuButton("Delete", () => deleteCustomColorPalette(normalized), false, "danger")
  );
  menu.replaceChildren(
    title,
    meta,
    contextMenuSectionTitle("Apply"),
    applyActions,
    contextMenuSectionTitle("Manage"),
    manageActions
  );
  const rect = event?.currentTarget?.getBoundingClientRect?.();
  showContextMenuAt(menu, rect ? rect.left : window.innerWidth / 2, rect ? rect.bottom + 6 : window.innerHeight / 2);
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
  await updatePanels(panels.map((panel) => ({
    panelId: panel.id,
    updates: { color: targetColor }
  })));
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
  await updatePanels(panels.map((panel) => ({
    panelId: panel.id,
    updates: { color: "" }
  })));
  if (state.inspectorMode === "settings" && state.settingsCategory === "appearance") renderSettingsInspector();
  toast(`${panels.length} pane${panels.length === 1 ? "" : "s"} cleared.`);
  return true;
}

function workspaceTerminalPanels(workspace = activeWorkspace()) {
  return (workspace?.panels || []).filter((panel) => panel.type === "terminal" && !isPendingPanel(panel));
}

function activeTerminalPanelForSettings() {
  return resolveTerminalPanel(focusedPanel()) || resolveTerminalPanel(activePanel());
}

function panelBackgroundMatches(panel, value) {
  return normalizeBackgroundValue(panel?.backgroundImage) === normalizeBackgroundValue(value);
}

function terminalBackgroundsMatch(workspace, value) {
  const terminals = workspaceTerminalPanels(workspace);
  return terminals.length > 0 && terminals.every((panel) => panelBackgroundMatches(panel, value));
}

function backgroundPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "background-preset-grid";
  const workspace = activeWorkspace();
  const activeTerminal = activeTerminalPanelForSettings();
  const terminalPanels = workspaceTerminalPanels(workspace);
  const hasTerminalPanes = terminalPanels.length > 0;
  const target = normalizeBackgroundApplyTarget(state.backgroundApplyTarget);
  const targetOption = backgroundApplyTargetOption(target, workspace);
  for (const preset of backgroundPresets) {
    const activeApp = preset.value === state.settings.backgroundImage;
    const activePane = Boolean(activeTerminal && panelBackgroundMatches(activeTerminal, preset.value));
    const activeAll = terminalBackgroundsMatch(workspace, preset.value);
    const activeTarget = target === "pane" ? activePane : target === "all" ? activeAll : activeApp;
    const card = document.createElement("div");
    card.className = [
      "background-preset-card",
      activeApp ? "is-active-app" : "",
      activePane ? "is-active-pane" : "",
      activeAll ? "is-active-all" : ""
    ].filter(Boolean).join(" ");
    card.dataset.settingsSearch = normalizeSettingsQuery(`background image wallpaper template ${preset.label}`);

    const button = document.createElement("button");
    button.className = `background-preset${activeTarget ? " is-active" : ""}`;
    button.type = "button";
    button.disabled = Boolean(targetOption.disabled);
    button.title = `Apply ${preset.label} to ${targetOption.label.toLowerCase()}`;
    button.setAttribute("aria-label", `Apply ${preset.label} to ${targetOption.label}.`);
    button.setAttribute("aria-pressed", activeTarget ? "true" : "false");
    button.style.setProperty("--preset-background", preset.preview);
    button.innerHTML = `<span class="background-preset-preview"></span><span class="background-preset-label"></span>`;
    button.querySelector(".background-preset-label").textContent = preset.label;
    button.onclick = () => applyBackgroundPresetToTarget(preset, target);

    const scope = document.createElement("div");
    scope.className = "background-preset-scope";
    scope.dataset.settingsSearch = normalizeSettingsQuery(`background template scope app pane all terminals ${preset.label}`);
    const addScopeChip = (label, active, muted = false) => {
      const chip = document.createElement("span");
      chip.className = [
        "background-preset-scope-chip",
        active ? "is-active" : "",
        muted ? "is-muted" : ""
      ].filter(Boolean).join(" ");
      chip.textContent = active ? `${label} active` : label;
      scope.append(chip);
    };
    addScopeChip("App", activeApp);
    addScopeChip("Pane", activePane, !activeTerminal);
    addScopeChip("All", activeAll, !hasTerminalPanes);

    const actions = document.createElement("div");
    actions.className = "background-preset-actions";
    const applyAction = settingsActionButton(backgroundApplyTargetPrimaryLabel(target), () => applyBackgroundPresetToTarget(preset, target), "primary", `background template apply selected target ${targetOption.label} ${preset.label}`);
    applyAction.disabled = Boolean(targetOption.disabled);
    const moreAction = settingsActionButton("More", (event) => showBackgroundPresetMenu(event, preset), "", `background template more scopes app pane all terminals ${preset.label}`);
    actions.append(applyAction, moreAction);

    card.append(button, scope, actions);
    grid.append(card);
  }
  return grid;
}

function showBackgroundPresetMenu(event, preset) {
  event?.preventDefault?.();
  event?.stopPropagation?.();
  if (!preset) return;
  const workspace = activeWorkspace();
  const activeTerminal = activeTerminalPanelForSettings();
  const hasTerminalPanes = workspaceTerminalPanels(workspace).length > 0;
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = preset.label || "Background";
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = "Choose where to apply this background.";
  const actions = contextMenuActionGroup(
    contextMenuButton("Apply to app", () => applyBackgroundPreset(preset, { toast: true })),
    contextMenuButton("Apply to active terminal", () => applyBackgroundPresetToTarget(preset, "pane"), !activeTerminal),
    contextMenuButton("Apply to all terminals", () => applyBackgroundPresetToTarget(preset, "all"), !hasTerminalPanes)
  );
  menu.replaceChildren(title, meta, contextMenuSectionTitle("Apply"), actions);
  const rect = event?.currentTarget?.getBoundingClientRect?.();
  showContextMenuAt(menu, rect ? rect.left : window.innerWidth / 2, rect ? rect.bottom + 6 : window.innerHeight / 2);
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

  panel.append(activeBackgroundTargetControl());

  const targetStatus = activeBackgroundTargetStatus();
  const addTargetOption = backgroundApplyTargetOption(targetStatus.scope);
  const targetLabel = backgroundApplyTargetActionLabel(targetStatus.scope);
  const addCard = document.createElement("div");
  addCard.className = "saved-background-add-card";
  addCard.dataset.settingsSearch = normalizeSettingsQuery("saved background add image drop paste choose local file url selected target wallpaper");

  const addCopy = document.createElement("button");
  addCopy.className = "saved-background-add-copy";
  addCopy.type = "button";
  addCopy.title = `Choose and save an image for ${targetLabel}`;
  addCopy.setAttribute("aria-label", `Choose and save an image for ${targetLabel}.`);
  addCopy.innerHTML = `
      <span class="saved-background-add-icon" aria-hidden="true">${quickActionIconMarkup("background")}</span>
      <span class="saved-background-add-text">
        <span class="saved-background-add-title">Use any image</span>
        <span class="saved-background-add-target">
          <span class="saved-background-add-target-icon" aria-hidden="true">${backgroundTargetIconMarkup(targetStatus.scope)}</span>
          <span class="saved-background-add-target-label"></span>
        </span>
        <span class="saved-background-add-body"></span>
        <span class="saved-background-add-chips" aria-hidden="true">
          <span>Drop</span>
          <span>Paste</span>
          <span>Choose</span>
          <span>URL/path</span>
        </span>
      </span>
  `;
  addCopy.querySelector(".saved-background-add-target-label").textContent = targetLabel;
  addCopy.querySelector(".saved-background-add-body").textContent = `Apply to ${addTargetOption.label.toLowerCase()}. Drop, paste, choose, or enter an image path.`;
  addCopy.onclick = () => chooseBackgroundImageForTarget({ save: true });
  const applyUnknownBackgroundSaveLimit = (button, availableTitle) => {
    applySavedBackgroundImageCapacityLimit(button, availableTitle);
    if (!targetStatus.canTarget) {
      button.disabled = true;
      button.title = `${addTargetOption.label} cannot use a background right now.`;
    }
    return button;
  };
  applyUnknownBackgroundSaveLimit(addCopy, `Choose and save an image for ${targetLabel}`);

  const addRow = document.createElement("div");
  addRow.className = "saved-background-add";
  const input = document.createElement("input");
  input.className = "setting-control saved-background-input";
  input.placeholder = "URL or C:\\path\\image.png";
  input.dataset.settingsSearch = normalizeSettingsQuery("saved background image url local path file add apply save");
  const saveTypedImage = () => withDisabledControl(input, async () => {
    const saved = await saveCustomBackgroundImage({ url: input.value });
    if (saved) input.value = saved.url;
    return saved;
  });
  const applyAndSaveTypedImage = () => withDisabledControl(input, async () => {
    const saved = await applyAndSaveBackgroundImageToTarget({ url: input.value }, state.backgroundApplyTarget, { resetInput: input });
    if (saved) input.value = saved.url;
    return saved;
  });
  input.addEventListener("keydown", async (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      await applyAndSaveTypedImage();
    }
  });
  const saveUrl = settingsActionButton("Save only", saveTypedImage, "", "saved background image url local path file add");
  addRow.append(input, saveUrl);

  const actions = document.createElement("div");
  actions.className = "settings-actions saved-background-actions";
  actions.dataset.settingsSearch = normalizeSettingsQuery("saved background current choose local file wallpaper apply save");
  const applyAndSave = settingsActionButton(backgroundApplyTargetSaveLabel(targetStatus.scope), applyAndSaveTypedImage, "primary", "saved background image apply save selected target url local path file wallpaper");
  const refreshTypedSaveState = () => {
    applySavedBackgroundImageSaveLimit(saveUrl, input.value, "Save the typed image to the reusable background library.");
    applySavedBackgroundImageSaveLimit(applyAndSave, input.value, `Apply and save the typed image to ${targetLabel}`);
    if (!targetStatus.canTarget) {
      applyAndSave.disabled = true;
      applyAndSave.title = `${addTargetOption.label} cannot use a background right now.`;
    }
  };
  refreshTypedSaveState();
  input.addEventListener("input", refreshTypedSaveState);
  input.addEventListener("change", refreshTypedSaveState);
  const saveCurrent = settingsActionButton("Save selected", () => saveCustomBackgroundImage({
    url: activeBackgroundPanelViewModel().background
  }), "", "saved background image current selected target");
  applySavedBackgroundImageSaveLimit(saveCurrent, activeBackgroundPanelViewModel().background, "Save the currently selected background without changing the target.");
  const pasteSave = settingsActionButton("Paste + save", () => pasteBackgroundImageFromClipboard({ input, target: () => state.backgroundApplyTarget, save: true }), "", "saved background image paste clipboard copied image apply save selected target wallpaper");
  applyUnknownBackgroundSaveLimit(pasteSave, `Paste, apply, and save an image to ${targetLabel}`);
  const chooseSave = settingsActionButton("Choose + save", () => chooseBackgroundImageForTarget({ save: true }), "", "saved background image choose local file selected target wallpaper");
  applyUnknownBackgroundSaveLimit(chooseSave, `Choose, apply, and save an image to ${targetLabel}`);
  actions.append(
    applyAndSave,
    saveCurrent,
    pasteSave,
    chooseSave
  );
  addCard.append(addCopy, addRow, actions);
  panel.append(addCard);
  installBackgroundDropTarget(addCard, { input, saveTarget: () => state.backgroundApplyTarget });

  if (state.savedBackgroundImages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "saved-background-empty";
    empty.textContent = "Save URL or local image backgrounds here so they can be applied again without pasting the path.";
    panel.append(empty);
    return panel;
  }

  const list = document.createElement("div");
  list.className = "saved-background-list";
  const workspace = activeWorkspace();
  const activeTerminal = activeTerminalPanelForSettings();
  const terminalPanels = workspaceTerminalPanels(workspace);
  const hasTerminalPanes = terminalPanels.length > 0;
  const target = normalizeBackgroundApplyTarget(state.backgroundApplyTarget);
  const targetOption = backgroundApplyTargetOption(target, workspace);
  for (const background of state.savedBackgroundImages) {
    const activeApp = normalizeBackgroundValue(state.settings.backgroundImage) === normalizeBackgroundValue(background.url);
    const activePane = Boolean(activeTerminal && panelBackgroundMatches(activeTerminal, background.url));
    const activeAll = hasTerminalPanes && terminalPanels.every((panel) => panelBackgroundMatches(panel, background.url));
    const activeTarget = target === "pane" ? activePane : target === "all" ? activeAll : activeApp;
    const card = document.createElement("div");
    card.className = [
      "saved-background-card",
      activeApp ? "is-active is-active-app" : "",
      activePane ? "is-active-pane" : "",
      activeAll ? "is-active-all" : ""
    ].filter(Boolean).join(" ");
    card.dataset.settingsSearch = normalizeSettingsQuery(`saved background image wallpaper scope app pane all terminals ${background.label} ${background.url}`);
    const preview = document.createElement("button");
    preview.className = "saved-background-preview";
    preview.type = "button";
    preview.disabled = Boolean(targetOption.disabled);
    preview.title = `Apply ${background.label} to ${targetOption.label.toLowerCase()}`;
    preview.setAttribute("aria-label", `Apply ${background.label} to ${targetOption.label}.`);
    preview.setAttribute("aria-pressed", activeTarget ? "true" : "false");
    preview.style.setProperty("--saved-background-image", backgroundCss(background.url));
    preview.style.setProperty("--saved-background-repeat", backgroundRepeatCss(background.url));
    preview.onclick = () => applySavedBackgroundImageToTarget(background.id, target);
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

    const scope = document.createElement("div");
    scope.className = "background-preset-scope saved-background-scope";
    scope.dataset.settingsSearch = normalizeSettingsQuery(`saved background scope app pane all terminals ${background.label}`);
    const addScopeChip = (labelText, active, muted = false) => {
      const chip = document.createElement("span");
      chip.className = [
        "background-preset-scope-chip",
        active ? "is-active" : "",
        muted ? "is-muted" : ""
      ].filter(Boolean).join(" ");
      chip.textContent = active ? `${labelText} active` : labelText;
      scope.append(chip);
    };
    addScopeChip("App", activeApp);
    addScopeChip("Pane", activePane, !activeTerminal);
    addScopeChip(hasTerminalPanes ? `All ${terminalPanels.length}` : "All", activeAll, !hasTerminalPanes);

    const cardActions = document.createElement("div");
    cardActions.className = "saved-background-card-actions";
    const apply = settingsActionButton(backgroundApplyTargetPrimaryLabel(target), () => applySavedBackgroundImageToTarget(background.id, target), "primary", `apply saved background selected target ${targetOption.label} ${background.label}`);
    apply.disabled = Boolean(targetOption.disabled);
    const more = settingsActionButton("More", (event) => showSavedBackgroundImageMenu(event, background), "", `saved background more actions open rename delete copy ${background.label}`);
    cardActions.append(apply, more);
    card.append(preview, text, scope, cardActions);
    list.append(card);
  }
  panel.append(list);
  return panel;
}

function showSavedBackgroundImageMenu(event, background) {
  event?.preventDefault?.();
  event?.stopPropagation?.();
  if (!background?.id) return;
  const menu = ensureContextMenu();
  menu.className = "context-menu";
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = background.label || "Background";
  const meta = document.createElement("div");
  meta.className = "context-meta";
  meta.textContent = background.url || "";
  const workspace = activeWorkspace();
  const activeTerminal = activeTerminalPanelForSettings();
  const hasTerminalPanes = workspaceTerminalPanels(workspace).length > 0;
  const applyActions = contextMenuActionGroup(
    contextMenuButton("Apply to app", () => applySavedBackgroundImage(background.id)),
    contextMenuButton("Apply to active terminal", () => applySavedBackgroundImageToPanel(background.id), !activeTerminal),
    contextMenuButton("Apply to all terminals", () => applySavedBackgroundImageToWorkspaceTerminals(background.id), !hasTerminalPanes)
  );
  const manageActions = contextMenuActionGroup(
    contextMenuButton("Open source", () => openBackgroundImageSource(background.url), !canOpenBackgroundImageSource(background.url)),
    contextMenuButton("Copy source", () => copySavedBackgroundImageSource(background)),
    contextMenuButton("Rename", () => renameSavedBackgroundImage(background.id)),
    contextMenuButton("Delete", () => deleteSavedBackgroundImage(background.id), false, "danger")
  );
  menu.replaceChildren(
    title,
    meta,
    contextMenuSectionTitle("Apply"),
    applyActions,
    contextMenuSectionTitle("Manage"),
    manageActions
  );
  const rect = event?.currentTarget?.getBoundingClientRect?.();
  showContextMenuAt(menu, rect ? rect.left : window.innerWidth / 2, rect ? rect.bottom + 6 : window.innerHeight / 2);
}

async function copySavedBackgroundImageSource(background) {
  if (!background?.url) {
    toast("Background source is unavailable.");
    return false;
  }
  if (await writeClipboardText(background.url)) {
    toast("Background source copied.");
    return true;
  }
  toast("Clipboard is unavailable.");
  return false;
}

function isActiveTerminalColorPreset(preset) {
  return state.settings.terminalBackground === preset.background
    && state.settings.terminalForeground === preset.foreground
    && state.settings.terminalCursorColor === preset.cursor;
}

function isTerminalColorPresetIdActive(presetId) {
  const preset = terminalColorPresets.find((candidate) => candidate.id === presetId);
  return Boolean(preset && isActiveTerminalColorPreset(preset));
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
    button.dataset.settingsSearch = normalizeSettingsQuery(`terminal color preset theme ${active ? "active current " : ""}${preset.label} ${preset.body}`);
    button.style.setProperty("--terminal-preset-background", preset.background || terminalColorDefaults.background);
    button.style.setProperty("--terminal-preset-foreground", preset.foreground || terminalColorDefaults.foreground);
    button.style.setProperty("--terminal-preset-cursor", preset.cursor || state.settings.accent || terminalColorDefaults.cursor);
    button.innerHTML = `
      <span class="terminal-color-preset-preview">
        <span class="terminal-color-preset-line"></span>
        <span class="terminal-color-preset-prompt"></span>
      </span>
      <span class="terminal-color-preset-text">
        <span class="terminal-color-preset-title-row">
          <span class="terminal-color-preset-title"></span>
        </span>
        <span class="terminal-color-preset-body"></span>
      </span>
    `;
    button.querySelector(".terminal-color-preset-line").textContent = "> cmux";
    button.querySelector(".terminal-color-preset-prompt").textContent = "_";
    button.querySelector(".terminal-color-preset-title").textContent = preset.label;
    if (active) {
      const status = document.createElement("span");
      status.className = "terminal-color-preset-status";
      status.textContent = "Active";
      button.querySelector(".terminal-color-preset-title-row").append(status);
    }
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
  clear.title = clear.disabled ? "Recent folders are already clear." : "Clear recent workspace folders.";
  header.append(title, clear);
  section.append(header);

  if (state.recentFolders.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Chosen workspace folders will appear here.";
    section.append(empty);
    return section;
  }

  const hasWorkspace = Boolean(activeWorkspace());
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
    use.disabled = !hasWorkspace;
    use.title = hasWorkspace ? "Use this folder for the active workspace." : "Open a workspace before using a recent folder.";
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
  clear.title = clear.disabled ? "Recent commands are already clear." : "Clear recent terminal commands.";
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
  clear.title = clear.disabled ? "Recent browser pages are already clear." : "Clear recent browser pages.";
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
    const activeHome = isActiveRecentBrowserHome(url);
    const card = document.createElement("div");
    card.className = `recent-folder-card${activeHome ? " is-active" : ""}`;
    card.dataset.recentBrowserUrl = url;
    card.dataset.settingsSearch = recentBrowserPageSearch(url, activeHome);
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
    open.dataset.recentBrowserUrl = url;
    const home = settingsActionButton("Home", () => {
      const changed = updateSettings({ browserHomeUrl: url });
      toast(changed ? "Browser home updated." : "Browser home already uses this page.");
    }, activeHome ? "primary" : "", recentBrowserHomeActionSearch(url, activeHome));
    home.dataset.recentBrowserAction = "home";
    home.dataset.recentBrowserUrl = url;
    setRecentBrowserHomeActionState(home, activeHome);
    actions.append(open, home);
    card.append(text, actions);
    section.append(card);
  }

  return section;
}

function isActiveRecentBrowserHome(url) {
  return browserHomeKey(url) === browserHomeKey(state.settings.browserHomeUrl);
}

function recentBrowserPageSearch(url, activeHome = isActiveRecentBrowserHome(url)) {
  return normalizeSettingsQuery(`recent browser page url web open home ${activeHome ? "active current " : ""}${hostnameOf(url)} ${url}`);
}

function recentBrowserHomeActionSearch(url, activeHome = isActiveRecentBrowserHome(url)) {
  return `recent browser page ${activeHome ? "active current " : ""}home set browser home ${url}`;
}

function setRecentBrowserHomeActionState(button, activeHome) {
  if (!button) return;
  button.disabled = activeHome;
  button.classList.toggle("primary", activeHome);
  button.title = activeHome ? "This page is already the browser home." : "Set this page as the browser home.";
  setSettingsActionLabel(button, activeHome ? "Active" : "Home");
}

function refreshRecentBrowserHomeActions() {
  const cards = elements.inspectorBody.querySelectorAll(".recent-folder-card[data-recent-browser-url]");
  for (const card of cards) {
    const url = card.dataset.recentBrowserUrl || "";
    const activeHome = isActiveRecentBrowserHome(url);
    card.classList.toggle("is-active", activeHome);
    const cardSearch = recentBrowserPageSearch(url, activeHome);
    if (card.dataset.settingsSearch !== cardSearch) {
      card.dataset.settingsSearch = cardSearch;
      updateSettingsSearchIndexItemSearch(card, cardSearch);
    }
  }
  const buttons = elements.inspectorBody.querySelectorAll('[data-recent-browser-action="home"][data-recent-browser-url]');
  for (const button of buttons) {
    const url = button.dataset.recentBrowserUrl || "";
    const activeHome = isActiveRecentBrowserHome(url);
    setRecentBrowserHomeActionState(button, activeHome);
    const search = normalizeSettingsQuery(`Home ${recentBrowserHomeActionSearch(url, activeHome)}`);
    if (button.dataset.settingsSearch !== search) {
      button.dataset.settingsSearch = search;
      updateSettingsSearchIndexItemSearch(button, search);
    }
  }
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
  add.disabled = customCommandSnippetsFull();
  add.title = add.disabled ? commandSnippetLimitTitle() : "Add a saved terminal command snippet.";
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
  const savedBuiltIn = Boolean(snippet.builtIn && isBuiltInCommandSnippetSaved(snippet));
  const card = document.createElement("div");
  card.className = `recent-folder-card command-snippet-card${savedBuiltIn ? " is-active" : ""}`;
  card.dataset.settingsSearch = normalizeSettingsQuery(`command snippet terminal shell run ${snippet.builtIn ? "built in" : "custom saved"} ${savedBuiltIn ? "saved active current " : ""}${snippet.label} ${snippet.command}`);

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
    const limitReached = !savedBuiltIn && customCommandSnippetsFull();
    const save = settingsActionButton(
      savedBuiltIn ? "Saved" : "Save",
      () => saveBuiltInCommandSnippet(snippet),
      savedBuiltIn ? "primary" : "",
      `save built in command snippet ${savedBuiltIn ? "saved active current " : ""}${limitReached ? "limit full " : ""}${snippet.label}`
    );
    save.disabled = savedBuiltIn || limitReached;
    save.title = savedBuiltIn
      ? "This built-in snippet is already saved."
      : limitReached
        ? commandSnippetLimitTitle()
        : "Save this built-in snippet.";
    actions.append(save);
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
  if (customCommandSnippetsFull()) {
    toast(commandSnippetLimitTitle());
    return null;
  }
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
  if (isBuiltInCommandSnippetSaved(snippet)) {
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
    const card = document.createElement("div");
    card.className = "workspace-starter";
    card.dataset.workspaceStarter = starter.id;
    card.dataset.settingsSearch = normalizeSettingsQuery(`workspace starter layout preset new add current ${starter.label} ${starter.body} ${starter.panels.join(" ")}`);
    card.innerHTML = `
      <span class="workspace-starter-title-text"></span>
      <span class="workspace-starter-body"></span>
      <span class="workspace-starter-panes"></span>
    `;
    card.querySelector(".workspace-starter-title-text").textContent = starter.label;
    card.querySelector(".workspace-starter-body").textContent = starter.body;
    card.querySelector(".workspace-starter-panes").textContent = starter.panels
      .map((type) => type === "browser" ? "web" : "term")
      .join(" + ");
    const actions = document.createElement("div");
    actions.className = "workspace-starter-actions";
    actions.append(
      settingsActionButton("New", () => createWorkspaceFromStarter(starter.id), "", `new workspace from starter ${starter.label}`),
      settingsActionButton("Add", () => applyWorkspaceStarter(starter.id), "", `add starter to current workspace ${starter.label}`)
    );
    card.append(actions);
    grid.append(card);
  }
  section.append(grid);
  return section;
}

function settingsActionIconMarkup(label, tone = "") {
  const text = String(label || "").trim().toLowerCase();
  if (!text) return "";
  if (tone === "danger" || text.startsWith("delete") || text.startsWith("clear") || text.startsWith("reset")) {
    return controlIconMarkup("close");
  }
  if (text.startsWith("save") || text.includes("+ save")) return quickActionIconMarkup("saveLayout");
  if (text.startsWith("add") || text.startsWith("new")) return controlIconMarkup("plus");
  if (text.startsWith("apply") || text === "use" || text.startsWith("use ")) return controlIconMarkup("arrowRight");
  if (text.startsWith("choose") || text.startsWith("paste")) return quickActionIconMarkup("background");
  if (text.startsWith("open external") || text === "external") return controlIconMarkup("external");
  if (text.startsWith("open")) return controlIconMarkup("external");
  if (text.startsWith("refresh") || text.startsWith("restart")) return controlIconMarkup("reload");
  if (text.startsWith("rename") || text === "edit") return quickActionIconMarkup("rename");
  if (text.startsWith("run")) return controlIconMarkup("terminal");
  if (text.startsWith("focus") || text.startsWith("leave focus")) return quickActionIconMarkup("focus");
  if (text.startsWith("split")) return controlIconMarkup("splitRight");
  if (text.startsWith("duplicate")) return quickActionIconMarkup("paneShape");
  if (text.startsWith("copy")) return quickActionIconMarkup("actions");
  if (text.startsWith("import")) return controlIconMarkup("down");
  if (text.startsWith("export")) return controlIconMarkup("up");
  if (text.startsWith("home")) return controlIconMarkup("home");
  if (text.includes("speed") || text.includes("tune")) return quickActionIconMarkup("speed");
  if (text.includes("profile")) return quickActionIconMarkup("profiles");
  if (text.includes("workspace")) return quickActionIconMarkup("workspace");
  if (text.includes("pane")) return quickActionIconMarkup("paneShape");
  if (text.includes("browser")) return controlIconMarkup("browser");
  if (text.includes("terminal")) return controlIconMarkup("terminal");
  return "";
}

function setSettingsActionLabel(button, label) {
  const labelNode = button?.querySelector?.(".settings-action-label");
  if (labelNode) {
    setTextIfChanged(labelNode, label);
    return;
  }
  setTextIfChanged(button, label);
}

function settingsActionButton(label, onClick, tone = "", searchTerms = "") {
  const button = document.createElement("button");
  button.className = `settings-action${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  const icon = settingsActionIconMarkup(label, tone);
  if (icon) {
    button.classList.add("has-icon");
    button.innerHTML = `<span class="settings-action-icon" aria-hidden="true">${icon}</span><span class="settings-action-label"></span>`;
    setSettingsActionLabel(button, label);
  } else {
    button.textContent = label;
  }
  button.title = label;
  button.dataset.settingsSearch = normalizeSettingsQuery(`${label} ${searchTerms}`);
  button.onclick = (event) => {
    if (button.disabled || button.classList.contains("is-busy")) return;
    const currentLabel = button.querySelector(".settings-action-label")?.textContent || button.textContent || label;
    let result = null;
    try {
      result = onClick?.(event);
    } catch (error) {
      console.error(error);
      toast(`${currentLabel} failed.`);
      return;
    }
    if (!result || typeof result.then !== "function") return;
    runSettingsAction(button, currentLabel, result);
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
  setSettingsActionLabel(button, "Working");
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
    setSettingsActionLabel(button, previousText || label);
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

async function chooseBackgroundImageForTarget(options = {}) {
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return null;
  }
  const target = normalizeBackgroundApplyTarget(options.target || state.backgroundApplyTarget);
  const targetStatus = activeBackgroundTargetStatus(target);
  if (!targetStatus.canTarget) {
    const option = backgroundApplyTargetOption(target);
    toast(formatMessage("quickGuide.backgroundTargetUnavailable", { label: option.label }));
    return null;
  }
  if (state.backgroundApplyTarget !== target) {
    state.backgroundApplyTarget = target;
    refreshBackgroundPreviewNodes();
    refreshBackgroundLibraryPanels();
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return null;
  if (options.save) {
    return applyAndSaveBackgroundImageToTarget({ url }, target, { render: true });
  }
  const changed = await applyBackgroundValueToTarget(url, target, { render: false, toast: true });
  if (changed !== null) renderSettingsInspector();
  return changed;
}

async function readBackgroundImageFromClipboard() {
  if (!window.cmuxNative?.readClipboard) {
    toast("Clipboard is unavailable.");
    return null;
  }
  const textValue = String(await window.cmuxNative.readClipboard() || "").trim();
  let value = textValue;
  let pastedImage = false;
  let imageError = "";
  if (!value && window.cmuxNative?.readClipboardImage) {
    const image = await window.cmuxNative.readClipboardImage();
    if (image?.ok && image.dataUrl) {
      value = image.dataUrl;
      pastedImage = true;
    } else {
      imageError = image?.error || "";
    }
  }
  if (!value) {
    toast(imageError === "too_large"
      ? "Clipboard image is too large for a saved background."
      : "Clipboard does not contain an image URL, path, or copied image.");
    return null;
  }
  return {
    background: pastedImage ? { url: value, label: "Clipboard image" } : { url: value },
    pastedImage,
    value
  };
}

async function pasteBackgroundImageFromClipboard(options = {}) {
  const payload = await readBackgroundImageFromClipboard();
  if (!payload) return null;
  const { background, pastedImage, value } = payload;
  if (options.input) options.input.value = pastedImage ? "Copied image" : value;
  if (options.target) {
    const target = typeof options.target === "function" ? options.target() : options.target;
    if (options.save) {
      const saved = await applyAndSaveBackgroundImageToTarget(background, target, { resetInput: options.input });
      if (saved && options.input) options.input.value = pastedImage ? "" : saved.url;
      return saved;
    }
    const changed = await applyBackgroundValueToTarget(value, target, { resetInput: options.input, toast: true });
    if (changed !== null && pastedImage && options.input) options.input.value = "";
    return changed;
  }
  if (options.save) {
    const saved = await applyAndSaveCustomBackgroundImage(background, { resetInput: options.input });
    if (saved && options.input) options.input.value = pastedImage ? "" : saved.url;
    return saved;
  }
  const changed = await applyCustomBackgroundImage(value, { resetInput: options.input, toast: true });
  if (changed !== null && pastedImage && options.input) options.input.value = "";
  return changed;
}

async function chooseWorkspaceTerminalBackground(workspace = activeWorkspace()) {
  if (!workspace) return null;
  if (!window.cmuxNative?.pickBackgroundImage) {
    toast("Local image picker is unavailable.");
    return null;
  }
  const url = await window.cmuxNative.pickBackgroundImage();
  if (!url) return null;
  const changed = await applyWorkspaceBackgroundImageToTerminals(url, workspace, { render: false, toast: true });
  if (changed !== null && state.inspectorMode === "settings") renderSettingsInspector();
  return changed;
}

async function pasteWorkspaceTerminalBackgroundFromClipboard(workspace = activeWorkspace()) {
  if (!workspace) return null;
  const payload = await readBackgroundImageFromClipboard();
  if (!payload) return null;
  const changed = await applyWorkspaceBackgroundImageToTerminals(payload.value, workspace, { render: false, toast: true });
  if (changed !== null && state.inspectorMode === "settings") renderSettingsInspector();
  return changed;
}

function settingsPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "settings-preset-grid";
  for (const preset of settingsPresets) {
    const normalized = normalizeSettings(preset.settings);
    const themePreview = settingsPresetThemePreview(normalized.theme);
    const active = isActiveSettingsPreset(preset);
    const button = document.createElement("button");
    button.className = `settings-preset${active ? " is-active" : ""}`;
    button.type = "button";
    button.title = `${preset.label}: ${settingsProfileSummary(normalized)}`;
    button.setAttribute("aria-label", `${preset.label}. ${active ? "Active. " : ""}${preset.body}. ${settingsProfileSummary(normalized)}.`);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.dataset.settingsSearch = normalizeSettingsQuery(`preset ${active ? "active current " : ""}${preset.label} ${preset.body} ${settingsProfileSummary(normalized)}`);
    button.style.setProperty("--preset-canvas", themePreview.canvas);
    button.style.setProperty("--preset-pane", themePreview.pane);
    button.style.setProperty("--preset-rail", themePreview.rail);
    button.style.setProperty("--preset-line", themePreview.line);
    button.style.setProperty("--preset-accent", normalized.accent || themePreview.accent);
    button.innerHTML = `
      <span class="settings-preset-preview" aria-hidden="true">
        <span class="settings-preset-preview-rail"></span>
        <span class="settings-preset-preview-main">
          <span></span>
          <span></span>
        </span>
        <span class="settings-preset-preview-accent"></span>
      </span>
      <span class="settings-preset-copy">
        <span class="settings-preset-title-row">
          <span class="settings-preset-title"></span>
          <span class="settings-preset-status"></span>
        </span>
        <span class="settings-preset-body"></span>
        <span class="settings-preset-tags"></span>
      </span>
    `;
    button.querySelector(".settings-preset-title").textContent = preset.label;
    button.querySelector(".settings-preset-status").textContent = active ? "Active" : "";
    button.querySelector(".settings-preset-body").textContent = preset.body;
    button.querySelector(".settings-preset-tags").replaceChildren(...settingsPresetTags(normalized));
    button.onclick = () => applySettingsPreset(preset);
    grid.append(button);
  }
  return grid;
}

function settingsPresetThemePreview(themeId) {
  return themePreviewOptions.find((theme) => theme.id === themeId)
    || themePreviewOptions.find((theme) => theme.id === defaultSettings.theme)
    || {
      canvas: "var(--color-canvas)",
      pane: "var(--color-pane)",
      rail: "var(--color-rail)",
      line: "var(--color-line)",
      accent: "var(--color-accent)"
    };
}

function settingsPresetTags(settings) {
  const tags = [
    optionLabel(toolbarModeOptions, settings.toolbarMode, "Toolbar"),
    settings.performanceMode ? "Speed" : settings.focusMode ? "Focus" : settings.density,
    settings.showStatusbar ? "Status" : "No status",
    `${settings.terminalScrollback.toLocaleString()} history`
  ];
  return tags.map((tag) => {
    const item = document.createElement("span");
    item.textContent = tag;
    return item;
  });
}

function isActiveSettingsPreset(preset) {
  return Object.entries(preset.settings).every(([key, value]) => state.settings[key] === value);
}

function isActiveSettingsProfile(profile) {
  if (!profile?.settings) return false;
  const normalized = normalizeSettings(profile.settings);
  return profileSettingsSettingKeys.every((key) => state.settings[key] === normalized[key]);
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
  const preset = settingsPresetById(presetId);
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
  applySettingsProfileSaveLimit(save);
  header.append(title, save);
  wrapper.append(header, settingsProfileCurrentSetupPanel());

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

function settingsProfileCurrentSetupPanel() {
  const setup = activeSettingsSetupModel();
  const setupClass = setup.kind === "Saved profile"
    ? " is-saved"
    : setup.kind === "Unsaved setup"
      ? " is-unsaved"
      : " is-built-in";
  const panel = document.createElement("div");
  panel.className = `settings-profile-overview${setupClass}`;
  panel.dataset.settingsSearch = normalizeSettingsQuery(`current active settings setup profile ${setup.kind} ${setup.label} ${settingsProfileSummary(state.settings)} ${savedSettingsProfileCountLabel()}`);
  panel.title = `${setup.kind}: ${setup.label}`;
  panel.setAttribute("aria-label", `Current setup. ${setup.kind}: ${setup.label}. ${savedSettingsProfileCountLabel()} saved profiles.`);
  panel.innerHTML = `
    <span class="settings-profile-overview-copy">
      <span class="settings-profile-overview-eyebrow">Current setup</span>
      <span class="settings-profile-overview-label"></span>
      <span class="settings-profile-overview-meta"></span>
    </span>
    <span class="settings-profile-overview-badge"></span>
  `;
  panel.querySelector(".settings-profile-overview-label").textContent = setup.label;
  panel.querySelector(".settings-profile-overview-meta").textContent = `${savedSettingsProfileCountLabel()} saved / ${settingsProfileSummary(state.settings)}`;
  panel.querySelector(".settings-profile-overview-badge").textContent = setup.kind;
  return panel;
}

function settingsProfileCard(profile) {
  const active = isActiveSettingsProfile(profile);
  const card = document.createElement("div");
  card.className = `recent-folder-card settings-profile-card${active ? " is-active" : ""}`;
  card.dataset.settingsSearch = normalizeSettingsQuery(`saved settings profile preset apply active rename delete ${profile.label} ${settingsProfileSummary(profile.settings)}`);

  const text = document.createElement("div");
  text.className = "recent-folder-text";
  const name = document.createElement("div");
  name.className = "recent-folder-name settings-profile-name";
  const nameText = document.createElement("span");
  nameText.textContent = profile.label;
  name.append(nameText);
  if (active) {
    const status = document.createElement("span");
    status.className = "settings-profile-status";
    status.textContent = "Active";
    name.append(status);
  }
  name.title = profile.label;
  const summary = document.createElement("div");
  summary.className = "recent-folder-path settings-profile-summary";
  summary.textContent = settingsProfileSummary(profile.settings);
  summary.title = summary.textContent;
  text.append(name, summary);

  const actions = document.createElement("div");
  actions.className = "recent-folder-actions settings-profile-actions";
  const apply = settingsActionButton(active ? "Active" : "Apply", () => applySavedSettingsProfile(profile.id), active ? "primary" : "", `apply active settings profile ${profile.label}`);
  apply.disabled = active;
  actions.append(
    apply,
    settingsActionButton("Update", () => updateSavedSettingsProfile(profile.id), "", `update settings profile ${profile.label} overwrite current settings`),
    settingsActionButton("Rename", () => renameSavedSettingsProfile(profile.id), "", `rename settings profile ${profile.label}`),
    settingsActionButton("Delete", () => deleteSavedSettingsProfile(profile.id), "danger", `delete settings profile ${profile.label}`)
  );
  card.append(text, actions);
  return card;
}

async function saveCurrentSettingsProfile(options = {}) {
  if (savedSettingsProfilesFull()) {
    toast(settingsProfileLimitTitle());
    return null;
  }
  const label = await showTextDialog({
    title: options.title || "Save settings profile",
    message: options.message || "Save the current look, layout, terminal, and performance settings.",
    value: options.value || defaultSettingsProfileName(options.baseName),
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

function saveCurrentLookProfile() {
  return saveCurrentSettingsProfile({
    title: "Save appearance profile",
    message: "Save this look together with the current layout, terminal, and performance settings.",
    baseName: "Look profile"
  });
}

function saveCurrentTerminalProfile() {
  return saveCurrentSettingsProfile({
    title: "Save terminal profile",
    message: "Save the current terminal font, colors, cursor, shell, and supporting app settings.",
    baseName: "Terminal profile"
  });
}

function saveCurrentBrowserProfile() {
  return saveCurrentSettingsProfile({
    title: "Save browser profile",
    message: "Save the current browser home page, launch mode, external profile, and supporting app settings.",
    baseName: "Browser profile"
  });
}

function saveCurrentPerformanceProfile() {
  return saveCurrentSettingsProfile({
    title: "Save performance profile",
    message: "Save the current speed, rendering, terminal output, and supporting app settings.",
    baseName: "Performance profile"
  });
}

function defaultSettingsProfileName(baseName = "My profile") {
  const base = String(baseName || "My profile").trim() || "My profile";
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
  applyWorkspaceBlueprintSaveLimit(save, activeWorkspace(), "Save the current workspace pane setup as a blueprint.");
  header.append(title, save);
  wrapper.append(header);

  if (state.workspaceBlueprints.length === 0) {
    const empty = document.createElement("div");
    empty.className = "recent-folder-empty";
    empty.textContent = "Save a workspace pane setup, then recreate it later as a new workspace or add it to the current one.";
    wrapper.append(empty);
  } else {
    const currentBlueprint = currentWorkspaceBlueprintSnapshot("Current setup");
    for (const blueprint of state.workspaceBlueprints) {
      wrapper.append(workspaceBlueprintCard(blueprint, currentBlueprint));
    }
  }

  const starterTitle = document.createElement("div");
  starterTitle.className = "command-snippet-group-title";
  starterTitle.textContent = "Starter layouts";
  wrapper.append(starterTitle, workspaceStarterGrid());
  return wrapper;
}

function workspaceBlueprintCard(blueprint, currentBlueprint = null) {
  const active = workspaceBlueprintMatchesSnapshot(blueprint, currentBlueprint);
  const card = document.createElement("div");
  card.className = `recent-folder-card workspace-blueprint-card${active ? " is-active" : ""}`;
  const activeSearch = active ? " active current" : "";
  card.dataset.settingsSearch = normalizeSettingsQuery(`workspace blueprint saved layout pane template${activeSearch} ${blueprint.label} ${workspaceBlueprintSummary(blueprint)}`);

  const text = document.createElement("div");
  text.className = "recent-folder-text";
  const name = document.createElement("div");
  name.className = "recent-folder-name workspace-blueprint-name";
  const nameText = document.createElement("span");
  nameText.textContent = blueprint.label;
  name.append(nameText);
  if (active) {
    const status = document.createElement("span");
    status.className = "settings-profile-status";
    status.textContent = "Active";
    name.append(status);
  }
  name.title = blueprint.label;
  const summary = document.createElement("div");
  summary.className = "recent-folder-path workspace-blueprint-summary";
  summary.textContent = workspaceBlueprintSummary(blueprint);
  summary.title = summary.textContent;
  text.append(name, summary);

  const actions = document.createElement("div");
  actions.className = "recent-folder-actions workspace-blueprint-actions";
  const add = settingsActionButton(active ? "Active" : "Add", () => applyWorkspaceBlueprint(blueprint.id), active ? "primary" : "", `${active ? "active current " : ""}add apply workspace blueprint ${blueprint.label}`);
  add.disabled = active;
  actions.append(
    settingsActionButton("New", () => createWorkspaceFromBlueprint(blueprint.id), "", `new workspace from blueprint ${blueprint.label}`),
    add,
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
      backgroundImage: panel.backgroundImage || "",
      cwd: panel.cwd || workspace.cwd || "",
      shellProfile: panel.shellProfile || state.settings.terminalProfile,
      shellPath: panel.shellPath || "",
      terminalFontSize: panel.terminalFontSize || 0,
      url: panel.url || state.settings.browserHomeUrl,
      weight: storedPaneWeight(panel.id, direction) || equalWeight
    }))
  });
}

function workspaceBlueprintComparableModel(blueprint) {
  if (!blueprint) return null;
  return {
    splitDirection: blueprint.splitDirection,
    color: blueprint.color || "",
    cwd: blueprint.cwd || "",
    panels: (blueprint.panels || []).map((panel) => ({
      type: panel.type,
      title: panel.title || "",
      color: panel.color || "",
      backgroundImage: panel.backgroundImage || "",
      cwd: panel.cwd || "",
      shellProfile: panel.shellProfile || "",
      shellPath: panel.shellPath || "",
      terminalFontSize: panel.terminalFontSize || 0,
      url: panel.url || "",
      weight: panel.weight || paneLayoutScale
    }))
  };
}

function workspaceBlueprintMatchesSnapshot(blueprint, snapshot) {
  if (!blueprint || !snapshot) return false;
  return stableJson(workspaceBlueprintComparableModel(blueprint))
    === stableJson(workspaceBlueprintComparableModel(snapshot));
}

async function saveCurrentWorkspaceBlueprint() {
  const workspace = activeWorkspace();
  if (!workspace || workspace.panels.length === 0) {
    toast("Open panes before saving a blueprint.");
    return;
  }
  if (workspaceBlueprintsFull()) {
    toast(workspaceBlueprintLimitTitle());
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
    const results = await Promise.allSettled(blueprint.panels.map((panel) => createPanel(panel.type, blueprint.splitDirection, {
        workspaceId: workspace.id,
        focus: false,
        reconcile: false,
        operation: false,
        title: panel.title,
        color: panel.color,
        backgroundImage: panel.backgroundImage,
        cwd: panel.cwd || blueprint.cwd || workspace.cwd,
        shellProfile: panel.shellProfile,
        shellPath: panel.shellPath,
        terminalFontSize: panel.terminalFontSize,
        url: panel.url
      })));
    if (results.some((result) => result.status === "rejected" || !result.value?.id)) {
      throw new Error("Workspace blueprint panel creation failed.");
    }
    const createdPanels = results.map((result, index) => ({
      id: result.value.id,
      weight: blueprint.panels[index].weight
    }));
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

function contextPaneSummary(panel, workspace) {
  const title = panelDisplayTitle(panel, true);
  const fullTitle = panelDisplayTitle(panel, false);
  const isBrowser = panel.type === "browser";
  const typeLabel = isBrowser ? "Browser" : "Terminal";
  const meta = isBrowser
    ? browserPanelUrl(panel) || panel.url || state.settings.browserHomeUrl
    : `${workspace?.title || "Workspace"} / ${panel.cwdShort || workspace?.cwdShort || "~"} / ${optionLabel(terminalProfiles, panel.shellProfile || state.settings.terminalProfile, "Shell")}`;
  const summary = document.createElement("div");
  summary.className = "context-pane-summary";
  summary.style.setProperty("--context-pane-color", panel.color || workspace?.color || state.settings.accent);
  summary.innerHTML = `
    <span class="context-pane-summary-icon" aria-hidden="true"></span>
    <span class="context-pane-summary-copy">
      <span class="context-pane-summary-title"></span>
      <span class="context-pane-summary-meta"></span>
    </span>
    <span class="context-pane-summary-kind"></span>
  `;
  summary.querySelector(".context-pane-summary-icon").innerHTML = controlIconMarkup(isBrowser ? "browser" : "terminal");
  summary.querySelector(".context-pane-summary-title").textContent = title;
  summary.querySelector(".context-pane-summary-title").title = fullTitle;
  summary.querySelector(".context-pane-summary-meta").textContent = meta;
  summary.querySelector(".context-pane-summary-meta").title = meta;
  summary.querySelector(".context-pane-summary-kind").textContent = typeLabel;
  return summary;
}

function showPanelContextMenu(event, panel) {
  event.preventDefault();
  event.stopPropagation();
  const menu = ensureContextMenu();
  menu.className = "context-menu context-menu-pane";
  const found = findPanelState(panel.id);
  if (!found) return;
  const index = found.workspace.panels.findIndex((candidate) => candidate.id === panel.id);
  const panesToRight = found.workspace.panels.slice(index + 1);
  const summary = contextPaneSummary(panel, found.workspace);
  if (isPendingPanel(panel)) {
    menu.replaceChildren(
      summary,
      contextMenuButton(panel.type === "browser" ? "Opening..." : "Starting...", () => {}, true, "", {
        icon: panel.type === "browser" ? "browserPlus" : "terminalPlus"
      })
    );
    showContextMenuAt(menu, event.clientX, event.clientY);
    return;
  }
  const isTerminal = panel.type === "terminal";
  const isBrowser = panel.type === "browser";
  const generalActions = contextMenuActionGroup(
    contextMenuButton("Rename", () => renamePanel(panel), false, "", { icon: "rename" }),
    contextMenuButton("Use default name", () => updatePanel(panel.id, { title: "" }), !panel.titleLocked, "", { icon: "reload" }),
    contextMenuButton("Customize tab", () => openPaneAppearanceSettings(panel), false, "", { icon: "palette" }),
    contextMenuButton("Duplicate", () => duplicatePanel(panel), false, "", { icon: "copy" }),
    isTerminal
      ? contextMenuButton("New terminal tab", () => createTerminalPanel("right", { anchorPanelId: panel.id }), false, "", { icon: "terminalPlus" })
      : contextMenuButton("New browser tab", () => newBrowserTabFromPanel(panel), false, "", { icon: "browserPlus" }),
    contextMenuButton("Split right", () => splitPanel(panel, "right"), false, "", { icon: "splitRight" }),
    contextMenuButton("Split down", () => splitPanel(panel, "down"), false, "", { icon: "splitDown" }),
    contextMenuButton(isPanelMinimized(panel) ? "Restore pane" : "Minimize pane", () => togglePaneMinimized(panel.id), false, "", {
      icon: isPanelMinimized(panel) ? "maximize" : "minimize"
    })
  );
  const surfaceActions = [];
  if (isTerminal) {
    surfaceActions.push(
      contextMenuButton("Find", () => openTerminalSearch(panel), false, "", { icon: "search" }),
      contextMenuButton("Find next", () => findNextInTerminal(panel), false, "", { icon: "arrowRight" }),
      contextMenuButton("Copy selection", () => copyActiveTerminalSelection(panel), false, "", { icon: "copy" }),
      contextMenuButton("Paste", () => pasteClipboardToTerminal(panel), false, "", { icon: "clipboard" }),
      contextMenuButton("Clear terminal", () => clearTerminalPanel(panel), false, "", { icon: "close" }),
      contextMenuButton("Text larger", () => changePaneTerminalFontSize(panel.id, 1), false, "", { icon: "textSize" }),
      contextMenuButton("Text smaller", () => changePaneTerminalFontSize(panel.id, -1), false, "", { icon: "textSize" }),
      contextMenuButton("Reset text size", () => resetPaneTerminalFontSize(panel.id), !panelHasTerminalFontSize(panel), "", { icon: "reload" }),
      contextMenuButton("Restart terminal", () => restartPanel(panel.id), false, "", { icon: "reload" }),
      contextMenuButton("Choose pane background", () => choosePanelBackgroundImage(panel), false, "", { icon: "image" }),
      contextMenuButton("Use app background", () => applyPanelBackgroundImage(state.settings.backgroundImage, panel), !state.settings.backgroundImage, "", { icon: "image" }),
      (() => {
        const action = contextMenuButton("Save pane background", () => saveCustomBackgroundImage({ url: panel.backgroundImage }), !canSaveBackgroundImage(panel.backgroundImage), "", { icon: "plus" });
        action.title = savedBackgroundImageSaveTitle(panel.backgroundImage, "Save this pane background image.");
        return action;
      })(),
      contextMenuButton("Clear pane background", () => applyPanelBackgroundImage("", panel), !panel.backgroundImage, "", { icon: "close" }),
      contextMenuButton("Terminal settings", () => openSettingsCategory("terminal"), false, "", { icon: "settings" })
    );
  }
  if (isBrowser) {
    surfaceActions.push(
      contextMenuButton("Focus address", () => focusBrowserAddress(panel), false, "", { icon: "search" }),
      contextMenuButton("Reload page", () => reloadBrowserPanel(panel), false, "", { icon: "reload" }),
      contextMenuButton("Open externally", () => openBrowserPanelExternally(panel), false, "", { icon: "external" }),
      contextMenuButton(t("browser.openWithProfile"), () => showExternalBrowserProfileMenuAt(event.clientX, event.clientY, browserPanelUrl(panel)), false, "", { keepOpen: true, icon: "browser" }),
      contextMenuButton("Copy URL", () => copyBrowserPanelUrl(panel), false, "", { icon: "copy" }),
      contextMenuButton("Browser settings", () => openSettingsCategory("browser"), false, "", { icon: "settings" })
    );
  }
  const layoutActions = contextMenuActionGroup(
    contextMenuButton("Set pane size", () => promptPanelLayoutPercent(panel), found.workspace.panels.length <= 1, "", { icon: "layout" }),
    contextMenuButton(isPanelZoomed(panel, found.workspace) ? "Show all panes" : "Focus pane", () => togglePaneZoom(panel.id), false, "", { icon: "maximize" }),
    contextMenuButton("Equalize panes", () => applyPaneLayoutPreset("equal", { panelId: panel.id }), found.workspace.panels.length <= 1, "", { icon: "layout" }),
    contextMenuButton("Grid layout", () => applyPaneLayoutPreset("grid", { panelId: panel.id }), found.workspace.panels.length <= 1, "", { icon: "layout" }),
    contextMenuButton("Active pane wide", () => applyPaneLayoutPreset("activeWide", { panelId: panel.id }), found.workspace.panels.length <= 1, "", { icon: "splitRight" }),
    contextMenuButton("Active pane tall", () => applyPaneLayoutPreset("activeTall", { panelId: panel.id }), found.workspace.panels.length <= 1, "", { icon: "splitDown" }),
    contextMenuButton("Move left", () => movePanelLeft(found.workspace, index), index <= 0, "", { icon: "back" }),
    contextMenuButton("Move right", () => movePanelRight(found.workspace, index), index >= found.workspace.panels.length - 1, "", { icon: "arrowRight" })
  );
  const closeActions = contextMenuActionGroup(
    contextMenuButton("Close other panes", () => closeOtherPanes(panel.id), found.workspace.panels.length <= 1, "danger", { icon: "close" }),
    contextMenuButton("Close panes to right", () => closePanelsById(panesToRight.map((candidate) => candidate.id)), panesToRight.length === 0, "danger", { icon: "close" }),
    contextMenuButton("Close all panes", () => closeAllPanes(found.workspace), found.workspace.panels.length === 0, "danger", { icon: "close" }),
    contextMenuButton(closePaneActionLabel(found.workspace, panel.id), () => closePanel(panel.id), false, "danger", { icon: "close" })
  );
  const colorTitle = document.createElement("div");
  colorTitle.className = "context-section-title";
  colorTitle.textContent = "Tab appearance";
  const colors = document.createElement("div");
  colors.className = "context-colors";
  for (const [colorIndex, color] of workspaceColorPalette().entries()) {
    const button = document.createElement("button");
    button.className = `context-color${panel.color === color ? " is-active" : ""}`;
    button.type = "button";
    const label = contextColorButtonLabel("tab", color, panel.color === color, colorIndex);
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(panel.color === color));
    button.style.setProperty("--context-color", color);
    button.onclick = () => {
      updatePanel(panel.id, { color });
      hideContextMenu();
    };
    colors.append(button);
  }
  const appearanceSettings = contextMenuButton("All appearance settings", () => openSettingsCategory("appearance"), false, "", { icon: "settings" });
  const clear = contextMenuButton("Clear color", () => updatePanel(panel.id, { color: "" }), !panel.color, "", { icon: "close" });
  const saveColor = contextMenuButton("Save color", () => upsertCustomColorPalette(panel.color), !canSaveCustomColor(panel.color), "", { icon: "plus" });
  saveColor.title = customColorSaveTitle(panel.color, "Save this pane color to the reusable palette.");
  const customColor = contextColorPicker(panel.color, (color) => {
    updatePanel(panel.id, { color });
    upsertCustomColorPalette(color, { render: false, toast: false });
  });
  const nodes = [
    summary,
    contextMenuSectionTitle("Tab"),
    generalActions,
    colorTitle,
    colors,
    customColor,
    contextMenuActionGroup(appearanceSettings, saveColor, clear)
  ];
  if (surfaceActions.length) {
    nodes.push(contextMenuSectionTitle(isTerminal ? "Terminal" : "Browser"), contextMenuActionGroup(...surfaceActions));
  }
  nodes.push(
    contextMenuSectionTitle("Layout"),
    layoutActions,
    contextMenuSectionTitle("Close"),
    closeActions
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
    contextMenuButton("New terminal here", () => createTerminalPanel("right", { workspaceId: workspace.id })),
    contextMenuButton("Open browser here", () => openBrowserPrompt(workspace.id)),
    contextMenuButton("New workspace", () => createWorkspace()),
    contextMenuButton("New workspace from folder", () => createWorkspaceFromFolder()),
    contextMenuButton("Close all panes", () => closeAllPanes(workspace), workspace.panels.length === 0, "danger"),
    contextMenuButton("Close workspace", () => closeWorkspaceById(workspace.id), false, "danger")
  );
  const colors = document.createElement("div");
  colors.className = "context-colors";
  for (const [colorIndex, color] of workspaceColorPalette().entries()) {
    const button = document.createElement("button");
    button.className = `context-color${workspace.color === color ? " is-active" : ""}`;
    button.type = "button";
    const label = contextColorButtonLabel("workspace", color, workspace.color === color, colorIndex);
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(workspace.color === color));
    button.style.setProperty("--context-color", color);
    button.onclick = () => {
      setWorkspaceColor(color, workspace.id);
      hideContextMenu();
    };
    colors.append(button);
  }
  const customColor = contextColorPicker(workspace.color, (color) => {
    setWorkspaceColor(color, workspace.id);
    upsertCustomColorPalette(color, { render: false, toast: false });
  });
  const saveColor = contextMenuButton("Save color", () => upsertCustomColorPalette(workspace.color), !canSaveCustomColor(workspace.color));
  saveColor.title = customColorSaveTitle(workspace.color, "Save this workspace color to the reusable palette.");
  const hasTerminalPanes = (workspace.panels || []).some((panel) => panel.type === "terminal");
  const backgroundActions = contextMenuActionGroup(
    contextMenuButton(t("workspace.chooseTerminalBackground"), () => chooseWorkspaceTerminalBackground(workspace), !hasTerminalPanes),
    contextMenuButton(t("workspace.pasteTerminalBackground"), () => pasteWorkspaceTerminalBackgroundFromClipboard(workspace), !hasTerminalPanes),
    contextMenuButton(t("workspace.useAppBackground"), () => applyWorkspaceBackgroundImageToTerminals(state.settings.backgroundImage, workspace), !hasTerminalPanes || !state.settings.backgroundImage),
    contextMenuButton(t("workspace.clearTerminalBackgrounds"), () => applyWorkspaceBackgroundImageToTerminals("", workspace), !hasTerminalPanes, "danger"),
    contextMenuButton(t("workspace.backgroundSettings"), () => openSettingsCategory("appearance", { query: "background", focusSearch: true }))
  );
  menu.replaceChildren(
    title,
    meta,
    actions,
    contextMenuSectionTitle("Workspace color"),
    colors,
    customColor,
    contextMenuActionGroup(saveColor),
    contextMenuSectionTitle(t("workspace.backgrounds")),
    backgroundActions
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
    ...[1, 5, 10, 25, 33, 50, 67, 75, 90, 95, 99].map((nextPercent) => (
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
      contextMenuButton("Customize active pane", () => openPaneSettings(panel), !panel),
      contextMenuButton("Active pane appearance", () => openPaneAppearanceSettings(panel), !panel),
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
      contextMenuButton("Reset workspace chrome", resetWorkspaceChrome, workspaceChromeSettingsAreDefault()),
      contextMenuButton("Equalize panes", () => applyPaneLayoutPreset("equal"), !multiPane),
      contextMenuButton("Grid layout", () => applyPaneLayoutPreset("grid"), !multiPane),
      contextMenuButton("Active pane wide", () => applyPaneLayoutPreset("activeWide"), !multiPane),
      contextMenuButton("Active pane tall", () => applyPaneLayoutPreset("activeTall"), !multiPane),
      contextMenuButton("Set active pane size", promptActivePaneLayoutPercent, !multiPane),
      contextMenuButton("Close other panes", () => closeOtherPanes(), !multiPane, "danger"),
      contextMenuButton("Close all panes", () => closeAllPanes(workspace), !workspace?.panels.length, "danger")
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
      contextMenuButton("Choose terminal background", () => choosePanelBackgroundImage(panel), !terminalActive),
      contextMenuButton("Terminal settings", () => openSettingsCategory("terminal")),
      contextMenuButton("Reset terminal colors", () => applyTerminalColorPresetById("cmux"), isTerminalColorPresetIdActive("cmux"))
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
      (() => {
        const action = contextMenuButton("Save workspace blueprint", saveCurrentWorkspaceBlueprint, !canSaveCurrentWorkspaceBlueprint(workspace));
        action.title = currentWorkspaceBlueprintSaveTitle(workspace, "Save the current workspace as a reusable blueprint.");
        return action;
      })(),
      (() => {
        const targets = hasEmptyWorkspaceCleanupTargets();
        const action = contextMenuButton("Close extra empty workspaces", closeEmptyWorkspaces, !targets, "danger");
        action.title = targets ? "Close empty workspaces except the active one." : "There are no extra empty workspaces to close.";
        return action;
      })()
    ),
    contextMenuSectionTitle("Settings"),
    contextMenuActionGroup(
      contextMenuButton("Performance settings", () => openSettingsCategory("performance")),
      contextMenuButton("Tune performance now", () => tunePerformanceNow()),
      contextMenuButton("Copy performance diagnostics", copyPerformanceDiagnostics),
      contextMenuButton("Apply clean + fast preset", () => applySettingsPresetById("simpleFast")),
      contextMenuButton("Save clean + fast profile", () => applyAndSaveCleanFastProfile()),
      contextMenuButton("Apply speed preset", () => applySettingsPresetById("performance")),
      contextMenuButton("Actions settings", () => openSettingsCategory("actions")),
      contextMenuButton("Command snippets", () => openSettingsCategory("commands")),
      contextMenuButton("Settings profiles", () => openSettingsCategory("profiles")),
      (() => {
        const recentActivity = hasRecentActivity();
        const action = contextMenuButton("Clear recent activity", clearRecentActivity, !recentActivity, "danger");
        action.title = recentActivity ? "Clear recent folders, commands, browser pages, and saved browser tabs." : "Recent activity is already clear.";
        return action;
      })(),
      contextMenuButton("Color settings", () => openSettingsCategory("appearance", { query: "color", focusSearch: true })),
      (() => {
        const action = contextMenuButton("Save current accent", () => upsertCustomColorPalette(state.settings.accent), !canSaveCustomColor(state.settings.accent));
        action.title = customColorSaveTitle(state.settings.accent, "Save the current accent color to the reusable palette.");
        return action;
      })(),
      contextMenuButton("Background settings", () => openSettingsCategory("appearance", { query: "background", focusSearch: true })),
      (() => {
        const action = contextMenuButton("Save current background", () => saveCustomBackgroundImage({ url: state.settings.backgroundImage }), !canSaveBackgroundImage(state.settings.backgroundImage));
        action.title = savedBackgroundImageSaveTitle(state.settings.backgroundImage, "Save the current background image.");
        return action;
      })(),
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
  button.className = `context-action${options.icon ? " has-icon" : ""}${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  if (options.icon) {
    button.innerHTML = `
      <span class="context-action-icon" aria-hidden="true">${controlIconMarkup(options.icon)}</span>
      <span class="context-action-label"></span>
    `;
    button.querySelector(".context-action-label").textContent = label;
  } else {
    button.textContent = label;
  }
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

function contextColorButtonLabel(scope, color, active, index = 0) {
  const customColor = normalizeCustomPaletteColor(color);
  const colorName = customColor ? customColor.toUpperCase() : `preset ${index + 1}`;
  return `${active ? "Selected" : "Set"} ${scope} color ${colorName}`;
}

function contextColorPicker(activeColor, onPick) {
  const wrapper = document.createElement("label");
  wrapper.className = "context-color-picker";
  const label = document.createElement("span");
  const customColor = normalizeCustomPaletteColor(activeColor);
  label.textContent = customColor ? `Custom ${customColor.toUpperCase()}` : "Custom color";
  const input = document.createElement("input");
  input.type = "color";
  input.value = colorInputValue(activeColor);
  input.title = "Pick custom color";
  input.setAttribute("aria-label", "Pick custom color");
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
  if (title === null) return;
  if (!title) {
    if (!panel.titleLocked) {
      toast("Pane already uses the default name.");
      return;
    }
    updatePanel(panel.id, { title: "" });
    toast("Pane name reset.");
    return;
  }
  updatePanel(panel.id, { title });
}

function splitPanel(panel, direction, type = "terminal", options = {}) {
  const found = findPanelState(panel?.id);
  if (!found) return null;
  const createOptions = type === "terminal"
    ? { immediateTerminalInit: true, ...options }
    : options;
  return createPanel(type, direction, {
    ...createOptions,
    workspaceId: found.workspace.id,
    anchorPanelId: panel.id
  });
}

function splitActivePanel(direction, type = "terminal", options = {}) {
  const panel = focusedPanel();
  if (panel) return splitPanel(panel, direction, type, options);
  if (type === "terminal") return createTerminalPanel(direction, options);
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
    terminalFontSize: panel.terminalFontSize || 0,
    backgroundImage: panel.backgroundImage || ""
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

function paletteEntriesForOpenSession() {
  const signature = paletteEntriesSignature();
  if (!state.paletteEntriesCache || state.paletteEntriesCacheSignature !== signature) {
    state.paletteEntriesCache = paletteEntries();
    state.paletteEntriesCacheSignature = signature;
    state.paletteListSignature = "";
  }
  return state.paletteEntriesCache;
}

function paletteEntriesSignature() {
  const parts = [];
  const workspace = activeWorkspace();
  appendSignatureValue(parts, state.dataSignature || "");
  if (workspace) {
    appendSignatureValue(parts, workspace.id);
    appendSignatureValue(parts, workspace.activePanelId);
    appendSignatureValue(parts, workspace.splitDirection);
    appendSignatureData(parts, state.paneTrees.get(workspace.id) || null);
  }
  appendSignatureData(parts, state.recentFolders);
  appendSignatureData(parts, state.recentCommands);
  appendSignatureData(parts, state.recentBrowserPages);
  appendSignatureData(parts, state.customCommandSnippets);
  appendSignatureData(parts, state.customColorPalette);
  appendSignatureData(parts, state.savedBackgroundImages);
  appendSignatureData(parts, state.savedSettingsProfiles);
  appendSignatureData(parts, state.workspaceBlueprints);
  appendSignatureValue(parts, state.settings.browserHomeUrl);
  appendSignatureValue(parts, settingsKeysSignature(profileSettingsSettingKeys));
  return parts.join("");
}

function paletteQuickActions() {
  const workspace = activeWorkspace();
  const active = focusedPanel();
  const creatingPane = paneCreationButtonsDisabled();
  const actions = [
    {
      id: "quick.terminal",
      label: t("palette.quickTerminal"),
      meta: workspace?.title || t("palette.quickWorkspace"),
      shortcut: "Ctrl+T",
      icon: "terminalPlus",
      disabled: creatingPane,
      run: () => createTerminalPanel("right", { workspaceId: workspace?.id })
    },
    {
      id: "quick.browser",
      label: t("palette.quickBrowser"),
      meta: hostnameOf(state.settings.browserHomeUrl),
      shortcut: "Ctrl+Shift+L",
      icon: "browserPlus",
      disabled: creatingPane,
      run: () => openBrowserHome(workspace?.id)
    },
    {
      id: "quick.split",
      label: t("palette.quickSplit"),
      meta: active?.type === "browser" ? hostnameOf(active.url) : active?.title || t("palette.quickPane"),
      shortcut: "",
      icon: "splitRight",
      disabled: !active || creatingPane,
      run: () => splitActivePanel("right")
    },
    {
      id: "quick.settings",
      label: t("palette.quickSettings"),
      meta: t("palette.quickSettingsMeta"),
      shortcut: "Ctrl+,",
      icon: "settings",
      disabled: false,
      run: () => openInspector("settings")
    }
  ];
  if (!isSettingsPresetIdActive("simpleFast")) {
    actions.splice(2, 0, {
      id: "quick.fastSetup",
      label: t("palette.quickFastSetup"),
      meta: t("palette.quickFastSetupMeta"),
      shortcut: "",
      icon: "speed",
      disabled: false,
      run: () => applySettingsPresetById("simpleFast")
    });
  }
  if (!activeSavedSettingsProfile() && !savedSettingsProfilesFull()) {
    actions.splice(Math.min(actions.length, 3), 0, {
      id: "quick.saveSetup",
      label: t("palette.quickSaveSetup"),
      meta: activeSettingsSetupLabel(),
      shortcut: "",
      icon: "save",
      disabled: false,
      run: () => saveQuickSetupProfile()
    });
  }
  return actions;
}

function renderPaletteQuickActions() {
  const group = document.createElement("div");
  group.className = "palette-quick-actions";
  group.setAttribute("aria-label", t("palette.quickActions"));
  for (const action of paletteQuickActions()) {
    const button = document.createElement("button");
    button.className = "palette-quick-action";
    button.type = "button";
    button.disabled = Boolean(action.disabled);
    button.title = `${action.label}${action.meta ? ` - ${action.meta}` : ""}`;
    button.innerHTML = `
      <span class="palette-quick-icon" aria-hidden="true"></span>
      <span class="palette-quick-copy">
        <span class="palette-quick-label"></span>
        <span class="palette-quick-meta"></span>
      </span>
      <span class="palette-quick-shortcut"></span>
    `;
    button.querySelector(".palette-quick-icon").innerHTML = controlIconMarkup(action.icon);
    button.querySelector(".palette-quick-label").textContent = action.label;
    button.querySelector(".palette-quick-meta").textContent = action.meta || "";
    button.querySelector(".palette-quick-shortcut").textContent = action.shortcut || "";
    button.onclick = () => {
      if (button.disabled) return;
      closePalette();
      elements.paletteInput.value = "";
      action.run();
    };
    group.append(button);
  }
  return group;
}

function renderPalette() {
  elements.palette.classList.toggle("is-open", state.paletteOpen);
  elements.palette.setAttribute("aria-hidden", String(!state.paletteOpen));
  if (!state.paletteOpen) return;

  const query = normalizeSettingsQuery(elements.paletteInput.value);
  const tokens = settingsSearchTokens(query);
  const allMatches = paletteEntriesForOpenSession()
    .filter((entry) => paletteEntryMatches(entry, tokens))
    .sort((left, right) => paletteEntryScore(right, query, tokens) - paletteEntryScore(left, query, tokens));
  const matches = allMatches.slice(0, paletteVisibleResultLimit);
  state.paletteIndex = Math.min(state.paletteIndex, Math.max(0, matches.length - 1));
  const signature = paletteListSignature(query, matches, allMatches.length);
  if (signature === state.paletteListSignature) {
    updatePaletteSelection();
    return;
  }
  state.paletteListSignature = signature;
  const nodes = [];
  if (!query) nodes.push(renderPaletteQuickActions());
  nodes.push(...matches.map((entry, index) => {
    const button = document.createElement("button");
    const kind = paletteEntryKind(entry);
    button.type = "button";
    button.className = `palette-item palette-kind-${kind}${entry.active ? " is-active-entry" : ""}${index === state.paletteIndex ? " is-selected" : ""}`;
    button.setAttribute("aria-selected", String(index === state.paletteIndex));
    if (entry.active) button.setAttribute("aria-current", "true");
    button.innerHTML = `
      <span class="palette-icon" aria-hidden="true"></span>
      <span class="palette-main">
        <span class="palette-label"></span>
        <span class="palette-meta"></span>
      </span>
      <span class="palette-shortcut"></span>
    `;
    button.querySelector(".palette-icon").innerHTML = paletteEntryIconMarkup(entry, kind);
    button.querySelector(".palette-label").textContent = entry.label;
    button.querySelector(".palette-meta").textContent = entry.meta;
    button.querySelector(".palette-shortcut").textContent = entry.shortcut;
    button.onclick = () => runPaletteCommand(entry);
    return button;
  }));
  if (matches.length === 0) {
    const empty = document.createElement("div");
    empty.className = "palette-empty";
    empty.textContent = t("palette.empty");
    nodes.push(empty);
  }
  if (allMatches.length > matches.length) {
    const more = document.createElement("div");
    more.className = "palette-more";
    more.textContent = formatMessage("palette.moreResults", {
      visible: matches.length,
      total: allMatches.length
    });
    nodes.push(more);
  }
  elements.paletteList.replaceChildren(...nodes);
}

function paletteListSignature(query, entries, totalCount = entries.length) {
  const parts = [];
  appendSignatureValue(parts, query);
  appendSignatureValue(parts, totalCount);
  if (!query) appendSignatureValue(parts, paletteQuickActionsSignature());
  appendSignatureArray(parts, entries, (nextParts, entry) => {
    appendSignatureValue(nextParts, entry.id);
    appendSignatureValue(nextParts, entry.label);
    appendSignatureValue(nextParts, entry.meta);
    appendSignatureValue(nextParts, entry.shortcut);
  });
  return parts.join("");
}

function paletteQuickActionsSignature() {
  const workspace = activeWorkspace();
  const active = focusedPanel();
  const parts = [];
  appendSignatureValue(parts, workspace?.id || "");
  appendSignatureValue(parts, workspace?.title || "");
  appendSignatureValue(parts, active?.id || "");
  appendSignatureValue(parts, active?.type || "");
  appendSignatureValue(parts, active?.title || "");
  appendSignatureValue(parts, active?.url || "");
  appendSignatureValue(parts, state.settings.browserHomeUrl);
  appendSignatureValue(parts, isSettingsPresetIdActive("simpleFast"));
  appendSignatureValue(parts, Boolean(activeSavedSettingsProfile()));
  appendSignatureValue(parts, activeSettingsSetupLabel());
  appendSignatureValue(parts, state.savedSettingsProfiles.length);
  appendSignatureValue(parts, paneCreationButtonsDisabled());
  return parts.join("");
}

function paletteEntryKind(entry) {
  const id = String(entry?.id || "");
  if (id.startsWith("terminal.") || id.startsWith("recentCommand.") || id.startsWith("commandSnippet.")) return "terminal";
  if (id.startsWith("browser.") || id.startsWith("recentBrowser.") || id.startsWith("browserHomePreset.")) return "browser";
  if (id.startsWith("workspace.") || id.startsWith("recentFolder.") || id.startsWith("workspaceBlueprint.")) return "workspace";
  if (id.startsWith("settings.") || id.startsWith("settingsPreset.") || id.startsWith("settingsProfile.")) return "settings";
  if (id.startsWith("layout.")) return "layout";
  if (id.startsWith("background") || id.startsWith("savedBackground")) return "look";
  if (id.startsWith("savedColor.") || id.startsWith("terminalColor.")) return "color";
  return "command";
}

function paletteEntryIconMarkup(entry, kind = paletteEntryKind(entry)) {
  if (kind === "terminal") return controlIconMarkup("terminal");
  if (kind === "browser") return controlIconMarkup("browser");
  if (kind === "workspace") return quickActionIconMarkup("workspace");
  if (kind === "settings") return controlIconMarkup("settings");
  if (kind === "layout") return controlIconMarkup("splitRight");
  if (kind === "look") return quickActionIconMarkup("background");
  if (kind === "color") return quickActionIconMarkup("appearance");
  return quickActionIconMarkup("actions");
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
  const activeLayoutCommandIds = activePaneLayoutCommandIds();
  const entries = commands.map((command) => {
    const active = activeLayoutCommandIds.has(command.id);
    return {
      id: command.id,
      label: command.label,
      meta: active ? "Active layout command" : "Command",
      shortcut: active ? "Active" : command.shortcut,
      active,
      search: normalizeSettingsQuery(`${command.label} ${command.shortcut} command ${active ? "active current layout" : ""}`),
      run: command.run
    };
  });
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
    const active = isActiveTerminalColorPreset(preset);
    entries.push({
      id: `terminalColor.${preset.id}`,
      label: `Terminal colors: ${preset.label}`,
      meta: active ? `Active / ${preset.body}` : preset.body,
      shortcut: active ? "Active" : "Theme",
      active,
      search: normalizeSettingsQuery(`terminal colors theme preset apply active ${preset.label} ${preset.body}`),
      run: () => applyTerminalColorPreset(preset)
    });
  }
  for (const preset of settingsPresets) {
    const summary = settingsProfileSummary(preset.settings);
    const active = isActiveSettingsPreset(preset);
    entries.push({
      id: `settingsPreset.${preset.id}`,
      label: `Preset: ${preset.label}`,
      meta: active ? `Active / ${preset.body || summary}` : preset.body || summary,
      shortcut: active ? "Active" : "Preset",
      active,
      search: normalizeSettingsQuery(`settings preset profile setup apply active ${preset.label} ${preset.body} ${summary}`),
      run: () => applySettingsPreset(preset)
    });
  }
  const paletteWorkspace = activeWorkspace();
  const paletteActiveTerminal = activeTerminalPanelForSettings();
  for (const preset of backgroundPresets) {
    const presetId = preset.value || "none";
    const activeApp = normalizeBackgroundValue(state.settings.backgroundImage) === normalizeBackgroundValue(preset.value);
    const activePane = Boolean(paletteActiveTerminal && panelBackgroundMatches(paletteActiveTerminal, preset.value));
    const activeAll = terminalBackgroundsMatch(paletteWorkspace, preset.value);
    const appMeta = preset.value ? "Built-in background" : "No background";
    entries.push({
      id: `backgroundPreset.${presetId}`,
      label: `Background template: ${preset.label}`,
      meta: activeApp ? `Active / ${appMeta}` : appMeta,
      shortcut: activeApp ? "Active" : "Look",
      active: activeApp,
      search: normalizeSettingsQuery(`background preset template image wallpaper look apply active app whole window ${preset.label} ${preset.value}`),
      run: () => applyBackgroundPreset(preset, { toast: true })
    });
    entries.push({
      id: `backgroundPresetPane.${presetId}`,
      label: `Pane background: ${preset.label}`,
      meta: activePane ? "Active / Active terminal pane" : "Active terminal pane",
      shortcut: activePane ? "Active" : "Look",
      active: activePane,
      search: normalizeSettingsQuery(`background preset template image wallpaper apply active terminal pane ${preset.label} ${preset.value}`),
      run: () => applyPanelBackgroundImage(preset.value, activeTerminalPanelForSettings())
    });
    entries.push({
      id: `backgroundPresetTerminals.${presetId}`,
      label: `Terminal backgrounds: ${preset.label}`,
      meta: activeAll ? "Active / All terminal panes in workspace" : "All terminal panes in workspace",
      shortcut: activeAll ? "Active" : "Look",
      active: activeAll,
      search: normalizeSettingsQuery(`background preset template image wallpaper apply active all terminal panes workspace ${preset.label} ${preset.value}`),
      run: () => applyWorkspaceBackgroundImageToTerminals(preset.value)
    });
  }
  for (const preset of browserHomePresets) {
    const active = isActiveBrowserHomePreset(preset);
    entries.push({
      id: `browserHomePreset.${preset.id}`,
      label: `Browser home: ${preset.label}`,
      meta: active ? `Active / ${preset.url}` : preset.url,
      shortcut: active ? "Active" : "Browser",
      active,
      search: normalizeSettingsQuery(`browser home preset start page homepage apply active ${preset.label} ${preset.body} ${preset.url}`),
      run: () => applyBrowserHomePreset(preset)
    });
  }
  const paletteActivePane = activePaneForColorTarget();
  for (const color of state.customColorPalette) {
    const colorValue = colorKey(color);
    const activeAccent = colorKey(state.settings.accent) === colorValue;
    const activeWorkspaceColor = colorKey(paletteWorkspace?.color) === colorValue;
    const activePaneColor = colorKey(paletteActivePane?.color) === colorValue;
    const activeAllPaneColors = Boolean(paletteWorkspace?.panels?.length)
      && paletteWorkspace.panels.every((panel) => colorKey(panel.color) === colorValue);
    const workspaceMeta = paletteWorkspace?.title || "Active workspace";
    entries.push({
      id: `savedColor.accent.${color.slice(1)}`,
      label: `Accent color: ${color}`,
      meta: activeAccent ? "Active / Saved color" : "Saved color",
      shortcut: activeAccent ? "Active" : "Color",
      active: activeAccent,
      search: normalizeSettingsQuery(`saved color palette custom accent active ${color}`),
      run: () => updateSettings({ accent: color })
    });
    entries.push({
      id: `savedColor.workspace.${color.slice(1)}`,
      label: `Workspace color: ${color}`,
      meta: activeWorkspaceColor ? `Active / ${workspaceMeta}` : workspaceMeta,
      shortcut: activeWorkspaceColor ? "Active" : "Color",
      active: activeWorkspaceColor,
      search: normalizeSettingsQuery(`saved color palette custom workspace pane tab active ${color}`),
      run: () => setWorkspaceColor(color)
    });
    entries.push({
      id: `savedColor.pane.${color.slice(1)}`,
      label: `Pane color: ${color}`,
      meta: activePaneColor ? "Active / Active pane" : "Active pane",
      shortcut: activePaneColor ? "Active" : "Color",
      active: activePaneColor,
      search: normalizeSettingsQuery(`saved color palette custom active pane tab ${color}`),
      run: () => applySavedColorToTarget(color, "pane")
    });
    entries.push({
      id: `savedColor.all.${color.slice(1)}`,
      label: `All pane colors: ${color}`,
      meta: activeAllPaneColors ? "Active / Current workspace" : "Current workspace",
      shortcut: activeAllPaneColors ? "Active" : "Color",
      active: activeAllPaneColors,
      search: normalizeSettingsQuery(`saved color palette custom active all panes workspace ${color}`),
      run: () => applySavedColorToTarget(color, "all")
    });
  }
  for (const background of state.savedBackgroundImages) {
    const activeApp = normalizeBackgroundValue(state.settings.backgroundImage) === normalizeBackgroundValue(background.url);
    const activePane = Boolean(paletteActiveTerminal && panelBackgroundMatches(paletteActiveTerminal, background.url));
    const activeAll = terminalBackgroundsMatch(paletteWorkspace, background.url);
    entries.push({
      id: `savedBackground.${background.id}`,
      label: `Background: ${background.label}`,
      meta: activeApp ? `Active / ${background.url}` : background.url,
      shortcut: activeApp ? "Active" : "Look",
      active: activeApp,
      search: normalizeSettingsQuery(`saved background image wallpaper apply active app whole window ${background.label} ${background.url}`),
      run: () => applySavedBackgroundImage(background.id)
    });
    entries.push({
      id: `savedBackgroundPane.${background.id}`,
      label: `Pane background: ${background.label}`,
      meta: activePane ? "Active / Active terminal pane" : "Active terminal pane",
      shortcut: activePane ? "Active" : "Look",
      active: activePane,
      search: normalizeSettingsQuery(`saved background image wallpaper apply active terminal pane ${background.label} ${background.url}`),
      run: () => applySavedBackgroundImageToPanel(background.id)
    });
    entries.push({
      id: `savedBackgroundTerminals.${background.id}`,
      label: `Terminal backgrounds: ${background.label}`,
      meta: activeAll ? "Active / All terminal panes in workspace" : "All terminal panes in workspace",
      shortcut: activeAll ? "Active" : "Look",
      active: activeAll,
      search: normalizeSettingsQuery(`saved background image wallpaper apply active all terminal panes workspace ${background.label} ${background.url}`),
      run: () => applySavedBackgroundImageToWorkspaceTerminals(background.id)
    });
  }
  for (const profile of state.savedSettingsProfiles) {
    const summary = settingsProfileSummary(profile.settings);
    const active = isActiveSettingsProfile(profile);
    entries.push({
      id: `settingsProfile.${profile.id}`,
      label: `Profile: ${profile.label}`,
      meta: active ? `Active / ${summary}` : summary,
      shortcut: active ? "Active" : "Profile",
      active,
      search: normalizeSettingsQuery(`settings profile preset saved apply active ${profile.label} ${summary}`),
      run: () => applySavedSettingsProfile(profile.id)
    });
  }
  const currentPaletteBlueprint = state.workspaceBlueprints.length > 0 ? currentWorkspaceBlueprintSnapshot("Current setup") : null;
  for (const blueprint of state.workspaceBlueprints) {
    const summary = workspaceBlueprintSummary(blueprint);
    const active = workspaceBlueprintMatchesSnapshot(blueprint, currentPaletteBlueprint);
    entries.push({
      id: `workspaceBlueprint.${blueprint.id}`,
      label: `Blueprint: ${blueprint.label}`,
      meta: active ? `Active / ${summary}` : summary,
      shortcut: active ? "Active" : "Blueprint",
      active,
      search: normalizeSettingsQuery(`workspace blueprint layout template new add apply ${active ? "active current " : ""}${blueprint.label} ${summary}`),
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
  state.paletteEntriesCache = null;
  state.paletteEntriesCacheSignature = "";
  state.paletteListSignature = "";
  renderPalette();
  elements.paletteList.scrollTop = 0;
  schedulePaletteFocus();
}

function closePalette() {
  state.paletteOpen = false;
  cancelPaletteFocus();
  state.paletteEntriesCache = null;
  state.paletteEntriesCacheSignature = "";
  state.paletteListSignature = "";
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
  const nextTitle = trimmed.slice(0, 80);
  if (!workspace || !nextTitle || nextTitle === workspace.title) return false;
  return await updateWorkspace(workspace.id, { title: nextTitle });
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

async function applyWorkspaceStarter(starterId, workspaceId = activeWorkspace()?.id, options = {}) {
  const starter = workspaceStarters.find((candidate) => candidate.id === starterId);
  const workspace = state.data?.workspaces.find((candidate) => candidate.id === workspaceId);
  if (!starter || !workspace) {
    toast("No workspace available.");
    return;
  }
  return withUiOperation("workspace-starter", "create-panel", `Adding ${starter.label}...`, async () => {
    clearPaneLayoutsForWorkspace(workspace);
    try {
      const results = await Promise.allSettled(starter.panels.map((type) => createPanel(type, "right", {
          workspaceId: workspace.id,
          focus: false,
          reconcile: false,
          operation: false,
          url: type === "browser" ? state.settings.browserHomeUrl : undefined
        })));
      if (results.some((result) => result.status === "rejected" || !result.value?.id)) {
        throw new Error("Workspace starter panel creation failed.");
      }
      await loadState();
      if (workspace.id !== state.data?.activeWorkspaceId) await focusWorkspace(workspace.id);
      toast(options.newWorkspace ? `${starter.label} workspace created.` : `${starter.label} added.`);
    } catch {
      await loadState();
      toast("Workspace starter could not be added.");
    }
  });
}

async function createWorkspaceFromStarter(starterId) {
  const starter = workspaceStarters.find((candidate) => candidate.id === starterId);
  if (!starter) return;
  try {
    const workspace = await createWorkspace({
      title: starter.label,
      cwd: activeWorkspace()?.cwd
    });
    const createdWorkspace = state.data?.workspaces.find((candidate) => candidate.id === workspace.id);
    const defaultPanels = createdWorkspace?.panels.map((panel) => panel.id) || [];
    for (const panelId of defaultPanels) {
      await api(`/api/panels/${panelId}`, { method: "DELETE" });
    }
    await applyWorkspaceStarter(starterId, workspace.id, { newWorkspace: true });
  } catch {
    await loadState();
    toast("Starter workspace could not be created.");
  }
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
    toast(emptyWorkspaces().length ? "cmux home is the only empty workspace." : "No empty workspaces to close.");
    return false;
  }
  const label = `${targets.length} empty workspace${targets.length === 1 ? "" : "s"}`;
  if (!await showConfirmDialog({
    title: "Close extra empty workspaces",
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
    focus: options.focus,
    immediateTerminalInit: Boolean(options.immediateTerminalInit),
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
  const added = optimisticAddPanel(panel, workspace.id, {
    direction,
    focus: options.focus,
    scheduleRender: true
  });
  ensurePendingPaneTimer();
  updateOperationChrome();
  return added;
}

function shouldInitCreatedTerminalImmediately(panel, workspace, options = {}) {
  const activeWorkspaceId = options.activeWorkspaceId || state.data?.activeWorkspaceId;
  return panel?.type === "terminal"
    && options.focus !== false
    && options.immediateTerminalInit === true
    && workspace?.activePanelId === panel.id
    && activeWorkspaceId === workspace.id
    && !state.terminals.has(panel.id)
    && !isPanelMinimized(panel)
    && !isPendingPanel(panel);
}

function startCreatedTerminalImmediately(panel) {
  if (!panel?.id || state.terminals.has(panel.id)) return false;
  const pane = state.paneCache.get(panel.id);
  const body = pane ? paneParts(pane).body : null;
  if (!body) return false;
  ensureTerminal(panel, body);
  const terminal = state.terminals.get(panel.id);
  if (!terminal) return false;
  scheduleFitTerminal(terminal, true);
  focusTerminalSession(panel.id);
  return true;
}

function deferCreatedTerminalInitUntilPaint(panel, workspace, options = {}) {
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
  if (shouldInitCreatedTerminalImmediately(panel, workspace, options)) {
    if (!startCreatedTerminalImmediately(panel)) requestImmediateTerminalInit(panel.id);
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
      deferCreatedTerminalInitUntilPaint(existing.panel, existing.workspace, options);
      if (options.scheduleRender) scheduleRender();
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
    deferCreatedTerminalInitUntilPaint(nextPanel, workspace, options);
    if (options.scheduleRender) {
      refreshAppStateSignature();
      scheduleRender();
    } else {
      render();
    }
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
  deferCreatedTerminalInitUntilPaint(nextPanel, workspace, options);
  if (options.scheduleRender) {
    refreshAppStateSignature();
    scheduleRender();
  } else {
    render();
  }
  return true;
}

async function createPanel(type, direction = "right", options = {}) {
  if (options.operation !== false && paneCreationButtonsDisabled()) {
    toast(paneCreationLimitLabel());
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
          backgroundImage: options.backgroundImage,
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
    if (pendingPanel) await replacePendingPanel(pendingPanel.id, createdPanel, workspace.id, {
      ...options,
      scheduleRender: true
    });
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
  return withUiOperation(operationKey, "create-panel", label, addPanel, { paneType: type });
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
  return createPanel("browser", options.direction || "right", { url: state.settings.browserHomeUrl, workspaceId });
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
  if (options.scheduleRender) {
    refreshAppStateSignature();
    scheduleRender();
  } else {
    render();
  }
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
    state.deferSettingsInspectorForWorkspaceSwitch = true;
    state.data.activeWorkspaceId = workspaceId;
    refreshAppStateSignature();
    renderFocusChange();
  } else if (workspace.activePanelId !== previousPanelId) {
    refreshAppStateSignature();
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
  if (previousWorkspaceId !== found.workspace.id) {
    state.deferSettingsInspectorForWorkspaceSwitch = true;
  }
  const changed = previousWorkspaceId !== found.workspace.id
    || previousPanelId !== panelId
    || previousFocusedPanelId !== panelId
    || previousLastInteractedPanelId !== panelId
    || zoomChanged;
  if (changed) {
    refreshAppStateSignature();
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

async function browserUrlSyncFetch(panelId, url, options = {}) {
  const response = await fetch(`/api/panels/${panelId}`, {
    method: "PATCH",
    headers: {
      "content-type": "application/json",
      ...(launchToken ? { "x-local-token": launchToken } : {})
    },
    body: JSON.stringify({ url }),
    keepalive: Boolean(options.keepalive)
  });
  if (!response.ok) throw new Error(await response.text());
  return response;
}

async function flushBrowserUrlSync(options = {}) {
  if (state.browserUrlSyncTimer) {
    clearTimeout(state.browserUrlSyncTimer);
    state.browserUrlSyncTimer = 0;
  }
  const entries = [...state.pendingBrowserUrlSync.entries()];
  state.pendingBrowserUrlSync.clear();
  await Promise.all(entries.map(async ([panelId, url]) => {
    const found = findPanelState(panelId);
    if (!found || found.panel.type !== "browser" || found.panel.url !== url) return;
    try {
      await browserUrlSyncFetch(panelId, url, options);
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

function optimisticUpdatePanel(panelId, updates = {}, options = {}) {
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
    } else {
      found.panel.title = found.panel.type === "browser" ? "Browser" : "Terminal";
      found.panel.titleLocked = false;
    }
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    found.panel.color = isAllowedUiColor(color, state.data?.palette || accentOptions) ? color : "";
  }
  if (Object.hasOwn(updates, "backgroundImage") && found.panel.type === "terminal") {
    found.panel.backgroundImage = normalizeBackgroundValue(updates.backgroundImage);
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
  if (options.render !== false) {
    if (options.schedule) scheduleRender();
    else render();
  }
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
    if (title) {
      if (found.panel.title !== title.slice(0, 80) || !found.panel.titleLocked) return true;
    } else if (found.panel.titleLocked) {
      return true;
    }
  }
  if (Object.hasOwn(updates, "color")) {
    const color = String(updates.color || "").trim();
    const expected = isAllowedUiColor(color, state.data?.palette || accentOptions) ? color : "";
    if ((found.panel.color || "") !== expected) return true;
  }
  if (Object.hasOwn(updates, "backgroundImage") && found.panel.type === "terminal") {
    const expected = normalizeBackgroundValue(updates.backgroundImage);
    if ((found.panel.backgroundImage || "") !== expected) return true;
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
    backgroundImage: found.panel.type === "terminal" ? found.panel.backgroundImage || "" : "",
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
    const createOptions = {
      workspaceId: workspace.id,
      title: snapshot.title,
      color: snapshot.color,
      backgroundImage: snapshot.backgroundImage,
      cwd: snapshot.cwd || workspace.cwd,
      shellProfile: snapshot.shellProfile,
      shellPath: snapshot.shellPath,
      terminalFontSize: snapshot.terminalFontSize,
      url: snapshot.url,
      browserTabs: snapshot.browserTabs
    };
    const created = snapshot.type === "terminal"
      ? await createTerminalPanel("right", createOptions)
      : await createPanel(snapshot.type, "right", createOptions);
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

async function closeAllPanes(workspace = activeWorkspace()) {
  const panels = workspace?.panels || [];
  if (panels.length === 0) return;
  await closePanelsById(panels.map((panel) => panel.id));
}

async function closePanesToRight(panelId = activePanel()?.id) {
  const found = findPanelState(panelId);
  if (!found) return;
  const index = found.workspace.panels.findIndex((candidate) => candidate.id === panelId);
  await closePanelsById(found.workspace.panels.slice(index + 1).map((candidate) => candidate.id));
}

async function updatePanel(panelId, updates) {
  optimisticUpdatePanel(panelId, updates, { schedule: true });
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

async function updatePanels(panelUpdates) {
  const entries = (panelUpdates || [])
    .map((entry) => ({
      panelId: String(entry?.panelId || ""),
      updates: entry?.updates || {}
    }))
    .filter((entry) => entry.panelId && entry.updates && typeof entry.updates === "object");
  if (entries.length === 0) return;
  let changed = false;
  for (const entry of entries) {
    changed = optimisticUpdatePanel(entry.panelId, entry.updates, { render: false }) || changed;
  }
  if (changed) scheduleRender();
  try {
    const results = await Promise.all(entries.map((entry) => api(`/api/panels/${entry.panelId}`, {
      method: "PATCH",
      body: JSON.stringify(entry.updates)
    }).then((result) => ({ ...entry, result }))));
    if (results.some((entry) => !entry.result?.ok || panelUpdateReconcileNeeded(entry.panelId, entry.updates))) {
      await loadState();
    }
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
    const persistSteps = panelOrderSwapPersistenceSteps(found.workspace, panelId, targetPanelId);
    if (swapPanePositions(panelId, targetPanelId)) {
      await persistPanelOrderSwap(persistSteps);
      queueFocusSync({ type: "panel", panelId });
    }
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

function swapWorkspacePanelOrder(workspace, panelId, targetPanelId) {
  const sourceIndex = workspace?.panels?.findIndex((panel) => panel.id === panelId) ?? -1;
  const targetIndex = workspace?.panels?.findIndex((panel) => panel.id === targetPanelId) ?? -1;
  if (sourceIndex < 0 || targetIndex < 0 || sourceIndex === targetIndex) return false;
  [workspace.panels[sourceIndex], workspace.panels[targetIndex]] = [workspace.panels[targetIndex], workspace.panels[sourceIndex]];
  return true;
}

function panelOrderSwapPersistenceSteps(workspace, panelId, targetPanelId) {
  const panels = workspace?.panels || [];
  const sourceIndex = panels.findIndex((panel) => panel.id === panelId);
  const targetIndex = panels.findIndex((panel) => panel.id === targetPanelId);
  if (sourceIndex < 0 || targetIndex < 0 || sourceIndex === targetIndex) return [];
  if (sourceIndex < targetIndex) {
    const targetNextPanel = panels[targetIndex + 1];
    return [
      { panelId: targetPanelId, updates: { workspaceId: workspace.id, beforePanelId: panelId } },
      {
        panelId,
        updates: targetNextPanel
          ? { workspaceId: workspace.id, beforePanelId: targetNextPanel.id }
          : { workspaceId: workspace.id, moveToEnd: true }
      }
    ];
  }
  const sourceNextPanel = panels[sourceIndex + 1];
  return [
    { panelId, updates: { workspaceId: workspace.id, beforePanelId: targetPanelId } },
    {
      panelId: targetPanelId,
      updates: sourceNextPanel
        ? { workspaceId: workspace.id, beforePanelId: sourceNextPanel.id }
        : { workspaceId: workspace.id, moveToEnd: true }
    }
  ];
}

async function persistPanelOrderSwap(steps = []) {
  try {
    for (const step of steps) {
      if (!step?.panelId || !step.updates) continue;
      await api(`/api/panels/${step.panelId}`, {
        method: "PATCH",
        body: JSON.stringify(step.updates)
      });
    }
  } catch {
    await loadState();
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
  swapWorkspacePanelOrder(target.workspace, panelId, targetPanelId);
  target.workspace.activePanelId = panelId;
  state.data.activeWorkspaceId = target.workspace.id;
  scheduleRender();
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
  refreshAppStateSignature();
  scheduleRender();
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
      workspace.branch = "";
      changed = true;
    }
  }
  if (changed) {
    refreshAppStateSignature();
    scheduleRender();
  }
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
    if (cwd) return true;
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
  const shouldDeferColdTerminalForWorkspaceSwitch = Boolean(
    switchingWorkspace
    && focusablePanel?.type === "terminal"
    && !state.terminals.has(focusablePanel.id)
    && !isPanelMinimized(focusablePanel)
    && !isPendingPanel(focusablePanel)
  );
  if (
    focusablePanel?.type === "terminal"
    && !state.terminals.has(focusablePanel.id)
    && (switchingWorkspace || workspace.activePanelId !== previousPanelId)
  ) {
    if (shouldDeferColdTerminalForWorkspaceSwitch) requestTerminalInitAfterPaint(focusablePanel.id);
    else requestImmediateTerminalInit(focusablePanel.id);
  }
  if (state.data?.activeWorkspaceId === workspaceId) {
    if (workspace.activePanelId !== previousPanelId) scheduleRender();
    focusTerminalSession(focusablePanel?.id);
    return;
  }
  optimisticFocusWorkspace(workspaceId, { schedule: true });
  if (switchingWorkspace) showWorkspaceSwitchHud(workspace);
  queueFocusSync({ type: "workspace", workspaceId });
  focusTerminalSession(focusablePanel?.id, {
    deferInitUntilPaint: shouldDeferColdTerminalForWorkspaceSwitch
  });
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
    const shouldInitTerminal = requestImmediateTerminalInit(panelId);
    if (wasMinimized || zoomChanged) render();
    else if (shouldInitTerminal) scheduleRender();
    if (shouldShowPaneHud) showPaneSwitchHud(found.panel, found.workspace);
    focusTerminalSession(panelId);
    return;
  }
  if (!optimisticFocusPanel(panelId, { schedule: true })) return;
  if (found.panel.type === "terminal" && !state.terminals.has(panelId)) {
    requestImmediateTerminalInit(panelId);
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

function focusTerminalSession(panelId, options = {}) {
  if (!state.terminals.has(panelId)) {
    const requested = options.deferInitUntilPaint
      ? requestTerminalInitAfterPaint(panelId)
      : requestImmediateTerminalInit(panelId);
    if (requested) scheduleRender();
    return;
  }
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

function normalizedWheelDeltaX(event) {
  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) return event.deltaX * 40;
  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) return event.deltaX * 360;
  return event.deltaX;
}

function closestElementFromEvent(event, selector) {
  for (const target of event?.composedPath?.() || []) {
    const element = target?.nodeType === Node.ELEMENT_NODE ? target : target?.parentElement;
    const match = element?.closest?.(selector);
    if (match) return match;
  }
  const target = event?.target?.nodeType === Node.ELEMENT_NODE ? event.target : event?.target?.parentElement;
  return target?.closest?.(selector) || null;
}

function terminalHostFromEvent(event) {
  return closestElementFromEvent(event, ".terminal-host");
}

function eventTargetsTerminalViewport(event) {
  return Boolean(terminalHostFromEvent(event));
}

function terminalPanelFromWheelEvent(event, options = {}) {
  const terminalHost = terminalHostFromEvent(event);
  if (terminalHost) {
    const directPanel = panelFromElement(terminalHost);
    if (directPanel?.type === "terminal") return directPanel;
    const pointedPanel = panelFromPoint(event?.clientX, event?.clientY);
    if (pointedPanel?.type === "terminal") return pointedPanel;
  }
  if (!options.allowPaneFallback) return null;
  const pointedPanel = panelFromPoint(event?.clientX, event?.clientY);
  if (pointedPanel?.type === "terminal") return pointedPanel;
  const eventPanel = panelFromEvent(event);
  return eventPanel?.type === "terminal" ? eventPanel : null;
}

function applyTerminalWheelZoom(event, panel) {
  const terminalPanel = resolveTerminalPanel(panel);
  if (!terminalPanel) return false;
  if (!event.ctrlKey) return false;
  event.preventDefault();
  event.stopPropagation();
  event.stopImmediatePropagation?.();
  markInteractedPanel(terminalPanel.id);
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
  changeTerminalFontSize(direction * steps, { panel: terminalPanel, focus: false, toast: false, status: true });
  return true;
}

function handleTerminalWheelZoom(event) {
  if (!event.ctrlKey) return;
  const panel = terminalPanelFromWheelEvent(event);
  if (panel?.type !== "terminal") return;
  applyTerminalWheelZoom(event, panel);
}

function handlePaneWheelZoom(event) {
  if (!event.ctrlKey) return;
  const panelId = event.currentTarget?.dataset?.panelId || "";
  const panel = terminalPanelFromWheelEvent(event, { allowPaneFallback: true });
  if (panel?.type !== "terminal" || (panelId && panel.id !== panelId)) return;
  applyTerminalWheelZoom(event, panel);
}

function handleWindowWheelZoom(event) {
  if (!event.ctrlKey) return;
  const terminalPanel = terminalPanelFromWheelEvent(event, { allowPaneFallback: true });
  if (terminalPanel) {
    applyTerminalWheelZoom(event, terminalPanel);
    return;
  }
  const targetsTerminalViewport = eventTargetsTerminalViewport(event);
  const panel = panelFromEvent(event) || panelFromPoint(event.clientX, event.clientY);
  if (panel?.type === "browser" && applyBrowserWheelZoomGuard(event, panel)) return;
  if (consumeCtrlWheelChrome(event)) return;
  if (targetsTerminalViewport) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  } else if (event.target?.closest?.(".shell, .pane, .surface-tabs, .sidebar, .topbar, .command-strip")) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  }
}

function consumeCtrlWheelChrome(event) {
  const target = closestElementFromEvent(
    event,
    "#inspectorBody, #workspaceList, #surfaceTabs, #paletteList, .command-strip"
  );
  if (!target) return false;
  const canScrollY = target.scrollHeight > target.clientHeight;
  const canScrollX = target.scrollWidth > target.clientWidth;
  if (!canScrollY && !canScrollX) return false;
  event.preventDefault();
  event.stopPropagation();
  event.stopImmediatePropagation?.();
  return true;
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
  refreshAppStateSignature();
  scheduleRender();
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
  refreshAppStateSignature();
  scheduleRender();
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
  refreshAppStateSignature();
  scheduleRender();
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
  if (state.inspectorMode !== "settings") state.settingsSearchFocusPending = false;
  updateRailButtons();
  render();
}

function openSettingsCategory(category = "quick", options = {}) {
  state.inspectorMode = "settings";
  state.settingsCategory = settingsCategories.some(([id]) => id === category) ? category : "quick";
  state.settingsQuery = String(options.query || "").trim();
  state.settingsSearchFocusPending = options.focusSearch === undefined
    ? Boolean(state.settingsQuery)
    : Boolean(options.focusSearch);
  if (normalizeSettingsQuery(state.settingsQuery)) queueSettingsSearchAutoScroll();
  state.settingsScrollResetPending = true;
  updateRailButtons();
  render();
}

function openPaneSettings(panel = focusedPanel()) {
  if (panel?.id) focusPanel(panel.id);
  openSettingsCategory("workspace", { query: "active pane", focusSearch: false });
}

function primePaneAppearanceSettings(panel = focusedPanel()) {
  const found = panel?.id ? findPanelState(panel.id) : null;
  const targetPanel = found?.panel || panel;
  if (!targetPanel?.id) return false;
  state.colorApplyTarget = "pane";
  if (resolveTerminalPanel(targetPanel)) state.backgroundApplyTarget = "pane";
  return true;
}

function openPaneAppearanceSettings(panel = focusedPanel()) {
  if (panel?.id) {
    focusPanel(panel.id);
    primePaneAppearanceSettings(panel);
  }
  openSettingsCategory("appearance", { focusSearch: false });
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
  "sidebarBranchMode",
  "sidebarFooterMode",
  "toolbarMode",
  "tabSize",
  "addTabStyle",
  "titleDetailMode",
  "paneColorMarkers",
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

function settingsKeysMatchDefaults(keys) {
  return keys.every((key) => state.settings[key] === defaultSettings[key]);
}

function appearanceSettingsAreDefault() {
  return settingsKeysMatchDefaults(appearanceResetSettings);
}

function workspaceChromeSettingsAreDefault() {
  return settingsKeysMatchDefaults(workspaceChromeSettings);
}

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

async function applyPaneLayoutPreset(presetId, options = {}) {
  const preset = paneLayoutPresets.find((candidate) => candidate.id === presetId);
  const workspace = options.workspaceId
    ? state.data?.workspaces.find((candidate) => candidate.id === options.workspaceId)
    : activeWorkspace();
  const active = options.panelId
    ? workspace?.panels.find((panel) => panel.id === options.panelId)
    : activePanel();
  if (!preset || !workspace || workspace.panels.length <= 1 || !active) {
    toast("Open another pane to use layout presets.");
    return false;
  }
  if (state.data.activeWorkspaceId !== workspace.id || workspace.activePanelId !== active.id) {
    workspace.activePanelId = active.id;
    state.data.activeWorkspaceId = workspace.id;
    state.focusedPanelId = active.id;
    state.lastInteractedPanelId = active.id;
    refreshAppStateSignature();
    queueFocusSync({ type: "panel", panelId: active.id });
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
  const previousTimer = state.terminalFontSizeSyncTimers.get(panelId);
  if (previousTimer) clearTimeout(previousTimer);
  state.terminalFontSizeSyncTimers.set(panelId, setTimeout(() => {
    flushTerminalFontSizeSync({ panelIds: [panelId] });
  }, 220));
  return true;
}

async function terminalFontSizeSyncFetch(panelId, terminalFontSize, options = {}) {
  const response = await fetch(`/api/panels/${panelId}`, {
    method: "PATCH",
    headers: {
      "content-type": "application/json",
      ...(launchToken ? { "x-local-token": launchToken } : {})
    },
    body: JSON.stringify({ terminalFontSize }),
    keepalive: Boolean(options.keepalive)
  });
  if (!response.ok) throw new Error(await response.text());
  return response;
}

async function flushTerminalFontSizeSync(options = {}) {
  const requestedPanelIds = Array.isArray(options.panelIds)
    ? new Set(options.panelIds.filter(Boolean))
    : null;
  const panelIdsToClear = requestedPanelIds || new Set(state.terminalFontSizeSyncTimers.keys());
  for (const panelId of panelIdsToClear) {
    const timer = state.terminalFontSizeSyncTimers.get(panelId);
    if (timer) clearTimeout(timer);
    state.terminalFontSizeSyncTimers.delete(panelId);
  }
  const entries = [...state.pendingTerminalFontSizeSync.entries()]
    .filter(([panelId]) => !requestedPanelIds || requestedPanelIds.has(panelId));
  for (const [panelId] of entries) state.pendingTerminalFontSizeSync.delete(panelId);
  await Promise.all(entries.map(async ([panelId, terminalFontSize]) => {
    const found = findPanelState(panelId);
    if (!found || found.panel.type !== "terminal" || normalizeTerminalFontSize(found.panel.terminalFontSize, 0) !== terminalFontSize) return;
    try {
      await terminalFontSizeSyncFetch(panelId, terminalFontSize, options);
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
  if (options.focus === false) {
    const active = activeWorkspace();
    if (active?.activePanelId === panel.id) markInteractedPanel(panel.id);
  } else {
    markInteractedPanel(panel.id);
  }
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

function changePaneTerminalFontSize(panelId, delta, options = {}) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  focusPanel(panelId);
  return changeTerminalFontSize(delta, { panel: found.panel, ...options });
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
  if (options.status) showTerminalTextSizeStatus(panel.id, nextSize);
  if (options.toast !== false) toast(`Pane text reset to ${nextSize}px.`);
  return true;
}

function resetPaneTerminalFontSize(panelId, options = {}) {
  const found = findPanelState(panelId);
  if (!found || found.panel.type !== "terminal") return false;
  focusPanel(panelId);
  return resetTerminalFontSize({ panel: found.panel, ...options });
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

async function restartSettingsTerminal() {
  const panel = activeTerminalPanelForSettings();
  if (!panel) {
    toast("Focus a terminal pane first.");
    return false;
  }
  await restartPanel(panel.id);
  return true;
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

function paneTextSizeShortcutKind(event) {
  if (!event.ctrlKey || event.altKey || event.metaKey) return "";
  if (event.key === "=" || event.key === "+") return "increase";
  if (event.key === "-") return "decrease";
  if (event.key === "0") return "reset";
  return "";
}

function terminalPanelForShortcutEvent(event) {
  return resolveTerminalPanel(keyboardPanelFromEvent(event));
}

function browserPanelForShortcutEvent(event) {
  return resolveBrowserPanel(keyboardPanelFromEvent(event));
}

function runTerminalKeyShortcut(event, action) {
  const panel = terminalPanelForShortcutEvent(event);
  if (!panel) return false;
  consumeGlobalShortcut(event);
  action(panel);
  return true;
}

function lockBrowserPanelZoom(panel) {
  const browserPanel = resolveBrowserPanel(panel);
  if (!browserPanel) return false;
  markInteractedPanel(browserPanel.id);
  const session = state.browserViews.get(browserPanel.id);
  if (session?.view) lockBrowserViewZoom(session.view);
  return true;
}

function handlePaneTextSizeKeyShortcut(event, kind) {
  if (!kind) return false;
  const terminalPanel = terminalPanelForShortcutEvent(event);
  if (terminalPanel) {
    consumeGlobalShortcut(event);
    if (kind === "reset") resetTerminalFontSize({ panel: terminalPanel, toast: false, status: true });
    else changeTerminalFontSize(kind === "increase" ? 1 : -1, { panel: terminalPanel, toast: false, status: true });
    return true;
  }
  const browserPanel = browserPanelForShortcutEvent(event);
  if (!browserPanel) return false;
  consumeGlobalShortcut(event);
  lockBrowserPanelZoom(browserPanel);
  return true;
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
const newTerminalButton = document.getElementById("newTerminalButton");
newTerminalButton.onclick = () => createTerminalPanel("right");
newTerminalButton.oncontextmenu = showNewTerminalMenu;
document.getElementById("splitRightButton").onclick = () => splitActivePanel("right");
document.getElementById("splitDownButton").onclick = () => splitActivePanel("down");
const newBrowserButton = document.getElementById("newBrowserButton");
newBrowserButton.onclick = () => openBrowserHome();
newBrowserButton.oncontextmenu = (event) => showExternalBrowserProfileMenu(event, state.settings.browserHomeUrl);
document.getElementById("toolsMenuButton").onclick = showToolbarMenu;
document.getElementById("settingsButton").onclick = () => openInspector("settings");
document.getElementById("renameWorkspaceButton").onclick = () => renameActiveWorkspace();
document.getElementById("colorWorkspaceButton").onclick = () => cycleWorkspaceColor();
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
  state.settingsSearchFocusPending = false;
  updateRailButtons();
  render();
};
document.getElementById("closeInspectorButton").onclick = () => {
  state.inspectorMode = null;
  state.settingsSearchFocusPending = false;
  updateRailButtons();
  render();
};
document.getElementById("minimizeWindowButton").onclick = () => window.cmuxNative?.minimizeWindow?.();
document.getElementById("maximizeWindowButton").onclick = toggleWindowMaximize;
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
    elements.paletteList.querySelectorAll(".palette-item")[state.paletteIndex]?.click();
  }
  if (event.key === "Escape") {
    closePalette();
  }
});

window.addEventListener("keydown", (event) => {
  const key = event.key.toLowerCase();
  if (state.activeDialog) return;
  const editingText = isFormEditableTarget(event.target);
  const textSizeShortcutKind = paneTextSizeShortcutKind(event);
  const directBrowserPanel = textSizeShortcutKind ? resolveBrowserPanel(panelFromEvent(event)) : null;
  if (
    textSizeShortcutKind
    && (!editingText || directBrowserPanel)
    && handlePaneTextSizeKeyShortcut(event, textSizeShortcutKind)
  ) return;
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
    runTerminalKeyShortcut(event, openTerminalSearch);
  } else if (event.ctrlKey && event.shiftKey && event.key === "Enter") {
    runTerminalKeyShortcut(event, promptRunTerminalCommand);
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
    runTerminalKeyShortcut(event, event.shiftKey ? findPreviousInTerminal : findNextInTerminal);
  } else if (event.ctrlKey && event.shiftKey && key === "c") {
    runTerminalKeyShortcut(event, copyActiveTerminalSelection);
  } else if (event.ctrlKey && event.shiftKey && key === "v") {
    runTerminalKeyShortcut(event, pasteClipboardToTerminal);
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
    createTerminalPanel("right");
  } else if (event.ctrlKey && event.shiftKey && key === "l") {
    consumeGlobalShortcut(event);
    openBrowserHome();
  } else if (event.ctrlKey && key === "l") {
    const panel = keyboardPanelFromEvent(event);
    if (resolveBrowserPanel(panel)) {
      consumeGlobalShortcut(event);
      focusBrowserAddress(panel);
    }
  } else if (event.ctrlKey && !event.shiftKey && key === "r") {
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
    runTerminalKeyShortcut(event, clearTerminalPanel);
  } else if (event.ctrlKey && event.shiftKey && key === "r") {
    runTerminalKeyShortcut(event, (panel) => restartPanel(panel.id));
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
  if (document.hidden) {
    flushTerminalFontSizeSync({ keepalive: true });
    flushBrowserUrlSync({ keepalive: true });
  } else {
    scheduleDeferredTerminalFitFlush();
  }
});
window.addEventListener("focus", scheduleDeferredTerminalFitFlush);
window.addEventListener("pagehide", () => {
  flushTerminalFontSizeSync({ keepalive: true });
  flushBrowserUrlSync({ keepalive: true });
});

elements.sidebar.addEventListener("pointerdown", startSidebarResize);
elements.inspector.addEventListener("pointerdown", startInspectorResize);
for (const edge of elements.windowResizeEdges) {
  edge.addEventListener("pointerdown", startWindowResize);
}
elements.topbar?.addEventListener("dblclick", handleTopbarDoubleClick);
elements.paneGrid.addEventListener("dragover", handlePaneGridDragOver);
elements.paneGrid.addEventListener("dragleave", handlePaneGridDragLeave);
elements.paneGrid.addEventListener("drop", handlePaneGridDrop);
elements.workspaceList.addEventListener("dragover", handleWorkspaceListDragOver);
elements.workspaceList.addEventListener("dragleave", handleWorkspaceListDragLeave);
elements.workspaceList.addEventListener("drop", handleWorkspaceListDrop);
new MutationObserver(scheduleVisiblePaneLayoutApply).observe(elements.paneGrid, {
  childList: true
});
window.addEventListener("pointermove", (event) => {
  continueWindowResize(event);
  continuePaneResize(event);
  continuePanePointerDrag(event);
  continueSidebarResize(event);
  continueInspectorResize(event);
});
window.addEventListener("pointerup", (event) => {
  finishWindowResize(event);
  finishPaneResize(event);
  finishPanePointerDrag(event);
  finishSidebarResize(event);
  finishInspectorResize(event);
});
window.addEventListener("pointercancel", (event) => {
  finishWindowResize(event);
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
  flushTerminalFontSizeSync({ keepalive: true });
  flushBrowserUrlSync({ keepalive: true });
});

function isTopbarDoubleClickInteractiveTarget(target) {
  return Boolean(target?.closest?.([
    "button",
    "input",
    "select",
    "textarea",
    "a",
    "[contenteditable='true']",
    ".command-strip",
    ".native-window-controls",
    ".window-resize-edge",
    ".palette-dialog"
  ].join(",")));
}

function handleTopbarDoubleClick(event) {
  if (event.button !== 0 || isTopbarDoubleClickInteractiveTarget(event.target)) return;
  event.preventDefault();
  event.stopPropagation();
  toggleWindowMaximize();
}

async function toggleWindowMaximize() {
  if (!window.cmuxNative?.toggleMaximizeWindow) return;
  const previousMaximized = state.windowMaximized;
  updateMaximizeButton(!previousMaximized);
  try {
    const maximized = await window.cmuxNative.toggleMaximizeWindow();
    if (typeof maximized === "boolean") {
      updateMaximizeButton(maximized);
    } else if (window.cmuxNative?.isWindowMaximized) {
      window.cmuxNative.isWindowMaximized().then(updateMaximizeButton);
    }
  } catch (error) {
    updateMaximizeButton(previousMaximized);
    console.error(`window maximize failed: ${error?.message || error}`);
  }
}

const windowControlIcons = {
  maximize: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="7" y="7" width="10" height="10" rx="1"></rect></svg>`,
  restore: `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 8h9v9H8z"></path><path d="M6 15V6h9"></path></svg>`
};

function setWindowControlIcon(button, icon) {
  if (!button || button.dataset.windowIcon === icon) return;
  button.innerHTML = windowControlIcons[icon] || windowControlIcons.maximize;
  button.dataset.windowIcon = icon;
}

function updateMaximizeButton(maximized) {
  if (!elements.maximizeWindowButton) return;
  const nextMaximized = Boolean(maximized);
  state.windowMaximized = nextMaximized;
  elements.shell?.classList.toggle("window-maximized", nextMaximized);
  if (nextMaximized && state.windowResizing) {
    window.cmuxNative?.endWindowResize?.();
    elements.shell.classList.remove("window-resizing", state.windowResizing.cursorClass);
    state.windowResizing = null;
  }
  setWindowControlIcon(elements.maximizeWindowButton, nextMaximized ? "restore" : "maximize");
  elements.maximizeWindowButton.title = nextMaximized ? "Restore" : "Maximize";
  elements.maximizeWindowButton.setAttribute("aria-label", nextMaximized ? "Restore window" : "Maximize window");
  elements.maximizeWindowButton.dataset.windowState = nextMaximized ? "maximized" : "normal";
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

installBackgroundDropTarget(elements.paneGrid, {
  allowPlainText: false,
  panelFromEvent: terminalPanelFromBackgroundDropEvent
});
applySettings();
loadState();
loadBrowserProfiles();
connectEvents();
