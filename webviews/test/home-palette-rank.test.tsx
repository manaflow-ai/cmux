// The Channels Cmd-K palette ranks through the page client (`cmux.home.paletteRank`, the daemon's
// palette.rank): it shows the rows in order before the first answer, keeps the last answer on screen
// until the next one arrives, and drops an answer for an older query. A catalog past one request's
// caps ranks in several requests, and the caps hold any title and name the app allows.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import table from "../src/pages/home-channels/generated/strings.json";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const { Palette } = await import("../src/pages/home-channels/Palette");
const { clipUtf8, fixtureRank } = await import("../src/pages/home-channels/paletteRank");
const { MockHomeProvider } = await import("../src/pages/home-channels/mockProvider");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");
const { createStrings } = await import("../src/pages/shared/i18n");
const strings = createStrings(table, ["en"]);
type Request = import("../src/pages/home-channels/paletteRank").PaletteRankRequest;
type Reply = import("../src/pages/home-channels/paletteRank").PaletteRankReply;

const items = ["general", "Release train", "random"].map((title, index) => ({
  id: `c${index}`,
  group: "conversations" as const,
  title,
  run() {},
}));

/** A rank function whose answers the test releases one by one, in any order. */
function heldRanker() {
  const asked: Array<{ request: Request; answer(reply: Reply): void }> = [];
  const rank = (request: Request) => new Promise<Reply>((resolve) => asked.push({ request, answer: resolve }));
  return { asked, rank };
}

function shown(): string[] {
  return [...host.ownerDocument.querySelectorAll("[role='option'] .lg-palette-title")].map(
    (node) => node.textContent ?? "",
  );
}

async function type(value: string) {
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, value);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

/** The reply that ranks the rows at `indexes` in that order. */
const reply = (...indexes: number[]): Reply => ({
  sections: [{ sectionIndex: 0, rows: indexes.map((index) => ({ index, score: 1, highlights: [] })) }],
});

test("the palette keeps the last answer until the next and drops an older query's", async () => {
  const ranker = heldRanker();
  root = createRoot(host);
  await act(async () => root!.render(createElement(Palette, { items, rank: ranker.rank, strings, onClose() {} })));
  // Before any answer: the rows in their order, never an empty list.
  expect(shown()).toEqual(["general", "Release train", "random"]);
  expect(ranker.asked.map((ask) => ask.request.query)).toEqual([""]);
  expect(ranker.asked[0]!.request.keepsSectionOrder).toBe(true);

  await type("r");
  await type("re");
  expect(ranker.asked.map((ask) => ask.request.query)).toEqual(["", "r", "re"]);
  // Nothing answered yet: the first frame's rows stay.
  expect(shown()).toEqual(["general", "Release train", "random"]);

  // The newest query answers first, then the older one: the older answer is dropped.
  await act(async () => ranker.asked[2]!.answer(reply(1)));
  expect(shown()).toEqual(["Release train"]);
  await act(async () => ranker.asked[1]!.answer(reply(2, 1)));
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  expect(shown()).toEqual(["Release train"]);

  // A new query keeps the shown answer until its own arrives.
  await type("rel");
  expect(shown()).toEqual(["Release train"]);
  await act(async () => ranker.asked[3]!.answer(reply()));
  expect(shown()).toEqual([]);
});

test("a failed rank falls back to the substring filter, not to no rows", async () => {
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items,
        rank: () => Promise.reject(new Error("daemon went away")),
        strings,
        onClose() {},
      }),
    ),
  );
  await type("RAN");
  expect(shown()).toEqual(["random"]);
});

test("the fixture ranker keeps the rows in order, filtered by a case-insensitive substring", async () => {
  const entries = [
    { title: "general", sectionIndex: 0 },
    { title: "Fix it", keywords: ["Release"], sectionIndex: 1 },
    { title: "Release train", sectionIndex: 0 },
  ];
  expect(fixtureRank({ entries, query: "" }).sections.map((section) => section.rows.map((row) => row.index))).toEqual([
    [0, 2],
    [1],
  ]);
  expect(fixtureRank({ entries, query: "release" }).sections).toEqual([
    { sectionIndex: 0, rows: [{ index: 2, score: 0, highlights: [] }] },
    { sectionIndex: 1, rows: [{ index: 1, score: 0, highlights: [] }] },
  ]);
  // The mock provider (gallery and dev loop) answers the op with it.
  const mocked = await new MockHomeProvider().call<Reply>(HomeOps.paletteRank, { entries, query: "TRAIN" });
  expect(mocked).toEqual({
    sections: [{ sectionIndex: 0, rows: [{ index: 2, score: 0, highlights: [] }] }],
  });
});

test("a row that changes while an answer is on its way runs its current action", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  const rows = (label: string) => items.map((item) => ({ ...item, run: () => void ran.push(`${label}:${item.id}`) }));
  root = createRoot(host);
  const render = (list: ReturnType<typeof rows>) =>
    act(async () => root!.render(createElement(Palette, { items: list, rank: ranker.rank, strings, onClose() {} })));
  await render(rows("old"));
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  // The rows change (one leaves) before their new answer arrives.
  await render(rows("new").filter((item) => item.id !== "c2"));
  expect(shown()).toEqual(["general", "Release train"]);
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  // The new rows are being ranked: Enter waits for that answer, then runs the row's current action.
  expect(ran).toEqual([]);
  await act(async () => ranker.asked[1]!.answer(reply(0, 1)));
  expect(ran).toEqual(["new:c0"]);
});

test("Enter before the current query's answer waits for it and runs its top row", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  let closed = 0;
  const list = items.map((item) => ({ ...item, run: () => void ran.push(item.id) }));
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items: list,
        rank: ranker.rank,
        strings,
        onClose: () => void (closed += 1),
      }),
    ),
  );
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  await type("release");
  // The empty query's rows are still on screen; Enter must not run "general".
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(ran).toEqual([]);
  expect(closed).toBe(0);
  await act(async () => ranker.asked[1]!.answer(reply(1)));
  expect(ran).toEqual(["c1"]);
  expect(closed).toBe(1);
});

test("a row clicked while an answer is on its way runs that row, not the answer's top row", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  const list = items.map((item) => ({ ...item, run: () => void ran.push(item.id) }));
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items: list,
        rank: ranker.rank,
        strings,
        onClose() {},
      }),
    ),
  );
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  await type("release");
  // The empty query's rows are still on screen; the person clicks "random" among them.
  const random = [...host.ownerDocument.querySelectorAll<HTMLElement>("[role='option']")].find(
    (row) => row.querySelector(".lg-palette-title")?.textContent === "random",
  )!;
  await act(async () => {
    random.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, detail: 1 }));
  });
  expect(ran).toEqual(["c2"]);
  await act(async () => ranker.asked[1]!.answer(reply(1)));
  expect(ran).toEqual(["c2"]);
});

test("an edit after an early Enter cancels it: the new query's answer runs nothing", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  const list = items.map((item) => ({ ...item, run: () => void ran.push(item.id) }));
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items: list,
        rank: ranker.rank,
        strings,
        onClose() {},
      }),
    ),
  );
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  await type("release");
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  await type("ran");
  await act(async () => ranker.asked[1]!.answer(reply(1)));
  await act(async () => ranker.asked[2]!.answer(reply(2)));
  expect(ran).toEqual([]);
});

test("Enter after typing away and back waits for the newest answer, not the older one for the same text", async () => {
  const ranker = heldRanker();
  const ran: string[] = [];
  const list = items.map((item) => ({ ...item, run: () => void ran.push(item.id) }));
  root = createRoot(host);
  await act(async () =>
    root!.render(
      createElement(Palette, {
        items: list,
        rank: ranker.rank,
        strings,
        onClose() {},
      }),
    ),
  );
  await act(async () => ranker.asked[0]!.answer(reply(0, 1, 2)));
  await type("release");
  await act(async () => ranker.asked[1]!.answer(reply(0)));
  await type("ran");
  await type("release");
  // On screen: the answer to the first "release" request; a newer one is on its way.
  const field = host.ownerDocument.querySelector<HTMLInputElement>(".lg-palette input")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(ran).toEqual([]);
  await act(async () => ranker.asked[3]!.answer(reply(1)));
  expect(ran).toEqual(["c1"]);
});

test("the request is clipped to the daemon's byte caps on a character boundary", () => {
  expect(clipUtf8("short", 512)).toBe("short");
  const long = "é".repeat(300); // 600 bytes
  expect(new TextEncoder().encode(clipUtf8(long, 512)).length).toBe(512);
  expect(clipUtf8("a😀", 4)).toBe("a");
});

type Entry = import("../src/pages/home-channels/paletteRank").PaletteRankEntry;
type Json = Record<string, unknown>;
const utf8 = (text: string) => new TextEncoder().encode(text).length;

/** The daemon's palette.rank bounds: the catalog's caps on a request and on each entry, and the
 * WebSocket's 4 MiB inbound message; a v1 daemon (before palette-rank-v2) has smaller text caps. */
const DAEMONS = {
  2: { entries: 5000, titleBytes: 1024, keywords: 64, keywordBytes: 400, messageBytes: 4 * 1024 * 1024 },
  1: { entries: 5000, titleBytes: 512, keywords: 32, keywordBytes: 256, messageBytes: 4 * 1024 * 1024 },
};

/**
 * A daemon whose palette.rank refuses a request past its bounds (as the catalog does) and ranks
 * by substring, case-insensitive: a title that starts with the query scores 10000, a title or
 * keyword that contains it 4000 (a strict match). Its typo pass (`typoPass: true`, or absent with
 * fewer than three strict matches) also finds a title that contains the query without its last
 * letter, at 3000. Rows sort by score, then entry order, cut to the row limit (400). A v1 daemon
 * refuses `typoPass`, as its catalog has no such field.
 */
function rankingDaemon(version: 1 | 2 = 2) {
  const DAEMON = DAEMONS[version];
  const requests: Json[] = [];
  const socket = {
    async request(command: string): Promise<unknown> {
      if (command === "identify")
        return { capabilities: version === 2 ? ["palette-rank-v1", "palette-rank-v2"] : ["palette-rank-v1"] };
      return {};
    },
    async operation(operation: string, params: Json): Promise<unknown> {
      expect(operation).toBe("palette.rank");
      requests.push(params);
      const entries = params.entries as Entry[];
      const message = JSON.stringify({ protocol: "cmux.protocol/2", type: "request", id: "op-1", operation, params });
      if (
        (version === 1 && "typoPass" in params) ||
        entries.length > DAEMON.entries ||
        utf8(message) > DAEMON.messageBytes ||
        entries.some(
          (entry) =>
            utf8(entry.title) > DAEMON.titleBytes ||
            (entry.keywords?.length ?? 0) > DAEMON.keywords ||
            entry.keywords?.some((keyword) => utf8(keyword) > DAEMON.keywordBytes),
        )
      )
        throw Object.assign(new Error("past the caps"), { code: "validation.invalid" });
      const query = String(params.query).trim().toLowerCase();
      const section = (entry: Entry) => entry.sectionIndex ?? 0;
      if (!query) {
        const bySection = new Map<number, Array<{ index: number; score: number; highlights: number[] }>>();
        entries.forEach((entry, index) => {
          if (!bySection.has(section(entry))) bySection.set(section(entry), []);
          bySection.get(section(entry))!.push({ index, score: 0, highlights: [] });
        });
        return {
          sections: [...bySection].sort(([a], [b]) => a - b).map(([sectionIndex, rows]) => ({ sectionIndex, rows })),
          strictMatches: 0,
        };
      }
      const strict = (entry: Entry) =>
        entry.title.toLowerCase().startsWith(query)
          ? 10_000
          : [entry.title, ...(entry.keywords ?? [])].some((word) => word.toLowerCase().includes(query))
            ? 4_000
            : 0;
      const strictMatches = entries.filter((entry) => strict(entry) > 0).length;
      const typo = params.typoPass === true || (params.typoPass == null && strictMatches < 3);
      const scored = entries.flatMap((entry, index) => {
        const score = strict(entry) || (typo && entry.title.toLowerCase().includes(query.slice(0, -1)) ? 3_000 : 0);
        return score ? [{ index, score, section: section(entry) }] : [];
      });
      scored.sort((a, b) => b.score - a.score || a.index - b.index);
      const order: number[] = [];
      const bySection = new Map<number, Array<{ index: number; score: number; highlights: number[] }>>();
      for (const row of scored.slice(0, Number(params.rowLimit ?? 400))) {
        if (!bySection.has(row.section)) {
          bySection.set(row.section, []);
          order.push(row.section);
        }
        bySection.get(row.section)!.push({ index: row.index, score: row.score, highlights: [] });
      }
      if (params.keepsSectionOrder === true) order.sort((a, b) => a - b);
      return {
        sections: order.map((sectionIndex) => ({ sectionIndex, rows: bySection.get(sectionIndex)! })),
        strictMatches,
      };
    },
    onEvent: () => () => {},
    onClose: () => () => {},
  } as unknown as import("../src/pages/shared/daemonSocket").DaemonSocket;
  const client = new DaemonHomeClient(socket);
  const rank = (entries: Entry[], query: string) =>
    client.call<Reply>(HomeOps.paletteRank, { entries, query, keepsSectionOrder: true });
  return { requests, rank };
}

/** 5,000 conversations, then a thread and the actions: every row past the first request's cap. */
function bigCatalog(): Entry[] {
  const conversations = Array.from({ length: 5000 }, (_, index) => ({
    title: `Conversation ${index}`,
    keywords: [`person ${index % 97}`],
    sectionIndex: 0,
    isVisibleWhenQueryEmpty: true,
  }));
  return [
    ...conversations,
    { title: "Fix the release notes", sectionIndex: 1, isVisibleWhenQueryEmpty: true },
    { title: "New message", keywords: ["Add channel"], sectionIndex: 2, isVisibleWhenQueryEmpty: true },
    { title: "Next unread", sectionIndex: 2, isVisibleWhenQueryEmpty: true },
  ];
}

const ranked = (reply: Reply) =>
  reply.sections.map((section) => [section.sectionIndex, section.rows.map((row) => row.index)] as const);

test("an action past the 5,000-entry request cap is still found, and the empty query lists every row", async () => {
  const daemon = rankingDaemon();
  const entries = bigCatalog();
  expect(ranked(await daemon.rank(entries, "New message"))).toEqual([[2, [5001]]]);
  expect(ranked(await daemon.rank(entries, "next unread"))).toEqual([[2, [5002]]]);
  const empty = await daemon.rank(entries, "");
  expect(empty.sections.map((section) => section.rows.length)).toEqual([5000, 1, 2]);
  expect(empty.sections[0]!.rows.map((row) => row.index)).toEqual(entries.slice(0, 5000).map((_, index) => index));
  for (const request of daemon.requests) expect((request.entries as Entry[]).length).toBeLessThanOrEqual(5000);
});

test("rows ranked in several requests merge by score across them, cut to the row limit", async () => {
  const daemon = rankingDaemon();
  const entries = bigCatalog();
  entries[3] = { ...entries[3]!, title: "Pre-release" };
  entries.push({ title: "Release train", sectionIndex: 0, isVisibleWhenQueryEmpty: true });
  entries.push({ title: "Conversation archive", sectionIndex: 0, isVisibleWhenQueryEmpty: true });
  // "release": a conversation's title contains it (4000) in the first request, another's starts
  // with it (10000) in the second. Sections keep their order; rows inside one follow the scores.
  expect(ranked(await daemon.rank(entries, "release"))).toEqual([
    [0, [5003, 3]],
    [1, [5000]],
  ]);
  // "conversation" starts 5,000 titles across both requests: the ranker's 400 best, in entry order.
  const best = entries.flatMap((entry, index) => (entry.title.startsWith("Conversation") ? [index] : []));
  expect(ranked(await daemon.rank(entries, "conversation"))).toEqual([[0, best.slice(0, 400)]]);
});

test("the requests decide the typo pass together, as one request over the whole catalog would", async () => {
  const daemon = rankingDaemon();
  const entries = bigCatalog();
  entries.push({ title: "Releasx plan", sectionIndex: 1, isVisibleWhenQueryEmpty: true });
  entries.push({ title: "Profile settings", sectionIndex: 2, isVisibleWhenQueryEmpty: true });
  for (const index of [10, 20, 30]) entries[index] = { ...entries[index]!, title: `Fix ${index}` };
  // "release" matches one row strictly in the whole catalog (fewer than three): every request
  // ranks again with the typo pass, which finds "Releasx plan".
  expect(ranked(await daemon.rank(entries, "release"))).toEqual([[1, [5000, 5003]]]);
  expect(daemon.requests.map((request) => request.typoPass)).toEqual([false, false, true, true]);
  daemon.requests.length = 0;
  // "fix" matches three rows strictly in the first request and one in the second: no typo pass
  // anywhere, though the second alone (one strict match) would have run it and added "Profile".
  expect(ranked(await daemon.rank(entries, "fix"))).toEqual([
    [0, [10, 20, 30]],
    [1, [5000]],
  ]);
  expect(daemon.requests.map((request) => request.typoPass)).toEqual([false, false]);
});

test("each request stays under the daemon's 4 MiB message, with every name whole", async () => {
  const daemon = rankingDaemon();
  // 64 participants of 100 characters each: 6,400 characters of keywords per conversation.
  const names = (index: number) => Array.from({ length: 64 }, (_, at) => `${index}-${at}-${"n".repeat(90)}`);
  const entries: Entry[] = Array.from({ length: 1000 }, (_, index) => ({
    title: `Room ${index}`,
    keywords: names(index),
    sectionIndex: 0,
  }));
  expect(ranked(await daemon.rank(entries, `999-63-${"n".repeat(90)}`))).toEqual([[0, [999]]]);
  expect(daemon.requests.length).toBeGreaterThan(1);
});

test("a 200-character CJK title and a 100-character CJK name reach the daemon whole", async () => {
  const daemon = rankingDaemon();
  // 198 characters, 578 UTF-8 bytes: "Release" ends past byte 512.
  const title = `${"发".repeat(190)} Release`;
  const name = "名".repeat(100);
  const entries: Entry[] = [
    { title: "general", sectionIndex: 0 },
    { title, sectionIndex: 0 },
    { title: `#${"😀".repeat(200)}`, keywords: [name], sectionIndex: 0 },
  ];
  expect(ranked(await daemon.rank(entries, "Release"))).toEqual([[0, [1]]]);
  expect(ranked(await daemon.rank(entries, name))).toEqual([[0, [2]]]);
  const sent = daemon.requests[0]!.entries as Entry[];
  expect(sent[1]!.title).toBe(title);
  expect(sent[2]!.title).toBe(entries[2]!.title);
  expect(sent[2]!.keywords).toEqual([name]);
});

test("a v1 daemon gets requests it takes: its own caps, no typoPass, every row still searchable", async () => {
  const daemon = rankingDaemon(1);
  const entries = bigCatalog();
  // A conversation of 33 participants with long names, and a title past v1's 512 bytes.
  entries[0] = {
    title: `Release train ${"发".repeat(190)}`,
    keywords: Array.from({ length: 33 }, (_, index) => `${index}${"名".repeat(99)}`),
    sectionIndex: 0,
  };
  expect(ranked(await daemon.rank(entries, "release train"))).toEqual([[0, [0]]]);
  expect(ranked(await daemon.rank(entries, "New message"))).toEqual([[2, [5001]]]);
  for (const request of daemon.requests) expect("typoPass" in request).toBe(false);
});
