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
