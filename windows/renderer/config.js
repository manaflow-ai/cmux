export const defaultSettings = {
  theme: "cmux",
  accent: "oklch(61% 0.22 255)",
  backgroundImage: "",
  backgroundOpacity: 16,
  browserHomeUrl: "https://www.bing.com",
  density: "comfortable",
  toolbarMode: "compact",
  showTabs: true,
  showStatusbar: true,
  showAdvanced: false,
  performanceMode: false,
  sidebarWidth: 232,
  terminalFontFamily: "cascadia",
  terminalFontSize: 13,
  terminalLineHeight: 1.22,
  terminalPadding: 8,
  terminalScrollback: 12000,
  terminalCursorStyle: "block",
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

export const terminalColorDefaults = {
  background: "#191c22",
  foreground: "#d7dce6",
  cursor: "#7aa7ff"
};

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
      density: "comfortable",
      toolbarMode: "compact",
      showTabs: true,
      showStatusbar: true,
      showAdvanced: false,
      performanceMode: false,
      sidebarWidth: 232,
      terminalFontFamily: "cascadia",
      terminalFontSize: 13,
      terminalLineHeight: 1.22,
      terminalPadding: 8,
      terminalScrollback: 12000,
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
      density: "compact",
      toolbarMode: "compact",
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: false,
      sidebarWidth: 216,
      terminalFontFamily: "cascadia",
      terminalFontSize: 14,
      terminalLineHeight: 1.18,
      terminalPadding: 6,
      terminalScrollback: 10000,
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
      density: "compact",
      toolbarMode: "compact",
      showTabs: true,
      showStatusbar: false,
      showAdvanced: false,
      performanceMode: true,
      sidebarWidth: 204,
      terminalFontFamily: "consolas",
      terminalFontSize: 13,
      terminalLineHeight: 1.16,
      terminalPadding: 4,
      terminalScrollback: 6000,
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
      density: "comfortable",
      toolbarMode: "standard",
      showTabs: true,
      showStatusbar: true,
      showAdvanced: false,
      performanceMode: false,
      sidebarWidth: 248,
      terminalFontFamily: "cascadia",
      terminalFontSize: 14,
      terminalLineHeight: 1.24,
      terminalPadding: 10,
      terminalScrollback: 12000,
      terminalBackground: "",
      terminalForeground: "",
      terminalCursorColor: ""
    }
  }
];

export const settingsCategories = [
  ["quick", "Quick"],
  ["workspace", "Workspace"],
  ["appearance", "Look"],
  ["browser", "Browser"],
  ["layout", "Layout"],
  ["terminal", "Terminal"],
  ["data", "Data"]
];
