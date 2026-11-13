// l10n-allow-file: test fixtures name harnesses as the catalog does.
//
// The Harnesses page never leaves a row at a bare "Not installed": a harness cmux has no installer
// and no setup page for (Cursor, DeepSeek and Grok in the bundled catalog) offers Check again, which
// asks acpmux to look again (the first-user journey's error-without-next-step finding).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "../modelCatalogData";
import { HarnessesScreen } from "./HarnessesScreen";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) {
    const mounted = root;
    act(() => mounted.unmount());
    await settleReact();
  }
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("a not-installed harness with no installer and no setup page offers Check again, which asks acpmux to look", async () => {
  const container = installDom();
  const asked: { method: string; params: Record<string, unknown> }[] = [];
  const callNative = (method: string, params: Record<string, unknown> = {}) => {
    asked.push({ method, params });
    return Promise.resolve(method === "harness.health" ? { health: { id: params.id, auth: "unknown" } } : {});
  };
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <HarnessesScreen
        catalog={buildPickerCatalog({ catalog: BUNDLED_MODEL_CATALOG, acpmux: [] })}
        acpmux={[]}
        callNative={callNative}
        onClose={() => undefined}
      />,
    );
  });
  await settle();
  // Every not-installed row has a button: an installer, a setup page, or Check again.
  const rows = [...container.querySelectorAll<HTMLElement>('[data-harness-status="notInstalled"]')];
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) expect(row.querySelector("button")).not.toBeNull();
  const cursor = container.querySelector<HTMLElement>('[data-harness-row="cursor"]');
  expect(cursor).not.toBeNull();
  const button = cursor!.querySelector<HTMLButtonElement>("button")!;
  await act(async () => {
    button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  await settle();
  expect(asked).toContainEqual({ method: "harness.health", params: { id: "cursor", refresh: true, rescan: true } });
  // Still not found: the row says so and offers Check again again, never a dead end.
  expect(cursor!.getAttribute("data-harness-status")).toBe("failed");
  expect(cursor!.querySelector("button")).not.toBeNull();
});
