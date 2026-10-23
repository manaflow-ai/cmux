// Leo 2026-10-22: "but also why only 10 attachments per message? is that a model limitation or...
// idk i feel like we should have better situation handling for that". The 10 was the composer's own
// (attachments.ts MAX_ATTACHMENTS, #16583); no model API or acpmux has it. One message now takes
// what the chat's harness takes (composer/messageLimit.ts), within what one acpmux message carries;
// past that the files stay staged, Send takes the first ones, and the rest go with the next message.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
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
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

type Sent = { text: string; attachments: ComposerAttachment[] };

async function openComposer(harness: string, sent: Sent[]): Promise<RefObject<ComposerHandle | null>> {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId: "chat-a",
    summary: { sessionId: "chat-a", harness, cwd: "/Users/you/src/app", turnCount: 0 },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId="chat-a"
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  return handle;
}

const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52]);
const screenshot = (index: number) => new File([PNG], `shot-${index}.png`, { type: "image/png", lastModified: index });
const staged = (composer: RefObject<ComposerHandle | null>) => composer.current!.wakeState().attachments ?? [];

async function paste(files: File[]) {
  const field = host.querySelector<HTMLElement>('[role="combobox"]')!;
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { files, types: ["Files"], getData: () => "" },
  });
  await act(async () => {
    field.dispatchEvent(event);
  });
}

describe("the composer past one message's limit", () => {
  test("25 pasted screenshots all stay staged, and the composer names the limit", async () => {
    const composer = await openComposer("opencode", []);
    await paste(Array.from({ length: 25 }, (_, index) => screenshot(index)));
    await until(() => staged(composer).length === 25, "all 25 chips");
    expect(host.querySelector(".acpmux-attachment-note")?.textContent ?? "").not.toContain("Up to 10");
    const notice = host.querySelector(".acpmux-attachment-limit");
    expect(notice?.textContent).toContain("20");
    // The chips past the limit are marked as the next message's.
    expect(host.querySelectorAll(".acpmux-attachment[data-later]")).toHaveLength(5);
  });

  test("Send takes the first 20; the other 5 stay, and Send the rest sends them as the next message", async () => {
    const sent: Sent[] = [];
    const composer = await openComposer("opencode", sent);
    const files = Array.from({ length: 25 }, (_, index) => screenshot(index));
    await paste(files);
    await until(() => staged(composer).length === 25, "all 25 chips");
    await act(async () => {
      composer.current!.send();
    });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.attachments.map((item) => item.name)).toEqual(files.slice(0, 20).map((file) => file.name));
    expect(staged(composer).map((item) => item.name)).toEqual(files.slice(20).map((file) => file.name));
    const rest = host.querySelector<HTMLButtonElement>("button.acpmux-attachment-send-rest");
    expect(rest).not.toBeNull();
    await act(async () => {
      rest!.click();
    });
    expect(sent).toHaveLength(2);
    expect(sent[1]!.attachments.map((item) => item.name)).toEqual(files.slice(20).map((file) => file.name));
    expect(staged(composer)).toHaveLength(0);
    expect(host.querySelector(".acpmux-attachment-limit")).toBeNull();
  });

  test("under the limit nothing is held back and no notice shows", async () => {
    const sent: Sent[] = [];
    const composer = await openComposer("claude", sent);
    await paste(Array.from({ length: 12 }, (_, index) => screenshot(index)));
    await until(() => staged(composer).length === 12, "all 12 chips");
    expect(host.querySelector(".acpmux-attachment-limit")).toBeNull();
    await act(async () => {
      composer.current!.send();
    });
    expect(sent[0]!.attachments).toHaveLength(12);
    expect(staged(composer)).toHaveLength(0);
    expect(host.querySelector("button.acpmux-attachment-send-rest")).toBeNull();
  });
});
