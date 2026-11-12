// Harness updates available (Leo 2026-11-12, ask-3fdf0982ec, from a reference popover listing
// Codex and OpenCode: "we might as well keep a note of this for Claude and other sources too").
// Every agent CLI on this Mac that acpmux found outdated (`_acpmux/harness/health`), not only the
// chat's own: its version and the newest, Update on each, Update all, drawn in the model menus'
// update footer where the chat's own offer was. Never a banner or a dot (hq#2569 #12).
//
// The chat's own agent keeps its offer (UpdateOffer: the composer's notice runs it and then offers
// Restart Chat, and Skip This Version). Any other agent updates in place through the host's
// `harness.update {id}`; nothing of its runs here, so no restart follows.
import { createContext, useCallback, useContext, useMemo, useRef, useState } from "react";
import { type HarnessHealth, skipped, type UpdateOffer } from "./harnessHealthNoticeModel";

/// One agent CLI with an update, as a menu row shows it.
export type HarnessUpdateRow = {
  harness: string;
  agent: string;
  version: string;
  latest: string;
  /// The update this list started is running, or failed (the updater's words in `error`).
  phase?: "updating" | "failed";
  error?: string;
  update(): void;
  /// Skip This Version: the chat's own agent only, as before.
  skip?(): void;
};

export type HarnessUpdates = {
  rows: HarnessUpdateRow[];
  /// Starts every row's update that is not already running.
  updateAll(): void;
};

export const HarnessUpdatesContext = createContext<HarnessUpdates | undefined>(undefined);

export const useHarnessUpdates = () => useContext(HarnessUpdatesContext);

/// The rows of `_acpmux/harness/health` the list offers: outdated, both versions known, an update
/// that needs no sudo (that one is Settings > Agents', which shows its command), and a newest
/// version the person did not skip. `except` is the chat's own agent, offered by its UpdateOffer.
export function outdatedHarnesses(
  rows: readonly unknown[],
  skippedVersions: Record<string, string>,
  except?: string,
): HarnessHealth[] {
  const out: HarnessHealth[] = [];
  for (const row of rows) {
    const health = row as HarnessHealth | null;
    if (!health || typeof health.id !== "string" || health.id === except) continue;
    if (!health.outdated || !health.version || !health.latest) continue;
    if (!health.update || health.update.elevated) continue;
    if (skippedVersions[health.id] === health.latest) continue;
    out.push(health);
  }
  return out;
}

type Progress = Record<string, { latest: string; phase: "updating" | "failed" | "done"; error?: string }>;

const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {};

/// The list for the menus: the chat's own offer first, then every other outdated agent.
/// `native` is the host's `harness.update {id}` -> `{ok, version?, error?}`; `onUpdated` reads the
/// health rows again once one finished, so its row leaves for good.
export function useHarnessUpdateList({
  rows,
  offer,
  own,
  nameFor,
  native,
  onUpdated,
}: {
  rows: readonly unknown[];
  offer: UpdateOffer | undefined;
  own: string | undefined;
  nameFor(id: string): string;
  native(method: string, params: Record<string, unknown>): Promise<unknown>;
  onUpdated(): void;
}): HarnessUpdates | undefined {
  const [progress, setProgress] = useState<Progress>({});
  const updated = useRef(onUpdated);
  updated.current = onUpdated;
  const start = useCallback(
    (id: string, latest: string) => {
      setProgress((now) => ({ ...now, [id]: { latest, phase: "updating" } }));
      const failed = (error: string) => setProgress((now) => ({ ...now, [id]: { latest, phase: "failed", error } }));
      native("harness.update", { id }).then(
        (value) => {
          const reply = record(value);
          if (reply.ok !== true) return failed(typeof reply.error === "string" ? reply.error.trim() : "");
          setProgress((now) => ({ ...now, [id]: { latest, phase: "done" } }));
          updated.current();
        },
        (error: unknown) => failed(error instanceof Error ? error.message.trim() : ""),
      );
    },
    [native],
  );
  const list = useMemo<HarnessUpdateRow[]>(() => {
    const out: HarnessUpdateRow[] = [];
    if (offer)
      out.push({
        harness: offer.harness,
        agent: offer.agent,
        version: offer.version,
        latest: offer.latest,
        update: offer.update,
        skip: offer.skip,
      });
    for (const health of outdatedHarnesses(rows, skipped(), own ?? offer?.harness)) {
      const id = health.id;
      const latest = health.latest ?? "";
      // A row's progress holds only for the version it was started for.
      const state = progress[id]?.latest === latest ? progress[id] : undefined;
      // Updated: hidden until the health read again says it is current (or names a newer one).
      if (state?.phase === "done") continue;
      out.push({
        harness: id,
        agent: nameFor(id),
        version: health.version ?? "",
        latest,
        ...(state ? { phase: state.phase } : {}),
        ...(state?.error ? { error: state.error } : {}),
        update: () => start(id, latest),
      });
    }
    return out;
  }, [rows, offer, own, progress, nameFor, start]);
  return useMemo(
    () =>
      list.length === 0
        ? undefined
        : { rows: list, updateAll: () => list.forEach((row) => row.phase !== "updating" && row.update()) },
    [list],
  );
}
