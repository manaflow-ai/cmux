import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { fileURLToPath } from "node:url";
import type { MachineDetail } from "./detail";
import type { CloudStore } from "./store";
import type { Strings } from "../shared/i18n";
import { FilesSection } from "./FilesSection";

const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const savedGlobals = new Map<string, unknown>();
for (const name of [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLTextAreaElement",
  "Event",
  "Node",
  "IS_REACT_ACT_ENVIRONMENT",
]) {
  savedGlobals.set(name, globals[name]);
  globals[name] = name === "IS_REACT_ACT_ENVIRONMENT" ? true : (dom.window as unknown as Record<string, unknown>)[name];
}
// Evaluate the DOM client after installing the document, even when another test imported it first.
const clientPath = fileURLToPath(
  new URL("./cjs/react-dom-client.development.js", import.meta.resolve("react-dom/client")),
);
delete require.cache[clientPath];
const { createRoot } = require(clientPath) as typeof import("react-dom/client");
afterAll(() => {
  dom.window.close();
  for (const [name, value] of savedGlobals) {
    if (value === undefined) delete globals[name];
    else globals[name] = value;
  }
});

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };

async function editor() {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const detail: MachineDetail = {
    machine: "machine-a",
    loading: false,
    files: {
      path: "/home/cmux",
      loading: false,
      entries: [],
      preview: { path: "/home/cmux/note.txt", size: 8, text: "original" },
    },
  };
  const writes: string[] = [];
  let finish!: (saved: boolean) => void;
  const store = {
    files: {
      save: (_path: string, text: string) => {
        writes.push(text);
        return new Promise<boolean>((resolve) => {
          finish = resolve;
        });
      },
    },
  } as unknown as CloudStore;
  await act(async () =>
    root.render(<FilesSection store={store} detail={detail} unavailable={[]} transfers={[]} strings={strings} />),
  );
  const click = async (selector: string) => {
    await act(async () => container.querySelector<HTMLButtonElement>(selector)!.click());
  };
  const type = async (text: string) => {
    await act(async () => {
      const input = container.querySelector("textarea")!;
      Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!.call(input, text);
      input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  };
  await click(".cloud-file-edit");
  return {
    container,
    writes,
    click,
    type,
    finish: async (saved: boolean) => {
      await act(async () => finish(saved));
    },
    close: () => {
      act(() => root.unmount());
      container.remove();
    },
  };
}

test("a successful delayed save preserves edits typed during the write and allows saving them next", async () => {
  const view = await editor();
  try {
    await view.type("submitted");
    await view.click(".cloud-file-save");
    expect(view.writes).toEqual(["submitted"]);
    expect(view.container.querySelector<HTMLButtonElement>(".cloud-file-save")!.disabled).toBe(true);
    await view.type("newer draft");
    await view.click(".cloud-file-save");
    expect(view.writes).toHaveLength(1);
    await view.finish(true);
    expect(view.container.querySelector("textarea")?.value).toBe("newer draft");
    await view.click(".cloud-file-save");
    expect(view.writes).toEqual(["submitted", "newer draft"]);
    await view.finish(true);
    expect(view.container.querySelector("textarea")).toBeNull();
  } finally {
    view.close();
  }
});

test("a failed save leaves the draft editable and can be retried", async () => {
  const view = await editor();
  try {
    await view.type("unsaved");
    await view.click(".cloud-file-save");
    await view.finish(false);
    expect(view.container.querySelector("textarea")?.value).toBe("unsaved");
    expect(view.container.querySelector<HTMLButtonElement>(".cloud-file-save")!.disabled).toBe(false);
    await view.click(".cloud-file-save");
    await view.finish(true);
    expect(view.writes).toEqual(["unsaved", "unsaved"]);
    expect(view.container.querySelector("textarea")).toBeNull();
  } finally {
    view.close();
  }
});

test("an old successful write cannot close a cancelled and reopened editor", async () => {
  const view = await editor();
  try {
    await view.click(".cloud-file-save");
    await view.click(".cloud-file-view .cloud-item-actions button:not(.cloud-file-save)");
    await view.click(".cloud-file-edit");
    await view.finish(true);
    expect(view.container.querySelector("textarea")?.value).toBe("original");
  } finally {
    view.close();
  }
});
