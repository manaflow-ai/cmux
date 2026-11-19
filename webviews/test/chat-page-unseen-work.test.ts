// cmux-web-test-timeout: 300
// l10n-allow-file: generated chats for a counting harness, not shipped UI.
// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?". A chat page
// did whole-list work for things no one on it sees: every snapshot sorted, stringified, parsed back and
// wrote all of acpmux's chats to the New Tab store (newtab/chatStore.ts) and filtered and sorted them
// for the next New Tab's folders (newtab/recentProject.ts); a hidden page (the spare, a background tab)
// sorted every chat and read 12 chats' pages ahead (direct.ts `scheduleReadAhead`); the reload copy was
// written every 250 ms (snapshotCache.ts); and each prompt image's whole data URL stayed in a map for the
// pane's life (direct.ts `promptImage`). Leo's daemon lists 10,790 chats and changes about 4 a second.
// This drives the real direct client over a fake acpmux with that list and 1,000 `session_changed`
// deltas, feeds each snapshot to what App.tsx feeds it (newtab/pageLists.ts), and counts: storage writes
// and bytes, sorts of the whole list, `_acpmux/events` reads while hidden, and held image strings.
//   bun test test/chat-page-unseen-work.test.ts      (CHAT_PAGE_SESSIONS=N to change the list size)
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { FakeDaemon, VirtualClock } from "../bench/stateGrowth";
import type { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const SESSIONS = Number(process.env.CHAT_PAGE_SESSIONS ?? 10_790);
const DELTAS = 1_000;
/// About 4 changes a second, as Leo's daemon sends (mostly other machines' chats).
const DELTA_MS = 250;
const IMAGES = 300;

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "localStorage", "sessionStorage", "navigator", "HTMLElement"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let hidden = false;

/// Every `setItem`, by storage, with its bytes.
const writes = { local: 0, localBytes: 0, session: 0, sessionBytes: 0 };
/// Sorts of an array as long as the whole list (90% of it or more).
let fullSorts = 0;
const sort = Array.prototype.sort;

beforeAll(() => {
  window = new JSDOM("<!doctype html>", { url: "https://pane.test/", pretendToBeVisual: true }).window;
  Object.defineProperty(window.document, "visibilityState", {
    configurable: true,
    get: () => (hidden ? "hidden" : "visible"),
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    localStorage: window.localStorage,
    sessionStorage: window.sessionStorage,
  });
  const proto = window.Storage.prototype;
  const setItem = proto.setItem;
  proto.setItem = function (this: Storage, key: string, value: string) {
    if (this === window.localStorage) {
      writes.local += 1;
      writes.localBytes += value.length;
    } else {
      writes.session += 1;
      writes.sessionBytes += value.length;
    }
    // Leo's list is past the 5 MB quota; the counts are what matter here, not jsdom's quota.
    try {
      setItem.call(this, key, value);
    } catch {
      // Over jsdom's quota.
    }
  };
  Array.prototype.sort = function (this: unknown[], compare?: (a: unknown, b: unknown) => number) {
    if (this.length >= SESSIONS * 0.9) fullSorts += 1;
    return sort.call(this, compare);
  } as typeof Array.prototype.sort;
});

afterAll(() => {
  Array.prototype.sort = sort;
  window.localStorage.clear();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  window.close();
});

function resetCounts(): void {
  Object.assign(writes, { local: 0, localBytes: 0, session: 0, sessionBytes: 0 });
  fullSorts = 0;
}

const BASE = Date.UTC(2026, 10, 18, 8, 0, 0);
/// Leo's list: a quarter child chats (another agent started them), some archived, most on other machines.
function summary(index: number, updatedAt: number): Record<string, any> {
  return {
    sessionId: `s-${index}`,
    name: `peer-${index % 30}/lane-${index}`,
    peer: index % 30 === 0 ? undefined : `peer-${index % 30}`,
    harness: "claude",
    cwd: `/Users/leo/src/repo-${index % 40}`,
    status: index % 7 === 0 ? "running" : "idle",
    createdAt: BASE + index,
    updatedAt,
    transcriptSeq: updatedAt,
    title: `chat ${index}`,
    ...(index % 4 === 1 && { spawnedBy: `s-${index - 1}` }),
    ...(index % 50 === 3 && { tags: ["archived"] }),
  };
}

/// A fake acpmux with the list, every chat a few records long, that also serves prompt images.
class Daemon extends FakeDaemon {
  /// Every request the client sent, by method.
  asked = new Map<string, string[]>();
  override answer(method: string, params: any): unknown {
    const ids = this.asked.get(method) ?? [];
    ids.push(String(params?.sessionId ?? ""));
    this.asked.set(method, ids);
    if (method === "_acpmux/attachment") return { mimeType: "image/png", data: "A".repeat(64 * 1024) + params.id };
    return super.answer(method, params);
  }
  record(sessionId: string, seq: number): any {
    return {
      seq,
      sessionId,
      kind: "transcript",
      at: BASE,
      direction: "out",
      payload: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `reply ${seq}` } } },
    };
  }
}

async function openPage(options: { hidden: boolean; showsNewTab: boolean }) {
  hidden = options.hidden;
  const clock = new VirtualClock().install();
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { keepListsForNewTab } = await import("../src/agent-session/acpmux/newtab/pageLists");
  AcpmuxDirectClient.scheduleFrame = (run) => {
    const id = setTimeout(run, 16);
    return () => clearTimeout(id);
  };
  const daemon = new Daemon();
  for (let index = 0; index < SESSIONS; index++) {
    const id = `s-${index}`;
    daemon.add(summary(index, BASE + index), [daemon.record(id, 1), daemon.record(id, 2)]);
  }
  let snapshots = 0;
  let posts = 0;
  const connecting = AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: "s-0" },
    (next: AcpmuxSnapshot) => {
      snapshots += 1;
      // What App.tsx's direct-client callback does with each snapshot of a page on this Mac's daemon.
      keepListsForNewTab(next, options.showsNewTab, () => (posts += 1));
    },
    undefined,
    daemon.open,
  );
  let client: AcpmuxDirectClient | undefined;
  void connecting.then((value) => (client = value));
  for (let step = 0; step < 400 && !client; step++) await clock.advance(10);
  client ??= await connecting;
  await clock.advance(2_000);
  return { clock, daemon, client, snapshots: () => snapshots, posts: () => posts };
}

/// 1,000 changes of other chats, the newest chats' among them (they are the ones read ahead).
async function deltas(page: Awaited<ReturnType<typeof openPage>>): Promise<number> {
  const started = performance.now();
  for (let change = 0; change < DELTAS; change++) {
    const index = change % 3 === 0 ? SESSIONS - 1 - (change % 24) : 1 + ((change * 7919) % (SESSIONS - 1));
    page.daemon.changed(summary(index, BASE + SESSIONS + change));
    await page.clock.advance(DELTA_MS);
  }
  return performance.now() - started;
}

/// The image data URLs reachable from `root` through its fields, Maps, Sets and arrays.
function heldImageStrings(root: object, depth = 5): number {
  const seen = new Set<unknown>();
  let held = 0;
  const visit = (value: unknown, left: number): void => {
    if (typeof value === "string") {
      if (value.startsWith("data:image/") && !seen.has(value)) {
        seen.add(value);
        held += 1;
      }
      return;
    }
    if (!value || typeof value !== "object" || seen.has(value) || left < 0) return;
    seen.add(value);
    if (value instanceof Map) {
      for (const [key, item] of value) {
        visit(key, left - 1);
        visit(item, left - 1);
      }
    } else if (value instanceof Set || Array.isArray(value)) for (const item of value) visit(item, left - 1);
    else for (const key of Object.keys(value)) visit((value as Record<string, unknown>)[key], left - 1);
  };
  visit(root, depth);
  return held;
}

function close(page: Awaited<ReturnType<typeof openPage>>): void {
  page.client.close?.();
  page.clock.uninstall();
}

test("a shown chat page writes no localStorage and sorts no whole list for New Tabs it does not show", async () => {
  const { reloadChatStoreForTests } = await import("../src/agent-session/acpmux/newtab/chatStore");
  const { resetRecentProjectForTests } = await import("../src/agent-session/acpmux/newtab/recentProject");
  reloadChatStoreForTests();
  resetRecentProjectForTests();
  window.localStorage.clear();
  const page = await openPage({ hidden: false, showsNewTab: false });
  resetCounts();
  const snapshotsBefore = page.snapshots();
  const ms = await deltas(page);
  const snapshots = page.snapshots() - snapshotsBefore;
  console.log(
    `shown chat page, ${SESSIONS} chats, ${DELTAS} deltas: snapshots=${snapshots} localStorage writes=${writes.local} ` +
      `bytes=${writes.localBytes} full-list sorts=${fullSorts} warm posts=${page.posts()} ms=${ms.toFixed(0)}`,
  );
  close(page);
  // The page drew the changes: the budget is about what it did for other pages, not whether it ran.
  expect(snapshots).toBeGreaterThan(DELTAS / 2);
  expect(writes.local).toBe(0);
  expect(page.posts()).toBe(0);
  expect(fullSorts).toBe(0);
  // Going away, it leaves its folders for the next New Tab once: one small write, not a list.
  resetCounts();
  window.dispatchEvent(new window.Event("pagehide"));
  expect(writes.local).toBeLessThanOrEqual(1);
  expect(writes.localBytes).toBeLessThan(4_096);
});

test("a hidden page reads no chat ahead, and once shown reads only top-level listed chats", async () => {
  const page = await openPage({ hidden: true, showsNewTab: true });
  page.daemon.asked.clear();
  resetCounts();
  await deltas(page);
  const hiddenReads = page.daemon.asked.get("_acpmux/events")?.length ?? 0;
  const hiddenSorts = fullSorts;
  hidden = false;
  window.document.dispatchEvent(new window.Event("visibilitychange"));
  await page.clock.advance(5_000);
  const shownReads = page.daemon.asked.get("_acpmux/events")?.slice(hiddenReads) ?? [];
  console.log(
    `hidden page, ${SESSIONS} chats, ${DELTAS} deltas: _acpmux/events reads=${hiddenReads} full-list sorts=${hiddenSorts}; ` +
      `on show: reads=${shownReads.length}`,
  );
  close(page);
  expect(hiddenReads).toBe(0);
  // Showing the page reads the recent chats a switch lands on, never a child chat or an archived one.
  expect(shownReads.length).toBeGreaterThan(0);
  expect(shownReads.length).toBeLessThanOrEqual(12);
  for (const id of shownReads) {
    const index = Number(id.slice(2));
    expect({ id, child: index % 4 === 1, archived: index % 50 === 3 }).toEqual({ id, child: false, archived: false });
  }
});

test("300 prompt images read leave no data URL held by the client", async () => {
  const page = await openPage({ hidden: false, showsNewTab: false });
  for (let index = 0; index < IMAGES; index++) {
    const read = page.client.promptImage(`image-${index}`);
    await page.clock.advance(1);
    expect((await read)?.startsWith("data:image/png;base64,")).toBe(true);
  }
  const held = heldImageStrings(page.client);
  console.log(`prompt images: ${IMAGES} read, data URLs the client still holds: ${held}`);
  close(page);
  // The bounded sent-image cache (conversation/imageEntries.ts) keeps what a bubble draws; the client none.
  expect(held).toBe(0);
});

test("a shown page's streaming snapshots write no reload copy until it hides", async () => {
  hidden = false;
  const { saveSnapshot } = await import("../src/agent-session/acpmux/snapshotCache");
  const clock = new VirtualClock().install();
  resetCounts();
  const sessions = Array.from({ length: SESSIONS }, (_, index) => ({ sessionId: `s-${index}`, activityAt: index }));
  const started = performance.now();
  for (let frame = 0; frame < DELTAS; frame++) {
    saveSnapshot({
      type: "snapshot",
      protocolVersion: 1,
      sessionId: "s-0",
      rows: [{ id: "reply", kind: "assistant", text: `word `.repeat(frame + 1) }],
      sessions,
    } as unknown as AcpmuxSnapshot);
    await clock.advance(DELTA_MS);
  }
  const ms = performance.now() - started;
  const shown = { writes: writes.session, bytes: writes.sessionBytes };
  clock.uninstall();
  hidden = true;
  window.document.dispatchEvent(new window.Event("visibilitychange"));
  hidden = false;
  console.log(
    `reload copy, ${DELTAS} snapshots over ${(DELTAS * DELTA_MS) / 1000} s shown: sessionStorage writes=${shown.writes} ` +
      `bytes=${shown.bytes} ms=${ms.toFixed(0)}; on hide: writes=${writes.session - shown.writes}`,
  );
  expect(shown.writes).toBe(0);
  expect(writes.session).toBe(1);
});
