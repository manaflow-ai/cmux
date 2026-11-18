// l10n-allow-file: fixture prompts, not shipped UI.
// Find in Chat over the whole transcript (chatFind.ts `useChatFind` with a FindIndexSource): the
// daemon's hits in turns not loaded add to the count and the steps, the loaded match stays current
// while they land, stepping to one loads its turn and then its match is current, the rows on screen
// are asked for first, a stale query's answer is dropped, a `find:` reveal makes the nearest hit
// current, and a daemon with no index leaves Find as it was. Then the real client on the mock
// daemon: a hit in a turn far above the loaded page is loaded through its seq, or by older pages
// when the daemon could not place it.
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import type { AcpmuxRow } from "../model";
import { type ChatFind, useChatFind } from "./chatFind";
import type { FindIndexSource, IndexAnswer, IndexHit, IndexSearch } from "./findIndex";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  delete (globalThis as { cmuxAcpmuxMockTranscriptSearch?: unknown }).cmuxAcpmuxMockTranscriptSearch;
});

function mount(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

/// Yields to the next macrotask until `check` holds (the find's debounce is a timer), or fails.
async function until(check: () => boolean, what: string) {
  const deadline = performance.now() + 5_000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

const row = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });

/// Loaded rows: two prompts that say "retry", the oldest loaded at t=1000.
const loaded = [row("r1", 1_000, "Why does the retry loop stop?"), row("r2", 2_000, "Add a retry test.")];
/// Three hits in turns before the loaded rows.
const older: IndexHit[] = [
  { at: 100, seq: 1, snippet: "retry" },
  { at: 200, seq: 2, snippet: "retry" },
  { at: 300, seq: 3, snippet: "retry" },
];

type Asked = { search: IndexSearch; answer: (value: IndexAnswer | undefined) => void };

/// An index whose answers the test gives: every search waits in `asked` until answered.
function fakeIndex(firstSeq: number, extra: Partial<FindIndexSource> = {}) {
  const asked: Asked[] = [];
  const loads: IndexHit[] = [];
  const source: FindIndexSource = {
    key: "chat-1",
    search: (search) => new Promise((answer) => asked.push({ search, answer })),
    holdsSeq: (seq) => seq >= firstSeq,
    load: (hit) => {
      loads.push(hit);
      return Promise.resolve(true);
    },
    ...extra,
  };
  return { source, asked, loads };
}

function render(rows: readonly AcpmuxRow[], index?: FindIndexSource) {
  const container = mount();
  const state: { find?: ChatFind; rows: readonly AcpmuxRow[]; index?: FindIndexSource } = { rows, index };
  function Find() {
    state.find = useChatFind(state.rows, state.index);
    return null;
  }
  root = createRoot(container);
  act(() => root!.render(<Find />));
  return {
    get find() {
      return state.find!;
    },
    rerender(next: { rows?: readonly AcpmuxRow[]; index?: FindIndexSource }) {
      if (next.rows) state.rows = next.rows;
      if (next.index) state.index = next.index;
      act(() => root!.render(<Find />));
    },
  };
}

describe("useChatFind with the transcript index", () => {
  test("hits only in turns not loaded add to the count; the first loaded match stays current", async () => {
    const { source, asked } = fakeIndex(10);
    const view = render(loaded, source);
    act(() => view.find.show("retry"));
    // Before the index answers: the loaded matches, searching.
    expect(view.find.total).toBe(2);
    expect(view.find.busy).toBe(true);
    await until(() => asked.length === 1, "the whole-chat search");
    expect(asked[0]!.search).toEqual({ query: "retry", limit: 200 });
    // The loaded ones are hits too: only those before the loaded rows count again.
    await act(async () =>
      asked[0]!.answer({ hits: [...older, { at: 1_000, seq: 10 }, { at: 2_000, seq: 11 }], total: 5 }),
    );
    expect(view.find.index).toBe("whole");
    expect(view.find.total).toBe(5);
    expect(view.find.position).toBe(3);
    expect(view.find.active).toBe(0);
    expect(view.find.matches[view.find.active]!.rowId).toBe("r1");
    expect(view.find.busy).toBe(false);
  });

  test("stepping to a hit in a turn not loaded loads it, then its match is current", async () => {
    const { source, asked, loads } = fakeIndex(10);
    const view = render(loaded, source);
    act(() => view.find.show("retry"));
    await until(() => asked.length === 1, "the search");
    await act(async () => asked[0]!.answer({ hits: older }));
    act(() => view.find.previous());
    expect(view.find.position).toBe(2);
    expect(view.find.active).toBe(-1);
    expect(view.find.pending?.seq).toBe(3);
    await until(() => loads.length === 1, "the load");
    expect(loads[0]!.seq).toBe(3);
    // Its turn lands: the row it is in is loaded now, and its match is the current one.
    const landed = [row("r0", 300, "retry from the start"), ...loaded];
    view.rerender({ rows: landed, index: { ...source, holdsSeq: (seq) => seq >= 3 } });
    await until(() => view.find.active >= 0, "the landed match");
    expect(view.find.matches[view.find.active]!.rowId).toBe("r0");
    expect(view.find.total).toBe(5);
    expect(view.find.position).toBe(2);
    expect(view.find.pending).toBeUndefined();
  });

  test("with no loaded match the newest hit is current and its turn loads", async () => {
    const { source, asked, loads } = fakeIndex(10);
    const view = render([row("r1", 1_000, "nothing here")], source);
    act(() => view.find.show("retry"));
    await until(() => asked.length === 1, "the search");
    await act(async () => asked[0]!.answer({ hits: older }));
    expect(view.find.total).toBe(3);
    expect(view.find.position).toBe(2);
    await until(() => loads.length === 1, "the load");
    expect(loads[0]!.seq).toBe(3);
  });

  test("the rows on screen are asked for first and drawn before the whole chat answers", async () => {
    const { source, asked } = fakeIndex(10, { window: () => ({ fromMs: 1_000, toMs: 2_000 }) });
    const view = render(loaded, source);
    act(() => view.find.show("retry"));
    await until(() => asked.length === 1, "the window search");
    expect(asked[0]!.search).toEqual({ query: "retry", window: { fromMs: 1_000, toMs: 2_000 }, limit: 50 });
    await act(async () => asked[0]!.answer({ hits: [{ at: 1_000, seq: 10, inWindow: true }, older[2]!] }));
    expect(view.find.index).toBe("window");
    expect(view.find.total).toBe(3);
    expect(view.find.busy).toBe(true);
    await until(() => asked.length === 2, "the whole-chat search");
    await act(async () => asked[1]!.answer({ hits: older }));
    expect(view.find.index).toBe("whole");
    expect(view.find.total).toBe(5);
  });

  test("a full page whose newest hit is not loaded reads the next page", async () => {
    const { source, asked } = fakeIndex(100_000);
    const view = render(loaded, source);
    act(() => view.find.show("retry"));
    await until(() => asked.length === 1, "the first page");
    const page = Array.from({ length: 200 }, (_, at) => ({ at, seq: at + 1 }));
    await act(async () => asked[0]!.answer({ hits: page, total: 250 }));
    await until(() => asked.length === 2, "the second page");
    expect(asked[1]!.search).toEqual({ query: "retry", limit: 200, offset: 200 });
    await act(async () =>
      asked[1]!.answer({ hits: Array.from({ length: 50 }, (_, at) => ({ at: 200 + at, seq: 201 + at })), total: 250 }),
    );
    expect(view.find.total).toBe(252);
  });

  test("an older query's answer is dropped", async () => {
    const { source, asked } = fakeIndex(10);
    const view = render(loaded, source);
    act(() => view.find.show("retr"));
    await until(() => asked.length === 1, "the first search");
    act(() => view.find.setQuery("retry"));
    await until(() => asked.length === 2, "the second search");
    await act(async () => asked[1]!.answer({ hits: [older[0]!] }));
    await act(async () => asked[0]!.answer({ hits: older }));
    expect(view.find.total).toBe(3);
  });

  test("a `find:` reveal makes the hit nearest its time current", async () => {
    const { source, asked, loads } = fakeIndex(10);
    const view = render(loaded, source);
    act(() => view.find.reveal({ query: "retry", atMs: 190 }));
    expect(view.find.open).toBe(true);
    expect(view.find.query).toBe("retry");
    await until(() => asked.length === 1, "the search");
    await act(async () => asked[0]!.answer({ hits: older }));
    expect(view.find.position).toBe(1);
    expect(view.find.pending?.seq).toBe(2);
    await until(() => loads.length === 1, "the load");
  });

  test("a daemon with no index leaves Find on the loaded rows", async () => {
    const { source, asked } = fakeIndex(10);
    const view = render(loaded, source);
    act(() => view.find.show("retry"));
    await until(() => asked.length === 1, "the search");
    await act(async () => asked[0]!.answer(undefined));
    expect(view.find.index).toBe("absent");
    expect(view.find.total).toBe(2);
    expect(view.find.busy).toBe(false);
    act(() => view.find.next());
    expect(view.find.active).toBe(1);
    act(() => view.find.next());
    expect(view.find.active).toBe(0);
  });

  test("without an index Find is as before", () => {
    const view = render(loaded);
    act(() => view.find.show("retry"));
    expect(view.find.index).toBe("none");
    expect(view.find.total).toBe(2);
    expect(view.find.busy).toBe(false);
    act(() => view.find.previous());
    expect(view.find.active).toBe(1);
  });
});

type Snapshot = { sessionId?: string; rows: AcpmuxRow[]; historyFrom?: number };

describe("on the mock daemon, through the real client", () => {
  async function openLongChat(turns: number) {
    const { AcpmuxDirectClient } = await import("../direct");
    const { MockAcpmuxSocket, mockHost } = await import("../mock");
    const state: { snapshot?: Snapshot } = {};
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (next) => {
        state.snapshot = next as unknown as Snapshot;
      },
      undefined,
      () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
    );
    const session = MockAcpmuxSocket.live!.seedLoadSession(turns);
    await client.select(session);
    return { client, state, session };
  }

  /// The pane's index over the client, as App.tsx builds it.
  const indexOver = (client: import("../direct").AcpmuxDirectClient, snapshot: Snapshot): FindIndexSource => ({
    key: snapshot.sessionId!,
    search: (search) => client.searchTranscript(search),
    ...(snapshot.historyFrom !== undefined && { holdsSeq: (seq: number) => snapshot.historyFrom! <= seq }),
    rowsOfMessage: (messageId) => client.rowsOfMessage(messageId),
    load: (hit) => (hit.seq !== undefined ? client.loadThrough(hit.seq) : client.loadToward(hit)),
  });

  async function findOldTurn(turns: number) {
    const container = mount();
    const { client, state } = await openLongChat(turns);
    try {
      let find: ChatFind | undefined;
      // The pane renders on each snapshot; here each wait's turn renders the latest one.
      function Find() {
        const snapshot = state.snapshot!;
        find = useChatFind(snapshot.rows, indexOver(client, snapshot));
        return null;
      }
      root = createRoot(container);
      const draw = () => act(() => root!.render(<Find />));
      const drawn = (check: () => boolean) => () => {
        draw();
        return check();
      };
      draw();
      expect(state.snapshot!.rows.some((each) => each.text?.startsWith("Turn 3:"))).toBe(false);
      act(() => find!.show("Turn 3: why"));
      await until(
        drawn(() => find!.index === "whole"),
        "the index answer",
      );
      expect(find!.total).toBe(1);
      await until(
        drawn(() => find!.active >= 0),
        "the old turn to load and its match to be current",
      );
      const current = state.snapshot!.rows[find!.matches[find!.active]!.rowIndex]!;
      expect(current.text).toStartWith("Turn 3: why");
      expect(find!.total).toBe(1);
      await until(
        drawn(() => !find!.busy),
        "the load to settle",
      );
    } finally {
      client.close();
    }
  }

  test("a hit the daemon placed by seq loads through it", async () => {
    await findOldTurn(400);
  });

  test("a hit with no seq loads by older pages toward its time", async () => {
    (globalThis as { cmuxAcpmuxMockTranscriptSearch?: string }).cmuxAcpmuxMockTranscriptSearch = "noSeq";
    await findOldTurn(120);
  });

  test("an acpmux with no index: Find reads the loaded rows alone", async () => {
    (globalThis as { cmuxAcpmuxMockTranscriptSearch?: string }).cmuxAcpmuxMockTranscriptSearch = "absent";
    mount();
    const { client, state } = await openLongChat(200);
    try {
      expect(await client.searchTranscript({ query: "Turn 3:", limit: 200 })).toBeUndefined();
      // The connection is not asked again.
      expect(await client.searchTranscript({ query: "Turn 4:", limit: 200 })).toBeUndefined();
      expect(state.snapshot!.rows.length).toBeGreaterThan(0);
    } finally {
      client.close();
    }
  });
});
