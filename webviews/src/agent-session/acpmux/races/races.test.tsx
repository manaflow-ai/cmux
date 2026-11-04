import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { RaceCompareView } from "./RaceCompareView";
import { fixtureRaceClient, raceFixture } from "./fixtures";
import { newerRace, raceChoices, type RaceRecord } from "./model";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;
function mount() {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  return container;
}
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("race model choices preserve model identity and exclude disabled, untrusted and unavailable targets", () => {
  expect(
    raceChoices([
      {
        id: "codex",
        name: "Codex",
        models: [
          { id: "sol", name: "Sol" },
          { id: "bad", unavailable: "missing" },
        ],
      },
      { id: "disabled", name: "Disabled", pickable: false, models: [{ id: "x" }] },
      {
        id: "profile",
        name: "Profile",
        models: [{ id: "x" }],
        folder: { folder: "/project", state: "needs-trust" },
      },
    ]),
  ).toEqual([
    {
      key: JSON.stringify(["codex", "sol"]),
      label: "Codex · Sol",
      target: { harness: "codex", model: "sol" },
    },
  ]);
});

test("older fetches cannot overwrite a newer reviewer decision", () => {
  expect(
    newerRace(raceFixture, {
      ...raceFixture,
      updatedAt: raceFixture.updatedAt - 1,
      state: "running",
    }).state,
  ).toBe("completed");
});

test("an equal-millisecond fetch preserves the event while the next live event can advance it", () => {
  const running = { ...raceFixture, state: "running" as const };
  expect(newerRace(raceFixture, running, true).state).toBe("completed");
  expect(newerRace(running, raceFixture).state).toBe("completed");
});

test("comparison shows real replies and reviewer winner without manufactured build evidence", () => {
  const html = renderToStaticMarkup(
    <RaceCompareView
      parent={raceFixture.parent}
      raceId={raceFixture.id}
      initialRace={raceFixture}
      client={fixtureRaceClient(raceFixture)}
    />,
  );
  expect(html).toContain("Added a short instruction");
  expect(html).toContain('data-winner="true"');
  expect(html).toContain(raceFixture.reason!);
  expect(html).not.toContain("atlas");
  expect(html).not.toContain("Tests passed");
});

test("live event wins over delayed get and cleanup removes subscription", async () => {
  const container = mount();
  let resolve!: (race: RaceRecord) => void;
  let listener: ((race: RaceRecord) => void) | undefined;
  let removed = 0;
  const client = {
    ...fixtureRaceClient(raceFixture),
    getRace: () =>
      new Promise<RaceRecord>((done) => {
        resolve = done;
      }),
    watchRaces: (next: (race: RaceRecord) => void) => {
      listener = next;
      return () => {
        removed++;
      };
    },
  };
  await act(async () =>
    root!.render(<RaceCompareView parent={raceFixture.parent} raceId={raceFixture.id} client={client} />),
  );
  await act(async () => listener!(raceFixture));
  await act(async () =>
    resolve({
      ...raceFixture,
      state: "running",
      winnerId: undefined,
      reason: undefined,
      updatedAt: raceFixture.updatedAt - 1,
    }),
  );
  expect(container.textContent).toContain(raceFixture.reason!);
  await act(async () => root!.render(<RaceCompareView parent="other" raceId="other" client={client} />));
  expect(container.textContent).not.toContain(raceFixture.reason!);
  expect(removed).toBe(1);
  await act(async () => root!.unmount());
  root = undefined;
  expect(removed).toBe(2);
});
