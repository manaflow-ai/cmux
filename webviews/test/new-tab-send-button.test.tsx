// The New Tab field's Return glyph (dogfood run, hq #1893): it looked like the send button, but a
// click on it did nothing; only the Return key sent the prompt. It is the Send button now, and a
// click asks the agent as Return does.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { CMUX_PASS_THROUGH } from "../src/agent-session/acpmux/cmuxCommands";
import { parseImportedSession } from "../src/agent-session/acpmux/importSession";
import { inlineToken, inlineTokenIds, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { NewTabCommandActions } from "../src/agent-session/acpmux/newtab/useNewTabCommand";

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
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
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
async function writeScreenPrompt(host: HTMLElement, text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await act(async () => field.acpmuxMarkdownField!.writeText(text, text.length, text.length));
  return field;
}
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
  await writeScreenPrompt(host, "fix the flaky upload test");

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
  await writeScreenPrompt(host, "/import");
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

async function commandPage(
  template: Template,
  onImportFile?: (file: File) => Promise<void>,
  importError?: string,
  sandboxed = false,
  onCmuxCommand?: NewTabCommandActions["onCmuxCommand"],
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const prompts: { text: string; attachments: ComposerAttachment[] }[] = [];
  const common = {
    snapshot: noChat(),
    lastAgent: "claude",
    cwd: "/Users/you/src/app",
    ...(onImportFile ? { onImportFile } : {}),
    ...(importError ? { importError } : {}),
    ...(template === "screen"
      ? {
          runMode: {
            mode: sandboxed ? ("sandboxed" as const) : ("persistent" as const),
            onMode: noop,
          },
        }
      : { importSandboxed: sandboxed }),
    onOpenSession: noop,
    onShowAll: noop,
    onCmuxCommand: onCmuxCommand ?? (() => "Fork is unavailable for this chat right now"),
  };
  root = createRoot(host);
  const renderPage = () =>
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
    );
  await act(async () => renderPage());
  const setSandboxed = async (value: boolean) => {
    if ("runMode" in common) common.runMode.mode = value ? "sandboxed" : "persistent";
    else common.importSandboxed = value;
    await act(async () => renderPage());
  };
  const field =
    template === "screen"
      ? host.querySelector<MarkdownFieldElement>(".nt-field")!
      : host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  const value = () =>
    template === "screen"
      ? ((field as MarkdownFieldElement).acpmuxMarkdownField?.plainText() ?? "").replace(/\n$/, "")
      : (field as HTMLInputElement).value;
  const edit = async (text: string) => {
    await act(async () => {
      if (template === "screen") {
        const handle = (field as MarkdownFieldElement).acpmuxMarkdownField!;
        // Keep inline attachment atoms in this synthetic whole-prompt edit.
        const tokens = inlineTokenIds(handle.value()).map(inlineToken).join("");
        handle.type(`${text}${tokens}`);
        handle.setCaret(text.length);
      } else {
        const input = field as HTMLInputElement;
        const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!;
        setValue.call(input, text);
        input.dispatchEvent(new window.Event("input", { bubbles: true }));
      }
    });
  };
  const send = async (afterDispatch?: () => void) =>
    act(async () => {
      if (template === "screen") host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click();
      else host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
      afterDispatch?.();
    });
  const paste = async (file = new File([PNG], "private.png", { type: "image/png" }), pending = false) => {
    const event = new window.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: {
        files: [file],
        types: ["Files"],
        getData: () => "",
      },
    });
    const target = template === "screen" ? field.querySelector<HTMLElement>("[contenteditable]")! : field;
    await act(async () => target.dispatchEvent(event));
    const pendingSelector = ".acpmux-attachment-pending, .acpmux-md-inline-chip[data-state='loading']";
    const readySelector =
      ".acpmux-attachment-image:not(.acpmux-attachment-pending):not(.acpmux-attachment-failed), .acpmux-md-inline-chip[data-state='ready']";
    expect(host.querySelector(pending ? pendingSelector : readySelector)).not.toBeNull();
  };
  const waitForAttachment = async () => {
    const pendingSelector = ".acpmux-attachment-pending, .acpmux-md-inline-chip[data-state='loading']";
    for (let turn = 0; turn < 200 && host.querySelector(pendingSelector); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  return {
    field: {
      get value() {
        return value();
      },
    },
    edit,
    send,
    paste,
    waitForAttachment,
    prompts,
    setSandboxed,
  };
}

test("screen: a ready inline attachment survives /model passthrough", async () => {
  const page = await commandPage("screen", undefined, undefined, false, () => CMUX_PASS_THROUGH);
  await page.paste();
  await page.edit("/model opus");
  await page.send();
  expect(page.prompts).toHaveLength(1);
  expect(page.prompts[0]!.text).toBe("/model opus");
  expect(page.prompts[0]!.attachments.map((attachment) => attachment.name)).toEqual(["private.png"]);
});

for (const template of ["screen", "classic"] as const) {
  test(`${template}: /import supersedes an earlier send held for a pending image`, async () => {
    const imported: File[] = [];
    const page = await commandPage(template, async (file) => {
      imported.push(file);
    });
    const file = new File([PNG], "pending.png", { type: "image/png" });
    const bytes = await file.arrayBuffer();
    let resolve!: (bytes: ArrayBuffer) => void;
    Object.defineProperty(file, "arrayBuffer", {
      value: () =>
        new Promise<ArrayBuffer>((done) => {
          resolve = done;
        }),
    });
    await page.paste(file, true);
    await page.send();
    expect(page.prompts).toEqual([]);
    await page.edit("/import");
    const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
    let opened = 0;
    input.click = () => {
      opened += 1;
    };
    await page.send();
    expect(opened).toBe(1);
    expect(page.prompts).toEqual([]);
    expect(input.isConnected).toBe(true);
    expect(page.field.value).toBe("");
    expect(host.querySelector(".acpmux-attachment-pending")).toBeNull();
    await act(async () => resolve(bytes));
    expect(page.prompts).toEqual([]);
    const transcript = new File(["A transcript"], "conversation.txt", { type: "text/plain" });
    Object.defineProperty(input, "files", { configurable: true, value: [transcript] });
    await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
    expect(imported).toEqual([transcript]);
    await page.edit("A later prompt");
    await page.send();
    expect(page.prompts).toEqual([{ text: "A later prompt", attachments: [] }]);
  });

  for (const outcome of ["resolve", "reject", "edited"] as const) {
    test(`${template}: an async owned command preserves its text until ${outcome}`, async () => {
      let settle!: () => void;
      const accepted = new Promise<void>((resolve, reject) => {
        settle = outcome === "reject" ? () => reject(new Error("refused")) : resolve;
      });
      const page = await commandPage(
        template,
        async () => {},
        undefined,
        false,
        () => accepted,
      );
      await page.paste();
      await page.edit("/btw question");
      await page.send();
      expect(page.field.value).toBe("/btw question");
      expect(host.querySelector(".acpmux-attachment-image")).toBeNull();
      if (outcome === "edited") await page.edit("A later edit");
      await act(async () => settle());
      expect(page.field.value).toBe(
        outcome === "edited" ? "A later edit" : outcome === "reject" ? "/btw question" : "",
      );
      if (outcome === "reject") expect(host.querySelector(".acpmux-attachment-note")).not.toBeNull();
      expect(page.prompts).toEqual([]);
    });
  }

  test(`${template}: a terminal-only spelling waits for its pending image and sends as a prompt`, async () => {
    const page = await commandPage(template, async () => {});
    const file = new File([PNG], "pending.png", { type: "image/png" });
    const bytes = await file.arrayBuffer();
    let resolve!: (bytes: ArrayBuffer) => void;
    Object.defineProperty(file, "arrayBuffer", {
      value: () =>
        new Promise<ArrayBuffer>((done) => {
          resolve = done;
        }),
    });
    await page.paste(file, true);
    await page.edit("/login");
    await page.send();
    expect(page.prompts).toEqual([]);
    expect(host.querySelector(".acpmux-attachment-note")).toBeNull();
    await act(async () => resolve(bytes));
    expect(page.prompts).toHaveLength(1);
    expect(page.prompts[0]!.text).toBe("/login");
    expect(page.prompts[0]!.attachments.map((attachment) => attachment.name)).toEqual(["pending.png"]);
  });

  for (const accepted of [true, false]) {
    test(`${template}: pending attachment does not delay /import and is cancelled only when accepted=${accepted}`, async () => {
      const page = await commandPage(template, accepted ? async () => {} : undefined);
      const file = new File([PNG], "pending.png", { type: "image/png" });
      const bytes = await file.arrayBuffer();
      let resolve!: (bytes: ArrayBuffer) => void;
      Object.defineProperty(file, "arrayBuffer", {
        value: () =>
          new Promise<ArrayBuffer>((done) => {
            resolve = done;
          }),
      });
      await page.paste(file, true);
      await page.edit("/import");
      let opened = false;
      host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!.click = () => {
        opened = true;
      };
      await page.send(() => {
        expect(opened).toBe(accepted);
      });
      expect(page.field.value).toBe(accepted ? "" : "/import");
      expect(
        Boolean(host.querySelector(".acpmux-attachment-pending, .acpmux-md-inline-chip[data-state='loading']")),
      ).toBe(!accepted);
      expect(page.prompts).toEqual([]);
      await act(async () => {
        resolve(bytes);
      });
      await page.waitForAttachment();
      await page.edit("Explain this file");
      await page.send();
      expect(page.prompts).toHaveLength(1);
      expect(page.prompts[0]!.attachments.map((attachment) => attachment.name)).toEqual(
        accepted ? [] : ["pending.png"],
      );
    });
  }

  test(`${template}: ordinary prompts still wait for pending attachments`, async () => {
    const page = await commandPage(template, async () => {});
    const file = new File([PNG], "pending.png", { type: "image/png" });
    const bytes = await file.arrayBuffer();
    let resolve!: (bytes: ArrayBuffer) => void;
    Object.defineProperty(file, "arrayBuffer", {
      value: () =>
        new Promise<ArrayBuffer>((done) => {
          resolve = done;
        }),
    });
    await page.paste(file, true);
    await page.edit("Explain this file");
    await page.send();
    expect(page.prompts).toEqual([]);
    await act(async () => {
      resolve(bytes);
    });
    expect(page.prompts).toHaveLength(1);
    expect(page.prompts[0]!.attachments.map((attachment) => attachment.name)).toEqual(["pending.png"]);
  });

  test(`${template}: sandboxed /import refuses before the picker and preserves draft and attachments`, async () => {
    const imported: File[] = [];
    const page = await commandPage(
      template,
      async (file) => {
        imported.push(file);
      },
      undefined,
      true,
    );
    await page.paste();
    await page.edit("/import");
    const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
    let opened = false;
    input.click = () => {
      opened = true;
    };
    await page.send();
    expect(opened).toBe(false);
    expect(page.field.value).toBe("/import");
    expect(host.querySelector(".acpmux-attachment")).not.toBeNull();
    expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain(
      "Transcript import is unavailable in Sandboxed mode",
    );
    // A late picker result must obey the current mode too.
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [new File(["{}"], "transcript.json")],
    });
    await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
    expect(imported).toEqual([]);
    expect(page.prompts).toEqual([]);
  });

  test(`${template}: switching to sandboxed while the picker is open blocks the selected file`, async () => {
    const imported: File[] = [];
    const page = await commandPage(template, async (file) => {
      imported.push(file);
    });
    await page.edit("/import");
    const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
    let opened = false;
    input.click = () => {
      opened = true;
    };
    await page.send();
    expect(opened).toBe(true);
    await page.setSandboxed(true);
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [new File(["{}"], "transcript.json")],
    });
    await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
    expect(imported).toEqual([]);
    expect(page.prompts).toEqual([]);
    expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain(
      "Transcript import is unavailable in Sandboxed mode",
    );
  });

  test(`${template}: a rejected import is visible on New Tab`, async () => {
    const page = await commandPage(template, async () => {
      throw new Error("Transcript could not be imported");
    });
    await page.edit("/import");
    await page.send();
    const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [new File(["{}"], "transcript.json")],
    });
    await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
    expect(page.prompts).toEqual([]);
    expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Transcript could not be imported");
  });

  test(`${template}: the app's import error is visible on New Tab`, async () => {
    await commandPage(template, async () => {}, "Native import failed");
    expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Native import failed");
  });

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
