// Leo, 2026-10-20: "the settings flicker is bad when you load it". The host shows Settings from the
// frame its paint report names (PagePaintProbe.swift; the pane keeps what it showed until then,
// PanePaintHold). The report waits for the page's gate (`__cmuxPaintAfter`). Settings opened with
// every control disabled at its schema default, then its values; and the host's cards (Spaces,
// Machines) appended after the first frame. Now the gate holds until the first screen is in, for a
// pooled page from its claim and for a page loaded fresh, so the first frame shown is the final one.
//
// Task 081 (Chrome's settings/lazy_load.ts): the first load holds the navigation and the section the
// route opens on; another section draws complete with its one extra chunk, and the rest load after
// the first paint, one per idle turn.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { act } = await import("react");
const { createMockClient } = await import("./mockProvider");
const { withMockTiming } = await import("./mockTiming");
const { mountSettingsPage } = await import("./mount");
const { PAINT_AFTER_NAME } = await import("../shared/paintGate");
const { PARKED_NAME } = await import("../shared/pageClient");
const { createSectionLoader, lazySections } = await import("./lazySections");

type SettingsClient = import("./ops").SettingsClient;
type SectionChunk = import("./lazySections").SectionChunk;
type SectionChunks = import("./lazySections").SectionChunks;

const scope = globalThis as Record<string, unknown>;
/// What the page has asked the host and not heard back yet: calls in flight, and stream events the
/// mock sent that the timing layer has not delivered to the page.
const traffic = { calls: 0, made: 0, sent: 0, delivered: 0 };
const quiet = () => traffic.made > 0 && traffic.calls === 0 && traffic.sent === traffic.delivered;
/// Counts the events the mock sends (`inner`) and the calls and events the page sees (`outer`).
function counted(client: SettingsClient, side: "inner" | "outer"): SettingsClient {
  return {
    async call<R>(op: string, params: unknown, opts?: { signal?: AbortSignal }) {
      if (side === "inner") return client.call<R>(op, params, opts);
      traffic.calls += 1;
      traffic.made += 1;
      try {
        return await client.call<R>(op, params, opts);
      } finally {
        traffic.calls -= 1;
      }
    },
    subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (side === "outer") traffic.calls += 1;
      traffic.made += 1;
      const subscribed = client.subscribe<E>(stream, (data, seq) => {
        traffic[side === "inner" ? "sent" : "delivered"] += 1;
        onEvent(data, seq);
      });
      if (side === "outer") void subscribed.finally(() => (traffic.calls -= 1));
      return subscribed;
    },
  };
}

let unmount: (() => void) | undefined;
afterEach(() => {
  Object.assign(traffic, { calls: 0, made: 0, sent: 0, delivered: 0 });
  act(() => unmount?.());
  unmount = undefined;
  document.body.replaceChildren();
  delete scope[PAINT_AFTER_NAME];
  delete scope[PARKED_NAME];
  history.replaceState(null, "", "/");
  loads.length = 0;
  idleTurns.length = 0;
});

/// The section chunks the page asked for, in order, and the idle turns it is waiting for.
const loads: SectionChunk[] = [];
const idleTurns: (() => void)[] = [];
/// The page's section code over the built chunks, counting each chunk it asks for; idle work waits
/// for `idleTurn()`.
function countedSections() {
  const chunks = Object.fromEntries(
    Object.entries(lazySections).map(([id, load]) => [
      id,
      () => {
        loads.push(id as SectionChunk);
        return load();
      },
    ]),
  ) as SectionChunks;
  return createSectionLoader({
    chunks,
    idle: (work) => {
      idleTurns.push(work);
      return () => idleTurns.splice(idleTurns.indexOf(work) >>> 0, 1);
    },
  });
}

/// Runs the next idle turn and waits for the chunk it starts.
async function idleTurn() {
  const work = idleTurns.shift();
  if (!work) throw new Error("no idle work is waiting");
  await act(async () => work());
  const all = Object.keys(lazySections).length;
  await until(() => idleTurns.length > 0 || loads.length === all, "the next idle turn");
}

/// What a frame shows: rows, disabled controls and the page's groups.
function screen() {
  return {
    rows: document.querySelectorAll("[data-row-key]").length,
    disabled: [...document.querySelectorAll(".row-control :disabled, .row-control [aria-disabled='true']")].filter(
      (control) => !orderEnd(control),
    ).length,
    groups: document.querySelectorAll("section").length,
  };
}

/// An ordered list's first Move Up or last Move Down button, disabled at any value.
function orderEnd(control: Element) {
  const item = control.closest("[data-ordered-choices] > .folder-item");
  if (!item) return false;
  const buttons = item.querySelectorAll("button");
  return (
    (control === buttons[0] && item.previousElementSibling === null) ||
    (control === buttons[1] && item.nextElementSibling === null)
  );
}

/// Yields to the page until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  do {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  } while (!ready());
}

/// The screen once every call the page made is answered and every event the host sent has reached it.
async function settled() {
  await until(quiet, "every answer to reach the page");
  // React draws what the last answer changed.
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  expect(quiet()).toBe(true);
  return screen();
}

async function opened(search: string, claim: boolean, sections?: ReturnType<typeof createSectionLoader>) {
  const root = document.createElement("div");
  document.body.append(root);
  const client = counted(
    withMockTiming(counted(createMockClient().client, "inner"), new URLSearchParams(search)),
    "outer",
  );
  let mounted: Promise<() => void> | undefined;
  await act(async () => {
    mounted = mountSettingsPage(root, client, sections);
  });
  void mounted!.then((stop) => (unmount = stop));
  if (claim) {
    // Parked in the pool until the host claims it (its first calls wait); then the host asks for a
    // paint report.
    await until(() => traffic.calls > 0, "the parked page's first calls");
    await act(async () => (scope.__cmuxSettingsClaim as () => void)());
  }
  const gate = scope[PAINT_AFTER_NAME] as Promise<unknown> | undefined;
  expect(gate).toBeDefined();
  await act(async () => await gate);
  return screen();
}

test("a pooled Settings page claimed by the host reports its paint once its first screen is in", async () => {
  const first = await opened("latency=20&parked", true);
  expect(first.rows).toBeGreaterThan(0);
  expect(first.disabled).toBe(0);
  expect(first).toEqual(await settled());
});

test("a Settings page loaded fresh reports its first paint once its first screen is in", async () => {
  const first = await opened("latency=20", false);
  expect(first.rows).toBeGreaterThan(0);
  expect(first.disabled).toBe(0);
  expect(first).toEqual(await settled());
});

test("the first load holds the section the route opens on and no other", async () => {
  history.replaceState(null, "", "/#/settings/advanced");
  const first = await opened("latency=20", false, countedSections());
  expect(loads).toEqual(["advanced"]);
  expect(document.querySelector("[data-section='advanced'] [data-card='problems']")).not.toBeNull();
  expect(first).toEqual(await settled());
  expect(loads).toEqual(["advanced"]);
});

test("a focused key opens on the code of the section that holds it", async () => {
  history.replaceState(null, "", "/#/settings/general?focus=appearance.density");
  await opened("latency=20", false, countedSections());
  expect(loads).toEqual(["appearance"]);
  expect(document.querySelector("[data-section='appearance'] [data-card='density']")).not.toBeNull();
});

test("another section draws complete with one extra chunk", async () => {
  history.replaceState(null, "", "/#/settings/advanced");
  await opened("latency=20", false, countedSections());
  await settled();
  const link = document.querySelector<HTMLElement>("[data-section-link='appearance']");
  expect(link).not.toBeNull();
  await act(async () => link!.click());
  await until(() => document.querySelector("[data-section='appearance']") !== null, "the Appearance section");
  // The section's first frame has its card: the route drew it once its chunk was in.
  expect(document.querySelector("[data-section='appearance'] [data-card='density']")).not.toBeNull();
  expect(loads).toEqual(["advanced", "appearance"]);
});

test("after the first paint the other sections load, one per idle turn", async () => {
  await opened("latency=20", false, countedSections());
  await settled();
  expect(loads).toEqual(["general"]);
  const all = Object.keys(lazySections) as SectionChunk[];
  for (let turn = 1; turn < all.length; turn += 1) {
    await idleTurn();
    expect(loads.length).toBe(turn + 1);
  }
  expect(idleTurns).toEqual([]);
  expect([...loads].sort()).toEqual([...all].sort());
});
