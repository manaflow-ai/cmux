// l10n-allow-file: synthetic model-race gallery and test fixtures.
import type { RaceClient, RaceRecord } from "./model";

export const raceFixture: RaceRecord = {
  id: "race-demo",
  parent: "parent-demo",
  prompt: "Make the empty state explain how to start a chat.",
  state: "completed",
  winnerId: "candidate-b",
  reason: "Candidate B keeps the existing layout and adds the missing keyboard instruction.",
  createdAt: 1793750400000,
  updatedAt: 1793750410000,
  candidates: [
    {
      id: "candidate-a",
      target: { harness: "codex", model: "gpt-6.1-sol" },
      state: "discarded",
      reply: "Added a title and a button. The button starts a new chat.",
    },
    {
      id: "candidate-b",
      sessionId: "winner-demo",
      target: { harness: "claude", model: "opus" },
      state: "completed",
      cwd: "/project/.worktrees/race-demo-b",
      reply:
        "Added a short instruction beside the existing input. Press Enter to start a chat.\n\nVerified the keyboard path and preserved the empty-state layout.",
    },
  ],
};
export function fixtureRaceClient(race: RaceRecord): RaceClient {
  return {
    startRace: async () => race,
    getRace: async () => race,
    getRaceStats: async () => ({}),
    listRaces: async () => [race],
    cancelRace: async () => ({ ...race, state: "cancelled" }),
    watchRaces: () => () => undefined,
  };
}
