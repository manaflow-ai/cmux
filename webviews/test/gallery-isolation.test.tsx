// The gallery's entry isolation (src/gallery/entryStore.ts, shell/EntryBoundary.tsx,
// dev-server/galleryLive.ts): one entry file that does not load shows its own error card while a
// sibling entry renders, and it recovers in place once a reload succeeds.
import { afterEach, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ReactNode } from "react";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createEntryStore, type EntrySource, type EntryState } from "../src/gallery/entryStore";
import { agentPaneEntry, type GalleryEntry } from "../src/gallery/format";
import { errorFile, errorKind, scopeOf, type ScopeNode } from "../dev-server/galleryLive";

void mock.module("virtual:cmux-gallery/revision", () => ({
  default: { sha: "0".repeat(40), subject: "test", committedAt: 0, branch: "test" },
}));
let EntryBoundary: typeof import("../src/gallery/shell/EntryBoundary").EntryBoundary;

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

beforeAll(async () => {
  ({ EntryBoundary } = await import("../src/gallery/shell/EntryBoundary"));
});

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  for (const key of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved)
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  saved.clear();
});

const entry = (id: string, title: string): GalleryEntry =>
  agentPaneEntry({
    id,
    title,
    area: "Agent pane",
    covers: ["agent-session/acpmux/App.tsx"],
    variants: { empty: { snapshot: {} as never } },
  });

/** Every entry of the store, each in its own boundary, as the shell's list renders them. */
function List({ states }: { states: readonly EntryState[] }): ReactNode {
  return states.map((state) => (
    <EntryBoundary
      key={state.path}
      state={state}
      loading={<p data-loading={state.path}>loading</p>}
      render={(loaded) => <h2 data-entry={loaded.id}>{loaded.title}</h2>}
    />
  ));
}

async function render(states: readonly EntryState[], container: HTMLElement): Promise<void> {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<List states={states} />);
  });
}

test("an entry whose import throws shows its error card while a sibling entry renders", async () => {
  const container = installDom();
  const sources: EntrySource[] = [
    { path: "src/a/broken.gallery.ts", load: () => Promise.reject(new SyntaxError("Unexpected token '}' (3:1)")) },
    { path: "src/b/good.gallery.ts", load: () => Promise.resolve(entry("test.good", "Good entry")) },
    { path: "src/c/empty.gallery.ts", load: () => Promise.resolve(undefined) },
  ];
  const store = createEntryStore(sources);
  await store.settled();
  await render(store.getSnapshot(), container);

  const cards = [...container.querySelectorAll("[data-gallery-entry-error]")];
  expect(cards.map((card) => card.getAttribute("data-gallery-entry-error"))).toEqual([
    "src/a/broken.gallery.ts",
    "src/c/empty.gallery.ts",
  ]);
  expect(cards[0]!.textContent).toContain("Unexpected token '}'");
  expect(cards[1]!.textContent).toContain("has no default export");
  expect(container.querySelector("[data-entry='test.good']")?.textContent).toBe("Good entry");
});

test("a broken entry recovers in place once its reload succeeds, and its sibling is not reloaded", async () => {
  const container = installDom();
  let fixed = false;
  const goodLoads: (number | undefined)[] = [];
  const sources: EntrySource[] = [
    {
      path: "src/a/flaky.gallery.ts",
      load: (bust) =>
        fixed ? Promise.resolve(entry("test.flaky", `Fixed ${bust}`)) : Promise.reject(new Error("Transform failed")),
    },
    {
      path: "src/b/good.gallery.ts",
      load: (bust) => {
        goodLoads.push(bust);
        return Promise.resolve(entry("test.good", "Good entry"));
      },
    },
  ];
  const store = createEntryStore(sources);
  await store.settled();
  await render(store.getSnapshot(), container);
  expect(container.querySelector("[data-gallery-entry-error='src/a/flaky.gallery.ts']")).not.toBeNull();
  const sibling = container.querySelector("[data-entry='test.good']");

  fixed = true;
  store.reload(["src/a/flaky.gallery.ts"], 42);
  await store.settled();
  await render(store.getSnapshot(), container);

  expect(container.querySelector("[data-gallery-entry-error]")).toBeNull();
  expect(container.querySelector("[data-entry='test.flaky']")?.textContent).toBe("Fixed 42");
  // The same root, the same sibling node: no page reload, no remount of the other entry.
  expect(container.querySelector("[data-entry='test.good']")).toBe(sibling);
  expect(goodLoads).toEqual([undefined]);
  // The last good entry is kept, so a broken file keeps its place in the shell.
  expect(store.getSnapshot()[0]!.lastGood?.id).toBe("test.flaky");
});

test("a render error inside one entry stays in that entry's boundary", async () => {
  const container = installDom();
  const store = createEntryStore([
    { path: "src/a/one.gallery.ts", load: () => Promise.resolve(entry("test.one", "One")) },
    { path: "src/b/two.gallery.ts", load: () => Promise.resolve(entry("test.two", "Two")) },
  ]);
  await store.settled();
  const original = console.error;
  console.error = () => {};
  try {
    await act(async () => {
      root = createRoot(container);
      root.render(
        store.getSnapshot().map((state) => (
          <EntryBoundary
            key={state.path}
            state={state}
            loading={null}
            render={(loaded) => {
              if (loaded.id === "test.one") throw new Error("render broke");
              return <h2 data-entry={loaded.id}>{loaded.title}</h2>;
            }}
          />
        )),
      );
    });
  } finally {
    console.error = original;
  }
  expect(container.querySelector("[data-gallery-entry-error='src/a/one.gallery.ts']")?.textContent).toContain(
    "render broke",
  );
  expect(container.querySelector("[data-entry='test.two']")).not.toBeNull();
});

// The dev server's sorting of saves and compile errors (galleryLive.ts).
function graph() {
  const node = (file: string): ScopeNode => ({ file, importers: new Set() });
  const shell = node("/w/src/gallery/shell/main.tsx");
  const shellView = node("/w/src/gallery/shell/Shell.tsx");
  const frame = node("/w/src/gallery/frame/main.ts");
  const registry = node("/w/src/gallery/registry.ts");
  const entryFile = node("/w/src/agent-session/x.gallery.ts");
  const fixture = node("/w/src/gallery/fixtures/acpmux.ts");
  const component = node("/w/src/agent-session/acpmux/Row.tsx");
  const env = node("/w/src/gallery/env.ts");
  const link = (child: ScopeNode, ...parents: ScopeNode[]) => parents.forEach((parent) => child.importers.add(parent));
  link(shellView, shell);
  link(registry, shellView, frame);
  link(entryFile, registry);
  link(fixture, entryFile);
  link(component, frame);
  link(env, shellView, frame, entryFile);
  return { entryFile, fixture, component, env };
}
const isEntry = (file: string) => file.endsWith(".gallery.ts");
const isShellRoot = (file: string) => file.endsWith("/shell/main.tsx");

test("errors and saves are sorted by who imports the module", () => {
  const { entryFile, fixture, component, env } = graph();
  const kind = (node: ScopeNode) => errorKind(scopeOf([node], isEntry, isShellRoot));
  expect(kind(entryFile)).toBe("entry");
  expect(kind(fixture)).toBe("entry");
  expect(scopeOf([fixture], isEntry, isShellRoot).entries).toEqual([entryFile]);
  expect(kind(component)).toBe("stage");
  // The shell imports it (not only through entries): Vite's overlay stays.
  expect(kind(env)).toBe("shell");
});

test("a compile error names its module by id, by location or in its message", () => {
  expect(errorFile({ id: "/w/src/a.gallery.ts?t=1" }, "/w")).toBe("/w/src/a.gallery.ts");
  expect(errorFile({ loc: { file: "/w/src/b.ts" } }, "/w")).toBe("/w/src/b.ts");
  // The React Compiler's Babel error: no id, the file in the message.
  expect(
    errorFile({ message: "[BabelError] /w/src/pages/markdown/markdown.gallery.ts: Unexpected token (104:15)" }, "/w"),
  ).toBe("/w/src/pages/markdown/markdown.gallery.ts");
  expect(errorFile({ message: "something else" }, "/w")).toBe("");
});
