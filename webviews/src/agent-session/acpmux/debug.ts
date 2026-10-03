import * as automation from "./automation";
import type { AcpmuxRow } from "./model";
import type { PermissionDecision } from "./permissions/protocol";
import { acpmuxPerf, frameStats, isBlank, median, round2, typingSummary } from "./perf";
import { openPicker, pickerLabels } from "./pickerOpeners";
import { syntheticRows } from "./synthetic";
import { workedTurnRows } from "./workedTurn";
import { acpWire, type AcpWireLog } from "./wire";

// `window.cmuxAcpmuxDebug`, called by the DEBUG `debug.agent_pane` socket
// method. The first measurement call turns on measurement (acpmuxPerf.enabled);
// until then the pane pays nothing for it. openMenu opens a composer menu for
// automation and captures. `acpLog` and `acpLogExport` read the pane's ACP
// wire log (wire.ts), which is always kept.

export type FlingOptions = { nominal_ms?: number; wait?: boolean };

export type AcpmuxDebug = {
  /// Replaces the transcript with `count` synthetic rows, or with the worked turn of
  /// workedTurn.ts when `fixture` is "worked-turn".
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
  selectSession(sessionId: string): Record<string, unknown>;
  answerPermission(options?: {
    optionId?: string;
    allow?: boolean;
    decision?: PermissionDecision;
  }): Promise<Record<string, unknown>>;
  openChanges(): Record<string, unknown>;
  setModel(model: string, effort?: string): Promise<Record<string, unknown>>;
  models(): Record<string, unknown>;
};

const NO_AUTOMATION = { error: "the page has no automation host" };

const WARMUP_FRAMES = 30;

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
  let nominal = 1000 / 60;
  let running = false;
  let generation = 0;

  const flingStats = () => {
    if (timestamps.length < 2) return { running, frames: 0 };
    return { running, rows: host.rowCount(), ...frameStats(timestamps, nominal) };
  };

  return {
    async seedRows(count = 5000, fixture) {
      acpmuxPerf.enable();
      const rows =
        fixture === "worked-turn" ? workedTurnRows(Date.now() - 60_000) : syntheticRows(Math.max(3, Math.floor(count)));
      const start = performance.now();
      const committed = acpmuxPerf.nextCommit();
      host.replaceRows(rows);
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
              isBlank(
                acpmuxPerf.mountedTop,
                acpmuxPerf.mountedBottom,
                scroller.scrollTop,
                scroller.clientHeight,
                scroller.scrollHeight,
              ),
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
      return { running, ...acpmuxPerf.stats(options.raw === true), agent: acpmuxPerf.agentLatency() };
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
      if (!openPicker(label)) return { error: `no menu labelled ${JSON.stringify(label)}`, menus: pickerLabels() };
      await nextFrame();
      await nextFrame();
      const button = [...document.querySelectorAll<HTMLElement>("button[data-menu]")].find(
        (node) => node.dataset.menu === label,
      );
      return { opened: label, open: button?.getAttribute("aria-expanded") === "true" };
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
      return host.automation ? automation.automationState(host.automation) : NO_AUTOMATION;
    },
    async sendPrompt(text) {
      return host.automation ? automation.sendPrompt(host.automation, String(text ?? "")) : NO_AUTOMATION;
    },
    async newChat(harness, cwd) {
      return host.automation ? automation.newChat(host.automation, harness, cwd) : NO_AUTOMATION;
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
  };
}
