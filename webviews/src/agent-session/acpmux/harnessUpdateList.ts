// Harness updates available (Leo 2026-11-12, ask-3fdf0982ec, from a reference popover listing
// Codex and OpenCode: "we might as well keep a note of this for Claude and other sources too").
// Every agent CLI on this Mac that acpmux found outdated (`_acpmux/harness/health`), not only the
// chat's own: its version and the newest, Update on each, Update all, drawn in the model menus'
// update footer where the chat's own offer was. Never a banner or a dot (hq#2569 #12).
//
// The chat's own agent keeps its offer (UpdateOffer: the composer's notice runs it and then offers
// Restart Chat, and Skip This Version). Any other agent updates in place through the host's
// `harness.update {id}`; nothing of its runs here, so no restart follows.
import { createContext, useCallback, useContext, useMemo, useState } from "react";
import { agentKey } from "../shared/agentKey";
import { type HarnessHealth, skipped, type UpdateOffer } from "./harnessHealthNoticeModel";
import { installName, oneRowPerInstall, sameInstall } from "./harnessInstalls";

/// One agent CLI with an update, as a menu row shows it.
export type HarnessUpdateRow = {
  harness: string;
  agent: string;
  version: string;
  latest: string;
  /// The update this list started is running, or failed (the updater's words go to the log).
  phase?: "updating" | "failed";
  update(): void;
  /// Starts it on its answer from Update all's one `harness.update {ids}` call.
  updateWith?(reply: Promise<unknown>): void;
  /// Skip This Version: the chat's own agent only, as before.
  skip?(): void;
};

export type HarnessUpdates = {
  rows: HarnessUpdateRow[];
  /// Starts every row's update that is not already running, in one host call: the host spends the
  /// person's click on its first `harness.update`, so one call per row would run only the first.
  updateAll(): void;
};

export const HarnessUpdatesContext = createContext<HarnessUpdates | undefined>(undefined);

export const useHarnessUpdates = () => useContext(HarnessUpdatesContext);

/// The rows of `_acpmux/harness/health` the list offers, one per installed binary
/// (harnessInstalls.ts): outdated, both versions known, an update that needs no sudo (that one is
/// Settings > Agents', which shows its command), and a newest version the person did not skip for
/// any profile of that binary. `except` is the chat's own agent, offered by its UpdateOffer: no
/// profile of its binary is listed again. `offered`: whether the menus offer a harness; a binary no
/// offered harness runs is not listed, and an offered one names a shared binary's row.
export function outdatedHarnesses(
  rows: readonly unknown[],
  skippedVersions: Record<string, string>,
  except?: string,
  offered: (id: string) => boolean = () => true,
): HarnessHealth[] {
  const health = rows.filter((row): row is HarnessHealth => !!row && typeof (row as HarnessHealth).id === "string");
  const own = except === undefined ? undefined : health.find((row) => row.id === except);
  const due = health.filter(
    (row) => row.outdated && !!row.version && !!row.latest && !!row.update && !row.update.elevated,
  );
  return oneRowPerInstall(due, (row) => offered(row.id)).filter((row) => {
    const profiles = due.filter((other) => sameInstall(other, row));
    if (profiles.some((other) => other.id === except || (own && sameInstall(other, own)))) return false;
    if (profiles.some((other) => skippedVersions[other.id] === other.latest)) return false;
    return profiles.some((other) => offered(other.id));
  });
}

type Progress = Record<string, { latest: string; phase: "updating" | "failed" | "done" }>;

const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {};

/// Update all's one answer (`{results: [{id, ok, version?, error?}]}`) as `id`'s own, in the shape
/// `harness.update {id}` answers; a failed call fails every row with its words.
export function answerFor(batch: Promise<unknown>, id: string): Promise<unknown> {
  return batch.then((value) => {
    const results = record(value).results;
    const row = Array.isArray(results) ? results.find((entry) => record(entry).id === id) : undefined;
    return row ?? { ok: false };
  });
}

/// The list for the menus: the chat's own offer first, then every other outdated agent.
/// `native` is the host's `harness.update {id}` -> `{ok, version?, error?}` (or `{ids}` ->
/// `{results}`); `onUpdated` (stable, as `native` is) reads the health rows again once one
/// finished, so its row leaves for good. `offered` says whether the model menus offer a harness:
/// a binary only one they do not offer runs is not listed. Two profiles of one binary (acpmux's
/// hidden `cmux` router fallback runs Claude Code's own `claude`) are one row, named for the binary
/// (harnessInstalls.ts). Two rows of one brand ("opencode", "opencode-v2") never share a name.
export function useHarnessUpdateList({
  rows,
  offer,
  own,
  nameFor,
  native,
  onUpdated,
  offered = () => true,
}: {
  rows: readonly unknown[];
  offer: UpdateOffer | undefined;
  own: string | undefined;
  nameFor(id: string): string;
  offered?: (id: string) => boolean;
  native(method: string, params: Record<string, unknown>): Promise<unknown>;
  onUpdated(): void;
}): HarnessUpdates | undefined {
  const [progress, setProgress] = useState<Progress>({});
  const start = useCallback(
    (id: string, latest: string, reply?: Promise<unknown>) => {
      setProgress((now) => ({ ...now, [id]: { latest, phase: "updating" } }));
      // The row says the update failed in plain words; the updater's own text goes to the log.
      const failed = (error: unknown) => {
        console.warn(`agent pane: updating ${id} failed`, error);
        setProgress((now) => ({ ...now, [id]: { latest, phase: "failed" } }));
      };
      (reply ?? native("harness.update", { id })).then(
        (value) => {
          const reply = record(value);
          if (reply.ok !== true) return failed(reply.error);
          setProgress((now) => ({ ...now, [id]: { latest, phase: "done" } }));
          onUpdated();
        },
        (error: unknown) => failed(error),
      );
    },
    [native, onUpdated],
  );
  const list = useMemo<HarnessUpdateRow[]>(() => {
    const out: HarnessUpdateRow[] = [];
    const ownRow = offer
      ? (rows as readonly (HarnessHealth | null)[]).find((row) => row?.id === offer.harness)
      : undefined;
    if (offer)
      out.push({
        harness: offer.harness,
        agent: ownRow ? installName(ownRow, () => offer.agent) : offer.agent,
        version: offer.version,
        latest: offer.latest,
        update: offer.update,
        ...(offer.updateWith ? { updateWith: offer.updateWith } : {}),
        skip: offer.skip,
      });
    for (const health of outdatedHarnesses(rows, skipped(), own ?? offer?.harness, offered)) {
      const id = health.id;
      const latest = health.latest ?? "";
      // A row's progress holds only for the version it was started for.
      const state = progress[id]?.latest === latest ? progress[id] : undefined;
      // Updated: hidden until the health read again says it is current (or names a newer one).
      if (state?.phase === "done") continue;
      out.push({
        harness: id,
        agent: installName(health, nameFor),
        version: health.version ?? "",
        latest,
        ...(state ? { phase: state.phase } : {}),
        update: () => start(id, latest),
        updateWith: (reply) => start(id, latest, reply),
      });
    }
    return distinctNames(out);
  }, [rows, offer, own, progress, nameFor, start, offered]);
  return useMemo(() => {
    if (list.length === 0) return undefined;
    const updateAll = () => {
      // An own offer that cannot take Update all's answer (one with no updateWith) asks for itself.
      const alone = list.filter((row) => row.phase !== "updating" && !row.updateWith);
      const due = list.filter((row) => row.phase !== "updating" && row.updateWith);
      if (due.length > 0) {
        const batch = native("harness.update", { ids: due.map((row) => row.harness) });
        for (const row of due) row.updateWith?.(answerFor(batch, row.harness));
      }
      for (const row of alone) row.update();
    };
    return { rows: list, updateAll };
  }, [list, native]);
}

/// The rows with each name once: a row whose name another shares is named with what its id adds to
/// its brand, as the model picker's rail names it ("opencode-v2" is "OpenCode (v2)"), else its id.
function distinctNames(rows: HarnessUpdateRow[]): HarnessUpdateRow[] {
  const count = new Map<string, number>();
  for (const row of rows) count.set(row.agent, (count.get(row.agent) ?? 0) + 1);
  return rows.map((row) => {
    if ((count.get(row.agent) ?? 0) < 2) return row;
    const base = agentKey(row.harness) ?? "";
    const suffix = row.harness.toLowerCase().startsWith(base)
      ? row.harness.slice(base.length).replace(/^[-_\s]+/, "")
      : row.harness;
    return suffix ? { ...row, agent: `${row.agent} (${suffix})` } : row;
  });
}
