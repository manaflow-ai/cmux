import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { EnvironmentStore } from "./environmentStore";
import type { CloudEnvironment, EnvironmentPatch } from "./environmentModel";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const [{ createRoot }, { EnvironmentSheet }] = await Promise.all([
  import("react-dom/client"),
  import("./EnvironmentSheet"),
]);
const strings = createStrings(table, ["en"]);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

const sample: CloudEnvironment = {
  id: "env_example",
  scope: "personal",
  name: "Default",
  is_default: true,
  setup_script: null,
  env_vars: [],
  secrets: [{ name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }],
  network: { mode: "full", package_managers: true, domains: [] },
  created_at: "2026-11-01T00:00:00Z",
  updated_at: "2026-11-01T00:00:00Z",
  updated_by: "user_example",
};
async function mount(section: "overview" | "script" = "overview") {
  const writes: EnvironmentPatch[] = [];
  const store = new EnvironmentStore({
    list: async () => [sample],
    get: async () => sample,
    update: async (_id, patch) => {
      writes.push(patch);
      return sample;
    },
    derive: async () => ({ setup: { script: "#!/bin/bash\nnpm ci\n" } }),
  });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(<EnvironmentSheet store={store} strings={strings} />);
    await store.open({ section, repo: "example/project" });
    await settle();
  });
  return {
    store,
    writes,
    async dispose() {
      await act(async () => root.unmount());
      container.remove();
    },
  };
}
const button = (label: string) =>
  Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(
    (node) => node.getAttribute("aria-label") === label || node.textContent?.includes(label),
  );

test("summary rows drill in and back to the same draft; Cancel never writes", async () => {
  const mounted = await mount();
  try {
    expect(document.querySelector<HTMLInputElement>(".env-field input")?.readOnly).toBe(true);
    for (const label of ["Network access", "Network secrets", "Setup script", "Environment variables"]) {
      await act(async () => {
        button(label)!.click();
      });
      expect(document.querySelector(".env-heading h2")?.textContent).toBe(label);
      if (label === "Network secrets") {
        const secret = document.querySelector<HTMLInputElement>('input[type="password"]');
        expect(secret?.value).toBe("");
        expect(document.querySelector<HTMLInputElement>('input[aria-label="Secret name"]')?.value).toBe(
          "PACKAGE_TOKEN",
        );
      }
      await act(async () => {
        button("Back to environment")!.click();
      });
      expect(document.querySelector(".env-heading h2")?.textContent).toBe("Edit cloud environment");
    }
    await act(async () => {
      mounted.store.edit({ script: "echo unsaved" });
      button("Cancel")!.click();
    });
    expect(mounted.store.getSnapshot().open).toBe(false);
    expect(mounted.writes).toEqual([]);
  } finally {
    await mounted.dispose();
  }
});

test("the checklist entry displays the derived Bash script and backs into the cog overview", async () => {
  const mounted = await mount("script");
  try {
    expect(document.querySelector<HTMLTextAreaElement>(".env-code textarea")?.value).toBe("#!/bin/bash\nnpm ci\n");
    expect(document.querySelector(".env-code pre")?.textContent).toBe("1\n2\n3");
    expect(document.querySelector(".env-editor-foot")?.textContent).toBe("Files up to 64 KB");
    expect(document.querySelector(".env-note")?.textContent).toContain("before the agent launches");
    await act(async () => {
      button("Back to environment")!.click();
    });
    expect(document.querySelector(".env-heading h2")?.textContent).toBe("Edit cloud environment");
    await act(async () => {
      button("Save changes")!.click();
      await settle();
    });
    expect(mounted.writes).toEqual([]);
    expect(mounted.store.getSnapshot().open).toBe(false);
  } finally {
    await mounted.dispose();
  }
});
