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
