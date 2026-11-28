// The chat's structure a look reshapes (chatLayout.ts; Leo, 2026-11-22: "customizations on the deeper
// level ... and having them hot swappable"): the `agentPane.display.layout.*` rows arrive with the
// host's `display` event and reshape the open page at once, with no reload:
//   - each slot's value lands on <html> as a data attribute, the default as none;
//   - flipping a look swaps the attributes on the same document and re-renders a reader in place
//     (the same DOM node, no remount);
//   - the schema rows, the page's arms and the stylesheet's rules name the same values.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import {
  CHAT_LAYOUT,
  DEFAULT_CHAT_LAYOUT,
  resolveChatLayout,
  useChatLayout,
} from "../src/agent-session/acpmux/chatLayout";
import { teardownDom } from "./support/domTeardown";

const root = join(import.meta.dir, "..", "..");

// The page's own document: bun has no DOM, so this file installs a JSDOM window, loads react-dom and
// the display event after it, and puts the globals back when it is done (domTeardown.ts).
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "Event",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    Event: dom.window.Event,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});
const CODE_LOOK = {
  "agentPane.display.layout.messages": "flat",
  "agentPane.display.layout.composer": "square",
  "agentPane.display.layout.header": "full",
};
const WARM_LOOK = {
  "agentPane.display.layout.messages": "card",
  "agentPane.display.layout.composer": "rounded",
  "agentPane.display.layout.header": "quiet",
};
const MINIMAL_LOOK = {
  "agentPane.display.layout.messages": "bubbles",
  "agentPane.display.layout.composer": "pill",
  "agentPane.display.layout.header": "quiet",
};

describe("chat layout resolution", () => {
  test("no keys and bad values: every slot's default", () => {
    expect(resolveChatLayout({})).toEqual(DEFAULT_CHAT_LAYOUT);
    expect(resolveChatLayout(null)).toEqual(DEFAULT_CHAT_LAYOUT);
    expect(
      resolveChatLayout({ "agentPane.display.layout.messages": "sideways", "agentPane.display.layout.composer": 3 }),
    ).toEqual(DEFAULT_CHAT_LAYOUT);
  });

  test("a look's values", () => {
    expect(resolveChatLayout(CODE_LOOK)).toEqual({ messages: "flat", composer: "square", header: "full" });
  });
});

describe("chat layout hot-applies from the display event", () => {
  test("switching looks reshapes the open page without a reload", async () => {
    const { createRoot } = await import("react-dom/client");
    const { setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
    const html = document.documentElement;
    const container = document.createElement("div");
    document.body.appendChild(container);
    const seen: string[] = [];
    function Probe() {
      const layout = useChatLayout();
      seen.push(layout.messages);
      return (
        <div className="acpmux-shell" data-probe={layout.messages}>
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble">hello</div>
          </div>
        </div>
      );
    }
    const reactRoot = createRoot(container);
    act(() => reactRoot.render(<Probe />));
    const node = container.querySelector(".acpmux-shell");
    act(() => setChatDisplay({}));
    expect(html.dataset.chatMessages).toBeUndefined();
    expect(html.dataset.chatComposer).toBeUndefined();

    act(() => setChatDisplay(CODE_LOOK));
    expect(html.dataset.chatMessages).toBe("flat");
    expect(html.dataset.chatComposer).toBe("square");
    expect(html.dataset.chatHeader).toBeUndefined();
    expect(container.querySelector(".acpmux-shell")?.getAttribute("data-probe")).toBe("flat");

    act(() => setChatDisplay(WARM_LOOK));
    expect(html.dataset.chatMessages).toBe("card");
    expect(html.dataset.chatComposer).toBeUndefined();
    expect(html.dataset.chatHeader).toBe("quiet");

    act(() => setChatDisplay(MINIMAL_LOOK));
    expect(html.dataset.chatMessages).toBeUndefined();
    expect(html.dataset.chatComposer).toBe("pill");
    expect(html.dataset.chatHeader).toBe("quiet");

    act(() => setChatDisplay({}));
    expect(Object.keys(html.dataset).filter((key) => key.startsWith("chat"))).toEqual([]);
    // The same element the whole time: the page was reshaped in place, not reloaded or remounted.
    expect(container.querySelector(".acpmux-shell")).toBe(node);
    expect(seen).toContain("flat");
    expect(seen).toContain("card");
    act(() => reactRoot.unmount());
    container.remove();
  });
});

describe("one set of values everywhere", () => {
  const source = JSON.parse(readFileSync(join(root, "schemas/settings/source/agent-pane-display.json"), "utf8")) as {
    lists: { rows: { key: string; choices?: { value: string }[]; default?: unknown }[] }[];
  };
  const rows = new Map(source.lists.flatMap((list) => list.rows).map((row) => [row.key, row]));
  const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/chatLayout.css"), "utf8");

  for (const [slot, spec] of Object.entries(CHAT_LAYOUT)) {
    test(`${spec.key}: schema row, page arms, default and stylesheet agree`, () => {
      const row = rows.get(spec.key);
      expect(row).toBeDefined();
      expect(row?.choices?.map((choice) => choice.value)).toEqual([...spec.arms]);
      expect(row?.default).toBe(DEFAULT_CHAT_LAYOUT[slot as keyof typeof DEFAULT_CHAT_LAYOUT]);
      expect(existsSync(join(root, `schemas/settings/source/agent-policy/${spec.key}.json`))).toBe(true);
      const attr = spec.attr.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
      for (const arm of spec.arms) {
        if (arm === row?.default) continue;
        expect(css).toContain(`:root[data-${attr}="${arm}"]`);
      }
    });
  }
});
