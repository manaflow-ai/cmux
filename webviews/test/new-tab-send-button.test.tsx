// The New Tab field's Return glyph (dogfood run, hq #1893): it looked like the send button, but a
// click on it did nothing; only the Return key sent the prompt. It is the Send button now, and a
// click asks the agent as Return does.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { parseImportedSession } from "../src/agent-session/acpmux/importSession";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "createImageBitmap",
  "OffscreenCanvas",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // jsdom has no pixel decoder. This engine adapter stages a real image attachment.
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const PNG = Uint8Array.from([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0,
  0,
  2,
  0x80,
  0,
  0,
  1,
  0xe0,
  ...Array(504).fill(7),
]);

test("a click on the field's Send button asks the agent, as Return does", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const asked: unknown[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        onAsk={(...args) => asked.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "fix the flaky upload test");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });

  const send = host.querySelector<HTMLButtonElement>('button[aria-label="Send"]');
  expect(send).not.toBeNull();
  await act(async () => send!.click());
  // On the model the chip names (cx-sljrg).
  expect(asked).toEqual([["claude", "fix the flaky upload test", "/Users/you/src/app", "claude-opus-5-5"]]);
});

test("New Tab /import opens the transcript flow and never sends the slash token as a prompt", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const asked: unknown[][] = [];
  const imported: File[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        onAsk={(...args) => asked.push(args)}
        onImportFile={(file) => {
          imported.push(file);
        }}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "/import");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  let opened = false;
  input.click = () => {
    opened = true;
  };
  await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
  expect(opened).toBe(true);
  expect(asked).toEqual([]);
  const file = new window.File(["{}"], "transcript.json", { type: "application/json" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(imported).toEqual([file]);
});

test("classic New Tab intercepts /import before its omnibar can treat it as a path", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const submitted: unknown[][] = [];
  const imported: File[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        lastAgent="claude"
        onSubmit={(...args) => {
          submitted.push(args);
        }}
        onImportFile={(file) => {
          imported.push(file);
        }}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLInputElement>("input:not([type=file])")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "/import");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  let opened = false;
  input.click = () => {
    opened = true;
  };
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(opened).toBe(true);
  expect(submitted).toEqual([]);
  const file = new window.File(["{}"], "transcript.json", { type: "application/json" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(imported).toEqual([file]);
});

type Template = "screen" | "classic";

async function commandPage(template: Template, onImportFile: (file: File) => Promise<void>) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const prompts: { text: string; attachments: ComposerAttachment[] }[] = [];
  const common = {
    snapshot: noChat(),
    lastAgent: "claude",
    cwd: "/Users/you/src/app",
    onImportFile,
    onOpenSession: noop,
    onShowAll: noop,
    onCmuxCommand: () => "Fork is unavailable for this chat right now",
  };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      template === "screen" ? (
        <NewTabScreen
          {...common}
          onAsk={(_agent, text, _cwd, _model, _none, attachments) => {
            prompts.push({ text, attachments: attachments ?? [] });
          }}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
        />
      ) : (
        <NewTabPage
          {...common}
          onSubmit={(_kind, text, _cwd, attachments) => {
            prompts.push({ text, attachments: attachments ?? [] });
          }}
        />
      ),
    ),
  );
  const field = host.querySelector<HTMLInputElement | HTMLTextAreaElement>(
    template === "screen" ? ".nt-field" : ".acpmux-newtab-field",
  )!;
  const edit = async (text: string) => {
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    await act(async () => {
      setValue.call(field, text);
      field.dispatchEvent(new window.Event("input", { bubbles: true }));
    });
  };
  const send = async () =>
    act(async () => {
      if (template === "screen") host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click();
      else host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
    });
  const paste = async () => {
    const event = new window.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: {
        files: [new File([PNG], "private.png", { type: "image/png" })],
        types: ["Files"],
        getData: () => "",
      },
    });
    await act(async () => field.dispatchEvent(event));
    expect(
      host.querySelector(".acpmux-attachment-image:not(.acpmux-attachment-pending):not(.acpmux-attachment-failed)"),
    ).not.toBeNull();
  };
  return { field, edit, send, paste, prompts };
}

for (const template of ["screen", "classic"] as const) {
  for (const outcome of ["cancel", "invalid transcript"] as const) {
    test(`${template}: /import consumes staged attachments after ${outcome}, not in the next prompt`, async () => {
      const imported: File[] = [];
      let failed = false;
      const page = await commandPage(template, async (file) => {
        imported.push(file);
        try {
          failed = parseImportedSession(await file.text(), file.name).messages.length === 0;
        } catch {
          failed = true;
        }
      });
      await page.paste();
      await page.edit("/import");
      const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
      let opened = false;
      input.click = () => {
        opened = true;
      };
      await page.send();
      expect(opened).toBe(true);
      expect(page.prompts).toEqual([]);
      expect(page.field.value).toBe("");
      expect(host.querySelector(".acpmux-attachment")).toBeNull();
      const file = new File(["{invalid json"], "broken.json", { type: "application/json" });
      Object.defineProperty(input, "files", {
        configurable: true,
        value: outcome === "cancel" ? [] : [file],
      });
      await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
      expect(imported).toEqual(outcome === "cancel" ? [] : [file]);
      expect(failed).toBe(outcome === "invalid transcript");
      await page.edit("Explain this function");
      await page.send();
      expect(page.prompts).toEqual([{ text: "Explain this function", attachments: [] }]);
    });
  }

  test(`${template}: a refused owned command preserves its draft and staged attachment`, async () => {
    const page = await commandPage(template, async () => {});
    await page.paste();
    await page.edit("/fork");
    await page.send();
    expect(page.prompts).toEqual([]);
    expect(page.field.value).toBe("/fork");
    expect(host.querySelector(".acpmux-attachment")).not.toBeNull();
    expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Fork is unavailable");
    await page.edit("Explain this file");
    await page.send();
    expect(page.prompts).toHaveLength(1);
    expect(page.prompts[0]!.attachments.map((attachment) => attachment.name)).toEqual(["private.png"]);
  });

  test(`${template}: a Claude terminal-only refusal preserves its draft`, async () => {
    const page = await commandPage(template, async () => {});
    await page.edit("/login");
    await page.send();
    expect(page.prompts).toEqual([]);
    expect(page.field.value).toBe("/login");
    expect(host.querySelector(".acpmux-attachment-note")).not.toBeNull();
  });
}
