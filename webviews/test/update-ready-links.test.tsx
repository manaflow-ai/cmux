import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";

test("the ready surface keeps one PR chip in both lists and routes the shared card to its page host", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/ready" });
  const scope = globalThis as Record<string, unknown>;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
      unobserve() {}
    },
    requestAnimationFrame: () => 0,
  };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const data: UpdateHighlights = {
    version: "1.0.0-nightly.42",
    build: "42",
    fromVersion: "1.0.0-nightly.41",
    fromBuild: "41",
    source: "whatsNew",
    language: "en",
    moreCount: 1,
    items: [
      {
        id: "top",
        title: "Readable transcript",
        category: "new",
        pr: "https://github.com/manaflow-ai/cmux/pull/26875",
      },
      { id: "legacy", title: "A legacy title", category: "improved" },
    ],
    rest: [
      {
        id: "rest",
        title: "Clearer messages",
        category: "fixed",
        pr: "https://github.com/manaflow-ai/cmux/pull/27312",
      },
    ],
    changelog: { from: "1.0.0-nightly.41", to: "1.0.0-nightly.42" },
  };
  const calls: { op: string; params: unknown }[] = [];
  let onChange: ((data: UpdateHighlights | null) => void) | undefined;
  const client = {
    call: async (op: string, params: unknown) => {
      calls.push({ op, params });
      return op === "cmux.changelog.surface.get" ? data : { ok: true };
    },
    subscribe: async (_op: string, listener: typeof onChange) => {
      onChange = listener;
      return () => {};
    },
    handle: () => () => {},
  } as PageClient;
  const { setChipHost, callChipHost } = await import("../src/agent-session/acpmux/chips/host");
  try {
    const { mountUpdateSurface } = await import("../src/pages/changelog/surface");
    const host = dom.window.document.getElementById("root")!;
    await act(async () => mountUpdateSurface(host, "ready", client));
    for (const [selector, title, number] of [
      [".wn-pop-list li", "Readable transcript", "26875"],
      [".wn-pop-rest li", "Clearer messages", "27312"],
    ]) {
      const row = host.querySelector(selector!)!;
      expect(row.textContent).toContain(title!);
      expect(row.querySelectorAll("a.cl-pr").length).toBe(1);
      expect(row.querySelector(".cv-chip__label")?.textContent).toBe(`#${number}`);
      expect(row.querySelector("a.cl-pr")?.getAttribute("href")).toBe(
        `https://github.com/manaflow-ai/cmux/pull/${number}`,
      );
    }
    expect(host.querySelectorAll(".wn-pop-list li")[1]!.textContent).toContain("A legacy title");
    expect(host.querySelectorAll(".wn-pop-list li")[1]!.querySelector("a")).toBeNull();
    const params = { url: data.items[0]!.pr };
    for (const method of ["pr.inspect", "browser.list", "browser.openIn"]) {
      expect(await callChipHost(method, params)).toEqual({ ok: true });
      expect(calls.at(-1)).toEqual({ op: `cmux.changelog.${method}`, params });
    }
  } finally {
    await act(async () => onChange?.(null));
    setChipHost(undefined);
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
