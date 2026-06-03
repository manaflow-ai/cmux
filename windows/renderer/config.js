import { t } from "./i18n.js";

const label = (key, fallback) => t(`config.${key}`, fallback);

export const defaultSettings = {
  theme: "cmux",
  accent: "oklch(61% 0.22 255)",
  backgroundImage: "",
  backgroundOpacity: 16,
  backgroundFit: "cover",
  backgroundPosition: "center",
  backgroundEffects: "flat",
  browserHomeUrl: "https://www.google.com",
  browserLaunchMode: "pane",
  externalBrowserProfileId: "system",
  browserSuspendInactive: true,
  density: "comfortable",
  paneHeaderMode: "compact",
  paneActionMode: "essential",
  sidebarDetailMode: "compact",
  sidebarBranchMode: "hidden",
  sidebarFooterMode: "workspace",
  toolbarMode: "minimal",
  tabSize: "balanced",
  addTabStyle: "compact",
  titleDetailMode: "smart",
  paneColorMarkers: false,
  focusMode: false,
  showTabs: true,
  showStatusbar: true,
  showAdvanced: false,
  performanceMode: false,
  adaptivePerformance: true,
  reduceMotion: false,
  sidebarWidth: 232,
  inspectorWidth: 360,
  terminalFontFamily: "cascadia",
  terminalFontSize: 13,
  terminalLineHeight: 1.22,
  terminalPadding: 8,
  terminalScrollback: 12000,
  terminalStartupMode: "fast",
  terminalPauseInactiveOutput: true,
  terminalSmoothResumedOutput: true,
  terminalCursorStyle: "bar",
  terminalCursorBlink: true,
  terminalBackground: "",
  terminalForeground: "",
  terminalCursorColor: "",
  terminalProfile: "auto",
  terminalCustomShell: ""
};

export const themeOptions = [
  ["cmux", label("theme.cmux", "cmux")],
  ["graphite", label("theme.graphite", "Graphite")],
  ["forest", label("theme.forest", "Forest")],
  ["blueprint", label("theme.blueprint", "Blueprint")],
  ["harbor", label("theme.harbor", "Harbor")],
  ["orchid", label("theme.orchid", "Orchid")],
  ["ember", label("theme.ember", "Ember")],
  ["paper", label("theme.paper", "Paper Dark")]
];

export const themePreviewOptions = [
  {
    id: "cmux",
    canvas: "oklch(12% 0.006 255)",
    pane: "oklch(16% 0.007 255)",
    rail: "oklch(15% 0.007 255)",
    line: "oklch(31% 0.012 255)",
    accent: "oklch(61% 0.22 255)"
  },
  {
    id: "graphite",
    canvas: "oklch(12% 0.008 260)",
    pane: "oklch(16% 0.01 260)",
    rail: "oklch(15% 0.01 260)",
    line: "oklch(32% 0.015 260)",
    accent: "oklch(72% 0.17 230)"
  },
  {
    id: "forest",
    canvas: "oklch(13% 0.018 150)",
    pane: "oklch(17% 0.018 150)",
    rail: "oklch(16% 0.02 150)",
    line: "oklch(32% 0.03 150)",
    accent: "oklch(70% 0.16 145)"
  },
  {
    id: "blueprint",
    canvas: "oklch(13% 0.026 245)",
    pane: "oklch(17% 0.026 245)",
    rail: "oklch(16% 0.03 245)",
    line: "oklch(32% 0.04 245)",
    accent: "oklch(72% 0.17 230)"
  },
  {
    id: "harbor",
    canvas: "oklch(13% 0.02 205)",
    pane: "oklch(17% 0.02 205)",
    rail: "oklch(16% 0.024 205)",
    line: "oklch(34% 0.032 205)",
    accent: "oklch(66% 0.13 175)"
  },
  {
    id: "orchid",
    canvas: "oklch(13% 0.022 315)",
    pane: "oklch(17% 0.022 315)",
    rail: "oklch(16% 0.026 315)",
    line: "oklch(34% 0.035 315)",
    accent: "oklch(74% 0.18 305)"
  },
  {
    id: "ember",
    canvas: "oklch(13% 0.018 35)",
    pane: "oklch(17% 0.02 35)",
    rail: "oklch(16% 0.022 35)",
    line: "oklch(34% 0.035 35)",
    accent: "oklch(64% 0.17 28)"
  },
  {
    id: "paper",
    canvas: "oklch(17% 0.006 95)",
    pane: "oklch(21% 0.007 95)",
    rail: "oklch(20% 0.008 95)",
    line: "oklch(38% 0.014 95)",
    accent: "oklch(86% 0.11 70)"
  }
];

export const accentOptions = [
  "oklch(61% 0.22 255)",
  "oklch(70% 0.16 145)",
  "oklch(78% 0.15 82)",
  "oklch(68% 0.18 330)",
  "oklch(70% 0.14 195)",
  "oklch(64% 0.17 28)",
  "oklch(74% 0.18 305)",
  "oklch(72% 0.17 230)",
  "oklch(74% 0.12 35)",
  "oklch(80% 0.1 115)",
  "oklch(66% 0.13 175)",
  "oklch(86% 0.11 70)"
];

export const backgroundPresets = [
  {
    value: "",
    label: label("background.none", "None"),
    preview: "linear-gradient(135deg, var(--color-pane), var(--color-canvas))",
    css: "none"
  },
  {
    value: "preset:terminal-grid",
    label: label("background.terminalGrid", "Terminal grid"),
    preview: "linear-gradient(90deg, color-mix(in oklch, var(--color-accent) 24%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-accent) 18%, transparent) 1px, transparent 1px), radial-gradient(circle at 22% 18%, color-mix(in oklch, var(--color-accent) 22%, transparent), transparent 34%)",
    css: "linear-gradient(90deg, color-mix(in oklch, var(--color-accent) 17%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-accent) 13%, transparent) 1px, transparent 1px), radial-gradient(circle at 22% 18%, color-mix(in oklch, var(--color-accent) 20%, transparent), transparent 34%)"
  },
  {
    value: "preset:soft-aurora",
    label: label("background.softAurora", "Soft aurora"),
    preview: "radial-gradient(circle at 18% 20%, color-mix(in oklch, var(--color-success) 32%, transparent), transparent 36%), radial-gradient(circle at 78% 18%, color-mix(in oklch, var(--color-accent) 30%, transparent), transparent 34%), linear-gradient(135deg, var(--color-pane), var(--color-canvas))",
    css: "radial-gradient(circle at 18% 20%, color-mix(in oklch, var(--color-success) 22%, transparent), transparent 36%), radial-gradient(circle at 78% 18%, color-mix(in oklch, var(--color-accent) 24%, transparent), transparent 34%), linear-gradient(135deg, var(--color-pane), var(--color-canvas))"
  },
  {
    value: "preset:blueprint-lines",
    label: label("background.blueprintLines", "Blueprint lines"),
    preview: "linear-gradient(120deg, color-mix(in oklch, var(--color-accent) 24%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-text) 8%, transparent), transparent)",
    css: "linear-gradient(120deg, color-mix(in oklch, var(--color-accent) 18%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-text) 6%, transparent), transparent)"
  }
];

export const backgroundFitOptions = [
  ["cover", label("backgroundFit.cover", "Fill")],
  ["contain", label("backgroundFit.contain", "Fit")],
  ["stretch", label("backgroundFit.stretch", "Stretch")],
  ["auto", label("backgroundFit.auto", "Original")]
];

export const backgroundPositionOptions = [
  ["center", label("backgroundPosition.center", "Center")],
  ["top", label("backgroundPosition.top", "Top")],
  ["bottom", label("backgroundPosition.bottom", "Bottom")],
  ["left", label("backgroundPosition.left", "Left")],
  ["right", label("backgroundPosition.right", "Right")]
];

export const backgroundEffectsOptions = [
  ["flat", label("backgroundEffects.flat", "Flat")],
  ["glass", label("backgroundEffects.glass", "Glass")]
];

export const browserHomePresets = [
  {
    id: "google",
    label: label("browserHome.google", "Google"),
    body: label("browserHome.google.body", "Default search home."),
    url: "https://www.google.com"
  },
  {
    id: "github",
    label: label("browserHome.github", "GitHub"),
    body: label("browserHome.github.body", "Code, PRs, and issues."),
    url: "https://github.com"
  },
  {
    id: "localhost3000",
    label: label("browserHome.localhost3000", "Local 3000"),
    body: label("browserHome.localhost3000.body", "Next and Node apps."),
    url: "http://localhost:3000"
  },
  {
    id: "localhost5173",
    label: label("browserHome.localhost5173", "Local 5173"),
    body: label("browserHome.localhost5173.body", "Vite dev server."),
    url: "http://localhost:5173"
  }
];

export const browserLaunchModeOptions = [
  ["pane", label("browserLaunchMode.pane", "cmux pane")],
  ["external", label("browserLaunchMode.external", "External profile")]
];

export const terminalProfiles = [
  ["auto", label("terminalProfile.auto", "Auto")],
  ["pwsh", label("terminalProfile.pwsh", "PowerShell 7")],
  ["powershell", label("terminalProfile.powershell", "Windows PowerShell")],
  ["cmd", label("terminalProfile.cmd", "Command Prompt")],
  ["wsl", label("terminalProfile.wsl", "WSL")],
  ["git-bash", label("terminalProfile.gitBash", "Git Bash")],
  ["custom", label("terminalProfile.custom", "Custom path")]
];

export const terminalCursorStyles = [
  ["block", label("terminalCursor.block", "Block")],
  ["bar", label("terminalCursor.bar", "Line")],
  ["underline", label("terminalCursor.underline", "Underline")]
];

export const terminalFontOptions = [
  ["cascadia", label("terminalFont.cascadia", "Cascadia Mono"), "\"Cascadia Mono\", \"Cascadia Code\", Consolas, monospace"],
  ["cascadia-code", label("terminalFont.cascadiaCode", "Cascadia Code"), "\"Cascadia Code\", \"Cascadia Mono\", Consolas, monospace"],
  ["consolas", label("terminalFont.consolas", "Consolas"), "Consolas, \"Cascadia Mono\", monospace"],
  ["jetbrains", label("terminalFont.jetbrains", "JetBrains Mono"), "\"JetBrains Mono\", \"Cascadia Mono\", Consolas, monospace"],
  ["fira", label("terminalFont.fira", "Fira Code"), "\"Fira Code\", \"Cascadia Mono\", Consolas, monospace"],
  ["mono", label("terminalFont.systemMono", "System monospace"), "ui-monospace, \"Cascadia Mono\", Consolas, monospace"]
];

export const toolbarModeOptions = [
  ["minimal", label("toolbar.minimal", "Minimal"), label("toolbar.minimal.body", "Only terminal, browser, tools, and settings stay on the top bar.")],
  ["compact", label("toolbar.compact", "Compact"), label("toolbar.compact.body", "Icon-only main actions for a small top bar.")],
  ["standard", label("toolbar.standard", "Standard"), label("toolbar.standard.body", "Named main actions with advanced tools tucked away.")],
  ["expanded", label("toolbar.expanded", "Expanded"), label("toolbar.expanded.body", "Show every toolbar shortcut on the top bar.")]
];

export const sidebarDetailOptions = [
  ["compact", label("sidebarDetail.compact", "Name + folder")],
  ["balanced", label("sidebarDetail.balanced", "Name, folder, counts")],
  ["detailed", label("sidebarDetail.detailed", "Full details")]
];

export const sidebarBranchOptions = [
  ["hidden", label("sidebarBranch.hidden", "Hide branches")],
  ["active", label("sidebarBranch.active", "Active workspace only")],
  ["all", label("sidebarBranch.all", "All detailed rows")]
];

export const sidebarFooterOptions = [
  ["workspace", label("sidebarFooter.workspace", "Workspace only")],
  ["compact", label("sidebarFooter.compact", "Compact tools")],
  ["full", label("sidebarFooter.full", "Workspace + reset")]
];

export const paneHeaderOptions = [
  ["compact", label("paneHeader.compact", "Compact")],
  ["full", label("paneHeader.full", "Full")],
  ["hidden", label("paneHeader.hidden", "Content only")]
];

export const paneActionOptions = [
  ["essential", label("paneAction.essential", "Clean")],
  ["split", label("paneAction.split", "Split tools")],
  ["full", label("paneAction.full", "Full")]
];

export const tabSizeOptions = [
  ["compact", label("tabSize.compact", "Compact")],
  ["balanced", label("tabSize.balanced", "Balanced")],
  ["roomy", label("tabSize.roomy", "Roomy")]
];

export const addTabStyleOptions = [
  ["labeled", label("addTabStyle.labeled", "Labeled")],
  ["compact", label("addTabStyle.compact", "Compact")],
  ["hidden", label("addTabStyle.hidden", "Hidden")]
];

export const terminalStartupOptions = [
  ["fast", label("terminalStartup.fast", "Fast")],
  ["balanced", label("terminalStartup.balanced", "Balanced")]
];

export const titleDetailOptions = [
  ["smart", label("titleDetail.smart", "Smart")],
  ["compact", label("titleDetail.compact", "Name only")],
  ["folder", label("titleDetail.folder", "Folder only")],
  ["detailed", label("titleDetail.detailed", "Name + folder")]
];

export const terminalColorDefaults = {
  background: "#191c22",
  foreground: "#d7dce6",
  cursor: "#7aa7ff"
};

export const terminalColorPresets = [
  {
    id: "cmux",
    label: label("terminalColor.cmux", "cmux"),
    body: label("terminalColor.cmux.body", "Default dark surface with app accent cursor."),
    background: "",
    foreground: "",
    cursor: ""
  },
  {
    id: "powershell",
    label: label("terminalColor.powershell", "PowerShell"),
    body: label("terminalColor.powershell.body", "Classic Windows console blue."),
    background: "#012456",
    foreground: "#f5f5f5",
    cursor: "#f5f5f5"
  },
  {
    id: "graphite",
    label: label("terminalColor.graphite", "Graphite"),
    body: label("terminalColor.graphite.body", "Low-glare dark neutral."),
    background: "#111318",
    foreground: "#d8dee9",
    cursor: "#88c0d0"
  },
  {
    id: "contrast",
    label: label("terminalColor.contrast", "High contrast"),
    body: label("terminalColor.contrast.body", "Sharper text and cursor visibility."),
    background: "#050505",
    foreground: "#f4f4f4",
    cursor: "#ffd166"
  },
  {
    id: "warm",
    label: label("terminalColor.warm", "Warm"),
    body: label("terminalColor.warm.body", "Softer amber-tinted terminal."),
    background: "#1c1714",
    foreground: "#eadfce",
    cursor: "#f6bd60"
  },
  {
    id: "light",
    label: label("terminalColor.light", "Light"),
    body: label("terminalColor.light.body", "Bright terminal for daytime use."),
    background: "#f7f3ea",
    foreground: "#24211d",
    cursor: "#2557d6"
  }
];

export const terminalAppearanceKeys = new Set([
  "theme",
  "accent",
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

export const settingsPresets = [
  {
    id: "balanced",
    label: label("settingsPreset.balanced", "Balanced"),
    body: label("settingsPreset.balanced.body", "Default chrome, clear terminal, full status."),
    settings: {
      theme: "cmux",
      accent: "oklch(61% 0.22 255)",
      backgroundImage: "",
      backgroundOpacity: 16,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "flat",
      density: "comfortable",
      paneHeaderMode: "compact",
      paneActionMode: "essential",
      sidebarDetailMode: "compact",
      sidebarBranchMode: "hidden",
      sidebarFooterMode: "workspace",
      toolbarMode: "minimal",
      tabSize: "balanced",
      addTabStyle: "compact",
      titleDetailMode: "smart",
      paneColorMarkers: false,
      focusMode: false,
      showTabs: true,
      showStatusbar: true,
      showAdvanced: false,
      performanceMode: false,
      adaptivePerformance: true,
      reduceMotion: false,
      sidebarWidth: 232,
      inspectorWidth: 360,
      terminalFontFamily: "cascadia",
      terminalFontSize: 13,
      terminalLineHeight: 1.22,
      terminalPadding: 8,
      terminalScrollback: 12000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "simple",
    label: label("settingsPreset.simple", "Simple"),
    body: label("settingsPreset.simple.body", "Clean workspace chrome with compact rows and quiet tabs."),
    settings: {
      theme: "graphite",
      accent: "oklch(66% 0.13 175)",
      backgroundImage: "",
      backgroundOpacity: 12,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "flat",
      density: "compact",
      paneHeaderMode: "compact",
      paneActionMode: "essential",
      sidebarDetailMode: "compact",
      sidebarBranchMode: "hidden",
      sidebarFooterMode: "compact",
      toolbarMode: "minimal",
      tabSize: "compact",
      addTabStyle: "compact",
      titleDetailMode: "compact",
      paneColorMarkers: false,
      focusMode: false,
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: false,
      adaptivePerformance: true,
      reduceMotion: false,
      sidebarWidth: 212,
      inspectorWidth: 340,
      terminalFontFamily: "cascadia",
      terminalFontSize: 13,
      terminalLineHeight: 1.18,
      terminalPadding: 6,
      terminalScrollback: 10000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "simpleFast",
    label: label("settingsPreset.simpleFast", "Clean + Fast"),
    body: label("settingsPreset.simpleFast.body", "Simple chrome with speed tuning and fast terminal startup."),
    settings: {
      theme: "graphite",
      accent: "oklch(66% 0.13 175)",
      backgroundImage: "",
      backgroundOpacity: 6,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "flat",
      density: "compact",
      paneHeaderMode: "compact",
      paneActionMode: "essential",
      sidebarDetailMode: "compact",
      sidebarBranchMode: "hidden",
      sidebarFooterMode: "compact",
      toolbarMode: "minimal",
      tabSize: "compact",
      addTabStyle: "compact",
      titleDetailMode: "compact",
      paneColorMarkers: false,
      focusMode: false,
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: true,
      adaptivePerformance: true,
      reduceMotion: true,
      sidebarWidth: 212,
      inspectorWidth: 340,
      terminalFontFamily: "cascadia",
      terminalFontSize: 13,
      terminalLineHeight: 1.16,
      terminalPadding: 4,
      terminalScrollback: 6000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: "",
      browserSuspendInactive: true
    }
  },
  {
    id: "focus",
    label: label("settingsPreset.focus", "Focus"),
    body: label("settingsPreset.focus.body", "Tighter layout with quiet Harbor colors."),
    settings: {
      theme: "harbor",
      accent: "oklch(66% 0.13 175)",
      backgroundImage: "",
      backgroundOpacity: 10,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "flat",
      density: "compact",
      paneHeaderMode: "hidden",
      paneActionMode: "essential",
      sidebarDetailMode: "compact",
      sidebarBranchMode: "hidden",
      sidebarFooterMode: "workspace",
      toolbarMode: "minimal",
      tabSize: "balanced",
      addTabStyle: "compact",
      titleDetailMode: "compact",
      paneColorMarkers: false,
      focusMode: true,
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: false,
      adaptivePerformance: true,
      reduceMotion: true,
      sidebarWidth: 216,
      inspectorWidth: 328,
      terminalFontFamily: "cascadia",
      terminalFontSize: 14,
      terminalLineHeight: 1.18,
      terminalPadding: 6,
      terminalScrollback: 10000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "performance",
    label: label("settingsPreset.performance", "Performance"),
    body: label("settingsPreset.performance.body", "Cuts effects and keeps terminal history lighter."),
    settings: {
      theme: "graphite",
      accent: "oklch(72% 0.17 230)",
      backgroundImage: "",
      backgroundOpacity: 0,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "flat",
      density: "compact",
      paneHeaderMode: "hidden",
      paneActionMode: "essential",
      sidebarDetailMode: "compact",
      sidebarBranchMode: "hidden",
      sidebarFooterMode: "workspace",
      toolbarMode: "minimal",
      tabSize: "compact",
      addTabStyle: "hidden",
      titleDetailMode: "compact",
      paneColorMarkers: false,
      focusMode: false,
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: true,
      adaptivePerformance: true,
      reduceMotion: true,
      sidebarWidth: 204,
      inspectorWidth: 320,
      terminalFontFamily: "consolas",
      terminalFontSize: 13,
      terminalLineHeight: 1.16,
      terminalPadding: 4,
      terminalScrollback: 6000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "showcase",
    label: label("settingsPreset.showcase", "Showcase"),
    body: label("settingsPreset.showcase.body", "Richer theme and soft background for demos."),
    settings: {
      theme: "orchid",
      accent: "oklch(74% 0.18 305)",
      backgroundImage: "preset:soft-aurora",
      backgroundOpacity: 24,
      backgroundFit: "cover",
      backgroundPosition: "center",
      backgroundEffects: "glass",
      density: "comfortable",
      paneHeaderMode: "full",
      paneActionMode: "full",
      sidebarDetailMode: "detailed",
      sidebarBranchMode: "all",
      sidebarFooterMode: "compact",
      toolbarMode: "standard",
      tabSize: "roomy",
      addTabStyle: "labeled",
      titleDetailMode: "detailed",
      paneColorMarkers: true,
      focusMode: false,
      showTabs: true,
      showStatusbar: true,
      showAdvanced: false,
      performanceMode: false,
      adaptivePerformance: false,
      reduceMotion: false,
      sidebarWidth: 248,
      inspectorWidth: 384,
      terminalFontFamily: "cascadia",
      terminalFontSize: 14,
      terminalLineHeight: 1.24,
      terminalPadding: 10,
      terminalScrollback: 12000,
      terminalStartupMode: "fast",
      terminalPauseInactiveOutput: true,
      terminalSmoothResumedOutput: true,
      terminalCursorStyle: "bar",
      terminalCursorBlink: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  }
];

export const settingsCategories = [
  ["quick", label("settingsCategory.quick", "Quick")],
  ["profiles", label("settingsCategory.profiles", "Profiles")],
  ["blueprints", label("settingsCategory.blueprints", "Blueprints")],
  ["workspace", label("settingsCategory.workspace", "Workspace")],
  ["appearance", label("settingsCategory.appearance", "Look")],
  ["browser", label("settingsCategory.browser", "Browser")],
  ["layout", label("settingsCategory.layout", "Layout")],
  ["performance", label("settingsCategory.performance", "Performance")],
  ["actions", label("settingsCategory.actions", "Actions")],
  ["commands", label("settingsCategory.commands", "Commands")],
  ["terminal", label("settingsCategory.terminal", "Terminal")],
  ["data", label("settingsCategory.data", "Data")]
];
