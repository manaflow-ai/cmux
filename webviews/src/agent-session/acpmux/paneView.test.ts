import { expect, test } from "bun:test";
import type { PageClient, PageHandler } from "../../pages/shared/pageClient";
import { handleForPage, scopedPageClient } from "./paneView";

function fakeBase() {
  const calls: { op: string; params: unknown }[] = [];
  const subs: { stream: string; filter?: Record<string, unknown> }[] = [];
  const handlers = new Map<string, PageHandler>();
  const base: PageClient = {
    call: async <R>(op: string, params: unknown) => {
      calls.push({ op, params });
      return undefined as R;
    },
    subscribe: async (stream, _onEvent, filter) => {
      subs.push({ stream, filter });
      return () => {};
    },
    handle: (op, handler) => {
      handlers.set(op, handler);
      return () => handlers.delete(op);
    },
  };
  return { base, calls, subs, handlers };
}

test("a null view is the base client itself", () => {
  const { base } = fakeBase();
  expect(scopedPageClient(base, null)).toBe(base);
});

test("a view's calls and subscriptions carry its view", async () => {
  const { base, calls, subs } = fakeBase();
  const a = scopedPageClient(base, "a");
  await a.call("cmux.agent.send", { text: "hi" });
  await a.call("cmux.agent.handshake", undefined);
  await a.subscribe("cmux.agent.host.events", () => {}, { kind: "x" });
  expect(calls).toEqual([
    { op: "cmux.agent.send", params: { text: "hi", view: "a" } },
    { op: "cmux.agent.handshake", params: { view: "a" } },
  ]);
  expect(subs).toEqual([{ stream: "cmux.agent.host.events", filter: { kind: "x", view: "a" } }]);
});

test("a host call goes to the view it names, else the page's handler", async () => {
  const { base, handlers } = fakeBase();
  const seen: string[] = [];
  const offA = scopedPageClient(base, "a").handle("op", () => seen.push("a"));
  scopedPageClient(base, "b").handle("op", () => seen.push("b"));
  handleForPage(base, "op", () => seen.push("page"));
  const route = handlers.get("op")!;
  await route({ view: "b" });
  await route({ view: "a" });
  await route({});
  expect(seen).toEqual(["b", "a", "page"]);
  offA();
  expect(() => route({ view: "a" })).toThrow();
});

test("the base handler goes when the last view lets go", () => {
  const { base, handlers } = fakeBase();
  const offA = scopedPageClient(base, "a").handle("op", () => 1);
  const offB = scopedPageClient(base, "b").handle("op", () => 2);
  offA();
  expect(handlers.has("op")).toBe(true);
  offB();
  expect(handlers.has("op")).toBe(false);
});
