// l10n-allow-file: replay fixtures.
// Replay the updated receiver's journal through the pane's session replay client and App.
// aria-setsize includes off-screen transcript rows, so virtualization cannot hide a flood.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const { window } = dom;
const media = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
const observer = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
const globals: Record<string, unknown> = {
  window,
  document: window.document,
  location: window.location,
  navigator: window.navigator,
  Node: window.Node,
  Element: window.Element,
  HTMLElement: window.HTMLElement,
  customElements: window.customElements,
  MutationObserver: window.MutationObserver,
  ResizeObserver: observer,
  IntersectionObserver: observer,
  getComputedStyle: window.getComputedStyle.bind(window),
  requestAnimationFrame: window.requestAnimationFrame.bind(window),
  cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
  matchMedia: media,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(window)) {
  if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) globals[key] = Reflect.get(window, key);
}
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, globals);
Object.assign(window, { matchMedia: media });
Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get: () => 10_000,
});
Object.defineProperty(window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 760,
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
afterAll(() => teardownDom(saved, { window, scope }));

async function replay(sessionId: string, events: EventRecord[], held: number, visible: string[]) {
  let snapshot: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.replay(sessionId, events, (next) => {
    snapshot = next;
  });
  client.seekReplay(Math.max(...events.map((event) => event.seq)));
  const host = window.document.getElementById("root")!;
  const root = createRoot(host);
  try {
    expect(snapshot?.surge?.held).toBe(held);
    await act(async () => root.render(<AcpmuxApp initialChat={{ snapshot: snapshot! }} />));
    expect(host.querySelectorAll(".acpmux-surge-line").length).toBe(1);
    const rows = host.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]");
    expect(rows.length).toBeGreaterThan(0);
    const count = Number(rows[0].getAttribute("aria-setsize"));
    expect(count).toBeGreaterThanOrEqual(rows.length);
    expect(count + 1).toBeLessThanOrEqual(10);
    const text = Array.from(rows, (row) => row.textContent).join("\n");
    for (const message of visible) expect(text).toContain(message);
    return count + 1;
  } finally {
    await act(async () => root.unmount());
    client.dispose();
  }
}

test("a surge keeps one inbox row and the transcript still displays each protected message", async () => {
  const held = 373;
  const events: EventRecord[] = Array.from({ length: held }, (_, i) => ({
    seq: i + 1,
    at: 1000 + i,
    dir: "mux",
    kind: "inbox",
    msg: {
      promptId: String(i),
      threadId: "topic:runner",
      surgeHeld: true,
      surge: { held: i + 1, needYou: 0 },
      from: "vm-" + (i % 86),
      text: "Repeated runner notice",
    },
  }));
  const visible = ["First arrival", "FIRE delivery", "Question delivery", "Block delivery", "Person delivery"];
  for (const text of visible)
    events.push({
      seq: events.length + 1,
      at: 1000 + events.length,
      dir: "mux",
      kind: "user_message",
      msg: { promptId: text, text },
    });
  const count = await replay("surge-replay", events, held, visible);
  console.log("synthetic pane replay: arrivals=378 held=373 chatRows=" + count);
}, 30_000);

// Supply a redacted *post-replay* session journal, with the expected held count and protected
// message excerpts from the independent source trace. An admission-only report is insufficient.
const path = process.env.ACPMUX_SURGE_PANE_TRACE;
test.skipIf(!path)(
  "coordinator flood replay fits in ten actual chat rows",
  async () => {
    const { sessionId, events, held, protectedExcerpts } = await Bun.file(path!).json();
    expect(Number.isSafeInteger(held) && held > 0).toBe(true);
    expect(Array.isArray(protectedExcerpts) && protectedExcerpts.length > 0).toBe(true);
    const chatRows = await replay(sessionId, events, held, protectedExcerpts);
    console.log("coordinator pane replay: held=" + held + " chatRows=" + chatRows);
  },
  30_000,
);
