// A page saves its state when it hides (visibilitychange), never when the host discards it: a frozen
// page cannot answer the host (p13-webui-088).
import { describe, expect, test } from "bun:test";
import {
  PAGE_STATE_KEY,
  PAGE_STATE_MAX_BYTES,
  type PageStateHost,
  readPageState,
  savePageStateOnHide,
  writePageState,
} from "./pageLifecycle";

type Listener = () => void;

/** A document whose visibility the test sets, a Map as sessionStorage and a log of host posts. */
function makeHost(): {
  host: PageStateHost;
  posts: string[];
  stored: Map<string, string>;
  setVisibility(state: DocumentVisibilityState): void;
  listenerCount(): number;
} {
  let visibility: DocumentVisibilityState = "visible";
  const listeners = new Set<Listener>();
  const stored = new Map<string, string>();
  const posts: string[] = [];
  const document = {
    get visibilityState() {
      return visibility;
    },
    addEventListener: (type: string, listener: Listener) => {
      if (type === "visibilitychange") listeners.add(listener);
    },
    removeEventListener: (type: string, listener: Listener) => {
      if (type === "visibilitychange") listeners.delete(listener);
    },
  } as unknown as PageStateHost["document"];
  const storage = {
    getItem: (key: string) => stored.get(key) ?? null,
    setItem: (key: string, value: string) => void stored.set(key, value),
    removeItem: (key: string) => void stored.delete(key),
  };
  return {
    host: { document, storage, post: (json) => posts.push(json) },
    posts,
    stored,
    setVisibility(state) {
      visibility = state;
      for (const listener of listeners) listener();
    },
    listenerCount: () => listeners.size,
  };
}

describe("pageLifecycle hide-time save", () => {
  test("the state is saved on the hide, not before and not on the show", () => {
    const page = makeHost();
    let scroll = 10;
    let saves = 0;
    savePageStateOnHide(() => {
      saves += 1;
      return { scroll };
    }, page.host);
    expect(saves).toBe(0);
    scroll = 120;
    page.setVisibility("hidden");
    expect(saves).toBe(1);
    expect(page.stored.get(PAGE_STATE_KEY)).toBe('{"scroll":120}');
    expect(page.posts).toEqual(['{"scroll":120}']);
    page.setVisibility("visible");
    expect(saves).toBe(1);
    expect(readPageState<{ scroll: number }>(page.host)).toEqual({ scroll: 120 });
  });

  test("the stop function removes the one listener", () => {
    const page = makeHost();
    const stop = savePageStateOnHide(() => ({}), page.host);
    expect(page.listenerCount()).toBe(1);
    stop();
    expect(page.listenerCount()).toBe(0);
    page.setVisibility("hidden");
    expect(page.posts).toEqual([]);
  });

  test("an oversized state clears the older one everywhere", () => {
    const page = makeHost();
    expect(writePageState({ query: "a" }, page.host)).toBe(true);
    expect(writePageState({ text: "x".repeat(PAGE_STATE_MAX_BYTES) }, page.host)).toBe(false);
    expect(page.stored.has(PAGE_STATE_KEY)).toBe(false);
    expect(page.posts).toEqual(['{"query":"a"}', "null"]);
    expect(readPageState(page.host)).toBeUndefined();
  });

  test("the limit counts UTF-8 bytes, not UTF-16 units", () => {
    const page = makeHost();
    // Each "é" is one UTF-16 unit and two UTF-8 bytes: about 40 K units is about 80 KB.
    expect(writePageState("é".repeat(40_000), page.host)).toBe(false);
  });

  test("a page with no host still saves to sessionStorage", () => {
    const page = makeHost();
    const host: PageStateHost = { ...page.host, post: null };
    expect(writePageState([1, 2], host)).toBe(true);
    expect(readPageState<number[]>(host)).toEqual([1, 2]);
  });

  test("an unreadable saved state reads as none", () => {
    const page = makeHost();
    page.stored.set(PAGE_STATE_KEY, "{not json");
    expect(readPageState(page.host)).toBeUndefined();
  });
});
