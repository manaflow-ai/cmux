// l10n-allow-file: test fixtures.
// How long each self-healing connection state is on screen, on fake timers (Leo, 2026-11-14: "i also
// want all our connectivity stuff to shut up and load faster/percievably load faster / whatever it
// takes"): a state the person can do nothing about shows nothing until it has lasted the shared bound,
// `CONNECTION_QUIET_MS` (ui/lasting.ts). Each surface runs the same timelines through labelExposure:
// a connect that completes in 0.8 s, a reconnect that heals in 6 s, a drop that lasts 15 s. A failure
// with its one button, and a busy model (it is not a connection that heals), still show at once.
import { afterAll, afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";
import { labelExposure, TICK_MS } from "./support/labelExposure";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
type Root = ReturnType<typeof createRoot>;
const { translate: t } = await import("../src/agent-session/acpmux/i18n");
const { Thinking } = await import("../src/agent-session/acpmux/conversation/Thinking");
const { SubagentDoneLine } = await import("../src/agent-session/acpmux/subagents/SubagentDoneLine");
const { SUBAGENT_DONE } = await import("../src/agent-session/acpmux/subagents/subagentRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { ConnectorsSection } = await import("../src/agent-session/acpmux/session-info/ConnectorsSection");
const { GuestPage, loadGuestTranscript } = await import("../src/agent-session/guest/GuestPage");
await loadGuestTranscript();
const { joinFrames, memoryStorage, workingRecords } = await import("../src/agent-session/guest/fixtures/liveChat");
import type { AcpmuxRow, AcpmuxTurnRetry } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { ShareSocketLike } from "../src/agent-session/guest/shareSocket";
import type { ReactNode } from "react";

let root: Root | undefined;
let host: HTMLElement;
let clock: ReturnType<typeof setInterval> | undefined;

beforeEach(() => {
  jest.useFakeTimers();
  // Date.now walks with the fake clock, so the hold's own `now` and its timers agree.
  jest.setSystemTime(0);
  let at = 0;
  clock = setInterval(() => jest.setSystemTime((at += TICK_MS)), TICK_MS);
  host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.remove();
  clearInterval(clock);
  jest.useRealTimers();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const draw = (node: ReactNode) => () => root!.render(node);
const shows = (words: string) => () => (host.textContent ?? "").includes(words);

// --- The live line: "Can't reach the model" ------------------------------------------------------

const UNREACHABLE: AcpmuxTurnRetry = { attempt: 2, maxRetries: 10, errorStatus: 503, error: "server_error" };
const BUSY: AcpmuxTurnRetry = { attempt: 2, maxRetries: 10, errorStatus: 529, error: "overloaded_error" };
const line = (retry?: AcpmuxTurnRetry, retryAt?: number) => (
  <Thinking since={-60_000} retry={retry} retryAt={retryAt} below />
);
const retrying = () => host.querySelector("[data-retrying]") !== null;

test("the model out of reach for 6 s: the line never says so", async () => {
  const ms = await labelExposure(
    "thinking-unreachable-heals-6s",
    [
      { at: 0, apply: draw(line(UNREACHABLE, 0)) },
      { at: 6_000, apply: draw(line()) },
    ],
    20_000,
    retrying,
  );
  expect(ms).toBe(0);
});

test("the model out of reach for 15 s: the line says so for the last 5 s", async () => {
  const ms = await labelExposure(
    "thinking-unreachable-lasts-15s",
    [
      { at: 0, apply: draw(line(UNREACHABLE, 0)) },
      { at: 15_000, apply: draw(line()) },
    ],
    20_000,
    retrying,
  );
  expect(ms).toBe(5_000);
});

test("a retry that began before the line drew shows as soon as it has lasted, not 10 s after the draw", async () => {
  const ms = await labelExposure(
    "thinking-unreachable-mounted-late",
    [
      { at: 0, apply: draw(line(UNREACHABLE, -20_000)) },
      { at: 6_000, apply: draw(line()) },
    ],
    10_000,
    retrying,
  );
  expect(ms).toBe(6_000);
});

test("a busy model says so at once: it is no link that heals", async () => {
  const ms = await labelExposure(
    "thinking-busy-6s",
    [
      { at: 0, apply: draw(line(BUSY, 0)) },
      { at: 6_000, apply: draw(line()) },
    ],
    10_000,
    retrying,
  );
  expect(ms).toBe(6_000);
});

// --- A subagent's retry: "Retrying (2/4)…" ----------------------------------------------------------

const agent = (id: string, retry: boolean): Subagent => ({
  id,
  parent: null,
  name: id,
  task: "Fix the upload test",
  state: retry ? "failed" : "running",
  startedAt: 0,
  ...(retry && { endedAt: 0, retryable: true, error: "Connection reset", retry: { attempt: 2, of: 4 } }),
});
const doneLine = (id: string, retry: boolean) => {
  const row: AcpmuxRow = { id: `done-${id}`, version: 1, at: 0, kind: SUBAGENT_DONE, subagents: [agent(id, retry)] };
  return (
    <TurnActionsContext.Provider value={{ retryAgent: async () => undefined }}>
      <SubagentDoneLine row={row} />
    </TurnActionsContext.Provider>
  );
};
const retryWords = shows(t("retry.waiting", { attempt: 2, of: 4 }));

test("a subagent's retry that heals in 6 s says nothing of it", async () => {
  const ms = await labelExposure(
    "subagent-retry-heals-6s",
    [
      { at: 0, apply: draw(doneLine("heals", true)) },
      { at: 6_000, apply: draw(doneLine("heals", false)) },
    ],
    20_000,
    retryWords,
  );
  expect(ms).toBe(0);
});

test("a subagent's retry that lasts 15 s says so for the last 5 s", async () => {
  const ms = await labelExposure(
    "subagent-retry-lasts-15s",
    [
      { at: 0, apply: draw(doneLine("lasts", true)) },
      { at: 15_000, apply: draw(doneLine("lasts", false)) },
    ],
    20_000,
    retryWords,
  );
  expect(ms).toBe(5_000);
});

// --- Session Info's connectors: "Connecting…" -------------------------------------------------------

type Server = { name: string; status: "pending" | "connected" | "failed" };
const connectors = (servers: Server[]) => (
  <ConnectorsSection servers={servers as never} onReconnect={async () => undefined} />
);
const connecting = shows(t("rail.connectorPending"));

test("a connector that connects in 0.8 s never says it is connecting", async () => {
  const ms = await labelExposure(
    "connector-connects-0.8s",
    [
      { at: 0, apply: draw(connectors([{ name: "github", status: "pending" }])) },
      { at: 800, apply: draw(connectors([{ name: "github", status: "connected" }])) },
    ],
    5_000,
    connecting,
  );
  expect(ms).toBe(0);
});

test("a connector still connecting after 15 s says so for the last 5 s", async () => {
  const ms = await labelExposure(
    "connector-connect-lasts-15s",
    [
      { at: 0, apply: draw(connectors([{ name: "linear", status: "pending" }])) },
      { at: 15_000, apply: draw(connectors([{ name: "linear", status: "connected" }])) },
    ],
    20_000,
    connecting,
  );
  expect(ms).toBe(5_000);
});

test("a failed connector shows its Reconnect at once", async () => {
  const ms = await labelExposure(
    "connector-failed",
    [{ at: 0, apply: draw(connectors([{ name: "sentry", status: "failed" }])) }],
    2_000,
    () => host.querySelector("button") !== null,
  );
  expect(ms).toBe(2_000);
});

// --- The web guest: "Connecting…" / "Reconnecting…" -------------------------------------------------

/** A room whose answers the timeline sends: `live` plays the join frames on the newest socket, `drop` closes it. */
function room() {
  const sockets: ShareSocketLike[] = [];
  return {
    open: () => {
      const socket: ShareSocketLike = {
        send: () => undefined,
        close: () => undefined,
        onopen: null,
        onmessage: null,
        onclose: null,
      };
      sockets.push(socket);
      return socket;
    },
    live: () => {
      for (const frame of joinFrames(workingRecords())) sockets.at(-1)!.onmessage?.({ data: JSON.stringify(frame) });
    },
    drop: () => sockets.at(-1)!.onclose?.(),
  };
}
const guest = (link: ReturnType<typeof room>) => (
  <GuestPage
    shareId="c2hhcmUtMTIzNDU2Nzg"
    secret={btoa("secret-abcdefgh")}
    guestId="g1"
    redeem={() => new Promise(() => undefined)}
    attempt={() => "a".repeat(32)}
    socketUrl="wss://room.test/guest"
    storage={memoryStorage()}
    openSocket={link.open}
  />
);
const linkWords = () => shows(t("guest.live.connecting"))() || shows(t("guest.live.reconnecting"))();

test("the guest's first connect in 0.8 s says nothing of it", async () => {
  const link = room();
  const ms = await labelExposure(
    "guest-connects-0.8s",
    [
      { at: 0, apply: draw(guest(link)) },
      { at: 800, apply: link.live },
    ],
    5_000,
    linkWords,
  );
  expect(ms).toBe(0);
});

test("the guest's reconnect that heals in 6 s says nothing of it", async () => {
  const link = room();
  const ms = await labelExposure(
    "guest-reconnect-heals-6s",
    [
      { at: 0, apply: draw(guest(link)) },
      { at: 800, apply: link.live },
      { at: 2_000, apply: link.drop },
      { at: 8_000, apply: link.live },
    ],
    20_000,
    linkWords,
  );
  expect(ms).toBe(0);
});

test("the guest's drop that lasts 15 s says Reconnecting for the last 5 s", async () => {
  const link = room();
  const ms = await labelExposure(
    "guest-drop-lasts-15s",
    [
      { at: 0, apply: draw(guest(link)) },
      { at: 800, apply: link.live },
      { at: 2_000, apply: link.drop },
      { at: 17_000, apply: link.live },
    ],
    20_000,
    linkWords,
  );
  expect(ms).toBe(5_000);
});
