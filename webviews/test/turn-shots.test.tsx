// A turn's before and after picture of the chat's page (agent-session/acpmux/turnChanges/turnShots.ts,
// TurnShotsPair.tsx; acpmux hub/turn_shots.rs): the reply reads as a pair only with both pictures, the
// pair belongs to the turn's ending summary, reads stay bounded, and the card draws the shared
// before/after split with both fixture pictures.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { setEditedFilesSettings } from "../src/agent-session/acpmux/turnChanges/settings";
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
  // A failed read is not kept: the next draw asks again.
  await cache.read("t4", () => Promise.reject(new Error("gone")));
  expect(cache.peek("t4")).toBeUndefined();
  await cache.read("t4", load);
  expect(cache.peek("t4")).toEqual({ pair });
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

// The card reads stores that only a client render has: draw it in jsdom, as the pane does.
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
setDefaultTimeout(30_000);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function renderCard(row: AcpmuxRow, shots: TurnShotsReader) {
  const { createRoot } = await import("react-dom/client");
  const { EditedFilesCard } = await import("../src/agent-session/acpmux/conversation/EditedFilesCard");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <TurnShotsContext.Provider value={shots}>
        <EditedFilesCard row={row} sessionId="s" />
      </TurnShotsContext.Provider>,
    ),
  );
}

test("an ended turn's card draws the split with both pictures", async () => {
  await renderCard(edit(true), reader({ before: PAGE_BEFORE, after: PAGE_AFTER }));
  const pair = host.querySelector(".acpmux-turn-shots .ui-compare");
  expect(pair?.getAttribute("data-mode")).toBe("slider");
  const sources = [...host.querySelectorAll(".ui-compare img")].map((img) => img.getAttribute("src"));
  expect(sources).toEqual([PAGE_AFTER, PAGE_BEFORE]);
  const range = host.querySelector<HTMLInputElement>(".ui-compare-range");
  expect(range?.value).toBe("50");
});

test("no pair, or a turn still running, draws no pictures", async () => {
  await renderCard(edit(true), reader(undefined));
  expect(host.querySelector(".acpmux-turn-shots")).toBeNull();
  act(() => root?.unmount());
  await renderCard(edit(false), reader({ before: PAGE_BEFORE, after: PAGE_AFTER }));
  expect(host.querySelector(".acpmux-turn-shots")).toBeNull();
});

test("a card the setting collapses shows its pictures only once opened", async () => {
  // The edit fixture is a one-file card: its pictures go with its diff.
  setEditedFilesSettings({ show: "collapsed" });
  try {
    await renderCard(edit(true), reader({ before: PAGE_BEFORE, after: PAGE_AFTER }));
    expect(host.querySelector(".acpmux-turn-shots")).toBeNull();
  } finally {
    act(() => setEditedFilesSettings({ show: "always" }));
  }
});

// The build's compiler memoizes `peek(rowId)` on the reader and row, so after the read the card
// sees what `peek` said before it: here `peek` never learns of the read, and the card must draw the
// read's answer anyway.
test("a pair read while the card shows arrives and is marked to grow in", async () => {
  const pair = { before: PAGE_BEFORE, after: PAGE_AFTER };
  const arriving: TurnShotsReader = {
    peek: () => undefined,
    read: () => Promise.resolve(pair),
  };
  await renderCard(edit(true), arriving);
  await act(async () => {
    await Promise.resolve();
  });
  expect(host.querySelector(".acpmux-turn-shots[data-arrived] .ui-compare")).not.toBeNull();
});
