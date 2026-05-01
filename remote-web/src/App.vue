<template>
  <main class="app-shell" :class="{ 'nav-open': navOpen, 'has-token': hasToken, 'keyboard-active': keyboardActive }">
    <section v-if="!hasToken" class="token-screen">
      <div class="token-panel">
        <div class="brand-row">
          <div class="brand-mark" aria-hidden="true">c</div>
          <div class="brand-copy">
            <h1>{{ t("appTitle") }}</h1>
            <p>{{ t("connectSubtitle") }}</p>
          </div>
        </div>
        <form class="token-form" @submit.prevent="connect">
          <label for="token-input">{{ t("tokenLabel") }}</label>
          <input
            id="token-input"
            v-model.trim="tokenInput"
            type="password"
            autocomplete="current-password"
            autocapitalize="off"
            spellcheck="false"
            :placeholder="t('tokenPlaceholder')"
          />
          <button type="submit">{{ t("connectButton") }}</button>
        </form>
        <p class="hint">{{ t("tokenHint") }}</p>
      </div>
    </section>

    <section v-else class="remote-screen">
      <header class="topbar">
        <button type="button" class="icon-button nav-toggle" :aria-label="t('sessionsTitle')" @click="navOpen = true">
          <span aria-hidden="true"></span>
          <span aria-hidden="true"></span>
          <span aria-hidden="true"></span>
        </button>
        <div class="topbar-title">
          <div class="brand-mark small" aria-hidden="true">c</div>
          <div>
            <h1>{{ terminalTitle }}</h1>
            <p class="status-pill" :class="statusClass">{{ statusText }}</p>
          </div>
        </div>
        <div class="topbar-actions">
          <button type="button" class="ghost" @click="refresh">{{ t("refreshButton") }}</button>
          <button type="button" class="ghost" @click="forget">{{ t("forgetButton") }}</button>
        </div>
      </header>

      <div class="workspace-layout">
        <div v-if="navOpen" class="drawer-scrim" @click="navOpen = false"></div>
        <aside class="session-rail" :class="{ open: navOpen }">
          <div class="rail-header">
            <div class="panel-title">{{ t("sessionsTitle") }}</div>
            <div class="rail-actions">
              <button type="button" class="ghost" :disabled="creatingSession" @click="createNewSession">
                {{ creatingSession ? t("creatingSessionButton") : t("newSessionButton") }}
              </button>
              <button type="button" class="icon-button rail-close" :aria-label="t('sessionsTitle')" @click="navOpen = false">
                <span aria-hidden="true">x</span>
              </button>
            </div>
          </div>
          <div v-if="!windows.length" class="empty-note">{{ t("tree.noWindows") }}</div>
          <section
            v-for="workspace in flatWorkspaces"
            :key="workspace.key"
            class="workspace-card"
            :class="{ active: workspace.workspace.selected }"
          >
            <div class="workspace-title">
              <span>{{ workspace.workspace.title || t("tree.workspaceFallback") }}</span>
              <span>{{ workspace.workspace.selected ? t("tree.selected") : `#${workspace.workspace.index + 1}` }}</span>
            </div>
            <div class="workspace-meta">
              {{ format("tree.windowPanes", { window: workspace.window.index + 1, panes: workspace.workspace.panes?.length || 0 }) }}
            </div>
            <div class="surface-list">
              <button
                v-for="selection in workspace.surfaces"
                :key="selection.surface.id"
                type="button"
                class="surface-button"
                :class="{ selected: selectedSurface?.surface.id === selection.surface.id, focused: selection.surface.focused }"
                :disabled="selection.surface.type !== 'terminal'"
                @click="selectSurface(selection)"
              >
                <span class="surface-label">{{ selection.surface.title || selection.surface.type || t("tree.surfaceFallback") }}</span>
                <span class="surface-meta">{{ surfaceMeta(selection.surface) }}</span>
              </button>
            </div>
          </section>
        </aside>

        <section class="terminal-pane" :class="{ empty: !selectedSurface }">
          <div class="terminal-header">
            <div>
              <h2>{{ terminalTitle }}</h2>
              <p>{{ terminalMeta }}</p>
            </div>
            <div class="terminal-actions">
              <button type="button" class="ghost" :disabled="!selectedSurface || creatingTab" @click="createNewTerminalTab">
                {{ creatingTab ? t("creatingTabButton") : t("newTabButton") }}
              </button>
              <button type="button" class="ghost read-button" :disabled="!selectedSurface" @click="readSelectedTerminalFromButton">
                {{ t("readButton") }}
              </button>
            </div>
          </div>

          <div class="terminal-stage">
            <div class="window-controls" aria-hidden="true">
              <span></span>
              <span></span>
              <span></span>
            </div>
            <div
              ref="terminalElement"
              class="xterm-host"
              :aria-label="t('terminalOutputLabel')"
              @click="focusTerminalInput"
              @pointerdown="focusTerminalInput"
            ></div>
          </div>

          <div class="quick-key-strip" :aria-label="t('terminalKeysLabel')">
            <span>{{ t("quickKeysLabel") }}</span>
            <button
              v-for="quickKey in quickKeys"
              :key="quickKey.key"
              type="button"
              :disabled="!selectedSurface"
              @click="sendKey(quickKey.key)"
            >
              {{ t(quickKey.label) }}
            </button>
          </div>
        </section>
      </div>
    </section>
  </main>
</template>

<script setup lang="ts">
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { classifyTerminalData } from "./terminalKeyMap";
import { TerminalInputQueue, type TerminalInputTarget } from "./terminalInputQueue";

type RemoteStrings = Record<string, string>;
type SurfaceSnapshot = {
  id: string;
  title?: string;
  type?: string;
  focused?: boolean;
};
type PaneSnapshot = {
  id?: string;
  surfaces?: SurfaceSnapshot[];
};
type WorkspaceSnapshot = {
  id: string;
  title?: string;
  index: number;
  selected?: boolean;
  panes?: PaneSnapshot[];
};
type WindowSnapshot = {
  id?: string;
  index: number;
  workspaces?: WorkspaceSnapshot[];
};
type Snapshot = {
  windows?: WindowSnapshot[];
};
type Selection = {
  window: WindowSnapshot;
  workspace: WorkspaceSnapshot;
  pane: PaneSnapshot;
  surface: SurfaceSnapshot;
};
type EventState = "live" | "reconnecting" | "offline";

const storageKey = "cmux.remote.token";
const eventSessionRefreshMs = 24 * 60 * 60 * 1000;
const strings = ref<RemoteStrings>({});
const token = ref("");
const tokenInput = ref("");
const snapshot = ref<Snapshot | null>(null);
const selectedSurface = ref<Selection | null>(null);
const eventState = ref<EventState>("offline");
const statusMessage = ref("");
const statusIsError = ref(false);
const navOpen = ref(false);
const creatingSession = ref(false);
const creatingTab = ref(false);
const keyboardActive = ref(false);
const terminalElement = ref<HTMLElement | null>(null);

let terminal: Terminal | null = null;
let fitAddon: FitAddon | null = null;
let pollingTimer: number | null = null;
let eventSource: EventSource | null = null;
let eventRefreshTimer: number | null = null;
let eventSessionRefreshTimer: number | null = null;
let eventStartGeneration = 0;
let lastTerminalText = "";
let terminalFocusDisposable: { dispose: () => void } | null = null;
let terminalBlurDisposable: { dispose: () => void } | null = null;
const terminalInputQueue = new TerminalInputQueue({
  targetEquals,
  sendText: sendTextMutation,
  sendKey: sendKeyMutation,
  afterMutation: readSelectedTerminalForTarget,
  handleError: handleRemoteError,
});

const quickKeys = [
  { key: "enter", label: "key.enter" },
  { key: "escape", label: "key.escape" },
  { key: "ctrl-c", label: "key.ctrlC" },
  { key: "tab", label: "key.tab" },
  { key: "up", label: "key.up" },
  { key: "down", label: "key.down" },
  { key: "left", label: "key.left" },
  { key: "right", label: "key.right" },
  { key: "backspace", label: "key.backspace" },
];

const hasToken = computed(() => Boolean(token.value));
const windows = computed(() => snapshot.value?.windows || []);
const flatSurfaces = computed<Selection[]>(() => {
  const result: Selection[] = [];
  for (const win of windows.value) {
    for (const workspace of win.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          result.push({ window: win, workspace, pane, surface });
        }
      }
    }
  }
  return result;
});
const flatWorkspaces = computed(() =>
  windows.value.flatMap((win) =>
    (win.workspaces || []).map((workspace) => ({
      key: `${win.id || win.index}:${workspace.id}`,
      window: win,
      workspace,
      surfaces: flatSurfaces.value.filter((selection) => selection.window === win && selection.workspace === workspace),
    })),
  ),
);
const terminalTitle = computed(() => {
  const selected = selectedSurface.value;
  if (!selected) return t("noTerminalSelected");
  return selected.surface.title || t("terminalFallback");
});
const terminalMeta = computed(() => {
  const selected = selectedSurface.value;
  if (!selected) return t("selectTerminal");
  return `${selected.workspace.title || t("tree.workspaceFallback")} - ${selected.surface.id.slice(0, 8)}`;
});
const statusText = computed(() => {
  if (statusMessage.value) return statusMessage.value;
  if (!token.value) return t("status.disconnected");
  if (eventState.value === "live") return t("status.live");
  if (eventState.value === "reconnecting") return t("status.reconnecting");
  return t("status.connected");
});
const statusClass = computed(() => ({
  error: statusIsError.value,
  connected: !statusIsError.value && (eventState.value === "live" || statusText.value === t("status.connected")),
}));

function t(key: string) {
  return strings.value[key] || "";
}

function format(key: string, replacements: Record<string, string | number> = {}) {
  const source = t(key);
  const named = Object.entries(replacements).reduce(
    (message, [name, value]) => message.split(`{${name}}`).join(String(value)),
    source,
  );
  return Object.values(replacements).reduce(
    (message, value) => message.replace("%lld", String(value)),
    named,
  );
}

async function loadStrings() {
  try {
    const response = await fetch("/remote/strings.json");
    if (!response.ok) return;
    strings.value = await response.json();
    document.title = t("appTitle");
  } catch {
    strings.value = {};
  }
}

function importTokenFromHash() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const hashToken = hash.get("token");
  if (!hashToken) return;
  localStorage.setItem(storageKey, hashToken);
  history.replaceState(null, "", window.location.pathname);
}

function loadToken() {
  importTokenFromHash();
  token.value = localStorage.getItem(storageKey) || "";
  tokenInput.value = token.value;
}

function authHeaders() {
  return { Authorization: `Bearer ${token.value}` };
}

async function createEventSession() {
  if (!token.value) return;
  const response = await fetch("/events/session", {
    method: "POST",
    headers: authHeaders(),
    credentials: "same-origin",
  });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    if (response.status === 401) throw tokenRejectedError();
    throw new Error(format("error.requestFailed", { status: payload.error?.code || response.status }));
  }
  scheduleEventSessionRefresh();
}

function deleteEventSession() {
  clearEventSessionRefresh();
  fetch("/events/session", {
    method: "DELETE",
    credentials: "same-origin",
  }).catch(() => {
    // The cookie is server-owned; failures are harmless when disconnecting.
  });
}

function clearEventSessionRefresh() {
  if (eventSessionRefreshTimer) window.clearTimeout(eventSessionRefreshTimer);
  eventSessionRefreshTimer = null;
}

function scheduleEventSessionRefresh() {
  clearEventSessionRefresh();
  if (!token.value) return;
  eventSessionRefreshTimer = window.setTimeout(() => {
    eventSessionRefreshTimer = null;
    createEventSession().catch(handleRemoteError);
  }, eventSessionRefreshMs);
}

function setStatus(message: string, isError = false) {
  statusMessage.value = message;
  statusIsError.value = isError;
}

function clearStatus() {
  statusMessage.value = "";
  statusIsError.value = false;
}

function tokenRejectedError() {
  const error = new Error(t("error.tokenRejected"));
  (error as Error & { authFailed?: boolean }).authFailed = true;
  return error;
}

function handleRemoteError(error: unknown) {
  const remoteError = error as Error & { authFailed?: boolean };
  if (remoteError.authFailed) {
    stopEvents();
    stopPolling();
    deleteEventSession();
  }
  setStatus(remoteError.message || String(error), true);
}

async function rpc(method: string, params: Record<string, unknown> = {}) {
  const response = await fetch("/rpc", {
    method: "POST",
    headers: {
      ...authHeaders(),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method,
      params,
    }),
  });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    if (response.status === 401) throw tokenRejectedError();
    throw new Error(format("error.requestFailed", { status: payload.error?.code || response.status }));
  }
  return payload.result;
}

async function fetchSnapshot(options: { showRefreshing?: boolean; updateSelection?: boolean } = {}) {
  if (options.showRefreshing !== false) {
    setStatus(t("status.refreshing"));
  }
  const response = await fetch("/snapshot", { headers: authHeaders() });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    if (response.status === 401) throw tokenRejectedError();
    throw new Error(format("error.snapshotFailed", { status: payload.error?.code || response.status }));
  }
  snapshot.value = payload.result;
  clearStatus();
  if (options.updateSelection !== false) {
    ensureSelection();
  }
}

function eventURL() {
  return new URL("/events", window.location.origin).toString();
}

function scheduleEventRefresh() {
  if (document.hidden || !token.value || eventRefreshTimer) return;
  eventRefreshTimer = window.setTimeout(() => {
    eventRefreshTimer = null;
    fetchSnapshot({ showRefreshing: false }).catch(handleRemoteError);
  }, 200);
}

async function startEvents() {
  eventStartGeneration += 1;
  const generation = eventStartGeneration;
  closeEventSource();
  if (!token.value || !("EventSource" in window)) {
    eventState.value = "offline";
    return;
  }
  await createEventSession();
  if (generation !== eventStartGeneration || !token.value) return;
  const source = new EventSource(eventURL(), { withCredentials: true });
  eventSource = source;
  source.onopen = () => {
    if (eventSource === source) {
      eventState.value = "live";
      clearStatus();
      scheduleEventRefresh();
    }
  };
  source.addEventListener("hello", () => {
    if (eventSource === source) {
      eventState.value = "live";
      clearStatus();
      scheduleEventRefresh();
    }
  });
  source.addEventListener("snapshot_changed", () => {
    if (eventSource === source) scheduleEventRefresh();
  });
  source.onerror = () => {
    if (eventSource === source && token.value) {
      eventState.value = "reconnecting";
      statusIsError.value = false;
    }
  };
}

function closeEventSource() {
  eventSource?.close();
  eventSource = null;
  if (eventRefreshTimer) window.clearTimeout(eventRefreshTimer);
  eventRefreshTimer = null;
  eventState.value = "offline";
}

function stopEvents() {
  eventStartGeneration += 1;
  closeEventSource();
}

function ensureSelection() {
  const surfaces = flatSurfaces.value;
  const refreshed = selectedSurface.value
    ? surfaces.find((selection) => selection.surface.id === selectedSurface.value?.surface.id && selection.surface.type === "terminal")
    : null;
  selectedSurface.value =
    refreshed ||
    surfaces.find((selection) => selection.surface.type === "terminal" && selection.surface.focused) ||
    surfaces.find((selection) => selection.surface.type === "terminal") ||
    null;

  if (selectedSurface.value) {
    readSelectedTerminal().catch(handleRemoteError);
  } else {
    writeTerminal(t("terminalEmptyOutput"));
  }
}

async function waitForTerminalInputIdle() {
  terminalInputQueue.flushBuffer();
  await terminalInputQueue.waitForIdle();
}

function stringResult(value: unknown) {
  return typeof value === "string" ? value : "";
}

function delay(milliseconds: number) {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function findTerminalSelection(workspaceID?: string, surfaceID?: string) {
  return flatSurfaces.value.find((selection) => {
    if (selection.surface.type !== "terminal") return false;
    if (workspaceID && selection.workspace.id !== workspaceID) return false;
    if (surfaceID && selection.surface.id !== surfaceID) return false;
    return true;
  }) || null;
}

function selectCreatedTerminal(workspaceID?: string, surfaceID?: string) {
  const selection = findTerminalSelection(workspaceID, surfaceID);
  if (!selection) {
    ensureSelection();
    setStatus(t("error.createdTerminalNotFound"), true);
    return false;
  }
  selectSurface(selection);
  return true;
}

function requireCreatedTerminal(workspaceID?: string, surfaceID?: string) {
  const selection = findTerminalSelection(workspaceID, surfaceID);
  if (!selection) {
    throw new Error(t("error.createdTerminalNotFound"));
  }
  return selection;
}

function selectSurface(selection: Selection) {
  selectedSurface.value = selection;
  navOpen.value = false;
  readSelectedTerminal().catch(handleRemoteError);
  nextTick(() => {
    fitTerminal();
    terminal?.focus();
  });
}

function surfaceMeta(surface: SurfaceSnapshot) {
  const surfaceType = surface.type || t("tree.surfaceTypeFallback");
  return surface.focused ? `${surfaceType} - ${t("tree.focusedSurface")}` : surfaceType;
}

async function readSelectedTerminal() {
  const selected = selectedSurface.value;
  if (!selected) return;
  const target = currentTargetForSelection(selected);
  const result = await readTerminal(target);
  if (!targetMatchesSelection(target)) return;
  writeTerminal(result.text || t("terminalEmptyOutput"), !result.text);
}

function sendKey(key: string) {
  const target = currentTerminalTarget();
  if (!target) return;
  terminalInputQueue.sendMappedKey(target, key);
}

async function sendTextMutation(target: TerminalInputTarget, text: string) {
  if (!text) return;
  await rpc("surface.send_text", {
    workspace_id: target.workspaceID,
    surface_id: target.surfaceID,
    text,
  });
}

async function sendKeyMutation(target: TerminalInputTarget, key: string) {
  await rpc("surface.send_key", {
    workspace_id: target.workspaceID,
    surface_id: target.surfaceID,
    key,
  });
}

async function readTerminal(target: TerminalInputTarget) {
  return rpc("surface.read_text", {
    workspace_id: target.workspaceID,
    surface_id: target.surfaceID,
    lines: 200,
  });
}

function terminalRuntimeReady(payload: Record<string, unknown>, surfaceID: string) {
  const directSurface = payload.surface as Record<string, unknown> | null | undefined;
  if (directSurface?.id === surfaceID) {
    return directSurface.runtime_ready === true;
  }

  const surfaces = Array.isArray(payload.surfaces) ? payload.surfaces : [];
  return surfaces.some((surface) => {
    const item = surface as Record<string, unknown>;
    return item.id === surfaceID && item.runtime_ready === true;
  });
}

async function waitForTerminalRuntime(workspaceID: string, surfaceID: string) {
  if (!workspaceID || !surfaceID) {
    throw new Error(t("error.createdTerminalNotFound"));
  }

  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const health = await rpc("surface.health", {
      workspace_id: workspaceID,
      surface_id: surfaceID,
    });
    if (terminalRuntimeReady(health, surfaceID)) return;
    await delay(150);
  }
  throw new Error(t("error.createdTerminalNotReady"));
}

async function readSelectedTerminalForTarget(target: TerminalInputTarget) {
  if (!targetMatchesSelection(target)) return;
  await readSelectedTerminal();
}

function currentTerminalTarget() {
  const selected = selectedSurface.value;
  return selected ? currentTargetForSelection(selected) : null;
}

function currentTargetForSelection(selection: Selection): TerminalInputTarget {
  return {
    workspaceID: selection.workspace.id,
    surfaceID: selection.surface.id,
  };
}

function targetMatchesSelection(target: TerminalInputTarget) {
  const selected = selectedSurface.value;
  return Boolean(selected) && targetEquals(currentTargetForSelection(selected), target);
}

function targetEquals(lhs: TerminalInputTarget, rhs: TerminalInputTarget) {
  return lhs.workspaceID === rhs.workspaceID && lhs.surfaceID === rhs.surfaceID;
}

function readSelectedTerminalFromButton() {
  readSelectedTerminal().catch(handleRemoteError);
}

async function createNewSession() {
  if (creatingSession.value) return;
  creatingSession.value = true;
  setStatus(t("status.creatingSession"));
  try {
    await waitForTerminalInputIdle();
    const result = await rpc("workspace.create");
    const workspaceID = stringResult(result?.workspace_id);
    await fetchSnapshot({ showRefreshing: false, updateSelection: false });
    const terminal = requireCreatedTerminal(workspaceID);
    await waitForTerminalRuntime(workspaceID, terminal.surface.id);
    await fetchSnapshot({ showRefreshing: false, updateSelection: false });
    if (selectCreatedTerminal(workspaceID, terminal.surface.id)) {
      setStatus(t("status.sessionCreated"));
    }
  } catch (error) {
    handleRemoteError(error);
  } finally {
    creatingSession.value = false;
  }
}

async function createNewTerminalTab() {
  if (creatingTab.value) return;
  const selection = selectedSurface.value;
  if (!selection) return;

  creatingTab.value = true;
  setStatus(t("status.creatingTab"));
  try {
    await waitForTerminalInputIdle();
    const params: Record<string, unknown> = {
      workspace_id: selection.workspace.id,
      type: "terminal",
      start: true,
    };
    if (selection.pane.id) {
      params.pane_id = selection.pane.id;
    }

    const result = await rpc("surface.create", params);
    const workspaceID = stringResult(result?.workspace_id);
    const surfaceID = stringResult(result?.surface_id);
    await waitForTerminalRuntime(workspaceID, surfaceID);
    await fetchSnapshot({ showRefreshing: false, updateSelection: false });
    if (selectCreatedTerminal(workspaceID, surfaceID)) {
      setStatus(t("status.tabCreated"));
    }
  } catch (error) {
    handleRemoteError(error);
  } finally {
    creatingTab.value = false;
  }
}

function startPolling() {
  stopPolling();
  pollingTimer = window.setInterval(() => {
    if (!document.hidden && selectedSurface.value) {
      readSelectedTerminal().catch(handleRemoteError);
    }
  }, 3000);
}

function stopPolling() {
  if (pollingTimer) window.clearInterval(pollingTimer);
  pollingTimer = null;
}

async function connect() {
  if (!tokenInput.value) return;
  localStorage.setItem(storageKey, tokenInput.value);
  token.value = tokenInput.value;
  try {
    await ensureTerminalInitialized();
    await fetchSnapshot();
    await startEvents();
    startPolling();
  } catch (error) {
    handleRemoteError(error);
  }
}

function forget() {
  localStorage.removeItem(storageKey);
  stopEvents();
  stopPolling();
  deleteEventSession();
  snapshot.value = null;
  selectedSurface.value = null;
  navOpen.value = false;
  clearStatus();
  disposeTerminal();
  token.value = "";
  tokenInput.value = "";
}

function refresh() {
  fetchSnapshot().catch(handleRemoteError);
}

function isMobileTerminalViewport() {
  return window.matchMedia("(max-width: 720px)").matches;
}

function applyTerminalSizing() {
  if (!terminal) return;
  const mobile = isMobileTerminalViewport();
  terminal.options.fontSize = mobile ? 10.5 : 13;
  terminal.options.lineHeight = mobile ? 1.08 : 1.18;
}

function updateVisualViewportHeight() {
  const height = window.visualViewport?.height || window.innerHeight;
  if (height > 0) {
    document.documentElement.style.setProperty("--remote-visual-height", `${Math.round(height)}px`);
  }
}

async function ensureTerminalInitialized() {
  if (terminal) {
    await nextTick();
    applyTerminalSizing();
    fitTerminal();
    return true;
  }

  await nextTick();
  if (!terminalElement.value) return false;

  fitAddon = new FitAddon();
  terminal = new Terminal({
    allowProposedApi: false,
    convertEol: true,
    cursorBlink: true,
    disableStdin: false,
    fontFamily: '"SF Mono", Menlo, Monaco, Consolas, monospace',
    fontSize: isMobileTerminalViewport() ? 10.5 : 13,
    lineHeight: isMobileTerminalViewport() ? 1.08 : 1.18,
    scrollback: 5000,
    theme: {
      background: "#030507",
      foreground: "#e9efe6",
      cursor: "#50e39f",
      selectionBackground: "#294f41",
      black: "#11151a",
      red: "#ff756f",
      green: "#50e39f",
      yellow: "#f0c66a",
      blue: "#63b7ff",
      magenta: "#d58cff",
      cyan: "#54d7d0",
      white: "#e9efe6",
      brightBlack: "#687584",
      brightRed: "#ff9a94",
      brightGreen: "#8af2c1",
      brightYellow: "#f8db90",
      brightBlue: "#9dd0ff",
      brightMagenta: "#e2b4ff",
      brightCyan: "#94ece8",
      brightWhite: "#ffffff",
    },
  });
  terminal.loadAddon(fitAddon);
  terminal.loadAddon(new WebLinksAddon());
  terminal.open(terminalElement.value);
  terminal.onData(handleTerminalData);
  terminalFocusDisposable = terminal.onFocus(handleTerminalFocus);
  terminalBlurDisposable = terminal.onBlur(handleTerminalBlur);
  writeTerminal(t("terminalEmptyOutput"));
  nextTick(fitTerminal);
  return true;
}

function disposeTerminal() {
  terminalInputQueue.dispose();
  terminalFocusDisposable?.dispose();
  terminalBlurDisposable?.dispose();
  terminalFocusDisposable = null;
  terminalBlurDisposable = null;
  terminal?.dispose();
  terminal = null;
  fitAddon = null;
  lastTerminalText = "";
  keyboardActive.value = false;
}

function handleTerminalData(data: string) {
  const target = currentTerminalTarget();
  if (!target) return;
  const input = classifyTerminalData(data);
  switch (input.kind) {
    case "key":
      terminalInputQueue.sendMappedKey(target, input.key);
      break;
    case "text":
      terminalInputQueue.appendText(target, input.text);
      break;
    case "ignore":
      break;
  }
}

function writeTerminal(text: string, isEmpty = false) {
  if (!terminal) return;
  const nextText = text || "";
  if (nextText === lastTerminalText && !isEmpty) return;
  lastTerminalText = nextText;
  terminal.reset();
  terminal.write(normalizeTerminalText(nextText));
  fitTerminal();
}

function normalizeTerminalText(text: string) {
  return text.replace(/\r?\n/g, "\r\n");
}

function fitTerminal() {
  try {
    fitAddon?.fit();
  } catch {
    // xterm can reject fitting before CSS has produced dimensions.
  }
}

function handleResize() {
  updateVisualViewportHeight();
  applyTerminalSizing();
  nextTick(fitTerminal);
}

function keepTerminalVisible() {
  const target = terminalElement.value;
  if (!target) return;
  updateVisualViewportHeight();
  window.setTimeout(() => target.scrollIntoView({ block: "nearest", inline: "nearest" }), 80);
  window.setTimeout(() => {
    updateVisualViewportHeight();
    target.scrollIntoView({ block: "nearest", inline: "nearest" });
    fitTerminal();
  }, 260);
}

function handleTerminalFocus() {
  keyboardActive.value = true;
  keepTerminalVisible();
}

function handleTerminalBlur() {
  keyboardActive.value = false;
  window.setTimeout(handleResize, 120);
}

function focusTerminalInput() {
  terminal?.focus();
  handleTerminalFocus();
}

function handleVisibilityChange() {
  if (!document.hidden && token.value) {
    fetchSnapshot()
      .then(() => {
        if (eventSource) {
          return createEventSession();
        }
        return startEvents();
      })
      .catch(handleRemoteError);
  }
}

watch(selectedSurface, () => nextTick(fitTerminal));
watch(navOpen, () => nextTick(fitTerminal));

onMounted(async () => {
  await loadStrings();
  loadToken();
  updateVisualViewportHeight();
  window.addEventListener("resize", handleResize);
  window.addEventListener("orientationchange", handleResize);
  window.visualViewport?.addEventListener("resize", handleResize);
  window.visualViewport?.addEventListener("scroll", handleResize);
  document.addEventListener("visibilitychange", handleVisibilityChange);
  if (token.value) {
    await ensureTerminalInitialized();
    fetchSnapshot()
      .then(() => {
        startEvents().catch(handleRemoteError);
        startPolling();
      })
      .catch(handleRemoteError);
  }
});

onBeforeUnmount(() => {
  stopEvents();
  stopPolling();
  clearEventSessionRefresh();
  window.removeEventListener("resize", handleResize);
  window.removeEventListener("orientationchange", handleResize);
  window.visualViewport?.removeEventListener("resize", handleResize);
  window.visualViewport?.removeEventListener("scroll", handleResize);
  document.removeEventListener("visibilitychange", handleVisibilityChange);
  disposeTerminal();
});
</script>
