// l10n-allow-file: test rows, not shipped UI.
// Canaries for the row render counter (support/commitRenders.ts), the one counter every list lane
// uses: each is a way a row really renders that a counter can miss, and the counter must count it;
// and a memo bail-out, which it must not. A counter that compares a row's props object read 0 for a
// row re-rendered by its own state, a context read alone, or a store. Settings' Browse More Art redrew
// its 36 tiles on every keystroke until #46364 (a change redraws only its row); the counter reads 0 now. Each case runs as
// written and compiled by the React Compiler (babel-plugin-react-compiler, as the app builds).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { transformSync } from "@babel/core";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { JSDOM } from "jsdom";
import * as React from "react";
import { act } from "react";
import * as compilerRuntime from "react/compiler-runtime";
import type { Root } from "react-dom/client";
import { rowRenders } from "./support/commitRenders";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

// The rows, in plain calls so the same text runs as written and through the compiler. Every row's
// root element has class "row"; `useX` in a handler is what makes the compiler give up on a
// component (it reads as a hook called outside render), as `store.useMuseumArt` does in ArtBrowser.
const SOURCE = `
export const Ctx = createContext(0);
export const OwnState = memo(function OwnState({ id, expose }) {
  const [n, set] = useState(0);
  expose(id, () => set((v) => v + 1));
  return h("li", { className: "row" }, id + ":" + n);
});
export const OnlyContext = memo(function OnlyContext({ id }) {
  return h("li", { className: "row" }, id + ":" + useContext(Ctx));
});
export const OnlyStore = memo(function OnlyStore({ id, store }) {
  return h("li", { className: "row" }, id + ":" + useSyncExternalStore(store.subscribe, store.get));
});
export const QuietState = memo(function QuietState({ id, expose }) {
  const [, set] = useState(0);
  expose(id, () => set((v) => v + 1));
  return h("li", { className: "row" }, id);
});
export const QuietContext = memo(function QuietContext({ id }) {
  useContext(Ctx);
  return h("li", { className: "row" }, id);
});
export const QuietStore = memo(function QuietStore({ id, store }) {
  useSyncExternalStore(store.subscribe, store.get);
  return h("li", { className: "row" }, id);
});
export const Plain = memo(function Plain({ id }) {
  return h("li", { className: "row" }, id);
});
export function Cached({ id, meta }) {
  return h("li", { className: "row" }, id);
}
export function Inline({ ids, useX }) {
  const [query, setQuery] = useState("");
  return h(
    "div",
    null,
    h("input", { value: query, onChange: (event) => setQuery(event.target.value) }),
    h("ul", null, ids.map((id) => h("li", { key: id, className: "row", onClick: () => useX(id) }, id))),
  );
}
`;

type Rows = {
  Ctx: React.Context<number>;
  OwnState: React.FC<{ id: string; expose(id: string, bump: () => void): void }>;
  OnlyContext: React.FC<{ id: string }>;
  OnlyStore: React.FC<{ id: string; store: Store }>;
  QuietState: Rows["OwnState"];
  QuietContext: React.FC<{ id: string }>;
  QuietStore: React.FC<{ id: string; store: Store }>;
  Plain: React.FC<{ id: string }>;
  Cached: React.FC<{ id: string; meta: object }>;
  Inline: React.FC<{ ids: string[]; useX(id: string): void }>;
  code: string;
};

/// The rows as a module: as written, or as the compiler writes them. It reads React from a global,
/// so it can live in a temporary directory with no node_modules beside it.
async function build(compiled: boolean): Promise<Rows> {
  let code = SOURCE;
  if (compiled)
    code = transformSync(SOURCE, {
      filename: "/canaries/rows.js",
      babelrc: false,
      configFile: false,
      plugins: [["babel-plugin-react-compiler", { target: "19" }]],
    })!.code!;
  const module = code.replace(
    /^import \{ c as _c \} from "react\/compiler-runtime";$/m,
    "const _c = globalThis.__canaryReact.runtime.c;",
  );
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "row-canaries-")), "rows.mjs");
  fs.writeFileSync(
    file,
    `const { createElement: h, createContext, memo, useState, useContext, useSyncExternalStore } = globalThis.__canaryReact.React;\n${module}`,
  );
  (globalThis as { __canaryReact?: unknown }).__canaryReact = { React, runtime: compilerRuntime };
  return { ...((await import(pathToFileURL(file).href)) as Omit<Rows, "code">), code };
}

type Store = { subscribe(listener: () => void): () => void; get(): number; fire(): void };
function store(): Store {
  let version = 0;
  const listeners = new Set<() => void>();
  return {
    subscribe: (listener) => (listeners.add(listener), () => listeners.delete(listener)),
    get: () => version,
    fire: () => {
      version++;
      for (const listener of listeners) listener();
    },
  };
}

const ids = Array.from({ length: 10 }, (_, index) => `r${index}`);
async function mount(element: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(element));
}
function measure(run: () => void) {
  const renders = rowRenders();
  renders.begin(host, ".row");
  act(run);
  return renders.end();
}
const type = (input: HTMLInputElement, text: string) => {
  Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!.call(input, text);
  input.dispatchEvent(new input.ownerDocument.defaultView!.Event("input", { bubbles: true }));
};

const built = { written: await build(false), compiled: await build(true) };
for (const compiled of [false, true])
  describe(compiled ? "compiled" : "as written", () => {
    const rows = compiled ? built.compiled : built.written;

    test("compiled rows really are compiled, and the inline list really is not", () => {
      if (!compiled) return;
      expect(rows.code).toContain('from "react/compiler-runtime"');
      // The compiler gave up on Inline: its body has no memo cache.
      const inline = rows.code.slice(rows.code.indexOf("function Inline"));
      expect(inline.slice(0, inline.indexOf("\n}\n"))).not.toContain("_c(");
    });

    test("a memo row re-rendered by its own useState counts once per toggle", async () => {
      const bumps = new Map<string, () => void>();
      const expose = (id: string, bump: () => void) => bumps.set(id, bump);
      await mount(
        React.createElement(
          "ul",
          null,
          ids.map((id) => React.createElement(rows.OwnState, { key: id, id, expose })),
        ),
      );
      expect(measure(() => bumps.get("r3")!())).toEqual({ rerendered: 1, wasted: 0, added: 0, maxRenders: 1 });
    });

    test("a memo row whose only hook is useContext counts once per consumer when the value changes", async () => {
      const view = (value: number) =>
        React.createElement(
          rows.Ctx,
          { value },
          React.createElement(
            "ul",
            null,
            ids.map((id) => React.createElement(rows.OnlyContext, { key: id, id })),
          ),
        );
      await mount(view(0));
      expect(measure(() => root!.render(view(1)))).toEqual({ rerendered: 10, wasted: 0, added: 0, maxRenders: 1 });
    });

    test("a memo row on its own store counts when its store fires, and no other row does", async () => {
      const stores = new Map(ids.map((id) => [id, store()]));
      await mount(
        React.createElement(
          "ul",
          null,
          ids.map((id) => React.createElement(rows.OnlyStore, { key: id, id, store: stores.get(id)! })),
        ),
      );
      expect(measure(() => stores.get("r6")!.fire())).toEqual({ rerendered: 1, wasted: 0, added: 0, maxRenders: 1 });
    });

    // The same three, with rows whose output does not change: compiled, the root element is the
    // cached one, so no host element gets new props and only the row's own render can be counted
    // (the case a props or hook-list counter reads 0 for). Each is a wasted render.
    test("a quiet row re-rendered by its own useState still counts", async () => {
      const bumps = new Map<string, () => void>();
      const expose = (id: string, bump: () => void) => bumps.set(id, bump);
      await mount(
        React.createElement(
          "ul",
          null,
          ids.map((id) => React.createElement(rows.QuietState, { key: id, id, expose })),
        ),
      );
      expect(measure(() => bumps.get("r3")!())).toEqual({ rerendered: 1, wasted: 1, added: 0, maxRenders: 1 });
    });

    test("a quiet row whose only hook is useContext still counts when the value changes", async () => {
      const view = (value: number) =>
        React.createElement(
          rows.Ctx,
          { value },
          React.createElement(
            "ul",
            null,
            ids.map((id) => React.createElement(rows.QuietContext, { key: id, id })),
          ),
        );
      await mount(view(0));
      expect(measure(() => root!.render(view(1)))).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
    });

    test("a quiet row on its own store still counts when its store fires", async () => {
      const stores = new Map(ids.map((id) => [id, store()]));
      await mount(
        React.createElement(
          "ul",
          null,
          ids.map((id) => React.createElement(rows.QuietStore, { key: id, id, store: stores.get(id)! })),
        ),
      );
      expect(measure(() => stores.get("r6")!.fire())).toEqual({ rerendered: 1, wasted: 1, added: 0, maxRenders: 1 });
    });

    test("inline rows in a list the compiler gives up on count every row its own state redraws", async () => {
      await mount(React.createElement(rows.Inline, { ids, useX: () => {} }));
      const input = host.querySelector("input")!;
      expect(measure(() => type(input, "a"))).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
    });

    // A row whose body runs and returns the root element the compiler cached counts as a render:
    // React ran it (the work rule 2 is about), though it changed no DOM, so it is a wasted one.
    test("a row whose body runs and returns its cached element counts, as a wasted render", async () => {
      const view = () =>
        React.createElement(
          "ul",
          null,
          ids.map((id) => React.createElement(rows.Cached, { key: id, id, meta: {} })),
        );
      await mount(view());
      expect(measure(() => root!.render(view()))).toEqual({ rerendered: 10, wasted: 10, added: 0, maxRenders: 1 });
    });

    test("a memo row with unchanged props stays at 0 when its parent redraws", async () => {
      const view = (tick: number) =>
        React.createElement(
          "ul",
          { "data-tick": tick },
          ids.map((id) => React.createElement(rows.Plain, { key: id, id })),
        );
      await mount(view(0));
      expect(measure(() => root!.render(view(1)))).toEqual({ rerendered: 0, wasted: 0, added: 0, maxRenders: 0 });
    });
  });

test("Settings' Browse More Art: one keystroke redraws none of its 36 tiles (#46364)", async () => {
  const { ArtBrowser } = await import("../src/pages/settings/components/ArtBrowser");
  const { SettingsContext } = await import("../src/pages/settings/context");
  const results = Array.from({ length: 36 }, (_, index) => ({
    key: `w${index}`,
    title: `Work ${index}`,
    artist: "Artist",
    date: "1890",
    source: "Museum",
    page: "",
  }));
  const settings = { searchMuseumArt: async () => results, useMuseumArt: async () => true };
  await mount(
    React.createElement(
      SettingsContext,
      { value: { store: settings, router: {} } as never },
      React.createElement(ArtBrowser, { onClose: () => {} }),
    ),
  );
  const input = host.querySelector<HTMLInputElement>("input[type=search]")!;
  act(() => type(input, "sunflowers"));
  await act(async () => {
    host.querySelector("form")!.dispatchEvent(new host.ownerDocument.defaultView!.Event("submit", { bubbles: true }));
  });
  expect(host.querySelectorAll(".backdrop-tile")).toHaveLength(36);
  const renders = rowRenders();
  renders.begin(host, ".backdrop-tile");
  act(() => type(input, "sunflowers!"));
  expect(renders.end()).toEqual({ rerendered: 0, wasted: 0, added: 0, maxRenders: 0 });
});
