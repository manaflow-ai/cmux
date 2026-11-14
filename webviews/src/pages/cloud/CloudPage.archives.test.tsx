// The last machine went to an archive: the storefront shows, and the archive's Restore stays reachable there.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudOps, type CloudSnapshot } from "./ops";
import { CloudStore } from "./store";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

const archive: CloudSnapshot = {
  id: "snap_arch1",
  machine: "vm_x8",
  name: null,
  size_mb: 12_288,
  status: "ready",
  created_at: Date.now() - 86_400_000,
  archive_of: { machine: "vm_x8", name: "docs-preview", until: Date.now() + 86 * 86_400_000 },
  revision: "1",
};

test("no machines left: the storefront still lists the archive, and Restore makes it a machine", async () => {
  const provider = new MockCloudProvider({ unsupported: [] });
  provider.machines = [];
  provider.snapshots = [archive];
  const store = new CloudStore(provider);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(settle);
    expect(store.getSnapshot().rows).toHaveLength(0);
    expect(rootElement.querySelector(".cloud-machines")).toBeNull();
    expect(rootElement.querySelector(".cloud-archives .cloud-archive-name")?.textContent).toBe("docs-preview");
    const restore = rootElement.querySelector<HTMLButtonElement>(".cloud-archive-restore");
    expect(restore?.disabled).toBe(false);
    await act(async () => {
      restore!.click();
      await settle();
    });
    const restores = provider.calls.filter(
      (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudOps.snapshotRestore,
    );
    expect(restores).toHaveLength(1);
    expect(store.getSnapshot().machines.map((machine) => machine.name)).toContain("docs-preview");
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
  }
});
