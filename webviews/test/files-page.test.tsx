// The Files page (cx-p4rt) through its host ops (`cmux.files.*`, the mock host): the tree lists the
// chat's folder, folders first, and is driven from the keyboard alone. Down and Up move, Right opens a
// folder and then steps into it, typing selects by name, Return opens a file in the editor, Left steps
// to the parent and then closes it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  window.HTMLElement.prototype.scrollIntoView = () => {};
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    // The file icons' sprite comes from @pierre/trees, which registers its element on import.
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the Files tree walks and opens from the keyboard", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FilesPage } = await import("../src/pages/files/FilesPage");
  const { FilesStore } = await import("../src/pages/files/store");
  const { MockFilesProvider } = await import("../src/pages/files/mockProvider");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/files/generated/strings.json")).default;
  const provider = new MockFilesProvider();
  const store = new FilesStore(provider);
  root = createRoot(host);
  act(() => root!.render(<FilesPage store={store} strings={createStrings(table)} />));
  await act(() => store.start());

  const rows = () => [...host.querySelectorAll('[role="treeitem"]')].map((row) => row.textContent);
  const selected = () => host.querySelector('[role="treeitem"][aria-selected="true"]')?.textContent;
  const tree = host.querySelector<HTMLElement>('[role="tree"]')!;
  const press = async (key: string) => {
    const KeyboardEvent = host.ownerDocument.defaultView!.KeyboardEvent;
    await act(
      async () => void tree.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true })),
    );
  };

  expect(host.querySelector(".files-header")?.textContent).toBe("app");
  expect(rows()).toEqual([".github", "docs", "src", ".gitignore", "package.json", "README.md", "tsconfig.json"]);
  expect(selected()).toBe(".github");

  await press("ArrowDown");
  await press("ArrowDown");
  expect(selected()).toBe("src");
  await press("ArrowRight");
  expect(rows()).toEqual([
    ".github",
    "docs",
    "src",
    "components",
    "main.ts",
    "store.ts",
    ".gitignore",
    "package.json",
    "README.md",
    "tsconfig.json",
  ]);
  expect(host.querySelector('[aria-expanded="true"]')?.textContent).toBe("src");
  await press("ArrowRight");
  expect(selected()).toBe("components");
  await press("m");
  expect(selected()).toBe("main.ts");
  await press("Enter");
  expect(provider.opened).toEqual(["src/main.ts"]);

  await press("ArrowLeft");
  expect(selected()).toBe("src");
  await press("ArrowLeft");
  expect(rows()).toEqual([".github", "docs", "src", ".gitignore", "package.json", "README.md", "tsconfig.json"]);
  await press("End");
  expect(selected()).toBe("tsconfig.json");
});

// The tree takes the keys when it shows; a folder's cut-short line follows its rows; a file that fails
// to open says why until the selection moves; a folder that disappears forgets it was open; and a page
// with no host says so in words.
test("the Files tree keeps up with its folder", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FilesPage } = await import("../src/pages/files/FilesPage");
  const { FilesStore } = await import("../src/pages/files/store");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/files/generated/strings.json")).default;
  const strings = createStrings(table);
  const files = structuredClone(sampleTree);
  const provider = new MockFilesProvider(files);
  const store = new FilesStore(provider);
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<FilesPage store={store} strings={strings} />));
  await act(() => store.start());

  const tree = host.querySelector<HTMLElement>('[role="tree"]')!;
  const lines = () => [...tree.children].map((line) => line.textContent);
  const press = async (key: string) => {
    const KeyboardEvent = host.ownerDocument.defaultView!.KeyboardEvent;
    await act(
      async () => void tree.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true })),
    );
  };
  expect(host.ownerDocument.activeElement).toBe(tree);

  provider.truncated.add("src");
  await act(async () => store.expand("src"));
  expect(lines().slice(2, 8)).toEqual([
    "src",
    "components",
    "main.ts",
    "store.ts",
    strings.t("files.page.truncated"),
    ".gitignore",
  ]);

  await act(async () => store.select("src/main.ts"));
  provider.openFailure = "main.ts is gone.";
  await press("Enter");
  expect(host.querySelector(".files-notice")?.textContent).toBe("main.ts is gone.");
  expect(lines()).not.toContain("main.ts is gone.");
  await press("ArrowDown");
  expect(host.querySelector(".files-notice")).toBeNull();

  // Once the listing is complete again, a deleted selection falls back to its folder.
  provider.truncated.delete("src");
  await act(async () => store.select("src/main.ts"));
  delete files.src!["main.ts"];
  await act(() => store.refresh());
  expect(store.getSnapshot().selected).toBe("src");

  files.src!["main.ts"] = null;
  delete files.src;
  await act(() => store.refresh());
  expect(lines()).not.toContain("components");
  files.src = { "index.ts": null };
  await act(() => store.refresh());
  expect(lines().slice(0, 4)).toEqual([".github", "docs", "src", ".gitignore"]);
  expect(host.querySelector('[aria-expanded="true"]')).toBeNull();

  const hostless = new FilesStore(null);
  act(() => root!.render(<FilesPage key="no-host" store={hostless} strings={strings} />));
  await act(() => hostless.start());
  expect(host.textContent).toBe(strings.t("files.page.unavailable"));
});

test("keeps selection when a truncated listing omits an entry", async () => {
  const { FilesStore } = await import("../src/pages/files/store");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const files = structuredClone(sampleTree);
  const provider = new MockFilesProvider(files);
  const store = new FilesStore(provider);

  await store.start();
  store.expand("src");
  await store.refresh();
  store.select("src/main.ts");
  provider.truncated.add("src");
  delete files.src!["main.ts"];

  await store.refresh();

  expect(store.getSnapshot().selected).toBe("src/main.ts");
});

test("keeps a folder's state when a complete listing still holds a file of that name", async () => {
  const { FilesStore } = await import("../src/pages/files/store");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const files = structuredClone(sampleTree);
  const store = new FilesStore(new MockFilesProvider(files));

  await store.start();
  store.expand("src");
  await store.refresh();
  store.select("src/main.ts");
  files.src!["components"] = null;

  await store.refresh();

  const snapshot = store.getSnapshot();
  expect(snapshot.selected).toBe("src/main.ts");
  expect(snapshot.rows.find((row) => row.path === "src/components")?.kind).toBe("file");
});

test("ignores stale open failures across navigation, collapse, and retry", async () => {
  const { FilesStore } = await import("../src/pages/files/store");
  const { FilesOps } = await import("../src/pages/files/types");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const { pageError } = await import("../src/pages/shared/pageClient");
  const files = structuredClone(sampleTree);
  const provider = new MockFilesProvider(files);
  const baseCall = provider.call.bind(provider);
  const pending: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];
  provider.call = (async (op: string, params: unknown) => {
    if (op === FilesOps.open) {
      return new Promise<undefined>((resolve, reject) => pending.push({ resolve: () => resolve(undefined), reject }));
    }
    return baseCall(op, params);
  }) as typeof provider.call;
  const settle = (reject: boolean, message = "gone") => {
    const attempt = pending.shift()!;
    if (reject) attempt.reject(pageError("test.open_failed", message));
    else attempt.resolve();
  };
  const store = new FilesStore(provider);

  await store.start();
  store.expand("src");
  await store.refresh();
  store.select("src/main.ts");
  const a1 = store.open("src/main.ts");
  store.select("src/store.ts");
  const b = store.open("src/store.ts");
  store.select("src/main.ts");
  const a2 = store.open("src/main.ts");
  settle(true, "old A");
  settle(false);
  settle(false);
  await Promise.all([a1, b, a2]);
  expect(store.getSnapshot().notice).toBeUndefined();

  const current = store.open("src/main.ts");
  expect(store.getSnapshot().notice).toBeUndefined();
  settle(true, "current A");
  await current;
  expect(store.getSnapshot().notice).toBe("current A");
  const retry = store.open("src/main.ts");
  expect(store.getSnapshot().notice).toBeUndefined();
  settle(false);
  await retry;

  store.select("src/main.ts");
  const collapsed = store.open("src/main.ts");
  store.collapse("src");
  settle(true, "collapsed");
  await collapsed;
  expect(store.getSnapshot().notice).toBeUndefined();

  store.expand("src");
  await store.refresh();
  store.select("src/main.ts");
  const forgotten = store.open("src/main.ts");
  delete files.src;
  await store.refresh();
  settle(true, "forgotten");
  await forgotten;
  expect(store.getSnapshot().selected).toBeUndefined();
  expect(store.getSnapshot().notice).toBeUndefined();
});

test("a path that neither the page nor the host could copy says so", async () => {
  const { FilesStore } = await import("../src/pages/files/store");
  const { CLIPBOARD_WRITE } = await import("../src/pages/files/types");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const { pageError } = await import("../src/pages/shared/pageClient");
  const provider = new MockFilesProvider(structuredClone(sampleTree));
  const baseCall = provider.call.bind(provider);
  const writes: string[] = [];
  let hostFails = true;
  provider.call = (async (op: string, params: unknown) => {
    if (op !== CLIPBOARD_WRITE) return baseCall(op, params);
    writes.push((params as { text: string }).text);
    if (hostFails) throw pageError("test.clipboard_denied", "Clipboard access was denied");
    return undefined;
  }) as typeof provider.call;
  const store = new FilesStore(provider, async () => {
    throw new Error("page clipboard refused");
  });
  await store.start();

  await store.copy("src/main.ts");
  expect(writes).toEqual(["src/main.ts"]);
  expect(store.getSnapshot().notice).toBe("Clipboard access was denied");

  // Another selection clears the notice, and a copy the host takes leaves none.
  store.select("src/store.ts");
  expect(store.getSnapshot().notice).toBeUndefined();
  hostFails = false;
  await store.copy("src/store.ts");
  expect(store.getSnapshot().notice).toBeUndefined();
});

test("a copy failure that arrives after the selection moved or a newer copy began is not shown", async () => {
  const { FilesStore } = await import("../src/pages/files/store");
  const { CLIPBOARD_WRITE } = await import("../src/pages/files/types");
  const { MockFilesProvider, sampleTree } = await import("../src/pages/files/mockProvider");
  const { pageError } = await import("../src/pages/shared/pageClient");
  const provider = new MockFilesProvider(structuredClone(sampleTree));
  const baseCall = provider.call.bind(provider);
  const writes: { resolve(): void; reject(error: Error): void }[] = [];
  provider.call = (async (op: string, params: unknown) => {
    if (op !== CLIPBOARD_WRITE) return baseCall(op, params);
    return new Promise<undefined>((resolve, reject) => writes.push({ resolve: () => resolve(undefined), reject }));
  }) as typeof provider.call;
  const store = new FilesStore(provider, async () => {
    throw new Error("page clipboard refused");
  });
  await store.start();
  const denied = () => pageError("test.clipboard_denied", "Clipboard access was denied");

  const moved = store.copy("src/main.ts");
  await Promise.resolve();
  store.select("src/store.ts");
  writes[0]!.reject(denied());
  await moved;
  expect(store.getSnapshot().notice).toBeUndefined();

  const older = store.copy("src/main.ts");
  await Promise.resolve();
  const newer = store.copy("src/store.ts");
  await Promise.resolve();
  writes[2]!.resolve();
  writes[1]!.reject(denied());
  await Promise.all([older, newer]);
  expect(store.getSnapshot().notice).toBeUndefined();
});
