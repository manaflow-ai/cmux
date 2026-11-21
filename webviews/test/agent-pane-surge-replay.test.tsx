// l10n-allow-file: replay fixtures.
// Replay the updated receiver's journal through the pane's session replay client and App.
// aria-setsize includes off-screen transcript rows, so virtualization cannot hide a flood.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { teardownDom } from "./support/domTeardown";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

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
    const rows = host.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW);
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
  const digest = "surge-digest-runner";
  const digestText = "Check the stalled runner for this pull request.";
  const protectedIds = visible.slice(1);
  const source = events.map(({ msg }, index) => ({
    promptId: msg.promptId,
    senderId: "vm-" + (index % 86),
    class: msg.promptId === "Question delivery" ? "question" : msg.promptId === "Block delivery" ? "block" : "fyi",
    person: msg.promptId === "Person delivery",
    provenance: msg.promptId === "FIRE delivery" ? { notice: { severity: "fire" } } : null,
  }));
  const append = (kind: string, msg: EventRecord["msg"]) => {
    events.push({ seq: events.length + 1, at: 1000 + events.length, dir: "mux", kind, msg });
  };
  for (let start = 0; start < held; start += 16) {
    const items = source.slice(start, Math.min(start + 16, held)).map(({ promptId }) => ({
      promptId,
      category: promptId === "0" ? "needs_this_session" : "noise",
      threadId: "topic:runner",
    }));
    append("inbox_triaged", { digestPromptId: digest, items, surge: { held, needYou: 1 } });
  }
  append("user_message", {
    promptId: digest,
    text: digestText,
    _meta: { provenance: { kind: "surge_digest", digestId: digest, promptIds: ["0"] } },
  });
  const excerpts = Object.fromEntries(protectedIds.map((id) => [id, id]));
  expect(() => checkDelivery(source, protectedIds, events, excerpts)).toThrow();
  append("inbox_triaged", { digestDelivered: digest, items: [], surge: { held, needYou: 1 } });
  checkDelivery(source, protectedIds, events, excerpts);
  const count = await replay("surge-replay", events, held, [...visible, digestText]);
  console.log("synthetic pane replay: arrivals=378 held=373 chatRows=" + count);
}, 30_000);

// Keep the source trace independent of the journal from the replayed coordinator. A journal
// with a missing delivery or an unclassified backlog cannot qualify by rendering fewer rows.
type SourceArrival = {
  promptId: string;
  senderId: string;
  class: string;
  person: boolean;
  provenance: { notice?: { severity?: string } } | null;
};

function checkDelivery(
  arrivals: SourceArrival[],
  protectedIds: string[],
  events: EventRecord[],
  excerpts: Record<string, string>,
) {
  const source = new Set(arrivals.map((item) => item.promptId));
  expect(arrivals.length).toBe(378);
  expect(source.size).toBe(378);
  expect(new Set(arrivals.map((item) => item.senderId)).size).toBe(86);
  const protectedSet = new Set(protectedIds);
  for (const item of arrivals) {
    if (
      item.person ||
      item.class === "question" ||
      item.class === "block" ||
      item.provenance?.notice?.severity === "fire"
    ) {
      expect(protectedSet.has(item.promptId)).toBe(true);
    }
  }
  const held = new Set<string>();
  const visible = new Set<string>();
  const classified = new Set<string>();
  const owed = new Set<string>();
  const delivered = new Set<string>();
  for (const event of events) {
    const msg = event.msg;
    if (event.kind === "inbox" && msg.surgeHeld === true) {
      expect(source.has(msg.promptId)).toBe(true);
      expect(held.has(msg.promptId)).toBe(false);
      held.add(msg.promptId);
    }
    if (event.kind === "bridge_delivered" || event.kind === "user_message") visible.add(msg.promptId);
    if (event.kind === "inbox_triaged") {
      for (const item of msg.items ?? []) {
        expect(held.has(item.promptId)).toBe(true);
        expect(classified.has(item.promptId)).toBe(false);
        expect(["needs_this_session", "needs_its_owner", "already_handled", "noise"]).toContain(item.category);
        classified.add(item.promptId);
        if (!item.repeatOf && (item.category === "needs_this_session" || item.category === "needs_its_owner")) {
          expect(typeof msg.digestPromptId).toBe("string");
          owed.add(msg.digestPromptId);
        }
      }
      if (typeof msg.digestDelivered === "string") delivered.add(msg.digestDelivered);
    }
  }
  for (const id of owed) expect(delivered.has(id)).toBe(true);
  for (const id of source) {
    expect(held.has(id) || visible.has(id)).toBe(true);
    if (held.has(id)) {
      expect(visible.has(id)).toBe(false);
      expect(classified.has(id)).toBe(true);
    }
  }
  for (const id of protectedSet) {
    expect(source.has(id) && visible.has(id) && !held.has(id)).toBe(true);
    expect(typeof excerpts[id] === "string" && excerpts[id].trim().length > 0).toBe(true);
  }
  return { held: held.size, visible: Array.from(protectedSet, (id) => excerpts[id]!) };
}

const path = process.env.ACPMUX_SURGE_PANE_TRACE;
test.skipIf(!path)(
  "coordinator flood replay fits in ten actual chat rows",
  async () => {
    const sourcePath = process.env.ACPMUX_SURGE_TRACE;
    if (!sourcePath) throw new Error("Supply the owner-exported source trace alongside the replay journal");
    const { arrivals, protectedIds } = await Bun.file(sourcePath).json();
    const { sessionId, events, protectedExcerpts } = await Bun.file(path!).json();
    const { held, visible } = checkDelivery(arrivals, protectedIds, events, protectedExcerpts);
    const chatRows = await replay(sessionId, events, held, visible);
    console.log(
      "coordinator pane replay: arrivals=378 senders=86 held=" +
        held +
        " protected=" +
        visible.length +
        " chatRows=" +
        chatRows,
    );
  },
  30_000,
);
