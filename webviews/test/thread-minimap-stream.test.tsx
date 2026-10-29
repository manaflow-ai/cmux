// cmux-web-test-timeout: 300
// The wave rail while a reply streams (#24058 review round 3). Every streamed token gives the
// transcript a new rows snapshot, and the rail used to map every prompt again for each one: its
// list of ticks rebuilt each tick's label and element, O(prompts) work per token on the main thread
// in a long chat. The ticks now come from a list that changes only when the prompts do (model.ts
// minimapTurns' `ticks`), so a token in the last reply leaves every tick alone, while the preview
// card still reads the reply as it streams.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { MinimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
setDefaultTimeout(120_000);

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
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  // Reduce Motion: scrolls land at once, so a test reads where they land.
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport in a 1040 px pane, and a scroll offset.
const VIEWPORT = 600;
const paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

// The pane's strings, with a count of every tick label the rail builds (one per tick it renders).
let labels = 0;
const english: Record<string, string> = {
  "minimap.label": "Messages",
  "minimap.moveRight": "",
  "minimap.moveLeft": "",
};
for (const key of ["minimap.tick", "minimap.tickBookmarked"])
  Object.defineProperty(english, key, {
    enumerable: true,
    get: () => {
      labels += 1;
      return "Message {index} of {count}: {prompt}";
    },
  });
const strings = globalThis as { __cmuxPaneStrings?: Record<string, Record<string, string>> };
const stringsBefore = strings.__cmuxPaneStrings;
strings.__cmuxPaneStrings = { en: english };

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { tickRanges } = await import("../src/agent-session/acpmux/threadMinimap/tickWindow");
const { minimapTurns } = await import("../src/agent-session/acpmux/threadMinimap/model");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
// No marks in this chat; acpmux answers at once.
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [] }),
  set: async (sessionId) => ({ sessionId, bookmarks: [] }),
});

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  if (stringsBefore) strings.__cmuxPaneStrings = stringsBefore;
  else delete strings.__cmuxPaneStrings;
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const PROMPTS = 300;
/// A long chat whose last reply is `reply` so far.
const chat = (reply: string) =>
  Array.from({ length: PROMPTS }, (_, index) => {
    const last = index === PROMPTS - 1;
    const answer = last ? reply : `Answer ${index}.\n\nWith a second paragraph so the turn has height.`;
    return [
      row(`user-${index + 1}`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", answer),
      ...(last ? [] : [{ ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 }]),
    ];
  }).flat();

test("a token streaming into the last reply of a 300-prompt chat builds no tick again", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  // One row array per snapshot, as the store hands them: every row but the streaming one is the
  // same object from snapshot to snapshot.
  const base = chat("Streaming");
  const at = base.findIndex((item) => item.id === `t${PROMPTS - 1}-answer`);
  const render = (reply: string) => {
    const rows = base.slice();
    rows[at] = { ...base[at]!, text: reply, version: reply.length };
    return act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="minimap-stream"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  };
  try {
    let reply = "Streaming";
    await render(reply);
    // The rail draws the ticks in its view and some past each edge (tickWindow.ts), not all 300.
    const drawn = host.querySelectorAll("[data-tick]").length;
    expect(drawn).toBeGreaterThan(0);
    expect(drawn).toBeLessThan(PROMPTS);
    // The rail drew each of them once.
    expect(labels).toBeGreaterThanOrEqual(drawn);
    const perToken: number[] = [];
    for (let token = 0; token < 20; token += 1) {
      reply += ` word${token}`;
      labels = 0;
      await render(reply);
      perToken.push(labels);
    }
    // No tick is built again for a token: the ticks show the prompts, and no prompt changed.
    expect(Math.max(...perToken)).toBe(0);
    expect(host.querySelectorAll("[data-tick]").length).toBe(drawn);

    // The card still previews the reply as it streams.
    const last = host.querySelector<HTMLElement>(`[data-tick="${PROMPTS - 1}"]`)!;
    await act(async () => last.focus());
    reply += " latest";
    await render(reply);
    expect(host.querySelector(".acpmux-minimap__card")?.textContent).toContain("latest");
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("a new prompt adds its tick, and the earlier ones keep theirs", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const rows = chat("Done");
  const render = (list: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(list, new Set())}
          sessionId="minimap-stream-prompt"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await render(rows);
    const ticks = () =>
      new Map([...host.querySelectorAll<HTMLElement>("[data-tick]")].map((node) => [Number(node.dataset.tick), node]));
    /// The rows the rail's window draws for its list's offset and height (tickWindow.ts), nothing
    /// focused or hovered.
    const window = (count: number) => {
      const list = host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      const height = Number.parseFloat(list.parentElement!.style.height);
      return tickRanges(count, list.scrollTop, height).flatMap(([from, to]) =>
        Array.from({ length: to - from }, (_, offset) => from + offset),
      );
    };
    const before = ticks();
    expect([...before.keys()]).toEqual(window(PROMPTS));
    await render([...rows, row(`user-${PROMPTS + 1}`, "user", "One more question")]);
    expect(host.querySelector(`[data-tick="${PROMPTS}"]`)?.getAttribute("aria-label")).toContain("One more question");
    expect(host.querySelector(`[data-tick="${PROMPTS}"]`)?.getAttribute("aria-label")).toContain(`${PROMPTS + 1}`);
    // Exactly the rows of the rail's window are drawn, and every one drawn before the new prompt is
    // the same element.
    const after = ticks();
    expect([...after.keys()]).toEqual(window(PROMPTS + 1));
    const kept = [...before.keys()].filter((index) => after.has(index));
    expect(kept).toEqual([...before.keys()].filter((index) => window(PROMPTS + 1).includes(index)));
    for (const index of kept) expect(after.get(index)).toBe(before.get(index)!);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

/// `rows` behind a proxy that counts the items read by index.
function counted<T>(rows: T[]) {
  const reads = { count: 0 };
  const proxy = new Proxy(rows, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads.count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  return { proxy, reads };
}

/// Counts the items read from `list` by index, in place: the list keeps its identity (the next
/// read finds the list it last wrote by it), and every read of an item, a copy's included, counts.
function countReads<T>(list: readonly T[]) {
  const reads = { count: 0 };
  list.forEach((item, index) => {
    let value = item;
    Object.defineProperty(list, index, {
      configurable: true,
      enumerable: true,
      get() {
        reads.count += 1;
        return value;
      },
      set(next: T) {
        value = next;
      },
    });
  });
  return reads;
}

/// The chat's rows with the last prompt's reply at `reply`.
const streamingChat = (prompts: number, reply: string) =>
  Array.from({ length: prompts }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", index === prompts - 1 ? reply : `Answer ${index}.`),
  ]).flat();

/// `rows` with its last row's text replaced, as one streamed token does.
const streamed = (rows: readonly AcpmuxRow[], text: string) => {
  const next = rows.slice();
  const at = next.length - 1;
  next[at] = { ...next[at]!, text, version: (next[at]!.version ?? 1) + 1 };
  return { next, change: { base: rows, rows: next, from: at } };
};

/// The rows the rail's turns read for one streamed token in a chat of `prompts` prompts, given
/// where the snapshot changed (the transcript finds it once for every reader of the rows), after
/// one token before it (the rail's steady state: the list it writes the next turns into exists).
function readsPerToken(prompts: number) {
  const first = minimapTurns(streamingChat(prompts, "Streaming"), "s");
  const one = streamed(first.rows, "Streaming more");
  const base = counted(one.next);
  const previous = minimapTurns(base.proxy, "s", first, { ...one.change, rows: base.proxy });
  // The committed turns, counted in place: a copy of them reads every one.
  const committed = [...previous.turns];
  const turns = countReads(previous.turns);
  const ticks = previous.ticks;
  const two = streamed(base.proxy, "Streaming more still");
  const after = counted(two.next);
  base.reads.count = 0;
  const result = minimapTurns(after.proxy, "s", previous, { ...two.change, rows: after.proxy });
  return {
    reads: base.reads.count + after.reads.count,
    turnReads: turns.count,
    result,
    previous,
    committed,
    ticks,
    fresh: minimapTurns(two.next, "s"),
  };
}

test("a streamed token reads the same few rows in a 300- and a 3000-prompt chat", () => {
  const small = readsPerToken(300);
  const large = readsPerToken(3000);
  // Bounded by what changed (the live reply), not by the chat: no scan from the first row.
  expect(large.reads).toBe(small.reads);
  expect(small.reads).toBeLessThan(10);
  // The reply's preview is still filling, so the live turn is new; the turns before it are neither
  // copied nor walked (#24058 review round 5): the live turn is found by binary search, about
  // log2(prompts) reads of the committed turns.
  expect(small.turnReads).toBeLessThan(30);
  expect(large.turnReads).toBeLessThan(30);
  // The committed turns are left as they were (#24058 review round 6): the new ones are another list.
  expect(large.result.turns).not.toBe(large.previous.turns);
  expect(large.previous.turns.length).toBe(large.committed.length);
  expect(large.previous.turns.every((turn, index) => turn === large.committed[index])).toBe(true);
  // The prompts did not change: the same ticks; the turns are what a fresh read gives.
  expect(large.result.ticks).toBe(large.ticks);
  expect([...large.result.turns]).toEqual([...large.fresh.turns]);
});

// React may render with the next rows and then drop that render (a scroll or another update wins)
// before it commits. The rail reads the next turns from the committed ones; that read must leave them
// as they were, or the committed rail would show prompts and replies from rows it never committed
// (#24058 review round 6).
test("a dropped render leaves the committed turns as they were, and the next read matches a fresh one", () => {
  const first = minimapTurns(streamingChat(40, "Streaming"), "s");
  const warm = streamed(first.rows, "Streaming more");
  let committed = minimapTurns(warm.next, "s", first, warm.change);
  const snapshot = (result: MinimapTurns) => ({
    turns: [...result.turns],
    ticks: [...result.ticks],
    length: result.turns.length,
  });
  const unchanged = (result: MinimapTurns, before: ReturnType<typeof snapshot>) => {
    expect(result.turns.length).toBe(before.length);
    expect(result.turns.every((turn, index) => turn === before.turns[index])).toBe(true);
    expect(result.ticks.every((tick, index) => tick === before.ticks[index])).toBe(true);
  };
  for (let step = 0; step < 4; step += 1) {
    const before = snapshot(committed);
    // Dropped: a new prompt, then a streamed token, each read from the committed turns.
    const added = [...committed.rows, row(`dropped-${step}`, "user", `Dropped question ${step}`)];
    const dropped = minimapTurns(added, "s", committed, {
      base: committed.rows,
      rows: added,
      from: committed.rows.length,
    });
    expect(dropped.turns.at(-1)?.prompt).toBe(`Dropped question ${step}`);
    unchanged(committed, before);
    const token = streamed(committed.rows, `Streaming more, step ${step} dropped`);
    minimapTurns(token.next, "s", committed, token.change);
    unchanged(committed, before);
    // Then the render that commits, from the same committed turns.
    const next = streamed(committed.rows, `Streaming more, step ${step}`);
    const result = minimapTurns(next.next, "s", committed, next.change);
    unchanged(committed, before);
    expect([...result.turns]).toEqual([...minimapTurns(next.next, "s").turns]);
    expect(result.turns.some((turn) => turn.prompt.startsWith("Dropped"))).toBe(false);
    committed = result;
  }
});

test("a change in the middle of the chat reads from there on, and matches a fresh read", () => {
  const rows = Array.from({ length: 50 }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.`),
  ]).flat();
  const previous = minimapTurns(rows, "s");
  const before = previous.turns.slice();
  // A prompt edited mid-chat, and a row inserted before a later prompt (its index moves).
  const edited = rows.slice();
  edited[40] = { ...edited[40]!, text: "Question 20, edited", version: 2 };
  edited.splice(61, 0, row("t30-read", "activity"));
  const result = minimapTurns(edited, "s", previous, { base: rows, rows: edited, from: 40 });
  expect(result.turns).toEqual(minimapTurns(edited, "s").turns);
  // The turns before the change are the same objects.
  expect(result.turns.slice(0, 20).every((turn, index) => turn === before[index])).toBe(true);
  // A change point for other rows is not used: the turns are read as a scan would.
  const stale = minimapTurns(edited, "s", minimapTurns(rows, "s"), { base: [], rows: edited, from: 99 });
  expect(stale.turns).toEqual(result.turns);
});

/// The tick labels the rail shows, in order.
const tickLabels = (host: HTMLElement) =>
  [...host.querySelectorAll<HTMLElement>("[data-tick]")].map((node) => node.getAttribute("aria-label"));

test("through the transcript: another chat, then the same chat replaced and cut, show their own ticks", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const prompts = (prefix: string, count: number) =>
    Array.from({ length: count }, (_, index) => [
      row(`user-${index + 1}`, "user", `${prefix} ${index}`),
      row(`t${index}-answer`, "assistant", `Answer ${index}.`),
    ]).flat();
  const render = (rows: AcpmuxRow[], sessionId: string) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  const expected = (prefix: string, count: number) =>
    Array.from({ length: count }, (_, index) => `Message ${index + 1} of ${count}: ${prefix} ${index}`);
  try {
    await render(prompts("Alpha", 12), "chat-a");
    expect(tickLabels(host)).toEqual(expected("Alpha", 12));
    // Another chat, whose row ids repeat the first one's.
    await render(prompts("Beta", 9), "chat-b");
    expect(tickLabels(host)).toEqual(expected("Beta", 9));
    // The same chat, every row replaced (a reload of its history).
    await render(prompts("Gamma", 9), "chat-b");
    expect(tickLabels(host)).toEqual(expected("Gamma", 9));
    // Its last prompts deleted.
    await render(prompts("Gamma", 5), "chat-b");
    expect(tickLabels(host)).toEqual(expected("Gamma", 5));
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});
