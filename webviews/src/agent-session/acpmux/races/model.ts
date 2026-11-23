import type { AcpmuxSnapshot } from "../model";

export type RaceTarget = { harness: string; model?: string; effort?: string };
export type RaceCandidate = {
  id: string;
  target: RaceTarget;
  sessionId?: string;
  state: "pending" | "running" | "completed" | "failed" | "discarded";
  cwd?: string;
  reply?: string;
  error?: string;
};
export type RaceRecord = {
  id: string;
  parent: string;
  prompt: string;
  state: "running" | "reviewing" | "completed" | "failed" | "cancelled";
  candidates: RaceCandidate[];
  reviewerSessionId?: string;
  winnerId?: string;
  reason?: string;
  createdAt: number;
  updatedAt: number;
};
export type RaceStart = {
  parent: string;
  prompt: string;
  candidates: RaceTarget[];
  reviewer: RaceTarget;
};
export type RaceClient = {
  startRace(request: RaceStart): Promise<RaceRecord>;
  getRace(parent: string, raceId: string): Promise<RaceRecord>;
  getRaceStats(parent: string): Promise<unknown>;
  listRaces(parent: string): Promise<RaceRecord[]>;
  cancelRace(parent: string, raceId: string): Promise<RaceRecord>;
  watchRaces(listener: (race: RaceRecord) => void): () => void;
};

export function newerRace(previous: RaceRecord | undefined, next: RaceRecord, fromFetch = false): RaceRecord {
  return previous?.id === next.id &&
    (previous.updatedAt > next.updatedAt || (fromFetch && previous.updatedAt === next.updatedAt))
    ? previous
    : next;
}

export function raceChoices(catalog: AcpmuxSnapshot["catalog"]): { key: string; label: string; target: RaceTarget }[] {
  return catalog.flatMap((harness) => {
    if (
      harness.pickable === false ||
      (harness.unavailable && !harness.probeFailed) ||
      (harness.folder && harness.folder.state !== "enabled")
    )
      return [];
    return harness.models
      .filter((model) => !model.unavailable)
      .map((model) => ({
        key: JSON.stringify([harness.id, model.id]),
        label: `${harness.name} · ${model.name ?? model.id}`,
        target: { harness: harness.id, model: model.id },
      }));
  });
}
