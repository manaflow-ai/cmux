const defaultSettings = {
  theme: "cmux",
  accent: "oklch(61% 0.22 255)",
  backgroundImage: "",
  backgroundOpacity: 16,
  density: "comfortable",
  showTabs: true,
  showStatusbar: true,
  showAdvanced: false,
  performanceMode: false,
  sidebarWidth: 232,
  terminalFontSize: 13,
  terminalPadding: 8,
  terminalScrollback: 12000
};

const themeOptions = [
  ["cmux", "cmux"],
  ["graphite", "Graphite"],
  ["forest", "Forest"],
  ["blueprint", "Blueprint"],
  ["harbor", "Harbor"],
  ["orchid", "Orchid"],
  ["ember", "Ember"],
  ["paper", "Paper Dark"]
];

const accentOptions = [
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

const backgroundPresets = [
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

const backgroundPresetMap = new Map(backgroundPresets.map((preset) => [preset.value, preset]));

const initialSettings = loadSettings();

const state = {
  data: null,
  sidebarCollapsed: false,
  inspectorMode: null,
  terminals: new Map(),
  browserViews: new Map(),
  paneCache: new Map(),
  workspaceRows: new Map(),
  surfaceTabButtons: new Map(),
  newTabButton: null,
  paletteOpen: false,
  paletteIndex: 0,
  dragPanelId: null,
  contextMenu: null,
  resizing: null,
  renderFrame: 0,
  scheduledRenderPrevious: null,
  pendingRender: false,
  pendingRenderPrevious: null,
  settings: initialSettings,
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

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, Number(value) || min));
}

function normalizeSettings(input = {}, legacyFontSize = 0) {
  const parsed = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const next = {
    ...defaultSettings,
    ...parsed
  };
  if (legacyFontSize && !parsed.terminalFontSize) next.terminalFontSize = legacyFontSize;
  next.terminalFontSize = clamp(next.terminalFontSize, 10, 22);
  next.backgroundOpacity = clamp(next.backgroundOpacity, 0, 42);
  if (!themeOptions.some(([id]) => id === next.theme)) next.theme = defaultSettings.theme;
  if (!accentOptions.includes(next.accent)) next.accent = defaultSettings.accent;
  if (!["comfortable", "compact"].includes(next.density)) next.density = defaultSettings.density;
  next.backgroundImage = normalizeBackgroundValue(next.backgroundImage);
  next.showTabs = next.showTabs !== false;
  next.showStatusbar = next.showStatusbar !== false;
  next.showAdvanced = Boolean(next.showAdvanced);
  next.performanceMode = Boolean(next.performanceMode);
  next.sidebarWidth = clamp(next.sidebarWidth, 188, 304);
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

function isBackgroundPreset(value) {
  return backgroundPresetMap.has(String(value || "").trim());
}

function normalizeBackgroundValue(value) {
  let url = String(value || "").trim();
  if (!url) return "";
  if (url.startsWith("preset:")) return backgroundPresetMap.has(url) ? url : "";
  if (!/^(https?:|data:image\/|\/)/i.test(url)) url = `https://${url}`;
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

function applySettings() {
  document.body.classList.remove(...themeOptions.filter(([id]) => id !== "cmux").map(([id]) => `theme-${id}`));
  if (state.settings.theme !== "cmux") document.body.classList.add(`theme-${state.settings.theme}`);
  document.documentElement.style.setProperty("--color-accent", state.settings.accent);
  document.documentElement.style.setProperty("--color-accent-hover", state.settings.accent);
  elements.shell.style.setProperty("--sidebar-width", `${state.settings.sidebarWidth}px`);
  elements.shell.style.setProperty("--terminal-padding", `${state.settings.terminalPadding}px`);
  elements.shell.classList.toggle("density-compact", state.settings.density === "compact");
  elements.shell.classList.toggle("hide-tabs", !state.settings.showTabs);
  elements.shell.classList.toggle("hide-status", !state.settings.showStatusbar);
  elements.shell.classList.toggle("show-advanced", state.settings.showAdvanced);
  elements.shell.classList.toggle("performance-mode", state.settings.performanceMode);
  const css = backgroundCss(state.settings.backgroundImage);
  elements.shell.classList.toggle("has-background", css !== "none");
  elements.shell.style.setProperty("--background-image", css);
  elements.shell.style.setProperty("--background-opacity", String(state.settings.backgroundOpacity / 100));
}

function updateSettings(updates) {
  state.settings = normalizeSettings({
    ...state.settings,
    ...updates
  });
  state.terminalFontSize = state.settings.terminalFontSize;
  saveSettings();
  applySettings();
  refreshTerminalAppearance();
}

function replaceChildrenIfChanged(parent, nodes) {
  if (parent.childNodes.length === nodes.length && nodes.every((node, index) => parent.childNodes[index] === node)) {
    return false;
  }
  parent.replaceChildren(...nodes);
  return true;
}

function terminalTheme() {
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim() || "#72a4ff";
  return {
    background: "#20221d",
    foreground: "#d9d7c9",
    cursor: accent,
    cursorAccent: "#111316",
    selectionBackground: "#315a92",
    black: "#20221d",
    red: "#f07178",
    green: "#88c070",
    yellow: "#d9c77f",
    blue: "#72a4ff",
    magenta: "#c792ea",
    cyan: "#75c7c6",
    white: "#d9d7c9",
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
    session.term.options.fontSize = state.terminalFontSize;
    session.term.options.scrollback = state.settings.terminalScrollback;
    session.term.options.theme = terminalTheme();
    scheduleFitTerminal(session);
  }
}

const commands = [
  { id: "workspace.new", label: "New Workspace", shortcut: "Ctrl+N", run: () => createWorkspace() },
  { id: "workspace.rename", label: "Rename Workspace", shortcut: "", run: () => renameActiveWorkspace() },
  { id: "workspace.color", label: "Change Workspace Color", shortcut: "", run: () => cycleWorkspaceColor() },
  { id: "workspace.close", label: "Close Workspace", shortcut: "", run: () => closeActiveWorkspace() },
  { id: "terminal.new", label: "New Terminal", shortcut: "Ctrl+T", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitRight", label: "Split Terminal Right", shortcut: "", run: () => createPanel("terminal", "right") },
  { id: "terminal.splitDown", label: "Split Terminal Down", shortcut: "", run: () => createPanel("terminal", "down") },
  { id: "terminal.clear", label: "Clear Active Terminal", shortcut: "Ctrl+K", run: () => clearActiveTerminal() },
  { id: "terminal.restart", label: "Restart Active Terminal", shortcut: "Ctrl+Shift+R", run: () => restartActiveTerminal() },
  { id: "terminal.close", label: "Close Active Pane", shortcut: "Ctrl+W", run: () => closeActivePanel() },
  { id: "terminal.fontUp", label: "Terminal Font Larger", shortcut: "Ctrl+=", run: () => changeTerminalFontSize(1) },
  { id: "terminal.fontDown", label: "Terminal Font Smaller", shortcut: "Ctrl+-", run: () => changeTerminalFontSize(-1) },
  { id: "browser.new", label: "Open Browser", shortcut: "Ctrl+Shift+L", run: () => openBrowserPrompt() },
  { id: "notifications.open", label: "Show Notifications", shortcut: "Ctrl+I", run: () => openInspector("notifications") },
  { id: "session.tools", label: "Show Session Tools", shortcut: "", run: () => openInspector("session") },
  { id: "settings.open", label: "Open Settings", shortcut: "Ctrl+,", run: () => openInspector("settings") },
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
  cleanupStalePaneCache();
  const workspace = activeWorkspace();
  const panelCount = workspace?.panels.length || 0;
  const attentionCount = allAttentionPanels().length;

  elements.workspaceHeading.textContent = workspace?.title || "Workspace";
  elements.workspaceSubheading.textContent = workspace
    ? `${workspace.cwdShort || "no directory"}`
    : "Ready";
  elements.statusSummary.textContent = workspace
    ? `${workspace.title} · ${panelCount ? `${panelCount} panel${panelCount === 1 ? "" : "s"}` : "home"} · ${attentionCount} attention`
    : "cmux Windows";
  elements.statusPipe.textContent = state.data.pipeName || "pipe unavailable";
  elements.statusPty.textContent = state.data.ptyAvailable ? "ConPTY ready" : "process pipe fallback";

  elements.shell.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  elements.shell.classList.toggle("inspector-open", Boolean(state.inspectorMode));
  applySettings();
  renderWorkspaces();
  renderSurfaceTabs(workspace);
  renderPanes(workspace);
  renderInspector();
  renderPalette();
  announceNewAttention(previousState, state.data);
}

function cleanupStalePaneCache() {
  const livePanelIds = allPanelIds();
  for (const panelId of [...state.paneCache.keys()]) {
    if (!livePanelIds.has(panelId)) cleanupPanel(panelId);
  }
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
    <span class="surface-close" title="Close">x</span>
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
  });
  button.querySelector(".surface-close").addEventListener("click", (event) => {
    event.stopPropagation();
    closePanel(button.dataset.panelId);
  });
  return button;
}

function updateSurfaceTab(button, workspace, panel) {
  button.dataset.panelId = panel.id;
  button.className = `surface-tab${panel.id === workspace.activePanelId ? " is-active" : ""}${panel.needsAttention ? " has-attention" : ""}`;
  button.style.setProperty("--tab-color", panel.color || workspace.color || "var(--color-accent)");
  button.querySelector(".surface-label").textContent = panel.type === "browser"
    ? hostnameOf(panel.url)
    : panel.title || "Terminal";
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
  const panelIds = new Set(panels.map((panel) => panel.id));
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
  for (const [index, panel] of panels.entries()) {
    if (index > 0) nodes.push(getPaneSplitter(workspace, panels[index - 1], panel));
    let pane = elements.paneGrid.querySelector(`[data-panel-id="${panel.id}"]`) || state.paneCache.get(panel.id);
    if (!pane) {
      pane = createPane(panel);
    }
    nodes.push(pane);
    pane.dataset.panelId = panel.id;
    pane.style.setProperty("--panel-color", panel.color || workspace.color || "var(--color-accent)");
    pane.classList.toggle("is-active", panel.id === workspace.activePanelId);
    pane.classList.toggle("has-attention", panel.needsAttention);
    pane.classList.toggle("is-browser", panel.type === "browser");
    pane.classList.toggle("is-terminal", panel.type === "terminal");
    pane.querySelector(".pane-type").textContent = panel.type === "browser" ? "www" : ">";
    pane.querySelector(".pane-title").textContent = panel.type === "browser"
      ? panel.url || "Browser"
      : panelTitle(panel);
    if (panel.type === "terminal") {
      ensureTerminal(panel, pane.querySelector(".pane-body"));
      const terminal = state.terminals.get(panel.id);
      if (terminal) scheduleFitTerminal(terminal);
    }
    if (panel.type === "browser") ensureBrowser(panel, pane.querySelector(".pane-body"));
  }
  replaceChildrenIfChanged(elements.paneGrid, nodes);
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
      <div class="empty-workspace-body">No panels are open in this workspace.</div>
      <div class="empty-workspace-actions">
        <button class="tool-button primary new-terminal">+ Term</button>
        <button class="tool-button new-browser">Web</button>
      </div>
    </div>
  `;
  node.querySelector(".empty-workspace-title").textContent = workspace?.title || "cmux Windows";
  node.querySelector(".new-terminal").onclick = () => createPanel("terminal", "right");
  node.querySelector(".new-browser").onclick = () => openBrowserPrompt();
  return node;
}

function renderEmptyWorkspace(workspace) {
  let node = [...elements.paneGrid.children].find((child) => child.classList.contains("empty-workspace"));
  if (!node) {
    node = createEmptyWorkspace(workspace);
  } else {
    node.querySelector(".empty-workspace-title").textContent = workspace?.title || "cmux Windows";
  }
  replaceChildrenIfChanged(elements.paneGrid, [node]);
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
  state.resizing = { splitter, previousPane, nextPane, vertical, start, previousSize, nextSize };
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
  state.resizing.splitter.releasePointerCapture?.(event.pointerId);
  state.resizing.splitter.classList.remove("is-dragging");
  state.resizing = null;
  flushPendingRender();
}

function createPane(panel) {
  const pane = document.createElement("article");
  pane.className = "pane";
  pane.dataset.panelId = panel.id;
  pane.innerHTML = `
    <div class="pane-header">
      <div class="pane-type"></div>
      <div class="pane-title"></div>
      <div class="pane-toolbar">
        <button class="pane-tool split-right" title="Split right">+</button>
        <button class="pane-tool split-down" title="Split down">▾</button>
        <button class="pane-tool font-down" title="Smaller terminal text">A-</button>
        <button class="pane-tool font-up" title="Larger terminal text">A+</button>
        <button class="pane-tool restart" title="Restart terminal">R</button>
        <button class="pane-tool close" title="Close">x</button>
      </div>
    </div>
    <div class="pane-body"></div>
  `;
  const header = pane.querySelector(".pane-header");
  header.draggable = true;
  header.addEventListener("dragstart", (event) => {
    state.dragPanelId = pane.dataset.panelId;
    pane.classList.add("is-dragging");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", state.dragPanelId);
  });
  header.addEventListener("dragend", () => {
    pane.classList.remove("is-dragging");
    state.dragPanelId = null;
  });
  pane.querySelector(".split-right").onclick = (event) => {
    event.stopPropagation();
    createPanel("terminal", "right");
  };
  pane.querySelector(".split-down").onclick = (event) => {
    event.stopPropagation();
    createPanel("terminal", "down");
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
    restartPanel(panel.id);
  };
  pane.querySelector(".close").onclick = (event) => {
    event.stopPropagation();
    closePanel(panel.id);
  };
  pane.addEventListener("dragover", (event) => {
    if (!state.dragPanelId || state.dragPanelId === pane.dataset.panelId) return;
    event.preventDefault();
    pane.classList.add("is-drop-before");
  });
  pane.addEventListener("dragleave", () => pane.classList.remove("is-drop-before"));
  pane.addEventListener("drop", (event) => {
    event.preventDefault();
    pane.classList.remove("is-drop-before");
    if (state.dragPanelId && state.dragPanelId !== pane.dataset.panelId) {
      movePanelBefore(state.dragPanelId, pane.dataset.panelId);
    }
  });
  pane.addEventListener("pointerdown", () => focusPanel(panel.id));
  state.paneCache.set(panel.id, pane);
  return pane;
}

function cleanupPanel(panelId) {
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
  const host = document.createElement("div");
  host.className = "terminal-host";
  body.appendChild(host);

  const term = new Terminal({
    cursorBlink: true,
    allowProposedApi: true,
    convertEol: true,
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--font-mono"),
    fontSize: state.terminalFontSize,
    lineHeight: 1.22,
    scrollback: state.settings.terminalScrollback,
    theme: terminalTheme()
  });
  const fitAddon = new FitAddon.FitAddon();
  const webLinksAddon = new WebLinksAddon.WebLinksAddon();
  term.loadAddon(fitAddon);
  term.loadAddon(webLinksAddon);
  term.open(host);

  const socket = new WebSocket(`${location.origin.replace(/^http/, "ws")}/terminal/${panel.id}`);
  const session = { term, fitAddon, socket, queue: "", scheduled: false, fitFrame: 0, resizeObserver: null, disposed: false };

  socket.addEventListener("open", () => scheduleFitTerminal(session));
  socket.addEventListener("message", (event) => {
    if (session.disposed) return;
    const message = JSON.parse(event.data);
    if (message.type === "output") {
      session.queue += message.data;
      if (!session.scheduled) {
        session.scheduled = true;
        requestAnimationFrame(() => {
          term.write(session.queue);
          session.queue = "";
          session.scheduled = false;
        });
      }
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
    scheduleFitTerminal(session);
    if (panel.id === activeWorkspace()?.activePanelId) term.focus();
  }, 60);
  state.terminals.set(panel.id, session);
}

function scheduleFitTerminal(session) {
  if (session.disposed || session.fitFrame) return;
  session.fitFrame = requestAnimationFrame(() => {
    session.fitFrame = 0;
    fitTerminal(session);
  });
}

function fitTerminal(session) {
  if (session.disposed) return;
  try {
    session.fitAddon.fit();
    if (session.socket.readyState === WebSocket.OPEN) {
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

function ensureBrowser(panel, body) {
  if (state.browserViews.has(panel.id)) return;
  body.replaceChildren();

  const shell = document.createElement("div");
  shell.className = "browser-shell";
  const bar = document.createElement("div");
  bar.className = "browser-bar";
  const back = document.createElement("button");
  back.className = "browser-nav";
  back.textContent = "<";
  const forward = document.createElement("button");
  forward.className = "browser-nav";
  forward.textContent = ">";
  const address = document.createElement("input");
  address.className = "browser-address";
  address.value = panel.url || "https://example.com";
  const go = document.createElement("button");
  go.className = "browser-go";
  go.textContent = "Go";
  const external = document.createElement("button");
  external.className = "browser-go";
  external.textContent = "Open";
  const status = document.createElement("div");
  status.className = "browser-status";
  status.textContent = "Loading";
  bar.append(back, forward, address, go, external);

  const view = document.createElement(window.cmuxNative?.electron ? "webview" : "iframe");
  view.className = "browser-view";
  view.src = normalizeUrl(address.value);
  view.setAttribute("allowpopups", "true");
  if (view.tagName.toLowerCase() === "webview") {
    view.setAttribute("partition", "persist:cmux-browser");
    view.setAttribute("webpreferences", "contextIsolation=yes,nodeIntegration=no");
  }

  const navigate = () => {
    if (!findPanelState(panel.id)) return;
    const next = normalizeUrl(address.value);
    address.value = next;
    view.src = next;
    updatePanel(panel.id, { url: next });
  };
  go.onclick = navigate;
  external.onclick = () => {
    if (window.cmuxNative?.openExternal) {
      window.cmuxNative.openExternal(normalizeUrl(address.value));
    } else {
      window.open(normalizeUrl(address.value), "_blank", "noopener");
    }
  };
  address.addEventListener("keydown", (event) => {
    if (event.key === "Enter") navigate();
  });
  back.onclick = () => {
    if (typeof view.goBack === "function" && view.canGoBack()) view.goBack();
  };
  forward.onclick = () => {
    if (typeof view.goForward === "function" && view.canGoForward()) view.goForward();
  };
  view.addEventListener("did-navigate", (event) => {
    if (event.url) {
      address.value = event.url;
      if (findPanelState(panel.id)) updatePanel(panel.id, { url: event.url });
    }
  });
  view.addEventListener("did-start-loading", () => {
    status.textContent = "Loading";
    status.classList.add("is-visible");
  });
  view.addEventListener("did-stop-loading", () => {
    status.classList.remove("is-visible");
  });
  view.addEventListener("did-fail-load", (event) => {
    if (event.errorCode === -3) return;
    status.textContent = "Could not load here. Use Open.";
    status.classList.add("is-visible");
  });

  shell.append(bar, status, view);
  body.append(shell);
  state.browserViews.set(panel.id, { view, address });
}

function normalizeUrl(value) {
  let next = String(value || "").trim();
  if (!next) next = "https://example.com";
  if (!/^https?:\/\//i.test(next)) next = `https://${next}`;
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
  elements.inspectorSubtitle.textContent = "Appearance and workspace controls";
  const workspace = activeWorkspace();
  const nodes = [];

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
  workspaceSection.append(settingRow("Color", swatchGrid(state.data?.palette || accentOptions, workspace?.color, (color) => setWorkspaceColor(color))));
  nodes.push(workspaceSection);

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

  const opacityInput = document.createElement("input");
  opacityInput.className = "setting-control";
  opacityInput.type = "range";
  opacityInput.min = "0";
  opacityInput.max = "42";
  opacityInput.value = String(state.settings.backgroundOpacity);
  opacityInput.oninput = () => updateSettings({ backgroundOpacity: Number(opacityInput.value) });
  appearanceSection.append(settingRow("Image strength", opacityInput));
  nodes.push(appearanceSection);

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
  layoutSection.append(settingRow("Surface tabs", toggleInput(state.settings.showTabs, (checked) => updateSettings({ showTabs: checked }))));
  layoutSection.append(settingRow("Status bar", toggleInput(state.settings.showStatusbar, (checked) => updateSettings({ showStatusbar: checked }))));
  layoutSection.append(settingRow("Toolbar shortcuts", toggleInput(state.settings.showAdvanced, (checked) => updateSettings({ showAdvanced: checked }))));
  layoutSection.append(settingRow("Performance mode", toggleInput(state.settings.performanceMode, (checked) => updateSettings({ performanceMode: checked }))));
  nodes.push(layoutSection);

  const terminalSection = settingsSection("Terminal");
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
  const restart = document.createElement("button");
  restart.className = "notification-action";
  restart.textContent = "Restart active terminal";
  restart.onclick = () => restartActiveTerminal();
  terminalSection.append(restart);
  nodes.push(terminalSection);

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

  elements.inspectorBody.replaceChildren(...nodes);
}

function settingsSection(title) {
  const section = document.createElement("section");
  section.className = "settings-section";
  const heading = document.createElement("div");
  heading.className = "settings-section-title";
  heading.textContent = title;
  section.append(heading);
  return section;
}

function settingRow(label, control, stacked = false) {
  const row = document.createElement("label");
  row.className = `setting-row${stacked ? " stacked" : ""}`;
  const text = document.createElement("span");
  text.className = "setting-label";
  text.textContent = label;
  row.append(text, control);
  return row;
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

function backgroundPresetGrid() {
  const grid = document.createElement("div");
  grid.className = "background-preset-grid";
  for (const preset of backgroundPresets) {
    const button = document.createElement("button");
    button.className = `background-preset${preset.value === state.settings.backgroundImage ? " is-active" : ""}`;
    button.type = "button";
    button.title = preset.label;
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

function settingsActionButton(label, onClick, tone = "") {
  const button = document.createElement("button");
  button.className = `settings-action${tone ? ` ${tone}` : ""}`;
  button.type = "button";
  button.textContent = label;
  button.onclick = onClick;
  return button;
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
  const title = document.createElement("div");
  title.className = "context-title";
  title.textContent = panel.type === "browser" ? hostnameOf(panel.url) : panel.title || "Terminal";
  const actions = document.createElement("div");
  actions.className = "context-actions";
  actions.append(
    contextMenuButton("Rename", () => renamePanel(panel)),
    contextMenuButton("Duplicate", () => duplicatePanel(panel)),
    contextMenuButton("Move left", () => movePanelLeft(found.workspace, index), index <= 0),
    contextMenuButton("Move right", () => movePanelRight(found.workspace, index), index >= found.workspace.panels.length - 1),
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
  menu.replaceChildren(title, actions, colors, clear);
  menu.hidden = false;
  const x = Math.min(event.clientX, window.innerWidth - 238);
  const y = Math.min(event.clientY, window.innerHeight - 260);
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
    contextMenuButton("Rename workspace", renameActiveWorkspace),
    contextMenuButton("Change workspace color", cycleWorkspaceColor),
    contextMenuButton("Clear active terminal", clearActiveTerminal, panel?.type !== "terminal"),
    contextMenuButton("Restart terminal", restartActiveTerminal, panel?.type !== "terminal"),
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

function renamePanel(panel) {
  const title = prompt("Tab name", panel.title || (panel.type === "browser" ? hostnameOf(panel.url) : "Terminal"));
  if (!title) return;
  updatePanel(panel.id, { title: title.trim() });
}

function duplicatePanel(panel) {
  if (panel.type === "browser") {
    createPanel("browser", "right", { url: panel.url || "https://example.com" });
    return;
  }
  createPanel("terminal", "right");
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

  const query = elements.paletteInput.value.trim().toLowerCase();
  const matches = commands.filter((command) => command.label.toLowerCase().includes(query));
  state.paletteIndex = Math.min(state.paletteIndex, Math.max(0, matches.length - 1));
  elements.paletteList.replaceChildren(...matches.map((command, index) => {
    const button = document.createElement("button");
    button.className = `palette-item${index === state.paletteIndex ? " is-selected" : ""}`;
    button.innerHTML = `<span></span><span class="palette-shortcut"></span>`;
    button.querySelector("span").textContent = command.label;
    button.querySelector(".palette-shortcut").textContent = command.shortcut;
    button.onclick = () => runPaletteCommand(command);
    return button;
  }));
}

function runPaletteCommand(command) {
  state.paletteOpen = false;
  elements.paletteInput.value = "";
  renderPalette();
  command.run();
}

async function createWorkspace() {
  await api("/api/workspaces", {
    method: "POST",
    body: JSON.stringify({ title: `Workspace ${state.data.workspaces.length + 1}` })
  });
}

async function renameActiveWorkspace() {
  const workspace = activeWorkspace();
  if (!workspace) return;
  const title = prompt("Workspace name", workspace.title);
  if (!title) return;
  await renameWorkspaceTo(title);
}

async function renameWorkspaceTo(title) {
  const workspace = activeWorkspace();
  const trimmed = String(title || "").trim();
  if (!workspace || !trimmed || trimmed === workspace.title) return;
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ title: trimmed })
  });
}

async function cycleWorkspaceColor() {
  const workspace = activeWorkspace();
  const palette = state.data?.palette || [];
  if (!workspace || palette.length === 0) return;
  const currentIndex = Math.max(0, palette.indexOf(workspace.color));
  const color = palette[(currentIndex + 1) % palette.length];
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ color })
  });
}

async function setWorkspaceColor(color) {
  const workspace = activeWorkspace();
  if (!workspace) return;
  await api(`/api/workspaces/${workspace.id}`, {
    method: "PATCH",
    body: JSON.stringify({ color })
  });
}

async function closeActiveWorkspace() {
  const workspace = activeWorkspace();
  if (!workspace) return;
  await api(`/api/workspaces/${workspace.id}`, { method: "DELETE" });
}

async function createPanel(type, direction = "right", options = {}) {
  const workspace = activeWorkspace();
  if (!workspace) return;
  await api("/api/panels", {
    method: "POST",
    body: JSON.stringify({
      workspaceId: workspace.id,
      type,
      direction,
      url: type === "browser" ? normalizeUrl(options.url || "https://example.com") : undefined
    })
  });
}

async function openBrowserPrompt() {
  const url = prompt("Open URL", "https://www.bing.com");
  if (url === null) return;
  await createPanel("browser", "right", { url });
}

async function closePanel(panelId) {
  try {
    await api(`/api/panels/${panelId}`, { method: "DELETE" });
  } catch {
    await loadState();
  }
}

async function updatePanel(panelId, updates) {
  try {
    await api(`/api/panels/${panelId}`, {
      method: "PATCH",
      body: JSON.stringify(updates)
    });
  } catch {
    // Navigation can race with pane closure; the next state event will reconcile.
  }
}

async function movePanelBefore(panelId, beforePanelId) {
  const workspace = activeWorkspace();
  if (!workspace || !panelId || !beforePanelId || panelId === beforePanelId) return;
  await updatePanel(panelId, { workspaceId: workspace.id, beforePanelId });
}

async function movePanelToWorkspace(panelId, workspaceId) {
  if (!panelId || !workspaceId) return;
  await updatePanel(panelId, { workspaceId, moveToEnd: true });
}

async function focusWorkspace(workspaceId) {
  try {
    await api(`/api/workspaces/${workspaceId}/focus`, { method: "POST" });
  } catch {
    await loadState();
  }
}

async function focusPanel(panelId) {
  try {
    await api(`/api/panels/${panelId}/focus`, { method: "POST" });
  } catch {
    await loadState();
    return;
  }
  const terminal = state.terminals.get(panelId);
  if (terminal) setTimeout(() => terminal.term.focus(), 20);
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

function clearActiveTerminal() {
  const panel = activePanel();
  const terminal = panel ? state.terminals.get(panel.id) : null;
  if (terminal) terminal.term.clear();
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

async function exportSettings() {
  const payload = JSON.stringify(state.settings, null, 2);
  if (await writeClipboardText(payload)) {
    toast("Settings copied to clipboard.");
    return;
  }
  prompt("cmux settings JSON", payload);
}

async function importSettings() {
  const clipboard = await readClipboardText();
  const suggested = clipboard.trim().startsWith("{") ? clipboard : "";
  const raw = prompt("Paste cmux settings JSON", suggested);
  if (raw === null) return;
  try {
    state.settings = normalizeSettings(JSON.parse(raw));
    state.terminalFontSize = state.settings.terminalFontSize;
    saveSettings();
    applySettings();
    refreshTerminalAppearance();
    renderSettingsInspector();
    toast("Settings imported.");
  } catch {
    toast("Settings import failed.");
  }
}

function resetSettings() {
  if (!confirm("Reset cmux Windows settings to defaults?")) return;
  state.settings = normalizeSettings(defaultSettings);
  state.terminalFontSize = state.settings.terminalFontSize;
  saveSettings();
  applySettings();
  refreshTerminalAppearance();
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
  if (event.key === "Escape" && state.contextMenu && !state.contextMenu.hidden) {
    hideContextMenu();
  } else if (event.ctrlKey && event.shiftKey && key === "p") {
    event.preventDefault();
    state.paletteOpen = !state.paletteOpen;
    renderPalette();
    if (state.paletteOpen) setTimeout(() => elements.paletteInput.focus(), 0);
  } else if (event.ctrlKey && key === "n") {
    event.preventDefault();
    createWorkspace();
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
  } else if (event.ctrlKey && key === "w") {
    const workspace = activeWorkspace();
    if (workspace?.activePanelId) {
      event.preventDefault();
      closePanel(workspace.activePanelId);
    }
  }
});

window.addEventListener("pointermove", continuePaneResize);
window.addEventListener("pointerup", finishPaneResize);
window.addEventListener("pointercancel", finishPaneResize);
document.addEventListener("click", (event) => {
  if (state.contextMenu && !state.contextMenu.hidden && !state.contextMenu.contains(event.target)) {
    hideContextMenu();
  }
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
