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

type MockProvider = ReturnType<typeof createMockClient>["provider"];

/// Mounts the page on the mock host (`setup` changes the host first); `gate` is its paint gate.
async function mounted(
  search: string,
  claim: boolean,
  sections?: ReturnType<typeof createSectionLoader>,
  setup?: (provider: MockProvider) => void,
): Promise<{ gate: Promise<unknown> }> {
  const root = document.createElement("div");
  document.body.append(root);
  const mock = createMockClient();
  setup?.(mock.provider);
  const client = counted(withMockTiming(counted(mock.client, "inner"), new URLSearchParams(search)), "outer");
  let mounting: Promise<() => void> | undefined;
  await act(async () => {
    mounting = mountSettingsPage(root, client, sections);
  });
  void mounting!.then((stop) => (unmount = stop));
  if (claim) {
    // Parked in the pool until the host claims it (its first calls wait); then the host asks for a
    // paint report.
    await until(() => traffic.calls > 0, "the parked page's first calls");
    await act(async () => (scope.__cmuxSettingsClaim as () => void)());
  }
  const gate = scope[PAINT_AFTER_NAME] as Promise<unknown> | undefined;
  expect(gate).toBeDefined();
  return { gate: gate! };
}

/// The screen of the frame the host shows first: the page's, once its paint gate settles.
async function opened(...args: Parameters<typeof mounted>) {
  const { gate } = await mounted(...args);
  await act(async () => await gate);
  return screen();
}

/// Section code whose chunks load only when the test releases them, as a slow disk or a cold
/// cache would: what the page draws before then is what it shows while a chunk is out.
function deferredSections() {
  const waiting = new Map<SectionChunk, () => void>();
  const chunks = Object.fromEntries(
    Object.entries(lazySections).map(([id, load]) => [
      id,
      () => {
        loads.push(id as SectionChunk);
        return new Promise<void>((resolve) => waiting.set(id as SectionChunk, resolve)).then(load);
      },
    ]),
  ) as SectionChunks;
  const sections = createSectionLoader({ chunks, idle: () => () => {} });
  return {
    sections,
    /// Lets `chunk` load and waits until the page has it.
    async release(chunk: SectionChunk) {
      const resolve = waiting.get(chunk);
      if (!resolve) throw new Error(`the page has not asked for the ${chunk} chunk`);
      let loaded = false;
      const stop = sections.subscribe(() => (loaded = true));
      await act(async () => resolve());
      await until(() => loaded, `the ${chunk} chunk`);
      stop();
    },
  };
}

/// Whether the node `selector` names had `inner` in it at the commit that added it.
function firstFrameOf(selector: string, inner: string) {
  let complete: boolean | undefined;
  const observer = new MutationObserver(() => {
    const node = document.querySelector(selector);
    if (node && complete === undefined) complete = node.querySelector(inner) !== null;
  });
  observer.observe(document.body, { childList: true, subtree: true });
  return {
    shown: () => complete !== undefined,
    complete() {
      observer.disconnect();
      return complete === true;
    },
  };
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

test("the first paint waits for the code of the section the route opens on", async () => {
  history.replaceState(null, "", "/#/settings/advanced");
  const deferred = deferredSections();
  const { gate } = await mounted("latency=20", false, deferred.sections);
  let painted = false;
  void gate.then(() => (painted = true));
  // Every host read is in; only the section's chunk is out.
  await until(() => quiet() && loads.includes("advanced"), "the host's answers and the Advanced chunk's load");
  expect(painted).toBe(false);
  expect(document.querySelector("[data-card='problems']")).toBeNull();
  await deferred.release("advanced");
  await act(async () => await gate);
  expect(painted).toBe(true);
  expect(document.querySelector("[data-section='advanced'] [data-card='problems']")).not.toBeNull();
});

test("another section draws complete with one extra chunk", async () => {
  history.replaceState(null, "", "/#/settings/advanced");
  const deferred = deferredSections();
  const { gate } = await mounted("latency=20", false, deferred.sections);
  await until(() => loads.includes("advanced"), "the Advanced chunk's load");
  await deferred.release("advanced");
  await act(async () => await gate);
  await settled();
  const link = document.querySelector<HTMLElement>("[data-section-link='appearance']");
  expect(link).not.toBeNull();
  const appearance = firstFrameOf("[data-section='appearance']", "[data-card='density']");
  await act(async () => link!.click());
  // While its chunk is out (well under the router's pending wait) the route keeps Advanced.
  await until(() => quiet() && loads.includes("appearance"), "the Appearance chunk's load");
  expect(appearance.shown()).toBe(false);
  expect(document.querySelector("[data-section='advanced']")).not.toBeNull();
  await deferred.release("appearance");
  await until(appearance.shown, "the Appearance section");
  // The section's first frame has its card: the route drew it once its chunk was in.
  expect(appearance.complete()).toBe(true);
  expect(loads).toEqual(["advanced", "appearance"]);
});

test("a DEV-only section opened in a release build loads and draws the section it shows", async () => {
  history.replaceState(null, "", "/#/settings/devices");
  await opened("latency=20", false, countedSections(), (provider) => {
    provider.host = { ...provider.host, dev_build: false };
  });
  // General shows in place of Devices, with the Spaces card of its chunk, in the first frame.
  expect(document.querySelector("[data-section='devices']")).toBeNull();
  expect(document.querySelector("[data-section='general'] [data-card='rooms']")).not.toBeNull();
  expect(loads).toEqual(["general"]);
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
