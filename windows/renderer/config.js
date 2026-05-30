export const defaultSettings = {
  theme: "cmux",
  accent: "oklch(61% 0.22 255)",
  backgroundImage: "",
  backgroundOpacity: 16,
  backgroundFit: "cover",
  backgroundPosition: "center",
  browserHomeUrl: "https://www.google.com",
  browserLaunchMode: "pane",
  externalBrowserProfileId: "system",
  browserSuspendInactive: true,
  density: "comfortable",
  paneHeaderMode: "compact",
  sidebarDetailMode: "compact",
  sidebarFooterMode: "workspace",
  toolbarMode: "compact",
  tabSize: "balanced",
  titleDetailMode: "smart",
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
  terminalPauseInactiveOutput: true,
  terminalCursorStyle: "bar",
  terminalCursorBlink: true,
  terminalBackground: "",
  terminalForeground: "",
  terminalCursorColor: "",
  terminalProfile: "auto",
  terminalCustomShell: ""
};

export const themeOptions = [
  ["cmux", "cmux"],
  ["graphite", "Graphite"],
  ["forest", "Forest"],
  ["blueprint", "Blueprint"],
  ["harbor", "Harbor"],
  ["orchid", "Orchid"],
  ["ember", "Ember"],
  ["paper", "Paper Dark"]
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
    label: "None",
    preview: "linear-gradient(135deg, var(--color-pane), var(--color-canvas))",
    css: "none"
  },
  {
    value: "preset:terminal-grid",
    label: "Terminal grid",
    preview: "linear-gradient(90deg, color-mix(in oklch, var(--color-accent) 24%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-accent) 18%, transparent) 1px, transparent 1px), radial-gradient(circle at 22% 18%, color-mix(in oklch, var(--color-accent) 22%, transparent), transparent 34%)",
    css: "linear-gradient(90deg, color-mix(in oklch, var(--color-accent) 17%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-accent) 13%, transparent) 1px, transparent 1px), radial-gradient(circle at 22% 18%, color-mix(in oklch, var(--color-accent) 20%, transparent), transparent 34%)"
  },
  {
    value: "preset:soft-aurora",
    label: "Soft aurora",
    preview: "radial-gradient(circle at 18% 20%, color-mix(in oklch, var(--color-success) 32%, transparent), transparent 36%), radial-gradient(circle at 78% 18%, color-mix(in oklch, var(--color-accent) 30%, transparent), transparent 34%), linear-gradient(135deg, var(--color-pane), var(--color-canvas))",
    css: "radial-gradient(circle at 18% 20%, color-mix(in oklch, var(--color-success) 22%, transparent), transparent 36%), radial-gradient(circle at 78% 18%, color-mix(in oklch, var(--color-accent) 24%, transparent), transparent 34%), linear-gradient(135deg, var(--color-pane), var(--color-canvas))"
  },
  {
    value: "preset:blueprint-lines",
    label: "Blueprint lines",
    preview: "linear-gradient(120deg, color-mix(in oklch, var(--color-accent) 24%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-text) 8%, transparent), transparent)",
    css: "linear-gradient(120deg, color-mix(in oklch, var(--color-accent) 18%, transparent) 1px, transparent 1px), linear-gradient(180deg, color-mix(in oklch, var(--color-text) 6%, transparent), transparent)"
  }
];

export const backgroundFitOptions = [
  ["cover", "Fill"],
  ["contain", "Fit"],
  ["stretch", "Stretch"],
  ["auto", "Original"]
];

export const backgroundPositionOptions = [
  ["center", "Center"],
  ["top", "Top"],
  ["bottom", "Bottom"],
  ["left", "Left"],
  ["right", "Right"]
];

export const browserHomePresets = [
  {
    id: "google",
    label: "Google",
    body: "Default search home.",
    url: "https://www.google.com"
  },
  {
    id: "github",
    label: "GitHub",
    body: "Code, PRs, and issues.",
    url: "https://github.com"
  },
  {
    id: "localhost3000",
    label: "Local 3000",
    body: "Next and Node apps.",
    url: "http://localhost:3000"
  },
  {
    id: "localhost5173",
    label: "Local 5173",
    body: "Vite dev server.",
    url: "http://localhost:5173"
  }
];

export const browserLaunchModeOptions = [
  ["pane", "cmux pane"],
  ["external", "External profile"]
];

export const terminalProfiles = [
  ["auto", "Auto"],
  ["pwsh", "PowerShell 7"],
  ["powershell", "Windows PowerShell"],
  ["cmd", "Command Prompt"],
  ["wsl", "WSL"],
  ["git-bash", "Git Bash"],
  ["custom", "Custom path"]
];

export const terminalCursorStyles = [
  ["block", "Block"],
  ["bar", "Bar"],
  ["underline", "Underline"]
];

export const terminalFontOptions = [
  ["cascadia", "Cascadia Mono", "\"Cascadia Mono\", \"Cascadia Code\", Consolas, monospace"],
  ["cascadia-code", "Cascadia Code", "\"Cascadia Code\", \"Cascadia Mono\", Consolas, monospace"],
  ["consolas", "Consolas", "Consolas, \"Cascadia Mono\", monospace"],
  ["jetbrains", "JetBrains Mono", "\"JetBrains Mono\", \"Cascadia Mono\", Consolas, monospace"],
  ["fira", "Fira Code", "\"Fira Code\", \"Cascadia Mono\", Consolas, monospace"],
  ["mono", "System monospace", "ui-monospace, \"Cascadia Mono\", Consolas, monospace"]
];

export const toolbarModeOptions = [
  ["compact", "Compact", "Icon-only main actions for the cleanest top bar."],
  ["standard", "Standard", "Named main actions with advanced tools tucked away."],
  ["expanded", "Expanded", "Show every toolbar shortcut on the top bar."]
];

export const sidebarDetailOptions = [
  ["compact", "Name + folder"],
  ["balanced", "Name, folder, counts"],
  ["detailed", "Full details"]
];

export const sidebarFooterOptions = [
  ["workspace", "Workspace only"],
  ["compact", "Compact tools"],
  ["full", "Workspace + reset"]
];

export const paneHeaderOptions = [
  ["compact", "Compact"],
  ["full", "Full"],
  ["hidden", "Content only"]
];

export const tabSizeOptions = [
  ["compact", "Compact"],
  ["balanced", "Balanced"],
  ["roomy", "Roomy"]
];

export const titleDetailOptions = [
  ["smart", "Smart"],
  ["compact", "Name only"],
  ["folder", "Folder only"],
  ["detailed", "Name + folder"]
];

export const terminalColorDefaults = {
  background: "#191c22",
  foreground: "#d7dce6",
  cursor: "#7aa7ff"
};

export const terminalColorPresets = [
  {
    id: "cmux",
    label: "cmux",
    body: "Default dark surface with app accent cursor.",
    background: "",
    foreground: "",
    cursor: ""
  },
  {
    id: "powershell",
    label: "PowerShell",
    body: "Classic Windows console blue.",
    background: "#012456",
    foreground: "#f5f5f5",
    cursor: "#f5f5f5"
  },
  {
    id: "graphite",
    label: "Graphite",
    body: "Low-glare dark neutral.",
    background: "#111318",
    foreground: "#d8dee9",
    cursor: "#88c0d0"
  },
  {
    id: "contrast",
    label: "High contrast",
    body: "Sharper text and cursor visibility.",
    background: "#050505",
    foreground: "#f4f4f4",
    cursor: "#ffd166"
  },
  {
    id: "warm",
    label: "Warm",
    body: "Softer amber-tinted terminal.",
    background: "#1c1714",
    foreground: "#eadfce",
    cursor: "#f6bd60"
  },
  {
    id: "light",
    label: "Light",
    body: "Bright terminal for daytime use.",
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
    label: "Balanced",
    body: "Default chrome, clear terminal, full status.",
    settings: {
      theme: "cmux",
      accent: "oklch(61% 0.22 255)",
      backgroundImage: "",
      backgroundOpacity: 16,
      backgroundFit: "cover",
      backgroundPosition: "center",
      density: "comfortable",
      paneHeaderMode: "compact",
      sidebarDetailMode: "compact",
      sidebarFooterMode: "workspace",
      toolbarMode: "compact",
      tabSize: "balanced",
      titleDetailMode: "smart",
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
      terminalPauseInactiveOutput: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "focus",
    label: "Focus",
    body: "Tighter layout with quiet Harbor colors.",
    settings: {
      theme: "harbor",
      accent: "oklch(66% 0.13 175)",
      backgroundImage: "",
      backgroundOpacity: 10,
      backgroundFit: "cover",
      backgroundPosition: "center",
      density: "compact",
      paneHeaderMode: "hidden",
      sidebarDetailMode: "compact",
      sidebarFooterMode: "workspace",
      toolbarMode: "compact",
      tabSize: "balanced",
      titleDetailMode: "compact",
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
      terminalPauseInactiveOutput: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "performance",
    label: "Performance",
    body: "Cuts effects and keeps terminal history lighter.",
    settings: {
      theme: "graphite",
      accent: "oklch(72% 0.17 230)",
      backgroundImage: "",
      backgroundOpacity: 0,
      backgroundFit: "cover",
      backgroundPosition: "center",
      density: "compact",
      paneHeaderMode: "hidden",
      sidebarDetailMode: "compact",
      sidebarFooterMode: "workspace",
      toolbarMode: "compact",
      tabSize: "compact",
      titleDetailMode: "compact",
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
      terminalPauseInactiveOutput: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  },
  {
    id: "showcase",
    label: "Showcase",
    body: "Richer theme and soft background for demos.",
    settings: {
      theme: "orchid",
      accent: "oklch(74% 0.18 305)",
      backgroundImage: "preset:soft-aurora",
      backgroundOpacity: 24,
      backgroundFit: "cover",
      backgroundPosition: "center",
      density: "comfortable",
      paneHeaderMode: "full",
      sidebarDetailMode: "detailed",
      sidebarFooterMode: "compact",
      toolbarMode: "standard",
      tabSize: "roomy",
      titleDetailMode: "detailed",
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
      terminalPauseInactiveOutput: true,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  }
];

export const settingsCategories = [
  ["quick", "Quick"],
  ["profiles", "Profiles"],
  ["blueprints", "Blueprints"],
  ["workspace", "Workspace"],
  ["appearance", "Look"],
  ["browser", "Browser"],
  ["layout", "Layout"],
  ["performance", "Performance"],
  ["actions", "Actions"],
  ["commands", "Commands"],
  ["terminal", "Terminal"],
  ["data", "Data"]
];
