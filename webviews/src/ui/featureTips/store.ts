// Where feature tips keep their state (leo-workspace design/feature-tips.md, "State").
//
// - For good (a tip closed, its feature used, the launches it showed on): the app, through the
//   page's host (`TipHost`); an agent page's own storage ends with the launch.
// - For this launch (which tip the launch showed, and which page shows it now): the pages' shared
//   storage. Every agent page of a launch shares one web data store that is not persistent
//   (AgentPaneView+Warmup.swift), so it holds exactly one launch: the one-tip-per-launch budget
//   needs no host state, and a `storage` event tells the other pages at once.
import type { LaunchTip, TipRecord, TipRecords } from "./policy";

/** The app's tip records. `read` rejects on a host that keeps none. */
export interface TipHost {
  read(): Promise<TipRecords>;
  write(id: string, record: TipRecord): Promise<TipRecords | void>;
}

/** This launch's tip, shared by the launch's pages. */
export interface LaunchStore {
  get(): LaunchTip | null;
  /** Takes the launch's one tip for `page`; false when the launch already showed one. */
  claim(id: string, page: string): boolean;
  /** The tip is put away (it stays this launch's tip). */
  release(page: string): void;
  subscribe(listener: () => void): () => void;
}

export const LAUNCH_KEY = "cmux.featureTips.launch";

function parse(text: string | null): LaunchTip | null {
  if (!text) return null;
  try {
    const value = JSON.parse(text) as Partial<LaunchTip>;
    return typeof value.id === "string"
      ? { id: value.id, page: typeof value.page === "string" ? value.page : null }
      : null;
  } catch {
    return null;
  }
}

/** The launch store on a page's `Storage` (localStorage). Without one, a page keeps it alone. */
export function storageLaunchStore(storage: Storage | undefined, target: EventTarget | undefined): LaunchStore {
  let own: LaunchTip | null = null;
  const read = () => (storage ? parse(storage.getItem(LAUNCH_KEY)) : own);
  const write = (tip: LaunchTip) => {
    own = tip;
    try {
      storage?.setItem(LAUNCH_KEY, JSON.stringify(tip));
    } catch {
      // A full or refused store: this page still keeps the launch's tip.
    }
  };
  return {
    get: () => read() ?? own,
    claim(id, page) {
      if (read() ?? own) return false;
      write({ id, page });
      // Another page that wrote between the read and the write wins (the last write).
      const winner: LaunchTip | null = read() ?? own;
      return winner?.page === page;
    },
    release(page) {
      const tip = read() ?? own;
      if (tip && tip.page === page) write({ id: tip.id, page: null });
    },
    subscribe(listener) {
      if (!target) return () => undefined;
      const onStorage = (event: Event) => {
        if ((event as StorageEvent).key === LAUNCH_KEY) listener();
      };
      target.addEventListener("storage", onStorage);
      return () => target.removeEventListener("storage", onStorage);
    },
  };
}

/** A store kept in memory: tests and the gallery. */
export function memoryLaunchStore(): LaunchStore {
  return storageLaunchStore(undefined, undefined);
}

/** A host kept in memory: tests and the gallery. */
export function memoryTipHost(initial: TipRecords = {}): TipHost & { records: Record<string, string> } {
  const records: Record<string, string> = { ...initial };
  return {
    records,
    read: async () => ({ ...records }),
    write: async (id, record) => {
      records[id] = record;
      return { ...records };
    },
  };
}
