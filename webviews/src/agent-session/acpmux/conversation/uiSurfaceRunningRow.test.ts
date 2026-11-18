// A running call that carries an agent UI surface keeps its own row in a live turn, so its card
// (rows/ToolActivityRow.tsx) streams in while the call runs (turns.ts `streamsOwnSurface`). Handed to
// the live line like any running call, the call had no row until it finished: its card landed whole,
// in one frame, at the call's end (bench/ui-surface-stream-frames.bench.ts: one card height over 40
// streamed updates, CLS 0.033). With Labs `labs.agentUiSurfaces` off nothing changes.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { setAgentUiSurfaces } from "../agentUiSurfaces";
import { tableSurface } from "../uiSurface/fixtures";
import { THINKING, turnView } from "./turns";

afterEach(() => setAgentUiSurfaces(false));

const user: AcpmuxRow = { id: "user", version: 1, at: 1_000, kind: "user", text: "Show the release status." };
const streaming = { ...tableSurface, status: "streaming" as const };

function liveTurn(status: "in_progress" | "completed", version: number): AcpmuxRow[] {
  return [
    user,
    {
      id: "act",
      version,
      at: 2_000,
      kind: "activity",
      items: [
        {
          kind: "tool",
          text: "",
          tool: { id: "ui-call", title: "ui_surface", kind: "other", status, uiSurface: streaming },
        },
      ],
    },
  ];
}

const surfaceRow = (rows: readonly AcpmuxRow[]) =>
  rows.find((row) => row.items?.some((item) => item.tool?.uiSurface !== undefined));

test("a running call with a surface keeps its row while it streams, a new version per update", () => {
  setAgentUiSurfaces(true);
  const first = turnView(liveTurn("in_progress", 1), new Set(), { now: 3_000, working: true });
  const row = surfaceRow(first);
  expect(row?.id).toBe("act");
  expect(row?.items?.[0]?.tool?.status).toBe("in_progress");
  // The live line still closes the turn, and it names no call: the call is drawn in its row.
  expect(first.at(-1)?.kind).toBe(THINKING);
  expect(first.at(-1)?.doing ?? "").not.toContain("ui_surface");
  // Each streamed update moves the row's version, so the memoized row (and its card) draws it.
  const next = turnView(liveTurn("in_progress", 2), new Set(), { now: 3_016, working: true });
  expect(surfaceRow(next)?.version).not.toBe(row?.version);
  // Finished, it is still the same row: it never leaves and comes back.
  const done = turnView(liveTurn("completed", 3), new Set(), { now: 3_032, working: true });
  expect(surfaceRow(done)?.id).toBe("act");
});

test("with agent UI surfaces off a running call goes to the live line as before", () => {
  setAgentUiSurfaces(false);
  const shown = turnView(liveTurn("in_progress", 1), new Set(), { now: 3_000, working: true });
  expect(surfaceRow(shown)).toBeUndefined();
});
