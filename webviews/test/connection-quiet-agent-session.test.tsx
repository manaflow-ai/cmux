// The agent pane's connection states stay quiet through a blip and speak once one lasts the shared bound
// (ui/lasting.ts CONNECTION_QUIET_MS, schemas/notice-timing): the composer's retry line, a sub-session card's
// retry words and a starting connector's "Connecting". Each one draws its cached content on the first frame and
// no connection words through a 2 s drop, then one calm line past 10 s (Leo, 2026-11-14, asked connectivity UI to
// stay quiet and feel instant). `noticeFrames` is the harness the PR's before/after numbers come from: it counts
// the 100 ms frames across a scripted 2 s drop that show a connection state.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { SubsessionCall } from "../src/agent-session/acpmux/conversation/subsessionCalls";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { importWithDom } from "./support/importWithDom";
import { settleReact } from "./support/domTeardown";

const [
  { setPaneLanguage },
  { NoticeSlot },
  { AutoResumeNotice },
  { SubsessionCallCard },
  { ConnectorsSection },
  { SubsessionContext, SubsessionStore },
  { CONNECTION_QUIET_MS, QUIET_CONNECT_SWITCH },
  { setExperimentSwitches },
] = await importWithDom(() =>
  Promise.all([
    import("../src/agent-session/acpmux/i18n"),
    import("../src/agent-session/acpmux/NoticeSlot"),
    import("../src/agent-session/acpmux/AutoResumeNotice"),
    import("../src/agent-session/acpmux/conversation/SubsessionCallCard"),
    import("../src/agent-session/acpmux/session-info/ConnectorsSection"),
    import("../src/agent-session/acpmux/subagents/subsessions"),
    import("../src/ui/lasting"),
    import("../src/experiments/switches"),
  ]),
);

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    NodeFilter: dom.window.NodeFilter,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  setExperimentSwitches({});
  setPaneLanguage("en");
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const CONNECTION_WORDS = /retrying|reconnecting|connecting|disconnected|not connected|waiting to retry/i;

/// The frames, one per 100 ms across `ms`, whose text says a connection state.
async function noticeFrames(container: HTMLElement, ms: number): Promise<number> {
  let frames = 0;
  for (let at = 0; at < ms; at += 100) {
    if (CONNECTION_WORDS.test(container.textContent ?? "")) frames += 1;
    await act(async () => jest.advanceTimersByTime(100));
  }
  return frames;
}

async function advance(ms: number) {
  await act(async () => jest.advanceTimersByTime(ms));
}

// The composer's retry line (AutoResumeNotice.tsx).

async function renderNotice(container: HTMLElement, state: Parameters<typeof AutoResumeNotice>[0]["state"]) {
  root ??= createRoot(container);
  await act(async () =>
    root!.render(
      <NoticeSlot>
        <AutoResumeNotice state={state} />
      </NoticeSlot>,
    ),
  );
}

const RETRY = { retry: { attempt: 1, of: 4, reason: "transport" as const }, attempt: 1 };

test("a 2 s retry draws no line in the composer, and the turn that goes on says nothing about it", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderNotice(container, RETRY);
  expect(container.querySelector('[data-auto-resume="waiting"]')).toBeNull();
  expect(await noticeFrames(container, 2_000)).toBe(0);
  await renderNotice(container, { attempt: 2 });
  await advance(CONNECTION_QUIET_MS);
  expect(container.textContent).toBe("");
});

test("a retry that waits past 10 s says one calm line", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderNotice(container, RETRY);
  await advance(CONNECTION_QUIET_MS - 100);
  expect(container.querySelector('[data-auto-resume="waiting"]')).toBeNull();
  await advance(200);
  const lines = container.querySelectorAll('[data-auto-resume="waiting"]');
  expect(lines).toHaveLength(1);
  expect(lines[0]!.textContent).not.toBe("");
});

// A sub-session card's retry words (SubsessionCallCard.tsx SessionCard).

const WAIT: Extract<SubsessionCall, { tool: "wait" }> = {
  tool: "wait",
  running: false,
  sessions: [{ sessionId: "review-id", name: "review", state: "working" }],
} as never;
const WAIT_TOOL = {
  id: "wait-call",
  title: "mcp__cmux-subsessions__wait_for_sessions",
  status: "completed",
  inputSummary: "{}",
  output: "",
} as never;

async function renderCard(container: HTMLElement, store: InstanceType<typeof SubsessionStore>) {
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => {} }}>
        <SubsessionCallCard call={WAIT} tool={WAIT_TOOL} />
      </SubsessionContext.Provider>,
    ),
  );
}

const child = (change: Partial<AcpmuxSessionEntry>) =>
  ({
    sessionId: "review-id",
    name: "review",
    startedBy: "parent",
    status: "idle",
    lane: "working",
    ...change,
  }) as AcpmuxSessionEntry;

test("a sub-session card draws its name on the first frame and no retry words through a 2 s retry", async () => {
  // The card's retry words wait the bound behind Settings > Experiments > Quiet Connections (off by default).
  setExperimentSwitches({ [QUIET_CONNECT_SWITCH]: true });
  jest.useFakeTimers();
  const container = installDom();
  const store = new SubsessionStore();
  store.set([child({ lane: "failed", retry: { attempt: 1, of: 4 } })]);
  await renderCard(container, store);
  // The first frame: the cached card, by name, working.
  expect(container.textContent).toContain("review");
  expect(await noticeFrames(container, 2_000)).toBe(0);
  await act(async () => store.set([child({ lane: "working" })]));
  await advance(CONNECTION_QUIET_MS);
  expect(container.textContent).not.toMatch(CONNECTION_WORDS);
});

test("a sub-session retry that lasts past 10 s says so once", async () => {
  jest.useFakeTimers();
  const container = installDom();
  const store = new SubsessionStore();
  store.set([child({ lane: "failed", retry: { attempt: 1, of: 4 } })]);
  await renderCard(container, store);
  await advance(CONNECTION_QUIET_MS + 100);
  expect(container.textContent?.match(/Retrying/g) ?? []).toHaveLength(1);
});

// A starting connector (session-info/ConnectorsSection.tsx).

async function renderConnectors(container: HTMLElement, servers: Parameters<typeof ConnectorsSection>[0]["servers"]) {
  root ??= createRoot(container);
  await act(async () => root!.render(<ConnectorsSection servers={servers} />));
}

test("a connector coming up draws its name on the first frame and no Connecting through a 2 s start", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderConnectors(container, [
    { name: "github", status: "connected" },
    { name: "linear", status: "pending" },
  ]);
  const names = [...container.querySelectorAll(".acpmux-session-info-row__name")].map((n) => n.textContent);
  expect(names).toEqual(["github", "linear"]);
  expect(container.querySelector('[data-state="connected"]')).not.toBeNull();
  expect(await noticeFrames(container, 2_000)).toBe(0);
  await renderConnectors(container, [
    { name: "github", status: "connected" },
    { name: "linear", status: "connected" },
  ]);
  expect(container.querySelectorAll('[data-state="connected"]')).toHaveLength(2);
});

test("a connector still starting past 10 s says Connecting once", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await renderConnectors(container, [{ name: "linear", status: "pending" }]);
  const said = () => container.querySelector('[data-state="pending"]')?.textContent ?? "";
  await advance(CONNECTION_QUIET_MS - 100);
  expect(said()).toBe("");
  await advance(200);
  expect(said()).not.toBe("");
});
