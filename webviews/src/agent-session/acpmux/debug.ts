import { debugAnswer, debugChangesRow, type DebugDecision } from "./debugActions";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import type { PermissionDecision } from "./permissions/protocol";
import { acpmuxPerf, frameStats, isBlank, median, round2, typingSummary } from "./perf";
import { openPicker, pickerLabels } from "./pickerOpeners";
import { syntheticRows } from "./synthetic";
import { acpWire, type AcpWireLog } from "./wire";

// `window.cmuxAcpmuxDebug`, called by the DEBUG `debug.agent_pane` socket
// method. The first measurement call turns on measurement (acpmuxPerf.enabled);
// until then the pane pays nothing for it. openMenu opens a composer menu for
// automation and captures. `acpLog` and `acpLogExport` read the pane's ACP
// wire log (wire.ts), which is always kept. sendPrompt, selectSession,
// answerPermission and openChanges drive the chat through the same paths as
// the composer, the session list, a permission card and an edited-files card,
// so automation reaches them when the window is not key and keys can't.

export type FlingOptions = { nominal_ms?: number; wait?: boolean };

export type AcpmuxDebug = {
  seedRows(count?: number): Promise<Record<string, unknown>>;
  startFling(seconds?: number, options?: FlingOptions): Promise<Record<string, unknown>>;
  flingStats(): Record<string, unknown>;
  perfStats(options?: { raw?: boolean }): Record<string, unknown>;
  typingStats(): Record<string, unknown>;
  resetTyping(): Record<string, unknown>;
  /// Opens the composer menu labelled `label` and resolves once it has painted.
  openMenu(label: string): Promise<Record<string, unknown>>;
  /** The newest `limit` wire log entries (all when omitted) and the log's stats. */
  acpLog(options?: { limit?: number }): Record<string, unknown>;
  /** The wire log as JSON Lines. */
  acpLogExport(): string;
  /** Sends `text` as the composer's Send does, into the open chat or a new one. */
  sendPrompt(text: string): Promise<Record<string, unknown>>;
  /** Switches to the session, as picking it in the session list does; resolves once it shows. */
  selectSession(sessionId: string): Promise<Record<string, unknown>>;
  /** Answers a pending permission (debugActions.ts picks which, and with what). */
  answerPermission(options?: DebugAnswerOptions): Promise<Record<string, unknown>>;
  /** Opens the Changes view of a turn (the newest that changed files by default), at `path`. */
  openChanges(options?: { row_id?: string; path?: string }): Promise<Record<string, unknown>>;
};

export type DebugAnswerOptions = {
  permission_id?: string;
  group_id?: string;
  option_id?: string;
  decision?: DebugDecision;
};

/// The pane's own paths that the chat actions call.
export type DebugChatHost = {
  snapshot(): AcpmuxSnapshot | undefined;
  /// The composer's send: settles when the turn ends, and rejects when it fails or acpmux is
  /// not connected.
  send(text: string): Promise<unknown>;
  /// The session list's select: settles once the session is attached and its transcript read.
  select(sessionId: string): Promise<unknown>;
  answer(permissionId: string, optionId: string): Promise<unknown>;
  respondGroup(groupId: string, revision: number, decision: PermissionDecision): Promise<unknown>;
  openChanges(rowId: string, path?: string): void;
  /// The turn whose Changes view shows, if any.
  changesRow(): string | undefined;
};

/// Resolves true once `done()` holds, checking every 16 ms (a timer, so it also runs while
/// WebKit throttles frames in a covered window), or false after `ms`.
async function until(done: () => boolean, ms: number): Promise<boolean> {
  const start = Date.now();
  while (!done()) {
    if (Date.now() - start > ms) return false;
    await new Promise((resolve) => setTimeout(resolve, 16));
  }
  return true;
}

const WARMUP_FRAMES = 30;

function nextFrame(): Promise<number> {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

export function createAcpmuxDebug(
  host: {
    replaceRows(rows: AcpmuxRow[]): void;
    rowCount(): number;
    sessionId?(): string | undefined;
    chat?: DebugChatHost;
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
    async seedRows(count = 5000) {
      acpmuxPerf.enable();
      const rows = syntheticRows(Math.max(3, Math.floor(count)));
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
      return { running, ...acpmuxPerf.stats(options.raw === true) };
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

    // Returns once the prompt shows as the chat's newest user row, not when the turn ends: a
    // turn can run for minutes, or wait on a permission the caller answers next.
    async sendPrompt(text) {
      const chat = host.chat;
      if (!chat) return { error: "this page has no chat" };
      if (!text.trim()) return { error: "empty prompt" };
      const before = chat.snapshot()?.rows.filter((row) => row.kind === "user").length ?? 0;
      let failure: string | undefined;
      chat.send(text).catch((error: unknown) => {
        failure = String(error instanceof Error ? error.message : error);
      });
      const shown = await until(() => {
        if (failure) return true;
        const users = chat.snapshot()?.rows.filter((row) => row.kind === "user") ?? [];
        return users.length > before && users.at(-1)?.text?.trim() === text.trim();
      }, 10_000);
      if (failure) return { error: failure };
      return { sent: shown, session: chat.snapshot()?.sessionId ?? null };
    },

    async selectSession(sessionId) {
      const chat = host.chat;
      if (!chat) return { error: "this page has no chat" };
      // The list may not hold every session (it pages), so an unlisted id is still tried.
      const listed = chat.snapshot()?.sessions.some((session) => session.sessionId === sessionId) ?? false;
      try {
        await chat.select(sessionId);
      } catch (error) {
        return { error: String(error instanceof Error ? error.message : error), listed };
      }
      const snapshot = chat.snapshot();
      return {
        selected: sessionId,
        listed,
        shown: snapshot?.sessionId === sessionId,
        rows: snapshot?.rows.length ?? 0,
      };
    },

    async answerPermission(options = {}) {
      const chat = host.chat;
      const snapshot = chat?.snapshot();
      if (!chat || !snapshot) return { error: "this page has no chat" };
      const answer = debugAnswer(snapshot, options);
      if ("error" in answer) return answer;
      try {
        if (answer.kind === "group") await chat.respondGroup(answer.groupId, answer.revision, answer.decision);
        else await chat.answer(answer.permissionId, answer.optionId);
      } catch (error) {
        return { error: String(error instanceof Error ? error.message : error) };
      }
      return { answered: answer };
    },

    async openChanges(options = {}) {
      const chat = host.chat;
      const snapshot = chat?.snapshot();
      if (!chat || !snapshot) return { error: "this page has no chat" };
      const row = debugChangesRow(snapshot.rows, options.row_id);
      if (!row) return { error: options.row_id ? `no row ${options.row_id}` : "no turn in this chat changed files" };
      chat.openChanges(row.id, options.path);
      const open = await until(
        () => chat.changesRow() === row.id && globalThis.document?.querySelector(".acpmux-diff-panel") != null,
        2000,
      );
      return { row: row.id, open };
    },
  };
}
