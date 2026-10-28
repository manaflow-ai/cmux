import * as automation from "./automation";
import type { AcpmuxRow } from "./model";
import type { PermissionDecision } from "./permissions/protocol";
import { acpmuxPerf, frameStats, isBlank, median, round2, typingSummary } from "./perf";
import { openPicker, pickerLabels } from "./pickerOpeners";
import { syntheticRows } from "./synthetic";
import { runStream, type StreamOptions } from "./streamDebug";
import { loadRun, loadSeed, type LoadRunOptions } from "./loadDebug";
import { workedTurnRows } from "./workedTurn";
import { incomingRows } from "./incomingFixture";
import { SUBAGENT_TRAY_STEPS, subagentTrayRows } from "./subagentsFixture";
import { SHARED_PRESENCE, sharedRows } from "./multiplayer/sharedFixture";
import { shownPresence } from "./multiplayer/LivePresence";
import { acpWire, type AcpWireLog } from "./wire";
import { followTrace } from "./followTrace";
import { composerChips, layoutWatch, type LayoutWatchOptions } from "./layoutWatch";
import { queuedRowsState } from "./queuedRowsState";

// `window.cmuxAcpmuxDebug`, called by the DEBUG `debug.agent_pane` socket
// method. The first measurement call turns on measurement (acpmuxPerf.enabled);
// until then the pane pays nothing for it. openMenu opens a composer menu for
// automation and captures. `acpLog` and `acpLogExport` read the pane's ACP
// wire log (wire.ts), which is always kept.

export type FlingOptions = { nominal_ms?: number; wait?: boolean };

export type AcpmuxDebug = {
  /// Replaces the transcript with `count` synthetic rows, with the worked turn of
  /// workedTurn.ts when `fixture` is "worked-turn", or with received agent messages
  /// (incomingFixture.ts) when it is "incoming", or with a shared chat (teammates' prompts, who
  /// answered an ask, who else is here and typing; multiplayer/sharedFixture.ts) when it is "shared",
  /// or with step `count` (0-5, else 0) of the subagent tray's life (subagentsFixture.ts) when it is
  /// "subagents".
  seedRows(count?: number, fixture?: string): Promise<Record<string, unknown>>;
  startFling(seconds?: number, options?: FlingOptions): Promise<Record<string, unknown>>;
  flingStats(): Record<string, unknown>;
  perfStats(options?: { raw?: boolean }): Record<string, unknown>;
  agentLatency(): Record<string, unknown>;
  typingStats(): Record<string, unknown>;
  resetTyping(): Record<string, unknown>;
  /// Opens the composer menu labelled `label` and resolves once it has painted.
  openMenu(label: string): Promise<Record<string, unknown>>;
  /** The newest `limit` wire log entries (all when omitted) and the log's stats. */
  acpLog(options?: { limit?: number }): Record<string, unknown>;
  /** The wire log as JSON Lines. */
  acpLogExport(): string;
  /** Automation (automation.ts): the chat state a script reads, and the verbs it drives. */
  chatState(): Record<string, unknown>;
  sendPrompt(text: string): Promise<Record<string, unknown>>;
  newChat(harness?: string, cwd?: string): Promise<Record<string, unknown>>;
  pickFolder(cwd: string): Record<string, unknown>;
  selectSession(sessionId: string): Record<string, unknown>;
  answerPermission(options?: {
    optionId?: string;
    allow?: boolean;
    decision?: PermissionDecision;
  }): Promise<Record<string, unknown>>;
  openChanges(): Record<string, unknown>;
  setModel(model: string, effort?: string): Promise<Record<string, unknown>>;
  models(): Record<string, unknown>;
  /** What moved on the page after it first showed its content, watched for `ms` (layoutWatch.ts). */
  layoutWatch(options?: LayoutWatchOptions): Promise<Record<string, unknown>>;
  /** Streams a scripted reply into a long synthetic transcript and reports the frames (streamDebug.ts). */
  stream(options?: StreamOptions): Promise<Record<string, unknown>>;
  /** Opens a mock session of `turns` heavy turns through the real client (loadDebug.ts). */
  loadSeed(turns?: number): Promise<Record<string, unknown>>;
  /** Streams a turn at full speed into it while scrolling, and reports every frame (loadDebug.ts). */
  loadRun(options?: LoadRunOptions): Promise<Record<string, unknown>>;
};

const NO_AUTOMATION = { error: "the page has no automation host" };

const WARMUP_FRAMES = 30;

/** The open menu's rows: how many, how many show whole in the page, and whether it went past the window. */
function openMenuRows(
  popup = [...document.querySelectorAll<HTMLElement>("[role=menu],[role=listbox]")].at(-1) ?? null,
): Record<string, unknown> | null {
  if (!popup) return null;
  const rows = [...popup.querySelectorAll('[role^="menuitem"],[role=option]')];
  const frame = popup.getBoundingClientRect();
  const top = Math.max(0, frame.top);
  const bottom = Math.min(innerHeight, frame.bottom);
  const whole = rows.filter((row) => {
    const box = row.getBoundingClientRect();
    return box.height > 0 && box.top >= top - 0.5 && box.bottom <= bottom + 0.5;
  });
  const dialog = popup.closest<HTMLElement>("[role=dialog]");
  return {
    rows: rows.length,
    shown_in_page: whole.length,
    height: Math.round(frame.height),
    ...(dialog ? { dialog_height: Math.round(dialog.getBoundingClientRect().height) } : {}),
    // A Base UI menu marks its positioner; a list the page positions itself, itself (popupHost.ts).
    escaped: popup.hasAttribute("data-escaped") || (popup.parentElement?.hasAttribute("data-escaped") ?? false),
  };
}

function nextFrame(): Promise<number> {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

export function createAcpmuxDebug(
  host: {
    replaceRows(rows: AcpmuxRow[]): void;
    rowCount(): number;
    sessionId?(): string | undefined;
    automation?: automation.AutomationHost;
  },
  wire: AcpWireLog = acpWire,
): AcpmuxDebug {
  let timestamps: number[] = [];
  /// The live presence the shared fixture replaced (`null`: the fixture is not shown).
  let beforeShared: ReturnType<typeof shownPresence.get> | null = null;
  let nominal = 1000 / 60;
  let running = false;
  let generation = 0;
  /** How far the last fling scrolled and the view it scrolled, in CSS pixels. */
  let geometry = { distance: 0, viewport: 0 };

  const flingStats = () => {
    if (timestamps.length < 2) return { running, frames: 0 };
    const perFrame = geometry.distance / (timestamps.length - 1);
    return {
      running,
      rows: host.rowCount(),
      ...frameStats(timestamps, nominal),
      distance_px: Math.round(geometry.distance),
      viewport_px: geometry.viewport,
      // The scroll per frame, in viewports: past what the transcript mounts ahead, frames blank.
      viewports_per_frame: geometry.viewport > 0 ? round2(perFrame / geometry.viewport) : 0,
    };
  };

  // The subagents fixture's steps share the time its step 0 began, so its rows keep their places.
  let subagentsAt: number | undefined;
  const trayStep = (count: number) => (Number.isInteger(count) && count > 0 && count < SUBAGENT_TRAY_STEPS ? count : 0);
  const trayOrigin = (count: number) => {
    if (trayStep(count) === 0 || subagentsAt === undefined) subagentsAt = Date.now() - 60_000;
    return subagentsAt;
  };

  return {
    async seedRows(count = 5000, fixture) {
      acpmuxPerf.enable();
      const rows =
        fixture === "subagents"
          ? subagentTrayRows(trayStep(count), trayOrigin(count))
          : fixture === "worked-turn"
            ? workedTurnRows(Date.now() - 60_000)
            : fixture === "incoming"
              ? incomingRows(Date.now() - 120_000)
              : fixture === "shared"
                ? sharedRows(Date.now() - 720_000)
                : syntheticRows(Math.max(3, Math.floor(count)), fixture === "short" ? "short" : "mixed");
      const start = performance.now();
      const committed = acpmuxPerf.nextCommit();
      host.replaceRows(rows);
      if (fixture === "shared") {
        // The presence to restore on leaving: kept across uninterrupted repeat seeds of this chat,
        // taken again once live presence or a switch displaced the fixture. The fixture's own
        // faces over another chat are never a baseline.
        const now = shownPresence.get();
        const sessionId = host.sessionId?.();
        const showing = now?.presence === SHARED_PRESENCE;
        if (beforeShared === null || !showing || now?.sessionId !== sessionId) {
          beforeShared = showing ? undefined : now;
        }
        shownPresence.set(sessionId, SHARED_PRESENCE);
      } else if (beforeShared !== null) {
        // Leaving the shared fixture: its made-up faces go, and the live presence from before
        // comes back unless the chat's own acpmux has set a newer one since.
        if (shownPresence.get()?.presence === SHARED_PRESENCE) {
          shownPresence.set(beforeShared?.sessionId, beforeShared?.presence);
        }
        beforeShared = null;
      }
      const at = await committed;
      return { rows: rows.length, commit_ms: at === undefined ? null : round2(at - start) };
    },

    // Scrolls to the bottom, measures the idle frame interval (unless
    // `nominal_ms` is given), then scrolls linearly from the bottom to the
    // top over `seconds`, one step per animation frame.
    async startFling(seconds = 3, options = {}) {
      acpmuxPerf.enable();
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!scroller) return { error: "no transcript" };
      const run = ++generation;
      const duration = Math.max(0.1, seconds) * 1000;
      timestamps = [];
      running = true;
      acpmuxPerf.resetFrames();
      scroller.scrollTop = scroller.scrollHeight;
      const done = (async () => {
        const warmup: number[] = [];
        for (let frame = 0; frame < WARMUP_FRAMES; frame += 1) warmup.push(await nextFrame());
        if (run !== generation) return;
        nominal =
          options.nominal_ms && options.nominal_ms > 0
            ? options.nominal_ms
            : Math.max(1, median(warmup.slice(1).map((time, index) => time - warmup[index])));
        scroller.scrollTop = scroller.scrollHeight;
        const from = scroller.scrollTop;
        geometry = { distance: from, viewport: scroller.clientHeight };
        acpmuxPerf.resetFrames();
        await new Promise<void>((resolve) => {
          let start: number | undefined;
          const tick = (now: number) => {
            if (run !== generation) return resolve();
            start ??= now;
            timestamps.push(now);
            const progress = Math.min(1, (now - start) / duration);
            scroller.scrollTop = from * (1 - progress);
            acpmuxPerf.markFrame(
              now,
              isBlank(acpmuxPerf.mounted, scroller.scrollTop, scroller.clientHeight, scroller.scrollHeight),
            );
            if (progress < 1) requestAnimationFrame(tick);
            else resolve();
          };
          requestAnimationFrame(tick);
        });
        if (run === generation) running = false;
      })();
      if (options.wait) {
        await done;
        return flingStats();
      }
      return { started: true, rows: host.rowCount(), seconds: duration / 1000 };
    },

    flingStats,

    perfStats(options = {}) {
      acpmuxPerf.enable();
      return {
        running,
        ...acpmuxPerf.stats(options.raw === true),
        agent: acpmuxPerf.agentLatency(),
      };
    },

    agentLatency() {
      return acpmuxPerf.agentLatency();
    },

    typingStats() {
      acpmuxPerf.enable();
      return typingSummary(acpmuxPerf.typing);
    },

    resetTyping() {
      acpmuxPerf.enable();
      acpmuxPerf.typing.length = 0;
      return { keys: 0 };
    },

    // Not a measurement, so it leaves acpmuxPerf off.
    async openMenu(label) {
      // "/" or "@query" types into the prompt, as key presses do: the commands list or the file
      // list opens (the file list once its results arrive).
      if (label.startsWith("/") || label.startsWith("@")) {
        const prompt = document.querySelector<HTMLElement>(
          ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']",
        );
        if (!prompt) return { error: "no prompt" };
        prompt.focus();
        document.execCommand("insertText", false, label);
        const id = label.startsWith("/") ? "acpmux-slash-menu" : "acpmux-mention-menu";
        for (let frame = 0; frame < 300; frame += 1) {
          if (document.querySelector(`#${id} [role=option]`)) break;
          await nextFrame();
        }
        for (let frame = 0; frame < 4; frame += 1) await nextFrame();
        return { opened: label, menu: openMenuRows(document.getElementById(id)) };
      }
      if (!openPicker(label)) return { error: `no menu labelled ${JSON.stringify(label)}`, menus: pickerLabels() };
      await nextFrame();
      await nextFrame();
      const button = [...document.querySelectorAll<HTMLElement>("button[data-menu]")].find(
        (node) => node.dataset.menu === label,
      );
      // The menu may hand its rows to the window's host a frame after it shows (popupHost.ts).
      await nextFrame();
      await nextFrame();
      return { opened: label, open: button?.getAttribute("aria-expanded") === "true", menu: openMenuRows() };
    },

    acpLog(options = {}) {
      const entries = wire.entries();
      const limit = options.limit && options.limit > 0 ? Math.floor(options.limit) : entries.length;
      return { stats: wire.stats(), entries: entries.slice(-limit) };
    },

    acpLogExport() {
      return wire.exportJsonl({ sessionId: host.sessionId?.() });
    },

    chatState() {
      return host.automation
        ? {
            ...automation.automationState(host.automation),
            follow: followTrace.snapshot(),
            // The summary card as drawn (summary/SummaryCard.tsx), and the subagent this pane shows.
            summaryCard: summaryCardState(),
            // The prompts as drawn, top first: who sent each, its bubble, and the collapsed view line.
            userBubbles: userBubblesState(),
            // The queued prompts as drawn: each row's text, its image ids and each thumbnail's state.
            queued: queuedRowsState(),
            subagentOf: document.querySelector(".cv-subagent-of__parent")?.textContent ?? null,
            // The composer's chips as drawn (model, effort, access), keyed by their menu label.
            composer: composerChips(),
            focused: document.hasFocus(),
          }
        : NO_AUTOMATION;
    },
    async sendPrompt(text) {
      return host.automation ? automation.sendPrompt(host.automation, String(text ?? "")) : NO_AUTOMATION;
    },
    async newChat(harness, cwd) {
      return host.automation ? automation.newChat(host.automation, harness, cwd) : NO_AUTOMATION;
    },
    pickFolder(cwd) {
      return host.automation ? automation.pickFolder(host.automation, String(cwd ?? "")) : NO_AUTOMATION;
    },
    selectSession(sessionId) {
      return host.automation ? automation.selectSession(host.automation, String(sessionId ?? "")) : NO_AUTOMATION;
    },
    async answerPermission(options = {}) {
      return host.automation ? automation.answerPermission(host.automation, options) : NO_AUTOMATION;
    },
    openChanges() {
      return host.automation ? automation.openChanges(host.automation) : NO_AUTOMATION;
    },
    async setModel(model, effort) {
      return host.automation
        ? automation.setModel(host.automation, String(model ?? ""), effort || undefined)
        : NO_AUTOMATION;
    },
    models() {
      return host.automation ? automation.models(host.automation) : NO_AUTOMATION;
    },
    layoutWatch(options = {}) {
      return layoutWatch(options);
    },
    stream(options = {}) {
      return runStream(host.replaceRows, options);
    },
    loadSeed(turns = 5000) {
      const automationHost = host.automation;
      if (!automationHost) return Promise.resolve(NO_AUTOMATION);
      return loadSeed({ selectSession: automationHost.selectSession, rowCount: host.rowCount }, turns);
    },
    loadRun(options = {}) {
      return loadRun({ sessionId: () => host.sessionId?.(), rowCount: host.rowCount }, options);
    },
  };
}

/// The prompts as drawn, top first: the "From the Chief" label, the collapsed view line and the bubble.
function userBubblesState() {
  return [...document.querySelectorAll<HTMLElement>(".cv-user")].slice(0, 8).map((row) => ({
    from: row.querySelector(".cv-user__from")?.textContent ?? null,
    context: row.querySelector(".cv-user__context summary")?.textContent ?? null,
    text: (row.querySelector(".cv-user__bubble")?.textContent ?? "").slice(0, 400),
    top: Math.round(row.getBoundingClientRect().top),
  }));
}

/// The summary card's rows as drawn: each subagent's name and status, or null with no card.
function summaryCardState() {
  const card = document.querySelector(".acpmux-summary-card");
  if (!card) return null;
  return {
    collapsed: card.hasAttribute("data-collapsed"),
    agents: [...card.querySelectorAll<HTMLElement>(".acpmux-summary-agent")].map((row) => ({
      name: row.querySelector(".acpmux-summary-agent__name")?.textContent ?? "",
      status: row.dataset.status ?? "",
      current: row.getAttribute("aria-current") === "true",
    })),
  };
}
