import { afterEach, describe, expect, test } from "bun:test";
import { chatMini, miniRow, readChatMini, setChatMiniHost, showInMini } from "./miniRow";

const t = (key: string) => key;

afterEach(() => setChatMiniHost(undefined));

/// A host whose mini shows the Chief (null) or one chat, as `agent.mini` and `agent.mini.show` do.
function host(start: string | null = null) {
  const state = { shown: start, calls: [] as [string, Record<string, unknown>][] };
  setChatMiniHost(async (method, params) => {
    state.calls.push([method, params]);
    if (method === "agent.mini") return { sessionId: state.shown };
    if (method === "agent.mini.show") {
      state.shown = params.sessionId as string | null;
      return {};
    }
    throw new Error("unsupported");
  });
  return state;
}

describe("Show in Mini (header/miniRow.ts)", () => {
  test("a chat offers Show in Mini while the mini shows the Chief or another chat", () => {
    const picked: (string | null)[] = [];
    for (const mini of [null, "other"]) {
      const rows = miniRow({ sessionId: "s1", mini }, (id) => picked.push(id), t);
      expect(rows.map((row) => [row.key, row.label])).toEqual([["showInMini", "chatMenu.showInMini"]]);
      rows[0]?.onSelect?.();
    }
    expect(picked).toEqual(["s1", "s1"]);
  });

  test("the chat the mini shows offers Show Chief in Mini, which picks the Chief (null)", () => {
    const picked: (string | null)[] = [];
    const rows = miniRow({ sessionId: "s1", mini: "s1" }, (id) => picked.push(id), t);
    expect(rows.map((row) => [row.key, row.label])).toEqual([["showChiefInMini", "chatMenu.showChiefInMini"]]);
    rows[0]?.onSelect?.();
    expect(picked).toEqual([null]);
  });

  test("no row without a session or before the host answers (an older app)", () => {
    expect(miniRow({ sessionId: undefined, mini: null }, () => undefined, t)).toEqual([]);
    expect(miniRow({ sessionId: "s1", mini: undefined }, () => undefined, t)).toEqual([]);
  });

  test("reads what the mini shows, and a pick reads it again", async () => {
    const state = host(null);
    await readChatMini();
    expect(chatMini()).toBeNull();
    await showInMini("s1");
    expect(chatMini()).toBe("s1");
    await showInMini(null);
    expect(chatMini()).toBeNull();
    expect(state.calls).toEqual([
      ["agent.mini", {}],
      ["agent.mini.show", { sessionId: "s1" }],
      ["agent.mini", {}],
      ["agent.mini.show", { sessionId: null }],
      ["agent.mini", {}],
    ]);
  });

  test("a refused or unreadable answer hides the row", async () => {
    host("s1");
    await readChatMini();
    expect(chatMini()).toBe("s1");
    setChatMiniHost(async () => {
      throw Object.assign(new Error("unsupported"), { code: "unsupported" });
    });
    await readChatMini();
    expect(chatMini()).toBeUndefined();
    setChatMiniHost(async () => ({ shown: "s1" }));
    await readChatMini();
    expect(chatMini()).toBeUndefined();
  });

  test("a slow read never undoes a later answer", async () => {
    let release: (value: unknown) => void = () => undefined;
    let first = true;
    setChatMiniHost((method) => {
      if (method !== "agent.mini") return Promise.resolve({});
      if (first) {
        first = false;
        return new Promise((resolve) => (release = resolve));
      }
      return Promise.resolve({ sessionId: "s2" });
    });
    const slow = readChatMini();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await readChatMini();
    expect(chatMini()).toBe("s2");
    release({ sessionId: null });
    await slow;
    expect(chatMini()).toBe("s2");
  });
});
