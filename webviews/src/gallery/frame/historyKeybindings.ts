import { HostError, installMockHost, type HostOp } from "../../../test/latency/mock-host";
import type { HistoryPageVariant, KeybindingsPageVariant } from "../format";
import type { StageContext } from "./context";
import { HistoryOps, type HistoryEntry } from "../../pages/history/types";
import { HISTORY_FILTERS, type HistoryFilter } from "../../pages/history/model";
import { KeybindingOps } from "../../pages/keybindings/types";
const never = (): Promise<never> => new Promise(() => undefined);

function historyError(state: HistoryPageVariant): HostError | undefined {
  switch (state.error) {
    case "network":
      return new HostError("cmux.protocol.closed", "history is unavailable");
    case "permission":
      return new HostError("cmux.history.permission_denied", "history cannot be changed");
    case "not-found":
      return new HostError("cmux.history.not_found", "the history owner was not found");
    default:
      return undefined;
  }
}

function historyMatches(entry: HistoryEntry, params: { kinds?: string[]; text?: string }): boolean {
  if (params.kinds?.length && !params.kinds.includes(entry.kind)) return false;
  const query = (params.text ?? "").trim().toLocaleLowerCase();
  return (
    !query ||
    [entry.title, entry.detail, entry.cwd, entry.command, entry.workspace]
      .filter(Boolean)
      .join(" ")
      .toLocaleLowerCase()
      .includes(query)
  );
}

export function historyFixtureOps(state: HistoryPageVariant, changed: () => void = () => {}): Record<string, HostOp> {
  let entries = [...(state.entries ?? [])];
  const failure = historyError(state);
  return {
    [HistoryOps.list]: (params: { kinds?: string[]; text?: string; limit?: number }) => {
      if (state.loading) return never();
      if (failure && state.error !== "permission") throw failure;
      return {
        entries: entries.filter((entry) => historyMatches(entry, params)).slice(0, params.limit ?? 200),
        revision: 1,
      };
    },
    [HistoryOps.remove]: (params: { ids: string[] }) => {
      if (state.error === "permission")
        throw new HostError("cmux.history.permission_denied", "history cannot be changed");
      const ids = new Set(params.ids);
      const before = entries.length;
      entries = entries.filter((entry) => !ids.has(entry.id));
      if (before !== entries.length) changed();
      return { removed: before - entries.length };
    },
    [HistoryOps.removeSite]: () => ({ removed: 0 }),
    [HistoryOps.clear]: () => ({ removed: 0 }),
    ["cmux.app.action.run"]: () => ({}),
    ["cmux.app.clipboard.write"]: () => ({}),
  };
}

export async function mountHistoryPage(state: HistoryPageVariant, _context: StageContext): Promise<void> {
  const host = installMockHost(
    historyFixtureOps(state, () => host.emit(HistoryOps.changed, { revision: 2, kinds: [] })),
    [HistoryOps.changed, "cmux.page.connection", "cmux.page.command"] as const,
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "history";
  root.dataset.cmuxWebviewKind = "history";
  await import("../../pages/history/main");
  const query = state.query;
  if (query) {
    window.setTimeout(() => {
      const input = document.querySelector<HTMLInputElement>(".history-search");
      if (query.text !== undefined && input) {
        input.value = query.text;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (query.filter) {
        const index = (HISTORY_FILTERS as readonly HistoryFilter[]).indexOf(query.filter);
        document.querySelectorAll<HTMLButtonElement>(".history-chip")[index]?.click();
      }
      if (query.selectIndex !== undefined || query.menuIndex !== undefined) {
        window.setTimeout(() => {
          const rows = document.querySelectorAll<HTMLElement>(".history-row");
          const index = query.menuIndex ?? query.selectIndex!;
          const row = rows[index];
          if (!row) return;
          if (query.menuIndex !== undefined)
            row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, clientX: 220, clientY: 180 }));
          else row.click();
        }, 100);
      }
    }, 100);
  }
}

function keybindingsError(state: KeybindingsPageVariant): HostError | undefined {
  switch (state.error) {
    case "network":
      return new HostError("cmux.protocol.closed", "keybindings are unavailable");
    case "unsupported":
      return new HostError("cmux.keybindings.unsupported", "keybindings.json writing is not supported yet");
    case "not-found":
      return new HostError("cmux.keybindings.keymap_failed", "the keymap file was not found");
    default:
      return undefined;
  }
}

export function keybindingsFixtureOps(state: KeybindingsPageVariant): Record<string, HostOp> {
  let bindings = [...(state.bindings ?? [])];
  const failure = keybindingsError(state);
  return {
    [KeybindingOps.list]: () => {
      if (state.loading) return never();
      if (failure && state.error === "network") throw failure;
      return { bindings };
    },
    [KeybindingOps.set]: () => {
      if (failure && state.error !== "not-found") throw failure;
      return {};
    },
    [KeybindingOps.remove]: () => {
      if (failure && state.error !== "not-found") throw failure;
      return {};
    },
    [KeybindingOps.reset]: () => {
      if (failure && state.error !== "not-found") throw failure;
      return {};
    },
    [KeybindingOps.recordStart]: () => ({}),
    [KeybindingOps.recordStop]: () => ({}),
    [KeybindingOps.keymapExport]: () => {
      if (failure && state.error === "not-found") throw failure;
      return { path: "/Users/you/Downloads/cmux-keymap.json" };
    },
    [KeybindingOps.keymapImport]: () => {
      if (failure && state.error === "not-found") throw failure;
      return { path: "/Users/you/Downloads/cmux-keymap.json" };
    },
  };
}

export async function mountKeybindingsPage(state: KeybindingsPageVariant, _context: StageContext): Promise<void> {
  const host = installMockHost(keybindingsFixtureOps(state), [
    KeybindingOps.changed,
    KeybindingOps.recorded,
    "cmux.page.connection",
    "cmux.page.command",
  ] as const);
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "keybindings";
  root.dataset.cmuxWebviewKind = "keybindings";
  await import("../../pages/keybindings/main");
  const query = state.query;
  if (query) {
    window.setTimeout(() => {
      const input = document.querySelector<HTMLInputElement>(".keys-search");
      if (query.text !== undefined && input) {
        input.value = query.text;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (query.conflictsOnly) document.querySelector<HTMLButtonElement>(".keys-conflicts-only")?.click();
      window.setTimeout(() => {
        const rows = document.querySelectorAll<HTMLTableRowElement>(".keys-row");
        if (query.selectIndex !== undefined) rows[query.selectIndex]?.click();
        if (query.editIndex !== undefined)
          rows[query.editIndex]?.querySelector<HTMLButtonElement>(".keys-when")?.click();
        if (query.record) document.querySelector<HTMLButtonElement>(".keys-record")?.click();
      }, 100);
    }, 100);
  }
}
