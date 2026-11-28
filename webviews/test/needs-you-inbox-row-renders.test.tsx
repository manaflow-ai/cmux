import { createRoot, rowRenders } from "./support/rowRenders";
// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// Unchanged rows do not draw again (visible-only re-renders, rule 2) in the header's Needs you list
// (needsYou/NeedsYou.tsx NeedsYouRow), the home's inbox (HomeInbox.tsx InboxRow) and its Ready for
// review list (HomeLists.tsx HomeRow):
// - a parent draw with the same data, a new `actions` object and asks rebuilt from the snapshot (as
//   needsYouItems does on every change) draws no row;
// - one ask's change draws that row only;
// - moving the focused ask (Needs you) or the shortcut row (the inbox) draws the two rows it moves
//   between only;
// - a minute passing draws no row: each age is a label on the shared clock (clock.ts
//   useLabelClock) that wakes when its own text changes, and the inbox's ages now move at all.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { HomeInboxOutcome } from "../src/agent-session/acpmux/homeInboxModel";
import type { NeedsYouActions } from "../src/agent-session/acpmux/needsYou/needsYouModel";
import type { NeedsYouItem, WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
// A focused ask scrolls into view; jsdom lays nothing out.
dom.window.HTMLElement.prototype.scrollIntoView = () => {};
afterAll(async () => {
  jest.useRealTimers();
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { NeedsYouPanel } = await import("../src/agent-session/acpmux/needsYou/NeedsYou");
const { HomeLists } = await import("../src/agent-session/acpmux/HomeLists");
const { session } = await import("../src/gallery/fixtures/acpmux");

const MINUTE = 60_000;
// 10:00:20 on a fixed day: a minute's tick lands at 10:01.
const T0 = Date.UTC(2026, 10, 18, 10, 0, 20);

function mountOn() {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  return { host, root: createRoot(host) };
}

// ---- Needs you (header list) ----

/// The asks as needsYouItems makes them: new objects on every call.
const askItems = (n: number, changed?: { index: number; ask: string }): NeedsYouItem[] =>
  Array.from({ length: n }, (_, index) => ({
    id: `acpmux:p${index}`,
    kind: "approval" as const,
    sessionId: `s${index}`,
    ask: changed?.index === index ? changed.ask : `Run step ${index}`,
    who: { name: `Chat ${index}`, harness: "claude", chief: false },
    // 30 s, 7m30s, 14m30s... old: the youngest turns from "now" at the next minute, the rest wait.
    at: T0 - index * 7 * MINUTE - 30_000,
    answers: [
      { id: `p${index}-yes`, label: "Allow", tone: "allow" as const },
      { id: `p${index}-no`, label: "Deny", tone: "deny" as const },
    ],
    permissionId: `p${index}`,
  }));

/// A new actions object per draw, as useNeedsYou and NeedsYouButton build one.
const needsYouActions = (): NeedsYouActions => ({
  answer: async () => undefined,
  goTo: () => {},
  ask: async () => undefined,
  open: () => {},
  opensElsewhere: () => true,
  context: () => ({ turns: [], partial: false }),
});

async function mountNeedsYou(n: number) {
  const { host, root } = mountOn();
  const draw = (items: NeedsYouItem[], focus?: string) =>
    act(async () => root.render(<NeedsYouPanel items={items} actions={needsYouActions()} focus={focus} />));
  await draw(askItems(n));
  return { host, root, draw };
}

test("Needs you: only the rows whose ask changed draw again", async () => {
  jest.useFakeTimers();
  jest.setSystemTime(T0);
  const n = 40;
  const { host, root, draw } = await mountNeedsYou(n);
  expect(host.querySelectorAll(".acpmux-needs-you-item").length).toBe(n);

  // The same asks, rebuilt, with new actions: no row.
  rowRenders.reset();
  await draw(askItems(n));
  const sameData = rowRenders.count("NeedsYouRow");

  // One ask's text changes: its row.
  rowRenders.reset();
  await draw(askItems(n, { index: 5, ask: "Run step five again" }));
  const oneChange = rowRenders.count("NeedsYouRow");
  expect(host.querySelectorAll(".acpmux-needs-you-ask-toggle")[5]?.textContent).toBe("Run step five again");

  // A link focuses ask 3, then ask 9: the rows focus moves between.
  await draw(askItems(n, { index: 5, ask: "Run step five again" }), "acpmux:p3");
  rowRenders.reset();
  await draw(askItems(n, { index: 5, ask: "Run step five again" }), "acpmux:p9");
  const focusMove = rowRenders.count("NeedsYouRow");
  expect(host.querySelector('[data-focused=""] .acpmux-needs-you-who')?.textContent).toBe("Chat 9");

  // A minute passes: the youngest ask's "now" turns to "1m", and no row draws.
  const firstAge = () => host.querySelector(".acpmux-needs-you-age")?.textContent;
  const before = firstAge();
  rowRenders.reset();
  await act(async () => jest.advanceTimersByTime(MINUTE));
  const tick = rowRenders.count("NeedsYouRow");
  const after = firstAge();

  console.log(
    `NeedsYouRow renders (N=${n}): same data ${sameData}, one ask ${oneChange}, focus move ${focusMove}, minute tick ${tick}; first age ${before} -> ${after}`,
  );
  expect(sameData).toBe(0);
  expect(oneChange).toBe(1);
  expect(focusMove).toBe(2);
  expect(tick).toBe(0);
  expect(after).not.toBe(before);
  await act(async () => root.unmount());
  host.remove();
  jest.useRealTimers();
});

// ---- Home inbox and Ready for review ----

/// The chats the asks are in, and three with a pull request ready for review. One snapshot's
/// sessions keep their objects where nothing changed, as the pane's session list does.
const homeSessions = (n: number): AcpmuxSessionEntry[] => [
  session({ sessionId: "home", updatedAt: T0 }),
  ...Array.from({ length: n }, (_, index) =>
    session({ sessionId: `s${index}`, title: `Chat ${index}`, pendingPermissions: 1, updatedAt: T0 - index * MINUTE }),
  ),
  ...Array.from({ length: 3 }, (_, index) => ({
    ...session({ sessionId: `pr${index}`, title: `Review ${index}`, updatedAt: T0 - (index + 1) * 7 * MINUTE }),
    pullRequest: { number: 100 + index, title: `Pull request ${index}`, state: "open" as const, reviewReady: true },
  })),
];

/// The pending asks, new objects every snapshot.
const homeAsks = (n: number, changed?: { index: number; title: string }): WatchedAsk[] =>
  Array.from({ length: n }, (_, index) => ({
    sessionId: `s${index}`,
    // 30 s, 7m30s, 14m30s... old: the youngest turns from "now" at the next minute, the rest wait.
    at: T0 - index * 7 * MINUTE - 30_000,
    permission: {
      permissionId: `p${index}`,
      title: changed?.index === index ? changed.title : `Run step ${index}`,
      pending: true,
      options: [
        { id: `p${index}-yes`, name: "Yes", kind: "allow_once" as const, allow: true },
        { id: `p${index}-no`, name: "No", kind: "reject_once" as const, allow: false },
      ],
    },
  }));

async function mountHome(n: number) {
  const { host, root } = mountOn();
  const sessions = homeSessions(n);
  const draw = (asks: WatchedAsk[], shortcuts = true) =>
    act(async () =>
      root.render(
        <HomeLists
          sessions={sessions}
          currentId="home"
          asks={asks}
          shortcuts={shortcuts}
          // New closures every draw, as the pane's App passes.
          onSelect={() => {}}
          onAnswer={async (): Promise<HomeInboxOutcome> => "answered"}
        />,
      ),
    );
  await draw(homeAsks(n));
  return { host, root, draw };
}

test("Home inbox and Ready for review: only the rows whose data changed draw again", async () => {
  jest.useFakeTimers();
  jest.setSystemTime(T0);
  const n = 40;
  const { host, root, draw } = await mountHome(n);
  expect(host.querySelectorAll(".acpmux-home-inbox-row").length).toBe(n);
  expect(host.querySelectorAll(".acpmux-home-row").length).toBe(3);

  // The same asks, rebuilt, and new callbacks: no row.
  rowRenders.reset();
  await draw(homeAsks(n));
  const sameInbox = rowRenders.count("InboxRow");
  const sameReview = rowRenders.count("HomeRow");

  // One ask's text changes: its row.
  rowRenders.reset();
  await draw(homeAsks(n, { index: 5, title: "Run step five again" }));
  const oneChange = rowRenders.count("InboxRow");
  expect(host.querySelectorAll(".acpmux-home-inbox-ask")[5]?.textContent).toBe("Run step five again");

  // The home's own chat takes the shortcuts, then gives them back: the first row only, each time.
  rowRenders.reset();
  await draw(homeAsks(n, { index: 5, title: "Run step five again" }), false);
  const keysMove = rowRenders.count("InboxRow");
  await draw(homeAsks(n, { index: 5, title: "Run step five again" }), true);

  // A minute passes: the youngest ask's "now" turns to "1m ago", and no row draws.
  const firstAge = () => host.querySelector(".acpmux-home-inbox-row .acpmux-home-meta")?.textContent;
  const before = firstAge();
  rowRenders.reset();
  await act(async () => jest.advanceTimersByTime(MINUTE));
  const tickInbox = rowRenders.count("InboxRow");
  const tickReview = rowRenders.count("HomeRow");
  const after = firstAge();

  console.log(
    `InboxRow renders (N=${n}): same data ${sameInbox}, one ask ${oneChange}, shortcut row move ${keysMove}, minute tick ${tickInbox}; HomeRow (3 rows): same data ${sameReview}, minute tick ${tickReview}; first age ${before} -> ${after}`,
  );
  expect(sameInbox).toBe(0);
  expect(sameReview).toBe(0);
  expect(oneChange).toBe(1);
  expect(keysMove).toBe(1);
  expect(tickInbox).toBe(0);
  expect(tickReview).toBe(0);
  expect(after).not.toBe(before);
  await act(async () => root.unmount());
  host.remove();
  jest.useRealTimers();
});

// Neither list is windowed (another change's concern): every ask is mounted. Measured here so the
// numbers sit beside the render counts, with one ask's change at each size.
test("mounted rows, DOM nodes and one ask's change at 1,000 and 10,000 asks", async () => {
  jest.useFakeTimers();
  jest.setSystemTime(T0);
  for (const n of [1_000, 10_000]) {
    const needsYou = await mountNeedsYou(n);
    rowRenders.reset();
    await needsYou.draw(askItems(n, { index: 5, ask: "Run step five again" }));
    console.log(
      `Needs you N=${n}: mounted rows ${needsYou.host.querySelectorAll(".acpmux-needs-you-item").length}, DOM nodes ${needsYou.host.querySelectorAll("*").length}, NeedsYouRow renders per one-ask change ${rowRenders.count("NeedsYouRow")}`,
    );
    expect(rowRenders.count("NeedsYouRow")).toBe(1);
    await act(async () => needsYou.root.unmount());
    needsYou.host.remove();

    const home = await mountHome(n);
    rowRenders.reset();
    await home.draw(homeAsks(n, { index: 5, title: "Run step five again" }));
    console.log(
      `Home inbox N=${n}: mounted rows ${home.host.querySelectorAll(".acpmux-home-inbox-row").length}, DOM nodes ${home.host.querySelectorAll("*").length}, InboxRow renders per one-ask change ${rowRenders.count("InboxRow")}`,
    );
    expect(rowRenders.count("InboxRow")).toBe(1);
    await act(async () => home.root.unmount());
    home.host.remove();
  }
  jest.useRealTimers();
}, 300_000);
