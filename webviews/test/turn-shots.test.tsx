// A turn's before and after picture of the chat's page (agent-session/acpmux/turnChanges/turnShots.ts,
// TurnShotsPair.tsx; acpmux hub/turn_shots.rs): the reply reads as a pair only with both pictures, the
// pair belongs to the turn's ending summary, reads stay bounded, and the card draws the shared
// before/after split with both fixture pictures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { PAGE_AFTER, PAGE_BEFORE } from "../src/agent-session/acpmux/turnChanges/turnShotFixtures";
import {
  readTurnShots,
  shotTurnId,
  TurnShotCache,
  TurnShotsContext,
  type TurnShotPair,
  type TurnShotsReader,
} from "../src/agent-session/acpmux/turnChanges/turnShots";

// Stand-ins for the base64 PNG bytes acpmux sends (never decoded here).
const RED = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
const GREEN = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNg+M8AAAICAQB7CYF4AAAAAElFTkSuQmCC";

test("a reply is a pair only with both pictures", () => {
  const before = { mimeType: "image/png", data: RED };
  const after = { mimeType: "image/png", data: GREEN };
  expect(readTurnShots({ sessionId: "s", turnId: "t", before, after })).toEqual({
    before: `data:image/png;base64,${RED}`,
    after: `data:image/png;base64,${GREEN}`,
  });
  expect(readTurnShots({ sessionId: "s", turnId: "t" })).toBeUndefined();
  expect(readTurnShots({ before, after: { data: "" } })).toBeUndefined();
  expect(readTurnShots(null)).toBeUndefined();
  // A type that is not an image's reads as PNG, never as markup.
  expect(readTurnShots({ before: { mimeType: "text/html", data: RED }, after })?.before).toStartWith("data:image/png;");
});

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...fields,
});

test("the pair is the turn's ending summary's, and none while the turn runs", () => {
  const rows = [
    row("u1", "user", { text: "restyle", turnId: "t1" }),
    row("a1", "activity"),
    row("s1", "turnSummary", { turnId: "t1" }),
    row("u2", "user", { text: "again", turnId: "t2" }),
    row("a2", "activity"),
  ];
  expect(shotTurnId(rows, "a1")).toBe("t1");
  expect(shotTurnId(rows, "a2")).toBeUndefined();
  expect(shotTurnId(rows, "missing")).toBeUndefined();
});

test("reads are kept once per turn, at most the cache's limit", async () => {
  const cache = new TurnShotCache(2);
  const pair: TurnShotPair = { before: "b", after: "a" };
  let loads = 0;
  const load = () => {
    loads += 1;
    return Promise.resolve(pair);
  };
  expect(cache.peek("t1")).toBeUndefined();
  await cache.read("t1", load);
  await cache.read("t1", load);
  expect(loads).toBe(1);
  expect(cache.peek("t1")).toEqual({ pair });
  await cache.read("t2", () => Promise.resolve(undefined));
  expect(cache.peek("t2")).toEqual({ pair: undefined });
  await cache.read("t3", load);
  // The oldest read went: a third turn keeps two.
  expect(cache.peek("t1")).toBeUndefined();
  expect(cache.peek("t3")).toEqual({ pair });
  await cache.read("t4", () => Promise.reject(new Error("gone")));
  expect(cache.peek("t4")).toEqual({});
});

const edit = (ended: boolean): AcpmuxRow =>
  row("edit", "activity", {
    ended,
    items: [
      {
        kind: "tool",
        text: "Edit Pricing.tsx",
        tool: {
          id: "e1",
          title: "Edit Pricing.tsx",
          kind: "edit",
          status: "completed",
          diffs: [{ path: "/repo/Pricing.tsx", oldText: "a\n", newText: "b\n" }],
        },
      },
    ],
  });

const reader = (pair?: TurnShotPair): TurnShotsReader => ({
  peek: () => ({ pair }),
  read: () => Promise.resolve(pair),
});

test("an ended turn's card draws the split with both pictures", async () => {
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const html = renderToStaticMarkup(
    <TurnShotsContext.Provider value={reader({ before: PAGE_BEFORE, after: PAGE_AFTER })}>
      <EditedFilesCard row={edit(true)} sessionId="s" />
    </TurnShotsContext.Provider>,
  );
  expect(html).toContain('class="ui-compare" data-mode="slider"');
  expect(html).toContain('type="range"');
  expect(html).toContain(`src="${PAGE_BEFORE.replace(/&/g, "&amp;")}"`);
  expect(html).toContain(`src="${PAGE_AFTER.replace(/&/g, "&amp;")}"`);
});

test("no pair, or a turn still running, draws no pictures", async () => {
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  const none = renderToStaticMarkup(
    <TurnShotsContext.Provider value={reader(undefined)}>
      <EditedFilesCard row={edit(true)} sessionId="s" />
    </TurnShotsContext.Provider>,
  );
  expect(none).not.toContain("acpmux-turn-shots");
  const running = renderToStaticMarkup(
    <TurnShotsContext.Provider value={reader({ before: PAGE_BEFORE, after: PAGE_AFTER })}>
      <EditedFilesCard row={edit(false)} sessionId="s" />
    </TurnShotsContext.Provider>,
  );
  expect(running).not.toContain("acpmux-turn-shots");
});
